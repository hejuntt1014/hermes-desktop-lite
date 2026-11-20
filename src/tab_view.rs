use crate::theme::{ink, rgb};

use crate::i18n::text as tr;

use std::rc::Rc;

use crate::{
    app::TabClose,
    icons,
    session::{SessionTarget, Summary},
    session_colors::SessionTitleColor,
};
use gpui::{
    AnyView, App, AppContext, ClipboardItem, Context, Div, Render, SharedString, WeakEntity,
    Window, div, prelude::*, px,
};
use gpui_component::{
    Icon,
    menu::{ContextMenuExt, PopupMenu, PopupMenuItem},
    tooltip::Tooltip,
};
use serde_json::json;

use super::{ACCENT, Desktop, INK, LINE, MUTED, SURFACE, UNREAD, icon_button, svg_symbol, symbol};

const TAB_MAX_WIDTH: f32 = 178.;
const TAB_MIN_WIDTH: f32 = 86.;
const TAB_MIN_WIDTH_WITH_PROFILE: f32 = 100.;
const TAB_COMPACT_WIDTH: f32 = 132.;

struct ChatTabTooltip {
    desktop: WeakEntity<Desktop>,
    tab: String,
    content: AnyView,
}

impl Render for ChatTabTooltip {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let hovered = self
            .desktop
            .upgrade()
            .is_some_and(|desktop| desktop.read(cx).tab_contains_pointer(&self.tab, window));
        div().children((hovered && !cx.has_active_drag()).then(|| self.content.clone()))
    }
}

#[derive(Clone)]
struct ChatTabDrag {
    id: String,
    title: SharedString,
    width: gpui::Pixels,
    profile: Option<SharedString>,
}

impl Render for ChatTabDrag {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div()
            .w(self.width)
            .h(px(28.))
            .px_2()
            .flex()
            .items_center()
            .rounded(px(4.))
            .border_1()
            .border_color(rgb(LINE))
            .bg(rgb(SURFACE))
            .shadow_sm()
            .font_family("Microsoft YaHei UI")
            .text_size(px(12.))
            .text_color(ink(INK))
            .gap_1()
            .child(div().flex_1().truncate().child(self.title.clone()))
            .children(self.profile.clone().map(|profile| {
                div()
                    .text_size(px(10.))
                    .text_color(ink(MUTED))
                    .child(profile)
            }))
    }
}

pub(super) fn menu_item(
    desktop: &WeakEntity<Desktop>,
    label: &'static str,
    glyph: &'static str,
    enabled: bool,
    handler: impl Fn(&mut Desktop, &mut Window, &mut Context<Desktop>) + 'static,
) -> PopupMenuItem {
    let item = PopupMenuItem::element(move |_, _| {
        div()
            .h(px(18.))
            .flex()
            .items_center()
            .gap_2()
            .child(
                div()
                    .w(px(16.))
                    .flex_none()
                    .flex()
                    .items_center()
                    .justify_center()
                    .text_color(ink(MUTED))
                    .child(symbol(glyph, 13.)),
            )
            .child(label)
    });
    menu_handler(item, desktop, enabled, handler)
}

fn session_menu_item(
    desktop: &WeakEntity<Desktop>,
    label: &'static str,
    glyph: &'static str,
    enabled: bool,
    handler: impl Fn(&mut Desktop, &mut Window, &mut Context<Desktop>) + 'static,
) -> PopupMenuItem {
    menu_handler(
        PopupMenuItem::new(label).icon(Icon::default().path(glyph)),
        desktop,
        enabled,
        handler,
    )
}

fn menu_handler(
    item: PopupMenuItem,
    desktop: &WeakEntity<Desktop>,
    enabled: bool,
    handler: impl Fn(&mut Desktop, &mut Window, &mut Context<Desktop>) + 'static,
) -> PopupMenuItem {
    let desktop = desktop.clone();
    let handler = Rc::new(handler);
    item.disabled(!enabled).on_click(move |_, window, cx| {
        let desktop = desktop.clone();
        let handler = handler.clone();
        window.defer(cx, move |window, cx| {
            let _ = desktop.update(cx, |this, cx| handler(this, window, cx));
        });
    })
}

