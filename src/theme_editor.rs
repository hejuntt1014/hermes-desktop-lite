use anyhow::Result;
use gpui::{Context, Div, Entity, Rgba, Subscription, Task, Window, div, prelude::*, px};
use gpui_component::{
    Sizable,
    color_picker::{ColorPickerEvent, ColorPickerState, ColorSelect},
    input::{Input, InputEvent, InputState},
};

use crate::{
    i18n::text as tr,
    theme::{self, Appearance, Fonts, Palette, Preset, ink, rgb},
    theme_package::{InstalledTheme, Manifest, Wallpaper},
};

use super::{
    Desktop,
    background_view::{apply_theme, wallpaper_bytes},
    settings_view::setting_row,
    view::control,
};

#[derive(Clone, Copy)]
enum Role {
    Accent,
    Canvas,
    Foreground,
    Message,
    Chrome,
    Sidebar,
    Surface,
    Composer,
    Code,
    Selection,
    Line,
    Muted,
    Primary,
    Link,
    Positive,
    Warning,
    Danger,
}

impl Role {
    const ALL: [Self; 17] = [
        Self::Accent,
        Self::Canvas,
        Self::Foreground,
        Self::Message,
        Self::Chrome,
        Self::Sidebar,
        Self::Surface,
        Self::Composer,
        Self::Code,
        Self::Selection,
        Self::Line,
        Self::Muted,
        Self::Primary,
        Self::Link,
        Self::Positive,
        Self::Warning,
        Self::Danger,
    ];
    const BOTTOM: usize = 4;

    fn label(self) -> &'static str {
        match self {
            Self::Accent => tr("强调色"),
            Self::Canvas => tr("窗口背景色"),
            Self::Foreground => tr("文字色"),
            Self::Message => tr("用户消息气泡"),
            Self::Chrome => tr("标签栏"),
            Self::Sidebar => tr("侧栏背景"),
            Self::Surface => tr("弹窗和面板"),
            Self::Composer => tr("输入框背景"),
            Self::Code => tr("代码块背景"),
            Self::Selection => tr("选中项"),
            Self::Line => tr("边框"),
            Self::Muted => tr("次要文字"),
            Self::Primary => tr("按钮填充色"),
            Self::Link => tr("链接色"),
            Self::Positive => tr("成功状态"),
            Self::Warning => tr("警告状态"),
            Self::Danger => tr("错误状态"),
        }
    }

    fn color(self, colors: Palette) -> u32 {
        match self {
            Self::Accent => colors.accent,
            Self::Canvas => colors.canvas,
            Self::Foreground => colors.foreground,
            Self::Message => colors.message,
            Self::Chrome => colors.chrome,
            Self::Sidebar => colors.sidebar.unwrap_or(colors.surface),
            Self::Surface => colors.surface,
            Self::Composer => colors.composer.unwrap_or(colors.surface),
            Self::Code => colors.code.unwrap_or(colors.surface),
            Self::Selection => colors.selection,
            Self::Line => colors.line,
            Self::Muted => colors.muted,
            Self::Primary => colors.primary,
            Self::Link => colors.link,
            Self::Positive => colors.positive,
            Self::Warning => colors.warning,
            Self::Danger => colors.danger,
        }
    }

    fn set(self, colors: &mut Palette, value: u32) {
        match self {
            Self::Accent => colors.accent = value,
            Self::Canvas => colors.canvas = value,
            Self::Foreground => colors.foreground = value,
            Self::Message => colors.message = value,
            Self::Chrome => colors.chrome = value,
            Self::Sidebar => colors.sidebar = Some(value),
            Self::Surface => colors.surface = value,
            Self::Composer => colors.composer = Some(value),
            Self::Code => colors.code = Some(value),
            Self::Selection => colors.selection = value,
            Self::Line => colors.line = value,
            Self::Muted => colors.muted = value,
            Self::Primary => colors.primary = value,
            Self::Link => colors.link = value,
            Self::Positive => colors.positive = value,
            Self::Warning => colors.warning = value,
            Self::Danger => colors.danger = value,
        }
    }

    fn restore(self, colors: &mut Palette, source: Palette) {
        match self {
            Self::Accent => colors.accent = source.accent,
            Self::Canvas => colors.canvas = source.canvas,
            Self::Foreground => colors.foreground = source.foreground,
            Self::Message => colors.message = source.message,
            Self::Chrome => colors.chrome = source.chrome,
            Self::Sidebar => colors.sidebar = source.sidebar,
            Self::Surface => colors.surface = source.surface,
            Self::Composer => colors.composer = source.composer,
            Self::Code => colors.code = source.code,
            Self::Selection => colors.selection = source.selection,
            Self::Line => colors.line = source.line,
            Self::Muted => colors.muted = source.muted,
            Self::Primary => colors.primary = source.primary,
            Self::Link => colors.link = source.link,
            Self::Positive => colors.positive = source.positive,
            Self::Warning => colors.warning = source.warning,
            Self::Danger => colors.danger = source.danger,
        }
    }
}

