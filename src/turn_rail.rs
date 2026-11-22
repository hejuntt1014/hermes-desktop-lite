use crate::theme::{ink, rgba};

use std::{collections::BTreeMap, time::Instant};

use gpui::{
    Context, Div, Entity, FocusHandle, KeyDownEvent, ListOffset, MouseMoveEvent, Pixels, Point,
    Render, ScrollEvent, ScrollHandle, Stateful, StyleRefinement, WeakEntity, Window, div,
    prelude::*, px,
};

use crate::style::ACCENT;

use super::Desktop;

const TICK_HEIGHT: f32 = 7.;
const RAIL_WIDTH: f32 = 48.;
const SCROLLBAR_GUTTER: f32 = 16.;
pub(super) const RAIL_GUTTER: f32 = RAIL_WIDTH + SCROLLBAR_GUTTER;
const TICK_INSET: f32 = 4.;
const BAR_WIDTH: f32 = 8.;
const PREVIEW_HEIGHT: f32 = 25.;

pub(super) struct TurnRail {
    pub focus: FocusHandle,
    prior_focus: Option<FocusHandle>,
    pub active: Option<usize>,
    pub jumped: Option<usize>,
    view: Entity<RailView>,
}

impl TurnRail {
    pub fn new(cx: &mut Context<Desktop>) -> Self {
        let owner = cx.entity().downgrade();
        let view = cx.new(|_| RailView::new(owner));
        Self {
            focus: cx.focus_handle(),
            prior_focus: None,
            active: None,
            jumped: None,
            view,
        }
    }

    pub fn reset(&mut self) {
        self.active = None;
        self.jumped = None;
        self.prior_focus = None;
    }
}

impl Desktop {
    pub(super) fn sync_turn_rail(&mut self) -> bool {
        let active = if self.turns.is_empty() {
            None
        } else if let Some(chosen) = self
            .turn_rail
            .jumped
            .filter(|index| *index < self.turns.len())
        {
            Some(chosen)
        } else if self.following {
            Some(self.turns.len() - 1)
        } else {
            let top = self.list.logical_scroll_top().item_ix;
            Some(
                self.turns
                    .partition_point(|turn| turn.item <= top)
                    .saturating_sub(1),
            )
        };
        let changed = active != self.turn_rail.active;
        self.turn_rail.active = active;
        changed
    }

    pub(super) fn focus_turn_rail(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.turns.is_empty()
            || !self.settings.display.turn_rail
            || self.settings_open
            || self.files.open
            || self.review.open
            || self.media.is_open()
        {
            return;
        }
        if !self.turn_rail.focus.is_focused(window) {
            self.turn_rail.prior_focus = window.focused(cx);
            self.turn_rail.focus.focus(window, cx);
        }
        self.turn_rail.view.update(cx, |view, cx| {
            view.reveal_active = true;
            cx.notify();
        });
        cx.notify();
    }

    pub(super) fn release_turn_rail(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.turn_rail.focus.is_focused(window) {
            self.turn_rail
                .prior_focus
                .take()
                .unwrap_or_else(|| self.workspace_focus.clone())
                .focus(window, cx);
            cx.notify();
        }
    }

    fn jump_to_turn(&mut self, index: usize, window: &mut Window, cx: &mut Context<Self>) {
        let Some(turn) = self.turns.get(index) else {
            return;
        };
        self.following = false;
        self.list.scroll_to(ListOffset {
            item_ix: turn.item,
            offset_in_item: px(0.),
        });
        self.turn_rail.jumped = Some(index);
        self.reading_moved(cx);
        self.sync_turn_rail();
        self.focus_turn_rail(window, cx);
    }

    fn rail_key(&mut self, event: &KeyDownEvent, window: &mut Window, cx: &mut Context<Self>) {
        if !self.turn_rail.focus.is_focused(window) || self.turns.is_empty() {
            return;
        }
        let active = self.turn_rail.active.unwrap_or(0).min(self.turns.len() - 1);
        let next = match event.keystroke.key.as_str() {
            "up" => active.saturating_sub(1),
            "down" => (active + 1).min(self.turns.len() - 1),
            "home" => 0,
            "end" => self.turns.len() - 1,
            "escape" => {
                cx.stop_propagation();
                self.release_turn_rail(window, cx);
                return;
            }
            _ => return,
        };
        cx.stop_propagation();
        self.jump_to_turn(next, window, cx);
    }

    pub(super) fn turn_rail_element(&self) -> Option<impl IntoElement + use<>> {
        (!self.turns.is_empty()).then(|| {
            self.turn_rail.view.clone().cached(
                StyleRefinement::default()
                    .absolute()
                    .right(px(SCROLLBAR_GUTTER))
                    .top_0()
                    .bottom_0()
                    .w(px(RAIL_WIDTH)),
            )
        })
    }
}

