use crate::theme::{self, Palette, Preset, ink, rgb};

use std::sync::Arc;

use anyhow::{Context as _, Result};

use gpui::{
    Context, Div, ObjectFit, PathPromptOptions, RenderImage, Rgba, SharedString, Subscription,
    Task, Window, div, img, prelude::*, px,
};
use gpui_component::slider::{Slider, SliderEvent, SliderState};

use crate::{
    i18n::text as tr,
    media::{read_local_image, render_encoded_image},
    settings::{BackgroundPreferences, DisplayPreferences},
    theme_package::{self, InstalledTheme, Manifest, Wallpaper},
    wallpapers::{self, Builtin, Source as WallpaperSource, Tile},
};

use super::{
    Desktop,
    settings_view::setting_row,
    view::{CANVAS, control, svg_symbol},
};

pub(super) struct BackgroundView {
    pub image: Option<Arc<RenderImage>>,
    job: Option<Task<()>>,
    package_job: Option<Task<()>>,
    pub(super) installed: Vec<InstalledTheme>,
    gallery: Option<Vec<Tile>>,
    gallery_job: Option<Task<()>>,
    error: Option<SharedString>,
    image_opacity: gpui::Entity<SliderState>,
    window_transparency: gpui::Entity<SliderState>,
    _subscriptions: [Subscription; 2],
}

impl BackgroundView {
    pub fn new(
        display: &mut DisplayPreferences,
        window: &Window,
        cx: &mut Context<Desktop>,
    ) -> Self {
        let installed = InstalledTheme::catalog();
        apply_theme(display, &installed, cx);
        window.set_background_appearance(display.window_background());
        let prefs = display.background();
        let image_opacity = cx.new(|_| {
            SliderState::new()
                .max(100.)
                .default_value(f32::from(prefs.image_opacity()))
        });
        let window_transparency = cx.new(|_| {
            SliderState::new()
                .max(f32::from(BackgroundPreferences::MAX_WINDOW_TRANSPARENCY))
                .default_value(f32::from(prefs.window_transparency()))
        });
        let picture = cx.subscribe(&image_opacity, |desktop, _, event, cx| {
            if let SliderEvent::Change(value) = event {
                desktop.settings.display.background_mut().image_opacity = value.end() as u8;
                desktop.schedule_save(cx);
                cx.notify();
            }
        });
        let window_opacity = cx.subscribe_in(
            &window_transparency,
            window,
            |desktop, _, event, window, cx| {
                if let SliderEvent::Change(value) = event {
                    let previous = desktop.settings.display.window_background();
                    desktop
                        .settings
                        .display
                        .background_mut()
                        .window_transparency = value.end() as u8;
                    let appearance = desktop.settings.display.window_background();
                    if appearance != previous {
                        window.set_background_appearance(appearance);
                    }
                    desktop.schedule_save(cx);
                    cx.notify();
                }
            },
        );
        Self {
            image: None,
            job: None,
            package_job: None,
            installed,
            gallery: None,
            gallery_job: None,
            error: None,
            image_opacity,
            window_transparency,
            _subscriptions: [picture, window_opacity],
        }
    }
}

impl Desktop {
    pub(super) fn restore_background(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.sync_background_sliders(window, cx);
        let prefs = self.settings.display.background();
        if let Some(image) = prefs.builtin_image {
            self.load_wallpaper(WallpaperSource::Builtin(image), false, cx);
        } else if let Some(path) = prefs.image.clone() {
            self.load_wallpaper(WallpaperSource::File(path), true, cx);
        } else if prefs.use_theme_image
            && let Some(package) = self.installed_theme().cloned()
        {
            self.load_theme_image(package, cx);
        }
    }

    pub(super) fn select_theme(&mut self, id: &str, window: &mut Window, cx: &mut Context<Self>) {
        if self.settings.display.theme == id {
            return;
        }
        self.background_view.job = None;
        self.background_view.image = None;
        self.background_view.error = None;
        self.settings.display.theme = id.to_owned();
        apply_theme(
            &mut self.settings.display,
            &self.background_view.installed,
            cx,
        );
        window.set_background_appearance(self.settings.display.window_background());
        self.restore_background(window, cx);
        self.remeasure_transcript();
        self.persist(cx);
        cx.notify();
    }

