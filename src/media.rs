use crate::i18n::text as tr;

use std::{
    fs::File,
    io::{Cursor, Read, Write},
    path::{Path, PathBuf},
    sync::Arc,
};

use anyhow::{Context, Result, bail};
use base64::{Engine as _, engine::general_purpose::STANDARD};
use gpui::{RenderImage, SharedString};
use image::{Frame, ImageFormat, ImageReader, Limits};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::{gateway::Gateway, settings::StagedImage};

pub(crate) const MAX_BYTES: usize = 16 * 1024 * 1024;
const MAX_BASE64_BYTES: usize = MAX_BYTES.div_ceil(3) * 4;
pub(crate) const IMAGE_RESPONSE_LIMIT: usize = MAX_BASE64_BYTES + 1024;

#[derive(Clone, PartialEq, Eq)]
pub struct ChatImage {
    pub name: SharedString,
    pub source: ImageSource,
}

#[derive(Clone, PartialEq, Eq)]
pub enum ImageSource {
    Gateway(SharedString),
    Inline { url: SharedString, digest: [u8; 32] },
}

#[derive(Clone, PartialEq, Eq, Hash)]
pub enum ImageIdentity {
    Gateway(SharedString),
    Inline([u8; 32]),
}

impl ChatImage {
    pub(crate) fn from_tool_result(output: &str) -> Option<Self> {
        let value: Value = serde_json::from_str(output).ok()?;
        if value["success"] == false {
            return None;
        }
        ["host_image", "image"]
            .into_iter()
            .find_map(|field| value[field].as_str().and_then(Self::from_reference))
    }

    pub(crate) fn from_reference(value: &str) -> Option<Self> {
        let value = unquote(value.trim());
        if let Some(payload) = inline_payload(value) {
            return (payload.len() <= MAX_BASE64_BYTES).then(|| Self {
                name: crate::i18n::format_text!(
                    "图片.{}",
                    "image.{}",
                    value["data:image/".len()..]
                        .split_once(';')
                        .map_or("png", |(format, _)| format)
                )
                .into(),
                source: ImageSource::Inline {
                    url: value.to_owned().into(),
                    digest: Sha256::digest(value.as_bytes()).into(),
                },
            });
        }
        let path = value.strip_prefix("file://").unwrap_or(value);
        let drive = path.as_bytes().get(1..3).is_some_and(|prefix| {
            path.as_bytes()[0].is_ascii_alphabetic() && matches!(prefix, b":/" | b":\\")
        });
        let name = path.rsplit(['/', '\\']).next()?;
        let extension = name.rsplit_once('.')?.1.to_ascii_lowercase();
        if path.len() > 4096
            || path.chars().any(char::is_control)
            || (path.contains(':') && !drive)
            || !matches!(
                extension.as_str(),
                "png" | "jpg" | "jpeg" | "webp" | "gif" | "bmp" | "tiff" | "tif"
            )
        {
            return None;
        }
        Some(Self {
            name: name.to_owned().into(),
            source: ImageSource::Gateway(value.to_owned().into()),
        })
    }

    pub fn identity(&self) -> ImageIdentity {
        match &self.source {
            ImageSource::Gateway(path) => ImageIdentity::Gateway(path.clone()),
            ImageSource::Inline { digest, .. } => ImageIdentity::Inline(*digest),
        }
    }
}

#[derive(Clone)]
pub struct Message {
    raw: SharedString,
    projection: Option<Arc<ImageProjection>>,
}

struct ImageProjection {
    caption: SharedString,
    images: Vec<ChatImage>,
}

impl From<String> for Message {
    fn from(raw: String) -> Self {
        Self::new(raw.into(), true)
    }
}

impl PartialEq for Message {
    fn eq(&self, other: &Self) -> bool {
        self.raw == other.raw
    }
}

