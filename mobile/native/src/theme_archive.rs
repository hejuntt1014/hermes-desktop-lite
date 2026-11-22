use std::fs::{self, File};
use std::io::{self, BufReader, Read};
use std::path::Path;

use zip::write::SimpleFileOptions;
use zip::{ZipArchive, ZipWriter};

const THEME: &str = "theme.json";
const IMAGE: &str = "background";
const MANIFEST_LIMIT: u64 = 64 * 1024;
const IMAGE_LIMIT: u64 = 16 * 1024 * 1024;
const ARCHIVE_LIMIT: u64 = IMAGE_LIMIT + MANIFEST_LIMIT + 64 * 1024;

fn member_limit(name: &str) -> Option<u64> {
    match name {
        THEME => Some(MANIFEST_LIMIT),
        IMAGE => Some(IMAGE_LIMIT),
        _ => None,
    }
}

pub(crate) fn unpack(archive: &Path, directory: &Path) -> Result<(), i32> {
    let file = File::open(archive).map_err(|_| 3)?;
    if file.metadata().map_err(|_| 3)?.len() > ARCHIVE_LIMIT {
        return Err(2);
    }
    let mut archive = ZipArchive::new(BufReader::new(file)).map_err(|_| 1)?;
    if archive.is_empty() || archive.len() > 2 {
        return Err(1);
    }
    let mut manifest_seen = false;
    let mut image_seen = false;
    for index in 0..archive.len() {
        let file = archive.by_index(index).map_err(|_| 1)?;
        let name = file.name().map_err(|_| 1)?.into_owned();
        let limit = member_limit(&name).ok_or(1)?;
        if !file.is_file() {
            return Err(1);
        }
        let seen = if name == THEME {
            &mut manifest_seen
        } else {
            &mut image_seen
        };
        if *seen {
            return Err(1);
        }
        *seen = true;
        if file.size() > limit {
            return Err(2);
        }
        let mut target = File::create_new(directory.join(&name)).map_err(|_| 3)?;
        let copied = io::copy(&mut file.take(limit + 1), &mut target).map_err(|_| 1)?;
        if copied > limit {
            return Err(2);
        }
    }
    if !manifest_seen {
        return Err(1);
    }
    let text = fs::read(directory.join(THEME)).map_err(|_| 3)?;
    let manifest: serde_json::Value = serde_json::from_slice(&text).map_err(|_| 1)?;
    let has_background = manifest
        .get("background")
        .is_some_and(|value| !value.is_null());
    if has_background != image_seen {
        return Err(1);
    }
    Ok(())
}

pub(crate) fn pack(archive: &Path, directory: &Path) -> Result<(), i32> {
    let destination = File::create_new(archive).map_err(|_| 3)?;
    let mut zip = ZipWriter::new(destination);
    for (name, limit) in [(THEME, MANIFEST_LIMIT), (IMAGE, IMAGE_LIMIT)] {
        let input = directory.join(name);
        if name == IMAGE && !input.exists() {
            continue;
        }
        let file = File::open(input).map_err(|_| 3)?;
        if file.metadata().map_err(|_| 3)?.len() > limit {
            return Err(2);
        }
        zip.start_file(name, SimpleFileOptions::default())
            .map_err(|_| 3)?;
        if io::copy(&mut file.take(limit + 1), &mut zip).map_err(|_| 3)? > limit {
            return Err(2);
        }
    }
    zip.finish().map_err(|_| 3)?;
    Ok(())
}
