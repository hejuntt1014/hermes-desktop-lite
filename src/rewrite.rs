use crate::i18n::text as tr;

use std::collections::HashSet;

use anyhow::{Context as _, Result, bail};
use gpui::{
    AnyElement, App, ClipboardItem, Context, Div, Entity, EntityInputHandler, FocusHandle, Pixels,
    Stateful, WeakEntity, Window, div, prelude::*, px, rgb, rgba,
};
use gpui_component::{
    Disableable, Sizable,
    button::{Button, ButtonVariants},
    input::{InputEvent, Position, Textarea, TextareaState},
};
use serde_json::{Value, json};
use uuid::Uuid;

use crate::{
    gateway::Gateway,
    media::{
        ChatImage, ImageSource, attachment_ref, prepare_replay_image, upload_chat_image,
        vision_prompt,
    },
    session::{Row, Session, string},
    settings::{PendingRewrite, RewritePhase, StagedImage},
    style::{INK, MUTED},
};

use super::{Call, Desktop, attachment_ops::leading_file_refs, rpc_error, view::svg_symbol};

#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum RewriteKind {
    Edit,
    Retry,
}

#[derive(Clone, PartialEq, Eq)]
pub(super) struct RewriteTarget {
    session: String,
    row_id: u64,
    revision: Option<u64>,
    generation: u64,
    saved_text: gpui::SharedString,
    caption: String,
    attachments: Vec<String>,
    images: Vec<ChatImage>,
    later_turns: usize,
}

pub(super) struct RewriteEditor {
    kind: RewriteKind,
    target: RewriteTarget,
    input: Entity<TextareaState>,
    prior_focus: Option<FocusHandle>,
    focus: FocusHandle,
    stale: bool,
    _input_changes: gpui::Subscription,
}

enum PreparedPictures {
    Canonical(Vec<StagedImage>),
    Legacy(Vec<InlineRewriteImage>),
}

struct InlineRewriteImage {
    reference: String,
    data_url: String,
}

impl Desktop {
    fn ready_for_rewrite(&self, key: &str) -> Option<&Session> {
        self.sessions.get(key).filter(|session| {
            self.out.is_some()
                && session.attached
                && !session.loading
                && !session.running
                && !session.submitting
                && !session.uncertain
                && session.queued.is_empty()
                && session.unknown.is_empty()
                && session.prompts.is_empty()
                && !self.model_controls.busy.contains(key)
        })
    }

    fn rewrite_source(
        &self,
        key: &str,
        index: usize,
        kind: RewriteKind,
    ) -> Option<(&Session, usize)> {
        let session = self.ready_for_rewrite(key)?;
        if self.canonical && session.revision.is_none()
            || self.workspace().is_some_and(|workspace| {
                workspace.pending_submissions.contains_key(key)
                    || workspace.pending_rewrites.contains_key(key)
            })
        {
            return None;
        }
        let user_index = match kind {
            RewriteKind::Edit => index,
            RewriteKind::Retry => {
                let tail = session.rows.get(index + 1..)?;
                if tail
                    .iter()
                    .take_while(|row| !matches!(row, Row::User(_) | Row::Background(_)))
                    .any(|row| matches!(row, Row::Answer(_)))
                {
                    return None;
                }
                let source = session
                    .rows
                    .get(..index)?
                    .iter()
                    .rposition(|row| matches!(row, Row::User(_) | Row::Background(_)))?;
                if !matches!(session.rows[source], Row::User(_)) {
                    return None;
                }
                source
            }
        };
        if !session.user_row_ids.contains_key(&user_index) {
            return None;
        }
        Some((session, user_index))
    }

    pub(super) fn can_rewrite(&self, key: &str, index: usize, kind: RewriteKind) -> bool {
        self.rewrite_editor.is_none() && self.rewrite_source(key, index, kind).is_some()
    }

