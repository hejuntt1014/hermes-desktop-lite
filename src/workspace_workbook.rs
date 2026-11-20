use std::{
    io::Cursor,
    sync::{Arc, Mutex},
};

use anyhow::{Context as _, Result, bail};
use calamine::{Data, DataRef, Reader, SheetType, SheetVisible, Xlsx};
use gpui::{
    Div, FontWeight, ListHorizontalSizingBehavior, SharedString, UniformListScrollHandle, div,
    prelude::*, px, rgb,
};
use gpui_component::scroll::Scrollbar;

pub(super) const WORKBOOK_BYTES: usize = 24 * 1024 * 1024;
const MAX_EXPANDED_BYTES: u128 = 128 * 1024 * 1024;
const MAX_ROWS: usize = 4096;
const MAX_COLUMNS: usize = 64;
const MAX_VALUES: usize = 80_000;
const ROW_HEIGHT: f32 = 25.;
const GUTTER_WIDTH: f32 = 48.;

type ReaderHandle = Arc<Mutex<Xlsx<Cursor<Vec<u8>>>>>;

pub(super) struct Workbook {
    pub names: Vec<SharedString>,
    pub selected: usize,
    pub sheet: Option<Result<Arc<Sheet>, SharedString>>,
    reader: ReaderHandle,
}

pub(super) struct Sheet {
    rows: Vec<Vec<(usize, SharedString)>>,
    columns: Vec<f32>,
    clipped: bool,
}

impl Workbook {
    pub fn open(bytes: Vec<u8>) -> Result<Self> {
        let mut archive =
            zip::ZipArchive::new(Cursor::new(bytes.as_slice())).context("无法读取 XLSX 工作簿")?;
        if archive.len() > 8192 {
            bail!("工作簿超过预览大小限制，请下载查看");
        }
        let mut expanded = 0;
        for index in 0..archive.len() {
            expanded += u128::from(archive.by_index_raw(index)?.size());
            if expanded > MAX_EXPANDED_BYTES {
                bail!("工作簿超过预览大小限制，请下载查看");
            }
        }
        drop(archive);
        let reader = Xlsx::new(Cursor::new(bytes)).context("无法读取 XLSX 工作簿")?;
        let names: Vec<_> = reader
            .sheets_metadata()
            .iter()
            .filter(|sheet| {
                sheet.typ == SheetType::WorkSheet && sheet.visible == SheetVisible::Visible
            })
            .map(|sheet| SharedString::from(sheet.name.clone()))
            .collect();
        let name = names.first().context("此工作簿没有可预览的工作表")?;
        let reader = Arc::new(Mutex::new(reader));
        let sheet = Some(Self::read_sheet(&reader, name));
        Ok(Self {
            names,
            selected: 0,
            sheet,
            reader,
        })
    }

    pub fn reader_for(
        &self,
        index: usize,
    ) -> Option<impl FnOnce() -> Result<Arc<Sheet>, SharedString> + Send + use<>> {
        let name = self.names.get(index)?.clone();
        let reader = self.reader.clone();
        Some(move || Self::read_sheet(&reader, &name))
    }

    fn read_sheet(reader: &ReaderHandle, name: &str) -> Result<Arc<Sheet>, SharedString> {
        let mut reader = reader
            .lock()
            .map_err(|_| SharedString::from("无法读取工作表"))?;
        Sheet::read(&mut reader, name)
            .map(Arc::new)
            .map_err(|error| error.to_string().into())
    }
}

impl Sheet {
    fn read(book: &mut Xlsx<Cursor<Vec<u8>>>, name: &str) -> Result<Self> {
        let mut source = book
            .worksheet_cells_reader(name)
            .context("无法读取工作表")?;
        let dimensions = source.dimensions();
        let mut clipped =
            dimensions.end.0 as usize >= MAX_ROWS || dimensions.end.1 as usize >= MAX_COLUMNS;
        let mut columns: Vec<f32> = Vec::new();
        let mut rows: Vec<Vec<(usize, SharedString)>> = Vec::new();
        let mut retained = 0;
        while let Some(cell) = source
            .next_cell_with_formula()
            .context("工作表内容无法解析")?
        {
            let (row, column) = (cell.pos.0 as usize, cell.pos.1 as usize);
            if row >= MAX_ROWS || retained >= MAX_VALUES {
                clipped = true;
                break;
            }
            if column >= MAX_COLUMNS {
                clipped = true;
                continue;
            }
            let value = match cell.value {
                DataRef::Empty => cell
                    .formula
                    .map_or_else(String::new, |formula| format!("={formula}")),
                DataRef::DateTime(date) => date.as_datetime().map_or_else(
                    || date.to_string(),
                    |date| {
                        if date.time() == chrono::NaiveTime::MIN {
                            date.date().format("%Y-%m-%d").to_string()
                        } else {
                            date.format("%Y-%m-%d %H:%M:%S").to_string()
                        }
                    },
                ),
                DataRef::String(value) => value,
                value => Data::from(value).to_string(),
            };
            if value.is_empty() {
                continue;
            }
            let value = crate::session::compact_preview(&value, 240);
            let display_width = value
                .chars()
                .take(40)
                .map(|ch| if ch.is_ascii() { 7. } else { 12. })
                .sum::<f32>()
                + 18.;
            if columns.len() <= column {
                columns.resize(column + 1, 92.);
            }
            if rows.len() <= row {
                rows.resize_with(row + 1, Vec::new);
            }
            columns[column] = columns[column].max(display_width.min(248.));
            rows[row].push((column, value));
            retained += 1;
        }
        for row in &mut rows {
            row.sort_by_key(|(column, _)| *column);
        }
        Ok(Self {
            rows,
            columns,
            clipped,
        })
    }
}

