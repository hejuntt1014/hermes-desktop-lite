use std::{collections::VecDeque, io::Cursor, time::Duration};

use anyhow::{Context, Result, bail};
use cpal::{
    FromSample, Sample, SampleFormat, SizedSample, Stream, StreamConfig,
    traits::{DeviceTrait, HostTrait, StreamTrait},
};
use tokio::sync::{mpsc, watch};

use crate::i18n::text as tr;
use crate::voice::{InputControl, Meter};

pub struct Microphone {
    _stream: Stream,
    frames: mpsc::Receiver<Vec<f32>>,
    errors: mpsc::UnboundedReceiver<cpal::StreamError>,
    source_rate: u32,
    target_rate: u32,
    phase: u32,
}

impl Microphone {
    pub fn open(target_rate: u32) -> Result<Self> {
        let device = cpal::default_host()
            .default_input_device()
            .context(tr("找不到麦克风"))?;
        let supported = device.default_input_config()?;
        let config = supported.config();
        let (send, frames) = mpsc::channel(32);
        let (report_error, errors) = mpsc::unbounded_channel();
        let stream = match supported.sample_format() {
            SampleFormat::F32 => input::<f32>(&device, &config, send, report_error),
            SampleFormat::F64 => input::<f64>(&device, &config, send, report_error),
            SampleFormat::I8 => input::<i8>(&device, &config, send, report_error),
            SampleFormat::I16 => input::<i16>(&device, &config, send, report_error),
            SampleFormat::I24 => input::<cpal::I24>(&device, &config, send, report_error),
            SampleFormat::I32 => input::<i32>(&device, &config, send, report_error),
            SampleFormat::I64 => input::<i64>(&device, &config, send, report_error),
            SampleFormat::U8 => input::<u8>(&device, &config, send, report_error),
            SampleFormat::U16 => input::<u16>(&device, &config, send, report_error),
            SampleFormat::U32 => input::<u32>(&device, &config, send, report_error),
            SampleFormat::U64 => input::<u64>(&device, &config, send, report_error),
            _ => bail!("{}", tr("麦克风的音频格式不受支持")),
        }?;
        stream.play()?;
        Ok(Self {
            _stream: stream,
            frames,
            errors,
            source_rate: config.sample_rate.0,
            target_rate,
            phase: 0,
        })
    }

    pub async fn next(&mut self) -> Result<Vec<f32>> {
        let frames = tokio::select! {
            Some(error) = self.errors.recv() => return Err(error.into()),
            frames = self.frames.recv() => frames.context(tr("麦克风已断开"))?,
        };
        let mut samples = Vec::new();
        for sample in frames {
            self.phase += self.target_rate;
            while self.phase >= self.source_rate {
                self.phase -= self.source_rate;
                samples.push(sample);
            }
        }
        Ok(samples)
    }
}

fn input<T: SizedSample>(
    device: &cpal::Device,
    config: &StreamConfig,
    audio: mpsc::Sender<Vec<f32>>,
    errors: mpsc::UnboundedSender<cpal::StreamError>,
) -> Result<Stream, cpal::BuildStreamError>
where
    f32: FromSample<T>,
{
    let channels = usize::from(config.channels);
    device.build_input_stream(
        config,
        move |frames: &[T], _| {
            let samples = frames
                .chunks_exact(channels)
                .map(|frame| {
                    frame
                        .iter()
                        .map(|sample| sample.to_sample::<f32>())
                        .sum::<f32>()
                        / channels as f32
                })
                .collect();
            let _ = audio.try_send(samples);
        },
        move |error| {
            let _ = errors.send(error);
        },
        None,
    )
}

const STT_RATE: u32 = 16_000;

