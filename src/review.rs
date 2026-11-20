use std::sync::Arc;

use anyhow::{Context as _, Result, bail};
use gpui::{
    ClipboardItem, Context, Div, FocusHandle, ListHorizontalSizingBehavior, SharedString,
    UniformListScrollHandle, Window, div, prelude::*, px, rgb, uniform_list,
};
use gpui_component::{scroll::Scrollbar, tooltip::Tooltip};
use serde::Deserialize;

use crate::{gateway::Gateway, session::string};

use super::{
    Desktop,
    pane_layout::Pane,
    view::icon_button,
    workspace_scope::{WorkspaceRequest, WorkspaceScope},
};

#[derive(Clone, Copy, Default, PartialEq, Eq)]
enum Mode {
    #[default]
    Working,
    Branch,
    Previous,
}

impl Mode {
    fn scope(self) -> &'static str {
        match self {
            Self::Working => "uncommitted",
            Self::Branch => "branch",
            Self::Previous => "lastTurn",
        }
    }
}

#[derive(Clone, Deserialize)]
struct ChangedFile {
    path: String,
    status: String,
    added: u64,
    removed: u64,
    #[serde(default)]
    staged: bool,
}

#[derive(Deserialize)]
struct FileList {
    files: Vec<ChangedFile>,
    base: Option<String>,
}

struct Diff {
    raw: SharedString,
    rows: Arc<[DiffRow]>,
    widest: Option<usize>,
    shortened: bool,
}

#[derive(Clone)]
struct DiffRow {
    old: Option<u32>,
    new: Option<u32>,
    kind: LineKind,
    text: SharedString,
}

#[derive(Clone, Copy)]
enum LineKind {
    Plain,
    Header,
    Added,
    Removed,
}

pub(super) struct Review {
    pub open: bool,
    focus: FocusHandle,
    previous_focus: Option<FocusHandle>,
    target: Option<WorkspaceScope>,
    mode: Mode,
    root: Option<String>,
    loaded: bool,
    base: Option<String>,
    files: Vec<ChangedFile>,
    selected: Option<String>,
    diff: Option<Diff>,
    list_error: Option<SharedString>,
    diff_error: Option<SharedString>,
    list_job: Option<WorkspaceRequest>,
    diff_job: Option<WorkspaceRequest>,
    list_scroll: UniformListScrollHandle,
    diff_scroll: UniformListScrollHandle,
}

impl Review {
    pub fn new(focus: FocusHandle) -> Self {
        Self {
            open: false,
            focus,
            previous_focus: None,
            target: None,
            mode: Mode::Working,
            root: None,
            loaded: false,
            base: None,
            files: Vec::new(),
            selected: None,
            diff: None,
            list_error: None,
            diff_error: None,
            list_job: None,
            diff_job: None,
            list_scroll: Default::default(),
            diff_scroll: Default::default(),
        }
    }

    pub fn clear(&mut self) {
        *self = Self::new(self.focus.clone());
    }

    fn retarget(&mut self, target: Option<WorkspaceScope>) {
        let open = self.open;
        let focus = self.previous_focus.take();
        self.clear();
        self.open = open;
        self.previous_focus = focus;
        self.target = target;
    }
}

impl Desktop {
    pub(super) fn toggle_review(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.review.open {
            self.close_review(window, cx);
        } else {
            self.open_review(window, cx);
        }
    }

    pub(super) fn open_review(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.gateway.is_none()
            || self.login_url.is_some()
            || self.settings_open
            || self.media.is_open()
        {
            return;
        }
        self.close_files(window, cx);
        self.close_palette(window, cx);
        self.close_transcript_find(window, cx);
        self.release_turn_rail(window, cx);
        if !self.review.open {
            self.review.previous_focus = window.focused(cx);
            self.review.open = true;
            self.review.focus.focus(window, cx);
        }
        self.refresh_review_scope(cx);
        if self.review.loaded && self.review.list_job.is_none() {
            self.load_review(cx);
        }
        cx.notify();
    }

    pub(super) fn close_review(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.review.open {
            return;
        }
        self.review.open = false;
        self.review
            .previous_focus
            .take()
            .unwrap_or_else(|| self.workspace_focus.clone())
            .focus(window, cx);
        cx.notify();
    }