pub(super) struct ThemeEditor {
    original: Manifest,
    draft: Manifest,
    controls: Vec<Entity<ColorPickerState>>,
    name: Entity<InputState>,
    interface: Entity<InputState>,
    code: Entity<InputState>,
    font_names: Vec<String>,
    advanced: bool,
    invalid_font: bool,
    error: Option<String>,
    job: Option<Task<()>>,
    _subscriptions: Vec<Subscription>,
}

impl Desktop {
    pub(super) fn edit_theme(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let original = self.installed_theme().map_or_else(
            || {
                Manifest::from_preset(
                    Preset::named(&self.settings.display.theme).unwrap_or_default(),
                )
            },
            |theme| theme.manifest.clone(),
        );
        let mut draft = original.clone();
        draft.id = format!("custom-{}", uuid::Uuid::new_v4().simple());
        let copy_name = format!("{} · {}", original.name, tr("副本"));
        let name = cx.new(|cx| {
            InputState::new(window, cx)
                .placeholder(tr("主题名称"))
                .default_value(copy_name)
        });
        let interface = cx.new(|cx| {
            InputState::new(window, cx)
                .placeholder(tr("系统字体"))
                .default_value(original.fonts.interface.clone().unwrap_or_default())
        });
        let code = cx.new(|cx| {
            InputState::new(window, cx)
                .placeholder(tr("系统字体"))
                .default_value(original.fonts.code.clone().unwrap_or_default())
        });
        let mut subscriptions = Vec::new();
        let controls = Role::ALL
            .into_iter()
            .map(|role| {
                let color = cx.new(|cx| {
                    ColorPickerState::new(window, cx)
                        .default_value(gpui::rgb(role.color(original.colors)))
                });
                subscriptions.push(cx.subscribe(
                    &color,
                    move |desktop, _, event: &ColorPickerEvent, cx| {
                        if let ColorPickerEvent::Change(Some(color)) = event
                            && let Some(editor) = desktop.theme_editor.as_mut()
                        {
                            role.set(&mut editor.draft.colors, to_rgb(*color));
                            desktop.preview_theme(cx);
                        }
                    },
                ));
                color
            })
            .collect();
        for input in [&interface, &code] {
            subscriptions.push(cx.subscribe(input, |desktop, _, event: &InputEvent, cx| {
                if let InputEvent::Change = event {
                    desktop.preview_theme(cx);
                }
            }));
        }
        subscriptions.push(cx.subscribe(&name, |_, _, _: &InputEvent, cx| cx.notify()));
        self.theme_editor = Some(ThemeEditor {
            original,
            draft,
            controls,
            name,
            interface,
            code,
            font_names: cx.text_system().all_font_names(),
            advanced: false,
            invalid_font: false,
            error: None,
            job: None,
            _subscriptions: subscriptions,
        });
        cx.notify();
    }

    fn preview_theme(&mut self, cx: &mut Context<Self>) {
        if let Some(editor) = &mut self.theme_editor {
            let font = |input: &Entity<InputState>| {
                let value = input.read(cx).value();
                let value = value.trim();
                if value.is_empty() {
                    return Ok(None);
                }
                editor
                    .font_names
                    .iter()
                    .find(|family| family.eq_ignore_ascii_case(value))
                    .map(|family| Some(family.clone()))
                    .ok_or(())
            };
            let fonts = (font(&editor.interface), font(&editor.code));
            editor.invalid_font = fonts.0.is_err() || fonts.1.is_err();
            editor.draft.fonts = Fonts {
                interface: fonts.0.unwrap_or_default(),
                code: fonts.1.unwrap_or_default(),
            };
            theme::apply(
                editor.draft.appearance,
                editor.draft.colors,
                &editor.draft.fonts,
                cx,
            );
            self.remeasure_transcript();
            cx.notify();
        }
    }

    pub(super) fn cancel_theme_edit(&mut self, cx: &mut Context<Self>) {
        if let Some(editor) = self.theme_editor.take() {
            if editor.job.is_some() {
                self.theme_editor = Some(editor);
                return;
            }
            apply_theme(
                &mut self.settings.display,
                &self.background_view.installed,
                cx,
            );
            self.remeasure_transcript();
            cx.notify();
        }
    }

    pub(super) fn theme_saving(&self) -> bool {
        self.theme_editor
            .as_ref()
            .is_some_and(|editor| editor.job.is_some())
    }

