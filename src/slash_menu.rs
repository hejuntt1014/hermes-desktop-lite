use crate::theme::{ink, rgb, rgba};

use crate::i18n::text as tr;

use std::{
    collections::{HashMap, VecDeque},
    time::Duration,
};

use gpui::{
    ClipboardItem, Context, Div, EntityInputHandler, Focusable, ScrollHandle, SharedString, Task,
    Window, div, prelude::*, px,
};
use serde_json::{Value, json};

use crate::{
    session::{Row, SessionTarget, Summary, string},
    settings::{Prepared, SkillSubmission},
    style::{ACCENT, INK, MUTED},
};

use super::{Call, Desktop, model_controls::Picker, rpc_error};

const SKILL_GROUP: &str = "技能";

const GROUPS: &[&str] = &[
    "会话",
    "配置",
    "工具与技能",
    "信息",
    "自定义命令",
    "插件命令",
    SKILL_GROUP,
];
const LOCAL_COMMANDS: &[(&str, &str, &str)] = &[
    ("new", "新开一个聊天标签", "会话"),
    ("resume", "查找并打开历史会话", "会话"),
    ("find", "在当前会话中查找", "会话"),
    ("branch", "将当前会话分叉到新标签", "会话"),
    ("title", "重命名当前会话", "会话"),
    ("save", "保存当前会话", "会话"),
    ("stop", "停止当前回复", "会话"),
    ("agents", "查看当前会话的后台工作", "会话"),
    ("model", "选择对话模型", "配置"),
    ("reasoning", "设置推理强度和思考显示", "配置"),
    ("settings", "打开设置", "配置"),
    ("files", "查看工作区文件", "工具与技能"),
    ("review", "审查工作区改动", "工具与技能"),
    ("cron", "管理当前 Profile 的定时任务", "工具与技能"),
    ("copy", "复制最后一条助手回复", "信息"),
    ("version", "查看网关版本", "信息"),
    ("help", "浏览会话和快捷操作", "信息"),
    ("commands", "浏览斜杠命令和技能", "信息"),
];

const REMOTE_COMMANDS: &[(&str, &str, &str)] = &[
    ("status", "查看会话和模型状态", "会话"),
    ("context", "查看上下文用量和压缩信息", "会话"),
    ("personality", "查看或选择会话人格", "配置"),
    ("profile", "查看当前 Profile", "信息"),
    ("usage", "查看用量和限额", "信息"),
    ("whoami", "查看当前命令权限", "信息"),
    ("diff", "查看工作区差异", "信息"),
    ("bundles", "列出技能组合", "工具与技能"),
    ("skills", "查看待审核的技能", "工具与技能"),
    ("memory", "查看待审核的记忆", "工具与技能"),
    ("suggestions", "查看自动化建议", "工具与技能"),
];

const REASONING_EFFORTS: &[&str] = &[
    "none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra",
];
const REASONING_DISPLAY: &[&str] = &["show", "hide", "on", "off", "full", "clamp"];

#[derive(Clone, PartialEq, Eq)]
pub(super) struct Scope {
    pub(super) draft: String,
    runtime: String,
    pub(super) profile: String,
}

#[derive(Clone, PartialEq, Eq)]
pub(super) struct Lookup {
    scope: Scope,
    text: String,
    catalog: bool,
    arguments: bool,
    preserve_draft: bool,
}

#[derive(Clone)]
struct Choice {
    name: String,
    hint: SharedString,
    skill: bool,
    group: &'static str,
    options: Vec<String>,
    browse: bool,
}

impl Choice {
    fn new(name: &str, hint: &str, group: &'static str, skill: bool) -> Self {
        Self {
            name: name.to_owned(),
            hint: hint.to_owned().into(),
            skill,
            group,
            options: Vec::new(),
            browse: true,
        }
    }
}

#[derive(Default)]
enum CatalogStatus {
    #[default]
    Loading,
    Ready,
    Unavailable,
}

#[derive(Default)]
pub(super) struct SlashMenu {
    query: Option<Lookup>,
    dismissed: Option<Lookup>,
    rows: Vec<Choice>,
    cursor: usize,
    explicit: bool,
    scroll: ScrollHandle,
    debounce: Option<Task<()>>,
    catalogs: VecDeque<(Scope, Vec<Choice>)>,
    catalog_status: CatalogStatus,
    outputs: HashMap<String, (String, SharedString)>,
}

impl Desktop {
    fn command_scope(&self) -> Scope {
        let session = self
            .selected
            .as_ref()
            .and_then(|key| self.sessions.get(key))
            .filter(|session| session.attached && !session.loading);
        Scope {
            draft: self.key(),
            runtime: session
                .map(|session| session.runtime.clone())
                .unwrap_or_default(),
            profile: session
                .map(|session| session.profile.clone())
                .unwrap_or_else(|| self.model_profile()),
        }
    }

    pub(super) fn slash_changed(&mut self, text: &str, cx: &mut Context<Self>) {
        let Some(query) = text.strip_prefix('/').filter(|query| query.len() < 100) else {
            self.slash_menu.query = None;
            self.slash_menu.debounce = None;
            self.slash_menu.dismissed = None;
            return;
        };
        let arguments = self.slash_argument(text).is_some();
        if !arguments && !query.is_empty() && !valid_name(query) {
            self.slash_menu.query = None;
            self.slash_menu.debounce = None;
            self.slash_menu.dismissed = None;
            return;
        }
        let scope = self.command_scope();
        let lookup = Lookup {
            scope,
            text: text.to_owned(),
            catalog: query.is_empty(),
            arguments,
            preserve_draft: false,
        };
        if self.slash_menu.query.as_ref() == Some(&lookup) {
            return;
        }
        self.start_slash_lookup(lookup, cx);
    }

