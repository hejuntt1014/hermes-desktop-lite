use gpui::{
    Anchor, AnyElement, App, Context, Div, Focusable, IntoElement, MouseButton, SharedString,
    WeakEntity, div, prelude::*, px, rgb, uniform_list,
};
use gpui_component::{
    Disableable, Sizable,
    button::{Button, ButtonVariants},
    input::Input,
    popover::Popover,
    switch::Switch,
    tooltip::Tooltip,
};

use super::{Desktop, INK, LINE, MUTED, SURFACE, control, panel, primary, svg_symbol};
use crate::{
    app::model_controls::{CatalogModel, CatalogState, Choice, Picker, speed_word},
    icons,
    settings::ModelChoice,
};

const EFFORTS: &[(&str, &str, &str)] = &[
    ("none", "Off", "关闭"),
    ("minimal", "Min", "最低"),
    ("low", "Low", "低"),
    ("medium", "Med", "中"),
    ("high", "High", "高"),
    ("xhigh", "XHigh", "极高"),
    ("max", "Max", "最大"),
    ("ultra", "Ultra", "超强"),
];
const MENU_LINE: u32 = 0xe1e5ed;
const MENU_MUTED: u32 = 0x6f7783;
const MENU_HOVER: u32 = 0xf0f2f6;
const MENU_SELECTED: u32 = 0xe6eaf2;
const MENU_ROW_HEIGHT: f32 = 25.;

fn short_effort(value: &str) -> &str {
    EFFORTS
        .iter()
        .find(|(key, _, _)| *key == value)
        .map_or(value, |(_, label, _)| *label)
}

enum CatalogRow {
    Provider(SharedString),
    Model(Box<ModelMenuRow>),
}

struct ModelMenuRow {
    entry: CatalogModel,
    favorite: bool,
    active: bool,
    options_open: bool,
    ultrafast: bool,
    effort: Option<String>,
    speed: Option<String>,
}

fn menu_surface() -> Div {
    div()
        .flex()
        .flex_col()
        .rounded(px(5.))
        .overflow_hidden()
        .border_1()
        .border_color(rgb(MENU_LINE))
        .bg(rgb(SURFACE))
        .shadow_md()
}

fn empty_menu(label: &str) -> Div {
    div()
        .px_2()
        .py_3()
        .text_size(px(12.))
        .text_color(rgb(MENU_MUTED))
        .child(label.to_owned())
}

fn section_title(title: &'static str) -> Div {
    div().px_2().pt_1().pb(px(2.)).child(section_label(title))
}

fn section_label(title: impl Into<SharedString>) -> Div {
    div()
        .text_size(px(10.))
        .font_weight(gpui::FontWeight::SEMIBOLD)
        .line_height(px(14.))
        .text_color(rgb(MENU_MUTED))
        .child(title.into())
}

fn option_row(id: &'static str, disabled: bool) -> gpui::Stateful<Div> {
    div()
        .id(id)
        .h(px(MENU_ROW_HEIGHT))
        .px_2()
        .gap_2()
        .flex()
        .items_center()
        .text_size(px(12.))
        .text_color(rgb(INK))
        .when(disabled, |row| row.opacity(0.52))
        .when(!disabled, |row| {
            row.cursor_pointer().hover(|row| row.bg(rgb(MENU_HOVER)))
        })
}

fn option_switch(
    id: &'static str,
    label: &'static str,
    checked: bool,
    enabled: bool,
    model: ModelChoice,
    desktop: &WeakEntity<Desktop>,
    choice: impl Fn(bool) -> Choice + 'static,
) -> gpui::Stateful<Div> {
    let owner = desktop.clone();
    option_row(id, !enabled)
        .child(div().flex_1().child(label))
        .child(
            Switch::new(SharedString::from(format!("{id}-switch")))
                .small()
                .checked(checked)
                .disabled(!enabled)
                .on_click(move |checked, _, cx| {
                    cx.stop_propagation();
                    let _ = owner.update(cx, |this, cx| {
                        this.edit_model_option(model.clone(), choice(*checked), cx);
                    });
                }),
        )
}