    fn sync_background_sliders(&self, window: &mut Window, cx: &mut Context<Self>) {
        let prefs = self.settings.display.background();
        self.background_view.image_opacity.update(cx, |state, cx| {
            state.set_value(f32::from(prefs.image_opacity()), window, cx)
        });
        self.background_view
            .window_transparency
            .update(cx, |state, cx| {
                state.set_value(f32::from(prefs.window_transparency()), window, cx)
            });
    }

    fn choose_background(&mut self, cx: &mut Context<Self>) {
        if self.background_view.job.is_some() {
            return;
        }
        let paths = cx.prompt_for_paths(PathPromptOptions {
            files: true,
            directories: false,
            multiple: false,
            prompt: Some(tr("选择背景图").into()),
        });
        self.background_view.error = None;
        self.background_view.job = Some(cx.spawn(async move |view, cx| {
            let selection = paths.await;
            let _ = view.update(cx, |desktop, cx| {
                desktop.background_view.job = None;
                match selection {
                    Ok(Ok(Some(paths))) => {
                        if let Some(path) = paths.into_iter().next() {
                            desktop.load_wallpaper(WallpaperSource::File(path), false, cx);
                        }
                    }
                    Ok(Ok(None)) => {}
                    _ => {
                        desktop.background_view.error = Some(tr("无法打开文件选择窗口").into());
                    }
                }
                cx.notify();
            });
        }));
        cx.notify();
    }

    fn load_wallpaper(&mut self, source: WallpaperSource, restoring: bool, cx: &mut Context<Self>) {
        let terminal =
            cfg!(windows) && restoring && self.settings.display.theme == Preset::Terminal.id();
        let pending = self.runtime.spawn_blocking(move || -> Result<_> {
            #[cfg(windows)]
            let source = if terminal
                && let WallpaperSource::File(path) = &source
                && crate::terminal_appearance::background()
                    .and_then(|prefs| prefs.image)
                    .as_ref()
                    == Some(path)
            {
                WallpaperSource::Builtin(Builtin::BlueHour)
            } else {
                source
            };
            #[cfg(not(windows))]
            let _ = terminal;
            let pixels = source.render(3072, 2304)?;
            Ok((source, pixels))
        });
        self.background_view.job = Some(cx.spawn(async move |view, cx| {
            let loaded = pending
                .await
                .context(tr("无法加载背景图"))
                .and_then(|result| result);
            let _ = view.update(cx, |desktop, cx| {
                desktop.background_view.job = None;
                match loaded {
                    Ok((source, pixels)) => {
                        desktop.background_view.image = Some(pixels);
                        desktop.background_view.error = None;
                        let prefs = desktop.settings.display.background_mut();
                        let (file, builtin) = match &source {
                            WallpaperSource::File(path) => (Some(path.clone()), None),
                            WallpaperSource::Builtin(image) => (None, Some(*image)),
                        };
                        let changed = prefs.image != file
                            || prefs.builtin_image != builtin
                            || prefs.use_theme_image;
                        prefs.image = file.clone();
                        prefs.builtin_image = builtin;
                        prefs.use_theme_image = false;
                        let remembered = file.is_some_and(|path| {
                            let history = &mut desktop.settings.display.wallpaper_history;
                            if changed || !history.contains(&path) {
                                wallpapers::remember(history, &path);
                                true
                            } else {
                                false
                            }
                        });
                        if changed || remembered {
                            desktop.persist(cx);
                            if desktop.background_view.gallery.is_some()
                                || desktop.background_view.gallery_job.is_some()
                            {
                                desktop.refresh_wallpaper_gallery(cx);
                            }
                        }
                    }
                    Err(error) => desktop.background_view.error = Some(error.to_string().into()),
                }
                cx.notify();
            });
        }));
        cx.notify();
    }

