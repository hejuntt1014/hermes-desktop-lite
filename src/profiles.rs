use crate::i18n::text as tr;

use std::collections::HashMap;

use gpui::{Context, ListOffset, SharedString, Task, Window};
use serde_json::Value;

use crate::{
    session::{Summary, string},
    settings::{ChatTab, ModelChoice},
};

use super::Desktop;

#[derive(Clone)]
pub(super) struct Profile {
    pub name: String,
    pub label: SharedString,
    pub model: Option<ModelChoice>,
    pub path: SharedString,
    pub is_default: bool,
    pub has_env: bool,
    pub skill_count: Option<u64>,
}

#[derive(Clone, Default, PartialEq, Eq)]
pub(super) struct ListScope {
    pub profile: String,
    pub archived: bool,
    pub query: String,
}

#[derive(Default)]
struct CachedPage {
    rows: Vec<Summary>,
    next: Option<usize>,
    scroll: Option<ListOffset>,
    ready: bool,
}

#[derive(Default)]
pub(super) struct Profiles {
    pub entries: Vec<Profile>,
    pub serving: String,
    pub scope: ListScope,
    pub ready: bool,
    pub last_tabs: HashMap<String, String>,
    pages: HashMap<(String, bool), CachedPage>,
    job: Option<Task<()>>,
}

impl Desktop {
    pub(super) fn active_profile(&self) -> &str {
        self.workspace()
            .and_then(|workspace| {
                let id = workspace.active_tab.as_ref()?;
                workspace.tabs.iter().find(|tab| &tab.id == id)
            })
            .map(|tab| self.tab_profile(tab))
            .unwrap_or(&self.profiles.serving)
    }

    pub(super) fn tab_profile<'a>(&'a self, tab: &'a ChatTab) -> &'a str {
        if tab.profile.is_empty() {
            &self.profiles.serving
        } else {
            &tab.profile
        }
    }

    pub(super) fn profile_label(&self, name: &str) -> SharedString {
        self.profiles
            .entries
            .iter()
            .find(|profile| profile.name == name)
            .map(|profile| profile.label.clone())
            .unwrap_or_else(|| {
                if name.is_empty() {
                    tr("默认").into()
                } else {
                    name.to_owned().into()
                }
            })
    }

    pub(super) fn profile_model(&self, name: &str) -> Option<ModelChoice> {
        self.profiles
            .entries
            .iter()
            .find(|profile| profile.name == name)?
            .model
            .clone()
    }

    pub(super) fn profile_summary(&self, profile: &str, id: &str) -> Option<&Summary> {
        self.rows
            .iter()
            .find(|row| row.profile == profile && row.id == id)
            .or_else(|| {
                self.profiles
                    .pages
                    .iter()
                    .filter(|((owner, _), _)| owner == profile)
                    .find_map(|(_, page)| page.rows.iter().find(|row| row.id == id))
            })
    }

    pub(super) fn load_profiles(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(gateway) = self.gateway.clone() else {
            return;
        };
        self.profile_editor.roster_failed = false;
        let runtime = self.runtime.clone();
        self.profiles.job = Some(cx.spawn_in(window, async move |view, cx| {
            let roster = runtime
                .spawn(async move {
                    tokio::join!(
                        gateway.api(reqwest::Method::GET, "api/profiles", &[], None),
                        gateway.api(reqwest::Method::GET, "api/profiles/active", &[], None),
                    )
                })
                .await;
            let Ok((Ok(roster), status)) = roster.as_ref() else {
                let _ = view.update_in(cx, |this, _, cx| {
                    this.profile_editor.roster_failed = true;
                    cx.notify();
                });
                return;
            };
            let Some(rows) = roster["profiles"].as_array() else {
                let _ = view.update_in(cx, |this, _, cx| {
                    this.profile_editor.roster_failed = true;
                    cx.notify();
                });
                return;
            };
            let serving = status
                .as_ref()
                .ok()
                .map(|status| string(status, "current"))
                .filter(|name| rows.iter().any(|row| row["name"] == *name))
                .or_else(|| {
                    rows.iter()
                        .find(|row| row["is_default"] == true)
                        .map(|row| string(row, "name"))
                })
                .or_else(|| rows.first().map(|row| string(row, "name")))
                .unwrap_or_default()
                .to_owned();
            let mut entries: Vec<_> = rows.iter().filter_map(profile_entry).collect();
            entries.sort_by(|left, right| {
                (left.name != serving, &left.name).cmp(&(right.name != serving, &right.name))
            });
            let _ = view.update_in(cx, |this, window, cx| {
                this.profiles.entries = entries;
                let serving_changed = this.profiles.serving != serving;
                this.profiles.serving = serving;
                this.sync_profile_editor(window, cx);
                this.sync_tab_sidebar(window, cx);
                if serving_changed {
                    this.refresh_busy_input(cx);
                }
                if serving_changed
                    && this.workspace().is_some_and(|workspace| {
                        workspace
                            .tabs
                            .iter()
                            .any(|tab| tab.profile.is_empty() && tab.session.is_some())
                    })
                {
                    this.refresh_unread_sessions(this.profiles.serving.clone(), cx);
                }
                cx.notify();
            });
        }));
    }

