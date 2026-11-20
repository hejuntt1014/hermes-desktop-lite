use crate::theme::{ink, rgb, rgba};

use crate::i18n::text as tr;

use std::{
    cell::{OnceCell, RefCell},
    collections::{HashMap, VecDeque},
    env,
    path::{Path, PathBuf},
    rc::Rc,
    sync::Arc,
};

use anyhow::Context as _;
use gpui::{
    App, Context, Div, Entity, FocusHandle, MouseButton, MouseMoveEvent, ObjectFit, Pixels, Point,
    RenderImage, ScrollEvent, SharedString, Size, Stateful, Task, Window, div, img, point,
    prelude::*, px, size,
};
use gpui_component::tooltip::Tooltip;
use tokio::{
    sync::Semaphore,
    task::{AbortHandle, JoinHandle},
};

use crate::{
    icons,
    media::{
        ChatImage, ImageIdentity, ImageSource, is_image_file, load_image, load_local_image,
        save_image, save_local_image,
    },
};

use super::{
    Desktop,
    attachment_ops::file_name,
    remote_refs::{gateway_path, scoped_path},
    view::symbol,
    workspace_files::download_name,
};

const THUMBNAIL_LIMIT: usize = 32;
const PREVIEW_TOP: f32 = 32.;
const PREVIEW_FOOTER: f32 = 62.;
const PREVIEW_CONTROL_GAP: f32 = 10.;

#[derive(Clone, PartialEq, Eq)]
struct Key {
    session: String,
    profile: String,
    image: ImageIdentity,
}

#[derive(Clone, PartialEq, Eq)]
enum ImageKey {
    Chat(Key),
    Draft(PathBuf),
}

#[derive(Clone)]
enum PreviewSource {
    Chat(Key, ChatImage),
    Draft(PathBuf),
}

impl PreviewSource {
    fn key(&self) -> ImageKey {
        match self {
            Self::Chat(key, _) => ImageKey::Chat(key.clone()),
            Self::Draft(path) => ImageKey::Draft(path.clone()),
        }
    }

    fn name(&self) -> SharedString {
        match self {
            Self::Chat(_, source) => source.name.clone(),
            Self::Draft(path) => file_name(path).into(),
        }
    }
}

enum Loading {
    Pending { _task: Task<()> },
    Ready(Arc<RenderImage>),
    Failed(SharedString),
}

struct Lightbox {
    key: ImageKey,
    source: PreviewSource,
    focus: Option<FocusHandle>,
    preview: Option<Arc<RenderImage>>,
    full: Loading,
    zoom_steps: i32,
    pan: Point<Pixels>,
    last_drag: Option<Point<Pixels>>,
    gallery: Option<Gallery>,
    fetch_abort: Option<AbortHandle>,
}

#[derive(Clone)]
struct Gallery {
    items: Arc<[PreviewSource]>,
    index: usize,
}

impl Gallery {
    fn offset(&self, step: isize) -> Option<usize> {
        self.index
            .checked_add_signed(step)
            .filter(|index| *index < self.items.len())
    }
}

impl Drop for Lightbox {
    fn drop(&mut self) {
        if let Some(fetch) = &self.fetch_abort {
            fetch.abort();
        }
    }
}

pub(super) struct MediaView {
    thumbnails: VecDeque<(Key, Loading)>,
    draft_thumbnails: HashMap<PathBuf, Loading>,
    requests: Arc<Semaphore>,
    lightbox: Option<Lightbox>,
    downloading: Option<ImageKey>,
    download_error: Option<(ImageKey, SharedString)>,
}

impl Default for MediaView {
    fn default() -> Self {
        Self {
            thumbnails: VecDeque::new(),
            draft_thumbnails: HashMap::new(),
            requests: Arc::new(Semaphore::new(3)),
            lightbox: None,
            downloading: None,
            download_error: None,
        }
    }
}

