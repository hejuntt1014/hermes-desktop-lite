use std::{
    fs::{self, File},
    io::{Cursor, Read, Seek, Write},
    path::{Path, PathBuf},
};

use anyhow::{Context as _, Result, bail, ensure};
use serde::{Deserialize, Serialize};
use zip::{ZipArchive, ZipWriter, write::SimpleFileOptions};

use crate::{
    i18n::text as tr,
    media::{MAX_BYTES, render_encoded_image},
    settings::{BackgroundPreferences, Settings},
    theme::{Appearance, Fonts, Palette, Preset},
};

const VERSION: u32 = 1;
const MANIFEST_LIMIT: usize = 64 * 1024;
const PACKAGE_LIMIT: usize = MAX_BYTES + MANIFEST_LIMIT + 64 * 1024;
const MANIFEST: &str = "theme.json";
const WALLPAPER: &str = "background";

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Manifest {
    pub schema_version: u32,
    pub id: String,
    pub name: String,
    pub appearance: Appearance,
    pub colors: Palette,
    #[serde(default, skip_serializing_if = "Fonts::is_default")]
    pub fonts: Fonts,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub author: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub background: Option<Wallpaper>,
    #[serde(default)]
    pub window_transparency: u8,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Wallpaper {
    pub opacity: u8,
}

impl Manifest {
    pub fn from_preset(preset: Preset) -> Self {
        Self {
            schema_version: VERSION,
            id: format!("{}-custom", preset.id()),
            name: preset.name().to_owned(),
            appearance: preset.appearance(),
            colors: preset.palette(),
            fonts: Fonts::default(),
            author: None,
            background: None,
            window_transparency: 0,
        }
    }

    pub fn preferences(&self) -> BackgroundPreferences {
        BackgroundPreferences {
            image: None,
            builtin_image: None,
            use_theme_image: self.background.is_some(),
            image_opacity: self.background.map_or(18, |image| image.opacity),
            window_transparency: self.window_transparency,
        }
    }

    fn validate(&self) -> Result<()> {
        ensure!(self.schema_version == VERSION, tr("主题格式版本暂不支持"));
        let bytes = self.id.as_bytes();
        ensure!(
            !bytes.is_empty()
                && bytes.len() <= 64
                && bytes[0].is_ascii_alphanumeric()
                && bytes.iter().all(|byte| byte.is_ascii_lowercase()
                    || byte.is_ascii_digit()
                    || *byte == b'-')
                && Preset::named(&self.id).is_none(),
            tr("主题 ID 无效或与内置主题冲突")
        );
        ensure!(
            valid_label(&self.name) && self.author.as_deref().is_none_or(valid_label),
            tr("主题名称或作者无效")
        );
        ensure!(
            self.fonts.interface.as_deref().is_none_or(valid_label)
                && self.fonts.code.as_deref().is_none_or(valid_label),
            tr("主题字体名称无效")
        );
        ensure!(
            self.background.is_none_or(|image| image.opacity <= 100)
                && self.window_transparency <= BackgroundPreferences::MAX_WINDOW_TRANSPARENCY,
            tr("主题背景透明度超出范围")
        );
        Ok(())
    }
}

fn valid_label(label: &str) -> bool {
    !label.trim().is_empty() && label.chars().count() <= 100 && !label.chars().any(char::is_control)
}

#[derive(Clone)]
pub struct InstalledTheme {
    pub path: PathBuf,
    pub manifest: Manifest,
}

impl InstalledTheme {
    pub fn create(manifest: &Manifest, image: Option<&[u8]>) -> Result<Self> {
        let scratch = tempfile::tempdir()?;
        let staged = scratch.path().join("theme.hermes-theme");
        export(&staged, manifest, image)?;
        Self::install(&staged)
    }

    pub fn catalog() -> Vec<Self> {
        let directory = Settings::config_dir().map(|path| path.join("themes"));
        let Ok(entries) = directory.and_then(|directory| Ok(fs::read_dir(directory)?)) else {
            return Vec::new();
        };
        let mut themes = Vec::new();
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().and_then(|extension| extension.to_str()) != Some("hermes-theme") {
                continue;
            }
            if let Ok((_, manifest)) = open(&path)
                && path.file_name().and_then(|name| name.to_str())
                    == Some(filename(&manifest.id).as_str())
            {
                themes.push(Self { path, manifest });
            }
        }
        themes.sort_by(|left, right| {
            (&left.manifest.name, &left.manifest.id)
                .cmp(&(&right.manifest.name, &right.manifest.id))
        });
        themes
    }

    pub fn install(source: &Path) -> Result<Self> {
        Self::install_in(source, &Settings::config_dir()?.join("themes"))
    }

    fn install_in(source: &Path, directory: &Path) -> Result<Self> {
        let payload = read_limited(open_regular_file(source)?, PACKAGE_LIMIT)?;
        let mut zip = ZipArchive::new(Cursor::new(&payload)).context(tr("主题包格式无效"))?;
        let manifest = read_manifest(&mut zip)?;
        if manifest.background.is_some() {
            let bytes = read_member(&mut zip, WALLPAPER, MAX_BYTES)?;
            render_encoded_image(&bytes, 128, 128).context(tr("无法加载背景图"))?;
        }
        fs::create_dir_all(directory)?;
        let path = directory.join(filename(&manifest.id));
        let mut staged = tempfile::NamedTempFile::new_in(directory)?;
        staged.write_all(&payload)?;
        staged.as_file().sync_all()?;
        match staged.persist_noclobber(&path) {
            Ok(_) => Ok(Self { path, manifest }),
            Err(error) if error.error.kind() == std::io::ErrorKind::AlreadyExists => {
                bail!(tr("该主题已安装"))
            }
            Err(error) => Err(error.into()),
        }
    }

    pub fn wallpaper(&self) -> Result<Vec<u8>> {
        let (mut zip, manifest) = open(&self.path)?;
        ensure!(
            manifest.id == self.manifest.id && manifest.background.is_some(),
            tr("主题包格式无效")
        );
        read_member(&mut zip, WALLPAPER, MAX_BYTES)
    }
}

