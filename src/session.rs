use crate::i18n::text as tr;

use std::collections::{BTreeMap, HashMap};

use crate::{
    background_notice::BackgroundNotice,
    media::{ChatImage, Message, image_part_reference},
    settings::ModelChoice,
};
use gpui::SharedString;
use serde_json::Value;

pub fn string<'a>(object: &'a Value, field: &str) -> &'a str {
    object[field].as_str().unwrap_or_default()
}

pub fn compact_preview(value: &str, max: usize) -> SharedString {
    let mut chars = value
        .split_whitespace()
        .flat_map(|part| part.chars().chain(std::iter::once(' ')));
    let mut result: String = chars.by_ref().take(max).collect();
    if chars.any(|ch| ch != ' ') {
        result.push('…');
    }
    result.trim_end().to_owned().into()
}

pub fn text(value: &Value) -> String {
    match value {
        Value::Null => String::new(),
        Value::String(value) => value.clone(),
        Value::Array(parts) => parts
            .iter()
            .filter_map(|part| {
                if let Some(value) = part.as_str().or_else(|| part["text"].as_str()) {
                    Some(value.to_owned())
                } else {
                    let kind = string(part, "type");
                    if kind.is_empty() {
                        None
                    } else if kind.contains("image") {
                        Some("[图片]".into())
                    } else {
                        Some(format!("[{kind}]"))
                    }
                }
            })
            .collect::<Vec<_>>()
            .join("\n"),
        value => serde_json::to_string_pretty(value).unwrap_or_default(),
    }
}

#[derive(Clone)]
pub struct Summary {
    pub id: String,
    pub title: SharedString,
    pub pinned: bool,
    pub archived: bool,
    pub unread: bool,
    pub profile: String,
    pub updated_at: i64,
    pub lineage_root: String,
    pub branch_parent: String,
}

#[derive(Clone)]
pub struct SessionTarget {
    pub id: String,
    pub title: String,
    pub profile: String,
}

impl From<&Summary> for SessionTarget {
    fn from(row: &Summary) -> Self {
        Self {
            id: row.id.clone(),
            title: row.title.to_string(),
            profile: row.profile.clone(),
        }
    }
}

impl Summary {
    pub fn pin_order_key(&self) -> &str {
        if self.lineage_root.is_empty() {
            &self.id
        } else {
            &self.lineage_root
        }
    }

    pub fn from_wire(row: &Value) -> Option<Self> {
        let id = ["id", "session_id"]
            .into_iter()
            .find_map(|key| row[key].as_str().filter(|id| !id.is_empty()))?;
        let title = ["title", "preview", "snippet"]
            .into_iter()
            .find_map(|key| {
                row[key]
                    .as_str()
                    .map(str::trim)
                    .filter(|title| !title.is_empty())
            })
            .unwrap_or(tr("未命名会话"));
        let updated_at = ["last_active", "started_at"]
            .iter()
            .filter_map(|key| row[key].as_f64())
            .find(|timestamp| timestamp.is_finite() && *timestamp > 0.)
            .map_or(0, |timestamp| timestamp as i64);
        let lineage_root = string(row, "_lineage_root_id").trim().to_owned();
        let branch_parent = if string(row, "_reset_from").trim().is_empty() {
            ["_branched_from", "parent_session_id"]
                .iter()
                .map(|key| string(row, key).trim())
                .find(|value| !value.is_empty())
                .unwrap_or_default()
                .to_owned()
        } else {
            String::new()
        };
        Some(Self {
            id: id.to_owned(),
            title: title.to_owned().into(),
            pinned: row["pinned"] == true,
            archived: row["archived"] == true,
            unread: row["unread"] == true,
            profile: string(row, "profile").to_owned(),
            updated_at,
            lineage_root,
            branch_parent,
        })
    }
}

#[derive(Clone)]
pub enum Row {
    User(Message),
    Answer(Answer),
    Reasoning(SharedString),
    Tool(Tool),
    Notice(SharedString),
    Background(BackgroundNotice),
    Command(crate::command_receipt::CommandReceipt),
}

impl Row {
    fn wire_prompt(text: &str, metadata: &Value) -> Self {
        BackgroundNotice::project(text, metadata)
            .map_or_else(|| Self::User(text.to_owned().into()), Self::Background)
    }

    fn prompt_text(&self) -> Option<&str> {
        match self {
            Self::User(message) => Some(message.raw().as_ref()),
            Self::Background(notice) => Some(notice.raw.as_ref()),
            _ => None,
        }
    }
}

#[derive(Clone)]
pub struct QueuedTurn {
    pub id: String,
    pub text: SharedString,
    pub sequence: u64,
    pub can_replace: bool,
}

#[derive(Clone)]
pub struct Answer {
    pub body: Message,
    pub timestamp: Option<f64>,
    pub stored_id: Option<u64>,
}

#[derive(Clone, PartialEq, Eq, Hash)]
pub struct BranchPoint {
    pub row_id: Option<u64>,
    pub timestamp_bits: Option<u64>,
    pub text: SharedString,
}

