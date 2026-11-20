use crate::i18n::text as tr;

use std::{
    fs,
    io::{self, Write},
    path::{Path, PathBuf},
};

#[cfg(windows)]
use std::io::Cursor;

use anyhow::{Context as _, Result, bail};
use gpui::{ClipboardEntry, ClipboardItem, Context, EntityInputHandler, Focusable, Window};
use image::ImageFormat;

use crate::media::{MAX_BYTES, decode_raster};

use super::Desktop;

enum Picture {
    Encoded(Vec<u8>),
    #[cfg(windows)]
    Dib(Vec<u8>),
}

impl Desktop {
    pub(super) fn clipboard_loading(&self) -> bool {
        self.workspace()
            .and_then(|workspace| workspace.active_tab.as_ref())
            .is_some_and(|tab| self.clipboard_pastes.contains_key(tab))
    }

    pub(super) fn paste_composer(
        &mut self,
        can_attach: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let clipboard = cx.read_from_clipboard();
        let text = clipboard.as_ref().and_then(ClipboardItem::text);
        let Some(pictures) = self.read_clipboard_pictures(clipboard, cx) else {
            cx.stop_propagation();
            return;
        };
        if pictures.is_empty() {
            if let Some(text) = text.filter(|text| text.contains('\n')) {
                cx.stop_propagation();
                let (text, cursor) = self.composer.update(cx, |field, cx| {
                    field.replace(text, window, cx);
                    (field.text().clone(), field.cursor())
                });
                let view = cx.entity().downgrade();
                let key = self.key();
                // The old one-line bounds are stale after replacing the draft.
                window.on_next_frame(move |window, _| {
                    window.on_next_frame(move |window, cx| {
                        let _ = view.update(cx, |this, cx| {
                            if this.key() != key {
                                return;
                            }
                            this.composer.update(cx, |field, cx| {
                                if field.cursor() == cursor
                                    && field.text() == &text
                                    && field.focus_handle(cx).is_focused(window)
                                    && field
                                        .selected_text_range(false, window, cx)
                                        .is_some_and(|selection| selection.range.is_empty())
                                {
                                    field.set_cursor_position(field.cursor_position(), window, cx);
                                }
                            });
                        });
                    });
                });
            }
            return;
        }
        cx.stop_propagation();
        if can_attach {
            self.attach_clipboard_pictures(pictures, cx);
        }
    }

    pub(super) fn paste_clipboard_image(&mut self, cx: &mut Context<Self>) {
        let clipboard = cx.read_from_clipboard();
        let Some(pictures) = self.read_clipboard_pictures(clipboard, cx) else {
            return;
        };
        if pictures.is_empty() {
            self.banner = Some(tr("剪贴板中没有图片").into());
            cx.notify();
        } else {
            self.attach_clipboard_pictures(pictures, cx);
        }
    }

    fn read_clipboard_pictures(
        &mut self,
        clipboard: Option<ClipboardItem>,
        cx: &mut Context<Self>,
    ) -> Option<Vec<Picture>> {
        match clipboard_pictures(clipboard) {
            Ok(pictures) => Some(pictures),
            Err(error) => {
                self.banner = Some(error.to_string().into());
                cx.notify();
                None
            }
        }
    }

    fn attach_clipboard_pictures(&mut self, pictures: Vec<Picture>, cx: &mut Context<Self>) {
        let Some(tab) = self
            .workspace()
            .and_then(|workspace| workspace.active_tab.clone())
        else {
            return;
        };
        let address = self.settings.workspace_key().to_owned();
        *self.clipboard_pastes.entry(tab.clone()).or_default() += 1;
        let job = self.runtime.spawn_blocking(move || {
            let root = clipboard_dir().context(tr("无法定位截图存储目录"))?;
            fs::create_dir_all(&root)?;
            pictures
                .into_iter()
                .map(|picture| stage_picture(&root, picture))
                .collect::<Result<Vec<_>>>()
        });
        cx.spawn(async move |view, cx| {
            let result = job
                .await
                .context(tr("读取剪贴板图片失败"))
                .and_then(|result| result);
            let _ = view.update(cx, |this, cx| {
                if let Some(count) = this.clipboard_pastes.get_mut(&tab) {
                    *count -= 1;
                    if *count == 0 {
                        this.clipboard_pastes.remove(&tab);
                    }
                }
                cx.notify();
                if this.settings.workspace_key() != address {
                    return;
                }
                let Some(key) = this.draft_key_for_tab(&tab) else {
                    return;
                };
                match result {
                    Ok(staged) => {
                        let mut paths = Vec::new();
                        for (file, path) in staged {
                            match file.persist_noclobber(&path) {
                                Ok(_) => paths.push(path),
                                Err(error) => {
                                    this.banner = Some(
                                        crate::i18n::format_text!(
                                            "无法保存粘贴的图片 · {error}",
                                            "Could not save pasted image · {error}"
                                        )
                                        .into(),
                                    )
                                }
                            }
                        }
                        if !paths.is_empty() {
                            this.settings.clipboard_files.extend(paths.iter().cloned());
                            this.add_files(key, paths, cx);
                        }
                    }
                    Err(error) => {
                        this.banner = Some(
                            crate::i18n::format_text!(
                                "无法粘贴图片 · {error}",
                                "Could not paste image · {error}"
                            )
                            .into(),
                        )
                    }
                }
            });
        })
        .detach();
        cx.notify();
    }