impl Message {
    pub fn user_with_display(raw: SharedString, display: SharedString) -> Self {
        if raw == display {
            return Self::new(raw, true);
        }
        let view = display_projection(&display, true).unwrap_or(ImageProjection {
            caption: display,
            images: Vec::new(),
        });
        Self {
            raw,
            projection: Some(Arc::new(view)),
        }
    }

    pub fn new(raw: SharedString, user: bool) -> Self {
        let projection = display_projection(&raw, user).map(Arc::new);
        Self { raw, projection }
    }

    pub fn streaming(raw: SharedString) -> Self {
        Self {
            raw,
            projection: None,
        }
    }

    pub fn raw(&self) -> &SharedString {
        &self.raw
    }

    pub fn display(&self) -> &SharedString {
        self.projection
            .as_ref()
            .map_or(&self.raw, |projection| &projection.caption)
    }

    pub fn images(&self) -> &[ChatImage] {
        self.projection
            .as_ref()
            .map_or(&[], |projection| &projection.images)
    }
}

fn display_projection(raw: &str, user: bool) -> Option<ImageProjection> {
    let legacy = user.then(|| legacy_uploaded_files(raw)).flatten();
    let input = legacy.as_deref().unwrap_or(raw);
    let mut projection = project_images(input, user);
    if user
        && let Some(caption) =
            user_context_projection(projection.as_ref().map_or(input, |view| &view.caption))
    {
        if let Some(view) = &mut projection {
            view.caption = caption.into();
        } else {
            projection = Some(ImageProjection {
                caption: caption.into(),
                images: Vec::new(),
            });
        }
    }
    projection.or_else(|| {
        legacy.map(|caption| ImageProjection {
            caption: caption.into(),
            images: Vec::new(),
        })
    })
}

pub(crate) fn attachment_ref(prefix: &str, path: &str) -> Option<String> {
    if path.is_empty() || path.contains(char::is_control) {
        return None;
    }
    if !path.contains(char::is_whitespace) {
        return Some(format!("{prefix}{path}"));
    }
    let quote = ["\"", "'", "`"]
        .into_iter()
        .find(|quote| !path.contains(quote))?;
    Some(format!("{prefix}{quote}{path}{quote}"))
}

fn legacy_uploaded_files(raw: &str) -> Option<String> {
    const MARKER: &str = "[Attached files: ";
    let raw = raw.trim_end();
    let (caption, list) = if let Some(list) = raw.strip_prefix(MARKER) {
        ("", list)
    } else {
        let (caption, note) = raw.rsplit_once('\n')?;
        (
            caption.trim_end_matches(['\n', '\r']),
            note.strip_prefix(MARKER)?,
        )
    };
    let list = list.strip_suffix(']')?;
    let mut start = 0;
    let mut directives = Vec::new();
    for (separator, _) in list.match_indices(", ") {
        if legacy_upload_path(&list[separator + 2..]).is_some() {
            let path = legacy_upload_path(&list[start..separator])?;
            directives.push(attachment_ref("@file:", path)?);
            start = separator + 2;
        }
    }
    directives.push(attachment_ref(
        "@file:",
        legacy_upload_path(&list[start..])?,
    )?);
    if caption.is_empty() {
        return Some(directives.join("\n"));
    }
    let gap = if caption.starts_with("@file:") || caption.starts_with("@image:") {
        "\n"
    } else {
        "\n\n"
    };
    Some(format!("{}{gap}{caption}", directives.join("\n")))
}

fn legacy_upload_path(path: &str) -> Option<&str> {
    let path = path.trim();
    let rooted = path.starts_with('/')
        || path.starts_with("\\\\")
        || path.as_bytes().get(1..3).is_some_and(|segment| {
            path.as_bytes()[0].is_ascii_alphabetic() && matches!(segment, b":/" | b":\\")
        });
    let normalized = path.replace('\\', "/");
    (rooted
        && !path.contains(char::is_control)
        && normalized.contains("/webui/attachments/")
        && !normalized.split('/').any(|component| component == "..")
        && !normalized.ends_with('/'))
    .then_some(path)
}

