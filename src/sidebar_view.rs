use crate::theme::{ink, rgb};

use crate::i18n::text as tr;

use gpui::{
    Anchor, AnyElement, AppContext, Context, Div, Focusable, IntoElement, Render, SharedString,
    Window, div, prelude::*, px,
};
use gpui_component::{
    Sizable,
    button::{Button, ButtonVariants},
    input::Input,
    menu::{ContextMenuExt, DropdownMenu, PopupMenuItem},
};
use serde_json::json;

use super::{
    ACCENT, Desktop, INK, LINE, MUTED, SECONDARY, SELECTED, UNREAD, icon_button, icons,
    sidebar_tree, svg_symbol, tab_view,
};

const SIDEBAR_BACKGROUND: u32 = 0xfafafa;
const SIDEBAR_GLASS_TINT: u32 = 0xffffff;
pub(super) const SIDEBAR_HOVER: u32 = 0xe9edf4;

#[derive(Clone)]
struct PinnedDrag {
    profile: String,
    key: String,
    title: SharedString,
    index: usize,
}

impl Render for PinnedDrag {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        super::panel()
            .w(px(168.))
            .h(px(28.))
            .px_2()
            .flex()
            .gap_2()
            .items_center()
            .shadow_md()
            .text_size(px(12.))
            .text_color(ink(SECONDARY))
            .child(svg_symbol(icons::PIN, 12., MUTED))
            .child(div().min_w_0().truncate().child(self.title.clone()))
    }
}

impl Desktop {
    pub(super) fn sidebar(&self, window: &Window, cx: &mut Context<Self>) -> Div {
        let search = self.search.read(cx);
        let searching = search.focus_handle(cx).is_focused(window);
        let has_query = search.text().len() > 0;
        div()
            .w(px(self.sidebar_width(window)))
            .flex_none()
            .flex()
            .flex_col()
            .bg(if self.has_workspace_background() {
                let glass = cfg!(windows) && self.settings.display.sidebar_glass;
                let tint = if glass {
                    0.34 - f32::from(self.settings.display.sidebar_transparency()) / 100.
                } else {
                    0.34
                };
                crate::theme::sidebar(SIDEBAR_BACKGROUND).alpha(
                    tint * (1.
                        - f32::from(self.settings.display.background().window_transparency())
                            / 100.),
                )
            } else if cfg!(windows) && self.settings.display.sidebar_glass {
                crate::theme::sidebar(SIDEBAR_GLASS_TINT)
                    .alpha(1. - f32::from(self.settings.display.sidebar_transparency()) / 100.)
            } else {
                crate::theme::sidebar(SIDEBAR_BACKGROUND)
            })
            .child(
                div()
                    .h(px(32.))
                    .px_4()
                    .flex()
                    .items_center()
                    .border_b_1()
                    .border_color(rgb(LINE))
                    .child(
                        div()
                            .h_full()
                            .flex()
                            .items_center()
                            .border_b_2()
                            .border_color(rgb(ACCENT))
                            .text_size(px(13.))
                            .font_weight(gpui::FontWeight::MEDIUM)
                            .child(if self.archived_only {
                                tr("已归档")
                            } else {
                                tr("会话")
                            }),
                    )
                    .child(div().flex_1())
                    .child(self.profile_picker(cx))
                    .child(
                        icon_button(
                            "archived-list",
                            if self.archived_only {
                                icons::BACK
                            } else {
                                icons::ARCHIVE
                            },
                            if self.archived_only {
                                tr("返回会话")
                            } else {
                                tr("查看已归档会话")
                            },
                        )
                        .on_click(cx.listener(|this, _, window, cx| {
                            this.archived_only = !this.archived_only;
                            this.fetch_list(0, false, window, cx);
                        })),
                    ),
            )
            .child(
                div()
                    .p_3()
                    .flex()
                    .flex_col()
                    .gap_2()
                    .child(
                        div()
                            .id("new-chat")
                            .px_2()
                            .h(px(32.))
                            .flex()
                            .gap_2()
                            .items_center()
                            .cursor_pointer()
                            .rounded(px(5.))
                            .hover(|s| s.bg(rgb(SELECTED)))
                            .child(svg_symbol(icons::ROBOT, 16., MUTED))
                            .child(
                                div()
                                    .flex_1()
                                    .min_w_0()
                                    .truncate()
                                    .text_size(px(13.))
                                    .text_color(ink(SECONDARY))
                                    .child(tr("新建会话")),
                            )
                            .child(
                                div().flex().flex_none().gap(px(3.)).children(
                                    if cfg!(target_os = "macos") {
                                        ["⌘", "N"]
                                    } else {
                                        ["Ctrl", "N"]
                                    }
                                    .into_iter()
                                    .map(|key| {
                                        div()
                                            .h(px(17.))
                                            .min_w(px(16.))
                                            .px(px(3.))
                                            .flex()
                                            .items_center()
                                            .justify_center()
                                            .rounded(px(3.))
                                            .border_1()
                                            .border_color(rgb(0xe3e8ef))
                                            .bg(rgb(0xf7f8fa))
                                            .text_size(px(9.5))
                                            .text_color(ink(MUTED))
                                            .child(key)
                                    }),
                                ),
                            )
                            .on_click(
                                cx.listener(|this, _, window, cx| this.new_chat_tab(window, cx)),
                            ),
                    )
                    .child(
                        div()
                            .flex()
                            .gap(px(6.))
                            .items_center()
                            .mx_2()
                            .h(px(26.))
                            .border_b_1()
                            .border_color(gpui::transparent_black())
                            .when(searching, |field| field.border_color(rgb(ACCENT)))
                            .child(svg_symbol(
                                icons::SIDEBAR_SEARCH,
                                14.,
                                if searching || has_query {
                                    MUTED
                                } else {
                                    0xb0b7bf
                                },
                            ))
                            .child(
                                div().flex_1().min_w_0().child(
                                    Input::new(&self.search)
                                        .appearance(false)
                                        .bordered(false)
                                        .small()
                                        .px_0(),
                                ),
                            )
                            .children(has_query.then(|| {
                                icon_button(
                                    "clear-sidebar-search",
                                    icons::TAB_CLOSE,
                                    tr("清除搜索"),
                                )
                                .size(px(21.))
                                .on_click(cx.listener(
                                    |this, _, window, cx| {
                                        this.search.update(cx, |input, cx| {
                                            input.replace_all("", window, cx);
                                            input.focus(window, cx);
                                        });
                                    },
                                ))
                            })),
                    ),
            )
            .child(self.sidebar_sessions(cx))
            .child(self.cron_sidebar(cx))
    }

