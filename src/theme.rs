use std::sync::{LazyLock, RwLock};

use gpui::{App, Hsla, Rgba, SharedString, px};
use gpui_component::{Theme, ThemeMode};
use serde::{Deserialize, Serialize};

use crate::{
    i18n::text as tr,
    style::{ACCENT, CODE_FONT, INK, MUTED, UI_FONT, UI_TEXT_SIZE},
};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Preset {
    #[default]
    Default,
    Pink,
    Paper,
    Terminal,
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Palette {
    #[serde(with = "hex")]
    pub canvas: u32,
    #[serde(with = "hex")]
    pub surface: u32,
    #[serde(with = "hex")]
    pub chrome: u32,
    #[serde(with = "hex")]
    pub line: u32,
    #[serde(with = "hex")]
    pub selection: u32,
    #[serde(with = "hex")]
    pub message: u32,
    #[serde(with = "hex")]
    pub accent: u32,
    #[serde(with = "hex")]
    pub primary: u32,
    #[serde(with = "hex")]
    pub foreground: u32,
    #[serde(with = "hex")]
    pub muted: u32,
    #[serde(with = "hex")]
    pub link: u32,
    #[serde(with = "hex")]
    pub positive: u32,
    #[serde(with = "hex")]
    pub warning: u32,
    #[serde(with = "hex")]
    pub danger: u32,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        with = "optional_hex"
    )]
    pub code: Option<u32>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        with = "optional_hex"
    )]
    pub composer: Option<u32>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        with = "optional_hex"
    )]
    pub sidebar: Option<u32>,
}

impl Preset {
    pub const ALL: [Self; 4] = [Self::Default, Self::Pink, Self::Paper, Self::Terminal];

