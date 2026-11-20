use super::{TimelineItem, at_bottom, splice_older_page};
use gpui::{ListAlignment, ListOffset, ListState, px};

fn items(count: usize) -> Vec<TimelineItem> {
    (0..count)
        .map(|i| TimelineItem {
            rows: i..i + 1,
            receipt: None,
        })
        .collect()
}

#[test]
fn repeated_prepends_keep_the_same_message_and_pixel_with_unmeasured_rows() {
    let state = ListState::new(80, ListAlignment::Top, px(260.));
    let mut timeline = items(80);
    for _ in 0..3 {
        state.scroll_to(ListOffset {
            item_ix: 2,
            offset_in_item: px(1725.),
        });
        let next = items(timeline.len() + 79);
        assert!(splice_older_page(&state, &timeline, &next, 79));
        assert_eq!(
            state.logical_scroll_top(),
            ListOffset {
                item_ix: 81,
                offset_in_item: px(1725.)
            }
        );
        assert!(!at_bottom(&state));
        timeline = next;
    }
}

#[cfg(windows)]
#[test]
#[ignore = "requires a Windows graphics session"]
fn wheel_crosses_three_pages_without_following_the_tail() {
    use gpui::{
        Context, IntoElement, PlatformInput, Render, ScrollDelta, ScrollEvent, Window,
        WindowOptions, div, list, point, prelude::*,
    };
    use std::{cell::Cell, rc::Rc};

    struct Chat {
        list: ListState,
        timeline: Vec<TimelineItem>,
        pages: usize,
        following: bool,
    }

    impl Render for Chat {
        fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
            div()
                .w(px(360.))
                .h(px(260.))
                .on_scroll(cx.listener(|chat, event: &ScrollEvent, _, cx| {
                    let y = event.delta.pixel_delta(px(20.)).y;
                    let Some(nav) = super::wheel_navigation(&chat.list, y) else {
                        return;
                    };
                    chat.following = nav.following;
                    let top = chat.list.logical_scroll_top();
                    if nav.load_older && chat.pages < 3 {
                        let next = items(chat.timeline.len() + 79);
                        assert!(splice_older_page(&chat.list, &chat.timeline, &next, 79));
                        let anchored = chat.list.logical_scroll_top();
                        assert_eq!(anchored.item_ix, top.item_ix + 79);
                        assert_eq!(anchored.offset_in_item, top.offset_in_item);
                        chat.timeline = next;
                        chat.pages += 1;
                    }
                    cx.notify();
                }))
                .child(
                    list(self.list.clone(), |_, _, _| {
                        div().w_full().h(px(45.)).into_any_element()
                    })
                    .with_sizing_behavior(gpui::ListSizingBehavior::Auto)
                    .w(px(360.))
                    .h(px(260.)),
                )
        }
    }

    let completed = Rc::new(Cell::new(false));
    let success = completed.clone();
    gpui_platform::application().run(move |cx| {
        let handle = cx
            .open_window(
                WindowOptions {
                    window_bounds: Some(gpui::WindowBounds::Windowed(gpui::Bounds::new(
                        point(px(0.), px(0.)),
                        gpui::size(px(360.), px(260.)),
                    ))),
                    show: true,
                    focus: false,
                    ..Default::default()
                },
                |_, cx| {
                    cx.new(|_| Chat {
                        list: ListState::new(80, ListAlignment::Top, px(260.)),
                        timeline: items(80),
                        pages: 0,
                        following: true,
                    })
                },
            )
            .unwrap();
        let chat = handle.entity(cx).unwrap();
        gpui::AnyWindowHandle::from(handle)
            .update(cx, |_, window, cx| {
                assert!(
                    window.viewport_size().height > px(0.),
                    "empty native viewport {:?}",
                    window.viewport_size()
                );
                chat.read(cx).list.scroll_to_end();
                window.refresh();
                window.draw(cx).clear(cx);
                let viewport = chat.read(cx).list.viewport_bounds();
                assert!(viewport.size.height > px(0.), "unlaid list: {viewport:?}");
                let mut previous = chat.read(cx).list.logical_scroll_top().item_ix as isize;
                for _ in 0..300 {
                    window.dispatch_event(
                        PlatformInput::Scroll(ScrollEvent {
                            position: viewport.center(),
                            delta: ScrollDelta::Pixels(point(px(0.), px(70.))),
                            ..Default::default()
                        }),
                        cx,
                    );
                    window.draw(cx).clear(cx);
                    let view = chat.read(cx);
                    assert!(
                        !view.following,
                        "wheel at {:?}, top {:?}, previous {previous}, viewport {viewport:?}",
                        window.mouse_position(),
                        view.list.logical_scroll_top()
                    );
                    let logical = view.list.logical_scroll_top().item_ix as isize
                        - (view.pages * 79) as isize;
                    assert!(
                        logical <= previous,
                        "wheel jumped from {previous} to {logical}"
                    );
                    previous = logical;
                    if view.pages == 3 {
                        break;
                    }
                }
                assert_eq!(chat.read(cx).pages, 3);
                for _ in 0..400 {
                    window.dispatch_event(
                        PlatformInput::Scroll(ScrollEvent {
                            position: viewport.center(),
                            delta: ScrollDelta::Pixels(point(px(0.), px(-100.))),
                            ..Default::default()
                        }),
                        cx,
                    );
                    window.draw(cx).clear(cx);
                    if chat.read(cx).following {
                        break;
                    }
                }
                assert!(
                    chat.read(cx).following,
                    "scrolling to the last message should resume following"
                );
            })
            .unwrap();
        success.set(true);
        cx.quit();
    });
    assert!(completed.get());
}
