use crate::theme::{ink, rgb, rgba};

use crate::i18n::text as tr;

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};

use gpui::{
    Context, Div, Entity, EntityInputHandler, FocusHandle, Focusable, KeyDownEvent, ScrollHandle,
    Stateful, Window, div, prelude::*, px,
};
use gpui_component::{
    Disableable, Sizable,
    button::{Button, ButtonVariants},
    input::{InputEvent, Textarea, TextareaState},
};
use serde_json::{Value, json};

use crate::{
    icons,
    session::{ClarifyQuestion, Prompt, PromptRoute},
    style::{ACCENT, INK, MUTED, SECONDARY},
};

use super::{Call, Desktop, view::symbol};

#[derive(Clone, PartialEq, Eq, Hash)]
struct Request {
    session: String,
    prompt: String,
}

struct Answer {
    question: ClarifyQuestion,
    seen_answer: Option<String>,
    field: Entity<TextareaState>,
    selected: BTreeSet<usize>,
    _subscription: gpui::Subscription,
}

impl Answer {
    fn is_filled(&self, cx: &gpui::App) -> bool {
        !self.selected.is_empty() || !self.field.read(cx).value().trim().is_empty()
    }

    fn sync_answer(&mut self, saved: Option<&String>, window: &mut Window, cx: &mut gpui::App) {
        if let Some(saved) = saved.filter(|saved| self.seen_answer.as_ref() != Some(*saved)) {
            let (selected, text) = unpack_answer(&self.question, saved);
            self.selected = selected;
            self.seen_answer = Some(saved.clone());
            self.field
                .update(cx, |field, cx| field.set_value(text, window, cx));
        }
    }
}

fn unpack_answer(question: &ClarifyQuestion, saved: &str) -> (BTreeSet<usize>, String) {
    let values = if question.multi {
        serde_json::from_str::<Vec<String>>(saved).unwrap_or_else(|_| vec![saved.to_owned()])
    } else {
        vec![saved.to_owned()]
    };
    let mut selected = BTreeSet::new();
    let mut other = Vec::new();
    for value in values {
        if let Some(index) = question
            .choices
            .iter()
            .position(|option| choice_label(option) == value)
        {
            selected.insert(index);
        } else {
            other.push(value);
        }
    }
    (selected, other.join("\n"))
}

#[derive(Clone, Copy, Default, PartialEq, Eq)]
struct Cursor {
    question: usize,
    row: usize,
}

pub(super) struct Clarify {
    focus: FocusHandle,
    previous_focus: Option<FocusHandle>,
    visible: Option<Request>,
    deferred: HashSet<Request>,
    forms: HashMap<Request, Vec<Answer>>,
    cursor: Cursor,
    scroll: ScrollHandle,
    empty_submission: bool,
}

impl Clarify {
    pub fn new(focus: FocusHandle) -> Self {
        Self {
            focus,
            previous_focus: None,
            visible: None,
            deferred: HashSet::new(),
            forms: HashMap::new(),
            cursor: Cursor::default(),
            scroll: ScrollHandle::new(),
            empty_submission: false,
        }
    }

    pub fn clear(&mut self) {
        *self = Self::new(self.focus.clone());
    }
}

impl Desktop {
    fn active_questions(&self) -> Option<(Request, Prompt)> {
        if self.out.is_none()
            || self.settings_open
            || self.palette.open
            || self.files.open
            || self.review.open
            || self.media.is_open()
            || self.transcript_find.open
            || self.rewrite_editor.is_some()
            || self.queue_editor.is_some()
        {
            return None;
        }
        let key = self.selected.as_ref()?;
        let session = self
            .sessions
            .get(key)
            .filter(|session| session.attached && !session.loading)?;
        session.prompts.iter().find_map(|(id, prompt)| {
            if !prompt.clarify {
                return None;
            }
            let request = Request {
                session: key.clone(),
                prompt: id.clone(),
            };
            (!self.clarify.deferred.contains(&request)).then(|| (request, prompt.clone()))
        })
    }

    pub(super) fn show_questions(&mut self, id: &str, cx: &mut Context<Self>) {
        if let Some(session) = self.selected.clone() {
            self.clarify.deferred.remove(&Request {
                session,
                prompt: id.to_owned(),
            });
            cx.notify();
        }
    }