    pub fn id(self) -> &'static str {
        match self {
            Self::Default => "default",
            Self::Pink => "pink",
            Self::Paper => "paper",
            Self::Terminal => "terminal",
        }
    }

    pub fn named(id: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|preset| preset.id() == id)
    }

    pub fn appearance(self) -> Appearance {
        if self == Self::Terminal {
            Appearance::Dark
        } else {
            Appearance::Light
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Self::Default => tr("默认"),
            Self::Pink => tr("粉色"),
            Self::Paper => tr("纸黄"),
            Self::Terminal => tr("蓝调时刻"),
        }
    }

    pub fn palette(self) -> Palette {
        match self {
            Self::Default => Palette {
                canvas: 0xfdfdfd,
                surface: 0xffffff,
                chrome: 0xf4f5f7,
                line: 0xe4e7ed,
                selection: 0xe2e9f7,
                message: 0xf0f6fd,
                accent: ACCENT,
                primary: ACCENT,
                foreground: INK,
                muted: MUTED,
                link: ACCENT,
                positive: 0x248365,
                warning: 0x95611f,
                danger: 0x9d3c32,
                sidebar: None,
                composer: None,
                code: None,
            },
            Self::Pink => Palette {
                canvas: 0xfdf4f8,
                surface: 0xfff8fb,
                chrome: 0xf5dee8,
                line: 0xe7bfce,
                selection: 0xf3dce7,
                message: 0xf9e7f0,
                accent: 0xc45c8c,
                primary: 0x9b3864,
                foreground: 0x513441,
                muted: 0x795464,
                link: 0x9b3864,
                positive: 0x248365,
                warning: 0x95611f,
                danger: 0x9d3c32,
                sidebar: None,
                composer: None,
                code: None,
            },
            Self::Paper => Palette {
                canvas: 0xfff8e7,
                surface: 0xfffbef,
                chrome: 0xf0e2bd,
                line: 0xdfcda7,
                selection: 0xf0e2bd,
                message: 0xf7ebca,
                accent: 0x9f732d,
                primary: 0x80561e,
                foreground: 0x463724,
                muted: 0x715b40,
                link: 0x80561e,
                positive: 0x248365,
                warning: 0x95611f,
                danger: 0x9d3c32,
                sidebar: None,
                composer: None,
                code: None,
            },
            Self::Terminal => Palette {
                canvas: 0x282c34,
                surface: 0x303641,
                chrome: 0x262a31,
                line: 0x464d5a,
                selection: 0x3b485a,
                message: 0x394354,
                accent: 0x61afef,
                primary: 0x2f6ba0,
                foreground: 0xdcdfe4,
                muted: 0xa8b3c5,
                link: 0x8ac9fa,
                positive: 0x7ed6b6,
                warning: 0xe4bd75,
                danger: 0xf09d9a,
                sidebar: None,
                composer: None,
                code: None,
            },
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Appearance {
    Light,
    Dark,
}

#[derive(Clone, Copy)]
struct Active {
    colors: Palette,
    dark: bool,
    reference: bool,
}

// Rendering helpers without a Desktop reference share the active window palette.
static ACTIVE: LazyLock<RwLock<Active>> = LazyLock::new(|| {
    RwLock::new(Active {
        colors: Preset::Default.palette(),
        dark: false,
        reference: true,
    })
});

fn current() -> Active {
    *ACTIVE.read().unwrap()
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Fonts {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub interface: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub code: Option<String>,
}

impl Fonts {
    pub fn is_default(&self) -> bool {
        self == &Self::default()
    }
}

static FONTS: LazyLock<RwLock<(SharedString, SharedString)>> =
    LazyLock::new(|| RwLock::new((UI_FONT.into(), CODE_FONT.into())));

pub fn interface_family() -> SharedString {
    FONTS.read().unwrap().0.clone()
}

pub fn code_family() -> SharedString {
    FONTS.read().unwrap().1.clone()
}

pub fn apply(appearance: Appearance, palette: Palette, fonts: &Fonts, cx: &mut App) {
    let available = if fonts.is_default() {
        Vec::new()
    } else {
        cx.text_system().all_font_names()
    };
    let resolve = |name: Option<&str>, fallback: &'static str| {
        name.and_then(|name| {
            available
                .iter()
                .find(|font| font.eq_ignore_ascii_case(name))
        })
        .map_or_else(|| fallback.into(), |font| SharedString::from(font.clone()))
    };
    let ui = resolve(fonts.interface.as_deref(), UI_FONT);
    let code = resolve(fonts.code.as_deref(), CODE_FONT);
    *FONTS.write().unwrap() = (ui.clone(), code.clone());
    let dark = appearance == Appearance::Dark;
    let reference = !dark && palette == Preset::Default.palette();
    *ACTIVE.write().unwrap() = Active {
        colors: palette,
        dark,
        reference,
    };
    Theme::change(
        if dark {
            ThemeMode::Dark
        } else {
            ThemeMode::Light
        },
        None,
        cx,
    );
    Theme::update(cx, |theme| {
        theme.foreground = ink(INK).into();
        theme.muted_foreground = ink(MUTED).into();
        theme.accent = if reference {
            gpui::rgba(0x1414140d).into()
        } else {
            gpui::rgb(palette.selection).into()
        };
        theme.primary = gpui::rgb(palette.primary).into();
        theme.font_family = ui;
        theme.font_size = px(UI_TEXT_SIZE);
        theme.mono_font_family = code;
        theme.mono_font_size = px(12.);
        theme.primary_hover = if reference {
            gpui::rgb(0x2867ff).into()
        } else {
            mix(gpui::rgb(palette.primary), gpui::rgb(palette.accent), 0.2).into()
        };
        theme.primary_active = if reference {
            gpui::rgb(0x124add).into()
        } else {
            mix(
                gpui::rgb(palette.primary),
                gpui::rgb(palette.foreground),
                0.14,
            )
            .into()
        };
        theme.ring = gpui::rgb(palette.accent).into();
        if !reference {
            theme.background = gpui::rgb(palette.canvas).into();
            theme.border = gpui::rgb(palette.line).into();
            theme.popover = gpui::rgb(palette.surface).into();
            theme.selection = gpui::rgb(palette.selection).into();
            theme.input = gpui::rgb(palette.line).into();
            theme.primary_foreground = gpui::rgb(0xffffff).into();
        }
    });
}

pub fn primary() -> Rgba {
    gpui::rgb(current().colors.primary)
}

pub fn sidebar(value: u32) -> Rgba {
    current()
        .colors
        .sidebar
        .map_or_else(|| rgb(value), gpui::rgb)
}

pub fn composer(value: u32) -> Rgba {
    current()
        .colors
        .composer
        .map_or_else(|| rgb(value), gpui::rgb)
}

pub fn code(value: u32) -> Rgba {
    current().colors.code.map_or_else(|| rgb(value), gpui::rgb)
}

pub fn rgb(value: u32) -> Rgba {
    let Active {
        colors,
        dark,
        reference,
    } = current();
    let source = gpui::rgb(value);
    if reference {
        return source;
    }
    if let Some(color) = match value {
        0xfdfdfd => Some(colors.canvas),
        0xffffff | 0xfefefe | 0xfdfefe => Some(colors.surface),
        0xf4f5f7 | 0xf5f7fb | 0xfafafa => Some(colors.chrome),
        0xe4e7ed | 0xd5e3f3 => Some(colors.line),
        0xe2e9f7 | 0xe6eaf2 => Some(colors.selection),
        0xf0f6fd | 0xf0f6ff => Some(colors.message),
        ACCENT => Some(colors.accent),
        _ => None,
    } {
        return gpui::rgb(color);
    }
    if is_blue(source) {
        return gpui::rgb(colors.primary);
    }

    let tone = Hsla::from(source);
    if dark && tone.l >= 0.72 {
        let base = mix(
            gpui::rgb(colors.line),
            gpui::rgb(colors.surface),
            (tone.l - 0.72) / 0.28,
        );
        return if tone.s > 0.24 {
            mix(base, source, 0.09)
        } else {
            base
        };
    }
    if !dark && tone.l >= 0.77 && !is_warm(source) {
        let target = mix(
            gpui::rgb(colors.line),
            gpui::rgb(colors.surface),
            (tone.l - 0.77) / 0.23,
        );
        return mix(source, target, 0.83);
    }
    source
}

pub fn rgba(value: u32) -> Rgba {
    rgb(value >> 8).alpha((value & 0xff) as f32 / 255.)
}

pub fn ink(value: u32) -> Rgba {
    let Active {
        colors,
        dark,
        reference,
    } = current();
    let source = gpui::rgb(value);
    let tone = Hsla::from(source);
    if reference || tone.l >= 0.90 {
        return source;
    }
    if let Some(color) = match value {
        0x9d3c32 | 0xa74941 | 0xae413b | 0xc53f42 => Some(colors.danger),
        0x248365 | 0x318873 | 0x27775f => Some(colors.positive),
        0x95611f | 0xb17635 | 0xab782f => Some(colors.warning),
        _ => None,
    } {
        return gpui::rgb(color);
    }
    if is_blue(source) {
        return gpui::rgb(colors.link);
    }
    if tone.s < 0.32 || is_blue_gray(source) {
        let lightness = ((tone.l - 0.15) / 0.54).clamp(0., 1.);
        return mix(
            gpui::rgb(colors.foreground),
            gpui::rgb(colors.muted),
            lightness,
        );
    }
    if dark {
        return mix(source, gpui::rgb(0xf3ecf0), 0.55);
    }
    source
}

pub fn ink_alpha(value: u32) -> Rgba {
    ink(value >> 8).alpha((value & 0xff) as f32 / 255.)
}

fn is_blue(color: Rgba) -> bool {
    color.b - color.r > 0.24 && color.b - color.g > 0.08
}

fn is_blue_gray(color: Rgba) -> bool {
    color.b >= color.g && color.g >= color.r && color.b - color.r < 0.24
}

fn is_warm(color: Rgba) -> bool {
    color.r - color.b > 0.05 && color.r - color.g > 0.02
}

fn mix(start: Rgba, end: Rgba, amount: f32) -> Rgba {
    Rgba {
        r: start.r + (end.r - start.r) * amount,
        g: start.g + (end.g - start.g) * amount,
        b: start.b + (end.b - start.b) * amount,
        a: start.a + (end.a - start.a) * amount,
    }
}

mod hex {
    use serde::{Deserialize, Deserializer, Serializer, de::Error as _};

    pub fn serialize<S: Serializer>(value: &u32, output: S) -> Result<S::Ok, S::Error> {
        output.serialize_str(&format!("#{value:06X}"))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(input: D) -> Result<u32, D::Error> {
        let value = String::deserialize(input)?;
        parse(&value).map_err(D::Error::custom)
    }

    pub fn parse(value: &str) -> Result<u32, &'static str> {
        let digits = value
            .strip_prefix('#')
            .filter(|digits| digits.len() == 6 && digits.bytes().all(|b| b.is_ascii_hexdigit()))
            .ok_or("expected #RRGGBB")?;
        u32::from_str_radix(digits, 16).map_err(|_| "expected #RRGGBB")
    }
}

mod optional_hex {
    use serde::{Deserialize, Deserializer, Serializer, de::Error as _};

    pub fn serialize<S: Serializer>(value: &Option<u32>, output: S) -> Result<S::Ok, S::Error> {
        match value {
            Some(value) => super::hex::serialize(value, output),
            None => output.serialize_none(),
        }
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(input: D) -> Result<Option<u32>, D::Error> {
        Option::<String>::deserialize(input)?
            .as_deref()
            .map(super::hex::parse)
            .transpose()
            .map_err(D::Error::custom)
    }
}
