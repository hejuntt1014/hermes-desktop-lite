use std::{collections::HashMap, sync::Arc};

use anyhow::{Context as _, Result, bail};
use gpui::{AppContext, Context, Entity, Focusable, SharedString, Subscription, Window};
use gpui_component::input::{InputEvent, InputState, TextareaState};
use reqwest::Method;
use serde::Deserialize;
use serde_json::json;

use crate::{encode_path, gateway::Gateway};

use super::Desktop;

#[derive(Clone, Deserialize, PartialEq, Eq)]
struct SoulDocument {
    content: String,
    exists: bool,
}

pub(super) struct SoulBuffer {
    pub field: Entity<TextareaState>,
    original: SoulDocument,
    _changes: Subscription,
}

impl SoulBuffer {
    pub fn changed(&self, cx: &Context<Desktop>) -> bool {
        self.field.read(cx).value().as_ref() != self.original.content
    }

    pub fn exists(&self) -> bool {
        self.original.exists
    }
}

#[derive(Default)]
pub(super) struct SoulPage {
    pub buffer: Option<SoulBuffer>,
    pub loading: bool,
    pub saving: bool,
    pub saved: bool,
    pub conflict: bool,
    pub error: Option<SharedString>,
}

pub(super) struct NewProfile {
    pub name: Entity<InputState>,
    pub source: Option<String>,
    pub busy: bool,
    pub error: Option<SharedString>,
    _changes: Subscription,
}

#[derive(Default)]
pub(super) struct ProfileEditor {
    pub open: bool,
    pub memory_file: Option<&'static str>,
    pub memory_text: Option<Result<String, String>>,
    pub memory_query: Option<Entity<InputState>>,
    memory_job: Option<gpui::Task<()>>,
    pub roster_failed: bool,
    pub selected: String,
    pub pages: HashMap<String, SoulPage>,
    pub search: Option<Entity<InputState>>,
    pub create: Option<NewProfile>,
    search_changes: Option<Subscription>,
    identity: Arc<()>,
}

impl Desktop {
    pub(super) fn open_profile_editor(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.out.is_none() || self.profile_editor.open {
            return;
        }
        self.close_cron(window, cx);
        self.close_files(window, cx);
        self.close_review(window, cx);
        self.close_palette(window, cx);
        let search = cx.new(|cx| InputState::new(window, cx).placeholder("搜索配置档案"));
        self.profile_editor.search_changes =
            Some(cx.subscribe(&search, |_, _, event: &InputEvent, cx| {
                if matches!(event, InputEvent::Change) {
                    cx.notify();
                }
            }));
        self.profile_editor.search = Some(search);
        self.profile_editor.open = true;
        self.profile_editor.selected = self.active_profile().to_owned();
        self.workspace_focus.focus(window, cx);
        self.sync_profile_editor(window, cx);
        if self
            .profile_editor
            .pages
            .get(&self.profile_editor.selected)
            .and_then(|page| page.buffer.as_ref())
            .is_some_and(|buffer| !buffer.changed(cx))
        {
            self.load_profile_soul(true, window, cx);
        }
        self.load_profiles(window, cx);
        cx.notify();
    }

    pub(super) fn escape_profile_editor(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(create) = &self.profile_editor.create {
            if !create.busy {
                self.profile_editor.create = None;
                self.workspace_focus.focus(window, cx);
                cx.notify();
            }
        } else {
            self.close_profile_editor(window, cx);
        }
    }

    pub(super) fn close_profile_editor(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self
            .profile_editor
            .create
            .as_ref()
            .is_some_and(|create| create.busy)
        {
            return;
        }
        self.profile_editor.memory_file = None;
        self.profile_editor.memory_job = None;
        self.profile_editor.memory_text = None;
        self.profile_editor.memory_query = None;
        self.profile_editor.open = false;
        self.profile_editor.create = None;
        self.profile_editor.search = None;
        self.profile_editor.search_changes = None;
        self.workspace_focus.focus(window, cx);
        cx.notify();
    }

    pub(super) fn sync_profile_editor(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.profile_editor.open || self.profiles.entries.is_empty() {
            return;
        }
        if !self
            .profiles
            .entries
            .iter()
            .any(|profile| profile.name == self.profile_editor.selected)
        {
            self.select_profile_editor(self.profiles.entries[0].name.clone(), window, cx);
            return;
        }
        self.load_profile_soul(false, window, cx);
    }

    pub(super) fn select_profile_editor(
        &mut self,
        name: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self
            .profile_editor
            .create
            .as_ref()
            .is_some_and(|create| create.busy)
        {
            return;
        }
        self.profile_editor.create = None;
        self.profile_editor.selected = name;
        if let Some(file) = self.profile_editor.memory_file {
            self.select_profile_document(Some(file), window, cx);
        }
        self.load_profile_soul(false, window, cx);
        cx.notify();
    }

