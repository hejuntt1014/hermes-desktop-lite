use crate::theme::{ink, rgb};

use crate::i18n::text as tr;

use std::{ops::Range, sync::Arc, time::Duration};

use gpui::{
    Context, Div, Entity, EntityInputHandler, FocusHandle, Focusable, HighlightStyle, ListOffset,
    SharedString, StyledText, Task, Window, div, prelude::*, px,
};
use gpui_component::input::{Input, InputState, SelectAll};
use markdown::{ParseOptions, mdast::Node, to_mdast};
use regex::RegexBuilder;

use super::view::{icon_button, panel};
use super::{Desktop, Row, attachment_ops::display_file_refs};

pub(super) struct TranscriptFind {
    pub input: Entity<InputState>,
    pub open: bool,
    prior_focus: Option<FocusHandle>,
    query: SharedString,
    job: Option<Task<()>>,
    index: Option<Arc<[Segment]>>,
    index_revision: u64,
    hits: Vec<Hit>,
    active: usize,
}

struct Segment {
    row: usize,
    text: SharedString,
}

struct Hit {
    row: usize,
    text: SharedString,
    span: Range<usize>,
}

impl TranscriptFind {
    pub(super) fn searching(&self) -> bool { self.open && !self.query.is_empty() }

    pub fn new(input: Entity<InputState>) -> Self {
        Self {
            input,
            open: false,
            prior_focus: None,
            query: "".into(),
            job: None,
            index: None,
            index_revision: 0,
            hits: Vec::new(),
            active: 0,
        }
    }

    pub fn row_highlight(&self, row: usize) -> Option<u32> {
        if self.hits.get(self.active).is_some_and(|hit| hit.row == row) {
            Some(0xfff2ce)
        } else if self.hits.binary_search_by_key(&row, |hit| hit.row).is_ok() {
            Some(0xfffbef)
        } else {
            None
        }
    }
}

impl Desktop {
    pub(super) fn open_transcript_find(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.settings_open
            || self.files.open
            || self.review.open
            || self.selected.is_none()
            || self.media.is_open()
        {
            return;
        }
        let already_open = self.transcript_find.open;
        if !already_open {
            self.transcript_find.open = true;
            self.transcript_find.prior_focus = window.focused(cx);
        }
        self.transcript_find
            .input
            .update(cx, |field, cx| field.focus(window, cx));
        if already_open {
            window.dispatch_action(Box::new(SelectAll), cx);
        }
        cx.notify();
    }

    pub(super) fn close_transcript_find(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let find = &mut self.transcript_find;
        if !find.open {
            return;
        }
        find.open = false;
        find.job = None;
        find.index = None;
        find.query = "".into();
        find.hits.clear();
        find.active = 0;
        if find.input.read(cx).focus_handle(cx).is_focused(window) {
            find.prior_focus
                .take()
                .unwrap_or_else(|| self.workspace_focus.clone())
                .focus(window, cx);
        }
        find.prior_focus = None;
        find.input
            .update(cx, |field, cx| field.set_value("", window, cx));
        cx.notify();
    }

    pub(super) fn transcript_find_changed(&mut self, cx: &mut Context<Self>) {
        let find = &mut self.transcript_find;
        let query = find.input.read(cx).value();
        if !find.open || find.query == query {
            return;
        }
        find.query = query;
        find.job = None;
        find.hits.clear();
        find.active = 0;
        if self.transcript_find.searching() { self.older_history(cx); }
        self.schedule_transcript_find(true, cx);
        cx.notify();
    }

    pub(super) fn transcript_changed(&mut self, cx: &mut Context<Self>) {
        let find = &mut self.transcript_find;
        if !find.open {
            return;
        }
        find.index = None;
        find.index_revision = find.index_revision.wrapping_add(1);
        self.schedule_transcript_find(false, cx);
    }

