use std::{collections::HashSet, time::Duration};

use anyhow::{Context, Result, bail};
use serde_json::{Value, json};
use tokio::{
    sync::{mpsc, oneshot, watch},
    time::Instant,
};
use uuid::Uuid;

use crate::{
    gateway::Gateway,
    i18n::text as tr,
    voice::{Event, InputControl, Phase, VoiceCommand, audio_request},
};

#[cfg_attr(windows, path = "voice_live/windows.rs")]
#[cfg_attr(not(windows), path = "voice_live/legacy.rs")]
mod platform;

struct Call<'a> {
    gateway: &'a Gateway,
    profile: &'a str,
    commands: &'a mut mpsc::Receiver<VoiceCommand>,
    events: &'a mpsc::Sender<Event>,
    input: watch::Receiver<InputControl>,
    transcript: &'a mut Vec<(bool, String)>,
}
#[derive(Debug)]
struct TransportLost(&'static str);

impl std::fmt::Display for TransportLost {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.0)
    }
}

impl std::error::Error for TransportLost {}

pub async fn run(
    gateway: &Gateway,
    profile: &str,
    history: Vec<Value>,
    commands: &mut mpsc::Receiver<VoiceCommand>,
    events: &mpsc::Sender<Event>,
    mut cancelled: oneshot::Receiver<()>,
    input: watch::Receiver<InputControl>,
) -> Result<()> {
    let status = tokio::select! {
        _ = &mut cancelled => return Ok(()),
        result = audio_request(gateway, profile, "api/audio/voice-live/status", None) => result?,
    };
    if status["available"] != true {
        let reason = status["reason"].as_str().unwrap_or_default();
        bail!("{} {reason}", tr("GPT-Live 当前不可用"));
    }
    let connector = platform::Connector::new()?;
    let mut transcript = Vec::new();
    let mut retries = 0;
    loop {
        let peer = connector.peer().await?;
        let mut seed = history.clone();
        seed.extend(transcript.iter().map(|(user, text): &(bool, String)| {
            let (role, kind) = if *user {
                ("user", "input_text")
            } else {
                ("assistant", "output_text")
            };
            json!({"type":"message", "role":role, "content":[{"type":kind,"text":text}]})
        }));
        let mut call = Call {
            gateway,
            profile,
            commands,
            events,
            input: input.clone(),
            transcript: &mut transcript,
        };
        let start = Instant::now();
        let result = tokio::select! {
            _ = &mut cancelled => Ok(()),
            result = peer.converse(&mut call, seed) => result,
        };
        peer.close().await;
        if start.elapsed() >= Duration::from_secs(120) {
            retries = 0;
        }
        match result {
            Err(error) if error.is::<TransportLost>() && retries < 2 => {
                retries += 1;
                let _ = events.try_send(Event::Phase(Phase::Connecting));
                tokio::select! {
                    _ = &mut cancelled => return Ok(()),
                    _ = tokio::time::sleep(Duration::from_millis(250)) => {}
                }
            }
            result => return result,
        }
    }
}

async fn request_answer(
    gateway: &Gateway,
    profile: &str,
    offer: String,
    history: Vec<Value>,
) -> Result<String> {
    let result = audio_request(
        gateway,
        profile,
        "api/audio/voice-live/session",
        Some(json!({"sdp": offer, "history": history})),
    )
    .await?;
    result["transport"]["sdp"]
        .as_str()
        .map(str::to_owned)
        .context(tr("语音连接失败"))
}

#[derive(Clone, Copy)]
enum ConnectionState {
    Connected,
    Disconnected,
    Closed,
}

async fn monitor_connection<T: Copy + Send + Sync>(
    mut state: watch::Receiver<T>,
    classify: impl Fn(T) -> ConnectionState + Send,
) -> Result<()> {
    loop {
        let current = *state.borrow_and_update();
        match classify(current) {
            ConnectionState::Closed => return Err(TransportLost(tr("语音连接已断开")).into()),
            ConnectionState::Disconnected => {
                tokio::time::timeout(Duration::from_secs(12), state.changed())
                    .await
                    .map_err(|_| TransportLost(tr("语音连接恢复超时")))??;
            }
            ConnectionState::Connected => state.changed().await?,
        }
    }
}

