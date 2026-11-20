use crate::i18n::text as tr;

use std::{
    collections::HashMap,
    env,
    io::{BufWriter, Write},
    path::Path,
};

use anyhow::{Context as _, Result};
use gpui::Context;
use serde_json::{Value, json};

use crate::{
    media::{ChatImage, ImageSource, Message, image_part_reference},
    session::{SessionTarget, string, text},
};

use super::{Desktop, attachment_ops::leading_file_refs};

#[derive(Clone, Copy)]
pub(super) enum ExportFormat {
    Markdown,
    Json,
}

impl ExportFormat {
    fn extension(self) -> &'static str {
        match self {
            Self::Markdown => "md",
            Self::Json => "json",
        }
    }
}

impl Desktop {
    pub(super) fn export_session(
        &self,
        target: SessionTarget,
        format: ExportFormat,
        cx: &mut Context<Self>,
    ) {
        let Some(gateway) = self.gateway.clone().filter(|_| self.out.is_some()) else {
            return;
        };
        let Some(directory) = dirs::download_dir()
            .or_else(dirs::document_dir)
            .or_else(|| env::current_dir().ok())
        else {
            return;
        };
        let name = export_filename(&target.title, &target.id, format);
        let destination = cx.prompt_for_new_path(&directory, Some(&name));
        let runtime = self.runtime.clone();
        cx.spawn(async move |view, cx| {
            let result = async {
                let Some(path) = destination.await.context(tr("保存对话框已关闭"))?? else {
                    return Ok(());
                };
                let (target, messages) = runtime
                    .spawn(async move {
                        let messages = gateway
                            .session_transcript(&target.id, &target.profile)
                            .await?;
                        Ok::<_, anyhow::Error>((target, messages))
                    })
                    .await??;
                runtime
                    .spawn_blocking(move || save_export(&path, format, target, messages))
                    .await?
            }
            .await;
            if let Err(error) = result {
                let _ = view.update(cx, |this, cx| {
                    this.banner = Some(
                        crate::i18n::format_text!(
                            "导出会话失败 · {error}",
                            "Could not export the conversation · {error}"
                        )
                        .into(),
                    );
                    cx.notify();
                });
            }
        })
        .detach();
    }
}

fn export_filename(title: &str, key: &str, format: ExportFormat) -> String {
    let title: String = title
        .chars()
        .map(|ch| {
            if ch.is_alphanumeric() || matches!(ch, '-' | '_') {
                ch
            } else {
                '-'
            }
        })
        .take(48)
        .collect();
    let title = title.trim_matches('-');
    let id: String = key
        .chars()
        .filter(char::is_ascii_alphanumeric)
        .take(8)
        .collect();
    format!(
        "{}-{}.{}",
        if title.is_empty() {
            tr("会话")
        } else {
            title
        },
        if id.is_empty() { "hermes" } else { &id },
        format.extension()
    )
}

fn save_export(
    path: &Path,
    format: ExportFormat,
    target: SessionTarget,
    messages: Vec<Value>,
) -> Result<()> {
    let parent = path.parent().context(tr("没有可用的导出目录"))?;
    let mut temporary = tempfile::Builder::new()
        .prefix(".hermes-export-")
        .tempfile_in(parent)?;
    {
        let mut output = BufWriter::new(temporary.as_file_mut());
        let now = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true);
        match format {
            ExportFormat::Json => {
                serde_json::to_writer_pretty(
                    &mut output,
                    &json!({
                        "exported_at": now,
                        "session_id": target.id,
                        "title": target.title,
                        "session": null,
                        "message_count": messages.len(),
                        "messages": messages,
                    }),
                )?;
                writeln!(output)?;
            }
            ExportFormat::Markdown => write_markdown(&mut output, &target, &now, &messages)?,
        }
        output.flush()?;
    }
    temporary.as_file().sync_all()?;
    temporary
        .persist(path)
        .map(drop)
        .context(tr("无法保存导出的会话"))
}

