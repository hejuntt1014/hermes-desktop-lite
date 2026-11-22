use std::time::Duration;

use anyhow::{Context as _, Result, ensure};
use base64::{Engine as _, engine::general_purpose::STANDARD};
use gpui::{Context, Task, Window};
use serde_json::{Value, json};
use tokio::sync::{mpsc, oneshot};
use uuid::Uuid;

use crate::{i18n::text as tr, voice::Mode, voice_audio::Microphone};

use super::{Call, Desktop, rpc_error};

#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum Operation {
    Start,
    Stop,
    Pause,
    Resume,
}

pub(super) struct Request {
    id: Uuid,
    operation: Operation,
    sticky: bool,
}

#[derive(Default)]
pub(super) struct Wake {
    /// Retain ownership while the microphone is loaned to dictation or conversation.
    armed: bool,
    paused: bool,
    external: bool,
    pending: Option<Uuid>,
    failed: bool,
    pub phrase: String,
    capture: Option<Task<()>>,
}

impl Wake {
    pub(super) fn available(&self) -> bool {
        self.pending.is_none()
    }
    pub(super) fn listening(&self) -> bool {
        self.armed && !self.paused
    }
}

impl Desktop {
    pub(super) fn toggle_voice_wake(&mut self, cx: &mut Context<Self>) {
        if self.out.is_none() || self.voice.using_microphone() || !self.voice_wake.available() {
            return;
        }
        let operation = if self.voice_wake.armed {
            self.voice_wake.capture = None;
            Operation::Stop
        } else {
            Operation::Start
        };
        self.voice_wake.failed = false;
        self.voice_wake_call(operation, true);
        cx.notify();
    }

    pub(super) fn pause_voice_wake(&mut self) {
        self.voice_wake.capture = None;
        if self.voice_wake.listening() && self.voice_wake.available() {
            self.voice_wake_call(Operation::Pause, false);
        }
    }

    pub(super) fn resume_voice_wake(&mut self) {
        if self.out.is_none()
            || self.voice.using_microphone()
            || !self.voice_wake.available()
            || self.voice_wake.failed
        {
            return;
        }
        if !self
            .settings
            .voice_wake
            .contains(self.settings.workspace_key())
        {
            return;
        }
        if !self.voice_wake.armed {
            self.voice_wake_call(Operation::Start, false);
        } else if self.voice_wake.paused {
            self.voice_wake_call(Operation::Resume, false);
        }
    }

    fn voice_wake_call(&mut self, operation: Operation, sticky: bool) {
        let id = Uuid::new_v4();
        let (method, payload) = match operation {
            Operation::Start => (
                "wake.start",
                json!({"surface":"gui", "client_capture":true, "persist":sticky}),
            ),
            Operation::Stop => ("wake.stop", json!({"persist":sticky})),
            Operation::Pause => ("wake.pause", json!({})),
            Operation::Resume => ("wake.resume", json!({})),
        };
        if self.call(
            method,
            payload,
            Call::VoiceWake(Request {
                id,
                operation,
                sticky,
            }),
        ) {
            self.voice_wake.pending = Some(id);
        }
    }

    pub(super) fn voice_wake_lost(&mut self, request: Request) {
        if self.voice_wake.pending == Some(request.id) {
            self.voice_wake.pending = None;
            self.voice_wake.failed = true;
            self.banner = Some(tr("未收到语音唤醒确认").into());
        }
    }

