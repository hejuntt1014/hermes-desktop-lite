use crate::theme::{ink, rgb, rgba};

use crate::i18n::text as tr;

use gpui::{
    Context, Div, Entity, EntityInputHandler, FocusHandle, Focusable, Stateful, Window, div,
    prelude::*, px,
};
use gpui_component::{
    Disableable, Sizable,
    button::{Button, ButtonVariants},
    input::{InputEvent, Textarea, TextareaState},
};
use serde_json::{Value, json};
use uuid::Uuid;

use crate::{
    session::{QueuedTurn, Session},
    settings::{Prepared, SkillSubmission},
    style::{INK, MUTED},
};

use super::{Call, Desktop, attachment_ops::file_name, rpc_error};

#[derive(Clone)]
struct Replacement {
    submission_id: String,
    text: String,
    sending: bool,
}

pub(super) struct QueueEditor {
    session: String,
    id: String,
    remote: bool,
    original: String,
    attachments: Vec<String>,
    input: Entity<TextareaState>,
    prior_focus: Option<FocusHandle>,
    replacement: Option<Replacement>,
    error: Option<String>,
    _changes: gpui::Subscription,
}

impl Desktop {
    pub(super) fn has_followups(&self, key: &str) -> bool {
        self.workspace().is_some_and(|workspace| {
            workspace
                .followups
                .get(key)
                .is_some_and(|queue| !queue.is_empty())
        })
    }

    pub(super) fn enqueue_followup(
        &mut self,
        key: &str,
        mut prepared: Prepared,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        prepared.queued = true;
        prepared.staging = true;
        let workspace = self.workspace_mut();
        let text = workspace.drafts.remove(key);
        let files = workspace.draft_files.remove(key);
        let skill = workspace.draft_skills.remove(key);
        workspace
            .followups
            .entry(key.to_owned())
            .or_default()
            .push(prepared);
        if let Err(error) = self.settings.save() {
            let workspace = self.workspace_mut();
            if let Some(queue) = workspace.followups.get_mut(key) {
                queue.pop();
                if queue.is_empty() {
                    workspace.followups.remove(key);
                }
            }
            if let Some(text) = text {
                workspace.drafts.insert(key.to_owned(), text);
            }
            if let Some(files) = files {
                workspace.draft_files.insert(key.to_owned(), files);
            }
            if let Some(skill) = skill {
                workspace.draft_skills.insert(key.to_owned(), skill);
            }
            self.banner = Some(
                crate::i18n::format_text!(
                    "无法保存待发送消息 · {error}",
                    "Could not save the pending message · {error}"
                )
                .into(),
            );
            cx.notify();
            return;
        }
        if self.selected.as_deref() == Some(key) {
            self.restore_draft(window, cx);
        }
        cx.notify();
    }

    pub(super) fn drain_followups(&mut self, key: &str, cx: &mut Context<Self>) {
        if self.out.is_none()
            || !self.sessions.get(key).is_some_and(|session| {
                session.attached
                    && !session.loading
                    && !session.running
                    && !session.submitting
                    && !session.uncertain
                    && session.queued.is_empty()
                    && session.unknown.is_empty()
                    && session.prompts.is_empty()
                    && session.error.is_none()
            })
            || self.model_controls.busy.contains(key)
        {
            return;
        }
        let Some(workspace) = self.workspace() else {
            return;
        };
        if workspace.pending_rewrites.contains_key(key) {
            return;
        }
        let Some(first) = workspace.followups.get(key).and_then(|queue| queue.first()) else {
            return;
        };
        if self
            .queue_editor
            .as_ref()
            .is_some_and(|editor| !editor.remote && editor.session == key && editor.id == first.id)
        {
            return;
        }
        let ready = match workspace.pending_submissions.get(key) {
            None => first.clone(),
            Some(pending) if pending.id == first.id && pending.staging => pending.clone(),
            _ => return,
        };
        self.start_submission(key.to_owned(), ready, cx);
        cx.notify();
    }

