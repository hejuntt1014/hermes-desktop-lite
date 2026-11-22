use std::time::Duration;

use anyhow::{Context, Result, ensure};
use futures_util::StreamExt;
use libwebrtc::{
    audio_stream::native::NativeAudioStream,
    data_channel::{DataChannelInit, DataChannelState},
    media_stream_track::MediaStreamTrack,
    peer_connection::{IceGatheringState, OfferOptions, PeerConnection, PeerConnectionState},
    peer_connection_factory::{
        ContinualGatheringPolicy, PeerConnectionFactory, RtcConfiguration,
        native::PeerConnectionFactoryExt,
    },
    session_description::{SdpType, SessionDescription},
    stats::RtcStats,
};
use serde_json::Value;
use tokio::{
    sync::{mpsc, watch},
    time::MissedTickBehavior,
};

use crate::{
    i18n::text as tr,
    voice::{Event, Phase},
};

use super::{
    Call, ConnectionState, TransportLost, handle_messages, monitor_connection, request_answer,
};

pub(super) struct Connector(PeerConnectionFactory);

pub(super) struct Peer {
    connection: PeerConnection,
    factory: PeerConnectionFactory,
}

impl Connector {
    pub(super) fn new() -> Result<Self> {
        let factory = PeerConnectionFactory::default();
        ensure!(factory.acquire_platform_adm(), "{}", tr("无法打开麦克风"));
        let connector = Self(factory);
        ensure!(
            connector.0.recording_devices() > 0,
            "{}",
            tr("找不到麦克风")
        );
        ensure!(connector.0.playout_devices() > 0, "{}", tr("无法播放语音"));
        connector.0.set_adm_playout_enabled(true);
        connector.0.set_adm_recording_enabled(true);
        Ok(connector)
    }

    pub(super) async fn peer(&self) -> Result<Peer> {
        let mut config = RtcConfiguration::default();
        config.continual_gathering_policy = ContinualGatheringPolicy::GatherOnce;
        Ok(Peer {
            connection: self.0.create_peer_connection(config)?,
            factory: self.0.clone(),
        })
    }
}

impl Drop for Connector {
    fn drop(&mut self) {
        self.0.set_adm_recording_enabled(false);
        self.0.set_adm_playout_enabled(false);
        self.0.release_platform_adm();
    }
}

impl Peer {
    pub(super) async fn close(&self) {
        self.connection.close();
    }

    pub(super) async fn converse(&self, call: &mut Call<'_>, history: Vec<Value>) -> Result<()> {
        let peer = &self.connection;
        let events = call.events;
        let input = call.input.clone();
        let mic = self.factory.create_device_audio_track("microphone");
        mic.set_enabled(!input.borrow().muted);
        peer.add_track(MediaStreamTrack::Audio(mic.clone()), &["hermes-lite"])?;

        let (tracks, mut remote) = mpsc::channel(1);
        peer.on_track(Some(Box::new(move |event| {
            if let MediaStreamTrack::Audio(track) = event.track {
                let _ = tracks.try_send(track);
            }
        })));
        let (state_tx, state) = watch::channel(PeerConnectionState::New);
        peer.on_connection_state_change(Some(Box::new(move |state| {
            state_tx.send_replace(state);
        })));
        let (closed, mut ended) = mpsc::channel(1);
        let channel = peer.create_data_channel("oai-events", DataChannelInit::default())?;
        let channel_closed = closed.clone();
        channel.on_state_change(Some(Box::new(move |state| {
            if state == DataChannelState::Closed {
                let _ = channel_closed.try_send(());
            }
        })));
        let (messages, incoming) = mpsc::channel(128);
        channel.on_message(Some(Box::new(move |message| {
            if !message.data.is_empty() && messages.try_send(message.data.to_vec()).is_err() {
                let _ = closed.try_send(());
            }
        })));

        let offer = gather_offer(peer).await?;
        let answer = request_answer(call.gateway, call.profile, offer, history).await?;
        peer.set_remote_description(
            SessionDescription::parse(&answer, SdpType::Answer)
                .map_err(|_| anyhow::anyhow!("{}", tr("语音连接失败")))?,
        )
        .await?;

        let handling = handle_messages(
            call,
            incoming,
            move |message| {
                let result = channel
                    .send(message.to_string().as_bytes(), false)
                    .map_err(|_| TransportLost(tr("语音数据通道已关闭")).into());
                std::future::ready(result)
            },
            move |muted| {
                mic.set_enabled(!muted);
            },
        );
        let receiving = async {
            let track = remote.recv().await.context(tr("语音连接已断开"))?;
            let mut audio = NativeAudioStream::new(track, 48_000, 1);
            // The platform audio device plays the track. Only inspect its decoded samples here.
            let mut speaking = false;
            let mut quiet = 0;
            while let Some(frame) = audio.next().await {
                let loud = frame.data.iter().any(|&sample| sample.unsigned_abs() > 786);
                quiet = if loud { 0 } else { quiet + 1 };
                let next = loud || (speaking && quiet < 30);
                if next != speaking {
                    speaking = next;
                    let phase = if next {
                        Phase::Speaking
                    } else {
                        Phase::Listening
                    };
                    let _ = events.try_send(Event::Phase(phase));
                }
            }
            Err(TransportLost(tr("语音连接已断开")).into())
        };
        let data_channel_closed = async {
            let _ = ended.recv().await;
            // Let the service's final event reach the handler before treating this as transport loss.
            tokio::time::sleep(Duration::from_millis(180)).await;
            Err(TransportLost(tr("语音数据通道已关闭")).into())
        };
        tokio::select! {
            result = handling => result,
            result = receiving => result,
            result = monitor_connection(state, |state| match state {
                PeerConnectionState::Failed | PeerConnectionState::Closed => ConnectionState::Closed,
                PeerConnectionState::Disconnected => ConnectionState::Disconnected,
                _ => ConnectionState::Connected,
            }) => result,
            result = data_channel_closed => result,
            () = update_input_meter(peer, &input, events) => Ok(()),
        }
    }
}