    pub(super) fn open_slash_picker(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.out.is_none() {
            return;
        }
        let value = self.composer.read(cx).value();
        self.composer.update(cx, |field, cx| {
            if value.is_empty() {
                field.replace("/", window, cx);
            }
            field.focus(window, cx);
        });
        self.dismiss_reference(cx);
        if value.is_empty()
            || self.slash_argument(&value).is_some()
            || value
                .strip_prefix('/')
                .is_some_and(|query| query.is_empty() || valid_name(query))
        {
            self.slash_changed(if value.is_empty() { "/" } else { &value }, cx);
            self.slash_menu.dismissed = None;
        } else {
            self.start_slash_lookup(
                Lookup {
                    scope: self.command_scope(),
                    text: "/".to_owned(),
                    catalog: true,
                    arguments: false,
                    preserve_draft: true,
                },
                cx,
            );
        }
        cx.notify();
    }

    fn start_slash_lookup(&mut self, lookup: Lookup, cx: &mut Context<Self>) {
        self.slash_menu.query = Some(lookup.clone());
        self.slash_menu.dismissed = None;
        self.slash_menu.cursor = 0;
        self.slash_menu.explicit = false;
        self.slash_menu.scroll = ScrollHandle::new();
        self.slash_menu.debounce = None;
        self.slash_menu.catalog_status = CatalogStatus::Loading;
        self.collect_slash_rows(&lookup, Vec::new());
        if self.out.is_some() {
            self.slash_menu.debounce = Some(cx.spawn(async move |handle, cx| {
                cx.background_executor()
                    .timer(Duration::from_millis(70))
                    .await;
                let _ = handle.update(cx, |this, _| this.request_slash(lookup));
            }));
        }
    }

    pub(super) fn refresh_slash_connection(&mut self, cx: &mut Context<Self>) {
        self.slash_menu.query = None;
        let text = self.composer.read(cx).value();
        self.slash_changed(&text, cx);
    }

    pub(super) fn refresh_slash_scope(&mut self, cx: &mut Context<Self>) {
        let Some(query) = self.slash_menu.query.clone() else {
            return;
        };
        let scope = self.command_scope();
        if query.scope.draft == scope.draft && query.scope != scope {
            self.start_slash_lookup(Lookup { scope, ..query }, cx);
            cx.notify();
        }
    }

    fn request_slash(&mut self, lookup: Lookup) {
        if self.slash_menu.query.as_ref() != Some(&lookup) || self.command_scope() != lookup.scope {
            return;
        }
        let mut params = json!({});
        if !lookup.scope.runtime.is_empty() {
            params["session_id"] = json!(lookup.scope.runtime);
        }
        if !lookup.scope.profile.is_empty() {
            params["profile"] = json!(lookup.scope.profile);
        }
        if !lookup.catalog
            && !lookup.arguments
            && !self
                .slash_menu
                .catalogs
                .iter()
                .any(|(scope, _)| scope == &lookup.scope)
        {
            let mut catalog = lookup.clone();
            catalog.catalog = true;
            self.call(
                "commands.catalog",
                params.clone(),
                Call::SlashSuggestions(catalog),
            );
        }
        let method = if lookup.catalog {
            "commands.catalog"
        } else {
            params["text"] = json!(lookup.text);
            "complete.slash"
        };
        if !self.call(method, params, Call::SlashSuggestions(lookup.clone())) {
            self.slash_lookup_failed(&lookup);
        }
    }

