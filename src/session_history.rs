use crate::i18n::text as tr;

use std::collections::HashSet;

use anyhow::{Context as _, Result, bail};
use gpui::Context;
use serde_json::Value;

use super::Desktop;

impl Desktop {
    pub(super) fn prefetch_history(&mut self, key: &str, cx: &mut Context<Self>) {
        if self.history_reads.contains_key(key)
            || self.sessions.get(key).is_some_and(|session| {
                (session.attached || !session.rows.is_empty()) && session.history_error.is_none()
            })
        {
            return;
        }
        let Some(gateway) = self.gateway.clone() else {
            return;
        };
        let profile = self.session_profile_for_history(key);
        let receipts = self
            .workspace()
            .and_then(|workspace| workspace.command_receipts.get(&profile)?.get(key))
            .cloned()
            .unwrap_or_default();
        let session = self.sessions.entry(key.to_owned()).or_default();
        session.profile.clone_from(&profile);
        session.command_receipts = receipts;
        session.history_error = None;

        let key = key.to_owned();
        let runtime = self.runtime.clone();
        self.history_reads.insert(
            key.clone(),
            cx.spawn(async move |desktop, cx| {
                let mut offset = 0;
                let mut resolved = None;
                let mut last_row = None;
                let mut seen_rows = HashSet::new();
                let mut pages = Vec::new();
                let result: Result<()> = async {
                    loop {
                        let gateway = gateway.clone();
                        let id = key.clone();
                        let profile = profile.clone();
                        let mut page = runtime
                            .spawn(async move {
                                gateway.recent_history_page(&id, &profile, offset).await
                            })
                            .await
                            .context(tr("无法读取会话历史"))??;
                        if resolved.as_ref().is_some_and(|id| id != &page.resolved) {
                            bail!(tr("会话在读取历史期间切换了续接记录"));
                        }
                        resolved.get_or_insert(page.resolved);
                        if offset == 0 {
                            last_row = page.rows.iter().filter_map(history_row_id).max();
                        }
                        page.rows.retain(|row| {
                            history_row_id(row).is_none_or(|id| {
                                last_row.is_none_or(|last| id <= last) && seen_rows.insert(id)
                            })
                        });
                        if offset > 0 && page.rows.is_empty() && page.next.is_some() {
                            bail!(tr("网关重复返回同一页历史"));
                        }
                        if offset == 0 {
                            let displayed = desktop.update(cx, |this, cx| {
                                this.display_history(&key, &page.rows, page.next.is_none(), cx);
                            });
                            if displayed.is_err() {
                                return Ok(());
                            }
                            if page.next.is_none() {
                                break;
                            }
                        }
                        pages.push(page.rows);
                        if let Some(next) = page.next {
                            offset = next;
                        } else {
                            let rows = pages.into_iter().rev().flatten().collect();
                            let _ = desktop
                                .update(cx, |this, cx| this.display_history(&key, &rows, true, cx));
                            break;
                        }
                    }
                    Ok(())
                }
                .await;
                let _ = desktop.update(cx, |this, cx| {
                    this.history_reads.remove(&key);
                    this.restore_bookmark();
                    if let Err(error) = result
                        && let Some(session) = this.sessions.get_mut(&key)
                    {
                        session.history_error = Some(crate::i18n::format_text!(
                            "历史读取未完成 · {error}",
                            "History loading was interrupted · {error}"
                        ));
                    }
                    cx.notify();
                });
            }),
        );
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

    fn display_history(
        &mut self,
        key: &str,
        rows: &Vec<Value>,
        complete: bool,
        cx: &mut Context<Self>,
    ) {
        let selected = self.selected.as_deref() == Some(key);
        if selected && self.pending_reading.is_none() {
            self.pending_reading = self.reading_position();
        }
        let Some(session) = self.sessions.get_mut(key) else {
            return;
        };
        session.replace_history(Some(rows), None);
        session.history_via_rest = true;
        session.history_partial = !complete;
        if selected {
            self.timeline_raw_count = None;
            self.sync_list();
            self.transcript_changed(cx);
            if self.files.open && self.files.collection.open {
                self.show_session_files(cx)
            }
        }
        cx.notify();
    }
}

fn history_row_id(row: &Value) -> Option<u64> {
    row["row_id"].as_u64().or_else(|| row["id"].as_u64())
}