    pub(super) fn defer_questions(&mut self, cx: &mut Context<Self>) {
        if let Some(request) = self.clarify.visible.clone() {
            self.clarify.deferred.insert(request);
            cx.notify();
        }
    }

    fn ensure_question_form(
        &mut self,
        request: &Request,
        prompt: &Prompt,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if let Some(form) = self.clarify.forms.get_mut(request)
            && form.len() == prompt.questions.len()
            && form
                .iter()
                .zip(&prompt.questions)
                .all(|(answer, question)| answer.question == *question)
        {
            for answer in form {
                answer.sync_answer(
                    prompt.submitted_answers.get(&answer.question.id),
                    window,
                    cx,
                );
            }
            return false;
        }
        let mut previous = self.clarify.forms.remove(request).unwrap_or_default();
        let answers = prompt
            .questions
            .iter()
            .map(|question| {
                let saved = prompt.submitted_answers.get(&question.id);
                if let Some(index) = previous
                    .iter()
                    .position(|answer| answer.question == *question)
                {
                    let mut answer = previous.swap_remove(index);
                    answer.sync_answer(saved, window, cx);
                    return answer;
                }
                let (selected, other) =
                    saved.map_or_else(Default::default, |saved| unpack_answer(question, saved));
                let placeholder = if question.choices.is_empty() {
                    tr("输入你的答案…")
                } else {
                    tr("其他（输入你的答案）")
                };
                let field = cx.new(|cx| {
                    TextareaState::new(window, cx)
                        .auto_grow(1, 4)
                        .placeholder(placeholder)
                        .default_value(other)
                });
                let key = request.clone();
                let subscription =
                    cx.subscribe_in(&field, window, move |this, field, event, _, cx| {
                        let Some(form) = this.clarify.forms.get_mut(&key) else {
                            return;
                        };
                        let Some((index, answer)) = form
                            .iter_mut()
                            .enumerate()
                            .find(|(_, answer)| answer.field.entity_id() == field.entity_id())
                        else {
                            return;
                        };
                        if matches!(event, InputEvent::Focus)
                            && this.clarify.visible.as_ref() == Some(&key)
                        {
                            this.clarify.cursor = Cursor {
                                question: index,
                                row: answer.question.choices.len(),
                            };
                            this.clarify.scroll.scroll_to_item(index + 1);
                            cx.notify();
                            return;
                        }
                        if !matches!(event, InputEvent::Change) {
                            return;
                        }
                        if !answer.question.multi && !field.read(cx).value().trim().is_empty() {
                            answer.selected.clear();
                        }
                        this.clarify.empty_submission = false;
                        cx.notify();
                    });
                Answer {
                    question: question.clone(),
                    seen_answer: saved.cloned(),
                    field,
                    selected,
                    _subscription: subscription,
                }
            })
            .collect();
        self.clarify.forms.insert(request.clone(), answers);
        true
    }

    fn toggle_question_choice(
        &mut self,
        request: &Request,
        question: usize,
        option: usize,
        multi: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.clarify.visible.as_ref() != Some(request) || self.question_sending(request) {
            return;
        }
        let Some(answer) = self
            .clarify
            .forms
            .get_mut(request)
            .and_then(|form| form.get_mut(question))
        else {
            return;
        };
        if multi {
            if !answer.selected.remove(&option) {
                answer.selected.insert(option);
            }
        } else {
            answer.selected.clear();
            answer.selected.insert(option);
            answer
                .field
                .update(cx, |input, cx| input.set_value("", window, cx));
        }
        self.clarify.empty_submission = false;
        cx.notify();
    }

    fn focus_question(
        &mut self,
        request: &Request,
        cursor: Cursor,
        focus_text: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.clarify.cursor = cursor;
        self.clarify.scroll.scroll_to_item(cursor.question + 1);
        if focus_text {
            self.clarify.forms[request][cursor.question]
                .field
                .read(cx)
                .focus_handle(cx)
                .focus(window, cx);
        } else {
            self.clarify.focus.focus(window, cx);
        }
        cx.notify();
    }

