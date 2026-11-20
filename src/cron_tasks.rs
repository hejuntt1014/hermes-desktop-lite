use std::{
    collections::{HashMap, HashSet},
    sync::Arc,
    time::Duration,
};

use chrono::{DateTime, FixedOffset, Local, Utc};
use gpui::{AppContext, Context, Entity, Focusable, SharedString, Task, Window};
use gpui_component::input::{InputState, TextareaState};
use reqwest::Method;
use serde::Deserialize;
use serde_json::{Value, json};

use crate::{encode_path, session::Summary};

use super::Desktop;

const JOBS: &str = "api/cron/jobs";

#[derive(Clone, Deserialize)]
pub(super) struct CronJob {
    pub id: String,
    pub name: Option<String>,
    pub enabled: bool,
    pub state: Option<String>,
    pub prompt: Option<String>,
    pub script: Option<String>,
    pub schedule: Option<Schedule>,
    pub schedule_display: Option<String>,
    pub deliver: Option<String>,
    pub next_run_at: Option<String>,
    pub last_run_at: Option<String>,
    pub last_error: Option<String>,
    profile: Option<String>,
    #[serde(default)]
    no_agent: bool,
    live_execution: Option<Execution>,
}

#[derive(Clone, Deserialize)]
pub(super) struct Schedule {
    expr: Option<String>,
    display: Option<String>,
    run_at: Option<String>,
}

#[derive(Clone, Deserialize)]
struct Execution {
    status: String,
}

impl CronJob {
    pub fn title(&self) -> &str {
        [&self.name, &self.prompt, &self.script]
            .into_iter()
            .filter_map(Option::as_deref)
            .map(|text| text.lines().next().unwrap_or_default().trim())
            .find(|text| !text.is_empty())
            .unwrap_or(&self.id)
    }

    pub fn schedule_label(&self) -> &str {
        self.schedule_display
            .as_deref()
            .or_else(|| self.schedule.as_ref()?.display.as_deref())
            .or_else(|| self.schedule.as_ref()?.expr.as_deref())
            .unwrap_or("—")
    }

    fn next_run(&self) -> Option<DateTime<FixedOffset>> {
        DateTime::parse_from_rfc3339(self.next_run_at.as_deref()?).ok()
    }

    pub fn running(&self) -> bool {
        self.state.as_deref() == Some("running")
            || self
                .live_execution
                .as_ref()
                .is_some_and(|run| matches!(run.status.as_str(), "running" | "claimed"))
    }

    pub fn status(&self, now: i64) -> (String, u32) {
        use crate::style::ACCENT;
        if self.running() {
            return ("执行中".into(), ACCENT);
        }
        match self.state.as_deref() {
            Some("paused") => ("已暂停".into(), 0xd09240),
            Some("completed") => ("已完成".into(), 0x9ba3ad),
            Some("error") => ("异常".into(), 0xb8605d),
            _ if !self.enabled => ("已停用".into(), 0x9ba3ad),
            _ => {
                let Some(at) = self.next_run() else {
                    return ("待调度".into(), ACCENT);
                };
                let delta = at.timestamp() - now;
                match delta {
                    ..=-901 => ("已逾期".into(), 0xb8605d),
                    ..=0 => ("待执行".into(), ACCENT),
                    1..=59 => ("即将执行".into(), ACCENT),
                    60..=3599 => (format!("{}分钟后", delta / 60), ACCENT),
                    3600..=86399 => (format!("{}小时后", delta / 3600), ACCENT),
                    _ => (format!("{}天后", delta / 86400), ACCENT),
                }
            }
        }
    }
}

pub(super) fn cron_datetime(timestamp: Option<&str>) -> Option<String> {
    let timestamp = timestamp?.parse::<DateTime<FixedOffset>>().ok()?;
    Some(
        timestamp
            .with_timezone(&Local)
            .format("%m月%d日 %H:%M")
            .to_string(),
    )
}

#[derive(Default)]
pub(super) struct JobPage {
    pub jobs: Vec<CronJob>,
    pub error: Option<SharedString>,
    pub ready: bool,
    pub loading: bool,
    request: u64,
}