fn session_actions(
    menu: PopupMenu,
    desktop: &WeakEntity<Desktop>,
    target: SessionTarget,
    summary: Option<Summary>,
    connected: bool,
    window: &mut Window,
    cx: &mut Context<PopupMenu>,
) -> PopupMenu {
    let rename = target.clone();
    let mut menu = menu.min_w(px(154.)).item(session_menu_item(
        desktop,
        tr("重命名…"),
        icons::RENAME,
        connected,
        move |this, window, cx| this.begin_rename(rename.clone(), window, cx),
    ));
    let archive = summary.clone();
    if let Some(summary) = summary {
        let pin = summary.clone();
        menu = menu
            .item(session_menu_item(
                desktop,
                if summary.pinned {
                    tr("取消置顶")
                } else {
                    tr("置顶")
                },
                icons::PIN,
                connected,
                move |this, window, cx| {
                    this.patch_session(
                        &pin.id,
                        &pin.profile,
                        json!({"pinned": !pin.pinned}),
                        window,
                        cx,
                    );
                },
            ))
            .item(session_menu_item(
                desktop,
                if summary.unread {
                    tr("标记为已读")
                } else {
                    tr("标记为未读")
                },
                if summary.unread {
                    icons::MAIL_READ
                } else {
                    icons::MAIL
                },
                connected,
                move |this, window, cx| {
                    this.patch_session(
                        &summary.id,
                        &summary.profile,
                        json!({"unread": !summary.unread}),
                        window,
                        cx,
                    );
                },
            ));
    }
    menu = appearance_submenu(menu, desktop, &target, window, cx);
    let key = target.id.clone();
    let branch = target.clone();
    let markdown_target = target.clone();
    menu = menu
        .item(session_menu_item(
            desktop,
            tr("复制 ID"),
            crate::icons::COPY,
            true,
            move |_, _, cx| {
                cx.write_to_clipboard(ClipboardItem::new_string(key.clone()));
            },
        ))
        .separator()
        .item(session_menu_item(
            desktop,
            tr("分叉"),
            crate::icons::FORK,
            connected,
            move |this, window, cx| {
                this.branch_session(branch.clone(), None, window, cx);
            },
        ))
        .item(session_menu_item(
            desktop,
            tr("导出 Markdown"),
            icons::CLOUD_DOWNLOAD,
            connected,
            move |this, _, cx| {
                this.export_session(
                    markdown_target.clone(),
                    super::super::session_export::ExportFormat::Markdown,
                    cx,
                );
            },
        ))
        .item(session_menu_item(
            desktop,
            tr("导出 JSON"),
            icons::CLOUD_DOWNLOAD,
            connected,
            move |this, _, cx| {
                this.export_session(
                    target.clone(),
                    super::super::session_export::ExportFormat::Json,
                    cx,
                )
            },
        ));
    if let Some(summary) = archive {
        menu = menu.separator().item(session_menu_item(
            desktop,
            if summary.archived {
                tr("取消归档")
            } else {
                tr("归档")
            },
            icons::ARCHIVE,
            connected,
            move |this, window, cx| {
                let patch = if summary.archived {
                    json!({"archived": false})
                } else {
                    json!({"archived": true, "pinned": false})
                };
                this.patch_session(&summary.id, &summary.profile, patch, window, cx);
            },
        ));
    }
    menu
}

