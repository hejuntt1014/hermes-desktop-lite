use crate::theme::{ink, rgb};

use crate::i18n::text as tr;

use std::{
    collections::{HashMap, HashSet},
    time::Duration,
};

use gpui::{
    AnyElement, App, ClipboardItem, Context, Div, Entity, SharedString, Stateful, div, prelude::*,
    px,
};
use serde_json::Value;
use uuid::Uuid;

use crate::{
    icons,
    session::{Row, Tool, compact_preview},
    style::{MESSAGE_INSET, MUTED, SCAFFOLD_INK},
};

use super::{
    Desktop,
    clarify::completed_questions,
    timeline::{ToolGroup, tool_group},
    view::{icon_button, svg_symbol},
};

#[derive(Clone)]
enum FetchState {
    Loading(Uuid),
    Empty,
    Failed(SharedString),
}

#[derive(Default)]
pub(super) struct ToolHistory {
    pub groups: HashSet<usize>,
    results: HashMap<(String, String), FetchState>,
}

pub(super) fn tool_run(
    start: usize,
    tools: Vec<Tool>,
    entity: &Entity<Desktop>,
    app: &App,
) -> AnyElement {
    let desktop = entity.read(app);
    let open = desktop.tool_history.groups.contains(&start);
    let pending = tools.iter().filter(|tool| !tool.done).count();
    let failed = tools.iter().filter(|tool| tool.failed).count();
    let group = tools.first().and_then(tool_group);
    let title = match (group, tools.first()) {
        (Some(ToolGroup::Commands), Some(first)) => {
            let first = command_preview(first);
            if first.is_empty() {
                ToolGroup::Commands.label(tools.len(), pending)
            } else {
                crate::i18n::format_text!(
                    "{} {} + {} 条命令",
                    "{} {} + {} more command(s)",
                    if pending == 0 {
                        tr("已运行")
                    } else {
                        tr("正在运行")
                    },
                    compact_preview(&first, 80),
                    tools.len() - 1
                )
            }
        }
        (Some(group), _) => group.label(tools.len(), pending),
        _ => crate::i18n::format_text!("{} 项工具活动", "{} tool action(s)", tools.len()),
    };
    let weak = entity.downgrade();
    let header = disclosure(
        ("tool-run", start),
        open,
        title.into(),
        match group {
            Some(ToolGroup::Commands) => icons::TERMINAL,
            Some(ToolGroup::Reading) => icons::FILE_TEXT,
            Some(ToolGroup::Search) => icons::SIDEBAR_SEARCH,
            _ => icons::LIST_DETAILS,
        },
    )
    .when(failed > 0, |row| {
        row.child(badge(
            crate::i18n::format_text!("{failed} 项失败", "{failed} failed"),
            true,
        ))
    })
    .on_click(move |_, _, app| {
        let _ = weak.update(app, |desktop, cx| {
            desktop.hold_transcript_row_position(start);
            if !desktop.tool_history.groups.remove(&start) {
                desktop.tool_history.groups.insert(start);
            }
            cx.notify();
        });
    });
    div()
        .w_full()
        .child(header)
        .when(open, |run| {
            run.child(
                div()
                    .ml_2()
                    .pl_2()
                    .border_l_1()
                    .border_color(rgb(0xe4e9ef))
                    .children(
                        tools
                            .into_iter()
                            .enumerate()
                            .map(|(offset, tool)| tool_row(start + offset, tool, entity, app)),
                    ),
            )
        })
        .into_any_element()
}