pub(super) struct CronRun {
    pub row: Summary,
    pub label: String,
    pub preview: Option<String>,
    pub outcome: Option<(&'static str, u32)>,
    pub can_open: bool,
}

#[derive(Default)]
pub(super) struct RunPage {
    pub rows: Vec<CronRun>,
    pub error: Option<SharedString>,
    pub ready: bool,
    loading: bool,
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum JobAction {
    Pause,
    Resume,
    Run,
    Delete,
}

impl JobAction {
    pub fn label(self) -> &'static str {
        match self {
            Self::Pause => "暂停",
            Self::Resume => "恢复",
            Self::Run => "立即执行",
            Self::Delete => "删除",
        }
    }
}

pub(super) struct CronEditor {
    pub id: Option<String>,
    pub name: Entity<InputState>,
    pub schedule: Entity<InputState>,
    pub prompt: Entity<TextareaState>,
    pub deliver: Entity<InputState>,
    pub script_only: bool,
    original_schedule: String,
}

#[derive(Default)]
pub(super) struct CronTasks {
    pub open: bool,
    pub profile: String,
    pub selected: Option<String>,
    pub editor: Option<CronEditor>,
    pub confirmation: Option<JobAction>,
    pub error: Option<SharedString>,
    pub pages: HashMap<String, JobPage>,
    pub runs: HashMap<(String, String), RunPage>,
    pub busy: bool,
    pub triggering: HashSet<(String, String)>,
    identity: Arc<()>,
    poll: Option<Task<()>>,
}

impl Desktop {
    pub(super) fn cron_expanded(&self) -> bool {
        self.workspace()
            .is_some_and(|workspace| workspace.cron_expanded)
    }

    pub(super) fn cron_visible(&self) -> bool {
        self.cron.open || self.sidebar_open && self.cron_expanded()
    }

    pub(super) fn toggle_cron_sidebar(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.workspace_mut().cron_expanded = !self.cron_expanded();
        self.persist(cx);
        self.sync_cron(window, cx);
        cx.notify();
    }

    pub(super) fn sync_cron(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let profile = self.active_profile().to_owned();
        if self.cron.profile != profile {
            self.cron.profile = profile;
            self.cron.open = false;
            self.cron.selected = None;
            self.cron.editor = None;
            self.cron.confirmation = None;
            self.cron.error = None;
        }
        if !self.cron_visible() {
            self.cron.poll = None;
            return;
        }
        self.refresh_cron_jobs(cx);
        if self.cron.poll.is_none() {
            self.cron.poll = Some(cx.spawn_in(window, async move |view, cx| {
                loop {
                    cx.background_executor()
                        .timer(Duration::from_secs(15))
                        .await;
                    if view
                        .update_in(cx, |this, _, cx| {
                            this.refresh_cron_jobs(cx);
                            if this.cron.open {
                                this.refresh_cron_runs(cx);
                            }
                            cx.notify();
                        })
                        .is_err()
                    {
                        break;
                    }
                }
            }));
        }
    }

    pub(super) fn open_cron(
        &mut self,
        id: Option<String>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.sync_cron(window, cx);
        self.cron.open = true;
        self.cron.selected = id;
        self.cron.editor = None;
        self.cron.confirmation = None;
        self.cron.error = None;
        self.workspace_focus.focus(window, cx);
        self.sync_cron(window, cx);
        self.refresh_cron_runs(cx);
        cx.notify();
    }

    pub(super) fn close_cron(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.cron.open {
            return;
        }
        self.cron.open = false;
        self.cron.selected = None;
        self.cron.editor = None;
        self.cron.confirmation = None;
        self.cron.error = None;
        if !self.cron_visible() {
            self.cron.poll = None;
        }
        self.workspace_focus.focus(window, cx);
        cx.notify();
    }