impl Answer {
    fn live(body: Message) -> Self {
        Self {
            body,
            timestamp: None,
            stored_id: None,
        }
    }

    pub fn branch_point(&self) -> Option<BranchPoint> {
        (self.stored_id.is_some() || self.timestamp.is_some()).then(|| BranchPoint {
            row_id: self.stored_id,
            timestamp_bits: self.timestamp.map(f64::to_bits),
            text: self.body.raw().clone(),
        })
    }
}

#[derive(Clone)]
pub struct Tool {
    pub id: String,
    pub name: SharedString,
    pub context: SharedString,
    pub args: SharedString,
    pub output: SharedString,
    pub image: Option<ChatImage>,
    pub done: bool,
    pub failed: bool,
    pub duration: Option<f64>,
    pub diff: SharedString,
}

impl Tool {
    fn from_payload(value: &Value, done: bool) -> Self {
        let name = ["name", "tool_name"]
            .into_iter()
            .find_map(|key| value[key].as_str().filter(|name| !name.is_empty()))
            .unwrap_or(tr("工具"));
        let id = value["tool_id"]
            .as_str()
            .or_else(|| value["tool_call_id"].as_str())
            .or_else(|| value["id"].as_str())
            .unwrap_or_default();
        let output = ["result", "content", "result_text", "text"]
            .into_iter()
            .map(|key| text(&value[key]))
            .find(|output| !output.is_empty())
            .unwrap_or_default();
        let image = (name == "image_generate" && done)
            .then(|| ChatImage::from_tool_result(&output))
            .flatten();
        let args = ["args", "args_text", "arguments"]
            .into_iter()
            .map(|field| text(&value[field]))
            .find(|value| !value.is_empty())
            .unwrap_or_default();
        let context = if name == "skill_view" {
            skill_target(&args).or_else(|| skill_target(&output))
        } else {
            None
        };
        Self {
            id: id.to_owned(),
            name: name.to_owned().into(),
            context: context.unwrap_or_else(|| {
                value["context"]
                    .as_str()
                    .or_else(|| value["summary"].as_str())
                    .unwrap_or_default()
                    .to_owned()
                    .into()
            }),
            args: args.into(),
            done,
            failed: tool_failed(&value["result"]) || check_tool_output(&output),
            output: output.into(),
            image,
            duration: value["duration_s"]
                .as_f64()
                .filter(|value| value.is_finite() && *value >= 0.0),
            diff: string(value, "inline_diff").to_owned().into(),
        }
    }
    fn finish(&mut self, update: Tool) {
        self.done = true;
        if self.args.is_empty() {
            self.args = update.args;
        }
        if self.context.is_empty() {
            self.context = update.context;
        }
        if !update.output.is_empty() {
            self.set_output(update.output);
        }
        self.failed |= update.failed;
        self.duration = update.duration.or(self.duration);
        if !update.diff.is_empty() {
            self.diff = update.diff;
        }
    }

    fn set_output(&mut self, output: SharedString) {
        self.failed |= check_tool_output(&output);
        if self.name.as_ref() == "image_generate" {
            self.image = ChatImage::from_tool_result(&output);
        }
        if self.name.as_ref() == "skill_view"
            && self.context.is_empty()
            && let Some(target) = skill_target(&output)
        {
            self.context = target;
        }
        self.output = output;
    }
}

fn skill_target(json: &str) -> Option<SharedString> {
    #[derive(serde::Deserialize)]
    struct Target {
        name: String,
        #[serde(alias = "file")]
        file_path: Option<String>,
    }
    let target: Target = serde_json::from_str(json).ok()?;
    let name = target.name.trim();
    if name.is_empty() {
        return None;
    }
    Some(match target.file_path.as_deref().map(str::trim) {
        Some(file) if !file.is_empty() => format!("{name} → {file}").into(),
        _ => name.to_owned().into(),
    })
}

fn check_tool_output(output: &str) -> bool {
    output.len() <= 64 * 1024
        && serde_json::from_str(output).is_ok_and(|result| tool_failed(&result))
}

fn tool_failed(result: &Value) -> bool {
    result["success"] == false
        || result["ok"] == false
        || result["error"]
            .as_str()
            .is_some_and(|message| !message.trim().is_empty())
        || result["exit_code"].as_i64().is_some_and(|code| code != 0)
}

#[derive(Clone)]
pub enum PromptRoute {
    Canonical {
        id: String,
        generation: u64,
        kind: String,
    },
    Request(Value),
    LegacyApproval(String),
}

#[derive(Clone)]
pub struct Prompt {
    pub route: PromptRoute,
    pub label: SharedString,
    pub detail: SharedString,
    pub choices: Vec<String>,
    pub questions: Vec<ClarifyQuestion>,
    pub clarify: bool,
    pub submitted_answers: BTreeMap<String, String>,
}