    pub(super) fn open_profile(
        &mut self,
        profile: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.active_profile() == profile {
            return;
        }
        let preferred = self.profiles.last_tabs.get(profile);
        let existing = self.workspace().and_then(|workspace| {
            let mut tabs = workspace
                .tabs
                .iter()
                .filter(|tab| self.tab_profile(tab) == profile);
            tabs.clone()
                .find(|tab| Some(&tab.id) == preferred)
                .or_else(|| tabs.next())
                .map(|tab| tab.id.clone())
        });
        if let Some(id) = existing {
            self.select_tab(&id, window, cx);
            return;
        }
        let mut tab = ChatTab::draft();
        tab.profile = profile.to_owned();
        let id = tab.id.clone();
        self.workspace_mut().tabs.push(tab);
        self.select_tab(&id, window, cx);
    }

    pub(super) fn sync_tab_sidebar(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.profiles.scope.profile == self.active_profile() {
            return;
        }
        self.archived_only = false;
        self.query.clear();
        self.search
            .update(cx, |input, cx| input.set_value("", window, cx));
        self.fetch_list(0, false, window, cx);
        self.sync_cron(window, cx);
        self.apply_reasoning_visibility();
        self.refresh_display_preferences(cx);
        self.refresh_unread_sessions(self.active_profile().to_owned(), cx);
    }

    pub(super) fn update_list_scope(&mut self) -> ListScope {
        let next_scope = ListScope {
            profile: self.active_profile().to_owned(),
            archived: self.archived_only,
            query: self.query.clone(),
        };
        if next_scope != self.profiles.scope {
            let previous = std::mem::replace(&mut self.profiles.scope, next_scope.clone());
            self.list_job = None;
            self.refreshing = false;
            if previous.query.is_empty() && (self.profiles.ready || !self.rows.is_empty()) {
                self.profiles.pages.insert(
                    (previous.profile, previous.archived),
                    CachedPage {
                        rows: std::mem::take(&mut self.rows),
                        next: self.next,
                        scroll: Some(self.sidebar_list.scroll_position()),
                        ready: self.profiles.ready,
                    },
                );
            }
            let page = if next_scope.query.is_empty() {
                self.profiles
                    .pages
                    .remove(&(next_scope.profile.clone(), next_scope.archived))
            } else {
                None
            }
            .unwrap_or_default();
            self.rows = page.rows;
            self.next = page.next;
            self.profiles.ready = page.ready;
            self.sidebar_list.change_scope(page.scroll);
        }
        next_scope
    }

    pub(super) fn insert_profile_session(&mut self, row: Summary) {
        let scope = &self.profiles.scope;
        let rows = if scope.profile == row.profile && !scope.archived && scope.query.is_empty() {
            self.sidebar_list.invalidate();
            &mut self.rows
        } else {
            &mut self
                .profiles
                .pages
                .entry((row.profile.clone(), false))
                .or_default()
                .rows
        };
        if !rows.iter().any(|existing| existing.id == row.id) {
            rows.insert(0, row);
        }
    }

    pub(super) fn patch_profile_rows(&mut self, profile: &str, id: &str, patch: &Value) {
        if self.profiles.scope.profile == profile {
            patch_rows(&mut self.rows, self.profiles.scope.archived, id, patch);
            self.sidebar_list.invalidate();
        }
        for ((owner, archived), page) in &mut self.profiles.pages {
            if owner == profile {
                patch_rows(&mut page.rows, *archived, id, patch);
            }
        }
    }

    pub(super) fn forget_pin_position(&mut self, profile: &str, id: &str, cx: &mut Context<Self>) {
        let key = self
            .rows
            .iter()
            .chain(
                self.profiles
                    .pages
                    .iter()
                    .filter(|((owner, _), _)| owner == profile)
                    .flat_map(|(_, page)| &page.rows),
            )
            .find(|row| row.id == id && row.profile == profile)
            .map_or(id, Summary::pin_order_key)
            .to_owned();
        let positions = &mut self.workspace_mut().pinned_order;
        let Some(order) = positions.get_mut(profile) else {
            return;
        };
        let old_length = order.len();
        order.retain(|saved| saved != &key);
        if order.len() != old_length {
            if order.is_empty() {
                positions.remove(profile);
            }
            self.persist(cx);
        }
    }
}

fn patch_rows(rows: &mut Vec<Summary>, archived: bool, id: &str, patch: &Value) {
    if patch["hidden"] == true
        || patch["archived"]
            .as_bool()
            .is_some_and(|value| value != archived)
    {
        rows.retain(|row| row.id != id);
    } else if let Some(row) = rows.iter_mut().find(|row| row.id == id) {
        if let Some(title) = patch["title"].as_str() {
            row.title = title.to_owned().into();
        }
        if let Some(pinned) = patch["pinned"].as_bool() {
            row.pinned = pinned;
        }
        if let Some(unread) = patch["unread"].as_bool() {
            row.unread = unread;
        }
    }
}

fn profile_entry(row: &Value) -> Option<Profile> {
    let name = string(row, "name").trim();
    if name.is_empty() {
        return None;
    }
    let label = string(row, "display_name").trim();
    let model = string(row, "model").trim();
    Some(Profile {
        name: name.to_owned(),
        label: if label.is_empty() { name } else { label }
            .to_owned()
            .into(),
        model: (!model.is_empty()).then(|| ModelChoice {
            id: model.to_owned(),
            provider: string(row, "provider").to_owned(),
        }),
        path: string(row, "path").to_owned().into(),
        is_default: row["is_default"] == true || name == "default",
        has_env: row["has_env"] == true,
        skill_count: row["skill_count"].as_u64(),
    })
}
