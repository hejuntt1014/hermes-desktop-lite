use std::collections::{HashMap, HashSet};

use chrono::{DateTime, Local, Utc};
use gpui::{
    Anchor, AnyElement, Context, Div, FontWeight, IntoElement, SharedString, div, prelude::*, px,
    rgb,
};
use gpui_component::{
    button::{Button, ButtonVariants},
    popover::Popover,
    progress::ProgressCircle,
    tooltip::Tooltip,
};
use serde_json::{Value, json};

use super::{Call, Desktop, model_controls::CatalogState, rpc_error};
use crate::{
    icons,
    style::{INK, MUTED},
};

#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum ApprovalMode {
    Manual,
    Smart,
    Off,
}

impl ApprovalMode {
    fn from_wire(value: &str) -> Option<Self> {
        match value {
            "manual" => Some(Self::Manual),
            "smart" => Some(Self::Smart),
            "off" => Some(Self::Off),
            _ => None,
        }
    }

    fn wire(self) -> &'static str {
        match self {
            Self::Manual => "manual",
            Self::Smart => "smart",
            Self::Off => "off",
        }
    }

    fn label(self) -> &'static str {
        match self {
            Self::Manual => "手动",
            Self::Smart => "智能",
            Self::Off => "关闭",
        }
    }

    fn detail(self) -> &'static str {
        match self {
            Self::Manual => "需要审批的操作会先询问",
            Self::Smart => "自动评估操作，必要时询问",
            Self::Off => "无需审批即可运行",
        }
    }
}

#[derive(Default)]
pub(super) struct ApprovalStatus {
    modes: HashMap<String, ApprovalMode>,
    pending: HashSet<String>,
    open: bool,
}

pub(super) struct CodexUsage {
    accounts: Vec<UsageAccount>,
}

struct UsageAccount {
    label: SharedString,
    windows: Vec<UsageWindow>,
}

struct UsageWindow {
    label: SharedString,
    used: f64,
    reset: Option<DateTime<Utc>>,
}

impl UsageWindow {
    fn open(&self) -> bool {
        self.reset.is_none_or(|reset| reset > Utc::now())
    }

    fn remaining(&self) -> f64 {
        100. - self.used
    }
}

impl CodexUsage {
    pub fn from_inventory(value: &Value) -> Option<Self> {
        let windows = |source: &Value| {
            source["windows"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|row| {
                    let used = row["used_percent"]
                        .as_f64()
                        .filter(|used| used.is_finite())?;
                    let reset = row["resets_at"]
                        .as_str()
                        .and_then(|date| DateTime::parse_from_rfc3339(date).ok())
                        .map(|date| date.with_timezone(&Utc));
                    Some(UsageWindow {
                        label: row["label"]
                            .as_str()
                            .unwrap_or("订阅用量")
                            .to_owned()
                            .into(),
                        used: used.clamp(0., 100.),
                        reset,
                    })
                })
                .collect::<Vec<_>>()
        };
        if let Some(accounts) = value["accounts"].as_array().filter(|list| !list.is_empty()) {
            return Some(Self {
                accounts: accounts
                    .iter()
                    .enumerate()
                    .map(|(index, row)| UsageAccount {
                        label: row["label"]
                            .as_str()
                            .filter(|label| !label.is_empty())
                            .map_or_else(|| format!("账户 {}", index + 1), str::to_owned)
                            .into(),
                        windows: windows(row),
                    })
                    .collect(),
            });
        }
        let windows = windows(value);
        (!windows.is_empty()).then(|| Self {
            accounts: vec![UsageAccount {
                label: SharedString::default(),
                windows,
            }],
        })
    }

    fn badge(&self) -> Option<String> {
        if self.accounts.len() > 1 {
            return Some(format!("Codex · {} 个账户", self.accounts.len()));
        }
        let remaining = self
            .accounts
            .first()?
            .windows
            .iter()
            .filter(|window| window.open())
            .map(UsageWindow::remaining)
            .reduce(f64::min)?;
        Some(format!("Codex · {remaining:.0}%"))
    }
}

pub(super) fn is_codex(provider: &str) -> bool {
    matches!(provider, "openai-codex" | "codex")
}

impl Desktop {
    pub(super) fn read_approval_mode(&mut self, mode: Option<ApprovalMode>) {
        let profile = self.model_profile();
        if !self.approval_status.pending.insert(profile.clone()) {
            return;
        }
        let mut params = json!({"key":"approvals.mode"});
        if !profile.is_empty() {
            params["profile"] = json!(profile);
        }
        if let Some(mode) = mode {
            params["value"] = json!(mode.wire());
        }
        let method = if mode.is_some() {
            "config.set"
        } else {
            "config.get"
        };
        if !self.call(
            method,
            params,
            Call::ApprovalMode(profile.clone(), mode.is_some()),
        ) {
            self.approval_status.pending.remove(&profile);
        }
    }

