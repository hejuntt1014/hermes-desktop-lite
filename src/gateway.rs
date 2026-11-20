use crate::i18n::text as tr;

use crate::{auth::Tokens, local_gateway::LocalTickets, settings::RemoteAuth};
use std::{
    collections::{BTreeMap, HashMap},
    fmt,
    path::PathBuf,
    sync::Arc,
    time::Duration,
};
use tokio::{io::AsyncWriteExt, sync::Mutex};

use anyhow::{Context, Result, bail};
use futures_util::{SinkExt, StreamExt};
use reqwest::StatusCode;
use serde_json::{Value, json};
use tokio::{runtime::Handle, sync::mpsc, time};
use tokio_tungstenite::{
    MaybeTlsStream, WebSocketStream, connect_async,
    tungstenite::{Error as WebSocketError, Message, client::IntoClientRequest},
};
use url::Url;

const TIMEOUT: Duration = Duration::from_secs(15);
const SIDEBAR_HIDDEN_SOURCES: &str = "acp,cron,kanban,oneshot,subagent,tool";

#[derive(Debug)]
struct HttpFailure {
    status: StatusCode,
    reason: Option<String>,
}

impl fmt::Display for HttpFailure {
    fn fmt(&self, output: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self.reason.as_deref() {
            Some("revision_conflict" | "stale_generation") => {
                write!(output, "{}", tr("会话状态已变化，请重试"))
            }
            Some("session_busy") => write!(output, "{}", tr("会话正在运行，请稍后重试")),
            Some("not_found") => write!(output, "{}", tr("找不到这段会话")),
            _ => write!(
                output,
                "{}",
                crate::i18n::format_text!(
                    "网关请求失败（HTTP {}）",
                    "Gateway request failed (HTTP {})",
                    self.status
                )
            ),
        }
    }
}

impl std::error::Error for HttpFailure {}

pub(crate) fn missing_history_endpoint(error: &anyhow::Error) -> bool {
    error
        .downcast_ref::<HttpFailure>()
        .is_some_and(HttpFailure::missing_endpoint)
}

impl HttpFailure {
    fn missing_endpoint(&self) -> bool {
        self.status == StatusCode::NOT_FOUND
            && self.reason.as_deref().is_some_and(|reason| {
                reason.starts_with("No such API endpoint:")
                    || reason.starts_with("Headless backend (hermes serve): web UI disabled")
            })
    }

    fn rejected_mutation(&self) -> bool {
        matches!(self.status.as_u16(), 400 | 401 | 403 | 404 | 422)
            || matches!(
                self.reason.as_deref(),
                Some(
                    "revision_conflict"
                        | "stale_generation"
                        | "admission_conflict"
                        | "session_busy"
                        | "retained_receipts"
                        | "runtime_coordination_required"
                        | "unknown_execution"
                        | "mutation_identity_required"
                )
            )
    }
}

#[derive(Clone)]
struct MutationIdentity {
    request_id: String,
    revision: u64,
    generation: u64,
}

type SessionEdits = Arc<Mutex<Vec<(Value, MutationIdentity)>>>;
type Socket = WebSocketStream<MaybeTlsStream<tokio::net::TcpStream>>;