fn write_markdown(
    output: &mut impl Write,
    target: &SessionTarget,
    exported_at: &str,
    messages: &[Value],
) -> Result<()> {
    let title = target
        .title
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    writeln!(
        output,
        "# {}\n",
        escape_inline(if title.is_empty() {
            tr("会话")
        } else {
            &title
        })
    )?;
    writeln!(
        output,
        "{}",
        crate::i18n::format_text!("- 会话 {}", "- Conversation {}", inline_code(&target.id))
    )?;
    writeln!(
        output,
        "{}",
        crate::i18n::format_text!("- 导出时间 {exported_at}", "- Exported at {exported_at}")
    )?;
    let mut tool_names = HashMap::new();
    for row in messages {
        if row["display_kind"] == "hidden" {
            continue;
        }
        let role = string(row, "role");
        let value = row
            .get("display_content")
            .filter(|value| !value.is_null())
            .or_else(|| row.get("content"))
            .unwrap_or(&row["text"]);
        match role {
            "user" | "assistant" => {
                let user = role == "user";
                let (message, extra_images) = export_message(value, user);
                let reason = ["display_reasoning", "reasoning", "reasoning_content"]
                    .iter()
                    .find_map(|key| row[*key].as_str().filter(|text| !text.is_empty()))
                    .unwrap_or_default();
                let parsed = row["tool_calls"]
                    .as_str()
                    .and_then(|value| serde_json::from_str::<Value>(value).ok());
                let calls = parsed.as_ref().unwrap_or(&row["tool_calls"]).as_array();
                if message.display().trim().is_empty()
                    && message.images().is_empty()
                    && extra_images.is_empty()
                    && reason.is_empty()
                    && calls.is_none_or(Vec::is_empty)
                {
                    continue;
                }
                let tool_only = !user
                    && message.display().trim().is_empty()
                    && message.images().is_empty()
                    && extra_images.is_empty()
                    && calls.is_some_and(|calls| !calls.is_empty());
                heading(
                    output,
                    if user {
                        tr("用户")
                    } else if tool_only {
                        tr("工具调用")
                    } else {
                        tr("助手")
                    },
                    row,
                )?;
                let (files, prose) = if user {
                    leading_file_refs(message.display())
                } else {
                    (Vec::new(), message.display().as_ref())
                };
                if !prose.trim().is_empty() {
                    if user {
                        fenced(output, "text", prose)?;
                    } else {
                        writeln!(output, "{prose}\n")?;
                    }
                }
                if !reason.is_empty() {
                    writeln!(output, "{}", tr("### 推理\n"))?;
                    fenced(output, "text", reason)?;
                }
                if !files.is_empty() || !message.images().is_empty() || !extra_images.is_empty() {
                    writeln!(output, "{}", tr("### 附件\n"))?;
                    for (path, name) in files {
                        writeln!(
                            output,
                            "{}",
                            crate::i18n::format_text!(
                                "- 文件 {} · {}",
                                "- File {} · {}",
                                inline_code(name),
                                inline_code(path)
                            )
                        )?;
                    }
                    for image in message.images() {
                        match &image.source {
                            ImageSource::Gateway(path) => writeln!(
                                output,
                                "{}",
                                crate::i18n::format_text!(
                                    "- 远程图片 {}",
                                    "- Remote image {}",
                                    inline_code(path)
                                )
                            )?,
                            ImageSource::Inline { url, .. } => {
                                if url.split_once(";base64,").is_some_and(|(_, payload)| {
                                    !payload.is_empty()
                                        && payload.bytes().all(|byte| {
                                            byte.is_ascii_alphanumeric()
                                                || matches!(byte, b'+' | b'/' | b'=')
                                        })
                                }) {
                                    writeln!(
                                        output,
                                        "{}",
                                        crate::i18n::format_text!(
                                            "- ![图片](<{url}>)",
                                            "- ![Image](<{url}>)"
                                        )
                                    )?;
                                } else {
                                    writeln!(
                                        output,
                                        "{}",
                                        crate::i18n::format_text!(
                                            "- 图片引用 {}",
                                            "- Image reference {}",
                                            inline_code(url)
                                        )
                                    )?;
                                }
                            }
                        }
                    }
                    for reference in extra_images {
                        writeln!(
                            output,
                            "{}",
                            crate::i18n::format_text!(
                                "- 图片引用 {}",
                                "- Image reference {}",
                                inline_code(reference)
                            )
                        )?;
                    }
                    writeln!(output)?;
                }
                for call in calls.into_iter().flatten() {
                    let function = call.get("function").unwrap_or(call);
                    let name = function["name"]
                        .as_str()
                        .filter(|name| !name.is_empty())
                        .unwrap_or(tr("工具"));
                    if let Some(id) = call["id"].as_str() {
                        tool_names.insert(id.to_owned(), name.to_owned());
                    }
                    if tool_only {
                        writeln!(output, "### {}\n", inline_code(name))?;
                    } else {
                        writeln!(
                            output,
                            "{}",
                            crate::i18n::format_text!(
                                "### 调用 {}\n",
                                "### Call {}\n",
                                inline_code(name)
                            )
                        )?;
                    }
                    let arguments = function
                        .get("arguments")
                        .or_else(|| function.get("args"))
                        .map(text)
                        .unwrap_or_default();
                    if !arguments.is_empty() {
                        fenced(output, "text", &arguments)?;
                    }
                }
            }
            "tool" => {
                let id = string(row, "tool_call_id");
                let name = ["tool_name", "name"]
                    .iter()
                    .find_map(|key| row[*key].as_str().filter(|name| !name.is_empty()))
                    .or_else(|| tool_names.get(id).map(String::as_str))
                    .unwrap_or(tr("工具"));
                heading(
                    output,
                    &crate::i18n::format_text!(
                        "工具结果 · {}",
                        "Tool result · {}",
                        inline_code(name)
                    ),
                    row,
                )?;
                if !id.is_empty() {
                    writeln!(
                        output,
                        "{}",
                        crate::i18n::format_text!("调用 ID {}\n", "Call ID {}\n", inline_code(id))
                    )?;
                }
                fenced(output, "text", &text(value))?;
            }
            "system" | "notice" => {
                let body = text(value);
                if !body.is_empty() {
                    heading(output, tr("系统"), row)?;
                    fenced(output, "text", &body)?;
                }
            }
            _ => {}
        }
    }
    Ok(())
}