    pub(super) fn finish_approval_mode(
        &mut self,
        profile: String,
        write: bool,
        result: &Value,
        error: Option<&Value>,
    ) {
        self.approval_status.pending.remove(&profile);
        if let Some(error) = error {
            if write {
                self.banner = Some(rpc_error(error).into());
            }
        } else if let Some(mode) = result["value"].as_str().and_then(ApprovalMode::from_wire) {
            self.approval_status.modes.insert(profile, mode);
        }
    }

    pub(super) fn lose_approval_mode(&mut self, profile: &str, write: bool) {
        self.approval_status.pending.remove(profile);
        if write {
            self.banner = Some("未收到审批模式确认".into());
        }
    }

    pub(super) fn refresh_selection_status(&mut self, cx: &mut Context<Self>) {
        let profile = self.model_profile();
        self.approval_status.open = false;
        if !self.approval_status.modes.contains_key(&profile) {
            self.read_approval_mode(None);
        }
        if self
            .shown_model()
            .is_some_and(|model| is_codex(&model.provider))
        {
            self.load_codex_usage(false, cx);
        }
    }

    pub(super) fn refresh_context_usage(&mut self, key: &str) {
        let Some(session) = self
            .sessions
            .get(key)
            .filter(|session| session.attached && !session.running)
        else {
            return;
        };
        let mut params = json!({"session_id":session.runtime});
        if !session.profile.is_empty() {
            params["profile"] = json!(session.profile);
        }
        let action = Call::ContextUsage(key.to_owned(), session.generation, session.seq);
        self.call("session.context_breakdown", params, action);
    }