impl MediaView {
    pub fn is_open(&self) -> bool {
        self.lightbox.is_some()
    }

    pub fn draft_thumbnail(&self, path: &Path) -> Option<Arc<RenderImage>> {
        match self.draft_thumbnails.get(path)? {
            Loading::Ready(image) => Some(image.clone()),
            _ => None,
        }
    }

    pub fn retry_failed_thumbnails(&mut self, session: &str) {
        self.thumbnails.retain(|(key, loading)| {
            key.session != session || !matches!(loading, Loading::Failed(_))
        });
    }
}

pub(super) struct TranscriptImages<'a> {
    session: &'a str,
    profile: &'a str,
    cwd: &'a str,
    available: f32,
    gallery: OnceCell<Rc<RefCell<Vec<PreviewSource>>>>,
}

impl<'a> TranscriptImages<'a> {
    pub(super) fn new(session: &'a str, profile: &'a str, cwd: &'a str, available: f32) -> Self {
        Self {
            session,
            profile,
            cwd,
            available,
            gallery: OnceCell::new(),
        }
    }

    pub(super) fn strip(
        &self,
        images: &[ChatImage],
        user: bool,
        entity: &Entity<Desktop>,
        app: &mut App,
    ) -> Option<Div> {
        if images.is_empty() {
            return None;
        }
        let gallery = self.gallery.get_or_init(Rc::default);
        let mut strip = div()
            .w_full()
            .flex()
            .flex_col()
            .items_start()
            .gap_2()
            .pt_1();
        let max_width = self.available.min(if user { 260. } else { 586. });
        let max_height = if user { 175. } else { 385. };
        for (index, image) in images.iter().enumerate() {
            let scoped;
            let image = if let ImageSource::Gateway(path) = &image.source
                && !self.cwd.is_empty()
                && !gateway_path(path, false)
            {
                scoped = ChatImage {
                    name: image.name.clone(),
                    source: ImageSource::Gateway(scoped_path(self.cwd, path).into_owned().into()),
                };
                &scoped
            } else {
                image
            };
            let key = Key {
                session: self.session.to_owned(),
                profile: self.profile.to_owned(),
                image: image.identity(),
            };
            let (preview, error, request) = match entity
                .read(app)
                .media
                .thumbnails
                .iter()
                .find(|(candidate, _)| *candidate == key)
            {
                Some((_, Loading::Ready(image))) => (Some(image.clone()), None, false),
                Some((_, Loading::Failed(error))) => (None, Some(error.clone()), false),
                Some((_, Loading::Pending { .. })) => (None, None, false),
                None => (None, None, true),
            };
            if request {
                let weak = entity.downgrade();
                let key = key.clone();
                let source = image.clone();
                app.defer(move |app| {
                    let _ = weak.update(app, |desktop, cx| desktop.load_thumbnail(key, source, cx));
                });
            }
            let weak = entity.downgrade();
            let source = PreviewSource::Chat(key.clone(), image.clone());
            let gallery_index = {
                let mut images = gallery.borrow_mut();
                images.iter().position(|image| matches!(image, PreviewSource::Chat(existing, _) if existing == &key)).unwrap_or_else(|| {
                images.push(source.clone());
                images.len() - 1
            })
            };
            let group = gallery.clone();
            let name = image.name.clone();
            let preview_open = entity.read(app).media.is_open();
            let (width, height) = preview
                .as_ref()
                .map_or((max_width.min(280.), 108.), |image| {
                    fit_size(image, max_width, max_height, false)
                });
            let card = div()
                .id(("transcript-image", index))
                .relative()
                .w(px(width))
                .h(px(height))
                .max_w_full()
                .rounded(px(4.))
                .bg(rgb(0xf3f5f8))
                .flex()
                .items_center()
                .justify_center()
                .overflow_hidden()
                .cursor_pointer()
                .when(!preview_open, |card| {
                    card.tooltip(move |window, cx| Tooltip::new(name.clone()).build(window, cx))
                })
                .on_click(move |_, window, app| {
                    let _ = weak.update(app, |desktop, cx| {
                        let images = group.borrow();
                        let gallery = (images.len() > 1).then(|| Gallery {
                            items: images.clone().into(),
                            index: gallery_index,
                        });
                        desktop.open_image(source.clone(), gallery, window, cx);
                    });
                });
            strip = strip.child(match preview {
                Some(preview) => {
                    let weak = entity.downgrade();
                    let source = PreviewSource::Chat(key.clone(), image.clone());
                    let busy = entity.read(app).media.downloading.as_ref() == Some(&source.key());
                    card.child(
                        img(preview)
                            .size_full()
                            .flex_none()
                            .object_fit(ObjectFit::Contain),
                    )
                    .when(width >= 68. && height >= 54., |card| {
                        card.child(
                            media_button_base("save-inline-image", tr("下载原图"))
                                .absolute()
                                .top(px(8.))
                                .right(px(8.))
                                .bg(rgba(0xffffffcc))
                                .border_color(rgba(0xffffff80))
                                .hover(|button| button.bg(rgba(0xfffffff0)))
                                .child(
                                    gpui::svg()
                                        .path(icons::DOWNLOAD)
                                        .size(px(15.))
                                        .text_color(ink(0x536170)),
                                )
                                .when(busy, |button| button.opacity(0.5))
                                .on_click(move |_, _, cx| {
                                    cx.stop_propagation();
                                    let _ = weak.update(cx, |desktop, cx| {
                                        desktop.download_image(source.clone(), cx);
                                    });
                                }),
                        )
                    })
                }
                None => card.child(
                    div()
                        .size_full()
                        .flex()
                        .flex_col()
                        .items_center()
                        .justify_center()
                        .px_2()
                        .gap_1()
                        .text_size(px(11.))
                        .text_color(ink(0x67727e))
                        .child(
                            div()
                                .w_full()
                                .truncate()
                                .text_center()
                                .child(image.name.clone()),
                        )
                        .child(if let Some(error) = error {
                            error
                        } else {
                            tr("正在加载图片…").into()
                        }),
                ),
            });
        }
        Some(strip)
    }
}