    pub(super) fn refresh_review_scope(&mut self, cx: &mut Context<Self>) {
        if !self.review.open {
            return;
        }
        let scope = self.active_workspace_scope();
        if self.review.target != scope {
            self.review.retarget(scope);
        }
        if !self.review.loaded && self.review.list_job.is_none() {
            self.load_review(cx);
        }
    }

    fn load_review(&mut self, cx: &mut Context<Self>) {
        let (Some(scope), Some(gateway)) = (self.review.target.clone(), self.gateway.clone())
        else {
            return;
        };
        self.review.list_error = None;
        self.review.diff_job = None;
        self.review.diff_error = None;
        let mode = self.review.mode;
        let fetch = self
            .runtime
            .spawn(async move { load_files(&gateway, &scope, mode).await });
        let abort = fetch.abort_handle();
        let task = cx.spawn(async move |view, cx| {
            let result = fetch.await;
            let _ = view.update(cx, |this, cx| {
                this.review.list_job = None;
                this.review.loaded = true;
                match result {
                    Ok(Ok(Some((root, list)))) => {
                        this.review.root = Some(root);
                        this.review.base = list.base;
                        this.review.files = list.files;
                        let previous = this.review.selected.take();
                        if let Some(previous) = previous
                            && this.review.files.iter().any(|file| file.path == previous)
                        {
                            this.select_review_file(previous, cx);
                        } else {
                            this.review.diff = None;
                        }
                    }
                    Ok(Ok(None)) => {
                        this.review.root = None;
                        this.review.files.clear();
                        this.review.selected = None;
                        this.review.diff = None;
                    }
                    Ok(Err(error)) => this.review.list_error = Some(error.to_string().into()),
                    Err(_) => this.review.list_error = Some("无法读取工作区变更".into()),
                }
                cx.notify();
            });
        });
        self.review.list_job = Some(WorkspaceRequest { _task: task, abort });
        cx.notify();
    }

    fn select_review_file(&mut self, path: String, cx: &mut Context<Self>) {
        let review = &mut self.review;
        let (Some(root), Some(scope), Some(gateway)) = (
            review.root.clone(),
            review.target.clone(),
            self.gateway.clone(),
        ) else {
            return;
        };
        if review.list_job.is_some() || !review.files.iter().any(|file| file.path == path) {
            return;
        }
        review.diff = None;
        review.diff_error = None;
        review.diff_scroll = Default::default();
        review.selected = Some(path.clone());
        let mode = review.mode;
        let base = review.base.clone();
        let fetch = self.runtime.spawn(async move {
            let route = if mode == Mode::Working {
                "api/git/file-diff"
            } else {
                "api/git/review/diff"
            };
            let mut query = vec![("path", root), ("file", path)];
            if mode != Mode::Working {
                query.push(("scope", mode.scope().to_owned()));
                if let Some(base) = base {
                    query.push(("base", base));
                }
            }
            let value = scope.get(&gateway, route, query, false).await?;
            let raw = value["diff"].as_str().context("网关未返回有效差异")?;
            Ok::<_, anyhow::Error>(parse_diff(raw))
        });
        let abort = fetch.abort_handle();
        let task = cx.spawn(async move |view, cx| {
            let result = fetch.await;
            let _ = view.update(cx, |this, cx| {
                this.review.diff_job = None;
                match result {
                    Ok(Ok(diff)) => this.review.diff = Some(diff),
                    Ok(Err(error)) => this.review.diff_error = Some(error.to_string().into()),
                    Err(_) => this.review.diff_error = Some("无法读取文件差异".into()),
                }
                cx.notify();
            });
        });
        self.review.diff_job = Some(WorkspaceRequest { _task: task, abort });
        cx.notify();
    }

