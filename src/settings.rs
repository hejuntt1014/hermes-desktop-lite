use crate::i18n::text as tr;

use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    path::PathBuf,
};

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

#[derive(Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    pub address: String,
    pub gateway_mode: GatewayMode,
    pub remote_auth: Option<RemoteAuth>,
    pub workspaces: BTreeMap<String, Workspace>,
    pub display: DisplayPreferences,
    pub window: Option<SavedWindow>,
    #[serde(skip_serializing_if = "BTreeSet::is_empty")]
    pub clipboard_files: BTreeSet<PathBuf>,
}

#[derive(Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GatewayMode {
    Local,
    #[default]
    Remote,
}

#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RemoteAuth {
    Password,
    Token,
}

#[derive(Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct SavedWindow {
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
    pub maximized: bool,
}

#[derive(Serialize, Deserialize)]
#[serde(default)]
pub struct DisplayPreferences {
    pub language: crate::i18n::Language,
    pub theme: String,
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    pub theme_backgrounds: BTreeMap<String, BackgroundPreferences>,
    pub background: BackgroundPreferences,
    pub terminal_background: Option<BackgroundPreferences>,
    pub wallpaper_history: Vec<PathBuf>,
    pub message_size: u8,
    pub conversation_backdrop: bool,
    pub turn_rail: bool,
    pub reasoning: ReasoningVisibility,
    pub sidebar_open: bool,
    pub sidebar_glass: bool,
    pub alert_prompts: bool,
    pub alert_replies: bool,
    sidebar_transparency: u8,
    pub sidebar_width: u16,
    pub file_list_width: Option<u16>,
    pub restore_session: bool,
}

impl Default for DisplayPreferences {
    fn default() -> Self {
        Self {
            language: Default::default(),
            theme: "default".to_owned(),
            theme_backgrounds: BTreeMap::new(),
            background: BackgroundPreferences::default(),
            terminal_background: None,
            wallpaper_history: Vec::new(),
            message_size: 13,
            conversation_backdrop: true,
            turn_rail: true,
            reasoning: ReasoningVisibility::Gateway,
            sidebar_open: true,
            sidebar_glass: true,
            alert_prompts: true,
            alert_replies: false,
            sidebar_transparency: 6,
            sidebar_width: 237,
            file_list_width: None,
            restore_session: true,
        }
    }
}

impl DisplayPreferences {
    pub const MAX_SIDEBAR_TRANSPARENCY: u8 = 25;

    pub fn sidebar_transparency(&self) -> u8 {
        self.sidebar_transparency
            .min(Self::MAX_SIDEBAR_TRANSPARENCY)
    }

    pub fn set_sidebar_transparency(&mut self, value: u8) {
        self.sidebar_transparency = value.min(Self::MAX_SIDEBAR_TRANSPARENCY);
    }

    pub fn background(&self) -> &BackgroundPreferences {
        match self.theme.as_str() {
            "terminal" => self
                .terminal_background
                .as_ref()
                .unwrap_or(&BackgroundPreferences::TERMINAL),
            "default" => &self.background,
            id => self
                .theme_backgrounds
                .get(id)
                .unwrap_or(&BackgroundPreferences::DEFAULT),
        }
    }

    pub fn background_mut(&mut self) -> &mut BackgroundPreferences {
        match self.theme.as_str() {
            "terminal" => self
                .terminal_background
                .get_or_insert(BackgroundPreferences::TERMINAL),
            "default" => &mut self.background,
            id => self.theme_backgrounds.entry(id.to_owned()).or_default(),
        }
    }

    pub fn window_background(&self) -> gpui::WindowBackgroundAppearance {
        if cfg!(windows) && self.sidebar_glass {
            gpui::WindowBackgroundAppearance::Blurred
        } else if self.background().window_transparency() > 0 {
            gpui::WindowBackgroundAppearance::Transparent
        } else {
            gpui::WindowBackgroundAppearance::Opaque
        }
    }
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct BackgroundPreferences {
    pub image: Option<PathBuf>,
    pub use_theme_image: bool,
    pub builtin_image: Option<crate::wallpapers::Builtin>,
    pub image_opacity: u8,
    pub window_transparency: u8,
}

impl Default for BackgroundPreferences {
    fn default() -> Self {
        Self::DEFAULT
    }
}

impl BackgroundPreferences {
    pub const DEFAULT: Self = Self {
        image: None,
        builtin_image: None,
        use_theme_image: false,
        image_opacity: 18,
        window_transparency: 0,
    };