fn checkmark() -> Div {
    div()
        .flex_none()
        .text_color(rgb(0x485775))
        .text_size(px(13.))
        .child("✓")
}

fn model_matches_query(entry: &CatalogModel, tokens: &[&str]) -> bool {
    if tokens.is_empty() {
        return true;
    }
    let terms = format!(
        "{} {} {}",
        entry.choice.id, entry.choice.provider, entry.provider_name
    )
    .to_lowercase();
    tokens.iter().all(|token| terms.contains(token))
}

fn catalog_footer(desktop: &WeakEntity<Desktop>, follow_default: bool) -> Div {
    let refresh = desktop.clone();
    let follow = desktop.clone();
    div()
        .border_t_1()
        .border_color(rgb(MENU_LINE))
        .py_1()
        .when(follow_default, |footer| {
            footer.child(
                option_row("default-model", false)
                    .child(svg_symbol(icons::BACK, 13., MENU_MUTED))
                    .child("使用 Profile 默认模型")
                    .on_click(move |_, window, cx| {
                        let _ = follow.update(cx, |this, cx| {
                            this.follow_model_default(Picker::Model, window, cx)
                        });
                    }),
            )
        })
        .child(
            option_row("refresh-models", false)
                .text_color(rgb(MENU_MUTED))
                .child(svg_symbol(icons::REFRESH, 13., MENU_MUTED))
                .child("刷新模型")
                .on_click(move |_, _, cx| {
                    let _ = refresh.update(cx, |this, cx| this.load_models(true, cx));
                }),
        )
}

fn model_row(row: &ModelMenuRow, desktop: &WeakEntity<Desktop>, index: usize) -> AnyElement {
    let model = &row.entry.choice;
    let selected = model.clone();
    let favored = model.clone();
    let inspected = model.clone();
    let caret_choice = model.clone();
    let selection = desktop.clone();
    let favorite = desktop.clone();
    let hover = desktop.clone();
    let options = desktop.clone();
    let label = if row.favorite {
        "取消收藏"
    } else {
        "收藏模型"
    };
    let flash = model.provider == "deepseek" && model.id.ends_with("-flash");
    let available = row.entry.available;
    let settings_badge = row
        .speed
        .as_deref()
        .filter(|speed| matches!(*speed, "fast" | "ultrafast"))
        .map(|speed| {
            if speed == "ultrafast" {
                "Ultrafast"
            } else {
                "Fast"
            }
        });
    let effort_badge = row.effort.as_deref().map(short_effort).map(str::to_owned);
    div()
        .id(("model-row", index))
        .w_full()
        .h(px(MENU_ROW_HEIGHT))
        .px_1()
        .gap(px(4.))
        .flex()
        .items_center()
        .text_size(px(12.))
        .text_color(rgb(if available { INK } else { MENU_MUTED }))
        .when(row.active || row.options_open, |element| {
            element.bg(rgb(MENU_SELECTED))
        })
        .when(available, |element| {
            element
                .cursor_pointer()
                .hover(|element| element.bg(rgb(MENU_HOVER)))
                .on_hover(move |is_over, _, cx| {
                    if *is_over {
                        let _ =
                            hover.update(cx, |this, cx| this.inspect_model(inspected.clone(), cx));
                    }
                })
        })
        .child(
            div()
                .id("favorite-model")
                .aria_label(label)
                .size(px(18.))
                .flex_none()
                .flex()
                .items_center()
                .justify_center()
                .cursor_pointer()
                .rounded(px(3.))
                .hover(|element| element.bg(rgb(0xe1e6ef)))
                .tooltip(move |window, cx| Tooltip::new(label).build(window, cx))
                .child(svg_symbol(
                    if row.favorite {
                        icons::MODEL_STAR_FILLED
                    } else {
                        icons::MODEL_STAR
                    },
                    13.,
                    if row.favorite { 0x576b93 } else { 0x939caa },
                ))
                .on_click(move |_, _, cx| {
                    cx.stop_propagation();
                    let _ =
                        favorite.update(cx, |this, cx| this.toggle_model_favorite(&favored, cx));
                }),
        )
        .child(
            div()
                .flex_1()
                .min_w_0()
                .truncate()
                .child(model_label(&model.id)),
        )
        .when(flash, |element| element.child(model_tag("FLASH")))
        .when_some(settings_badge, |element, label| {
            element.child(model_tag(label))
        })
        .when(
            row.ultrafast && settings_badge != Some("Ultrafast"),
            |element| {
                element.child(
                    div()
                        .flex_none()
                        .child(svg_symbol(icons::ZAP, 11., 0x6376a4)),
                )
            },
        )
        .when_some(effort_badge, |element, label| {
            element.child(model_tag(label))
        })
        .when(row.active, |element| element.child(checkmark()))
        .when(available, |element| {
            element
                .child(
                    div()
                        .id("inspect-model")
                        .aria_label("模型选项")
                        .size(px(21.))
                        .flex_none()
                        .flex()
                        .items_center()
                        .justify_center()
                        .rounded(px(3.))
                        .hover(|button| button.bg(rgb(0xdde5f2)))
                        .child(svg_symbol(icons::CHEVRON_RIGHT, 11., MENU_MUTED))
                        .on_click(move |_, _, cx| {
                            cx.stop_propagation();
                            let _ = options.update(cx, |this, cx| {
                                this.inspect_model(caret_choice.clone(), cx)
                            });
                        }),
                )
                .on_click(move |_, window, cx| {
                    let _ = selection.update(cx, |this, cx| {
                        this.choose_model_setting(Choice::Model(selected.clone()), window, cx);
                    });
                })
        })
        .into_any_element()
}