    fn pick_question_choice(
        &mut self,
        request: &Request,
        prompt: &Prompt,
        cursor: Cursor,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let multi = prompt.questions[cursor.question].multi;
        self.toggle_question_choice(request, cursor.question, cursor.row, multi, window, cx);
        let next = (!multi)
            .then(|| {
                let form = &self.clarify.forms[request];
                ((cursor.question + 1)..form.len())
                    .chain(0..cursor.question)
                    .find(|index| !form[*index].is_filled(cx))
            })
            .flatten();
        if let Some(question) = next {
            self.focus_question(
                request,
                Cursor { question, row: 0 },
                prompt.questions[question].choices.is_empty(),
                window,
                cx,
            );
        } else {
            self.focus_question(request, cursor, false, window, cx);
        }
    }

    fn question_key(&mut self, event: &KeyDownEvent, window: &mut Window, cx: &mut Context<Self>) {
        let modifiers = event.keystroke.modifiers;
        if modifiers.control || modifiers.platform || modifiers.function {
            return;
        }
        let key = event.keystroke.key.as_str();
        let switch_question = modifiers.alt && !modifiers.shift && matches!(key, "up" | "down");
        if !switch_question && (modifiers.alt || !self.clarify.focus.is_focused(window)) {
            return;
        }
        let Some((request, prompt)) = self
            .active_questions()
            .filter(|(request, _)| self.clarify.visible.as_ref() == Some(request))
        else {
            return;
        };
        if self.question_sending(&request) {
            return;
        }
        let cursor = self.clarify.cursor;
        let final_question = prompt.questions.len() - 1;
        let options = &prompt.questions[cursor.question].choices;
        if switch_question {
            let question = if key == "up" {
                cursor.question.saturating_sub(1)
            } else {
                (cursor.question + 1).min(final_question)
            };
            if question != cursor.question {
                self.focus_question(
                    &request,
                    Cursor { question, row: 0 },
                    prompt.questions[question].choices.is_empty(),
                    window,
                    cx,
                );
            }
            cx.stop_propagation();
            return;
        }
        if matches!(key, "up" | "down") && !modifiers.shift {
            let next = match (key, cursor.row) {
                ("up", 0) if cursor.question > 0 => Cursor {
                    question: cursor.question - 1,
                    row: prompt.questions[cursor.question - 1].choices.len(),
                },
                ("up", row) => Cursor {
                    row: row.saturating_sub(1),
                    ..cursor
                },
                (_, row) if row < options.len() => Cursor {
                    row: row + 1,
                    ..cursor
                },
                _ => Cursor {
                    question: (cursor.question + 1).min(final_question),
                    row: if cursor.question < final_question {
                        0
                    } else {
                        cursor.row
                    },
                },
            };
            self.focus_question(&request, next, false, window, cx);
            cx.stop_propagation();
            return;
        }
        if event.is_held {
            return;
        }
        if let Some(row) = option_shortcut(key).filter(|row| *row <= options.len()) {
            if row < options.len() {
                self.pick_question_choice(&request, &prompt, Cursor { row, ..cursor }, window, cx);
            } else {
                self.focus_question(&request, Cursor { row, ..cursor }, true, window, cx);
            }
            cx.stop_propagation();
            return;
        }
        if modifiers.shift || !matches!(key, "enter" | "space") {
            return;
        }
        cx.stop_propagation();
        let form = &self.clarify.forms[&request];
        if cursor.row == options.len() {
            self.focus_question(&request, cursor, true, window, cx);
        } else if key == "space"
            || prompt.questions[cursor.question].multi
            || !form[cursor.question].selected.contains(&cursor.row)
        {
            self.pick_question_choice(&request, &prompt, cursor, window, cx);
        } else if let Some(question) = form
            .iter()
            .zip(&prompt.questions)
            .position(|(answer, question)| !question.multi && !answer.is_filled(cx))
        {
            self.focus_question(
                &request,
                Cursor { question, row: 0 },
                prompt.questions[question].choices.is_empty(),
                window,
                cx,
            );
        } else {
            self.submit_questions(false, window, cx);
        }
    }

    fn question_sending(&self, request: &Request) -> bool {
        self.pending.values().any(|call| {
            matches!(call, Call::Answer(session, key) if *session == request.session && *key == request.prompt)
        })
    }