    pub(super) fn prune_clipboard_files(&mut self) {
        if self.settings.clipboard_files.is_empty() {
            return;
        }
        let Some(root) = clipboard_dir() else {
            return;
        };
        let workspaces = &self.settings.workspaces;
        self.settings.clipboard_files.retain(|path| {
            if path.parent() != Some(root.as_path()) {
                return false;
            }
            let referenced = workspaces.values().any(|workspace| {
                workspace
                    .draft_files
                    .values()
                    .any(|files| files.contains(path))
                    || workspace
                        .pending_submissions
                        .values()
                        .any(|pending| pending.files.contains(path))
                    || workspace
                        .followups
                        .values()
                        .flatten()
                        .any(|pending| pending.files.contains(path))
            });
            referenced
                || fs::remove_file(path).is_err_and(|error| error.kind() != io::ErrorKind::NotFound)
        });
    }
}

fn clipboard_dir() -> Option<PathBuf> {
    Some(
        dirs::cache_dir()?
            .join("HermesDesktopLite")
            .join("clipboard"),
    )
}

fn clipboard_pictures(clipboard: Option<ClipboardItem>) -> Result<Vec<Picture>> {
    if let Some(clipboard) = clipboard {
        return Ok(clipboard
            .into_entries()
            .filter_map(|entry| match entry {
                ClipboardEntry::Image(image) => Some(Picture::Encoded(image.bytes)),
                _ => None,
            })
            .collect());
    }
    #[cfg(windows)]
    return Ok(read_dib()?.map(Picture::Dib).into_iter().collect());
    #[cfg(not(windows))]
    Ok(Vec::new())
}

fn stage_picture(root: &Path, picture: Picture) -> Result<(tempfile::NamedTempFile, PathBuf)> {
    let (bytes, extension) = match picture {
        Picture::Encoded(bytes) => {
            if bytes.len() > MAX_BYTES {
                bail!(tr("图片大小超过 16 MB"));
            }
            let format = image::guess_format(&bytes).context(tr("无法识别剪贴板中的图片格式"))?;
            decode_raster(&bytes, format)?;
            let extension = match format {
                ImageFormat::Png => "png",
                ImageFormat::Jpeg => "jpg",
                ImageFormat::Gif => "gif",
                ImageFormat::WebP => "webp",
                ImageFormat::Bmp => "bmp",
                ImageFormat::Tiff => "tiff",
                _ => bail!(tr("图片格式暂不支持")),
            };
            (bytes, extension)
        }
        #[cfg(windows)]
        Picture::Dib(bytes) => {
            use image::{DynamicImage, ImageDecoder, codecs::bmp::BmpDecoder};
            let mut decoder = BmpDecoder::new_without_file_header(Cursor::new(bytes))?;
            decoder.set_limits(crate::media::image_limits())?;
            let image = DynamicImage::from_decoder(decoder)?;
            let mut output = Cursor::new(Vec::new());
            image.write_to(&mut output, ImageFormat::Png)?;
            (output.into_inner(), "png")
        }
    };
    if bytes.len() > MAX_BYTES {
        bail!(tr("图片大小超过 16 MB"));
    }
    let mut file = tempfile::Builder::new()
        .prefix(".clipboard-")
        .tempfile_in(root)?;
    file.write_all(&bytes)?;
    file.as_file().sync_all()?;
    let uuid = uuid::Uuid::new_v4().simple().to_string();
    let path = root.join(crate::i18n::format_text!(
        "截图-{}.{extension}",
        "screenshot-{}.{extension}",
        &uuid[..12]
    ));
    Ok((file, path))
}

#[cfg(windows)]
fn read_dib() -> Result<Option<Vec<u8>>> {
    use windows_sys::Win32::System::{
        DataExchange::{
            CloseClipboard, GetClipboardData, IsClipboardFormatAvailable, OpenClipboard,
        },
        Memory::{GlobalLock, GlobalSize, GlobalUnlock},
        Ole::{CF_DIB, CF_DIBV5},
    };

    let format = [u32::from(CF_DIBV5), u32::from(CF_DIB)]
        .into_iter()
        .find(|format| unsafe { IsClipboardFormatAvailable(*format) != 0 });
    let Some(format) = format else {
        return Ok(None);
    };
    if unsafe { OpenClipboard(std::ptr::null_mut()) } == 0 {
        bail!(tr("剪贴板正忙，请再粘贴一次"));
    }
    struct OpenedClipboard;
    impl Drop for OpenedClipboard {
        fn drop(&mut self) {
            unsafe {
                CloseClipboard();
            }
        }
    }
    let _clipboard = OpenedClipboard;
    let data = unsafe { GetClipboardData(format) };
    if data.is_null() {
        bail!(tr("无法读取剪贴板中的位图"));
    }
    let size = unsafe { GlobalSize(data) };
    if size == 0 || size > 64 * 1024 * 1024 {
        bail!(tr("剪贴板中的位图过大或已损坏"));
    }
    let memory = unsafe { GlobalLock(data) };
    if memory.is_null() {
        bail!(tr("无法读取剪贴板中的位图"));
    }
    // The clipboard keeps this handle alive until it is unlocked and closed.
    let bytes = unsafe { std::slice::from_raw_parts(memory.cast::<u8>(), size).to_vec() };
    unsafe {
        GlobalUnlock(data);
    }
    Ok(Some(bytes))
}