    fn rewrite_target(&self, key: &str, index: usize, kind: RewriteKind) -> Option<RewriteTarget> {
        let (session, user_index) = self.rewrite_source(key, index, kind)?;
        let row_id = *session.user_row_ids.get(&user_index)?;
        let Row::User(message) = session.rows.get(user_index)? else {
            return None;
        };
        let (files, caption) = leading_file_refs(message.display());
        let images = message.images().to_vec();
        let mut attachments = files
            .into_iter()
            .map(|(path, _)| path.to_owned())
            .collect::<Vec<_>>();
        attachments.retain(|path| {
            !images.iter().any(|image| {
            matches!(&image.source, ImageSource::Gateway(source) if source.as_ref() == path)
        })
        });
        if caption.trim().is_empty() && attachments.is_empty() && images.is_empty() {
            return None;
        }
        let later_turns = session.rows[user_index + 1..]
            .iter()
            .filter(|row| matches!(row, Row::User(_)))
            .count();
        Some(RewriteTarget {
            session: key.to_owned(),
            row_id,
            revision: session.revision,
            generation: session.generation,
            saved_text: message.raw().clone(),
            caption: caption.to_owned(),
            attachments,
            images,
            later_turns,
        })
    }

    fn rewrite_target_is_current(&self, target: &RewriteTarget) -> bool {
        let Some(session) = self.ready_for_rewrite(&target.session) else {
            return false;
        };
        session
            .user_row_ids
            .iter()
            .find(|(_, id)| **id == target.row_id)
            .and_then(|(index, _)| self.rewrite_target(&target.session, *index, RewriteKind::Edit))
            .as_ref()
            == Some(target)
    }

    pub(super) fn open_rewrite(
        &mut self,
        key: &str,
        index: usize,
        kind: RewriteKind,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.selected.as_deref() != Some(key) || self.rewrite_editor.is_some() {
            return;
        }
        let Some(target) = self.rewrite_target(key, index, kind) else {
            return;
        };
        if kind == RewriteKind::Retry && target.later_turns == 0 {
            self.begin_rewrite(&target, &target.caption, window, cx);
            return;
        }
        let prior_focus = window.focused(cx);
        let focus = cx.focus_handle();
        let input = cx.new(|cx| {
            TextareaState::new(window, cx)
                .auto_grow(1, 10)
                .default_value(target.caption.clone())
        });
        let changes = cx.subscribe_in(&input, window, |_, _, event, _, cx| {
            if matches!(event, InputEvent::Change) {
                cx.notify();
            }
        });
        if kind == RewriteKind::Edit {
            self.hold_transcript_row_position(index);
            let (line, last) = target
                .caption
                .split('\n')
                .enumerate()
                .last()
                .unwrap_or_default();
            let end = Position::new(line as u32, last.encode_utf16().count() as u32);
            input.update(cx, |field, cx| {
                field.set_cursor_position(end, window, cx);
                field.focus(window, cx);
            });
        } else {
            focus.focus(window, cx);
        }
        self.rewrite_editor = Some(RewriteEditor {
            kind,
            target,
            input,
            prior_focus,
            focus,
            stale: false,
            _input_changes: changes,
        });
        cx.notify();
    }

    pub(super) fn close_rewrite(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(editor) = self.rewrite_editor.take() {
            if let Some(focus) = editor.prior_focus {
                focus.focus(window, cx);
            }
            cx.notify();
        }
    }

    pub(super) fn confirm_rewrite(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(editor) = &self.rewrite_editor else {
            return;
        };
        if editor.stale {
            return;
        }
        let kind = editor.kind;
        let target = editor.target.clone();
        if self.selected.as_deref() != Some(&target.session)
            || !self.rewrite_target_is_current(&target)
        {
            self.rewrite_editor.as_mut().unwrap().stale = true;
            self.attach(&target.session, true);
            cx.notify();
            return;
        }
        let caption = if kind == RewriteKind::Edit {
            let Some(text) = editor.input.update(cx, |field, cx| {
                field
                    .marked_text_range(window, cx)
                    .is_none()
                    .then(|| field.value().to_string())
            }) else {
                return;
            };
            text
        } else {
            target.caption.clone()
        };
        if caption.trim().is_empty() && target.attachments.is_empty() && target.images.is_empty()
            || kind == RewriteKind::Edit && caption == target.caption
        {
            return;
        }
        self.begin_rewrite(&target, &caption, window, cx);
    }