impl Desktop {
    pub(super) fn prepare_draft_thumbnails(&mut self, files: &[PathBuf], cx: &mut Context<Self>) {
        self.media
            .draft_thumbnails
            .retain(|path, _| files.contains(path));
        for path in files.iter().filter(|path| is_image_file(path)).take(10) {
            if self.media.draft_thumbnails.contains_key(path) {
                continue;
            }
            let source = path.clone();
            let job = self
                .runtime
                .spawn_blocking(move || load_local_image(&source, false));
            let source = path.clone();
            let task = cx.spawn(async move |view, cx| {
                let result = job.await;
                let _ = view.update(cx, |this, cx| {
                    if let Some(state) = this.media.draft_thumbnails.get_mut(&source) {
                        *state = load_result(result);
                        cx.notify();
                    }
                });
            });
            self.media
                .draft_thumbnails
                .insert(path.clone(), Loading::Pending { _task: task });
        }
    }

    fn load_thumbnail(&mut self, key: Key, image: ChatImage, cx: &mut Context<Self>) {
        let Some(gateway) = self.gateway.clone() else {
            return;
        };
        if self.out.is_none() || self.media.thumbnails.iter().any(|(old, _)| *old == key) {
            return;
        }
        let requests = self.media.requests.clone();
        let fetch = self.runtime.spawn({
            let session = key.session.clone();
            let profile = key.profile.clone();
            async move {
                let _slot = requests.acquire().await?;
                load_image(gateway, session, profile, image, false).await
            }
        });
        let stored_key = key.clone();
        let task = cx.spawn(async move |view, cx| {
            let result = fetch.await;
            let _ = view.update(cx, |desktop, cx| {
                if let Some((_, state)) = desktop
                    .media
                    .thumbnails
                    .iter_mut()
                    .find(|(candidate, _)| *candidate == key)
                {
                    *state = load_result(result);
                    cx.notify();
                }
            });
        });
        self.media
            .thumbnails
            .push_back((stored_key, Loading::Pending { _task: task }));
        if self.media.thumbnails.len() > THUMBNAIL_LIMIT {
            self.media.thumbnails.pop_front();
        }
    }

