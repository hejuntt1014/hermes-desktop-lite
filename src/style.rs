use std::sync::OnceLock;

use gpui::{Font, FontFallbacks, font};

pub const INK: u32 = 0x353b41;
pub const SECONDARY: u32 = 0x555e68;
pub const MUTED: u32 = 0x707983;
pub const UI_TEXT_SIZE: f32 = 13.;
pub const ACCENT: u32 = 0x185aff;
pub const TRANSCRIPT_INSET: f32 = 24.;
pub const MESSAGE_INSET: f32 = 12.;
pub const CONVERSATION_INK: u32 = 0x1f2328;
pub const SCAFFOLD_INK: u32 = 0x9b9d9f;
pub const PARAGRAPH_GAP: f32 = 11.2;
pub(crate) const INTRO_FONT: &str = "Hermes Lite Display";

pub const UI_FONT: &str = if cfg!(target_os = "windows") {
    "Segoe UI"
} else if cfg!(target_os = "macos") {
    ".AppleSystemUIFont"
} else {
    "sans-serif"
};
pub const CODE_FONT: &str = if cfg!(target_os = "windows") {
    "Consolas"
} else if cfg!(target_os = "macos") {
    "Menlo"
} else {
    "monospace"
};

pub fn interface_font() -> Font {
    static FALLBACKS: OnceLock<FontFallbacks> = OnceLock::new();
    ui_font("Microsoft YaHei UI", &FALLBACKS)
}

pub fn conversation_font() -> Font {
    static FALLBACKS: OnceLock<FontFallbacks> = OnceLock::new();
    ui_font("Microsoft YaHei", &FALLBACKS)
}

fn ui_font(cjk: &str, fallbacks: &OnceLock<FontFallbacks>) -> Font {
    let mut font = font(crate::theme::interface_family());
    if cfg!(target_os = "windows") {
        font.fallbacks = Some(
            fallbacks
                .get_or_init(|| {
                    FontFallbacks::from_fonts(vec![
                        cjk.to_owned().into(),
                        "Segoe UI Emoji".into(),
                        "Segoe UI Symbol".into(),
                    ])
                })
                .clone(),
        );
    }
    font
}