    fn begin_rewrite(
        &mut self,
        target: &RewriteTarget,
        caption: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(wire_text) = rewrite_text(caption, &target.attachments) else {
            self.banner = Some(tr("附件路径不可用，无法重新发送这条消息").into());
            cx.notify();
            return;
        };
        let saved = PendingRewrite {
            request_id: Uuid::new_v4().to_string(),
            row_id: target.row_id,
            revision: target.revision,
            generation: target.generation,
            phase: match (self.canonical, target.images.is_empty()) {
                (true, true) => RewritePhase::Cut,
                (false, true) => RewritePhase::Legacy,
                (true, false) => RewritePhase::StageCanonical,
                (false, false) => RewritePhase::StageLegacy,
            },
            wire_text,
            deep: target.later_turns > 0,
            image_count: target.images.len(),
            images: Vec::new(),
        };
        self.workspace_mut()
            .pending_rewrites
            .insert(target.session.clone(), saved);
        if !self.save_rewrite(cx) {
            self.workspace_mut()
                .pending_rewrites
                .remove(&target.session);
            return;
        }
        self.close_rewrite(window, cx);
        self.continue_rewrite(&target.session, cx);
    }

    fn save_rewrite(&mut self, cx: &mut Context<Self>) -> bool {
        if let Err(error) = self.settings.save() {
            self.banner = Some(
                crate::i18n::format_text!(
                    "无法保存待发消息 · {error}",
                    "Could not save the pending message · {error}"
                )
                .into(),
            );
            cx.notify();
            return false;
        }
        true
    }

    pub(super) fn continue_rewrite(&mut self, key: &str, cx: &mut Context<Self>) {
        let stage = self
            .workspace()
            .and_then(|workspace| workspace.pending_rewrites.get(key))
            .filter(|saved| {
                matches!(
                    saved.phase,
                    RewritePhase::StageCanonical | RewritePhase::StageLegacy
                )
            })
            .cloned();
        if let Some(saved) = stage {
            self.stage_rewrite_pictures(key, saved, cx);
        } else {
            self.send_rewrite(key, Vec::new(), cx);
        }
    }

    fn rewrite_pictures(&self, key: &str, saved: &PendingRewrite) -> Option<Vec<ChatImage>> {
        let session = self.ready_for_rewrite(key)?;
        if self.canonical != (saved.phase == RewritePhase::StageCanonical)
            || session.revision != saved.revision
            || session.generation != saved.generation
        {
            return None;
        }
        let (index, _) = session
            .user_row_ids
            .iter()
            .find(|(_, id)| **id == saved.row_id)?;
        let Row::User(message) = session.rows.get(*index)? else {
            return None;
        };
        (message.images().len() == saved.image_count).then(|| message.images().to_vec())
    }