    pub(super) fn review_element(&self, window: &Window, cx: &mut Context<Self>) -> Div {
        let review = &self.review;
        let mode = review.mode;
        let source: SharedString = review
            .root
            .as_deref()
            .map(file_name)
            .unwrap_or("工作区")
            .to_owned()
            .into();
        let header = div()
            .h(px(32.))
            .w_full()
            .flex_none()
            .flex()
            .items_center()
            .gap_2()
            .px_3()
            .border_b_1()
            .border_color(rgb(0xe8edf4))
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .truncate()
                    .text_size(px(11.))
                    .text_color(rgb(0x2855a3))
                    .child(source),
            )
            .children(review.base.as_ref().map(|base| {
                div()
                    .font_family("Consolas")
                    .text_size(px(11.))
                    .text_color(rgb(0x69778b))
                    .child(base.chars().take(20).collect::<String>())
            }))
            .child(
                icon_button("refresh-git-review", "", "刷新变更").on_click(cx.listener(
                    |this, _, _, cx| {
                        if this.review.target.is_none() {
                            if let Some(session) = this.selected.clone() {
                                this.attach(&session, true);
                            }
                            this.refresh_review_scope(cx);
                        } else {
                            this.load_review(cx);
                        }
                    },
                )),
            );
        let modes = div().flex_none().w_full().h(px(34.)).px_2().py_1().child(
            div()
                .flex()
                .size_full()
                .bg(rgb(0xe9eef7))
                .rounded(px(4.))
                .p(px(2.))
                .children(
                    [
                        (Mode::Working, "未提交"),
                        (Mode::Branch, "分支"),
                        (Mode::Previous, "对比上一版本"),
                    ]
                    .into_iter()
                    .enumerate()
                    .map(|(index, (target, title))| {
                        div()
                            .id(("review-mode", index))
                            .h_full()
                            .flex_1()
                            .flex()
                            .items_center()
                            .justify_center()
                            .text_size(px(11.))
                            .text_color(rgb(0x46586e))
                            .rounded(px(3.))
                            .cursor_pointer()
                            .when(mode == target, |tab| {
                                tab.bg(rgb(0xffffff)).text_color(rgb(0x244578))
                            })
                            .hover(|tab| tab.bg(rgb(0xf4f7fc)))
                            .on_click(cx.listener(move |this, _, _, cx| {
                                if this.review.mode == target {
                                    return;
                                }
                                this.review.mode = target;
                                this.review.selected = None;
                                this.review.diff = None;
                                this.review.files.clear();
                                this.review.list_scroll = Default::default();
                                this.load_review(cx);
                            }))
                            .child(title)
                    }),
                ),
        );
        let body = if let Some(error) = &review.list_error {
            center(error.clone())
        } else if review.list_job.is_some() {
            center("正在读取 Git 变更…".into())
        } else if !review.loaded {
            center("正在定位会话工作目录…".into())
        } else if review.root.is_none() {
            center("当前目录没有 Git 仓库".into())
        } else if review.files.is_empty() {
            center("无差异".into())
        } else {
            self.review_columns(window, cx)
        };
        div()
            .flex()
            .flex_col()
            .flex_1()
            .min_h_0()
            .track_focus(&review.focus)
            .child(header)
            .child(modes)
            .child(body)
    }

    fn review_columns(&self, window: &Window, cx: &mut Context<Self>) -> Div {
        let entity = cx.entity();
        let review = &self.review;
        let list = uniform_list(
            "git-changed-files",
            review.files.len(),
            move |range, _, app| {
                let desktop = entity.read(app);
                range
                    .filter_map(|index| {
                        let file = desktop.review.files.get(index)?;
                        let path = file.path.clone();
                        let name = file_name(&path).to_owned();
                        let hint: SharedString = path.clone().into();
                        let selected = desktop.review.selected.as_ref() == Some(&path);
                        let weak = entity.downgrade();
                        Some(
                            div()
                                .id(("changed-file", index))
                                .w_full()
                                .h(px(26.))
                                .px_2()
                                .flex()
                                .items_center()
                                .gap_2()
                                .cursor_pointer()
                                .rounded(px(3.))
                                .text_size(px(12.))
                                .text_color(rgb(0x344459))
                                .when(selected, |row| row.bg(rgb(0xe5eefb)))
                                .hover(|row| row.bg(rgb(0xeaf0fa)))
                                .tooltip(move |window, cx| {
                                    Tooltip::new(hint.clone()).build(window, cx)
                                })
                                .child(
                                    div()
                                        .font_family("Consolas")
                                        .w(px(13.))
                                        .flex_none()
                                        .text_color(rgb(match file.status.as_str() {
                                            "A" | "?" => 0x22845b,
                                            "D" => 0xb84245,
                                            _ => 0xa07527,
                                        }))
                                        .child(file.status.clone()),
                                )
                                .child(div().min_w_0().flex_1().truncate().child(name))
                                .when(file.staged, |row| {
                                    row.child(
                                        div()
                                            .text_size(px(10.))
                                            .text_color(rgb(0x6380a0))
                                            .child("已暂存"),
                                    )
                                })
                                .child(diff_counts(file.added, file.removed))
                                .on_click(move |_, _, app| {
                                    let _ = weak.update(app, |this, cx| {
                                        this.select_review_file(path.clone(), cx)
                                    });
                                }),
                        )
                    })
                    .collect::<Vec<_>>()
            },
        )
        .flex_1()
        .min_h_0()
        .w_full()
        .track_scroll(&review.list_scroll);
        let list_pane = div()
            .w(px(self.file_list_width(window)))
            .h_full()
            .flex_none()
            .relative()
            .bg(rgb(0xfbfcfe))
            .flex()
            .flex_col()
            .child(list)
            .child(Scrollbar::vertical(&review.list_scroll));
        div()
            .flex_1()
            .min_h_0()
            .flex()
            .child(list_pane)
            .child(self.pane_divider(Pane::Files, cx))
            .child(self.diff_element())
    }

    fn diff_element(&self) -> Div {
        let review = &self.review;
        let Some(path) = &review.selected else {
            return center("选择文件查看差异".into());
        };
        let mut head = div()
            .h(px(32.))
            .w_full()
            .flex_none()
            .flex()
            .items_center()
            .gap_2()
            .px_3()
            .border_b_1()
            .border_color(rgb(0xe8edf4))
            .text_size(px(12.))
            .child(div().min_w_0().flex_1().truncate().child(path.clone()));
        if let Some(file) = review.files.iter().find(|file| &file.path == path) {
            head = head.child(diff_counts(file.added, file.removed));
        }
        let body = if let Some(error) = &review.diff_error {
            center(error.clone())
        } else if review.diff_job.is_some() {
            center("正在读取差异…".into())
        } else if let Some(diff) = &review.diff {
            let raw = diff.raw.clone();
            head = head.child(
                icon_button("copy-git-diff", crate::icons::COPY, "复制原始差异").on_click(
                    move |_, _, app| {
                        app.write_to_clipboard(ClipboardItem::new_string(raw.to_string()));
                    },
                ),
            );
            if diff.rows.is_empty() {
                center("此文件没有文本差异".into())
            } else {
                let rows = diff.rows.clone();
                let list = uniform_list("git-diff-lines", rows.len(), move |range, _, _| {
                    range
                        .filter_map(|index| rows.get(index).map(diff_row))
                        .collect::<Vec<_>>()
                })
                .flex_1()
                .min_h_0()
                .w_full()
                .with_horizontal_sizing_behavior(ListHorizontalSizingBehavior::Unconstrained)
                .with_width_from_item(diff.widest)
                .track_scroll(&review.diff_scroll);
                div()
                    .flex_1()
                    .min_h_0()
                    .relative()
                    .flex()
                    .flex_col()
                    .child(list)
                    .child(Scrollbar::vertical(&review.diff_scroll))
                    .child(Scrollbar::horizontal(&review.diff_scroll))
                    .when(diff.shortened, |body| {
                        body.child(
                            div()
                                .px_3()
                                .py_1()
                                .text_size(px(11.))
                                .text_color(rgb(0x68788b))
                                .child("预览仅显示前段差异，可复制全文"),
                        )
                    })
            }
        } else {
            center("此文件没有文本差异".into())
        };
        div()
            .flex_1()
            .min_w_0()
            .flex()
            .flex_col()
            .child(head)
            .child(body)
    }
}

