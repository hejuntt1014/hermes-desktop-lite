use crate::i18n::text as tr;

use std::{
    collections::{HashMap, HashSet, VecDeque},
    time::Instant,
};

use anyhow::{Context as _, Result};
use gpui::{Context, Entity, SharedString, Window};
use gpui_component::input::InputState;
use serde_json::{Value, json};

use super::{Call, Desktop, rpc_error};
use crate::{
    gateway::Gateway,
    session::{Session, string},
    settings::{LaunchOptions, ModelChoice, ModelPreference},
};

#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum Picker {
    Model,
    Effort,
}

#[derive(Clone)]
pub(super) struct CatalogModel {
    pub choice: ModelChoice,
    pub provider_name: SharedString,
    pub provider_aliases: std::sync::Arc<[String]>,
    pub available: bool,
    pub reasoning: Option<bool>,
    pub can_disable_reasoning: bool,
    pub fast: bool,
    pub ultrafast: bool,
}

impl CatalogModel {
    pub fn matches(&self, choice: &ModelChoice) -> bool {
        self.choice.id == choice.id
            && (choice.provider.is_empty()
                || self.choice.provider == choice.provider
                || self.provider_name.as_ref() == choice.provider
                || self.provider_aliases.contains(&choice.provider))
    }
}

#[derive(Clone, PartialEq, Eq, Hash)]
pub(super) struct MenuScope {
    profile: String,
    session: Option<String>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) struct MenuRequest {
    id: u64,
    refresh: bool,
}

#[derive(Default)]
struct MenuCatalogs {
    entries: HashMap<MenuScope, CatalogState>,
    pending: HashMap<MenuScope, MenuRequest>,
    next_id: u64,
}

impl MenuCatalogs {
    fn start(&mut self, scope: &MenuScope, refresh: bool) -> Option<MenuRequest> {
        if self
            .pending
            .get(scope)
            .is_some_and(|request| request.refresh || !refresh)
        {
            return None;
        }
        self.next_id = self.next_id.wrapping_add(1);
        let request = MenuRequest {
            id: self.next_id,
            refresh,
        };
        self.pending.insert(scope.clone(), request);
        Some(request)
    }

    fn is_pending(&self, scope: &MenuScope, request: MenuRequest) -> bool {
        self.pending.get(scope) == Some(&request)
    }

    fn cancel(&mut self, scope: &MenuScope, request: MenuRequest) -> bool {
        if !self.is_pending(scope, request) {
            return false;
        }
        self.pending.remove(scope);
        true
    }

    fn finish(&mut self, scope: &MenuScope, request: MenuRequest, result: Result<Catalog>) -> bool {
        if !self.cancel(scope, request) {
            return false;
        }
        match result {
            Ok(catalog) => {
                self.entries
                    .insert(scope.clone(), CatalogState::Loaded(catalog));
            }
            Err(error) if !matches!(self.entries.get(scope), Some(CatalogState::Loaded(_))) => {
                self.entries
                    .insert(scope.clone(), CatalogState::Failed(error.to_string()));
            }
            Err(_) => {}
        }
        true
    }
}

struct TierOptions {
    fast: bool,
    ultrafast: bool,
    received: Instant,
}

struct PendingPreset {
    model: ModelChoice,
    queue: VecDeque<Choice>,
}

pub(super) struct Catalog {
    pub current: Option<ModelChoice>,
    pub models: Vec<CatalogModel>,
    pub codex_usage: Option<super::session_status::CodexUsage>,
    fetched_at: Instant,
}

pub(super) enum CatalogState {
    Loading,
    Loaded(Catalog),
    Failed(String),
}

#[derive(Clone, PartialEq, Eq)]
pub(super) enum Choice {
    Model(ModelChoice),
    Effort(String),
    Speed(String),
}

#[derive(Clone, PartialEq, Eq)]
enum Confirmation {
    Legacy,
    Authority {
        token: String,
        version: Option<(u64, u64)>,
    },
}

struct PickPlan {
    id: String,
    choice: Choice,
    confirmed: bool,
    profile: String,
    runtime: String,
    command: PickCommand,
    sent_version: Option<(u64, u64)>,
    retried: bool,
    bundled_effort: bool,
    show_receipt: bool,
}

enum PickCommand {
    Mutation {
        operation: &'static str,
        payload: Value,
    },
    Config {
        key: &'static str,
        value: String,
    },
}

impl PickCommand {
    fn new(
        choice: &Choice,
        canonical: bool,
        confirmation: Option<&Confirmation>,
        effort: Option<&str>,
    ) -> Result<Self> {
        if let Choice::Speed(value) = choice {
            return Ok(Self::Config {
                key: "fast",
                value: value.clone(),
            });
        }
        if canonical {
            let (operation, mut payload) = match choice {
                Choice::Model(model) => {
                    ("model", json!({"model":model.id,"provider":model.provider}))
                }
                Choice::Effort(value) => ("reasoning", json!({"effort":value})),
                Choice::Speed(_) => unreachable!(),
            };
            if let Some(effort) = effort {
                payload["reasoning"] = json!(effort);
            }
            if let Some(Confirmation::Authority { token, .. }) = confirmation {
                payload["confirm"] = json!(token);
            }
            return Ok(Self::Mutation { operation, payload });
        }
        let (key, value) =
            match choice {
                Choice::Model(model) => {
                    if model.id.split_whitespace().any(|word| {
                        word.starts_with("--") || word.starts_with(['‒', '–', '—', '―'])
                    }) || model.provider.chars().any(char::is_whitespace)
                    {
                        anyhow::bail!(tr("网关不支持切换到此模型标识"));
                    }
                    (
                        "model",
                        format!("{} --provider {} --session", model.id, model.provider),
                    )
                }
                Choice::Effort(value) => ("reasoning", value.clone()),
                Choice::Speed(_) => unreachable!(),
            };
        Ok(Self::Config { key, value })
    }
}

