use gpui::{
    Anchor, Animation, AnimationExt, Context, Div, EntityInputHandler, FontWeight, Pixels, Point,
    Task, Window, anchored, deferred, div, point, prelude::*, px,
};
use gpui_component::{
    button::{Button, ButtonVariants},
    popover::Popover,
    tooltip::Tooltip,
};
use serde_json::{Value, json};
use std::time::{Duration, Instant};
use tokio::{
    sync::{mpsc, oneshot, watch},
    task::AbortHandle,
};
use uuid::Uuid;

use super::{
    Call, Desktop, rpc_error,
    view::{DANGER, SELECTED, SURFACE, icon_button},
};
use crate::{
    i18n::text as tr,
    icons,
    session::Row,
    style::{ACCENT, INK, MUTED},
    theme::{ink, rgb},
    voice::{
        Event, InputControl, Mode, Phase, VoiceCommand, VoiceEngine, run_chained, spoken_stop,
    },
    voice_live,
};

#[derive(Default)]
pub(super) struct Voice {
    active: Option<Active>,
    error: Option<String>,
    menu: bool,
    fan_anchor: Option<Point<Pixels>>,
    fan_open: bool,
    fan_close: Option<Task<()>>,
    stop_hint: bool,
    reconnecting: Option<Task<()>>,
    playback: Option<(Uuid, AbortHandle)>,
    engines: Option<(String, Option<Value>)>,
    saving_engine: Option<String>,
}

struct Active {
    id: Uuid,
    tab: Option<String>,
    mode: Mode,
    phase: Phase,
    commands: mpsc::Sender<VoiceCommand>,
    input: watch::Sender<InputControl>,
    level: f32,
    started: Instant,
    _cancel: oneshot::Sender<()>,
    turn: Option<Turn>,
    followup: Option<(String, Option<Delegation>)>,
    interrupting: bool,
    hint_shown: bool,
}

struct Turn {
    key: String,
    submission: String,
    delegation: Option<Delegation>,
}

pub(super) struct Delegation {
    id: String,
    context: String,
}

impl Voice {
    pub(super) fn using_microphone(&self) -> bool {
        self.active.is_some()
    }

    pub(super) fn is_conversation(&self) -> bool {
        matches!(
            self.active.as_ref().map(|active| active.mode),
            Some(Mode::Conversation(_))
        )
    }

    pub(super) fn stop_on_tab_change(&mut self, tab: &str) {
        if self
            .active
            .as_ref()
            .is_some_and(|active| active.tab.as_deref() != Some(tab))
        {
            self.active = None;
        }
        self.error = None;
    }

    pub(super) fn expect_turn(
        &mut self,
        key: &str,
        submission: &str,
        delegation: Option<Delegation>,
    ) {
        if let Some(active) = self.active.as_mut()
            && matches!(active.mode, Mode::Conversation(_))
        {
            active.turn = Some(Turn {
                key: key.to_owned(),
                submission: submission.to_owned(),
                delegation,
            });
            active.phase = Phase::Waiting;
        }
    }

    fn turn_for(&self, key: &str, submission: &str) -> Option<&Turn> {
        self.active
            .as_ref()?
            .turn
            .as_ref()
            .filter(|turn| turn.key == key && turn.submission == submission)
    }

    pub(super) fn owns_turn(&self, key: &str, submission: &str) -> bool {
        self.turn_for(key, submission).is_some()
    }

    pub(super) fn context_for(&self, key: &str, submission: &str) -> Option<&str> {
        Some(&self.turn_for(key, submission)?.delegation.as_ref()?.context)
    }

    pub(super) fn fail_submission(&mut self, key: &str, submission: &str) {
        if self.owns_turn(key, submission) {
            self.active = None;
        }
    }

    pub(super) fn promote_turn(&mut self, draft: &str, request: &str, key: &str, submission: &str) {
        if let Some(turn) = self.active.as_mut().and_then(|active| active.turn.as_mut())
            && turn.key == draft
            && turn.submission == request
        {
            turn.key = key.to_owned();
            turn.submission = submission.to_owned();
        }
    }
}

impl Desktop {
    pub(super) fn end_voice(&mut self) {
        self.voice.active = None;
        self.voice.error = None;
        self.voice.menu = false;
        self.voice.fan_open = false;
        self.voice.fan_close = None;
        self.voice.stop_hint = false;
        self.voice.reconnecting = None;
        self.stop_voice_playback();
    }

    pub(super) fn reset_voice_connection(&mut self) {
        self.end_voice();
        self.voice.engines = None;
        self.voice.saving_engine = None;
    }

    pub(super) fn voice_socket_offline(&mut self, retry: bool, cx: &mut Context<Self>) {
        if !retry || !self.voice.is_conversation() {
            self.reset_voice_connection();
        } else if self.voice.reconnecting.is_none() {
            self.voice.reconnecting = Some(cx.spawn(async move |desktop, cx| {
                cx.background_executor()
                    .timer(Duration::from_secs(12))
                    .await;
                let _ = desktop.update(cx, |this, cx| {
                    this.voice.reconnecting = None;
                    if this.out.is_none() && this.voice.is_conversation() {
                        this.reset_voice_connection();
                        this.voice.error = Some(tr("语音连接恢复超时").to_owned());
                    }
                    cx.notify();
                });
            }));
        }
    }

