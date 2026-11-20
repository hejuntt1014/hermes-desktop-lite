use std::collections::{HashMap, HashSet};

use gpui::SharedString;
use serde_json::Value;

use crate::session::string;

const MAX_TODO_RESULT_BYTES: usize = 512_000 * 4;

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum TodoStatus {
    Pending,
    InProgress,
    Completed,
    Cancelled,
}

pub struct Todo {
    id: String,
    parent: String,
    pub content: SharedString,
    pub status: TodoStatus,
}

struct Snapshot {
    items: Vec<Todo>,
    revision: Option<u64>,
}

#[derive(Default)]
pub struct SessionTodos {
    history: Option<Snapshot>,
    current: Option<Snapshot>,
    pub live_in_turn: bool,
    pub live_collapsed: bool,
    pub previous_expanded: bool,
}

impl SessionTodos {
    pub fn items(&self) -> &[Todo] {
        self.current
            .as_ref()
            .or(self.history.as_ref())
            .map_or(&[], |snapshot| &snapshot.items)
    }

    pub fn replace_history(&mut self, messages: Option<&[Value]>, display: Option<&[Value]>) {
        self.history = messages
            .and_then(history_snapshot)
            .or_else(|| display.and_then(history_snapshot));
    }

    pub fn restore(&mut self, state: &Value, same_runtime: bool, running: bool, complete: bool) {
        if !same_runtime || complete && !running && state.is_null() {
            self.current = None;
            self.live_in_turn = false;
        }
        if self.apply(state) {
            self.live_in_turn = running
                && (self.live_in_turn
                    || self.items().iter().any(|item| {
                        matches!(item.status, TodoStatus::Pending | TodoStatus::InProgress)
                    }));
        }
    }

    pub fn apply(&mut self, payload: &Value) -> bool {
        let Some(snapshot) = Snapshot::parse(payload, 0) else {
            return false;
        };
        if snapshot.items.is_empty() && snapshot.revision == Some(0) {
            return false;
        }
        if matches!((self.current.as_ref().and_then(|existing| existing.revision), snapshot.revision), (Some(old), Some(new)) if new < old)
        {
            return false;
        }
        self.current = Some(snapshot);
        true
    }
}

impl Snapshot {
    fn parse(value: &Value, depth: u8) -> Option<Self> {
        if depth > 2 {
            return None;
        }
        if let Some(text) = value
            .as_str()
            .filter(|text| text.len() <= MAX_TODO_RESULT_BYTES)
        {
            return Self::parse(&serde_json::from_str(text).ok()?, depth + 1);
        }
        if value["success"] == false || value["ok"] == false || !value["error"].is_null() {
            return None;
        }
        let Some(list) = value["todos"].as_array() else {
            return value
                .get("result")
                .and_then(|result| Self::parse(result, depth + 1));
        };
        let items = list
            .iter()
            .filter_map(|item| {
                let status = match string(item, "status") {
                    "pending" => TodoStatus::Pending,
                    "in_progress" => TodoStatus::InProgress,
                    "completed" => TodoStatus::Completed,
                    "cancelled" => TodoStatus::Cancelled,
                    _ => return None,
                };
                let id = string(item, "id").trim();
                let content = string(item, "content").trim();
                (!id.is_empty() && !content.is_empty()).then(|| Todo {
                    id: id.to_owned(),
                    parent: string(item, "parent").trim().to_owned(),
                    content: content.to_owned().into(),
                    status,
                })
            })
            .collect::<Vec<_>>();
        if items.is_empty() && !list.is_empty() {
            return None;
        }
        Some(Self {
            items,
            revision: value["revision"].as_u64(),
        })
    }
}

pub fn is_todo_tool(name: &str, args: &Value) -> bool {
    match name {
        "todo" | "todo_list" => true,
        "tool_call" => {
            let parsed;
            let args = if let Some(text) = args.as_str() {
                if !text.contains("todo") {
                    return false;
                }
                parsed = serde_json::from_str::<Value>(text).unwrap_or_default();
                &parsed
            } else {
                args
            };
            let parsed_calls;
            let mut calls = &args["calls"];
            if let Some(text) = calls.as_str() {
                parsed_calls = serde_json::from_str::<Value>(text).unwrap_or_default();
                calls = &parsed_calls;
            }
            let name = match calls {
                Value::Array(calls) if calls.len() == 1 => string(&calls[0], "name"),
                Value::Object(_) => string(calls, "name"),
                Value::Null => string(args, "name"),
                _ => "",
            };
            matches!(name, "todo" | "todo_list")
        }
        _ => false,
    }
}

fn history_snapshot(messages: &[Value]) -> Option<Snapshot> {
    let mut todo_calls = HashSet::new();
    let mut latest = None;
    for message in messages {
        match string(message, "role") {
            "assistant" => {
                todo_calls.extend(
                    message["tool_calls"]
                        .as_array()
                        .into_iter()
                        .flatten()
                        .filter_map(|call| {
                            let tool = &call["function"];
                            is_todo_tool(string(tool, "name"), &tool["arguments"])
                                .then(|| call["id"].as_str().filter(|id| !id.is_empty()))
                                .flatten()
                        }),
                );
            }
            "tool"
                if message["tool_call_id"]
                    .as_str()
                    .is_some_and(|id| todo_calls.remove(id)) =>
            {
                if let Some(snapshot) = Snapshot::parse(&message["content"], 0)
                    .or_else(|| Snapshot::parse(&message["result"], 0))
                {
                    latest = Some(snapshot);
                }
            }
            _ => {}
        }
    }
    latest
}

pub fn ordered_todos(items: &[Todo]) -> Vec<(&Todo, usize)> {
    let ids: HashSet<_> = items.iter().map(|item| item.id.as_str()).collect();
    let mut children: HashMap<&str, Vec<&Todo>> = HashMap::new();
    let mut roots = Vec::new();
    for item in items {
        if item.parent != item.id && ids.contains(item.parent.as_str()) {
            children.entry(&item.parent).or_default().push(item);
        } else {
            roots.push(item);
        }
    }
    let mut stack: Vec<_> = roots.into_iter().rev().map(|item| (item, 0)).collect();
    let mut seen = HashSet::new();
    let mut ordered = Vec::with_capacity(items.len());
    while let Some((item, depth)) = stack.pop() {
        if seen.insert(item.id.as_str()) {
            ordered.push((item, depth));
            if let Some(nested) = children.get(item.id.as_str()) {
                stack.extend(nested.iter().rev().map(|item| (*item, depth + 1)));
            }
        }
    }
    ordered.extend(
        items
            .iter()
            .filter(|item| seen.insert(&item.id))
            .map(|item| (item, 0)),
    );
    ordered
}
