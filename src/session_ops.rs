use crate::i18n::text as tr;

use anyhow::{Context as _, Result};
use gpui::{Context, Window};
use serde_json::{Value, json};

use crate::{
    gateway::Gateway,
    session::{BranchPoint, SessionTarget, Summary, string, text},
    settings::ChatTab,
};

use super::{Call, Desktop, rpc_error};

pub(super) struct BranchPlan {
    request_id: String,
    command: Option<(&'static str, Value)>,
}

impl Desktop {
    pub(super) fn branch_session(
        &mut self,
        target: SessionTarget,
        through: Option<BranchPoint>,
        window: &Window,
        cx: &mut Context<Self>,
    ) {
        let Some(gateway) = self.gateway.clone().filter(|_| self.out.is_some()) else {
            return;
        };
        let branch = (target.id.clone(), through.clone());
        if self.pending.values().any(|call| {
            matches!(call, Call::Branch { target: parent, through: boundary, .. }
            if parent.id == target.id && boundary == &through)
        }) {
            return;
        }
        let origin_tab = self
            .workspace()
            .and_then(|workspace| workspace.active_tab.clone());
        let runtime_session = self
            .sessions
            .get(&target.id)
            .filter(|session| session.attached && !session.runtime.is_empty())
            .map(|session| session.runtime.clone());
        if !self.canonical && through.is_some() && runtime_session.is_none() {
            self.banner = Some(tr("请等待会话恢复后再分叉").into());
            cx.notify();
            return;
        }
        if let Some(plan) = self.branch_requests.get(&branch) {
            if let Some((method, mut params)) = plan.command.clone() {
                if method == "session.branch"
                    && let Some(runtime_session) = runtime_session
                {
                    params["session_id"] = json!(runtime_session);
                }
                self.call(
                    method,
                    params,
                    Call::Branch {
                        target,
                        through,
                        origin_tab,
                    },
                );
            }
            return;
        }

        let canonical = self.canonical;
        let request_id = uuid::Uuid::new_v4().to_string();
        self.branch_requests.insert(
            branch.clone(),
            BranchPlan {
                request_id: request_id.clone(),
                command: None,
            },
        );
        let preparation = self.runtime.spawn({
            let target = target.clone();
            let through = through.clone();
            let request = request_id.clone();
            async move {
                prepare_branch(
                    &gateway,
                    &target,
                    through.as_ref(),
                    canonical,
                    runtime_session.as_deref(),
                    &request,
                )
                .await
            }
        });
        cx.spawn_in(window, async move |view, cx| {
            let result = preparation
                .await
                .context(tr("无法读取分叉边界"))
                .and_then(|result| result);
            let _ = view.update_in(cx, |this, _, cx| {
                let Some(plan) = this
                    .branch_requests
                    .get_mut(&branch)
                    .filter(|plan| plan.request_id == request_id)
                else {
                    return;
                };
                let (method, params) = match result {
                    Ok(command) => command,
                    Err(error) => {
                        this.branch_requests.remove(&branch);
                        this.banner = Some(
                            crate::i18n::format_text!(
                                "无法分叉 · {error}",
                                "Could not fork · {error}"
                            )
                            .into(),
                        );
                        cx.notify();
                        return;
                    }
                };
                plan.command = Some((method, params.clone()));
                if !this.call(
                    method,
                    params,
                    Call::Branch {
                        target,
                        through,
                        origin_tab,
                    },
                ) {
                    this.banner = Some(tr("网关已离线，连接后可重试分叉").into());
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub(super) fn finish_branch(
        &mut self,
        target: SessionTarget,
        through: Option<BranchPoint>,
        origin_tab: Option<String>,
        response: &Value,
        error: Option<&Value>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let branch = (target.id.clone(), through);
        if let Some(error) = error {
            let reason = error["data"]["reason"]
                .as_str()
                .or_else(|| error["message"].as_str())
                .unwrap_or_default();
            if matches!(error["code"].as_i64(), Some(-32601 | -32602 | 4008 | 4018))
                || matches!(
                    reason,
                    "revision_conflict"
                        | "stale_generation"
                        | "session_busy"
                        | "invalid_params"
                        | "not_found"
                        | "permission_denied"
                        | "profile_mismatch"
                        | "admission_conflict"
                )
            {
                self.branch_requests.remove(&branch);
            }
            self.banner = Some(
                crate::i18n::format_text!("无法分叉 · {}", "Could not fork · {}", rpc_error(error))
                    .into(),
            );
            return;
        }
        let canonical = self
            .branch_requests
            .get(&branch)
            .and_then(|plan| plan.command.as_ref())
            .is_some_and(|(method, _)| *method == "session.mutate");
        let keys: &[&str] = if canonical {
            &["branched_session_id"]
        } else {
            &["stored_session_id", "session_id"]
        };
        let Some(id) = keys
            .iter()
            .find_map(|key| response[*key].as_str().filter(|id| !id.is_empty()))
            .map(str::to_owned)
        else {
            self.banner = Some(tr("网关未返回分叉会话标识，可重试").into());
            return;
        };
        self.branch_requests.remove(&branch);
        let title = match string(response, "title") {
            "" => crate::i18n::format_text!("{} · 分叉", "{} · Fork", target.title),
            title => title.to_owned(),
        };
        let session = self.sessions.entry(id.clone()).or_default();
        session.profile.clone_from(&target.profile);
        let runtime = string(response, "session_id");
        if !runtime.is_empty() && runtime != target.id {
            session.runtime = runtime.to_owned();
            session
                .parked
                .extend(self.unbound.remove(runtime).unwrap_or_default());
            self.aliases.insert(runtime.to_owned(), id.clone());
        }
        self.insert_profile_session(Summary {
            id: id.clone(),
            title: title.clone().into(),
            pinned: false,
            archived: false,
            unread: false,
            profile: target.profile.clone(),
            updated_at: chrono::Utc::now().timestamp(),
            lineage_root: String::new(),
            branch_parent: target.id.clone(),
        });
        let workspace = self.workspace_mut();
        let select_child = workspace.active_tab == origin_tab;
        let tab_id = if let Some(existing) = workspace
            .tabs
            .iter()
            .find(|tab| tab.session.as_deref() == Some(&id))
        {
            existing.id.clone()
        } else {
            let mut tab = ChatTab::draft();
            tab.session = Some(id);
            tab.title = title;
            tab.profile = target.profile;
            let tab_id = tab.id.clone();
            workspace.tabs.push(tab);
            tab_id
        };
        if select_child {
            self.select_tab(&tab_id, window, cx);
        } else {
            self.persist(cx);
        }
        self.fetch_list(0, false, window, cx);
    }
}

async fn prepare_branch(
    gateway: &Gateway,
    target: &SessionTarget,
    through: Option<&BranchPoint>,
    canonical: bool,
    runtime_session: Option<&str>,
    request_id: &str,
) -> Result<(&'static str, Value)> {
    let (method, mut params) = if canonical {
        let (revision, generation) = gateway
            .session_version(&target.id, &target.profile)
            .await?
            .context(tr("网关未提供分叉所需的会话版本"))?;
        let payload = match through {
            Some(point) => {
                let id = match point.row_id {
                    Some(id) => id,
                    None => resolve_branch_boundary(gateway, target, point).await?.0,
                };
                json!({"through_message_id":id})
            }
            None => json!({}),
        };
        (
            "session.mutate",
            json!({
                "session_id":target.id, "request_id":request_id, "expected_revision":revision,
                "expected_generation":generation, "operation":"branch", "payload":payload,
            }),
        )
    } else if let Some(point) = through {
        let (_, count) = resolve_branch_boundary(gateway, target, point).await?;
        (
            "session.branch",
            json!({
                "session_id":runtime_session.context(tr("请等待会话恢复后再分叉"))?,
                "count":count, "idempotency_key":request_id,
            }),
        )
    } else {
        (
            "session.branch_stored",
            json!({"parent_session_id":target.id, "source":"desktop", "idempotency_key":request_id}),
        )
    };
    if !target.profile.is_empty() {
        params["profile"] = json!(target.profile);
    }
    Ok((method, params))
}

async fn resolve_branch_boundary(
    gateway: &Gateway,
    target: &SessionTarget,
    point: &BranchPoint,
) -> Result<(u64, usize)> {
    let messages = gateway
        .session_transcript(&target.id, &target.profile)
        .await?;
    let mut count = 0;
    let mut found = None;
    for message in messages {
        let role = string(&message, "role");
        if !matches!(role, "user" | "assistant") || !branch_has_content(&message["content"]) {
            continue;
        }
        count += 1;
        if role != "assistant" {
            continue;
        }
        let id = message["id"]
            .as_u64()
            .or_else(|| message["row_id"].as_u64());
        let matches = if let Some(expected) = point.row_id {
            id == Some(expected)
        } else {
            let timestamp = message["timestamp"].as_f64().map(f64::to_bits);
            let content = message
                .get("display_content")
                .filter(|value| !value.is_null())
                .unwrap_or(&message["content"]);
            timestamp.is_some()
                && timestamp == point.timestamp_bits
                && text(content).trim() == point.text.trim()
        };
        if matches {
            if found.is_some() {
                anyhow::bail!(tr("回复的保存位置不唯一，请刷新会话后重试"));
            }
            found = Some((id.context(tr("网关未返回回复的保存位置"))?, count));
        }
    }
    found.context(tr("找不到这条已保存的回复，请刷新会话后重试"))
}

fn branch_has_content(content: &Value) -> bool {
    let part_has_content = |part: &Value| {
        if let Some(text) = part.as_str().or_else(|| part["text"].as_str()) {
            return !text.trim().is_empty();
        }
        let kind = string(part, "type");
        if matches!(kind, "text" | "input_text" | "output_text") {
            return !string(part, "content").trim().is_empty();
        }
        !kind.is_empty()
    };
    match content {
        Value::Array(parts) => parts.iter().any(part_has_content),
        Value::Object(_) => {
            if content.get("type").is_none() && content.get("text").is_none() {
                true
            } else {
                part_has_content(content)
            }
        }
        _ => !text(content).trim().is_empty(),
    }
}