#[derive(Clone, PartialEq, Eq)]
pub struct ClarifyQuestion {
    pub id: String,
    pub text: String,
    pub choices: Vec<String>,
    pub multi: bool,
}

fn choices(value: &Value) -> Vec<String> {
    value
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .map(str::to_owned)
        .collect()
}

impl Prompt {
    pub fn from_wire(kind: &str, value: &Value, route: PromptRoute) -> Self {
        let approval = kind == "approval";
        let mut questions: Vec<_> = value["questions"]
            .as_array()
            .into_iter()
            .flatten()
            .map(|question| ClarifyQuestion {
                id: string(question, "qid").to_owned(),
                text: string(question, "question").to_owned(),
                choices: choices(&question["choices"]),
                multi: question["multi_select"] == true,
            })
            .collect();
        let mut options = choices(&value["choices"]);
        if approval && options.is_empty() {
            options = vec!["once".into(), "deny".into()];
        }
        let detail = ["command", "question", "description"]
            .into_iter()
            .find_map(|key| value[key].as_str().filter(|text| !text.is_empty()))
            .unwrap_or_default();
        let clarify = kind == "clarify";
        if clarify && questions.is_empty() {
            questions.push(ClarifyQuestion {
                id: "answer".into(),
                text: detail.to_owned(),
                choices: std::mem::take(&mut options),
                multi: value["multi_select"] == true,
            });
        }
        let submitted_answers = value["answers"]
            .as_object()
            .into_iter()
            .flatten()
            .filter_map(|(qid, value)| Some((qid.clone(), value.as_str()?.to_owned())))
            .collect();
        let label = match kind {
            "approval" => tr("工具审批"),
            "clarify" => tr("Hermes 想确认"),
            "connection" => tr("连接请求"),
            _ => tr("输入请求"),
        };
        Self {
            route,
            label: label.into(),
            detail: detail.to_owned().into(),
            choices: options,
            questions,
            clarify,
            submitted_answers,
        }
    }
}

#[derive(Default)]
pub struct Session {
    pub(crate) upload: Option<crate::upload_progress::Display>,
    pub(super) uploading_draft_file: Option<std::path::PathBuf>,
    pub(super) staged_draft_files: HashMap<std::path::PathBuf, String>,
    pub(super) draft_upload_errors: HashMap<std::path::PathBuf, String>,
    pub(super) waiting_for_draft_upload: bool,
    pub runtime: String,
    pub profile: String,
    pub model: SharedString,
    pub provider: SharedString,
    pub branch: SharedString,
    pub cwd: SharedString,
    pub effort: SharedString,
    pub effort_on_wire: SharedString,
    pub speed: SharedString,
    pub context: Option<ContextUsage>,
    pub next_model: Option<ModelChoice>,
    pub next_effort: Option<String>,
    pub rows: Vec<Row>,
    pub user_row_ids: HashMap<usize, u64>,
    pub live: Vec<Row>,
    pub prompts: BTreeMap<String, Prompt>,
    pub running: bool,
    pub last_turn_activity: Option<std::time::Instant>,
    pub loading: bool,
    pub history_via_rest: bool,
    pub history_rest_unavailable: bool,
    pub awaiting_first_history: bool,
    pub history_partial: bool,
    pub history_window: crate::app::session_history::HistoryWindow,
    pub history_error: Option<String>,
    pub attached: bool,
    pub epoch: String,
    pub seq: u64,
    pub generation: u64,
    pub revision: Option<u64>,
    pub error: Option<String>,
    pub turn_error: Option<String>,
    pub todos: crate::session_todos::SessionTodos,
    pub activity: crate::session_activity::Activity,
    pub command_receipts: Vec<crate::command_receipt::CommandReceipt>,
    pub parked: Vec<Value>,
    pub submitting: bool,
    pub uncertain: bool,
    pub queued: Vec<QueuedTurn>,
    pub unknown: BTreeMap<String, (u64, SharedString)>,
    pub refresh: bool,
    stream: String,
    reasoning: String,
    offset: usize,
    segment: Option<u64>,
    turn: String,
    missing_prompt: Option<(u64, usize)>,
}

impl Session {
    pub fn display_row_id(&self, index: usize, row: &Row) -> Option<u64> {
        match row {
            Row::User(_) => self.user_row_ids.get(&index).copied(),
            Row::Answer(answer) => answer.stored_id,
            _ => None,
        }
    }

    pub fn has_streaming_reasoning(&self) -> bool {
        !self.reasoning.is_empty()
    }

    pub fn store_tool_result(&mut self, id: &str, result: SharedString) {
        for row in self.rows.iter_mut().chain(&mut self.live) {
            if let Row::Tool(tool) = row
                && tool.id == id
                && tool.done
                && tool.output.is_empty()
            {
                tool.set_output(result.clone());
            }
        }
    }

    pub fn count(&self) -> usize {
        self.rows.len()
            + self.live.len()
            + usize::from(!self.stream.is_empty())
            + usize::from(!self.reasoning.is_empty())
    }

