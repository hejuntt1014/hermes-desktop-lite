use crate::theme::{ink, rgb, rgba};

use crate::i18n::text as tr;

use gpui::{
    AnyElement, Context, Div, Entity, FocusHandle, FontWeight, ListOffset, Stateful, Subscription,
    Window, div, prelude::*, px,
};
use gpui_component::{
    Sizable,
    slider::{Slider, SliderEvent, SliderState},
    switch::Switch,
};

use crate::{
    i18n::Language,
    settings::{AttachmentTransport, DisplayPreferences, ReasoningVisibility},
};

use super::{
    Desktop,
    view::{icon_button, svg_symbol},
};
use crate::icons;

#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum SettingsPage {
    General,
    Appearance,
    Chat,
    Layout,
    Connection,
    Shortcuts,
}

impl SettingsPage {
    fn title(self) -> &'static str {
        match self {
            Self::General => tr("常规"),
            Self::Appearance => tr("外观"),
            Self::Chat => tr("聊天显示"),
            Self::Layout => tr("窗口与布局"),
            Self::Connection => tr("网关连接"),
            Self::Shortcuts => tr("键盘快捷键"),
        }
    }

    fn icon(self) -> &'static str {
        match self {
            Self::General => icons::SETTINGS,
            Self::Appearance => icons::SESSION_PALETTE,
            Self::Chat => icons::DISCUSSION,
            Self::Layout => icons::SIDEBAR_LEFT,
            Self::Connection => icons::WORLD,
            Self::Shortcuts => icons::TERMINAL,
        }
    }
}

pub(super) struct SettingsView {
    pub page: SettingsPage,
    pub connection_error: Option<gpui::SharedString>,
    focus: FocusHandle,
    previous_focus: Option<FocusHandle>,
    sidebar_transparency: Entity<SliderState>,
    _transparency_subscription: Subscription,
}

impl SettingsView {
    pub fn new(transparency: u8, cx: &mut Context<Desktop>) -> Self {
        let sidebar_transparency = cx.new(|_| {
            SliderState::new()
                .max(f32::from(DisplayPreferences::MAX_SIDEBAR_TRANSPARENCY))
                .default_value(f32::from(transparency))
        });
        let subscription = cx.subscribe(&sidebar_transparency, |desktop, _, event, cx| {
            if let SliderEvent::Change(value) = event {
                desktop
                    .settings
                    .display
                    .set_sidebar_transparency(value.end() as u8);
                desktop.schedule_save(cx);
                cx.notify();
            }
        });
        Self {
            page: SettingsPage::General,
            connection_error: None,
            focus: cx.focus_handle(),
            previous_focus: None,
            sidebar_transparency,
            _transparency_subscription: subscription,
        }
    }
}

impl Desktop {
    pub(super) fn toggle_settings(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.settings_open {
            self.close_settings(window, cx);
        } else {
            self.open_settings(self.settings_view.page, window, cx);
        }
    }

    pub(super) fn open_settings(
        &mut self,
        page: SettingsPage,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.media.is_open() || self.theme_saving() {
            return;
        }
        if !self.settings_open {
            self.close_files(window, cx);
            self.close_review(window, cx);
            self.close_transcript_find(window, cx);
            self.release_turn_rail(window, cx);
            self.settings_view.previous_focus = window.focused(cx);
            self.settings_view.connection_error = None;
            self.settings_open = true;
        }
        if page == SettingsPage::Appearance {
            self.refresh_wallpaper_gallery(cx);
        } else {
            self.cancel_theme_edit(cx);
        }
        self.settings_view.page = page;
        self.settings_view.focus.focus(window, cx);
        cx.notify();
    }

    pub(super) fn close_settings(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.settings_open || self.theme_saving() {
            return;
        }
        self.cancel_theme_edit(cx);
        self.settings_open = false;
        self.settings_view
            .previous_focus
            .take()
            .unwrap_or_else(|| self.workspace_focus.clone())
            .focus(window, cx);
        cx.notify();
    }

    pub(super) fn set_sidebar_open(
        &mut self,
        open: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.sidebar_open = open;
        self.settings.display.sidebar_open = open;
        self.remeasure_transcript();
        self.reveal_selected_tab();
        self.sync_cron(window, cx);
        self.persist(cx);
        cx.notify();
    }

