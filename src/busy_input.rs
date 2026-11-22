use std::collections::HashMap;

use anyhow::{Result, ensure};
use gpui::{Anchor, AnyElement, Context, FontWeight, IntoElement, Task, div, prelude::*, px};
use gpui_component::{
    button::{Button, ButtonVariants},
    popover::Popover,
};
use reqwest::Method;
use serde_json::json;

use super::Desktop;
use crate::{
    gateway::Gateway,
    i18n::text as tr,
    icons,
    settings::Prepared,
    style::{INK, MUTED},
    theme::{ink, rgb},
};

#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum BusyInputMode {
    Interrupt,
    Queue,
    Steer,
}

impl BusyInputMode {
    fn from_config(value: &str) -> Self {
        match value.trim().to_ascii_lowercase().as_str() {
            "queue" => Self::Queue,
            "steer" => Self::Steer,
            _ => Self::Interrupt,
        }
    }

    fn wire(self) -> &'static str {
        match self {
            Self::Interrupt => "interrupt",
            Self::Queue => "queue",
            Self::Steer => "steer",
        }
    }

    fn label(self) -> &'static str {
        match self {
            Self::Interrupt => tr("中断"),
            Self::Queue => tr("排队"),
            Self::Steer => tr("引导"),
        }
    }

    fn detail(self) -> &'static str {
        match self {
            Self::Interrupt => tr("优先处理新消息"),
            Self::Queue => tr("当前回复结束后发送"),
            Self::Steer => tr("把新消息补充到当前回复"),
        }
    }

    pub(super) fn correction(self) -> Option<&'static str> {
        match self {
            Self::Interrupt => Some("session.redirect"),
            Self::Queue => None,
            Self::Steer => Some("session.steer"),
        }
    }
}

#[derive(Default)]
pub(super) struct BusyInput {
    modes: HashMap<String, BusyInputMode>,
    settings_jobs: HashMap<String, (Task<()>, bool)>,
    submit_jobs: HashMap<String, Task<()>>,
    open: bool,
}

async fn load_mode(gateway: &Gateway, profile: String) -> Result<BusyInputMode> {
    let config = gateway
        .api(Method::GET, "api/config", &[("profile", profile)], None)
        .await?;
    ensure!(config.is_object(), tr("网关未返回忙碌输入模式"));
    Ok(BusyInputMode::from_config(
        config["display"]["busy_input_mode"]
            .as_str()
            .unwrap_or_default(),
    ))
}

impl Desktop {
    pub(super) fn refresh_busy_input(&mut self, cx: &mut Context<Self>) {
        self.busy_input.open = false;
        self.change_busy_input(None, cx);
    }

    fn change_busy_input(&mut self, mode: Option<BusyInputMode>, cx: &mut Context<Self>) {
        let profile = self.model_profile();
        let Some(gateway) = self.gateway.clone().filter(|_| self.out.is_some()) else {
            return;
        };
        if profile.is_empty() || self.busy_input.settings_jobs.contains_key(&profile) {
            return;
        }

        let request_profile = profile.clone();
        let request = self.runtime.spawn(async move {
            if let Some(mode) = mode {
                let patch = json!({"config":{"display":{"busy_input_mode":mode.wire()}}});
                let response = gateway
                    .api(
                        Method::PUT,
                        "api/config",
                        &[("profile", request_profile)],
                        Some(patch),
                    )
                    .await?;
                ensure!(response["ok"] == true, tr("未收到网关确认"));
                Ok(mode)
            } else {
                load_mode(&gateway, request_profile).await
            }
        });
        let job_profile = profile.clone();
        let job = cx.spawn(async move |this, cx| {
            let result = request
                .await
                .map_err(anyhow::Error::from)
                .and_then(|value| value);
            let _ = this.update(cx, |desktop, cx| {
                desktop.busy_input.settings_jobs.remove(&job_profile);
                match result {
                    Ok(mode) => {
                        desktop.busy_input.modes.insert(job_profile, mode);
                    }
                    Err(error) => {
                        desktop.busy_input.modes.remove(&job_profile);
                        if mode.is_some() {
                            desktop.banner = Some(error.to_string().into());
                        }
                    }
                }
                cx.notify();
            });
        });
        self.busy_input
            .settings_jobs
            .insert(profile, (job, mode.is_some()));
    }