    pub(super) fn select_profile_document(
        &mut self,
        file: Option<&'static str>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.profile_editor.memory_job = None;
        self.profile_editor.memory_file = file;
        self.profile_editor.memory_text = None;
        self.profile_editor.memory_query = None;
        cx.notify();
        let Some(file) = file else { return };
        let name = self.profile_editor.selected.clone();
        let query = cx.new(|cx| InputState::new(window, cx).placeholder("查找记忆内容"));
        cx.subscribe(&query, |_, _, event: &InputEvent, cx| {
            if matches!(event, InputEvent::Change) {
                cx.notify()
            }
        })
        .detach();
        self.profile_editor.memory_query = Some(query);
        let Some(profile) = self
            .profiles
            .entries
            .iter()
            .find(|p| p.name == name && !p.path.is_empty())
        else {
            self.profile_editor.memory_text = Some(Err("网关未提供该档案的目录".into()));
            return;
        };
        let Some(gateway) = self.gateway.clone() else {
            self.profile_editor.memory_text = Some(Err("网关未连接".into()));
            return;
        };
        let path = format!(
            "{}/memories/{file}",
            profile.path.trim_end_matches(['/', char::from(92)])
        );
        let request = self.runtime.spawn(async move {
            let wire = gateway
                .api(
                    Method::GET,
                    "api/fs/read-text",
                    &[("profile", name), ("path", path)],
                    None,
                )
                .await?;
            if wire["truncated"] == true {
                bail!("记忆文件超过网关的预览上限")
            }
            Ok::<_, anyhow::Error>(
                wire["text"]
                    .as_str()
                    .context("网关未返回记忆原文")?
                    .to_owned(),
            )
        });
        self.profile_editor.memory_job = Some(cx.spawn(async move |view, cx| {
            let result = request
                .await
                .context("读取任务中断")
                .and_then(|r| r)
                .map_err(|e| e.to_string());
            let _ = view.update(cx, |this, cx| {
                this.profile_editor.memory_text = Some(result);
                cx.notify();
            });
        }));
    }

    pub(super) fn load_profile_soul(
        &mut self,
        reload: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let name = self.profile_editor.selected.clone();
        let Some(gateway) = self
            .gateway
            .clone()
            .filter(|_| self.out.is_some() && !name.is_empty())
        else {
            return;
        };
        let page = self.profile_editor.pages.entry(name.clone()).or_default();
        if page.loading || page.saving || page.buffer.is_some() && !reload {
            return;
        }
        page.loading = true;
        page.error = None;
        page.saved = false;
        let identity = self.profile_editor.identity.clone();
        let request_name = name.clone();
        let request = self
            .runtime
            .spawn(async move { get_soul(&gateway, &request_name).await });
        cx.spawn_in(window, async move |view, cx| {
            let result = request
                .await
                .context("读取 SOUL.md 失败")
                .and_then(|result| result);
            let _ = view.update_in(cx, |this, window, cx| {
                if !Arc::ptr_eq(&this.profile_editor.identity, &identity) {
                    return;
                }
                match result {
                    Ok(document) => this.install_soul(name, document, window, cx),
                    Err(error) => {
                        let page = this.profile_editor.pages.entry(name).or_default();
                        page.loading = false;
                        page.error = Some(error.to_string().into());
                    }
                }
                cx.notify();
            });
        })
        .detach();
        cx.notify();
    }

    fn install_soul(
        &mut self,
        name: String,
        document: SoulDocument,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let field = cx.new(|cx| {
            TextareaState::new(window, cx)
                .rows(10)
                .placeholder("写下这个配置档案的人格与行为指令")
                .default_value(document.content.clone())
        });
        let owner = name.clone();
        let changes = cx.subscribe(&field, move |this, _, event: &InputEvent, cx| {
            if matches!(event, InputEvent::Change) {
                if let Some(page) = this.profile_editor.pages.get_mut(&owner) {
                    page.saved = false;
                }
                cx.notify();
            }
        });
        self.profile_editor.pages.insert(
            name,
            SoulPage {
                buffer: Some(SoulBuffer {
                    field,
                    original: document,
                    _changes: changes,
                }),
                ..SoulPage::default()
            },
        );
    }

