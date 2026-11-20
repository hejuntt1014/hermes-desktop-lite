use crate::i18n::text as tr;

use std::sync::LazyLock;

use gpui::SharedString;
use regex::Regex;
use serde_json::Value;

use crate::session::string;

#[derive(Clone)]
pub struct BackgroundNotice {
    pub raw: SharedString,
    pub report: SharedString,
    pub label: SharedString,
    pub process: bool,
}

static TASK_HEADER: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?m)^--- [✓✗⚠] TASK \d+/\d+(?:: [\s\S]*?)? {2}\(status=[^\r\n]*\) ---\r?\n")
        .expect("delegation task envelope regex")
});

impl BackgroundNotice {
    pub fn project(raw: &str, wire: &Value) -> Option<Self> {
        let content = raw.trim();
        if content.is_empty() {
            return None;
        }
        let first = content.lines().next().unwrap_or_default();
        let kind = string(wire, "display_kind");
        let legacy_delegation = [
            "[ASYNC DELEGATION BATCH COMPLETE — ",
            "[ASYNC DELEGATION COMPLETE — ",
        ]
        .into_iter()
        .any(|prefix| {
            first
                .strip_prefix(prefix)
                .and_then(|head| head.strip_suffix(']'))
                .is_some_and(|id| {
                    id.strip_prefix("deleg_").is_some_and(|tail| {
                        !tail.is_empty()
                            && tail
                                .bytes()
                                .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_')
                    })
                })
        }) && (content.contains("\nA background ")
            || TASK_HEADER.is_match(content));
        let process = kind == "process_complete"
            || content.starts_with("[IMPORTANT: Background process ") && content.ends_with(']');
        if kind != "async_delegation_complete" && !process && !legacy_delegation {
            return None;
        }

        let mut reports = Vec::new();
        let mut tasks = 0;
        if process {
            reports.push(
                content
                    .strip_prefix("[IMPORTANT: ")
                    .and_then(|body| body.strip_suffix(']'))
                    .unwrap_or(content),
            );
        } else if content.starts_with("[ASYNC DELEGATION") {
            let headers: Vec<_> = TASK_HEADER.find_iter(content).collect();
            tasks = headers.len();
            for (index, header) in headers.iter().enumerate() {
                let end = headers
                    .get(index + 1)
                    .map_or(content.len(), |next| next.start());
                reports.push(&content[header.end()..end]);
            }
            if headers.is_empty()
                && let Some((_, output)) = content
                    .split_once("\n--- RESULT ---\n")
                    .or_else(|| content.split_once("\n--- ERROR ---\n"))
                    .or_else(|| content.split_once("\r\n--- RESULT ---\r\n"))
                    .or_else(|| content.split_once("\r\n--- ERROR ---\r\n"))
            {
                reports.push(output);
            }
        } else {
            reports.push(content);
        }
        let report = reports
            .into_iter()
            .map(|body| {
                body.lines()
                    .filter(|line| {
                        !line.starts_with("Full live transcript (complete tool/assistant trace): ")
                    })
                    .collect::<Vec<_>>()
                    .join("\n")
                    .trim()
                    .to_owned()
            })
            .filter(|body| !body.is_empty())
            .collect::<Vec<_>>()
            .join("\n\n");
        let label = if process {
            tr("后台进程已完成").to_owned()
        } else if tasks > 1 {
            crate::i18n::format_text!(
                "后台委派已完成 · {tasks} 项结果",
                "Delegation finished · {tasks} result(s)"
            )
        } else {
            tr("后台委派已完成").to_owned()
        };
        Some(Self {
            raw: raw.to_owned().into(),
            report: report.into(),
            label: label.into(),
            process,
        })
    }
}
