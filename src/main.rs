#![cfg_attr(all(windows, not(debug_assertions)), windows_subsystem = "windows")]

mod app;
mod auth;
mod background_notice;
mod command_receipt;
mod file_upload;
mod gateway;
mod i18n;
mod icons;
mod local_gateway;
mod media;
mod reasoning;
mod session;
mod session_activity;
mod session_colors;
mod session_todos;
mod settings;
mod style;
#[cfg(windows)]
mod terminal_appearance;
mod theme;
mod theme_package;
mod wallpapers;

use anyhow::Result;
use gpui::{AppContext, KeyBinding, Size, Styled, TitlebarOptions, WindowOptions, px};
use gpui_component::Root;

gpui::actions!(
    hermes_lite,
    [
        SendMessage,
        NewChat,
        CloseChatTab,
        ReopenChatTab,
        OpenTranscriptFind,
        CloseTranscriptFind,
        NextTranscriptHit,
        PreviousTranscriptHit,
        CloseImagePreview,
        PreviousPreviewImage,
        NextPreviewImage,
        FocusTurnRail,
        TogglePalette,
        ClosePalette,
        NextPalette,
        PreviousPalette,
        CommitPalette,
        NextChatTab,
        PreviousChatTab,
        ToggleSettings,
        CloseSettings,
        ToggleFiles,
        CloseFiles,
        ToggleReview,
        CloseReview,
        CloseCron,
        CloseProfileEditor,
        CloseSessionDialog,
        SaveProfileSoul,
        DeferClarify,
        SubmitClarify,
        CloseRewrite,
        SubmitRewrite,
        PreviousCompletion,
        NextCompletion,
        AcceptCompletion,
        CloseCompletion,
        CloseQueueEdit,
        SaveQueueEdit
    ]
);