    fn voice_can_submit(&self) -> bool {
        let key = self.key();
        self.out.is_some()
            && !self.creating()
            && !self.clipboard_loading()
            && self.rewrite_editor.is_none()
            && !self.model_controls.busy.contains(&key)
            && !self.has_followups(&key)
            && self.workspace().is_none_or(|workspace| {
                !workspace.pending_submissions.contains_key(&key)
                    && !workspace.pending_rewrites.contains_key(&key)
            })
            && self.selected.as_ref().is_none_or(|key| {
                self.sessions.get(key).is_some_and(|session| {
                    session.attached
                        && !session.loading
                        && !session.running
                        && !session.submitting
                        && !session.uncertain
                })
            })
    }

    pub(super) fn toggle_voice(&mut self, mode: Mode, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(active) = self.voice.active.as_mut() {
            if active.mode == mode {
                if mode == Mode::Dictation && active.phase == Phase::Recording {
                    let _ = active.commands.try_send(VoiceCommand::Finish);
                    active.phase = Phase::Transcribing;
                } else if mode != Mode::Dictation {
                    self.end_voice();
                }
                cx.notify();
                return;
            }
            self.end_voice();
        }
        if self.out.is_none() || (mode != Mode::Dictation && !self.voice_can_submit()) {
            self.voice.error = Some(tr("请等待当前会话就绪").to_owned());
            cx.notify();
            return;
        }
        let Some(gateway) = self.gateway.clone() else {
            return;
        };
        let (mode, fallback) = if mode == Mode::Conversation(VoiceEngine::GptLive)
            && self
                .voice_engine_status()
                .is_some_and(|status| status["available"] != true)
        {
            (Mode::Conversation(VoiceEngine::Chained), true)
        } else {
            (mode, false)
        };
        if fallback {
            self.banner = Some(tr("GPT-Live 不可用，已使用语音转文字").into());
        }
        let history = if mode == Mode::Conversation(VoiceEngine::GptLive) {
            self.live_voice_history()
        } else {
            Vec::new()
        };
        let id = Uuid::new_v4();
        let profile = self.model_profile();
        let (cancel, mut cancelled) = oneshot::channel();
        let (commands, mut receive) = mpsc::channel(4);
        let (input, input_state) = watch::channel(InputControl::default());
        let (events, mut updates) = mpsc::channel(32);
        self.stop_voice_playback();
        self.pause_voice_wake();
        self.voice.fan_open = false;
        self.voice.active = Some(Active {
            id,
            tab: self
                .workspace()
                .and_then(|workspace| workspace.active_tab.clone()),
            mode,
            phase: Phase::Connecting,
            commands,
            input,
            level: 0.,
            started: Instant::now(),
            _cancel: cancel,
            turn: None,
            followup: None,
            interrupting: false,
            hint_shown: false,
        });
        self.voice.error = None;
        let speak_replies = self.settings.voice_auto_speak;
        self.runtime.spawn(async move {
            let result = if mode == Mode::Conversation(VoiceEngine::GptLive) {
                voice_live::run(
                    &gateway,
                    &profile,
                    history,
                    &mut receive,
                    &events,
                    cancelled,
                    input_state,
                )
                .await
            } else {
                tokio::select! {
                    _ = &mut cancelled => Ok(()),
                    result = run_chained(&gateway, &profile, mode, &mut receive, &events, input_state, speak_replies) => result,
                }
            };
            if let Err(error) = result {
                let _ = events.send(Event::Error(format!("{error:#}"))).await;
            }
        });
        cx.spawn_in(window, async move |view, cx| {
            while let Some(event) = updates.recv().await {
                let current = view.update_in(cx, |this, window, cx| {
                    if this
                        .voice
                        .active
                        .as_ref()
                        .is_none_or(|active| active.id != id)
                    {
                        return false;
                    }
                    this.apply_voice(event, window, cx);
                    cx.notify();
                    true
                });
                if !matches!(current, Ok(true)) {
                    return;
                }
            }
            let _ = view.update_in(cx, |this, _, cx| {
                if this
                    .voice
                    .active
                    .as_ref()
                    .is_some_and(|active| active.id == id)
                {
                    this.voice.active = None;
                    this.resume_voice_wake();
                    cx.notify();
                }
            });
        })
        .detach();
        cx.notify();
    }