    pub fn row(&self, index: usize) -> Option<Row> {
        if index < self.rows.len() {
            return self.rows.get(index).cloned();
        }
        let index = index - self.rows.len();
        if index < self.live.len() {
            return self.live.get(index).cloned();
        }
        let index = index - self.live.len();
        if !self.reasoning.is_empty() {
            if index == 0 {
                return Some(Row::Reasoning(self.reasoning.clone().into()));
            }
            return (index == 1 && !self.stream.is_empty()).then(|| {
                Row::Answer(Answer::live(Message::streaming(self.stream.clone().into())))
            });
        }
        (index == 0 && !self.stream.is_empty())
            .then(|| Row::Answer(Answer::live(Message::streaming(self.stream.clone().into()))))
    }

    pub fn accept_correction(&mut self, text: &str) {
        self.seal();
        self.live.push(Row::User(text.to_owned().into()));
    }

    fn seal_reasoning(&mut self) {
        if !self.reasoning.is_empty() {
            self.live
                .push(Row::Reasoning(std::mem::take(&mut self.reasoning).into()));
        }
    }

    fn seal(&mut self) {
        self.seal_reasoning();
        if !self.stream.is_empty() {
            self.live.push(Row::Answer(Answer::live(Message::new(
                std::mem::take(&mut self.stream).into(),
                false,
            ))));
        }
    }

    pub fn replace_snapshot(&mut self, response: &Value, canonical: bool, keep_stream: bool) {
        let same_runtime = self.runtime == string(response, "session_id");
        if !same_runtime {
            self.activity = Default::default();
        }
        self.runtime = string(response, "session_id").to_owned();
        self.update_workspace(&response["info"]);
        self.update_model(string(&response["info"], "model"));
        self.update_context(&response["info"]);
        self.clear_applied_choices();
        let deferred = response["messages_omitted"] == true || response["hydrating"] == true;
        let has_history = !deferred
            || response["messages"]
                .as_array()
                .is_some_and(|rows| !rows.is_empty())
            || response["display_messages"]
                .as_array()
                .is_some_and(|rows| !rows.is_empty());
        if has_history {
            self.replace_history(
                response["messages"].as_array(),
                response["display_messages"].as_array(),
            );
            self.history_via_rest = false;
            self.history_partial = false;
            self.history_window = Default::default();
        }
        if !keep_stream {
            self.live.clear();
            self.stream.clear();
            self.reasoning.clear();
            self.turn.clear();
            self.missing_prompt = None;
            self.segment = None;
            self.offset = 0;
        }
        self.deduplicate_live_prompt();
        self.prompts.clear();
        self.queued.clear();
        self.unknown.clear();
        self.error = None;
        self.attached = true;
        self.running = response["running"] == true || response["inflight"]["streaming"] == true;
        self.revision = response["revision"].as_u64();
        if canonical {
            self.epoch = string(response, "replay_epoch").to_owned();
            if !keep_stream {
                self.seq = response["last_sequence"].as_u64().unwrap_or_default();
            }
            self.generation = response["execution_generation"]
                .as_u64()
                .unwrap_or_default();
            self.update_pending(&response["pending"]);
            for prompt in response["prompts"].as_array().into_iter().flatten() {
                self.canonical_prompt(string(prompt, "kind"), prompt);
            }
        } else {
            let inflight = &response["inflight"];
            let user = string(inflight, "user");
            if !user.is_empty() && self.rows.last().and_then(Row::prompt_text) != Some(user) {
                self.live.push(Row::wire_prompt(user, inflight));
            }
            self.project_inflight(inflight);
            let queued = string(&response["queued"], "user");
            if !queued.is_empty() {
                self.record_queue(String::new(), queued.to_owned().into(), u64::MAX, false);
            }
            let error = string(inflight, "error");
            if !error.is_empty() {
                self.seal();
                self.live.push(Row::Notice(error.to_owned().into()));
            }
            let approval = &response["pending_approval"];
            if approval.is_object() {
                let id = string(approval, "request_id").to_owned();
                self.prompts.insert(
                    id.clone(),
                    Prompt::from_wire("approval", approval, PromptRoute::LegacyApproval(id)),
                );
            }
        }
        for request in response["open_requests"].as_array().into_iter().flatten() {
            self.server_request(request);
        }
        self.running |= !self.prompts.is_empty();
        self.todos.restore(
            &response["todo_state"],
            same_runtime,
            self.running,
            !deferred,
        );
    }

    pub fn replace_history(&mut self, messages: Option<&Vec<Value>>, display: Option<&Vec<Value>>) {
        self.todos
            .replace_history(messages.map(Vec::as_slice), display.map(Vec::as_slice));
        let observed_tools: HashMap<_, _> = self
            .rows
            .iter()
            .chain(&self.live)
            .filter_map(|row| match row {
                Row::Tool(tool) if !tool.id.is_empty() && !tool.output.is_empty() => {
                    Some((tool.id.clone(), tool.output.clone()))
                }
                _ => None,
            })
            .collect();
        self.rows.clear();
        self.user_row_ids.clear();
        let raw_tools: HashMap<_, _> = messages
            .into_iter()
            .flatten()
            .filter(|row| row["role"] == "tool")
            .filter_map(|row| row["tool_call_id"].as_str().map(|id| (id, &row["content"])))
            .collect();
        self.rows_from(display.or(messages), &raw_tools, &observed_tools);
        self.deduplicate_live_prompt();
    }

