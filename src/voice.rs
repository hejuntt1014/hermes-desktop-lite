use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use base64::{Engine, engine::general_purpose::STANDARD};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::sync::{mpsc, watch};

use crate::{
    gateway::Gateway,
    i18n::text as tr,
    voice_audio::{Microphone, play, record_until, record_utterance, wav},
};

#[derive(Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum VoiceEngine {
    #[default]
    Chained,
    GptLive,
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Dictation,
    Conversation(VoiceEngine),
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Phase {
    Connecting,
    Recording,
    Listening,
    Transcribing,
    Waiting,
    Speaking,
}

pub enum VoiceCommand {
    Finish,
    Reply {
        delegation: Option<String>,
        text: String,
    },
}

#[derive(Clone, Copy, Default)]
pub struct InputControl {
    pub muted: bool,
    pub finish: u64,
}

pub enum Event {
    Phase(Phase),
    Level(f32),
    Notice(String),
    Transcript(String),
    Delegate {
        id: String,
        prompt: String,
        context: String,
    },
    Error(String),
}

pub struct Meter<'a> {
    events: &'a mpsc::Sender<Event>,
    last: Instant,
}

impl<'a> Meter<'a> {
    pub fn new(events: &'a mpsc::Sender<Event>) -> Self {
        Self {
            events,
            last: Instant::now(),
        }
    }

    pub fn measure(&mut self, samples: &[f32]) {
        if self.last.elapsed() < Duration::from_millis(65) || samples.is_empty() {
            return;
        }
        self.last = Instant::now();
        let rms = (samples.iter().map(|sample| sample * sample).sum::<f32>()
            / samples.len() as f32)
            .sqrt();
        let _ = self.events.try_send(Event::Level((rms * 7.).clamp(0., 1.)));
    }
}

pub fn spoken_stop(text: &str) -> bool {
    let normalized = text
        .trim()
        .trim_end_matches(['.', '!', '?', '。', '！', '？'])
        .to_lowercase();
    let phrase = ["hey hermes", "hermes", "okay", "ok", "hey"]
        .iter()
        .find_map(|prefix| {
            normalized.strip_prefix(prefix).and_then(|tail| {
                tail.starts_with([' ', ',', '，'])
                    .then(|| tail.trim_start_matches([' ', ',', '，']))
            })
        })
        .unwrap_or(&normalized);
    matches!(
        phrase,
        "stop"
            | "stop listening"
            | "stop it"
            | "stop please"
            | "please stop"
            | "stop stop"
            | "that is all"
            | "that's all"
            | "never mind"
            | "nevermind"
            | "end conversation"
            | "end the conversation"
            | "goodbye"
            | "good bye"
            | "bye"
            | "cancel"
            | "停止"
            | "结束对话"
            | "停止对话"
    )
}

pub async fn audio_request(
    gateway: &Gateway,
    profile: &str,
    route: &str,
    body: Option<Value>,
) -> Result<Value> {
    let params = [("profile", profile.to_owned())];
    let method = if body.is_some() {
        reqwest::Method::POST
    } else {
        reqwest::Method::GET
    };
    let response = tokio::time::timeout(Duration::from_secs(90), async {
        let mut response = gateway
            .api_request_builder(method, route, &params, body)
            .await?
            .timeout(Duration::from_secs(90))
            .send()
            .await
            .map_err(|error| error.without_url())?;
        let status = response.status();
        if matches!(status.as_u16(), 404 | 405 | 501) {
            bail!("{}", tr("网关未提供此语音功能"));
        }
        const MAX_RESPONSE: usize = 48 * 1024 * 1024;
        let mut bytes = Vec::new();
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|error| error.without_url())?
        {
            if bytes.len() + chunk.len() > MAX_RESPONSE {
                bail!("{}", tr("语音回复过长"));
            }
            bytes.extend_from_slice(&chunk);
        }
        let data = serde_json::from_slice::<Value>(&bytes);
        if !status.is_success() || data.as_ref().is_ok_and(|data| data["ok"] == false) {
            let detail = data
                .as_ref()
                .ok()
                .and_then(|data| data["detail"].as_str())
                .unwrap_or_else(|| tr("语音请求失败"));
            bail!("{detail} ({status})");
        }
        Ok(data?)
    })
    .await
    .context(tr("语音请求超时"))??;
    Ok(response)
}

