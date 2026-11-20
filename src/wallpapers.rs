use gpui::RenderImage;
use serde::{Deserialize, Serialize};
use std::{
    path::{Path, PathBuf},
    sync::Arc,
};

use crate::{
    i18n::text as tr,
    media::{read_local_image, render_encoded_image},
};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Builtin {
    Hermes,
    BlueHour,
}

impl Builtin {
    pub const ALL: [Self; 2] = [Self::Hermes, Self::BlueHour];

    pub fn name(self) -> &'static str {
        match self {
            Self::Hermes => "Hermes",
            Self::BlueHour => tr("蓝调时刻"),
        }
    }

    pub fn bytes(self) -> &'static [u8] {
        match self {
            Self::Hermes => include_bytes!("../assets/filler-bg0.jpg"),
            Self::BlueHour => include_bytes!("../assets/backgrounds/blue-hour.jpg"),
        }
    }
}

#[derive(Clone, PartialEq, Eq)]
pub enum Source {
    Builtin(Builtin),
    File(PathBuf),
}

impl Source {
    pub fn label(&self) -> String {
        match self {
            Self::Builtin(image) => image.name().into(),
            Self::File(path) => path
                .file_name()
                .and_then(|name| name.to_str())
                .map_or_else(|| path.display().to_string(), str::to_owned),
        }
    }

    pub fn render(&self, width: u32, height: u32) -> anyhow::Result<Arc<RenderImage>> {
        match self {
            Self::Builtin(image) => render_encoded_image(image.bytes(), width, height),
            Self::File(path) => render_encoded_image(&read_local_image(path)?, width, height),
        }
    }
}

pub struct Tile {
    pub source: Source,
    pub thumbnail: Option<Arc<RenderImage>>,
}

pub fn thumbnails(paths: Vec<PathBuf>) -> Vec<Tile> {
    Builtin::ALL
        .into_iter()
        .map(Source::Builtin)
        .chain(paths.into_iter().map(Source::File))
        .map(|source| Tile {
            thumbnail: source.render(244, 140).ok(),
            source,
        })
        .collect()
}

pub fn remember(history: &mut Vec<PathBuf>, path: &Path) {
    history.retain(|entry| entry != path);
    history.insert(0, path.to_owned());
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn gallery_remembers_original_paths_without_writing_to_them() {
        let root = tempfile::tempdir().unwrap();
        let image = root.path().join("local.jpg");
        let original = Builtin::BlueHour.bytes();
        fs::write(&image, original).unwrap();
        let mut history = Vec::new();
        remember(&mut history, &image);
        remember(&mut history, &image);
        assert_eq!(history.len(), 1);
        let tiles = thumbnails(history);
        assert_eq!(tiles.len(), Builtin::ALL.len() + 1);
        assert!(tiles.iter().all(|tile| tile.thumbnail.is_some()));
        assert_eq!(fs::read(image).unwrap(), original);
    }
}
