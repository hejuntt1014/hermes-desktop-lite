use serde_json::Value;

use crate::session::string;

#[derive(Clone, Copy)]
pub struct Display {
    pub visible: bool,
    pub expanded: bool,
}

impl Default for Display {
    fn default() -> Self {
        Self {
            visible: true,
            expanded: true,
        }
    }
}

impl Display {
    pub fn from_config(config: &Value) -> Self {
        let display = &config["display"];
        let cli = &display["platforms"]["cli"];
        let visible = cli
            .get("show_reasoning")
            .filter(|value| !value.is_null())
            .unwrap_or(&display["show_reasoning"]);
        let thinking = cli["sections"]["thinking"]
            .as_str()
            .or_else(|| display["sections"]["thinking"].as_str());
        Self {
            visible: !matches!(visible, Value::Bool(false))
                && visible != "false"
                && visible.as_i64() != Some(0),
            expanded: thinking != Some("collapsed"),
        }
    }

    pub fn update(&mut self, value: &str) {
        match value {
            "show" => *self = Self::default(),
            "hide" => self.visible = false,
            "full" => self.expanded = true,
            "clamp" => self.expanded = false,
            _ => {}
        }
    }
}

pub fn message_reasoning(row: &Value) -> String {
    if let Some(visible) = row.get("display_reasoning") {
        return visible.as_str().unwrap_or_default().trim().to_owned();
    }
    ["reasoning", "reasoning_content"]
        .into_iter()
        .map(|field| string(row, field).trim())
        .find(|text| !text.is_empty())
        .map_or_else(
            || details_reasoning(&row["reasoning_details"]),
            str::to_owned,
        )
}

fn details_reasoning(details: &Value) -> String {
    let parsed;
    let details = if let Some(text) = details.as_str() {
        let text = text.trim();
        if !text.starts_with(['[', '{']) {
            return text.to_owned();
        }
        let Ok(value) = serde_json::from_str::<Value>(text) else {
            return String::new();
        };
        parsed = value;
        &parsed
    } else {
        details
    };
    let blocks = details
        .as_array()
        .map_or_else(|| std::slice::from_ref(details), Vec::as_slice);
    let mut prose = Vec::new();
    for block in blocks {
        let text = block.as_str().or_else(|| {
            if string(block, "type").starts_with("reasoning.")
                && string(block, "type").ends_with("encrypted")
            {
                return None;
            }
            ["summary", "thinking", "content", "text"]
                .into_iter()
                .find_map(|field| block[field].as_str().filter(|text| !text.trim().is_empty()))
        });
        if let Some(text) = text {
            push_text(&mut prose, text);
        }
        nested_reasoning(block, &mut prose);
    }
    prose.join("\n\n")
}

fn nested_reasoning<'a>(value: &'a Value, prose: &mut Vec<&'a str>) {
    match value {
        Value::Array(items) => {
            for item in items {
                nested_reasoning(item, prose);
            }
        }
        Value::Object(fields) => {
            let thought = match string(value, "type") {
                "reasoning.summary" | "summary_text" => {
                    value["summary"].as_str().or_else(|| value["text"].as_str())
                }
                "reasoning.text" | "reasoning_text" => value["text"].as_str(),
                _ => value["thinking"].as_str(),
            };
            if let Some(thought) = thought {
                push_text(prose, thought);
            }
            for (key, child) in fields {
                if !matches!(
                    key.as_str(),
                    "signature" | "data" | "projection" | "encrypted_content"
                ) {
                    nested_reasoning(child, prose);
                }
            }
        }
        _ => {}
    }
}

fn push_text<'a>(parts: &mut Vec<&'a str>, text: &'a str) {
    let text = text.trim();
    if !text.is_empty() && !parts.contains(&text) {
        parts.push(text);
    }
}