pub(super) fn tool_row(
    index: usize,
    tool: Tool,
    entity: &Entity<Desktop>,
    app: &App,
) -> AnyElement {
    if tool.name.as_ref() == "clarify"
        && tool.done
        && let Some(answers) = completed_questions(&tool.output)
    {
        return answers.into_any_element();
    }
    let desktop = entity.read(app);
    let open = desktop.expanded.contains(&index);
    let key = desktop.selected.as_deref().unwrap_or_default();
    let missing = open && tool.done && tool.output.is_empty() && !tool.id.is_empty();
    let fetch = if missing {
        desktop
            .tool_history
            .results
            .get(&(key.to_owned(), tool.id.clone()))
            .cloned()
    } else {
        None
    };
    let retry = matches!(fetch, Some(FetchState::Failed(_)));
    let show_fetch = missing && (retry || fetch.is_none());
    let title = tool_title(&tool);
    let icon = match tool_group(&tool) {
        Some(ToolGroup::Commands) => icons::TERMINAL,
        Some(ToolGroup::Reading) => icons::FILE_TEXT,
        Some(ToolGroup::Search) => icons::SIDEBAR_SEARCH,
        _ if tool.name.as_ref() == "vision_analyze" => icons::EYE,
        _ => icons::LIST_DETAILS,
    };
    let weak = entity.downgrade();
    let weak_retry = weak.clone();
    let id = tool.id.clone();
    let state = if tool.failed {
        Some(badge(tr("失败"), true))
    } else if !tool.done {
        Some(badge(tr("运行中"), false))
    } else {
        tool.duration.filter(|_| open).map(|seconds| {
            badge(
                crate::i18n::format_text!("{seconds:.1} 秒", "{seconds:.1} s"),
                false,
            )
        })
    };
    div()
        .id(("tool-entry", index))
        .w_full()
        .child(
            disclosure(("tool-call", index), open, title, icon)
                .children(state)
                .on_click(move |_, _, app| {
                    let _ = weak.update(app, |desktop, cx| {
                        desktop.hold_transcript_row_position(index);
                        if !desktop.expanded.remove(&index) {
                            desktop.expanded.insert(index);
                            desktop.load_tool_result(index, &id, false, cx);
                        }
                        cx.notify();
                    });
                }),
        )
        .when(open, |row| {
            let id = tool.id.clone();
            row.child(tool_details(tool, fetch).when(show_fetch, |details| {
                details.child(
                    div()
                        .id("read-tool-result")
                        .text_size(px(11.))
                        .text_color(ink(0x2459a9))
                        .cursor_pointer()
                        .px_2()
                        .py_1()
                        .child(if retry {
                            tr("重试读取结果")
                        } else {
                            tr("读取已保存结果")
                        })
                        .on_click(move |_, _, app| {
                            let _ = weak_retry.update(app, |this, cx| {
                                this.load_tool_result(index, &id, true, cx)
                            });
                        }),
                )
            }))
        })
        .into_any_element()
}

