use crate::theme::{ink, ink_alpha, rgb, rgba};

use crate::i18n::text as tr;

use std::sync::Arc;

use crate::{
    AcceptCompletion, CloseCompletion, CloseFiles, CloseQueueEdit, CloseReview, CloseRewrite,
    DeferClarify, NextCompletion, PreviousCompletion, SaveQueueEdit, SubmitClarify, SubmitRewrite,
    ToggleFiles, ToggleReview, ToggleSettings,
};
use chrono::{DateTime, Datelike, Duration, Local, NaiveDate, Utc};
use gpui::{
    AnyElement, ClipboardItem, Context, Div, ExternalPaths, Focusable, IntoElement,
    ListSizingBehavior, ObjectFit, Render, SharedString, Window, div, list, prelude::*, px,
};
use gpui_component::{
    Sizable,
    button::{Button, ButtonVariants},
    input::{Paste, Textarea},
    scroll::Scrollbar,
    text::{TextView, TextViewStyle},
    tooltip::Tooltip,
};

use super::{
    Desktop,
    attachment_ops::{file_name, leading_file_refs},
    media_view::TranscriptImages,
    pane_layout::{DIVIDER, Pane, start_window_drag, toggle_maximized, workspace_dialog_size},
    remote_refs::{
        ReplyLink, ReplyPart, gateway_path, preserve_chat_breaks, reply_files, reply_links,
        scoped_path,
    },
    rewrite::RewriteKind,
    tool_view::{tool_row, tool_run},
};

#[path = "cron_view.rs"]
mod cron_view;
#[path = "model_picker_view.rs"]
mod model_picker_view;
#[path = "profile_editor_view.rs"]
mod profile_editor_view;
#[path = "sidebar_list.rs"]
mod sidebar_list;
#[path = "sidebar_tree.rs"]
mod sidebar_tree;
#[path = "sidebar_view.rs"]
mod sidebar_view;
pub(super) use sidebar_list::SidebarList;
#[path = "chat_markdown.rs"]
mod chat_markdown;
#[path = "composer_status.rs"]
mod composer_status;
#[path = "composer_tools.rs"]
mod composer_tools;
#[path = "tab_view.rs"]
mod tab_view;
use crate::{
    CloseChatTab, CloseImagePreview, ClosePalette, CloseSettings, CloseTranscriptFind,
    CommitPalette, FocusTurnRail, NewChat, NextChatTab, NextPalette, NextPreviewImage,
    NextTranscriptHit, OpenTranscriptFind, PreviousChatTab, PreviousPalette, PreviousPreviewImage,
    PreviousTranscriptHit, ReopenChatTab, SendMessage, TogglePalette, icons,
    media::{Message, is_image_file},
    session::{Prompt, Row, SessionTarget, Summary},
    style::{
        ACCENT, CONVERSATION_INK, INK, MESSAGE_INSET, MUTED, PARAGRAPH_GAP, SECONDARY,
        TRANSCRIPT_INSET, UI_TEXT_SIZE, conversation_font, interface_font,
    },
};

const LINE: u32 = 0xe4e7ed;
pub(super) const CANVAS: u32 = 0xfdfdfd;
const RAIL: u32 = 0xfefefe;
pub(super) const SURFACE: u32 = 0xffffff;
pub(super) const SELECTED: u32 = 0xe2e9f7;
pub(super) const DANGER: u32 = 0x9d3c32;
const UNREAD: u32 = 0x179f8b;
const USER_MESSAGE_BACKGROUND: u32 = 0xf0f6fd;
const USER_MESSAGE_BORDER: u32 = 0xd5e3f3;
const COMPOSER_LINE_HEIGHT: f32 = 20.;

pub(super) fn control(
    id: impl Into<gpui::ElementId>,
    label: impl Into<SharedString>,
) -> gpui::Stateful<Div> {
    div()
        .id(id)
        .flex_none()
        .flex()
        .items_center()
        .justify_center()
        .h(px(28.))
        .px_2()
        .rounded(px(5.))
        .text_size(px(12.))
        .text_color(ink(MUTED))
        .cursor_pointer()
        .hover(|style| style.bg(rgb(SELECTED)).text_color(ink(INK)))
        .child(label.into())
}

pub(super) fn primary(id: &'static str, label: &'static str, enabled: bool) -> gpui::Stateful<Div> {
    control(id, label)
        .px_3()
        .bg(if enabled {
            crate::theme::primary()
        } else {
            rgb(LINE)
        })
        .text_color(ink(if enabled { SURFACE } else { MUTED }))
        .hover(move |style| {
            style
                .bg(rgb(if enabled { 0x214ab0 } else { LINE }))
                .text_color(ink(if enabled { SURFACE } else { MUTED }))
        })
}

fn caption(label: &'static str) -> Div {
    div().text_size(px(11.)).text_color(ink(MUTED)).child(label)
}

pub(super) fn panel() -> Div {
    div()
        .bg(rgb(SURFACE))
        .border_1()
        .border_color(rgb(LINE))
        .rounded(px(8.))
}

pub(super) fn symbol(asset: &'static str, size: f32) -> Div {
    svg_symbol(asset, size, MUTED)
}

pub(super) fn svg_symbol(asset: &'static str, size: f32, color: u32) -> Div {
    div()
        .size(px(size))
        .flex_none()
        .child(gpui::svg().path(asset).size_full().text_color(ink(color)))
}

fn upload_card(upload: &crate::upload_progress::Display, cx: &mut Context<Desktop>) -> gpui::Stateful<Div> {
    use crate::upload_progress::{Stage, size_label};
    use gpui_component::progress::Progress;

    let stage = *upload.state.borrow();
    let (status, detail, percent) = match stage {
        Stage::Preparing => (tr("正在准备附件"), String::new(), None),
        Stage::Sending { sent, total, .. } => {
            let percent = (total > 0).then(|| (sent as f64 / total as f64 * 100.).min(99.9) as f32);
            let size = format!("{} / {}", size_label(sent), size_label(total));
            let pace = stage.speed_label();
            let detail = pace.map_or_else(|| size.clone(), |speed| format!("{size} · {speed}"));
            let status = if stage.waiting_for_network() {
                tr("等待网络")
            } else {
                tr("正在上传")
            };
            (status, detail, percent)
        }
        Stage::Awaiting { bytes } => (tr("确认中"), size_label(bytes), None),
    };

    let label = if let Some(value) = percent.filter(|_| !stage.waiting_for_network()) {
        format!("{}%", value.floor() as u32)
    } else {
        status.to_owned()
    };
    let name = file_name(&upload.path);
    let cancel_path = upload.path.clone();
    let icon = if is_image_file(&upload.path) {
        icons::PHOTO
    } else {
        icons::FILE
    };
    let muted = percent.is_none() || stage.waiting_for_network();

    div()
        .id("upload-file-card")
        .relative()
        .w(px(272.))
        .max_w_full()
        .min_w_0()
        .rounded(px(6.))
        .border_1()
        .border_color(ink(ACCENT).alpha(0.22))
        .bg(ink(ACCENT).alpha(0.055))
        .px_2()
        .py(px(6.))
        .flex()
        .flex_col()
        .gap(px(5.))
        .tooltip(move |window, cx| Tooltip::new(name.clone()).build(window, cx))
        .child(
            div()
                .min_w_0()
                .flex()
                .items_center()
                .gap(px(7.))
                .pr(px(17.))
                .child(div().flex_none().child(svg_symbol(icon, 15., ACCENT)))
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .flex()
                        .flex_col()
                        .child(
                            div()
                                .min_w_0()
                                .flex()
                                .items_center()
                                .gap(px(8.))
                                .text_size(px(11.))
                                .child(
                                    div()
                                        .flex_1()
                                        .min_w_0()
                                        .truncate()
                                        .text_color(ink(INK))
                                        .child(file_name(&upload.path)),
                                )
                                .child(
                                    div()
                                        .flex_none()
                                        .text_color(ink(if muted { MUTED } else { ACCENT }))
                                        .child(label),
                                ),
                        )
                        .child(
                            div()
                                .h(px(14.))
                                .flex()
                                .items_center()
                                .justify_between()
                                .gap(px(8.))
                                .text_size(px(10.))
                                .text_color(ink(MUTED))
                                .child(div().min_w_0().truncate().child(detail))
                                .when(upload.count > 1, |row| {
                                    row.child(
                                        div()
                                            .flex_none()
                                            .child(format!("{}/{}", upload.number, upload.count)),
                                    )
                                }),
                        ),
                ),
        )
        .child(
            Progress::new("attachment-upload-progress")
                .with_size(px(2.))
                .color(ink(ACCENT).alpha(if muted { 0.55 } else { 0.9 }))
                .accessibility_label(status)
                .value(percent.unwrap_or_default())
                .loading(percent.is_none()),
        )
        .child(
            icon_button("cancel-upload", icons::TAB_CLOSE, tr("取消上传"))
                .absolute()
                .right(px(4.))
                .top(px(2.))
                .size(px(17.))
                .on_click(cx.listener(move |this, _, _, cx| {
                    cx.stop_propagation();
                    this.remove_file(&cancel_path, cx);
                })),
        )
}

fn status_item(icon: &'static str, label: impl Into<SharedString>, icon_color: u32) -> Div {
    div()
        .h(px(20.))
        .min_w_0()
        .px_1()
        .flex()
        .items_center()
        .gap(px(4.))
        .child(svg_symbol(icon, 12., icon_color))
        .child(div().min_w_0().truncate().child(label.into()))
}

pub(super) fn icon_button(
    id: &'static str,
    glyph: &'static str,
    label: &'static str,
) -> gpui::Stateful<Div> {
    div()
        .id(id)
        .size(px(23.))
        .flex_none()
        .flex()
        .items_center()
        .justify_center()
        .rounded(px(4.))
        .text_color(ink(MUTED))
        .cursor_pointer()
        .hover(|style| style.bg(rgb(SELECTED)).text_color(ink(INK)))
        .tooltip(move |window, cx| Tooltip::new(label).build(window, cx))
        .child(symbol(glyph, 13.))
}

fn message_icon_button(
    id: &'static str,
    asset: &'static str,
    label: &'static str,
) -> gpui::Stateful<Div> {
    div()
        .id(id)
        .size(px(22.))
        .flex_none()
        .flex()
        .items_center()
        .justify_center()
        .rounded(px(4.))
        .text_color(ink(MUTED))
        .cursor_pointer()
        .hover(|style| style.bg(rgb(0xf0f3f7)).text_color(ink(INK)))
        .tooltip(move |window, cx| {
            Tooltip::new(label)
                .bg(rgb(0x292e35))
                .text_color(ink(0xffffff))
                .border_0()
                .shadow_none()
                .rounded(px(5.))
                .text_size(px(12.))
                .px_2()
                .py(px(4.))
                .build(window, cx)
        })
        .child(symbol(asset, 14.))
}

fn message_rewrite_action(
    kind: RewriteKind,
    index: usize,
    session: &str,
    entity: &gpui::Entity<Desktop>,
    app: &gpui::App,
) -> Option<gpui::Stateful<Div>> {
    if !entity.read(app).can_rewrite(session, index, kind) {
        return None;
    }
    let key = session.to_owned();
    let weak = entity.downgrade();
    let (id, icon, label) = match kind {
        RewriteKind::Edit => ("edit-message", icons::PENCIL, tr("编辑消息")),
        RewriteKind::Retry => ("retry-answer", icons::REFRESH, tr("重新生成答复")),
    };
    Some(
        message_icon_button(id, icon, label).on_click(move |_, window, cx| {
            let _ = weak.update(cx, |this, cx| {
                this.open_rewrite(&key, index, kind, window, cx)
            });
        }),
    )
}

fn local_day(timestamp: i64) -> Option<NaiveDate> {
    let time = DateTime::<Utc>::from_timestamp(timestamp, 0)?;
    Some((time.with_timezone(&Local) - Duration::hours(4)).date_naive())
}

fn session_date_group(timestamp: i64, today: NaiveDate) -> String {
    let Some(day) = (timestamp > 0).then(|| local_day(timestamp)).flatten() else {
        return String::new();
    };
    let elapsed = (today - day).num_days();
    let weekday = i64::from(today.weekday().num_days_from_monday());
    let month = [
        tr("一月"),
        tr("二月"),
        tr("三月"),
        tr("四月"),
        tr("五月"),
        tr("六月"),
        tr("七月"),
        tr("八月"),
        tr("九月"),
        tr("十月"),
        tr("十一月"),
        tr("十二月"),
    ][day.month0() as usize];
    let label = match elapsed {
        i64::MIN..=0 => tr("今天早些时候"),
        1 => tr("昨天"),
        n if n <= weekday => tr("本周早些时候"),
        n if n <= weekday + 7 => tr("上周"),
        _ if day.year() == today.year() && day.month() == today.month() => tr("本月早些时候"),
        _ if day.year() == today.year() => month,
        _ => return crate::i18n::format_text!("{}年{month}", "{} {month}", day.year()),
    };
    label.into()
}