    fn slash_argument<'a>(&self, text: &'a str) -> Option<(&'a str, &'a str)> {
        let (command, tail) = split_argument(text)?;
        let name = command.trim_start_matches('/');
        let offers = command.eq_ignore_ascii_case("/reasoning")
            || command.eq_ignore_ascii_case("/save")
            || self
                .slash_menu
                .catalogs
                .iter()
                .find(|(scope, _)| *scope == self.command_scope())
                .is_some_and(|(_, rows)| {
                    rows.iter()
                        .any(|row| row.name.eq_ignore_ascii_case(name) && !row.options.is_empty())
                });
        offers.then_some((command, tail))
    }

    pub(super) fn slash_lookup_failed(&mut self, lookup: &Lookup) {
        if self.slash_menu.query.as_ref() == Some(lookup) {
            self.slash_menu.catalog_status = CatalogStatus::Unavailable;
        }
    }

    pub(super) fn slash_response(
        &mut self,
        lookup: Lookup,
        response: &Value,
        cx: &mut Context<Self>,
    ) {
        if lookup.arguments {
            if self.slash_menu.query.as_ref() != Some(&lookup)
                || self.command_scope() != lookup.scope
            {
                return;
            }
            let args: Vec<_> = response["items"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|item| {
                    let name = item["text"].as_str()?;
                    valid_name(name).then(|| Choice::new(name, string(item, "meta"), "", false))
                })
                .collect();
            self.slash_menu.catalog_status = CatalogStatus::Ready;
            self.collect_slash_rows(&lookup, args);
            cx.notify();
            return;
        }
        let choices = if lookup.catalog {
            catalog_choices(response)
        } else {
            response["items"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|item| {
                    let name = item["text"].as_str()?.trim_start_matches('/');
                    (item["kind"] == "skill" && valid_name(name))
                        .then(|| Choice::new(name, string(item, "meta"), SKILL_GROUP, true))
                })
                .collect()
        };
        let previous = self
            .slash_menu
            .catalogs
            .iter()
            .position(|(scope, _)| scope == &lookup.scope);
        if lookup.catalog || previous.is_some() || !choices.is_empty() {
            let mut known = previous
                .and_then(|index| self.slash_menu.catalogs.remove(index))
                .map(|(_, rows)| rows)
                .unwrap_or_default();
            if lookup.catalog {
                known = choices;
            } else {
                for choice in choices {
                    if !known
                        .iter()
                        .any(|row| row.name.eq_ignore_ascii_case(&choice.name))
                    {
                        known.push(choice);
                    }
                }
            }
            self.slash_menu
                .catalogs
                .push_back((lookup.scope.clone(), known));
            if self.slash_menu.catalogs.len() > 12 {
                self.slash_menu.catalogs.pop_front();
            }
        }
        let current = self.slash_menu.query.clone().filter(|current| {
            !current.arguments
                && current.scope == lookup.scope
                && (lookup.catalog || current == &lookup)
                && self.command_scope() == lookup.scope
        });
        if let Some(current) = current {
            self.slash_menu.catalog_status = CatalogStatus::Ready;
            self.collect_slash_rows(&current, Vec::new());
            cx.notify();
        }
    }

    fn collect_slash_rows(&mut self, lookup: &Lookup, matched: Vec<Choice>) {
        let old = self
            .slash_menu
            .rows
            .get(self.slash_menu.cursor)
            .map(|row| row.name.clone());
        let catalog = self
            .slash_menu
            .catalogs
            .iter()
            .find(|(scope, _)| scope == &lookup.scope)
            .map(|(_, choices)| choices.as_slice())
            .unwrap_or_default();
        let mut rows = if lookup.arguments {
            let (command, needle) = split_argument(&lookup.text).unwrap_or_default();
            let name = command.trim_start_matches('/');
            let needle = needle.to_lowercase();
            let options: Vec<&str> = match name.to_ascii_lowercase().as_str() {
                "reasoning" => REASONING_EFFORTS
                    .iter()
                    .chain(REASONING_DISPLAY)
                    .copied()
                    .collect(),
                "save" => vec!["md", "json"],
                _ => catalog
                    .iter()
                    .find(|row| row.name.eq_ignore_ascii_case(name))
                    .map(|row| row.options.iter().map(String::as_str).collect())
                    .unwrap_or_default(),
            };
            options
                .into_iter()
                .filter(|option| option.to_lowercase().starts_with(&needle))
                .map(|option| {
                    let hint = matched
                        .iter()
                        .find(|row| row.name == option && !row.hint.is_empty())
                        .map_or_else(|| reasoning_option_hint(option), |row| row.hint.as_ref());
                    Choice::new(option, hint, "", false)
                })
                .collect::<Vec<_>>()
        } else {
            let needle = lookup.text[1..].to_lowercase();
            let local = LOCAL_COMMANDS
                .iter()
                .filter(|_| !lookup.preserve_draft)
                .filter(|(name, _, _)| !needs_session(name) || !lookup.scope.runtime.is_empty())
                .map(|&(name, hint, group)| Choice::new(name, hint, group, false));
            let server = catalog
                .iter()
                .filter(|row| !lookup.preserve_draft || row.group == SKILL_GROUP)
                .filter(|row| row.skill || !lookup.scope.runtime.is_empty())
                .cloned();
            let mut visible: Vec<Choice> = Vec::new();
            for row in local.chain(server).filter(|row| {
                if needle.is_empty() {
                    row.browse
                } else {
                    row.name.to_lowercase().contains(&needle)
                        || tr(row.hint.as_ref()).to_lowercase().contains(&needle)
                }
            }) {
                if !visible
                    .iter()
                    .any(|other| other.name.eq_ignore_ascii_case(&row.name))
                {
                    visible.push(row);
                }
            }
            visible
        };
        if !lookup.arguments {
            rows.sort_by_key(|row| {
                GROUPS
                    .iter()
                    .position(|group| *group == row.group)
                    .unwrap_or(GROUPS.len())
            });
        }
        self.slash_menu.cursor = old
            .as_ref()
            .and_then(|name| rows.iter().position(|row| &row.name == name))
            .unwrap_or(0);
        self.slash_menu.rows = rows;
    }

    pub(super) fn slash_is_open(&self, window: &Window, cx: &Context<Self>) -> bool {
        self.out.is_some()
            && self.slash_menu.query != self.slash_menu.dismissed
            && self.slash_menu.query.as_ref().is_some_and(|query| {
                query.scope.draft == self.key()
                    && (query.preserve_draft || !self.slash_menu.rows.is_empty())
            })
            && self.composer.read(cx).focus_handle(cx).is_focused(window)
            && !self.settings_open
            && !self.palette.open
            && !self.media.is_open()
            && self.rewrite_editor.is_none()
    }

    pub(super) fn move_slash(&mut self, previous: bool, cx: &mut Context<Self>) {
        let count = self.slash_menu.rows.len();
        if count == 0 {
            return;
        }
        let cursor = self.slash_menu.cursor;
        self.slash_menu.cursor = if previous {
            (cursor + count - 1) % count
        } else {
            (cursor + 1) % count
        };
        self.slash_menu.explicit = true;
        let headers = self
            .slash_menu
            .rows
            .iter()
            .take(self.slash_menu.cursor + 1)
            .enumerate()
            .filter(|(index, row)| {
                !row.group.is_empty()
                    && (*index == 0 || self.slash_menu.rows[*index - 1].group != row.group)
            })
            .count();
        self.slash_menu
            .scroll
            .scroll_to_item(1 + self.slash_menu.cursor + headers);
        cx.notify();
    }

    pub(super) fn dismiss_slash(&mut self, cx: &mut Context<Self>) {
        self.slash_menu.dismissed = self.slash_menu.query.clone();
        cx.notify();
    }

    pub(super) fn choose_slash(
        &mut self,
        index: Option<usize>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.slash_is_open(window, cx) {
            return;
        }
        let Some(choice) = self
            .slash_menu
            .rows
            .get(index.unwrap_or(self.slash_menu.cursor))
            .cloned()
        else {
            return;
        };
        if choice.skill {
            let key = self.key();
            self.workspace_mut()
                .draft_skills
                .insert(key, choice.name.clone());
        }
        let query = self
            .slash_menu
            .query
            .as_ref()
            .expect("checked by slash_is_open");
        let value = if query.arguments {
            let (command, _) = split_argument(&query.text).unwrap_or_default();
            format!("{command} {} ", choice.name)
        } else {
            format!("/{} ", choice.name)
        };
        let preserve = query.preserve_draft;
        let expand = !query.arguments
            && !preserve
            && !choice.skill
            && (matches!(choice.name.as_str(), "reasoning" | "save") || !choice.options.is_empty());
        self.slash_menu.query = None;
        self.slash_menu.debounce = None;
        self.composer.update(cx, |field, cx| {
            if preserve {
                field.replace_text_in_range(Some(0..0), &value, window, cx);
            } else {
                let end = gpui_component::input::Position::new(0, value.chars().count() as u32);
                field.replace_all(value, window, cx);
                field.set_cursor_position(end, window, cx);
            }
            field.focus(window, cx);
        });
        if expand {
            let value = self.composer.read(cx).value();
            self.slash_changed(&value, cx);
        }
        cx.notify();
    }

    pub(super) fn complete_slash_before_send(
        &mut self,
        text: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if !self.slash_is_open(window, cx) {
            return false;
        }
        let choice = self.slash_menu.rows.get(self.slash_menu.cursor);
        if self
            .slash_menu
            .query
            .as_ref()
            .is_some_and(|query| query.arguments)
        {
            let (_, word) = split_argument(text).unwrap_or_default();
            if !self.slash_menu.explicit
                && self
                    .slash_menu
                    .rows
                    .iter()
                    .any(|row| row.name.eq_ignore_ascii_case(word))
            {
                return false;
            }
            self.choose_slash(None, window, cx);
            return true;
        }
        let typed = text.trim().trim_start_matches('/');
        if self.slash_menu.explicit
            || self
                .slash_menu
                .query
                .as_ref()
                .is_some_and(|query| query.preserve_draft)
            || choice.is_some_and(|row| {
                !typed.is_empty()
                    && (row.name.to_lowercase().contains(&typed.to_lowercase())
                        || row.hint.to_lowercase().contains(&typed.to_lowercase()))
                    && !self
                        .slash_menu
                        .rows
                        .iter()
                        .any(|row| row.name.eq_ignore_ascii_case(typed))
            })
        {
            self.choose_slash(None, window, cx);
            return true;
        }
        typed.is_empty()
    }

    pub(super) fn run_local_command(
        &mut self,
        text: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        let Some(body) = text.trim().strip_prefix('/') else {
            return false;
        };
        if !self.draft_files().is_empty() {
            return false;
        }
        let (name, arg) = body.split_once(char::is_whitespace).unwrap_or((body, ""));
        let name = name.to_ascii_lowercase();
        let command = match name.as_str() {
            "reset" => "new",
            "fork" => "branch",
            "sessions" | "switch" => "resume",
            "palette" => "help",
            "tasks" => "agents",
            "ctx" => "context",
            "v" => "version",
            name => name,
        };
        let arg = arg.trim();
        if command == "reasoning" && !arg.is_empty() {
            let value = arg.to_ascii_lowercase();
            let value = value.as_str();
            if REASONING_EFFORTS.contains(&value) {
                self.choose_slash_effort(value, window, cx);
            } else if REASONING_DISPLAY.contains(&value) {
                if !self.set_reasoning_display(value) {
                    return true;
                }
            } else {
                self.banner = Some(tr("未知的推理选项").into());
                cx.notify();
                return true;
            }
            self.composer
                .update(cx, |field, cx| field.set_value("", window, cx));
            self.draft_changed(cx);
            return true;
        }
        if REMOTE_COMMANDS.iter().any(|(name, _, _)| *name == command) {
            self.run_remote_slash(command, arg, window, cx);
            return true;
        }
        if !LOCAL_COMMANDS.iter().any(|(name, _, _)| *name == command) {
            return false;
        }
        if !arg.is_empty() && !matches!(command, "title" | "resume" | "save") {
            self.banner = Some(tr("此命令不需要参数").into());
            cx.notify();
            return true;
        }
        let summary = self.slash_session_summary();
        if needs_session(command) && summary.is_none() {
            self.banner = Some(tr("请先打开一个会话").into());
            cx.notify();
            return true;
        }
        if command == "save" && !matches!(arg.to_ascii_lowercase().as_str(), "" | "md" | "json") {
            self.banner = Some(tr("请输入 /save md 或 /save json").into());
            cx.notify();
            return true;
        }
        self.composer
            .update(cx, |field, cx| field.set_value("", window, cx));
        self.draft_changed(cx);
        self.slash_menu.query = None;
        match command {
            "new" => self.new_chat_tab(window, cx),
            "model" => self.picker_opened(Picker::Model, true, window, cx),
            "reasoning" => self.picker_opened(Picker::Effort, true, window, cx),
            "find" => self.open_transcript_find(window, cx),
            "files" => self.toggle_files(window, cx),
            "review" => self.toggle_review(window, cx),
            "settings" => self.toggle_settings(window, cx),
            "help" => self.toggle_palette(window, cx),
            "commands" => self.open_slash_picker(window, cx),
            "resume" => {
                self.toggle_palette(window, cx);
                if !arg.is_empty() && self.palette.open {
                    self.palette
                        .input
                        .update(cx, |field, cx| field.replace_all(arg, window, cx));
                }
            }
            "cron" => self.open_cron(None, window, cx),
            "branch" => self.branch_session(
                SessionTarget::from(summary.as_ref().unwrap()),
                None,
                window,
                cx,
            ),
            "title" => {
                let summary = summary.unwrap();
                if arg.is_empty() {
                    self.begin_rename(SessionTarget::from(&summary), window, cx);
                } else {
                    self.patch_session(
                        &summary.id,
                        &summary.profile,
                        json!({"title":arg}),
                        window,
                        cx,
                    );
                }
            }
            "copy" => {
                if let Some(text) = self.sessions.get(&self.key()).and_then(|session| {
                    session
                        .rows
                        .iter()
                        .chain(&session.live)
                        .rev()
                        .find_map(|row| match row {
                            Row::Answer(answer) => Some(answer.body.raw().to_string()),
                            _ => None,
                        })
                }) {
                    cx.write_to_clipboard(ClipboardItem::new_string(text));
                } else {
                    self.banner = Some(tr("暂无可复制的回复").into());
                }
            }
            "save" => self.export_session(
                SessionTarget::from(summary.as_ref().unwrap()),
                if arg.eq_ignore_ascii_case("json") {
                    super::session_export::ExportFormat::Json
                } else {
                    super::session_export::ExportFormat::Markdown
                },
                cx,
            ),
            "agents" => {
                if let Some(session) = self.sessions.get_mut(&self.key()) {
                    session.activity.processes_open = true;
                    session.activity.agents_open = true;
                    if !session.activity.has_work() {
                        self.banner = Some(tr("当前会话没有运行中的后台进程或子代理").into());
                    }
                }
                self.poll_work();
            }
            "version" => {
                let text = crate::i18n::format_text!(
                    "Hermes 网关 {}",
                    "Hermes gateway {}",
                    self.gateway_version.as_deref().unwrap_or(tr("版本未知"))
                );
                self.store_slash_output(self.key(), "version".into(), text);
            }
            "stop" => self.stop(),
            _ => unreachable!(),
        }
        cx.notify();
        true
    }

    fn slash_session_summary(&self) -> Option<Summary> {
        let id = self.selected.as_ref()?;
        let profile = self.model_profile();
        if let Some(row) = self
            .rows
            .iter()
            .find(|row| &row.id == id && row.profile == profile)
        {
            return Some(row.clone());
        }
        let tab = self
            .workspace()?
            .tabs
            .iter()
            .find(|tab| tab.session.as_ref() == Some(id))?;
        Summary::from_wire(&json!({"id":id,"profile":profile,"title":tab.title}))
    }

    fn run_remote_slash(
        &mut self,
        command: &str,
        arg: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let scope = self.command_scope();
        let Some(arg) = remote_argument(command, arg) else {
            self.banner = Some(tr("此命令只支持菜单中列出的选项").into());
            cx.notify();
            return;
        };
        if scope.runtime.is_empty() {
            self.banner = Some(tr("请等待会话恢复后再执行此命令").into());
            cx.notify();
            return;
        }
        if self
            .pending
            .values()
            .any(|call| matches!(call, Call::CatalogSlash(pending, _) if *pending == scope))
        {
            return;
        }
        let params = json!({"session_id":scope.runtime,"profile":scope.profile,"command":format!("/{command} {arg}")});
        if self.call(
            "slash.exec",
            params,
            Call::CatalogSlash(scope, command.to_owned()),
        ) {
            self.composer
                .update(cx, |field, cx| field.set_value("", window, cx));
            self.draft_changed(cx);
        }
    }

    pub(super) fn slash_result(
        &mut self,
        scope: Scope,
        command: String,
        response: &Value,
        error: Option<&Value>,
    ) {
        if self
            .sessions
            .get(&scope.draft)
            .is_none_or(|session| session.profile != scope.profile)
        {
            return;
        }
        let text = if let Some(error) = error {
            rpc_error(error)
        } else if response.is_null() {
            tr("未收到网关返回的命令结果").into()
        } else {
            [
                string(response, "warning"),
                string(response, "output"),
                string(response, "notice"),
            ]
            .into_iter()
            .filter(|text| !text.trim().is_empty())
            .collect::<Vec<_>>()
            .join("\n\n")
        };
        self.store_slash_output(scope.draft, command, text);
    }

    pub(super) fn store_slash_output(&mut self, key: String, command: String, text: String) {
        let text = if text.trim().is_empty() {
            tr("命令已完成").into()
        } else {
            text
        };
        if let Some(session) = self.sessions.get_mut(&key) {
            let after = session
                .rows
                .iter()
                .enumerate()
                .rev()
                .find_map(|(index, row)| session.display_row_id(index, row));
            let profile = session.profile.clone();
            let receipt = crate::command_receipt::CommandReceipt::recorded(after, command, &text);
            session.command_receipts.push(receipt.clone());
            self.workspace_mut()
                .command_receipts
                .entry(profile)
                .or_default()
                .entry(key.clone())
                .or_default()
                .push(receipt);
            if let Err(error) = self.settings.save() {
                self.banner = Some(
                    crate::i18n::format_text!(
                        "无法保存命令回执 · {error}",
                        "Could not save command result · {error}"
                    )
                    .into(),
                );
            }
            if self.selected.as_deref() == Some(key.as_str()) {
                self.timeline_raw_count = None;
                self.sync_list();
            }
            return;
        }
        let end = text.floor_char_boundary(text.len().min(32_000));
        self.slash_menu
            .outputs
            .insert(key, (command, text[..end].to_owned().into()));
    }

    fn set_reasoning_display(&mut self, value: &str) -> bool {
        let scope = self.command_scope();
        let mut params = json!({"key":"reasoning","value":value});
        if !scope.runtime.is_empty() {
            params["session_id"] = json!(scope.runtime);
        } else if self.selected.is_some() {
            self.banner = Some(tr("会话仍在恢复，请稍后再试").into());
            return false;
        }
        if !scope.profile.is_empty() {
            params["profile"] = json!(scope.profile);
        }
        self.call("config.set", params, Call::ReasoningDisplay(scope))
    }

    pub(super) fn skill_command(&self, text: &str) -> Option<SkillSubmission> {
        let text = text.trim().strip_prefix('/')?;
        let (name, argument) = text.split_once(char::is_whitespace).unwrap_or((text, ""));
        if !valid_name(name) || name.contains('/') {
            return None;
        }
        let scope = self.command_scope();
        let selected = self
            .workspace()
            .and_then(|workspace| workspace.draft_skills.get(&scope.draft))
            .is_some_and(|skill| skill.eq_ignore_ascii_case(name));
        let discovered = self
            .slash_menu
            .query
            .as_ref()
            .is_some_and(|query| query.scope == scope)
            && self
                .slash_menu
                .rows
                .iter()
                .any(|row| row.skill && row.name.eq_ignore_ascii_case(name))
            || self.slash_menu.catalogs.iter().any(|(owner, choices)| {
                owner == &scope
                    && choices
                        .iter()
                        .any(|row| row.skill && row.name.eq_ignore_ascii_case(name))
            });
        (selected || discovered).then(|| SkillSubmission {
            name: name.to_owned(),
            argument: argument.trim().to_owned(),
            prompt: None,
        })
    }

    pub(super) fn remember_draft_skill(&mut self, key: &str, text: &str) {
        let skill = self.skill_command(text);
        let workspace_key = self.settings.workspace_key().to_owned();
        let Some(workspace) = self.settings.workspaces.get_mut(&workspace_key) else {
            return;
        };
        if let Some(skill) = skill {
            workspace.draft_skills.insert(key.to_owned(), skill.name);
        } else {
            workspace.draft_skills.remove(key);
        }
    }

    pub(super) fn dispatch_skill(
        &mut self,
        key: String,
        prepared: Prepared,
        cx: &mut Context<Self>,
    ) {
        let Some(skill) = prepared.skill.as_ref() else {
            return;
        };
        let Some(session) = self.sessions.get(&key) else {
            return;
        };
        let mut params =
            json!({"session_id":session.runtime, "name":skill.name, "arg":skill.argument});
        if !session.profile.is_empty() {
            params["profile"] = json!(session.profile);
        }
        if self.call(
            "command.dispatch",
            params,
            Call::SkillDispatch(key.clone(), prepared.clone()),
        ) {
            let session = self.sessions.get_mut(&key).unwrap();
            session.submitting = true;
            session.error = None;
            self.workspace_mut()
                .pending_submissions
                .insert(key, prepared);
            self.persist(cx);
            cx.notify();
        }
    }

    pub(super) fn finish_skill(
        &mut self,
        key: String,
        mut prepared: Prepared,
        response: &Value,
        error: Option<&Value>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(session) = self.sessions.get_mut(&key) else {
            return;
        };
        session.submitting = false;
        let prompt = string(response, "message");
        if error.is_none()
            && matches!(string(response, "type"), "skill" | "send")
            && !prompt.trim().is_empty()
        {
            if let Some(skill) = prepared.skill.as_mut() {
                skill.prompt = Some(prompt.to_owned());
            }
            self.start_submission(key, prepared, cx);
        } else if error.is_none() && matches!(string(response, "type"), "exec" | "plugin") {
            let command = prepared
                .skill
                .as_ref()
                .map_or(tr("命令"), |skill| skill.name.as_str())
                .to_owned();
            self.accept_draft(&key, window, cx);
            self.store_slash_output(key, command, string(response, "output").to_owned());
        } else if error.is_none() && matches!(string(response, "type"), "alias" | "prefill") {
            let replacement = if response["type"] == "alias" {
                string(response, "target")
            } else {
                prompt
            };
            let unchanged = self
                .workspace()
                .and_then(|workspace| workspace.drafts.get(&key))
                == Some(&prepared.text);
            if unchanged && !replacement.trim().is_empty() {
                let workspace = self.workspace_mut();
                workspace.pending_submissions.remove(&key);
                workspace.draft_skills.remove(&key);
                workspace.drafts.insert(key.clone(), replacement.to_owned());
                if self.key() == key {
                    self.restore_draft(window, cx);
                }
                self.persist(cx);
            } else {
                self.workspace_mut().pending_submissions.remove(&key);
                self.persist(cx);
            }
        } else {
            session.error =
                Some(error.map_or_else(|| tr("网关未返回可发送的技能请求").into(), rpc_error));
        }
        cx.notify();
    }

    pub(super) fn slash_element(&self, width: f32, cx: &mut Context<Self>) -> Div {
        let arguments = self
            .slash_menu
            .query
            .as_ref()
            .is_some_and(|query| query.arguments);
        let title = if arguments {
            tr("选项")
        } else if self
            .slash_menu
            .query
            .as_ref()
            .is_some_and(|query| query.preserve_draft)
        {
            match self.slash_menu.catalog_status {
                _ if !self.slash_menu.rows.is_empty() => tr("选择技能"),
                CatalogStatus::Loading => tr("正在读取技能…"),
                CatalogStatus::Ready => tr("没有可选技能"),
                CatalogStatus::Unavailable => tr("无法读取技能"),
            }
        } else {
            tr("命令与技能")
        };
        let mut rows = Vec::new();
        let mut previous = "";
        for (index, item) in self.slash_menu.rows.iter().enumerate() {
            if !item.group.is_empty() && item.group != previous {
                previous = item.group;
                rows.push(
                    div()
                        .id(SharedString::from(format!("slash-group-{index}")))
                        .px_2()
                        .pt(px(6.))
                        .pb(px(3.))
                        .text_size(px(10.5))
                        .font_weight(gpui::FontWeight::SEMIBOLD)
                        .text_color(ink(MUTED))
                        .child(tr(item.group)),
                );
            }
            rows.push(
                completion_row(
                    index,
                    self.slash_menu.cursor,
                    if arguments {
                        item.name.clone().into()
                    } else {
                        format!("/{}", item.name).into()
                    },
                    tr(item.hint.as_ref()).to_owned().into(),
                    item.skill,
                )
                .on_hover(cx.listener(move |this, over: &bool, _, cx| {
                    if *over && this.slash_menu.cursor != index {
                        this.slash_menu.cursor = index;
                        cx.notify();
                    }
                }))
                .on_mouse_down(
                    gpui::MouseButton::Left,
                    cx.listener(move |this, _, window, cx| {
                        window.prevent_default();
                        cx.stop_propagation();
                        this.choose_slash(Some(index), window, cx)
                    }),
                ),
            );
        }
        completion_popup(
            if arguments {
                "slash-options"
            } else {
                "slash-menu"
            },
            title,
            width,
            &self.slash_menu.scroll,
            rows,
        )
    }

    pub(super) fn slash_output(&self, cx: &mut Context<Self>) -> Option<Div> {
        let key = self.key();
        let (command, output) = self.slash_menu.outputs.get(&key)?;
        Some(
            super::view::panel()
                .bg(rgb(0xf8f9fb))
                .child(
                    div()
                        .h(px(28.))
                        .px_2()
                        .flex()
                        .items_center()
                        .gap_2()
                        .child(
                            div()
                                .flex_1()
                                .text_size(px(11.))
                                .text_color(ink(MUTED))
                                .child(format!("/{command}")),
                        )
                        .child(
                            super::view::icon_button(
                                "dismiss-slash-output",
                                crate::icons::TAB_CLOSE,
                                tr("关闭命令结果"),
                            )
                            .size(px(21.))
                            .on_click(cx.listener(
                                move |this, _, _, cx| {
                                    this.slash_menu.outputs.remove(&key);
                                    if this.following {
                                        this.sync_list();
                                    }
                                    cx.notify();
                                },
                            )),
                        ),
                )
                .child(
                    div()
                        .id("slash-output")
                        .max_h(px(152.))
                        .overflow_y_scroll()
                        .px_2()
                        .pb_2()
                        .font_family(crate::theme::code_family())
                        .text_size(px(11.5))
                        .line_height(px(17.))
                        .text_color(ink(INK))
                        .child(output.clone()),
                ),
        )
    }
}