    pub(super) fn submit_questions(
        &mut self,
        skip: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some((request, prompt)) = self
            .active_questions()
            .filter(|(request, _)| self.clarify.visible.as_ref() == Some(request))
        else {
            return;
        };
        if self.question_sending(&request) {
            return;
        }
        let Some(form) = self.clarify.forms.get(&request) else {
            return;
        };
        if !skip
            && form.iter().any(|draft| {
                draft.field.update(cx, |field, cx| {
                    field.marked_text_range(window, cx).is_some()
                })
            })
        {
            return;
        }
        let answers = if skip {
            BTreeMap::new()
        } else {
            prompt
                .questions
                .iter()
                .zip(form)
                .map(|(question, draft)| {
                    let text = draft.field.read(cx).value();
                    let text = text.trim();
                    let mut selected = draft
                        .selected
                        .iter()
                        .filter_map(|index| question.choices.get(*index))
                        .map(|value| choice_label(value))
                        .collect::<Vec<_>>();
                    if !text.is_empty() {
                        if !question.multi {
                            selected.clear();
                        }
                        selected.push(text);
                    }
                    let answer = if question.multi && !selected.is_empty() {
                        serde_json::to_string(&selected).ok()
                    } else {
                        selected.first().map(|value| (*value).to_owned())
                    };
                    (question.id.clone(), answer)
                })
                .collect::<BTreeMap<_, _>>()
        };
        if !skip && answers.values().all(Option::is_none) {
            self.clarify.empty_submission = true;
            cx.notify();
            return;
        }
        let Some(session) = self.sessions.get(&request.session) else {
            return;
        };
        match &prompt.route {
            PromptRoute::Canonical { id, generation, .. } => {
                let answer = if prompt.questions.len() <= 1 {
                    answers.into_values().next().flatten().unwrap_or_default()
                } else if skip {
                    String::new()
                } else {
                    serde_json::to_string(&answers).unwrap_or_default()
                };
                let mut params = json!({ "session_id":session.runtime, "prompt_id":id,
                    "execution_generation":generation, "answer":answer });
                if !session.profile.is_empty() {
                    params["profile"] = json!(session.profile);
                }
                self.call(
                    "clarify.respond",
                    params,
                    Call::Answer(request.session, request.prompt),
                );
            }
            PromptRoute::Request(id) => {
                let result = if skip {
                    json!({"outcome":"cancelled"})
                } else {
                    json!({"outcome":"submitted", "answers":answers})
                };
                if self.out.as_ref().is_some_and(|out| {
                    out.send(json!({"jsonrpc":"2.0","id":id,"result":result}).into())
                        .is_ok()
                }) {
                    self.sessions
                        .get_mut(&request.session)
                        .unwrap()
                        .prompts
                        .remove(&request.prompt);
                }
            }
            PromptRoute::LegacyApproval(_) => {}
        }
        cx.notify();
    }