fn appearance_submenu(
    menu: PopupMenu,
    desktop: &WeakEntity<Desktop>,
    target: &SessionTarget,
    window: &mut Window,
    cx: &mut Context<PopupMenu>,
) -> PopupMenu {
    let Some(entity) = desktop.upgrade() else {
        return menu;
    };
    let app = entity.read(cx);
    let workspace = app.settings.workspace_key().to_owned();
    let desktop = desktop.clone();
    let target = target.clone();
    menu.submenu_with_icon(
        Some(Icon::default().path(icons::SESSION_PALETTE)),
        tr("外观"),
        window,
        cx,
        move |submenu, _, submenu_cx| {
            let picker = submenu_cx.entity().downgrade();
            let desktop = desktop.clone();
            let target = target.clone();
            let workspace = workspace.clone();
            let read_desktop = desktop.clone();
            let read_target = target.clone();
            let pick = Rc::new(
                move |color: Option<SessionTitleColor>, window: &mut Window, cx: &mut App| {
                    let desktop = desktop.clone();
                    let target = target.clone();
                    let workspace = workspace.clone();
                    let picker = picker.clone();
                    window.defer(cx, move |_, cx| {
                        let _ = desktop.update(cx, |this, cx| {
                            if this.settings.workspace_key() == workspace {
                                this.apply_title_color(&target, color, cx);
                            }
                        });
                        let _ = picker.update(cx, |_, cx| cx.notify());
                    });
                },
            );
            submenu.item(
                PopupMenuItem::element(move |_, cx| {
                    let selected = read_desktop.upgrade().and_then(|entity| {
                        let app = entity.read(cx);
                        let lineage = app
                            .profile_summary(&read_target.profile, &read_target.id)
                            .map_or(read_target.id.as_str(), Summary::pin_order_key);
                        app.title_color(&read_target.profile, &read_target.id, lineage)
                    });
                    let clear = pick.clone();
                    div()
                        .flex()
                        .flex_col()
                        .items_center()
                        .gap(px(5.))
                        .py(px(4.))
                        .children(SessionTitleColor::PALETTE.into_iter().map(|row| {
                            div()
                                .flex()
                                .gap(px(4.))
                                .children(row.into_iter().map(|color| {
                                    let (label, _, fill) = color.style();
                                    let current = selected == Some(color);
                                    let pick = pick.clone();
                                    div()
                                        .id(label)
                                        .size(px(27.))
                                        .rounded_full()
                                        .flex()
                                        .items_center()
                                        .justify_center()
                                        .cursor_pointer()
                                        .aria_label(label)
                                        .tooltip(move |window, cx| {
                                            Tooltip::new(label).build(window, cx)
                                        })
                                        .border_1()
                                        .border_color(rgb(if current { fill } else { 0xffffff }))
                                        .hover(|style| style.border_color(gpui::rgb(fill)))
                                        .child(
                                            div().size(px(21.)).rounded_full().bg(gpui::rgb(fill)),
                                        )
                                        .on_click(move |_, window, cx| {
                                            cx.stop_propagation();
                                            pick(Some(color), window, cx)
                                        })
                                }))
                        }))
                        .child(
                            div()
                                .id("clear-title-color")
                                .h(px(26.))
                                .w_full()
                                .mt(px(2.))
                                .rounded(px(4.))
                                .flex()
                                .items_center()
                                .justify_center()
                                .gap_1()
                                .text_size(px(12.))
                                .text_color(ink(MUTED))
                                .cursor_pointer()
                                .hover(|style| style.bg(rgb(0xe8eef9)).text_color(ink(INK)))
                                .child(svg_symbol(icons::NO_COLOR, 13., MUTED))
                                .child(tr("无颜色"))
                                .on_click(move |_, window, cx| {
                                    cx.stop_propagation();
                                    clear(None, window, cx);
                                }),
                        )
                })
                .disabled(true),
            )
        },
    )
}

pub(super) fn sidebar_menu(
    menu: PopupMenu,
    desktop: &WeakEntity<Desktop>,
    summary: &Summary,
    window: &mut Window,
    cx: &mut Context<PopupMenu>,
) -> PopupMenu {
    let Some(entity) = desktop.upgrade() else {
        return menu;
    };
    let state = entity.read(cx);
    let menu = menu.action_context(
        window
            .focused(cx)
            .unwrap_or_else(|| state.workspace_focus.clone()),
    );
    let mut current = state
        .rows
        .iter()
        .find(|row| row.id == summary.id && row.profile == summary.profile)
        .unwrap_or(summary)
        .clone();
    current.unread = state
        .unread_sessions
        .get(&current.profile, &current.id)
        .unwrap_or(current.unread);
    let open = current.clone();
    let connected = state.out.is_some();
    let menu = menu
        .item(session_menu_item(
            desktop,
            tr("在新标签页打开"),
            icons::LINK_EXTERNAL,
            true,
            move |this, window, cx| {
                this.open_session(&open, true, window, cx);
            },
        ))
        .separator();
    session_actions(
        menu,
        desktop,
        SessionTarget::from(&current),
        Some(current),
        connected,
        window,
        cx,
    )
}