    fn live_voice_history(&self) -> Vec<Value> {
        let Some(session) = self
            .selected
            .as_ref()
            .and_then(|key| self.sessions.get(key))
        else {
            return Vec::new();
        };
        let mut history: Vec<_> = session.live.iter().rev().chain(session.rows.iter().rev())
            .filter_map(|row| {
                let (role, kind, text) = match row {
                    Row::User(message) => ("user", "input_text", message.display()),
                    Row::Answer(answer) => ("assistant", "output_text", answer.body.display()),
                    _ => return None,
                };
                let text: String = text.trim().chars().take(1_000).collect();
                (!text.is_empty()).then(|| json!({"type":"message", "role":role, "content":[{"type":kind,"text":text}]}))
            }).take(12).collect();
        history.reverse();
        history
    }

    fn apply_voice(&mut self, event: Event, window: &mut Window, cx: &mut Context<Self>) {
        let Some(active) = self.voice.active.as_mut() else {
            return;
        };
        match event {
            Event::Phase(phase) if active.turn.is_none() => {
                if phase == Phase::Recording {
                    active.started = Instant::now();
                }
                active.phase = phase;
                if phase == Phase::Listening
                    && !active.hint_shown
                    && matches!(active.mode, Mode::Conversation(_))
                {
                    active.hint_shown = true;
                    let id = active.id;
                    self.voice.stop_hint = true;
                    cx.spawn(async move |desktop, cx| {
                        cx.background_executor().timer(Duration::from_secs(7)).await;
                        let _ = desktop.update(cx, |this, cx| {
                            if this
                                .voice
                                .active
                                .as_ref()
                                .is_some_and(|active| active.id == id)
                            {
                                this.voice.stop_hint = false;
                                cx.notify();
                            }
                        });
                    })
                    .detach();
                }
            }
            Event::Phase(_) => {}
            Event::Level(level) => active.level = level,
            Event::Notice(message) => self.banner = Some(message.into()),
            Event::Error(error) => {
                self.voice.active = None;
                self.voice.error = Some(error);
                self.resume_voice_wake();
            }
            Event::Transcript(text) if active.mode == Mode::Dictation => {
                self.voice.active = None;
                self.resume_voice_wake();
                if text.is_empty() {
                    self.voice.error = Some(tr("未听到清晰的语音").to_owned());
                } else {
                    self.composer.update(cx, |input, cx| {
                        input.replace_text_in_range(None, &text, window, cx);
                        input.focus(window, cx);
                    });
                }
            }
            Event::Transcript(text) => self.send_voice(text, None, window, cx),
            Event::Delegate {
                id,
                prompt,
                context,
            } => {
                self.send_voice(prompt, Some(Delegation { id, context }), window, cx);
            }
        }
    }

    fn send_voice(
        &mut self,
        text: String,
        delegation: Option<Delegation>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if spoken_stop(&text) {
            self.end_voice();
            self.resume_voice_wake();
            cx.notify();
            return;
        }
        if let Some(active) = self.voice.active.as_mut()
            && (active.turn.is_some() || self.voice.reconnecting.is_some())
        {
            active.followup = Some((text, delegation));
            self.interrupt_voice_turn();
            return;
        }
        if !self.voice_can_submit() {
            let message = tr("请等待当前会话就绪").to_owned();
            if let Some(delegation) = delegation
                && let Some(active) = &self.voice.active
            {
                let _ = active.commands.try_send(VoiceCommand::Reply {
                    delegation: Some(delegation.id),
                    text: message,
                });
            } else {
                self.voice.active = None;
                self.voice.error = Some(message);
            }
            return;
        }
        self.send_text(text, Vec::new(), None, delegation, window, cx);
    }

    fn interrupt_voice_turn(&mut self) {
        let Some(active) = self.voice.active.as_mut() else {
            return;
        };
        let Some(turn) = active.turn.as_ref() else {
            return;
        };
        if active.followup.is_some()
            && !active.interrupting
            && self.selected.as_ref() == Some(&turn.key)
            && self
                .sessions
                .get(&turn.key)
                .is_some_and(|session| session.running && session.attached && !session.loading)
        {
            active.interrupting = true;
            self.stop();
        }
    }

    pub(super) fn finish_voice_turn(&mut self, key: &str, payload: &Value) {
        let Some(active) = self.voice.active.as_mut() else {
            return;
        };
        let Some(turn) = active.turn.as_ref() else {
            return;
        };
        let submission = payload["persisted_turn"]["submission_id"]
            .as_str()
            .or_else(|| payload["submission_id"].as_str())
            .filter(|id| !id.is_empty());
        if turn.key != key || submission.is_some_and(|id| id != turn.submission) {
            return;
        }
        let turn = active.turn.take().unwrap();
        active.interrupting = false;
        if active.followup.is_some() {
            return;
        }
        let text = if let Some(error) = payload["error"].as_str().filter(|error| !error.is_empty())
        {
            self.voice.error = Some(error.to_owned());
            String::new()
        } else {
            crate::media::Message::new(crate::session::text(&payload["text"]).into(), false)
                .display()
                .to_string()
        };
        let delegation = turn.delegation.map(|delegation| delegation.id);
        if delegation.is_some() {
            active.phase = Phase::Listening;
        }
        let _ = active
            .commands
            .try_send(VoiceCommand::Reply { delegation, text });
    }