    pub const TERMINAL: Self = Self {
        image: None,
        builtin_image: Some(crate::wallpapers::Builtin::BlueHour),
        use_theme_image: false,
        image_opacity: 15,
        window_transparency: 0,
    };

    pub fn image_opacity(&self) -> u8 {
        self.image_opacity.min(100)
    }

    pub fn window_transparency(&self) -> u8 {
        self.window_transparency.min(Self::MAX_WINDOW_TRANSPARENCY)
    }

    pub const MAX_WINDOW_TRANSPARENCY: u8 = 60;
}

#[derive(Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReasoningVisibility {
    #[default]
    Gateway,
    Visible,
    Hidden,
}

#[derive(Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Workspace {
    pub selected: Option<String>,
    pub active_tab: Option<String>,
    pub tabs: Vec<ChatTab>,
    pub closed_tabs: Vec<ChatTab>,
    pub drafts: BTreeMap<String, String>,
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    pub draft_skills: BTreeMap<String, String>,
    pub draft_files: BTreeMap<String, Vec<PathBuf>>,
    pub draft_launch: BTreeMap<String, LaunchOptions>,
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    pub model_preferences: BTreeMap<String, ModelPreference>,
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    pub pinned_order: BTreeMap<String, Vec<String>>,
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    pub session_title_colors:
        BTreeMap<String, BTreeMap<String, crate::session_colors::SessionTitleColor>>,
    pub cron_expanded: bool,
    pub pending_submissions: BTreeMap<String, Prepared>,
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    pub followups: BTreeMap<String, Vec<Prepared>>,
    pub pending_rewrites: BTreeMap<String, PendingRewrite>,
    pub bookmarks: Vec<MessageBookmark>,
    pub reading_positions: BTreeMap<String, ReadingPosition>,
    #[serde(skip_serializing_if = "BTreeSet::is_empty")]
    pub collapsed_composer_status: BTreeSet<String>,
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    pub command_receipts:
        BTreeMap<String, BTreeMap<String, Vec<crate::command_receipt::CommandReceipt>>>,
}

#[derive(Clone, Serialize, Deserialize)]
pub struct PendingRewrite {
    pub request_id: String,
    pub row_id: u64,
    pub revision: Option<u64>,
    pub generation: u64,
    pub phase: RewritePhase,
    pub wire_text: String,
    pub deep: bool,
    #[serde(default)]
    pub image_count: usize,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub images: Vec<StagedImage>,
}

#[derive(Clone, Serialize, Deserialize)]
pub struct StagedImage {
    pub path: String,
    pub mime: String,
}

#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RewritePhase {
    StageCanonical,
    StageLegacy,
    Cut,
    Send,
    Legacy,
    Review,
}

#[derive(Clone, PartialEq, Serialize, Deserialize)]
pub struct MessageBookmark {
    pub profile: String,
    pub session: String,
    pub title: String,
    pub excerpt: String,
    pub anchor: ReadingAnchor,
}

#[derive(Clone, PartialEq, Serialize, Deserialize)]
pub struct ReadingPosition {
    pub anchor: ReadingAnchor,
    pub turn: Option<ReadingAnchor>,
    pub offset: f32,
}

#[derive(Clone, PartialEq, Serialize, Deserialize)]
pub struct ReadingAnchor {
    pub row: usize,
    pub stored_id: Option<u64>,
    pub signature: Option<[u8; 12]>,
}

#[derive(Clone, Serialize, Deserialize)]
pub struct ChatTab {
    pub id: String,
    pub session: Option<String>,
    pub title: String,
    #[serde(default)]
    pub profile: String,
}

impl ChatTab {
    pub fn display_title(&self) -> &str {
        if self.session.is_none() {
            tr("新会话")
        } else {
            &self.title
        }
    }

    pub fn draft() -> Self {
        Self {
            id: format!("draft:{}", uuid::Uuid::new_v4()),
            session: None,
            title: "新会话".into(),
            profile: String::new(),
        }
    }
}

