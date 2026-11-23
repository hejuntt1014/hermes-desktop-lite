use std::{
    collections::{BTreeMap, VecDeque},
    sync::{Arc, Mutex},
    time::Duration,
};

use anyhow::{Context, Result};
use serde_json::Value;
use sonora::{
    AudioProcessing, Config, StreamConfig,
    config::{EchoCanceller, GainController2, NoiseSuppression},
};
use tokio::{
    sync::{mpsc, watch},
    time::Instant,
};

use webrtc::{
    api::{
        APIBuilder, interceptor_registry::register_default_interceptors, media_engine::MediaEngine,
    },
    interceptor::registry::Registry,
    media::Sample,
    peer_connection::{
        RTCPeerConnection, configuration::RTCConfiguration,
        peer_connection_state::RTCPeerConnectionState,
        sdp::session_description::RTCSessionDescription,
    },
    rtp_transceiver::rtp_codec::RTCRtpCodecCapability,
    track::{
        track_local::track_local_static_sample::TrackLocalStaticSample, track_remote::TrackRemote,
    },
};

use crate::{
    i18n::text as tr,
    voice::{Event, Meter, Phase},
    voice_audio::{Microphone, Speaker},
};

const RATE: u32 = 48_000;
const FRAME: usize = RATE as usize / 50;
const DSP_FRAME: usize = FRAME / 2;
const PACKET: Duration = Duration::from_millis(20);

use super::{
    Call, ConnectionState, TransportLost, handle_messages, monitor_connection, request_answer,
};

pub(super) struct Connector(webrtc::api::API);
pub(super) struct Peer(RTCPeerConnection);

impl Connector {
    pub(super) fn new() -> Result<Self> {
        let mut codecs = MediaEngine::default();
        codecs.register_default_codecs()?;
        let interceptors = register_default_interceptors(Registry::new(), &mut codecs)?;
        let api = APIBuilder::new()
            .with_media_engine(codecs)
            .with_interceptor_registry(interceptors)
            .build();

        Ok(Self(api))
    }

    pub(super) async fn peer(&self) -> Result<Peer> {
        Ok(Peer(
            self.0
                .new_peer_connection(RTCConfiguration::default())
                .await?,
        ))
    }
}

impl Peer {
    pub(super) async fn close(&self) {
        let _ = tokio::time::timeout(Duration::from_secs(3), self.0.close()).await;
    }