fn model_tag(label: impl Into<SharedString>) -> Div {
    div()
        .flex_none()
        .rounded(px(3.))
        .bg(rgb(0xf2f4f8))
        .border_1()
        .border_color(rgb(0xe1e6ef))
        .px_1()
        .text_size(px(9.))
        .line_height(px(13.))
        .text_color(rgb(MENU_MUTED))
        .child(label.into())
}

fn model_label(id: &str) -> String {
    let name = id.rsplit('/').next().unwrap_or(id);
    match name {
        "deepseek-v4-pro" => return "DeepSeek V4 Pro".to_owned(),
        "deepseek-v4-flash" => return "DeepSeek V4 Flash".to_owned(),
        _ => {}
    }
    for (prefix, label) in [
        ("glm", "GLM"),
        ("gpt", "GPT"),
        ("qwen", "Qwen"),
        ("claude", "Claude"),
    ] {
        if let Some(suffix) = name.strip_prefix(prefix) {
            return format!("{label}{suffix}");
        }
    }
    name.to_owned()
}

impl Desktop {
    pub(in crate::app) fn shown_model(&self) -> Option<ModelChoice> {
        if let Some(key) = &self.selected {
            return self.sessions.get(key).and_then(|session| {
                session.next_model.clone().or_else(|| {
                    (!session.model.is_empty()).then(|| ModelChoice {
                        id: session.model.to_string(),
                        provider: session.provider.to_string(),
                    })
                })
            });
        }
        self.workspace()
            .and_then(|workspace| workspace.draft_launch.get(&self.key()))
            .and_then(|launch| launch.model.clone())
            .or_else(|| {
                self.menu_catalog()
                    .and_then(|catalog| catalog.current.clone())
            })
            .or_else(|| self.profile_model(self.active_profile()))
            .or_else(|| {
                (self.active_profile() == self.profiles.serving)
                    .then(|| self.model_controls.defaults.model.clone())
                    .flatten()
            })
    }

