use std::{
    collections::{HashMap, HashSet},
    time::{Duration, Instant},
};

use gpui::{Context, Task, Window};
use serde_json::{Value, json};

use crate::{
    session::{Summary, string},
    session_activity::{Kind, Poll},
};

use super::{Call, Desktop};

pub(super) struct WorkRequest {
    key: String,
    runtime: String,
    profile: String,
    kind: Kind,
    revision: u64,
}

#[derive(Default)]
pub(super) struct WorkMonitor {
    timer: Option<Task<()>>,
    rosters: HashMap<String, Roster>,
    tail_read: Option<Task<()>>,
    last_tail: Option<(String, Instant)>,
}

#[derive(Default)]
struct Roster {
    poll: Poll,
    sessions: HashSet<String>,
}

impl Desktop {
    pub(super) fn start_work_monitor(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.work_monitor.timer.is_some() {
            return;
        }
        self.work_monitor.timer = Some(cx.spawn_in(window, async move |view, cx| {
            loop {
                cx.background_executor().timer(Duration::from_secs(3)).await;
                if view
                    .update_in(cx, |this, window, cx| {
                        if window.is_window_active() {
                            this.poll_work();
                            this.check_open_transcript(false, cx);
                        }
                        this.check_pending_turns();
                    })
                    .is_err()
                {
                    break;
                }
            }
        }));
        self.poll_work();
    }

    pub(super) fn check_open_transcript(&mut self, changed: bool, cx: &mut Context<Self>) {
        let Some(key) = self.selected.clone() else {
            return;
        };
        let Some(session) = self.sessions.get(&key) else {
            return;
        };
        if self.out.is_none()
            || !session.attached
            || session.loading
            || session.submitting
            || session.running
            || session.uncertain
            || session.history_rest_unavailable
            || self.history_reads.contains_key(&key)
            || self.work_monitor.tail_read.is_some()
        {
            return;
        }
        let interval = Duration::from_secs(if changed { 2 } else { 20 });
        if self
            .work_monitor
            .last_tail
            .as_ref()
            .is_some_and(|(id, at)| id == &key && at.elapsed() < interval)
        {
            return;
        }
        let Some(gateway) = self.gateway.clone() else {
            return;
        };
        let profile = session.profile.clone();
        let runtime = session.runtime.clone();
        let seq = session.seq;
        let id = key.clone();
        self.work_monitor.last_tail = Some((key.clone(), Instant::now()));
        let read = self
            .runtime
            .spawn(async move { gateway.history_page(&id, &profile, 0, 1).await });
        self.work_monitor.tail_read = Some(cx.spawn(async move |view, cx| {
            let result = read.await;
            let _ = view.update(cx, |this, cx| {
                this.work_monitor.tail_read = None;
                if let Ok(Ok(page)) = result
                    && this.selected.as_ref() == Some(&key)
                    && !this.history_reads.contains_key(&key)
                    && this.sessions.get(&key).is_some_and(|s| {
                        s.attached
                            && !s.loading
                            && !s.running
                            && !s.submitting
                            && !s.uncertain
                            && s.seq == seq
                            && s.runtime == runtime
                            && !s.history_window.matches_tail(&page)
                    })
                {
                    this.refresh_changed_history(&key, cx);
                }
            });
        }));
    }

    fn check_pending_turns(&mut self) {
        if self.out.is_none() {
            return;
        }
        let probes: Vec<_> =
            self.sessions
                .iter()
                .filter(|(key, s)| {
                    s.attached
                        && !s.loading
                        && !s.submitting
                        && !s.uncertain
                        && s.error.is_none()
                        && (s.running || !s.queued.is_empty() || self.has_followups(key))
                        && s.last_turn_activity
                            .is_none_or(|at| at.elapsed() >= Duration::from_secs(20))
                        && !self.pending.values().any(
                            |call| matches!(call, Call::CheckTurn { key: id, .. } if id == *key),
                        )
                })
                .map(|(key, s)| (key.clone(), s.runtime.clone(), s.profile.clone(), s.seq))
                .collect();
        for (key, runtime, profile, seq) in probes {
            self.sessions.get_mut(&key).unwrap().last_turn_activity = Some(Instant::now());
            self.call(
                "session.active_list",
                json!({"profile": profile, "current_session_id": runtime}),
                Call::CheckTurn { key, runtime, seq },
            );
        }
    }