    fn schedule_transcript_find(&mut self, reveal: bool, cx: &mut Context<Self>) {
        let find = &mut self.transcript_find;
        if !find.open || find.query.is_empty() || find.job.is_some() {
            return;
        }
        let query = find.query.clone();
        let runtime = self.runtime.clone();
        find.job = Some(cx.spawn(async move |view, cx| {
            cx.background_executor()
                .timer(Duration::from_millis(160))
                .await;
            let Ok((revision, cached, rows)) = view.update(cx, |this, _| {
                let state = &this.transcript_find;
                let rows = if state.index.is_none() {
                    this.selected
                        .as_ref()
                        .and_then(|key| this.sessions.get(key))
                        .map(|session| {
                            (0..session.count())
                                .filter_map(|row| match session.row(row)? {
                                    Row::User(message) => {
                                        Some((row, message.display().clone(), false))
                                    }
                                    Row::Answer(answer) => {
                                        Some((row, answer.body.display().clone(), true))
                                    }
                                    Row::Notice(text) => Some((row, text, false)),
                                    Row::Background(notice) => Some((row, notice.raw, false)),
                                    _ => None,
                                })
                                .collect()
                        })
                        .unwrap_or_default()
                } else {
                    Vec::new()
                };
                (state.index_revision, state.index.clone(), rows)
            }) else {
                return;
            };
            let searched = runtime
                .spawn_blocking(move || {
                    let index = cached.unwrap_or_else(|| make_index(rows));
                    let hits = find_matches(&index, &query);
                    (index, hits)
                })
                .await;
            let _ = view.update(cx, |this, cx| {
                let state = &mut this.transcript_find;
                state.job = None;
                if let Ok((index, hits)) = searched {
                    let previous = state.hits.get(state.active);
                    state.active = previous
                        .and_then(|before| {
                            hits.iter().position(|hit| {
                                hit.row == before.row
                                    && hit.span == before.span
                                    && hit.text == before.text
                            })
                        })
                        .unwrap_or(0);
                    state.hits = hits;
                    if state.index_revision == revision {
                        state.index = Some(index);
                    }
                }
                if state.index_revision != revision {
                    this.schedule_transcript_find(reveal, cx);
                } else if reveal {
                    this.reveal_transcript_hit(cx);
                }
                cx.notify();
            });
        }));
    }

    pub(super) fn step_transcript_find(&mut self, backwards: bool, cx: &mut Context<Self>) {
        let find = &mut self.transcript_find;
        let count = find.hits.len();
        if count == 0 {
            return;
        }
        find.active = if backwards {
            (find.active + count - 1) % count
        } else {
            (find.active + 1) % count
        };
        self.reveal_transcript_hit(cx);
        cx.notify();
    }

    pub(super) fn navigate_transcript_find(
        &mut self,
        backwards: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let composing = self.transcript_find.input.update(cx, |input, cx| {
            input.marked_text_range(window, cx).is_some()
        });
        if !composing {
            self.step_transcript_find(backwards, cx);
        }
    }

    fn reveal_transcript_hit(&mut self, cx: &mut Context<Self>) {
        let find = &self.transcript_find;
        if let Some(item_ix) = find
            .hits
            .get(find.active)
            .and_then(|hit| self.visible_item_for(hit.row))
        {
            self.following = false;
            self.turn_rail.jumped = None;
            self.list.scroll_to(ListOffset {
                item_ix,
                offset_in_item: px(0.),
            });
            self.reading_moved(cx);
            self.sync_turn_rail();
        }
    }

    pub(super) fn transcript_find_bar(&self, window: &Window, cx: &mut Context<Self>) -> Div {
        let find = &self.transcript_find;
        let focus = find.input.read(cx).focus_handle(cx).is_focused(window);
        let has_matches = !find.hits.is_empty();
        let count = (!find.query.is_empty()).then(|| {
            if has_matches {
                format!("{}/{}", find.active + 1, find.hits.len())
            } else if find.job.is_some() {
                "…".into()
            } else {
                "0/0".into()
            }
        });
        let preview = find.hits.get(find.active).map(Hit::preview);
        div()
            .absolute()
            .right(px(12.))
            .top(px(8.))
            .key_context("HermesFindInput")
            .child(
                panel()
                    .rounded(px(5.))
                    .shadow_md()
                    .w(px(294.))
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap_1()
                            .p_1()
                            .child(
                                div()
                                    .min_w_0()
                                    .flex_1()
                                    .border_1()
                                    .border_color(rgb(if focus { 0x1453ef } else { 0xdfe4ed }))
                                    .rounded(px(3.))
                                    .child(
                                        Input::new(&find.input)
                                            .h(px(25.))
                                            .appearance(false)
                                            .bordered(false)
                                            .focus_bordered(false)
                                            .cleanable(true),
                                    ),
                            )
                            .children(count.map(|count| {
                                div()
                                    .min_w(px(33.))
                                    .text_center()
                                    .text_size(px(11.))
                                    .text_color(ink(0x656f7e))
                                    .child(count)
                            }))
                            .child(
                                icon_button(
                                    "find-previous",
                                    crate::icons::ARROW_UP,
                                    tr("上一个匹配"),
                                )
                                .when(!has_matches, |button| button.opacity(0.45))
                                .on_click(
                                    cx.listener(|this, _, _, cx| {
                                        this.step_transcript_find(true, cx)
                                    }),
                                ),
                            )
                            .child(
                                icon_button(
                                    "find-next",
                                    crate::icons::ARROW_DOWN,
                                    tr("下一个匹配"),
                                )
                                .when(!has_matches, |button| button.opacity(0.45))
                                .on_click(cx.listener(
                                    |this, _, _, cx| this.step_transcript_find(false, cx),
                                )),
                            )
                            .child(
                                icon_button("find-close", crate::icons::TAB_CLOSE, tr("关闭查找"))
                                    .on_click(cx.listener(|this, _, window, cx| {
                                        this.close_transcript_find(window, cx)
                                    })),
                            ),
                    )
                    .children(preview.map(|preview| {
                        div()
                            .px_2()
                            .py_1()
                            .border_t_1()
                            .border_color(rgb(0xe7eaf0))
                            .overflow_hidden()
                            .text_size(px(11.))
                            .text_color(ink(0x5d6773))
                            .truncate()
                            .child(preview)
                    })),
            )
    }
}