    pub(super) async fn converse(&self, call: &mut Call<'_>, history: Vec<Value>) -> Result<()> {
        let events = call.events;
        let input = call.input.clone();
        let peer = &self.0;
        let mut mic = Microphone::open(RATE).context(tr("无法打开麦克风"))?;
        let speaker = Speaker::open().context(tr("无法播放语音"))?;
        let sink = &speaker.sink;
        let playback = Arc::new(Mutex::new(VecDeque::new()));
        sink.append(ContinuousAudio {
            queue: playback.clone(),
            current: Vec::new().into_iter(),
            silence: 0,
        });
        let processing = Mutex::new(
            AudioProcessing::builder()
                .config(Config {
                    echo_canceller: Some(EchoCanceller::default()),
                    noise_suppression: Some(NoiseSuppression::default()),
                    gain_controller2: Some(GainController2::default()),
                    ..Default::default()
                })
                .capture_config(StreamConfig::new(RATE, 1))
                .render_config(StreamConfig::new(RATE, 1))
                .build(),
        );
        let track = Arc::new(TrackLocalStaticSample::new(
            RTCRtpCodecCapability {
                mime_type: "audio/opus".to_owned(),
                clock_rate: RATE,
                channels: 2,
                sdp_fmtp_line: "minptime=10;useinbandfec=1".to_owned(),
                ..Default::default()
            },
            "microphone".to_owned(),
            "hermes-lite".to_owned(),
        ));
        let sender = peer.add_track(track.clone()).await?;
        // Drain RTCP so sender feedback keeps flowing through the interceptors.
        tokio::spawn(async move {
            let mut packet = [0u8; 1500];
            while sender.read(&mut packet).await.is_ok() {}
        });
        let (tracks, mut remote) = mpsc::channel(1);
        peer.on_track(Box::new(move |track, _, _| {
            let _ = tracks.try_send(track);
            Box::pin(async {})
        }));
        let (closed, mut ended) = mpsc::channel(1);
        let (state_tx, state) = watch::channel(RTCPeerConnectionState::New);
        peer.on_peer_connection_state_change(Box::new(move |state| {
            state_tx.send_replace(state);
            Box::pin(async {})
        }));
        let channel = peer.create_data_channel("oai-events", None).await?;
        channel.on_close(Box::new(move || {
            let _ = closed.try_send(());
            Box::pin(async {})
        }));
        let (messages, incoming) = mpsc::channel(128);
        channel.on_message(Box::new(move |message| {
            let messages = messages.clone();
            Box::pin(async move {
                let _ = messages.send(message.data.to_vec()).await;
            })
        }));
        let mut ice = peer.gathering_complete_promise().await;
        peer.set_local_description(peer.create_offer(None).await?)
            .await?;
        tokio::time::timeout(Duration::from_secs(10), ice.recv())
            .await
            .context(tr("语音连接超时"))?;
        let offer = peer.local_description().await.context(tr("语音连接失败"))?;
        let answer = request_answer(call.gateway, call.profile, offer.sdp, history).await?;
        peer.set_remote_description(RTCSessionDescription::answer(answer)?)
            .await?;

        let mute = input.clone();
        let sending = async {
            let mut encoder =
                opus::Encoder::new(RATE, opus::Channels::Mono, opus::Application::Voip)?;
            let mut samples = Vec::with_capacity(FRAME * 2);
            let mut packet = [0u8; 1500];
            let mut cleaned = [0f32; FRAME];
            let mut meter = Meter::new(events);
            let mut muted = false;
            loop {
                let frames = mic.next().await?;
                let current_mute = mute.borrow().muted;
                if current_mute != muted {
                    muted = current_mute;
                    // Drop a partial frame at the transition so it cannot carry pre-mute audio.
                    samples.clear();
                }
                if muted {
                    // Like disabling a browser MediaStreamTrack, keep RTP clocking with silence.
                    // The provider can tear down an audio channel that stops sending altogether.
                    samples.resize(samples.len() + frames.len(), 0.);
                } else {
                    meter.measure(&frames);
                    samples.extend(frames);
                }
                let full = samples.len() / FRAME * FRAME;
                for frame in samples[..full].chunks_exact(FRAME) {
                    if muted {
                        cleaned.fill(0.);
                    } else {
                        let mut processor = processing.lock().unwrap();
                        for (input, output) in frame
                            .chunks_exact(DSP_FRAME)
                            .zip(cleaned.chunks_exact_mut(DSP_FRAME))
                        {
                            processor.process_capture_f32(&[input], &mut [output])?;
                        }
                    }
                    let size = encoder.encode_float(&cleaned, &mut packet)?;
                    track
                        .write_sample(&Sample {
                            data: packet[..size].to_vec().into(),
                            duration: PACKET,
                            ..Default::default()
                        })
                        .await?;
                }
                samples.drain(..full);
            }
        };
        let receiving = async {
            let track = remote.recv().await.context(tr("语音连接已断开"))?;
            receive_audio(track, &playback, &processing, events).await
        };

        let handling = handle_messages(
            call,
            incoming,
            move |message| {
                let channel = channel.clone();
                async move {
                    channel.send_text(message.to_string()).await?;
                    Ok(())
                }
            },
            |_| {},
        );
        let data_channel_closed = async {
            let _ = ended.recv().await;
            // Give a final session.closed event priority over reconnecting an intentionally ended call.
            tokio::time::sleep(Duration::from_millis(180)).await;
            Err(TransportLost(tr("语音数据通道已关闭")).into())
        };
        tokio::select! {
            result = sending => result,
            result = receiving => result,
            result = handling => result,
            result = monitor_connection(state, |state| match state {
                RTCPeerConnectionState::Failed | RTCPeerConnectionState::Closed => ConnectionState::Closed,
                RTCPeerConnectionState::Disconnected => ConnectionState::Disconnected,
                _ => ConnectionState::Connected,
            }) => result,
            result = data_channel_closed => result,
        }
    }
}

type PlaybackQueue = Arc<Mutex<VecDeque<Vec<f32>>>>;

struct ContinuousAudio {
    queue: PlaybackQueue,
    current: std::vec::IntoIter<f32>,
    silence: usize,
}

impl Iterator for ContinuousAudio {
    type Item = f32;

    fn next(&mut self) -> Option<f32> {
        if let Some(sample) = self.current.next() {
            return Some(sample);
        }
        if self.silence > 0 {
            self.silence -= 1;
            return Some(0.);
        }
        let next = self.queue.lock().unwrap().pop_front();
        if let Some(block) = next {
            self.current = block.into_iter();
            return self.current.next().or(Some(0.));
        }
        self.silence = DSP_FRAME - 1;
        Some(0.)
    }
}