    fn stage_rewrite_pictures(&mut self, key: &str, saved: PendingRewrite, cx: &mut Context<Self>) {
        let (Some(gateway), Some(connection)) = (self.gateway.clone(), self.out.clone()) else {
            return;
        };
        let Some(session) = self.ready_for_rewrite(key) else {
            return;
        };
        let profile = session.profile.clone();
        let Some(pictures) = self.rewrite_pictures(key, &saved) else {
            self.keep_rewrite_for_review(key, tr("原消息已更新，无法重新读取原图").into(), cx);
            return;
        };
        let session = self.sessions.get_mut(key).unwrap();
        session.submitting = true;
        session.error = None;
        let key = key.to_owned();
        let canonical = saved.phase == RewritePhase::StageCanonical;
        let job = self.runtime.spawn({
            let key = key.clone();
            async move { prepare_pictures(gateway, &key, &profile, pictures, canonical).await }
        });
        cx.spawn(async move |handle, cx| {
            let result = job
                .await
                .context(tr("读取原图失败"))
                .and_then(|result| result);
            let _ = handle.update(cx, |this, cx| {
                if !this
                    .out
                    .as_ref()
                    .is_some_and(|out| out.same_channel(&connection))
                    || !this
                        .workspace()
                        .and_then(|workspace| workspace.pending_rewrites.get(&key))
                        .is_some_and(|current| {
                            current.request_id == saved.request_id && current.phase == saved.phase
                        })
                {
                    return;
                }
                let Some(session) = this.sessions.get_mut(&key) else {
                    return;
                };
                session.submitting = false;
                if session.loading || session.running {
                    cx.notify();
                    return;
                }
                if this.rewrite_pictures(&key, &saved).is_none() {
                    this.keep_rewrite_for_review(
                        &key,
                        tr("原消息已更新，无法重发这组图片").into(),
                        cx,
                    );
                    return;
                }
                let result = match result {
                    Ok(result) => result,
                    Err(error) => {
                        this.sessions.get_mut(&key).unwrap().error =
                            Some(crate::i18n::format_text!(
                                "无法准备原图 · {error}",
                                "Could not prepare the original image · {error}"
                            ));
                        cx.notify();
                        return;
                    }
                };
                let record = this.workspace_mut().pending_rewrites.get_mut(&key).unwrap();
                let legacy = match result {
                    PreparedPictures::Canonical(images) => {
                        record.phase = RewritePhase::Cut;
                        record.images = images;
                        Vec::new()
                    }
                    PreparedPictures::Legacy(urls) => {
                        record.phase = RewritePhase::Legacy;
                        urls
                    }
                };
                if this.save_rewrite(cx) {
                    this.send_rewrite(&key, legacy, cx);
                } else {
                    this.workspace_mut().pending_rewrites.insert(key, saved);
                    cx.notify();
                }
            });
        })
        .detach();
        cx.notify();
    }

    fn keep_rewrite_for_review(&mut self, key: &str, error: String, cx: &mut Context<Self>) {
        if let Some(saved) = self.workspace_mut().pending_rewrites.get_mut(key) {
            saved.phase = RewritePhase::Review;
        }
        if let Some(session) = self.sessions.get_mut(key) {
            session.error = Some(error);
        }
        self.save_rewrite(cx);
        cx.notify();
    }

    fn send_rewrite(
        &mut self,
        key: &str,
        legacy_images: Vec<InlineRewriteImage>,
        cx: &mut Context<Self>,
    ) {
        let Some(session) = self.ready_for_rewrite(key) else {
            return;
        };
        let Some(saved) = self
            .workspace()
            .and_then(|workspace| workspace.pending_rewrites.get(key))
        else {
            return;
        };
        let (method, mut params) = match saved.phase {
            RewritePhase::Cut if self.canonical => {
                let Some(revision) = saved.revision else {
                    return;
                };
                (
                    "session.mutate",
                    json!({
                        "session_id":session.runtime, "request_id":saved.request_id, "operation":"rewind",
                        "expected_revision":revision, "expected_generation":saved.generation,
                        "payload":{"target_message_id":saved.row_id}
                    }),
                )
            }
            RewritePhase::Send if self.canonical => (
                "prompt.submit",
                json!({
                    "session_id":session.runtime, "submission_id":saved.request_id,
                    "text":with_image_refs(&saved.wire_text, saved.images.iter()
                        .filter_map(|image| attachment_ref("@image:", &image.path)))
                }),
            ),
            RewritePhase::Legacy
                if !self.canonical && (saved.image_count == 0 || !legacy_images.is_empty()) =>
            {
                let mut params = json!({
                    "session_id":session.runtime, "text":saved.wire_text,
                    "confirm_truncate":true, "confirm_empty_truncate":true,
                    "truncate_before_row_id":saved.row_id
                });
                if saved.deep {
                    params["confirm_deep_truncate"] = json!(true);
                }
                if !legacy_images.is_empty() {
                    let text = with_image_refs(
                        &saved.wire_text,
                        legacy_images.iter().map(|image| image.reference.clone()),
                    );
                    params["text"] =
                        vision_prompt(&text, legacy_images.into_iter().map(|image| image.data_url));
                }
                ("prompt.submit", params)
            }
            _ => return,
        };
        if !session.profile.is_empty() {
            params["profile"] = json!(session.profile);
        }
        if saved.phase == RewritePhase::Send && self.clarify_batch {
            params["clarify_batch"] = json!(true);
        }
        if saved.phase == RewritePhase::Send && !saved.images.is_empty() {
            params["attachments"] = json!(saved.images);
        }
        let phase = saved.phase;
        let id = saved.request_id.clone();
        if self.call(method, params, Call::Rewrite(key.to_owned(), id)) {
            let session = self.sessions.get_mut(key).unwrap();
            session.submitting = true;
            session.error = None;
        } else {
            self.mark_rewrite_uncertain(key, phase);
        }
        cx.notify();
    }