    pub(super) fn check_voice(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.refresh_voice_engines(cx);
        if self.out.is_some() {
            self.voice.reconnecting = None;
        } else if self.voice.reconnecting.is_some() {
            return;
        }
        let Some(active) = self.voice.active.as_ref() else {
            self.resume_voice_wake();
            return;
        };
        if self
            .workspace()
            .and_then(|workspace| workspace.active_tab.as_ref())
            != active.tab.as_ref()
        {
            self.end_voice();
            cx.notify();
            return;
        }
        let session = active
            .turn
            .as_ref()
            .and_then(|turn| self.sessions.get(&turn.key));
        if let Some(error) =
            session.and_then(|session| session.error.as_ref().or(session.turn_error.as_ref()))
        {
            self.voice.error = Some(error.to_string());
            self.voice.active = None;
            cx.notify();
            return;
        }
        self.interrupt_voice_turn();
        if self.voice_can_submit()
            && let Some(active) = self.voice.active.as_mut()
            && active.turn.is_none()
            && let Some((text, delegation)) = active.followup.take()
        {
            self.send_voice(text, delegation, window, cx);
        }
    }

    fn voice_engine_status(&self) -> Option<&Value> {
        let (profile, status) = self.voice.engines.as_ref()?;
        (profile == &self.model_profile())
            .then_some(status.as_ref())
            .flatten()
    }

    pub(super) fn voice_engine(&self) -> VoiceEngine {
        match self
            .voice_engine_status()
            .and_then(|status| status["mode"].as_str())
        {
            Some("chained") => VoiceEngine::Chained,
            Some("gpt-live") => VoiceEngine::GptLive,
            _ => self.settings.voice_engine,
        }
    }

    fn refresh_voice_engines(&mut self, cx: &mut Context<Self>) {
        let profile = self.model_profile();
        if self.out.is_none()
            || self
                .voice
                .engines
                .as_ref()
                .is_some_and(|(loaded, _)| loaded == &profile)
        {
            return;
        }
        let Some(gateway) = self.gateway.clone() else {
            return;
        };
        let route = gateway.clone();
        self.voice.engines = Some((profile.clone(), None));
        let load_profile = profile.clone();
        let request = self.runtime.spawn(async move {
            crate::voice::audio_request(
                &gateway,
                &load_profile,
                "api/audio/voice-live/status",
                None,
            )
            .await
        });
        cx.spawn(async move |desktop, cx| {
            let status = request.await.ok().and_then(Result::ok).unwrap_or_default();
            let _ = desktop.update(cx, |this, cx| {
                if this
                    .gateway
                    .as_ref()
                    .is_some_and(|gateway| gateway.uses_same_connection(&route))
                    && this
                        .voice
                        .engines
                        .as_ref()
                        .is_some_and(|(pending, status)| pending == &profile && status.is_none())
                {
                    this.voice.engines = Some((profile, Some(status)));
                    cx.notify();
                }
            });
        })
        .detach();
    }

    fn set_voice_engine(&mut self, engine: VoiceEngine, cx: &mut Context<Self>) {
        self.voice.menu = false;
        if self.voice_engine() == engine {
            cx.notify();
            return;
        }
        let profile = self.model_profile();
        let value = match engine {
            VoiceEngine::Chained => "chained",
            VoiceEngine::GptLive => "gpt-live",
        };
        if self.call(
            "config.set",
            json!({"profile":profile,"key":"voice.voice_chat_mode","value":value}),
            Call::SetVoiceEngine(profile.clone(), engine),
        ) {
            self.voice.saving_engine = Some(profile);
        }
        cx.notify();
    }

    pub(super) fn voice_engine_lost(&mut self, profile: &str) {
        if self.voice.saving_engine.as_deref() == Some(profile) {
            self.voice.saving_engine = None;
            self.banner = Some(tr("未能切换语音引擎").into());
        }
    }

    pub(super) fn voice_engine_saved(
        &mut self,
        profile: &str,
        engine: VoiceEngine,
        error: Option<&Value>,
        cx: &mut Context<Self>,
    ) {
        if self.voice.saving_engine.as_deref() != Some(profile) {
            return;
        }
        self.voice.saving_engine = None;
        if let Some(error) = error {
            self.banner = Some(rpc_error(error).into());
        } else {
            if let Some((scope, Some(status))) = self.voice.engines.as_mut()
                && scope == profile
            {
                status["mode"] = json!(engine);
            }
            self.settings.voice_engine = engine;
            self.persist(cx);
        }
        cx.notify();
    }

    fn stop_voice_playback(&mut self) {
        if let Some((_, playback)) = self.voice.playback.take() {
            playback.abort();
        }
    }