fn center(text: SharedString) -> Div {
    div()
        .flex_1()
        .min_h_0()
        .min_w_0()
        .flex()
        .items_center()
        .justify_center()
        .px_3()
        .text_size(px(12.))
        .text_color(rgb(0x69778b))
        .child(text)
}

fn file_name(path: &str) -> &str {
    path.trim_end_matches(['/', '\\'])
        .rsplit(['/', '\\'])
        .next()
        .unwrap_or(path)
}

fn diff_counts(added: u64, removed: u64) -> Div {
    div()
        .flex_none()
        .flex()
        .items_center()
        .gap_2()
        .font_family("Consolas")
        .text_size(px(10.))
        .when(added > 0, |row| {
            row.child(div().text_color(rgb(0x248351)).child(format!("+{added}")))
        })
        .when(removed > 0, |row| {
            row.child(div().text_color(rgb(0xb24245)).child(format!("−{removed}")))
        })
}

fn diff_row(row: &DiffRow) -> Div {
    let (bg, foreground) = match row.kind {
        LineKind::Plain => (0xffffff, 0x344158),
        LineKind::Header => (0xf0f5fe, 0x4c6690),
        LineKind::Added => (0xe6f6ec, 0x205f3e),
        LineKind::Removed => (0xfdebec, 0x833637),
    };
    div()
        .w_full()
        .h(px(20.))
        .px_2()
        .flex()
        .items_center()
        .bg(rgb(bg))
        .font_family("Consolas")
        .text_size(px(12.))
        .children([row.old, row.new].into_iter().map(|number| {
            div()
                .w(px(42.))
                .pr_2()
                .flex_none()
                .text_right()
                .text_color(rgb(0x8490a1))
                .children(number.map(|value| value.to_string()))
        }))
        .child(
            div()
                .pl_1()
                .flex_none()
                .whitespace_nowrap()
                .text_color(rgb(foreground))
                .child(row.text.clone()),
        )
}