impl Workspace {
    pub fn select_empty_draft(&mut self) {
        self.restore_tabs();
        let id = self
            .tabs
            .iter()
            .find(|tab| {
                tab.session.is_none()
                    && !self.drafts.contains_key(&tab.id)
                    && !self.draft_files.contains_key(&tab.id)
                    && !self.draft_launch.contains_key(&tab.id)
                    && !self.pending_submissions.contains_key(&tab.id)
            })
            .map(|tab| tab.id.clone())
            .unwrap_or_else(|| {
                let tab = ChatTab::draft();
                let id = tab.id.clone();
                self.tabs.push(tab);
                id
            });
        self.active_tab = Some(id);
        self.selected = None;
    }

    pub fn remember_closed(&mut self, tab: ChatTab) {
        if tab.session.is_some()
            || self.drafts.contains_key(&tab.id)
            || self.draft_files.contains_key(&tab.id)
            || self.draft_launch.contains_key(&tab.id)
            || self.pending_submissions.contains_key(&tab.id)
        {
            self.closed_tabs.retain(|closed| {
                closed.id != tab.id && (tab.session.is_none() || closed.session != tab.session)
            });
            self.closed_tabs.push(tab);
        }
    }

    pub fn restore_tabs(&mut self) {
        if self.tabs.is_empty() {
            let mut tab = ChatTab::draft();
            if let Some(session) = &self.selected {
                tab.session = Some(session.clone());
                tab.title = "会话".into();
            }
            self.tabs.push(tab);
        }
        if self.drafts.contains_key("") || self.pending_submissions.contains_key("") {
            let index = self
                .tabs
                .iter()
                .position(|tab| tab.session.is_none())
                .unwrap_or_else(|| {
                    self.tabs.push(ChatTab::draft());
                    self.tabs.len() - 1
                });
            let id = self.tabs[index].id.clone();
            if let Some(text) = self.drafts.remove("") {
                self.drafts.insert(id.clone(), text);
            }
            if let Some(prepared) = self.pending_submissions.remove("") {
                self.pending_submissions.insert(id, prepared);
            }
        }
        let active = self
            .active_tab
            .as_deref()
            .and_then(|id| self.tabs.iter().find(|tab| tab.id == id))
            .or_else(|| self.tabs.iter().find(|tab| tab.session == self.selected))
            .unwrap_or(&self.tabs[0]);
        self.selected = active.session.clone();
        self.active_tab = Some(active.id.clone());
    }
}

#[derive(Clone, Serialize, Deserialize)]
pub struct Prepared {
    pub id: String,
    pub text: String,
    pub legacy: bool,
    #[serde(default)]
    pub launch: LaunchOptions,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub files: Vec<PathBuf>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub file_refs: Vec<String>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub pictures: BTreeMap<usize, StagedImage>,
    #[serde(skip)]
    pub picture_urls: BTreeMap<usize, gpui::SharedString>,
    #[serde(default)]
    pub staging: bool,
    #[serde(default)]
    pub queued: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub skill: Option<SkillSubmission>,
}

#[derive(Clone, Serialize, Deserialize)]
pub struct SkillSubmission {
    pub name: String,
    pub argument: String,
    #[serde(default)]
    pub prompt: Option<String>,
}

impl Prepared {
    pub fn wire_text(&self) -> String {
        let caption = self
            .skill
            .as_ref()
            .and_then(|skill| skill.prompt.as_deref())
            .unwrap_or(&self.text);
        self.with_references(caption)
    }

    pub fn display_text(&self) -> String {
        self.with_references(&self.text)
    }

    fn with_references(&self, caption: &str) -> String {
        let mut text = self
            .file_refs
            .iter()
            .filter(|reference| reference.starts_with("@file:"))
            .cloned()
            .collect::<Vec<_>>()
            .join("\n");
        if !caption.trim().is_empty() {
            if !text.is_empty() {
                text.push_str("\n\n");
            }
            text.push_str(caption);
        }
        for image in self
            .file_refs
            .iter()
            .filter(|reference| reference.starts_with("@image:"))
        {
            if !text.is_empty() {
                text.push('\n');
            }
            text.push_str(image);
        }
        text
    }
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct LaunchOptions {
    pub model: Option<ModelChoice>,
    pub effort: Option<String>,
    pub speed: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ModelChoice {
    pub id: String,
    pub provider: String,
}

#[derive(Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct ModelPreference {
    pub favorite: bool,
    pub effort: Option<String>,
    pub speed: Option<String>,
}

impl Settings {
    pub fn workspace_key(&self) -> &str {
        match self.gateway_mode {
            GatewayMode::Local => "local",
            GatewayMode::Remote => &self.address,
        }
    }