impl PickPlan {
    fn belongs_to(&self, session: &Session) -> bool {
        session.attached && session.runtime == self.runtime && session.profile == self.profile
    }

    fn request(
        &mut self,
        session: &str,
        version: Option<(u64, u64)>,
    ) -> Option<(&'static str, Value)> {
        let (method, mut params) = match &self.command {
            PickCommand::Mutation { operation, payload } => {
                let (revision, generation) = version?;
                self.sent_version = Some((revision, generation));
                (
                    "session.mutate",
                    json!({"session_id":session,"request_id":self.id,
                    "expected_revision":revision,"expected_generation":generation,
                    "operation":operation,"payload":payload}),
                )
            }
            PickCommand::Config { key, value } => {
                let mut params = json!({"session_id":self.runtime,"key":key,"value":value});
                if *key != "fast" {
                    params["scope"] = json!("session");
                    params["confirm_expensive_model"] = json!(self.confirmed);
                }
                ("config.set", params)
            }
        };
        if !self.profile.is_empty() {
            params["profile"] = json!(self.profile);
        }
        Some((method, params))
    }

    fn retry_version(&mut self, error: &Value) -> bool {
        let reason = error["data"]["reason"]
            .as_str()
            .or_else(|| error["message"].as_str());
        if self.retried
            || !matches!(self.command, PickCommand::Mutation { .. })
            || !matches!(reason, Some("revision_conflict" | "stale_generation"))
        {
            return false;
        }
        self.retried = true;
        true
    }
}

fn wire_version(value: &Value) -> Option<(u64, u64)> {
    Some((
        value["revision"].as_u64()?,
        value["execution_generation"].as_u64()?,
    ))
}

pub(super) struct Prompt {
    pub message: SharedString,
    choice: Choice,
    confirmation: Confirmation,
}

pub(super) struct ModelControls {
    pub search: Entity<InputState>,
    pub picker: Option<Picker>,
    pub inspected_model: Option<ModelChoice>,
    pub catalogs: HashMap<String, CatalogState>,
    menus: MenuCatalogs,
    tiers: HashMap<(String, ModelChoice), TierOptions>,
    pending_presets: HashMap<String, PendingPreset>,
    catalog_requests: HashSet<String>,
    pub defaults: LaunchOptions,
    pub prompts: HashMap<String, Prompt>,
    pub busy: HashSet<String>,
    plans: HashMap<String, PickPlan>,
    catalog_generation: u64,
}

impl ModelControls {
    pub fn new(search: Entity<InputState>) -> Self {
        Self {
            search,
            picker: None,
            inspected_model: None,
            catalogs: HashMap::new(),
            menus: MenuCatalogs::default(),
            tiers: HashMap::new(),
            pending_presets: HashMap::new(),
            catalog_requests: HashSet::new(),
            defaults: LaunchOptions::default(),
            prompts: HashMap::new(),
            busy: HashSet::new(),
            plans: HashMap::new(),
            catalog_generation: 0,
        }
    }

    pub fn reset(&mut self) {
        let generation = self.catalog_generation.wrapping_add(1);
        let menu_request_id = self.menus.next_id;
        *self = Self::new(self.search.clone());
        self.catalog_generation = generation;
        self.menus.next_id = menu_request_id;
    }
}

impl Catalog {
    async fn fetch(gateway: &Gateway, profile: &str, refresh: bool) -> Result<Self> {
        Self::from_response(gateway.model_options(profile, refresh).await?)
    }

