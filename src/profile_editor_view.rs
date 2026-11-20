use crate::theme::{ink, rgb, rgba};

use crate::i18n::text as tr;

use gpui::{
    Anchor, ClipboardItem, Context, Div, IntoElement, SharedString, Stateful, Styled, Window, div,
    prelude::*, px,
};
use gpui_component::{
    Disableable, Sizable,
    button::{Button, ButtonVariants},
    input::{Input, Textarea},
    menu::{DropdownMenu, PopupMenuItem},
};

use crate::{
    app::{profile_editor::NewProfile, profiles::Profile},
};

use super::{
    ACCENT, DANGER, Desktop, INK, LINE, MUTED, SECONDARY, SELECTED, control, icon_button, icons,
    panel, primary, svg_symbol,
};

impl Desktop {
    pub(super) fn profile_editor_overlay(
        &self,
        window: &Window,
        cx: &mut Context<Self>,
    ) -> Option<Stateful<Div>> {
        if !self.profile_editor.open {
            return None;
        }
        let size = super::workspace_dialog_size(window);
        let entries = &self.profiles.entries;
        let query = self
            .profile_editor
            .search
            .as_ref()
            .map(|field| field.read(cx).value().trim().to_lowercase())
            .unwrap_or_default();
        let matches: Vec<_> = entries
            .iter()
            .filter(|profile| {
                profile.name.to_lowercase().contains(&query)
                    || profile.label.to_lowercase().contains(&query)
                    || profile
                        .model
                        .as_ref()
                        .is_some_and(|model| model.id.to_lowercase().contains(&query))
            })
            .collect();
        let content = if let Some(form) = self.profile_editor.create.as_ref() {
            self.profile_create_form(form, cx)
        } else {
            let selection = entries
                .iter()
                .find(|profile| profile.name == self.profile_editor.selected);
            self.profile_detail(selection, cx)
        };
        Some(
            div()
                .id("profile-editor-backdrop")
                .absolute()
                .left_0()
                .right_0()
                .top(px(34.))
                .bottom(px(23.))
                .occlude()
                .bg(rgba(0x28374d3d))
                .flex()
                .items_center()
                .justify_center()
                .on_click(cx.listener(|this, _, window, cx| this.close_profile_editor(window, cx)))
                .child(
                    panel()
                        .id("profile-editor")
                        .w(size.width.min(px(910.)))
                        .h(size.height.min(px(650.)))
                        .min_h_0()
                        .overflow_hidden()
                        .shadow_lg()
                        .flex()
                        .flex_col()
                        .on_click(|_, _, cx| cx.stop_propagation())
                        .child(
                            div()
                                .flex_none()
                                .h(px(47.))
                                .px_3()
                                .flex()
                                .items_center()
                                .gap_2()
                                .border_b_1()
                                .border_color(rgb(LINE))
                                .child(svg_symbol(icons::PROFILE_CARD, 17., ACCENT))
                                .child(
                                    div()
                                        .text_size(px(14.))
                                        .font_weight(gpui::FontWeight::SEMIBOLD)
                                        .text_color(ink(INK))
                                        .child(tr("配置档案")),
                                )
                                .children((!entries.is_empty()).then(|| {
                                    muted(crate::i18n::format_text!(
                                        "{} 个档案",
                                        "{} profile(s)",
                                        entries.len()
                                    ))
                                }))
                                .child(div().flex_1())
                                .child(
                                    icon_button(
                                        "reload-profile-roster",
                                        icons::REFRESH,
                                        tr("刷新配置档案列表"),
                                    )
                                    .on_click(cx.listener(
                                        |this, _, window, cx| this.load_profiles(window, cx),
                                    )),
                                )
                                .child(
                                    icon_button(
                                        "close-profile-editor",
                                        icons::TAB_CLOSE,
                                        tr("关闭配置档案"),
                                    )
                                    .on_click(cx.listener(
                                        |this, _, window, cx| this.close_profile_editor(window, cx),
                                    )),
                                ),
                        )
                        .child(
                            div()
                                .flex()
                                .flex_1()
                                .min_h_0()
                                .child(
                                    div()
                                        .w((size.width * 0.25).clamp(px(125.), px(207.)))
                                        .min_h_0()
                                        .flex_none()
                                        .flex()
                                        .flex_col()
                                        .bg(rgb(0xf7f9fc))
                                        .border_r_1()
                                        .border_color(rgb(LINE))
                                        .children(self.profile_editor.search.as_ref().map(
                                            |field| {
                                                div().flex_none().px_2().pt_2().pb_1().child(
                                                    div()
                                                        .h(px(31.))
                                                        .px_2()
                                                        .rounded(px(5.))
                                                        .bg(rgb(0xffffff))
                                                        .border_1()
                                                        .border_color(rgb(LINE))
                                                        .flex()
                                                        .items_center()
                                                        .gap_1()
                                                        .child(svg_symbol(
                                                            icons::SIDEBAR_SEARCH,
                                                            13.,
                                                            MUTED,
                                                        ))
                                                        .child(
                                                            div().min_w_0().flex_1().child(
                                                                Input::new(field)
                                                                    .small()
                                                                    .appearance(false)
                                                                    .bordered(false)
                                                                    .px_0(),
                                                            ),
                                                        ),
                                                )
                                            },
                                        ))
                                        .child(
                                            div()
                                                .id("profile-editor-list")
                                                .min_h_0()
                                                .flex_1()
                                                .overflow_y_scroll()
                                                .px_2()
                                                .pt_1()
                                                .children(matches.iter().map(|profile| {
                                                    self.profile_editor_row(profile, cx)
                                                }))
                                                .children(
                                                    (matches.is_empty() && !query.is_empty()).then(
                                                        || {
                                                            div()
                                                                .p_2()
                                                                .child(muted(tr("没有匹配的档案")))
                                                        },
                                                    ),
                                                ),
                                        )
                                        .child(
                                            div()
                                                .flex_none()
                                                .border_t_1()
                                                .border_color(rgb(LINE))
                                                .p_2()
                                                .child(
                                                    control("new-profile", tr("新建档案"))
                                                        .w_full()
                                                        .justify_start()
                                                        .gap_1()
                                                        .child(svg_symbol(icons::PLUS, 13., MUTED))
                                                        .on_click(cx.listener(
                                                            |this, _, window, cx| {
                                                                this.start_profile_create(
                                                                    window, cx,
                                                                )
                                                            },
                                                        )),
                                                ),
                                        ),
                                )
                                .child(div().flex_1().min_w_0().min_h_0().child(content)),
                        ),
                ),
        )
    }