impl rodio::Source for ContinuousAudio {
    fn current_span_len(&self) -> Option<usize> {
        None
    }
    fn channels(&self) -> u16 {
        1
    }
    fn sample_rate(&self) -> u32 {
        RATE
    }
    fn total_duration(&self) -> Option<Duration> {
        None
    }
}

async fn receive_audio(
    track: Arc<TrackRemote>,
    playback: &PlaybackQueue,
    processing: &Mutex<AudioProcessing>,
    events: &mpsc::Sender<Event>,
) -> Result<()> {
    let mut decoder = opus::Decoder::new(RATE, opus::Channels::Mono)?;
    let mut samples = [0f32; 5760];
    let mut rendered = [0f32; DSP_FRAME];
    // Playout follows a clock, independent of the timing of incoming UDP bursts.
    let mut packets = BTreeMap::<u16, Vec<u8>>::new();
    let mut expected = 0u16;
    let mut next_play: Option<Instant> = None;
    let mut priming = false;
    let mut last_len = FRAME;
    let mut missing = 0;
    let mut quiet = 0;
    let mut speaking = false;
    loop {
        let packet = tokio::select! {
            biased;
            _ = tokio::time::sleep_until(next_play.unwrap_or_else(Instant::now)), if next_play.is_some() => None,
            packet = track.read_rtp() => Some(packet?.0),
        };
        if let Some(packet) = packet {
            let seq = packet.header.sequence_number;
            let jump = seq.wrapping_sub(expected) as i16;
            if next_play.is_none() || jump > 48 {
                packets.clear();
                expected = seq;
                next_play = Some(Instant::now() + Duration::from_millis(72));
                missing = 0;
                priming = true;
            } else if jump < 0 {
                if !priming || jump < -4 {
                    continue;
                }
                expected = seq;
            }
            packets
                .entry(seq)
                .or_insert_with(|| packet.payload.to_vec());
            continue;
        }
        priming = false;
        let payload = packets.remove(&expected);
        expected = expected.wrapping_add(1);
        missing = if payload.is_some() { 0 } else { missing + 1 };
        if missing >= 6 {
            if packets.is_empty() {
                next_play = None;
                if speaking {
                    speaking = false;
                    let _ = events.try_send(Event::Phase(Phase::Listening));
                }
                continue;
            }
            // A long gap is a new talkspurt. Do not spend seconds playing packet-loss fill.
            expected = *packets
                .keys()
                .min_by_key(|seq| seq.wrapping_sub(expected))
                .unwrap();
            next_play = Some(Instant::now() + Duration::from_millis(40));
            missing = 0;
            continue;
        }
        let decoded = match payload {
            Some(payload) => decoder.decode_float(&payload, &mut samples, false),
            None => decoder.decode_float(&[], &mut samples[..last_len], false),
        };
        let len = match decoded {
            Ok(len) if len > 0 => {
                last_len = len;
                len
            }
            _ => {
                samples[..last_len].fill(0.);
                last_len
            }
        };
        let duration = Duration::from_secs_f64(len as f64 / f64::from(RATE));
        let now = Instant::now();
        let deadline = next_play.unwrap_or(now) + duration;
        next_play = Some(deadline.max(now + Duration::from_millis(2)));
        let loud = samples[..len].iter().any(|sample| sample.abs() > 0.024);
        quiet = if loud { 0 } else { quiet + len };
        if loud && !speaking {
            speaking = true;
            let _ = events.try_send(Event::Phase(Phase::Speaking));
        } else if speaking && quiet > RATE as usize / 5 {
            speaking = false;
            let _ = events.try_send(Event::Phase(Phase::Listening));
        }
        // Use the actual played samples as the echo-canceller reference.
        let mut audio = samples[..len].to_vec();
        for frame in audio.chunks_exact_mut(DSP_FRAME) {
            if processing
                .lock()
                .unwrap()
                .process_render_f32(&[frame], &mut [&mut rendered])
                .is_ok()
            {
                frame.copy_from_slice(&rendered);
            }
        }
        {
            let mut queue = playback.lock().unwrap();
            if queue.len() >= 14 {
                // Bound latency if the output device briefly stops consuming audio.
                queue.pop_front();
            }
            queue.push_back(audio);
        }
    }
}