fn chat_tab_menu(
    mut menu: PopupMenu,
    desktop: &WeakEntity<Desktop>,
    id: &str,
    window: &mut Window,
    app: &mut Context<PopupMenu>,
) -> PopupMenu {
    let Some(entity) = desktop.upgrade() else {
        return menu;
    };
    let state = entity.read(app);
    menu = menu.action_context(
        window
            .focused(app)
            .unwrap_or_else(|| state.workspace_focus.clone()),
    );
    let Some(workspace) = state.workspace() else {
        return menu;
    };
    let Some(index) = workspace.tabs.iter().position(|tab| tab.id == id) else {
        return menu;
    };
    let tab = &workspace.tabs[index];
    let has_other_tabs = workspace.tabs.len() > 1;
    let has_tabs_to_right = index + 1 < workspace.tabs.len();
    let profile = state.tab_profile(tab);
    let connected = state.out.is_some();
    let summary = tab
        .session
        .as_deref()
        .and_then(|id| state.profile_summary(profile, id))
        .cloned()
        .map(|mut row| {
            row.unread = state
                .unread_sessions
                .get(profile, &row.id)
                .unwrap_or(row.unread);
            row
        });

    if let Some(key) = &tab.session {
        let reload = key.clone();
        let target = SessionTarget {
            id: key.clone(),
            title: tab.title.clone(),
            profile: profile.to_owned(),
        };
        menu = session_actions(menu, desktop, target, summary, connected, window, app)
            .separator()
            .item(session_menu_item(
                desktop,
                tr("重新加载"),
                icons::REFRESH,
                connected,
                move |this, _, cx| {
                    this.attach(&reload, true);
                    cx.notify();
                },
            ));
    }

    for (label, glyph, scope, enabled) in [
        (tr("关闭"), icons::TAB_CLOSE, TabClose::Current, true),
        (
            tr("关闭其他"),
            icons::CLOSE_OTHERS,
            TabClose::Others,
            has_other_tabs,
        ),
        (
            tr("关闭右侧"),
            icons::RIGHT,
            TabClose::Right,
            has_tabs_to_right,
        ),
        (tr("全部关闭"), icons::CLEAR_ALL, TabClose::All, true),
    ] {
        let id = id.to_owned();
        menu = menu.item(session_menu_item(
            desktop,
            label,
            glyph,
            enabled,
            move |this, window, cx| {
                this.close_chat_tabs(&id, scope, window, cx);
            },
        ));
    }
    menu
}