    fn deduplicate_live_prompt(&mut self) {
        while self
            .rows
            .last()
            .and_then(Row::prompt_text)
            .zip(self.live.first().and_then(Row::prompt_text))
            .is_some_and(|(saved, live)| saved == live)
        {
            self.live.remove(0);
        }
    }

    fn project_inflight(&mut self, inflight: &Value) {
        let assistant = string(inflight, "assistant");
        let corrections = inflight["corrections"]
            .as_array()
            .map_or(&[][..], Vec::as_slice);
        let positions: Vec<_> = assistant
            .char_indices()
            .map(|(index, _)| index)
            .chain(std::iter::once(assistant.len()))
            .collect();
        let mut start = 0;
        for (index, correction) in corrections.iter().enumerate() {
            let Some(correction) = correction.as_str().filter(|text| !text.trim().is_empty())
            else {
                continue;
            };
            let end = inflight["correction_offsets"][index]
                .as_u64()
                .and_then(|position| positions.get(position as usize))
                .copied()
                .unwrap_or(assistant.len())
                .max(start);
            if start < end {
                self.live.push(Row::Answer(Answer::live(Message::new(
                    assistant[start..end].to_owned().into(),
                    false,
                ))));
            }
            if !matches!(self.rows.last().filter(|_| start == 0), Some(Row::User(last)) if last.raw().as_ref() == correction)
            {
                self.live.push(Row::User(correction.to_owned().into()));
            }
            start = end;
        }
        self.stream = assistant[start..].to_owned();
        self.offset = self.stream.encode_utf16().count();
    }

    pub fn recover_running(&mut self, response: &Value, through: u64) {
        if response["snapshot_required"] == true || response["truncated"] == true {
            return;
        }
        let events = response["events"].as_array().map_or(&[][..], Vec::as_slice);
        let start = events.iter().rposition(|event| {
            event["type"] == "message.start"
                && event["seq"].as_u64().unwrap_or_default() <= through
                && event["execution_generation"]
                    .as_u64()
                    .is_none_or(|generation| generation == self.generation)
        });
        if let Some(start) = start {
            self.seq = events[start]["seq"]
                .as_u64()
                .unwrap_or_default()
                .saturating_sub(1);
            for event in &events[start..] {
                self.apply(event);
            }
        }
        if let Some(requests) = response["open_requests"].as_array() {
            for request in requests {
                self.server_request(request);
            }
        }
    }

    fn rows_from(
        &mut self,
        messages: Option<&Vec<Value>>,
        raw_tools: &HashMap<&str, &Value>,
        observed_tools: &HashMap<String, SharedString>,
    ) {
        let mut tool_indices = HashMap::new();
        for row in messages.into_iter().flatten() {
            if row["display_kind"] == "hidden" {
                continue;
            }
            let role = string(row, "role");
            let value = row
                .get("display_content")
                .or_else(|| row.get("text"))
                .filter(|value| !value.is_null())
                .unwrap_or(&row["content"]);
            let mut body = text(value);
            if role == "system"
                && let Some(receipt) = crate::command_receipt::CommandReceipt::from_system(&body)
            {
                self.rows.push(Row::Command(receipt));
                continue;
            }
            if matches!(role, "user" | "assistant")
                && let Some(parts) = value.as_array()
            {
                for source in parts.iter().filter_map(image_part_reference) {
                    if source.contains(['\n', '\r']) {
                        continue;
                    }
                    body.push_str("\n@image:");
                    body.push_str(source);
                }
            }
            if matches!(role, "user" | "system") {
                let original = row["content"].as_str().unwrap_or_default();
                if let Some(notice) = BackgroundNotice::project(
                    if original.trim().is_empty() {
                        &body
                    } else {
                        original
                    },
                    row,
                ) {
                    self.rows.push(Row::Background(notice));
                    continue;
                }
            }
            match role {
                "user" if !body.is_empty() => {
                    if let Some(id) = row["row_id"]
                        .as_u64()
                        .or_else(|| row["id"].as_u64())
                        .filter(|id| *id > 0)
                    {
                        self.user_row_ids.insert(self.rows.len(), id);
                    }
                    self.rows.push(Row::User(body.into()));
                }
                "assistant" => {
                    let reasoning = crate::reasoning::message_reasoning(row);
                    if !reasoning.is_empty() {
                        self.rows.push(Row::Reasoning(reasoning.into()));
                    }
                    if !body.is_empty() {
                        let timestamp = row["timestamp"]
                            .as_f64()
                            .filter(|at| at.is_finite() && *at > 0.);
                        let stored_id = row["row_id"]
                            .as_u64()
                            .or_else(|| row["id"].as_u64())
                            .filter(|id| *id > 0);
                        self.rows.push(Row::Answer(Answer {
                            body: Message::new(body.into(), false),
                            timestamp,
                            stored_id,
                        }));
                    }
                    for call in row["tool_calls"].as_array().into_iter().flatten() {
                        let tool = &call["function"];
                        let mut row = Tool::from_payload(tool, false);
                        row.id = string(call, "id").to_owned();
                        if !row.id.is_empty() {
                            tool_indices.insert(row.id.clone(), self.rows.len());
                        }
                        self.rows.push(Row::Tool(row));
                    }
                }
                "tool" => {
                    let mut update = Tool::from_payload(row, true);
                    if let Some(content) = raw_tools
                        .get(update.id.as_str())
                        .filter(|content| !content.is_null())
                    {
                        update.set_output(text(content).into());
                    }
                    if update.output.is_empty() {
                        if let Some(output) = observed_tools.get(&update.id) {
                            update.set_output(output.clone());
                        }
                    }
                    if let Some(Row::Tool(tool)) = tool_indices
                        .remove(&update.id)
                        .and_then(|index| self.rows.get_mut(index))
                    {
                        tool.finish(update);
                    } else {
                        self.rows.push(Row::Tool(update));
                    }
                }
                _ => {}
            }
        }
    }