fn user_context_projection(raw: &str) -> Option<String> {
    const ATTACHED: &str = "\n\n--- Attached Context ---\n";
    const WARNINGS: &str = "\n\n--- Context Warnings ---\n";
    let expanded = raw.split_once(ATTACHED).filter(|(_, extra)| {
        extra.trim_start().lines().next().is_some_and(|head| {
            ["📄 @", "📁 @", "🌐 @", "📌 @", "📎 @", "🧾 "]
                .iter()
                .any(|prefix| head.starts_with(prefix))
        })
    });
    let (caption, context) = expanded.unwrap_or((raw, ""));
    let warned = caption.split_once(WARNINGS).filter(|(_, warnings)| {
        warnings.trim_start().starts_with("- @")
            && warnings
                .lines()
                .filter(|line| !line.trim().is_empty())
                .all(|line| line.starts_with("- "))
    });
    if expanded.is_none() && warned.is_none() {
        return None;
    }
    let visible = warned.map_or(caption, |(visible, _)| visible).trim_end();
    let mut missing = Vec::new();
    let mut in_code = false;
    for line in context.lines() {
        if line.starts_with("```") {
            in_code = !in_code;
            continue;
        }
        if in_code {
            continue;
        }
        let Some(rest) = line
            .strip_prefix("📄 ")
            .or_else(|| line.strip_prefix("📎 "))
        else {
            continue;
        };
        let Some((reference, _)) = rest.rsplit_once(" (") else {
            continue;
        };
        if reference.starts_with("@file:")
            && !visible.contains(reference)
            && !missing.contains(&reference)
        {
            missing.push(reference);
        }
    }
    if missing.is_empty() {
        Some(visible.to_owned())
    } else if visible.is_empty() {
        Some(missing.join("\n"))
    } else {
        Some(format!("{}\n\n{visible}", missing.join("\n")))
    }
}

fn image_reference(line: &str, user: bool) -> Option<&str> {
    if let Some(source) = line.strip_prefix("@image:") {
        return Some(source);
    }
    if user {
        if let Some(source) = line.strip_prefix("@file:") {
            return Some(source);
        }
        if let Some(source) = line
            .strip_prefix("[Image attached at: ")
            .and_then(|line| line.strip_suffix(']'))
        {
            return Some(source);
        }
    } else if let Some(source) = line.strip_prefix("MEDIA:") {
        return Some(source.trim());
    }
    if line.starts_with("data:image/") {
        return Some(line);
    }
    // History serializes structured image parts as Markdown image lines.
    let (_, destination) = line.strip_prefix("![")?.split_once("](")?;
    let destination = destination.strip_suffix(')')?;
    Some(
        destination
            .strip_prefix('<')
            .and_then(|value| value.strip_suffix('>'))
            .unwrap_or(destination),
    )
}

fn project_images(raw: &str, user: bool) -> Option<ImageProjection> {
    let mut images = Vec::new();
    let mut caption = raw;
    if user {
        while let Some((rest, image)) = legacy_vision_attachment(caption) {
            add_image(&mut images, image);
            caption = rest;
        }
    }
    if images.is_empty()
        && ![
            "@image:",
            "@file:",
            "[Image attached at: ",
            "MEDIA:",
            "data:image/",
            "![",
        ]
        .into_iter()
        .any(|marker| caption.contains(marker))
    {
        return None;
    }
    let mut lines = Vec::new();
    let mut fenced = None;
    for line in caption.lines() {
        let trimmed = line.trim();
        let marker = trimmed
            .chars()
            .next()
            .filter(|mark| matches!(mark, '`' | '~'));
        if let Some(mark) = marker {
            let width = trimmed.chars().take_while(|ch| *ch == mark).count();
            if width >= 3 {
                match fenced {
                    Some((start, opening_width))
                        if start == mark
                            && width >= opening_width
                            && trimmed[width..].trim().is_empty() =>
                    {
                        fenced = None
                    }
                    None => fenced = Some((mark, width)),
                    _ => {}
                }
                lines.push(line);
                continue;
            }
        }
        if fenced.is_none()
            && line == line.trim_start()
            && let Some(image) = image_reference(trimmed, user).and_then(ChatImage::from_reference)
        {
            add_image(&mut images, image);
            continue;
        }
        lines.push(line);
    }
    if images.is_empty() {
        return None;
    }
    if user {
        while lines.last().is_some_and(|last| {
            matches!(last.trim(), "" | "[screenshot]" | "[image]" | "[图片]")
        }) {
            lines.pop();
        }
    }
    Some(ImageProjection {
        caption: lines.join("\n").trim().to_owned().into(),
        images,
    })
}