    pub(super) fn collection_image(
        &mut self,
        session: String,
        profile: String,
        image: ChatImage,
        download: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let source = PreviewSource::Chat(
            Key {
                session,
                profile,
                image: image.identity(),
            },
            image,
        );
        if download {
            self.download_image(source, cx)
        } else {
            self.open_image(source, None, window, cx)
        }
    }

    fn open_image(
        &mut self,
        source: PreviewSource,
        gallery: Option<Gallery>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let (preview, fetch) = match &source {
            PreviewSource::Chat(key, image) => {
                let Some(gateway) = self.gateway.clone() else {
                    return;
                };
                let preview = self.media.thumbnails.iter().find_map(|(candidate, state)| {
                    if candidate == key
                        && let Loading::Ready(image) = state
                    {
                        Some(image.clone())
                    } else {
                        None
                    }
                });
                let requests = self.media.requests.clone();
                let session = key.session.clone();
                let profile = key.profile.clone();
                let image = image.clone();
                let fetch = self.runtime.spawn(async move {
                    let _slot = requests.acquire().await?;
                    load_image(gateway, session, profile, image, true).await
                });
                (preview, fetch)
            }
            PreviewSource::Draft(path) => {
                let preview = self.media.draft_thumbnail(path);
                let path = path.clone();
                let fetch = self
                    .runtime
                    .spawn_blocking(move || load_local_image(&path, true));
                (preview, fetch)
            }
        };
        self.open_lightbox(source, gallery, preview, fetch, window, cx);
    }

    pub(super) fn open_draft_image(
        &mut self,
        path: PathBuf,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let images: Vec<_> = self
            .draft_files()
            .into_iter()
            .filter(|file| is_image_file(file))
            .collect();
        let Some(index) = images.iter().position(|file| *file == path) else {
            return;
        };
        let gallery = (images.len() > 1).then(|| Gallery {
            items: images.into_iter().map(PreviewSource::Draft).collect(),
            index,
        });
        self.open_image(PreviewSource::Draft(path), gallery, window, cx);
    }

    pub(super) fn move_preview_image(
        &mut self,
        step: isize,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(mut gallery) = self
            .media
            .lightbox
            .as_ref()
            .and_then(|preview| preview.gallery.clone())
        else {
            return;
        };
        let Some(index) = gallery.offset(step) else {
            return;
        };
        gallery.index = index;
        let source = gallery.items[index].clone();
        self.open_image(source, Some(gallery), window, cx);
    }

    fn open_lightbox(
        &mut self,
        source: PreviewSource,
        gallery: Option<Gallery>,
        preview: Option<Arc<RenderImage>>,
        fetch: JoinHandle<anyhow::Result<Arc<RenderImage>>>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let key = source.key();
        let abort = fetch.abort_handle();
        let task = cx.spawn(async move |view, cx| {
            let result = fetch.await;
            let _ = view.update(cx, |desktop, cx| {
                let Some(lightbox) = desktop
                    .media
                    .lightbox
                    .as_mut()
                    .filter(|lightbox| lightbox.key == key)
                else {
                    return;
                };
                lightbox.fetch_abort = None;
                lightbox.full = load_result(result);
                cx.notify();
            });
        });
        let mut lightbox = Lightbox::new(source, Loading::Pending { _task: task });
        lightbox.gallery = gallery;
        lightbox.preview = preview;
        lightbox.fetch_abort = Some(abort);
        self.show_lightbox(lightbox, window, cx);
    }

