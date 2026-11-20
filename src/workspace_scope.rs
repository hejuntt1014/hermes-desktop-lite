use anyhow::{Result, bail};
use gpui::SharedString;
use serde_json::Value;

use crate::{gateway::Gateway, session::string};

use super::{
    Desktop,
    remote_refs::{gateway_path, scoped_path},
};

#[derive(Clone, PartialEq, Eq)]
pub(super) struct WorkspaceScope {
    pub session: String,
    pub profile: String,
    pub cwd: SharedString,
}

impl Desktop {
    pub(super) fn active_workspace_scope(&self) -> Option<WorkspaceScope> {
        let session = self.selected.as_deref().unwrap_or_default();
        let info = self.sessions.get(session);
        if !session.is_empty()
            && info.is_none_or(|session| session.cwd.is_empty() && !session.attached)
        {
            return None;
        }
        let profile = info
            .map(|info| info.profile.clone())
            .filter(|profile| !profile.is_empty())
            .unwrap_or_else(|| self.active_profile().to_owned());
        Some(WorkspaceScope {
            session: session.to_owned(),
            profile,
            cwd: info.map(|info| info.cwd.clone()).unwrap_or_default(),
        })
    }
}

impl WorkspaceScope {
    pub(super) async fn file_path(&self, gateway: &Gateway, path: &str) -> Result<String> {
        if gateway_path(path, false) {
            return Ok(path.to_owned());
        }
        let cwd = self.root(gateway).await?;
        Ok(scoped_path(&cwd, path).into_owned())
    }

    pub(super) async fn root(&self, gateway: &Gateway) -> Result<String> {
        if !self.cwd.is_empty() {
            return Ok(self.cwd.to_string());
        }
        let value = self
            .get(gateway, "api/fs/default-cwd", Vec::new(), false)
            .await?;
        let path = string(&value, "cwd");
        if path.is_empty() {
            bail!("网关没有提供工作区目录");
        }
        Ok(path.to_owned())
    }

    pub(super) async fn get(
        &self,
        gateway: &Gateway,
        endpoint: &str,
        mut params: Vec<(&str, String)>,
        session: bool,
    ) -> Result<Value> {
        if !self.profile.is_empty() {
            params.push(("profile", self.profile.clone()));
        }
        if session && !self.session.is_empty() {
            params.push(("session_id", self.session.clone()));
        }
        gateway
            .api(reqwest::Method::GET, endpoint, &params, None)
            .await
    }
}

pub(super) struct WorkspaceRequest {
    pub _task: gpui::Task<()>,
    pub abort: tokio::task::AbortHandle,
}

impl Drop for WorkspaceRequest {
    fn drop(&mut self) {
        self.abort.abort();
    }
}
