mod en;

use std::sync::atomic::{AtomicBool, Ordering};

use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Language {
    #[default]
    System,
    SimplifiedChinese,
    English,
}

impl Language {
    fn resolved(self, system_locale: Option<&str>) -> Self {
        match self {
            Self::System => {
                let language = system_locale
                    .unwrap_or_default()
                    .split(['-', '_', '.', '@'])
                    .next();
                if language.is_some_and(|value| value.eq_ignore_ascii_case("zh")) {
                    Self::SimplifiedChinese
                } else {
                    Self::English
                }
            }
            explicit => explicit,
        }
    }
}

// The app has a single language preference. Network tasks also use it for
// locally generated errors, so reads are safe off the UI thread.
static ENGLISH: AtomicBool = AtomicBool::new(false);

pub fn apply(language: Language) {
    let locale = (language == Language::System)
        .then(sys_locale::get_locale)
        .flatten();
    let english = language.resolved(locale.as_deref()) == Language::English;
    ENGLISH.store(english, Ordering::Relaxed);
    gpui_component::set_locale(if english { "en" } else { "zh-CN" });
}

pub fn is_english() -> bool {
    ENGLISH.load(Ordering::Relaxed)
}

pub fn text(source: &str) -> &str {
    if is_english() {
        en::translate(source)
    } else {
        match source {
            "Fast" => "快速",
            "Ultrafast" => "极速",
            _ => source,
        }
    }
}

/// Pass literal templates so Rust checks argument names and format specifiers
/// in both languages, including captured variables.
macro_rules! format_text {
    ($zh:literal, $en:literal $($args:tt)*) => {
        if $crate::i18n::is_english() {
            format!($en $($args)*)
        } else {
            format!($zh $($args)*)
        }
    };
}
pub(crate) use format_text;

#[cfg(test)]
mod tests {
    use super::Language::*;

    #[test]
    fn system_locale_and_manual_override() {
        assert_eq!(System.resolved(Some("zh-CN")), SimplifiedChinese);
        assert_eq!(System.resolved(Some("zh_TW.UTF-8")), SimplifiedChinese);
        assert_eq!(System.resolved(Some("en-US")), English);
        assert_eq!(System.resolved(Some("ja-JP")), English);
        assert_eq!(System.resolved(None), English);
        assert_eq!(English.resolved(Some("zh-CN")), English);
        assert_eq!(SimplifiedChinese.resolved(Some("en-US")), SimplifiedChinese);
    }
}