    pub(super) fn read_voice_reply(&mut self, key: &str, payload: &Value, cx: &mut Context<Self>) {
        if !self.settings.voice_auto_speak
            || self.voice.using_microphone()
            || self.selected.as_deref() != Some(key)
            || payload["error"]
                .as_str()
                .is_some_and(|error| !error.is_empty())
        {
            return;
        }
        let Some(gateway) = self.gateway.clone() else {
            return;
        };
        let text = crate::media::Message::new(crate::session::text(&payload["text"]).into(), false)
            .display()
            .trim()
            .to_owned();
        if text.is_empty() {
            return;
        }
        self.stop_voice_playback();
        let id = Uuid::new_v4();
        let profile = self.model_profile();
        let job = self.runtime.spawn(async move {
            let bytes = crate::voice::synthesize(&gateway, &profile, text).await?;
            crate::voice_audio::play(bytes).await
        });
        self.voice.playback = Some((id, job.abort_handle()));
        cx.spawn(async move |desktop, cx| {
            let result = job.await;
            let _ = desktop.update(cx, |this, cx| {
                if this
                    .voice
                    .playback
                    .as_ref()
                    .is_some_and(|(current, _)| *current == id)
                {
                    this.voice.playback = None;
                    if let Ok(Err(error)) = result {
                        this.voice.error = Some(error.to_string());
                    }
                    cx.notify();
                }
            });
        })
        .detach();
    }

    pub(super) fn voice_status(&self, cx: &mut Context<Self>) -> Option<Div> {
        if let Some(error) = self.voice.error.as_ref() {
            return Some(
                div()
                    .flex()
                    .items_center()
                    .gap_2()
                    .px_2()
                    .text_size(px(12.))
                    .text_color(ink(DANGER))
                    .child(div().flex_1().child(error.clone()))
                    .child(
                        icon_button("close-voice-status", icons::TAB_CLOSE, tr("关闭")).on_click(
                            cx.listener(|this, _, _, cx| {
                                this.voice.error = None;
                                cx.notify();
                            }),
                        ),
                    ),
            );
        }
        let (icon, caption, control) = if self.voice.playback.is_some() {
            (
                icons::VOICE_SPEAKER,
                tr("正在朗读…"),
                icon_button("stop-read-aloud", icons::STOP, tr("停止朗读")).on_click(cx.listener(
                    |this, _, _, cx| {
                        this.stop_voice_playback();
                        cx.notify();
                    },
                )),
            )
        } else {
            let active = self
                .voice
                .active
                .as_ref()
                .filter(|active| active.mode == Mode::Dictation)?;
            let label = match active.phase {
                Phase::Recording => tr("正在听写…"),
                Phase::Transcribing => tr("正在转写…"),
                _ => tr("正在启动语音…"),
            };
            (
                icons::MICROPHONE,
                label,
                icon_button("cancel-dictation", icons::TAB_CLOSE, tr("取消听写")).on_click(
                    cx.listener(|this, _, _, cx| {
                        this.end_voice();
                        this.resume_voice_wake();
                        cx.notify();
                    }),
                ),
            )
        };
        Some(
            div()
                .h(px(28.))
                .px_2()
                .flex()
                .items_center()
                .gap_2()
                .rounded(px(6.))
                .bg(rgb(SELECTED))
                .text_size(px(12.))
                .text_color(ink(MUTED))
                .child(super::view::svg_symbol(icon, 13., ACCENT))
                .child(caption)
                .children(self.voice.active.as_ref().map(|active| {
                    let elapsed = active.started.elapsed().as_secs();
                    format!("{:01}:{:02}", elapsed / 60, elapsed % 60)
                }))
                .child(div().flex_1())
                .children(
                    self.voice
                        .active
                        .as_ref()
                        .map(|active| level_bars(active.level, ACCENT)),
                )
                .child(control),
        )
    }

    fn voice_fan_hover(&mut self, inside: bool, window: &mut Window, cx: &mut Context<Self>) {
        if inside {
            self.voice.fan_close = None;
            if !self.voice.fan_open {
                self.voice.fan_open = true;
                cx.notify();
            }
        } else {
            self.voice_fan_pointer(window.mouse_position(), window, cx);
        }
    }

    fn over_voice_fan(&self, position: Point<Pixels>) -> bool {
        self.voice.fan_anchor.is_some_and(|at| {
            (position.x - at.x).abs() <= px(19.)
                && position.y >= at.y - px(66.)
                && position.y <= at.y + px(27.)
        })
    }

    pub(super) fn voice_fan_pointer(
        &mut self,
        position: Point<Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.voice.fan_open {
            return;
        }
        if self.over_voice_fan(position) {
            self.voice.fan_close = None;
        } else if self.voice.fan_close.is_none() {
            self.voice.fan_close = Some(cx.spawn_in(window, async move |desktop, cx| {
                cx.background_executor()
                    .timer(Duration::from_millis(190))
                    .await;
                let _ = desktop.update_in(cx, |this, window, cx| {
                    this.voice.fan_close = None;
                    if !this.over_voice_fan(window.mouse_position()) {
                        this.voice.fan_open = false;
                        cx.notify();
                    }
                });
            }));
        }
    }