    fn shown_speed(&self) -> &str {
        if let Some(session) = self
            .selected
            .as_ref()
            .and_then(|key| self.sessions.get(key))
        {
            return speed_word(&session.speed);
        }
        self.workspace()
            .and_then(|workspace| workspace.draft_launch.get(&self.key()))
            .and_then(|launch| launch.speed.as_deref())
            .or_else(|| {
                (self.active_profile() == self.profiles.serving)
                    .then_some(self.model_controls.defaults.speed.as_deref())
                    .flatten()
            })
            .map_or("", speed_word)
    }

    fn shown_effort(&self) -> (Option<String>, Option<String>) {
        if let Some(session) = self
            .selected
            .as_ref()
            .and_then(|key| self.sessions.get(key))
        {
            return (
                session
                    .next_effort
                    .clone()
                    .or_else(|| (!session.effort.is_empty()).then(|| session.effort.to_string())),
                (session.next_effort.is_none() && !session.effort_on_wire.is_empty())
                    .then(|| session.effort_on_wire.to_string()),
            );
        }
        (
            self.workspace()
                .and_then(|workspace| workspace.draft_launch.get(&self.key()))
                .and_then(|launch| launch.effort.clone())
                .or_else(|| {
                    (self.active_profile() == self.profiles.serving)
                        .then(|| self.model_controls.defaults.effort.clone())
                        .flatten()
                }),
            None,
        )
    }

    pub(super) fn model_pills(&self, enabled: bool, cx: &mut Context<Self>) -> Div {
        let model = self.shown_model();
        let (effort, wire) = self.shown_effort();
        let effort_label = effort
            .as_deref()
            .map(|effort| {
                if let Some(wire) = wire.as_deref().filter(|wire| *wire != effort) {
                    format!("{}→{}", short_effort(effort), short_effort(wire))
                } else {
                    short_effort(effort).to_owned()
                }
            })
            .unwrap_or_else(|| "推理".into());
        let mut model_label = model
            .as_ref()
            .map(|model| model_label(&model.id))
            .unwrap_or_else(|| "模型".into());
        match self.shown_speed() {
            "fast" => model_label.push_str(" · 快速"),
            "ultrafast" => model_label.push_str(" · Ultrafast"),
            _ => {}
        }
        let session = self
            .selected
            .as_ref()
            .and_then(|key| self.sessions.get(key));
        let pending = self.model_controls.busy.contains(&self.key());
        let enabled = enabled && !pending;
        let model_tip = if pending {
            "正在应用会话设置".to_owned()
        } else if session.is_some_and(|session| session.next_model.is_some()) {
            "下一轮使用此模型".to_owned()
        } else {
            model
                .as_ref()
                .map(|model| {
                    self.menu_catalog()
                        .and_then(|catalog| {
                            catalog.models.iter().find(|entry| entry.matches(model))
                        })
                        .map_or_else(
                            || model.id.clone(),
                            |entry| format!("模型 · {}: {}", entry.provider_name, model.id),
                        )
                })
                .unwrap_or_else(|| "选择模型".into())
        };
        let effort_tip = if session.is_some_and(|session| session.next_effort.is_some()) {
            "下一轮使用此推理强度"
        } else {
            "设置推理强度"
        };
        div()
            .flex()
            .items_center()
            .gap(px(6.))
            .child(self.picker_pill(Picker::Model, model_label, model_tip.into(), enabled, cx))
            .child(self.picker_pill(Picker::Effort, effort_label, effort_tip.into(), enabled, cx))
    }

