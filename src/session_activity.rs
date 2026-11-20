use std::{
    collections::HashSet,
    time::{Duration, Instant},
};

use gpui::SharedString;
use serde_json::Value;

use crate::session::{compact_preview, string};

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Processes,
    Agents,
}

impl Kind {
    pub const ALL: [Self; 2] = [Self::Processes, Self::Agents];

    pub fn method(self) -> &'static str {
        match self {
            Self::Processes => "process.list",
            Self::Agents => "subagent.list",
        }
    }
}

#[derive(Default)]
pub struct Poll {
    pending: bool,
    last: Option<Instant>,
    unavailable: bool,
}

impl Poll {
    pub fn start(&mut self, gap: Duration) -> bool {
        if self.pending || self.unavailable || self.last.is_some_and(|last| last.elapsed() < gap) {
            return false;
        }
        self.pending = true;
        self.last = Some(Instant::now());
        true
    }

    pub fn settle(&mut self, error: Option<&Value>) {
        self.pending = false;
        self.unavailable = error.is_some_and(|error| error["code"] == -32601);
    }
}

#[derive(Clone, PartialEq, Eq)]
pub struct Process {
    pub id: String,
    pub title: SharedString,
    pub output: SharedString,
}

#[derive(Clone, PartialEq, Eq)]
pub struct Agent {
    pub id: String,
    pub title: SharedString,
    pub tool: SharedString,
    pub model: SharedString,
    pub queued: bool,
    pub depth: usize,
}

#[derive(Default)]
pub struct Activity {
    pub processes: Vec<Process>,
    pub agents: Vec<Agent>,
    pub processes_open: bool,
    pub agents_open: bool,
    pub detail: Option<String>,
    pub agent_revision: u64,
    pub processes_read: bool,
    pub agents_read: bool,
    process_poll: Poll,
    agent_poll: Poll,
    retired_agents: HashSet<String>,
}

impl Activity {
    pub fn has_work(&self) -> bool {
        !self.processes.is_empty() || !self.agents.is_empty()
    }

    pub fn poll(&mut self, kind: Kind) -> &mut Poll {
        match kind {
            Kind::Processes => &mut self.process_poll,
            Kind::Agents => &mut self.agent_poll,
        }
    }

    pub fn replace_processes(&mut self, response: &Value) {
        let Some(rows) = response["processes"].as_array() else {
            return;
        };
        self.processes_read = true;
        self.processes = rows
            .iter()
            .filter_map(|row| {
                if row["status"] != "running" {
                    return None;
                }
                let id = string(row, "session_id");
                if id.is_empty() {
                    return None;
                }
                let title = string(row, "command")
                    .lines()
                    .next()
                    .unwrap_or_default()
                    .trim();
                let output = row["output_tail"]
                    .as_str()
                    .or_else(|| row["output_preview"].as_str())
                    .unwrap_or_default();
                let output = output.trim().replace('\r', "");
                let limit = output.ceil_char_boundary(output.len().saturating_sub(6_000));
                Some(Process {
                    id: id.to_owned(),
                    title: if title.is_empty() {
                        "后台进程".into()
                    } else {
                        compact_preview(title, 200)
                    },
                    output: output[limit..].to_owned().into(),
                })
            })
            .collect();
        if self.processes.is_empty() {
            self.detail = None;
        }
    }

    pub fn replace_agents(&mut self, response: &Value, revision: u64) {
        let Some(rows) = response["subagents"].as_array() else {
            return;
        };
        if self.agent_revision != revision {
            return;
        }
        self.agents_read = true;
        self.agents = rows
            .iter()
            .filter_map(|row| {
                if !matches!(string(row, "status"), "running" | "queued") {
                    return None;
                }
                let id = agent_id(row)?;
                if self.retired_agents.contains(&id) {
                    return None;
                }
                let previous = self.agents.iter().find(|agent| agent.id == id);
                Some(agent_row(id, row, previous, row["status"] == "queued"))
            })
            .collect();
    }

    pub fn agent_event(&mut self, kind: &str, payload: &Value) {
        let Some(id) = agent_id(payload) else {
            return;
        };
        if kind == "subagent.complete"
            || matches!(
                string(payload, "status"),
                "completed" | "failed" | "timeout" | "cancelled" | "interrupted"
            )
        {
            self.agents.retain(|agent| agent.id != id);
            self.retired_agents.insert(id);
        } else if !self.retired_agents.contains(&id) {
            let previous = self.agents.iter().position(|agent| agent.id == id);
            let queued = kind == "subagent.spawn_requested" || payload["status"] == "queued";
            let agent = agent_row(id, payload, previous.map(|i| &self.agents[i]), queued);
            if let Some(index) = previous {
                self.agents[index] = agent;
            } else {
                self.agents.push(agent);
            }
        } else {
            return;
        }
        self.agent_revision = self.agent_revision.wrapping_add(1);
    }
}

fn agent_id(payload: &Value) -> Option<String> {
    let id = string(payload, "subagent_id").trim();
    if !id.is_empty() {
        return Some(id.to_owned());
    }
    let goal = string(payload, "goal");
    (!goal.is_empty()).then(|| {
        format!(
            "{}:{}:{goal}",
            string(payload, "parent_id"),
            payload["task_index"].as_u64().unwrap_or(0)
        )
    })
}

fn agent_row(id: String, payload: &Value, previous: Option<&Agent>, queued: bool) -> Agent {
    let title = string(payload, "goal").trim();
    let tool = payload["tool_name"]
        .as_str()
        .or_else(|| payload["last_tool"].as_str())
        .or_else(|| payload["output_tail"].as_array()?.last()?["tool"].as_str())
        .unwrap_or_default();
    let model = string(payload, "model").trim();
    Agent {
        id,
        title: if title.is_empty() {
            previous
                .map(|row| row.title.clone())
                .unwrap_or_else(|| "子代理".into())
        } else {
            compact_preview(title, 220)
        },
        tool: if tool.is_empty() {
            previous.map(|row| row.tool.clone()).unwrap_or_default()
        } else {
            compact_preview(tool, 70)
        },
        model: if model.is_empty() {
            previous.map(|row| row.model.clone()).unwrap_or_default()
        } else {
            compact_preview(model, 70)
        },
        queued,
        depth: payload["depth"]
            .as_u64()
            .and_then(|value| usize::try_from(value).ok())
            .or_else(|| previous.map(|row| row.depth))
            .unwrap_or(0),
    }
}
