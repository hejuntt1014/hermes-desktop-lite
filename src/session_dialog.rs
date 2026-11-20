use gpui::{
    Context, Div, EntityInputHandler, FocusHandle, Stateful, Window, div, prelude::*, px, rgb, rgba,
};
use gpui_component::{Sizable, input::Input};
use serde_json::json;
use uuid::Uuid;

use crate::{icons, session::SessionTarget, session_colors::SessionTitleColor, style::INK};

use super::{
    Desktop,
    view::{control, icon_button, panel, primary},
};

pub(super) struct SessionDialog {
    target: SessionTarget,
    focus: Option<FocusHandle>,
    request: Option<Uuid>,
    error: Option<String>,
}

impl Desktop {
    pub(super) fn begin_rename(
        &mut self,
        target: SessionTarget,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.out.is_none() || self.session_dialog.is_some() {
            return;
        }
        let focus = window.focused(cx);
        self.rename.update(cx, |field, cx| {
            field.set_value(target.title.clone(), window, cx);
            field.focus(window, cx);
            field.select_all(window, cx);
        });
        self.session_dialog = Some(SessionDialog {
            target,
            focus,
            request: None,
            error: None,
        });
        cx.notify();
    }

    pub(super) fn close_session_dialog(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self
            .session_dialog
            .as_ref()
            .is_some_and(|dialog| dialog.request.is_some())
        {
            return;
        }
        if let Some(dialog) = self.session_dialog.take() {
            dialog
                .focus
                .as_ref()
                .unwrap_or(&self.workspace_focus)
                .focus(window, cx);
            cx.notify();
        }
    }

    pub(super) fn finish_rename(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(dialog) = self
            .session_dialog
            .as_mut()
            .filter(|dialog| dialog.request.is_none())
        else {
            return;
        };
        if self.out.is_none() {
            return;
        }
        let Some(title) = self.rename.update(cx, |field, cx| {
            field
                .marked_text_range(window, cx)
                .is_none()
                .then(|| field.value().trim().to_owned())
        }) else {
            return;
        };
        if title.is_empty() || title == dialog.target.title {
            return;
        }
        dialog.request = Some(Uuid::new_v4());
        dialog.error = None;
        let target = dialog.target.clone();
        self.patch_session(
            &target.id,
            &target.profile,
            json!({"title": title}),
            window,
            cx,
        );
        cx.notify();
    }

    pub(super) fn rename_request_for(&self, profile: &str, id: &str) -> Option<Uuid> {
        let dialog = self.session_dialog.as_ref()?;
        if dialog.target.profile == profile && dialog.target.id == id {
            dialog.request
        } else {
            None
        }
    }

    pub(super) fn settle_rename(
        &mut self,
        request: Option<Uuid>,
        error: Option<String>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        let Some(dialog) = self
            .session_dialog
            .as_mut()
            .filter(|dialog| request.is_some() && dialog.request == request)
        else {
            return false;
        };
        dialog.request = None;
        if let Some(error) = error {
            dialog.error = Some(error);
            self.rename.update(cx, |field, cx| field.focus(window, cx));
        } else {
            self.close_session_dialog(window, cx);
        }
        true
    }

    pub(super) fn title_color(
        &self,
        profile: &str,
        id: &str,
        lineage: &str,
    ) -> Option<SessionTitleColor> {
        let colors = self.workspace()?.session_title_colors.get(profile)?;
        colors.get(lineage).or_else(|| colors.get(id)).copied()
    }

    pub(super) fn apply_title_color(
        &mut self,
        target: &SessionTarget,
        color: Option<SessionTitleColor>,
        cx: &mut Context<Self>,
    ) {
        let lineage = self
            .profile_summary(&target.profile, &target.id)
            .map(|summary| summary.pin_order_key().to_owned())
            .unwrap_or_else(|| target.id.clone());
        let scoped = &mut self.workspace_mut().session_title_colors;
        let colors = scoped.entry(target.profile.clone()).or_default();
        colors.remove(&target.id);
        if let Some(color) = color {
            colors.insert(lineage, color);
        } else {
            colors.remove(&lineage);
        }
        if colors.is_empty() {
            scoped.remove(&target.profile);
        }
        self.persist(cx);
        cx.notify();
    }

    pub(super) fn session_dialog_overlay(
        &self,
        window: &Window,
        cx: &mut Context<Self>,
    ) -> Option<Stateful<Div>> {
        let dialog = self.session_dialog.as_ref()?;
        Some(
            div()
                .id("session-dialog-backdrop")
                .absolute()
                .inset_0()
                .occlude()
                .bg(rgba(0x28374d4a))
                .flex()
                .items_center()
                .justify_center()
                .on_click(cx.listener(|this, _, window, cx| this.close_session_dialog(window, cx)))
                .child(
                    panel()
                        .id("session-dialog")
                        .w((window.viewport_size().width - px(30.)).min(px(425.)))
                        .px_4()
                        .py_3()
                        .shadow_lg()
                        .flex()
                        .flex_col()
                        .gap_3()
                        .on_click(|_, _, cx| cx.stop_propagation())
                        .child(
                            div()
                                .flex()
                                .items_center()
                                .gap_2()
                                .child(
                                    div()
                                        .flex_1()
                                        .text_size(px(15.))
                                        .font_weight(gpui::FontWeight::SEMIBOLD)
                                        .text_color(rgb(INK))
                                        .child("重命名会话"),
                                )
                                .child(
                                    icon_button("close-session-dialog", icons::TAB_CLOSE, "关闭")
                                        .size(px(23.))
                                        .on_click(cx.listener(|this, _, window, cx| {
                                            this.close_session_dialog(window, cx)
                                        })),
                                ),
                        )
                        .child(self.rename_dialog(dialog, cx)),
                ),
        )
    }

    fn rename_dialog(&self, dialog: &SessionDialog, cx: &mut Context<Self>) -> Div {
        let waiting = dialog.request.is_some();
        let value = self.rename.read(cx).value();
        let enabled = !waiting
            && self.out.is_some()
            && !value.trim().is_empty()
            && value.trim() != dialog.target.title;
        div()
            .flex()
            .flex_col()
            .gap_3()
            .child(Input::new(&self.rename).small().disabled(waiting))
            .children(dialog.error.clone().map(|error| {
                div()
                    .text_size(px(11.))
                    .text_color(rgb(0xa0443b))
                    .child(error)
            }))
            .child(
                div()
                    .flex()
                    .justify_end()
                    .items_center()
                    .gap_2()
                    .child(control("cancel-rename", "取消").on_click(
                        cx.listener(|this, _, window, cx| this.close_session_dialog(window, cx)),
                    ))
                    .child(
                        primary(
                            "save-title",
                            if waiting { "保存中…" } else { "保存" },
                            enabled,
                        )
                        .on_click(
                            cx.listener(|this, _, window, cx| this.finish_rename(window, cx)),
                        ),
                    ),
            )
    }
}