    pub(super) fn voice_fan(&self, enabled: bool, cx: &mut Context<Self>) -> Div {
        let phase = self
            .voice
            .active
            .as_ref()
            .filter(|active| active.mode == Mode::Dictation)
            .map(|active| active.phase);
        let (icon, label) = match phase {
            Some(Phase::Recording) => (icons::STOP, tr("完成听写")),
            Some(Phase::Transcribing) => (icons::CLOCK, tr("正在转写…")),
            _ => (icons::MICROPHONE, tr("语音听写")),
        };
        let open = self.voice.fan_open && enabled;
        let mic = voice_disc(
            "voice-dictation",
            icon,
            label,
            open || phase.is_some(),
            false,
            enabled,
        )
        .on_hover(cx.listener(|this, inside, window, cx| this.voice_fan_hover(*inside, window, cx)))
        .on_click(cx.listener(move |this, _, window, cx| {
            if enabled {
                this.toggle_voice(Mode::Dictation, window, cx);
            }
        }));
        let desktop = cx.weak_entity();
        let tray = open.then_some(self.voice.fan_anchor).flatten().map(|at| {
            let speak = self.settings.voice_auto_speak;
            let wake = self.voice_wake.listening();
            let wake_enabled = self.voice_wake.available() && !self.voice.using_microphone();
            let phrase = &self.voice_wake.phrase;
            let wake_label = if phrase.is_empty() {
                tr("唤醒词").to_owned()
            } else {
                format!("{} · {phrase}", tr("唤醒词"))
            };
            deferred(
                anchored().anchor(Anchor::BottomCenter).position(at).child(
                    div()
                        .id("voice-hover-fan")
                        .pb(px(3.))
                        .flex()
                        .flex_col()
                        .items_center()
                        .gap(px(4.))
                        .on_hover(cx.listener(|this, inside, window, cx| {
                            this.voice_fan_hover(*inside, window, cx)
                        }))
                        .child(
                            fan_disc(
                                "toggle-wake-word",
                                if wake {
                                    icons::VOICE_EAR
                                } else {
                                    icons::VOICE_EAR_OFF
                                },
                                wake_label,
                                wake,
                                wake_enabled,
                            )
                            .on_click(cx.listener(|this, _, _, cx| this.toggle_voice_wake(cx))),
                        )
                        .child(
                            fan_disc(
                                "toggle-read-aloud",
                                if speak {
                                    icons::VOICE_SPEAKER
                                } else {
                                    icons::VOICE_SPEAKER_OFF
                                },
                                if speak {
                                    tr("停止自动朗读")
                                } else {
                                    tr("朗读回复")
                                },
                                speak,
                                true,
                            )
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.settings.voice_auto_speak = !this.settings.voice_auto_speak;
                                if !this.settings.voice_auto_speak {
                                    this.stop_voice_playback();
                                }
                                this.persist(cx);
                                cx.notify();
                            })),
                        ),
                ),
            )
        });
        div()
            .flex_none()
            .relative()
            .child(mic)
            .children(tray)
            .when(open, |view| {
                view.on_children_prepainted(move |bounds, window, app| {
                    let Some(bounds) = bounds.first() else { return };
                    let at = point(bounds.center().x, bounds.top());
                    let Some(owner) = desktop.upgrade() else {
                        return;
                    };
                    if owner.read(app).voice.fan_anchor == Some(at) {
                        return;
                    }
                    window.on_next_frame(move |_, cx| {
                        owner.update(cx, |this, cx| {
                            this.voice.fan_anchor = Some(at);
                            cx.notify();
                        })
                    });
                })
            })
    }

    pub(super) fn voice_conversation_pill(&self, cx: &mut Context<Self>) -> Div {
        let active = self.voice.active.as_ref().unwrap();
        let muted = active.input.borrow().muted;
        let listening = active.phase == Phase::Listening && !muted;
        let status = match active.phase {
            Phase::Connecting => tr("正在启动语音…"),
            Phase::Speaking => tr("正在朗读…"),
            Phase::Transcribing => tr("正在转写…"),
            Phase::Waiting => tr("正在等待 Hermes 回复…"),
            _ if muted => tr("麦克风已静音"),
            _ => tr("正在听你说话…"),
        };
        div()
            .flex_none()
            .flex()
            .items_center()
            .gap(px(5.))
            .child(voice_disc(
                "voice-wake-paused",
                icons::VOICE_EAR_OFF,
                tr("语音对话中暂停唤醒"),
                false,
                false,
                false,
            ))
            .child(
                voice_disc(
                    "voice-mute",
                    if muted {
                        icons::VOICE_MIC_OFF
                    } else {
                        icons::MICROPHONE
                    },
                    if muted {
                        tr("取消麦克风静音")
                    } else {
                        tr("静音麦克风")
                    },
                    muted,
                    false,
                    true,
                )
                .on_click(cx.listener(|this, _, _, cx| {
                    if let Some(active) = this.voice.active.as_mut() {
                        active.input.send_modify(|state| state.muted = !state.muted);
                        active.level = 0.;
                        cx.notify();
                    }
                })),
            )
            .children(listening.then(|| {
                div()
                    .id("voice-finish-turn")
                    .h(px(26.))
                    .px_2()
                    .flex()
                    .items_center()
                    .gap(px(5.))
                    .rounded_full()
                    .text_size(px(11.))
                    .text_color(ink(MUTED))
                    .cursor_pointer()
                    .hover(|button| button.bg(rgb(SELECTED)))
                    .tooltip(|window, cx| Tooltip::new(tr("结束本轮收音")).build(window, cx))
                    .child(super::view::svg_symbol(icons::STOP, 10., MUTED))
                    .child(tr("停止"))
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.finish_voice_input(cx);
                    }))
            }))
            .child(
                div()
                    .id("voice-end-conversation")
                    .h(px(28.))
                    .px(px(13.))
                    .rounded_full()
                    .flex()
                    .items_center()
                    .gap(px(6.))
                    .cursor_pointer()
                    .text_size(px(11.))
                    .text_color(ink(SURFACE))
                    .bg(rgb(ACCENT))
                    .hover(|button| button.opacity(0.9))
                    .aria_label(status)
                    .tooltip(move |window, cx| {
                        Tooltip::new(format!("{} · {status}", tr("结束语音对话"))).build(window, cx)
                    })
                    .child(
                        if matches!(
                            active.phase,
                            Phase::Connecting
                                | Phase::Speaking
                                | Phase::Waiting
                                | Phase::Transcribing
                        ) {
                            gpui::svg()
                                .path(icons::VOICE_SPINNER)
                                .size(px(13.))
                                .text_color(ink(SURFACE))
                                .with_animation(
                                    "voice-call-spinner",
                                    Animation::new(Duration::from_millis(900))
                                        .repeat()
                                        .with_max_fps(30.),
                                    |icon, t| {
                                        icon.with_transformation(gpui::Transformation::rotate(
                                            gpui::radians(t * std::f32::consts::TAU),
                                        ))
                                    },
                                )
                                .into_any_element()
                        } else {
                            level_bars(if listening { active.level } else { 0. }, SURFACE)
                                .into_any_element()
                        },
                    )
                    .child(tr("结束"))
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.end_voice();
                        this.resume_voice_wake();
                        cx.notify();
                    })),
            )
    }

    pub(super) fn voice_stop_notice(&self, cx: &mut Context<Self>) -> Option<Div> {
        if !self.voice.stop_hint || !self.voice.is_conversation() {
            return None;
        }
        Some(
            super::view::panel()
                .absolute()
                .right(px(16.))
                .bottom(px(58.))
                .w(px(410.))
                .max_w_full()
                .h(px(50.))
                .px_3()
                .flex()
                .items_center()
                .gap(px(10.))
                .rounded(px(6.))
                .shadow_md()
                .text_size(px(13.))
                .text_color(ink(MUTED))
                .child(super::view::svg_symbol(icons::MICROPHONE, 15., MUTED))
                .child(div().flex_1().child(tr("说“stop”即可结束语音对话。")))
                .child(
                    icon_button("dismiss-voice-stop-hint", icons::TAB_CLOSE, tr("关闭")).on_click(
                        cx.listener(|this, _, _, cx| {
                            this.voice.stop_hint = false;
                            cx.notify();
                        }),
                    ),
                ),
        )
    }

    pub(super) fn finish_voice_input(&mut self, cx: &mut Context<Self>) -> bool {
        if let Some(active) = self.voice.active.as_ref()
            && active.phase == Phase::Listening
            && !active.input.borrow().muted
        {
            active
                .input
                .send_modify(|state| state.finish = state.finish.wrapping_add(1));
            cx.notify();
            return true;
        }
        false
    }

    pub(super) fn voice_primary(&self, enabled: bool, cx: &mut Context<Self>) -> Div {
        let engine = self.voice_engine();
        let title = format!(
            "{} · {}",
            tr("开始语音对话"),
            match engine {
                VoiceEngine::Chained => tr("语音转文字 + Hermes 语音"),
                VoiceEngine::GptLive => "GPT-Live",
            }
        );
        div()
            .flex_none()
            .flex()
            .items_center()
            .gap(px(1.))
            .child(
                voice_disc(
                    "voice-start",
                    icons::VOICE_WAVE,
                    title,
                    false,
                    true,
                    enabled,
                )
                .on_click(cx.listener(move |this, _, window, cx| {
                    if enabled {
                        this.toggle_voice(Mode::Conversation(engine), window, cx);
                    }
                })),
            )
            .child(self.voice_engine_menu(cx))
    }

    fn voice_engine_menu(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let owner = cx.entity().downgrade();
        let toggle = owner.clone();
        Popover::new("voice-engine-menu")
            .anchor(Anchor::BottomRight)
            .open(self.voice.menu)
            .on_open_change(move |open, _, cx| {
                let _ = toggle.update(cx, |this, cx| {
                    this.voice.menu = *open;
                    cx.notify();
                });
            })
            .trigger(
                Button::new("voice-engine-trigger")
                    .ghost()
                    .compact()
                    .px_1()
                    .tooltip(tr("语音对话引擎"))
                    .child(super::view::svg_symbol(icons::CHEVRON_DOWN, 11., MUTED)),
            )
            .content(move |_, _, cx| {
                let Some(entity) = owner.upgrade() else {
                    return div();
                };
                let view = entity.read(cx);
                let selected = view.voice_engine();
                let live = view.voice_engine_status();
                let live_ready = live.is_some_and(|status| status["available"] == true);
                let reason = live
                    .and_then(|status| status["reason"].as_str())
                    .unwrap_or_else(|| {
                        if live.is_none() {
                            tr("正在检查引擎…")
                        } else {
                            tr("GPT-Live 当前不可用")
                        }
                    })
                    .to_owned();
                let pending = view.voice.saving_engine.is_some();
                div()
                    .w(px(268.))
                    .flex()
                    .flex_col()
                    .gap_1()
                    .text_size(px(12.))
                    .child(
                        div()
                            .px_2()
                            .py_1()
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(ink(MUTED))
                            .child(tr("语音对话引擎")),
                    )
                    .children(
                        [
                            (
                                VoiceEngine::Chained,
                                "voice-chained",
                                tr("语音转文字 + Hermes 语音"),
                            ),
                            (
                                VoiceEngine::GptLive,
                                "voice-gpt-live",
                                tr("GPT-Live（全双工，委托给 Hermes）"),
                            ),
                        ]
                        .into_iter()
                        .map(|(engine, id, label)| {
                            let owner = owner.clone();
                            let available =
                                !pending && (engine != VoiceEngine::GptLive || live_ready);
                            div()
                                .id(id)
                                .rounded(px(4.))
                                .px_2()
                                .py_1()
                                .flex()
                                .items_center()
                                .justify_between()
                                .when(available, |row| {
                                    row.cursor_pointer().hover(|row| row.bg(rgb(SELECTED)))
                                })
                                .child(
                                    div()
                                        .min_w_0()
                                        .flex_1()
                                        .text_color(ink(if available { INK } else { MUTED }))
                                        .child(label)
                                        .children(
                                            (engine == VoiceEngine::GptLive && !live_ready).then(
                                                || {
                                                    div()
                                                        .truncate()
                                                        .text_size(px(10.))
                                                        .text_color(ink(MUTED))
                                                        .child(reason.clone())
                                                },
                                            ),
                                        ),
                                )
                                .children((selected == engine).then(|| {
                                    super::view::svg_symbol(icons::TASK_CHECK, 13., ACCENT)
                                }))
                                .on_click(move |_, _, cx| {
                                    let _ = owner.update(cx, |this, cx| {
                                        if available {
                                            this.set_voice_engine(engine, cx);
                                        }
                                    });
                                })
                        }),
                    )
            })
    }
}

