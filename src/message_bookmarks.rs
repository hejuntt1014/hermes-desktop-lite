use super::{
    Desktop,
    reading_position::{find_anchor, make_anchor},
};
use crate::{
    session::{Summary, compact_preview},
    settings::MessageBookmark,
};
use gpui::{Context, ListOffset, Window, px};

impl Desktop {
    pub(super) fn bookmark_for(&self, row: usize, text: &str) -> Option<MessageBookmark> {
        let key = self.selected.as_ref()?;
        let session = self.sessions.get(key)?;
        let tab = self
            .workspace()?
            .tabs
            .iter()
            .find(|t| t.session.as_ref() == Some(key))?;
        let anchor = make_anchor(session, row);
        anchor.signature?;
        Some(MessageBookmark {
            session: key.clone(),
            profile: self.tab_profile(tab).to_owned(),
            title: tab.title.clone(),
            excerpt: compact_preview(text, 180).to_string(),
            anchor,
        })
    }

    pub(super) fn toggle_bookmark(&mut self, mark: MessageBookmark, cx: &mut Context<Self>) {
        let saved = &mut self.workspace_mut().bookmarks;
        if let Some(i) = saved.iter().position(|other| same_message(other, &mark)) {
            saved.remove(i);
        } else {
            saved.push(mark);
        }
        self.persist(cx);
        cx.notify();
    }

    pub(super) fn visit_bookmark(
        &mut self,
        mark: MessageBookmark,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let summary = Summary::from_wire(
            &serde_json::json!({"id":mark.session, "title":mark.title,"profile":mark.profile}),
        )
        .unwrap();
        self.open_session(&summary, true, window, cx);
        self.pending_bookmark = Some(mark);
        self.restore_bookmark();
        cx.notify();
    }

    pub(super) fn restore_bookmark(&mut self) {
        let Some(mark) = self.pending_bookmark.as_ref() else {
            return;
        };
        let Some(s) = self.sessions.get(&mark.session) else {
            return;
        };
        if self.selected.as_ref() != Some(&mark.session)
            || s.history_partial
            || s.loading
            || self.history_reads.contains_key(&mark.session)
        {
            return;
        }
        let index = find_anchor(s, &mark.anchor);
        self.pending_bookmark = None;
        if let Some(row) = index {
            self.jump_message(row);
        } else {
            self.banner = Some("这条收藏的消息已不在当前会话记录中".into());
        }
    }

    pub(super) fn jump_message(&mut self, row: usize) {
        if let Some(item_ix) = self.visible_item_for(row) {
            self.pending_reading = None;
            self.following = false;
            self.list.scroll_to(ListOffset {
                item_ix,
                offset_in_item: px(0.),
            });
        }
    }
}

pub(super) fn same_message(a: &MessageBookmark, b: &MessageBookmark) -> bool {
    a.session == b.session
        && a.profile == b.profile
        && match (a.anchor.stored_id, b.anchor.stored_id) {
            (Some(x), Some(y)) => x == y,
            _ => a.anchor.row == b.anchor.row && a.anchor.signature == b.anchor.signature,
        }
}