    fn from_response(value: Value) -> Result<Self> {
        let providers = value["providers"]
            .as_array()
            .context(tr("网关未返回模型列表"))?;
        let mut models = Vec::new();
        let mut codex_usage = None;
        for provider in providers {
            let slug = string(provider, "slug");
            if slug.is_empty() {
                continue;
            }
            let name = provider["name"]
                .as_str()
                .filter(|name| !name.is_empty())
                .unwrap_or(slug);
            let available = provider["authenticated"] != false;
            let aliases: std::sync::Arc<[String]> = provider["aliases"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .map(str::to_owned)
                .collect::<Vec<_>>()
                .into();
            if available && super::session_status::is_codex(slug) {
                codex_usage = super::session_status::CodexUsage::from_inventory(&provider["usage"]);
            }
            for model in provider["models"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
            {
                let blocked = provider["unavailable_models"]
                    .as_array()
                    .is_some_and(|entries| entries.iter().any(|id| id == model));
                let caps = &provider["capabilities"][model];
                models.push(CatalogModel {
                    choice: ModelChoice {
                        id: model.to_owned(),
                        provider: slug.to_owned(),
                    },
                    provider_name: name.to_owned().into(),
                    provider_aliases: aliases.clone(),
                    available: available && !blocked,
                    reasoning: caps["reasoning"].as_bool(),
                    can_disable_reasoning: caps["can_disable_reasoning"] != false,
                    fast: caps["fast"] == true,
                    ultrafast: caps["ultrafast"] == true,
                });
            }
        }
        let model = string(&value, "model");
        let current = (!model.is_empty()).then(|| ModelChoice {
            id: model.to_owned(),
            provider: string(&value, "provider").to_owned(),
        });
        Ok(Self {
            current,
            models,
            codex_usage,
            fetched_at: Instant::now(),
        })
    }
}

pub(super) fn defaults_from_config(config: &Value) -> LaunchOptions {
    let current = &config["model"];
    let id = current
        .as_str()
        .or_else(|| current["default"].as_str())
        .unwrap_or_default();
    let model = (!id.is_empty()).then(|| ModelChoice {
        id: id.to_owned(),
        provider: string(current, "provider").to_owned(),
    });
    let effort = &config["agent"]["reasoning_effort"];
    let effort = if *effort == false {
        Some("none".into())
    } else {
        effort.as_str().map(str::to_owned)
    };
    let speed = config["agent"]["service_tier"]
        .as_str()
        .map(speed_word)
        .map(str::to_owned);
    LaunchOptions {
        model,
        effort,
        speed,
    }
}

pub(super) fn speed_word(value: &str) -> &str {
    match value {
        "fast" | "priority" | "on" => "fast",
        "ultrafast" | "ultra" => "ultrafast",
        "auto" => "auto",
        "cold" => "cold",
        _ => "normal",
    }
}

impl Desktop {
    pub(super) fn model_profile(&self) -> String {
        self.selected
            .as_ref()
            .and_then(|key| self.sessions.get(key))
            .map(|session| session.profile.clone())
            .filter(|profile| !profile.is_empty())
            .unwrap_or_else(|| self.active_profile().to_owned())
    }

    pub(super) fn picker_opened(
        &mut self,
        picker: Picker,
        open: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if open {
            self.model_controls.picker = Some(picker);
            self.model_controls.inspected_model = None;
            if picker == Picker::Model {
                self.model_controls
                    .search
                    .update(cx, |field, cx| field.set_value("", window, cx));
            }
            self.load_models(false, cx);
        } else if self.model_controls.picker == Some(picker) {
            self.model_controls.picker = None;
            self.model_controls.inspected_model = None;
        }
        cx.notify();
    }

    pub(super) fn load_models(&mut self, refresh: bool, cx: &mut Context<Self>) {
        let scope = self.menu_scope();
        if !refresh
            && self
                .model_controls
                .menus
                .entries
                .get(&scope)
                .is_some_and(|state| {
                    matches!(state, CatalogState::Loaded(catalog)
                    if catalog.fetched_at.elapsed().as_secs() < 45)
                })
        {
            self.load_model_tiers();
            return;
        }
        if let Some(request) = self.model_controls.menus.start(&scope, refresh) {
            let mut params = json!({"explicit_only":true, "refresh":refresh});
            if !scope.profile.is_empty() {
                params["profile"] = json!(scope.profile);
            }
            if let Some(runtime) = scope
                .session
                .as_ref()
                .and_then(|key| self.sessions.get(key))
                .filter(|session| session.attached && !session.runtime.is_empty())
                .map(|session| &session.runtime)
            {
                params["session_id"] = json!(runtime);
            }
            if !self.call(
                "model.options",
                params,
                Call::ModelOptions(scope.clone(), request),
            ) {
                self.fallback_model_options(scope, request, cx);
            }
        }
        self.load_model_tiers();
        cx.notify();
    }

    fn menu_scope(&self) -> MenuScope {
        MenuScope {
            profile: self.model_profile(),
            session: self.selected.clone(),
        }
    }

    pub(super) fn menu_catalog(&self) -> Option<&Catalog> {
        let scope = self.menu_scope();
        match self.model_controls.menus.entries.get(&scope) {
            Some(CatalogState::Loaded(catalog)) => Some(catalog),
            _ => match self.model_controls.catalogs.get(&scope.profile) {
                Some(CatalogState::Loaded(catalog)) => Some(catalog),
                _ => None,
            },
        }
    }

    pub(super) fn model_menu_error(&self) -> Option<&str> {
        let scope = self.menu_scope();
        let menus = &self.model_controls.menus;
        if menus.pending.contains_key(&scope) {
            return None;
        }
        match menus.entries.get(&scope) {
            Some(CatalogState::Failed(error)) => Some(error),
            _ => None,
        }
    }

    pub(super) fn model_refreshing(&self) -> bool {
        self.model_controls
            .menus
            .pending
            .get(&self.menu_scope())
            .is_some_and(|request| request.refresh)
    }

    pub(super) fn cancel_model_options(&mut self, scope: &MenuScope, request: MenuRequest) {
        self.model_controls.menus.cancel(scope, request);
    }

    pub(super) fn finish_model_options(
        &mut self,
        scope: MenuScope,
        request: MenuRequest,
        result: &Value,
        error: Option<&Value>,
        cx: &mut Context<Self>,
    ) {
        if !self.model_controls.menus.is_pending(&scope, request) {
            return;
        }
        match Catalog::from_response(result.clone()) {
            Ok(catalog) if error.is_none() && !catalog.models.is_empty() => {
                self.publish_menu_catalog(scope, request, Ok(catalog), cx);
            }
            _ => self.fallback_model_options(scope, request, cx),
        }
    }

    pub(super) fn fallback_model_options(
        &mut self,
        scope: MenuScope,
        request: MenuRequest,
        cx: &mut Context<Self>,
    ) {
        if !self.model_controls.menus.is_pending(&scope, request) {
            return;
        }
        let Some(gateway) = self.gateway.clone().filter(|_| self.out.is_some()) else {
            self.publish_menu_catalog(scope, request, Err(anyhow::anyhow!(tr("未连接"))), cx);
            return;
        };
        let profile = scope.profile.clone();
        let read = self
            .runtime
            .spawn(async move { Catalog::fetch(&gateway, &profile, request.refresh).await });
        cx.spawn(async move |view, cx| {
            let result = read
                .await
                .context(tr("无法读取模型列表"))
                .and_then(|result| result);
            let _ = view.update(cx, |this, cx| {
                this.publish_menu_catalog(scope, request, result, cx);
            });
        })
        .detach();
    }

    fn publish_menu_catalog(
        &mut self,
        scope: MenuScope,
        request: MenuRequest,
        result: Result<Catalog>,
        cx: &mut Context<Self>,
    ) {
        let refresh_error = result
            .as_ref()
            .err()
            .filter(|_| request.refresh && scope == self.menu_scope())
            .map(ToString::to_string);
        if !self.model_controls.menus.finish(&scope, request, result) {
            return;
        }
        if let Some(error) = refresh_error {
            self.banner = Some(
                crate::i18n::format_text!(
                    "无法刷新模型列表 · {error}",
                    "Could not refresh models · {error}"
                )
                .into(),
            );
        }
        cx.notify();
    }

    fn load_model_tiers(&mut self) {
        let Some(key) = self.selected.clone() else {
            return;
        };
        let Some(session) = self.sessions.get(&key).filter(|session| {
            session.attached && session.next_model.is_none() && !session.model.is_empty()
        }) else {
            return;
        };
        let model = ModelChoice {
            id: session.model.to_string(),
            provider: session.provider.to_string(),
        };
        if self.model_controls.tiers.get(&(key.clone(), model.clone()))
            .is_some_and(|tier| tier.received.elapsed().as_secs() < 45)
            || self.pending.values().any(|call| matches!(call, Call::ModelTiers(pending, choice) if pending == &key && choice == &model))
        {
            return;
        }
        let mut params = json!({"key":"service_tier", "session_id":session.runtime});
        if !session.profile.is_empty() {
            params["profile"] = json!(session.profile);
        }
        self.call("config.get", params, Call::ModelTiers(key, model));
    }

    pub(super) fn finish_model_tiers(&mut self, key: String, model: ModelChoice, result: &Value) {
        if let Some(options) = result["options"].as_array() {
            let fast = options.iter().any(|option| {
                option
                    .as_str()
                    .is_some_and(|value| speed_word(value) == "fast")
            });
            let ultrafast = options.iter().any(|option| {
                option
                    .as_str()
                    .is_some_and(|value| speed_word(value) == "ultrafast")
            });
            self.model_controls.tiers.insert(
                (key, model),
                TierOptions {
                    fast,
                    ultrafast,
                    received: Instant::now(),
                },
            );
        }
    }

    pub(super) fn model_speed_options(
        &self,
        choice: &ModelChoice,
        entry: Option<&CatalogModel>,
    ) -> (bool, bool) {
        if let Some(key) = &self.selected
            && let Some(session) = self.sessions.get(key)
            && session.next_model.is_none()
            && session.model.as_ref() == choice.id
            && (session.provider.as_ref() == choice.provider
                || entry.is_some_and(|entry| {
                    entry.matches(&ModelChoice {
                        id: session.model.to_string(),
                        provider: session.provider.to_string(),
                    })
                }))
            && let Some(tiers) = self.model_controls.tiers.get(&(
                key.clone(),
                ModelChoice {
                    id: session.model.to_string(),
                    provider: session.provider.to_string(),
                },
            ))
        {
            return (tiers.fast, tiers.ultrafast);
        }
        entry.map_or((false, false), |entry| (entry.fast, entry.ultrafast))
    }

    pub(super) fn model_preference(&self, choice: &ModelChoice) -> ModelPreference {
        self.workspace()
            .and_then(|workspace| {
                workspace
                    .model_preferences
                    .get(&preference_key(&self.model_profile(), choice))
            })
            .cloned()
            .unwrap_or_default()
    }

    pub(super) fn toggle_model_favorite(&mut self, choice: &ModelChoice, cx: &mut Context<Self>) {
        let key = preference_key(&self.model_profile(), choice);
        let item = self
            .workspace_mut()
            .model_preferences
            .entry(key.clone())
            .or_default();
        item.favorite = !item.favorite;
        if !item.favorite && item.effort.is_none() && item.speed.is_none() {
            self.workspace_mut().model_preferences.remove(&key);
        }
        self.persist(cx);
        cx.notify();
    }

    pub(super) fn inspect_model(&mut self, choice: ModelChoice, cx: &mut Context<Self>) {
        if self.model_controls.picker == Some(Picker::Model)
            && self.model_controls.inspected_model.as_ref() != Some(&choice)
        {
            self.model_controls.inspected_model = Some(choice);
            cx.notify();
        }
    }

    pub(super) fn edit_model_option(
        &mut self,
        target: ModelChoice,
        choice: Choice,
        cx: &mut Context<Self>,
    ) {
        let current = self.shown_model().is_some_and(|model| {
            model.id == target.id
                && (model.provider == target.provider
                    || self
                        .menu_catalog()
                        .and_then(|catalog| {
                            catalog.models.iter().find(|entry| entry.matches(&target))
                        })
                        .is_some_and(|entry| entry.matches(&model)))
        });
        let key = self.key();
        if current && self.selected.is_some() {
            self.model_controls.prompts.remove(&key);
            self.change_model_setting(key, choice, None, cx);
        } else {
            let preference = preference_key(&self.model_profile(), &target);
            let workspace = self.workspace_mut();
            let item = workspace.model_preferences.entry(preference).or_default();
            match choice {
                Choice::Effort(effort) => {
                    item.effort = Some(effort.clone());
                    if current {
                        workspace.draft_launch.entry(key).or_default().effort = Some(effort);
                    }
                }
                Choice::Speed(speed) => {
                    item.speed = Some(speed.clone());
                    if current {
                        workspace.draft_launch.entry(key).or_default().speed = Some(speed);
                    }
                }
                Choice::Model(_) => return,
            }
            self.persist(cx);
        }
        cx.notify();
    }

    pub(super) fn load_codex_usage(&mut self, force: bool, cx: &mut Context<Self>) {
        let profile = self.model_profile();
        let refresh = match self.model_controls.catalogs.get(&profile) {
            Some(CatalogState::Loaded(catalog)) => {
                let age = catalog.fetched_at.elapsed().as_secs();
                age >= 120 || (force || catalog.codex_usage.is_none()) && age >= 5
            }
            _ => true,
        };
        if refresh {
            self.request_usage_catalog(profile, cx);
        }
    }

    fn request_usage_catalog(&mut self, profile: String, cx: &mut Context<Self>) {
        let Some(gateway) = self.gateway.clone().filter(|_| self.out.is_some()) else {
            return;
        };
        if !self.model_controls.catalog_requests.insert(profile.clone()) {
            return;
        }
        let generation = self.model_controls.catalog_generation;
        if !matches!(
            self.model_controls.catalogs.get(&profile),
            Some(CatalogState::Loaded(_))
        ) {
            self.model_controls
                .catalogs
                .insert(profile.clone(), CatalogState::Loading);
        }
        let read = self.runtime.spawn({
            let profile = profile.clone();
            async move { Catalog::fetch(&gateway, &profile, false).await }
        });
        cx.spawn(async move |view, cx| {
            let result = read
                .await
                .context(tr("无法读取模型列表"))
                .and_then(|result| result);
            let _ = view.update(cx, |this, cx| {
                if this.model_controls.catalog_generation != generation {
                    return;
                }
                this.model_controls.catalog_requests.remove(&profile);
                match result {
                    Ok(catalog) => {
                        this.model_controls
                            .catalogs
                            .insert(profile, CatalogState::Loaded(catalog));
                    }
                    Err(error)
                        if !matches!(
                            this.model_controls.catalogs.get(&profile),
                            Some(CatalogState::Loaded(_))
                        ) =>
                    {
                        this.model_controls
                            .catalogs
                            .insert(profile, CatalogState::Failed(error.to_string()));
                    }
                    Err(_) => {}
                }
                cx.notify();
            });
        })
        .detach();
        cx.notify();
    }

    pub(super) fn choose_model_setting(
        &mut self,
        choice: Choice,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.model_controls.picker = None;
        self.model_controls.inspected_model = None;
        let key = self.key();
        if self.selected.is_none() {
            let preference = match &choice {
                Choice::Model(model) => Some(self.model_preference(model)),
                _ => None,
            };
            let options = self.workspace_mut().draft_launch.entry(key).or_default();
            match choice {
                Choice::Model(model) => {
                    if options.model.as_ref() != Some(&model) {
                        options.effort = preference
                            .as_ref()
                            .and_then(|preference| preference.effort.clone());
                        options.speed = preference.and_then(|preference| preference.speed);
                    }
                    options.model = Some(model);
                }
                Choice::Effort(effort) => options.effort = Some(effort),
                Choice::Speed(speed) => options.speed = Some(speed),
            }
            self.persist(cx);
        } else {
            self.model_controls.prompts.remove(&key);
            self.cancel_model_preset(&key);
            self.change_model_setting(key, choice, None, cx);
        }
        self.composer
            .update(cx, |field, cx| field.focus(window, cx));
        cx.notify();
    }

    pub(super) fn choose_slash_effort(
        &mut self,
        effort: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let key = self.key();
        self.choose_model_setting(Choice::Effort(effort.to_owned()), window, cx);
        if let Some(plan) = self.model_controls.plans.get_mut(&key)
            && matches!(&plan.choice, Choice::Effort(value) if value == effort)
        {
            plan.show_receipt = true;
        } else if self.selected.is_none() {
            self.store_slash_output(key, "reasoning".into(), format!("reasoning: {effort}"));
        }
    }

    pub(super) fn follow_model_default(
        &mut self,
        picker: Picker,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.selected.is_some() {
            return;
        }
        let key = self.key();
        if let Some(options) = self.workspace_mut().draft_launch.get_mut(&key) {
            match picker {
                Picker::Model => {
                    options.model = None;
                    options.speed = None;
                }
                Picker::Effort => options.effort = None,
            }
            if options.model.is_none() && options.effort.is_none() && options.speed.is_none() {
                self.workspace_mut().draft_launch.remove(&key);
            }
            self.persist(cx);
        }
        self.model_controls.picker = None;
        self.composer
            .update(cx, |field, cx| field.focus(window, cx));
        cx.notify();
    }

    pub(super) fn resolve_model_prompt(&mut self, confirmed: bool, cx: &mut Context<Self>) {
        let key = self.key();
        if let Some(prompt) = self.model_controls.prompts.remove(&key)
            && confirmed
        {
            self.change_model_setting(key, prompt.choice, Some(prompt.confirmation), cx);
        }
        cx.notify();
    }

    fn change_model_setting(
        &mut self,
        key: String,
        choice: Choice,
        confirmation: Option<Confirmation>,
        cx: &mut Context<Self>,
    ) {
        let Some(gateway) = self.gateway.clone().filter(|_| self.out.is_some()) else {
            return;
        };
        let Some(session) = self
            .sessions
            .get(&key)
            .filter(|session| session.attached && !session.submitting)
        else {
            return;
        };
        if !self.model_controls.busy.insert(key.clone()) {
            return;
        }
        let profile = session.profile.clone();
        let runtime = session.runtime.clone();
        let version = match &confirmation {
            Some(Confirmation::Authority {
                version: Some(version),
                ..
            }) => Some(*version),
            _ => session
                .revision
                .map(|revision| (revision, session.generation)),
        };
        let canonical = self.canonical && !matches!(choice, Choice::Speed(_));
        let effort = match &choice {
            Choice::Model(model) if canonical => self
                .workspace()
                .and_then(|workspace| {
                    workspace
                        .model_preferences
                        .get(&preference_key(&profile, model))
                })
                .and_then(|pref| pref.effort.clone())
                .filter(|value| {
                    matches!(
                        value.as_str(),
                        "none" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max" | "ultra"
                    )
                }),
            _ => None,
        };
        let command =
            match PickCommand::new(&choice, canonical, confirmation.as_ref(), effort.as_deref()) {
                Ok(command) => command,
                Err(error) => {
                    self.model_controls.busy.remove(&key);
                    self.banner = Some(error.to_string().into());
                    return;
                }
            };
        self.model_controls.plans.insert(
            key.clone(),
            PickPlan {
                id: uuid::Uuid::new_v4().to_string(),
                choice,
                confirmed: confirmation.is_some(),
                profile,
                runtime,
                command,
                sent_version: None,
                retried: false,
                bundled_effort: effort.is_some(),
                show_receipt: false,
            },
        );
        self.send_model_setting(&key, version, gateway, cx);
    }

    pub(super) fn model_switch_status(&self) -> Option<&'static str> {
        let plan = self.model_controls.plans.get(&self.key())?;
        if !matches!(plan.choice, Choice::Model(_)) {
            return None;
        }
        Some(if plan.confirmed {
            tr("正在切换模型…")
        } else {
            tr("正在检查模型…")
        })
    }

    pub(super) fn clear_model_setting(&mut self, key: &str) {
        self.model_controls.busy.remove(key);
        self.model_controls.plans.remove(key);
        self.cancel_model_preset(key);
    }

    fn dispatch_model_setting(&mut self, key: &str, method: &'static str, params: Value) {
        if !self.call(method, params, Call::ModelChange(key.to_owned())) {
            self.clear_model_setting(key);
        }
    }

    fn send_model_setting(
        &mut self,
        key: &str,
        version: Option<(u64, u64)>,
        gateway: Gateway,
        cx: &mut Context<Self>,
    ) {
        let Some(plan) = self.model_controls.plans.get_mut(key) else {
            return;
        };
        if let Some((method, params)) = plan.request(key, version) {
            self.dispatch_model_setting(key, method, params);
            return;
        }
        let Some(out) = self.out.clone() else {
            self.clear_model_setting(key);
            return;
        };
        let id = plan.id.clone();
        let profile = plan.profile.clone();
        let key = key.to_owned();
        let read = self.runtime.spawn({
            let key = key.clone();
            async move {
                gateway
                    .session_version(&key, &profile)
                    .await?
                    .context(tr("无法读取会话版本"))
            }
        });
        cx.spawn(async move |view, cx| {
            let result = read
                .await
                .context(tr("无法准备会话模型切换"))
                .and_then(|value| value);
            let _ = view.update(cx, |this, cx| {
                let Some(plan) = this
                    .model_controls
                    .plans
                    .get_mut(&key)
                    .filter(|plan| plan.id == id)
                else {
                    return;
                };
                if !this
                    .out
                    .as_ref()
                    .is_some_and(|current| current.same_channel(&out))
                    || !this
                        .sessions
                        .get(&key)
                        .is_some_and(|session| plan.belongs_to(session))
                {
                    this.clear_model_setting(&key);
                } else {
                    match result {
                        Ok(version) => {
                            let (method, params) = plan
                                .request(&key, Some(version))
                                .expect("version provides mutation fences");
                            this.dispatch_model_setting(&key, method, params);
                        }
                        Err(error) => {
                            this.clear_model_setting(&key);
                            this.banner = Some(error.to_string().into());
                        }
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    fn retry_model_setting(&mut self, key: &str, error: &Value, cx: &mut Context<Self>) -> bool {
        let Some(gateway) = self
            .gateway
            .clone()
            .filter(|_| self.canonical && self.out.is_some())
        else {
            return false;
        };
        let Some(plan) = self.model_controls.plans.get_mut(key) else {
            return false;
        };
        if !self
            .sessions
            .get(key)
            .is_some_and(|session| plan.belongs_to(session))
        {
            return false;
        }
        if !plan.retry_version(error) {
            return false;
        }
        self.send_model_setting(key, wire_version(&error["data"]), gateway, cx);
        true
    }

    pub(super) fn finish_model_setting(
        &mut self,
        key: String,
        result: &Value,
        error: Option<&Value>,
        cx: &mut Context<Self>,
    ) {
        if let Some(error) = error
            && self.retry_model_setting(&key, error, cx)
        {
            return;
        }
        self.model_controls.busy.remove(&key);
        let Some(plan) = self.model_controls.plans.remove(&key) else {
            return;
        };
        if !self
            .sessions
            .get(&key)
            .is_some_and(|session| plan.belongs_to(session))
        {
            self.cancel_model_preset(&key);
            return;
        }
        if let Some(error) = error {
            self.cancel_model_preset(&key);
            self.banner = Some(rpc_error(error).into());
            return;
        }
        if result["confirm_required"] == true || result["status"] == "confirmation_required" {
            let confirmation = result["confirm"]
                .as_str()
                .filter(|token| !token.is_empty())
                .map(|token| Confirmation::Authority {
                    token: token.to_owned(),
                    version: plan.sent_version,
                })
                .unwrap_or(Confirmation::Legacy);
            let message = result["confirm_message"]
                .as_str()
                .filter(|value| !value.trim().is_empty())
                .unwrap_or(tr("网关要求确认这次模型切换。"));
            self.model_controls.prompts.insert(
                key,
                Prompt {
                    message: message.to_owned().into(),
                    choice: plan.choice,
                    confirmation,
                },
            );
            return;
        }
        let Some(session) = self.sessions.get_mut(&key) else {
            return;
        };
        if matches!(plan.command, PickCommand::Mutation { .. })
            && let Some((revision, generation)) = wire_version(result)
            && generation == session.generation
            && session.revision.is_none_or(|current| revision >= current)
        {
            session.revision = Some(revision);
        }
        let deferred = result["deferred"] == true || result["status"] == "deferred";
        let mut model_pick = None;
        let mut preference_update = None;
        let mut receipt = None;
        match plan.choice {
            Choice::Model(model) => {
                model_pick = Some(model.clone());
                let applied = result["model"]
                    .as_str()
                    .or_else(|| result["value"].as_str())
                    .filter(|value| !value.is_empty());
                if deferred {
                    session.next_model = Some(model);
                } else if let Some(applied) = applied {
                    if let Some(provider) = result["provider"]
                        .as_str()
                        .or_else(|| (applied == model.id).then_some(model.provider.as_str()))
                    {
                        if session.provider.as_ref() != provider {
                            session.context = None;
                        }
                        session.provider = provider.to_owned().into();
                    }
                    session.update_model(applied);
                    session.next_model = None;
                    if plan.bundled_effort
                        && let Some(effort) = result["effort"].as_str()
                        && session.effort.as_ref() != effort
                    {
                        session.effort = effort.to_owned().into();
                        session.effort_on_wire = SharedString::default();
                    }
                }
            }
            Choice::Effort(effort) => {
                let value = result["effort"]
                    .as_str()
                    .or_else(|| result["value"].as_str())
                    .unwrap_or(&effort);
                if deferred {
                    session.next_effort = Some(value.to_owned());
                } else {
                    if session.effort.as_ref() != value {
                        session.effort_on_wire = SharedString::default();
                    }
                    session.effort = value.to_owned().into();
                    session.next_effort = None;
                }
                preference_update = Some(Choice::Effort(value.to_owned()));
                if plan.show_receipt {
                    receipt = Some(if deferred {
                        crate::i18n::format_text!(
                            "reasoning: {value} · 下一轮生效",
                            "Reasoning: {value} · applies on the next turn"
                        )
                    } else {
                        format!("reasoning: {value}")
                    });
                }
            }
            Choice::Speed(speed) => {
                let value = result["value"].as_str().unwrap_or(&speed);
                session.speed = speed_word(value).to_owned().into();
                preference_update = Some(Choice::Speed(session.speed.to_string()));
            }
        }
        let profile = session.profile.clone();
        let active_model = ModelChoice {
            id: session.model.to_string(),
            provider: session.provider.to_string(),
        };
        if let Some(pick) = model_pick {
            let pref = self
                .workspace()
                .and_then(|workspace| {
                    workspace
                        .model_preferences
                        .get(&preference_key(&profile, &pick))
                })
                .cloned()
                .unwrap_or_default();
            let queue = [
                pref.effort
                    .filter(|_| !plan.bundled_effort)
                    .map(Choice::Effort),
                pref.speed.map(Choice::Speed),
            ]
            .into_iter()
            .flatten()
            .collect::<VecDeque<_>>();
            if !queue.is_empty() {
                self.model_controls
                    .pending_presets
                    .insert(key.clone(), PendingPreset { model: pick, queue });
            }
        }
        if let Some(choice) = preference_update.filter(|_| !active_model.id.is_empty()) {
            let preference = self
                .workspace_mut()
                .model_preferences
                .entry(preference_key(&profile, &active_model))
                .or_default();
            match choice {
                Choice::Effort(effort) => preference.effort = Some(effort),
                Choice::Speed(speed) => preference.speed = Some(speed),
                Choice::Model(_) => {}
            }
            self.persist(cx);
        }
        if let Some(warning) = result["warning"]
            .as_str()
            .filter(|warning| !warning.trim().is_empty())
        {
            self.banner = Some(warning.to_owned().into());
        }
        self.apply_ready_model_preset(&key, cx);
        if self.selected.as_deref() == Some(&key) {
            self.load_model_tiers();
        }
        if let Some(receipt) = receipt {
            self.store_slash_output(key, "reasoning".into(), receipt);
        }
    }

    pub(super) fn cancel_model_preset(&mut self, key: &str) {
        self.model_controls.pending_presets.remove(key);
    }

    pub(super) fn apply_ready_model_preset(&mut self, key: &str, cx: &mut Context<Self>) {
        if self.model_controls.busy.contains(key) || self.model_controls.prompts.contains_key(key) {
            return;
        }
        let Some(session) = self.sessions.get(key).filter(|session| {
            session.attached && !session.loading && !session.running && !session.submitting
        }) else {
            return;
        };
        let Some(plan) = self.model_controls.pending_presets.get_mut(key) else {
            return;
        };
        if session.model.as_ref() != plan.model.id
            || (!session.provider.is_empty() && session.provider.as_ref() != plan.model.provider)
        {
            return;
        }
        let next = plan.queue.pop_front();
        if plan.queue.is_empty() {
            self.cancel_model_preset(key);
        }
        if let Some(choice) = next {
            self.change_model_setting(key.to_owned(), choice, None, cx);
        }
    }
}

fn preference_key(profile: &str, model: &ModelChoice) -> String {
    format!("{profile}\n{}\n{}", model.provider, model.id)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::settings::RemoteAuth;
    use tokio::{
        io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
        net::TcpListener,
    };

    fn scope(session: &str) -> MenuScope {
        MenuScope {
            profile: "work".to_owned(),
            session: Some(session.to_owned()),
        }
    }

    fn inventory(model: &str) -> Value {
        json!({
            "providers": [{
                "slug": "openai-codex",
                "models": [model],
            }],
        })
    }

    fn model_id<'a>(menus: &'a MenuCatalogs, scope: &MenuScope) -> &'a str {
        let Some(CatalogState::Loaded(catalog)) = menus.entries.get(scope) else {
            panic!("expected a loaded menu");
        };
        &catalog.models[0].choice.id
    }

    fn model_plan(canonical: bool, confirmation: Option<&Confirmation>) -> PickPlan {
        let choice = Choice::Model(ModelChoice {
            id: "gpt-6.2-astra-900k".into(),
            provider: "openai-codex".into(),
        });
        let effort = canonical.then_some("high");
        let command = PickCommand::new(&choice, canonical, confirmation, effort).unwrap();
        PickPlan {
            id: "pick-1".into(),
            choice,
            confirmed: confirmation.is_some(),
            profile: "work".into(),
            runtime: "live".into(),
            command,
            sent_version: None,
            retried: false,
            bundled_effort: effort.is_some(),
            show_receipt: false,
        }
    }

    #[test]
    fn model_confirmation_uses_the_preview_version_and_bundles_reasoning() {
        let mut preview = model_plan(true, None);
        let (method, request) = preview.request("stored", Some((12, 3))).unwrap();
        assert_eq!(method, "session.mutate");
        assert_eq!(request["profile"], "work");
        assert_eq!(request["session_id"], "stored");
        assert_eq!(request["expected_revision"], 12);
        assert_eq!(request["payload"]["reasoning"], "high");
        assert!(request["payload"].get("confirm").is_none());

        let confirmation = Confirmation::Authority {
            token: "gateway-token".into(),
            version: preview.sent_version,
        };
        let mut confirmed = model_plan(true, Some(&confirmation));
        let (_, request) = confirmed.request("stored", preview.sent_version).unwrap();
        assert_eq!(request["expected_revision"], 12);
        assert_eq!(request["expected_generation"], 3);
        assert_eq!(request["payload"]["confirm"], "gateway-token");

        let mut old_gateway = model_plan(false, Some(&Confirmation::Legacy));
        let (method, request) = old_gateway.request("stored", None).unwrap();
        assert_eq!(method, "config.set");
        assert_eq!(request["session_id"], "live");
        assert_eq!(request["confirm_expensive_model"], true);
    }

    #[test]
    fn stale_version_retries_the_same_pick_once_with_gateway_fences() {
        let mut plan = model_plan(true, None);
        assert!(plan.request("stored", None).is_none());
        let (_, first) = plan.request("stored", Some((12, 3))).unwrap();
        assert!(!plan.retry_version(&json!({"message":"model_resolution_failed"})));
        let stale =
            json!({"data":{"reason":"revision_conflict","revision":13,"execution_generation":4}});
        assert!(plan.retry_version(&stale));
        let (_, retry) = plan
            .request("stored", wire_version(&stale["data"]))
            .unwrap();
        assert_eq!(retry["expected_revision"], 13);
        assert_eq!(retry["expected_generation"], 4);
        assert_eq!(retry["request_id"], first["request_id"]);
        assert_eq!(retry["payload"], first["payload"]);
        assert!(!plan.retry_version(&stale));
    }

    #[test]
    fn manual_refresh_takes_precedence_over_an_in_progress_menu_read() {
        let scope = scope("chat");
        let mut menus = MenuCatalogs::default();
        let reading = menus.start(&scope, false).unwrap();
        let refresh = menus.start(&scope, true).unwrap();
        assert!(menus.start(&scope, true).is_none());
        assert!(menus.start(&scope, false).is_none());

        assert!(menus.finish(&scope, refresh, Catalog::from_response(inventory("new"))));
        assert!(!menus.finish(&scope, reading, Catalog::from_response(inventory("old"))));
        assert_eq!(model_id(&menus, &scope), "new");
    }

    #[tokio::test]
    async fn http_refresh_replaces_the_catalog_for_the_originating_menu() -> Result<()> {
        let mut menus = MenuCatalogs::default();
        let chat = scope("chat");
        let other = scope("other");
        for scope in [&chat, &other] {
            let request = menus.start(scope, false).unwrap();
            menus.finish(scope, request, Catalog::from_response(inventory("old")));
        }
        let refresh = menus.start(&chat, true).unwrap();
        assert_eq!(model_id(&menus, &chat), "old");

        let listener = TcpListener::bind("127.0.0.1:0").await?;
        let gateway = Gateway::new(
            &listener.local_addr()?.to_string(),
            RemoteAuth::Token,
            String::new(),
        )?;
        let serve = async {
            let (socket, _) = listener.accept().await?;
            let mut socket = BufReader::new(socket);
            let mut line = String::new();
            socket.read_line(&mut line).await?;
            let request = line.split_whitespace().nth(1).unwrap();
            let (path, query) = request.split_once('?').unwrap();
            assert_eq!(path, "/api/model/options");
            let query: HashMap<_, _> = url::form_urlencoded::parse(query.as_bytes()).collect();
            assert_eq!(query["profile"], "work");
            assert_eq!(query["explicit_only"], "true");
            assert_eq!(query["refresh"], "true");
            loop {
                line.clear();
                if socket.read_line(&mut line).await? == 0 || line == "\r\n" {
                    break;
                }
            }
            let body = inventory("new").to_string();
            let reply = format!(
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            socket.get_mut().write_all(reply.as_bytes()).await
        };
        let (served, fetched) = tokio::time::timeout(std::time::Duration::from_secs(5), async {
            tokio::join!(
                serve,
                Catalog::fetch(&gateway, &chat.profile, refresh.refresh)
            )
        })
        .await?;
        served?;
        assert!(menus.finish(&chat, refresh, Ok(fetched?)));
        assert_eq!(model_id(&menus, &chat), "new");
        assert_eq!(model_id(&menus, &other), "old");
        Ok(())
    }
}