    fn picker_pill(
        &self,
        picker: Picker,
        label: String,
        tooltip: SharedString,
        enabled: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let id = if picker == Picker::Model {
            "composer-model"
        } else {
            "composer-effort"
        };
        let open = self.model_controls.picker == Some(picker);
        let button = Button::new(id)
            .ghost()
            .compact()
            .small()
            .h(px(26.))
            .tooltip(tooltip)
            .disabled(!enabled)
            .child(
                div()
                    .max_w(px(184.))
                    .flex()
                    .items_center()
                    .gap_1()
                    .text_size(px(12.))
                    .text_color(rgb(if open { INK } else { MUTED }))
                    .child(div().min_w_0().truncate().child(label))
                    .child(svg_symbol(icons::CHEVRON_DOWN, 10., MENU_MUTED)),
            );
        if !enabled && !open {
            return button.into_any_element();
        }
        let desktop = cx.entity().downgrade();
        let on_open = desktop.clone();
        let mut popover = Popover::new(id)
            .anchor(Anchor::BottomRight)
            .appearance(false)
            .open(open)
            .on_open_change(move |open, window, cx| {
                let _ =
                    on_open.update(cx, |this, cx| this.picker_opened(picker, *open, window, cx));
            })
            .trigger(button)
            .content(move |_, _, cx| {
                let Some(view) = desktop.upgrade() else {
                    return div().into_any_element();
                };
                let closer = desktop.clone();
                let this = view.read(cx);
                let menu = if picker == Picker::Model {
                    this.model_catalog_panel(&desktop, cx)
                } else {
                    this.effort_picker_panel(&desktop)
                };
                div()
                    .id("composer-model-menu")
                    .child(menu)
                    .on_mouse_down_out(move |event, window, cx| {
                        if event.button == MouseButton::Left {
                            let _ = closer.update(cx, |this, cx| {
                                this.picker_opened(picker, false, window, cx)
                            });
                        }
                    })
                    .into_any_element()
            });
        if picker == Picker::Model {
            popover = popover.track_focus(&self.model_controls.search.read(cx).focus_handle(cx));
        }
        popover.into_any_element()
    }