fn recent_session_cutoff(rows: &[&Summary], today: NaiveDate) -> i64 {
    let mut best = None;
    for (index, pair) in rows.windows(2).enumerate() {
        let gap = pair[0].updated_at - pair[1].updated_at;
        if gap >= 1_800 {
            let score = (((index + 1) as f64) / 5.).ln().abs();
            if best.is_none_or(|(_, old_score, _)| score < old_score) {
                best = Some((index, score, gap > 28_800));
            }
        }
        if gap > 28_800 {
            break;
        }
    }
    match best {
        Some((index, _, true))
            if session_date_group(rows[0].updated_at, today)
                == session_date_group(rows[index + 1].updated_at, today) =>
        {
            i64::MAX
        }
        Some((index, _, _)) => rows[index].updated_at,
        None => i64::MIN,
    }
}

fn gateway_illustration(framing: ObjectFit) -> impl IntoElement {
    static ART: std::sync::LazyLock<std::sync::Arc<gpui::Image>> = std::sync::LazyLock::new(|| {
        std::sync::Arc::new(gpui::Image::from_bytes(
            gpui::ImageFormat::Png,
            include_bytes!("../assets/gateway-illustration.png").to_vec(),
        ))
    });
    gpui::img(ART.clone()).size_full().object_fit(framing)
}

fn conversation_backdrop(window: &Window) -> Div {
    static ART: std::sync::LazyLock<std::sync::Arc<gpui::Image>> = std::sync::LazyLock::new(|| {
        std::sync::Arc::new(gpui::Image::from_bytes(
            gpui::ImageFormat::Jpeg,
            include_bytes!("../assets/filler-bg0.jpg").to_vec(),
        ))
    });
    let viewport = window.viewport_size();
    let side = (viewport.height * 1.6).max(viewport.width);
    div().absolute().inset_0().overflow_hidden().child(
        gpui::img(ART.clone())
            .size(side)
            .flex_none()
            .object_fit(ObjectFit::Cover)
            .opacity(0.025),
    )
}

impl Render for Desktop {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let question_overlay = self.question_overlay(window, cx);
        let asking = question_overlay.is_some();
        let rewriting = self.rewrite_editor.is_some();
        let connecting = self.gateway.is_none() || self.login_url.is_some();
        if self.sidebar_open && !connecting {
            self.refresh_sidebar_layout();
        }
        let sidebar = (self.sidebar_open && !connecting).then(|| self.sidebar(window, cx));
        let divider = sidebar.is_some().then(|| {
            self.pane_divider(Pane::Sessions, cx)
                .bg(self.workspace_tint(CANVAS, 0.18))
        });
        let settings = connecting.then(|| self.gateway_settings(window, cx));
        let showing_chat = !connecting;
        let content = showing_chat.then(|| self.transcript(window, cx));
        let rail = (showing_chat && self.settings.display.turn_rail)
            .then(|| self.turn_rail_element())
            .flatten();
        let composer = showing_chat.then(|| self.composer_panel(window, cx));
        div()
            .id("desktop")
            .relative()
            .track_focus(&self.workspace_focus)
            .on_mouse_move(
                cx.listener(|this, event: &gpui::MouseMoveEvent, window, cx| {
                    this.voice_fan_pointer(event.position, window, cx);
                    if let Some(start) = this.maximized_drag {
                        let delta = event.position - start;
                        if event.pressed_button != Some(gpui::MouseButton::Left) {
                            this.maximized_drag = None;
                        } else if delta.x.abs() >= px(4.) || delta.y.abs() >= px(4.) {
                            this.maximized_drag = None;
                            start_window_drag(window);
                        }
                    }
                    this.move_pane(event, window, cx);
                }),
            )
            .on_mouse_up(
                gpui::MouseButton::Left,
                cx.listener(|this, _, _, cx| {
                    this.maximized_drag = None;
                    this.finish_pane_resize(cx);
                }),
            )
            .on_mouse_up_out(
                gpui::MouseButton::Left,
                cx.listener(|this, _, _, cx| {
                    this.maximized_drag = None;
                    this.finish_pane_resize(cx);
                }),
            )
            .key_context(if self.queue_editor.is_some() {
                "HermesLite HermesQueueEditOpen"
            } else if rewriting {
                "HermesLite HermesRewriteOpen"
            } else if asking {
                "HermesLite HermesClarifyOpen"
            } else if self.palette.open {
                "HermesLite HermesPaletteOpen"
            } else if self.media.is_open() {
                "HermesLite HermesImagePreview"
            } else if self.settings_open {
                "HermesLite HermesSettingsOpen"
            } else if self.session_dialog.is_some() {
                "HermesLite HermesSessionDialog"
            } else if self.profile_editor.open {
                "HermesLite HermesProfilesOpen"
            } else if self.cron.open {
                "HermesLite HermesCronOpen"
            } else if self.review.open {
                "HermesLite HermesReviewOpen"
            } else if self.files.open {
                "HermesLite HermesFilesOpen"
            } else if self.transcript_find.open {
                "HermesLite HermesFindOpen"
            } else {
                "HermesLite"
            })
            .on_action(cx.listener(|this, _: &DeferClarify, _, cx| this.defer_questions(cx)))
            .on_action(
                cx.listener(|this, _: &crate::CloseSessionDialog, window, cx| {
                    this.close_session_dialog(window, cx)
                }),
            )
            .on_action(cx.listener(|this, _: &SubmitClarify, window, cx| {
                this.submit_questions(false, window, cx)
            }))
            .on_action(
                cx.listener(|this, _: &CloseRewrite, window, cx| this.close_rewrite(window, cx)),
            )
            .on_action(
                cx.listener(|this, _: &SubmitRewrite, window, cx| this.confirm_rewrite(window, cx)),
            )
            .on_action(cx.listener(|this, _: &CloseQueueEdit, window, cx| {
                this.close_queue_editor(window, cx)
            }))
            .on_action(
                cx.listener(|this, _: &SaveQueueEdit, window, cx| {
                    this.save_queue_editor(window, cx)
                }),
            )
            .on_action(
                cx.listener(|this, _: &ToggleReview, window, cx| this.toggle_review(window, cx)),
            )
            .on_action(
                cx.listener(|this, _: &CloseReview, window, cx| this.close_review(window, cx)),
            )
            .on_action(
                cx.listener(|this, _: &crate::CloseCron, window, cx| this.close_cron(window, cx)),
            )
            .on_action(
                cx.listener(|this, _: &crate::CloseProfileEditor, window, cx| {
                    this.escape_profile_editor(window, cx)
                }),
            )
            .on_action(cx.listener(|this, _: &crate::SaveProfileSoul, window, cx| {
                this.save_profile_soul(window, cx)
            }))
            .on_action(
                cx.listener(|this, _: &ToggleFiles, window, cx| this.toggle_files(window, cx)),
            )
            .on_action(cx.listener(|this, _: &CloseFiles, window, cx| this.close_files(window, cx)))
            .on_action(
                cx.listener(|this, _: &ToggleSettings, window, cx| {
                    this.toggle_settings(window, cx)
                }),
            )
            .on_action(
                cx.listener(|this, _: &CloseSettings, window, cx| this.close_settings(window, cx)),
            )
            .on_action(
                cx.listener(|this, _: &TogglePalette, window, cx| this.toggle_palette(window, cx)),
            )
            .on_action(
                cx.listener(|this, _: &ClosePalette, window, cx| this.close_palette(window, cx)),
            )
            .on_action(
                cx.listener(|this, _: &CommitPalette, window, cx| this.commit_palette(window, cx)),
            )
            .on_action(
                cx.listener(|this, _: &NextPalette, window, cx| {
                    this.step_palette(false, window, cx)
                }),
            )
            .on_action(cx.listener(|this, _: &PreviousPalette, window, cx| {
                this.step_palette(true, window, cx)
            }))
            .on_action(cx.listener(|this, _: &NextChatTab, window, cx| {
                this.cycle_chat_tab(false, window, cx)
            }))
            .on_action(cx.listener(|this, _: &PreviousChatTab, window, cx| {
                this.cycle_chat_tab(true, window, cx)
            }))
            .on_action(cx.listener(|this, _: &FocusTurnRail, window, cx| {
                this.focus_turn_rail(window, cx);
            }))
            .on_action(cx.listener(|this, _: &CloseImagePreview, window, cx| {
                this.close_image(window, cx);
            }))
            .on_action(cx.listener(|this, _: &PreviousPreviewImage, window, cx| {
                this.move_preview_image(-1, window, cx);
            }))
            .on_action(cx.listener(|this, _: &NextPreviewImage, window, cx| {
                this.move_preview_image(1, window, cx);
            }))
            .on_action(cx.listener(|this, _: &OpenTranscriptFind, window, cx| {
                this.open_transcript_find(window, cx);
            }))
            .on_action(cx.listener(|this, _: &CloseTranscriptFind, window, cx| {
                this.close_transcript_find(window, cx);
            }))
            .on_action(cx.listener(|this, _: &NextTranscriptHit, window, cx| {
                this.navigate_transcript_find(false, window, cx);
            }))
            .on_action(cx.listener(|this, _: &PreviousTranscriptHit, window, cx| {
                this.navigate_transcript_find(true, window, cx);
            }))
            .on_action(cx.listener(|this, _: &NewChat, window, cx| this.new_chat_tab(window, cx)))
            .on_action(
                cx.listener(|this, _: &CloseChatTab, window, cx| this.close_active_tab(window, cx)),
            )
            .on_action(
                cx.listener(|this, _: &ReopenChatTab, window, cx| this.reopen_chat_tab(window, cx)),
            )
            .size_full()
            .font(interface_font())
            .flex()
            .flex_col()
            .text_size(px(UI_TEXT_SIZE))
            .text_color(ink(INK))
            .children(
                self.has_workspace_background()
                    .then(|| self.workspace_background()),
            )
            .child(self.title_strip(connecting, window, cx))
            .child(
                div()
                    .flex_1()
                    .min_h_0()
                    .flex()
                    .children(sidebar)
                    .children(divider)
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .relative()
                            .when(!self.has_workspace_background(), |pane| {
                                pane.bg(rgb(CANVAS))
                            })
                            .flex()
                            .flex_col()
                            .children(
                                (showing_chat
                                    && self.settings.display.conversation_backdrop
                                    && !self.has_workspace_background())
                                .then(|| conversation_backdrop(window)),
                            )
                            .children(self.banner.as_ref().map(|banner| {
                                div()
                                    .flex_none()
                                    .px_4()
                                    .py_1()
                                    .flex()
                                    .items_center()
                                    .gap_2()
                                    .bg(rgb(0xffeee8))
                                    .text_color(ink(DANGER))
                                    .text_sm()
                                    .child(div().flex_1().child(banner.clone()))
                                    .child(control("dismiss-banner", tr("关闭")).on_click(
                                        cx.listener(|this, _, _, cx| {
                                            this.banner = None;
                                            cx.notify();
                                        }),
                                    ))
                            }))
                            .children(settings)
                            .when(showing_chat, |this| {
                                this.children(content)
                                    .children(composer)
                                    .children(rail)
                                    .children(
                                        self.transcript_find
                                            .open
                                            .then(|| self.transcript_find_bar(window, cx)),
                                    )
                            }),
                    ),
            )
            .child(self.status_bar(cx))
            .children(
                (!connecting)
                    .then(|| self.workspace_popup(window, cx))
                    .flatten(),
            )
            .children(self.cron_overlay(window, cx))
            .children(self.profile_editor_overlay(window, cx))
            .children(self.voice_stop_notice(cx))
            .children(self.session_dialog_overlay(window, cx))
            .children(self.settings_overlay(window, cx))
            .children(self.palette_element(window, cx))
            .children(self.image_overlay(window, cx))
            .children(question_overlay)
            .children(self.rewrite_overlay(window, cx))
            .children(self.queue_editor_panel(window, cx))
            .children(
                (self.has_linux_client_chrome(window)
                    && !window.is_maximized()
                    && !window.is_fullscreen())
                .then(linux_resize_edges)
                .into_iter()
                .flatten(),
            )
    }
}