    pub(super) fn remove_followup_record(&mut self, key: &str, id: &str) -> bool {
        let workspace = self.workspace_mut();
        let Some(queue) = workspace.followups.get_mut(key) else {
            return false;
        };
        let count = queue.len();
        queue.retain(|entry| entry.id != id);
        let removed = queue.len() != count;
        if queue.is_empty() {
            workspace.followups.remove(key);
        }
        removed
    }

    fn editable_followup(&self, key: &str, id: &str) -> Option<&Prepared> {
        let workspace = self.workspace()?;
        if workspace
            .pending_submissions
            .get(key)
            .is_some_and(|pending| {
                pending.id == id
                    && (!pending.staging
                        || self.sessions.get(key).is_none_or(|session| {
                            session.loading
                                || session.submitting
                                || session.uncertain
                                || !session.attached
                        }))
            })
        {
            return None;
        }
        workspace
            .followups
            .get(key)?
            .iter()
            .find(|row| row.id == id)
    }

    fn open_queue_editor(
        &mut self,
        key: &str,
        id: &str,
        remote: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.selected.as_deref() != Some(key) || self.queue_editor.is_some() {
            return;
        }
        let (original, attachments) = if remote {
            let Some(row) = self
                .sessions
                .get(key)
                .filter(|session| self.canonical && session.attached && !session.loading)
                .and_then(|session| {
                    session
                        .queued
                        .iter()
                        .find(|row| row.id == id && row.can_replace)
                })
                .filter(|_| !self.queue_canceling(key, id))
            else {
                return;
            };
            (row.text.to_string(), Vec::new())
        } else {
            let Some(row) = self.editable_followup(key, id) else {
                return;
            };
            (
                row.text.clone(),
                row.files.iter().map(|path| file_name(path)).collect(),
            )
        };
        let prior_focus = window.focused(cx);
        let input = cx.new(|cx| {
            TextareaState::new(window, cx)
                .auto_grow(3, 12)
                .default_value(original.clone())
                .placeholder(tr("输入排队消息"))
        });
        let changes = cx.subscribe_in(&input, window, |_, _, event, _, cx| {
            if matches!(event, InputEvent::Change) {
                cx.notify();
            }
        });
        input.read(cx).focus_handle(cx).focus(window, cx);
        self.queue_editor = Some(QueueEditor {
            session: key.to_owned(),
            id: id.to_owned(),
            remote,
            original,
            attachments,
            input,
            prior_focus,
            replacement: None,
            error: None,
            _changes: changes,
        });
        cx.notify();
    }

    pub(super) fn close_queue_editor(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(editor) = self.queue_editor.take() {
            if let Some(focus) = editor.prior_focus {
                focus.focus(window, cx);
            }
            self.drain_followups(&editor.session, cx);
            cx.notify();
        }
    }

    pub(super) fn save_queue_editor(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(editor) = self.queue_editor.as_ref() else {
            return;
        };
        let Some(text) = editor.input.update(cx, |input, cx| {
            input
                .marked_text_range(window, cx)
                .is_none()
                .then(|| input.value().to_string())
        }) else {
            return;
        };
        if text == editor.original
            || text.trim().is_empty() && editor.attachments.is_empty()
            || editor
                .replacement
                .as_ref()
                .is_some_and(|attempt| attempt.sending)
        {
            return;
        }
        let key = editor.session.clone();
        let id = editor.id.clone();
        if self.selected.as_deref() != Some(&key) {
            return;
        }
        if editor.remote {
            self.send_queue_replacement(&key, &id, text, cx);
            return;
        }
        let Some(previous) = self.editable_followup(&key, &id).cloned() else {
            self.queue_editor.as_mut().unwrap().error =
                Some(tr("消息已开始发送，无法保存这次编辑").into());
            cx.notify();
            return;
        };
        let skill = previous
            .skill
            .as_ref()
            .and_then(|previous| {
                let (command, arguments) = text
                    .trim()
                    .split_once(char::is_whitespace)
                    .unwrap_or((text.trim(), ""));
                (command
                    .strip_prefix('/')
                    .is_some_and(|name| name.eq_ignore_ascii_case(&previous.name)))
                .then(|| SkillSubmission {
                    name: previous.name.clone(),
                    argument: arguments.trim().to_owned(),
                    prompt: None,
                })
            })
            .or_else(|| self.skill_command(&text));
        let old_stage = self
            .workspace()
            .and_then(|workspace| workspace.pending_submissions.get(&key))
            .filter(|pending| pending.id == id)
            .cloned();
        self.apply_followup_edit(&key, &id, &text, skill.clone());
        if let Err(error) = self.settings.save() {
            self.apply_followup_edit(&key, &id, &previous.text, previous.skill);
            if let Some(stage) = old_stage {
                self.workspace_mut().pending_submissions.insert(key, stage);
            }
            self.queue_editor.as_mut().unwrap().error = Some(crate::i18n::format_text!(
                "无法保存排队消息 · {error}",
                "Could not save queued message · {error}"
            ));
            cx.notify();
            return;
        }
        if let Some(session) = self
            .sessions
            .get_mut(&key)
            .filter(|session| !session.uncertain)
        {
            session.error = None;
        }
        self.close_queue_editor(window, cx);
    }