    pub(super) fn lost_rewrite(&mut self, key: &str, id: &str) {
        let phase = self
            .workspace()
            .and_then(|workspace| workspace.pending_rewrites.get(key))
            .filter(|saved| saved.request_id == id)
            .map(|saved| saved.phase);
        if let Some(phase) = phase {
            self.mark_rewrite_uncertain(key, phase);
        }
    }

    fn mark_rewrite_uncertain(&mut self, key: &str, phase: RewritePhase) {
        if let Some(session) = self.sessions.get_mut(key) {
            session.submitting = false;
            session.error = Some(tr("未收到会话更新确认").into());
        }
        if phase == RewritePhase::Legacy {
            if let Some(saved) = self.workspace_mut().pending_rewrites.get_mut(key) {
                saved.phase = RewritePhase::Review;
            }
            let _ = self.settings.save();
        }
        self.attach(key, true);
    }

    pub(super) fn rewrite_response(
        &mut self,
        key: &str,
        id: &str,
        response: &Value,
        error: Option<&Value>,
        cx: &mut Context<Self>,
    ) {
        let Some(phase) = self
            .workspace()
            .and_then(|workspace| workspace.pending_rewrites.get(key))
            .filter(|saved| saved.request_id == id)
            .map(|saved| saved.phase)
        else {
            return;
        };
        let Some(session) = self.sessions.get_mut(key) else {
            return;
        };
        session.submitting = false;
        if let Some(error) = error {
            if phase == RewritePhase::Legacy
                && error["code"] == 4000
                && string(error, "message")
                    .contains("invalid params for prompt.submit: confirm_deep_truncate:")
                && let Some(saved) = self
                    .workspace_mut()
                    .pending_rewrites
                    .get_mut(key)
                    .filter(|saved| saved.deep)
            {
                saved.deep = false;
                if saved.image_count > 0 {
                    saved.phase = RewritePhase::StageLegacy;
                }
                if self.save_rewrite(cx) {
                    self.continue_rewrite(key, cx);
                }
                return;
            }
            if matches!(phase, RewritePhase::Cut | RewritePhase::Legacy)
                && matches!(error["code"].as_i64(), Some(4000..=4999 | -32602 | -32601))
            {
                self.workspace_mut()
                    .pending_rewrites
                    .get_mut(key)
                    .unwrap()
                    .phase = RewritePhase::Review;
                self.save_rewrite(cx);
            } else if phase != RewritePhase::Send {
                self.mark_rewrite_uncertain(key, phase);
            }
            self.sessions.get_mut(key).unwrap().error = Some(rpc_error(error));
            cx.notify();
            return;
        }
        match phase {
            RewritePhase::Cut
                if response["operation"] == "rewind" && response["revision"].is_u64() =>
            {
                self.workspace_mut()
                    .pending_rewrites
                    .get_mut(key)
                    .unwrap()
                    .phase = RewritePhase::Send;
                if self.save_rewrite(cx) {
                    self.continue_rewrite(key, cx);
                }
            }
            RewritePhase::Send
                if response["admission_id"].is_string()
                    && response["ref"]["session_id"] == session.runtime =>
            {
                self.finish_rewrite(key, cx);
            }
            RewritePhase::Legacy if response["status"] == "streaming" => {
                self.finish_rewrite(key, cx);
            }
            _ => self.mark_rewrite_uncertain(key, phase),
        }
        cx.notify();
    }

