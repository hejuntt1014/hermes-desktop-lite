use crate::i18n::text as tr;

use super::Desktop;
use gpui::{Context, Window};

pub(super) enum Alert {
    Prompt(String),
    Reply,
    Preview,
}

pub(super) struct AlertTarget {
    owner: String,
    profile: String,
    session: String,
    title: String,
    request: Option<String>,
}

impl AlertTarget {
    fn open(self, desktop: &mut Desktop, window: &mut Window, cx: &mut Context<Desktop>) {
        if desktop.settings.workspace_key() != self.owner {
            return;
        }
        window.activate_window();
        desktop.close_settings(window, cx);
        desktop.close_palette(window, cx);
        if desktop.profile_editor.open {
            desktop.close_profile_editor(window, cx);
        }
        if desktop.cron.open {
            desktop.close_cron(window, cx);
        }
        if let Some(summary) = crate::session::Summary::from_wire(&serde_json::json!({
            "id": self.session,
            "profile": self.profile,
            "title": self.title,
        })) {
            desktop.open_session(&summary, true, window, cx);
            if let Some(id) = self.request {
                desktop.show_questions(&id, cx);
            }
            cx.notify();
        }
    }
}

impl Desktop {
    pub(super) fn sync_prompt_alerts(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let waiting = self
            .sessions
            .iter()
            .flat_map(|(sid, s)| s.prompts.keys().map(move |id| (sid.clone(), id.clone())))
            .collect::<std::collections::HashSet<_>>();
        if self.settings.display.alert_prompts && !window.is_window_active() {
            for (session, prompt) in waiting
                .difference(&self.notified_prompts)
                .cloned()
                .collect::<Vec<_>>()
            {
                self.desktop_alert(&session, Alert::Prompt(prompt), window, cx);
            }
        }
        self.notified_prompts = waiting;
    }

    #[cfg(not(windows))]
    pub(super) fn register_notification_handler(&self, window: &Window, cx: &mut Context<Self>) {
        let view = cx.entity().downgrade();
        let handle = window.window_handle();
        cx.on_system_notification_response(move |response, app| {
            let _ = handle.update(app, |_, window, app| {
                let _ = view.update(app, |desktop, cx| {
                    let Some(index) = desktop
                        .alert_targets
                        .iter()
                        .position(|(tag, _)| tag == &response.tag)
                    else {
                        return;
                    };
                    if let Some((_, target)) = desktop.alert_targets.remove(index) {
                        target.open(desktop, window, cx);
                    }
                });
            });
        });
    }

    pub(super) fn desktop_alert(
        &mut self,
        key: &str,
        alert: Alert,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(tab) = self
            .workspace()
            .and_then(|ws| ws.tabs.iter().find(|t| t.session.as_deref() == Some(key)))
        else {
            return;
        };
        let profile = self.tab_profile(tab).to_owned();
        let preview = matches!(alert, Alert::Preview);
        let request = match alert {
            Alert::Prompt(id) => Some(id),
            _ => None,
        };
        let heading = if preview {
            tr("Hermes Lite · 通知预览")
        } else if let Some(id) = &request {
            if self
                .sessions
                .get(key)
                .and_then(|s| s.prompts.get(id))
                .is_some_and(|p| p.clarify)
            {
                tr("等待你回答")
            } else {
                tr("等待你审批")
            }
        } else {
            tr("回复已完成")
        };
        let detail = format!("{} · {}", self.profile_label(&profile), tab.title);
        let target = AlertTarget {
            owner: self.settings.workspace_key().to_owned(),
            profile,
            session: key.to_owned(),
            title: tab.title.clone(),
            request,
        };
        self.post_desktop_alert(heading, detail, target, preview, window, cx);
    }