    fn model_catalog_panel(&self, desktop: &WeakEntity<Self>, cx: &App) -> Div {
        let search = &self.model_controls.search;
        let mut panel = menu_surface().w(px(306.)).flex_none().child(
            div()
                .h(px(35.))
                .flex_none()
                .border_b_1()
                .border_color(rgb(MENU_LINE))
                .px_1()
                .flex()
                .items_center()
                .child(
                    Input::new(search)
                        .appearance(false)
                        .small()
                        .prefix(svg_symbol(icons::SEARCH, 13., MENU_MUTED).flex_none()),
                ),
        );
        let follow_default = self.selected.is_none()
            && self
                .workspace()
                .and_then(|workspace| workspace.draft_launch.get(&self.key()))
                .is_some_and(|launch| launch.model.is_some());
        let Some(catalog) = self.menu_catalog() else {
            let label = match self.model_controls.catalogs.get(&self.model_profile()) {
                Some(CatalogState::Failed(error)) => error.as_str(),
                _ => "正在读取模型列表…",
            };
            return panel
                .child(empty_menu(label))
                .child(catalog_footer(desktop, follow_default));
        };
        let query = search.read(cx).value().trim().to_lowercase();
        let tokens: Vec<_> = query.split_whitespace().collect();
        let active = self.shown_model();
        let (effort, _) = self.shown_effort();
        let speed = self.shown_speed();
        let mut rows = Vec::new();
        let mut pinned = Vec::new();
        let mut provider: Option<&str> = None;
        for entry in catalog
            .models
            .iter()
            .filter(|entry| model_matches_query(entry, &tokens))
        {
            let preference = self.model_preference(&entry.choice);
            let is_active = active.as_ref().is_some_and(|model| entry.matches(model));
            let options_open = self.model_controls.inspected_model.as_ref() == Some(&entry.choice);
            let (_, ultrafast) = self.model_speed_options(&entry.choice, Some(entry));
            let row = CatalogRow::Model(Box::new(ModelMenuRow {
                entry: entry.clone(),
                favorite: preference.favorite,
                active: is_active,
                options_open,
                ultrafast,
                effort: if is_active {
                    effort.clone()
                } else {
                    preference.effort
                },
                speed: if is_active {
                    Some(speed.to_owned())
                } else {
                    preference.speed
                },
            }));
            if preference.favorite {
                pinned.push(row);
                continue;
            }
            if provider != Some(entry.choice.provider.as_str()) {
                provider = Some(entry.choice.provider.as_str());
                rows.push(CatalogRow::Provider(entry.provider_name.clone()));
            }
            rows.push(row);
        }
        if !pinned.is_empty() {
            pinned.insert(0, CatalogRow::Provider("收藏".into()));
            pinned.append(&mut rows);
            rows = pinned;
        }
        let count = rows.len();
        if count == 0 {
            panel = panel.child(empty_menu(if tokens.is_empty() {
                "暂无模型"
            } else {
                "没有匹配的模型"
            }));
        } else {
            let list_owner = desktop.clone();
            panel = panel.child(
                uniform_list("model-options", count, move |range, _, _| {
                    range
                        .map(|index| match &rows[index] {
                            CatalogRow::Provider(label) => div()
                                .h(px(MENU_ROW_HEIGHT))
                                .px_2()
                                .flex()
                                .items_end()
                                .pb(px(3.))
                                .child(section_label(label.clone()))
                                .into_any_element(),
                            CatalogRow::Model(row) => model_row(row, &list_owner, index),
                        })
                        .collect()
                })
                .h(px(count.min(12) as f32 * MENU_ROW_HEIGHT))
                .w_full(),
            );
        }
        panel = panel.child(catalog_footer(desktop, follow_default));
        let details = self
            .model_controls
            .inspected_model
            .as_ref()
            .and_then(|choice| {
                catalog
                    .models
                    .iter()
                    .find(|entry| &entry.choice == choice && model_matches_query(entry, &tokens))
                    .map(|entry| {
                        self.model_options_panel(Some(&entry.choice), Some(entry), desktop)
                    })
            });
        div()
            .flex()
            .items_end()
            .gap(px(5.))
            .children(details)
            .child(panel)
    }

    fn effort_picker_panel(&self, desktop: &WeakEntity<Self>) -> Div {
        let model = self.shown_model();
        let entry = model.as_ref().and_then(|model| {
            self.menu_catalog()?
                .models
                .iter()
                .find(|entry| entry.matches(model))
        });
        self.model_options_panel(model.as_ref(), entry, desktop)
    }