    pub(super) fn refresh_wallpaper_gallery(&mut self, cx: &mut Context<Self>) {
        let display = &self.settings.display;
        let mut paths = display.wallpaper_history.clone();
        for prefs in std::iter::once(&display.background)
            .chain(display.terminal_background.iter())
            .chain(display.theme_backgrounds.values())
        {
            if let Some(path) = &prefs.image
                && !paths.contains(path)
            {
                paths.push(path.clone());
            }
        }
        let pending = self
            .runtime
            .spawn_blocking(move || wallpapers::thumbnails(paths));
        self.background_view.gallery_job = Some(cx.spawn(async move |view, cx| {
            let Ok(tiles) = pending.await else { return };
            let _ = view.update(cx, |desktop, cx| {
                desktop.background_view.gallery_job = None;
                desktop.background_view.gallery = Some(tiles);
                cx.notify();
            });
        }));
    }

    fn wallpaper_gallery(&self, cx: &mut Context<Self>) -> Div {
        let mut gallery = div().flex().flex_col().gap_2().py_2();
        let Some(tiles) = &self.background_view.gallery else {
            return gallery
                .text_size(px(11.))
                .text_color(ink(0x68768b))
                .child(tr("正在读取…"));
        };
        for (heading, section) in [(tr("内置背景"), &tiles[..2]), (tr("我的背景"), &tiles[2..])]
        {
            if section.is_empty() {
                continue;
            }
            gallery =
                gallery
                    .child(
                        div()
                            .text_size(px(11.))
                            .text_color(ink(0x68768b))
                            .child(heading),
                    )
                    .child(div().grid().grid_cols(4).gap_2().children(
                        section.iter().enumerate().map(|(index, tile)| {
                            let prefs = self.settings.display.background();
                            let is_selected = match &tile.source {
                                WallpaperSource::Builtin(image) => {
                                    prefs.builtin_image == Some(*image)
                                }
                                WallpaperSource::File(path) => prefs.image.as_ref() == Some(path),
                            };
                            let source = tile.source.clone();
                            let label: SharedString = source.label().into();
                            div()
                                .id((heading, index))
                                .aria_label(label.clone())
                                .min_w_0()
                                .p_1()
                                .rounded(px(6.))
                                .border_1()
                                .border_color(rgb(if is_selected { 0x185aff } else { 0xe4e7ed }))
                                .bg(rgb(if is_selected { 0xe2e9f7 } else { 0xffffff }))
                                .child(
                                    div()
                                        .h(px(57.))
                                        .rounded(px(4.))
                                        .overflow_hidden()
                                        .bg(rgb(0xf4f5f7))
                                        .children(tile.thumbnail.clone().map(|image| {
                                            img(image).size_full().object_fit(ObjectFit::Cover)
                                        })),
                                )
                                .child(
                                    div()
                                        .truncate()
                                        .text_size(px(11.))
                                        .text_color(ink(0x4d596d))
                                        .pt_1()
                                        .child(label),
                                )
                                .when(
                                    tile.thumbnail.is_some() && self.background_view.job.is_none(),
                                    |tile| {
                                        tile.cursor_pointer()
                                            .hover(|tile| tile.border_color(rgb(0x185aff)))
                                            .on_click(cx.listener(move |desktop, _, _, cx| {
                                                desktop.load_wallpaper(source.clone(), false, cx)
                                            }))
                                    },
                                )
                                .children(tile.thumbnail.is_none().then(|| {
                                    div()
                                        .text_size(px(10.))
                                        .text_color(ink(0x68768b))
                                        .child(tr("原图不可用"))
                                }))
                        }),
                    ));
        }
        gallery
    }

    fn clear_background(&mut self, cx: &mut Context<Self>) {
        self.background_view.job = None;
        self.background_view.image = None;
        self.background_view.error = None;
        let prefs = self.settings.display.background_mut();
        prefs.image = None;
        prefs.builtin_image = None;
        prefs.use_theme_image = false;
        self.persist(cx);
        cx.notify();
    }