    pub(super) fn refresh_cron_jobs(&mut self, cx: &mut Context<Self>) {
        let profile = self.cron.profile.clone();
        let Some(gateway) = self
            .gateway
            .clone()
            .filter(|_| self.out.is_some() && !profile.is_empty())
        else {
            return;
        };
        let page = self.cron.pages.entry(profile.clone()).or_default();
        if page.loading {
            return;
        }
        page.loading = true;
        page.request += 1;
        let request = page.request;
        let args = [("profile", profile.clone())];
        let task = self.runtime.spawn(async move {
            let result = gateway.api(Method::GET, JOBS, &args, None).await?;
            let mut jobs: Vec<CronJob> = serde_json::from_value(result)?;
            jobs.retain(|job| job.profile.as_ref().is_none_or(|name| name == &args[0].1));
            sort_jobs(&mut jobs);
            Ok::<_, anyhow::Error>(jobs)
        });
        let identity = self.cron.identity.clone();
        cx.spawn(async move |view, cx| {
            let result = task
                .await
                .map_err(anyhow::Error::from)
                .and_then(|result| result);
            let _ = view.update(cx, |this, cx| {
                if !Arc::ptr_eq(&this.cron.identity, &identity) {
                    return;
                }
                let page = this.cron.pages.entry(profile.clone()).or_default();
                if page.request != request {
                    return;
                }
                page.loading = false;
                match result {
                    Ok(jobs) => {
                        page.ready = true;
                        page.jobs = jobs;
                        page.error = None;
                    }
                    Err(error) => page.error = Some(error.to_string().into()),
                }
                if this.cron.profile == profile {
                    cx.notify();
                }
            });
        })
        .detach();
        cx.notify();
    }

    pub(super) fn refresh_cron_runs(&mut self, cx: &mut Context<Self>) {
        let (Some(gateway), Some(id)) = (
            self.gateway.clone().filter(|_| self.out.is_some()),
            self.cron.selected.clone(),
        ) else {
            return;
        };
        let owner = (self.cron.profile.clone(), id);
        let page = self.cron.runs.entry(owner.clone()).or_default();
        if page.loading {
            return;
        }
        page.loading = true;
        let args = [("profile", owner.0.clone()), ("limit", "20".into())];
        let path = format!("{JOBS}/{}/runs", encode_path(&owner.1));
        let task = self.runtime.spawn(async move {
            let result = gateway.api(Method::GET, &path, &args, None).await?;
            let rows = result["runs"]
                .as_array()
                .ok_or_else(|| anyhow::anyhow!("网关返回了无效的执行记录"))?;
            Ok::<_, anyhow::Error>(
                rows.iter()
                    .filter_map(|wire| {
                        let mut row = Summary::from_wire(wire)?;
                        if row.profile.is_empty() {
                            row.profile.clone_from(&args[0].1);
                        }
                        let label = wire["started_at"]
                            .as_f64()
                            .and_then(|at| DateTime::<Utc>::from_timestamp(at as i64, 0))
                            .map(|at| {
                                at.with_timezone(&Local)
                                    .format("%m月%d日 %H:%M")
                                    .to_string()
                            })
                            .unwrap_or_else(|| "时间未知".into());
                        let script = wire["source"] == "cron_output";
                        let (title, outcome) = run_title(&row.title, script);
                        let preview = wire["preview"].as_str().map(clean_run_preview);
                        row.title = title.into();
                        Some(CronRun {
                            can_open: wire["source"] != "cron_output"
                                && wire["ended_at"].is_number()
                                && row.profile == args[0].1,
                            preview,
                            outcome,
                            row,
                            label,
                        })
                    })
                    .collect::<Vec<_>>(),
            )
        });
        let identity = self.cron.identity.clone();
        cx.spawn(async move |view, cx| {
            let result = task
                .await
                .map_err(anyhow::Error::from)
                .and_then(|result| result);
            let _ = view.update(cx, |this, cx| {
                if !Arc::ptr_eq(&this.cron.identity, &identity) {
                    return;
                }
                let selected =
                    this.cron.profile == owner.0 && this.cron.selected.as_deref() == Some(&owner.1);
                let Some(page) = this.cron.runs.get_mut(&owner) else {
                    return;
                };
                page.loading = false;
                match result {
                    Ok(rows) => {
                        page.rows = rows;
                        page.ready = true;
                        page.error = None;
                    }
                    Err(error) => page.error = Some(error.to_string().into()),
                }
                if selected {
                    cx.notify();
                }
            });
        })
        .detach();
    }