#[derive(Debug)]
struct ConnectionRefused(&'static str);

impl fmt::Display for ConnectionRefused {
    fn fmt(&self, output: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(output, "{}", self.0)
    }
}

impl std::error::Error for ConnectionRefused {}

#[derive(Clone)]
pub struct Gateway {
    pub url: Url,
    token: String,
    pub auth: RemoteAuth,
    pub(crate) http: reqwest::Client,
    pub(crate) oauth: Arc<Mutex<Option<Tokens>>>,
    pub(crate) renew: Arc<Mutex<()>>,
    local: Option<Arc<LocalTickets>>,
    session_edits: Arc<Mutex<HashMap<(String, String), SessionEdits>>>,
}

impl Gateway {
    pub fn normalize_address(address: &str) -> Result<Url> {
        let address = address.trim();
        let address = if address.contains("://") {
            address.to_string()
        } else {
            format!("http://{address}")
        };
        let mut url = Url::parse(&address).context(tr("网关地址无效"))?;
        if !matches!(url.scheme(), "http" | "https")
            || url.host().is_none()
            || !url.username().is_empty()
            || url.password().is_some()
            || url.query().is_some()
            || url.fragment().is_some()
        {
            bail!(tr("请输入 HTTP 或 HTTPS 网关地址"));
        }
        let path = url.path().trim_end_matches('/').to_owned();
        url.set_path(&path);
        Ok(url)
    }

    pub fn new(address: &str, auth: RemoteAuth, token: String) -> Result<Self> {
        Self::with_target(Self::normalize_address(address)?, auth, token, None)
    }

    pub fn new_local(url: Url, tickets: LocalTickets) -> Result<Self> {
        Self::with_target(
            url,
            RemoteAuth::Token,
            String::new(),
            Some(Arc::new(tickets)),
        )
    }

    fn with_target(
        url: Url,
        auth: RemoteAuth,
        token: String,
        local: Option<Arc<LocalTickets>>,
    ) -> Result<Self> {
        let http = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(TIMEOUT)
            .build()?;
        Ok(Self {
            url,
            token,
            auth,
            http,
            oauth: Default::default(),
            renew: Default::default(),
            local,
            session_edits: Default::default(),
        })
    }

    pub(crate) fn uses_same_connection(&self, other: &Self) -> bool {
        self.url == other.url
            && self.auth == other.auth
            && self.token == other.token
            && self.local.is_some() == other.local.is_some()
    }

    pub fn is_local(&self) -> bool {
        self.local.is_some()
    }

    pub(crate) fn endpoint(&self, path: &str) -> Url {
        self.url
            .join(&format!(
                "{}/{}",
                self.url.path().trim_end_matches('/'),
                path.trim_start_matches('/')
            ))
            .expect("validated gateway URL")
    }

    async fn api_request(
        &self,
        method: reqwest::Method,
        path: &str,
        params: &[(&str, String)],
        body: Option<Value>,
    ) -> Result<reqwest::Response> {
        let request = self.http.request(method, self.endpoint(path)).query(params);
        let profile = params
            .iter()
            .find(|(name, _)| *name == "profile")
            .map(|(_, value)| value.as_str());
        let mut request = self.authorize(request, profile).await?;
        if let Some(body) = body {
            request = request.json(&body);
        }
        let response = request.send().await.map_err(|e| e.without_url())?;
        Ok(response)
    }

    async fn authorize(
        &self,
        request: reqwest::RequestBuilder,
        profile: Option<&str>,
    ) -> Result<reqwest::RequestBuilder> {
        if let Some(local) = &self.local {
            Ok(request.header(
                "X-Hermes-Gateway-Ticket",
                local.mint("native-http", profile).await?,
            ))
        } else if self.auth == RemoteAuth::Password {
            Ok(request.bearer_auth(self.bearer().await?.context(tr("请重新登录网关"))?))
        } else if !self.token.is_empty() {
            Ok(request.header("X-Hermes-Session-Token", &self.token))
        } else {
            Ok(request)
        }
    }

    pub(crate) async fn save_workspace_file(
        &self,
        path: &str,
        session: &str,
        profile: &str,
        destination: PathBuf,
    ) -> Result<()> {
        let client = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .connect_timeout(TIMEOUT)
            .read_timeout(TIMEOUT)
            .build()?;
        let mut query = vec![("path", path)];
        if !session.is_empty() {
            query.push(("session_id", session));
        }
        if !profile.is_empty() {
            query.push(("profile", profile));
        }
        let request = client.get(self.endpoint("api/fs/download")).query(&query);
        let mut response = self
            .authorize(request, Some(profile))
            .await?
            .send()
            .await
            .map_err(|error| error.without_url())?;
        if response.status() != StatusCode::OK {
            bail!(crate::i18n::format_text!(
                "下载失败（HTTP {}）",
                "Download failed (HTTP {})",
                response.status().as_u16()
            ));
        }
        let total = response.content_length();
        let directory = destination
            .parent()
            .context(tr("没有可用的保存目录"))?
            .to_owned();
        let (temporary, file) = tokio::task::spawn_blocking(move || {
            let temporary = tempfile::Builder::new()
                .prefix(".hermes-download-")
                .tempfile_in(directory)?;
            let file = temporary.as_file().try_clone()?;
            Ok::<_, std::io::Error>((temporary, file))
        })
        .await??;
        let mut file = tokio::fs::File::from_std(file);
        let mut received = 0u64;
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|error| error.without_url())?
        {
            file.write_all(&chunk).await?;
            received += chunk.len() as u64;
        }
        if total.is_some_and(|size| received != size) {
            bail!(tr("下载不完整，请重试"));
        }
        file.flush().await?;
        file.sync_all().await?;
        drop(file);
        tokio::task::spawn_blocking(move || {
            temporary
                .persist(destination)
                .map(drop)
                .context(tr("无法保存下载文件"))
        })
        .await?
    }

    pub(crate) async fn workspace_preview_bytes(
        &self,
        path: &str,
        session: &str,
        profile: &str,
        limit: usize,
    ) -> Result<Vec<u8>> {
        let mut query = vec![("path", path.to_owned())];
        if !session.is_empty() {
            query.push(("session_id", session.to_owned()));
        }
        if !profile.is_empty() {
            query.push(("profile", profile.to_owned()));
        }
        let mut response = self
            .api_request(reqwest::Method::GET, "api/fs/download", &query, None)
            .await?;
        if response.status() != StatusCode::OK {
            bail!(crate::i18n::format_text!(
                "无法读取文件（HTTP {}）",
                "Could not read file (HTTP {})",
                response.status().as_u16()
            ));
        }
        let declared = response.content_length();
        if declared.is_some_and(|size| size > limit as u64) {
            bail!(tr("此文件超过预览大小限制，请下载查看"));
        }
        let mut bytes = Vec::new();
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|error| error.without_url())?
        {
            if chunk.len() > limit - bytes.len() {
                bail!(tr("此文件超过预览大小限制，请下载查看"));
            }
            bytes.extend_from_slice(&chunk);
        }
        if declared.is_some_and(|size| size != bytes.len() as u64) {
            bail!(tr("文件未完整读取，请重试"));
        }
        Ok(bytes)
    }

    pub async fn api(
        &self,
        method: reqwest::Method,
        path: &str,
        params: &[(&str, String)],
        body: Option<Value>,
    ) -> Result<Value> {
        let response = self.api_request(method, path, params, body).await?;
        Self::api_response(response).await
    }

    pub(crate) async fn model_options(&self, profile: &str, refresh: bool) -> Result<Value> {
        let mut request = self
            .http
            .get(self.endpoint("api/model/options"))
            .query(&[("explicit_only", true), ("refresh", refresh)]);
        let profile = Some(profile).filter(|profile| !profile.is_empty());
        if let Some(profile) = profile {
            request = request.query(&[("profile", profile)]);
        }
        if refresh {
            // Live probes can run sequentially across multiple providers.
            request = request.timeout(Duration::from_secs(120));
        }
        let response = self
            .authorize(request, profile)
            .await?
            .send()
            .await
            .map_err(|error| error.without_url())?;
        Self::api_response(response).await
    }

    pub async fn trigger_cron_job(&self, id: &str, profile: &str) -> Result<Value> {
        let path = format!("api/cron/jobs/{}/trigger", crate::encode_path(id));
        let request = self
            .http
            .post(self.endpoint(&path))
            .query(&[("profile", profile)])
            .timeout(Duration::from_secs(24 * 60 * 60));
        let response = self
            .authorize(request, Some(profile))
            .await?
            .send()
            .await
            .map_err(|error| error.without_url())?;
        Self::api_response(response).await
    }

    async fn api_response(response: reqwest::Response) -> Result<Value> {
        if !response.status().is_success() {
            let status = response.status();
            let reason = response.json::<Value>().await.ok().and_then(|body| {
                body["detail"]
                    .as_str()
                    .or_else(|| body["error"].as_str())
                    .filter(|detail| detail.len() <= 128)
                    .map(str::to_owned)
            });
            return Err(HttpFailure { status, reason }.into());
        }
        Ok(response.json().await.map_err(|e| e.without_url())?)
    }

    pub(crate) async fn image_data_url(
        &self,
        path: &str,
        session: &str,
        profile: &str,
    ) -> Result<gpui::SharedString> {
        use crate::media::IMAGE_RESPONSE_LIMIT;
        let mut query = vec![("path", path.to_owned())];
        if !session.is_empty() {
            query.push(("session_id", session.to_owned()));
        }
        if !profile.is_empty() {
            query.push(("profile", profile.to_owned()));
        }
        let mut response = self
            .api_request(reqwest::Method::GET, "api/fs/read-data-url", &query, None)
            .await?;
        if !response.status().is_success() {
            bail!(crate::i18n::format_text!(
                "读取图片失败（HTTP {}）",
                "Could not read image (HTTP {})",
                response.status().as_u16()
            ));
        }
        if response
            .content_length()
            .is_some_and(|length| length > IMAGE_RESPONSE_LIMIT as u64)
        {
            bail!(tr("图片大小超过 16 MB"));
        }
        let mut bytes = Vec::new();
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|error| error.without_url())?
        {
            if bytes.len() + chunk.len() > IMAGE_RESPONSE_LIMIT {
                bail!(tr("图片大小超过 16 MB"));
            }
            bytes.extend_from_slice(&chunk);
        }
        #[derive(serde::Deserialize)]
        struct Payload {
            #[serde(rename = "dataUrl")]
            data_url: String,
        }
        let payload: Payload = serde_json::from_slice(&bytes).context(tr("无效的图片响应"))?;
        Ok(payload.data_url.into())
    }

    pub async fn patch_session(&self, id: &str, profile: &str, payload: Value) -> Result<Value> {
        let path = format!("api/sessions/{}", crate::encode_path(id));
        let mut body = payload.clone();
        if !profile.is_empty() {
            body["profile"] = json!(profile);
        }
        let edits = self
            .session_edits
            .lock()
            .await
            .entry((profile.to_owned(), id.to_owned()))
            .or_default()
            .clone();
        let mut pending = edits.lock().await;
        let identity = match pending.iter().find(|(change, _)| change == &payload) {
            Some((_, identity)) => identity.clone(),
            None => {
                let Some((revision, generation)) = self.session_version(id, profile).await? else {
                    return self
                        .api(reqwest::Method::PATCH, &path, &[], Some(body))
                        .await;
                };
                let identity = MutationIdentity {
                    request_id: uuid::Uuid::new_v4().to_string(),
                    revision,
                    generation,
                };
                pending.push((payload.clone(), identity.clone()));
                identity
            }
        };
        body["request_id"] = json!(identity.request_id);
        body["expected_revision"] = json!(identity.revision);
        body["expected_generation"] = json!(identity.generation);
        let result = self
            .api(reqwest::Method::PATCH, &path, &[], Some(body))
            .await;
        match &result {
            Ok(_) => pending.clear(),
            Err(error)
                if error
                    .downcast_ref::<HttpFailure>()
                    .is_some_and(HttpFailure::rejected_mutation) =>
            {
                pending.retain(|(change, _)| change != &payload);
            }
            _ => {}
        }
        result
    }

    pub async fn session_version(&self, id: &str, profile: &str) -> Result<Option<(u64, u64)>> {
        let mut query = Vec::new();
        if !profile.is_empty() {
            query.push(("profile", profile.to_owned()));
        }
        let path = format!("api/sessions/{}/mutation-snapshot", crate::encode_path(id));
        let snapshot = match self.api(reqwest::Method::GET, &path, &query, None).await {
            Ok(snapshot) => snapshot,
            Err(error)
                if error
                    .downcast_ref::<HttpFailure>()
                    .is_some_and(HttpFailure::missing_endpoint) =>
            {
                return Ok(None);
            }
            Err(error) => return Err(error),
        };
        if snapshot["session_id"] != id || snapshot["exists"] != true {
            bail!(tr("找不到要修改的会话"));
        }
        let revision = snapshot["runtime_revision"]
            .as_u64()
            .context(tr("无法读取会话版本"))?;
        let generation = snapshot["runtime_generation"]
            .as_u64()
            .context(tr("无法读取会话执行版本"))?;
        Ok(Some((revision, generation)))
    }

    pub async fn session_transcript(&self, id: &str, profile: &str) -> Result<Vec<Value>> {
        const MAX_TRANSCRIPT_BYTES: usize = 32_000_000;
        let path = format!("api/sessions/{}/messages", crate::encode_path(id));
        let mut messages = Vec::new();
        let mut bytes = 0;
        let mut target = None;
        let mut offset = 0usize;
        let mut page_starts = std::collections::HashSet::new();
        loop {
            let mut query = vec![
                ("limit", "500".to_owned()),
                ("offset", offset.to_string()),
                ("order", "oldest".to_owned()),
                ("include_compacted", "true".to_owned()),
            ];
            if !profile.is_empty() {
                query.push(("profile", profile.to_owned()));
            }
            let mut page = self.api(reqwest::Method::GET, &path, &query, None).await?;
            if let Some(resolved) = page["session_id"].as_str() {
                if target.as_deref().is_some_and(|known| known != resolved) {
                    bail!(tr("导出期间会话发生变化，请重试"));
                }
                target.get_or_insert_with(|| resolved.to_owned());
            }
            let Value::Array(mut records) = page["messages"].take() else {
                bail!(tr("网关返回了无法读取的会话记录"));
            };
            if let Some(id) = records
                .first()
                .and_then(|row| row["id"].as_u64().or_else(|| row["row_id"].as_u64()))
                && !page_starts.insert(id)
            {
                bail!(tr("网关重复返回同一页历史，请重新导出"));
            }
            if let Some(actual) = page["pagination"]["offset"].as_u64()
                && actual != offset as u64
            {
                bail!(tr("网关返回的历史分页位置不一致"));
            }
            bytes += serde_json::to_vec(&records)?.len();
            if bytes > MAX_TRANSCRIPT_BYTES {
                bail!(tr("会话记录超过 32 MB，可使用网关管理界面导出"));
            }
            let page_size = page["pagination"]["limit"]
                .as_u64()
                .and_then(|limit| usize::try_from(limit).ok());
            let next = page_size
                .filter(|limit| *limit > 0 && records.len() >= *limit)
                .and_then(|limit| offset.checked_add(limit));
            messages.append(&mut records);
            if let Some(next) = next {
                offset = next;
            } else {
                return Ok(messages);
            }
        }
    }

    pub async fn recent_history_page(
        &self,
        id: &str,
        profile: &str,
        offset: usize,
    ) -> Result<HistoryPage> {
        const PAGE_SIZE: usize = 80;
        let path = format!("api/sessions/{}/messages", crate::encode_path(id));
        let mut query = vec![
            ("limit", PAGE_SIZE.to_string()),
            ("offset", offset.to_string()),
            ("order", "latest".to_owned()),
            ("include_compacted", "true".to_owned()),
        ];
        if !profile.is_empty() {
            query.push(("profile", profile.to_owned()));
        }
        let mut page = self.api(reqwest::Method::GET, &path, &query, None).await?;
        let resolved = page["session_id"].as_str().unwrap_or(id).to_owned();
        if let Some(owner) = page["profile"].as_str()
            && !profile.is_empty()
            && owner != profile
        {
            bail!(tr("网关返回的历史所属 Profile 不一致"));
        }
        if let Some(actual) = page["pagination"]["offset"].as_u64()
            && actual != offset as u64
        {
            bail!(tr("网关返回的历史分页位置不一致"));
        }
        let Value::Array(rows) = page["messages"].take() else {
            bail!(tr("网关返回了无法读取的会话记录"));
        };
        let limit = page["pagination"]["limit"]
            .as_u64()
            .and_then(|value| usize::try_from(value).ok());
        let next = limit
            .filter(|limit| *limit > 0 && rows.len() >= *limit)
            .and_then(|limit| offset.checked_add(limit));
        Ok(HistoryPage {
            resolved,
            rows,
            next,
        })
    }

    pub async fn stored_tool_result(
        &self,
        id: &str,
        profile: &str,
        tool: &str,
    ) -> Result<Option<gpui::SharedString>> {
        const PAGE_SIZE: usize = 160;
        const PAGE_LIMIT: usize = 64;
        let path = format!("api/sessions/{}/messages", crate::encode_path(id));
        let mut observed = None;
        for index in 0..PAGE_LIMIT {
            let mut query = vec![
                ("limit", PAGE_SIZE.to_string()),
                ("offset", (index * PAGE_SIZE).to_string()),
                ("order", "latest".to_owned()),
                ("include_compacted", "true".to_owned()),
                ("inline_images", "false".to_owned()),
            ];
            if !profile.is_empty() {
                query.push(("profile", profile.to_owned()));
            }
            let page = self.api(reqwest::Method::GET, &path, &query, None).await?;
            if let Some(session) = page["session_id"].as_str() {
                if observed
                    .as_deref()
                    .is_some_and(|previous| previous != session)
                {
                    bail!(tr("会话已更新，请重新读取工具结果"));
                }
                observed.get_or_insert_with(|| session.to_owned());
            }
            let Some(messages) = page["messages"].as_array() else {
                bail!(tr("网关返回了无法读取的会话记录"));
            };
            if let Some(record) = messages
                .iter()
                .find(|row| row["role"] == "tool" && row["tool_call_id"] == tool)
            {
                let result = ["content", "result", "result_text"]
                    .into_iter()
                    .map(|field| crate::session::text(&record[field]))
                    .find(|text| !text.is_empty());
                return Ok(result.map(Into::into));
            }
            if messages.is_empty() || page["pagination"]["limit"].as_u64().is_none() {
                return Ok(None);
            }
        }
        bail!(tr("工具记录超出可读取的历史范围"))
    }

    pub async fn search_sessions(
        &self,
        query: &str,
        profile: &str,
        limit: usize,
    ) -> Result<Vec<Value>> {
        let path = "api/sessions/search";
        let mut params = vec![
            ("q", query.to_owned()),
            ("limit", limit.to_string()),
            ("min_messages", "1".to_owned()),
        ];
        if !profile.is_empty() {
            params.push(("profile", profile.to_owned()));
        }
        let response = self.api(reqwest::Method::GET, path, &params, None).await;
        let needs_fallback = match &response {
            Ok(value) => value["results"].as_array().is_some_and(Vec::is_empty),
            Err(error) => error.downcast_ref::<HttpFailure>().is_some_and(|error| {
                matches!(
                    error.status,
                    StatusCode::BAD_REQUEST
                        | StatusCode::UNPROCESSABLE_ENTITY
                        | StatusCode::INTERNAL_SERVER_ERROR
                )
            }),
        };
        let mut response = if needs_fallback
            && query
                .chars()
                .any(|ch| !ch.is_alphanumeric() && !ch.is_whitespace())
        {
            // Older gateways can reject a filename or path as FTS syntax.
            // Give their tokenizer the same terms without the separators.
            let normalized = query
                .split(|ch: char| !ch.is_alphanumeric())
                .filter(|term| !term.is_empty())
                .collect::<Vec<_>>()
                .join(" ");
            if normalized.is_empty() {
                return Ok(Vec::new());
            }
            params[0].1 = normalized;
            self.api(reqwest::Method::GET, path, &params, None).await?
        } else {
            response?
        };
        check_session_storage(&response)?;
        let Value::Array(results) = response["results"].take() else {
            bail!(tr("网关返回了无法读取的会话搜索结果"));
        };
        Ok(results)
    }

    pub async fn sessions(
        &self,
        query: &str,
        offset: usize,
        profile: &str,
        archived: bool,
    ) -> Result<SessionPage> {
        if !query.is_empty() {
            let mut rows = self.search_sessions(query, profile, 60).await?;
            rows.retain(|row| (row["archived"] == true) == archived);
            return Ok(SessionPage { rows, next: None });
        }
        let mut params = vec![
            ("limit", "60".to_owned()),
            ("min_messages", "1".to_owned()),
            ("order", "recent".to_owned()),
            ("offset", offset.to_string()),
        ];
        if !profile.is_empty() {
            params.push(("profile", profile.to_owned()));
        }
        if archived {
            params.push(("archived", "only".to_owned()));
        }
        params.push(("exclude_sources", SIDEBAR_HIDDEN_SOURCES.to_owned()));
        let mut response = self
            .api(reqwest::Method::GET, "api/sessions", &params, None)
            .await?;
        let next = offset + 60;
        let next = (response["total"].as_u64().unwrap_or(0) > next as u64).then_some(next);
        check_session_storage(&response)?;
        let Value::Array(mut rows) = response["sessions"].take() else {
            bail!(tr("网关返回了无法读取的会话列表"));
        };
        rows.retain(|row| (row["archived"] == true) == archived);
        Ok(SessionPage { rows, next })
    }

    pub async fn unread_recent_sessions(&self, profile: &str) -> Result<HashMap<String, bool>> {
        let mut params = vec![
            ("limit", "100".to_owned()),
            ("min_messages", "1".to_owned()),
            ("order", "recent".to_owned()),
            ("exclude_sources", SIDEBAR_HIDDEN_SOURCES.to_owned()),
        ];
        if !profile.is_empty() {
            params.push(("profile", profile.to_owned()));
        }
        let response = self
            .api(reqwest::Method::GET, "api/sessions", &params, None)
            .await?;
        check_session_storage(&response)?;
        let rows = response["sessions"]
            .as_array()
            .context(tr("网关返回了无法读取的会话列表"))?;
        Ok(rows
            .iter()
            .filter_map(|row| {
                if !profile.is_empty()
                    && row["profile"]
                        .as_str()
                        .is_some_and(|name| !name.is_empty() && name != profile)
                {
                    return None;
                }
                let id = row["id"].as_str().or_else(|| row["session_id"].as_str())?;
                (!id.is_empty()).then(|| {
                    (
                        id.to_owned(),
                        row["unread"] == true && row["archived"] != true,
                    )
                })
            })
            .collect())
    }

    pub fn start(&self, runtime: &Handle) -> Connection {
        let (tx, rx) = mpsc::unbounded_channel();
        let gateway = self.clone();
        let task = runtime.spawn(gateway.run(tx));
        Connection { inbox: rx, task }
    }

    async fn run(self, tx: mpsc::UnboundedSender<Update>) {
        let mut failures = 0_u32;
        loop {
            let result = self.socket(&tx, &mut failures).await;
            let (reason, denied) = match result {
                Ok(false) => return,
                Ok(true) => (tr("连接已断开").to_owned(), false),
                Err(error) => {
                    let denied = error.is::<ConnectionRefused>();
                    (error.to_string(), denied)
                }
            };
            failures = failures.saturating_add(1);
            let delay = Duration::from_secs(1 << (failures - 1).min(4));
            if tx
                .send(Update::Offline {
                    reason,
                    retry: !denied && failures < 7,
                })
                .is_err()
                || denied
                || failures >= 7
            {
                return;
            }
            time::sleep(delay).await;
        }
    }

    async fn open_socket(
        &self,
        sign_in: Option<&mpsc::UnboundedSender<Update>>,
    ) -> Result<(Socket, Value, Option<String>)> {
        let mut ws = self.endpoint("api/ws");
        ws.set_scheme(if self.url.scheme() == "https" {
            "wss"
        } else {
            "ws"
        })
        .expect("HTTP and WS URL schemes are compatible");
        let status: Value = if self.is_local() {
            self.api(reqwest::Method::GET, "api/status", &[], None)
                .await?
        } else {
            self.http
                .get(self.endpoint("api/status"))
                .send()
                .await
                .map_err(|error| error.without_url())?
                .error_for_status()
                .map_err(|error| error.without_url())?
                .json()
                .await
                .map_err(|error| error.without_url())?
        };
        let protocols = if let Some(local) = &self.local {
            Some(local.socket_protocols().await?)
        } else {
            match self.auth {
                RemoteAuth::Password => {
                    if status["auth_required"] == false {
                        return Err(
                            ConnectionRefused(tr("该网关使用访问令牌，请切换认证方式")).into()
                        );
                    }
                    let ticket = self.password_socket_ticket(sign_in).await?;
                    ws.query_pairs_mut().append_pair("ticket", &ticket);
                }
                RemoteAuth::Token => {
                    if self.token.is_empty() {
                        return Err(ConnectionRefused(tr("请输入此网关的访问令牌")).into());
                    }
                    ws.query_pairs_mut().append_pair("token", &self.token);
                }
            }
            None
        };
        let mut request = ws
            .as_str()
            .into_client_request()
            .context(tr("网关连接地址无效"))?;
        if let Some(protocols) = protocols {
            request.headers_mut().insert(
                "Sec-WebSocket-Protocol",
                protocols.parse().context(tr("本地网关票据无效"))?,
            );
        }
        let (mut socket, _) = time::timeout(TIMEOUT, connect_async(request))
            .await
            .context(tr("连接网关超时"))?
            .map_err(websocket_failure)?;

        let ready = time::timeout(TIMEOUT, async {
            while let Some(frame) = socket.next().await {
                match frame.map_err(websocket_failure)? {
                    Message::Text(text) => {
                        let value: Value = serde_json::from_str(&text)?;
                        if value["params"]["type"] == "gateway.ready" {
                            return Ok(value["params"]["payload"].clone());
                        }
                    }
                    Message::Close(close)
                        if close.as_ref().is_some_and(|close| {
                            matches!(u16::from(close.code), 1008 | 4401 | 4403)
                        }) =>
                    {
                        return Err(ConnectionRefused(tr("网关拒绝了此认证")).into());
                    }
                    Message::Close(_) => break,
                    Message::Ping(_) => socket.flush().await.map_err(websocket_failure)?,
                    _ => {}
                }
            }
            bail!(tr("网关在就绪前断开"))
        })
        .await
        .context(tr("等待网关就绪超时"))??;

        let version = status["version"]
            .as_str()
            .filter(|version| !version.is_empty())
            .map(str::to_owned);
        Ok((socket, ready, version))
    }

    async fn password_socket_ticket(
        &self,
        sign_in: Option<&mpsc::UnboundedSender<Update>>,
    ) -> Result<String> {
        let bearer = match (self.bearer().await?, sign_in) {
            (Some(bearer), _) => bearer,
            (None, Some(tx)) => self.login(tx).await?,
            (None, None) => return Err(ConnectionRefused(tr("请先在浏览器完成网关登录")).into()),
        };
        let mut response = self.request_ws_ticket(&bearer).await?;
        if response.status() == StatusCode::UNAUTHORIZED {
            let next = match (self.refresh_bearer(Some(&bearer)).await?, sign_in) {
                (Some(bearer), _) => bearer,
                (None, Some(tx)) => self.login(tx).await?,
                (None, None) => {
                    return Err(ConnectionRefused(tr("远程登录已过期，请重新登录")).into());
                }
            };
            response = self.request_ws_ticket(&next).await?;
        }
        if matches!(
            response.status(),
            StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN
        ) {
            return Err(ConnectionRefused(tr("网关拒绝了登录凭据，请重新登录")).into());
        }
        let reply: Value = response
            .error_for_status()
            .map_err(|error| error.without_url())?
            .json()
            .await
            .map_err(|error| error.without_url())?;
        reply["ticket"]
            .as_str()
            .filter(|ticket| !ticket.is_empty())
            .map(str::to_owned)
            .context(tr("网关未返回连接票据"))
    }

    async fn request_ws_ticket(&self, bearer: &str) -> Result<reqwest::Response> {
        Ok(self
            .http
            .post(self.endpoint("api/auth/ws-ticket"))
            .bearer_auth(bearer)
            .send()
            .await
            .map_err(|error| error.without_url())?)
    }

    pub async fn test_remote(&self) -> Result<Option<String>> {
        let (mut socket, _, version) = self.open_socket(None).await?;
        let _ = time::timeout(Duration::from_secs(1), socket.close(None)).await;
        self.api(
            reqwest::Method::GET,
            "api/sessions",
            &[("limit", "1".into())],
            None,
        )
        .await?;
        Ok(version)
    }

    async fn socket(&self, tx: &mpsc::UnboundedSender<Update>, failures: &mut u32) -> Result<bool> {
        let (mut socket, ready, version) = self.open_socket(Some(tx)).await?;
        let capability_id = "lite-capabilities";
        let capabilities = json!({"jsonrpc":"2.0", "id":capability_id,
            "method":"client.capabilities", "params":{"server_requests":true}});
        time::timeout(
            TIMEOUT,
            socket.send(Message::Text(capabilities.to_string().into())),
        )
        .await??;
        let mut early_frames = Vec::new();
        let clarify_batch = time::timeout(Duration::from_secs(3), async {
            while let Some(frame) = socket.next().await {
                match frame? {
                    Message::Text(text) => {
                        let Ok(value) = serde_json::from_str::<Value>(&text) else {
                            continue;
                        };
                        if value["id"] == capability_id && value["method"].is_null() {
                            return Ok(value["result"]["canonical_clarify_batch"] == true);
                        }
                        early_frames.push(value);
                    }
                    Message::Close(_) => break,
                    Message::Ping(_) => socket.flush().await?,
                    _ => {}
                }
            }
            bail!(tr("网关在协商客户端能力时断开"))
        })
        .await
        .unwrap_or(Ok(false))?;

        let (out, mut outgoing) = mpsc::unbounded_channel::<Outgoing>();
        let epoch = ready["replay_epoch"]
            .as_str()
            .unwrap_or_default()
            .to_owned();
        let canonical = ready["session_authority"] == true;
        let heartbeat = ready["heartbeat"] == true;
        *failures = 0;
        if tx
            .send(Update::Online {
                out,
                canonical,
                clarify_batch: canonical && clarify_batch,
                epoch,
                version,
            })
            .is_err()
        {
            return Ok(false);
        }
        for frame in early_frames {
            if tx.send(Update::Frame(frame)).is_err() {
                return Ok(false);
            }
        }

        let mut interval = time::interval_at(time::Instant::now() + TIMEOUT, TIMEOUT);
        let mut last_frame = time::Instant::now();
        let mut deadlines = BTreeMap::new();
        loop {
            tokio::select! {
                cmd = outgoing.recv() => {
                    let Some(Outgoing { message: frame, attachment }) = cmd else { return Ok(false) };
                    if let Some(file) = attachment {
                        let id = frame["id"].as_u64().context("file.attach request ID is missing")?;
                        crate::file_upload::send(&mut socket, id, &frame["params"], file).await?;
                        // A streamed transfer may take longer than the idle threshold.
                        last_frame = time::Instant::now();
                    } else {
                        time::timeout(TIMEOUT, socket.send(Message::Text(frame.to_string().into()))).await??;
                    }
                    if let Some(id) = frame["id"].as_u64().filter(|_| frame["method"].is_string()) {
                        let seconds = if matches!(frame["method"].as_str(), Some("approval.respond" | "clarify.respond")) { 300 } else { 120 };
                        deadlines.insert(id, time::Instant::now() + Duration::from_secs(seconds));
                    }
                }
                frame = socket.next() => {
                    let Some(frame) = frame else { return Ok(true) };
                    last_frame = time::Instant::now();
                    match frame? {
                        Message::Text(text) => {
                            let Ok(value) = serde_json::from_str::<Value>(&text) else { continue };
                            if let Some(id) = value["id"].as_u64().filter(|_| value["method"].is_null()) {
                                deadlines.remove(&id);
                            }
                            if tx.send(Update::Frame(value)).is_err() {
                                return Ok(false);
                            }
                        }
                        Message::Close(_) => return Ok(true),
                        Message::Ping(_) => socket.flush().await?,
                        _ => {}
                    }
                }
                _ = interval.tick() => {
                    if last_frame.elapsed() >= TIMEOUT * 3 {
                        bail!(tr("网关连接超时"));
                    }
                    if heartbeat {
                        let ping = json!({"jsonrpc":"2.0","id":"lite-heartbeat","method":"gateway.ping","params":{}});
                        time::timeout(TIMEOUT, socket.send(Message::Text(ping.to_string().into()))).await??;
                    } else {
                        socket.send(Message::Ping(Vec::new().into())).await?;
                    }
                    let now = time::Instant::now();
                    deadlines.retain(|id, deadline| {
                        if *deadline > now { return true }
                        let _ = tx.send(Update::Timeout(*id));
                        false
                    });
                }
            }
        }
    }
}