    pub fn suggested_auth(&self) -> RemoteAuth {
        if let Some(auth) = self.remote_auth {
            return auth;
        }
        if !self.address.is_empty()
            && Self::saved_token(&self.address).is_ok_and(|value| !value.is_empty())
        {
            return RemoteAuth::Token;
        }
        let official = dirs::config_dir()
            .map(|base| base.join("Hermes").join("connection.json"))
            .and_then(|path| fs::read(path).ok())
            .and_then(|data| serde_json::from_slice::<serde_json::Value>(&data).ok());
        if official.is_some_and(|entry| {
            entry["mode"] == "remote" && entry["remote"]["authMode"] == "token"
        }) {
            RemoteAuth::Token
        } else {
            RemoteAuth::Password
        }
    }

    pub fn saved_token(address: &str) -> Result<String> {
        match Self::credential(address)?.get_password() {
            Ok(token) => Ok(token),
            Err(keyring::Error::NoEntry) => Ok(String::new()),
            Err(error) => Err(error.into()),
        }
    }

    pub fn suggested_address(&self) -> String {
        if !self.address.is_empty() {
            return self.address.clone();
        }
        let Some(path) = dirs::config_dir().map(|base| base.join("Hermes").join("connection.json"))
        else {
            return String::new();
        };
        let config: Option<serde_json::Value> = fs::read(path)
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok());
        config
            .filter(|value| value["mode"] == "remote")
            .and_then(|value| value["remote"]["url"].as_str().map(String::from))
            .unwrap_or_default()
    }
    pub fn config_dir() -> Result<PathBuf> {
        Ok(dirs::config_dir()
            .context(tr("无法定位应用配置目录"))?
            .join("HermesDesktopLite"))
    }

    fn path() -> Result<PathBuf> {
        Ok(Self::config_dir()?.join("settings.json"))
    }

    pub fn load() -> Result<Self> {
        match fs::read(Self::path()?) {
            Ok(data) => Ok(serde_json::from_slice(&data).context(tr("无法读取应用配置"))?),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(Self::default()),
            Err(error) => Err(error.into()),
        }
    }

    pub fn save(&self) -> Result<()> {
        let path = Self::path()?;
        fs::create_dir_all(path.parent().context(tr("无法定位应用配置目录"))?)?;
        let temp = path.with_extension(format!("{}.tmp", uuid::Uuid::new_v4()));
        fs::write(&temp, serde_json::to_vec(self)?)?;
        if let Err(error) = fs::rename(&temp, path) {
            let _ = fs::remove_file(temp);
            return Err(error.into());
        }
        Ok(())
    }

    pub fn credential(address: &str) -> Result<keyring::Entry> {
        Ok(keyring::Entry::new("Hermes Desktop Lite", address)?)
    }
}

#[cfg(test)]
mod appearance_tests {
    use super::*;
    #[test]
    fn terminal_changes_preserve_the_custom_background_from_an_existing_config() {
        let mut settings: DisplayPreferences = serde_json::from_str(
            r#"{"background":{"image":"wallpaper.jpg","image_opacity":27,"window_transparency":13}}"#,
        )
        .unwrap();
        assert_eq!(settings.theme, "default");
        settings.theme = "terminal".into();
        assert_eq!(settings.background().image_opacity(), 15);
        settings.background_mut().image_opacity = 42;
        settings.theme = "pink".into();
        assert_eq!(settings.background().image_opacity(), 18);
        settings.background_mut().image_opacity = 31;
        settings.theme = "default".into();
        assert_eq!(settings.background().image_opacity(), 27);
        assert_eq!(settings.background().window_transparency(), 13);
        let saved = serde_json::to_string(&settings).unwrap();
        let mut restored: DisplayPreferences = serde_json::from_str(&saved).unwrap();
        restored.theme = "terminal".into();
        assert_eq!(restored.background().image_opacity(), 42);
        restored.theme = "pink".into();
        assert_eq!(restored.background().image_opacity(), 31);
    }
}