    pub(super) fn edit_cron(
        &mut self,
        job: Option<&CronJob>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.cron.error = None;
        self.cron.confirmation = None;
        let name = job.and_then(|job| job.name.as_deref()).unwrap_or_default();
        let schedule = job
            .and_then(|job| {
                let schedule = job.schedule.as_ref()?;
                schedule.expr.as_deref().or(schedule.run_at.as_deref())
            })
            .or_else(|| job.map(CronJob::schedule_label))
            .unwrap_or_default();
        let prompt = job
            .and_then(|job| job.prompt.as_deref())
            .unwrap_or_default();
        let deliver = job
            .and_then(|job| job.deliver.as_deref())
            .unwrap_or("local");
        let editor = CronEditor {
            id: job.map(|job| job.id.clone()),
            name: cx.new(|cx| InputState::new(window, cx).default_value(name.to_owned())),
            schedule: cx.new(|cx| {
                InputState::new(window, cx)
                    .default_value(schedule.to_owned())
                    .placeholder("例如 0 9 * * 1-5 或 every 30m")
            }),
            deliver: cx.new(|cx| {
                InputState::new(window, cx)
                    .default_value(deliver.to_owned())
                    .placeholder("local")
            }),
            prompt: cx.new(|cx| {
                TextareaState::new(window, cx)
                    .auto_grow(3, 8)
                    .default_value(prompt.to_owned())
                    .placeholder("到点后要执行的内容")
            }),
            script_only: job.is_some_and(|job| {
                job.no_agent
                    || job.script.is_some() && job.prompt.as_deref().is_none_or(str::is_empty)
            }),
            original_schedule: schedule.trim().to_owned(),
        };
        editor.name.focus_handle(cx).focus(window, cx);
        self.cron.editor = Some(editor);
        cx.notify();
    }

    pub(super) fn save_cron(&mut self, cx: &mut Context<Self>) {
        let Some(editor) = &self.cron.editor else {
            return;
        };
        let name = editor.name.read(cx).value();
        let schedule = editor.schedule.read(cx).value();
        let deliver = editor.deliver.read(cx).value();
        let prompt = editor.prompt.read(cx).value();
        if name.trim().is_empty()
            || schedule.trim().is_empty()
            || (!editor.script_only && prompt.trim().is_empty())
        {
            self.cron.error = Some("请填写任务名称、计划和执行指令".into());
            cx.notify();
            return;
        }
        let mut updates = json!({"name": name.trim(), "deliver": if deliver.trim().is_empty() { "local" } else { deliver.trim() }});
        if !editor.script_only {
            updates["prompt"] = json!(prompt.trim());
        }
        if editor.id.is_none() || editor.original_schedule != schedule.trim() {
            updates["schedule"] = json!(schedule.trim());
        }
        let (method, path, body) = match &editor.id {
            Some(id) => (
                Method::PUT,
                format!("{JOBS}/{}", encode_path(id)),
                json!({"updates": updates}),
            ),
            None => (Method::POST, JOBS.into(), updates),
        };
        self.mutate_cron(method, path, Some(body), None, cx);
    }

    pub(super) fn act_on_cron(&mut self, id: String, action: JobAction, cx: &mut Context<Self>) {
        let path = format!("{JOBS}/{}", encode_path(&id));
        let (method, path) = match action {
            JobAction::Pause => (Method::POST, format!("{path}/pause")),
            JobAction::Resume => (Method::POST, format!("{path}/resume")),
            JobAction::Delete => (Method::DELETE, path),
            JobAction::Run => (Method::POST, path),
        };
        self.cron.confirmation = None;
        self.mutate_cron(method, path, None, Some((id, action)), cx);
    }