pub async fn record_utterance(
    mic: &mut Microphone,
    input: &mut watch::Receiver<InputControl>,
    meter: &mut Meter<'_>,
) -> Result<Option<Vec<f32>>> {
    const FRAME: usize = STT_RATE as usize / 50;
    const MAX: usize = STT_RATE as usize * 45;
    let mut pending = VecDeque::new();
    let mut preroll = VecDeque::with_capacity(15);
    let mut audio = Vec::new();
    let mut quiet = 0;
    let mut voiced = 0;
    loop {
        tokio::select! {
            frames = mic.next() => {
                let frames = frames?;
                meter.measure(&frames);
                pending.extend(frames);
            }
            changed = input.changed() => {
                if changed.is_err() || input.borrow_and_update().muted {
                    return Ok(None);
                }
                if audio.is_empty() {
                    audio.extend(preroll.drain(..).flatten());
                }
                audio.extend(pending);
                return Ok(Some(audio));
            }
        }
        while pending.len() >= FRAME {
            let frame: Vec<_> = pending.drain(..FRAME).collect();
            let rms =
                (frame.iter().map(|sample| sample * sample).sum::<f32>() / FRAME as f32).sqrt();
            let loud = rms > 0.014;
            if audio.is_empty() {
                if preroll.len() == 15 {
                    preroll.pop_front();
                }
                preroll.push_back(frame);
                voiced = if loud { voiced + 1 } else { 0 };
                if voiced >= 3 {
                    audio.extend(preroll.drain(..).flatten());
                }
            } else {
                audio.extend(frame);
                quiet = if loud { 0 } else { quiet + 1 };
                if quiet >= 40 || audio.len() >= MAX {
                    return Ok(Some(audio));
                }
            }
        }
    }
}

pub fn wav(samples: &[f32]) -> Vec<u8> {
    let size = (samples.len() * 2) as u32;
    let mut bytes = Vec::with_capacity(44 + size as usize);
    bytes.extend(b"RIFF");
    bytes.extend((36 + size).to_le_bytes());
    bytes.extend(b"WAVEfmt ");
    bytes.extend(16u32.to_le_bytes()); // PCM fmt chunk length
    bytes.extend(1u16.to_le_bytes()); // PCM
    bytes.extend(1u16.to_le_bytes()); // mono
    bytes.extend(STT_RATE.to_le_bytes());
    bytes.extend((STT_RATE * 2).to_le_bytes());
    bytes.extend(2u16.to_le_bytes());
    bytes.extend(16u16.to_le_bytes());
    bytes.extend(b"data");
    bytes.extend(size.to_le_bytes());
    bytes.extend(
        samples
            .iter()
            .flat_map(|sample| sample.to_sample::<i16>().to_le_bytes()),
    );
    bytes
}

pub async fn record_until<T>(
    finish: &mut mpsc::Receiver<T>,
    mic: &mut Microphone,
    meter: &mut Meter<'_>,
) -> Result<Vec<f32>> {
    let mut audio = Vec::new();
    let deadline = tokio::time::sleep(Duration::from_secs(120));
    tokio::pin!(deadline);
    loop {
        tokio::select! {
            frames = mic.next() => {
                let frames = frames?;
                meter.measure(&frames);
                audio.extend(frames);
            }
            _ = finish.recv() => return Ok(audio),
            _ = &mut deadline => return Ok(audio),
        }
    }
}

pub async fn play(bytes: Vec<u8>) -> Result<()> {
    let stream = rodio::OutputStreamBuilder::open_default_stream()?;
    let output = rodio::Sink::connect_new(stream.mixer());
    if bytes.starts_with(b"OggS") && bytes.get(28..36) == Some(b"OpusHead") {
        let pcm = decode_ogg_opus(&bytes)?;
        output.append(rodio::buffer::SamplesBuffer::new(1, 48_000, pcm));
    } else {
        output.append(rodio::Decoder::try_from(Cursor::new(bytes))?);
    }
    while !output.empty() {
        tokio::time::sleep(Duration::from_millis(30)).await;
    }
    Ok(())
}

fn decode_ogg_opus(bytes: &[u8]) -> Result<Vec<f32>> {
    let mut reader = ogg::PacketReader::new(Cursor::new(bytes));
    let header = reader.read_packet()?.context("Missing Opus header")?;
    let serial = header.stream_serial();
    let skip = header.data.get(10..12).context("Incomplete Opus header")?;
    let mut skip = u16::from_le_bytes([skip[0], skip[1]]) as usize;
    let mut decoder = opus::Decoder::new(48_000, opus::Channels::Mono)?;
    let mut samples = [0f32; 5760];
    let mut pcm = Vec::new();
    while let Some(packet) = reader.read_packet()? {
        if packet.stream_serial() != serial || packet.data.starts_with(b"OpusTags") {
            continue;
        }
        let len = decoder.decode_float(&packet.data, &mut samples, false)?;
        let offset = skip.min(len);
        skip -= offset;
        pcm.extend_from_slice(&samples[offset..len]);
        if pcm.len() > 48_000 * 600 {
            bail!("{}", tr("语音回复过长"));
        }
        if packet.last_in_stream() {
            break;
        }
    }
    Ok(pcm)
}