    pub(super) fn settle_rewrite_snapshot(
        &mut self,
        key: &str,
        snapshot: &Value,
        cx: &mut Context<Self>,
    ) {
        let Some(saved) = self
            .workspace()
            .and_then(|workspace| workspace.pending_rewrites.get(key))
        else {
            return;
        };
        let id = &saved.request_id;
        if saved.phase == RewritePhase::Send
            && ["pending", "messages"].into_iter().any(|field| {
                snapshot[field].as_array().into_iter().flatten().any(|row| {
                    row["submission_id"] == id.as_str() || row["admission_id"] == id.as_str()
                })
            })
        {
            self.workspace_mut().pending_rewrites.remove(key);
            self.persist(cx);
        }
    }

    fn finish_rewrite(&mut self, key: &str, cx: &mut Context<Self>) {
        self.workspace_mut().pending_rewrites.remove(key);
        self.persist(cx);
        if let Some(session) = self.sessions.get_mut(key).filter(|session| session.loading) {
            session.refresh = true;
        }
        self.attach(key, true);
    }

    pub(super) fn rewrite_recovery(&self, key: &str, cx: &mut Context<Self>) -> Option<Div> {
        let saved = self.workspace()?.pending_rewrites.get(key)?;
        let working = self
            .sessions
            .get(key)
            .is_some_and(|session| session.submitting);
        let staging = matches!(
            saved.phase,
            RewritePhase::StageCanonical | RewritePhase::StageLegacy
        );
        let retry = staging || matches!(saved.phase, RewritePhase::Cut | RewritePhase::Send);
        let ready = self.ready_for_rewrite(key).is_some();
        let text = saved.wire_text.clone();
        let session = key.to_owned();
        let dismiss = session.clone();
        Some(
            div()
                .flex()
                .items_center()
                .gap_2()
                .px_2()
                .py_1()
                .rounded(px(5.))
                .bg(rgb(0xf3f6fc))
                .text_size(px(12.))
                .child(div().flex_1().min_w_0().child(if working && staging {
                    tr("正在读取原图…")
                } else if working {
                    tr("正在更新会话…")
                } else if saved.phase == RewritePhase::Send {
                    tr("待发送的替换消息")
                } else {
                    tr("会话更新待确认")
                }))
                .when(!working, |bar| {
                    bar.child(
                        Button::new("copy-rewrite-text")
                            .ghost()
                            .small()
                            .label(tr("复制内容"))
                            .on_click(move |_, _, cx| {
                                cx.write_to_clipboard(ClipboardItem::new_string(text.clone()))
                            }),
                    )
                    .when(retry, |bar| {
                        bar.child(
                            Button::new("continue-rewrite")
                                .small()
                                .label(tr("继续"))
                                .disabled(!ready)
                                .on_click(cx.listener(move |this, _, _, cx| {
                                    this.continue_rewrite(&session, cx)
                                })),
                        )
                    })
                    .child(
                        Button::new("dismiss-rewrite")
                            .ghost()
                            .small()
                            .label(tr("放弃待发内容"))
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.workspace_mut().pending_rewrites.remove(&dismiss);
                                this.persist(cx);
                                cx.notify();
                            })),
                    )
                }),
        )
    }

    pub(super) fn rewrite_overlay(
        &self,
        window: &Window,
        cx: &mut Context<Self>,
    ) -> Option<Stateful<Div>> {
        let editor = self.rewrite_editor.as_ref()?;
        let missing_edit = editor.kind == RewriteKind::Edit;
        if missing_edit
            && self
                .sessions
                .get(&editor.target.session)
                .is_some_and(|session| {
                    session.user_row_ids.iter().any(|(&index, &id)| {
                        id == editor.target.row_id
                            && matches!(session.rows.get(index), Some(Row::User(_)))
                    })
                })
        {
            return None;
        }
        let count = editor.target.later_turns;
        let attachment_count = editor.target.attachments.len() + editor.target.images.len();
        Some(
            div()
                .id("rewrite-overlay")
                .absolute()
                .inset_0()
                .occlude()
                .flex()
                .items_center()
                .justify_center()
                .bg(rgba(0x24324b36))
                .child(
                    div()
                        .id("rewrite-dialog")
                        .track_focus(&editor.focus)
                        .key_context("HermesRewriteInput")
                        .w((window.viewport_size().width - px(48.)).min(px(550.)))
                        .p_4()
                        .flex()
                        .flex_col()
                        .gap_3()
                        .rounded(px(9.))
                        .bg(rgb(0xffffff))
                        .shadow_lg()
                        .text_color(rgb(INK))
                        .child(
                            div()
                                .text_size(px(15.))
                                .font_weight(gpui::FontWeight::SEMIBOLD)
                                .child(if missing_edit {
                                    tr("原消息暂不可见")
                                } else {
                                    tr("重新生成答复")
                                }),
                        )
                        .children(missing_edit.then(|| Textarea::new(&editor.input).small()))
                        .children((!missing_edit).then(|| {
                            div()
                                .max_h(px(75.))
                                .overflow_hidden()
                                .px_2()
                                .py_1()
                                .bg(rgb(0xf4f6fa))
                                .rounded(px(4.))
                                .child(if editor.target.caption.is_empty() {
                                    tr("图片消息").to_owned()
                                } else {
                                    editor.target.caption.clone()
                                })
                        }))
                        .children((!missing_edit && count > 0).then(|| {
                            div()
                                .text_size(px(12.))
                                .text_color(rgb(0x9a562b))
                                .child(crate::i18n::format_text!(
                                    "继续后，这条消息及之后的 {count} 轮对话会从当前会话移除。", "Continuing will remove this message and the next {count} turn(s) from this conversation."
                                ))
                        }))
                        .children((editor.stale || missing_edit).then(|| {
                            div()
                                .text_size(px(12.))
                                .text_color(rgb(0xa44c35))
                                .child(tr("会话已更新。可以复制编辑内容，再重新打开这条消息。"))
                        }))
                        .child(
                            div()
                                .flex()
                                .justify_end()
                                .gap_2()
                                .when(attachment_count > 0, |row| {
                                    row.child(
                                        div()
                                            .flex_1()
                                            .text_size(px(11.))
                                            .text_color(rgb(MUTED))
                                            .child(crate::i18n::format_text!("保留 {attachment_count} 个附件", "Keep {attachment_count} attachment(s)")),
                                    )
                                })
                                .child(
                                    Button::new("close-rewrite")
                                        .ghost()
                                        .small()
                                        .label(tr("取消"))
                                        .on_click(cx.listener(|this, _, window, cx| {
                                            this.close_rewrite(window, cx)
                                        })),
                                )
                                .children((!missing_edit).then(|| {
                                    Button::new("confirm-rewrite")
                                        .primary()
                                        .small()
                                        .disabled(editor.stale)
                                        .label(tr("重新生成"))
                                        .on_click(cx.listener(|this, _, window, cx| {
                                            this.confirm_rewrite(window, cx)
                                        }))
                                })),
                        ),
                ),
        )
    }

    pub(super) fn inline_rewrite(
        &self,
        key: &str,
        index: usize,
        font_size: Pixels,
        desktop: WeakEntity<Self>,
        app: &App,
    ) -> Option<AnyElement> {
        let editor = self
            .rewrite_editor
            .as_ref()
            .filter(|editor| editor.kind == RewriteKind::Edit && editor.target.session == key)?;
        if self.sessions.get(key)?.user_row_ids.get(&index) != Some(&editor.target.row_id) {
            return None;
        }
        let value = editor.input.read(app).value();
        let attachment_count = editor.target.attachments.len() + editor.target.images.len();
        let confirm = !editor.stale
            && value.as_ref() != editor.target.caption
            && (!value.trim().is_empty() || attachment_count > 0);
        let later = editor.target.later_turns;
        let close = desktop.clone();
        Some(
            div()
                .id("inline-rewrite")
                .key_context("HermesRewriteInput")
                .flex()
                .flex_col()
                .gap_1()
                .child(
                    div()
                        .flex()
                        .items_end()
                        .gap(px(3.))
                        .child(
                            div().min_w_0().flex_1().child(
                                Textarea::new(&editor.input)
                                    .small()
                                    .appearance(false)
                                    .bordered(false)
                                    .p_0()
                                    .text_size(font_size)
                                    .line_height((font_size * 1.3).max(px(19.))),
                            ),
                        )
                        .child(
                            Button::new("cancel-inline-rewrite")
                                .ghost()
                                .compact()
                                .size(px(25.))
                                .p_0()
                                .tooltip(tr("取消编辑 · Esc"))
                                .child(svg_symbol(crate::icons::TAB_CLOSE, 13., MUTED))
                                .on_click(move |_, window, app| {
                                    let _ = close
                                        .update(app, |this, cx| this.close_rewrite(window, cx));
                                }),
                        )
                        .child(
                            Button::new("send-inline-rewrite")
                                .ghost()
                                .compact()
                                .size(px(25.))
                                .p_0()
                                .disabled(!confirm)
                                .tooltip(if cfg!(target_os = "macos") {
                                    tr("保存并重发 · ⌘+Enter")
                                } else {
                                    tr("保存并重发 · Ctrl+Enter")
                                })
                                .child(svg_symbol(
                                    crate::icons::ARROW_UP,
                                    15.,
                                    if confirm { crate::style::ACCENT } else { MUTED },
                                ))
                                .on_click(move |_, window, app| {
                                    let _ = desktop
                                        .update(app, |this, cx| this.confirm_rewrite(window, cx));
                                }),
                        ),
                )
                .children((later > 0).then(|| {
                    div()
                        .text_size(px(11.))
                        .line_height(px(16.))
                        .text_color(rgb(0x9a562b))
                        .child(crate::i18n::format_text!(
                            "重发后，此消息之后的 {later} 轮对话将从当前会话移除。",
                            "Resending will remove the {later} turn(s) that follow this message."
                        ))
                }))
                .children(editor.stale.then(|| {
                    div()
                        .text_size(px(11.))
                        .line_height(px(16.))
                        .text_color(rgb(0xa44c35))
                        .child(tr("会话已更新。可以复制编辑内容，再重新打开这条消息。"))
                }))
                .into_any_element(),
        )
    }
}

