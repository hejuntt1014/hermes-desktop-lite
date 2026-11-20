use crate::i18n::text as tr;

use std::{
    fs::File,
    io::{Read, Result as IoResult},
    path::{Path, PathBuf},
};

use anyhow::Context as _;
use base64::{Engine as _, engine::general_purpose::STANDARD};
use gpui::{Context, PathPromptOptions, SharedString};
use serde_json::{Value, json};

use crate::media::{attachment_ref, is_image_file, prepare_local_image, upload_chat_image};

use super::{Call, Desktop, Prepared, rpc_error, string};

const MAX_FILE_BYTES: u64 = 25 * 1024 * 1024;

impl Desktop {
    pub(super) fn draft_files(&self) -> Vec<PathBuf> {
        self.workspace()
            .and_then(|workspace| workspace.draft_files.get(&self.key()))
            .cloned()
            .unwrap_or_default()
    }

    pub(super) fn pick_files(&mut self, cx: &mut Context<Self>) {
        let address = self.settings.workspace_key().to_owned();
        let Some(tab_id) = self
            .workspace()
            .and_then(|workspace| workspace.active_tab.clone())
        else {
            return;
        };
        let paths = cx.prompt_for_paths(PathPromptOptions {
            files: true,
            directories: false,
            multiple: true,
            prompt: Some(tr("添加附件").into()),
        });
        cx.spawn(async move |view, cx| {
            let Ok(selection) = paths.await else {
                return;
            };
            let _ = view.update(cx, |this, cx| {
                if this.settings.workspace_key() != address {
                    return;
                }
                match selection {
                    Ok(Some(paths)) => {
                        let key = this.draft_key_for_tab(&tab_id);
                        if let Some(key) = key {
                            this.add_files(key, paths, cx);
                        }
                    }
                    Ok(None) => {}
                    Err(_) => {
                        this.banner = Some(tr("无法打开文件选择窗口").into());
                        cx.notify();
                    }
                }
            });
        })
        .detach();
    }

    pub(super) fn drop_files(&mut self, paths: &[PathBuf], cx: &mut Context<Self>) {
        self.add_files(self.key(), paths.to_vec(), cx);
    }

    pub(super) fn draft_key_for_tab(&self, tab_id: &str) -> Option<String> {
        let workspace = self.workspace()?;
        workspace
            .tabs
            .iter()
            .chain(&workspace.closed_tabs)
            .find(|tab| tab.id == tab_id)
            .map(|tab| tab.session.clone().unwrap_or_else(|| tab.id.clone()))
    }

    pub(super) fn add_files(&mut self, key: String, paths: Vec<PathBuf>, cx: &mut Context<Self>) {
        let files = self
            .workspace_mut()
            .draft_files
            .entry(key.clone())
            .or_default();
        for path in paths {
            if path.is_absolute() && path.file_name().is_some() && !files.contains(&path) {
                files.push(path);
            }
        }
        if files.is_empty() {
            self.workspace_mut().draft_files.remove(&key);
        }
        self.persist(cx);
        cx.notify();
    }

    pub(super) fn remove_file(&mut self, path: &Path, cx: &mut Context<Self>) {
        let key = self.key();
        let workspace = self.workspace_mut();
        if let Some(files) = workspace.draft_files.get_mut(&key) {
            files.retain(|file| file != path);
            if files.is_empty() {
                workspace.draft_files.remove(&key);
            }
        }
        if let Some(session) = self
            .sessions
            .get_mut(&key)
            .filter(|session| !session.uncertain)
        {
            session.error = None;
        }
        self.persist(cx);
        cx.notify();
    }

