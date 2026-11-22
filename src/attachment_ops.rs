use crate::i18n::text as tr;

use std::path::{Path, PathBuf};

use anyhow::Context as _;
use gpui::{Context, PathPromptOptions, SharedString};
use serde_json::{Value, json};

use crate::media::{attachment_ref, is_image_file, prepare_local_image, upload_chat_image};

use super::{Call, Desktop, Prepared, rpc_error, string};

pub(super) enum AttachmentJob {
    Draft(PathBuf),
    Send(Prepared),
}

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
        self.start_eager_attachment(&key, cx);
        cx.notify();
    }

    pub(super) fn remove_file(&mut self, path: &Path, cx: &mut Context<Self>) {
        let key = self.key();
        let mut cancelled = false;
        let mut stop_submission = false;
        if let Some(session) = self.sessions.get_mut(&key)
            && session
                .upload
                .as_ref()
                .is_some_and(|upload| upload.path == path)
        {
            let upload = session.upload.take().unwrap();
            upload.cancel.cancel();
            cancelled = true;
            stop_submission = std::mem::take(&mut session.submitting);
            session.uploading_draft_file = None;
            session.waiting_for_draft_upload = false;
        }
        let workspace = self.workspace_mut();
        if stop_submission && let Some(pending) = workspace.pending_submissions.remove(&key) {
            if pending.queued
                && let Some(queue) = workspace.followups.get_mut(&key)
                && let Some(item) = queue.iter_mut().find(|item| item.id == pending.id)
                && let Some(index) = item.files.iter().position(|file| file == path)
            {
                item.files.remove(index);
                item.file_refs.truncate(index);
                item.pictures.retain(|i, _| *i < index);
                item.picture_urls.retain(|i, _| *i < index);
                queue.retain(|item| {
                    item.id != pending.id || !item.files.is_empty() || !item.text.trim().is_empty()
                });
            }
        }
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
            session.staged_draft_files.remove(path);
            session.draft_upload_errors.remove(path);
        }
        self.persist(cx);
        if cancelled {
            self.start_eager_attachment(&key, cx);
        }
        cx.notify();
    }

    pub(super) fn start_eager_attachment(&mut self, key: &str, cx: &mut Context<Self>) {
        let Some(workspace) = self.workspace().filter(|_| self.out.is_some()) else {
            return;
        };
        let Some(files) = workspace.draft_files.get(key) else {
            return;
        };
        let session = self.sessions.get(key);
        let files_to_upload = files
            .iter()
            .filter(|path| !is_image_file(path))
            .filter(|path| {
                session.is_none_or(|session| {
                    !session.staged_draft_files.contains_key(*path)
                        && !session.draft_upload_errors.contains_key(*path)
                })
            });
        let Some(path) = files_to_upload.into_iter().next().cloned() else {
            return;
        };
        if let Some(session) = session {
            if !session.attached
                || session.loading
                || session.submitting
                || session.uncertain
                || session.uploading_draft_file.is_some()
            {
                return;
            }
            let number = files.iter().position(|entry| *entry == path).unwrap() + 1;
            let count = files.len();
            self.sessions.get_mut(key).unwrap().uploading_draft_file = Some(path.clone());
            let progress = self.show_attachment_progress(key, &path, number, count, cx);
            self.start_file_attachment(
                key.to_owned(),
                path.clone(),
                AttachmentJob::Draft(path),
                progress,
                cx,
            );
        } else if let Some(tab) = workspace
            .tabs
            .iter()
            .find(|tab| tab.id == key && tab.session.is_none())
            && !self
                .pending
                .values()
                .any(|call| matches!(call, Call::Create { draft, .. } if draft == key))
        {
            let profile = self.tab_profile(tab).to_owned();
            let launch = workspace.draft_launch.get(key).cloned().unwrap_or_default();
            self.create_chat(
                key.to_owned(),
                uuid::Uuid::new_v4().to_string(),
                profile,
                launch,
                true,
            );
        }
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
        if let Some(session) = self.sessions.get_mut(&key) {
            if session.uploading_draft_file.is_some() {
                session.waiting_for_draft_upload = true;
                session.submitting = true;
                self.workspace_mut()
                    .pending_submissions
                    .insert(key, prepared);
                self.persist(cx);
                return;
            }
            session.upload = None;
            if prepared.staging {
                while let Some(reference) = prepared
                    .files
                    .get(prepared.file_refs.len())
                    .and_then(|path| session.staged_draft_files.get(path))
                {
                    prepared.file_refs.push(reference.clone());
                }
            }
        }
        if !prepared.staging || prepared.files.len() == prepared.file_refs.len() {
            self.submit(key, prepared, cx);
            return;
        }
        if self.out.is_none() {
            return;
        }
        let session = self.sessions.get_mut(&key).unwrap();
        session.submitting = true;
        session.uncertain = false;
        session.error = None;
        let runtime_id = session.runtime.clone();
        let number = prepared.file_refs.len() + 1;
        let path = prepared.files[number - 1].clone();
        self.workspace_mut()
            .pending_submissions
            .insert(key.clone(), prepared.clone());
        self.persist(cx);
        let progress = self.show_attachment_progress(&key, &path, number, prepared.files.len(), cx);
        if is_image_file(&path) {
            let name = file_name(&path);
            self.attach_picture(key, prepared, path, name, runtime_id, progress, cx);
        } else {
            self.start_file_attachment(key, path, AttachmentJob::Send(prepared), progress, cx);
        }
    }

    fn show_attachment_progress(
        &mut self,
        key: &str,
        path: &Path,
        number: usize,
        count: usize,
        cx: &mut Context<Self>,
    ) -> crate::upload_progress::Reporter {
        let (progress, state) = crate::upload_progress::Reporter::new();
        let mut changes = state.clone();
        let active = key.to_owned();
        let repaint = cx.spawn(async move |view, cx| {
            cx.background_executor()
                .timer(std::time::Duration::from_millis(180))
                .await;
            loop {
                let expires = changes.borrow_and_update().speed_expires_in();
                if view
                    .update(cx, |this, cx| {
                        if this.selected.as_ref() == Some(&active) {
                            cx.notify();
                        }
                    })
                    .is_err()
                {
                    break;
                }
                let changed = if let Some(remaining) = expires {
                    tokio::select! {
                        changed = changes.changed() => changed,
                        _ = cx.background_executor().timer(remaining) => continue,
                    }
                } else {
                    changes.changed().await
                };
                if changed.is_err() {
                    break;
                }
            }
        });
        self.sessions.get_mut(key).unwrap().upload = Some(crate::upload_progress::Display {
            path: path.to_owned(),
            cancel: crate::upload_progress::Cancel::new(),
            number,
            count,
            started: std::time::Instant::now(),
            state,
            _repaint: repaint,
        });

        progress
    }

    fn start_file_attachment(
        &mut self,
        key: String,
        path: PathBuf,
        job: AttachmentJob,
        progress: crate::upload_progress::Reporter,
        cx: &mut Context<Self>,
    ) {
        let Some(connection) = self.out.clone() else {
            return;
        };
        let session = &self.sessions[&key];
        let runtime_id = session.runtime.clone();
        let cancel = session.upload.as_ref().unwrap().cancel.clone();
        let transfer_cancel = cancel.clone();
        let name = file_name(&path);
        let profile = &session.profile;
        let profile = if profile.is_empty() {
            &self.profiles.serving
        } else {
            profile
        }
        .clone();
        let home = self
            .profiles
            .entries
            .iter()
            .find(|entry| entry.name == profile && !entry.path.is_empty())
            .map(|entry| entry.path.to_string());
        let gateway = self.gateway.clone();
        let upload_gateway = gateway.clone();
        let transport = self.settings.attachment_transport;
        let upload_name = name.clone();
        let mut params = json!({"session_id": runtime_id, "name": name});
        if !profile.is_empty() {
            params["profile"] = json!(profile);
        }
        let read = self.runtime.spawn(async move {
            crate::file_upload::prepare(
                path,
                &upload_name,
                upload_gateway,
                profile,
                home,
                progress,
                transport,
                transfer_cancel,
            )
            .await
        });
        cx.spawn(async move |view, cx| {
            let result = read
                .await
                .context(tr("无法读取附件"))
                .and_then(|result| result);
            if cancel.is_cancelled() {
                if let (Ok(crate::file_upload::Ready::Staged(staged)), Some(gateway)) =
                    (result, gateway)
                {
                    let _ = view.update(cx, |this, _| {
                        this.runtime.spawn(staged.remove(gateway));
                    });
                }
                return;
            }
            let _ = view.update(cx, |this, cx| {
                if !this
                    .out
                    .as_ref()
                    .is_some_and(|out| out.same_channel(&connection))
                {
                    return;
                }
                if !this.sessions.get(&key).is_some_and(|session| {
                    session.runtime == runtime_id
                        && match &job {
                            AttachmentJob::Send(_) => session.submitting,
                            AttachmentJob::Draft(path) => {
                                session.uploading_draft_file.as_ref() == Some(path)
                            }
                        }
                }) {
                    this.lose_attachment(&key, &job, tr("会话已更新，请重新发送附件").into());
                } else {
                    let (attachment, staged) = match result {
                        Ok(crate::file_upload::Ready::Socket(file)) => (Some(file), None),
                        Ok(crate::file_upload::Ready::Staged(upload)) => {
                            params["path"] = json!(upload.path);
                            (None, Some(upload))
                        }
                        Err(error) => {
                            this.lose_attachment(&key, &job, format!("{name} · {error}"));
                            this.start_eager_attachment(&key, cx);
                            cx.notify();
                            return;
                        }
                    };
                    let draft_path = match &job {
                        AttachmentJob::Draft(path) => Some(path.clone()),
                        AttachmentJob::Send(_) => None,
                    };
                    if !this.send_call(
                        "file.attach",
                        params,
                        attachment,
                        Call::AttachFile(key.clone(), job, staged, cancel),
                    ) {
                        let message = tr("未能上传附件").to_owned();
                        if let Some(path) = draft_path {
                            this.lose_attachment(&key, &AttachmentJob::Draft(path), message);
                        } else {
                            this.attachment_failed(&key, message);
                        }
                    }
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
        progress: crate::upload_progress::Reporter,
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
        let cancel = self.sessions[&key].upload.as_ref().unwrap().cancel.clone();
        let job = self.runtime.spawn({
            let name = name.clone();
            let cancel = cancel.clone();
            async move {
                tokio::select! {
                    biased;
                    _ = cancel.cancelled() => anyhow::bail!(tr("取消上传")),
                    result = async {
                let image =
                    tokio::task::spawn_blocking(move || prepare_local_image(&path)).await??;
                let upload =
                    upload_chat_image(&gateway, &profile, &name, &image.data_url, Some(progress))
                        .await?;
                let reference = attachment_ref("@image:", &upload.path)
                    .context(tr("网关未返回可用的图片引用"))?;
                Ok::<_, anyhow::Error>((upload, reference, legacy.then_some(image.data_url)))
                    } => result,
                }
            }
        });
        cx.spawn(async move |view, cx| {
            let result = job
                .await
                .context(tr("读取图片失败"))
                .and_then(|result| result);
            if cancel.is_cancelled() {
                return;
            }
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
        job: AttachmentJob,
        response: &Value,
        error: Option<&Value>,
        cx: &mut Context<Self>,
    ) {
        let reference = string(response, "ref_text");
        if error.is_some() || response["attached"] != true || !reference.starts_with("@file:") {
            let path = match &job {
                AttachmentJob::Draft(path) => path,
                AttachmentJob::Send(prepared) => &prepared.files[prepared.file_refs.len()],
            };
            let reason = error
                .map(rpc_error)
                .unwrap_or_else(|| tr("网关未返回附件引用").into());
            self.lose_attachment(&key, &job, format!("{} · {reason}", file_name(path)));
            self.start_eager_attachment(&key, cx);
            return;
        }
        match job {
            AttachmentJob::Send(mut prepared) => {
                prepared.file_refs.push(reference.to_owned());
                self.start_submission(key, prepared, cx);
            }
            AttachmentJob::Draft(path) => {
                let still_needed = self.workspace().is_some_and(|w| {
                    w.draft_files
                        .get(&key)
                        .is_some_and(|files| files.contains(&path))
                        || w.pending_submissions
                            .get(&key)
                            .is_some_and(|pending| pending.files.contains(&path))
                        || w.followups.get(&key).is_some_and(|queue| {
                            queue.iter().any(|item| item.files.contains(&path))
                        })
                });
                let Some(session) = self.sessions.get_mut(&key) else {
                    return;
                };
                if session.uploading_draft_file.take().as_ref() != Some(&path) {
                    return;
                }
                session.upload = None;
                if still_needed {
                    session
                        .staged_draft_files
                        .insert(path, reference.to_owned());
                }
                if std::mem::take(&mut session.waiting_for_draft_upload) {
                    if let Some(prepared) = self
                        .workspace()
                        .and_then(|w| w.pending_submissions.get(&key))
                        .cloned()
                    {
                        self.start_submission(key, prepared, cx);
                    }
                } else {
                    self.drain_followups(&key, cx);
                    self.start_eager_attachment(&key, cx);
                }
            }
        }
    }

    pub(super) fn lose_attachment(&mut self, key: &str, job: &AttachmentJob, message: String) {
        let AttachmentJob::Draft(path) = job else {
            self.attachment_failed(key, message);
            return;
        };
        let Some(session) = self.sessions.get_mut(key) else {
            return;
        };
        if session.uploading_draft_file.as_ref() == Some(path) {
            session.uploading_draft_file = None;
            session.upload = None;
        }
        session
            .draft_upload_errors
            .insert(path.clone(), message.clone());
        if std::mem::take(&mut session.waiting_for_draft_upload) {
            self.attachment_failed(key, message);
        }
    }

    pub(super) fn attachment_failed(&mut self, key: &str, message: String) {
        if let Some(session) = self.sessions.get_mut(key) {
            session.upload = None;
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