    pub(super) fn save_profile_soul(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.profile_editor.open
            || self.profile_editor.memory_file.is_some()
            || self.profile_editor.create.is_some()
        {
            return;
        }
        let name = self.profile_editor.selected.clone();
        let Some(gateway) = self.gateway.clone().filter(|_| self.out.is_some()) else {
            return;
        };
        let Some(page) = self
            .profile_editor
            .pages
            .get_mut(&name)
            .filter(|page| !page.loading && !page.saving && !page.conflict)
        else {
            return;
        };
        let Some(buffer) = page.buffer.as_ref().filter(|buffer| buffer.changed(cx)) else {
            return;
        };
        let new_content = buffer.field.read(cx).value().to_string();
        let original = buffer.original.clone();
        page.saving = true;
        page.saved = false;
        page.error = None;
        let identity = self.profile_editor.identity.clone();
        let request_name = name.clone();
        let request = self.runtime.spawn(async move {
            let remote = get_soul(&gateway, &request_name).await?;
            if remote.exists && remote.content == new_content {
                return Ok::<_, anyhow::Error>(Some(new_content));
            }
            if remote != original {
                return Ok::<_, anyhow::Error>(None);
            }
            let (path, query) = soul_endpoint(&request_name);
            let result = gateway
                .api(
                    Method::PUT,
                    &path,
                    &query,
                    Some(json!({"content": new_content})),
                )
                .await?;
            if result["ok"] != true {
                bail!("网关未确认保存 SOUL.md");
            }
            Ok(Some(new_content))
        });
        cx.spawn_in(window, async move |view, cx| {
            let result = request
                .await
                .context("保存 SOUL.md 失败")
                .and_then(|result| result);
            let _ = view.update_in(cx, |this, _, cx| {
                if !Arc::ptr_eq(&this.profile_editor.identity, &identity) {
                    return;
                }
                let Some(page) = this.profile_editor.pages.get_mut(&name) else {
                    return;
                };
                page.saving = false;
                match result {
                    Ok(Some(content)) => {
                        if let Some(buffer) = page.buffer.as_mut() {
                            buffer.original = SoulDocument {
                                content,
                                exists: true,
                            };
                        }
                        page.saved = true;
                    }
                    Ok(None) => {
                        page.conflict = true;
                        page.error = Some("远端 SOUL.md 已更新，当前编辑内容尚未保存。".into());
                    }
                    Err(error) => page.error = Some(error.to_string().into()),
                }
                cx.notify();
            });
        })
        .detach();
        cx.notify();
    }

    pub(super) fn start_profile_create(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.profile_editor.create.is_some() || self.out.is_none() {
            return;
        }
        let name = cx.new(|cx| InputState::new(window, cx).placeholder("例如 research"));
        name.focus_handle(cx).focus(window, cx);
        self.profile_editor.create = Some(NewProfile {
            _changes: cx.subscribe(&name, |this, _, event: &InputEvent, cx| {
                if matches!(event, InputEvent::Change) {
                    if let Some(create) = &mut this.profile_editor.create {
                        create.error = None;
                    }
                    cx.notify();
                }
            }),
            name,
            source: None,
            busy: false,
            error: None,
        });
        cx.notify();
    }

    pub(super) fn create_profile(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(gateway) = self.gateway.clone().filter(|_| self.out.is_some()) else {
            return;
        };
        let Some(form) = self
            .profile_editor
            .create
            .as_mut()
            .filter(|form| !form.busy)
        else {
            return;
        };
        let name = form.name.read(cx).value().trim().to_owned();
        if !valid_profile_name(&name)
            || self
                .profiles
                .entries
                .iter()
                .any(|profile| profile.name == name)
        {
            form.error = Some(
                if valid_profile_name(&name) {
                    "这个档案名称已存在。"
                } else {
                    "请用小写字母或数字开头，最多 64 个字符，可包含短横线和下划线。"
                }
                .into(),
            );
            cx.notify();
            return;
        }
        let body = json!({"name":name,"clone_from":form.source,"clone_channels":false,"mirror_credentials":false,"share_auth":false});
        form.busy = true;
        form.error = None;
        let identity = self.profile_editor.identity.clone();
        let request = self.runtime.spawn(async move {
            gateway
                .api(Method::POST, "api/profiles", &[], Some(body))
                .await
        });
        cx.spawn_in(window, async move |view, cx| {
            let result = request
                .await
                .context("创建配置档案失败")
                .and_then(|result| result)
                .and_then(|result| {
                    if result["ok"] == true {
                        Ok(())
                    } else {
                        bail!("网关未确认创建配置档案");
                    }
                });
            let _ = view.update_in(cx, |this, window, cx| {
                if !Arc::ptr_eq(&this.profile_editor.identity, &identity) {
                    return;
                }
                match result {
                    Ok(()) => {
                        this.profile_editor.create = None;
                        this.profile_editor.pages.remove(&name);
                        this.select_profile_editor(name, window, cx);
                        this.load_profiles(window, cx);
                    }
                    Err(error) => {
                        if let Some(form) = &mut this.profile_editor.create {
                            form.busy = false;
                            form.error = Some(error.to_string().into());
                        }
                    }
                }
                cx.notify();
            });
        })
        .detach();
        cx.notify();
    }
}

fn valid_profile_name(name: &str) -> bool {
    let letters_or_digits = |ch: u8| ch.is_ascii_lowercase() || ch.is_ascii_digit();
    name.len() <= 64
        && name.bytes().next().is_some_and(letters_or_digits)
        && name
            .bytes()
            .all(|ch| letters_or_digits(ch) || matches!(ch, b'-' | b'_'))
}

fn soul_endpoint(name: &str) -> (String, [(&'static str, String); 1]) {
    (
        format!("api/profiles/{}/soul", encode_path(name)),
        [("profile", name.to_owned())],
    )
}

async fn get_soul(gateway: &Gateway, name: &str) -> Result<SoulDocument> {
    let (path, query) = soul_endpoint(name);
    let wire = gateway.api(Method::GET, &path, &query, None).await?;
    serde_json::from_value(wire).context("网关返回了无法读取的 SOUL.md")
}