fn export_message(value: &Value, user: bool) -> (Message, Vec<&str>) {
    let mut raw = text(value);
    let mut extra = Vec::new();
    let parts = value.as_array().into_iter().flatten();
    for source in parts
        .filter_map(image_part_reference)
        .chain(image_part_reference(value))
    {
        if !source.contains(['\r', '\n']) && ChatImage::from_reference(source).is_some() {
            raw.push_str("\n@image:");
            raw.push_str(source);
        } else {
            extra.push(source);
        }
    }
    (Message::new(raw.into(), user), extra)
}

fn heading(output: &mut impl Write, label: &str, message: &Value) -> std::io::Result<()> {
    let time = message["timestamp"]
        .as_f64()
        .filter(|value| value.is_finite() && *value > 0.)
        .and_then(|value| chrono::DateTime::from_timestamp(value as i64, 0));
    if let Some(time) = time {
        writeln!(
            output,
            "\n## {label} · {}\n",
            time.format("%Y-%m-%d %H:%M UTC")
        )
    } else {
        writeln!(output, "\n## {label}\n")
    }
}

fn escape_inline(text: &str) -> String {
    let mut escaped = String::new();
    for ch in text.chars() {
        if matches!(
            ch,
            '\\' | '`' | '*' | '_' | '[' | ']' | '<' | '>' | '&' | '#' | '~' | '|'
        ) {
            escaped.push('\\');
        }
        escaped.push(ch);
    }
    escaped
}

fn backticks(text: &str, minimum: usize) -> String {
    let mut longest = 0;
    let mut current = 0;
    for ch in text.bytes() {
        current = if ch == b'`' { current + 1 } else { 0 };
        longest = longest.max(current);
    }
    "`".repeat(minimum.max(longest + 1))
}

fn fenced(output: &mut impl Write, language: &str, text: &str) -> std::io::Result<()> {
    let fence = backticks(text, 3);
    writeln!(output, "{fence}{language}\n{text}\n{fence}\n")
}

fn inline_code(text: &str) -> String {
    let text = text.replace(['\r', '\n'], " ");
    let fence = backticks(&text, 1);
    format!("{fence} {text} {fence}")
}
