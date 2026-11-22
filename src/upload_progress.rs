use std::{
    collections::VecDeque,
    path::PathBuf,
    time::{Duration, Instant},
};

use tokio::sync::watch;

const SPEED_WINDOW: Duration = Duration::from_secs(3);
const MIN_SPEED_SAMPLE: Duration = Duration::from_millis(500);
const DISPLAY_INTERVAL: Duration = Duration::from_millis(120);

#[derive(Clone, Copy)]
pub(crate) enum Stage {
    Preparing,
    Sending {
        sent: u64,
        total: u64,
        rate: Option<f64>,
        sampled_at: Instant,
    },
    Awaiting {
        bytes: u64,
    },
}

impl Stage {
    pub(crate) fn speed_label(self) -> Option<String> {
        let Self::Sending {
            rate: Some(rate), ..
        } = self
        else {
            return None;
        };
        (!self.waiting_for_network()).then(|| format!("{}/s", size_label(rate.round() as u64)))
    }

    pub(crate) fn waiting_for_network(self) -> bool {
        matches!(self, Self::Sending { sampled_at, .. } if sampled_at.elapsed() >= SPEED_WINDOW)
    }

    pub(crate) fn speed_expires_in(self) -> Option<Duration> {
        let Self::Sending { sampled_at, .. } = self else {
            return None;
        };
        SPEED_WINDOW
            .checked_sub(sampled_at.elapsed())
            .filter(|remaining| !remaining.is_zero())
    }
}

#[derive(Clone)]
pub(crate) struct Reporter {
    sender: watch::Sender<Stage>,
    samples: VecDeque<(Instant, u64)>,
}

impl Reporter {
    pub(crate) fn new() -> (Self, watch::Receiver<Stage>) {
        let (sender, receiver) = watch::channel(Stage::Preparing);
        (
            Self {
                sender,
                samples: VecDeque::new(),
            },
            receiver,
        )
    }

    pub(crate) fn sending(&mut self, sent: u64, total: u64) {
        let now = Instant::now();
        if self
            .samples
            .back()
            .is_some_and(|(at, _)| now.duration_since(*at) < DISPLAY_INTERVAL)
        {
            return;
        }

        // Keep one sample at or before the window boundary so gaps count toward the rate.
        while self
            .samples
            .get(1)
            .is_some_and(|(at, _)| now.duration_since(*at) >= SPEED_WINDOW)
        {
            self.samples.pop_front();
        }
        let rate = self.samples.front().and_then(|(first, first_sent)| {
            let elapsed = now.duration_since(*first);
            (elapsed >= MIN_SPEED_SAMPLE)
                .then(|| sent.saturating_sub(*first_sent) as f64 / elapsed.as_secs_f64())
        });
        self.samples.push_back((now, sent));
        self.sender.send_replace(Stage::Sending {
            sent,
            total,
            rate,
            sampled_at: now,
        });
    }

    pub(crate) fn preparing(&self) {
        self.sender.send_replace(Stage::Preparing);
    }

    pub(crate) fn awaiting(&self, bytes: u64) {
        self.sender.send_replace(Stage::Awaiting { bytes });
    }
}

#[derive(Clone)]
pub(crate) struct Cancel(watch::Sender<bool>);

impl Cancel {
    pub(crate) fn new() -> Self {
        Self(watch::channel(false).0)
    }

    pub(crate) fn cancel(&self) {
        self.0.send_replace(true);
    }

    pub(crate) fn is_cancelled(&self) -> bool {
        *self.0.borrow()
    }

    pub(crate) async fn cancelled(&self) {
        let mut receiver = self.0.subscribe();
        let _ = receiver.wait_for(|cancelled| *cancelled).await;
    }
}

pub(crate) struct Display {
    pub cancel: Cancel,
    pub path: PathBuf,
    pub number: usize,
    pub count: usize,
    pub started: Instant,
    pub state: watch::Receiver<Stage>,
    pub _repaint: gpui::Task<()>,
}

pub(crate) fn size_label(bytes: u64) -> String {
    for (unit, scale) in [("GB", 1_000_000_000), ("MB", 1_000_000), ("KB", 1_000)] {
        if bytes >= scale {
            return format!("{:.1} {unit}", bytes as f64 / scale as f64);
        }
    }
    format!("{bytes} B")
}