    pub(super) fn start_submission(
        &mut self,
        key: String,
        mut prepared: Prepared,
        cx: &mut Context<Self>,
    ) {
        if prepared
            .skill
            .as_ref()
            .is_some_and(|skill| skill.prompt.is_none())
        {
            self.dispatch_skill(key, prepared, cx);
            return;
        }
        if prepared.staging
            && !self.canonical
            && let Some(index) = prepared
                .pictures
                .keys()
                .find(|index| !prepared.picture_urls.contains_key(index))
                .copied()
        {
            prepared.file_refs.truncate(index);
            prepared.pictures.retain(|file, _| *file < index);
            prepared.picture_urls.retain(|file, _| *file < index);
        }
        if !prepared.staging || prepared.files.len() == prepared.file_refs.len() {
            self.submit(key, prepared, cx);
            return;
        }
        let Some(connection) = self.out.clone() else {
            return;
        };
        let session = self.sessions.get_mut(&key).unwrap();
        session.submitting = true;
        session.uncertain = false;
        session.error = None;
        let mut params = json!({"session_id":session.runtime});
        if !session.profile.is_empty() {
            params["profile"] = json!(session.profile);
        }
        let runtime_id = session.runtime.clone();
        let path = prepared.files[prepared.file_refs.len()].clone();
        let name = file_name(&path);
        self.workspace_mut()
            .pending_submissions
            .insert(key.clone(), prepared.clone());
        self.persist(cx);

        if is_image_file(&path) {
            self.attach_picture(key, prepared, path, name, runtime_id, cx);
            return;
        }
        let read = self.runtime.spawn_blocking(move || file_data_url(&path));
        cx.spawn(async move |view, cx| {
            let result = read.await;
            let _ = view.update(cx, |this, cx| {
                if !this
                    .out
                    .as_ref()
                    .is_some_and(|out| out.same_channel(&connection))
                {
                    return;
                }
                if !this
                    .sessions
                    .get(&key)
                    .is_some_and(|session| session.runtime == runtime_id && session.submitting)
                {
                    this.attachment_failed(&key, tr("会话已更新，请重新发送附件").into());
                } else if let Ok(Ok(data_url)) = result {
                    params["data_url"] = Value::String(data_url);
                    params["name"] = json!(name);
                    if !this.call(
                        "file.attach",
                        params,
                        Call::AttachFile(key.clone(), prepared),
                    ) {
                        this.attachment_failed(&key, tr("未能上传附件").into());
                    }
                } else {
                    let reason = match result {
                        Ok(Err(error)) if error.kind() == std::io::ErrorKind::FileTooLarge => {
                            tr("附件大小超过 25 MB")
                        }
                        _ => tr("无法读取附件"),
                    };
                    this.attachment_failed(&key, format!("{reason} · {name}"));
                }
                cx.notify();
            });
        })
        .detach();
    }