pub(super) fn completion_popup(
    id: &'static str,
    title: &'static str,
    width: f32,
    scroll: &ScrollHandle,
    rows: impl IntoIterator<Item = gpui::Stateful<Div>>,
) -> Div {
    div()
        .absolute()
        .bottom_full()
        .left(px(7.))
        .pb_1()
        .w(px((width - 42.).clamp(240., 411.)))
        .child(
            div()
                .id(id)
                .occlude()
                .track_scroll(scroll)
                .max_h(px(match id {
                    "slash-menu" => 390.,
                    "slash-options" => 316.,
                    _ => 248.,
                }))
                .overflow_y_scroll()
                .flex()
                .flex_col()
                .p_1()
                .rounded(px(8.))
                .border_1()
                .border_color(rgb(0xe0e6ef))
                .shadow_lg()
                .bg(rgba(0xfcfcfef8))
                .child(
                    div()
                        .px_2()
                        .py_1()
                        .text_size(px(11.))
                        .text_color(ink(MUTED))
                        .child(title),
                )
                .children(rows),
        )
}

fn split_argument(text: &str) -> Option<(&str, &str)> {
    let (command, tail) = text.split_once([' ', '\t'])?;
    let query = tail.trim_start_matches([' ', '\t']);
    (command.starts_with('/') && (query.is_empty() || valid_name(query)))
        .then_some((command, query))
}