    pub(super) fn remeasure_transcript(&mut self) {
        let cursor = self.list.logical_scroll_top();
        self.list.reset(self.visible_count);
        if !self.following {
            self.list.scroll_to(cursor);
        }
        self.sync_list();
    }

    pub(super) fn apply_reasoning_visibility(&mut self) {
        let hidden = match self.settings.display.reasoning {
            ReasoningVisibility::Gateway => {
                !self
                    .gateway_reasoning
                    .get(self.active_profile())
                    .copied()
                    .unwrap_or_default()
                    .visible
            }
            ReasoningVisibility::Visible => false,
            ReasoningVisibility::Hidden => true,
        };
        if self.hide_reasoning == hidden {
            return;
        }
        self.hide_reasoning = hidden;
        let cursor = self.list.logical_scroll_top();
        let row = self
            .timeline
            .get(cursor.item_ix)
            .map(|item| item.rows.start);
        self.timeline_raw_count = None;
        self.sync_list();
        if !self.following
            && let Some(row) = row
        {
            if let Some(item_ix) = self.visible_item_for(row) {
                self.list.scroll_to(ListOffset {
                    item_ix,
                    offset_in_item: cursor.offset_in_item,
                });
            } else if !self.timeline.is_empty() {
                let item_ix = self
                    .timeline
                    .partition_point(|item| item.rows.end <= row)
                    .min(self.timeline.len() - 1);
                self.list.scroll_to(ListOffset {
                    item_ix,
                    offset_in_item: px(0.),
                });
            }
            self.sync_turn_rail();
        }
    }

    pub(super) fn settings_overlay(
        &self,
        window: &Window,
        cx: &mut Context<Self>,
    ) -> Option<Stateful<Div>> {
        if !self.settings_open {
            return None;
        }
        let view = window.viewport_size();
        let page = self.settings_view.page;
        let width = (f32::from(view.width) - 54.).clamp(458., 1090.);
        let height = (f32::from(view.height) - 66.).clamp(318., 880.);
        let nav_width = (width * 0.20).clamp(142., 202.);
        let nav = div()
            .w(px(nav_width))
            .h_full()
            .flex_none()
            .flex()
            .flex_col()
            .bg(rgb(0xf5f7fb))
            .border_r_1()
            .border_color(rgb(0xe8edf4))
            .p_2()
            .children(
                [
                    SettingsPage::General,
                    SettingsPage::Appearance,
                    SettingsPage::Chat,
                    SettingsPage::Layout,
                    SettingsPage::Connection,
                    SettingsPage::Shortcuts,
                ]
                .into_iter()
                .enumerate()
                .map(|(index, candidate)| {
                    let selected = candidate == page;
                    div()
                        .id(("settings-page", index))
                        .h(px(32.))
                        .w_full()
                        .px_2()
                        .rounded(px(4.))
                        .flex()
                        .items_center()
                        .gap_2()
                        .cursor_pointer()
                        .text_size(px(12.))
                        .text_color(ink(if selected { 0x264371 } else { 0x4d596d }))
                        .when(selected, |row| row.bg(rgb(0xe2e9f8)))
                        .hover(|row| row.bg(rgb(0xe7edf8)))
                        .child(svg_symbol(
                            candidate.icon(),
                            14.,
                            if selected { 0x285684 } else { 0x6c7a8d },
                        ))
                        .child(candidate.title())
                        .on_click(cx.listener(move |this, _, window, cx| {
                            this.open_settings(candidate, window, cx)
                        }))
                }),
            );
        let body = match page {
            SettingsPage::General => self.general_preferences(cx),
            SettingsPage::Appearance => self.appearance_preferences(cx),
            SettingsPage::Chat => self.chat_preferences(cx),
            SettingsPage::Layout => self.layout_preferences(cx),
            SettingsPage::Connection => self.connection_preferences(cx),
            SettingsPage::Shortcuts => shortcuts(),
        };
        let heading = div()
            .h(px(43.))
            .flex_none()
            .w_full()
            .flex()
            .items_center()
            .px_4()
            .gap_2()
            .text_size(px(12.))
            .text_color(ink(0x64748b))
            .child(tr("设置"))
            .child("›")
            .child(div().flex_1().text_color(ink(0x243247)).child(page.title()))
            .child(
                icon_button("settings-close", icons::TAB_CLOSE, tr("关闭设置")).on_click(
                    cx.listener(|this, _, window, cx| {
                        cx.stop_propagation();
                        this.close_settings(window, cx);
                    }),
                ),
            );
        Some(
            div()
                .id("settings-backdrop")
                .absolute()
                .inset_0()
                .occlude()
                .bg(rgba(if page == SettingsPage::Appearance {
                    0x22334a26
                } else {
                    0x22334a4d
                }))
                .flex()
                .items_center()
                .justify_center()
                .on_click(cx.listener(|this, _, window, cx| this.close_settings(window, cx)))
                .child(
                    div()
                        .id("desktop-settings")
                        .key_context("HermesSettings")
                        .track_focus(&self.settings_view.focus)
                        .w(px(width))
                        .h(px(height))
                        .rounded(px(6.))
                        .shadow_lg()
                        .bg(rgb(0xfdfefe))
                        .border_1()
                        .border_color(rgb(0xe2e9f5))
                        .overflow_hidden()
                        .flex()
                        .on_click(|_, _, app| app.stop_propagation())
                        .child(nav)
                        .child(
                            div()
                                .flex_1()
                                .min_w_0()
                                .flex()
                                .flex_col()
                                .child(heading)
                                .child(
                                    div()
                                        .id((
                                            "settings-scroll",
                                            (page as usize) * 2
                                                + usize::from(self.theme_editor.is_some()),
                                        ))
                                        .flex_1()
                                        .min_h_0()
                                        .overflow_y_scroll()
                                        .px_4()
                                        .pb_4()
                                        .child(body),
                                ),
                        ),
                ),
        )
    }