    pub(super) fn voice_wake_result(
        &mut self,
        request: Request,
        result: &Value,
        error: Option<&Value>,
        cx: &mut Context<Self>,
    ) {
        if self.voice_wake.pending != Some(request.id) {
            return;
        }
        self.voice_wake.pending = None;
        let successful = match request.operation {
            Operation::Start => result["started"] == true,
            Operation::Stop => result["stopped"] == true || result["disabled_persisted"] == true,
            Operation::Pause => result["paused"] == true,
            Operation::Resume => result["resumed"] == true,
        };
        if !successful {
            self.voice_wake.failed = true;
            let reason = error.map(rpc_error).or_else(|| {
                result["hint"]
                    .as_str()
                    .filter(|hint| !hint.is_empty())
                    .or_else(|| result["reason"].as_str())
                    .map(str::to_owned)
            });
            self.banner = Some(
                reason
                    .unwrap_or_else(|| tr("语音唤醒不可用").to_owned())
                    .into(),
            );
            cx.notify();
            return;
        }
        let key = self.settings.workspace_key().to_owned();
        match request.operation {
            Operation::Start => {
                self.voice_wake.armed = true;
                self.voice_wake.paused = false;
                self.voice_wake.external = result["capture"] == "client";
                self.voice_wake.phrase = result["phrase"].as_str().unwrap_or_default().to_owned();
                if request.sticky {
                    self.settings.voice_wake.insert(key);
                }
            }
            Operation::Stop => {
                self.voice_wake.armed = false;
                self.voice_wake.paused = false;
                if request.sticky {
                    self.settings.voice_wake.remove(&key);
                }
            }
            Operation::Pause => self.voice_wake.paused = true,
            Operation::Resume => self.voice_wake.paused = false,
        }
        if request.sticky {
            self.persist(cx);
        }
        if self.voice_wake.listening() {
            if self.voice.using_microphone() {
                self.pause_voice_wake();
            } else if self.voice_wake.external && self.voice_wake.capture.is_none() {
                self.start_wake_capture(cx);
            }
        }
        cx.notify();
    }

    pub(super) fn voice_wake_detected(
        &mut self,
        event: &Value,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.voice_wake.listening() {
            return;
        }
        self.voice_wake.paused = true;
        self.voice_wake.capture = None;
        let payload = &event["payload"];
        if let Some(profile) = payload["profile"]
            .as_str()
            .filter(|profile| !profile.is_empty() && *profile != self.active_profile())
        {
            self.open_profile(profile, window, cx);
        }
        if payload["start_new_session"] != false {
            self.new_chat_tab(window, cx);
        }
        self.toggle_voice(Mode::Conversation(self.voice_engine()), window, cx);
        if !self.voice.using_microphone() {
            self.resume_voice_wake();
        }
    }

    fn start_wake_capture(&mut self, cx: &mut Context<Self>) {
        let (frames, mut receive) = mpsc::channel(2);
        let worker = self.runtime.spawn(async move {
            let mut mic = Microphone::open(16_000).context(tr("无法打开麦克风"))?;
            let mut samples = Vec::with_capacity(3_200);
            loop {
                let chunk = tokio::select! {
                    _ = frames.closed() => return Ok::<_, anyhow::Error>(()),
                    chunk = mic.next() => chunk?,
                };
                samples.extend(chunk);
                while samples.len() >= 2_560 {
                    let pcm = samples
                        .drain(..2_560)
                        .flat_map(|sample| {
                            ((sample.clamp(-1., 1.) * 32767.).round() as i16).to_le_bytes()
                        })
                        .collect::<Vec<_>>();
                    let _ = frames.try_send(STANDARD.encode(pcm));
                }
            }
        });
        // Keep at most one request in flight so the microphone stream cannot pile up on a slow gateway.
        self.voice_wake.capture = Some(cx.spawn(async move |desktop, cx| {
            let result: Result<()> = async {
                let mut rejected = 0;
                while let Some(pcm) = receive.recv().await {
                    let (send, ack) = oneshot::channel();
                    let sent = desktop
                        .update(cx, |this, _| {
                            this.call(
                                "wake.feed",
                                json!({"pcm_b64":pcm, "sample_rate":16000}),
                                Call::WakeFeed(send),
                            )
                        })
                        .unwrap_or(false);
                    if !sent {
                        return Ok(());
                    }
                    let deadline = cx.background_executor().timer(Duration::from_secs(4));
                    futures_util::pin_mut!(deadline);
                    let fed = matches!(
                        futures_util::future::select(ack, deadline).await,
                        futures_util::future::Either::Left((Ok(true), _))
                    );
                    rejected = if fed { 0 } else { rejected + 1 };
                    ensure!(rejected < 4, "{}", tr("网关未接收唤醒音频"));
                }
                worker.await?
            }
            .await;
            let _ = desktop.update(cx, |this, cx| {
                this.voice_wake.capture = None;
                if let Err(error) = result {
                    this.pause_voice_wake();
                    this.voice_wake.failed = true;
                    this.banner = Some(error.to_string().into());
                }
                cx.notify();
            });
        }));
    }
}