    pub fn missing_prompt_sequence(&self) -> Option<u64> {
        self.missing_prompt.map(|(sequence, _)| sequence)
    }

    pub fn supply_turn_prompt(&mut self, sequence: u64, text: &str, source: &Value) {
        let Some((start, index)) = self.missing_prompt else { return };
        if start == sequence && self.running && !text.is_empty() && index <= self.live.len() {
            self.missing_prompt = None;
            if source["display_kind"] != "hidden" {
                self.live.insert(index, Row::wire_prompt(text, source));
                self.deduplicate_live_prompt();
            }
        }
    }

    fn update_pending(&mut self, pending: &Value) {
        let Some(pending) = pending.as_array() else {
            return;
        };
        self.queued.clear();
        self.unknown.clear();
        for item in pending {
            let id = string(item, "admission_id").to_owned();
            let body = string(item, "text").to_owned().into();
            match string(item, "status") {
                "queued" => {
                    let can_replace = item["controls"].as_array().is_some_and(|controls| {
                        controls.iter().any(|control| control == "replace")
                    });
                    self.record_queue(
                        id,
                        body,
                        item["sequence"].as_u64().unwrap_or(u64::MAX),
                        can_replace,
                    );
                }
                "started" if item["steering"] != true => {
                    if let Some(sequence) = self.missing_prompt_sequence() {
                        self.supply_turn_prompt(sequence, string(item, "text"), item);
                    }
                }
                "unknown" => {
                    if let Some(generation) = item["execution_generation"].as_u64() {
                        self.unknown.insert(id, (generation, body));
                    }
                }
                _ => {}
            }
        }
    }

    pub fn record_queue(
        &mut self,
        id: String,
        text: SharedString,
        sequence: u64,
        can_replace: bool,
    ) {
        self.queued.retain(|entry| entry.id != id);
        self.queued.push(QueuedTurn {
            id,
            text,
            sequence,
            can_replace,
        });
        self.queued.sort_by_key(|entry| entry.sequence);
    }

    pub fn take_queued(&mut self, id: &str) -> Option<QueuedTurn> {
        let index = self.queued.iter().position(|entry| entry.id == id)?;
        Some(self.queued.remove(index))
    }

    pub fn canonical_prompt(&mut self, kind: &str, value: &Value) {
        let id = string(value, "prompt_id").to_owned();
        if id.is_empty() {
            return;
        }
        let route = PromptRoute::Canonical {
            id: id.clone(),
            generation: value["execution_generation"]
                .as_u64()
                .unwrap_or(self.generation),
            kind: kind.to_owned(),
        };
        self.prompts
            .insert(id, Prompt::from_wire(kind, value, route));
    }

    pub fn server_request(&mut self, frame: &Value) -> bool {
        let kind = string(frame, "method");
        if !matches!(kind, "approval" | "clarify") {
            return false;
        }
        let params = &frame["params"];
        let id = frame["id"]
            .as_str()
            .map(str::to_owned)
            .unwrap_or_else(|| frame["id"].to_string());
        let key = params["request_id"].as_str().unwrap_or(&id).to_owned();
        self.prompts.insert(
            key,
            Prompt::from_wire(kind, params, PromptRoute::Request(frame["id"].clone())),
        );
        true
    }