    fn profile_editor_row(&self, profile: &Profile, cx: &mut Context<Self>) -> Stateful<Div> {
        let name = profile.name.clone();
        let selected = self.profile_editor.create.is_none() && name == self.profile_editor.selected;
        div()
            .id(SharedString::from(format!("profile-editor-row-{name}")))
            .h(px(34.))
            .px_2()
            .gap_2()
            .rounded(px(5.))
            .flex()
            .items_center()
            .cursor_pointer()
            .hover(|row| row.bg(rgb(0xebf0f8)))
            .when(selected, |row| row.bg(rgb(SELECTED)))
            .child(profile_avatar(profile))
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .truncate()
                    .text_size(px(12.))
                    .text_color(ink(SECONDARY))
                    .child(profile.label.clone()),
            )
            .on_click(cx.listener(move |this, _, window, cx| {
                this.select_profile_editor(name.clone(), window, cx)
            }))
    }

    fn profile_detail(
        &self,
        profile: Option<&Profile>,
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        let Some(profile) = profile else {
            return div()
                .size_full()
                .flex()
                .items_center()
                .justify_center()
                .child(muted(if self.out.is_none() {
                    tr("网关未连接")
                } else if self.profile_editor.roster_failed {
                    tr("无法读取配置档案，请刷新重试")
                } else {
                    tr("正在读取配置档案…")
                }))
                .into_any_element();
        };
        let page = self.profile_editor.pages.get(&profile.name);
        let loading = page.is_none_or(|page| page.loading);
        let saving = page.is_some_and(|page| page.saving);
        let conflict = page.is_some_and(|page| page.conflict);
        let connected = self.out.is_some();
        let buffer = page.and_then(|page| page.buffer.as_ref());
        let dirty = buffer.is_some_and(|buffer| buffer.changed(cx));
        let save_enabled = connected && dirty && !loading && !saving && !conflict;
        let reload_enabled = connected && !dirty && !saving && !loading;
        let subtitle = if profile.label.as_ref() == profile.name {
            None
        } else {
            Some(profile.name.clone())
        };
        let model = profile
            .model
            .as_ref()
            .map(|model| {
                if model.provider.is_empty() {
                    model.id.clone()
                } else {
                    format!("{}  ·  {}", model.id, model.provider)
                }
            })
            .unwrap_or_else(|| tr("跟随网关默认模型").into());
        let count = profile
            .skill_count
            .map(|count| count.to_string())
            .unwrap_or_else(|| "—".into());
        let detail = div()
            .id("profile-detail-scroll")
            .size_full()
            .overflow_y_scroll()
            .px_4()
            .py_4()
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap_2()
                    .flex_wrap()
                    .child(
                        div()
                            .text_size(px(17.))
                            .font_weight(gpui::FontWeight::SEMIBOLD)
                            .text_color(ink(INK))
                            .child(profile.label.clone()),
                    )
                    .children(subtitle.map(muted))
                    .children(
                        profile
                            .is_default
                            .then(|| badge(tr("默认"), 0xe7efff, ACCENT)),
                    )
                    .children(profile.has_env.then(|| badge(".env", 0xedf0f4, MUTED))),
            )
            .children(
                (!profile.path.is_empty())
                    .then(|| muted(profile.path.clone()).font_family(crate::theme::code_family()).pt_1()),
            )
            .child(
                div()
                    .pt_3()
                    .pb_3()
                    .flex()
                    .flex_col()
                    .gap_1()
                    .border_b_1()
                    .border_color(rgb(LINE))
                    .child(meta(tr("模型"), model))
                    .child(meta(tr("技能"), count)),
            )
            .child(self.profile_document_toolbar(cx));
        if let Some(file) = self.profile_editor.memory_file {
            return detail
                .child(self.memory_document(file, cx))
                .into_any_element();
        }
        detail
            .child(
                div()
                    .pt_3()
                    .flex()
                    .items_center()
                    .gap_2()
                    .child(
                        div()
                            .flex_1()
                            .text_size(px(12.))
                            .font_family(crate::theme::code_family())
                            .font_weight(gpui::FontWeight::SEMIBOLD)
                            .text_color(ink(INK))
                            .child("SOUL.md"),
                    )
                    .children(reload_enabled.then(|| {
                        icon_button(
                            "reload-profile-soul",
                            icons::REFRESH,
                            tr("重新读取 SOUL.md"),
                        )
                        .size(px(22.))
                        .on_click(cx.listener(|this, _, window, cx| {
                            this.load_profile_soul(true, window, cx)
                        }))
                    })),
            )
            .child(muted(tr("为这个档案设置人格和行为指令。")).pb_2())
            .children(buffer.map(|buffer| {
                div().child(
                    Textarea::new(&buffer.field)
                        .w_full()
                        .small()
                        .text_size(px(13.))
                        .line_height(px(20.))
                        .disabled(loading || saving),
                )
            }))
            .children(buffer.is_none().then(|| {
                div()
                    .h(px(160.))
                    .rounded(px(6.))
                    .border_1()
                    .border_color(rgb(LINE))
                    .bg(rgb(0xf9fafc))
                    .flex()
                    .items_center()
                    .justify_center()
                    .child(muted(if loading {
                        tr("正在读取 SOUL.md…")
                    } else {
                        tr("未能读取 SOUL.md")
                    }))
            }))
            .children(
                page.and_then(|page| page.error.clone())
                    .map(|error| div().pt_2().child(error_line(error))),
            )
            .children(conflict.then(|| {
                let copy = buffer.map(|buffer| buffer.field.clone());
                div()
                    .pt_2()
                    .flex()
                    .gap_2()
                    .flex_wrap()
                    .child(control("copy-profile-draft", tr("复制草稿")).on_click(
                        move |_, _, cx| {
                            if let Some(field) = &copy {
                                cx.write_to_clipboard(ClipboardItem::new_string(
                                    field.read(cx).value().to_string(),
                                ));
                            }
                        },
                    ))
                    .child(
                        control("use-remote-profile-soul", tr("载入远端版本")).on_click(
                            cx.listener(|this, _, window, cx| {
                                this.load_profile_soul(true, window, cx);
                            }),
                        ),
                    )
            }))
            .child(
                div()
                    .pt_2()
                    .flex()
                    .items_center()
                    .gap_2()
                    .flex_wrap()
                    .child(
                        div().flex_1().min_w_0().children(
                            if !connected {
                                Some(tr("网关未连接"))
                            } else if saving {
                                Some(tr("正在保存…"))
                            } else if dirty {
                                Some(tr("有未保存的编辑"))
                            } else if page.is_some_and(|page| page.saved) {
                                Some(tr("已保存"))
                            } else if buffer.is_some_and(|buffer| !buffer.exists()) {
                                Some(tr("暂无 SOUL.md，保存后创建。"))
                            } else {
                                None
                            }
                            .map(muted),
                        ),
                    )
                    .child(
                        primary("save-profile-soul", tr("保存 SOUL.md"), save_enabled).on_click(
                            cx.listener(|this, _, window, cx| this.save_profile_soul(window, cx)),
                        ),
                    ),
            )
            .into_any_element()
    }

    fn profile_document_toolbar(&self, cx: &mut Context<Self>) -> Div {
        let state = &self.profile_editor;
        div()
            .flex()
            .flex_wrap()
            .items_center()
            .gap_2()
            .pt_3()
            .child(div().flex().flex_none().items_center().gap_1().children(
                ["SOUL.md", "MEMORY.md", "USER.md"].into_iter().map(|name| {
                    let file = (name != "SOUL.md").then_some(name);
                    control(name, name)
                        .when(state.memory_file == file, |button| {
                            button.bg(rgb(SELECTED)).text_color(ink(ACCENT))
                        })
                        .on_click(cx.listener(move |this, _, window, cx| {
                            this.select_profile_document(file, window, cx)
                        }))
                }),
            ))
            .children(
                state
                    .memory_file
                    .map(|file| self.memory_document_actions(file, cx)),
            )
    }

    fn memory_document_actions(&self, file: &'static str, cx: &mut Context<Self>) -> Div {
        let state = &self.profile_editor;
        let content = state
            .memory_text
            .as_ref()
            .and_then(|result| result.as_ref().ok());
        let copy = icon_button("memory-copy", icons::COPY, tr("复制原文")).size(px(28.));
        let copy = if let Some(text) = content {
            let text = text.clone();
            copy.on_click(move |_, _, cx| {
                cx.write_to_clipboard(ClipboardItem::new_string(text.clone()))
            })
        } else {
            copy.opacity(0.45)
                .cursor_default()
                .hover(|button| button.bg(gpui::transparent_black()))
        };
        div()
            .flex_1()
            .min_w(px(210.))
            .flex()
            .justify_end()
            .items_center()
            .gap_1()
            .children(state.memory_query.as_ref().map(|query| {
                div().w(px(184.)).min_w_0().child(
                    Styled::h(Input::new(query).small(), px(28.))
                        .bg(rgb(0xf8fafd))
                        .border_color(rgb(LINE))
                        .rounded(px(6.))
                        .prefix(svg_symbol(icons::SIDEBAR_SEARCH, 13., MUTED))
                        .cleanable(true),
                )
            }))
            .child(copy)
            .child(
                icon_button("memory-refresh", icons::REFRESH, tr("重新读取"))
                    .size(px(28.))
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.select_profile_document(Some(file), window, cx)
                    })),
            )
    }

    fn memory_document(&self, file: &'static str, cx: &Context<Self>) -> Div {
        let state = &self.profile_editor;
        let query = state
            .memory_query
            .as_ref()
            .map(|q| q.read(cx).value().trim().to_lowercase())
            .unwrap_or_default();
        let shown = match &state.memory_text {
            None => tr("正在读取…").into(),
            Some(Err(err)) => crate::i18n::format_text!(
                "无法读取 {file} · {err}",
                "Could not load {file} · {err}"
            ),
            Some(Ok(text)) if text.is_empty() => tr("暂无记忆").into(),
            Some(Ok(text)) if query.is_empty() => text.clone(),
            Some(Ok(text)) => {
                let hits = text
                    .lines()
                    .filter(|line| line.to_lowercase().contains(&query))
                    .collect::<Vec<_>>();
                if hits.is_empty() {
                    tr("没有匹配的内容").into()
                } else {
                    hits.join("\n")
                }
            }
        };
        div().pt_2().child(
            div()
                .p_3()
                .rounded(px(6.))
                .border_1()
                .border_color(rgb(LINE))
                .text_size(px(13.))
                .line_height(px(21.))
                .text_color(ink(INK))
                .child(shown),
        )
    }

    fn profile_create_form(&self, form: &NewProfile, cx: &mut Context<Self>) -> gpui::AnyElement {
        let desktop = cx.entity().downgrade();
        let profiles = self.profiles.entries.clone();
        let source = form.source.clone().unwrap_or_else(|| tr("空白档案").into());
        let choose_from = Button::new("profile-clone-source")
            .ghost()
            .compact()
            .disabled(form.busy)
            .border_1()
            .border_color(rgb(LINE))
            .w_full()
            .px_2()
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap_2()
                    .w_full()
                    .child(div().flex_1().truncate().child(source))
                    .child(svg_symbol(icons::CHEVRON_DOWN, 12., MUTED)),
            )
            .dropdown_menu_with_anchor(Anchor::TopLeft, move |mut menu, _, _| {
                for name in std::iter::once(None)
                    .chain(profiles.iter().map(|profile| Some(profile.name.clone())))
                {
                    let label = name.clone().unwrap_or_else(|| tr("空白档案").into());
                    let weak = desktop.clone();
                    menu = menu.item(PopupMenuItem::new(label).on_click(move |_, _, cx| {
                        let _ = weak.update(cx, |this, cx| {
                            if let Some(form) = this
                                .profile_editor
                                .create
                                .as_mut()
                                .filter(|form| !form.busy)
                            {
                                form.source.clone_from(&name);
                                cx.notify();
                            }
                        });
                    }));
                }
                menu
            });
        div()
            .id("profile-create-content")
            .size_full()
            .overflow_y_scroll()
            .p_4()
            .child(
                div()
                    .max_w(px(390.))
                    .flex()
                    .flex_col()
                    .gap_3()
                    .child(
                        div()
                            .text_size(px(16.))
                            .font_weight(gpui::FontWeight::SEMIBOLD)
                            .text_color(ink(INK))
                            .child(tr("新建配置档案")),
                    )
                    .child(
                        div()
                            .flex()
                            .flex_col()
                            .gap_1()
                            .child(muted(tr("档案名称")))
                            .child(Input::new(&form.name).small().disabled(form.busy)),
                    )
                    .child(
                        div()
                            .flex()
                            .flex_col()
                            .gap_1()
                            .child(muted(tr("复制自")))
                            .child(choose_from),
                    )
                    .children(form.error.clone().map(error_line))
                    .child(
                        div()
                            .flex()
                            .justify_end()
                            .items_center()
                            .gap_2()
                            .child(control("cancel-profile-create", tr("取消")).on_click(
                                cx.listener(|this, _, window, cx| {
                                    this.escape_profile_editor(window, cx)
                                }),
                            ))
                            .child(
                                primary(
                                    "create-profile",
                                    if form.busy {
                                        tr("正在创建…")
                                    } else {
                                        tr("创建档案")
                                    },
                                    !form.busy && self.out.is_some(),
                                )
                                .on_click(cx.listener(
                                    |this, _, window, cx| this.create_profile(window, cx),
                                )),
                            ),
                    ),
            )
            .into_any_element()
    }
}

