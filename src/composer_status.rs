use crate::i18n::text as tr;

use gpui::{Anchor, ClipboardItem, Context, Div, SharedString, div, prelude::*, px, rgb};
use gpui_component::{
    button::{Button, ButtonVariants},
    menu::DropdownMenu,
    tooltip::Tooltip,
};

use crate::{
    icons,
    session::Session,
    session_activity::Kind as WorkKind,
    session_todos::{TodoStatus, ordered_todos},
    style::{ACCENT, CODE_FONT, MUTED},
};

use super::{Desktop, LINE, SECONDARY, icon_button, svg_symbol, tab_view::menu_item};

impl Desktop {
    pub(super) fn composer_work(
        &self,
        key: &str,
        session: &Session,
        cx: &mut Context<Self>,
    ) -> Div {
        let work = &session.activity;
        let processes = (!work.processes.is_empty()).then(|| {
            self.work_group(
                key,
                WorkKind::Processes,
                work.processes.len(),
                work.processes_open,
                work.processes
                    .iter()
                    .filter(|_| work.processes_open)
                    .map(|process| {
                        let view_key = key.to_owned();
                        let id = process.id.clone();
                        let open = work.detail.as_ref() == Some(&process.id);
                        let row = div()
                            .id(SharedString::from(format!("work-process-{}", process.id)))
                            .h(px(25.))
                            .px(px(8.))
                            .gap(px(6.))
                            .flex()
                            .items_center()
                            .rounded(px(4.))
                            .cursor_pointer()
                            .hover(|row| row.bg(rgb(0xeff2f8)))
                            .child(work_dot(0x3777c4))
                            .child(
                                div()
                                    .flex_1()
                                    .min_w_0()
                                    .truncate()
                                    .text_color(rgb(SECONDARY))
                                    .child(process.title.clone()),
                            )
                            .child(work_status(tr("运行中"), 0x4d719f))
                            .child(svg_symbol(
                                if open {
                                    icons::CHEVRON_DOWN
                                } else {
                                    icons::CHEVRON_RIGHT
                                },
                                11.,
                                MUTED,
                            ))
                            .on_click(cx.listener(move |this, _, _, cx| {
                                if this.selected.as_deref() == Some(&view_key)
                                    && let Some(session) = this.sessions.get_mut(&view_key)
                                {
                                    session.activity.detail = (session.activity.detail.as_ref()
                                        != Some(&id))
                                    .then(|| id.clone());
                                    if this.following {
                                        this.sync_list();
                                    }
                                    cx.notify();
                                }
                            }));
                        div().child(row).children(open.then(|| {
                            div()
                                .mx(px(8.))
                                .mb(px(4.))
                                .p(px(6.))
                                .rounded(px(4.))
                                .bg(rgb(0xeff3f8))
                                .font_family(CODE_FONT)
                                .line_height(px(15.))
                                .text_color(rgb(MUTED))
                                .child(if process.output.is_empty() {
                                    tr("暂无输出").into()
                                } else {
                                    process.output.clone()
                                })
                        }))
                    })
                    .collect::<Vec<_>>(),
                cx,
            )
        });
        let agents = (!work.agents.is_empty()).then(|| {
            self.work_group(
                key,
                WorkKind::Agents,
                work.agents.len(),
                work.agents_open,
                work.agents
                    .iter()
                    .filter(|_| work.agents_open)
                    .map(|agent| {
                        div()
                            .min_h(px(25.))
                            .pl(px(8. + 12. * agent.depth.min(4) as f32))
                            .pr(px(8.))
                            .gap(px(6.))
                            .flex()
                            .items_center()
                            .child(work_dot(if agent.queued { 0xa6adb9 } else { 0x8670bd }))
                            .child(
                                div()
                                    .flex_1()
                                    .min_w_0()
                                    .truncate()
                                    .text_color(rgb(SECONDARY))
                                    .child(agent.title.clone()),
                            )
                            .children((!agent.model.is_empty() && agent.tool.is_empty()).then(
                                || {
                                    div()
                                        .max_w(px(130.))
                                        .truncate()
                                        .text_color(rgb(MUTED))
                                        .child(agent.model.clone())
                                },
                            ))
                            .children((!agent.tool.is_empty()).then(|| {
                                div()
                                    .max_w(px(130.))
                                    .truncate()
                                    .text_color(rgb(MUTED))
                                    .child(agent.tool.clone())
                            }))
                            .child(work_status(
                                if agent.queued {
                                    tr("排队中")
                                } else {
                                    tr("运行中")
                                },
                                0x78629f,
                            ))
                    })
                    .collect::<Vec<_>>(),
                cx,
            )
        });
        div()
            .flex()
            .flex_col()
            .gap(px(5.))
            .children(processes)
            .children(agents)
    }