fn add_image(images: &mut Vec<ChatImage>, image: ChatImage) {
    let identity = image.identity();
    if !images.iter().any(|seen| seen.identity() == identity) {
        images.push(image);
    }
}

fn legacy_vision_attachment(raw: &str) -> Option<(&str, ChatImage)> {
    // Older CLI and gateway versions prepended these model-facing notes to the
    // stored message. Only peel complete, leading notes with a valid image path.
    const PREFIXES: &[&str] = &[
        "[The user attached an image but analysis failed",
        "[The user attached an image but it couldn't be analyzed",
        "[The user attached an image. Here's what it contains:",
        "[The user attached an image: ",
        "[The user sent an image but I couldn't quite see it",
        "[The user sent an image but something went wrong",
        "[The user sent an image~ Here's what I can see",
    ];
    let raw = raw.trim_start();
    if !PREFIXES.iter().any(|prefix| raw.starts_with(prefix)) {
        return None;
    }
    let (_, reference) = raw.split_once("vision_analyze")?;
    let path_note = [
        " using image_url: ",
        " with image_url: ",
        " tool using image_url: ",
    ]
    .into_iter()
    .find_map(|prefix| reference.strip_prefix(prefix))?;
    let (path_line, caption) = path_note.split_once('\n').unwrap_or((path_note, ""));
    let path = path_line
        .trim_end()
        .strip_suffix(']')?
        .trim_end_matches(" ~")
        .trim_end();
    let image = ChatImage::from_reference(path)?;
    Some((caption.trim_start(), image))
}

fn unquote(value: &str) -> &str {
    let Some(quote @ ('`' | '\'' | '"')) = value.chars().next() else {
        return value;
    };
    value
        .strip_prefix(quote)
        .and_then(|value| value.strip_suffix(quote))
        .unwrap_or(value)
}

fn inline_payload(value: &str) -> Option<&str> {
    let (kind, payload) = value.strip_prefix("data:image/")?.split_once(";base64,")?;
    matches!(
        kind,
        "png" | "jpg" | "jpeg" | "gif" | "webp" | "bmp" | "tiff"
    )
    .then_some(payload)
}

pub fn image_part_reference(part: &Value) -> Option<&str> {
    if !matches!(
        part["type"].as_str()?,
        "image" | "image_url" | "input_image"
    ) {
        return None;
    }
    part["image_url"]["url"]
        .as_str()
        .or_else(|| part["image_url"].as_str())
        .or_else(|| part["url"].as_str())
}

async fn image_data_url(
    gateway: &Gateway,
    session: &str,
    profile: &str,
    source: ImageSource,
) -> Result<SharedString> {
    match source {
        ImageSource::Gateway(path) => gateway.image_data_url(&path, session, profile).await,
        ImageSource::Inline { url, .. } => Ok(url),
    }
}

pub async fn load_image(
    gateway: Gateway,
    session: String,
    profile: String,
    image: ChatImage,
    large: bool,
) -> Result<Arc<RenderImage>> {
    let url = image_data_url(&gateway, &session, &profile, image.source).await?;
    tokio::task::spawn_blocking(move || decode(&url, large)).await?
}

fn decode(url: &str, large: bool) -> Result<Arc<RenderImage>> {
    let bytes = decode_bytes(url)?;
    let (width, height) = if large { (3072, 2304) } else { (780, 580) };
    render_encoded_image(&bytes, width, height)
}

