use std::{
    collections::VecDeque,
    ops::Range,
    time::{Duration, Instant},
};

use gpui::{
    Context, Div, EntityInputHandler, Focusable, ScrollHandle, SharedString, Task, Window,
    prelude::*,
};
use serde_json::{Value, json};

use crate::{media::attachment_ref, session::string};

use super::{
    Call, Desktop,
    slash_menu::{completion_popup, completion_row},
    workspace_scope::WorkspaceScope,
};

#[derive(Clone, PartialEq, Eq)]
pub(super) struct PathLookup {
    tab: String,
    runtime: String,
    workspace: WorkspaceScope,
    word: String,
}

#[derive(Clone, PartialEq, Eq)]
struct Token {
    range: Range<usize>,
    word: String,
}

#[derive(Clone)]
struct Reference {
    token: String,
    title: SharedString,
    detail: SharedString,
    prefix: bool,
}

#[derive(Default)]
pub(super) struct ReferenceMenu {
    lookup: Option<PathLookup>,
    token: Option<Token>,
    dismissed: Option<Token>,
    rows: Vec<Reference>,
    selected: usize,
    scroll: ScrollHandle,
    debounce: Option<Task<()>>,
    cache: VecDeque<(PathLookup, Vec<Reference>, Instant)>,
}

