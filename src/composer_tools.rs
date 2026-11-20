use gpui::{Anchor, Context, IntoElement, prelude::*, px};
use gpui_component::{
    Disableable,
    button::{Button, ButtonVariants},
    menu::DropdownMenu,
};

use crate::{icons, style::MUTED};

use super::{Desktop, svg_symbol, tab_view::menu_item};

impl Desktop {
    pub(super) fn composer_tools(
        &self,
        may_edit_files: bool,
        cx: &mut Context<Self>,
    ) -> impl IntoElement + use<> {
        let desktop = cx.entity().downgrade();
        let online = self.out.is_some();
        let can_reference = online && self.active_workspace_scope().is_some();
        Button::new("composer-tools")
            .ghost()
            .compact()
            .size(px(24.))
            .p_0()
            .disabled(!may_edit_files)
            .tooltip("添加附件或引用")
            .child(svg_symbol(icons::PLUS, 13., MUTED))
            .dropdown_menu_with_anchor(Anchor::BottomLeft, move |menu, _, _| {
                menu.min_w(px(220.))
                    .label("附件")
                    .item(menu_item(
                        &desktop,
                        "上传文件或图片…",
                        icons::FILE_TEXT,
                        true,
                        |this, _, cx| this.pick_files(cx),
                    ))
                    .item(menu_item(
                        &desktop,
                        "粘贴剪贴板图片",
                        icons::CLIPBOARD,
                        true,
                        |this, _, cx| this.paste_clipboard_image(cx),
                    ))
                    .separator()
                    .label("工作区引用")
                    .item(menu_item(
                        &desktop,
                        "引用远程文件",
                        icons::FILE_TEXT,
                        can_reference,
                        |this, window, cx| this.add_reference_prefix("@file:", window, cx),
                    ))
                    .item(menu_item(
                        &desktop,
                        "引用远程文件夹",
                        icons::FOLDER_OPEN,
                        can_reference,
                        |this, window, cx| this.add_reference_prefix("@folder:", window, cx),
                    ))
                    .separator()
                    .item(menu_item(
                        &desktop,
                        "命令与技能",
                        icons::TERMINAL,
                        online,
                        |this, window, cx| this.open_slash_picker(window, cx),
                    ))
            })
    }
}