    pub(super) fn question_overlay(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<Stateful<Div>> {
        let active = self.active_questions();
        let key = active.as_ref().map(|(key, _)| key);
        let switching = self.clarify.visible.as_ref() != key;
        if switching {
            if self.clarify.visible.take().is_some()
                && let Some(previous) = self.clarify.previous_focus.take()
            {
                previous.focus(window, cx);
            }
            if let Some(key) = key {
                self.clarify.previous_focus = window.focused(cx);
                self.clarify.visible = Some(key.clone());
            }
        }
        if let Some((key, prompt)) = &active {
            let rebuilt = self.ensure_question_form(key, prompt, window, cx);
            if switching || rebuilt {
                self.clarify.empty_submission = false;
                self.clarify.cursor = Cursor::default();
                self.clarify.scroll = ScrollHandle::new();
                if prompt
                    .questions
                    .first()
                    .is_some_and(|question| question.choices.is_empty())
                {
                    self.clarify.forms[key][0]
                        .field
                        .read(cx)
                        .focus_handle(cx)
                        .focus(window, cx);
                } else {
                    self.clarify.focus.focus(window, cx);
                }
            }
        }
        self.clarify.forms.retain(|request, _| {
            self.sessions
                .get(&request.session)
                .is_some_and(|session| session.prompts.contains_key(&request.prompt))
        });
        self.clarify
            .deferred
            .retain(|request| self.clarify.forms.contains_key(request));
        let (key, prompt) = active?;
        let busy = self.question_sending(&key);
        let form = &self.clarify.forms[&key];
        let cursor = self.clarify.cursor;
        let navigating = self.clarify.focus.is_focused(window);
        let answered = form.iter().filter(|answer| answer.is_filled(cx)).count();
        let questions =
            div()
                .id("clarify-scroll")
                .min_h_0()
                .flex_1()
                .overflow_y_scroll()
                .track_scroll(&self.clarify.scroll)
                .p_3()
                .flex()
                .flex_col()
                .gap_3()
                .child(
                    div()
                        .flex()
                        .justify_between()
                        .items_center()
                        .gap_2()
                        .text_size(px(11.))
                        .text_color(ink(MUTED))
                        .child(if form.len() == 1 {
                            tr("1 个问题").to_owned()
                        } else {
                            crate::i18n::format_text!(
                                "已回答 {answered} / {}",
                                "Answered {answered} of {}",
                                form.len()
                            )
                        })
                        .child(div().flex_1())
                        .child(symbol(icons::QUESTION, 15.)),
                )
                .children(prompt.questions.iter().zip(form).enumerate().map(
                    |(index, (question, answer))| {
                        let options = &question.choices;
                        div()
                            .flex()
                            .flex_col()
                            .gap(px(3.))
                            .when(index > 0, |group| {
                                group.border_t_1().border_color(rgb(0xe5eaf1)).pt_2()
                            })
                            .child(
                                div()
                                    .flex()
                                    .items_start()
                                    .gap_2()
                                    .child(
                                        div()
                                            .flex_1()
                                            .min_w_0()
                                            .text_size(px(14.))
                                            .font_weight(gpui::FontWeight::MEDIUM)
                                            .child(question.text.clone()),
                                    )
                                    .children((!options.is_empty()).then(|| {
                                        div()
                                            .px_1()
                                            .rounded(px(3.))
                                            .bg(rgb(0xeef1f6))
                                            .text_size(px(11.))
                                            .flex_none()
                                            .text_color(ink(MUTED))
                                            .child(if question.multi {
                                                tr("可多选")
                                            } else {
                                                tr("选一个")
                                            })
                                    })),
                            )
                            .children(options.iter().enumerate().map(|(option, label)| {
                                let active = answer.selected.contains(&option);
                                let key = key.clone();
                                let name = choice_label(label);
                                let pointed = navigating
                                    && cursor
                                        == Cursor {
                                            question: index,
                                            row: option,
                                        };
                                div()
                                    .id(("clarify-choice", index * 1000 + option))
                                    .min_h(px(25.))
                                    .px_1()
                                    .py(px(3.))
                                    .flex()
                                    .items_start()
                                    .gap_2()
                                    .rounded(px(4.))
                                    .when(!busy, |choice| {
                                        choice
                                            .cursor_pointer()
                                            .hover(|choice| choice.bg(rgb(0xeaf0fb)))
                                    })
                                    .when(busy, |choice| choice.opacity(0.56))
                                    .when(active || pointed, |choice| choice.bg(rgb(0xe8effe)))
                                    .child(choice_key(option, active, pointed))
                                    .child(
                                        div()
                                            .flex()
                                            .flex_wrap()
                                            .items_center()
                                            .gap(px(5.))
                                            .min_w_0()
                                            .flex_1()
                                            .child(
                                                div()
                                                    .min_w_0()
                                                    .max_w_full()
                                                    .text_size(px(13.))
                                                    .text_color(ink(if active {
                                                        INK
                                                    } else {
                                                        SECONDARY
                                                    }))
                                                    .child(name.to_owned()),
                                            )
                                            .children((name != label).then(|| {
                                                div()
                                                    .text_size(px(11.))
                                                    .text_color(ink(MUTED))
                                                    .child(tr("推荐"))
                                            })),
                                    )
                                    .on_click(cx.listener(move |this, _, window, cx| {
                                        if let Some((request, prompt)) =
                                            this.active_questions().filter(|(request, _)| {
                                                *request == key && !this.question_sending(request)
                                            })
                                        {
                                            this.pick_question_choice(
                                                &request,
                                                &prompt,
                                                Cursor {
                                                    question: index,
                                                    row: option,
                                                },
                                                window,
                                                cx,
                                            );
                                        }
                                    }))
                            }))
                            .child(
                                div()
                                    .mt_1()
                                    .px_1()
                                    .flex()
                                    .items_center()
                                    .gap_2()
                                    .rounded(px(4.))
                                    .when(
                                        navigating
                                            && cursor
                                                == Cursor {
                                                    question: index,
                                                    row: options.len(),
                                                },
                                        |row| row.bg(rgb(0xe8effe)),
                                    )
                                    .children((!options.is_empty()).then(|| {
                                        choice_key(
                                            options.len(),
                                            !answer.field.read(cx).value().trim().is_empty(),
                                            navigating
                                                && cursor
                                                    == Cursor {
                                                        question: index,
                                                        row: options.len(),
                                                    },
                                        )
                                    }))
                                    .child(div().min_w_0().flex_1().child(
                                        Textarea::new(&answer.field).small().disabled(busy),
                                    )),
                            )
                    },
                ));
        let error = self
            .sessions
            .get(&key.session)
            .and_then(|session| session.error.as_ref());
        let width = (f32::from(window.viewport_size().width) - 48.).min(532.);
        let max_height = f32::from(window.viewport_size().height) - 46.;
        Some(
            div()
                .id("clarify-overlay")
                .absolute()
                .inset_0()
                .occlude()
                .flex()
                .items_center()
                .justify_center()
                .bg(rgba(0x24324b36))
                .child(
                    div()
                        .id("clarify-dialog")
                        .key_context("HermesClarifyInput")
                        .track_focus(&self.clarify.focus)
                        .on_key_down(cx.listener(|this, event: &KeyDownEvent, window, cx| {
                            this.question_key(event, window, cx)
                        }))
                        .w(px(width))
                        .max_h(px(max_height))
                        .flex()
                        .flex_col()
                        .rounded(px(9.))
                        .shadow_lg()
                        .border_1()
                        .border_color(rgb(0xd9e3f2))
                        .bg(rgb(0xffffff))
                        .text_color(ink(INK))
                        .p_3()
                        .gap_2()
                        .child(
                            div()
                                .h(px(27.))
                                .px_1()
                                .flex_none()
                                .flex()
                                .items_center()
                                .gap_2()
                                .child(
                                    div()
                                        .flex_1()
                                        .text_size(px(15.))
                                        .font_weight(gpui::FontWeight::SEMIBOLD)
                                        .child(tr("Hermes 想确认")),
                                )
                                .child(
                                    Button::new("defer-clarify")
                                        .small()
                                        .ghost()
                                        .label(tr("稍后"))
                                        .on_click(
                                            cx.listener(|this, _, _, cx| this.defer_questions(cx)),
                                        ),
                                ),
                        )
                        .child(questions.min_h_0().rounded(px(8.)).bg(rgb(0xf5f7fb)))
                        .children(self.clarify.empty_submission.then(|| {
                            div()
                                .px_4()
                                .text_size(px(12.))
                                .text_color(ink(0xa43e37))
                                .child(tr("请至少回答一个问题。"))
                        }))
                        .children(error.map(|error| {
                            div()
                                .px_4()
                                .text_size(px(12.))
                                .text_color(ink(0xa43e37))
                                .child(error.clone())
                        }))
                        .child(
                            div()
                                .h(px(31.))
                                .px_1()
                                .flex_none()
                                .flex()
                                .items_center()
                                .justify_end()
                                .gap_2()
                                .child(
                                    div()
                                        .flex_1()
                                        .min_w_0()
                                        .text_size(px(11.))
                                        .text_color(ink(MUTED))
                                        .child(if navigating {
                                            tr("↑ ↓ 移动 · Enter 选择")
                                        } else if cfg!(target_os = "macos") {
                                            tr("⌥ ↑ ↓ 切换问题 · ⌘ Enter 提交")
                                        } else {
                                            tr("Alt + ↑ ↓ 切换问题 · Ctrl + Enter 提交")
                                        }),
                                )
                                .child(
                                    Button::new("skip-clarify")
                                        .ghost()
                                        .small()
                                        .label(if form.len() == 1 {
                                            tr("跳过")
                                        } else {
                                            tr("跳过全部")
                                        })
                                        .disabled(busy)
                                        .on_click(cx.listener(|this, _, window, cx| {
                                            this.submit_questions(true, window, cx)
                                        })),
                                )
                                .child(
                                    Button::new("submit-clarify")
                                        .primary()
                                        .small()
                                        .disabled(busy || answered == 0)
                                        .label(if busy {
                                            tr("正在提交…")
                                        } else {
                                            tr("确认并继续")
                                        })
                                        .on_click(cx.listener(|this, _, window, cx| {
                                            this.submit_questions(false, window, cx)
                                        })),
                                ),
                        ),
                ),
        )
    }
}

fn option_shortcut(value: &str) -> Option<usize> {
    let [key] = value.as_bytes() else { return None };
    let key = key.to_ascii_lowercase();
    match key {
        b'1'..=b'9' => Some(usize::from(key - b'1')),
        b'a'..=b'z' => Some(usize::from(key - b'a')),
        _ => None,
    }
}

fn choice_key(index: usize, selected: bool, pointed: bool) -> Div {
    let label = if index < 26 {
        char::from(b'A' + index as u8).to_string()
    } else {
        (index + 1).to_string()
    };
    div()
        .size(px(18.))
        .flex_none()
        .flex()
        .items_center()
        .justify_center()
        .rounded(px(4.))
        .border_1()
        .border_color(rgb(if selected || pointed {
            ACCENT
        } else {
            0xdfe5ee
        }))
        .bg(rgb(if selected { ACCENT } else { 0xffffff }))
        .text_color(ink(if selected {
            0xffffff
        } else if pointed {
            ACCENT
        } else {
            MUTED
        }))
        .text_size(px(10.))
        .child(label)
}

fn choice_label(value: &str) -> &str {
    value
        .strip_suffix("(Recommended)")
        .map(str::trim_end)
        .unwrap_or(value)
}

pub(super) fn completed_questions(output: &str) -> Option<Div> {
    if output.len() > 256 * 1024 {
        return None;
    }
    let result: Value = serde_json::from_str(output).ok()?;
    let responses = result["responses"]
        .as_array()
        .filter(|rows| !rows.is_empty())?;
    let unanswered = match result["outcome"].as_str() {
        Some("cancelled") => tr("已跳过"),
        Some("timed_out") => tr("已超时"),
        Some("undelivered") => tr("未送达"),
        _ => tr("未回答"),
    };
    Some(
        div()
            .mx_3()
            .my_1()
            .max_w(px(532.))
            .p_3()
            .rounded(px(8.))
            .bg(rgb(0xf5f7fb))
            .flex()
            .flex_col()
            .gap_2()
            .children(responses.iter().map(|response| {
                let question = response["question"].as_str().unwrap_or_default();
                let value = &response["user_response"];
                let answer = value
                    .as_str()
                    .map(str::to_owned)
                    .or_else(|| {
                        Some(
                            value
                                .as_array()?
                                .iter()
                                .filter_map(Value::as_str)
                                .collect::<Vec<_>>()
                                .join("、"),
                        )
                    })
                    .filter(|text| !text.trim().is_empty());
                let missing = if response["status"] == "skipped" {
                    tr("已跳过")
                } else {
                    unanswered
                };
                let color = if answer.is_some() { SECONDARY } else { MUTED };
                div()
                    .flex()
                    .flex_col()
                    .gap(px(3.))
                    .children(
                        (!question.is_empty())
                            .then(|| answer_line(icons::QUESTION, question.to_owned(), INK)),
                    )
                    .child(answer_line(
                        icons::ANSWER,
                        answer.unwrap_or_else(|| missing.to_owned()),
                        color,
                    ))
            })),
    )
}

fn answer_line(icon: &'static str, text: String, color: u32) -> Div {
    div()
        .flex()
        .items_start()
        .gap_2()
        .text_size(px(13.))
        .child(div().flex_1().min_w_0().text_color(ink(color)).child(text))
        .child(symbol(icon, 14.))
}