    pub(super) fn has_workspace_background(&self) -> bool {
        let prefs = self.settings.display.background();
        prefs.window_transparency() != 0 || self.background_view.image.is_some()
    }

    pub(super) fn workspace_tint(&self, solid: u32, tint: f32) -> Rgba {
        let color = rgb(solid);
        if self.has_workspace_background() {
            color.alpha(
                tint * (1.
                    - f32::from(self.settings.display.background().window_transparency()) / 100.),
            )
        } else {
            color
        }
    }

    pub(super) fn workspace_background(&self) -> Div {
        let prefs = self.settings.display.background();
        let window_opacity = 1. - f32::from(prefs.window_transparency()) / 100.;
        let image = self.background_view.image.as_ref();
        let image_opacity = image.map_or(0., |_| f32::from(prefs.image_opacity()) / 100.);
        let photo_alpha = window_opacity * image_opacity;
        // For opaque photo pixels, the image and canvas together have the requested window opacity.
        let canvas_alpha = if window_opacity == 1. {
            1.
        } else {
            (window_opacity - photo_alpha) / (1. - photo_alpha)
        };
        div()
            .absolute()
            .inset_0()
            .overflow_hidden()
            .bg(rgb(CANVAS).alpha(canvas_alpha))
            .children(image.filter(|_| photo_alpha > 0.).map(|image| {
                img(image.clone())
                    .size_full()
                    .object_fit(ObjectFit::Cover)
                    .opacity(photo_alpha)
            }))
    }

    pub(super) fn appearance_preferences(&self, cx: &mut Context<Self>) -> Div {
        if self.theme_editor.is_some() {
            return self.theme_editor_view(cx);
        }
        let prefs = self.settings.display.background();
        let file_name = prefs
            .builtin_image
            .map(|image| image.name().to_owned())
            .or_else(|| {
                prefs
                    .image
                    .as_ref()
                    .and_then(|path| path.file_name())
                    .map(|name| name.to_string_lossy().into_owned())
            });
        let is_loading = self.background_view.job.is_some();
        let picker = div()
            .flex()
            .flex_none()
            .items_center()
            .gap_2()
            .children(
                (prefs.image.is_some() || prefs.builtin_image.is_some() || prefs.use_theme_image)
                    .then(|| {
                        control("clear-background", tr("移除背景图"))
                            .on_click(cx.listener(|desktop, _, _, cx| desktop.clear_background(cx)))
                    }),
            )
            .child(
                control(
                    "choose-background",
                    if is_loading {
                        tr("正在读取…")
                    } else {
                        tr("选择图片…")
                    },
                )
                .when(!is_loading, |button| {
                    button.on_click(cx.listener(|desktop, _, _, cx| desktop.choose_background(cx)))
                }),
            );
        div()
            .flex()
            .flex_col()
            .child(self.theme_presets(cx))
            .child(self.background_preview())
            .child(setting_row(tr("背景图"), None, picker))
            .child(self.wallpaper_gallery(cx))
            .children(file_name.map(|file_name| {
                div()
                    .py_2()
                    .truncate()
                    .text_size(px(11.))
                    .text_color(ink(0x68768b))
                    .child(file_name)
            }))
            .children(self.background_view.error.as_ref().map(|error| {
                div()
                    .py_2()
                    .text_size(px(12.))
                    .text_color(ink(0xa74941))
                    .child(error.clone())
            }))
            .child(setting_row(
                tr("图片不透明度"),
                None,
                opacity_control(
                    &self.background_view.image_opacity,
                    tr("图片不透明度"),
                    prefs.image_opacity(),
                    self.background_view.image.is_some(),
                ),
            ))
            .child(setting_row(
                tr("窗口透明度"),
                Some(tr("数值越高，桌面背景越明显。")),
                opacity_control(
                    &self.background_view.window_transparency,
                    tr("窗口透明度"),
                    prefs.window_transparency(),
                    true,
                ),
            ))
    }