pub struct SessionPage {
    pub rows: Vec<Value>,
    pub next: Option<usize>,
}

pub struct HistoryPage {
    pub resolved: String,
    pub rows: Vec<Value>,
    pub next: Option<usize>,
}

pub struct Outgoing {
    pub message: Value,
    pub attachment: Option<tokio::fs::File>,
}

impl From<Value> for Outgoing {
    fn from(message: Value) -> Self {
        Self {
            message,
            attachment: None,
        }
    }
}

pub enum Update {
    SignIn(String),
    Online {
        out: mpsc::UnboundedSender<Outgoing>,
        canonical: bool,
        clarify_batch: bool,
        epoch: String,
        version: Option<String>,
    },
    Offline {
        reason: String,
        retry: bool,
    },
    Frame(Value),
    Timeout(u64),
}

pub struct Connection {
    pub inbox: mpsc::UnboundedReceiver<Update>,
    task: tokio::task::JoinHandle<()>,
}

impl Drop for Connection {
    fn drop(&mut self) {
        self.task.abort();
    }
}

fn check_session_storage(response: &Value) -> Result<()> {
    if response["storage"]
        .as_object()
        .is_some_and(|profiles| profiles.values().any(|value| value == "corrupt"))
    {
        bail!(tr("网关报告会话存储已损坏"));
    }
    Ok(())
}

fn websocket_failure(error: WebSocketError) -> anyhow::Error {
    if let WebSocketError::Http(reply) = &error {
        if matches!(reply.status().as_u16(), 401 | 403) {
            return ConnectionRefused(tr("网关拒绝了此认证，请检查访问令牌或登录状态")).into();
        }
        return anyhow::anyhow!(crate::i18n::format_text!(
            "网关拒绝连接（HTTP {}）",
            "The gateway refused the connection (HTTP {})",
            reply.status().as_u16()
        ));
    }
    anyhow::anyhow!(tr("无法连接网关 WebSocket"))
}