async fn load_files(
    gateway: &Gateway,
    target: &WorkspaceScope,
    mode: Mode,
) -> Result<Option<(String, FileList)>> {
    let cwd = target.root(gateway).await?;
    let value = target
        .get(gateway, "api/fs/git-root", vec![("path", cwd)], false)
        .await?;
    let root = string(&value, "root").to_owned();
    if root.is_empty() {
        return Ok(None);
    }
    let mut query = vec![("path", root.clone()), ("scope", mode.scope().to_owned())];
    if mode == Mode::Previous {
        let value = target
            .get(
                gateway,
                "api/git/review/rev-parse",
                vec![("path", root.clone()), ("ref", "HEAD~1".into())],
                false,
            )
            .await?;
        let sha = string(&value, "sha");
        if sha.is_empty() {
            return Ok(Some((
                root,
                FileList {
                    files: Vec::new(),
                    base: None,
                },
            )));
        }
        if !matches!(sha.len(), 40 | 64) || !sha.bytes().all(|byte| byte.is_ascii_hexdigit()) {
            bail!("网关未返回有效的提交标识");
        }
        query.push(("base", sha.to_owned()));
    }
    let value = target
        .get(gateway, "api/git/review/list", query, false)
        .await?;
    let list = serde_json::from_value(value).context("网关未返回有效工作区变更")?;
    Ok(Some((root, list)))
}

fn parse_diff(raw: &str) -> Diff {
    const LIMIT: usize = 20_000;
    let mut old = None;
    let mut new = None;
    let mut rows = Vec::new();
    let mut widest = None;
    let mut width = 0usize;
    for line in raw.lines().take(LIMIT) {
        let starts_hunk = line.starts_with("@@ ");
        let kind = if starts_hunk {
            let mut bounds = line.split_whitespace().skip(1);
            old = bounds.next().and_then(|part| hunk_start(part, '-'));
            new = bounds.next().and_then(|part| hunk_start(part, '+'));
            LineKind::Header
        } else if line.starts_with("diff --git ") {
            old = None;
            new = None;
            LineKind::Header
        } else if old.is_none() && new.is_none() {
            LineKind::Header
        } else if line.starts_with('+') {
            LineKind::Added
        } else if line.starts_with('-') {
            LineKind::Removed
        } else {
            LineKind::Plain
        };
        let (old_line, new_line) = match kind {
            LineKind::Added => (None, next_line(&mut new)),
            LineKind::Removed => (next_line(&mut old), None),
            LineKind::Plain if line.starts_with(' ') => (next_line(&mut old), next_line(&mut new)),
            _ => (None, None),
        };
        let columns = line
            .chars()
            .map(|character| {
                if character == '\t' {
                    4
                } else if character.is_ascii() {
                    1
                } else {
                    2
                }
            })
            .sum();
        if columns > width {
            width = columns;
            widest = Some(rows.len());
        }
        rows.push(DiffRow {
            old: old_line,
            new: new_line,
            kind,
            text: line.to_owned().into(),
        });
    }
    Diff {
        raw: raw.to_owned().into(),
        shortened: rows.len() == LIMIT && raw.lines().nth(LIMIT).is_some(),
        rows: rows.into(),
        widest,
    }
}

fn hunk_start(value: &str, prefix: char) -> Option<u32> {
    value.strip_prefix(prefix)?.split(',').next()?.parse().ok()
}

fn next_line(number: &mut Option<u32>) -> Option<u32> {
    let current = (*number)?;
    *number = current.checked_add(1);
    Some(current)
}
