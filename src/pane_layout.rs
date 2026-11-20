use crate::theme::rgb;

use crate::i18n::text as tr;

use gpui::{
    App, Bounds, Context, Div, MouseButton, MouseDownEvent, MouseMoveEvent, Stateful, Window,
    WindowBounds, div, point, prelude::*, px, size,
};
use gpui_component::tooltip::Tooltip;

use crate::settings::SavedWindow;

use super::Desktop;

pub(super) const DIVIDER: f32 = 5.;

pub(super) fn workspace_dialog_size(window: &Window) -> gpui::Size<gpui::Pixels> {
    let view = window.viewport_size();
    size(
        (view.width - px(56.)).min(px(1090.)),
        (view.height - px(105.)).min(px(770.)),
    )
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum Pane {
    Sessions,
    Files,
}

#[derive(Clone, Copy)]
pub(super) struct PaneResize {
    pane: Pane,
    start: f32,
    width: f32,
}

pub(crate) fn initial_window_bounds(saved: Option<SavedWindow>, cx: &App) -> WindowBounds {
    let fallback = || Bounds::centered(None, size(px(1080.), px(720.)), cx);
    let Some(saved) = saved.filter(|saved| {
        [saved.x, saved.y, saved.width, saved.height]
            .into_iter()
            .all(f32::is_finite)
            && (540.0..=10_000.0).contains(&saved.width)
            && (420.0..=10_000.0).contains(&saved.height)
    }) else {
        return WindowBounds::Windowed(fallback());
    };
    let restored = Bounds::new(
        point(px(saved.x), px(saved.y)),
        size(px(saved.width), px(saved.height)),
    );
    let valid_title = Bounds::new(restored.origin, size(restored.size.width, px(33.)));
    let visible = cx.displays().into_iter().any(|display| {
        let area = valid_title.intersect(&display.bounds());
        area.size.width >= px(96.) && area.size.height >= px(18.)
    });
    let bounds = if visible {
        restored
    } else {
        let limit = cx
            .primary_display()
            .map(|display| display.bounds().size)
            .unwrap_or_else(|| fallback().size);
        Bounds::centered(None, restored.size.min(&limit), cx)
    };
    if saved.maximized {
        WindowBounds::Maximized(bounds)
    } else {
        WindowBounds::Windowed(bounds)
    }
}

impl Desktop {
    pub(super) fn record_window(&mut self, window: &Window) -> bool {
        let state = window.window_bounds();
        let bounds = state.get_bounds();
        if bounds.size.width < px(540.) || bounds.size.height < px(420.) {
            return false;
        }
        let saved = SavedWindow {
            x: f32::from(bounds.origin.x),
            y: f32::from(bounds.origin.y),
            width: f32::from(bounds.size.width),
            height: f32::from(bounds.size.height),
            maximized: matches!(state, WindowBounds::Maximized(_)),
        };
        if self.settings.window == Some(saved) {
            return false;
        }
        self.settings.window = Some(saved);
        true
    }

    pub(super) fn reveal_selected_tab(&self) {
        if let Some(index) = self.workspace().and_then(|workspace| {
            let active = workspace.active_tab.as_deref()?;
            workspace.tabs.iter().position(|tab| tab.id == active)
        }) {
            self.tab_scroll.scroll_to_item(index);
        }
    }

    pub(super) fn sidebar_width(&self, window: &Window) -> f32 {
        self.clamp_pane_width(
            Pane::Sessions,
            f32::from(self.settings.display.sidebar_width),
            window,
        )
    }

    pub(super) fn file_list_width(&self, window: &Window) -> f32 {
        let default = (f32::from(workspace_dialog_size(window).width) * 0.23).clamp(142., 255.);
        let desired = self
            .settings
            .display
            .file_list_width
            .map(f32::from)
            .unwrap_or(default);
        self.clamp_pane_width(Pane::Files, desired, window)
    }

    fn clamp_pane_width(&self, pane: Pane, desired: f32, window: &Window) -> f32 {
        let available = f32::from(window.viewport_size().width);
        let (min, max) = match pane {
            Pane::Sessions => (180., (available - 305. - DIVIDER).clamp(180., 420.)),
            Pane::Files => (
                140.,
                (f32::from(workspace_dialog_size(window).width) - 180. - DIVIDER).clamp(140., 490.),
            ),
        };
        desired.clamp(min, max)
    }

    pub(super) fn pane_divider(&self, pane: Pane, cx: &mut Context<Self>) -> Stateful<Div> {
        let dragging = self.pane_resize.is_some_and(|active| active.pane == pane);
        let (id, title) = match pane {
            Pane::Sessions => ("session-divider", tr("调整会话侧栏宽度，双击恢复默认")),
            Pane::Files => ("file-divider", tr("调整文件列表宽度，双击恢复默认")),
        };
        div()
            .id(id)
            .group(id)
            .h_full()
            .w(px(DIVIDER))
            .flex_none()
            .flex()
            .justify_center()
            .cursor_col_resize()
            .child(
                div()
                    .h_full()
                    .w(px(1.))
                    .bg(rgb(if dragging { 0x185aff } else { 0xe3e9f2 }))
                    .group_hover(id, |line| line.bg(rgb(0x729afa))),
            )
            .tooltip(move |window, cx| Tooltip::new(title).build(window, cx))
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(move |this, event: &MouseDownEvent, window, cx| {
                    cx.stop_propagation();
                    if event.click_count >= 2 {
                        this.pane_resize = None;
                        match pane {
                            Pane::Sessions => this.settings.display.sidebar_width = 237,
                            Pane::Files => this.settings.display.file_list_width = None,
                        }
                        this.finish_pane_layout(pane, cx);
                        return;
                    }
                    let width = match pane {
                        Pane::Sessions => this.sidebar_width(window),
                        Pane::Files => this.file_list_width(window),
                    };
                    this.pane_resize = Some(PaneResize {
                        pane,
                        start: f32::from(event.position.x),
                        width,
                    });
                    cx.notify();
                }),
            )
    }

    pub(super) fn move_pane(
        &mut self,
        event: &MouseMoveEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(resize) = self.pane_resize else {
            return;
        };
        if !event.dragging() {
            self.finish_pane_resize(cx);
            return;
        }
        let desired = resize.width + f32::from(event.position.x) - resize.start;
        let width = self.clamp_pane_width(resize.pane, desired, window).round() as u16;
        let changed = match resize.pane {
            Pane::Sessions if self.settings.display.sidebar_width != width => {
                self.settings.display.sidebar_width = width;
                true
            }
            Pane::Files if self.settings.display.file_list_width != Some(width) => {
                self.settings.display.file_list_width = Some(width);
                true
            }
            _ => false,
        };
        if changed {
            cx.notify();
        }
    }

    pub(super) fn finish_pane_resize(&mut self, cx: &mut Context<Self>) {
        if let Some(resize) = self.pane_resize.take() {
            self.finish_pane_layout(resize.pane, cx);
        }
    }

    fn finish_pane_layout(&mut self, pane: Pane, cx: &mut Context<Self>) {
        if pane == Pane::Sessions {
            self.remeasure_transcript();
            self.reveal_selected_tab();
        }
        self.persist(cx);
        cx.notify();
    }
}