impl Desktop {
    pub(super) fn add_reference_prefix(
        &mut self,
        prefix: &'static str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.out.is_none() || self.active_workspace_scope().is_none() {
            return;
        }
        self.composer.update(cx, |field, cx| {
            let text = field.value();
            let end = text.encode_utf16().count();
            let prefix = if text.chars().next_back().is_some_and(|c| !c.is_whitespace()) {
                format!(" {prefix}")
            } else {
                prefix.to_owned()
            };
            field.replace_text_in_range(Some(end..end), &prefix, window, cx);
            field.focus(window, cx);
        });
        self.references_changed(cx);
    }

    pub(super) fn refresh_reference_connection(&mut self, cx: &mut Context<Self>) {
        self.references.lookup = None;
        self.references.cache.clear();
        self.references_changed(cx);
    }

    pub(super) fn references_changed(&mut self, cx: &mut Context<Self>) {
        let input = self.composer.read(cx);
        let token = path_token(&input.value(), input.cursor());
        let Some(token) = token else {
            self.references.lookup = None;
            self.references.token = None;
            self.references.dismissed = None;
            self.references.debounce = None;
            return;
        };
        let Some(workspace) = self.active_workspace_scope() else {
            return;
        };
        let runtime = self
            .selected
            .as_ref()
            .and_then(|key| self.sessions.get(key))
            .filter(|session| session.attached && !session.loading)
            .map(|session| session.runtime.clone())
            .unwrap_or_default();
        let lookup = PathLookup {
            tab: self.key(),
            runtime,
            workspace,
            word: token.word.clone(),
        };
        if self.references.token.as_ref() == Some(&token)
            && self.references.lookup.as_ref() == Some(&lookup)
        {
            return;
        }
        self.references.lookup = Some(lookup.clone());
        self.references.token = Some(token);
        self.references.dismissed = None;
        self.references.debounce = None;
        self.references.selected = 0;
        self.references.scroll = ScrollHandle::new();
        self.references.rows = starters(&lookup.word);
        let cached = self.references.cache.iter().find(|(key, _, created)| {
            key == &lookup && created.elapsed() < Duration::from_secs(20)
        });
        if let Some((_, cached, _)) = cached {
            if !cached.is_empty() {
                self.references.rows = cached.clone();
            }
        } else if self.out.is_some()
            && lookup.word != "@"
            && (self.selected.is_none() || !lookup.runtime.is_empty())
        {
            self.references.debounce = Some(cx.spawn(async move |view, cx| {
                cx.background_executor()
                    .timer(Duration::from_millis(80))
                    .await;
                let _ = view.update(cx, |this, cx| this.request_references(lookup, cx));
            }));
        }
        cx.notify();
    }

    fn request_references(&mut self, lookup: PathLookup, cx: &mut Context<Self>) {
        if self.references.lookup.as_ref() != Some(&lookup)
            || self.active_workspace_scope().as_ref() != Some(&lookup.workspace)
        {
            return;
        }
        if self.canonical && lookup.runtime.is_empty() {
            let Some(gateway) = self.gateway.clone() else {
                return;
            };
            let job = self.runtime.spawn({
                let lookup = lookup.clone();
                async move { draft_paths(&gateway, &lookup).await }
            });
            cx.spawn(async move |view, cx| {
                if let Ok(Ok(response)) = job.await {
                    let _ = view.update(cx, |this, cx| {
                        this.reference_response(lookup, &response, cx)
                    });
                }
            })
            .detach();
            return;
        }
        let word = match lookup.word.as_str() {
            "@file" => "@file:",
            "@folder" => "@folder:",
            word => word,
        };
        let mut params = json!({"word":word});
        if !lookup.runtime.is_empty() {
            params["session_id"] = json!(lookup.runtime);
        }
        if !lookup.workspace.profile.is_empty() {
            params["profile"] = json!(lookup.workspace.profile);
        }
        if !lookup.workspace.cwd.is_empty() {
            params["cwd"] = json!(lookup.workspace.cwd.as_ref());
        }
        self.call("complete.path", params, Call::PathSuggestions(lookup));
    }

    pub(super) fn reference_response(
        &mut self,
        lookup: PathLookup,
        response: &Value,
        cx: &mut Context<Self>,
    ) {
        let mut rows = Vec::new();
        for item in response["items"].as_array().into_iter().flatten() {
            let raw = string(item, "text");
            let Some((kind, path)) = raw.split_once(':') else {
                continue;
            };
            let detail = match kind {
                "@file" => "文件",
                "@folder" => "文件夹",
                _ => continue,
            };
            let Some(token) = attachment_ref(&format!("{kind}:"), path) else {
                continue;
            };
            if rows.iter().any(|row: &Reference| row.token == token) {
                continue;
            }
            rows.push(Reference {
                token,
                title: path.to_owned().into(),
                detail: detail.into(),
                prefix: false,
            });
            if rows.len() >= 60 {
                break;
            }
        }
        self.references.cache.retain(|(key, _, _)| key != &lookup);
        self.references
            .cache
            .push_back((lookup.clone(), rows.clone(), Instant::now()));
        if self.references.cache.len() > 20 {
            self.references.cache.pop_front();
        }
        if self.references.lookup.as_ref() == Some(&lookup)
            && self.key() == lookup.tab
            && self.active_workspace_scope().as_ref() == Some(&lookup.workspace)
            && !rows.is_empty()
        {
            self.references.rows = rows;
            self.references.selected = 0;
            cx.notify();
        }
    }

    pub(super) fn reference_is_open(&self, window: &Window, cx: &Context<Self>) -> bool {
        let Some(lookup) = self.references.lookup.as_ref() else {
            return false;
        };
        self.out.is_some()
            && self.key() == lookup.tab
            && self.active_workspace_scope().as_ref() == Some(&lookup.workspace)
            && self.references.token.is_some()
            && self.references.token != self.references.dismissed
            && !self.references.rows.is_empty()
            && self.composer.read(cx).focus_handle(cx).is_focused(window)
            && !self.settings_open
            && !self.palette.open
            && !self.media.is_open()
            && self.rewrite_editor.is_none()
    }

    pub(super) fn move_reference(&mut self, previous: bool, cx: &mut Context<Self>) {
        let count = self.references.rows.len();
        if count > 0 {
            let delta = if previous { count - 1 } else { 1 };
            self.references.selected = (self.references.selected + delta) % count;
            self.references
                .scroll
                .scroll_to_item(1 + self.references.selected);
            cx.notify();
        }
    }

    pub(super) fn dismiss_reference(&mut self, cx: &mut Context<Self>) {
        self.references.dismissed = self.references.token.clone();
        cx.notify();
    }

    pub(super) fn choose_reference(
        &mut self,
        index: Option<usize>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.reference_is_open(window, cx) {
            return;
        }
        let Some(choice) = self
            .references
            .rows
            .get(index.unwrap_or(self.references.selected))
            .cloned()
        else {
            return;
        };
        let expected = self.references.token.clone();
        let committed = !choice.prefix;
        self.composer.update(cx, |field, cx| {
            let value = field.value();
            let Some(token) =
                path_token(&value, field.cursor()).filter(|token| Some(token) == expected.as_ref())
            else {
                return;
            };
            let range = value[..token.range.start].encode_utf16().count()
                ..value[..token.range.end].encode_utf16().count();
            let before_space = value[token.range.end..]
                .chars()
                .next()
                .is_some_and(char::is_whitespace);
            let insert = if choice.prefix || before_space {
                choice.token
            } else {
                format!("{} ", choice.token)
            };
            field.replace_text_in_range(Some(range), &insert, window, cx);
            field.focus(window, cx);
        });
        if committed {
            self.references_changed(cx);
            self.dismiss_reference(cx);
        }
    }

    pub(super) fn reference_element(&self, width: f32, cx: &mut Context<Self>) -> Div {
        let rows = self
            .references
            .rows
            .iter()
            .enumerate()
            .map(|(index, item)| {
                completion_row(
                    index,
                    self.references.selected,
                    item.title.clone(),
                    item.detail.clone(),
                    true,
                )
                .on_click(cx.listener(move |this, _, window, cx| {
                    this.choose_reference(Some(index), window, cx)
                }))
            });
        completion_popup(
            "path-menu",
            "工作区引用",
            width,
            &self.references.scroll,
            rows,
        )
    }
}