async fn prepare_pictures(
    gateway: Gateway,
    session: &str,
    profile: &str,
    pictures: Vec<ChatImage>,
    canonical: bool,
) -> Result<PreparedPictures> {
    let mut digests = HashSet::new();
    let mut total = 0;
    let mut staged = Vec::new();
    let mut inline = Vec::new();
    for picture in pictures {
        let name = picture.name.clone();
        let image = prepare_replay_image(&gateway, session, profile, picture)
            .await
            .with_context(|| {
                crate::i18n::format_text!("读取 {name} 失败", "Could not read {name}")
            })?;
        if !digests.insert(image.digest) {
            continue;
        }
        if digests.len() > 10 {
            bail!(tr("一次最多重新发送 10 张图片"));
        }
        if !canonical {
            total += image.data_url.len();
            if total > 32 * 1024 * 1024 {
                bail!(tr("这组图片超过网关可接收的数据大小"));
            }
        }
        let filename = format!("image-{}.{}", digests.len(), image.extension);
        let uploaded = upload_chat_image(&gateway, profile, &filename, &image.data_url)
            .await
            .with_context(|| {
                crate::i18n::format_text!("暂存 {name} 失败", "Could not stage {name}")
            })?;
        let reference =
            attachment_ref("@image:", &uploaded.path).context(tr("网关未返回可用的原图路径"))?;
        if canonical {
            staged.push(uploaded);
        } else {
            inline.push(InlineRewriteImage {
                reference,
                data_url: image.data_url,
            });
        }
    }
    Ok(if canonical {
        PreparedPictures::Canonical(staged)
    } else {
        PreparedPictures::Legacy(inline)
    })
}

fn with_image_refs(caption: &str, refs: impl Iterator<Item = String>) -> String {
    let mut result = caption.to_owned();
    for reference in refs {
        if !result.is_empty() {
            result.push('\n');
        }
        result.push_str(&reference);
    }
    result
}

fn rewrite_text(caption: &str, attachments: &[String]) -> Option<String> {
    if attachments.is_empty() {
        return Some(caption.to_owned());
    }
    let mut lines = Vec::with_capacity(attachments.len() + 2);
    for path in attachments {
        lines.push(attachment_ref("@file:", path)?);
    }
    if !caption.trim().is_empty() {
        lines.extend([String::new(), caption.to_owned()]);
    }
    Some(lines.join("\n"))
}
