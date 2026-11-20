use std::{
    collections::{HashMap, HashSet},
    time::Duration,
};

use gpui::{Context, Task};

use super::Desktop;

#[derive(Default)]
struct ProfileUnread {
    recent: HashMap<String, bool>,
    request: Option<Task<()>>,
    dirty: bool,
}

#[derive(Default)]
pub(super) struct UnreadSessions {
    profiles: HashMap<String, ProfileUnread>,
}

impl UnreadSessions {
    pub(super) fn clear(&mut self) {
        self.profiles.clear();
    }

    pub(super) fn record(&mut self, profile: &str, id: &str, unread: bool) {
        self.profiles
            .entry(profile.to_owned())
            .or_default()
            .recent
            .insert(id.to_owned(), unread);
    }

    pub(super) fn get(&self, profile: &str, id: &str) -> Option<bool> {
        self.profiles.get(profile)?.recent.get(id).copied()
    }
}

impl Desktop {
    pub(super) fn refresh_open_profile_unread(&mut self, cx: &mut Context<Self>) {
        let mut owners: HashSet<String> = self
            .workspace()
            .into_iter()
            .flat_map(|workspace| &workspace.tabs)
            .filter(|tab| tab.session.is_some())
            .map(|tab| self.tab_profile(tab).to_owned())
            .collect();
        owners.insert(self.active_profile().to_owned());
        for profile in owners {
            self.refresh_unread_sessions(profile, cx);
        }
    }

    pub(super) fn session_is_unread(&self, profile: &str, id: &str) -> bool {
        self.unread_sessions.get(profile, id).unwrap_or_else(|| {
            self.profile_summary(profile, id)
                .is_some_and(|row| row.unread && !row.archived)
        })
    }

    pub(super) fn unread_recent_count(&self) -> usize {
        let Some(state) = self.unread_sessions.profiles.get(self.active_profile()) else {
            return 0;
        };
        state
            .recent
            .iter()
            .filter(|(id, unread)| {
                **unread
                    && self
                        .sessions
                        .get(*id)
                        .is_none_or(|session| session.prompts.is_empty() && !session.running)
            })
            .count()
    }

    pub(super) fn refresh_unread_sessions(&mut self, profile: String, cx: &mut Context<Self>) {
        let Some(gateway) = self.gateway.clone().filter(|_| self.out.is_some()) else {
            return;
        };
        let scope = self
            .unread_sessions
            .profiles
            .entry(profile.clone())
            .or_default();
        if scope.request.is_some() {
            scope.dirty = true;
            return;
        }
        let runtime = self.runtime.clone();
        scope.request = Some(cx.spawn(async move |view, cx| {
            cx.background_executor()
                .timer(Duration::from_millis(250))
                .await;
            let _ = view.update(cx, |this, _| {
                if let Some(state) = this.unread_sessions.profiles.get_mut(&profile) {
                    state.dirty = false;
                }
            });
            let owner = profile.clone();
            let result = runtime
                .spawn(async move { gateway.unread_recent_sessions(&owner).await })
                .await;
            let _ = view.update(cx, |this, cx| {
                let Some(state) = this.unread_sessions.profiles.get_mut(&profile) else {
                    return;
                };
                state.request = None;
                if std::mem::take(&mut state.dirty) {
                    this.refresh_unread_sessions(profile, cx);
                } else if let Ok(Ok(recent)) = result
                    && state.recent != recent
                {
                    state.recent = recent;
                    cx.notify();
                }
            });
        }));
    }
}