fn make_index(rows: Vec<(usize, SharedString, bool)>) -> Arc<[Segment]> {
    let mut index = Vec::with_capacity(rows.len());
    for (row, source, markdown) in rows {
        if markdown {
            match to_mdast(&source, &ParseOptions::gfm()) {
                Ok(Node::Root(root)) => {
                    for block in root.children {
                        let mut text = String::new();
                        markdown_text(&block, &mut text);
                        if !text.is_empty() {
                            index.push(Segment {
                                row,
                                text: text.into(),
                            });
                        }
                    }
                }
                _ => index.push(Segment { row, text: source }),
            }
        } else {
            let (files, body) = display_file_refs(&source);
            if files.is_empty() {
                index.push(Segment { row, text: source });
            } else {
                index.extend(files.into_iter().map(|text| Segment { row, text }));
                if !body.is_empty() {
                    index.push(Segment {
                        row,
                        text: body.to_owned().into(),
                    });
                }
            }
        }
    }
    index.into()
}

fn markdown_text(node: &Node, result: &mut String) {
    match node {
        Node::Definition(_) | Node::FootnoteDefinition(_) => return,
        Node::Html(html) => {
            if matches!(html.value.as_str(), "<br>" | "<br/>" | "<br />") {
                result.push('\n');
            }
            return;
        }
        Node::Break(_) => {
            result.push('\n');
            return;
        }
        _ => {}
    }
    if let Some(children) = node.children() {
        for child in children {
            markdown_text(child, result);
        }
    } else {
        result.push_str(&node.to_string());
    }
    if matches!(
        node,
        Node::Paragraph(_) | Node::TableCell(_) | Node::Code(_)
    ) {
        result.push('\n');
    }
}

fn find_matches(segments: &[Segment], query: &str) -> Vec<Hit> {
    let Ok(pattern) = RegexBuilder::new(&regex::escape(query))
        .case_insensitive(true)
        .build()
    else {
        return Vec::new();
    };
    let mut hits = Vec::new();
    for segment in segments {
        hits.extend(pattern.find_iter(&segment.text).map(|matched| Hit {
            row: segment.row,
            text: segment.text.clone(),
            span: matched.range(),
        }));
    }
    hits
}

impl Hit {
    fn preview(&self) -> StyledText {
        let text = self.text.as_ref();
        let lower = text[..self.span.start]
            .char_indices()
            .rev()
            .nth(16)
            .map_or(0, |(offset, _)| offset);
        let upper = text[self.span.end..]
            .char_indices()
            .nth(30)
            .map_or(text.len(), |(offset, _)| self.span.end + offset);
        let prefix = if lower > 0 { "…" } else { "" };
        let suffix = if upper < text.len() { "…" } else { "" };
        let prefix_len = prefix.len();
        let content = format!(
            "{prefix}{}{suffix}",
            text[lower..upper].replace(['\n', '\r', '\t'], " ")
        );
        StyledText::new(content).with_highlights([(
            self.span.start - lower + prefix_len..self.span.end - lower + prefix_len,
            HighlightStyle {
                background_color: Some(rgb(0xffdb79).into()),
                color: Some(rgb(0x362b13).into()),
                ..Default::default()
            },
        )])
    }
}