    fn general_preferences(&self, cx: &mut Context<Self>) -> Div {
        setting_row(
            tr("界面语言"),
            None,
            segments(
                "interface-language",
                [
                    (Language::System, tr("跟随系统")),
                    (Language::SimplifiedChinese, "简体中文"),
                    (Language::English, "English"),
                ],
                self.settings.display.language,
                |this, language, window, cx| {
                    if this.settings.display.language != language {
                        this.settings.display.language = language;
                        this.apply_language(window, cx);
                    }
                },
                cx,
            ),
        )
    }

    fn chat_preferences(&self, cx: &mut Context<Self>) -> Div {
        let display = &self.settings.display;
        div()
            .flex()
            .flex_col()
            .child(setting_row(
                tr("附件上传方式"),
                Some(tr("自动模式优先通过 HTTP 传送大附件。")),
                segments(
                    "attachment-transport",
                    [AttachmentTransport::Auto, AttachmentTransport::Base64].map(|mode| (mode, mode.label())),
                    self.settings.attachment_transport,
                    |this, mode, _, _| this.settings.attachment_transport = mode,
                    cx,
                ),
            ))
            .child(setting_row(
                tr("消息字号"),
                None,
                segments(
                    "message-size",
                    [
                        (13, tr("小")),
                        (14, tr("标准")),
                        (16, tr("大")),
                        (18, tr("特大")),
                    ],
                    display.message_size,
                    |this, value, _, _| {
                        this.settings.display.message_size = value;
                        this.remeasure_transcript();
                    },
                    cx,
                ),
            ))
            .child(setting_row(
                tr("对话背景"),
                None,
                Switch::new("conversation-backdrop")
                    .small()
                    .checked(display.conversation_backdrop)
                    .on_click(cx.listener(|this, checked: &bool, _, cx| {
                        this.settings.display.conversation_backdrop = *checked;
                        this.persist(cx);
                        cx.notify();
                    })),
            ))
            .child(setting_row(
                tr("对话时间线"),
                Some(tr("显示会话右侧的轮次定位刻度。")),
                Switch::new("turn-rail-preference")
                    .small()
                    .checked(display.turn_rail)
                    .on_click(cx.listener(|this, checked: &bool, window, cx| {
                        this.settings.display.turn_rail = *checked;
                        if !checked {
                            this.release_turn_rail(window, cx);
                        }
                        this.persist(cx);
                        cx.notify();
                    })),
            ))
            .child(setting_row(
                tr("推理过程"),
                Some(tr("设置本机如何显示会话中的推理记录。")),
                segments(
                    "reasoning-visibility",
                    [
                        (ReasoningVisibility::Gateway, tr("跟随网关")),
                        (ReasoningVisibility::Visible, tr("显示")),
                        (ReasoningVisibility::Hidden, tr("隐藏")),
                    ],
                    display.reasoning,
                    |this, value, _, _| {
                        this.settings.display.reasoning = value;
                        this.apply_reasoning_visibility();
                    },
                    cx,
                ),
            ))
            .children(
                [
                    (true, tr("待处理提醒"), display.alert_prompts),
                    (false, tr("回复完成提醒"), display.alert_replies),
                ]
                .into_iter()
                .map(|(prompt, label, enabled)| {
                    setting_row(
                        label,
                        Some(tr("窗口在后台时发送桌面通知。")),
                        div()
                            .flex()
                            .items_center()
                            .gap_2()
                            .children((prompt && self.selected.is_some()).then(|| {
                                super::view::control("preview-toast", tr("预览通知")).on_click(
                                    cx.listener(|this, _, window, cx| {
                                        if let Some(key) = this.selected.clone() {
                                            this.desktop_alert(
                                                &key,
                                                super::desktop_alerts::Alert::Preview,
                                                window,
                                                cx,
                                            );
                                        }
                                    }),
                                )
                            }))
                            .child(Switch::new(label).small().checked(enabled).on_click(
                                cx.listener(move |this, checked: &bool, _, cx| {
                                    if prompt {
                                        this.settings.display.alert_prompts = *checked
                                    } else {
                                        this.settings.display.alert_replies = *checked
                                    }
                                    this.persist(cx);
                                    cx.notify();
                                }),
                            )),
                    )
                }),
            )
            .child(setting_row(
                tr("启动时恢复上次会话"),
                Some(tr("关闭后，启动时进入一个空白草稿。")),
                Switch::new("restore-session-preference")
                    .small()
                    .checked(display.restore_session)
                    .on_click(cx.listener(|this, checked: &bool, _, cx| {
                        this.settings.display.restore_session = *checked;
                        this.persist(cx);
                        cx.notify();
                    })),
            ))
    }

