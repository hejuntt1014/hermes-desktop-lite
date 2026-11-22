use crate::{gateway::HistoryPage, i18n::text as tr};
use anyhow::{Context as _, Result, bail};
use gpui::{Context, Window};
use serde_json::Value;

use super::{
    Desktop,
    reading_position::{find_anchor, make_anchor},
};

#[derive(Default)]
pub(crate) struct HistoryWindow {
    resolved: String,
    rows: Vec<Value>,
    older_offset: Option<usize>,
}

fn same_record(a: &Value, b: &Value) -> bool {
    fn id(row: &Value) -> Option<u64> {
        row["row_id"].as_u64().or_else(|| row["id"].as_u64())
    }
    match (id(a), id(b)) {
        (Some(left), Some(right)) => left == right,
        _ => a == b,
    }
}

impl HistoryWindow {
    pub(super) fn matches_tail(&self, page: &HistoryPage) -> bool {
        match (self.rows.last(), page.rows.last()) {
            (Some(saved), Some(latest)) => {
                self.resolved == page.resolved && same_record(saved, latest)
                    && saved["content"].as_str().zip(latest["content"].as_str())
                        .is_none_or(|(before, after)| before == after)
                    && saved["finish_reason"] == latest["finish_reason"]
            }
            (None, None) => true,
            _ => false,
        }
    }