    fn save_theme_edit(&mut self, window: &Window, cx: &mut Context<Self>) {
        let Some(editor) = self.theme_editor.as_ref() else {
            return;
        };
        let name = editor.name.read(cx).value().trim().to_owned();
        if name.is_empty() || editor.invalid_font || editor.job.is_some() {
            return;
        }
        let mut draft = editor.draft.clone();
        draft.name = name;
        let prefs = self.settings.display.background().clone();
        let source = self.installed_theme().cloned();
        let saved_preferences = prefs.clone();
        let pending = self
            .runtime
            .spawn_blocking(move || -> Result<InstalledTheme> {
                // Local wallpapers stay linked by path or built-in ID. Only an existing
                // package wallpaper needs to travel with a locally saved copy.
                let image = if prefs.use_theme_image {
                    wallpaper_bytes(&prefs, source.as_ref())?
                } else {
                    None
                };
                draft.background = image.as_ref().map(|_| Wallpaper {
                    opacity: prefs.image_opacity(),
                });
                draft.window_transparency = prefs.window_transparency();
                InstalledTheme::create(&draft, image.as_deref())
            });
        let task = cx.spawn_in(window, async move |view, cx| {
            let result = pending
                .await
                .map_err(anyhow::Error::from)
                .and_then(|result| result);
            let _ = view.update_in(cx, |desktop, window, cx| {
                match result {
                    Ok(package) => {
                        let id = package.manifest.id.clone();
                        desktop.theme_editor = None;
                        desktop
                            .settings
                            .display
                            .theme_backgrounds
                            .insert(id.clone(), saved_preferences);
                        desktop.background_view.installed.push(package);
                        desktop.background_view.installed.sort_by(|a, b| {
                            (&a.manifest.name, &a.manifest.id)
                                .cmp(&(&b.manifest.name, &b.manifest.id))
                        });
                        desktop.select_theme(&id, window, cx);
                    }
                    Err(error) => {
                        if let Some(editor) = desktop.theme_editor.as_mut() {
                            editor.job = None;
                            editor.error = Some(error.to_string());
                        }
                    }
                }
                cx.notify();
            });
        });
        if let Some(editor) = self.theme_editor.as_mut() {
            editor.job = Some(task);
        }
        cx.notify();
    }