impl Desktop {
    fn workspace_popup(
        &self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<gpui::Stateful<Div>> {
        let (title, glyph, body) = if self.files.open {
            (
                tr("文件"),
                icons::FOLDER_OPEN,
                if self.files.collection.open {
                    self.session_files_element(cx)
                } else {
                    self.files_element(window, cx)
                },
            )
        } else if self.review.open {
            (
                tr("审查变更"),
                icons::BRANCH,
                self.review_element(window, cx),
            )
        } else {
            return None;
        };
        let size = workspace_dialog_size(window);
        let close = cx.listener(|this, _, window, cx| {
            cx.stop_propagation();
            this.close_files(window, cx);
            this.close_review(window, cx);
        });
        Some(
            div()
                .id("workspace-popup-backdrop")
                .absolute()
                .left_0()
                .right_0()
                .top(px(34.))
                .bottom(px(23.))
                .occlude()
                .bg(rgba(0x28374d3d))
                .flex()
                .items_center()
                .justify_center()
                .on_click(cx.listener(|this, _, window, cx| {
                    this.close_files(window, cx);
                    this.close_review(window, cx);
                }))
                .child(
                    div()
                        .id("workspace-popup")
                        .w(size.width)
                        .h(size.height)
                        .rounded(px(9.))
                        .border_1()
                        .border_color(rgb(0xdce3ef))
                        .bg(rgb(SURFACE))
                        .shadow_lg()
                        .overflow_hidden()
                        .flex()
                        .flex_col()
                        .on_click(|_, _, cx| cx.stop_propagation())
                        .child(
                            div()
                                .h(px(37.))
                                .px_3()
                                .flex_none()
                                .flex()
                                .items_center()
                                .gap_2()
                                .border_b_1()
                                .border_color(rgb(LINE))
                                .bg(rgb(0xfafbfd))
                                .child(svg_symbol(glyph, 15., MUTED))
                                .when(self.files.open, |bar| {
                                    bar.children(
                                        [(true, tr("本次会话")), (false, tr("工作区"))]
                                            .into_iter()
                                            .map(|(collection, label)| {
                                                control(label, label)
                                                    .when(
                                                        collection == self.files.collection.open,
                                                        |b| {
                                                            b.bg(rgb(SELECTED))
                                                                .text_color(ink(ACCENT))
                                                        },
                                                    )
                                                    .on_click(cx.listener(move |this, _, _, cx| {
                                                        if collection {
                                                            this.show_session_files(cx)
                                                        } else {
                                                            this.files.collection =
                                                                Default::default();
                                                            this.refresh_files_scope(cx);
                                                            cx.notify()
                                                        }
                                                    }))
                                            }),
                                    )
                                })
                                .child(
                                    div()
                                        .flex_1()
                                        .text_size(px(13.))
                                        .text_color(ink(INK))
                                        .font_weight(gpui::FontWeight::SEMIBOLD)
                                        .child(if self.files.open { "" } else { title }),
                                )
                                .child(
                                    icon_button(
                                        "close-workspace-popup",
                                        icons::TAB_CLOSE,
                                        tr("关闭弹窗"),
                                    )
                                    .on_click(close),
                                ),
                        )
                        .child(body),
                ),
        )
    }

    fn title_strip(&self, connecting: bool, window: &Window, cx: &mut Context<Self>) -> Div {
        use gpui::WindowControlArea;
        const CAPTION_BUTTON_WIDTH: f32 = 46.;
        let leading = 41.;
        let client_chrome = cfg!(windows) || self.has_linux_client_chrome(window);
        let chrome = |id: &'static str, icon: Div| {
            div()
                .id(id)
                .w(px(37.))
                .flex_none()
                .h_full()
                .flex()
                .items_center()
                .justify_center()
                .cursor_pointer()
                .hover(|s| s.bg(rgb(SELECTED)))
                .child(icon)
        };
        let unread = self.unread_recent_count();
        let sidebar_label = if self.sidebar_open {
            tr("隐藏会话侧栏")
        } else {
            tr("显示会话侧栏")
        };
        let sidebar_tip: SharedString = if unread == 0 {
            sidebar_label.into()
        } else {
            crate::i18n::format_text!(
                "{sidebar_label} · {unread} 个最近会话未读",
                "{sidebar_label} · {unread} unread recent conversation(s)"
            )
            .into()
        };
        let sidebar_icon = svg_symbol(icons::SIDEBAR_LEFT, 15., MUTED)
            .relative()
            .children((unread > 0).then(|| {
                div()
                    .absolute()
                    .top(px(-4.))
                    .right(px(-6.))
                    .min_w(px(11.))
                    .h(px(11.))
                    .px(px(2.))
                    .flex()
                    .items_center()
                    .justify_center()
                    .rounded(px(3.))
                    .border_1()
                    .border_color(rgb(SURFACE))
                    .bg(rgb(ACCENT))
                    .text_size(px(8.))
                    .line_height(px(8.))
                    .font_weight(gpui::FontWeight::SEMIBOLD)
                    .text_color(ink(SURFACE))
                    .child(if unread > 99 {
                        "99+".to_owned()
                    } else {
                        unread.to_string()
                    })
            }));
        let drag_area = |id: &'static str, cx: &mut Context<Self>| {
            div().id(id).flex_1().h_full().on_mouse_down(
                gpui::MouseButton::Left,
                cx.listener(|this, event: &gpui::MouseDownEvent, window, cx| {
                    cx.stop_propagation();
                    if event.click_count == 2 {
                        this.maximized_drag = None;
                        toggle_maximized(window);
                    } else if cfg!(windows) && window.is_maximized() {
                        this.maximized_drag = Some(event.position);
                    } else {
                        start_window_drag(window);
                    }
                }),
            )
        };
        let mut strip = div()
            .h(px(34.))
            .flex_none()
            .w_full()
            .flex()
            .items_center()
            .bg(self.workspace_tint(0xf4f5f7, 0.48))
            .border_b_1()
            .border_color(rgb(LINE))
            .child(
                div()
                    .w(px(leading))
                    .flex_none()
                    .h_full()
                    .flex()
                    .items_center()
                    .child(
                        chrome("rail-toggle", sidebar_icon)
                            .w(px(leading))
                            .tooltip(move |window, cx| {
                                Tooltip::new(sidebar_tip.clone()).build(window, cx)
                            })
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.set_sidebar_open(!this.sidebar_open, window, cx);
                            })),
                    ),
            )
            .when(connecting, |bar| {
                bar.child(
                    div()
                        .h_full()
                        .px_3()
                        .flex()
                        .items_center()
                        .border_b_2()
                        .border_color(rgb(ACCENT))
                        .text_size(px(13.))
                        .child(tr("远程网关")),
                )
            })
            .when(!connecting, |bar| {
                let chrome_width = 37. * 5.
                    + 28.
                    + if client_chrome {
                        CAPTION_BUTTON_WIDTH * 3.
                    } else {
                        0.
                    };
                let available =
                    (window.viewport_size().width - px(leading + chrome_width)).max(px(0.));
                bar.child(self.chat_tabs(available, window, cx)).child(
                    chrome("title-new", svg_symbol(icons::ADD, 15., MUTED))
                        .aria_label(tr("新建标签"))
                        .tooltip(|window, cx| Tooltip::new(tr("新建标签")).build(window, cx))
                        .on_click(cx.listener(|this, _, window, cx| this.new_chat_tab(window, cx))),
                )
            })
            .child(drag_area("drag-between-tabs-and-window-controls", cx).min_w(px(28.)))
            .when(!connecting, |bar| {
                bar.child(
                    chrome("title-files", svg_symbol(icons::FOLDER_OPEN, 16., MUTED))
                        .aria_label(tr("工作区文件"))
                        .when(self.files.open, |button| button.bg(rgb(SELECTED)))
                        .tooltip(|window, cx| Tooltip::new(tr("工作区文件")).build(window, cx))
                        .on_click(cx.listener(|this, _, window, cx| this.toggle_files(window, cx))),
                )
                .child(
                    chrome("title-review", svg_symbol(icons::BRANCH, 15., MUTED))
                        .aria_label(tr("审查工作区变更"))
                        .when(self.review.open, |button| button.bg(rgb(SELECTED)))
                        .tooltip(|window, cx| Tooltip::new(tr("审查工作区变更")).build(window, cx))
                        .on_click(
                            cx.listener(|this, _, window, cx| this.toggle_review(window, cx)),
                        ),
                )
            })
            .child(
                chrome("quick-open", svg_symbol(icons::SEARCH, 15., MUTED))
                    .tooltip(|window, cx| Tooltip::new(tr("快速打开")).build(window, cx))
                    .on_click(cx.listener(|this, _, window, cx| this.toggle_palette(window, cx))),
            )
            .child(
                chrome("settings", svg_symbol(icons::SETTINGS, 15., MUTED))
                    .tooltip(|window, cx| Tooltip::new(tr("设置")).build(window, cx))
                    .on_click(cx.listener(|this, _, window, cx| {
                        this.toggle_settings(window, cx);
                    })),
            );
        if client_chrome {
            for (id, asset, area, label) in [
                (
                    "min",
                    icons::CHROME_MINIMIZE,
                    WindowControlArea::Min,
                    tr("最小化窗口"),
                ),
                (
                    "max",
                    if window.is_maximized() {
                        icons::CHROME_RESTORE
                    } else {
                        icons::CHROME_MAXIMIZE
                    },
                    WindowControlArea::Max,
                    if window.is_maximized() {
                        tr("还原窗口")
                    } else {
                        tr("最大化窗口")
                    },
                ),
                (
                    "close",
                    icons::CHROME_CLOSE,
                    WindowControlArea::Close,
                    tr("关闭窗口"),
                ),
            ] {
                let close = matches!(area, WindowControlArea::Close);
                let button = div()
                    .id(id)
                    .aria_label(label)
                    .group(id)
                    .h_full()
                    .w(px(CAPTION_BUTTON_WIDTH))
                    .flex_none()
                    .flex()
                    .items_center()
                    .justify_center()
                    .hover(move |style| style.bg(rgb(if close { 0xc42b1c } else { 0xeef1f5 })))
                    .child(
                        gpui::svg()
                            .path(asset)
                            .size(px(14.))
                            .text_color(ink(0x20252c))
                            .when(close, |icon| {
                                icon.group_hover(id, |style| style.text_color(ink(0xffffff)))
                            }),
                    );
                strip = strip.child(button.window_control_area(area).on_click(cx.listener(
                    move |this, _, window, cx| {
                        cx.stop_propagation();
                        match area {
                            WindowControlArea::Min => window.minimize_window(),
                            WindowControlArea::Max => toggle_maximized(window),
                            WindowControlArea::Close => {
                                this.finish_pane_resize(cx);
                                this.record_window(window);
                                this.remember_reading();
                                this.persist(cx);
                                window.remove_window();
                            }
                            WindowControlArea::Drag => {}
                        }
                    },
                )));
            }
        }
        strip
    }

    fn has_linux_client_chrome(&self, window: &Window) -> bool {
        #[cfg(target_os = "linux")]
        {
            self.x11_client_chrome
                || matches!(
                    window.window_decorations(),
                    gpui::Decorations::Client { .. }
                )
        }
        #[cfg(not(target_os = "linux"))]
        {
            let _ = window;
            false
        }
    }

    fn attachment_transport_menu(&self, cx: &mut Context<Self>) -> impl IntoElement {
        use crate::settings::AttachmentTransport;
        use gpui_component::menu::DropdownMenu;

        let weak = cx.entity().downgrade();
        let mode = self.settings.attachment_transport;
        let label = match mode {
            AttachmentTransport::Auto => tr("上传 · 自动"),
            AttachmentTransport::Base64 => tr("上传 · Base64"),
        };
        Button::new("status-attachment-transport")
            .ghost()
            .compact()
            .h(px(20.))
            .tooltip(tr("附件上传方式"))
            .child(status_item(icons::FILE, label, MUTED))
            .dropdown_menu_with_anchor(gpui::Anchor::BottomLeft, move |menu, _, _| {
                [AttachmentTransport::Auto, AttachmentTransport::Base64].into_iter().fold(menu, |menu, item| {
                    menu.item(tab_view::menu_item(
                        &weak,
                        item.label(),
                        if item == mode { icons::TASK_CHECK } else { icons::FILE },
                        true,
                        move |this, _, cx| {
                            this.settings.attachment_transport = item;
                            this.persist(cx);
                            cx.notify();
                        },
                    ))
                })
            })
    }

    fn status_bar(&self, cx: &mut Context<Self>) -> Div {
        let host = self.gateway.as_ref().map_or_else(
            || tr("网关连接").to_owned(),
            |gateway| {
                let host = gateway.url.host_str().unwrap_or_default();
                if let Some(port) = gateway.url.port() {
                    format!("{host}:{port}")
                } else {
                    host.to_owned()
                }
            },
        );
        let cwd = self
            .selected
            .as_ref()
            .and_then(|key| self.sessions.get(key))
            .map(|session| session.cwd.clone())
            .filter(|cwd| !cwd.is_empty());
        let version = self.gateway_version.as_deref().map(|version| {
            crate::i18n::format_text!("后端 v{}", "Backend v{}", version.trim_start_matches('v'))
        });
        div()
            .h(px(23.))
            .flex_none()
            .px_2()
            .bg(self.workspace_tint(RAIL, 0.46))
            .border_t_1()
            .border_color(rgb(LINE))
            .flex()
            .items_center()
            .gap(px(6.))
            .text_size(px(11.))
            .text_color(ink(MUTED))
            .child(self.gateway_switcher(host, cx))
            .child(self.gateway_health(cx))
            .children(cwd.map(|cwd| {
                let name = cwd
                    .rsplit(['/', '\\'])
                    .find(|part| !part.is_empty())
                    .unwrap_or(cwd.as_ref())
                    .to_owned();
                status_item(icons::FOLDER_OPEN, name, MUTED)
                    .id("status-workspace")
                    .max_w(px(230.))
                    .rounded(px(3.))
                    .cursor_pointer()
                    .hover(|style| style.bg(rgb(SELECTED)))
                    .tooltip(move |window, cx| Tooltip::new(cwd.clone()).build(window, cx))
                    .on_click(cx.listener(|this, _, window, cx| this.open_files(window, cx)))
            }))
            .child(self.attachment_transport_menu(cx))
            .child(div().min_w_0().flex_1())
            .children(self.context_indicator(cx))
            .children(self.codex_quota(cx))
            .children(self.busy_input_selector(cx))
            .children(self.approval_selector(cx))
            .children(version.map(|label| status_item(icons::HASH, label, MUTED).max_w(px(180.))))
            .when(self.out.is_none() && self.gateway.is_some(), |this| {
                this.child(
                    status_item(icons::REFRESH, tr("重新连接"), SECONDARY)
                        .id("reconnect")
                        .flex_none()
                        .rounded(px(3.))
                        .cursor_pointer()
                        .hover(|style| style.bg(rgb(SELECTED)))
                        .on_click(cx.listener(|this, _, window, cx| {
                            this.reconnect_gateway(window, cx);
                        })),
                )
            })
    }

    fn gateway_settings(&self, window: &Window, cx: &mut Context<Self>) -> gpui::Stateful<Div> {
        let login = self.login_url.is_some();
        let narrow = window.viewport_size().width < px(664.);
        let pad = if narrow { 24. } else { 37. };
        let illustration = div()
            .relative()
            .flex_none()
            .overflow_hidden()
            .bg(rgb(0xe3e2fa))
            .when(narrow, |art| art.w_full().h(px(176.)))
            .when(!narrow, |art| {
                art.w(px(if login { 304. } else { 296. }))
                    .min_h(px(if login { 380. } else { 372. }))
            })
            .child(
                div()
                    .absolute()
                    .inset_0()
                    .child(gateway_illustration(if narrow {
                        ObjectFit::Contain
                    } else {
                        ObjectFit::Cover
                    })),
            );
        let target = self.gateway.as_ref().filter(|_| login).map(|gateway| {
            let host = gateway.url.host_str().unwrap_or_default();
            gateway
                .url
                .port()
                .map_or_else(|| host.to_owned(), |port| format!("{host}:{port}"))
        });
        let form = div()
            .flex_1()
            .min_w_0()
            .px(px(pad))
            .py(px(if narrow { 23. } else { 30. }))
            .flex()
            .flex_col()
            .justify_center()
            .gap(px(16.))
            .font(interface_font())
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap(px(7.))
                    .child(
                        div()
                            .text_size(px(12.))
                            .line_height(px(17.))
                            .font_weight(gpui::FontWeight::SEMIBOLD)
                            .text_color(ink(0x606e9a))
                            .child("Hermes Lite"),
                    )
                    .child(
                        div()
                            .text_size(px(if narrow { 24. } else { 28. }))
                            .line_height(px(37.))
                            .font_weight(gpui::FontWeight::SEMIBOLD)
                            .text_color(ink(0x252b43))
                            .child(if login {
                                tr("登录远程网关")
                            } else {
                                tr("连接网关")
                            }),
                    ),
            )
            .children(target.map(|host| {
                div()
                    .flex()
                    .items_center()
                    .gap(px(6.))
                    .text_size(px(12.))
                    .line_height(px(17.))
                    .text_color(ink(0x6e7895))
                    .child(svg_symbol(icons::WORLD, 13., 0x6978a1))
                    .child(div().min_w_0().truncate().child(host))
            }))
            .child(self.gateway_form(false, cx));
        let card = div()
            .w_full()
            .max_w(px(if login { 746. } else { 844. }))
            .flex_none()
            .min_w_0()
            .rounded(px(12.))
            .overflow_hidden()
            .border_1()
            .border_color(rgb(0xe1e6f2))
            .bg(rgb(0xffffff))
            .shadow_md()
            .flex()
            .items_stretch()
            .when(narrow, |card| card.flex_col())
            .child(illustration)
            .child(form);
        div()
            .id("gateway-onboarding")
            .flex_1()
            .min_h_0()
            .w_full()
            .overflow_y_scroll()
            .when(!self.has_workspace_background(), |page| {
                page.bg(rgb(0xf5f6fc))
            })
            .child(
                div()
                    .min_h_full()
                    .w_full()
                    .px_4()
                    .py_5()
                    .flex()
                    .flex_col()
                    .justify_center()
                    .items_center()
                    .child(card),
            )
    }

    fn transcript(&self, window: &Window, cx: &mut Context<Self>) -> AnyElement {
        let session = self
            .selected
            .as_ref()
            .and_then(|key| self.sessions.get(key));
        if self.visible_count == 0 {
            if self.out.is_some() && self.selected.is_none() {
                let pane_width = if self.sidebar_open {
                    px(self.sidebar_width(window))
                } else {
                    px(0.)
                };
                let area = window.viewport_size().width - pane_width;
                return div()
                    .flex_1()
                    .min_h_0()
                    .min_w_0()
                    .flex()
                    .items_center()
                    .justify_center()
                    .overflow_hidden()
                    .child(new_chat_intro(area, window))
                    .into_any_element();
            }
            let label = if self.out.is_none() {
                tr("连接远程网关后开始会话")
            } else if self
                .selected
                .as_ref()
                .is_some_and(|id| self.history_reads.contains_key(id))
            {
                tr("正在读取历史…")
            } else if session.is_some_and(|session| session.loading) {
                tr("正在恢复会话…")
            } else {
                tr("暂无消息")
            };
            return div()
                .flex_1()
                .min_h_0()
                .flex()
                .items_center()
                .justify_center()
                .text_color(ink(MUTED))
                .text_size(px(14.))
                .child(label)
                .into_any_element();
        }
        let entity = cx.entity();
        let revision = self.view_revision;
        let message_size = px(f32::from(self.settings.display.message_size.clamp(12, 20)));
        let branch_target = self
            .workspace()
            .filter(|_| self.out.is_some())
            .and_then(|workspace| {
                workspace
                    .tabs
                    .iter()
                    .find(|tab| Some(&tab.id) == workspace.active_tab.as_ref())
            })
            .and_then(|tab| {
                tab.session.as_ref().map(|id| SessionTarget {
                    id: id.clone(),
                    title: tab.title.clone(),
                    profile: if tab.profile.is_empty() {
                        session
                            .map(|session| session.profile.clone())
                            .unwrap_or_default()
                    } else {
                        tab.profile.clone()
                    },
                })
            });
        let transcript = list(self.list.clone(), move |index, window, app| {
            let data = {
                let desktop = entity.read(app);
                let Some(session) = desktop
                    .selected
                    .as_ref()
                    .and_then(|key| desktop.sessions.get(key))
                else {
                    return div().into_any_element();
                };
                let Some(item) = desktop.timeline.get(index) else {
                    return div().into_any_element();
                };
                if let Some(receipt) = item.receipt
                    && let Some(receipt) = session.command_receipts.get(receipt)
                {
                    return command_receipt_row(receipt, index).into_any_element();
                }
                let rail_target = desktop.turn_rail.focus.is_focused(window)
                    && desktop
                        .turn_rail
                        .jumped
                        .and_then(|turn| desktop.turns.get(turn))
                        .is_some_and(|turn| turn.item == index);
                let index = item.rows.start;
                let Some(row) = session.row(index) else {
                    return div().into_any_element();
                };
                let tools = if item.rows.len() > 1 {
                    item.rows
                        .clone()
                        .filter_map(|index| match session.row(index)? {
                            Row::Tool(tool) => Some(tool),
                            _ => None,
                        })
                        .collect()
                } else {
                    Vec::new()
                };
                let generated = match &row {
                    Row::Tool(tool) => tool.image.clone().filter(|image| {
                        let identity = image.identity();
                        !session
                            .rows
                            .iter()
                            .chain(&session.live)
                            .skip(index + 1)
                            .take_while(|row| !matches!(row, Row::User(_) | Row::Background(_)))
                            .any(|row| {
                                let Row::Answer(answer) = row else {
                                    return false;
                                };
                                answer
                                    .body
                                    .images()
                                    .iter()
                                    .any(|image| image.identity() == identity)
                                    || reply_files(answer.body.display(), false).iter().any(|part| {
                                        matches!(part, ReplyPart::File { path, .. }
                                            if crate::media::ChatImage::from_reference(path)
                                                .is_some_and(|image| image.identity() == identity))
                                    })
                                    || reply_links(answer.body.display()).1.iter().any(|link| {
                                        crate::media::ChatImage::from_reference(&link.path)
                                            .is_some_and(|image| image.identity() == identity)
                                    })
                            })
                    }),
                    _ => None,
                };
                (
                    index,
                    row,
                    tools,
                    desktop.expanded.contains(&index),
                    desktop.transcript_find.row_highlight(index),
                    rail_target,
                    desktop.selected.clone().unwrap_or_default(),
                    session.profile.clone(),
                    generated,
                )
            };
            let (index, row, tools, expanded, highlight, rail_target, session, profile, generated) =
                data;
            let is_activity = matches!(&row, Row::Tool(_) | Row::Background(_));
            let available = transcript_image_width(entity.read(app), window);
            let cwd = entity
                .read(app)
                .sessions
                .get(&session)
                .map(|session| session.cwd.clone())
                .unwrap_or_default();
            let images = TranscriptImages::new(&session, &profile, &cwd, available);
            let weak = entity.downgrade();
            let row_id = SharedString::from(format!("msg-{revision}-{index}"));
            div()
                .id(row_id.clone())
                .w_full()
                .px(px(TRANSCRIPT_INSET))
                .font(conversation_font())
                .text_size(message_size)
                .line_height(message_size * 1.5)
                .py(if is_activity { px(1.) } else { px(4.) })
                .flex()
                .justify_center()
                .child(
                    div()
                        .w_full()
                        .min_w_0()
                        .when(rail_target, |row| {
                            row.border_l_2().border_color(rgb(ACCENT)).rounded(px(4.))
                        })
                        .child(match row {
                            Row::User(text) => message_body(
                                row_id,
                                index,
                                text,
                                true,
                                highlight,
                                None,
                                None,
                                message_rewrite_action(
                                    RewriteKind::Edit,
                                    index,
                                    &session,
                                    &entity,
                                    app,
                                ),
                                entity.read(app).inline_rewrite(
                                    &session,
                                    index,
                                    message_size,
                                    weak.clone(),
                                    app,
                                ),
                                &images,
                                message_size,
                                &entity,
                                window,
                                app,
                            ),
                            Row::Answer(answer) => {
                                let branch = branch_target.clone().zip(answer.branch_point()).map(
                                    |(target, through)| {
                                        message_icon_button(
                                            "branch-message",
                                            icons::FORK,
                                            tr("在新对话中分支"),
                                        )
                                        .on_click(
                                            move |_, window, cx| {
                                                let _ = weak.update(cx, |this, cx| {
                                                    this.branch_session(
                                                        target.clone(),
                                                        Some(through.clone()),
                                                        window,
                                                        cx,
                                                    )
                                                });
                                            },
                                        )
                                    },
                                );
                                message_body(
                                    row_id,
                                    index,
                                    answer.body,
                                    false,
                                    highlight,
                                    answer.timestamp.map(|seconds| seconds as i64),
                                    branch,
                                    message_rewrite_action(
                                        RewriteKind::Retry,
                                        index,
                                        &session,
                                        &entity,
                                        app,
                                    ),
                                    None,
                                    &images,
                                    message_size,
                                    &entity,
                                    window,
                                    app,
                                )
                            }
                            Row::Reasoning(text) => {
                                let display = entity
                                    .read(app)
                                    .gateway_reasoning
                                    .get(profile.as_str())
                                    .copied()
                                    .unwrap_or_default();
                                reasoning_row(
                                    index,
                                    revision,
                                    text,
                                    display.expanded != expanded,
                                    weak,
                                )
                            }
                            Row::Tool(_) if !tools.is_empty() => {
                                tool_run(index, tools, &entity, app)
                            }
                            Row::Tool(tool) => {
                                let details = tool_row(index, tool, &entity, app);
                                let media = images.strip(generated.as_slice(), false, &entity, app);
                                div()
                                    .child(details)
                                    .children(
                                        media.map(|image| div().px(px(MESSAGE_INSET)).child(image)),
                                    )
                                    .into_any_element()
                            }
                            Row::Notice(text) => div()
                                .px(px(MESSAGE_INSET))
                                .text_sm()
                                .text_color(ink(DANGER))
                                .when_some(highlight, |notice, color| {
                                    notice.bg(rgb(color)).rounded(px(4.))
                                })
                                .child(text)
                                .into_any_element(),
                            Row::Background(notice) => background_result_row(
                                row_id,
                                index,
                                notice,
                                expanded,
                                highlight,
                                message_size,
                                &images,
                                &entity,
                                window,
                                app,
                            )
                            .into_any_element(),
                            Row::Command(receipt) => {
                                command_receipt_row(&receipt, index).into_any_element()
                            }
                        }),
                )
                .into_any_element()
        })
        .with_sizing_behavior(ListSizingBehavior::Auto)
        .flex_1()
        .min_h_0();
        let show_jump = !self.following && !self.at_latest();
        let messages_below = if show_jump { self.messages_below() } else { 0 };
        let scrollbar_moved = self.transcript_scrollbar.has_navigation();
        let desktop = cx.entity().downgrade();
        div()
            .when(show_jump || scrollbar_moved, |view| {
                view.on_children_prepainted(move |_, window, app| {
                    let Some(entity) = desktop.upgrade() else {
                        return;
                    };
                    if scrollbar_moved || entity.read(app).messages_below() != messages_below {
                        window.on_next_frame(move |_, cx| entity.update(cx, |this, cx| {
                            this.apply_transcript_scrollbar(cx);
                            cx.notify();
                        }));
                    }
                })
            })
            .id("transcript")
            .relative()
            .flex()
            .flex_col()
            .flex_1()
            .min_h_0()
            .overflow_hidden()
            .on_scroll(cx.listener(|this, event: &gpui::ScrollEvent, _, cx| {
                let delta = event.delta.pixel_delta(px(20.)).y;
                let Some(nav) = super::timeline::wheel_navigation(&this.list, delta) else {
                    return;
                };
                let changed = this.following != nav.following;
                this.following = nav.following;
                this.turn_rail.jumped = None;
                this.reading_moved(cx);
                if nav.load_older {
                    this.older_history(cx);
                }
                if this.sync_turn_rail() || changed {
                    cx.notify();
                }
            }))
            .child(transcript)
            .children(self.sticky_prompt(message_size, cx))
            .child(Scrollbar::vertical(&self.transcript_scrollbar))
            .children(show_jump.then(|| {
                let label = if messages_below > 0 {
                    crate::i18n::format_text!(
                        "{messages_below} 条消息",
                        "{messages_below} message(s)"
                    )
                } else {
                    tr("回到最新").to_owned()
                };
                let accessible_label = if messages_below == 0 {
                    label.clone()
                } else {
                    crate::i18n::format_text!("回到最新 · {label}", "Jump to latest · {label}")
                };
                div()
                    .absolute()
                    .left_0()
                    .right_0()
                    .bottom(px(14.))
                    .flex()
                    .justify_center()
                    .child(
                        div()
                            .id("jump-to-latest")
                            .block_mouse_except_scroll()
                            .h(px(30.))
                            .px_3()
                            .flex()
                            .items_center()
                            .gap_1()
                            .rounded_full()
                            .border_1()
                            .border_color(rgb(0xdce3ed))
                            .bg(rgba(0xfafbfcf8))
                            .shadow_sm()
                            .text_size(px(12.))
                            .text_color(ink(MUTED))
                            .cursor_pointer()
                            .aria_label(accessible_label)
                            .hover(|pill| pill.bg(rgb(0xffffff)).text_color(ink(INK)))
                            .child(symbol(icons::ARROW_DOWN, 14.))
                            .child(label)
                            .on_click(cx.listener(|this, _, _, cx| {
                                cx.stop_propagation();
                                this.following = true;
                                this.turn_rail.jumped = None;
                                this.reading_moved(cx);
                                this.sync_list();
                                cx.notify();
                            })),
                    )
            }))
            .into_any_element()
    }

    fn messages_below(&self) -> usize {
        let top_item = self.list.logical_scroll_top().item_ix;
        let below_top = self.message_items.partition_point(|&item| item < top_item);
        let bottom = self.list.viewport_bounds().bottom() + px(1.);
        let remaining = &self.message_items[below_top..];
        let fully_visible = remaining
            .iter()
            .take_while(|&&item| {
                self.list
                    .bounds_for_item(item)
                    .is_some_and(|bounds| bounds.bottom() <= bottom)
            })
            .count();
        remaining.len() - fully_visible
    }

    fn sticky_prompt(
        &self,
        message_size: gpui::Pixels,
        cx: &mut Context<Self>,
    ) -> Option<gpui::Stateful<Div>> {
        if self.following || self.transcript_find.open {
            return None;
        }
        let top_item = self.list.logical_scroll_top().item_ix;
        let next = self.turns.partition_point(|turn| turn.item <= top_item);
        let turn = self.turns.get(next.checked_sub(1)?)?;
        if self.list.item_is_above_viewport(turn.item) != Some(true) {
            return None;
        }
        let viewport = self.list.viewport_bounds();
        let height = (message_size * 1.35 + px(13.)).max(px(29.));
        let inset = px(4.);
        let top = self
            .turns
            .get(next)
            .and_then(|next| self.list.bounds_for_item(next.item))
            .map_or(inset, |bounds| {
                inset.min(bounds.top() - viewport.top() - height)
            });
        if top + height <= px(0.) {
            return None;
        }
        let target = turn.item;
        let revision = self.view_revision;
        Some(
            div()
                .id("sticky-prompt")
                .block_mouse_except_scroll()
                .absolute()
                .top(top)
                .left(px(TRANSCRIPT_INSET))
                .right(px(TRANSCRIPT_INSET))
                .h(height)
                .px(px(MESSAGE_INSET))
                .flex()
                .items_center()
                .gap_2()
                .rounded(px(4.))
                .border_1()
                .border_color(rgb(USER_MESSAGE_BORDER))
                .bg(rgb(USER_MESSAGE_BACKGROUND))
                .shadow_sm()
                .text_color(ink(CONVERSATION_INK))
                .text_size(message_size)
                .cursor_pointer()
                .tooltip(|window, cx| Tooltip::new(tr("回到这条提问")).build(window, cx))
                .child(
                    div()
                        .min_w_0()
                        .flex_1()
                        .truncate()
                        .child(turn.preview.clone()),
                )
                .child(svg_symbol(icons::ARROW_UP, 13., MUTED).flex_none())
                .on_click(cx.listener(move |this, _, _, cx| {
                    if this.view_revision != revision {
                        return;
                    }
                    this.list.scroll_to(gpui::ListOffset {
                        item_ix: target,
                        offset_in_item: px(0.),
                    });
                    this.turn_rail.jumped = None;
                    this.reading_moved(cx);
                    this.sync_turn_rail();
                    cx.notify();
                })),
        )
    }

    fn composer_panel(&mut self, window: &mut Window, cx: &mut Context<Self>) -> Div {
        let focused = self.composer.read(cx).focus_handle(cx).is_focused(window);
        let session = self
            .selected
            .as_ref()
            .and_then(|key| self.sessions.get(key));
        let running = session.is_some_and(|session| session.running);
        let awaiting_input = session.is_some_and(|s| !s.prompts.is_empty());
        let session_id = self.selected.as_deref();
        let collapsed = session_id.is_some_and(|id| {
            self.workspace()
                .is_some_and(|workspace| workspace.collapsed_composer_status.contains(id))
        });
        let has_queue = session_id
            .zip(session)
            .is_some_and(|(key, session)| !session.queued.is_empty() || self.has_followups(key));
        let queue = if collapsed || !has_queue {
            None
        } else {
            session_id
                .zip(session)
                .and_then(|(key, session)| self.queue_panel(key, session, cx))
        };
        let loading = session.is_some_and(|session| session.loading || session.submitting);
        let enabled = self.out.is_some()
            && !self.creating()
            && !loading
            && self.rewrite_editor.is_none()
            && (self.selected.is_none() || session.is_some_and(|session| session.attached));
        let error = session.and_then(|session| {
            session
                .error
                .clone()
                .or_else(|| session.turn_error.clone())
                .or_else(|| session.history_error.clone())
        });
        let prompts = session
            .map(|session| {
                session
                    .prompts
                    .iter()
                    .map(|(key, prompt)| (key.clone(), prompt.clone()))
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        let uncertain = session.is_some_and(|session| session.uncertain);
        let unknown = session
            .map(|session| {
                session
                    .unknown
                    .iter()
                    .map(|(id, (_, text))| (id.clone(), text.clone()))
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        let workspace = session
            .filter(|session| !session.branch.is_empty() || !session.cwd.is_empty())
            .map(|session| (session.branch.clone(), session.cwd.clone()));
        let status_grip = session_id
            .filter(|_| workspace.is_some() || has_queue)
            .map(|id| self.composer_status_grip(id.to_owned(), collapsed, has_queue, cx));
        let tasks = session_id
            .zip(session)
            .and_then(|(key, session)| self.composer_todos(key, session, cx));
        let work = session_id
            .zip(session)
            .filter(|(_, session)| session.activity.has_work())
            .map(|(key, session)| self.composer_work(key, session, cx));
        let mut stack = div()
            .w_full()
            .flex()
            .flex_col()
            .gap_2()
            .children(self.model_confirmation(cx));
        let rewrite = self
            .selected
            .as_deref()
            .and_then(|key| self.rewrite_recovery(key, cx));
        let rewrite_pending = rewrite.is_some();
        stack = stack.children(rewrite);
        if let Some(error) = error {
            stack = stack.child(
                div()
                    .flex()
                    .items_center()
                    .gap_2()
                    .text_size(px(12.))
                    .text_color(ink(DANGER))
                    .child(div().flex_1().child(error))
                    .child(
                        control("reload-session", tr("重新读取")).on_click(cx.listener(
                            |this, _, _, cx| {
                                if let Some(key) = this.selected.clone() {
                                    this.prefetch_history(&key, cx);
                                    this.attach(&key, true);
                                }
                                cx.notify();
                            },
                        )),
                    ),
            );
        }
        if uncertain {
            stack =
                stack.child(
                    div()
                        .flex()
                        .items_center()
                        .gap_2()
                        .text_size(px(12.))
                        .text_color(ink(DANGER))
                        .child(div().flex_1().child(tr("上一条消息待确认")))
                        .child(control("discard-uncertain", tr("解除待确认")).on_click(
                            cx.listener(|this, _, _, cx| {
                                let key = this.key();
                                if let Some(pending) =
                                    this.workspace_mut().pending_submissions.remove(&key)
                                    && pending.queued
                                {
                                    this.remove_followup_record(&key, &pending.id);
                                }
                                if let Some(session) = this.sessions.get_mut(&key) {
                                    session.uncertain = false;
                                    session.error = None;
                                }
                                this.persist(cx);
                                this.drain_followups(&key, cx);
                                cx.notify();
                            }),
                        )),
                );
        }
        let mut cards = div()
            .id("pending-cards")
            .max_h(px(190.))
            .overflow_y_scroll()
            .flex()
            .flex_col()
            .gap_2();
        let has_cards = !prompts.is_empty();
        for (key, prompt) in prompts {
            cards = cards.child(self.prompt_card(key, prompt, enabled, window, cx));
        }
        if has_cards {
            stack = stack.child(cards);
        }
        for (id, text) in unknown {
            stack = stack.child(
                div()
                    .flex()
                    .items_center()
                    .gap_2()
                    .text_size(px(12.))
                    .text_color(ink(DANGER))
                    .child(tr("执行结果待确认"))
                    .child(div().flex_1().min_w_0().truncate().child(text))
                    .child(
                        control(SharedString::from(format!("resolve-{id}")), tr("确认中断"))
                            .on_click(cx.listener(move |this, _, _, cx| {
                                if enabled {
                                    this.resolve_unknown(id.clone());
                                    cx.notify();
                                }
                            })),
                    ),
            );
        }
        stack = stack
            .children(tasks)
            .children(work)
            .children(queue)
            .children(self.slash_output(cx));
        let files = self.draft_files();
        self.prepare_draft_thumbnails(&files, cx);
        let pasting = self.clipboard_loading();
        let may_edit_files = !loading && !self.creating();
        let composer_text = self.composer.read(cx).value();
        let has_content = !files.is_empty() || !composer_text.trim().is_empty();
        let changing = self.model_controls.busy.contains(&self.key());
        let can_queue = has_content && !changing && !rewrite_pending && !pasting;
        let can_submit = enabled && (running || can_queue)
            && (!has_content || !self.busy_input_saving());
        let stop_only = running && !can_queue;
        let queueing = running && (!files.is_empty() || awaiting_input)
            || self
                .selected
                .as_deref()
                .is_some_and(|key| self.has_followups(key));
        let upload_in_progress = loading
            && self.workspace().is_some_and(|workspace| {
                workspace
                    .pending_submissions
                    .get(&self.key())
                    .is_some_and(|prepared| prepared.staging)
            });
        let upload = self.selected.as_ref()
            .and_then(|key| self.sessions.get(key)?.upload.as_ref())
            .filter(|upload| upload.started.elapsed() >= std::time::Duration::from_millis(180));
        let attachments = div()
            .id("draft-attachments")
            .flex()
            .flex_wrap()
            .gap_2()
            .items_center()
            .max_h(px(88.))
            .overflow_y_scroll()
            .px_2()
            .pt_2()
            .children(upload.filter(|upload| !files.contains(&upload.path)).map(|upload| upload_card(upload, cx)))
            .children(files.iter().enumerate().map(|(index, path)| {
                if let Some(upload) = upload.filter(|upload| &upload.path == path) {
                    return upload_card(upload, cx).into_any_element();
                }
                let name = file_name(path);
                let draft_session = self.selected.as_ref().and_then(|key| self.sessions.get(key));
                let upload_error = draft_session.and_then(|session| session.draft_upload_errors.get(path));
                let staged = draft_session.is_some_and(|session| session.staged_draft_files.contains_key(path));
                let tooltip = SharedString::from(upload_error.cloned().unwrap_or_else(|| name.clone()));
                let picture = is_image_file(path);
                let thumbnail = self.media.draft_thumbnail(path);
                let path = path.clone();
                let chip = if picture {
                    let image_path = path.clone();
                    div().relative().flex_none().child(
                        Button::new("preview-draft-image")
                            .ghost()
                            .compact()
                            .h(px(38.))
                            .pl(px(4.))
                            .pr(px(if may_edit_files { 21. } else { 8. }))
                            .rounded(px(7.))
                            .border_1()
                            .border_color(rgb(0xdce4ef))
                            .bg(rgba(0xffffffbb))
                            .hover(|button| button.bg(rgb(0xecf3ff)).border_color(rgb(0xc8daf6)))
                            .cursor_pointer()
                            .when(!self.media.is_open(), |button| {
                                button.tooltip(crate::i18n::format_text!(
                                    "预览图片 · {name}",
                                    "Preview image · {name}"
                                ))
                            })
                            .child(
                                div()
                                    .flex()
                                    .items_center()
                                    .gap(px(6.))
                                    .child(
                                        div()
                                            .w(px(37.))
                                            .h(px(28.))
                                            .flex_none()
                                            .rounded(px(4.))
                                            .bg(rgb(0xf0f3f8))
                                            .overflow_hidden()
                                            .flex()
                                            .items_center()
                                            .justify_center()
                                            .child(if let Some(thumbnail) = thumbnail {
                                                gpui::img(thumbnail)
                                                    .size_full()
                                                    .object_fit(ObjectFit::Contain)
                                                    .into_any_element()
                                            } else {
                                                symbol(icons::PHOTO, 15.).into_any_element()
                                            }),
                                    )
                                    .child(
                                        div()
                                            .max_w(px(139.))
                                            .truncate()
                                            .text_size(px(11.))
                                            .text_color(ink(SECONDARY))
                                            .child(name),
                                    ),
                            )
                            .on_click(cx.listener(move |this, _, window, cx| {
                                this.open_draft_image(image_path.clone(), window, cx);
                            })),
                    )
                } else {
                    file_chip(name.into())
                        .when(staged, |chip| chip.child(svg_symbol(icons::TASK_CHECK, 10., MUTED)))
                        .children(upload_error.map(|_| div().flex_none().text_color(ink(DANGER)).child(tr("上传失败，发送时重试"))))
                };
                chip.id(("draft-file", index))
                    .when(!picture, |chip| {
                        chip.tooltip(move |window, cx| {
                            Tooltip::new(tooltip.clone()).build(window, cx)
                        })
                    })
                    .when(may_edit_files, |chip| {
                        chip.child(
                            div()
                                .id("remove-file")
                                .size(px(18.))
                                .flex()
                                .items_center()
                                .justify_center()
                                .rounded(px(3.))
                                .cursor_pointer()
                                .when(picture, |button| {
                                    button
                                        .absolute()
                                        .top(px(3.))
                                        .right(px(3.))
                                        .rounded_full()
                                        .bg(rgba(0xffffffea))
                                })
                                .hover(|style| style.bg(rgb(0xdee7f5)))
                                .child(svg_symbol(icons::TAB_CLOSE, 8., MUTED))
                                .on_click(cx.listener(move |this, _, _, cx| {
                                    cx.stop_propagation();
                                    this.remove_file(&path, cx);
                                })),
                        )
                    })
                    .into_any_element()
            }));
        let label = if stop_only {
            tr("停止")
        } else if pasting {
            tr("正在粘贴图片")
        } else if upload_in_progress {
            tr("上传附件中")
        } else if self.creating() || loading {
            tr("请稍候")
        } else if queueing {
            tr("加入队列")
        } else {
            tr("发送")
        };
        let button = div()
            .id("send-stop")
            .size(px(26.))
            .flex_none()
            .rounded_full()
            .bg(rgb(if can_submit { 0x272d36 } else { 0xdde2e9 }))
            .text_color(ink(SURFACE))
            .flex()
            .items_center()
            .justify_center()
            .when(can_submit, |button| {
                button.cursor_pointer().hover(|style| style.bg(rgb(ACCENT)))
            })
            .tooltip(move |window, cx| {
                Tooltip::new(if label == tr("发送") {
                    tr("发送（Enter）")
                } else {
                    label
                })
                .build(window, cx)
            })
            .child(svg_symbol(
                if stop_only {
                    icons::STOP
                } else {
                    icons::ARROW_UP
                },
                15.,
                SURFACE,
            ))
            .on_click(cx.listener(move |this, _, window, cx| {
                if can_submit {
                    if stop_only {
                        this.stop();
                    } else {
                        this.send(window, cx);
                    }
                    cx.notify();
                }
            }));
        let pane_width = f32::from(window.viewport_size().width)
            - if self.sidebar_open {
                self.sidebar_width(window) + DIVIDER
            } else {
                0.
            };
        let stacked = self.composer_expanded || pane_width < 585.;
        let reference = self.reference_is_open(window, cx);
        let slash = !reference && self.slash_is_open(window, cx);
        let leading = self.composer_tools(may_edit_files, cx);
        let input = div()
            .id("composer-input")
            .key_context(if slash || reference {
                "HermesComposer HermesCompletionOpen"
            } else {
                "HermesComposer"
            })
            .flex_1()
            .min_w_0()
            .capture_action(cx.listener(move |this, _: &Paste, window, cx| {
                this.paste_composer(may_edit_files, window, cx);
            }))
            .on_action(cx.listener(|this, _: &SendMessage, window, cx| {
                cx.stop_propagation();
                this.send(window, cx);
            }))
            .on_action(cx.listener(move |this, _: &PreviousCompletion, _, cx| {
                if reference {
                    this.move_reference(true, cx);
                } else {
                    this.move_slash(true, cx);
                }
            }))
            .on_action(cx.listener(move |this, _: &NextCompletion, _, cx| {
                if reference {
                    this.move_reference(false, cx);
                } else {
                    this.move_slash(false, cx);
                }
            }))
            .on_action(cx.listener(move |this, _: &AcceptCompletion, window, cx| {
                if reference {
                    this.choose_reference(None, window, cx);
                } else {
                    this.choose_slash(None, window, cx);
                }
            }))
            .on_action(cx.listener(move |this, _: &CloseCompletion, _, cx| {
                if reference {
                    this.dismiss_reference(cx);
                } else {
                    this.dismiss_slash(cx);
                }
            }))
            .child(
                Textarea::new(&self.composer)
                    .small()
                    .appearance(false)
                    .bordered(false)
                    .px_0()
                    .py_0()
                    .text_size(px(13.))
                    .line_height(px(COMPOSER_LINE_HEIGHT)),
            );
        let input = div().flex_1().min_w_0().child(input);
        let input = if !self.composer_expanded && !composer_text.is_empty() {
            let view = cx.entity().downgrade();
            let key = self.key();
            input.on_children_prepainted(move |bounds, window, _| {
                if bounds
                    .first()
                    .is_some_and(|bounds| bounds.size.height > px(COMPOSER_LINE_HEIGHT * 1.5))
                {
                    let view = view.clone();
                    let key = key.clone();
                    window.on_next_frame(move |_, cx| {
                        let _ = view.update(cx, |this, cx| {
                            if this.key() == key
                                && !this.composer_expanded
                                && this.composer.read(cx).text().len() > 0
                            {
                                this.composer_expanded = true;
                                cx.notify();
                            }
                        });
                    });
                }
            })
        } else {
            input
        };
        let voice_active = self.voice.is_conversation();
        let actions = if voice_active { self.voice_conversation_pill(cx) } else { div()
            .flex_none()
            .flex()
            .items_center()
            .gap(px(4.))
            .child(self.model_pills(enabled, cx))
            .child(self.voice_fan(enabled, cx))
            .children((running && can_queue).then(|| {
                icon_button("stop-current-turn", icons::STOP, tr("停止当前回复"))
                    .size(px(26.))
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.stop();
                        cx.notify();
                    }))
            }))
            .child(if !running && !has_content {
                self.voice_primary(enabled, cx).into_any_element()
            } else {
                button.into_any_element()
            }) };
        let row = if stacked {
            div()
                .flex()
                .flex_col()
                .gap(px(2.))
                .child(
                    div()
                        .min_w_0()
                        .pl(px(12.))
                        .pr(px(6.))
                        .pt(px(2.))
                        .child(input),
                )
                .child(
                    div()
                        .min_h(px(29.))
                        .flex()
                        .items_center()
                        .justify_between()
                        .child(leading)
                        .child(actions),
                )
        } else {
            div()
                .flex()
                .items_center()
                .gap(px(5.))
                .child(leading)
                .child(input)
                .child(actions)
        };
        let composer = panel()
            .id("composer-panel")
            .w_full()
            .rounded(px(6.))
            .when(voice_active, |panel| panel.capture_key_down(cx.listener(|this, event: &gpui::KeyDownEvent, _, cx| {
                let key = &event.keystroke;
                if !event.is_held && key.key == "space" && !key.modifiers.control && !key.modifiers.platform && !key.modifiers.alt
                    && this.finish_voice_input(cx)
                {
                    cx.stop_propagation();
                }
            })))
            .children(self.voice_status(cx).map(|activity| div().px_2().pt_1().child(activity)))
            .bg(crate::theme::composer(0xf9f9fb).alpha(0.93))
            .border_color(rgb(if focused { ACCENT } else { LINE }))
            .when(may_edit_files, |panel| {
                panel
                    .drag_over::<ExternalPaths>(|style, _, _, _| style.border_color(rgb(ACCENT)))
                    .on_drop(cx.listener(|this, paths: &ExternalPaths, _, cx| {
                        this.drop_files(paths.paths(), cx);
                    }))
            })
            .overflow_hidden()
            .children(
                workspace
                    .filter(|_| !collapsed)
                    .map(|(branch, cwd)| self.composer_workspace_row(branch, cwd, cx)),
            )
            .when(!files.is_empty() || upload.is_some(), |panel| panel.child(attachments))
            .child(row.min_h(px(35.)).px_2().py(px(4.)));
        stack = stack.child(
            div()
                .relative()
                .child(composer)
                .children(status_grip)
                .children(reference.then(|| self.reference_element(pane_width, cx)))
                .children(slash.then(|| self.slash_element(pane_width, cx))),
        );
        div()
            .w_full()
            .flex_none()
            .flex()
            .justify_center()
            .px_3()
            .pb_3()
            .pt_2()
            .child(stack)
    }

    fn prompt_card(
        &mut self,
        key: String,
        prompt: Prompt,
        enabled: bool,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Div {
        let mut card = panel().p_2().flex().flex_col().gap_2().child(
            div()
                .text_size(px(12.))
                .font_weight(gpui::FontWeight::SEMIBOLD)
                .child(prompt.label.clone()),
        );
        if prompt.clarify {
            return card
                .child(div().text_size(px(12.)).text_color(ink(MUTED)).child(
                    crate::i18n::format_text!(
                        "{} 个待回答问题",
                        "{} unanswered question(s)",
                        prompt.questions.len()
                    ),
                ))
                .child(
                    div().flex().justify_end().child(
                        primary("open-clarify", tr("回答问题"), enabled).on_click(
                            cx.listener(move |this, _, _, cx| this.show_questions(&key, cx)),
                        ),
                    ),
                );
        }
        if !prompt.detail.is_empty() {
            card = card.child(div().text_size(px(13.)).child(prompt.detail));
        }
        let mut actions = div().flex().flex_wrap().gap_1();
        for (index, option) in prompt.choices.into_iter().enumerate() {
            let label: SharedString = match option.as_str() {
                "once" => tr("允许一次").into(),
                "session" => tr("本会话允许").into(),
                "always" => tr("始终允许").into(),
                "deny" => tr("拒绝").into(),
                _ => option.clone().into(),
            };
            let key = key.clone();
            actions = actions.child(control(index, label).bg(rgb(RAIL)).on_click(cx.listener(
                move |this, _, _, cx| {
                    if enabled {
                        this.answer(key.clone(), option.clone(), cx);
                    }
                },
            )));
        }
        card.child(actions)
    }
}

fn new_chat_intro(width: gpui::Pixels, window: &Window) -> Div {
    const WORDMARK: &str = "HERMES LITE";
    let font = gpui::font(crate::style::INTRO_FONT);
    let color = rgb(0x0053fd);
    let reference_size = px(72.);
    let natural_width = window
        .text_system()
        .shape_line(
            WORDMARK.into(),
            reference_size,
            &[gpui::TextRun {
                len: WORDMARK.len(),
                font: font.clone(),
                color: color.into(),
                ..Default::default()
            }],
            None,
        )
        .width;
    let target_width = (width * 0.78).min(px(840.));
    let title_size = (reference_size
        * (f32::from(target_width) / f32::from(natural_width.max(px(1.)))))
    .clamp(px(24.), px(122.));
    div()
        .flex()
        .flex_col()
        .items_center()
        .gap(px(9.))
        .px_3()
        .text_center()
        .child(
            div()
                .font(font)
                .text_size(title_size)
                .line_height(title_size)
                .whitespace_nowrap()
                .text_color(color)
                .child(WORDMARK),
        )
        .child(
            div()
                .text_size(px(13.))
                .line_height(px(19.))
                .text_color(ink(MUTED))
                .child(tr("描述你的任务，或添加文件和图片。")),
        )
}

fn linux_resize_edges() -> impl Iterator<Item = gpui::Stateful<Div>> {
    use gpui::{CursorStyle, MouseButton, ResizeEdge};
    let edge = px(4.);
    let corner = px(8.);
    [
        (
            ResizeEdge::Top,
            CursorStyle::ResizeUpDown,
            div().top_0().left(corner).right(corner).h(edge),
        ),
        (
            ResizeEdge::Bottom,
            CursorStyle::ResizeUpDown,
            div().bottom_0().left(corner).right(corner).h(edge),
        ),
        (
            ResizeEdge::Left,
            CursorStyle::ResizeLeftRight,
            div().left_0().top(corner).bottom(corner).w(edge),
        ),
        (
            ResizeEdge::Right,
            CursorStyle::ResizeLeftRight,
            div().right_0().top(corner).bottom(corner).w(edge),
        ),
        (
            ResizeEdge::TopLeft,
            CursorStyle::ResizeUpLeftDownRight,
            div().top_0().left_0().size(corner),
        ),
        (
            ResizeEdge::TopRight,
            CursorStyle::ResizeUpRightDownLeft,
            div().top_0().right_0().size(corner),
        ),
        (
            ResizeEdge::BottomLeft,
            CursorStyle::ResizeUpRightDownLeft,
            div().bottom_0().left_0().size(corner),
        ),
        (
            ResizeEdge::BottomRight,
            CursorStyle::ResizeUpLeftDownRight,
            div().bottom_0().right_0().size(corner),
        ),
    ]
    .into_iter()
    .enumerate()
    .map(|(index, (edge, cursor, element))| {
        element
            .id(("window-resize", index))
            .absolute()
            .cursor(cursor)
            .on_mouse_down(MouseButton::Left, move |_, window, cx| {
                cx.stop_propagation();
                window.start_window_resize(edge);
            })
    })
}

fn file_chip(name: SharedString) -> Div {
    div()
        .h(px(23.))
        .max_w(px(230.))
        .flex()
        .items_center()
        .gap_1()
        .px_2()
        .rounded(px(4.))
        .border_1()
        .border_color(rgb(0xd8e3f4))
        .bg(rgb(0xf2f6fc))
        .text_size(px(11.))
        .text_color(ink(0x4e647e))
        .child(svg_symbol(icons::LINK, 10., MUTED))
        .child(div().min_w_0().truncate().child(name))
}

fn message_body(
    id: SharedString,
    row_index: usize,
    message: Message,
    user: bool,
    highlight: Option<u32>,
    timestamp: Option<i64>,
    branch: Option<gpui::Stateful<Div>>,
    rewrite: Option<gpui::Stateful<Div>>,
    inline_editor: Option<AnyElement>,
    images: &TranscriptImages<'_>,
    font_size: gpui::Pixels,
    desktop: &gpui::Entity<Desktop>,
    window: &mut Window,
    cx: &mut gpui::App,
) -> AnyElement {
    let (files, visible) = if user {
        leading_file_refs(message.display())
    } else {
        (Vec::new(), message.display().as_ref())
    };
    let editing = inline_editor.is_some();
    let has_body = editing || !visible.is_empty();
    let attachments = (!files.is_empty()).then(|| {
        div().flex().flex_col().gap_1().pt_1().children(
            files.into_iter().enumerate().map(|(index, (path, name))| {
                remote_file_card(index, name, path, None, desktop, cx)
            }),
        )
    });
    let body = div()
        .relative()
        .w_full()
        .px(px(MESSAGE_INSET))
        .py_2()
        .text_color(ink_alpha((CONVERSATION_INK << 8) | 0xf0))
        .when(user, |body| {
            body.rounded(px(4.))
                .bg(rgba((USER_MESSAGE_BACKGROUND << 8) | 0xe6))
                .border_1()
                .border_color(rgb(if editing { ACCENT } else { USER_MESSAGE_BORDER }))
                .text_color(ink_alpha((CONVERSATION_INK << 8) | 0xe3))
                .line_height((font_size * 1.3).max(px(19.)))
        })
        .when_some(highlight.filter(|_| !editing), |body, color| {
            body.bg(rgb(color))
                .rounded(px(4.))
                .border_l_2()
                .border_color(rgb(0xe3b75b))
        })
        .when(editing, |body| body.pr(px(6.)).py(px(5.)))
        .children(inline_editor)
        .when(!editing && !visible.is_empty(), |body| {
            body.child(if user {
                markdown(
                    id.clone(),
                    visible.to_owned().into(),
                    true,
                    font_size,
                    window,
                )
            } else {
                reply_body(id.clone(), visible, font_size, images, desktop, window, cx)
            })
        });
    let media = images.strip(message.images(), user, desktop, cx);
    // Assistant source keeps the media directives and Markdown that the transcript projects away.
    let copy = if user { message.display() } else { message.raw() }.clone();
    let copied = window.use_keyed_state(format!("{id}-copied"), cx, |_, _| None::<std::time::Instant>);
    let confirmation = copied.read(cx).is_some_and(|at| at.elapsed() < std::time::Duration::from_millis(1300));
    let owner = desktop.downgrade();
    let action = (!copy.is_empty()).then(|| message_icon_button(
        "copy-message",
        if confirmation { icons::TASK_CHECK } else { icons::COPY },
        if confirmation { tr("已复制消息") } else { tr("复制消息") },
    ).on_click(
        move |_, _, cx| {
            cx.stop_propagation();
            cx.write_to_clipboard(ClipboardItem::new_string(copy.to_string()));
            #[cfg(windows)]
            if cx.read_from_clipboard().and_then(|item| item.text()).as_deref() != Some(copy.as_ref()) {
                copied.update(cx, |at, _| *at = None);
                let _ = owner.update(cx, |this, cx| {
                    this.banner = Some(tr("无法写入剪贴板，请再复制一次").into());
                    cx.notify();
                });
                return;
            }
            copied.update(cx, |at, _| *at = Some(std::time::Instant::now()));
            let _ = owner.update(cx, |_, cx| {
                cx.notify();
                cx.spawn(async move |owner, cx| {
                    cx.background_executor().timer(std::time::Duration::from_millis(1300)).await;
                    let _ = owner.update(cx, |_, cx| cx.notify());
                }).detach();
            });
        },
    ));
    let time = timestamp
        .and_then(|seconds| DateTime::<Utc>::from_timestamp(seconds, 0))
        .map(|at| at.with_timezone(&Local));
    let (edit, retry) = if user {
        (rewrite, None)
    } else {
        (None, rewrite)
    };
    let chat = desktop.read(cx);
    let actions_inset = if chat.settings.display.turn_rail && !chat.turns.is_empty() {
        super::turn_rail::RAIL_GUTTER - TRANSCRIPT_INSET + 4.
    } else {
        4.
    };
    let footer = div()
        .h(px(23.))
        .flex()
        .justify_end()
        .items_center()
        .gap_2()
        .pl_1()
        .pr(px(if user { 4. } else { actions_inset }))
        .invisible()
        .group_hover("message", |style| style.visible())
        .children(time.map(|at| {
            let full = SharedString::from(at.format(tr("%Y年%-m月%-d日 %H:%M:%S")).to_string());
            div()
                .id("message-time")
                .text_size(px(11.))
                .text_color(ink(0x79818b))
                .tooltip(move |window, cx| Tooltip::new(full.clone()).build(window, cx))
                .child(at.format("%H:%M").to_string())
        }))
        .children(
            (!user)
                .then(|| desktop.read(cx).bookmark_for(row_index, visible))
                .flatten()
                .map(|mark| {
                    use gpui_component::menu::DropdownMenu;
                    let weak = desktop.downgrade();
                    let marked = desktop.read(cx).workspace().is_some_and(|ws| {
                        ws.bookmarks
                            .iter()
                            .any(|b| super::message_bookmarks::same_message(b, &mark))
                    });
                    Button::new("reply-more")
                        .ghost()
                        .small()
                        .child(svg_symbol(
                            if marked {
                                icons::MODEL_STAR_FILLED
                            } else {
                                icons::ELLIPSIS
                            },
                            13.,
                            MUTED,
                        ))
                        .tooltip(tr("更多操作"))
                        .dropdown_menu_with_anchor(gpui::Anchor::BottomRight, move |menu, _, _| {
                            let mark = mark.clone();
                            menu.item(tab_view::menu_item(
                                &weak,
                                if marked {
                                    tr("取消收藏")
                                } else {
                                    tr("收藏消息")
                                },
                                icons::MODEL_STAR,
                                true,
                                move |this, _, cx| this.toggle_bookmark(mark.clone(), cx),
                            ))
                        })
                }),
        )
        .children(branch)
        .children(edit)
        .children(action)
        .children(retry);
    if user {
        div()
            .id(id)
            .relative()
            .group("message")
            .when(has_body, |message| message.child(body))
            .children(attachments)
            .children(media)
            .children((!editing).then(|| {
                footer
                    .absolute()
                    .right(px(actions_inset))
                    .top(px(4.))
                    .rounded(px(4.))
                    .bg(rgb(highlight.unwrap_or(USER_MESSAGE_BACKGROUND)))
            }))
            .into_any_element()
    } else {
        div()
            .id(id)
            .group("message")
            .when(has_body, |message| message.child(body))
            .children(media)
            .child(footer)
            .into_any_element()
    }
}

fn background_result_row(
    id: SharedString,
    index: usize,
    notice: crate::background_notice::BackgroundNotice,
    expanded: bool,
    highlight: Option<u32>,
    size: gpui::Pixels,
    images: &TranscriptImages<'_>,
    desktop: &gpui::Entity<Desktop>,
    window: &mut Window,
    app: &mut gpui::App,
) -> Div {
    let open = expanded || highlight == Some(0xfff2ce);
    let revision = desktop.read(app).view_revision;
    let weak = desktop.downgrade();
    let glyph = if notice.process {
        icons::TERMINAL
    } else {
        icons::FORK
    };
    let title = div()
        .id(("background-result-toggle", index))
        .h(px(23.))
        .flex()
        .items_center()
        .gap(px(6.))
        .px(px(MESSAGE_INSET))
        .text_size(px(12.))
        .text_color(ink(crate::style::SCAFFOLD_INK))
        .rounded(px(4.))
        .cursor_pointer()
        .hover(|row| row.text_color(ink(MUTED)))
        .child(svg_symbol(glyph, 13., crate::style::SCAFFOLD_INK).flex_none())
        .child(div().min_w_0().truncate().child(notice.label))
        .child(
            svg_symbol(
                if open {
                    icons::CHEVRON_DOWN
                } else {
                    icons::CHEVRON_RIGHT
                },
                10.,
                MUTED,
            )
            .flex_none(),
        )
        .on_click(move |_, _, app| {
            let _ = weak.update(app, |desktop, cx| {
                if desktop.view_revision == revision {
                    desktop.hold_transcript_row_position(index);
                    if !desktop.expanded.remove(&index) {
                        desktop.expanded.insert(index);
                    }
                    cx.notify();
                }
            });
        });
    div()
        .w_full()
        .min_w_0()
        .when_some(highlight, |row, color| row.bg(rgb(color)).rounded(px(4.)))
        .child(title)
        .when(open, |row| {
            let scroll = window
                .use_keyed_state(format!("{id}-background-scroll"), app, |_, _| {
                    gpui::ScrollHandle::new()
                })
                .read(app)
                .clone();
            let output = if notice.report.is_empty() {
                markdown(id.clone(), notice.raw.clone(), true, size, window)
            } else {
                reply_body(
                    id.clone(),
                    &notice.report,
                    size,
                    images,
                    desktop,
                    window,
                    app,
                )
            };
            let raw = notice.raw;
            row.child(
                div()
                    .ml(px(MESSAGE_INSET))
                    .my_1()
                    .min_w_0()
                    .relative()
                    .rounded(px(5.))
                    .border_1()
                    .border_color(rgb(0xe2e7ee))
                    .bg(rgba(0xf6f8fac8))
                    .child(
                        div()
                            .id(("background-report-scroll", index))
                            .max_h(px(335.))
                            .px_3()
                            .py_2()
                            .pr(px(38.))
                            .overflow_y_scroll()
                            .track_scroll(&scroll)
                            .on_scroll(|_, _, cx| cx.stop_propagation())
                            .child(output),
                    )
                    .child(Scrollbar::vertical(&scroll))
                    .child(
                        icon_button("copy-background-notice", icons::COPY, tr("复制通知原文"))
                            .absolute()
                            .top(px(6.))
                            .right(px(12.))
                            .on_click(move |_, _, app| {
                                app.write_to_clipboard(ClipboardItem::new_string(raw.to_string()))
                            }),
                    ),
            )
        })
}

fn remote_file_card(
    index: usize,
    label: &str,
    path: &str,
    fragment: Option<&str>,
    desktop: &gpui::Entity<Desktop>,
    app: &gpui::App,
) -> gpui::Stateful<Div> {
    let state = desktop.read(app);
    let Some(session) = state.selected.clone().filter(|_| gateway_path(path, true)) else {
        return file_chip(label.to_owned().into()).id(("message-file", index));
    };
    let (saving, status) = state.conversation_download_status(&session, path);
    use super::workspace_files::DownloadStatus;
    let download_label = match status {
        Some(DownloadStatus::Saved(_)) => tr("已保存"),
        Some(DownloadStatus::Failed(_)) => tr("重试下载"),
        _ if saving => tr("下载中"),
        _ => tr("下载"),
    };
    let download_tip = status.map(DownloadStatus::label);
    let path = path.to_owned();
    let fragment = fragment.map(str::to_owned);
    let tip: SharedString = match &fragment {
        Some(fragment) => format!("{path}#{fragment}"),
        None => path.clone(),
    }
    .into();
    let download_owner = desktop.downgrade();
    let preview_owner = download_owner.clone();
    let download_session = session.clone();
    let download_path = path.clone();
    let file_icon = if path
        .rsplit_once('.')
        .is_some_and(|(_, ext)| ext.eq_ignore_ascii_case("xlsx"))
    {
        icons::LIST_DETAILS
    } else {
        icons::FILE_TEXT
    };
    div()
        .id(("message-file", index))
        .w_full()
        .max_w(px(615.))
        .min_w_0()
        .rounded(px(5.))
        .border_1()
        .border_color(rgb(0xdce4ef))
        .bg(rgba(0xf7f9fbd9))
        .child(
            div()
                .min_w_0()
                .w_full()
                .flex()
                .items_center()
                .gap(px(8.))
                .px(px(8.))
                .py(px(5.))
                .child(
                    div()
                        .size(px(24.))
                        .flex_none()
                        .rounded(px(4.))
                        .bg(rgb(0xf0f3f7))
                        .flex()
                        .items_center()
                        .justify_center()
                        .child(svg_symbol(file_icon, 14., MUTED)),
                )
                .child(
                    div()
                        .id("attachment-name")
                        .flex_1()
                        .min_w_0()
                        .truncate()
                        .text_size(px(12.))
                        .text_color(ink(INK))
                        .tooltip(move |window, cx| Tooltip::new(tip.clone()).build(window, cx))
                        .child(label.to_owned()),
                )
                .child(
                    attachment_action("download-attachment", download_label)
                        .w(px(75.))
                        .justify_center()
                        .child(svg_symbol(icons::DOWNLOAD, 13., MUTED))
                        .child(download_label)
                        .when_some(download_tip, |button, tip| {
                            button.tooltip(move |window, cx| {
                                Tooltip::new(tip.clone()).build(window, cx)
                            })
                        })
                        .when(saving, |button| button.opacity(0.55))
                        .when(!saving, |button| {
                            button.on_click(move |_, _, cx| {
                                cx.stop_propagation();
                                let _ = download_owner.update(cx, |this, cx| {
                                    this.download_conversation_file(
                                        &download_session,
                                        &download_path,
                                        cx,
                                    );
                                });
                            })
                        }),
                )
                .child(
                    attachment_action("preview-attachment", tr("打开预览"))
                        .child(tr("打开预览"))
                        .on_click(move |_, window, cx| {
                            cx.stop_propagation();
                            let _ = preview_owner.update(cx, |this, cx| {
                                this.open_conversation_file(
                                    &session,
                                    path.clone(),
                                    fragment.clone(),
                                    window,
                                    cx,
                                );
                            });
                        }),
                ),
        )
}

fn attachment_action(id: &'static str, label: &'static str) -> gpui::Stateful<Div> {
    div()
        .id(id)
        .aria_label(label)
        .h(px(24.))
        .px_2()
        .flex_none()
        .flex()
        .items_center()
        .gap_1()
        .rounded(px(4.))
        .border_1()
        .border_color(rgb(0xdce4ef))
        .bg(rgba(0xffffff82))
        .text_size(px(11.))
        .text_color(ink(MUTED))
        .cursor_pointer()
        .hover(|button| button.bg(rgb(0xe9eff8)).text_color(ink(INK)))
}

fn reply_body(
    id: SharedString,
    text: &str,
    font_size: gpui::Pixels,
    images: &TranscriptImages<'_>,
    desktop: &gpui::Entity<Desktop>,
    window: &mut Window,
    app: &mut gpui::App,
) -> AnyElement {
    let mut parts = reply_files(text, false);
    if parts.is_empty() {
        parts.push(ReplyPart::Text(text));
    }
    let app_state = desktop.read(app);
    let cwd = app_state
        .selected
        .as_ref()
        .and_then(|id| {
            app_state
                .sessions
                .get(id)
                .map(|session| session.cwd.clone())
        })
        .unwrap_or_default();
    let reply_file =
        |index, path: &str, label: &str, fragment: Option<&str>, app: &mut gpui::App| {
            if (!cwd.is_empty() || gateway_path(path, false))
                && let Some(image) =
                    crate::media::ChatImage::from_reference(&scoped_path(&cwd, path))
                && let Some(preview) = images.strip(&[image], false, desktop, app)
            {
                return div()
                    .id(("reply-image", index))
                    .child(preview)
                    .into_any_element();
            }
            remote_file_card(index, label, path, fragment, desktop, app).into_any_element()
        };
    let mut body = div().w_full().flex().flex_col().gap(px(PARAGRAPH_GAP));
    let mut file_index = 0;
    for (index, part) in parts.into_iter().enumerate() {
        match part {
            ReplyPart::Text(text) if !text.trim().is_empty() => {
                let prose_id = SharedString::from(format!("{id}-prose-{index}"));
                let prepared =
                    window.use_keyed_state(format!("reply-text-{prose_id}"), app, |_, _| {
                        ReplyText::new(text)
                    });
                if prepared.read(app).source.as_ref() != text {
                    prepared.update(app, |prepared, _| *prepared = ReplyText::new(text));
                }
                let prepared = prepared.read(app);
                let caption = prepared.caption.clone();
                let links = prepared.links.clone();
                if !caption.trim().is_empty() {
                    body = body.child(markdown(prose_id, caption, false, font_size, window));
                }
                for link in links.iter() {
                    body = body.child(reply_file(
                        file_index,
                        &link.path,
                        &link.label,
                        link.fragment.as_deref(),
                        app,
                    ));
                    file_index += 1;
                }
            }
            ReplyPart::File { path, label } => {
                body = body.child(reply_file(file_index, path, label, None, app));
                file_index += 1;
            }
            _ => {}
        }
    }
    body.into_any_element()
}

struct ReplyText {
    source: SharedString,
    caption: SharedString,
    links: Arc<[ReplyLink]>,
}

impl ReplyText {
    fn new(source: &str) -> Self {
        let rendered = chat_markdown::render_prose_fences(source);
        let (caption, links) = reply_links(&rendered);
        Self {
            source: source.to_owned().into(),
            caption: preserve_chat_breaks(caption).into_owned().into(),
            links: links.into(),
        }
    }
}

fn transcript_image_width(desktop: &Desktop, window: &Window) -> f32 {
    let sidebar = if desktop.sidebar_open {
        desktop.sidebar_width(window)
    } else {
        0.
    };
    (f32::from(window.viewport_size().width) - sidebar - 2. * (TRANSCRIPT_INSET + MESSAGE_INSET))
        .max(180.)
}

pub(in crate::app) fn markdown(
    id: SharedString,
    text: SharedString,
    user: bool,
    font_size: gpui::Pixels,
    window: &Window,
) -> AnyElement {
    let style = TextViewStyle {
        heading_base_font_size: font_size,
        paragraph_gap: gpui::rems(PARAGRAPH_GAP / f32::from(window.rem_size())),
        ..Default::default()
    };
    if user {
        // Keep the original prompt as literal selectable text.
        return TextView::markdown(id, escape_markdown(&text))
            .style(style)
            .selectable(true)
            .into_any_element();
    }
    TextView::markdown(id, text)
        .style(style.code_block(chat_markdown::code_fence_style(px(120.))))
        .markdown_extensions(chat_markdown::code_fences())
        .inline_code_style(
            gpui::StyleRefinement::default()
                .font_family(crate::theme::code_family())
                .text_size(font_size * 0.9)
                .px(px(3.))
                .py(px(1.))
                .rounded(px(4.))
                .bg(rgba(0x1414140d))
                .text_color(ink_alpha(0x141414e0)),
        )
        .selectable(true)
        .code_block_actions(|code, _, _| chat_markdown::copy_fence(code.code()))
        .into_any_element()
}

fn escape_markdown(value: &str) -> SharedString {
    let mut escaped = String::with_capacity(value.len());
    for ch in value.replace("\r\n", "\n").chars() {
        match ch {
            '\n' => {
                escaped.push_str("<br>");
                continue;
            }
            '&' => {
                escaped.push_str("&amp;");
                continue;
            }
            ':' | '.' | '@' => {
                // Character references keep literal URLs and email addresses out of GFM autolinks.
                escaped.push_str(match ch {
                    ':' => "&#58;",
                    '.' => "&#46;",
                    _ => "&#64;",
                });
                continue;
            }
            _ => {}
        }
        if matches!(
            ch,
            '\\' | '`'
                | '*'
                | '_'
                | '{'
                | '}'
                | '['
                | ']'
                | '('
                | ')'
                | '#'
                | '+'
                | '-'
                | '!'
                | '>'
                | '<'
                | '|'
                | '~'
        ) {
            escaped.push('\\');
        }
        escaped.push(ch);
    }
    escaped.into()
}

fn command_receipt_row(receipt: &crate::command_receipt::CommandReceipt, index: usize) -> Div {
    let command = format!("/{}", receipt.command);
    let output = SharedString::from(receipt.output.clone());
    let multiline = output.contains('\n') || output.chars().take(150).count() == 150;
    let name = div()
        .flex_none()
        .font_family(crate::theme::code_family())
        .child(command);
    let content = if multiline {
        div()
            .w(gpui::relative(0.72))
            .max_w(px(600.))
            .min_w_0()
            .flex()
            .flex_col()
            .gap_1()
            .child(name)
            .child(
                div()
                    .id(("command-receipt-output", index))
                    .max_h(px(148.))
                    .overflow_y_scroll()
                    .font_family(crate::theme::code_family())
                    .text_color(ink(0x818991))
                    .child(output),
            )
    } else {
        div()
            .max_w_full()
            .min_w_0()
            .flex()
            .items_start()
            .gap(px(6.))
            .child(name)
            .children((!output.is_empty()).then(|| div().min_w_0().child(format!("·  {output}"))))
    };
    div()
        .w_full()
        .flex()
        .justify_center()
        .px_3()
        .py(px(7.))
        .text_size(px(11.5))
        .line_height(px(17.))
        .text_color(ink(0x838b94))
        .child(content)
}

fn reasoning_row(
    index: usize,
    revision: u64,
    text: SharedString,
    expanded: bool,
    desktop: gpui::WeakEntity<Desktop>,
) -> AnyElement {
    div()
        .w_full()
        .px(px(MESSAGE_INSET))
        .child(
            div()
                .id("reasoning-disclosure")
                .h(px(23.))
                .flex()
                .items_center()
                .gap(px(5.))
                .cursor_pointer()
                .text_size(px(12.))
                .text_color(ink(MUTED))
                .hover(|row| row.text_color(ink(SECONDARY)))
                .on_click(move |_, _, cx| {
                    let _ = desktop.update(cx, |this, cx| {
                        if this.view_revision != revision {
                            return;
                        }
                        if !this.expanded.remove(&index) {
                            this.expanded.insert(index);
                        }
                        if this.following {
                            this.sync_list();
                        }
                        cx.notify();
                    });
                })
                .child(tr("思考"))
                .child(svg_symbol(
                    if expanded {
                        icons::CHEVRON_DOWN
                    } else {
                        icons::CHEVRON_RIGHT
                    },
                    12.,
                    MUTED,
                )),
        )
        .when(expanded, |this| {
            this.child(
                div()
                    .id("reasoning-text")
                    .max_h(px(180.))
                    .overflow_y_scroll()
                    .pb(px(2.))
                    .text_size(px(12.))
                    .line_height(px(18.))
                    .text_color(ink(0x858c94))
                    .child(text),
            )
        })
        .into_any_element()
}