    fn work_group(
        &self,
        session_key: &str,
        kind: WorkKind,
        count: usize,
        open: bool,
        rows: Vec<Div>,
        cx: &mut Context<Self>,
    ) -> Div {
        let (name, icon, tone, id) = match kind {
            WorkKind::Processes => (tr("后台进程"), icons::TERMINAL, 0x4d719f, "processes"),
            WorkKind::Agents => (tr("子代理"), icons::ROBOT, 0x78629f, "agents"),
        };
        let key = session_key.to_owned();
        div()
            .flex_none()
            .w_full()
            .rounded(px(5.))
            .overflow_hidden()
            .border_1()
            .border_color(rgb(LINE))
            .bg(rgb(0xf8f9fb))
            .child(
                div()
                    .id(SharedString::from(format!("composer-work-toggle-{id}")))
                    .h(px(25.))
                    .px(px(9.))
                    .flex()
                    .items_center()
                    .gap(px(6.))
                    .text_size(px(11.5))
                    .text_color(rgb(MUTED))
                    .cursor_pointer()
                    .hover(|row| row.bg(rgb(0xeff2f8)))
                    .child(svg_symbol(
                        if open {
                            icons::CHEVRON_DOWN
                        } else {
                            icons::CHEVRON_RIGHT
                        },
                        12.,
                        MUTED,
                    ))
                    .child(svg_symbol(icon, 13., tone))
                    .child(format!("{name} · {count}"))
                    .child(div().flex_1())
                    .child(work_dot(tone))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        if this.selected.as_deref() == Some(&key)
                            && let Some(session) = this.sessions.get_mut(&key)
                        {
                            let open = match kind {
                                WorkKind::Processes => &mut session.activity.processes_open,
                                WorkKind::Agents => &mut session.activity.agents_open,
                            };
                            *open = !*open;
                            if this.following {
                                this.sync_list();
                            }
                            cx.notify();
                        }
                    })),
            )
            .children(open.then(|| {
                div()
                    .id(SharedString::from(format!("work-{id}-{session_key}")))
                    .max_h(px(126.))
                    .overflow_y_scroll()
                    .px(px(18.))
                    .pb(px(4.))
                    .text_size(px(11.5))
                    .children(rows)
            }))
    }
    pub(super) fn composer_todos(
        &self,
        key: &str,
        session: &Session,
        cx: &mut Context<Self>,
    ) -> Option<Div> {
        let todos = &session.todos;
        let live = session.running && todos.live_in_turn;
        let items = todos.items();
        if items.is_empty() || session.running && !live {
            return None;
        }
        let expanded = if live {
            !todos.live_collapsed
        } else {
            todos.previous_expanded
        };
        let done = items
            .iter()
            .filter(|item| item.status == TodoStatus::Completed)
            .count();
        let total = items.len();
        let session_key = key.to_owned();
        let mut card = div()
            .flex_none()
            .w_full()
            .overflow_hidden()
            .rounded(px(5.))
            .border_1()
            .border_color(rgb(LINE))
            .bg(rgb(0xf8f9fb))
            .child(
                div()
                    .id("composer-todo-toggle")
                    .h(px(25.))
                    .px(px(9.))
                    .flex()
                    .items_center()
                    .gap(px(6.))
                    .text_size(px(11.5))
                    .text_color(rgb(MUTED))
                    .cursor_pointer()
                    .hover(|style| style.bg(rgb(0xeff2f8)))
                    .child(svg_symbol(
                        if expanded {
                            icons::CHEVRON_DOWN
                        } else {
                            icons::CHEVRON_RIGHT
                        },
                        12.,
                        MUTED,
                    ))
                    .child(svg_symbol(icons::LIST_DETAILS, 13., MUTED))
                    .child(format!(
                        "{} {done}/{total}",
                        if live {
                            tr("任务")
                        } else {
                            tr("以往任务")
                        }
                    ))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        if this.selected.as_deref() == Some(&session_key)
                            && let Some(session) = this.sessions.get_mut(&session_key)
                        {
                            if live {
                                session.todos.live_collapsed = !session.todos.live_collapsed;
                            } else {
                                session.todos.previous_expanded = !session.todos.previous_expanded;
                            }
                            if this.following {
                                this.sync_list();
                            }
                            cx.notify();
                        }
                    })),
            );
        if expanded {
            card = card.child(
                div()
                    .id(SharedString::from(format!("composer-todos-{key}")))
                    .max_h(px(155.))
                    .overflow_y_scroll()
                    .pb(px(4.))
                    .children(ordered_todos(items).into_iter().map(|(item, depth)| {
                        let badge = match item.status {
                            TodoStatus::Completed => svg_symbol(icons::TASK_CHECK, 13., 0x29a582),
                            TodoStatus::InProgress if live => todo_circle(ACCENT, true),
                            TodoStatus::Cancelled => svg_symbol(icons::TAB_CLOSE, 13., 0x9ca5af),
                            _ => todo_circle(0x9ca5af, false),
                        };
                        let tone = if live
                            && matches!(item.status, TodoStatus::InProgress | TodoStatus::Pending)
                        {
                            SECONDARY
                        } else {
                            MUTED
                        };
                        div()
                            .min_h(px(23.))
                            .pl(px(29. + 13. * depth.min(5) as f32))
                            .pr(px(11.))
                            .py(px(3.))
                            .flex()
                            .items_start()
                            .gap(px(6.))
                            .child(div().pt(px(1.)).child(badge))
                            .child(
                                div()
                                    .min_w_0()
                                    .text_size(px(11.5))
                                    .line_height(px(16.))
                                    .text_color(rgb(tone))
                                    .child(item.content.clone()),
                            )
                    })),
            );
        }
        Some(card)
    }

    pub(super) fn composer_status_grip(
        &self,
        session: String,
        collapsed: bool,
        queued: bool,
        cx: &mut Context<Self>,
    ) -> Div {
        let label = match (collapsed, queued) {
            (true, true) => tr("展开会话状态（有排队消息）"),
            (true, false) => tr("展开会话状态"),
            (false, _) => tr("收起会话状态"),
        };
        div()
            .absolute()
            .top(px(-7.))
            .left_0()
            .right_0()
            .flex()
            .justify_center()
            .child(
                Button::new("composer-status-grip")
                    .ghost()
                    .compact()
                    .w(px(40.))
                    .h(px(14.))
                    .p_0()
                    .cursor_pointer()
                    .tooltip(label)
                    .child(
                        div()
                            .relative()
                            .h(px(2.))
                            .w(px(27.))
                            .rounded_full()
                            .bg(rgb(0xa9afb6))
                            .when(collapsed && queued, |grip| {
                                grip.child(
                                    div()
                                        .absolute()
                                        .right(px(-8.))
                                        .top(px(-1.))
                                        .size(px(4.))
                                        .rounded_full()
                                        .bg(rgb(ACCENT)),
                                )
                            }),
                    )
                    .on_click(cx.listener(move |this, _, _, cx| {
                        if this.selected.as_deref() != Some(session.as_str()) {
                            return;
                        }
                        let hidden = &mut this.workspace_mut().collapsed_composer_status;
                        if !hidden.remove(&session) {
                            hidden.insert(session.clone());
                        }
                        this.schedule_save(cx);
                        cx.notify();
                    })),
            )
    }

    pub(super) fn composer_workspace_row(
        &self,
        branch: SharedString,
        cwd: SharedString,
        cx: &mut Context<Self>,
    ) -> Div {
        let has_branch = !branch.is_empty();
        let has_path = !cwd.is_empty();
        let branch_tip = if has_branch {
            crate::i18n::format_text!(
                "审查工作区变更 · {branch}",
                "Review workspace changes · {branch}"
            )
        } else {
            tr("浏览工作区文件").to_owned()
        };
        let path_tip = cwd.clone();
        let copy_path = cwd.clone();
        let menu_path = cwd.clone();
        let desktop = cx.entity().downgrade();
        div()
            .h(px(27.))
            .px(px(12.))
            .group("composer-workspace")
            .flex()
            .items_center()
            .gap(px(5.))
            .text_size(px(12.))
            .text_color(rgb(MUTED))
            .border_b_1()
            .border_color(rgb(0xe0e6ee))
            .child(
                Button::new("composer-review")
                    .ghost()
                    .compact()
                    .h(px(21.))
                    .px(px(2.))
                    .tooltip(branch_tip)
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap(px(7.))
                            .child(svg_symbol(
                                if has_branch {
                                    icons::BRANCH
                                } else {
                                    icons::FOLDER_OPEN
                                },
                                14.,
                                0x20876e,
                            ))
                            .when(has_branch, |button| {
                                button.child(div().max_w(px(149.)).truncate().child(branch))
                            }),
                    )
                    .on_click(cx.listener(move |this, _, window, cx| {
                        if has_branch {
                            this.open_review(window, cx);
                        } else {
                            this.open_files(window, cx);
                        }
                    })),
            )
            .when(has_path, |row| {
                row.child(
                    div()
                        .id("composer-workspace-path")
                        .min_w_0()
                        .max_w(px(360.))
                        .truncate()
                        .text_color(rgb(0x8d949c))
                        .font_family(CODE_FONT)
                        .text_size(px(11.))
                        .opacity(0.64)
                        .group_hover("composer-workspace", |style| style.opacity(1.))
                        .tooltip(move |window, cx| Tooltip::new(path_tip.clone()).build(window, cx))
                        .child(cwd),
                )
                .child(
                    icon_button("copy-composer-workspace", icons::COPY, tr("复制工作区路径"))
                        .size(px(19.))
                        .opacity(0.64)
                        .group_hover("composer-workspace", |style| style.opacity(1.))
                        .on_click(move |_, _, cx| {
                            cx.write_to_clipboard(ClipboardItem::new_string(copy_path.to_string()));
                        }),
                )
            })
            .child(div().flex_1())
            .child(
                Button::new("composer-workspace-menu")
                    .ghost()
                    .compact()
                    .size(px(21.))
                    .p_0()
                    .tooltip(tr("工作区操作"))
                    .child(svg_symbol(icons::DOTS_VERTICAL, 14., 0x979da5))
                    .dropdown_menu_with_anchor(Anchor::BottomRight, move |menu, _, _| {
                        let path = menu_path.clone();
                        menu.item(menu_item(
                            &desktop,
                            tr("审查工作区变更"),
                            icons::BRANCH,
                            has_branch,
                            |this, window, cx| this.open_review(window, cx),
                        ))
                        .item(menu_item(
                            &desktop,
                            tr("浏览工作区文件"),
                            icons::FOLDER_OPEN,
                            true,
                            |this, window, cx| this.open_files(window, cx),
                        ))
                        .item(menu_item(
                            &desktop,
                            tr("复制工作区路径"),
                            icons::COPY,
                            has_path,
                            move |_, _, cx| {
                                cx.write_to_clipboard(ClipboardItem::new_string(path.to_string()));
                            },
                        ))
                    }),
            )
    }
}

fn work_dot(color: u32) -> Div {
    div()
        .size(px(6.))
        .flex_none()
        .rounded_full()
        .border_1()
        .border_color(rgb(color))
}

fn work_status(label: &'static str, color: u32) -> Div {
    div()
        .flex_none()
        .text_size(px(10.5))
        .text_color(rgb(color))
        .child(label)
}

fn todo_circle(color: u32, filled: bool) -> Div {
    div()
        .size(px(13.))
        .flex_none()
        .flex()
        .items_center()
        .justify_center()
        .child(
            div()
                .size(px(9.))
                .rounded_full()
                .border_1()
                .border_color(rgb(color))
                .when(filled, |dot| dot.bg(rgb(color))),
        )
}