pub(super) fn grid(sheet: Arc<Sheet>, scroll: &UniformListScrollHandle) -> Div {
    if sheet.rows.is_empty() {
        return super::preview_status(Some("此工作表为空".into()));
    }
    let count = sheet.rows.len();
    let clipped = sheet.clipped;
    let columns = sheet.columns.len();
    let width = GUTTER_WIDTH + sheet.columns.iter().sum::<f32>();
    let list = gpui::uniform_list("workbook-grid", count + 1, move |range, _, _| {
        range
            .map(|index| {
                let cells = index.checked_sub(1).and_then(|index| sheet.rows.get(index));
                let mut values = cells.into_iter().flatten().peekable();
                let header = index == 0;
                let line = div()
                    .h(px(ROW_HEIGHT))
                    .w(px(width))
                    .flex()
                    .items_center()
                    .border_b_1()
                    .border_color(rgb(0xe8ecf1))
                    .text_size(px(12.))
                    .when(header, |line| {
                        line.bg(rgb(0xf0f3f7)).font_weight(FontWeight::SEMIBOLD)
                    })
                    .when(!header && index % 2 == 0, |line| line.bg(rgb(0xfafbfd)))
                    .child(
                        div()
                            .w(px(GUTTER_WIDTH))
                            .h_full()
                            .flex_none()
                            .flex()
                            .items_center()
                            .justify_end()
                            .pr_2()
                            .bg(rgb(0xf4f6f9))
                            .border_r_1()
                            .border_color(rgb(0xe0e6ee))
                            .text_size(px(11.))
                            .text_color(rgb(0x768294))
                            .child(if header {
                                String::new()
                            } else {
                                index.to_string()
                            }),
                    );
                line.children(sheet.columns.iter().enumerate().map(|(column, width)| {
                    let value = if header {
                        column_name(column).into()
                    } else if values
                        .peek()
                        .is_some_and(|(position, _)| *position == column)
                    {
                        values
                            .next()
                            .map(|(_, value)| value.clone())
                            .unwrap_or_default()
                    } else {
                        SharedString::default()
                    };
                    div()
                        .w(px(*width))
                        .h_full()
                        .flex_none()
                        .flex()
                        .items_center()
                        .px_2()
                        .border_r_1()
                        .border_color(rgb(0xe8ecf1))
                        .min_w_0()
                        .child(div().truncate().child(value))
                }))
            })
            .collect()
    })
    .track_scroll(scroll)
    .with_horizontal_sizing_behavior(ListHorizontalSizingBehavior::Unconstrained)
    .flex_1()
    .min_h_0();
    div()
        .flex_1()
        .min_h_0()
        .min_w_0()
        .flex()
        .flex_col()
        .child(
            div()
                .relative()
                .flex_1()
                .min_h_0()
                .flex()
                .flex_col()
                .child(list)
                .child(Scrollbar::vertical(scroll))
                .child(Scrollbar::horizontal(scroll)),
        )
        .when(clipped, |preview| {
            preview.child(
                div()
                    .px_3()
                    .py_1()
                    .text_size(px(11.))
                    .text_color(rgb(0x768294))
                    .child(format!(
                        "预览前 {count} 行、{columns} 列，下载可查看完整工作表"
                    )),
            )
        })
}

fn column_name(index: usize) -> String {
    let letter = |offset| (b'A' + offset as u8) as char;
    if index < 26 {
        letter(index).to_string()
    } else {
        format!("{}{}", letter(index / 26 - 1), letter(index % 26))
    }
}