async fn handle_messages<F>(
    call: &mut Call<'_>,
    mut incoming: mpsc::Receiver<Vec<u8>>,
    mut send: impl FnMut(Value) -> F + Send,
    mut set_muted: impl FnMut(bool) + Send,
) -> Result<()>
where
    F: Future<Output = Result<()>> + Send,
{
    let Call {
        commands,
        events,
        input,
        transcript,
        ..
    } = call;
    let mut delegations = HashSet::new();
    let started = tokio::time::sleep(Duration::from_secs(20));
    tokio::pin!(started);
    let mut ready = false;
    let mut last = InputControl::default();
    set_muted(input.borrow().muted);
    loop {
        tokio::select! {
            _ = &mut started, if !ready => bail!("{}", tr("语音连接超时")),
            changed = input.changed() => {
                if changed.is_err() { return Ok(()) }
                let current = *input.borrow_and_update();
                set_muted(current.muted);
                if !ready { continue; }
                if current.muted != last.muted {
                    let kind = if current.muted { "session.input_audio.mute" } else { "session.input_audio.unmute" };
                    send(json!({"type":kind,"event_id":Uuid::new_v4().to_string()})).await?;
                }
                if current.finish != last.finish {
                    send(json!({
                        "type":"session.instructions.append", "event_id":Uuid::new_v4().to_string(),
                        "delegation_id":null, "content":"The user has finished speaking. Respond now to what they said."
                    })).await?;
                }
                last = current;
            }
            Some(bytes) = incoming.recv() => {
                let Ok(event) = serde_json::from_slice::<Value>(&bytes) else { continue };
                match event["type"].as_str().unwrap_or_default() {
                    "session.started" => {
                        ready = true;
                        last = *input.borrow_and_update();
                        set_muted(last.muted);
                        if last.muted {
                            send(json!({"type":"session.input_audio.mute","event_id":Uuid::new_v4().to_string()})).await?;
                        }
                        events.send(Event::Phase(Phase::Listening)).await?;
                    }
                    "session.input_transcript.delta" | "session.output_transcript.delta" => {
                        let user = event["type"] == "session.input_transcript.delta";
                        if let Some(delta) = event["delta"].as_str() {
                            append_transcript(transcript, user, delta);
                        }
                    }
                    "session.delegation.created" => {
                        if let Some(id) = event["delegation"]["id"].as_str()
                            && let Some((prompt, context)) = delegation_prompt(transcript)
                        {
                            delegations.insert(id.to_owned());
                            events.send(Event::Delegate { id: id.to_owned(), prompt, context }).await?;
                        }
                    }
                    "session.closed" => {
                        let reason = event["reason"].as_str().filter(|reason| !reason.is_empty())
                            .unwrap_or_else(|| tr("语音服务已结束通话"));
                        bail!("{reason}");
                    }
                    "error" if event["error"]["code"] != "context_injection_incomplete" => {
                        if let Some(message) = event["error"]["message"].as_str() {
                            let _ = events.try_send(Event::Notice(message.to_owned()));
                        }
                    }
                    _ => {}
                }
            }
            command = commands.recv() => {
                match command {
                    Some(VoiceCommand::Reply { delegation, text }) => {
                        let delegation = delegation.filter(|id| delegations.remove(id));
                        let clean = text.split_whitespace().collect::<Vec<_>>().join(" ");
                        let chars: Vec<_> = clean.chars().take(12_000).collect();
                        for chunk in chars.chunks(1_500) {
                            let content = chunk.iter().collect::<String>();
                            let message = json!({
                                "type": "session.commentary.append",
                                "event_id": Uuid::new_v4().to_string(),
                                "delegation_id": delegation,
                                "content": content,
                            });
                            send(message).await?;
                        }
                    }
                    _ => return Ok(()),
                }
            }
        }
    }
}

fn append_transcript(turns: &mut Vec<(bool, String)>, user: bool, delta: &str) {
    if turns.last().is_none_or(|(speaker, _)| *speaker != user) {
        turns.push((user, String::new()));
    }
    let text = &mut turns.last_mut().unwrap().1;
    text.push_str(delta);
    if text.len() > 8_000 {
        text.drain(..text.ceil_char_boundary(text.len() - 8_000));
    }
    if turns.len() > 12 {
        turns.remove(0);
    }
}

fn delegation_prompt(turns: &[(bool, String)]) -> Option<(String, String)> {
    let prompt = turns
        .iter()
        .rev()
        .find(|(user, text)| *user && !text.trim().is_empty())?
        .1
        .trim()
        .to_owned();
    let context = turns
        .iter()
        .map(|(user, text)| {
            let speaker = if *user { "User" } else { "Voice assistant" };
            format!("{speaker}: {}", text.trim())
        })
        .collect::<Vec<_>>()
        .join("\n");
    Some((prompt, context))
}