    fn profile_picker(&self, cx: &mut Context<Self>) -> impl IntoElement + use<> {
        let current = self.active_profile().to_owned();
        let label = self.profile_label(&current);
        let profiles = self.profiles.entries.clone();
        let connected = self.out.is_some();
        let desktop = cx.entity().downgrade();
        Button::new("profile-picker")
            .ghost()
            .compact()
            .h(px(22.))
            .max_w(px(112.))
            .mr(px(5.))
            .px(px(6.))
            .rounded(px(6.))
            .bg(rgb(0xe9eef3))
            .hover(|button| button.bg(rgb(0xe1e8ef)))
            .tooltip(crate::i18n::format_text!(
                "切换 Profile · {label}",
                "Switch profile · {label}"
            ))
            .child(
                div()
                    .flex()
                    .min_w_0()
                    .items_center()
                    .gap(px(5.))
                    .child(
                        div()
                            .size(px(6.))
                            .flex_none()
                            .rounded_full()
                            .bg(rgb(0x3e8e83)),
                    )
                    .child(
                        div()
                            .min_w_0()
                            .truncate()
                            .text_size(px(11.))
                            .text_color(ink(SECONDARY))
                            .child(label),
                    )
                    .child(svg_symbol(icons::CHEVRON_DOWN, 11., MUTED).flex_none()),
            )
            .dropdown_menu_with_anchor(Anchor::TopRight, move |mut menu, _, _| {
                menu = menu.min_w(px(184.)).label(tr("切换 Profile"));
                for profile in &profiles {
                    let target = desktop.clone();
                    let name = profile.name.clone();
                    let selected = current == name;
                    let title = if profile.label.as_ref() == name {
                        profile.label.clone()
                    } else {
                        format!("{} · {name}", profile.label).into()
                    };
                    menu = menu.item(
                        PopupMenuItem::element(move |_, _| {
                            div()
                                .flex()
                                .items_center()
                                .gap_2()
                                .min_w_0()
                                .child(
                                    div()
                                        .w(px(16.))
                                        .flex_none()
                                        .flex()
                                        .items_center()
                                        .justify_center()
                                        .children(selected.then(|| {
                                            div().size(px(6.)).rounded_full().bg(rgb(0x3e8e83))
                                        })),
                                )
                                .child(div().truncate().child(title.clone()))
                        })
                        .on_click(move |_, window, cx| {
                            let _ =
                                target.update(cx, |this, cx| this.open_profile(&name, window, cx));
                        }),
                    );
                }
                menu.separator()
                    .item(tab_view::menu_item(
                        &desktop,
                        tr("管理配置档案…"),
                        icons::PROFILE_CARD,
                        connected,
                        |this, window, cx| this.open_profile_editor(window, cx),
                    ))
                    .item(tab_view::menu_item(
                        &desktop,
                        tr("刷新 Profile 列表"),
                        icons::REFRESH,
                        connected,
                        |this, window, cx| this.load_profiles(window, cx),
                    ))
            })
    }