    pub(super) fn open_loaded_image(
        &mut self,
        session: String,
        profile: String,
        image: ChatImage,
        pixels: Arc<RenderImage>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let key = Key {
            session,
            profile,
            image: image.identity(),
        };
        self.show_lightbox(
            Lightbox::new(PreviewSource::Chat(key, image), Loading::Ready(pixels)),
            window,
            cx,
        );
    }

    fn show_lightbox(
        &mut self,
        mut lightbox: Lightbox,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        lightbox.focus = self
            .media
            .lightbox
            .as_ref()
            .map_or_else(|| window.focused(cx), |previous| previous.focus.clone());
        self.workspace_focus.focus(window, cx);
        self.media.lightbox = Some(lightbox);
        cx.notify();
    }

    pub(super) fn close_image(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(mut lightbox) = self.media.lightbox.take() {
            if let Some(focus) = lightbox.focus.take() {
                focus.focus(window, cx);
            }
            cx.notify();
        }
    }

    fn download_image(&mut self, source: PreviewSource, cx: &mut Context<Self>) {
        let gateway = self.gateway.clone().filter(|_| self.out.is_some());
        if self.media.downloading.is_some()
            || matches!(&source, PreviewSource::Chat(..)) && gateway.is_none()
        {
            return;
        }
        let Some(directory) = dirs::download_dir()
            .or_else(dirs::document_dir)
            .or_else(|| env::current_dir().ok())
        else {
            return;
        };
        let filename = download_name(&source.name());
        let destination = cx.prompt_for_new_path(&directory, Some(&filename));
        let runtime = self.runtime.clone();
        let key = source.key();
        self.media.downloading = Some(key.clone());
        self.media.download_error = None;
        cx.spawn(async move |view, cx| {
            let result = async {
                let Some(path) = destination.await.context(tr("保存对话框已关闭"))?? else {
                    return Ok::<_, anyhow::Error>(());
                };
                runtime
                    .spawn(async move {
                        match source {
                            PreviewSource::Chat(key, image) => {
                                let gateway = gateway.context(tr("网关未连接"))?;
                                save_image(gateway, key.session, key.profile, image, path).await
                            }
                            PreviewSource::Draft(local) => save_local_image(local, path).await,
                        }
                    })
                    .await?
            }
            .await;
            let _ = view.update(cx, |desktop, cx| {
                if desktop.media.downloading.as_ref() != Some(&key) {
                    return;
                }
                desktop.media.downloading = None;
                if let Err(error) = result {
                    let message: SharedString = crate::i18n::format_text!(
                        "保存图片失败 · {error}",
                        "Could not save image · {error}"
                    )
                    .into();
                    desktop.media.download_error = Some((key, message.clone()));
                    desktop.banner = Some(message);
                }
                cx.notify();
            });
        })
        .detach();
        cx.notify();
    }

    fn zoom_image(&mut self, step: i32, window: &Window, cx: &mut Context<Self>) {
        if let Some(preview) = self.media.lightbox.as_mut() {
            preview.zoom_steps = if step == 0 {
                0
            } else {
                (preview.zoom_steps + step).clamp(-4, 8)
            };
            preview.clamp_pan(window);
            cx.notify();
        }
    }

    fn drag_image(&mut self, event: &MouseMoveEvent, window: &Window, cx: &mut Context<Self>) {
        if let Some(lightbox) = self.media.lightbox.as_mut()
            && let Some(previous) = lightbox.last_drag
            && event.dragging()
        {
            lightbox.pan += event.position - previous;
            lightbox.last_drag = Some(event.position);
            lightbox.clamp_pan(window);
            cx.notify();
        }
    }