pub(super) fn toggle_maximized(window: &Window) {
    if !cfg!(windows) || !window.is_maximized() {
        window.zoom_window();
        return;
    }

    #[cfg(windows)]
    {
        use raw_window_handle::{HasWindowHandle, RawWindowHandle};
        use windows_sys::Win32::{
            Foundation::HWND,
            UI::WindowsAndMessaging::{SW_RESTORE, ShowWindowAsync},
        };

        if let Ok(handle) = HasWindowHandle::window_handle(window)
            && let RawWindowHandle::Win32(handle) = handle.as_raw()
        {
            // GPUI keeps this HWND valid for the lifetime of the borrowed window.
            unsafe { ShowWindowAsync(handle.hwnd.get() as HWND, SW_RESTORE) };
        }
    }
}

pub(super) fn start_window_drag(window: &Window) {
    #[cfg(windows)]
    {
        use raw_window_handle::{HasWindowHandle, RawWindowHandle};
        use windows_sys::Win32::{
            Foundation::{HWND, POINT},
            UI::{
                Input::KeyboardAndMouse::ReleaseCapture,
                WindowsAndMessaging::{
                    GetCursorPos, HTCAPTION, PostMessageW, SC_MOVE, SC_RESTORE, WM_SYSCOMMAND,
                },
            },
        };
        if let Ok(handle) = HasWindowHandle::window_handle(window)
            && let RawWindowHandle::Win32(handle) = handle.as_raw()
        {
            let mut point = POINT::default();
            if unsafe { GetCursorPos(&mut point) } == 0 {
                return;
            }
            let position = (point.x as u16 as u32) | ((point.y as u16 as u32) << 16);
            // Let GPUI return from its mouse callback before Windows starts its move loop.
            let hwnd = handle.hwnd.get() as HWND;
            unsafe {
                ReleaseCapture();
                if window.is_maximized() {
                    PostMessageW(hwnd, WM_SYSCOMMAND, SC_RESTORE as usize, position as isize);
                }
                PostMessageW(
                    hwnd,
                    WM_SYSCOMMAND,
                    (SC_MOVE | HTCAPTION) as usize,
                    position as isize,
                );
            }
        }
    }
    #[cfg(not(windows))]
    window.start_window_move();
}

// X11 can honor Motif decoration hints even when it has no compositing manager.
// The app draws its own controls and resize edges without a translucent frame.
#[cfg(target_os = "linux")]
pub(super) fn enable_x11_client_chrome(window: &Window) -> bool {
    use raw_window_handle::{HasWindowHandle, RawWindowHandle};
    use x11rb::{
        connection::Connection,
        protocol::xproto::{ConnectionExt, PropMode},
        wrapper::ConnectionExt as _,
    };

    if matches!(
        window.window_decorations(),
        gpui::Decorations::Client { .. }
    ) {
        return false;
    }
    let Ok(handle) = HasWindowHandle::window_handle(window) else {
        return false;
    };
    let RawWindowHandle::Xcb(handle) = handle.as_raw() else {
        return false;
    };
    let change = || -> anyhow::Result<()> {
        let (connection, _) = x11rb::connect(None)?;
        let atom = connection
            .intern_atom(false, b"_MOTIF_WM_HINTS")?
            .reply()?
            .atom;
        // MWM_HINTS_DECORATIONS, with a zero decorations mask.
        connection
            .change_property32(
                PropMode::REPLACE,
                handle.window.get(),
                atom,
                atom,
                &[2, 0, 0, 0, 0],
            )?
            .check()?;
        // Some window managers read Motif hints only when the window is mapped.
        // GPUI has already mapped the window by the time its root view is created.
        connection.unmap_window(handle.window.get())?.check()?;
        connection.map_window(handle.window.get())?.check()?;
        connection.flush()?;
        Ok(())
    };
    change().is_ok()
}