    fn attach_picture(
        &mut self,
        key: String,
        mut prepared: Prepared,
        path: PathBuf,
        name: String,
        runtime_id: String,
        cx: &mut Context<Self>,
    ) {
        let (Some(connection), Some(gateway)) = (self.out.clone(), self.gateway.clone()) else {
            return;
        };
        if prepared.pictures.len() >= 10 {
            self.attachment_failed(&key, tr("一次最多发送 10 张图片").into());
            cx.notify();
            return;
        }
        let profile = self.sessions[&key].profile.clone();
        let legacy = !self.canonical;
        let job = self.runtime.spawn({
            let name = name.clone();
            async move {
                let image =
                    tokio::task::spawn_blocking(move || prepare_local_image(&path)).await??;
                let upload = upload_chat_image(&gateway, &profile, &name, &image.data_url).await?;
                let reference = attachment_ref("@image:", &upload.path)
                    .context(tr("网关未返回可用的图片引用"))?;
                Ok::<_, anyhow::Error>((upload, reference, legacy.then_some(image.data_url)))
            }
        });
        cx.spawn(async move |view, cx| {
            let result = job
                .await
                .context(tr("读取图片失败"))
                .and_then(|result| result);
            let _ = view.update(cx, |this, cx| {
                if !this
                    .out
                    .as_ref()
                    .is_some_and(|out| out.same_channel(&connection))
                {
                    return;
                }
                if !this
                    .sessions
                    .get(&key)
                    .is_some_and(|session| session.runtime == runtime_id && session.submitting)
                {
                    this.attachment_failed(&key, tr("会话已更新，请重新发送图片").into());
                } else {
                    match result {
                        Ok((upload, reference, data_url)) => {
                            let index = prepared.file_refs.len();
                            prepared.pictures.insert(index, upload);
                            if let Some(data_url) = data_url {
                                prepared.picture_urls.insert(index, data_url.into());
                            }
                            prepared.file_refs.push(reference);
                            this.start_submission(key, prepared, cx);
                        }
                        Err(error) => this.attachment_failed(&key, format!("{name} · {error}")),
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub(super) fn submit_legacy_pictures(
        &mut self,
        key: String,
        mut prepared: Prepared,
        cx: &mut Context<Self>,
    ) {
        let urls = prepared
            .pictures
            .keys()
            .map(|index| prepared.picture_urls.get(index))
            .collect::<Option<Vec<_>>>();
        let Some(urls) = urls else {
            self.attachment_failed(&key, tr("图片需要重新上传").into());
            cx.notify();
            return;
        };
        if urls.iter().map(|url| url.len()).sum::<usize>() > 32 * 1024 * 1024 {
            self.attachment_failed(&key, tr("这组图片超过网关可接收的数据大小").into());
            cx.notify();
            return;
        }
        let urls = urls.into_iter().map(ToString::to_string).collect();
        prepared.legacy = true;
        prepared.picture_urls.clear();
        self.submit_wire(key, prepared, urls, cx);
    }

    pub(super) fn file_attached(
        &mut self,
        key: String,
        mut prepared: Prepared,
        response: &Value,
        error: Option<&Value>,
        cx: &mut Context<Self>,
    ) {
        let name = file_name(&prepared.files[prepared.file_refs.len()]);
        let reference = string(response, "ref_text");
        if error.is_none() && response["attached"] == true && reference.starts_with("@file:") {
            prepared.file_refs.push(reference.to_owned());
            self.start_submission(key, prepared, cx);
        } else {
            let reason = error
                .map(rpc_error)
                .unwrap_or_else(|| tr("网关未返回附件引用").into());
            self.attachment_failed(&key, format!("{name} · {reason}"));
        }
    }

    pub(super) fn attachment_failed(&mut self, key: &str, message: String) {
        if let Some(session) = self.sessions.get_mut(key) {
            session.submitting = false;
            session.error = Some(message);
        }
    }
}

pub(in crate::app) fn file_name(path: &Path) -> String {
    path.file_name()
        .unwrap_or_default()
        .to_string_lossy()
        .into_owned()
}

fn file_data_url(path: &Path) -> IoResult<String> {
    let file = File::open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() {
        return Err(std::io::ErrorKind::InvalidInput.into());
    }
    if metadata.len() > MAX_FILE_BYTES {
        return Err(std::io::ErrorKind::FileTooLarge.into());
    }
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    file.take(MAX_FILE_BYTES + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > MAX_FILE_BYTES {
        return Err(std::io::ErrorKind::FileTooLarge.into());
    }
    let mut url = String::from("data:application/octet-stream;base64,");
    STANDARD.encode_string(bytes, &mut url);
    Ok(url)
}

pub(in crate::app) fn display_file_refs(text: &str) -> (Vec<SharedString>, &str) {
    let (files, body) = leading_file_refs(text);
    (
        files
            .into_iter()
            .map(|(_, name)| SharedString::from(name.to_owned()))
            .collect(),
        body,
    )
}

pub(in crate::app) fn leading_file_refs(text: &str) -> (Vec<(&str, &str)>, &str) {
    let (header, body) = text.split_once("\n\n").unwrap_or((text, ""));
    let files = header
        .lines()
        .map(|line| {
            let path = line.strip_prefix("@file:")?;
            let path = match path.chars().next()? {
                quote @ ('`' | '\'' | '"') => path.strip_prefix(quote)?.strip_suffix(quote)?,
                _ if path.contains(char::is_whitespace) => return None,
                _ => path,
            };
            let name = path.rsplit(['/', '\\']).next()?.trim();
            (!name.is_empty()).then_some((path, name))
        })
        .collect::<Option<Vec<_>>>();
    match files {
        Some(files) if !files.is_empty() => (files, body),
        _ => (Vec::new(), text),
    }
}