struct RailView {
    owner: WeakEntity<Desktop>,
    track: ScrollHandle,
    offset: f32,
    pointer: Option<Point<Pixels>>,
    entered_at: Instant,
    revision: Option<u64>,
    active: Option<usize>,
    reveal_active: bool,
    widths: BTreeMap<usize, Transition>,
    preview: Option<Transition>,
    preview_opacity: Option<Transition>,
}

impl RailView {
    fn new(owner: WeakEntity<Desktop>) -> Self {
        Self {
            owner,
            track: ScrollHandle::new(),
            offset: 0.,
            pointer: None,
            entered_at: Instant::now(),
            revision: None,
            active: None,
            reveal_active: false,
            widths: BTreeMap::new(),
            preview: None,
            preview_opacity: None,
        }
    }

    fn update_pointer(&mut self, position: Option<Point<Pixels>>, cx: &mut Context<Self>) {
        if position == self.pointer {
            return;
        }
        if self.pointer.is_none() {
            self.entered_at = Instant::now();
        }
        self.pointer = position;
        if position.is_none() {
            self.preview = None;
            self.preview_opacity = None;
        }
        cx.notify();
    }

    fn preview_element(
        &mut self,
        data: &Desktop,
        hover: Option<f32>,
        height: f32,
        max_width: f32,
        now: Instant,
        still: bool,
    ) -> (Option<Div>, bool) {
        let Some(index) = hover.map(|hover| hover.round() as usize) else {
            return (None, false);
        };
        let Some(turn) = data.turns.get(index) else {
            return (None, false);
        };
        if !still && now.saturating_duration_since(self.entered_at).as_millis() < 135 {
            return (None, true);
        }
        let target = ((index as f32 + 0.5) * TICK_HEIGHT - self.offset).clamp(0., height);
        let motion = self
            .preview
            .get_or_insert_with(|| Transition::new(target, now));
        let (center, moving) = motion.retarget(target, now, 76., still);
        let fade = self
            .preview_opacity
            .get_or_insert_with(|| Transition::new(0., now));
        let (opacity, fading) = fade.retarget(1., now, 116., still);
        let preview = div()
            .absolute()
            .right(px(RAIL_WIDTH + 3. + (1. - opacity) * -4.))
            .top(px(center - PREVIEW_HEIGHT / 2.))
            .max_w(px(max_width))
            .h(px(PREVIEW_HEIGHT))
            .px_2()
            .flex()
            .items_center()
            .rounded(px(5.))
            .bg(rgba(0x282d32f6))
            .shadow_md()
            .opacity(opacity)
            .child(
                div()
                    .min_w_0()
                    .truncate()
                    .text_size(px(11.))
                    .line_height(px(15.))
                    .text_color(ink(0xf6f7f8))
                    .child(turn.preview.clone()),
            );
        (Some(preview), moving || fading)
    }
}