    pub fn apply(&mut self, event: &Value) {
        let seq = event["seq"].as_u64().unwrap_or(0);
        if seq > 0 && seq <= self.seq {
            return;
        }
        self.seq = self.seq.max(seq);
        let kind = string(event, "type");
        let payload = &event["payload"];
        if matches!(kind, "message.start" | "message.delta" | "message.complete" | "tool.start" | "tool.complete") {
            self.last_turn_activity = Some(std::time::Instant::now());
        }
        let agent_event = matches!(
            kind,
            "subagent.spawn_requested"
                | "subagent.start"
                | "subagent.progress"
                | "subagent.tool"
                | "subagent.complete"
        );
        if agent_event {
            self.activity.agent_event(kind, payload);
            return;
        }
        if let Some(generation) = event["execution_generation"].as_u64() {
            if generation < self.generation && !matches!(kind, "session.title" | "session.updated")
            {
                return;
            }
            self.generation = generation;
        }
        match kind {
            "message.start" => {
                let turn = string(payload, "turn_id");
                if !turn.is_empty() && self.turn == turn {
                    return;
                }
                self.seal();
                self.turn = turn.to_owned();
                self.segment = None;
                self.offset = 0;
                self.running = true;
                self.todos.live_in_turn = false;
                let id = event["admission_id"]
                    .as_str()
                    .or_else(|| payload["admission_id"].as_str());
                let queued = self.take_queued(id.unwrap_or_default());
                let given = string(payload, "text");
                let user = if given.is_empty() {
                    queued.as_ref().map_or("", |row| row.text.as_ref())
                } else {
                    given
                };
                self.missing_prompt = (user.is_empty()
                    && !self.live.last().is_some_and(|last| last.prompt_text().is_some()))
                    .then_some((seq, self.live.len()));
                if !user.is_empty()
                    && !self.live.last().or_else(|| self.rows.last()).is_some_and(|last| {
                        last.prompt_text() == Some(user) ||
                            matches!(last, Row::User(last) if last.display().as_ref() == user)
                    })
                {
                    self.live.push(Row::wire_prompt(user, payload));
                }
            }
            "message.delta" => {
                self.running = true;
                let segment = payload["segment"].as_u64();
                if let (Some(last), Some(next)) = (self.segment, segment) {
                    if next < last {
                        return;
                    }
                    if next > last {
                        self.seal();
                        self.offset = 0;
                    }
                }
                if segment.is_some() {
                    self.segment = segment;
                }
                if let Some(chunk) = payload["text"].as_str() {
                    let offset = payload["offset"]
                        .as_u64()
                        .map(|n| n as usize)
                        .unwrap_or(self.offset);
                    if offset > self.offset {
                        // The next snapshot must rebuild this stream even if its generation is unchanged.
                        self.seq = 0;
                        self.refresh = true;
                        return;
                    }
                    let mut remaining = self.offset.saturating_sub(offset);
                    let mut start = 0;
                    for ch in chunk.chars() {
                        if remaining == 0 {
                            break;
                        }
                        remaining = remaining.saturating_sub(ch.len_utf16());
                        start += ch.len_utf8();
                    }
                    self.stream.push_str(&chunk[start..]);
                    self.offset = self.offset.max(offset + chunk.encode_utf16().count());
                }
            }
            "message.interim" => {
                let segment = payload["segment"].as_u64();
                if matches!((segment, self.segment), (Some(a), Some(b)) if a < b) {
                    return;
                }
                let value = string(payload, "text");
                if !value.is_empty() {
                    self.stream = value.to_owned();
                }
                self.seal();
                self.offset = 0;
                self.segment = segment.map(|n| n + 1);
            }
            "reasoning.delta" | "thinking.delta" => {
                self.reasoning.push_str(string(payload, "text"))
            }
            "reasoning.available" => {
                let value = string(payload, "text");
                if !value.trim().is_empty() {
                    self.reasoning = value.to_owned();
                }
            }
            "tool.start" => {
                self.seal_reasoning();
                self.live
                    .push(Row::Tool(Tool::from_payload(payload, false)));
            }
            "todo.updated" => {
                if self.todos.apply(payload) {
                    self.todos.live_in_turn = self.running;
                }
            }
            "tool.complete" => {
                if crate::session_todos::is_todo_tool(
                    payload["name"]
                        .as_str()
                        .or_else(|| payload["tool_name"].as_str())
                        .unwrap_or_default(),
                    payload.get("args").unwrap_or(&payload["arguments"]),
                ) && self.todos.apply(payload)
                {
                    self.todos.live_in_turn = self.running;
                }
                let update = Tool::from_payload(payload, true);
                if let Some(Row::Tool(tool)) = self.live.iter_mut().rev()
                    .find(|row| matches!(row, Row::Tool(tool) if !tool.id.is_empty() && tool.id == update.id))
                {
                    tool.finish(update);
                } else {
                    self.live.push(Row::Tool(update));
                }
            }
            "message.complete" => {
                self.update_context(payload);
                let final_text = text(&payload["text"]);
                if !final_text.is_empty() && payload["response_reused"] != true {
                    self.stream = final_text;
                }
                self.seal();
                self.running = false;
                self.missing_prompt = None;
                self.todos.live_in_turn = false;
                self.prompts.clear();
                let error = payload["error"]
                    .as_str()
                    .or_else(|| payload["warning"].as_str())
                    .unwrap_or_default();
                self.turn_error = (!error.is_empty()).then(|| error.to_owned());
                self.refresh = true;
            }
            "approval.request" if payload["prompt_id"].is_null() => {
                let id = string(payload, "request_id").to_owned();
                self.prompts.entry(id.clone()).or_insert_with(|| {
                    Prompt::from_wire("approval", payload, PromptRoute::LegacyApproval(id))
                });
            }
            "approval.request" => self.canonical_prompt("approval", payload),
            "clarify.request" => self.canonical_prompt("clarify", payload),
            "approval.settled" | "clarify.settled" => {
                self.prompts.remove(string(payload, "prompt_id"));
            }
            "approval.cancelled" => {
                self.prompts.remove(string(payload, "request_id"));
            }
            "request.cancel" => {
                let id = &payload["id"];
                self.prompts.retain(|_, prompt| !matches!(&prompt.route, PromptRoute::Request(other) if id == other));
            }
            "session.info" | "session.updated" => {
                self.update_workspace(payload);
                if let Some(model) = payload["model"]
                    .as_str()
                    .or_else(|| payload["committed_model"].as_str())
                {
                    self.update_model(model);
                }
                self.update_context(payload);
                self.clear_applied_choices();
                self.update_pending(&payload["pending"]);
                if kind == "session.info" && self.running && payload["running"] == false {
                    // Confirm the idle edge (and the queue) together in a fresh owner snapshot.
                    self.refresh = true;
                }
                if let Some(generation) = payload["execution_generation"].as_u64() {
                    self.generation = self.generation.max(generation);
                }
            }
            "session.usage" => self.update_context(payload),
            "error" | "notice" => {
                if let Some(message) = payload["message"]
                    .as_str()
                    .or_else(|| payload["text"].as_str())
                {
                    self.live.push(Row::Notice(message.to_owned().into()));
                }
            }
            _ => {}
        }
    }