    pub(super) fn session_row(
        &self,
        entry: sidebar_tree::Entry,
        now: i64,
        desktop: gpui::WeakEntity<Self>,
    ) -> AnyElement {
        let sidebar_tree::Entry { row, depth, last } = entry;
        let unread = self
            .unread_sessions
            .get(&row.profile, &row.id)
            .unwrap_or(row.unread);
        let selected = self.selected.as_deref() == Some(&row.id);
        let session = self.sessions.get(&row.id);
        let running = session.is_some_and(|session| session.running);
        let waiting = session.is_some_and(|session| !session.prompts.is_empty());
        let background = self.session_has_activity(row);
        let key = row.id.clone();
        let title_color = self
            .title_color(&row.profile, &row.id, row.pin_order_key())
            .map_or(if selected { INK } else { SECONDARY }, |color| {
                color.style().1
            });

        let open = row.clone();
        let middle = row.clone();
        let mut menu_summary = row.clone();
        menu_summary.unread = unread;
        let trigger_summary = menu_summary.clone();
        let click_desktop = desktop.clone();
        let middle_desktop = desktop.clone();
        let trigger_desktop = desktop.clone();
        let click_desktop_for_pin = desktop.clone();
        let drag_summary = trigger_summary.clone();
        let row = div()
            .id("row")
            .group("sidebar-session")
            .h(px(26.))
            .flex_none()
            .rounded(px(3.))
            .flex()
            .items_center()
            .gap_2()
            .px_2()
            .when(depth > 0, |this| {
                this.pl(px(8. + 9. * depth.min(6) as f32)).child(
                    div()
                        .flex_none()
                        .w(px(11.))
                        .text_size(px(11.))
                        .text_color(ink(0x8c95a3))
                        .child(if last { "└" } else { "├" }),
                )
            })
            .cursor_pointer()
            .when(selected, |row| row.bg(rgb(SELECTED)))
            .hover(|style| style.bg(rgb(if selected { SELECTED } else { SIDEBAR_HOVER })))
            .on_click(move |event: &gpui::ClickEvent, window, app| {
                let _ = click_desktop.update(app, |this, cx| {
                    let mods = event.modifiers();
                    let new_tab = mods.control || cfg!(target_os = "macos") && mods.platform;
                    if mods.shift && !new_tab && !mods.alt && !open.archived {
                        this.patch_session(
                            &open.id,
                            &open.profile,
                            json!({"pinned":!open.pinned}),
                            window,
                            cx,
                        );
                    } else {
                        this.open_session(&open, new_tab, window, cx);
                    }
                });
            })
            .on_mouse_up(gpui::MouseButton::Middle, move |_, window, app| {
                app.stop_propagation();
                let _ = middle_desktop
                    .update(app, |this, cx| this.open_session(&middle, true, window, cx));
            })
            .child(
                div()
                    .size(px(12.))
                    .flex_none()
                    .flex()
                    .items_center()
                    .justify_center()
                    .child(if row.archived {
                        svg_symbol(icons::ARCHIVE, 12., MUTED)
                    } else if background && !waiting && !running && !unread {
                        div()
                            .size(px(7.))
                            .rounded_full()
                            .border_1()
                            .border_color(rgb(ACCENT))
                    } else {
                        div()
                            .size(px(if unread && !waiting && !running {
                                6.
                            } else {
                                5.
                            }))
                            .rounded_full()
                            .bg(rgb(if waiting {
                                0xc68723
                            } else if running {
                                ACCENT
                            } else if unread {
                                UNREAD
                            } else {
                                0x9da5b0
                            }))
                    }),
            )
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .truncate()
                    .text_size(px(12.5))
                    .text_color(ink(title_color))
                    .font_weight(if unread {
                        gpui::FontWeight::MEDIUM
                    } else {
                        gpui::FontWeight::NORMAL
                    })
                    .child(row.title.clone()),
            )
            .child(
                div()
                    .relative()
                    .w(px(48.))
                    .h_full()
                    .flex_none()
                    .flex()
                    .items_center()
                    .justify_end()
                    .child(
                        div()
                            .text_size(px(11.))
                            .text_color(ink(MUTED))
                            .group_hover("sidebar-session", |style| style.invisible())
                            .child(session_age(row.updated_at, now)),
                    )
                    .child(
                        div()
                            .id("session-row-actions")
                            .absolute()
                            .right_0()
                            .top_0()
                            .h_full()
                            .flex()
                            .items_center()
                            .on_click(|_, _, cx| cx.stop_propagation())
                            .child(
                                Button::new("session-menu")
                                    .ghost()
                                    .compact()
                                    .size(px(21.))
                                    .p_0()
                                    .tooltip(tr("会话操作"))
                                    .child(
                                        svg_symbol(icons::KEBAB, 14., MUTED)
                                            .invisible()
                                            .group_hover("sidebar-session", |style| {
                                                style.visible()
                                            }),
                                    )
                                    .dropdown_menu_with_anchor(
                                        gpui::Anchor::TopRight,
                                        move |menu, window, cx| {
                                            tab_view::sidebar_menu(
                                                menu,
                                                &trigger_desktop,
                                                &trigger_summary,
                                                window,
                                                cx,
                                            )
                                        },
                                    ),
                            ),
                    ),
            )
            .context_menu(move |menu, window, cx| {
                tab_view::sidebar_menu(menu, &desktop, &menu_summary, window, cx)
            });
        div()
            .id(SharedString::from(format!("session-{key}")))
            .flex_none()
            .when(
                !self.archived_only && self.query.is_empty() && drag_summary.pinned,
                |element| {
                    let profile = self.profiles.scope.profile.clone();
                    let key = drag_summary.pin_order_key().to_owned();
                    let hover_profile = profile.clone();
                    let hover_key = key.clone();
                    let index = self.pin_index(&key).unwrap_or_default();
                    let reorder = click_desktop_for_pin;
                    element
                        .on_drag(
                            PinnedDrag {
                                profile: profile.clone(),
                                key: key.clone(),
                                title: drag_summary.title.clone(),
                                index,
                            },
                            |drag, _, _, cx| cx.new(|_| drag.clone()),
                        )
                        .drag_over::<PinnedDrag>(move |style, drag, _, _| {
                            if drag.profile == hover_profile && drag.key != hover_key {
                                let style = if drag.index < index {
                                    style.border_b_1()
                                } else {
                                    style.border_t_1()
                                };
                                style.border_color(rgb(ACCENT))
                            } else {
                                style
                            }
                        })
                        .on_drop(move |drag: &PinnedDrag, _, cx| {
                            if drag.profile == profile {
                                let _ = reorder.update(cx, |this, cx| {
                                    this.reorder_pins(&profile, &drag.key, &key, cx);
                                });
                            }
                        })
                },
            )
            .child(row)
            .into_any_element()
    }
}

fn session_age(timestamp: i64, now: i64) -> String {
    if timestamp <= 0 {
        return String::new();
    }
    match now.saturating_sub(timestamp).max(0) {
        0..=59 => tr("刚刚").into(),
        n if n < 3_600 => crate::i18n::format_text!("{}分", "{} min", n / 60),
        n if n < 86_400 => crate::i18n::format_text!("{}小时", "{} hr", n / 3_600),
        n => crate::i18n::format_text!("{}天", "{} days", n / 86_400),
    }
}