    pub(super) fn send_busy_text(
        &mut self,
        key: String,
        prepared: Prepared,
        cx: &mut Context<Self>,
    ) {
        let Some(gateway) = self.gateway.clone() else {
            return;
        };
        let profile = self.model_profile();
        let session = self.sessions.get_mut(&key).unwrap();
        let runtime = session.runtime.clone();
        let generation = session.generation;
        session.submitting = true;
        session.error = None;

        let request = self
            .runtime
            .spawn(async move { load_mode(&gateway, profile).await });
        let job_key = key.clone();
        let job = cx.spawn(async move |this, cx| {
            let result = request
                .await
                .map_err(anyhow::Error::from)
                .and_then(|value| value);
            let _ = this.update(cx, |desktop, cx| {
                desktop.busy_input.submit_jobs.remove(&job_key);
                match result {
                    Ok(mode) => {
                        desktop.route_busy_text(job_key, runtime, generation, prepared, mode, cx);
                    }
                    Err(error) => desktop.attachment_failed(&job_key, error.to_string()),
                }
                desktop.sync_list();
                cx.notify();
            });
        });
        self.busy_input.submit_jobs.insert(key, job);
    }

    pub(super) fn busy_input_saving(&self) -> bool {
        self.busy_input
            .settings_jobs
            .get(&self.model_profile())
            .is_some_and(|(_, writing)| *writing)
    }

    pub(super) fn busy_input_selector(&self, cx: &mut Context<Self>) -> Option<AnyElement> {
        self.out.as_ref()?;
        let profile = self.model_profile();
        if profile.is_empty() {
            return None;
        }
        let label = if self.busy_input_saving() {
            tr("正在保存…")
        } else {
            self.busy_input
                .modes
                .get(&profile)
                .map_or(tr("忙时发送"), |mode| mode.label())
        };
        let button = Button::new("busy-input-mode")
            .ghost()
            .compact()
            .h(px(20.))
            .tooltip(tr("忙时发送"))
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap_1()
                    .text_size(px(11.))
                    .text_color(ink(MUTED))
                    .child(
                        gpui::svg()
                            .path(icons::LIST_DETAILS)
                            .size(px(12.))
                            .text_color(ink(MUTED)),
                    )
                    .child(label),
            );
        let weak = cx.entity().downgrade();
        let toggle = weak.clone();
        Some(
            Popover::new("busy-input-menu")
                .anchor(Anchor::BottomRight)
                .open(self.busy_input.open)
                .on_open_change(move |open, _, cx| {
                    let _ = toggle.update(cx, |this, cx| {
                        let was_open = this.busy_input.open;
                        this.busy_input.open = *open;
                        if *open && !was_open {
                            this.change_busy_input(None, cx);
                        }
                        cx.notify();
                    });
                })
                .trigger(button)
                .content(move |_, _, cx| {
                    let Some(owner) = weak.upgrade() else {
                        return div();
                    };
                    let desktop = owner.read(cx);
                    let selected = desktop.busy_input.modes.get(&profile).copied();
                    let pending = desktop.busy_input.settings_jobs.contains_key(&profile);
                    let title = format!("{} · {}", tr("忙时发送"), profile);
                    div()
                        .w(px(208.))
                        .flex()
                        .flex_col()
                        .gap_1()
                        .child(
                            div()
                                .px_2()
                                .pb_1()
                                .truncate()
                                .text_size(px(12.))
                                .font_weight(FontWeight::SEMIBOLD)
                                .text_color(ink(MUTED))
                                .child(title),
                        )
                        .children(
                            [
                                BusyInputMode::Interrupt,
                                BusyInputMode::Queue,
                                BusyInputMode::Steer,
                            ]
                            .into_iter()
                            .map(|mode| {
                                let weak = weak.clone();
                                let profile = profile.clone();
                                div()
                                    .id(mode.wire())
                                    .px_2()
                                    .py_1()
                                    .rounded(px(4.))
                                    .flex()
                                    .items_center()
                                    .when(!pending, |row| {
                                        row.cursor_pointer().hover(|row| row.bg(rgb(0xf0f3f7)))
                                    })
                                    .child(
                                        div()
                                            .flex_1()
                                            .flex()
                                            .flex_col()
                                            .child(
                                                div()
                                                    .text_size(px(13.))
                                                    .text_color(ink(INK))
                                                    .child(mode.label()),
                                            )
                                            .child(
                                                div()
                                                    .text_size(px(11.))
                                                    .text_color(ink(MUTED))
                                                    .child(mode.detail()),
                                            ),
                                    )
                                    .when(selected == Some(mode), |row| {
                                        row.child(div().text_size(px(12.)).child("✓"))
                                    })
                                    .on_click(move |_, _, cx| {
                                        let _ = weak.update(cx, |desktop, cx| {
                                            if desktop.model_profile() == profile
                                                && !desktop
                                                    .busy_input
                                                    .settings_jobs
                                                    .contains_key(&profile)
                                            {
                                                desktop.busy_input.open = false;
                                                if desktop.busy_input.modes.get(&profile)
                                                    != Some(&mode)
                                                {
                                                    desktop.change_busy_input(Some(mode), cx);
                                                }
                                                cx.notify();
                                            }
                                        });
                                    })
                            }),
                        )
                })
                .into_any_element(),
        )
    }
}