    fn theme_presets(&self, cx: &mut Context<Self>) -> Div {
        let installed = &self.background_view.installed;
        let choices = Preset::ALL
            .into_iter()
            .map(|preset| (preset.id(), preset.name(), preset.palette()))
            .chain(installed.iter().map(|entry| {
                let manifest = &entry.manifest;
                (
                    manifest.id.as_str(),
                    manifest.name.as_str(),
                    manifest.colors,
                )
            }))
            .collect::<Vec<_>>();
        let can_manage = self.background_view.package_job.is_none();
        div()
            .pt_3()
            .pb_2()
            .flex()
            .flex_col()
            .gap_2()
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap_2()
                    .child(
                        div()
                            .flex_1()
                            .text_size(px(13.))
                            .text_color(ink(0x29374a))
                            .child(tr("主题")),
                    )
                    .child(
                        control("edit-theme", tr("编辑主题")).when(can_manage, |button| {
                            button.on_click(
                                cx.listener(|desktop, _, window, cx| {
                                    desktop.edit_theme(window, cx)
                                }),
                            )
                        }),
                    )
                    .child(
                        control("import-theme", tr("导入主题…")).when(can_manage, |button| {
                            button.on_click(cx.listener(|desktop, _, window, cx| {
                                desktop.import_theme(window, cx)
                            }))
                        }),
                    )
                    .child(
                        control("export-theme", tr("导出主题…")).when(can_manage, |button| {
                            button
                                .on_click(cx.listener(|desktop, _, _, cx| desktop.export_theme(cx)))
                        }),
                    ),
            )
            .child(
                div()
                    .grid()
                    .grid_cols(4)
                    .gap_2()
                    .children(choices.into_iter().enumerate().map(
                        |(index, (id, name, palette))| {
                            let selected = self.settings.display.theme == id;
                            let id = id.to_owned();
                            let name: SharedString = name.to_owned().into();
                            div()
                                .id(("theme-preset", index))
                                .aria_label(name.clone())
                                .min_w_0()
                                .p_1()
                                .rounded(px(6.))
                                .border_1()
                                .border_color(rgb(if selected { 0x185aff } else { 0xe4e7ed }))
                                .bg(rgb(if selected { 0xe2e9f7 } else { 0xffffff }))
                                .hover(|card| card.border_color(rgb(0x185aff)))
                                .cursor_pointer()
                                .child(theme_thumbnail(palette))
                                .child(
                                    div()
                                        .truncate()
                                        .text_size(px(11.))
                                        .text_color(ink(0x4d596d))
                                        .pt_1()
                                        .text_center()
                                        .child(name),
                                )
                                .on_click(cx.listener(move |desktop, _, window, cx| {
                                    desktop.select_theme(&id, window, cx)
                                }))
                        },
                    )),
            )
    }

    pub(super) fn installed_theme(&self) -> Option<&InstalledTheme> {
        self.background_view
            .installed
            .iter()
            .find(|entry| entry.manifest.id == self.settings.display.theme)
    }

    fn import_theme(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.background_view.package_job.is_some() {
            return;
        }
        let paths = cx.prompt_for_paths(PathPromptOptions {
            files: true,
            directories: false,
            multiple: false,
            prompt: Some(tr("导入主题…").into()),
        });
        let runtime = self.runtime.clone();
        self.background_view.package_job = Some(cx.spawn_in(window, async move |view, cx| {
            let result = async {
                let selected = paths.await.context(tr("无法打开文件选择窗口"))??;
                let Some(path) = selected.and_then(|paths| paths.into_iter().next()) else {
                    return Ok(None);
                };
                Ok::<_, anyhow::Error>(Some(
                    runtime
                        .spawn_blocking(move || InstalledTheme::install(&path))
                        .await??,
                ))
            }
            .await;
            let _ = view.update_in(cx, |desktop, window, cx| {
                desktop.background_view.package_job = None;
                match result {
                    Ok(Some(package)) => {
                        let id = package.manifest.id.clone();
                        desktop.background_view.installed.push(package);
                        desktop.background_view.installed.sort_by(|a, b| {
                            (&a.manifest.name, &a.manifest.id)
                                .cmp(&(&b.manifest.name, &b.manifest.id))
                        });
                        desktop.select_theme(&id, window, cx);
                    }
                    Ok(None) => {}
                    Err(error) => desktop.background_view.error = Some(error.to_string().into()),
                }
                cx.notify();
            });
        }));
        cx.notify();
    }

    fn export_theme(&mut self, cx: &mut Context<Self>) {
        if self.background_view.package_job.is_some() {
            return;
        }
        let Some(directory) = dirs::download_dir().or_else(dirs::document_dir) else {
            self.background_view.error = Some(tr("没有可用的保存目录").into());
            cx.notify();
            return;
        };
        let installed = self.installed_theme().cloned();
        let mut manifest = installed.as_ref().map_or_else(
            || {
                Manifest::from_preset(
                    Preset::named(&self.settings.display.theme).unwrap_or_default(),
                )
            },
            |theme| theme.manifest.clone(),
        );
        let prefs = self.settings.display.background().clone();
        let name = format!("{}.hermes-theme", manifest.id);
        let destination = cx.prompt_for_new_path(&directory, Some(&name));
        let runtime = self.runtime.clone();
        self.background_view.package_job = Some(cx.spawn(async move |view, cx| {
            let result = async {
                let Some(path) = destination.await.context(tr("保存对话框已关闭"))?? else {
                    return Ok(());
                };
                runtime
                    .spawn_blocking(move || {
                        let image = wallpaper_bytes(&prefs, installed.as_ref())?;
                        manifest.background = image.as_ref().map(|_| Wallpaper {
                            opacity: prefs.image_opacity(),
                        });
                        manifest.window_transparency = prefs.window_transparency();
                        theme_package::export(&path, &manifest, image.as_deref())
                    })
                    .await?
            }
            .await;
            let _ = view.update(cx, |desktop, cx| {
                desktop.background_view.package_job = None;
                desktop.background_view.error = result.err().map(|error| error.to_string().into());
                cx.notify();
            });
        }));
        cx.notify();
    }

    fn load_theme_image(&mut self, package: InstalledTheme, cx: &mut Context<Self>) {
        let job = self.runtime.spawn_blocking(move || -> Result<_> {
            render_encoded_image(&package.wallpaper()?, 3072, 2304)
        });
        self.background_view.job = Some(cx.spawn(async move |view, cx| {
            let result = job
                .await
                .context(tr("无法加载背景图"))
                .and_then(|result| result);
            let _ = view.update(cx, |desktop, cx| {
                desktop.background_view.job = None;
                match result {
                    Ok(image) => desktop.background_view.image = Some(image),
                    Err(error) => desktop.background_view.error = Some(error.to_string().into()),
                }
                cx.notify();
            });
        }));
    }

    fn background_preview(&self) -> Div {
        let line = |width| {
            div()
                .h(px(4.))
                .w(px(width))
                .rounded(px(2.))
                .bg(rgb(0x7f90a6).alpha(0.38))
        };
        div()
            .mt_2()
            .mb_2()
            .h(px(154.))
            .flex_none()
            .rounded(px(8.))
            .bg(rgb(0xdce6f4))
            .p_3()
            .child(
                div()
                    .relative()
                    .size_full()
                    .rounded(px(6.))
                    .border_1()
                    .border_color(rgb(0xd4dfef))
                    .shadow_sm()
                    .overflow_hidden()
                    .flex()
                    .flex_col()
                    .child(self.workspace_background())
                    .child(
                        div()
                            .relative()
                            .h(px(23.))
                            .flex_none()
                            .flex()
                            .items_center()
                            .px_2()
                            .bg(self.workspace_tint(0xf4f5f7, 0.48))
                            .child(svg_symbol(crate::icons::SIDEBAR_LEFT, 12., 0x647990)),
                    )
                    .child(
                        div()
                            .relative()
                            .flex_1()
                            .flex()
                            .child(
                                div()
                                    .w(px(78.))
                                    .p_2()
                                    .flex()
                                    .flex_col()
                                    .gap_2()
                                    .bg(self.workspace_tint(0xfafafa, 0.34))
                                    .child(line(39.))
                                    .child(line(47.))
                                    .child(line(34.)),
                            )
                            .child(
                                div()
                                    .min_w_0()
                                    .flex_1()
                                    .p_2()
                                    .flex()
                                    .flex_col()
                                    .gap_2()
                                    .child(
                                        div()
                                            .h(px(19.))
                                            .rounded(px(4.))
                                            .bg(rgb(0xe8f1fc).alpha(0.76))
                                            .flex()
                                            .items_center()
                                            .px_2()
                                            .child(line(88.)),
                                    )
                                    .child(line(120.))
                                    .child(line(94.)),
                            ),
                    ),
            )
    }
}