    fn layout_preferences(&self, cx: &mut Context<Self>) -> Div {
        div()
            .flex()
            .flex_col()
            .child(setting_row(
                tr("会话侧栏"),
                None,
                Switch::new("sidebar-preference")
                    .small()
                    .checked(self.sidebar_open)
                    .on_click(cx.listener(|this, checked: &bool, window, cx| {
                        this.set_sidebar_open(*checked, window, cx)
                    })),
            ))
            .children(cfg!(windows).then(|| {
                setting_row(
                    tr("侧栏磨砂"),
                    Some(tr("让窗口后方的画面轻微透出。")),
                    Switch::new("sidebar-glass")
                        .small()
                        .checked(self.settings.display.sidebar_glass)
                        .on_click(cx.listener(|this, checked: &bool, window, cx| {
                            this.settings.display.sidebar_glass = *checked;
                            window.set_background_appearance(
                                this.settings.display.window_background(),
                            );
                            this.persist(cx);
                            cx.notify();
                        })),
                )
            }))
            .children(cfg!(windows).then(|| {
                let enabled = self.settings.display.sidebar_glass;
                setting_row(
                    tr("磨砂透明度"),
                    Some(tr("数值越高，越能看见窗口后方的颜色。")),
                    div()
                        .flex_none()
                        .flex()
                        .items_center()
                        .gap_3()
                        .child(
                            div().w(px(126.)).child(
                                Slider::new(&self.settings_view.sidebar_transparency)
                                    .accessibility_label(tr("磨砂透明度"))
                                    .disabled(!enabled)
                                    .w_full(),
                            ),
                        )
                        .child(
                            div()
                                .w(px(32.))
                                .text_right()
                                .text_size(px(12.))
                                .text_color(ink(if enabled { 0x41608a } else { 0x77859a }))
                                .child(format!(
                                    "{}%",
                                    self.settings.display.sidebar_transparency()
                                )),
                        ),
                )
            }))
            .child(setting_row(
                tr("侧栏宽度"),
                None,
                segments(
                    "sidebar-width",
                    [(210, tr("紧凑")), (237, tr("标准")), (280, tr("宽"))],
                    self.settings.display.sidebar_width,
                    |this, value, _, _| {
                        this.settings.display.sidebar_width = value;
                        this.remeasure_transcript();
                        this.reveal_selected_tab();
                    },
                    cx,
                ),
            ))
    }