    pub(super) fn image_overlay(
        &self,
        window: &Window,
        cx: &mut Context<Self>,
    ) -> Option<Stateful<Div>> {
        let lightbox = self.media.lightbox.as_ref()?;
        let key = lightbox.key.clone();
        let source = lightbox.source.clone();
        let save_label = match &source {
            PreviewSource::Chat(..) => tr("下载原图"),
            PreviewSource::Draft(_) => tr("保存原图"),
        };
        let saving = self.media.downloading.as_ref() == Some(&key);
        let status = self
            .media
            .download_error
            .as_ref()
            .filter(|(candidate, _)| *candidate == key)
            .map(|(_, message)| message.clone())
            .or_else(|| match &lightbox.full {
                Loading::Failed(reason) => Some(reason.clone()),
                Loading::Pending { .. } if lightbox.image().is_none() => {
                    Some(tr("正在加载图片…").into())
                }
                _ => None,
            });
        let scale = lightbox.scale();
        let stage_size = preview_stage_size(window);
        let stage = lightbox.image().map(|image| {
            let (width, height) = preview_size(image, window);
            let shown = size(px(width * scale), px(height * scale));
            let pan = lightbox.bounded_pan(shown, stage_size);
            div()
                .id("preview-image")
                .absolute()
                .left((stage_size.width - shown.width) / 2. + pan.x)
                .top((stage_size.height - shown.height) / 2. + pan.y)
                .w(shown.width)
                .h(shown.height)
                .rounded(px(4.))
                .overflow_hidden()
                .bg(rgb(0xffffff))
                .shadow_lg()
                .when(scale > 1., |image| image.cursor_grab())
                .when(lightbox.last_drag.is_some(), |image| {
                    image.cursor_grabbing()
                })
                .on_mouse_down(
                    MouseButton::Left,
                    cx.listener(|this, event: &gpui::MouseDownEvent, _, _| {
                        if let Some(preview) = this
                            .media
                            .lightbox
                            .as_mut()
                            .filter(|preview| preview.zoom_steps > 0)
                        {
                            preview.last_drag = Some(event.position);
                        }
                    }),
                )
                .on_click(|_, _, app| app.stop_propagation())
                .child(
                    img(image.clone())
                        .size_full()
                        .object_fit(ObjectFit::Contain),
                )
        });
        let visible_bottom = lightbox
            .image()
            .map_or(stage_size.height / 2. + px(20.), |image| {
                let (_, height) = preview_size(image, window);
                ((stage_size.height + px(height * scale)) / 2.).min(stage_size.height)
            });
        let controls = (lightbox.image().is_some() || lightbox.gallery.is_some()).then(|| {
            div()
                .absolute()
                .left_0()
                .right_0()
                .top(px(PREVIEW_TOP + PREVIEW_CONTROL_GAP) + visible_bottom)
                .flex()
                .justify_center()
                .child(
                    div()
                        .id("image-preview-toolbar")
                        .flex()
                        .items_center()
                        .gap(px(7.))
                        .on_click(|_, _, app| app.stop_propagation())
                        .children(lightbox.gallery.as_ref().map(|gallery| {
                            div()
                                .id("image-gallery")
                                .h(px(35.))
                                .flex()
                                .items_center()
                                .gap(px(4.))
                                .px_1()
                                .rounded_full()
                                .border_1()
                                .border_color(rgb(0xe1e5ed))
                                .bg(rgb(0xffffff))
                                .shadow_md()
                                .child(
                                    media_button("previous-image", icons::BACK, tr("上一张（←）"))
                                        .when(gallery.offset(-1).is_none(), |button| {
                                            button.opacity(0.4)
                                        })
                                        .on_click(cx.listener(|this, _, window, cx| {
                                            cx.stop_propagation();
                                            this.move_preview_image(-1, window, cx);
                                        })),
                                )
                                .child(
                                    div()
                                        .min_w(px(31.))
                                        .text_center()
                                        .text_size(px(11.))
                                        .text_color(ink(0x626c77))
                                        .child(format!(
                                            "{} / {}",
                                            gallery.index + 1,
                                            gallery.items.len()
                                        )),
                                )
                                .child(
                                    media_button("next-image", icons::RIGHT, tr("下一张（→）"))
                                        .when(gallery.offset(1).is_none(), |button| {
                                            button.opacity(0.4)
                                        })
                                        .on_click(cx.listener(|this, _, window, cx| {
                                            cx.stop_propagation();
                                            this.move_preview_image(1, window, cx);
                                        })),
                                )
                        }))
                        .children(lightbox.image().is_some().then(|| {
                            div()
                                .id("image-zoom")
                                .h(px(35.))
                                .w(px(128.))
                                .flex()
                                .items_center()
                                .justify_between()
                                .px_1()
                                .rounded_full()
                                .border_1()
                                .border_color(rgb(0xe1e5ed))
                                .bg(rgb(0xffffff))
                                .shadow_md()
                                .child(
                                    media_button("zoom-out", icons::ZOOM_OUT, tr("缩小"))
                                        .when(lightbox.zoom_steps <= -4, |button| {
                                            button.opacity(0.4)
                                        })
                                        .on_click(cx.listener(|this, _, window, cx| {
                                            cx.stop_propagation();
                                            this.zoom_image(-1, window, cx);
                                        })),
                                )
                                .child(
                                    div()
                                        .id("reset-image-zoom")
                                        .min_w(px(43.))
                                        .rounded_full()
                                        .hover(|button| button.bg(rgb(0xf0f3f8)))
                                        .text_center()
                                        .text_size(px(12.))
                                        .text_color(ink(0x626c77))
                                        .cursor_pointer()
                                        .tooltip(|window, cx| {
                                            Tooltip::new(tr("恢复原始缩放")).build(window, cx)
                                        })
                                        .child(format!("{:.0}%", scale * 100.))
                                        .on_click(cx.listener(|this, _, window, cx| {
                                            cx.stop_propagation();
                                            this.zoom_image(0, window, cx);
                                        })),
                                )
                                .child(
                                    media_button("zoom-in", icons::ZOOM_IN, tr("放大"))
                                        .when(lightbox.zoom_steps >= 8, |button| {
                                            button.opacity(0.4)
                                        })
                                        .on_click(cx.listener(|this, _, window, cx| {
                                            cx.stop_propagation();
                                            this.zoom_image(1, window, cx);
                                        })),
                                )
                        }))
                        .children(lightbox.image().is_some().then(|| {
                            media_button("save-preview-image", icons::DOWNLOAD, save_label)
                                .size(px(35.))
                                .shadow_md()
                                .when(saving, |button| button.opacity(0.5))
                                .on_click(cx.listener(move |this, _, _, cx| {
                                    cx.stop_propagation();
                                    this.download_image(source.clone(), cx);
                                }))
                        })),
                )
        });
        Some(
            div()
                .id("image-preview")
                .absolute()
                .inset_0()
                .occlude()
                .overflow_hidden()
                .bg(rgba(0x181b22a8))
                .on_click(cx.listener(|this, _, window, cx| this.close_image(window, cx)))
                .on_scroll(cx.listener(|this, event: &ScrollEvent, window, cx| {
                    let delta = event.delta.pixel_delta(px(28.)).y;
                    if delta != px(0.) {
                        cx.stop_propagation();
                        this.zoom_image(if delta > px(0.) { 1 } else { -1 }, window, cx);
                    }
                }))
                .on_mouse_move(cx.listener(|this, event: &MouseMoveEvent, window, cx| {
                    this.drag_image(event, window, cx)
                }))
                .on_mouse_up(
                    MouseButton::Left,
                    cx.listener(|this, _, _, cx| {
                        if let Some(preview) = this.media.lightbox.as_mut()
                            && preview.last_drag.take().is_some()
                        {
                            cx.notify();
                        }
                    }),
                )
                .children(stage.map(|stage| {
                    div()
                        .absolute()
                        .left_0()
                        .right_0()
                        .top(px(PREVIEW_TOP))
                        .h(stage_size.height)
                        .overflow_hidden()
                        .child(stage)
                }))
                .children(controls)
                .children(status.map(|message| {
                    div()
                        .absolute()
                        .left(px(12.))
                        .right(px(12.))
                        .top(px(if lightbox.image().is_some() {
                            14.
                        } else {
                            f32::from(window.viewport_size().height) / 2. - 9.
                        }))
                        .text_center()
                        .text_size(px(13.))
                        .text_color(ink(0xffffff))
                        .child(message)
                })),
        )
    }
}