    fn merge(&mut self, mut page: HistoryPage, older: bool) -> Result<()> {
        // The latest-first REST offset can move when the server appends messages.
        // Request a one-row overlap and join only at the known boundary.
        if older {
            let overlap = self
                .rows
                .first()
                .and_then(|first| page.rows.iter().rposition(|row| same_record(first, row)));
            let Some(overlap) = overlap.filter(|_| page.resolved == self.resolved) else {
                bail!(tr("会话历史已更新，请重新读取"));
            };
            if overlap == 0 && page.next.is_some() {
                bail!(tr("会话历史已更新，请重新读取"));
            }
            page.rows.truncate(overlap);
            page.rows.append(&mut self.rows);
            self.rows = page.rows;
        } else {
            let prefix = if page.next.is_some() && page.resolved == self.resolved {
                page.rows
                    .first()
                    .and_then(|first| self.rows.iter().position(|row| same_record(first, row)))
            } else {
                None
            };
            let was_complete = self.older_offset.is_none() && prefix.is_some();
            self.rows.truncate(prefix.unwrap_or(0));
            self.rows.append(&mut page.rows);
            self.resolved = page.resolved;
            if was_complete {
                page.next = None;
            }
        }
        self.older_offset = page
            .next
            .map(|next| if older { next - 1 } else { self.rows.len() - 1 });
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn page(ids: std::ops::RangeInclusive<u64>, next: Option<usize>) -> HistoryPage {
        HistoryPage {
            resolved: "orders".into(),
            rows: ids
                .map(|id| json!({"id":id, "role":"user", "content":format!("order {id}")}))
                .collect(),
            next,
        }
    }

    #[test]
    fn scrolling_then_refreshing_a_long_chat_preserves_the_loaded_range() -> Result<()> {
        let mut loaded = HistoryWindow::default();
        loaded.merge(page(20_001..=20_080, Some(80)), false)?;
        assert_eq!(loaded.rows.len(), 80);
        assert_eq!(loaded.older_offset, Some(79));
        // Three new messages were written after the client fetched page one.
        loaded.merge(page(19_925..=20_004, Some(159)), true)?;
        assert_eq!(loaded.older_offset, Some(158));
        loaded.merge(page(20_004..=20_083, Some(80)), false)?;
        assert_eq!(loaded.rows, page(19_925..=20_083, None).rows);
        assert_eq!(loaded.older_offset, Some(158));
        Ok(())
    }

    #[test]
    fn a_rewind_or_rotation_cannot_splice_an_unrelated_page_into_history() -> Result<()> {
        let mut loaded = HistoryWindow::default();
        loaded.merge(page(81..=160, Some(80)), false)?;
        let mut rotated = page(2..=81, Some(159));
        rotated.resolved = "successor".into();
        assert!(loaded.merge(rotated, true).is_err());
        assert!(loaded.merge(page(1..=75, None), true).is_err());
        assert_eq!(loaded.rows, page(81..=160, None).rows);
        loaded.merge(page(60..=139, Some(80)), false)?;
        assert_eq!(loaded.rows, page(60..=139, None).rows);
        loaded.merge(page(1..=60, None), true)?;
        assert_eq!(loaded.rows, page(1..=139, None).rows);
        assert!(loaded.older_offset.is_none());
        Ok(())
    }

    #[tokio::test]
    async fn opens_and_scrolls_a_large_remote_transcript_one_page_at_a_time() -> Result<()> {
        use crate::{gateway::Gateway, settings::RemoteAuth};
        use tokio::{
            io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
            net::TcpListener,
        };

        let listener = TcpListener::bind("127.0.0.1:0").await?;
        let gateway = Gateway::new(
            &listener.local_addr()?.to_string(),
            RemoteAuth::Token,
            String::new(),
        )?;
        let serve = async {
            for (offset, total) in [(0usize, 20_080usize), (79, 20_083)] {
                let (socket, _) = listener.accept().await?;
                let mut socket = BufReader::new(socket);
                let mut line = String::new();
                socket.read_line(&mut line).await?;
                let target = line.split_whitespace().nth(1).unwrap();
                let url = gateway.url.join(target)?;
                assert_eq!(url.path(), "/api/sessions/orders/messages");
                let query: std::collections::HashMap<_, _> = url.query_pairs().collect();
                assert_eq!(query["profile"], "dingding");
                assert_eq!(query["order"], "latest");
                assert_eq!(query["limit"], "80");
                assert_eq!(query["offset"], offset.to_string());
                loop {
                    line.clear();
                    if socket.read_line(&mut line).await? == 0 || line == "\r\n" {
                        break;
                    }
                }
                let end = (total - offset) as u64;
                let body = json!({
                    "session_id":"orders", "profile":"dingding", "messages":page(end-79..=end,None).rows,
                    "pagination":{"limit":80,"offset":offset}
                }).to_string();
                let reply = format!(
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
                socket.get_mut().write_all(reply.as_bytes()).await?;
            }
            Ok::<_, anyhow::Error>(())
        };
        let read = async {
            let mut loaded = HistoryWindow::default();
            loaded.merge(
                gateway.recent_history_page("orders", "dingding", 0).await?,
                false,
            )?;
            assert_eq!(loaded.rows.len(), 80);
            let older = loaded.older_offset.unwrap();
            loaded.merge(
                gateway
                    .recent_history_page("orders", "dingding", older)
                    .await?,
                true,
            )?;
            assert_eq!(loaded.rows, page(19_925..=20_080, None).rows);
            Ok(())
        };
        tokio::time::timeout(std::time::Duration::from_secs(5), async {
            tokio::try_join!(serve, read)
        })
        .await??;
        Ok(())
    }
}

impl Desktop {
    pub(super) fn prefetch_history(&mut self, key: &str, cx: &mut Context<Self>) {
        if !self
            .sessions
            .get(key)
            .is_some_and(|s| s.awaiting_first_history || s.history_via_rest && s.history_error.is_none())
        {
            self.read_history_page(key, false, cx);
        }
    }

    pub(super) fn older_history(&mut self, cx: &mut Context<Self>) {
        if let Some(key) = self.selected.clone() {
            self.read_history_page(&key, true, cx);
        }
    }

    pub(super) fn read_history_page(&mut self, key: &str, older: bool, cx: &mut Context<Self>) {
        self.load_history_page(key, older, false, cx);
    }

    pub(super) fn refresh_changed_history(&mut self, key: &str, cx: &mut Context<Self>) {
        self.load_history_page(key, false, true, cx);
    }

    fn load_history_page(&mut self, key: &str, older: bool, background: bool, cx: &mut Context<Self>) {
        if self.history_reads.contains_key(key)
            || self
                .sessions
                .get(key)
                .is_some_and(|s| s.history_rest_unavailable)
        {
            return;
        }
        let Some(gateway) = self.gateway.clone() else {
            return;
        };
        let profile = self.session_profile_for_history(key);
        let receipts = self
            .workspace()
            .and_then(|w| w.command_receipts.get(&profile)?.get(key))
            .cloned()
            .unwrap_or_default();
        let session = self.sessions.entry(key.to_owned()).or_default();
        let offset = if older {
            let Some(offset) = session.history_window.older_offset else {
                return;
            };
            offset
        } else {
            0
        };
        session.command_receipts = receipts;
        session.profile.clone_from(&profile);
        session.history_error = None;
        let before = background.then(|| (session.runtime.clone(), session.seq, session.epoch.clone()));
        let id = key.to_owned();
        let read = self
            .runtime
            .spawn(async move { gateway.recent_history_page(&id, &profile, offset).await });
        let handle = self.window_handle;
        let id = key.to_owned();
        let job = cx.spawn(async move |view, cx| {
            let page = read.await.context(tr("无法读取会话历史")).and_then(|p| p);
            while view.update(cx, |this, _| {
                this.selected.as_deref() == Some(&id) && this.transcript_scrollbar.dragging()
            }).unwrap_or(false) {
                cx.background_executor().timer(std::time::Duration::from_millis(35)).await;
            }
            let _ = handle.update(cx, |_, window, app| {
                view.update(app, |this, cx| {
                    this.history_reads.remove(&id);
                    if let Some((runtime, seq, epoch)) = &before
                        && this.sessions.get(&id).is_none_or(|s| {
                            !s.attached || s.loading || s.running || s.submitting || s.uncertain
                                || &s.runtime != runtime || s.seq != *seq || &s.epoch != epoch
                        })
                    {
                        return;
                    }
                    if page
                        .as_ref()
                        .is_err_and(crate::gateway::missing_history_endpoint)
                    {
                        if let Some(session) = this.sessions.get_mut(&id) {
                            session.history_rest_unavailable = true;
                            if !session.loading {
                                this.attach(&id, true);
                            }
                        }
                        cx.notify();
                        return;
                    }
                    // A newly attached runtime may not have a stored row until its first turn.
                    if page.as_ref().is_err_and(crate::gateway::missing_stored_session)
                        && this.sessions.get(&id).is_some_and(|session| session.awaiting_first_history)
                    {
                        cx.notify();
                        return;
                    }
                    let result = page
                        .and_then(|page| this.display_history_page(&id, page, older, window, cx));
                    if let Err(error) = result
                        && !background
                        && let Some(session) = this.sessions.get_mut(&id)
                    {
                        session.history_error = Some(crate::i18n::format_text!(
                            "历史读取未完成 · {error}",
                            "History loading was interrupted · {error}"
                        ));
                    }
                    cx.notify();
                })
            });
        });
        self.history_reads.insert(key.to_owned(), job);
    }

    fn display_history_page(
        &mut self,
        key: &str,
        page: HistoryPage,
        older: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Result<()> {
        let selected = self.selected.as_deref() == Some(key);
        let position = selected.then(|| self.reading_position()).flatten();
        let Some(session) = self.sessions.get_mut(key) else {
            return Ok(());
        };
        let expanded = selected.then(|| {
            self.expanded
                .iter()
                .map(|&i| make_anchor(session, i))
                .collect::<Vec<_>>()
        });
        let groups = selected.then(|| {
            self.tool_history
                .groups
                .iter()
                .map(|&i| make_anchor(session, i))
                .collect::<Vec<_>>()
        });
        let old_row_count = session.count();
        let mut history = std::mem::take(&mut session.history_window);
        let merged = history.merge(page, older);
        if merged.is_ok() {
            session.replace_history(Some(&history.rows), None);
            session.awaiting_first_history = false;
            session.history_via_rest = true;
            session.history_partial = history.older_offset.is_some();
        }
        session.history_window = history;
        merged?;
        let inserted_rows = older
            .then(|| session.count().checked_sub(old_row_count))
            .flatten();
        if let (Some(expanded), Some(groups)) = (expanded, groups) {
            self.expanded = expanded
                .iter()
                .filter_map(|a| find_anchor(session, a))
                .collect();
            self.tool_history.groups = groups
                .iter()
                .filter_map(|a| find_anchor(session, a))
                .collect();
        }
        self.confirm_history_receipts(key, window, cx);
        if selected {
            self.timeline_raw_count = None;
            if inserted_rows.is_none() {
                self.list.remeasure_items(0..self.visible_count);
            }
            self.view_revision = self.view_revision.wrapping_add(1);
            self.turn_rail.jumped = None;
            self.sync_list_at(inserted_rows, position);
            if let Some(shift) = inserted_rows {
                self.shift_search_hits(shift);
            }
            self.transcript_changed(cx);
            if self.files.open && self.files.collection.open {
                self.show_session_files(cx);
            }
            if self.visible_count == 0
                || self
                    .pending_bookmark
                    .as_ref()
                    .is_some_and(|mark| mark.session == key)
                || self.pending_reading.is_some()
                || self.transcript_find.searching()
            {
                self.older_history(cx);
            }
        }
        Ok(())
    }

    pub(super) fn confirm_history_receipts(
        &mut self,
        key: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(workspace) = self.workspace() else {
            return;
        };
        let rows = &self.sessions[key].history_window.rows;
        let received = |id: &str| {
            rows.iter()
                .any(|row| row["submission_id"] == id || row["admission_id"] == id)
        };
        let admitted = workspace
            .pending_submissions
            .get(key)
            .is_some_and(|p| !p.staging && received(&p.id));
        let rewritten = workspace.pending_rewrites.get(key).is_some_and(|r| {
            r.phase == crate::settings::RewritePhase::Send && received(&r.request_id)
        });
        if rewritten {
            self.workspace_mut().pending_rewrites.remove(key);
            self.persist(cx);
        }
        if admitted {
            self.accept_draft(key, window, cx);
            self.sessions.get_mut(key).unwrap().uncertain = false;
        }
    }

    fn session_profile_for_history(&self, key: &str) -> String {
        self.rows
            .iter()
            .find(|row| row.id == key && !row.profile.is_empty())
            .map(|row| row.profile.clone())
            .or_else(|| {
                let workspace = self.workspace()?;
                workspace
                    .tabs
                    .iter()
                    .chain(&workspace.closed_tabs)
                    .find(|tab| tab.session.as_deref() == Some(key))
                    .map(|tab| self.tab_profile(tab).to_owned())
            })
            .or_else(|| {
                self.sessions
                    .get(key)
                    .map(|session| session.profile.clone())
            })
            .unwrap_or_default()
    }
}
