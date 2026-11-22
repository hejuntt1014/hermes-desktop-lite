use crate::i18n::text as tr;

use std::{cell::Cell, ops::Range, rc::Rc};

use gpui::{Bounds, ListOffset, ListState, Pixels, Point, SharedString, Size, point, px};
use gpui_component::scroll::ScrollbarHandle;

use super::attachment_ops::display_file_refs;

use crate::session::{Row, Session, Tool, compact_preview};

impl super::Desktop {
    pub(super) fn apply_transcript_scrollbar(&mut self, cx: &mut gpui::Context<Self>) {
        let Some(end) = self.transcript_scrollbar.take_navigation() else {
            return;
        };
        let dragging = self.transcript_scrollbar.dragging();
        self.cancel_search_reveal();
        self.following = end && !dragging;
        self.pending_reading = None;
        self.pending_bookmark = None;
        self.turn_rail.jumped = None;
        if !dragging {
            self.reading_moved(cx);
            if self.list.logical_scroll_top().item_ix <= 3 {
                self.older_history(cx);
            }
        }
        self.sync_turn_rail();
    }
}

#[derive(Clone, PartialEq, Eq)]
pub(super) struct TimelineItem {
    pub rows: Range<usize>,
    pub receipt: Option<usize>,
}

pub(super) fn at_bottom(list: &gpui::ListState) -> bool {
    let top = list.logical_scroll_top().item_ix;
    let count = list.item_count();
    let viewport = list.viewport_bounds();
    // Unmeasured rows can make a pixel-based scrollbar report the end early.
    count > 0
        && viewport.size.height > gpui::px(0.)
        && (top..count).all(|ix| {
            list.bounds_for_item(ix)
                .is_some_and(|bounds| bounds.bottom() <= viewport.bottom() + gpui::px(1.))
        })
}

const ROW_STEP: f32 = 56.;

#[derive(Clone)]
pub(super) struct TranscriptScrollbar {
    list: ListState,
    drag: Rc<Cell<Option<Drag>>>,
    navigation: Rc<Cell<Option<bool>>>,
}

#[derive(Clone, Copy)]
struct Drag {
    count: usize,
    position: Pixels,
}

impl TranscriptScrollbar {
    pub(super) fn new(list: ListState) -> Self {
        Self {
            list,
            drag: Default::default(),
            navigation: Default::default(),
        }
    }

    pub(super) fn dragging(&self) -> bool {
        self.drag.get().is_some()
    }

    pub(super) fn reset(&self) {
        self.drag.set(None);
        self.navigation.set(None);
    }

    pub(super) fn has_navigation(&self) -> bool {
        self.navigation.get().is_some()
    }

    pub(super) fn take_navigation(&self) -> Option<bool> {
        self.navigation.take()
    }

    fn track_end(&self) -> Pixels {
        if let Some(drag) = self.drag.get() {
            return px(drag.count as f32 * ROW_STEP);
        }
        let count = self.list.item_count();
        let top = self.list.logical_scroll_top();
        if top.item_ix == 0 && top.offset_in_item == px(0.) && at_bottom(&self.list) {
            return px(0.);
        }
        px(count as f32 * ROW_STEP)
    }

    fn row_extent(&self, item: usize) -> Pixels {
        self.list
            .bounds_for_item(item)
            .map_or(px(ROW_STEP), |bounds| bounds.size.height)
            .max(px(1.))
    }
}

impl ScrollbarHandle for TranscriptScrollbar {
    fn viewport_bounds(&self) -> Bounds<Pixels> {
        self.list.viewport_bounds()
    }

    fn content_size(&self) -> Size<Pixels> {
        let mut size = self.viewport_bounds().size;
        size.height += self.track_end();
        size
    }

    fn offset(&self) -> Point<Pixels> {
        if let Some(drag) = self.drag.get() {
            return point(px(0.), -drag.position);
        }
        let max = self.track_end();
        let top = self.list.logical_scroll_top();
        let position = if at_bottom(&self.list) {
            max
        } else {
            let within = (top.offset_in_item / self.row_extent(top.item_ix)).clamp(0., 1.);
            px((top.item_ix as f32 + within) * ROW_STEP).min(max)
        };
        point(px(0.), -position)
    }

    fn set_offset(&self, offset: Point<Pixels>) {
        let max = self.track_end();
        let position = (-offset.y).clamp(px(0.), max);
        if let Some(mut drag) = self.drag.get() {
            if drag.position == position {
                return;
            }
            drag.position = position;
            self.drag.set(Some(drag));
        }
        let end = max > px(0.) && position >= max - px(0.5);
        if end {
            self.list.scroll_to_end();
        } else {
            // GPUI's pixel seek crosses a different number of rows as images and
            // offscreen messages are measured. The track uses logical row slots.
            let slot = f32::from(position) / ROW_STEP;
            let item_ix = slot.floor() as usize;
            self.list.scroll_to(ListOffset {
                item_ix,
                offset_in_item: self.row_extent(item_ix) * slot.fract(),
            });
        }
        self.navigation.set(Some(end));
    }

    fn start_drag(&self) {
        self.drag.set(Some(Drag {
            count: self.list.item_count(),
            position: -self.offset().y,
        }));
        self.navigation.set(Some(false));
    }

    fn end_drag(&self) {
        if let Some(drag) = self.drag.take() {
            self.navigation.set(Some(
                drag.position >= px(drag.count as f32 * ROW_STEP - 0.5),
            ));
        }
    }
}

pub(super) struct ScrollNavigation {
    pub following: bool,
    pub load_older: bool,
}

pub(super) fn wheel_navigation(
    list: &gpui::ListState,
    y: gpui::Pixels,
) -> Option<ScrollNavigation> {
    (y != gpui::px(0.)).then(|| ScrollNavigation {
        following: y < gpui::px(0.) && at_bottom(list),
        load_older: y > gpui::px(0.) && list.logical_scroll_top().item_ix <= 3,
    })
}

#[cfg(test)]
#[path = "timeline_scroll_tests.rs"]
mod scroll_tests;

pub(super) fn splice_older_page(
    list: &gpui::ListState,
    before: &[TimelineItem],
    after: &[TimelineItem],
    shift: usize,
) -> bool {
    // Tool groups can straddle the page boundary. Keep the suffix whose row
    // ranges moved together, including GPUI's measured heights and pixel anchor.
    let retained = before
        .iter()
        .rev()
        .zip(after.iter().rev())
        .take_while(|(old, new)| {
            old.receipt == new.receipt
                && old.rows.start + shift == new.rows.start
                && old.rows.end + shift == new.rows.end
        })
        .count();
    let removed = before.len() - retained;
    let inserted = after.len() - retained;
    let top = list.logical_scroll_top().item_ix;
    if removed != 0 || inserted != 0 {
        list.splice(0..removed, inserted);
    }
    (removed..before.len()).contains(&top)
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