fn starters(word: &str) -> Vec<Reference> {
    [("@file:", "文件"), ("@folder:", "文件夹")]
        .into_iter()
        .filter(|(token, _)| token.starts_with(word) && token != &word)
        .map(|(token, title)| Reference {
            token: token.to_owned(),
            title: title.into(),
            detail: token.into(),
            prefix: true,
        })
        .collect()
}

fn path_token(text: &str, cursor: usize) -> Option<Token> {
    let before = text.get(..cursor)?;
    let line = before.rfind('\n').map_or(0, |index| index + 1);
    before[line..]
        .match_indices('@')
        .rev()
        .find_map(|(start, _)| {
            let start = line + start;
            if text[..start].chars().next_back().is_some_and(|previous| {
                !previous.is_whitespace() && !matches!(previous, '(' | '[' | '（' | '【')
            }) {
                return None;
            }
            let prefix = &text[start..cursor];
            if prefix.len() > 768 {
                return None;
            }
            let after = text[cursor..].split('\n').next().unwrap_or_default();
            let quoted = ["@file:", "@folder:"].iter().find_map(|kind| {
                let tail = prefix.strip_prefix(kind)?;
                let delimiter @ ('"' | '\'' | '`') = tail.chars().next()? else {
                    return None;
                };
                Some((*kind, delimiter, &tail[delimiter.len_utf8()..]))
            });
            if let Some((kind, delimiter, tail)) = quoted {
                if tail.contains(delimiter) {
                    return None;
                }
                let end = after
                    .find(delimiter)
                    .map_or(0, |index| index + delimiter.len_utf8());
                return Some(Token {
                    range: start..(cursor + end),
                    word: format!("{kind}{tail}"),
                });
            }
            if prefix[1..].chars().any(|character| {
                character.is_whitespace()
                    || character.is_control()
                    || matches!(character, '"' | '\'' | '`' | '@')
            }) {
                return None;
            }
            let end = after
                .find(|character: char| {
                    character.is_whitespace() || matches!(character, ')' | ']' | '）' | '】')
                })
                .unwrap_or(after.len());
            Some(Token {
                range: start..(cursor + end),
                word: prefix.to_owned(),
            })
        })
}

async fn draft_paths(
    gateway: &crate::gateway::Gateway,
    lookup: &PathLookup,
) -> anyhow::Result<Value> {
    let query = lookup.word.strip_prefix('@').unwrap_or(&lookup.word);
    let (kind, path) = match query.split_once(':') {
        Some(("file", path)) => ("file", path),
        Some(("folder", path)) => ("folder", path),
        Some(_) => return Ok(json!({"items":[]})),
        None if query == "file" || query == "folder" => (query, ""),
        None => ("", query),
    };
    let (dir, stub) = path.rsplit_once('/').unwrap_or(("", path));
    if dir.split('/').any(|piece| piece == "..")
        || path.starts_with('/')
        || path.contains(['\\', ':'])
    {
        return Ok(json!({"items":[]}));
    }
    let root = lookup.workspace.root(gateway).await?;
    let directory = if dir.is_empty() {
        root
    } else {
        format!("{}/{dir}", root.trim_end_matches(['/', '\\']))
    };
    let response = lookup
        .workspace
        .get(gateway, "api/fs/list", vec![("path", directory)], false)
        .await?;
    let query = stub.to_lowercase();
    let items = response["entries"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|row| {
            let name = row["name"].as_str()?.trim_end_matches('/');
            let is_dir = row["isDirectory"] == true;
            if name.starts_with('.')
                || !name.to_lowercase().starts_with(&query)
                || (kind == "folder" && !is_dir)
                || (kind == "file" && is_dir)
            {
                return None;
            }
            let path = if dir.is_empty() {
                name.to_owned()
            } else {
                format!("{dir}/{name}")
            };
            let tag = if is_dir { "folder" } else { "file" };
            Some(json!({"text":format!("@{tag}:{path}")}))
        })
        .take(30)
        .collect::<Vec<_>>();
    Ok(json!({"items":items}))
}