fn muted(text: impl Into<SharedString>) -> Div {
    div()
        .text_size(px(11.5))
        .line_height(px(17.))
        .text_color(ink(MUTED))
        .child(text.into())
}

fn badge(text: &'static str, fill: u32, color: u32) -> Div {
    div()
        .flex_none()
        .px_2()
        .py(px(1.))
        .rounded_full()
        .bg(rgb(fill))
        .text_size(px(10.))
        .text_color(ink(color))
        .child(text)
}

fn meta(label: &'static str, value: String) -> Div {
    div()
        .flex()
        .items_start()
        .gap_2()
        .min_w_0()
        .child(muted(label).w(px(44.)).flex_none())
        .child(
            div()
                .min_w_0()
                .text_size(px(12.))
                .line_height(px(17.))
                .text_color(ink(SECONDARY))
                .child(value),
        )
}

fn error_line(error: SharedString) -> Div {
    div()
        .px_2()
        .py_1()
        .bg(rgb(0xfff2f0))
        .rounded(px(4.))
        .text_size(px(11.5))
        .line_height(px(17.))
        .text_color(ink(DANGER))
        .child(error)
}

fn profile_avatar(profile: &Profile) -> Div {
    const COLORS: &[(u32, u32)] = &[
        (0xe3edfa, 0x3c6d9f),
        (0xe0f0e9, 0x367b65),
        (0xeae8f9, 0x6e59a8),
        (0xf6e7e9, 0x9d5b71),
        (0xf7ecdd, 0x9c6a37),
    ];
    let color = profile
        .name
        .bytes()
        .fold(0usize, |sum, byte| sum.wrapping_add(usize::from(byte)))
        % COLORS.len();
    let (fill, foreground) = COLORS[color];
    div()
        .size(px(21.))
        .flex_none()
        .rounded(px(5.))
        .bg(rgb(fill))
        .text_color(ink(foreground))
        .flex()
        .items_center()
        .justify_center()
        .text_size(px(11.))
        .font_weight(gpui::FontWeight::SEMIBOLD)
        .child(if profile.is_default {
            svg_symbol(icons::PROFILE_CARD, 13., foreground).into_any_element()
        } else {
            profile
                .label
                .chars()
                .next()
                .unwrap_or('?')
                .to_uppercase()
                .collect::<String>()
                .into_any_element()
        })
}
