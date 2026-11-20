use crate::i18n::text as tr;

use std::{
    borrow::Cow,
    hash::{DefaultHasher, Hash, Hasher},
    sync::LazyLock,
};

use gpui::{
    AnyElement, App, ClipboardItem, IntoElement, SharedString, StyleRefinement, Window, div,
    prelude::*, px, rgb, rgba,
};
use gpui_component::text::{MarkdownExtensions, MarkdownNode, TextView, TextViewStyle};
use markdown::{ParseOptions, mdast::Node, to_mdast};

use crate::{
    icons,
    style::{CODE_FONT, CONVERSATION_INK, MUTED},
};

use super::icon_button;

const COLLAPSED_HEIGHT: f32 = 120.;
const FENCE_BACKGROUND: u32 = 0xf3f5f7;
const CODE_BLOCK_KIND: &str = "expandable-fence";

pub(super) fn render_prose_fences(source: &str) -> Cow<'_, str> {
    if !source.contains("```") && !source.contains("~~~") {
        return Cow::Borrowed(source);
    }
    let Ok(Node::Root(document)) = to_mdast(source, &ParseOptions::gfm()) else {
        return Cow::Borrowed(source);
    };
    let mut rendered = String::new();
    let mut previous_end = 0;
    for node in document.children {
        let Node::Code(block) = node else { continue };
        let Some(position) = block.position else {
            continue;
        };
        let start = position.start.offset;
        let end = position.end.offset;
        let fence = &source[start..end];
        if !fence.starts_with("```") && !fence.starts_with("~~~") {
            continue;
        }
        let language = block
            .lang
            .as_deref()
            .unwrap_or_default()
            .trim()
            .to_ascii_lowercase();
        if !matches!(language.as_str(), "md" | "markdown")
            || !to_mdast(&block.value, &ParseOptions::gfm()).is_ok_and(|node| has_markup(&node))
        {
            continue;
        }
        rendered.push_str(&source[previous_end..start]);
        rendered.push_str("\n\n");
        rendered.push_str(&block.value);
        rendered.push_str("\n\n");
        previous_end = end;
    }
    if previous_end == 0 {
        return Cow::Borrowed(source);
    }
    rendered.push_str(&source[previous_end..]);
    Cow::Owned(rendered)
}

fn has_markup(node: &Node) -> bool {
    matches!(
        node,
        Node::Heading(_)
            | Node::List(_)
            | Node::Table(_)
            | Node::Blockquote(_)
            | Node::Strong(_)
            | Node::Emphasis(_)
            | Node::Link(_)
            | Node::Image(_)
    ) || node
        .children()
        .is_some_and(|children| children.iter().any(has_markup))
}

struct Fence {
    source: SharedString,
    key: u64,
}

pub(super) fn code_fences() -> MarkdownExtensions {
    static EXTENSIONS: LazyLock<MarkdownExtensions> = LazyLock::new(|| {
        MarkdownExtensions::default()
            .block_parser(|node, context| {
                let Node::Code(code) = node else { return None };
                if code.value.lines().take(6).count() < 6 {
                    return None;
                }
                let source = context.node_source(node)?;
                if !source.starts_with("```") && !source.starts_with("~~~") {
                    return None;
                }
                let mut hasher = DefaultHasher::new();
                source.hash(&mut hasher);
                let source = SharedString::from(source.to_owned());
                let fence = Fence {
                    source: source.clone(),
                    key: hasher.finish(),
                };
                Some(
                    MarkdownNode::new(CODE_BLOCK_KIND, fence)
                        .text(code.value.clone())
                        .markdown(source),
                )
            })
            .block_renderer(CODE_BLOCK_KIND, expandable_fence)
    });
    EXTENSIONS.clone()
}

pub(super) fn code_fence_style(height: gpui::Pixels) -> StyleRefinement {
    let mut style = StyleRefinement::default()
        .max_h(height)
        .rounded(px(7.))
        .border_0()
        .bg(rgba((FENCE_BACKGROUND << 8) | 0xb8))
        .font_family(CODE_FONT)
        .text_size(px(12.))
        .line_height(px(19.))
        .text_color(rgb(CONVERSATION_INK))
        .px_3()
        .pt(px(9.))
        .pb(px(10.))
        .pr(px(33.));
    style.overflow.y = Some(gpui::Overflow::Scroll);
    style
}

pub(super) fn copy_fence(text: SharedString) -> gpui::Stateful<gpui::Div> {
    icon_button("copy-code", icons::COPY, tr("复制代码"))
        .block_mouse_except_scroll()
        .size(px(20.))
        .on_click(move |_, _, cx| {
            cx.stop_propagation();
            cx.write_to_clipboard(ClipboardItem::new_string(text.to_string()));
        })
}

fn expandable_fence(node: &MarkdownNode, window: &mut Window, cx: &mut App) -> AnyElement {
    let Some(fence) = node.data::<Fence>() else {
        return div().into_any_element();
    };
    let at = node.source_range().map_or(0, |range| range.start);
    let key = format!("chat-fence-{}-{at}", fence.key);
    let state = window.use_keyed_state(key.clone(), cx, |_, _| false);
    let expanded = *state.read(cx);
    let height = if expanded {
        (window.viewport_size().height * 0.4).max(px(COLLAPSED_HEIGHT))
    } else {
        px(COLLAPSED_HEIGHT)
    };
    let body = TextView::markdown(format!("{key}-body"), fence.source.clone())
        .style(TextViewStyle::default().code_block(code_fence_style(height)))
        .code_block_actions(|code, _, _| copy_fence(code.code()))
        .selectable(true);
    div()
        .relative()
        .w_full()
        .min_w_0()
        .child(body)
        .child(
            div()
                .id(format!("{key}-toggle"))
                .absolute()
                .right(px(19.))
                .bottom(px(3.))
                .w(px(24.))
                .h(px(18.))
                .flex()
                .items_center()
                .justify_center()
                .rounded(px(4.))
                .bg(rgb(FENCE_BACKGROUND))
                .cursor_pointer()
                .block_mouse_except_scroll()
                .aria_label(if expanded {
                    tr("收起代码块")
                } else {
                    tr("展开代码块")
                })
                .child(
                    gpui::svg()
                        .path(icons::CHEVRON_DOWN)
                        .size(px(13.))
                        .text_color(rgb(MUTED))
                        .when(expanded, |icon| {
                            icon.with_transformation(gpui::Transformation::rotate(gpui::radians(
                                std::f32::consts::PI,
                            )))
                        }),
                )
                .on_click(move |_, window, cx| {
                    cx.stop_propagation();
                    state.update(cx, |expanded, cx| {
                        *expanded = !*expanded;
                        cx.notify();
                    });
                    window.refresh();
                }),
        )
        .into_any_element()
}
