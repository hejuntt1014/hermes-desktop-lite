use gpui::{App, Div, FontWeight, ScrollHandle, SharedString, Window, div, prelude::*, px, rgb};
use gpui_component::scroll::Scrollbar;
use markdown::mdast::AlignKind;

use super::workspace_markdown::{DocumentTable, InlineContent};
use crate::app::view::markdown;

const MIN_COLUMN_WIDTH: f32 = 104.;

pub(super) fn render_table(
    table: &DocumentTable,
    id: SharedString,
    available: f32,
    window: &mut Window,
    cx: &mut App,
) -> Div {
    let widths = column_widths(table, available - 2.);
    let table_width = widths.iter().sum::<f32>() + 2.;
    let scrolls = table_width > available + 1.;
    let mut grid = div()
        .w(px(table_width))
        .flex_none()
        .flex()
        .flex_col()
        .border_1()
        .border_color(rgb(0xdfe5ed))
        .rounded(px(5.))
        .overflow_hidden();
    for (row_index, row) in table.rows.iter().enumerate() {
        let header = row_index == 0;
        let mut line = div()
            .flex()
            .text_size(px(12.))
            .line_height(px(17.))
            .when(header, |row| {
                row.bg(rgb(0xf0f4f9)).font_weight(FontWeight::SEMIBOLD)
            })
            .when(row_index > 0, |row| {
                row.border_t_1().border_color(rgb(0xe6ebf2))
            });
        for (column, width) in widths.iter().enumerate() {
            let contents = match row.get(column) {
                Some(InlineContent::Text(text)) => text.clone().into_any_element(),
                Some(InlineContent::Markdown(text)) => markdown(
                    format!("{id}:cell:{row_index}:{column}").into(),
                    text.clone(),
                    false,
                    px(12.),
                    window,
                ),
                None => div().into_any_element(),
            };
            line = line.child(
                div()
                    .w(px(*width))
                    .min_w_0()
                    .flex_none()
                    .px_2()
                    .py(px(5.))
                    .when(column + 1 < widths.len(), |cell| {
                        cell.border_r_1().border_color(rgb(0xe6ebf2))
                    })
                    .when_some(table.align.get(column), |cell, align| match align {
                        AlignKind::Center => cell.text_center(),
                        AlignKind::Right => cell.text_right(),
                        _ => cell,
                    })
                    .child(contents),
            );
        }
        grid = grid.child(line);
    }
    let mut element = div().w_full().min_w_0().my_2().relative();
    if scrolls {
        let scroll = window
            .use_keyed_state(id.clone(), cx, |_, _| ScrollHandle::new())
            .read(cx)
            .clone();
        element = element
            .pb(px(6.))
            .child(
                div()
                    .id(id)
                    .w_full()
                    .overflow_x_scroll()
                    .track_scroll(&scroll)
                    .child(grid),
            )
            .child(Scrollbar::horizontal(&scroll));
    } else {
        element = element.child(grid);
    }
    element
}

fn column_widths(table: &DocumentTable, available: f32) -> Vec<f32> {
    let mut weights = vec![12_f32; table.align.len()];
    for row in &table.rows {
        if row.len() > weights.len() {
            weights.resize(row.len(), 12.);
        }
        for (weight, cell) in weights.iter_mut().zip(row) {
            let text = match cell {
                InlineContent::Text(text) | InlineContent::Markdown(text) => text,
            };
            *weight = weight.max(text.chars().take(160).count() as f32);
        }
    }
    let extra = (available - MIN_COLUMN_WIDTH * weights.len() as f32).max(0.);
    let total: f32 = weights.iter().sum();
    weights
        .into_iter()
        .map(|weight| MIN_COLUMN_WIDTH + extra * (weight / total))
        .collect()
}