    pub(super) fn poll_work(&mut self) {
        if self.out.is_none() {
            return;
        }
        let keys: Vec<_> = self
            .sessions
            .iter()
            .filter(|(key, session)| {
                session.activity.has_work() || self.selected.as_ref() == Some(key)
            })
            .map(|(key, _)| key.clone())
            .collect();
        for key in keys {
            for kind in Kind::ALL {
                self.refresh_work(&key, kind, false);
            }
        }
        self.refresh_work_roster();
    }

    pub(super) fn refresh_work(&mut self, key: &str, kind: Kind, urgent: bool) {
        if self.out.is_none() {
            return;
        }
        let Some(session) = self
            .sessions
            .get_mut(key)
            .filter(|s| s.attached && !s.loading && !s.runtime.is_empty())
        else {
            return;
        };
        let gap = Duration::from_secs(if urgent {
            1
        } else if session.running || session.activity.has_work() {
            4
        } else {
            15
        });
        if !session.activity.poll(kind).start(gap) {
            return;
        }
        let params = json!({"session_id":session.runtime,"profile":session.profile});
        let request = WorkRequest {
            key: key.to_owned(),
            runtime: session.runtime.clone(),
            profile: session.profile.clone(),
            kind,
            revision: session.activity.agent_revision,
        };
        if !self.call(kind.method(), params, Call::WorkStatus(request)) {
            self.sessions
                .get_mut(key)
                .unwrap()
                .activity
                .poll(kind)
                .settle(None);
        }
    }

    fn refresh_work_roster(&mut self) {
        let profile = self.active_profile().to_owned();
        if profile.is_empty()
            || !self
                .work_monitor
                .rosters
                .entry(profile.clone())
                .or_default()
                .poll
                .start(Duration::from_secs(15))
        {
            return;
        }
        let scope = json!({"profile":profile});
        if !self.call("subagent.roster", scope, Call::WorkRoster(profile.clone())) {
            self.finish_work_roster(&profile, &Value::Null, None);
        }
    }

    pub(super) fn finish_work(
        &mut self,
        request: WorkRequest,
        response: &Value,
        error: Option<&Value>,
    ) {
        let Some(session) = self.sessions.get_mut(&request.key).filter(|session| {
            session.runtime == request.runtime && session.profile == request.profile
        }) else {
            return;
        };
        let activity = &mut session.activity;
        activity.poll(request.kind).settle(error);
        if error.is_none() {
            match request.kind {
                Kind::Processes => activity.replace_processes(response),
                Kind::Agents => activity.replace_agents(response, request.revision),
            }
        }
    }

    pub(super) fn finish_work_roster(
        &mut self,
        profile: &str,
        response: &Value,
        error: Option<&Value>,
    ) {
        let Some(roster) = self.work_monitor.rosters.get_mut(profile) else {
            return;
        };
        roster.poll.settle(error);
        if error.is_none()
            && let Some(rows) = response["sessions"].as_array()
        {
            roster.sessions = rows
                .iter()
                .filter(|row| {
                    row["subagents"].as_u64().unwrap_or(0) > 0
                        || row["background"].as_u64().unwrap_or(0) > 0
                })
                .map(|row| string(row, "session_id"))
                .filter(|id| !id.is_empty())
                .map(str::to_owned)
                .collect();
        }
    }

    pub(super) fn session_has_activity(&self, row: &Summary) -> bool {
        if self.out.is_none() {
            return false;
        }
        if let Some(session) = self.sessions.get(&row.id)
            && session.profile == row.profile
        {
            if session.activity.has_work() {
                return true;
            }
            if self.selected.as_ref() == Some(&row.id)
                && session.activity.agents_read
                && session.activity.processes_read
            {
                return false;
            }
        }
        self.work_monitor
            .rosters
            .get(&row.profile)
            .is_some_and(|roster| {
                roster.sessions.contains(&row.id) || roster.sessions.contains(&row.lineage_root)
            })
    }
}
