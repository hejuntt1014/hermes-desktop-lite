use gpui::{Context, ListOffset, px};
use sha2::{Digest, Sha256};

use crate::{
    session::{Row, Session},
    settings::{ReadingAnchor, ReadingPosition},
};

use super::Desktop;

impl Desktop {
    pub(super) fn reading_position(&self) -> Option<ReadingPosition> {
        if self.following || self.pending_reading.is_some() || self.timeline.is_empty() {
            return None;
        }
        let session = self
            .selected
            .as_ref()
            .and_then(|key| self.sessions.get(key))?;
        let cursor = self.list.logical_scroll_top();
        let item = cursor.item_ix.min(self.timeline.len() - 1);
        let row = self.timeline[item]
            .rows
            .start
            .min(session.count().saturating_sub(1));
        let turn = self
            .turns
            .partition_point(|turn| turn.item <= item)
            .checked_sub(1)
            .and_then(|index| self.turns.get(index))
            .and_then(|turn| self.timeline.get(turn.item))
            .map(|item| make_anchor(session, item.rows.start))
            .filter(|turn| turn.row != row);
        let offset = f32::from(cursor.offset_in_item).max(0.);
        Some(ReadingPosition {
            anchor: make_anchor(session, row),
            turn,
            offset,
        })
    }

    pub(super) fn remember_reading(&mut self) -> bool {
        let Some(key) = self.selected.clone() else {
            return false;
        };
        if self.pending_reading.is_some() || self.timeline.is_empty() {
            return false;
        }
        let position = self.reading_position();
        let positions = &mut self.workspace_mut().reading_positions;
        match position {
            Some(position) if positions.get(&key) != Some(&position) => {
                positions.insert(key, position);
                true
            }
            None => positions.remove(&key).is_some(),
            _ => false,
        }
    }

    pub(super) fn reading_moved(&mut self, cx: &mut Context<Self>) {
        self.cancel_search_reveal();
        self.pending_reading = None;
        self.pending_bookmark = None;
        if self.remember_reading() {
            self.schedule_save(cx);
        }
    }

    pub(super) fn stage_reading_restore(&mut self) {
        self.pending_reading = self
            .selected
            .as_ref()
            .and_then(|key| self.workspace()?.reading_positions.get(key).cloned());
        if self.pending_reading.is_some() {
            self.following = false;
        }
    }

    pub(super) fn apply_reading_restore(&mut self) {
        if self.timeline.is_empty() {
            return;
        }
        let (Some(position), Some(session)) = (
            self.pending_reading.take(),
            self.selected
                .as_ref()
                .and_then(|key| self.sessions.get(key)),
        ) else {
            return;
        };
        let exact = find_anchor(session, &position.anchor);
        if exact.is_none() && session.history_partial {
            self.pending_reading = Some(position);
            return;
        }
        let fallback = || {
            position
                .turn
                .as_ref()
                .and_then(|turn| find_anchor(session, turn))
        };
        let row = exact.or_else(fallback).unwrap_or(position.anchor.row);
        if let Some(item_ix) = self.visible_item_for(row) {
            let offset = if exact.is_some() && position.offset.is_finite() {
                position.offset.max(0.)
            } else {
                0.
            };
            self.list.scroll_to(ListOffset {
                item_ix,
                offset_in_item: px(offset),
            });
        } else {
            let item_ix = self
                .timeline
                .partition_point(|item| item.rows.end <= row)
                .min(self.timeline.len() - 1);
            self.list.scroll_to(ListOffset {
                item_ix,
                offset_in_item: px(0.),
            });
        }
        self.following = false;
    }
}

fn row_ref(session: &Session, index: usize) -> Option<&Row> {
    if index < session.rows.len() {
        session.rows.get(index)
    } else {
        session.live.get(index - session.rows.len())
    }
}

pub(super) fn make_anchor(session: &Session, row: usize) -> ReadingAnchor {
    ReadingAnchor {
        row,
        stored_id: stored_id(session, row),
        signature: row_ref(session, row).map(signature),
    }
}

fn stored_id(session: &Session, row: usize) -> Option<u64> {
    match row_ref(session, row)? {
        Row::User(_) => session.user_row_ids.get(&row).copied(),
        Row::Answer(answer) => answer.stored_id,
        _ => None,
    }
}

pub(super) fn find_anchor(session: &Session, anchor: &ReadingAnchor) -> Option<usize> {
    let count = session.rows.len() + session.live.len();
    if let Some(id) = anchor.stored_id {
        if stored_id(session, anchor.row) == Some(id) {
            return Some(anchor.row);
        }
        if let Some(row) = (0..count).find(|row| stored_id(session, *row) == Some(id)) {
            return Some(row);
        }
    }
    let target = anchor.signature?;
    if row_ref(session, anchor.row).is_some_and(|row| signature(row) == target) {
        return Some(anchor.row);
    }
    (0..count)
        .filter(|index| row_ref(session, *index).is_some_and(|row| signature(row) == target))
        .min_by_key(|index| index.abs_diff(anchor.row))
}

fn signature(row: &Row) -> [u8; 12] {
    let (kind, primary, extra) = match row {
        Row::User(message) => (0, message.raw().as_ref(), ""),
        Row::Answer(answer) => (1, answer.body.raw().as_ref(), ""),
        Row::Reasoning(body) => (2, body.as_ref(), ""),
        Row::Tool(tool) if !tool.id.is_empty() => (3, tool.id.as_str(), ""),
        Row::Tool(tool) => (3, tool.name.as_ref(), tool.args.as_ref()),
        Row::Notice(body) => (4, body.as_ref(), ""),
        Row::Background(notice) => (0, notice.raw.as_ref(), ""),
        Row::Command(receipt) => (5, receipt.command.as_str(), receipt.output.as_str()),
    };
    let mut hash = Sha256::new();
    hash.update([kind]);
    for value in [primary, extra] {
        let bytes = value.as_bytes();
        let prefix = bytes.len().min(384);
        let suffix = bytes.len().saturating_sub(96).max(prefix);
        hash.update((bytes.len() as u64).to_le_bytes());
        hash.update(&bytes[..prefix]);
        hash.update(&bytes[suffix..]);
    }
    let digest = hash.finalize();
    let mut compact = [0; 12];
    compact.copy_from_slice(&digest[..12]);
    compact
}