fn voice_disc(
    id: &'static str,
    glyph: &'static str,
    label: impl Into<String>,
    active: bool,
    primary: bool,
    enabled: bool,
) -> gpui::Stateful<Div> {
    let label = label.into();
    div()
        .id(id)
        .size(px(27.))
        .rounded_full()
        .flex_none()
        .flex()
        .items_center()
        .justify_center()
        .aria_label(label.clone())
        .when(enabled, |button| button.cursor_pointer())
        .when(!enabled, |button| button.opacity(0.5))
        .when(active, |button| button.bg(rgb(SELECTED)))
        .when(primary, |button| button.bg(rgb(0x272d36)))
        .hover(move |button| {
            if !enabled {
                button
            } else {
                button.bg(rgb(if primary { ACCENT } else { SELECTED }))
            }
        })
        .tooltip(move |window, cx| Tooltip::new(label.clone()).build(window, cx))
        .child(super::view::svg_symbol(
            glyph,
            if primary { 16. } else { 14. },
            if primary {
                SURFACE
            } else if active {
                ACCENT
            } else {
                MUTED
            },
        ))
}

fn fan_disc(
    id: &'static str,
    glyph: &'static str,
    label: impl Into<String>,
    active: bool,
    enabled: bool,
) -> gpui::Stateful<Div> {
    voice_disc(id, glyph, label, active, false, enabled)
        .bg(rgb(if active { SELECTED } else { SURFACE }))
        .border_1()
        .border_color(rgb(0xdfe3ea))
        .shadow_sm()
}

fn level_bars(level: f32, color: u32) -> Div {
    div()
        .flex()
        .items_center()
        .gap(px(2.))
        .h(px(12.))
        .children([0.55, 0.85, 1., 0.85, 0.55].map(|weight| {
            div()
                .w(px(1.5))
                .h(px(3. + level * 9. * weight))
                .rounded_full()
                .bg(rgb(color))
        }))
}