    fn apply_followup_edit(
        &mut self,
        key: &str,
        id: &str,
        text: &str,
        skill: Option<SkillSubmission>,
    ) {
        let workspace = self.workspace_mut();
        if let Some(row) = workspace
            .followups
            .get_mut(key)
            .and_then(|queue| queue.iter_mut().find(|row| row.id == id))
        {
            row.text = text.to_owned();
            row.skill = skill.clone();
        }
        if let Some(stage) = workspace
            .pending_submissions
            .get_mut(key)
            .filter(|row| row.id == id)
        {
            stage.text = text.to_owned();
            stage.skill = skill;
        }
    }

    fn send_queue_replacement(
        &mut self,
        key: &str,
        id: &str,
        text: String,
        cx: &mut Context<Self>,
    ) {
        let Some(session) = self
            .sessions
            .get(key)
            .filter(|session| self.out.is_some() && session.attached && !session.loading)
        else {
            return;
        };
        let editor = self.queue_editor.as_mut().unwrap();
        if editor.replacement.is_none()
            && !session
                .queued
                .iter()
                .any(|row| row.id == id && row.can_replace)
        {
            editor.error = Some(tr("这条消息已离开队列，编辑内容仍可复制").into());
            cx.notify();
            return;
        }
        let attempt = editor.replacement.get_or_insert_with(|| Replacement {
            submission_id: Uuid::new_v4().to_string(),
            text,
            sending: false,
        });
        let submission_id = attempt.submission_id.clone();
        let mut params = json!({"session_id":session.runtime, "admission_id":id,
            "submission_id":submission_id, "text":attempt.text});
        if !session.profile.is_empty() {
            params["profile"] = json!(session.profile);
        }
        editor.error = None;
        if self.call(
            "prompt.replace_queued",
            params,
            Call::ReplaceQueued(key.to_owned(), id.to_owned(), submission_id),
        ) {
            self.queue_editor
                .as_mut()
                .unwrap()
                .replacement
                .as_mut()
                .unwrap()
                .sending = true;
        }
        cx.notify();
    }

    pub(super) fn replace_queued_lost(
        &mut self,
        key: &str,
        id: &str,
        submission_id: &str,
        timeout: bool,
    ) {
        if let Some(editor) = self.queue_editor.as_mut().filter(|editor| {
            editor.session == key
                && editor.id == id
                && editor
                    .replacement
                    .as_ref()
                    .is_some_and(|attempt| attempt.submission_id == submission_id)
        }) {
            editor.replacement.as_mut().unwrap().sending = false;
            editor.error = Some(tr("未收到保存确认，可重试这次保存").into());
        }
        if timeout {
            self.attach(key, true);
        }
    }