impl Lightbox {
    fn new(source: PreviewSource, full: Loading) -> Self {
        Self {
            key: source.key(),
            source,
            focus: None,
            preview: None,
            full,
            zoom_steps: 0,
            pan: point(px(0.), px(0.)),
            last_drag: None,
            gallery: None,
            fetch_abort: None,
        }
    }

    fn image(&self) -> Option<&Arc<RenderImage>> {
        match &self.full {
            Loading::Ready(image) => Some(image),
            _ => self.preview.as_ref(),
        }
    }

    fn scale(&self) -> f32 {
        1.25_f32.powi(self.zoom_steps)
    }

    fn clamp_pan(&mut self, window: &Window) {
        if let Some(image) = self.image() {
            let (width, height) = preview_size(image, window);
            let scale = self.scale();
            self.pan = self.bounded_pan(
                size(px(width * scale), px(height * scale)),
                preview_stage_size(window),
            );
        }
    }

    fn bounded_pan(&self, shown: Size<Pixels>, stage: Size<Pixels>) -> Point<Pixels> {
        let x = ((shown.width - stage.width) / 2.).max(px(0.));
        let y = ((shown.height - stage.height) / 2.).max(px(0.));
        point(self.pan.x.clamp(-x, x), self.pan.y.clamp(-y, y))
    }
}