    pub(super) fn approval_selector(&self, cx: &mut Context<Self>) -> Option<AnyElement> {
        self.out.as_ref()?;
        let profile = self.model_profile();
        let current = self.approval_status.modes.get(&profile).copied();
        let label = current.map_or("审批", ApprovalMode::label);
        let button = Button::new("approval-mode")
            .ghost()
            .compact()
            .h(px(20.))
            .tooltip("审批模式")
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap_1()
                    .text_size(px(11.))
                    .text_color(rgb(MUTED))
                    .child(
                        gpui::svg()
                            .path(icons::ZAP)
                            .size(px(12.))
                            .text_color(rgb(MUTED)),
                    )
                    .child(label),
            );
        let weak = cx.entity().downgrade();
        let toggle = weak.clone();
        Some(
            Popover::new("approval-mode-menu")
                .anchor(Anchor::BottomRight)
                .open(self.approval_status.open)
                .on_open_change(move |open, _, cx| {
                    let _ = toggle.update(cx, |this, cx| {
                        this.approval_status.open = *open;
                        if *open
                            && !this
                                .approval_status
                                .modes
                                .contains_key(&this.model_profile())
                        {
                            this.read_approval_mode(None);
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
                    let selected = desktop.approval_status.modes.get(&profile).copied();
                    let pending = desktop.approval_status.pending.contains(&profile);
                    div()
                        .w(px(238.))
                        .flex()
                        .flex_col()
                        .gap_1()
                        .child(
                            div()
                                .px_2()
                                .pb_1()
                                .text_size(px(12.))
                                .font_weight(FontWeight::SEMIBOLD)
                                .text_color(rgb(MUTED))
                                .child("审批模式"),
                        )
                        .children(
                            [ApprovalMode::Manual, ApprovalMode::Smart, ApprovalMode::Off]
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
                                                        .text_color(rgb(INK))
                                                        .child(mode.label()),
                                                )
                                                .child(
                                                    div()
                                                        .text_size(px(11.))
                                                        .text_color(rgb(MUTED))
                                                        .child(mode.detail()),
                                                ),
                                        )
                                        .when(selected == Some(mode), |row| {
                                            row.child(div().text_size(px(12.)).child("✓"))
                                        })
                                        .on_click(move |_, _, cx| {
                                            let _ = weak.update(cx, |desktop, cx| {
                                                if !pending && desktop.model_profile() == profile {
                                                    desktop.approval_status.open = false;
                                                    if selected != Some(mode) {
                                                        desktop.read_approval_mode(Some(mode));
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

    pub(super) fn context_indicator(&self, _: &mut Context<Self>) -> Option<AnyElement> {
        let session = self.sessions.get(self.selected.as_ref()?)?;
        let usage = session.context?;
        let percent = (100. * usage.used as f64 / usage.maximum as f64).clamp(0., 100.);
        let amount = format!("{} / {}", tokens(usage.used), tokens(usage.maximum));
        let label = format!(
            "上下文 {amount} · {percent:.0}%{}",
            if usage.estimated { "（估算）" } else { "" }
        );
        Some(
            div()
                .id("context-usage")
                .flex_none()
                .flex()
                .items_center()
                .gap_1()
                .px_1()
                .text_size(px(11.))
                .text_color(rgb(MUTED))
                .aria_label(label.clone())
                .tooltip(move |window, cx| {
                    let detail = usage.cache_hit.map_or_else(
                        || label.clone(),
                        |hit| format!("{label}\n缓存命中 {hit:.0}%"),
                    );
                    Tooltip::new(detail).build(window, cx)
                })
                .child(
                    ProgressCircle::new("context-ring")
                        .size(px(14.))
                        .value(percent as f32)
                        .color(rgb(if percent >= 85. { 0xb17635 } else { 0x7d8ca1 })),
                )
                .child(amount)
                .into_any_element(),
        )
    }

    pub(super) fn codex_quota(&self, cx: &mut Context<Self>) -> Option<AnyElement> {
        if !self
            .shown_model()
            .is_some_and(|model| is_codex(&model.provider))
        {
            return None;
        }
        let profile = self.model_profile();
        let label = self
            .codex_usage_for(&profile)
            .and_then(CodexUsage::badge)
            .unwrap_or_else(|| "Codex 额度".to_owned());
        let desktop = cx.entity().downgrade();
        let refresh = desktop.clone();
        Some(
            Popover::new("codex-quota")
                .anchor(Anchor::BottomRight)
                .on_open_change(move |open, _, cx| {
                    if *open {
                        let _ = refresh.update(cx, |this, cx| this.load_codex_usage(true, cx));
                    }
                })
                .trigger(
                    Button::new("codex-quota-button")
                        .ghost()
                        .compact()
                        .h(px(20.))
                        .tooltip("查看 Codex 订阅额度")
                        .child(
                            div()
                                .text_size(px(11.))
                                .text_color(rgb(0x427762))
                                .child(label),
                        ),
                )
                .content(move |_, _, cx| {
                    let mut panel = div().w(px(222.)).flex().flex_col().gap_1().child(
                        div()
                            .text_size(px(12.))
                            .font_weight(FontWeight::SEMIBOLD)
                            .child("Codex 订阅额度"),
                    );
                    let Some(owner) = desktop.upgrade() else {
                        return panel;
                    };
                    if let Some(usage) = owner.read(cx).codex_usage_for(&profile) {
                        for account in &usage.accounts {
                            panel = panel.child(quota_account(account));
                        }
                    } else {
                        panel = panel.child(
                            div()
                                .text_size(px(11.))
                                .text_color(rgb(MUTED))
                                .child("网关暂无可用额度数据"),
                        );
                    }
                    panel
                })
                .into_any_element(),
        )
    }

    fn codex_usage_for(&self, profile: &str) -> Option<&CodexUsage> {
        match self.model_controls.catalogs.get(profile)? {
            CatalogState::Loaded(catalog) => catalog.codex_usage.as_ref(),
            _ => None,
        }
    }
}

fn quota_account(account: &UsageAccount) -> Div {
    let windows = account
        .windows
        .iter()
        .filter(|entry| entry.open())
        .collect::<Vec<_>>();
    div()
        .flex()
        .flex_col()
        .gap_1()
        .when(!account.label.is_empty(), |row| {
            row.child(
                div()
                    .text_size(px(11.))
                    .text_color(rgb(MUTED))
                    .child(account.label.clone()),
            )
        })
        .when(windows.is_empty(), |row| {
            row.child(
                div()
                    .text_size(px(11.))
                    .text_color(rgb(MUTED))
                    .child("暂无额度数据"),
            )
        })
        .children(windows.into_iter().map(|entry| {
            div()
                .flex()
                .flex_col()
                .child(
                    div()
                        .flex()
                        .justify_between()
                        .text_size(px(12.))
                        .child(entry.label.clone())
                        .child(format!("剩余 {:.0}%", entry.remaining())),
                )
                .children(entry.reset.map(|date| {
                    div()
                        .text_size(px(10.))
                        .text_color(rgb(MUTED))
                        .child(format!(
                            "{} 重置",
                            date.with_timezone(&Local).format("%m-%d %H:%M")
                        ))
                }))
        }))
}

fn tokens(value: u64) -> String {
    if value >= 1_000_000 {
        format!("{:.1}M", value as f64 / 1_000_000.)
    } else if value >= 1000 {
        format!("{:.1}k", value as f64 / 1000.)
    } else {
        value.to_string()
    }
}