    pub(super) fn replaced_queued(
        &mut self,
        key: &str,
        id: &str,
        submission_id: &str,
        result: &Value,
        error: Option<&Value>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(session) = self.sessions.get(key) else {
            return;
        };
        let confirmed = error.is_none()
            && result["admission_id"].is_string()
            && result["ref"]["session_id"] == session.runtime;
        if confirmed {
            self.sessions.get_mut(key).unwrap().take_queued(id);
        }
        self.attach(key, true);
        if let Some(editor) = self.queue_editor.as_mut().filter(|editor| {
            editor.session == key
                && editor.id == id
                && editor
                    .replacement
                    .as_ref()
                    .is_some_and(|attempt| attempt.submission_id == submission_id)
        }) {
            if confirmed {
                self.close_queue_editor(window, cx);
            } else {
                editor.replacement.as_mut().unwrap().sending = false;
                if let Some(error) = error {
                    if matches!(error["code"].as_i64(), Some(4000..=4999 | -32601 | -32602)) {
                        editor.replacement = None;
                    }
                    editor.error = Some(rpc_error(error));
                } else {
                    editor.error = Some(tr("未收到保存确认，可重试这次保存").into());
                }
            }
        }
        cx.notify();
    }

    pub(super) fn queue_editor_panel(
        &self,
        window: &Window,
        cx: &mut Context<Self>,
    ) -> Option<Stateful<Div>> {
        let editor = self.queue_editor.as_ref()?;
        let text = editor.input.read(cx).value();
        let saving = editor
            .replacement
            .as_ref()
            .is_some_and(|attempt| attempt.sending);
        let enabled = !saving
            && text.as_ref() != editor.original
            && (!text.trim().is_empty() || !editor.attachments.is_empty());
        Some(
            div()
                .id("queue-editor-overlay")
                .absolute()
                .inset_0()
                .occlude()
                .flex()
                .items_center()
                .justify_center()
                .bg(rgba(0x24324b36))
                .child(
                    div()
                        .id("queue-editor")
                        .key_context("HermesQueueEditor")
                        .w((window.viewport_size().width - px(46.)).min(px(550.)))
                        .p_4()
                        .flex()
                        .flex_col()
                        .gap_3()
                        .rounded(px(9.))
                        .shadow_lg()
                        .bg(rgb(0xffffff))
                        .text_color(ink(INK))
                        .child(
                            div()
                                .text_sm()
                                .font_weight(gpui::FontWeight::SEMIBOLD)
                                .child(tr("编辑排队消息")),
                        )
                        .child(
                            Textarea::new(&editor.input)
                                .small()
                                .disabled(editor.replacement.is_some()),
                        )
                        .when(!editor.attachments.is_empty(), |panel| {
                            panel.child(
                                div()
                                    .min_w_0()
                                    .flex()
                                    .flex_wrap()
                                    .gap_1()
                                    .text_size(px(11.))
                                    .text_color(ink(MUTED))
                                    .children(editor.attachments.iter().map(|name| {
                                        div()
                                            .max_w(px(192.))
                                            .truncate()
                                            .px_1()
                                            .rounded(px(3.))
                                            .bg(rgb(0xf3f6fa))
                                            .child(name.clone())
                                    })),
                            )
                        })
                        .children(editor.error.as_ref().map(|error| {
                            div()
                                .text_size(px(12.))
                                .text_color(ink(0xa43e37))
                                .child(error.clone())
                        }))
                        .child(
                            div()
                                .flex()
                                .items_center()
                                .justify_end()
                                .gap_2()
                                .children(editor.remote.then(|| {
                                    div()
                                        .flex_1()
                                        .text_size(px(11.))
                                        .text_color(ink(MUTED))
                                        .child(tr("保存后移至队尾"))
                                }))
                                .child(
                                    Button::new("cancel-queue-edit")
                                        .small()
                                        .ghost()
                                        .label(if saving { tr("关闭") } else { tr("取消") })
                                        .on_click(cx.listener(|this, _, window, cx| {
                                            this.close_queue_editor(window, cx)
                                        })),
                                )
                                .child(
                                    Button::new("save-queue-edit")
                                        .small()
                                        .primary()
                                        .disabled(!enabled)
                                        .label(if saving {
                                            tr("正在保存…")
                                        } else if editor.replacement.is_some() {
                                            tr("重试保存")
                                        } else {
                                            tr("保存")
                                        })
                                        .on_click(cx.listener(|this, _, window, cx| {
                                            this.save_queue_editor(window, cx)
                                        })),
                                ),
                        ),
                ),
        )
    }

