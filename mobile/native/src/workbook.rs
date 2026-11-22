use std::fs::File;
use std::io::BufReader;

use calamine::{Data, DataRef, Reader, SheetType, SheetVisible, Xlsx};
use serde_json::{Value, json};

const MAX_FILE_BYTES: u64 = 24 * 1024 * 1024;
const MAX_EXPANDED_BYTES: u64 = 128 * 1024 * 1024;
const MAX_ROWS: usize = 4096;
const MAX_COLUMNS: usize = 64;
const MAX_VALUES: usize = 80_000;

pub(crate) fn read(path: &str, index: usize) -> Result<Value, &'static str> {
    let file = File::open(path).map_err(|_| "invalid")?;
    if file.metadata().map_err(|_| "invalid")?.len() > MAX_FILE_BYTES {
        return Err("size");
    }
    let mut archive = zip::ZipArchive::new(BufReader::new(file)).map_err(|_| "invalid")?;
    if archive.len() > 8192 {
        return Err("size");
    }
    let mut expanded = 0u64;
    for index in 0..archive.len() {
        let entry = archive.by_index_raw(index).map_err(|_| "invalid")?;
        expanded = expanded.saturating_add(entry.size());
        if expanded > MAX_EXPANDED_BYTES {
            return Err("size");
        }
    }
    let mut book = Xlsx::new(archive.into_inner()).map_err(|_| "invalid")?;
    let names: Vec<_> = book
        .sheets_metadata()
        .iter()
        .filter(|sheet| sheet.typ == SheetType::WorkSheet && sheet.visible == SheetVisible::Visible)
        .map(|sheet| sheet.name.clone())
        .collect();
    let name = names.get(index).ok_or("no_sheet")?;
    let mut sheet = book.worksheet_cells_reader(name).map_err(|_| "invalid")?;
    let dimensions = sheet.dimensions();
    let mut clipped =
        dimensions.end.0 as usize >= MAX_ROWS || dimensions.end.1 as usize >= MAX_COLUMNS;
    let mut cells = Vec::new();
    let (mut rows, mut columns) = (0, 0);
    while let Some(cell) = sheet.next_cell_with_formula().map_err(|_| "invalid")? {
        let (row, column) = (cell.pos.0 as usize, cell.pos.1 as usize);
        if row >= MAX_ROWS || cells.len() >= MAX_VALUES {
            clipped = true;
            break;
        }
        if column >= MAX_COLUMNS {
            clipped = true;
            continue;
        }
        let text = match cell.value {
            DataRef::Empty => cell
                .formula
                .map_or_else(String::new, |form| format!("={form}")),
            DataRef::DateTime(date) => date.as_datetime().map_or_else(
                || date.to_string(),
                |value| {
                    if value.time().to_string() == "00:00:00" {
                        value.date().to_string()
                    } else {
                        value.to_string()
                    }
                },
            ),
            value => Data::from(value).to_string(),
        };
        if !text.is_empty() {
            let value: String = text.chars().take(240).collect();
            clipped |= value.len() < text.len();
            cells.push((row, column, value));
            rows = rows.max(row + 1);
            columns = columns.max(column + 1);
        }
    }
    Ok(json!({
        "sheets": names,
        "rows": rows,
        "columns": columns,
        "cells": cells,
        "clipped": clipped,
    }))
}