    pub(super) fn theme_editor_view(&self, cx: &mut Context<Self>) -> Div {
        let editor = self.theme_editor.as_ref().expect("editor is open");
        let ready = editor.job.is_none()
            && !editor.invalid_font
            && !editor.name.read(cx).value().trim().is_empty();
        div()
            .flex()
            .flex_col()
            .pb_3()
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap_2()
                    .py_2()
                    .child(Input::new(&editor.name).small().w(px(184.)))
                    .child(div().flex_1())
                    .child(
                        control("cancel-theme-edit", tr("取消")).on_click(
                            cx.listener(|desktop, _, _, cx| desktop.cancel_theme_edit(cx)),
                        ),
                    )
                    .child(
                        control(
                            "save-theme-copy",
                            if editor.job.is_some() {
                                tr("正在保存…")
                            } else {
                                tr("另存为主题")
                            },
                        )
                        .bg(if ready {
                            theme::primary()
                        } else {
                            rgb(0xe4e7ed)
                        })
                        .text_color(if ready {
                            gpui::rgb(0xffffff)
                        } else {
                            ink(0x68768b)
                        })
                        .when(ready, |button| {
                            button.on_click(cx.listener(|desktop, _, window, cx| {
                                desktop.save_theme_edit(window, cx)
                            }))
                        }),
                    ),
            )
            .child(self.theme_editor_preview(editor.draft.colors))
            .children((0..Role::BOTTOM).map(|index| self.theme_color_row(editor, index, cx)))
            .child(setting_row(
                tr("界面字体"),
                None,
                font_field(&editor.interface, cx),
            ))
            .child(setting_row(
                tr("代码字体"),
                None,
                font_field(&editor.code, cx),
            ))
            .children(editor.invalid_font.then(|| {
                div()
                    .pt_2()
                    .text_size(px(11.))
                    .text_color(ink(0x9d3c32))
                    .child(tr("请输入本机已安装的字体名称。"))
            }))
            .child(
                control(
                    "advanced-theme-settings",
                    if editor.advanced {
                        tr("收起高级配色")
                    } else {
                        tr("高级配色")
                    },
                )
                .mt_2()
                .on_click(cx.listener(|desktop, _, _, cx| {
                    if let Some(editor) = desktop.theme_editor.as_mut() {
                        editor.advanced = !editor.advanced;
                        cx.notify();
                    }
                })),
            )
            .when(editor.advanced, |panel| {
                panel
                    .child(setting_row(
                        tr("主题明暗"),
                        None,
                        div().flex().gap_2().children(
                            [
                                (Appearance::Light, tr("浅色")),
                                (Appearance::Dark, tr("深色")),
                            ]
                            .into_iter()
                            .map(|(appearance, label)| {
                                control(("edit-theme-mode", appearance as usize), label)
                                    .bg(rgb(if editor.draft.appearance == appearance {
                                        0xe2e9f7
                                    } else {
                                        0xffffff
                                    }))
                                    .on_click(cx.listener(move |desktop, _, _, cx| {
                                        if let Some(editor) = desktop.theme_editor.as_mut() {
                                            editor.draft.appearance = appearance;
                                            desktop.preview_theme(cx);
                                        }
                                    }))
                            }),
                        ),
                    ))
                    .children(
                        (Role::BOTTOM..Role::ALL.len())
                            .map(|index| self.theme_color_row(editor, index, cx)),
                    )
            })
            .children(
                editor
                    .error
                    .as_ref()
                    .map(|error| div().pt_2().text_color(ink(0x9d3c32)).child(error.clone())),
            )
    }

    fn theme_color_row(&self, editor: &ThemeEditor, index: usize, cx: &mut Context<Self>) -> Div {
        let role = Role::ALL[index];
        let original = role.color(editor.original.colors);
        setting_row(
            role.label(),
            None,
            div()
                .flex()
                .items_center()
                .gap_2()
                .child(
                    ColorSelect::new(&editor.controls[index])
                        .small()
                        .w(px(130.))
                        .accessibility_label(role.label()),
                )
                .child(
                    div()
                        .id(("restore-theme-color", index))
                        .cursor_pointer()
                        .text_color(ink(0x68768b))
                        .text_size(px(11.))
                        .child(tr("还原颜色"))
                        .on_click(cx.listener(move |desktop, _, window, cx| {
                            if let Some(editor) = desktop.theme_editor.as_mut() {
                                role.restore(&mut editor.draft.colors, editor.original.colors);
                                editor.controls[index].update(cx, |picker, cx| {
                                    picker.set_value(gpui::rgb(original), window, cx)
                                });
                                desktop.preview_theme(cx);
                            }
                        })),
                ),
        )
    }

    fn theme_editor_preview(&self, colors: Palette) -> Div {
        div()
            .relative()
            .overflow_hidden()
            .rounded(px(8.))
            .border_1()
            .border_color(gpui::rgb(colors.line))
            .mb_2()
            .font(crate::style::interface_font())
            .text_size(px(12.))
            .text_color(gpui::rgb(colors.foreground))
            .child(self.workspace_background())
            .child(
                div()
                    .relative()
                    .bg(gpui::rgb(colors.chrome).alpha(0.88))
                    .border_b_1()
                    .border_color(gpui::rgb(colors.accent))
                    .px_3()
                    .py_1()
                    .child(tr("会话预览")),
            )
            .child(
                div()
                    .relative()
                    .flex()
                    .child(
                        div()
                            .w(px(89.))
                            .flex_none()
                            .bg(theme::sidebar(0xfafafa).alpha(0.86))
                            .p_2()
                            .child(
                                div()
                                    .rounded(px(4.))
                                    .px_2()
                                    .py_1()
                                    .bg(gpui::rgb(colors.selection))
                                    .child(tr("新会话")),
                            ),
                    )
                    .child(
                        div()
                            .min_w_0()
                            .flex_1()
                            .flex()
                            .flex_col()
                            .gap_2()
                            .p_3()
                            .child(
                                div()
                                    .bg(gpui::rgb(colors.message).alpha(0.92))
                                    .rounded(px(5.))
                                    .px_2()
                                    .py_1()
                                    .child(tr("这个配色读起来舒服吗？")),
                            )
                            .child(div().child(tr("试试在壁纸上同时阅读普通文字和代码。")))
                            .child(
                                div()
                                    .bg(gpui::rgb(colors.code.unwrap_or(colors.surface))
                                        .alpha(0.86))
                                    .rounded(px(5.))
                                    .px_2()
                                    .py_1()
                                    .font_family(theme::code_family())
                                    .child("let theme = \"Hermes Lite\";"),
                            ),
                    ),
            )
    }
}

fn font_field(field: &Entity<InputState>, cx: &mut Context<Desktop>) -> Div {
    let field = field.clone();
    div()
        .flex()
        .items_center()
        .gap_2()
        .child(Input::new(&field).small().w(px(154.)))
        .child(
            control(("reset-theme-font", field.entity_id()), tr("系统字体")).on_click(cx.listener(
                move |_, _, window, cx| {
                    field.update(cx, |input, cx| input.set_value("", window, cx))
                },
            )),
        )
}

fn to_rgb(color: gpui::Hsla) -> u32 {
    let Rgba { r, g, b, .. } = Rgba::from(color);
    let byte = |value: f32| (value * 255.).round() as u32;
    byte(r) << 16 | byte(g) << 8 | byte(b)
}
