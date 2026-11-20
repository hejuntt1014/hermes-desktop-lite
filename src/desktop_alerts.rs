use super::Desktop;
use gpui::{Context, Window};

pub(super) enum Alert {
    Prompt(String),
    Reply,
    Preview,
}

impl Desktop {
    pub(super) fn sync_prompt_alerts(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !cfg!(windows) {
            return;
        }
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
    pub(super) fn desktop_alert(
        &mut self,
        _: &str,
        _: Alert,
        _: &mut Window,
        _: &mut Context<Self>,
    ) {
    }

    #[cfg(windows)]
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
            "Hermes Lite · 通知预览"
        } else if let Some(id) = &request {
            if self
                .sessions
                .get(key)
                .and_then(|s| s.prompts.get(id))
                .is_some_and(|p| p.clarify)
            {
                "等待你回答"
            } else {
                "等待你审批"
            }
        } else {
            "回复已完成"
        };
        let detail = format!("{} · {}", self.profile_label(&profile), tab.title);
        let title = tab.title.clone();
        let session = key.to_owned();
        let owner = self.settings.workspace_key().to_owned();
        let result = windows_toast(heading, &detail);
        let (toast, mut events) = match result {
            Ok(r) => r,
            Err(e) => {
                if preview {
                    self.banner = Some(format!("Windows 通知不可用 · {e}").into());
                    cx.notify();
                }
                eprintln!("Windows 通知发送失败: {e}");
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
                if this.settings.workspace_key() != owner {
                    return;
                }
                window.activate_window();
                this.close_settings(window, cx);
                this.close_palette(window, cx);
                if this.profile_editor.open {
                    this.close_profile_editor(window, cx)
                }
                if this.cron.open {
                    this.close_cron(window, cx)
                }
                let summary = crate::session::Summary::from_wire(
                    &serde_json::json!({"id":session,"profile":profile,"title":title}),
                )
                .unwrap();
                this.open_session(&summary, true, window, cx);
                if let Some(id) = request {
                    this.show_questions(&id, cx)
                }
                cx.notify();
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