    fn connection_preferences(&self, cx: &mut Context<Self>) -> Div {
        div()
            .flex()
            .flex_col()
            .gap_3()
            .child(setting_row(
                tr("连接状态"),
                None,
                div()
                    .text_size(px(12.))
                    .text_color(ink(0x596980))
                    .child(tr(self.status)),
            ))
            .child(
                div()
                    .w_full()
                    .max_w(px(650.))
                    .child(self.gateway_form(true, cx)),
            )
            .children(self.settings_view.connection_error.as_ref().map(|error| {
                div()
                    .text_size(px(12.))
                    .text_color(ink(0xae413b))
                    .child(error.clone())
            }))
    }
}

pub(super) fn setting_row(
    title: &'static str,
    description: Option<&'static str>,
    control: impl IntoElement,
) -> Div {
    div()
        .min_h(px(57.))
        .py_2()
        .flex()
        .w_full()
        .items_center()
        .gap_3()
        .border_b_1()
        .border_color(rgb(0xecf0f5))
        .child(
            div()
                .min_w_0()
                .flex_1()
                .flex()
                .flex_col()
                .gap_1()
                .child(
                    div()
                        .text_size(px(13.))
                        .text_color(ink(0x29374a))
                        .child(title),
                )
                .children(description.map(|text| {
                    div()
                        .text_size(px(11.))
                        .text_color(ink(0x68768b))
                        .child(text)
                })),
        )
        .child(div().flex_none().child(control))
}

fn segments<T>(
    id: &'static str,
    options: impl IntoIterator<Item = (T, &'static str)>,
    selected: T,
    change: impl Fn(&mut Desktop, T, &mut Window, &mut Context<Desktop>) + Clone + 'static,
    cx: &mut Context<Desktop>,
) -> AnyElement
where
    T: Copy + Eq + 'static,
{
    div()
        .flex()
        .items_center()
        .gap(px(1.))
        .rounded(px(4.))
        .p(px(2.))
        .bg(rgb(0xe9edf5))
        .children(
            options
                .into_iter()
                .enumerate()
                .map(|(index, (value, label))| {
                    let change = change.clone();
                    div()
                        .id((id, index))
                        .h(px(24.))
                        .min_w(px(34.))
                        .px_2()
                        .rounded(px(3.))
                        .flex()
                        .items_center()
                        .justify_center()
                        .cursor_pointer()
                        .text_size(px(11.))
                        .text_color(ink(0x485971))
                        .when(value == selected, |part| {
                            part.bg(rgb(0xffffff)).text_color(ink(0x24457a))
                        })
                        .hover(|part| part.bg(rgb(0xf7f9fc)))
                        .on_click(cx.listener(move |this, _, window, cx| {
                            change(this, value, window, cx);
                            this.persist(cx);
                            cx.notify();
                        }))
                        .child(label)
                }),
        )
        .into_any_element()
}

fn shortcuts() -> Div {
    let mac = cfg!(target_os = "macos");
    div().flex().flex_col().children(
        [
            (
                tr("快速打开"),
                if mac {
                    tr("⌘K 或 ⌘P")
                } else {
                    tr("Ctrl+K 或 Ctrl+P")
                },
            ),
            (tr("新建会话"), if mac { "⌘N" } else { "Ctrl+N" }),
            (tr("前后切换标签"), "Ctrl+Tab / Ctrl+Shift+Tab"),
            (tr("关闭标签"), if mac { "⌘W" } else { "Ctrl+W" }),
            (
                tr("重新打开已关闭的标签"),
                if mac { "⌘⇧T" } else { "Ctrl+Shift+T" },
            ),
            (tr("会话内查找"), if mac { "⌘F" } else { "Ctrl+F" }),
            (tr("定位会话轮次"), "Alt+T"),
            (tr("工作区文件"), "Ctrl+Shift+E"),
            (tr("审查 Git 变更"), if mac { "⌘G" } else { "Ctrl+G" }),
            (tr("打开设置"), if mac { "⌘," } else { "Ctrl+," }),
        ]
        .into_iter()
        .map(|(label, key)| {
            setting_row(
                label,
                None,
                div()
                    .font_family(crate::theme::code_family())
                    .font_weight(FontWeight::MEDIUM)
                    .text_size(px(11.))
                    .text_color(ink(0x54657e))
                    .child(key),
            )
        }),
    )
}