fn needs_session(command: &str) -> bool {
    matches!(
        command,
        "find" | "branch" | "title" | "save" | "stop" | "agents" | "copy"
    )
}

fn remote_argument<'a>(command: &str, arg: &'a str) -> Option<&'a str> {
    match command {
        "skills" | "memory" if arg.is_empty() => Some("pending"),
        "skills" if arg == "pending" || arg == "diff" || arg.starts_with("diff ") => Some(arg),
        "memory" if arg == "pending" => Some(arg),
        "context" if arg == "all" => Some(arg),
        "diff" | "personality" => Some(arg),
        _ if arg.is_empty() => Some(arg),
        _ => None,
    }
}

fn catalog_choices(response: &Value) -> Vec<Choice> {
    let mut choices = Vec::new();
    for category in response["categories"].as_array().into_iter().flatten() {
        let group = match string(category, "name") {
            "Session" => "会话",
            "Configuration" => "配置",
            "Tools & Skills" => "工具与技能",
            "Info" => "信息",
            "User commands" => "自定义命令",
            "Plugin commands" => "插件命令",
            _ => continue,
        };
        let extension = matches!(group, "自定义命令" | "插件命令");
        for pair in category["pairs"].as_array().into_iter().flatten() {
            let name = pair[0].as_str().unwrap_or_default().trim_start_matches('/');
            if !valid_name(name) || LOCAL_COMMANDS.iter().any(|(local, _, _)| *local == name) {
                continue;
            }
            if extension {
                choices.push(Choice::new(
                    name,
                    pair[1].as_str().unwrap_or_default(),
                    group,
                    true,
                ));
            } else if let Some(choice) = remote_choice(response, name) {
                choices.push(choice);
            }
        }
    }
    let mut skills = Vec::new();
    for pair in response["pairs"].as_array().into_iter().flatten() {
        let wire = pair[0].as_str().unwrap_or_default();
        let name = wire.trim_start_matches('/');
        if !valid_name(name) {
            continue;
        }
        let meta = response["skills"]
            .get(wire)
            .or_else(|| response["skills"].get(name));
        if let Some(meta) = meta {
            let mut row = Choice::new(
                name,
                pair[1].as_str().unwrap_or_default(),
                SKILL_GROUP,
                true,
            );
            let usage = meta["usage"].as_u64().unwrap_or(0);
            row.browse = usage > 0 || meta["origin"] != "bundled";
            skills.push((usage, row));
        } else if !choices.iter().any(|row| row.name == name)
            && let Some(choice) = remote_choice(response, name)
        {
            choices.push(choice);
        }
    }
    skills.sort_by(|(a, left), (b, right)| b.cmp(a).then_with(|| left.name.cmp(&right.name)));
    choices.extend(skills.into_iter().map(|(_, row)| row));
    choices
}