impl Render for RailView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let Some(owner) = self.owner.upgrade() else {
            return div();
        };
        let desktop = owner.read(cx);
        let count = desktop.turns.len();
        if count == 0 {
            return div();
        }
        let revision = desktop.view_revision;
        if self.revision != Some(revision) {
            self.revision = Some(revision);
            self.offset = 0.;
            self.active = None;
            self.pointer = None;
            self.widths.clear();
            self.preview = None;
            self.preview_opacity = None;
        }
        let bounds = self.track.bounds();
        let height = (count as f32 * TICK_HEIGHT)
            .min(f32::from(window.viewport_size().height) * 0.47)
            .max(TICK_HEIGHT);
        let limit = (count as f32 * TICK_HEIGHT - height).max(0.);
        let active = desktop.turn_rail.active;
        let focus = desktop.turn_rail.focus.clone();
        let focused = focus.is_focused(window);
        let pointer = self.pointer.filter(|position| bounds.contains(position));
        if let Some(index) = active
            && (self.reveal_active || (active != self.active && pointer.is_none()))
        {
            let start = index as f32 * TICK_HEIGHT;
            self.offset = self
                .offset
                .clamp((start + TICK_HEIGHT - height).max(0.), start);
        }
        self.reveal_active = false;
        self.active = active;
        self.offset = self.offset.clamp(0., limit);
        let hover = pointer.map(|position| {
            ((f32::from(position.y - bounds.top()) + self.offset) / TICK_HEIGHT - 0.5)
                .clamp(0., (count - 1) as f32)
        });
        let now = Instant::now();
        let still = cx.reduce_motion();
        let first = (self.offset / TICK_HEIGHT).floor() as usize;
        let last = (((self.offset + height) / TICK_HEIGHT).ceil() as usize).min(count);
        self.widths.retain(|index, _| (first..last).contains(index));
        let mut animate = false;
        let mut ticks = Vec::with_capacity(last - first);
        for index in first..last {
            let current = active == Some(index);
            let target = hover.map_or(BAR_WIDTH, |peak| {
                let focus_weight = bell(index as f32 - peak);
                let active_weight = active.map_or(0., |active| bell(index as f32 - active as f32));
                BAR_WIDTH * (1. + focus_weight.max(active_weight))
            });
            let transition = self
                .widths
                .entry(index)
                .or_insert_with(|| Transition::new(BAR_WIDTH, now));
            let (width, moving) = transition.retarget(target, now, 180., still);
            animate |= moving;
            ticks.push(tick(
                index,
                index as f32 * TICK_HEIGHT - self.offset,
                width,
                current,
                focused && hover.is_none(),
                desktop.turns[index].preview.clone(),
                revision,
                self.owner.clone(),
            ));
        }
        let conversation = f32::from(window.viewport_size().width)
            - if desktop.sidebar_open {
                desktop.sidebar_width(window)
            } else {
                0.
            };
        let max_width = (conversation - RAIL_WIDTH - SCROLLBAR_GUTTER - 20.).clamp(40., 350.);
        let (preview, moving) = self.preview_element(desktop, hover, height, max_width, now, still);
        if animate || moving {
            window.request_animation_frame();
        }

        let keyboard_owner = self.owner.clone();
        div().size_full().flex().items_center().child(
            div()
                .relative()
                .h(px(height))
                .w_full()
                .children(preview)
                .child(
                    div()
                        .id("turn-timeline")
                        .relative()
                        .size_full()
                        .overflow_hidden()
                        .tab_index(0)
                        .track_focus(&focus)
                        .track_scroll(&self.track)
                        .on_key_down(move |event, window, app| {
                            let _ = keyboard_owner.update(app, |desktop, cx| {
                                desktop.rail_key(event, window, cx);
                            });
                        })
                        .on_hover(cx.listener(|this, inside: &bool, window, cx| {
                            this.update_pointer(inside.then(|| window.mouse_position()), cx);
                        }))
                        .on_mouse_move(cx.listener(|this, event: &MouseMoveEvent, _, cx| {
                            this.update_pointer(Some(event.position), cx);
                        }))
                        .on_scroll(cx.listener(move |this, event: &ScrollEvent, _, cx| {
                            let delta = f32::from(event.delta.pixel_delta(px(11.)).y);
                            if delta != 0. {
                                cx.stop_propagation();
                                this.offset = (this.offset - delta).clamp(0., limit);
                                this.update_pointer(Some(event.position), cx);
                                cx.notify();
                            }
                        }))
                        .children(ticks),
                ),
        )
    }
}

fn tick(
    index: usize,
    top: f32,
    width: f32,
    current: bool,
    keyboard_focus: bool,
    label: gpui::SharedString,
    revision: u64,
    owner: WeakEntity<Desktop>,
) -> Stateful<Div> {
    div()
        .id(("turn-tick", index))
        .aria_label(label)
        .absolute()
        .top(px(top))
        .left_0()
        .right_0()
        .h(px(TICK_HEIGHT))
        .pr(px(TICK_INSET))
        .flex()
        .items_center()
        .justify_end()
        .cursor_pointer()
        .when(current && keyboard_focus, |tick| {
            tick.rounded(px(3.)).bg(rgba(0x185aff11))
        })
        .child(
            div()
                .rounded_full()
                .w(px(width))
                .h(px(if current { 1.5 } else { 1. }))
                .bg(if current {
                    rgba((ACCENT << 8) | 0xff)
                } else {
                    rgba(0x78818da6)
                }),
        )
        .on_click(move |_, window, app| {
            let _ = owner.update(app, |desktop, cx| {
                if desktop.view_revision == revision {
                    desktop.jump_to_turn(index, window, cx);
                }
            });
        })
}

fn bell(distance: f32) -> f32 {
    if distance.abs() > 3. {
        0.
    } else {
        (-distance * distance / 1.35).exp()
    }
}

struct Transition {
    from: f32,
    to: f32,
    started: Instant,
}

impl Transition {
    fn new(value: f32, now: Instant) -> Self {
        Self {
            from: value,
            to: value,
            started: now,
        }
    }

    fn retarget(
        &mut self,
        target: f32,
        now: Instant,
        duration_ms: f32,
        still: bool,
    ) -> (f32, bool) {
        if still {
            *self = Self::new(target, now);
            return (target, false);
        }
        let t = (now.saturating_duration_since(self.started).as_secs_f32() * 1000. / duration_ms)
            .min(1.);
        let value = self.to + (self.from - self.to) * (1. - t).powi(3);
        if (self.to - target).abs() >= 0.015 {
            *self = Self {
                from: value,
                to: target,
                started: now,
            };
            return (value, true);
        }
        (value, t < 1. && (self.to - self.from).abs() >= 0.015)
    }
}