    fn withdraw_followup(&mut self, key: &str, id: &str, cx: &mut Context<Self>) {
        let pending = self
            .workspace()
            .and_then(|workspace| workspace.pending_submissions.get(key))
            .is_some_and(|row| row.id == id);
        if pending
            && self.sessions.get(key).is_none_or(|session| {
                !session.attached || session.loading || session.submitting || session.uncertain
            })
        {
            return;
        }
        let original = self
            .workspace()
            .and_then(|workspace| workspace.followups.get(key))
            .cloned();
        if self.remove_followup_record(key, id) {
            let original_pending = if pending {
                self.workspace_mut().pending_submissions.remove(key)
            } else {
                None
            };
            if let Err(error) = self.settings.save() {
                let workspace = self.workspace_mut();
                if let Some(queue) = original {
                    workspace.followups.insert(key.to_owned(), queue);
                }
                if let Some(prepared) = original_pending {
                    workspace
                        .pending_submissions
                        .insert(key.to_owned(), prepared);
                }
                self.banner = Some(
                    crate::i18n::format_text!(
                        "无法撤回待发送消息 · {error}",
                        "Could not withdraw the pending message · {error}"
                    )
                    .into(),
                );
                cx.notify();
                return;
            }
            if let Some(session) = self
                .sessions
                .get_mut(key)
                .filter(|session| pending || !session.submitting)
            {
                session.error = None;
            }
            self.prune_clipboard_files();
            self.drain_followups(key, cx);
            cx.notify();
        }
    }

    fn retry_followup(&mut self, key: &str, cx: &mut Context<Self>) {
        if let Some(session) = self
            .sessions
            .get_mut(key)
            .filter(|session| !session.submitting && !session.uncertain)
        {
            session.error = None;
            self.drain_followups(key, cx);
            cx.notify();
        }
    }

    fn withdraw_server_queue(&mut self, key: &str, id: &str, cx: &mut Context<Self>) {
        let Some(session) = self.sessions.get(key).filter(|session| {
            self.canonical
                && session.attached
                && !session.loading
                && !id.is_empty()
                && session.queued.iter().any(|row| row.id == id)
        }) else {
            return;
        };
        if self.queue_canceling(key, id) {
            return;
        }
        let mut params = json!({"session_id":session.runtime, "admission_id":id});
        if !session.profile.is_empty() {
            params["profile"] = json!(session.profile);
        }
        self.call(
            "prompt.cancel",
            params,
            Call::CancelQueued(key.to_owned(), id.to_owned()),
        );
        cx.notify();
    }

    fn queue_canceling(&self, key: &str, id: &str) -> bool {
        self.pending.values().any(|pending| {
            matches!(pending, Call::CancelQueued(session, row) | Call::ReplaceQueued(session, row, _)
            if session == key && row == id)
        })
    }

    pub(super) fn canceled_queued(
        &mut self,
        key: &str,
        id: &str,
        result: &Value,
        error: Option<&Value>,
        cx: &mut Context<Self>,
    ) {
        let Some(session) = self.sessions.get_mut(key) else {
            return;
        };
        if let Some(error) = error {
            session.error = Some(rpc_error(error));
        } else {
            if result["status"] == "terminal" && result["admission_id"] == id {
                session.take_queued(id);
            }
            self.attach(key, true);
        }
        cx.notify();
    }

