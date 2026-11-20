use std::sync::LazyLock;

use regex::Regex;
use serde::{Deserialize, Serialize};

#[derive(Clone, Deserialize, Serialize)]
pub struct CommandReceipt {
    pub after: Option<u64>,
    pub command: String,
    pub output: String,
}

impl CommandReceipt {
    pub fn recorded(after: Option<u64>, command: String, output: &str) -> Self {
        let output = clean_output(output);
        let end = output.floor_char_boundary(output.len().min(32_000));
        Self {
            after,
            command,
            output: output[..end].to_owned(),
        }
    }

    pub fn from_system(text: &str) -> Option<Self> {
        let (command, output) = text.strip_prefix("slash:/")?.split_once('\n')?;
        let command = command.trim();
        if command.is_empty() || command.chars().any(char::is_control) {
            return None;
        }
        Some(Self::recorded(None, command.to_owned(), output))
    }
}

fn clean_output(output: &str) -> String {
    static ESCAPES: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r"\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1b]*(?:\x07|\x1b\\))")
            .expect("terminal escape pattern")
    });
    ESCAPES.replace_all(output, "").trim().to_owned()
}