pub(super) fn wallpaper_bytes(
    prefs: &BackgroundPreferences,
    installed: Option<&InstalledTheme>,
) -> Result<Option<Vec<u8>>> {
    if let Some(image) = prefs.builtin_image {
        Ok(Some(image.bytes().to_vec()))
    } else if let Some(path) = &prefs.image {
        read_local_image(path).map(Some)
    } else if prefs.use_theme_image {
        installed.map(InstalledTheme::wallpaper).transpose()
    } else {
        Ok(None)
    }
}

pub(super) fn apply_theme(
    display: &mut DisplayPreferences,
    installed: &[InstalledTheme],
    cx: &mut gpui::App,
) {
    if let Some(entry) = installed
        .iter()
        .find(|entry| entry.manifest.id == display.theme)
    {
        let manifest = &entry.manifest;
        display
            .theme_backgrounds
            .entry(manifest.id.clone())
            .or_insert_with(|| manifest.preferences());
        theme::apply(manifest.appearance, manifest.colors, &manifest.fonts, cx);
        return;
    }
    let preset = Preset::named(&display.theme).unwrap_or_default();
    display.theme = preset.id().to_owned();
    theme::apply(
        preset.appearance(),
        preset.palette(),
        &theme::Fonts::default(),
        cx,
    );
}

