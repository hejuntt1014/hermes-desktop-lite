use std::{
    fs::File,
    io::Read,
    path::{Path, PathBuf},
};

use serde::Deserialize;

use crate::settings::BackgroundPreferences;

#[derive(Deserialize, Default)]
#[serde(default, rename_all = "camelCase")]
struct TerminalSettings {
    default_profile: String,
    profiles: Profiles,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct Profiles {
    defaults: Profile,
    list: Vec<Profile>,
}

#[derive(Deserialize, Default)]
#[serde(default, rename_all = "camelCase")]
struct Profile {
    guid: String,
    background_image: Option<String>,
    background_image_opacity: Option<f32>,
    opacity: Option<u8>,
}

pub fn background() -> Option<BackgroundPreferences> {
    let base = dirs::data_local_dir()?;
    [
        "Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json",
        "Microsoft/Windows Terminal/settings.json",
        "Packages/Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe/LocalState/settings.json",
        "Microsoft/Windows Terminal Preview/settings.json",
    ]
    .into_iter()
    .find_map(|file| read_background(&base.join(file)))
}

fn read_background(path: &Path) -> Option<BackgroundPreferences> {
    const LIMIT: u64 = 4 * 1024 * 1024;
    let mut json = String::new();
    File::open(path)
        .ok()?
        .take(LIMIT + 1)
        .read_to_string(&mut json)
        .ok()?;
    if json.len() as u64 > LIMIT {
        return None;
    }
    let settings: TerminalSettings = jsonc_parser::parse_to_serde_value(
        json.trim_start_matches('\u{feff}'),
        &Default::default(),
    )
    .ok()?;
    let profiles = &settings.profiles;
    let selected = profiles
        .list
        .iter()
        .find(|profile| profile.guid.eq_ignore_ascii_case(&settings.default_profile));
    selected
        .into_iter()
        .chain(std::iter::once(&profiles.defaults))
        .chain(&profiles.list)
        .find_map(|profile| effective_background(profile, &profiles.defaults))
}

fn effective_background(profile: &Profile, defaults: &Profile) -> Option<BackgroundPreferences> {
    let image = PathBuf::from(
        profile
            .background_image
            .as_ref()
            .or(defaults.background_image.as_ref())?,
    );
    if !image.is_absolute() || !image.is_file() {
        return None;
    }
    let image_opacity = profile
        .background_image_opacity
        .or(defaults.background_image_opacity)
        .filter(|value| value.is_finite())
        .map_or(BackgroundPreferences::TERMINAL.image_opacity, |value| {
            (value.clamp(0., 1.) * 100.).round() as u8
        });
    let opacity = profile.opacity.or(defaults.opacity).unwrap_or(100);
    Some(BackgroundPreferences {
        image: Some(image),
        builtin_image: None,
        use_theme_image: false,
        image_opacity,
        window_transparency: 100u8.saturating_sub(opacity),
    })
}

#[cfg(test)]
mod tests {
    use std::fs;

    use super::*;

    #[test]
    fn inherits_terminal_profile_image_and_reads_jsonc_opacity() {
        let dir = tempfile::tempdir().unwrap();
        let image = dir.path().join("wallpaper.jpg");
        fs::write(&image, []).unwrap();
        let config = dir.path().join("settings.json");
        let image_json = serde_json::to_string(&image).unwrap();
        fs::write(
            &config,
            format!(
                r#"{{
          // The selected profile sets the image opacity and inherits the path.
          "defaultProfile": "{{preview}}",
          "profiles": {{
            "defaults": {{ "backgroundImage": {image_json}, "opacity": 88 }},
            "list": [
              {{ "guid": "{{PREVIEW}}", "backgroundImageOpacity": 0.15 }},
            ],
          }},
        }}"#
            ),
        )
        .unwrap();
        let result = read_background(&config).unwrap();
        assert_eq!(result.image, Some(image));
        assert_eq!(result.image_opacity(), 15);
        assert_eq!(result.window_transparency(), 12);
    }
}