pub fn export(destination: &Path, manifest: &Manifest, image: Option<&[u8]>) -> Result<()> {
    manifest.validate()?;
    let folder = destination.parent().context(tr("没有可用的保存目录"))?;
    let mut temporary = tempfile::NamedTempFile::new_in(folder)?;
    {
        let mut archive = ZipWriter::new(temporary.as_file_mut());
        archive.start_file(MANIFEST, SimpleFileOptions::default())?;
        serde_json::to_writer_pretty(&mut archive, manifest)?;
        if let Some(bytes) = image {
            ensure!(
                bytes.len() <= MAX_BYTES && manifest.background.is_some(),
                tr("主题包格式无效")
            );
            archive.start_file(WALLPAPER, SimpleFileOptions::default())?;
            archive.write_all(bytes)?;
        } else {
            ensure!(manifest.background.is_none(), tr("主题包格式无效"));
        }
        archive.finish()?;
    }
    temporary.as_file().sync_all()?;
    temporary.persist(destination)?;
    Ok(())
}

fn open(path: &Path) -> Result<(ZipArchive<File>, Manifest)> {
    let mut zip = ZipArchive::new(open_regular_file(path)?).context(tr("主题包格式无效"))?;
    let manifest = read_manifest(&mut zip)?;
    Ok((zip, manifest))
}

fn open_regular_file(path: &Path) -> Result<File> {
    let file = File::open(path)?;
    let metadata = file.metadata()?;
    ensure!(metadata.is_file(), tr("主题包格式无效"));
    ensure!(metadata.len() <= PACKAGE_LIMIT as u64, tr("主题包过大"));
    Ok(file)
}

fn read_manifest<R: Read + Seek>(zip: &mut ZipArchive<R>) -> Result<Manifest> {
    ensure!(zip.len() <= 2, tr("主题包格式无效"));
    let manifest: Manifest = serde_json::from_slice(&read_member(zip, MANIFEST, MANIFEST_LIMIT)?)
        .context(tr("主题配色文件无效"))?;
    manifest.validate()?;
    if manifest.background.is_some() {
        ensure!(
            zip.len() == 2 && zip.by_name(WALLPAPER).is_ok(),
            tr("主题包格式无效")
        );
    } else {
        ensure!(zip.len() == 1, tr("主题包格式无效"));
    }
    Ok(manifest)
}

fn read_member<R: Read + Seek>(
    zip: &mut ZipArchive<R>,
    name: &str,
    limit: usize,
) -> Result<Vec<u8>> {
    let file = zip.by_name(name).context(tr("主题包格式无效"))?;
    ensure!(
        file.is_file() && file.size() <= limit as u64,
        tr("主题包过大")
    );
    read_limited(file, limit)
}

fn read_limited(reader: impl Read, limit: usize) -> Result<Vec<u8>> {
    let mut buffer = Vec::new();
    reader.take(limit as u64 + 1).read_to_end(&mut buffer)?;
    ensure!(buffer.len() <= limit, tr("主题包过大"));
    Ok(buffer)
}

fn filename(id: &str) -> String {
    format!("theme-{id}.hermes-theme")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn theme_package_round_trips_versioned_colors() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("pink.hermes-theme");
        let theme = Manifest::from_preset(Preset::Pink);
        export(&path, &theme, None).unwrap();
        let (_, read) = open(&path).unwrap();
        assert_eq!(read.id, theme.id);
        assert_eq!(read.colors, theme.colors);
        assert_eq!(read.appearance, theme.appearance);
    }

    #[test]
    fn installs_wallpaper_without_replacing_an_existing_theme() {
        let root = tempfile::tempdir().unwrap();
        let source = root.path().join("pink.hermes-theme");
        let folder = root.path().join("themes");
        let mut png = Cursor::new(Vec::new());
        image::DynamicImage::new_rgb8(2, 2)
            .write_to(&mut png, image::ImageFormat::Png)
            .unwrap();
        let mut manifest = Manifest::from_preset(Preset::Pink);
        manifest.background = Some(Wallpaper { opacity: 21 });
        manifest.window_transparency = 11;
        export(&source, &manifest, Some(png.get_ref())).unwrap();
        let installed = InstalledTheme::install_in(&source, &folder).unwrap();
        assert_eq!(installed.wallpaper().unwrap(), *png.get_ref());
        assert_eq!(installed.manifest.preferences().image_opacity(), 21);
        assert_eq!(installed.manifest.preferences().window_transparency(), 11);

        manifest.name = "Different name".to_owned();
        export(&source, &manifest, Some(png.get_ref())).unwrap();
        assert!(InstalledTheme::install_in(&source, &folder).is_err());
        assert_eq!(
            open(&installed.path).unwrap().1.name,
            installed.manifest.name
        );
    }

    #[test]
    fn invalid_ids_cannot_be_installed() {
        let mut theme = Manifest::from_preset(Preset::Pink);
        for bad_id in ["../outside", "terminal", "has space"] {
            theme.id = bad_id.into();
            assert!(theme.validate().is_err());
        }
    }
}