fn theme_thumbnail(palette: Palette) -> Div {
    div()
        .rounded(px(4.))
        .overflow_hidden()
        .h(px(36.))
        .flex()
        .flex_col()
        .bg(gpui::rgb(palette.canvas))
        .child(
            div()
                .h(px(9.))
                .flex_none()
                .bg(gpui::rgb(palette.chrome))
                .child(
                    div()
                        .ml_2()
                        .h_full()
                        .w(px(22.))
                        .bg(gpui::rgb(palette.surface))
                        .border_b_1()
                        .border_color(gpui::rgb(palette.accent)),
                ),
        )
        .child(
            div()
                .flex()
                .flex_1()
                .child(div().w(px(12.)).h_full().bg(gpui::rgb(palette.surface)))
                .child(
                    div().flex_1().px_1().pt_1().child(
                        div()
                            .h(px(7.))
                            .w_full()
                            .rounded(px(2.))
                            .bg(gpui::rgb(palette.message)),
                    ),
                ),
        )
}

fn opacity_control(
    state: &gpui::Entity<SliderState>,
    label: &'static str,
    value: u8,
    enabled: bool,
) -> Div {
    div()
        .flex()
        .items_center()
        .gap_3()
        .child(
            div().w(px(126.)).child(
                Slider::new(state)
                    .accessibility_label(label)
                    .disabled(!enabled)
                    .w_full(),
            ),
        )
        .child(
            div()
                .w(px(34.))
                .text_right()
                .text_size(px(12.))
                .text_color(ink(if enabled { 0x41608a } else { 0x77859a }))
                .child(format!("{value}%")),
        )
}