fn remote_choice(response: &Value, name: &str) -> Option<Choice> {
    let &(_, hint, group) = REMOTE_COMMANDS
        .iter()
        .find(|(command, _, _)| *command == name)?;
    let key = format!("/{name}");
    if response["commands"][&key]["desktop"]
        .as_str()
        .is_some_and(|surface| surface != "advanced")
    {
        return None;
    }
    let mut choice = Choice::new(name, hint, group, false);
    choice.options = response["sub"][&key]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .filter(|opt| valid_name(opt) && remote_argument(name, opt).is_some())
        .map(str::to_owned)
        .collect();
    Some(choice)
}

fn reasoning_option_hint(name: &str) -> &'static str {
    match name {
        "show" | "on" => tr("显示思考过程"),
        "hide" | "off" => tr("隐藏思考过程"),
        "full" => tr("默认展开"),
        "clamp" => tr("默认折叠"),
        _ => "",
    }
}

pub(super) fn completion_row(
    index: usize,
    cursor: usize,
    title: SharedString,
    detail: SharedString,
    accent: bool,
) -> gpui::Stateful<Div> {
    div()
        .id(("completion-choice", index))
        .min_h(px(28.))
        .px_2()
        .gap_2()
        .flex()
        .items_center()
        .rounded(px(5.))
        .cursor_pointer()
        .when(index == cursor, |row| row.bg(rgb(0xe7eefc)))
        .hover(|row| row.bg(rgb(0xe7eefc)))
        .child(
            div()
                .min_w_0()
                .max_w(px(255.))
                .truncate()
                .text_size(px(13.))
                .text_color(ink(if accent { ACCENT } else { INK }))
                .child(title),
        )
        .child(
            div()
                .flex_1()
                .min_w_0()
                .truncate()
                .text_size(px(11.5))
                .text_color(ink(MUTED))
                .child(detail),
        )
}

fn valid_name(value: &str) -> bool {
    !value.is_empty()
        && value
            .chars()
            .all(|character| character.is_alphanumeric() || matches!(character, '-' | '_' | '.'))
}