pub(crate) fn render_encoded_image(bytes: &[u8], width: u32, height: u32) -> Result<Arc<RenderImage>> {
    let format = image::guess_format(bytes).context(tr("图片格式无效"))?;
    Ok(render_raster(decode_raster(bytes, format)?, width, height))
}

fn render_raster(image: image::DynamicImage, width: u32, height: u32) -> Arc<RenderImage> {
    let mut pixels = if image.width() > width || image.height() > height {
        image
            .resize(width, height, image::imageops::FilterType::Triangle)
            .into_rgba8()
    } else {
        image.into_rgba8()
    };
    for pixel in pixels.pixels_mut() {
        pixel.0.swap(0, 2);
    }
    Arc::new(RenderImage::new([Frame::new(pixels)]))
}

pub(crate) fn decode_raster(bytes: &[u8], format: ImageFormat) -> Result<image::DynamicImage> {
    if !matches!(
        format,
        ImageFormat::Png
            | ImageFormat::Jpeg
            | ImageFormat::WebP
            | ImageFormat::Gif
            | ImageFormat::Bmp
            | ImageFormat::Tiff
    ) {
        bail!(tr("图片格式暂不支持"));
    }
    let mut reader = ImageReader::with_format(Cursor::new(bytes), format);
    reader.limits(image_limits());
    reader.decode().context(tr("无法解码图片"))
}

pub(crate) fn image_limits() -> Limits {
    let mut limits = Limits::default();
    limits.max_image_width = Some(8192);
    limits.max_image_height = Some(8192);
    limits.max_alloc = Some(96 * 1024 * 1024);
    limits
}

fn decode_bytes(url: &str) -> Result<Vec<u8>> {
    let Some(payload) = inline_payload(url).filter(|payload| payload.len() <= MAX_BASE64_BYTES)
    else {
        bail!(tr("网关未返回支持的图片"));
    };
    let bytes = STANDARD.decode(payload).context(tr("图片数据损坏"))?;
    if bytes.len() > MAX_BYTES {
        bail!(tr("图片大小超过 16 MB"));
    }
    Ok(bytes)
}

pub(crate) struct ReplayImage {
    pub data_url: String,
    pub extension: &'static str,
    pub digest: [u8; 32],
}

pub(crate) async fn prepare_replay_image(
    gateway: &Gateway,
    session: &str,
    profile: &str,
    image: ChatImage,
) -> Result<ReplayImage> {
    let source = image_data_url(gateway, session, profile, image.source).await?;
    tokio::task::spawn_blocking(move || prepare_picture(decode_bytes(&source)?)).await?
}

fn prepare_picture(bytes: Vec<u8>) -> Result<ReplayImage> {
    let format = image::guess_format(&bytes).context(tr("图片格式无效"))?;
    let raster = decode_raster(&bytes, format)?;
    let digest = Sha256::digest(&bytes).into();
    let (extension, mime, bytes) = match format {
        ImageFormat::Png => ("png", "image/png", bytes),
        ImageFormat::Jpeg => ("jpg", "image/jpeg", bytes),
        ImageFormat::Gif => ("gif", "image/gif", bytes),
        ImageFormat::WebP => ("webp", "image/webp", bytes),
        _ => {
            let mut output = Cursor::new(Vec::new());
            raster
                .write_to(&mut output, ImageFormat::Png)
                .context(tr("无法转换图片"))?;
            ("png", "image/png", output.into_inner())
        }
    };
    if bytes.len() > MAX_BYTES {
        bail!(tr("图片大小超过 16 MB"));
    }
    let encoded = STANDARD.encode(bytes);
    Ok(ReplayImage {
        data_url: format!("data:{mime};base64,{encoded}"),
        extension,
        digest,
    })
}