    fn model_options_panel(
        &self,
        target: Option<&ModelChoice>,
        entry: Option<&CatalogModel>,
        desktop: &WeakEntity<Self>,
    ) -> Div {
        let mut panel = menu_surface().w(px(174.)).flex_none().py_1();
        let Some(model) = target else {
            return panel.child(empty_menu("暂无模型选项"));
        };
        let is_active = self.shown_model().is_some_and(|current| {
            entry.map_or_else(|| current == *model, |catalog| catalog.matches(&current))
        });
        let choice = entry.map_or_else(|| model.clone(), |entry| entry.choice.clone());
        let preference = self.model_preference(&choice);
        let (effort, wire) = if is_active {
            self.shown_effort()
        } else {
            (preference.effort, None)
        };
        let default_effort = self
            .model_controls
            .defaults
            .effort
            .as_deref()
            .filter(|effort| *effort != "none")
            .unwrap_or("medium");
        let current_effort = effort.as_deref().unwrap_or(default_effort);
        let speed = if is_active {
            self.shown_speed()
        } else {
            preference.speed.as_deref().unwrap_or("normal")
        };
        let (fast, ultrafast) = self.model_speed_options(&choice, entry);
        let reasoning = entry.is_none_or(|entry| entry.reasoning != Some(false));
        let busy = is_active && self.model_controls.busy.contains(&self.key());
        let speed_allowed = !busy
            && (!is_active
                || !self
                    .selected
                    .as_ref()
                    .and_then(|key| self.sessions.get(key))
                    .is_some_and(|session| session.running || session.next_model.is_some()));
        let thinking_toggle = reasoning && entry.is_none_or(|entry| entry.can_disable_reasoning);
        if thinking_toggle || fast || ultrafast || matches!(speed, "fast" | "ultrafast") {
            panel = panel.child(section_title("选项"));
            if thinking_toggle {
                let enable_effort = if current_effort == "none" {
                    default_effort
                } else {
                    current_effort
                }
                .to_owned();
                panel = panel.child(option_switch(
                    "menu-thinking",
                    "思考",
                    current_effort != "none",
                    !busy,
                    choice.clone(),
                    desktop,
                    move |checked| {
                        Choice::Effort(if checked {
                            enable_effort.clone()
                        } else {
                            "none".into()
                        })
                    },
                ));
            }
            for (key, label, supported) in [
                ("fast", "Fast", fast),
                ("ultrafast", "Ultrafast", ultrafast),
            ] {
                if supported || speed == key {
                    panel = panel.child(option_switch(
                        key,
                        label,
                        speed == key,
                        speed_allowed,
                        choice.clone(),
                        desktop,
                        move |checked| Choice::Speed(if checked { key } else { "normal" }.into()),
                    ));
                }
            }
            if reasoning {
                panel = panel.child(div().border_t_1().border_color(rgb(MENU_LINE)).my_1());
            }
        }
        if reasoning {
            panel = panel.child(section_title("推理强度"));
            for &(key, _, label) in EFFORTS.iter().filter(|(key, _, _)| *key != "none") {
                let owner = desktop.clone();
                let target = choice.clone();
                let selected = current_effort == key;
                panel = panel.child(
                    option_row(key, busy)
                        .child(div().flex_1().child(label))
                        .when(selected, |row| row.child(checkmark()))
                        .when_some(
                            wire.as_deref().filter(|value| selected && *value != key),
                            |row, value| row.child(model_tag(short_effort(value).to_owned())),
                        )
                        .when(!busy, |row| {
                            row.on_click(move |_, _, cx| {
                                let _ = owner.update(cx, |this, cx| {
                                    this.edit_model_option(
                                        target.clone(),
                                        Choice::Effort(key.into()),
                                        cx,
                                    );
                                });
                            })
                        }),
                );
            }
        }
        if !reasoning && !fast && !ultrafast && !matches!(speed, "fast" | "ultrafast") {
            return panel.child(empty_menu("此模型没有可调选项"));
        }
        panel
    }

    pub(super) fn model_confirmation(&self, cx: &Context<Self>) -> Option<Div> {
        let prompt = self.model_controls.prompts.get(&self.key())?;
        Some(
            panel()
                .px_3()
                .py_2()
                .flex()
                .flex_col()
                .gap_1()
                .border_color(rgb(LINE))
                .bg(rgb(SURFACE))
                .child(
                    div()
                        .text_size(px(13.))
                        .font_weight(gpui::FontWeight::SEMIBOLD)
                        .child("确认模型切换"),
                )
                .child(
                    div()
                        .text_size(px(12.))
                        .text_color(rgb(MUTED))
                        .child(prompt.message.clone()),
                )
                .child(
                    div()
                        .flex()
                        .justify_end()
                        .gap_1()
                        .child(control("model-cancel", "取消").on_click(cx.listener(
                            |this, _, _, cx| {
                                this.resolve_model_prompt(false, cx);
                            },
                        )))
                        .child(primary("model-confirm", "继续", true).on_click(cx.listener(
                            |this, _, _, cx| {
                                this.resolve_model_prompt(true, cx);
                            },
                        ))),
                ),
        )
    }
}