    fn update_workspace(&mut self, info: &Value) {
        if let Some(provider) = info["provider"].as_str()
            && !provider.is_empty()
            && provider != self.provider.as_ref()
        {
            self.context = None;
        }
        if !info
            .as_object()
            .is_some_and(|info| info.contains_key("service_tier"))
            && let Some(fast) = info["fast"].as_bool()
        {
            self.speed = if fast { "fast".into() } else { "normal".into() };
        }
        for (field, key) in [
            (&mut self.branch, "branch"),
            (&mut self.cwd, "cwd"),
            (&mut self.provider, "provider"),
            (&mut self.effort, "reasoning_effort"),
            (&mut self.effort_on_wire, "reasoning_effort_wire"),
            (&mut self.speed, "service_tier"),
        ] {
            if let Some(value) = info.get(key) {
                *field = SharedString::from(value.as_str().unwrap_or_default().to_owned());
            }
        }
    }

    pub fn update_model(&mut self, model: &str) {
        if !model.is_empty() && model != self.model.as_ref() {
            self.model = model.to_owned().into();
            self.context = None;
        }
    }

    pub fn update_context(&mut self, value: &Value) {
        let stats = value.get("usage").unwrap_or(value);
        let model = stats["model"].as_str().or_else(|| value["model"].as_str());
        if model.is_some_and(|model| {
            !model.is_empty() && !self.model.is_empty() && model != self.model.as_ref()
        }) {
            return;
        }
        let Some(used) = stats["context_used"]
            .as_u64()
            .or_else(|| stats["last_prompt_tokens"].as_u64())
        else {
            return;
        };
        let Some(maximum) = stats["context_max"]
            .as_u64()
            .or_else(|| stats["context_length"].as_u64())
            .filter(|value| *value > 0)
        else {
            return;
        };
        let estimated = stats["context_estimated"] == true
            || stats["context_source"]
                .as_str()
                .is_some_and(|source| !source.is_empty() && source != "provider_usage");
        if used == 0 && (self.context.is_some() || stats["estimated_total"] == 0) {
            return;
        }
        self.context = Some(ContextUsage {
            used,
            maximum,
            estimated,
            cache_hit: stats["cache_hit_pct"].as_f64(),
        });
    }

    fn clear_applied_choices(&mut self) {
        if self.next_model.as_ref().is_some_and(|model| {
            self.model.as_ref() == model.id
                && (self.provider.is_empty() || self.provider.as_ref() == model.provider)
        }) {
            self.next_model = None;
        }
        if self
            .next_effort
            .as_ref()
            .is_some_and(|effort| self.effort.as_ref() == effort)
        {
            self.next_effort = None;
        }
    }
}

#[derive(Clone, Copy)]
pub struct ContextUsage {
    pub used: u64,
    pub maximum: u64,
    pub estimated: bool,
    pub cache_hit: Option<f64>,
}
