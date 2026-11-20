use crate::i18n::text as tr;

use std::ops::Range;

use gpui::SharedString;

use super::attachment_ops::display_file_refs;

use crate::session::{Row, Session, Tool, compact_preview};

#[derive(Clone, PartialEq, Eq)]
pub(super) struct TimelineItem {
    pub rows: Range<usize>,
    pub receipt: Option<usize>,
}

#[derive(Clone)]
pub(super) struct TurnMarker {
    pub item: usize,
    pub preview: SharedString,
}

pub(super) fn project(
    session: &Session,
    hide_reasoning: bool,
) -> (Vec<TimelineItem>, Vec<TurnMarker>, Vec<usize>) {
    let mut items: Vec<TimelineItem> = Vec::with_capacity(session.count());
    let mut turns = Vec::new();
    let mut message_items = Vec::new();
    let mut previous_group = None;
    let mut notes = receipt_positions(session).into_iter().peekable();
    for (index, row) in session.rows.iter().chain(&session.live).enumerate() {
        while let Some((at, receipt)) = notes.next_if(|(at, _)| *at == index) {
            items.push(TimelineItem {
                rows: at..at,
                receipt: Some(receipt),
            });
            previous_group = None;
        }
        if hide_reasoning && matches!(row, Row::Reasoning(_)) {
            previous_group = None;
            continue;
        }
        if let Row::User(message) = row {
            let (files, caption) = display_file_refs(message.display());
            let preview = compact_preview(caption, 110);
            let preview = if !preview.is_empty() {
                preview
            } else if let Some(image) = message.images().first() {
                image.name.clone()
            } else {
                files
                    .first()
                    .cloned()
                    .unwrap_or_else(|| tr("用户消息").into())
            };
            turns.push(TurnMarker {
                item: items.len(),
                preview,
            });
        }
        if matches!(
            row,
            Row::User(_) | Row::Answer(_) | Row::Notice(_) | Row::Background(_)
        ) {
            message_items.push(items.len());
        }
        let group = match row {
            Row::Tool(tool) => tool_group(tool),
            _ => None,
        };
        if group.is_some()
            && group == previous_group
            && let Some(item) = items.last_mut()
        {
            item.rows.end = index + 1;
        } else {
            items.push(TimelineItem {
                rows: index..index + 1,
                receipt: None,
            });
        }
        previous_group = group;
    }
    let buffered = session.rows.len() + session.live.len();
    for (at, receipt) in notes {
        items.push(TimelineItem {
            rows: at..at,
            receipt: Some(receipt),
        });
    }
    let start = buffered + usize::from(hide_reasoning && session.has_streaming_reasoning());
    for index in start..session.count() {
        if matches!(session.row(index), Some(Row::Answer(_))) {
            message_items.push(items.len());
        }
        items.push(TimelineItem {
            rows: index..index + 1,
            receipt: None,
        });
    }
    (items, turns, message_items)
}

fn receipt_positions(session: &Session) -> Vec<(usize, usize)> {
    if session.command_receipts.is_empty() {
        return Vec::new();
    }
    let anchors: std::collections::HashMap<_, _> = session
        .rows
        .iter()
        .enumerate()
        .filter_map(|(index, row)| session.display_row_id(index, row).map(|id| (id, index + 1)))
        .collect();
    let mut notes: Vec<_> = session
        .command_receipts
        .iter()
        .enumerate()
        .filter_map(|(index, note)| {
            let boundary = match note.after {
                Some(id) => *anchors.get(&id)?,
                None => 0,
            };
            Some((boundary, index))
        })
        .collect();
    notes.sort_unstable();
    notes
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum ToolGroup {
    Commands,
    Reading,
    Search,
}

pub(super) fn tool_group(tool: &Tool) -> Option<ToolGroup> {
    match tool.name.as_ref() {
        "terminal" | "execute_code" => Some(ToolGroup::Commands),
        "read_file" | "list_files" | "file_search" => Some(ToolGroup::Reading),
        "web_search" | "web_extract" => Some(ToolGroup::Search),
        _ => None,
    }
}

impl ToolGroup {
    pub(super) fn label(self, total: usize, pending: usize) -> String {
        match (self, pending > 0) {
            (Self::Commands, false) => {
                crate::i18n::format_text!("执行了 {total} 条命令", "Ran {total} command(s)")
            }
            (Self::Commands, true) => crate::i18n::format_text!(
                "正在执行命令 · {pending} / {total}",
                "Running commands · {pending} / {total}"
            ),
            (Self::Reading, false) => crate::i18n::format_text!(
                "查看了 {total} 项文件记录",
                "Viewed {total} file record(s)"
            ),
            (Self::Reading, true) => crate::i18n::format_text!(
                "正在查看文件 · {pending} / {total}",
                "Viewing files · {pending} / {total}"
            ),
            (Self::Search, false) => {
                crate::i18n::format_text!("完成了 {total} 项搜索", "Completed {total} search(es)")
            }
            (Self::Search, true) => crate::i18n::format_text!(
                "正在搜索 · {pending} / {total}",
                "Searching · {pending} / {total}"
            ),
        }
    }
}