fn disclosure(
    id: (&'static str, usize),
    open: bool,
    title: SharedString,
    icon: &'static str,
) -> Stateful<Div> {
    div()
        .id(id)
        .group("tool-summary")
        .w_full()
        .h(px(20.))
        .flex()
        .items_center()
        .gap(px(6.))
        .px(px(MESSAGE_INSET))
        .rounded(px(3.))
        .text_size(px(12.))
        .line_height(px(16.))
        .text_color(ink(SCAFFOLD_INK))
        .cursor_pointer()
        .hover(|row| row.text_color(ink(MUTED)))
        .child(svg_symbol(icon, 13., SCAFFOLD_INK).flex_none())
        .child(div().min_w_0().truncate().child(title))
        .child(
            div()
                .flex_none()
                .when(!open, |chevron| {
                    chevron
                        .invisible()
                        .group_hover("tool-summary", |style| style.visible())
                })
                .child(svg_symbol(
                    if open {
                        icons::CHEVRON_DOWN
                    } else {
                        icons::CHEVRON_RIGHT
                    },
                    10.,
                    SCAFFOLD_INK,
                )),
        )
}

fn badge(value: impl Into<SharedString>, error: bool) -> Div {
    div()
        .flex_none()
        .text_size(px(10.))
        .text_color(ink(if error { 0xaf3e35 } else { MUTED }))
        .child(value.into())
}

fn tool_title(tool: &Tool) -> SharedString {
    let label = match tool.name.as_ref() {
        "terminal" | "execute_code" if tool.done => tr("已运行"),
        "terminal" | "execute_code" => tr("正在运行"),
        "skill_view" if tool.failed => tr("技能加载失败"),
        "skill_view" if tool.done => tr("已加载技能"),
        "skill_view" => tr("正在加载技能"),
        "vision_analyze" if tool.done => tr("已分析图片"),
        "vision_analyze" => tr("正在分析图片"),
        "read_file" if tool.done => tr("已读取文件"),
        "read_file" => tr("正在读取文件"),
        "list_files" if tool.done => tr("已查看目录"),
        "list_files" => tr("正在查看目录"),
        "file_search" | "search_files" if tool.done => tr("已搜索文件"),
        "file_search" | "search_files" => tr("正在搜索文件"),
        "web_search" if tool.done => tr("已搜索网页"),
        "web_search" => tr("正在搜索网页"),
        other => other,
    };
    if tool_group(tool) == Some(ToolGroup::Commands) {
        let command = command_preview(tool);
        if !command.is_empty() {
            return format!("{label} {command}").into();
        }
    }
    if tool.context.is_empty() || tool.name.as_ref() == "vision_analyze" {
        label.to_owned().into()
    } else {
        format!("{label} · {}", tool.context).into()
    }
}

fn command_preview(tool: &Tool) -> SharedString {
    if !tool.context.is_empty() {
        return compact_preview(&tool.context, 240);
    }
    serde_json::from_str::<Value>(&tool.args)
        .ok()
        .and_then(|args| {
            args["command"]
                .as_str()
                .or_else(|| args["code"].as_str())
                .map(|text| compact_preview(text, 240))
        })
        .unwrap_or_default()
}

fn tool_details(tool: Tool, fetch: Option<FetchState>) -> Div {
    let params: Option<Value> = serde_json::from_str(&tool.args).ok();
    let param_body = match tool.name.as_ref() {
        "terminal" | "execute_code" => params
            .as_ref()
            .and_then(|data| data["command"].as_str().or_else(|| data["code"].as_str()))
            .map(|command| format!("$ {command}").into())
            .unwrap_or_else(|| tool.args.clone()),
        _ => tool.args.clone(),
    };
    let result: Option<Value> = (tool.output.len() <= 256 * 1024)
        .then(|| serde_json::from_str(&tool.output).ok())
        .flatten();
    let exit = result.as_ref().and_then(|data| data["exit_code"].as_i64());
    let output = result
        .as_ref()
        .and_then(|data| {
            matches!(tool.name.as_ref(), "terminal" | "execute_code").then_some(())?;
            let stdout = data["output"]
                .as_str()
                .or_else(|| data["stdout"].as_str())
                .unwrap_or_default();
            let stderr = data["stderr"].as_str().unwrap_or_default();
            if stdout.is_empty() && stderr.is_empty() {
                return None;
            }
            Some(
                if stderr.is_empty() {
                    stdout.to_owned()
                } else if stdout.is_empty() {
                    stderr.to_owned()
                } else {
                    crate::i18n::format_text!(
                        "{stdout}\n\n标准错误\n{stderr}",
                        "{stdout}\n\nStandard error\n{stderr}"
                    )
                }
                .into(),
            )
        })
        .unwrap_or_else(|| tool.output.clone());
    let pending = match fetch {
        Some(FetchState::Loading(_)) => Some(tr("正在读取工具结果…").into()),
        Some(FetchState::Empty) => Some(tr("历史记录没有返回工具结果").into()),
        Some(FetchState::Failed(error)) => Some(error),
        None => None,
    };
    div()
        .ml_4()
        .mt_1()
        .mb_1()
        .border_1()
        .border_color(rgb(0xe2e8f0))
        .rounded(px(4.))
        .bg(rgb(0xf8fafd))
        .overflow_hidden()
        .flex()
        .flex_col()
        .when(!tool.args.is_empty(), |card| {
            card.child(tool_section(
                tr("参数"),
                "copy-args",
                param_body,
                tool.args,
                None,
            ))
        })
        .when(!tool.diff.is_empty(), |card| {
            card.child(tool_section(
                tr("变更"),
                "copy-diff",
                tool.diff.clone(),
                tool.diff,
                None,
            ))
        })
        .when(!tool.output.is_empty(), |card| {
            card.child(tool_section(
                tr("结果"),
                "copy-result",
                output,
                tool.output,
                exit,
            ))
        })
        .children(pending.map(|text| {
            div()
                .px_2()
                .py_1()
                .text_size(px(11.))
                .text_color(ink(0x637286))
                .child(text)
        }))
}

fn tool_section(
    label: &'static str,
    copy_id: &'static str,
    display: SharedString,
    raw: SharedString,
    exit: Option<i64>,
) -> Div {
    const VISIBLE_BYTES: usize = 24_000;
    let shown = if display.len() > VISIBLE_BYTES {
        format!(
            "{}\n…",
            &display[..display.floor_char_boundary(VISIBLE_BYTES)]
        )
        .into()
    } else {
        display
    };
    div()
        .w_full()
        .child(
            div()
                .flex()
                .items_center()
                .gap_2()
                .px_2()
                .h(px(23.))
                .bg(rgb(0xf0f4f9))
                .text_size(px(10.))
                .text_color(ink(0x687589))
                .child(div().flex_1().child(label))
                .children(exit.map(|code| badge(format!("exit {code}"), code != 0)))
                .child(
                    icon_button(copy_id, crate::icons::COPY, tr("复制完整内容"))
                        .size(px(20.))
                        .on_click(move |_, _, app| {
                            app.write_to_clipboard(ClipboardItem::new_string(raw.to_string()))
                        }),
                ),
        )
        .child(
            div()
                .id(label)
                .max_h(px(160.))
                .overflow_scroll()
                .px_2()
                .py_1()
                .font_family(crate::theme::code_family())
                .text_size(px(12.))
                .line_height(px(18.))
                .text_color(ink(0x354153))
                .child(shown),
        )
}

impl Desktop {
    pub(super) fn hold_transcript_row_position(&mut self, row: usize) {
        self.following = false;
        if self.list.logical_scroll_top().item_ix >= self.visible_count
            && let Some(item_ix) = self.visible_item_for(row)
        {
            self.list.scroll_to(gpui::ListOffset {
                item_ix,
                offset_in_item: px(0.),
            });
        }
    }

    fn load_tool_result(&mut self, index: usize, id: &str, retry: bool, cx: &mut Context<Self>) {
        let (Some(session), Some(gateway)) = (self.selected.clone(), self.gateway.clone()) else {
            return;
        };
        let Some(Row::Tool(tool)) = self
            .sessions
            .get(&session)
            .and_then(|session| session.row(index))
        else {
            return;
        };
        if tool.id != id || id.is_empty() || !tool.done || !tool.output.is_empty() {
            return;
        }
        let profile = self.sessions[&session].profile.clone();
        let key = (session, id.to_owned());
        if self
            .tool_history
            .results
            .get(&key)
            .is_some_and(|state| !retry || !matches!(state, FetchState::Failed(_)))
        {
            return;
        }
        let request = Uuid::new_v4();
        self.tool_history
            .results
            .insert(key.clone(), FetchState::Loading(request));
        let fetch = self.runtime.spawn({
            let (session, id) = key.clone();
            async move {
                tokio::time::timeout(
                    Duration::from_secs(45),
                    gateway.stored_tool_result(&session, &profile, &id),
                )
                .await
            }
        });
        cx.spawn(async move |view, cx| {
            let result = fetch.await;
            let _ = view.update(cx, |desktop, cx| {
                if !matches!(desktop.tool_history.results.get(&key), Some(FetchState::Loading(current)) if *current == request) {
                    return;
                }
                match result {
                    Ok(Ok(Ok(Some(output)))) => {
                        desktop.tool_history.results.remove(&key);
                        if let Some(session) = desktop.sessions.get_mut(&key.0) {
                            session.store_tool_result(&key.1, output);
                        }
                    }
                    Ok(Ok(Ok(None))) => {
                        desktop.tool_history.results.insert(key, FetchState::Empty);
                    }
                    Ok(Ok(Err(error))) => {
                        desktop.tool_history.results.insert(key, FetchState::Failed(error.to_string().into()));
                    }
                    _ => {
                        desktop.tool_history.results.insert(key, FetchState::Failed(tr("读取工具结果超时").into()));
                    }
                }
                cx.notify();
            });
        }).detach();
        cx.notify();
    }
}