    pub(super) fn queue_panel(
        &self,
        key: &str,
        session: &Session,
        cx: &mut Context<Self>,
    ) -> Option<Stateful<Div>> {
        let followups = self
            .workspace()
            .and_then(|workspace| workspace.followups.get(key))
            .map(Vec::as_slice)
            .unwrap_or(&[]);
        if followups.is_empty() && session.queued.is_empty() {
            return None;
        }
        let pending = self
            .workspace()
            .and_then(|workspace| workspace.pending_submissions.get(key));
        let mut panel = div()
            .id("followup-queue")
            .max_h(px(128.))
            .overflow_y_scroll()
            .flex()
            .flex_col()
            .gap(px(3.));
        for (index, entry) in session.queued.iter().enumerate() {
            panel = panel.child(self.remote_queue_row(key, entry, index, cx));
        }
        for (index, entry) in followups.iter().enumerate() {
            let awaiting = session.uncertain || session.loading || !session.attached;
            let sending = pending.is_some_and(|pending| pending.id == entry.id)
                && (session.submitting || awaiting);
            let label = if sending && awaiting {
                tr("待确认")
            } else if sending {
                tr("正在发送")
            } else {
                tr("排队中")
            };
            let session_key = key.to_owned();
            let id = entry.id.clone();
            let retry_key = session_key.clone();
            let mut row = queue_row(("local-queue", index), label, entry.text.clone());
            if !entry.files.is_empty() {
                row = row.child(div().flex_none().text_color(ink(MUTED)).child(
                    crate::i18n::format_text!("{} 个附件", "{} attachment(s)", entry.files.len()),
                ));
            }
            if !sending {
                if index == 0 && !session.running && session.error.is_some() {
                    row = row.child(queue_action("retry-followup", tr("重试")).on_click(
                        cx.listener(move |this, _, _, cx| this.retry_followup(&retry_key, cx)),
                    ));
                }
                let edit_key = session_key.clone();
                let edit_id = id.clone();
                if self.editable_followup(key, &entry.id).is_some() {
                    row = row.child(queue_action("edit-followup", tr("编辑")).on_click(
                        cx.listener(move |this, _, window, cx| {
                            this.open_queue_editor(&edit_key, &edit_id, false, window, cx)
                        }),
                    ));
                }
                row = row.child(queue_action("withdraw-followup", tr("撤回")).on_click(
                    cx.listener(move |this, _, _, cx| {
                        this.withdraw_followup(&session_key, &id, cx)
                    }),
                ));
            }
            panel = panel.child(row);
        }
        Some(panel)
    }

    fn remote_queue_row(
        &self,
        key: &str,
        entry: &QueuedTurn,
        index: usize,
        cx: &mut Context<Self>,
    ) -> Stateful<Div> {
        let changing = self.queue_canceling(key, &entry.id);
        let mut row = queue_row(
            ("remote-queue", index),
            if changing {
                tr("正在更新")
            } else {
                tr("排队中")
            },
            entry.text.clone(),
        );
        if self.canonical && !entry.id.is_empty() && !changing {
            let session = key.to_owned();
            let id = entry.id.clone();
            if entry.can_replace {
                let edit_session = session.clone();
                let edit_id = id.clone();
                row = row.child(queue_action("edit-remote-queue", tr("编辑")).on_click(
                    cx.listener(move |this, _, window, cx| {
                        this.open_queue_editor(&edit_session, &edit_id, true, window, cx)
                    }),
                ));
            }
            row = row.child(queue_action("withdraw-remote", tr("撤回")).on_click(
                cx.listener(move |this, _, _, cx| this.withdraw_server_queue(&session, &id, cx)),
            ));
        }
        row
    }
}

fn queue_row(
    id: impl Into<gpui::ElementId>,
    label: &'static str,
    text: impl Into<gpui::SharedString>,
) -> Stateful<Div> {
    div()
        .id(id)
        .min_h(px(26.))
        .px_2()
        .flex()
        .items_center()
        .gap_2()
        .rounded(px(5.))
        .bg(rgb(0xf6f8fc))
        .text_size(px(11.5))
        .child(div().flex_none().text_color(ink(MUTED)).child(label))
        .child(
            div()
                .flex_1()
                .min_w_0()
                .truncate()
                .text_color(ink(INK))
                .child(text.into()),
        )
}

fn queue_action(id: &'static str, label: &'static str) -> Stateful<Div> {
    div()
        .id(id)
        .px_1()
        .py(px(2.))
        .flex_none()
        .rounded(px(3.))
        .cursor_pointer()
        .text_color(ink(MUTED))
        .hover(|row| row.bg(rgb(0xe6edf8)).text_color(ink(INK)))
        .child(label)
}