impl Desktop {
    pub(super) fn chat_tabs(
        &self,
        max_width: gpui::Pixels,
        window: &Window,
        cx: &mut Context<Self>,
    ) -> Div {
        let Some(workspace) = self.workspace() else {
            return div();
        };
        let mixed_profiles = workspace
            .tabs
            .iter()
            .any(|tab| self.tab_profile(tab) != self.active_profile());
        let minimum_tab_width = if mixed_profiles {
            TAB_MIN_WIDTH_WITH_PROFILE
        } else {
            TAB_MIN_WIDTH
        };
        let tab_count = workspace.tabs.len().max(1) as f32;
        let strip_width = max_width;
        let tab_width = (f32::from(strip_width) / tab_count)
            .floor()
            .clamp(minimum_tab_width, TAB_MAX_WIDTH);
        let profile_width = px((tab_width - 64.).clamp(30., 57.));
        if strip_width < self.tab_scroll.bounds().size.width {
            let desktop = cx.entity().downgrade();
            // The scroll handle still has the previous viewport until this frame is laid out.
            window.on_next_frame(move |_, cx| {
                let _ = desktop.update(cx, |this, cx| {
                    this.reveal_selected_tab();
                    cx.notify();
                });
            });
        }
        let mut strip = div()
            .id("chat-tabs")
            .h_full()
            .max_w(strip_width)
            .overflow_x_scroll()
            .track_scroll(&self.tab_scroll)
            .on_scroll(cx.listener(|this, event: &gpui::ScrollEvent, _, cx| {
                let delta = event.delta.pixel_delta(px(36.));
                let max_scroll = this.tab_scroll.max_offset().x;
                if delta.x != px(0.) || delta.y == px(0.) || max_scroll <= px(0.) {
                    return;
                }
                let mut offset = this.tab_scroll.offset();
                offset.x = (offset.x + delta.y).clamp(-max_scroll, px(0.));
                this.tab_scroll.set_offset(offset);
                cx.stop_propagation();
                cx.notify();
            }))
            .flex();
        let desktop = cx.entity().downgrade();
        let layout = self.tab_drag_layout(window);
        if self.dragged_tab.is_some() {
            let desktop = desktop.clone();
            window.on_next_frame(move |window, cx| {
                let _ = desktop.update(cx, |this, cx| {
                    if !cx.has_active_drag() {
                        this.dragged_tab = None;
                    } else {
                        let bounds = this.tab_scroll.bounds();
                        let mouse = window.mouse_position();
                        if bounds.contains(&mouse) {
                            let edge = px(26.);
                            let speed = ((mouse.x - bounds.right() + edge).max(px(0.))
                                - (bounds.left() + edge - mouse.x).max(px(0.)))
                                * 0.38;
                            let mut offset = this.tab_scroll.offset();
                            offset.x =
                                (offset.x - speed).clamp(-this.tab_scroll.max_offset().x, px(0.));
                            this.tab_scroll.set_offset(offset);
                        }
                    }
                    cx.notify();
                });
            });
        }
        for (index, tab) in workspace.tabs.iter().enumerate() {
            let active = !self.files.open
                && !self.review.open
                && workspace.active_tab.as_deref() == Some(tab.id.as_str());
            let key = tab.id.clone();
            let close = key.clone();
            let middle = key.clone();
            let drag_desktop = desktop.clone();
            let menu_target = key.clone();
            let menu_desktop = desktop.clone();
            let tooltip_desktop = desktop.clone();
            let tooltip_tab = tab.id.clone();
            let title = SharedString::from(tab.display_title().to_owned());
            let profile = self.tab_profile(tab);
            let title_color = tab
                .session
                .as_deref()
                .and_then(|id| {
                    let lineage = self
                        .profile_summary(profile, id)
                        .map_or(id, Summary::pin_order_key);
                    self.title_color(profile, id, lineage)
                })
                .map_or(if active { INK } else { MUTED }, |color| color.style().1);
            let show_profile = mixed_profiles
                && (tab_width >= TAB_COMPACT_WIDTH || profile != self.profiles.serving);
            let profile_badge = self.profile_label(profile);

            let session = tab.session.as_ref().and_then(|id| self.sessions.get(id));
            let pending = session.and_then(|s| s.prompts.values().next());
            let tooltip: SharedString = match pending {
                Some(prompt) => format!(
                    "{} · {} · {}",
                    title,
                    profile_badge,
                    if prompt.clarify {
                        tr("等待回答")
                    } else {
                        tr("等待审批")
                    }
                ),
                None => format!("{} · {}", title, profile_badge),
            }
            .into();
            let unread = tab
                .session
                .as_ref()
                .is_some_and(|id| self.session_is_unread(profile, id));
            let indicator = if session.is_some_and(|session| !session.prompts.is_empty()) {
                0xc68723
            } else if session.is_some_and(|session| session.running) {
                ACCENT
            } else if unread {
                UNREAD
            } else {
                0x9ba4af
            };
            let chip = div()
                .id("tab")
                .group("chat-tab")
                .h_full()
                .w_full()
                .min_w_0()
                .px_2()
                .flex()
                .items_center()
                .gap_1()
                .cursor_pointer()
                .relative()
                .left(
                    layout
                        .as_ref()
                        .map_or(px(0.), |layout| layout.shift(index, &self.tab_scroll)),
                )
                .when(
                    layout.as_ref().is_some_and(|layout| layout.source == index),
                    |tab| tab.opacity(0.),
                )
                .rounded_t(px(7.))
                .when(active, |tab| {
                    tab.bg(rgb(SURFACE)).border_b_2().border_color(rgb(ACCENT))
                })
                .text_color(ink(if active { INK } else { MUTED }))
                .hover(|style| style.bg(rgb(0xf2f4f8)))
                .aria_label(tooltip.clone())
                .tooltip(move |window, cx| {
                    let content = Tooltip::new(tooltip.clone()).build(window, cx);
                    cx.new(|_| ChatTabTooltip {
                        desktop: tooltip_desktop.clone(),
                        tab: tooltip_tab.clone(),
                        content,
                    })
                    .into()
                })
                .on_click(
                    cx.listener(move |this, event: &gpui::ClickEvent, window, cx| {
                        let modifiers = event.modifiers();
                        if modifiers.control || cfg!(target_os = "macos") && modifiers.platform {
                            this.close_chat_tabs(&key, TabClose::Current, window, cx);
                        } else {
                            this.select_tab(&key, window, cx);
                        }
                    }),
                )
                .on_mouse_up(
                    gpui::MouseButton::Middle,
                    cx.listener(move |this, _, window, cx| {
                        cx.stop_propagation();
                        this.close_chat_tabs(&middle, TabClose::Current, window, cx);
                    }),
                )
                .on_drag(
                    ChatTabDrag {
                        id: tab.id.clone(),
                        title: title.clone(),
                        width: px(tab_width),
                        profile: show_profile.then(|| profile_badge.clone()),
                    },
                    move |drag, offset, _, cx| {
                        cx.stop_propagation();
                        let mut preview = drag.clone();
                        let _ = drag_desktop.update(cx, |this, cx| {
                            if let Some(bounds) = this.tab_scroll.bounds_for_item(index) {
                                preview.width = bounds.size.width;
                            }
                            this.dragged_tab =
                                Some((drag.id.clone(), offset.x.clamp(px(0.), preview.width)));
                            cx.notify();
                        });
                        cx.new(|_| preview)
                    },
                )
                .child(
                    div()
                        .size(px(5.))
                        .flex_none()
                        .rounded_full()
                        .bg(rgb(indicator)),
                )
                .child(
                    div()
                        .min_w_0()
                        .flex_1()
                        .truncate()
                        .text_size(px(12.))
                        .text_color(ink(title_color))
                        .font_weight(if active {
                            gpui::FontWeight::MEDIUM
                        } else {
                            gpui::FontWeight::NORMAL
                        })
                        .child(title),
                )
                .when(show_profile, |tab| {
                    tab.child(
                        div()
                            .max_w(profile_width)
                            .min_w_0()
                            .px(px(4.))
                            .truncate()
                            .rounded(px(4.))
                            .bg(rgb(0xf0f3f5))
                            .text_size(px(10.))
                            .text_color(ink(0x62727b))
                            .child(profile_badge),
                    )
                })
                .child(
                    div()
                        .flex_none()
                        .invisible()
                        .group_hover("chat-tab", |style| style.visible())
                        .child(
                            icon_button("close-tab", icons::TAB_CLOSE, tr("关闭标签"))
                                .size(px(18.))
                                .on_mouse_down(gpui::MouseButton::Left, |_, _, cx| {
                                    cx.stop_propagation()
                                })
                                .on_click(cx.listener(move |this, _, window, cx| {
                                    cx.stop_propagation();
                                    this.close_chat_tabs(&close, TabClose::Current, window, cx);
                                })),
                        ),
                )
                .context_menu(move |menu, window, cx| {
                    chat_tab_menu(menu, &menu_desktop, &menu_target, window, cx)
                });
            let target = tab.id.clone();
            strip = strip.child(
                div()
                    .id(SharedString::from(format!("tab-{}", tab.id)))
                    .h_full()
                    .w(px(tab_width))
                    .pt(px(3.))
                    .flex_none()
                    .on_drop(cx.listener(move |this, drag: &ChatTabDrag, _, cx| {
                        this.dragged_tab = None;
                        this.move_chat_tab(&drag.id, &target, cx);
                        cx.notify();
                    }))
                    .child(chip),
            );
        }
        div().h_full().flex().items_center().min_w_0().child(strip)
    }