async fn transcribe(gateway: &Gateway, profile: &str, samples: &[f32]) -> Result<String> {
    if samples.len() < 1_600 {
        return Ok(String::new());
    }
    let data_url = format!("data:audio/wav;base64,{}", STANDARD.encode(wav(samples)));
    let body = json!({"data_url": data_url, "mime_type": "audio/wav"});
    let result = audio_request(gateway, profile, "api/audio/transcribe", Some(body)).await?;
    Ok(result["transcript"]
        .as_str()
        .unwrap_or_default()
        .trim()
        .to_owned())
}

pub async fn run_chained(
    gateway: &Gateway,
    profile: &str,
    mode: Mode,
    commands: &mut mpsc::Receiver<VoiceCommand>,
    events: &mpsc::Sender<Event>,
    mut input: watch::Receiver<InputControl>,
    speak_replies: bool,
) -> Result<()> {
    let mut meter = Meter::new(events);
    loop {
        while input.borrow_and_update().muted {
            events.send(Event::Phase(Phase::Listening)).await?;
            if input.changed().await.is_err() {
                return Ok(());
            }
        }
        let mut mic = Microphone::open(16_000).context(tr("无法打开麦克风"))?;
        let audio = if mode == Mode::Dictation {
            events.send(Event::Phase(Phase::Recording)).await?;
            record_until(commands, &mut mic, &mut meter).await?
        } else {
            events.send(Event::Phase(Phase::Listening)).await?;
            let Some(audio) = record_utterance(&mut mic, &mut input, &mut meter).await? else {
                continue;
            };
            audio
        };
        drop(mic);
        events.send(Event::Phase(Phase::Transcribing)).await?;
        let transcript = match transcribe(gateway, profile, &audio).await {
            Ok(text) => text,
            Err(error) if matches!(mode, Mode::Conversation(_)) => {
                events.send(Event::Notice(error.to_string())).await?;
                continue;
            }
            Err(error) => return Err(error),
        };
        if mode == Mode::Dictation {
            events.send(Event::Transcript(transcript)).await?;
            return Ok(());
        }
        if transcript.is_empty() {
            continue;
        }
        events.send(Event::Phase(Phase::Waiting)).await?;
        events.send(Event::Transcript(transcript)).await?;
        let interrupt = listen_while_waiting(gateway, profile, &mut input, &mut meter, events);
        let reply = tokio::select! {
            result = tokio::time::timeout(Duration::from_secs(600), commands.recv()) => result.context(tr("等待 Hermes 回复超时"))?,
            result = interrupt => return result,
        };
        let Some(VoiceCommand::Reply { text, .. }) = reply else {
            return Ok(());
        };
        if !speak_replies || text.trim().is_empty() {
            continue;
        }
        let bytes = match synthesize(gateway, profile, text).await {
            Ok(bytes) => bytes,
            Err(error) => {
                events.send(Event::Notice(error.to_string())).await?;
                continue;
            }
        };
        events.send(Event::Phase(Phase::Speaking)).await?;
        if let Err(error) = play(bytes).await {
            let title = tr("无法播放语音");
            events
                .send(Event::Notice(format!("{title} · {error}")))
                .await?;
        }
    }
}

async fn listen_while_waiting(
    gateway: &Gateway,
    profile: &str,
    input: &mut watch::Receiver<InputControl>,
    meter: &mut Meter<'_>,
    events: &mpsc::Sender<Event>,
) -> Result<()> {
    loop {
        while input.borrow_and_update().muted {
            if input.changed().await.is_err() {
                return Ok(());
            }
        }
        let mut mic = Microphone::open(16_000).context(tr("无法打开麦克风"))?;
        let Some(recording) = record_utterance(&mut mic, input, meter).await? else {
            continue;
        };
        drop(mic);
        let text = match transcribe(gateway, profile, &recording).await {
            Ok(text) => text,
            Err(error) => {
                let _ = events.try_send(Event::Notice(error.to_string()));
                continue;
            }
        };
        if !text.is_empty() {
            events.send(Event::Transcript(text)).await?;
        }
    }
}

pub async fn synthesize(gateway: &Gateway, profile: &str, text: String) -> Result<Vec<u8>> {
    let result = audio_request(
        gateway,
        profile,
        "api/audio/speak",
        Some(json!({ "text": text })),
    )
    .await?;
    let encoded = result["data_url"]
        .as_str()
        .and_then(|url| url.split_once(";base64,"))
        .map(|(_, data)| data)
        .context(tr("网关未返回语音音频"))?;
    Ok(STANDARD.decode(encoded)?)
}