async fn update_input_meter(
    peer: &PeerConnection,
    input: &watch::Receiver<crate::voice::InputControl>,
    events: &mpsc::Sender<Event>,
) {
    let mut interval = tokio::time::interval(Duration::from_millis(160));
    interval.set_missed_tick_behavior(MissedTickBehavior::Skip);
    loop {
        interval.tick().await;
        if input.borrow().muted {
            continue;
        }
        if let Ok(stats) = peer.get_stats().await
            && let Some(level) = stats.iter().find_map(|stat| match stat {
                RtcStats::MediaSource(source) if source.source.kind == "audio" => {
                    Some((source.audio.audio_level as f32 * 7.).clamp(0., 1.))
                }
                _ => None,
            })
        {
            let _ = events.try_send(Event::Level(level));
        }
    }
}

async fn gather_offer(peer: &PeerConnection) -> Result<String> {
    let (candidates, mut gathered) = mpsc::unbounded_channel();
    peer.on_ice_candidate(Some(Box::new(move |candidate| {
        let _ = candidates.send((candidate.sdp_mline_index(), candidate.to_string()));
    })));
    let (ready, mut ice) = watch::channel(false);
    peer.on_ice_gathering_state_change(Some(Box::new(move |state| {
        if state == IceGatheringState::Complete {
            ready.send_replace(true);
        }
    })));
    let offer = peer
        .create_offer(OfferOptions {
            offer_to_receive_audio: true,
            ..Default::default()
        })
        .await?;
    let sdp = offer.to_string();
    peer.set_local_description(offer).await?;
    tokio::time::timeout(Duration::from_secs(10), ice.wait_for(|ready| *ready))
        .await
        .context(tr("语音连接超时"))??;
    peer.on_ice_candidate(None);
    peer.on_ice_gathering_state_change(None);

    // The binding exposes the committed description, which is unavailable until the answer.
    let mut sections = sdp.split("\r\nm=");
    let mut offer = sections.next().unwrap_or_default().to_owned();
    let gathered: Vec<_> = std::iter::from_fn(|| gathered.try_recv().ok()).collect();
    for (index, section) in sections.enumerate() {
        offer.push_str("\r\nm=");
        offer.push_str(section.trim_end_matches("\r\n"));
        for (_, candidate) in gathered.iter().filter(|(line, _)| *line == index as i32) {
            offer.push_str("\r\na=");
            offer.push_str(candidate.trim_start_matches("a=").trim_end());
        }
    }
    offer.push_str("\r\n");
    Ok(offer)
}