fn preview_stage_size(window: &Window) -> Size<Pixels> {
    let viewport = window.viewport_size();
    size(
        viewport.width,
        (viewport.height - px(PREVIEW_TOP + PREVIEW_FOOTER)).max(px(1.)),
    )
}

fn preview_size(image: &RenderImage, window: &Window) -> (f32, f32) {
    let viewport = window.viewport_size();
    fit_size(
        image,
        f32::from(viewport.width) * 0.86,
        f32::from((viewport.height * 0.83).min(preview_stage_size(window).height)),
        false,
    )
}

fn media_button(id: &'static str, icon: &'static str, label: &'static str) -> Stateful<Div> {
    media_button_base(id, label)
        .border_color(rgb(0xe4e8ef))
        .bg(rgb(0xffffff))
        .hover(|button| button.bg(rgb(0xf1f4f9)))
        .child(symbol(icon, 15.))
}

fn media_button_base(id: &'static str, label: &'static str) -> Stateful<Div> {
    div()
        .id(id)
        .size(px(27.))
        .flex_none()
        .flex()
        .items_center()
        .justify_center()
        .rounded_full()
        .border_1()
        .cursor_pointer()
        .tooltip(move |window, cx| Tooltip::new(label).build(window, cx))
}

fn fit_size(image: &RenderImage, max_width: f32, max_height: f32, upscale: bool) -> (f32, f32) {
    let size = image.size(0);
    let width = size.width.0.max(1) as f32;
    let height = size.height.0.max(1) as f32;
    let fit = (max_width / width).min(max_height / height);
    let fit = if upscale { fit } else { fit.min(1.) };
    (width * fit, height * fit)
}

fn load_result(
    result: Result<anyhow::Result<Arc<RenderImage>>, tokio::task::JoinError>,
) -> Loading {
    match result {
        Ok(Ok(image)) => Loading::Ready(image),
        Ok(Err(error)) => Loading::Failed(error.to_string().into()),
        Err(_) => Loading::Failed(tr("无法加载图片").into()),
    }
}