    fn mutate_cron(
        &mut self,
        method: Method,
        path: String,
        body: Option<Value>,
        action: Option<(String, JobAction)>,
        cx: &mut Context<Self>,
    ) {
        let profile = self.cron.profile.clone();
        let Some(gateway) = self.gateway.clone().filter(|_| {
            self.out.is_some()
                && self.cron.open
                && !profile.is_empty()
                && self.active_profile() == profile
                && !self.cron.busy
        }) else {
            return;
        };
        let running = action
            .as_ref()
            .filter(|(_, action)| *action == JobAction::Run)
            .map(|(id, _)| (profile.clone(), id.clone()));
        if let Some(key) = &running {
            if !self.cron.triggering.insert(key.clone()) {
                return;
            }
        } else {
            self.cron.busy = true;
        }
        self.cron.error = None;
        let args = [("profile", profile.clone())];
        let run_id = running.as_ref().map(|(_, id)| id.clone());
        let task = self.runtime.spawn(async move {
            if let Some(id) = run_id {
                gateway.trigger_cron_job(&id, &args[0].1).await
            } else {
                gateway.api(method, &path, &args, body).await
            }
        });
        let identity = self.cron.identity.clone();
        cx.spawn(async move |view, cx| {
            let result = task
                .await
                .map_err(anyhow::Error::from)
                .and_then(|result| result);
            let _ = view.update(cx, |this, cx| {
                if !Arc::ptr_eq(&this.cron.identity, &identity) {
                    return;
                }
                if let Some(key) = &running {
                    this.cron.triggering.remove(key);
                } else {
                    this.cron.busy = false;
                }
                let same_profile = this.cron.profile == profile;
                match result {
                    Ok(value) => {
                        let page = this.cron.pages.entry(profile.clone()).or_default();
                        page.request += 1;
                        page.loading = false;
                        if let Some((id, JobAction::Delete)) = &action {
                            page.jobs.retain(|job| &job.id != id);
                            this.cron.runs.remove(&(profile, id.clone()));
                            if same_profile && this.cron.selected.as_ref() == Some(id) {
                                this.cron.selected = None;
                            }
                        } else if let Ok(job) = serde_json::from_value::<CronJob>(value) {
                            if action.is_none() && same_profile && this.cron.editor.is_some() {
                                this.cron.editor = None;
                                this.cron.selected = Some(job.id.clone());
                            }
                            page.jobs.retain(|old| old.id != job.id);
                            page.jobs.push(job);
                            sort_jobs(&mut page.jobs);
                        }
                        if same_profile && this.cron_visible() {
                            this.refresh_cron_jobs(cx);
                            this.refresh_cron_runs(cx);
                        }
                    }
                    Err(error) if same_profile => this.cron.error = Some(error.to_string().into()),
                    Err(error) => this.banner = Some(error.to_string().into()),
                }
                cx.notify();
            });
        })
        .detach();
        cx.notify();
    }
}

fn sort_jobs(jobs: &mut [CronJob]) {
    jobs.sort_by_cached_key(|job| {
        (
            job.next_run().is_none(),
            job.next_run(),
            job.title().to_owned(),
        )
    });
}

fn run_title(title: &str, script: bool) -> (String, Option<(&'static str, u32)>) {
    let (prefix, subtitle) = title.split_once(" · ").unwrap_or((title, ""));
    let outcome = match prefix {
        "COMPLETED" | "SUCCESS" => Some(("已完成", 0x318873)),
        "FAILED" | "ERROR" => Some(("失败", 0xb8605d)),
        "CANCELLED" => Some(("已取消", 0x88716b)),
        "MISSED" => Some(("已错过", 0xc18e48)),
        _ => None,
    };
    let title = if outcome.is_some() { subtitle } else { title };
    let title = if script
        && (title.is_empty() || title.starts_with("# Cron Job:") || title == "Script-only run")
    {
        "脚本运行"
    } else {
        title
    };
    (title.to_owned(), outcome)
}

fn clean_run_preview(text: &str) -> String {
    let Some(metadata) = text.strip_prefix("# Cron Job:") else {
        return text.to_owned();
    };
    let status = metadata
        .split_once("**Status:**")
        .map_or("", |(_, text)| text.trim());
    match status {
        "silent (empty output)" => "无输出".into(),
        "silent (wakeAgent=false)" => "本次未唤醒智能体".into(),
        "no_change (agent run suppressed)" => "无变化，本次未唤醒智能体".into(),
        value => value.to_owned(),
    }
}