fn main() -> Result<()> {
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()?;
    let handle = runtime.handle().clone();
    gpui_platform::application()
        .with_assets(icons::Icons)
        .run(move |cx| {
            #[cfg(not(windows))]
            cx.set_app_identity(
                "io.github.hejuntt1014.hermes-desktop-lite",
                "Hermes Desktop Lite",
            );
            let settings = settings::Settings::load();
            gpui_component::init(cx);
            i18n::apply(
                settings
                    .as_ref()
                    .map(|s| s.display.language)
                    .unwrap_or_default(),
            );
            if let Err(error) =
                cx.text_system()
                    .add_fonts(vec![std::borrow::Cow::Borrowed(include_bytes!(
                        "../assets/fonts/HermesLiteDisplay.ttf"
                    ))])
            {
                eprintln!("Could not load the Hermes Lite display font: {error}");
            }
            let (open_find, next_find, previous_find) = if cfg!(target_os = "macos") {
                ("cmd-f", "cmd-g", "cmd-shift-g")
            } else {
                ("ctrl-f", "ctrl-g", "ctrl-shift-g")
            };
            let (open_palette, alternate_palette) = if cfg!(target_os = "macos") {
                ("cmd-k", "cmd-p")
            } else {
                ("ctrl-k", "ctrl-p")
            };
            let mut palette_keys = Vec::new();
            for key in [open_palette, alternate_palette] {
                for context in [
                    "HermesLite",
                    "HermesComposer > Input",
                    "HermesFindInput > Input",
                    "HermesPaletteInput > Input",
                ] {
                    palette_keys.push(KeyBinding::new(key, TogglePalette, Some(context)));
                }
            }
            cx.bind_keys(palette_keys);
            let settings_key = if cfg!(target_os = "macos") {
                "cmd-,"
            } else {
                "ctrl-,"
            };
            cx.bind_keys([
                KeyBinding::new(settings_key, ToggleSettings, Some("HermesLite")),
                KeyBinding::new("escape", CloseSettings, Some("HermesSettingsOpen")),
                KeyBinding::new("escape", CloseSettings, Some("HermesSettings > Input")),
                KeyBinding::new("ctrl-tab", NextChatTab, Some("HermesLite")),
                KeyBinding::new("ctrl-shift-tab", PreviousChatTab, Some("HermesLite")),
                KeyBinding::new("escape", ClosePalette, Some("HermesPaletteOpen")),
                KeyBinding::new("enter", CommitPalette, Some("HermesPaletteInput > Input")),
                KeyBinding::new("down", NextPalette, Some("HermesPaletteInput > Input")),
                KeyBinding::new("up", PreviousPalette, Some("HermesPaletteInput > Input")),
                KeyBinding::new("alt-t", FocusTurnRail, Some("HermesLite")),
                KeyBinding::new("ctrl-shift-e", ToggleFiles, Some("HermesLite")),
                KeyBinding::new("escape", CloseFiles, Some("HermesFilesOpen")),
                KeyBinding::new("escape", CloseReview, Some("HermesReviewOpen")),
                KeyBinding::new("escape", CloseCron, Some("HermesCronOpen")),
                KeyBinding::new("escape", CloseCron, Some("HermesCronOpen > Input")),
                KeyBinding::new("escape", CloseProfileEditor, Some("HermesProfilesOpen")),
                KeyBinding::new("escape", CloseSessionDialog, Some("HermesSessionDialog")),
                KeyBinding::new(
                    "escape",
                    CloseSessionDialog,
                    Some("HermesSessionDialog > Input"),
                ),
                KeyBinding::new(
                    "escape",
                    CloseProfileEditor,
                    Some("HermesProfilesOpen > Input"),
                ),
                KeyBinding::new(
                    if cfg!(target_os = "macos") {
                        "cmd-s"
                    } else {
                        "ctrl-s"
                    },
                    SaveProfileSoul,
                    Some("HermesProfilesOpen"),
                ),
                KeyBinding::new(
                    if cfg!(target_os = "macos") {
                        "cmd-s"
                    } else {
                        "ctrl-s"
                    },
                    SaveProfileSoul,
                    Some("HermesProfilesOpen > Input"),
                ),
                KeyBinding::new("escape", CloseRewrite, Some("HermesRewriteOpen")),
                KeyBinding::new("escape", CloseRewrite, Some("HermesRewriteInput > Input")),
                KeyBinding::new("escape", CloseQueueEdit, Some("HermesQueueEditOpen")),
                KeyBinding::new("escape", CloseQueueEdit, Some("HermesQueueEditor > Input")),
                KeyBinding::new(
                    if cfg!(target_os = "macos") {
                        "cmd-enter"
                    } else {
                        "ctrl-enter"
                    },
                    SaveQueueEdit,
                    Some("HermesQueueEditor > Input"),
                ),
                KeyBinding::new(
                    if cfg!(target_os = "macos") {
                        "cmd-enter"
                    } else {
                        "ctrl-enter"
                    },
                    SubmitRewrite,
                    Some("HermesRewriteInput > Input"),
                ),
                KeyBinding::new("escape", DeferClarify, Some("HermesClarifyOpen")),
                KeyBinding::new("escape", DeferClarify, Some("HermesClarifyInput > Input")),
                KeyBinding::new(
                    if cfg!(target_os = "macos") {
                        "cmd-enter"
                    } else {
                        "ctrl-enter"
                    },
                    SubmitClarify,
                    Some("HermesClarifyOpen"),
                ),
                KeyBinding::new(
                    if cfg!(target_os = "macos") {
                        "cmd-enter"
                    } else {
                        "ctrl-enter"
                    },
                    SubmitClarify,
                    Some("HermesClarifyInput > Input"),
                ),
                KeyBinding::new(
                    next_find,
                    ToggleReview,
                    Some("HermesLite && !HermesFindOpen && !HermesPaletteOpen"),
                ),
                KeyBinding::new(open_find, OpenTranscriptFind, Some("HermesLite")),
                KeyBinding::new(
                    open_find,
                    OpenTranscriptFind,
                    Some("HermesComposer > Input"),
                ),
                KeyBinding::new(
                    open_find,
                    OpenTranscriptFind,
                    Some("HermesFindInput > Input"),
                ),
                KeyBinding::new(next_find, NextTranscriptHit, Some("HermesFindOpen")),
                KeyBinding::new(previous_find, PreviousTranscriptHit, Some("HermesFindOpen")),
                KeyBinding::new("escape", CloseTranscriptFind, Some("HermesFindOpen")),
                KeyBinding::new("escape", CloseImagePreview, Some("HermesImagePreview")),
                KeyBinding::new("left", PreviousPreviewImage, Some("HermesImagePreview")),
                KeyBinding::new("right", NextPreviewImage, Some("HermesImagePreview")),
                KeyBinding::new("enter", NextTranscriptHit, Some("HermesFindInput > Input")),
                KeyBinding::new(
                    "shift-enter",
                    PreviousTranscriptHit,
                    Some("HermesFindInput > Input"),
                ),
                KeyBinding::new(
                    if cfg!(target_os = "macos") {
                        "cmd-enter"
                    } else {
                        "ctrl-enter"
                    },
                    SendMessage,
                    Some("HermesComposer > Input"),
                ),
                KeyBinding::new("enter", SendMessage, Some("HermesComposer > Input")),
                KeyBinding::new(
                    "up",
                    PreviousCompletion,
                    Some("HermesCompletionOpen > Input"),
                ),
                KeyBinding::new("down", NextCompletion, Some("HermesCompletionOpen > Input")),
                KeyBinding::new(
                    "tab",
                    AcceptCompletion,
                    Some("HermesCompletionOpen > Input"),
                ),
                KeyBinding::new(
                    "escape",
                    CloseCompletion,
                    Some("HermesCompletionOpen > Input"),
                ),
                KeyBinding::new(
                    "shift-enter",
                    gpui_component::input::Enter {
                        secondary: false,
                        shift: true,
                    },
                    Some("HermesComposer > Input"),
                ),
                KeyBinding::new(
                    if cfg!(target_os = "macos") {
                        "cmd-n"
                    } else {
                        "ctrl-n"
                    },
                    NewChat,
                    Some("HermesLite"),
                ),
                KeyBinding::new(
                    if cfg!(target_os = "macos") {
                        "cmd-t"
                    } else {
                        "ctrl-t"
                    },
                    NewChat,
                    Some("HermesLite"),
                ),
                KeyBinding::new(
                    if cfg!(target_os = "macos") {
                        "cmd-w"
                    } else {
                        "ctrl-w"
                    },
                    CloseChatTab,
                    Some("HermesLite"),
                ),
                KeyBinding::new(
                    if cfg!(target_os = "macos") {
                        "cmd-shift-t"
                    } else {
                        "ctrl-shift-t"
                    },
                    ReopenChatTab,
                    Some("HermesLite"),
                ),
            ]);
            #[cfg(not(target_os = "macos"))]
            cx.bind_keys([
                KeyBinding::new(
                    "ctrl-home",
                    gpui_component::input::MoveToStart,
                    Some("HermesComposer > Input"),
                ),
                KeyBinding::new(
                    "ctrl-end",
                    gpui_component::input::MoveToEnd,
                    Some("HermesComposer > Input"),
                ),
                KeyBinding::new(
                    "ctrl-shift-home",
                    gpui_component::input::SelectToStart,
                    Some("HermesComposer > Input"),
                ),
                KeyBinding::new(
                    "ctrl-shift-end",
                    gpui_component::input::SelectToEnd,
                    Some("HermesComposer > Input"),
                ),
            ]);
            cx.on_window_closed(|cx, _| {
                if cx.windows().is_empty() {
                    cx.quit();
                }
            })
            .detach();
            let bounds = app::initial_window_bounds(
                settings.as_ref().ok().and_then(|settings| settings.window),
                cx,
            );
            let result = cx.open_window(
                WindowOptions {
                    window_bounds: Some(bounds),
                    window_min_size: Some(Size::new(px(540.), px(420.))),
                    window_background: settings
                        .as_ref()
                        .ok()
                        .map(|settings| &settings.display)
                        .unwrap_or(&settings::DisplayPreferences::default())
                        .window_background(),
                    #[cfg(target_os = "linux")]
                    window_decorations: Some(gpui::WindowDecorations::Client),
                    #[cfg(target_os = "linux")]
                    app_id: Some("io.github.hejuntt1014.hermes-desktop-lite".into()),
                    titlebar: Some(TitlebarOptions {
                        appears_transparent: cfg!(target_os = "windows"),
                        title: Some("Hermes Desktop Lite".into()),
                        ..Default::default()
                    }),
                    ..Default::default()
                },
                |window, cx| {
                    let view = cx.new(|cx| app::Desktop::new(handle, settings, window, cx));
                    cx.new(|cx| Root::new(view, window, cx).bg(gpui::transparent_black()))
                },
            );
            if let Err(error) = result {
                eprintln!("{error:#}");
                cx.quit();
            }
        });
    Ok(())
}

fn encode_path(value: &str) -> String {
    url::form_urlencoded::byte_serialize(value.as_bytes())
        .collect::<String>()
        .replace('+', "%20")
}