    #[cfg(not(windows))]
    fn post_desktop_alert(
        &mut self,
        heading: &str,
        detail: String,
        target: AlertTarget,
        _: bool,
        _: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.alert_targets.len() >= 64
            && let Some((old, _)) = self.alert_targets.pop_front()
        {
            cx.dismiss_system_notification(old.as_ref());
        }
        let tag: gpui::SharedString = uuid::Uuid::new_v4().to_string().into();
        self.alert_targets.push_back((tag.clone(), target));
        cx.show_system_notification(gpui::SystemNotification {
            tag,
            title: heading.to_owned().into(),
            body: detail.into(),
            actions: vec![gpui::SystemNotificationAction {
                id: "open-conversation".into(),
                label: tr("打开会话").into(),
            }],
        });
    }

    #[cfg(windows)]
    fn post_desktop_alert(
        &mut self,
        heading: &str,
        detail: String,
        target: AlertTarget,
        preview: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let result = windows_toast(heading, &detail);
        let (toast, mut events) = match result {
            Ok(r) => r,
            Err(e) => {
                if preview {
                    self.banner = Some(
                        crate::i18n::format_text!(
                            "Windows 通知不可用 · {e}",
                            "Windows notifications unavailable · {e}"
                        )
                        .into(),
                    );
                    cx.notify();
                }
                eprintln!(
                    "{}",
                    crate::i18n::format_text!(
                        "Windows 通知发送失败: {e}",
                        "Could not send Windows notification: {e}"
                    )
                );
                return;
            }
        };
        cx.spawn_in(window, async move |view, cx| {
            use futures_util::future::{Either, select};
            let timer = cx
                .background_executor()
                .timer(std::time::Duration::from_secs(3600));
            let clicked = matches!(
                select(Box::pin(events.recv()), Box::pin(timer)).await,
                Either::Left((Some(true), _))
            );
            drop(toast);
            if !clicked {
                return;
            }
            let _ = view.update_in(cx, move |this, window, cx| {
                target.open(this, window, cx);
            });
        })
        .detach();
    }
}

#[cfg(windows)]
fn windows_toast(
    title: &str,
    detail: &str,
) -> anyhow::Result<(
    windows::UI::Notifications::ToastNotification,
    tokio::sync::mpsc::UnboundedReceiver<bool>,
)> {
    use windows::{
        Data::Xml::Dom::XmlDocument,
        Foundation::TypedEventHandler,
        UI::Notifications::{
            ToastDismissalReason, ToastDismissedEventArgs, ToastNotification,
            ToastNotificationManager,
        },
        core::HSTRING,
    };
    use winreg::{RegKey, enums::HKEY_CURRENT_USER};
    const ID: &str = "Hermes.Desktop.Lite";
    let (key, _) = RegKey::predef(HKEY_CURRENT_USER)
        .create_subkey(r"Software\Classes\AppUserModelId\Hermes.Desktop.Lite")?;
    key.set_value("DisplayName", &"Hermes Desktop Lite")?;
    let xml = XmlDocument::new()?;
    xml.LoadXml(&HSTRING::from(
        "<toast><visual><binding template='ToastGeneric'><text/><text/></binding></visual></toast>",
    ))?;
    let lines = xml.GetElementsByTagName(&HSTRING::from("text"))?;
    for (i, text) in [title, detail].into_iter().enumerate() {
        lines.Item(i as u32)?.SetInnerText(&HSTRING::from(text))?
    }
    let toast = ToastNotification::CreateToastNotification(&xml)?;
    let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
    let click = tx.clone();
    toast.Activated(&TypedEventHandler::new(move |_, _| {
        let _ = click.send(true);
        Ok(())
    }))?;
    toast.Dismissed(&TypedEventHandler::<
        ToastNotification,
        ToastDismissedEventArgs,
    >::new(move |_, args| {
        if let Some(args) = args.as_ref()
            && args.Reason()? != ToastDismissalReason::TimedOut
        {
            let _ = tx.send(false);
        }
        Ok(())
    }))?;
    ToastNotificationManager::CreateToastNotifierWithId(&HSTRING::from(ID))?.Show(&toast)?;
    Ok((toast, rx))
}