pub(crate) fn is_image_file(path: &Path) -> bool {
    path.extension()
        .and_then(|ext| ext.to_str())
        .is_some_and(|ext| {
            matches!(
                ext.to_ascii_lowercase().as_str(),
                "png" | "jpg" | "jpeg" | "webp" | "gif" | "bmp" | "tiff" | "tif"
            )
        })
}

pub(crate) fn read_local_image(path: &Path) -> Result<Vec<u8>> {
    let file = File::open(path).context(tr("无法打开图片"))?;
    let metadata = file.metadata()?;
    if !metadata.is_file() {
        bail!(tr("图片必须是普通文件"));
    }
    if metadata.len() > MAX_BYTES as u64 {
        bail!(tr("图片大小超过 16 MB"));
    }
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    file.take(MAX_BYTES as u64 + 1).read_to_end(&mut bytes)?;
    if bytes.len() > MAX_BYTES {
        bail!(tr("图片大小超过 16 MB"));
    }
    Ok(bytes)
}

pub(crate) fn prepare_local_image(path: &Path) -> Result<ReplayImage> {
    prepare_picture(read_local_image(path)?)
}

pub(crate) fn load_local_image(path: &Path, large: bool) -> Result<Arc<RenderImage>> {
    let bytes = read_local_image(path)?;
    let (width, height) = if large { (3072, 2304) } else { (138, 138) };
    render_encoded_image(&bytes, width, height)
}

pub(crate) async fn upload_chat_image(
    gateway: &Gateway,
    profile: &str,
    filename: &str,
    data_url: &str,
) -> Result<StagedImage> {
    let scope = if profile.is_empty() {
        Vec::new()
    } else {
        vec![("profile", profile.to_owned())]
    };
    let reply = gateway
        .api(
            reqwest::Method::POST,
            "api/chat/image-upload",
            &scope,
            Some(json!({"filename":filename, "data_url":data_url})),
        )
        .await?;
    let path = reply["path"]
        .as_str()
        .filter(|path| !path.is_empty())
        .context(tr("网关未返回原图路径"))?;
    let mime = reply["mime_type"]
        .as_str()
        .filter(|mime| {
            matches!(
                *mime,
                "image/png" | "image/jpeg" | "image/gif" | "image/webp"
            )
        })
        .context(tr("网关未返回支持的图片格式"))?;
    Ok(StagedImage {
        path: path.to_owned(),
        mime: mime.to_owned(),
    })
}

pub(crate) fn vision_prompt(caption: &str, images: impl IntoIterator<Item = String>) -> Value {
    let mut parts = vec![json!({"type":"text","text":caption})];
    parts.extend(
        images
            .into_iter()
            .map(|url| json!({"type":"image_url","image_url":{"url":url}})),
    );
    Value::Array(parts)
}

pub async fn save_image(
    gateway: Gateway,
    session: String,
    profile: String,
    image: ChatImage,
    destination: PathBuf,
) -> Result<()> {
    let url = match image.source {
        ImageSource::Gateway(path) => {
            return gateway
                .save_workspace_file(&path, &session, &profile, destination)
                .await;
        }
        ImageSource::Inline { url, .. } => url,
    };
    tokio::task::spawn_blocking(move || {
        let bytes = decode_bytes(&url)?;
        save_image_bytes(&bytes, destination)
    })
    .await?
}

pub(crate) async fn save_local_image(path: PathBuf, destination: PathBuf) -> Result<()> {
    tokio::task::spawn_blocking(move || {
        let bytes = read_local_image(&path)?;
        save_image_bytes(&bytes, destination)
    })
    .await?
}

fn save_image_bytes(bytes: &[u8], destination: PathBuf) -> Result<()> {
    let directory = destination.parent().context(tr("没有可用的保存目录"))?;
    let mut file = tempfile::Builder::new()
        .prefix(".hermes-image-")
        .tempfile_in(directory)?;
    file.write_all(bytes)?;
    file.as_file().sync_all()?;
    file.persist(destination)
        .map(drop)
        .context(tr("无法保存图片"))
}