    fn tab_drag_layout(&self, window: &Window) -> Option<TabDragLayout> {
        let (id, grab) = self.dragged_tab.as_ref()?;
        let source = self
            .workspace()?
            .tabs
            .iter()
            .position(|tab| &tab.id == id)?;
        let width = self.tab_scroll.bounds_for_item(source)?.size.width;
        Some(TabDragLayout {
            source,
            width,
            center: window.mouse_position().x - self.tab_scroll.offset().x - *grab + width * 0.5,
        })
    }

    fn tab_contains_pointer(&self, id: &str, window: &Window) -> bool {
        let pointer = window.mouse_position();
        if !self.tab_scroll.bounds().contains(&pointer) {
            return false;
        }
        let Some(index) = self
            .workspace()
            .and_then(|workspace| workspace.tabs.iter().position(|tab| tab.id == id))
        else {
            return false;
        };
        let offset = self.tab_scroll.offset().x;
        self.tab_scroll.bounds_for_item(index).is_some_and(|slot| {
            pointer.x >= slot.left() + offset && pointer.x < slot.right() + offset
        })
    }
}

struct TabDragLayout {
    source: usize,
    width: gpui::Pixels,
    center: gpui::Pixels,
}

impl TabDragLayout {
    fn shift(&self, index: usize, scroll: &gpui::ScrollHandle) -> gpui::Pixels {
        let Some(bounds) = scroll.bounds_for_item(index) else {
            return px(0.);
        };
        let progress = (f32::from(self.center - bounds.left())
            / f32::from(bounds.size.width).max(1.))
        .clamp(0., 1.);
        let progress = progress * progress * (3. - 2. * progress);
        match index.cmp(&self.source) {
            std::cmp::Ordering::Less => self.width * (1. - progress),
            std::cmp::Ordering::Greater => -self.width * progress,
            std::cmp::Ordering::Equal => px(0.),
        }
    }
}
