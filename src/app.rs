use crate::i18n::text as tr;

use std::{
    collections::{HashMap, HashSet},
    time::Duration,
};

use gpui::{
    AppContext, Context, Entity, FocusHandle, ListAlignment, ListOffset, ListState, Pixels, Point,
    ScrollHandle, SharedString, Subscription, Task, Window, px,
};
use gpui_component::input::{InputEvent, InputState, TextareaState};
use serde_json::{Value, json};
use tokio::{runtime::Handle, sync::mpsc};
use uuid::Uuid;

use crate::{
    gateway::{Gateway, Outgoing, Update},
    session::{BranchPoint, PromptRoute, Row, Session, SessionTarget, Summary, string},
    session_activity::Kind as WorkKind,
    settings::{ChatTab, LaunchOptions, Prepared, ReadingPosition, Settings, Workspace},
};

#[path = "activity.rs"]
mod activity;
#[path = "clarify.rs"]
mod clarify;
#[path = "conversation_files.rs"]
mod conversation_files;
#[path = "desktop_alerts.rs"]
mod desktop_alerts;
#[path = "voice_view.rs"]
mod voice_view;
#[path = "voice_wake.rs"]
mod voice_wake;
#[path = "message_bookmarks.rs"]
mod message_bookmarks;
use clarify::Clarify;
#[path = "pane_layout.rs"]
mod pane_layout;
#[path = "reading_position.rs"]
mod reading_position;
use pane_layout::PaneResize;
pub(crate) use pane_layout::initial_window_bounds;
#[path = "remote_refs.rs"]
mod remote_refs;
#[path = "review.rs"]
mod review;
use review::Review;
#[path = "workspace_files.rs"]
mod workspace_files;
#[path = "workspace_scope.rs"]
mod workspace_scope;
use workspace_files::{FileDownload, WorkspaceFiles};
#[path = "background_view.rs"]
mod background_view;
#[path = "theme_editor.rs"]
mod theme_editor;
use background_view::BackgroundView;
#[path = "settings_view.rs"]
mod settings_view;
use settings_view::SettingsView;
#[path = "palette.rs"]
mod palette;
use palette::Palette;
#[path = "timeline.rs"]
mod timeline;
use timeline::{TimelineItem, TurnMarker};
#[path = "turn_rail.rs"]
mod turn_rail;
use turn_rail::TurnRail;
#[path = "tool_view.rs"]
mod tool_view;
use tool_view::ToolHistory;
#[path = "media_view.rs"]
mod media_view;
use media_view::MediaView;
#[path = "transcript_find.rs"]
mod transcript_find;
use transcript_find::TranscriptFind;
#[path = "attachment_ops.rs"]
mod attachment_ops;
#[path = "followups.rs"]
mod followups;
use followups::QueueEditor;
#[path = "pasted_images.rs"]
mod pasted_images;
#[path = "rewrite.rs"]
mod rewrite;
#[path = "session_export.rs"]
mod session_export;
#[path = "session_history.rs"]
pub(crate) mod session_history;
#[path = "session_ops.rs"]
mod session_ops;
use rewrite::RewriteEditor;
#[path = "slash_menu.rs"]
mod slash_menu;
use slash_menu::{Lookup, SlashMenu};
#[path = "reference_menu.rs"]
mod reference_menu;
use reference_menu::{PathLookup, ReferenceMenu};
#[path = "cron_tasks.rs"]
mod cron_tasks;
#[path = "view.rs"]
mod view;
use session_ops::BranchPlan;
#[path = "model_controls.rs"]
mod model_controls;
use model_controls::ModelControls;
#[path = "session_status.rs"]
mod session_status;
use session_status::ApprovalStatus;
#[path = "busy_input.rs"]
mod busy_input;
use busy_input::BusyInput;
#[path = "unread_sessions.rs"]
mod unread_sessions;
use unread_sessions::UnreadSessions;
#[path = "profile_editor.rs"]
mod profile_editor;
#[path = "profiles.rs"]
mod profiles;
#[path = "session_dialog.rs"]
mod session_dialog;
use profiles::Profiles;
#[path = "gateway_panel.rs"]
mod gateway_panel;
use gateway_panel::GatewayPanel;

enum Call {
    Create {
        draft: String,
        request: String,
        profile: String,
        draft_upload: bool,
    },
    Replay(String),
    Resume {
        key: String,
        refresh_history: bool,
        paged: bool,
    },
    RunningReplay(String, u64),
    CheckTurn { key: String, runtime: String, seq: u64 },
    PeerPrompt { key: String, runtime: String, sequence: u64 },
    CheckReplay { key: String, runtime: String, seq: u64 },
    AttachFile(String, attachment_ops::AttachmentJob, Option<crate::file_upload::StagedFile>, crate::upload_progress::Cancel),
    Submit(String, Prepared),
    CorrectTurn(String, Prepared),
    Stop(String),
    Answer(String, String),
    Resolve(String, String),
    ModelChange(String),
    ReasoningDisplay(slash_menu::Scope),
    WorkStatus(activity::WorkRequest),
    WorkRoster(String),
    ModelOptions(model_controls::MenuScope, model_controls::MenuRequest),
    ModelTiers(String, crate::settings::ModelChoice),
    ApprovalMode(String, bool),
    ContextUsage(String, u64, u64),
    GatewayInference,
    VoiceWake(voice_wake::Request),
    WakeFeed(tokio::sync::oneshot::Sender<bool>),
    SetVoiceEngine(String, crate::voice::VoiceEngine),
    Rewrite(String, String),
    SlashSuggestions(Lookup),
    CatalogSlash(slash_menu::Scope, String),
    PathSuggestions(PathLookup),
    CancelQueued(String, String),
    ReplaceQueued(String, String, String),
    SkillDispatch(String, Prepared),
    Branch {
        target: SessionTarget,
        through: Option<BranchPoint>,
        origin_tab: Option<String>,
    },
}

#[derive(Clone, Copy)]
enum TabClose {
    Current,
    Others,
    Right,
    All,
}

pub struct Desktop {
    voice: voice_view::Voice,
    voice_wake: voice_wake::Wake,
    window_handle: gpui::AnyWindowHandle,
    runtime: Handle,
    settings: Settings,
    gateway: Option<Gateway>,
    connection: Option<Task<()>>,
    out: Option<mpsc::UnboundedSender<Outgoing>>,
    canonical: bool,
    clarify_batch: bool,
    process_epoch: String,
    request_id: u64,
    pending: HashMap<u64, Call>,
    history_reads: HashMap<String, Task<()>>,
    branch_requests: HashMap<(String, Option<BranchPoint>), BranchPlan>,
    sessions: HashMap<String, Session>,
    aliases: HashMap<String, String>,
    unbound: HashMap<String, Vec<Value>>,
    selected: Option<String>,
    rows: Vec<Summary>,
    unread_sessions: UnreadSessions,
    sidebar_list: view::SidebarList,
    work_monitor: activity::WorkMonitor,
    cron: cron_tasks::CronTasks,
    next: Option<usize>,
    profiles: Profiles,
    profile_editor: profile_editor::ProfileEditor,
    archived_only: bool,
    refreshing: bool,
    list_job: Option<Task<()>>,
    save_job: Option<Task<()>>,
    query: String,
    hide_reasoning: bool,
    gateway_reasoning: HashMap<String, crate::reasoning::Display>,
    reasoning_config_revision: u64,
    model_controls: ModelControls,
    approval_status: ApprovalStatus,
    busy_input: BusyInput,
    media: MediaView,
    transcript_find: TranscriptFind,
    palette: Palette,
    composer: Entity<TextareaState>,
    composer_expanded: bool,
    slash_menu: SlashMenu,
    references: ReferenceMenu,
    clipboard_pastes: HashMap<String, usize>,
    search: Entity<InputState>,
    address: Entity<InputState>,
    token: Entity<InputState>,
    rename: Entity<InputState>,
    clarify: Clarify,
    rewrite_editor: Option<RewriteEditor>,
    queue_editor: Option<QueueEditor>,
    _subscriptions: Vec<Subscription>,
    settings_open: bool,
    settings_view: SettingsView,
    background_view: BackgroundView,
    theme_editor: Option<theme_editor::ThemeEditor>,
    files: WorkspaceFiles,
    review: Review,
    file_download: FileDownload,
    login_url: Option<String>,
    gateway_panel: GatewayPanel,
    sidebar_open: bool,
    pane_resize: Option<PaneResize>,
    #[cfg(target_os = "linux")]
    x11_client_chrome: bool,
    maximized_drag: Option<Point<Pixels>>,
    session_dialog: Option<session_dialog::SessionDialog>,
    list: ListState,
    transcript_scrollbar: timeline::TranscriptScrollbar,
    tab_scroll: ScrollHandle,
    dragged_tab: Option<(String, gpui::Pixels)>,
    workspace_focus: FocusHandle,
    #[cfg(not(windows))]
    alert_targets: std::collections::VecDeque<(SharedString, desktop_alerts::AlertTarget)>,
    notified_prompts: std::collections::HashSet<(String, String)>,
    pending_bookmark: Option<crate::settings::MessageBookmark>,
    pending_reading: Option<ReadingPosition>,
    following: bool,
    visible_count: usize,
    timeline: Vec<TimelineItem>,
    message_items: Vec<usize>,
    turns: Vec<TurnMarker>,
    turn_rail: TurnRail,
    timeline_raw_count: Option<usize>,
    tool_history: ToolHistory,
    view_revision: u64,
    expanded: HashSet<usize>,
    status: &'static str,
    gateway_version: Option<String>,
    banner: Option<SharedString>,
}

impl Desktop {
    pub fn new(
        runtime: Handle,
        loaded: anyhow::Result<Settings>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let banner = loaded.as_ref().err().map(|err| err.to_string().into());
        let mut settings = loaded.unwrap_or_default();
        let sidebar_open = settings.display.sidebar_open;
        let hide_reasoning =
            settings.display.reasoning == crate::settings::ReasoningVisibility::Hidden;
        let workspace_focus = cx.focus_handle();
        workspace_focus.focus(window, cx);
        let composer = cx.new(|cx| {
            TextareaState::new(window, cx)
                .auto_grow(1, 8)
                .placeholder(tr("输入消息…"))
        });
        let search = cx.new(|cx| InputState::new(window, cx).placeholder(tr("搜索会话")));
        let palette_input =
            cx.new(|cx| InputState::new(window, cx).placeholder(tr("搜索会话或操作…")));
        let transcript_search =
            cx.new(|cx| InputState::new(window, cx).placeholder(tr("会话内查找")));
        let model_search =
            cx.new(|cx| InputState::new(window, cx).placeholder(tr("搜索模型或提供商")));
        let address = cx.new(|cx| {
            InputState::new(window, cx)
                .placeholder("https://hermes.example.com")
                .default_value(settings.suggested_address())
        });
        let token = cx.new(|cx| {
            InputState::new(window, cx)
                .masked(true)
                .placeholder(tr("输入网关令牌"))
        });
        let gateway_panel = GatewayPanel::new(settings.gateway_mode, settings.suggested_auth());
        let rename = cx.new(|cx| InputState::new(window, cx).placeholder(tr("会话标题")));
        let subscriptions = vec![
            cx.subscribe_in(&palette_input, window, |this, _, event, _, cx| {
                if matches!(event, InputEvent::Change) {
                    this.palette_query_changed(cx);
                }
            }),
            cx.subscribe_in(
                &transcript_search,
                window,
                |this, _, event, _, cx| match event {
                    InputEvent::Change => this.transcript_find_changed(cx),
                    InputEvent::Focus | InputEvent::Blur => cx.notify(),
                    _ => {}
                },
            ),
            cx.subscribe_in(&model_search, window, |_, _, event, _, cx| {
                if matches!(event, InputEvent::Change) {
                    cx.notify();
                }
            }),
            cx.subscribe_in(&composer, window, |this, _, event, _, cx| match event {
                InputEvent::Change => this.draft_changed(cx),
                InputEvent::Focus | InputEvent::Blur => cx.notify(),
                _ => {}
            }),
            cx.observe(&composer, |this, _, cx| this.references_changed(cx)),
            cx.subscribe_in(&address, window, |this, _, event, window, cx| {
                if matches!(event, InputEvent::Change) {
                    this.remote_address_changed(window, cx);
                }
            }),
            cx.subscribe_in(&token, window, |this, _, event, _, cx| {
                if matches!(event, InputEvent::Change) {
                    this.gateway_panel.clear_probe();
                    cx.notify();
                }
            }),
            cx.subscribe_in(&search, window, |this, _, event, window, cx| {
                if matches!(event, InputEvent::Change) {
                    let query = this.search.read(cx).value().trim().to_owned();
                    if this.query != query {
                        this.query = query;
                        this.fetch_list(0, true, window, cx);
                    }
                }
                cx.notify();
            }),
            cx.subscribe_in(&rename, window, |this, _, event, window, cx| match event {
                InputEvent::PressEnter { .. } => this.finish_rename(window, cx),
                InputEvent::Change => cx.notify(),
                _ => {}
            }),
        ];
        let background_view = BackgroundView::new(&mut settings.display, window, cx);
        let list = ListState::new(0, ListAlignment::Top, px(260.));
        let mut this = Self {
            window_handle: window.window_handle(),
            runtime,
            address,
            token,
            rename,
            search,
            composer,
            composer_expanded: false,
            slash_menu: SlashMenu::default(),
            references: ReferenceMenu::default(),
            clipboard_pastes: HashMap::new(),
            _subscriptions: subscriptions,
            settings_open: false,
            background_view,
            theme_editor: None,
            settings_view: SettingsView::new(settings.display.sidebar_transparency(), cx),
            files: WorkspaceFiles::new(cx.focus_handle()),
            review: Review::new(cx.focus_handle()),
            file_download: FileDownload::default(),
            login_url: None,
            gateway_panel,
            settings,
            banner,
            gateway: None,
            connection: None,
            voice: Default::default(),
            voice_wake: Default::default(),
            out: None,
            canonical: false,
            clarify_batch: false,
            process_epoch: String::new(),
            request_id: 0,
            pending: HashMap::new(),
            history_reads: HashMap::new(),
            branch_requests: HashMap::new(),
            sessions: HashMap::new(),
            aliases: HashMap::new(),
            unbound: HashMap::new(),
            selected: None,
            rows: Vec::new(),
            unread_sessions: UnreadSessions::default(),
            sidebar_list: view::SidebarList::default(),
            work_monitor: activity::WorkMonitor::default(),
            cron: cron_tasks::CronTasks::default(),
            next: None,
            profiles: Profiles::default(),
            profile_editor: profile_editor::ProfileEditor::default(),
            archived_only: false,
            refreshing: false,
            list_job: None,
            save_job: None,
            query: String::new(),
            hide_reasoning,
            gateway_reasoning: HashMap::new(),
            reasoning_config_revision: 0,
            model_controls: ModelControls::new(model_search),
            approval_status: ApprovalStatus::default(),
            busy_input: BusyInput::default(),
            media: MediaView::default(),
            transcript_find: TranscriptFind::new(transcript_search),
            palette: Palette::new(palette_input),
            sidebar_open,
            pane_resize: None,
            #[cfg(target_os = "linux")]
            x11_client_chrome: pane_layout::enable_x11_client_chrome(window),
            maximized_drag: None,
            clarify: Clarify::new(cx.focus_handle()),
            rewrite_editor: None,
            queue_editor: None,
            session_dialog: None,
            list: list.clone(),
            transcript_scrollbar: timeline::TranscriptScrollbar::new(list),
            tab_scroll: ScrollHandle::new(),
            dragged_tab: None,
            workspace_focus,
            #[cfg(not(windows))]
            alert_targets: Default::default(),
            notified_prompts: Default::default(),
            pending_bookmark: None,
            pending_reading: None,
            following: true,
            visible_count: 0,
            timeline: Vec::new(),
            message_items: Vec::new(),
            turns: Vec::new(),
            turn_rail: TurnRail::new(cx),
            timeline_raw_count: None,
            tool_history: ToolHistory::default(),
            view_revision: 0,
            expanded: Default::default(),
            status: "未连接",
            gateway_version: None,
        };
        #[cfg(not(windows))]
        this.register_notification_handler(window, cx);
        this._subscriptions
            .push(cx.observe_window_bounds(window, |this, window, cx| {
                if this.record_window(window) {
                    this.reveal_selected_tab();
                    this.schedule_save(cx);
                    cx.notify();
                }
            }));
        this._subscriptions
            .push(cx.observe_window_activation(window, |this, window, cx| {
                if !window.is_window_active() {
                    this.maximized_drag = None;
                    this.finish_pane_resize(cx);
                } else {
                    this.check_open_transcript(true, cx);
                }
            }));
        let weak = cx.entity().downgrade();
        window.on_window_should_close(cx, move |window, cx| {
            let _ = weak.update(cx, |this, cx| {
                this.record_window(window);
                this.remember_reading();
                this.persist(cx);
            });
            true
        });
        this.restore_background(window, cx);
        this.restore_gateway(window, cx);
        this
    }

    fn show_connection_error(&mut self, error: String, cx: &mut Context<Self>) {
        if self.settings_open {
            self.settings_view.connection_error = Some(error.into());
        } else {
            self.banner = Some(error.into());
        }
        cx.notify();
    }

    fn connect(&mut self, gateway: Gateway, window: &mut Window, cx: &mut Context<Self>) {
        self.connection = None;
        self.out = None;
        self.list_job = None;
        self.pending.clear();
        self.session_dialog = None;
        self.history_reads.clear();
        self.branch_requests.clear();
        self.sessions.clear();
        self.aliases.clear();
        self.unbound.clear();
        self.rows.clear();
        self.unread_sessions.clear();
        self.sidebar_list = view::SidebarList::default();
        self.work_monitor = activity::WorkMonitor::default();
        self.cron = cron_tasks::CronTasks::default();
        self.profiles = Profiles::default();
        self.profile_editor = profile_editor::ProfileEditor::default();
        self.notified_prompts.clear();
        self.pending_bookmark = None;
        self.archived_only = false;
        self.gateway_reasoning.clear();
        self.reasoning_config_revision = self.reasoning_config_revision.wrapping_add(1);
        self.hide_reasoning =
            self.settings.display.reasoning == crate::settings::ReasoningVisibility::Hidden;
        self.model_controls.reset();
        self.approval_status = ApprovalStatus::default();
        self.busy_input = BusyInput::default();
        self.close_image(window, cx);
        self.close_files(window, cx);
        self.close_review(window, cx);
        self.files.clear();
        self.review.clear();
        self.media = MediaView::default();
        self.tool_history = ToolHistory::default();
        self.clarify.clear();
        self.queue_editor = None;
        self.slash_menu = SlashMenu::default();
        self.references = ReferenceMenu::default();
        self.close_rewrite(window, cx);
        self.pending_reading = None;
        self.tab_scroll = ScrollHandle::new();
        self.next = None;
        self.refreshing = false;
        self.query.clear();
        self.search
            .update(cx, |field, cx| field.set_value("", window, cx));
        self.workspace_mut().restore_tabs();
        self.selected = self
            .workspace()
            .and_then(|workspace| workspace.selected.clone());
        self.reveal_selected_tab();
        self.restore_draft(window, cx);
        self.close_transcript_find(window, cx);
        self.close_palette(window, cx);
        self.palette = Palette::new(self.palette.input.clone());
        self.release_turn_rail(window, cx);
        self.reset_scroll();
        self.stage_reading_restore();
        self.restart(gateway, window, cx);
    }

    fn restart(&mut self, gateway: Gateway, window: &mut Window, cx: &mut Context<Self>) {
        self.reset_voice_connection();
        self.voice_wake = Default::default();
        self.login_url = None;
        let mut connection = gateway.start(&self.runtime);
        self.gateway = Some(gateway);
        self.status = "正在连接";
        self.gateway_version = None;
        self.connection = Some(cx.spawn_in(window, async move |view, cx| {
            while let Some(update) = connection.inbox.recv().await {
                let batchable = matches!(&update, Update::Frame(frame) if frame["params"]["type"] == "message.delta" || frame["params"]["type"] == "reasoning.delta");
                if batchable { cx.background_executor().timer(Duration::from_millis(12)).await; }
                let mut batch = vec![update];
                while batch.len() < 256 {
                    let Ok(update) = connection.inbox.try_recv() else { break };
                    batch.push(update);
                }
                if view.update_in(cx, |this, window, cx| {
                    for update in batch { this.apply_update(update, window, cx); }
                    this.check_voice(window, cx);
                    this.sync_prompt_alerts(window,cx);
                    this.sync_list();
                    cx.notify();
                }).is_err() { break; }
            }
        }));
        cx.notify();
    }

    fn workspace(&self) -> Option<&Workspace> {
        self.settings.workspaces.get(self.settings.workspace_key())
    }

    fn workspace_mut(&mut self) -> &mut Workspace {
        let key = self.settings.workspace_key().to_owned();
        self.settings.workspaces.entry(key).or_default()
    }

    fn key(&self) -> String {
        self.selected
            .clone()
            .or_else(|| {
                self.workspace()
                    .and_then(|workspace| workspace.active_tab.clone())
            })
            .unwrap_or_default()
    }

    fn creating(&self) -> bool {
        let key = self.key();
        self.pending
            .values()
            .any(|call| matches!(call, Call::Create { draft, .. } if draft == &key))
    }

    fn persist(&mut self, cx: &mut Context<Self>) {
        if let Err(error) = self.settings.save() {
            self.banner = Some(
                crate::i18n::format_text!(
                    "无法保存草稿及偏好 · {error}",
                    "Could not save drafts and preferences · {error}"
                )
                .into(),
            );
            cx.notify();
        } else {
            self.prune_clipboard_files();
        }
    }

    fn draft_changed(&mut self, cx: &mut Context<Self>) {
        let key = self.key();
        let text = self.composer.read(cx).value().to_string();
        self.composer_expanded =
            !text.is_empty() && (self.composer_expanded || text.trim_end().contains('\n'));
        self.remember_draft_skill(&key, &text);
        self.slash_changed(&text, cx);
        let drafts = &mut self.workspace_mut().drafts;
        if text.is_empty() {
            drafts.remove(&key);
        } else {
            drafts.insert(key, text);
        }
        self.schedule_save(cx);
        cx.notify();
    }

    fn schedule_save(&mut self, cx: &mut Context<Self>) {
        self.save_job = Some(cx.spawn(async move |view, cx| {
            cx.background_executor()
                .timer(Duration::from_millis(200))
                .await;
            let _ = view.update(cx, |this, cx| this.persist(cx));
        }));
    }

    fn apply_language(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        crate::i18n::apply(self.settings.display.language);
        let placeholder = self.composer_placeholder();
        self.composer.update(cx, |field, cx| {
            field.set_placeholder(placeholder, window, cx);
        });
        for (input, placeholder) in [
            (&self.search, tr("搜索会话")),
            (&self.palette.input, tr("搜索会话或操作…")),
            (&self.transcript_find.input, tr("会话内查找")),
            (&self.model_controls.search, tr("搜索模型或提供商")),
            (&self.rename, tr("会话标题")),
            (&self.token, tr("输入网关令牌")),
        ] {
            input.update(cx, |field, cx| {
                field.set_placeholder(placeholder, window, cx)
            });
        }
        self.remeasure_transcript();
    }

    fn composer_placeholder(&self) -> &'static str {
        if self.selected.is_none() {
            tr("给 Hermes 一个任务")
        } else {
            tr("输入消息…")
        }
    }

    fn restore_draft(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.composer_expanded = false;
        let value = self
            .workspace()
            .and_then(|workspace| workspace.drafts.get(&self.key()))
            .cloned()
            .unwrap_or_default();
        self.slash_changed(&value, cx);
        let placeholder = self.composer_placeholder();
        self.composer.update(cx, |field, cx| {
            field.set_placeholder(placeholder, window, cx);
            field.set_value(value, window, cx);
        });
    }

    fn reset_scroll(&mut self) {
        self.transcript_scrollbar.reset();
        self.pending_bookmark = None;
        self.list.reset(0);
        self.visible_count = 0;
        self.timeline.clear();
        self.message_items.clear();
        self.turns.clear();
        self.turn_rail.reset();
        self.timeline_raw_count = None;
        self.pending_reading = None;
        self.following = true;
        self.expanded.clear();
        self.tool_history.groups.clear();
        self.view_revision = self.view_revision.wrapping_add(1);
    }

    fn at_latest(&self) -> bool {
        timeline::at_bottom(&self.list)
    }

    fn sync_list(&mut self) {
        self.sync_list_at(None, None);
    }

    fn sync_list_at(&mut self, prepended_rows: Option<usize>, position: Option<ReadingPosition>) {
        if self.transcript_scrollbar.dragging() || self.transcript_scrollbar.has_navigation() {
            self.cancel_search_reveal();
            self.following = false;
            self.pending_reading = None;
            self.pending_bookmark = None;
        }
        let mut preserved = false;
        let session = self
            .selected
            .as_ref()
            .and_then(|key| self.sessions.get(key));
        let raw_count = session.map_or(0, Session::count);
        if self.timeline_raw_count != Some(raw_count) {
            let (items, turns, message_items) = session.map_or_else(Default::default, |session| {
                timeline::project(session, self.hide_reasoning)
            });
            let new_count = items.len();
            if let Some(shift) = prepended_rows {
                preserved = timeline::splice_older_page(&self.list, &self.timeline, &items, shift);
            } else {
                let kept = self
                    .timeline
                    .iter()
                    .zip(&items)
                    .take_while(|(old, new)| old == new)
                    .count();
                if kept != self.visible_count || new_count != self.visible_count {
                    self.list.splice(kept..self.visible_count, new_count - kept);
                }
            }
            self.timeline = items;
            self.turns = turns;
            self.message_items = message_items;
            self.visible_count = new_count;
            self.timeline_raw_count = Some(raw_count);
        }
        if !preserved && self.pending_reading.is_none() {
            self.pending_reading = position;
        }
        self.apply_reading_restore();
        if self.following && self.visible_count > 0 {
            self.list.scroll_to(ListOffset {
                item_ix: self.visible_count,
                offset_in_item: px(0.),
            });
        }
        self.sync_turn_rail();
        self.restore_bookmark();
    }

    fn visible_item_for(&self, row: usize) -> Option<usize> {
        let index = self.timeline.partition_point(|item| item.rows.end <= row);
        self.timeline
            .get(index)
            .filter(|item| item.rows.contains(&row))
            .map(|_| index)
    }

    fn select_tab(&mut self, id: &str, window: &mut Window, cx: &mut Context<Self>) {
        self.voice.stop_on_tab_change(id);
        self.close_queue_editor(window, cx);
        self.close_rewrite(window, cx);
        self.close_files(window, cx);
        self.close_review(window, cx);
        let Some((index, tab)) = self.workspace().and_then(|workspace| {
            workspace
                .tabs
                .iter()
                .enumerate()
                .find(|(_, tab)| tab.id == id)
                .map(|(index, tab)| (index, tab.clone()))
        }) else {
            return;
        };
        self.tab_scroll.scroll_to_item(index);
        let unchanged = self.selected == tab.session
            && self
                .workspace()
                .is_some_and(|workspace| workspace.active_tab.as_deref() == Some(id));
        let profile = self.tab_profile(&tab).to_owned();
        self.profiles.last_tabs.insert(profile, id.to_owned());
        if !unchanged {
            self.remember_reading();
            self.close_transcript_find(window, cx);
            self.close_image(window, cx);
            self.release_turn_rail(window, cx);
            self.selected = tab.session.clone();
            self.model_controls.picker = None;
            let workspace = self.workspace_mut();
            workspace.active_tab = Some(id.to_owned());
            workspace.selected = tab.session.clone();
            self.sync_tab_sidebar(window, cx);
            self.restore_draft(window, cx);
            self.persist(cx);
            self.reset_scroll();
            self.stage_reading_restore();
        }
        if let Some(key) = tab.session {
            self.prefetch_history(&key, cx);
            self.attach(&key, false);
            if !unchanged {
                let profile = self.active_profile().to_owned();
                if self.session_is_unread(&profile, &key) {
                    self.patch_session(&key, &profile, json!({"unread":false}), window, cx);
                }
            }
            self.sync_list();
            if self.pending_reading.is_some() {
                self.older_history(cx);
            }
        } else {
            self.composer
                .update(cx, |field, cx| field.focus(window, cx));
        }
        if !unchanged {
            self.check_open_transcript(true, cx);
            self.refresh_selection_status(cx);
            self.poll_work();
        }
        cx.notify();
    }

    fn cycle_chat_tab(&mut self, reverse: bool, window: &mut Window, cx: &mut Context<Self>) {
        if self.palette.open
            || self.settings_open
            || self.media.is_open()
            || self.profile_editor.open
        {
            return;
        }
        let tab = self.workspace().and_then(|workspace| {
            let current = workspace.active_tab.as_deref()?;
            let index = workspace.tabs.iter().position(|tab| tab.id == current)?;
            let count = workspace.tabs.len();
            let next = if reverse {
                (index + count - 1) % count
            } else {
                (index + 1) % count
            };
            Some(workspace.tabs[next].id.clone())
        });
        if let Some(tab) = tab {
            self.select_tab(&tab, window, cx);
        }
    }

    fn new_chat_tab(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.settings_open || self.gateway.is_none() {
            return;
        }
        let mut tab = ChatTab::draft();
        tab.profile = self.active_profile().to_owned();
        let id = tab.id.clone();
        self.workspace_mut().tabs.push(tab);
        self.select_tab(&id, window, cx);
    }

    fn open_session(
        &mut self,
        summary: &Summary,
        new_tab: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let workspace = self.workspace_mut();
        let existing = workspace
            .tabs
            .iter()
            .position(|tab| tab.session.as_ref() == Some(&summary.id));
        let id = if let Some(index) = existing {
            workspace.tabs[index].id.clone()
        } else {
            let mut tab = ChatTab::draft();
            tab.session = Some(summary.id.clone());
            tab.title = summary.title.to_string();
            tab.profile = summary.profile.clone();
            let id = tab.id.clone();
            let active = workspace
                .active_tab
                .as_deref()
                .and_then(|active| workspace.tabs.iter().position(|tab| tab.id == active));
            if let Some(index) = active.filter(|_| !new_tab) {
                let previous = std::mem::replace(&mut workspace.tabs[index], tab);
                workspace.remember_closed(previous);
            } else {
                workspace.tabs.push(tab);
            }
            id
        };
        self.select_tab(&id, window, cx);
    }

    fn close_chat_tabs(
        &mut self,
        id: &str,
        scope: TabClose,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let profile = self.active_profile().to_owned();
        let workspace = self.workspace_mut();
        let Some(index) = workspace.tabs.iter().position(|tab| tab.id == id) else {
            return;
        };
        let active = workspace.active_tab.clone();
        let mut closed_active = None;
        for (position, tab) in std::mem::take(&mut workspace.tabs).into_iter().enumerate() {
            let close = match scope {
                TabClose::Current => position == index,
                TabClose::Others => position != index,
                TabClose::Right => position > index,
                TabClose::All => true,
            };
            if !close {
                workspace.tabs.push(tab);
            } else if active.as_deref() == Some(tab.id.as_str()) {
                closed_active = Some(tab);
            } else {
                workspace.remember_closed(tab);
            }
        }
        if workspace.tabs.is_empty() {
            let mut draft = ChatTab::draft();
            draft.profile = profile;
            workspace.tabs.push(draft);
        }
        if let Some(tab) = closed_active {
            workspace.remember_closed(tab);
            let next = workspace.tabs[index.min(workspace.tabs.len() - 1)]
                .id
                .clone();
            self.select_tab(&next, window, cx);
        } else {
            self.persist(cx);
            cx.notify();
        }
    }

    fn move_chat_tab(&mut self, source: &str, target: &str, cx: &mut Context<Self>) {
        let workspace = self.workspace_mut();
        let Some(from) = workspace.tabs.iter().position(|tab| tab.id == source) else {
            return;
        };
        let Some(to) = workspace.tabs.iter().position(|tab| tab.id == target) else {
            return;
        };
        if from == to {
            return;
        }
        let tab = workspace.tabs.remove(from);
        workspace.tabs.insert(to, tab);
        let active = workspace
            .active_tab
            .as_deref()
            .and_then(|id| workspace.tabs.iter().position(|tab| tab.id == id));
        if let Some(index) = active {
            self.tab_scroll.scroll_to_item(index);
        }
        self.persist(cx);
        cx.notify();
    }

    fn close_active_tab(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.settings_open
            && let Some(id) = self
                .workspace()
                .and_then(|workspace| workspace.active_tab.clone())
        {
            self.close_chat_tabs(&id, TabClose::Current, window, cx);
        }
    }

    fn reopen_chat_tab(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.settings_open || self.gateway.is_none() {
            return;
        }
        let workspace = self.workspace_mut();
        let Some(tab) = workspace.closed_tabs.pop() else {
            return;
        };
        let id = match workspace.tabs.iter().find(|existing| {
            existing.id == tab.id || (tab.session.is_some() && existing.session == tab.session)
        }) {
            Some(existing) => existing.id.clone(),
            None => {
                let id = tab.id.clone();
                workspace.tabs.push(tab);
                id
            }
        };
        self.select_tab(&id, window, cx);
        self.persist(cx);
    }

    fn bind_created_tab(
        &mut self,
        draft: &str,
        key: &str,
        title: &str,
        text: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let profile = self
            .sessions
            .get(key)
            .map(|session| session.profile.clone())
            .unwrap_or_default();
        let workspace = self.workspace_mut();
        let input = workspace
            .drafts
            .remove(draft)
            .unwrap_or_else(|| text.to_owned());
        workspace.drafts.insert(key.to_owned(), input);
        if let Some(files) = workspace.draft_files.remove(draft) {
            workspace.draft_files.insert(key.to_owned(), files);
        }
        if let Some(skill) = workspace.draft_skills.remove(draft) {
            workspace.draft_skills.insert(key.to_owned(), skill);
        }
        if let Some(tab) = workspace
            .tabs
            .iter_mut()
            .chain(&mut workspace.closed_tabs)
            .find(|tab| tab.id == draft)
        {
            tab.session = Some(key.to_owned());
            tab.title = title.to_owned();
            tab.profile = profile;
        }
        if workspace.active_tab.as_deref() == Some(draft) {
            self.select_tab(draft, window, cx);
        }
    }

    fn fetch_list(
        &mut self,
        offset: usize,
        debounce: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let scope = self.update_list_scope();
        let Some(gateway) = self.gateway.clone().filter(|_| self.out.is_some()) else {
            cx.notify();
            return;
        };
        let requested = scope.clone();
        let loaded = self.rows.len();
        let runtime = self.runtime.clone();
        self.refreshing = true;
        self.list_job = Some(cx.spawn_in(window, async move |view, cx| {
            if debounce {
                cx.background_executor()
                    .timer(Duration::from_millis(200))
                    .await;
            }
            let result = runtime
                .spawn(async move {
                    let sessions = |offset| {
                        gateway.sessions(
                            &requested.query,
                            offset,
                            &requested.profile,
                            requested.archived,
                        )
                    };
                    let mut page = sessions(offset).await?;
                    if offset == 0 && requested.query.is_empty() {
                        while let Some(next) = page.next.filter(|_| page.rows.len() < loaded) {
                            let more = sessions(next).await?;
                            page.rows.extend(more.rows);
                            page.next = more.next;
                        }
                    }
                    Ok::<_, anyhow::Error>(page)
                })
                .await;
            let _ = view.update_in(cx, |this, _, cx| {
                if this.profiles.scope != scope {
                    return;
                }
                this.refreshing = false;
                match result {
                    Ok(Ok(page)) => {
                        this.profiles.ready = true;
                        if offset == 0 {
                            this.rows.clear();
                        }
                        let mut seen: HashSet<_> =
                            this.rows.iter().map(|row| row.id.clone()).collect();
                        this.rows.extend(
                            page.rows
                                .iter()
                                .filter_map(Summary::from_wire)
                                .filter(|row| {
                                    scope.profile.is_empty()
                                        || row.profile.is_empty()
                                        || row.profile == scope.profile
                                })
                                .map(|mut row| {
                                    if row.profile.is_empty() {
                                        row.profile.clone_from(&scope.profile);
                                    }
                                    row
                                })
                                .filter(|row| seen.insert(row.id.clone())),
                        );
                        this.sidebar_list.invalidate();
                        this.update_tab_labels(cx);
                        this.next = page.next;
                    }
                    Ok(Err(error)) if this.rows.is_empty() && !this.profiles.ready => {
                        this.banner = Some(error.to_string().into())
                    }
                    Err(error) if this.rows.is_empty() && !this.profiles.ready => {
                        this.banner = Some(error.to_string().into())
                    }
                    _ => {}
                }
                cx.notify();
            });
        }));
        cx.notify();
    }

    fn update_tab_labels(&mut self, cx: &mut Context<Self>) {
        let key = self.settings.workspace_key().to_owned();
        let Some(workspace) = self.settings.workspaces.get_mut(&key) else {
            return;
        };
        let mut updated = false;
        for tab in workspace.tabs.iter_mut().chain(&mut workspace.closed_tabs) {
            let Some(key) = &tab.session else {
                continue;
            };
            let Some(row) = self.rows.iter().find(|row| &row.id == key) else {
                continue;
            };
            if tab.title.as_str() != row.title.as_ref() || tab.profile != row.profile {
                tab.title = row.title.to_string();
                tab.profile.clone_from(&row.profile);
                updated = true;
            }
        }
        if updated {
            self.persist(cx);
        }
    }

    fn call(&mut self, method: &str, params: Value, action: Call) -> bool {
        self.send_call(method, params, None, action)
    }

    fn send_call(
        &mut self,
        method: &str,
        params: Value,
        attachment: Option<crate::file_upload::Attachment>,
        action: Call,
    ) -> bool {
        let Some(out) = &self.out else { return false };
        self.request_id = self.request_id.wrapping_add(1);
        let id = self.request_id;
        let mut frame = json!({"jsonrpc":"2.0","id":id,"method":method});
        frame["params"] = params;
        if out
            .send(Outgoing {
                message: frame,
                attachment,
            })
            .is_err()
        {
            return false;
        }
        self.pending.insert(id, action);
        true
    }

    fn attach(&mut self, key: &str, force: bool) {
        if self.out.is_none() {
            return;
        }
        let session = self.sessions.entry(key.to_owned()).or_default();
        if session.loading || session.attached && !force {
            return;
        }
        session.loading = true;
        session.error = None;
        if !force && session.seq > 0 && (self.canonical || session.epoch == self.process_epoch) {
            let id = if session.runtime.is_empty() {
                key
            } else {
                &session.runtime
            };
            let mut params = json!({"session_id":id,"last_seen":session.seq});
            if !session.profile.is_empty() {
                params["profile"] = json!(session.profile);
            }
            if self.canonical {
                params["replay_epoch"] = json!(session.epoch);
            }
            if self.call("session.events.since", params, Call::Replay(key.to_owned())) {
                return;
            }
        }
        self.resume(key, force);
    }

    fn resume(&mut self, key: &str, authoritative: bool) {
        let saved_profile = self.workspace().and_then(|workspace| {
            workspace
                .tabs
                .iter()
                .chain(&workspace.closed_tabs)
                .find(|tab| tab.session.as_deref() == Some(key) && !tab.profile.is_empty())
                .map(|tab| tab.profile.clone())
        });
        let session = self.sessions.entry(key.to_owned()).or_default();
        let paged = !session.history_rest_unavailable;
        let mut params = hermes_client_core::resume(self.canonical, key, paged);
        if let Some(summary) = self
            .rows
            .iter()
            .find(|row| row.id == key)
            .filter(|row| !row.profile.is_empty())
        {
            session.profile = summary.profile.clone();
        } else if session.profile.is_empty()
            && let Some(profile) = saved_profile
        {
            session.profile = profile;
        }
        if !session.profile.is_empty() {
            params["profile"] = json!(session.profile);
        }
        let call = Call::Resume {
            key: key.to_owned(),
            refresh_history: authoritative,
            paged,
        };
        if !self.call("session.resume", params, call) {
            self.sessions.get_mut(key).unwrap().loading = false;
        }
    }

    fn apply_update(&mut self, update: Update, window: &mut Window, cx: &mut Context<Self>) {
        match update {
            Update::SignIn(url) => {
                self.login_url = Some(url);
                self.status = "等待登录";
            }
            Update::Online {
                out,
                canonical,
                clarify_batch,
                epoch,
                version,
            } => {
                self.out = Some(out);
                for session in self.sessions.values_mut() {
                    session.history_rest_unavailable = false;
                }
                self.gateway_version = version;
                self.refresh_slash_connection(cx);
                self.refresh_reference_connection(cx);
                self.login_url = None;
                self.canonical = canonical;
                self.clarify_batch = clarify_batch;
                self.process_epoch = epoch;
                self.status = "已连接";
                self.reveal_selected_tab();
                self.load_profiles(window, cx);
                self.fetch_list(0, false, window, cx);
                self.sync_cron(window, cx);
                self.refresh_open_profile_unread(cx);
                self.refresh_display_preferences(cx);
                self.refresh_selection_status(cx);
                self.start_work_monitor(window, cx);
                let mut keys: Vec<_> = self
                    .sessions
                    .iter()
                    .filter(|(_, session)| {
                        session.running || session.uncertain || !session.prompts.is_empty()
                    })
                    .map(|(key, _)| key.clone())
                    .collect();
                if let Some(workspace) = self.workspace() {
                    keys.extend(workspace.followups.keys().cloned());
                    keys.sort();
                    keys.dedup();
                }
                if let Some(key) = &self.selected {
                    if !keys.contains(key) {
                        keys.insert(0, key.clone());
                    }
                }
                if let Some(key) = self.selected.clone() {
                    self.prefetch_history(&key, cx);
                }
                for key in keys {
                    self.attach(&key, false);
                }
            }
            Update::Offline { reason, retry } => {
                self.voice_socket_offline(retry, cx);
                self.voice_wake = Default::default();
                self.login_url = None;
                self.gateway_version = None;
                self.model_controls.picker = None;
                self.status = if retry { "正在重连" } else { "未连接" };
                self.out = None;
                self.work_monitor = activity::WorkMonitor::default();
                self.busy_input = BusyInput::default();
                self.unread_sessions.clear();
                self.unbound.clear();
                self.list_job = None;
                self.refreshing = false;
                for session in self.sessions.values_mut() {
                    session.activity = Default::default();
                    session.upload = None;
                    session.uploading_draft_file = None;
                    session.waiting_for_draft_upload = false;
                    session.loading = false;
                    session.submitting = false;
                    session.attached = false;
                    session.parked.clear();
                }
                for (_, call) in std::mem::take(&mut self.pending) {
                    self.lost(call, false);
                }
                if !retry {
                    self.banner = Some(reason.into());
                }
            }
            Update::Frame(frame) => self.frame(frame, window, cx),
            Update::AttachmentCancelled(id) => {
                self.pending.remove(&id);
            }
            Update::Timeout(id) => match self.pending.remove(&id) {
                Some(Call::ModelOptions(scope, request)) => {
                    self.fallback_model_options(scope, request, cx);
                }
                Some(call) => self.lost(call, true),
                None => {}
            },
        }
    }

    fn refresh_display_preferences(&mut self, cx: &mut Context<Self>) {
        let Some(gateway) = self.gateway.clone().filter(|_| self.out.is_some()) else {
            return;
        };
        let address = gateway.url.clone();
        let owner = self.active_profile().to_owned();
        let config_revision = self.reasoning_config_revision;
        let query = (!owner.is_empty()).then(|| [("profile", owner.clone())]);
        let request = self.runtime.spawn(async move {
            let config = gateway
                .api(
                    reqwest::Method::GET,
                    "api/config",
                    query.as_ref().map_or(&[], |p| p.as_slice()),
                    None,
                )
                .await?;
            Ok::<_, anyhow::Error>((
                crate::reasoning::Display::from_config(&config),
                model_controls::defaults_from_config(&config),
            ))
        });
        cx.spawn(async move |view, cx| {
            if let Ok(Ok((display, defaults))) = request.await {
                let _ = view.update(cx, |this, cx| {
                    if this
                        .gateway
                        .as_ref()
                        .is_none_or(|gateway| gateway.url != address)
                    {
                        return;
                    }
                    if this.reasoning_config_revision == config_revision {
                        this.gateway_reasoning.insert(owner.clone(), display);
                    }
                    if this.active_profile() != owner {
                        return;
                    }
                    this.model_controls.defaults = defaults;
                    if this
                        .shown_model()
                        .is_some_and(|model| session_status::is_codex(&model.provider))
                    {
                        this.load_codex_usage(false, cx);
                    }
                    this.apply_reasoning_visibility();
                    cx.notify();
                });
            }
        })
        .detach();
    }

    fn lost(&mut self, call: Call, timeout: bool) {
        match call {
            Call::Create { .. } => {
                self.banner = Some(tr("未收到新会话确认，草稿已保留").into());
            }
            Call::Branch { .. } => {
                self.banner = Some(tr("未收到分叉确认，可以通过原会话菜单重试").into());
            }
            Call::Rewrite(key, id) => self.lost_rewrite(&key, &id),
            Call::SlashSuggestions(lookup) => self.slash_lookup_failed(&lookup),
            Call::CatalogSlash(scope, command) => {
                self.slash_result(scope, command, &Value::Null, None)
            }
            Call::SkillDispatch(key, _) => {
                self.attachment_failed(&key, tr("未收到技能请求确认").into());
            }
            Call::ModelChange(key) => {
                self.clear_model_setting(&key);
                self.banner = Some(tr("未收到模型设置确认，可以重试").into());
            }
            Call::ReasoningDisplay(_) => {
                self.banner = Some(tr("未收到思考显示设置的确认").into());
            }
            Call::WorkStatus(request) => self.finish_work(request, &Value::Null, None),
            Call::WorkRoster(profile) => self.finish_work_roster(&profile, &Value::Null, None),
            Call::ModelOptions(scope, request) => self.cancel_model_options(&scope, request),
            Call::ApprovalMode(profile, write) => self.lose_approval_mode(&profile, write),
            Call::GatewayInference => self.finish_gateway_inference(None),
            Call::VoiceWake(request) => self.voice_wake_lost(request),
            Call::WakeFeed(ack) => { let _ = ack.send(false); }
            Call::SetVoiceEngine(profile, _) => self.voice_engine_lost(&profile),
            Call::AttachFile(key, job, staged, cancel) => {
                if cancel.is_cancelled() {
                    if let (Some(staged), Some(gateway)) = (staged, self.gateway.clone()) {
                        self.runtime.spawn(staged.remove(gateway));
                    }
                } else {
                    self.lose_attachment(&key, &job, tr("未收到附件上传确认").into());
                }
            }
            Call::Submit(key, _) | Call::CorrectTurn(key, _) => {
                if let Some(session) = self.sessions.get_mut(&key) {
                    session.submitting = false;
                    session.uncertain = true;
                    session.error = Some(tr("未收到发送确认").into());
                }
                if timeout {
                    self.attach(&key, true);
                }
            }
            Call::Replay(key) if timeout => self.resume(&key, true),
            Call::RunningReplay(key, _) => self.end_attach(&key),
            Call::Resume { key, .. } | Call::Replay(key) => {
                if let Some(session) = self.sessions.get_mut(&key) {
                    session.loading = false;
                    if timeout {
                        session.error = Some(tr("读取会话超时").into());
                    }
                }
            }
            Call::Stop(_) | Call::Answer(_, _) | Call::Resolve(_, _) if timeout => {
                self.banner = Some(tr("未收到网关确认").into())
            }
            Call::CancelQueued(key, _) if timeout => {
                self.banner = Some(tr("未收到撤回确认").into());
                self.attach(&key, true);
            }
            Call::ReplaceQueued(key, id, submission) => {
                self.replace_queued_lost(&key, &id, &submission, timeout);
            }
            _ => {}
        }
    }

    fn frame(&mut self, frame: Value, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(id) = frame["id"].as_u64().filter(|_| frame["method"].is_null()) {
            if let Some(call) = self.pending.remove(&id) {
                self.response(call, &frame, window, cx);
            }
            if !self.pending.values().any(|call| {
                matches!(
                    call,
                    Call::Create { .. } | Call::Branch { .. } | Call::Resume { .. }
                )
            }) {
                self.unbound.clear();
            }
            return;
        }
        if frame["method"] == "event" {
            let event = &frame["params"];
            let sid = string(event, "session_id");
            let kind = string(event, "type");
            if kind == "wake.detected" {
                self.voice_wake_detected(event, window, cx);
                return;
            }
            if kind == "cron.changed"
                && self.cron_visible()
                && event["profile"]
                    .as_str()
                    .is_none_or(|profile| profile == self.cron.profile)
            {
                self.refresh_cron_jobs(cx);
                if self.cron.open {
                    self.refresh_cron_runs(cx);
                }
            }
            if matches!(
                kind,
                "sessions.changed" | "session.title" | "session.updated"
            ) && !self.refreshing
            {
                self.fetch_list(0, true, window, cx);
            }
            if matches!(
                kind,
                "sessions.changed" | "session.updated" | "message.complete"
            ) {
                let key = self.aliases.get(sid).map_or(sid, String::as_str);
                let profile = event["profile"]
                    .as_str()
                    .filter(|name| !name.is_empty())
                    .or_else(|| {
                        self.sessions
                            .get(key)
                            .map(|session| session.profile.as_str())
                            .filter(|name| !name.is_empty())
                    })
                    .unwrap_or_else(|| self.active_profile())
                    .to_owned();
                self.refresh_unread_sessions(profile, cx);
            }
            if kind == "sessions.changed" {
                self.check_open_transcript(true, cx);
            }
            if sid.is_empty() {
                return;
            }
            let key = self
                .aliases
                .get(sid)
                .cloned()
                .unwrap_or_else(|| sid.to_owned());
            let Some(session) = self.sessions.get_mut(&key) else {
                if self.pending.values().any(|call| {
                    matches!(
                        call,
                        Call::Resume { .. } | Call::Branch { .. } | Call::Create { .. }
                    )
                }) {
                    self.unbound
                        .entry(sid.to_owned())
                        .or_default()
                        .push(event.clone());
                }
                return;
            };
            if matches!(kind, "session.replay_gap" | "session.reclaimed") {
                session.attached = false;
                session.seq = 0;
                self.attach(&key, true);
                return;
            }
            if session.loading {
                session.parked.push(event.clone());
                return;
            }
            let epoch = string(event, "replay_epoch");
            if !epoch.is_empty() && !session.epoch.is_empty() && session.epoch != epoch {
                session.parked.push(event.clone());
                session.seq = 0;
                self.attach(&key, true);
                return;
            }
            let was_running = session.running;
            let old_seq = session.seq;
            session.apply(event);
            let peer_prompt = (!self.canonical && kind == "message.start" && session.seq > old_seq)
                .then(|| session.missing_prompt_sequence().map(|seq| (session.runtime.clone(), session.profile.clone(), seq)))
                .flatten();
            let completed = was_running && !session.running && kind == "message.complete";
            let refresh = session.refresh && !session.submitting;
            if refresh {
                session.refresh = false;
            }
            if let Some((runtime, profile, sequence)) = peer_prompt {
                self.call("session.activate", json!({"session_id": runtime, "profile": profile, "omit_messages": true}),
                    Call::PeerPrompt { key: key.clone(), runtime, sequence });
            }
            if kind == "message.complete" {
                self.finish_voice_turn(&key, &event["payload"]);
                if completed {
                    self.read_voice_reply(&key, &event["payload"], cx);
                }
            }
            if kind == "message.complete"
                && self.files.collection.open
                && self.selected.as_deref() == Some(&key)
            {
                self.show_session_files(cx)
            }
            if completed && self.settings.display.alert_replies && !window.is_window_active() {
                self.desktop_alert(&key, desktop_alerts::Alert::Reply, window, cx);
            }
            let payload = &event["payload"];
            if (kind == "tool.complete"
                && matches!(string(payload, "name"), "terminal" | "process"))
                || kind == "status.update" && payload["kind"] == "process"
            {
                self.refresh_work(&key, WorkKind::Processes, true);
            }
            if kind == "message.complete"
                && let Some(id) = event["payload"]["persisted_turn"]["submission_id"].as_str()
                && self
                    .workspace()
                    .and_then(|workspace| workspace.pending_submissions.get(&key))
                    .is_some_and(|prepared| prepared.id == id)
            {
                self.accept_draft(&key, window, cx);
            }
            if matches!(kind, "message.start" | "message.complete")
                && self.selected.as_deref() == Some(&key)
            {
                self.transcript_changed(cx);
            }
            if refresh {
                self.attach(&key, true);
                if !self.refreshing {
                    self.fetch_list(0, true, window, cx);
                }
            }
            if matches!(
                kind,
                "session.info" | "session.updated" | "message.complete"
            ) {
                self.apply_ready_model_preset(&key, cx);
            }
            return;
        }
        if !frame["id"].is_null() && frame["method"].is_string() {
            let sid = string(&frame["params"], "session_id");
            let key = self.aliases.get(sid).map_or(sid, String::as_str);
            if matches!(string(&frame, "method"), "approval" | "clarify") {
                if let Some(session) = self.sessions.get_mut(key) {
                    if session.loading {
                        session.parked.push(frame);
                    } else {
                        session.server_request(&frame);
                    }
                } else if self.pending.values().any(|call| {
                    matches!(
                        call,
                        Call::Resume { .. } | Call::Branch { .. } | Call::Create { .. }
                    )
                }) {
                    self.unbound.entry(sid.to_owned()).or_default().push(frame);
                }
            } else if let Some(out) = &self.out {
                let _ = out.send(json!({"jsonrpc":"2.0","id":frame["id"],"error":{"code":-32601,"message":"Unsupported client request"}}).into());
            }
        }
    }

    fn response(&mut self, call: Call, frame: &Value, window: &mut Window, cx: &mut Context<Self>) {
        let response = &frame["result"];
        let error = frame.get("error").filter(|value| !value.is_null());
        match call {
            Call::Create {
                draft,
                request,
                profile,
                draft_upload,
            } => self.created(draft, request, profile, draft_upload, response, error, window, cx),
            Call::Branch {
                target,
                through,
                origin_tab,
            } => {
                self.finish_branch(target, through, origin_tab, response, error, window, cx);
            }
            Call::ModelChange(key) => self.finish_model_setting(key, response, error, cx),
            Call::VoiceWake(request) => self.voice_wake_result(request, response, error, cx),
            Call::WakeFeed(ack) => { let _ = ack.send(error.is_none() && response["fed"] == true); }
            Call::SetVoiceEngine(profile, engine) => self.voice_engine_saved(&profile, engine, error, cx),
            Call::WorkStatus(request) => self.finish_work(request, response, error),
            Call::WorkRoster(profile) => self.finish_work_roster(&profile, response, error),
            Call::ReasoningDisplay(scope) => {
                if let Some(error) = error {
                    self.banner = Some(rpc_error(error).into());
                } else {
                    let value = string(response, "value");
                    let profile = scope.profile;
                    self.reasoning_config_revision = self.reasoning_config_revision.wrapping_add(1);
                    self.gateway_reasoning
                        .entry(profile.clone())
                        .or_default()
                        .update(value);
                    if self.active_profile() == profile {
                        use crate::settings::ReasoningVisibility;
                        if matches!(
                            (value, self.settings.display.reasoning),
                            ("show", ReasoningVisibility::Hidden)
                                | ("hide", ReasoningVisibility::Visible)
                        ) {
                            self.settings.display.reasoning = ReasoningVisibility::Gateway;
                            self.persist(cx);
                        }
                        self.apply_reasoning_visibility();
                    }
                    if !value.is_empty() {
                        self.store_slash_output(
                            scope.draft,
                            "reasoning".into(),
                            format!("reasoning: {value}"),
                        );
                    }
                    cx.notify();
                }
            }
            Call::ModelOptions(scope, request) => {
                self.finish_model_options(scope, request, response, error, cx)
            }
            Call::ModelTiers(key, model) if error.is_none() => {
                self.finish_model_tiers(key, model, response)
            }
            Call::ModelTiers(_, _) => {}
            Call::ApprovalMode(profile, write) => {
                self.finish_approval_mode(profile, write, response, error)
            }
            Call::GatewayInference => self.finish_gateway_inference(
                error.is_none().then(|| response["ok"].as_bool()).flatten(),
            ),
            Call::ContextUsage(key, generation, seq) => {
                if error.is_none()
                    && let Some(session) = self.sessions.get_mut(&key)
                    && session.generation == generation
                    && session.seq == seq
                    && !session.running
                {
                    session.update_context(response);
                }
            }
            Call::Rewrite(key, id) => self.rewrite_response(&key, &id, response, error, cx),
            Call::SlashSuggestions(lookup) => {
                if error.is_none() {
                    self.slash_response(lookup, response, cx);
                } else {
                    self.slash_lookup_failed(&lookup);
                }
            }
            Call::CatalogSlash(scope, command) => {
                self.slash_result(scope, command, response, error)
            }
            Call::PathSuggestions(lookup) => {
                if error.is_none() {
                    self.reference_response(lookup, response, cx);
                }
            }
            Call::SkillDispatch(key, prepared) => {
                self.finish_skill(key, prepared, response, error, window, cx)
            }
            Call::CancelQueued(key, id) => self.canceled_queued(&key, &id, response, error, cx),
            Call::ReplaceQueued(key, id, submission) => {
                self.replaced_queued(&key, &id, &submission, response, error, window, cx);
            }
            Call::AttachFile(key, job, staged, cancel) => {
                // The associated attachment is durable once the gateway confirms it copied the file.
                if let Some(staged) = staged
                    && (cancel.is_cancelled() || error.is_some() || response["uploaded"] == true && response["path"] != staged.path)
                    && let Some(gateway) = self.gateway.clone()
                {
                    self.runtime.spawn(staged.remove(gateway));
                }
                if !cancel.is_cancelled() {
                    self.file_attached(key, job, response, error, cx);
                }
            }
            Call::CorrectTurn(key, prepared) => {
                self.finish_busy_text(key, prepared, response, error, window, cx);
            }
            Call::Submit(key, prepared) => {
                self.submitted(&key, prepared, response, error, window, cx)
            }
            Call::Replay(key) => {
                let session = self.sessions.get_mut(&key).unwrap();
                let epoch = string(response, "epoch");
                if error.is_none()
                    && response["truncated"] != true
                    && response["snapshot_required"] != true
                    && (self.canonical || epoch.is_empty() || epoch == self.process_epoch)
                {
                    for event in response["events"].as_array().into_iter().flatten() {
                        session.apply(event);
                    }
                    for request in response["open_requests"].as_array().into_iter().flatten() {
                        session.server_request(request);
                    }
                } else {
                    session.seq = 0;
                }
                self.resume(&key, true);
            }
            Call::Resume {
                key,
                refresh_history,
                paged,
            } => {
                if self.selected.as_deref() == Some(&key)
                    && self.pending_reading.is_none()
                    && error.is_none()
                    && !string(response, "session_id").is_empty()
                {
                    self.pending_reading = self.reading_position();
                }
                self.resumed(&key, response, error, window, cx);
                if error.is_none()
                    && (response["messages_omitted"] == true || response["hydrating"] == true)
                {
                    if paged && self.sessions[&key].history_rest_unavailable {
                        self.attach(&key, true);
                    } else if refresh_history {
                        self.history_reads.remove(&key);
                        self.read_history_page(&key, false, cx);
                    } else {
                        self.prefetch_history(&key, cx);
                    }
                    self.confirm_history_receipts(&key, window, cx);
                }
                if error.is_none() {
                    self.drain_followups(&key, cx);
                    self.start_eager_attachment(&key, cx);
                    self.apply_ready_model_preset(&key, cx);
                    if self.selected.as_deref() == Some(&key) {
                        self.refresh_context_usage(&key);
                        if self
                            .shown_model()
                            .is_some_and(|model| session_status::is_codex(&model.provider))
                        {
                            self.load_codex_usage(false, cx);
                        }
                    }
                }
                if self.selected.as_deref() == Some(&key) {
                    self.references_changed(cx);
                    self.refresh_files_scope(cx);
                    self.refresh_review_scope(cx);
                    self.timeline_raw_count = None;
                    self.transcript_changed(cx);
                }
            }
            Call::PeerPrompt { key, runtime, sequence } => {
                if error.is_none() && response["session_id"] == runtime
                    && let Some(s) = self.sessions.get_mut(&key)
                    && s.runtime == runtime && !s.loading
                {
                    let inflight = &response["inflight"];
                    s.supply_turn_prompt(sequence, string(inflight, "user"), inflight);
                    if self.selected.as_ref() == Some(&key) {
                        self.transcript_changed(cx);
                    }
                }
            }
            Call::CheckTurn { key, runtime, seq } => {
                let Some(session) = self.sessions.get(&key).filter(|s|
                    s.runtime == runtime && s.seq == seq && !s.loading && !s.submitting
                        && !s.uncertain && s.error.is_none()
                ) else { return };
                let Some(rows) = response["sessions"].as_array().filter(|_| error.is_none()) else { return };
                let row = rows.iter().find(|row| row["id"] == runtime);
                if row.is_none_or(|r| r["status"] == "idle")
                    || row.is_some_and(|r| r["status"] == "waiting" && session.prompts.is_empty())
                {
                    self.attach(&key, true);
                } else if session.running && session.prompts.is_empty() {
                    let mut params = json!({"session_id": runtime, "profile": session.profile, "last_seen": seq});
                    if self.canonical {
                        params["replay_epoch"] = json!(session.epoch);
                    }
                    self.call("session.events.since", params, Call::CheckReplay { key, runtime, seq });
                }
            }
            Call::CheckReplay { key, runtime, seq } => {
                if error.is_none() && self.sessions.get(&key).is_some_and(|s|
                    s.runtime == runtime && s.seq == seq && !s.loading && !s.submitting
                ) && (response["snapshot_required"] == true || response["truncated"] == true
                    || response["events"].as_array().is_some_and(|events| !events.is_empty()))
                {
                    self.attach(&key, true);
                }
            }
            Call::RunningReplay(key, through) => {
                let session = self.sessions.get_mut(&key).unwrap();
                session.recover_running(response, through);
                self.end_attach(&key);
                self.refresh_slash_scope(cx);
                self.drain_followups(&key, cx);
                if self.selected.as_deref() == Some(&key) {
                    self.refresh_files_scope(cx);
                    self.refresh_review_scope(cx);
                    self.timeline_raw_count = None;
                    self.transcript_changed(cx);
                }
            }
            Call::Stop(key) => {
                if let Some(error) = error {
                    self.sessions.get_mut(&key).unwrap().error = Some(rpc_error(error));
                }
            }
            Call::Answer(key, prompt) => {
                let session = self.sessions.get_mut(&key).unwrap();
                if let Some(error) = error {
                    session.error = Some(rpc_error(error));
                } else {
                    session.prompts.remove(&prompt);
                }
            }
            Call::Resolve(key, admission) => {
                let session = self.sessions.get_mut(&key).unwrap();
                if let Some(error) = error {
                    session.error = Some(rpc_error(error));
                } else {
                    session.unknown.remove(&admission);
                    self.attach(&key, true);
                }
            }
        }
    }

    fn resumed(
        &mut self,
        key: &str,
        response: &Value,
        error: Option<&Value>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let session = self.sessions.get_mut(key).unwrap();
        if error.is_some() || string(response, "session_id").is_empty() {
            session.loading = false;
            session.attached = false;
            session.error = Some(match error {
                Some(error) if error["code"] == 4130 => {
                    tr("会话记录超过恢复上限。可查看历史，或新建会话继续。").into()
                }
                Some(error) => rpc_error(error),
                None => tr("无法读取会话").into(),
            });
            return;
        }
        let keep = self.canonical
            && session.running
            && session.seq > 0
            && response["running"] == true
            && string(response, "replay_epoch") == session.epoch
            && response["execution_generation"].as_u64() == Some(session.generation);
        let old_runtime = session.runtime.clone();
        session.replace_snapshot(response, self.canonical, keep);
        if old_runtime != session.runtime && !old_runtime.is_empty() {
            self.aliases.remove(&old_runtime);
        }
        if response["messages_omitted"] != true && response["hydrating"] != true {
            self.history_reads.remove(key);
            session.history_error = None;
        }
        self.media.retry_failed_thumbnails(key);
        if !self.canonical {
            if session.epoch != self.process_epoch || old_runtime != session.runtime {
                session.seq = 0;
            }
            session.epoch = self.process_epoch.clone();
        }
        self.aliases.insert(session.runtime.clone(), key.to_owned());
        session
            .parked
            .extend(self.unbound.remove(&session.runtime).unwrap_or_default());
        let through = session.seq;
        let running_replay = self.canonical && !keep && session.running && through > 0;
        let params =
            json!({"session_id":session.runtime,"replay_epoch":session.epoch,"last_seen":0});
        let prepared = self
            .workspace()
            .and_then(|workspace| workspace.pending_submissions.get(key))
            .cloned();
        if let Some(prepared) = prepared.filter(|prepared| !prepared.staging) {
            let admitted = response["pending"]
                .as_array()
                .into_iter()
                .flatten()
                .any(|item| item["input_id"] == prepared.id || item["admission_id"] == prepared.id)
                || response["messages"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .any(|row| {
                        row["submission_id"] == prepared.id || row["admission_id"] == prepared.id
                    });
            if admitted {
                self.accept_draft(key, window, cx);
            }
            self.sessions.get_mut(key).unwrap().uncertain = !admitted;
        }
        self.settle_rewrite_snapshot(key, response, cx);
        if running_replay
            && self.call(
                "session.events.since",
                params,
                Call::RunningReplay(key.to_owned(), through),
            )
        {
            return;
        }
        self.end_attach(key);
        self.refresh_slash_scope(cx);
    }

    fn end_attach(&mut self, key: &str) {
        let session = self.sessions.get_mut(key).unwrap();
        session.loading = false;
        for frame in std::mem::take(&mut session.parked) {
            if frame["method"].is_string() {
                session.server_request(&frame);
            } else if string(&frame, "replay_epoch").is_empty()
                || frame["replay_epoch"] == session.epoch
            {
                session.apply(&frame);
            }
        }
        if session.refresh {
            session.refresh = false;
            self.attach(key, true);
        } else if self.selected.as_deref() == Some(key) {
            for kind in WorkKind::ALL {
                self.refresh_work(key, kind, true);
            }
        }
    }

    fn send(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.out.is_none()
            || self.rewrite_editor.is_some()
            || self.creating()
            || self.clipboard_loading()
            || self.model_controls.busy.contains(&self.key())
        {
            return;
        }
        let text = self.composer.update(cx, |field, cx| {
            use gpui::EntityInputHandler;
            field
                .marked_text_range(window, cx)
                .is_none()
                .then(|| field.value().to_string())
        });
        let Some(text) = text else { return };
        if self.reference_is_open(window, cx) {
            self.choose_reference(None, window, cx);
            return;
        }
        if self.complete_slash_before_send(&text, window, cx)
            || self.run_local_command(&text, window, cx)
        {
            return;
        }
        let files = self.draft_files();
        if text.trim().is_empty() && files.is_empty() {
            return;
        }
        let skill = self.skill_command(&text);
        if self.voice.is_conversation() && crate::voice::spoken_stop(&text) && files.is_empty() {
            self.end_voice();
            self.resume_voice_wake();
            self.composer.update(cx, |input, cx| input.set_value("", window, cx));
            cx.notify();
            return;
        }
        if self.voice.is_conversation() {
            self.end_voice();
        }
        self.send_text(text, files, skill, None, window, cx);
    }

    fn send_text(
        &mut self,
        text: String,
        files: Vec<std::path::PathBuf>,
        skill: Option<crate::settings::SkillSubmission>,
        voice: Option<voice_view::Delegation>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.busy_input_saving() {
            return;
        }
        let Some(key) = self.selected.clone() else {
            let draft = self.key();
            let profile = self.active_profile().to_owned();
            let launch = self
                .workspace()
                .and_then(|workspace| {
                    workspace
                        .pending_submissions
                        .get(&draft)
                        .map(|pending| pending.launch.clone())
                        .or_else(|| workspace.draft_launch.get(&draft).cloned())
                })
                .unwrap_or_default();
            let request = self
                .workspace()
                .and_then(|workspace| workspace.pending_submissions.get(&draft))
                .map(|prepared| prepared.id.clone())
                .unwrap_or_else(|| Uuid::new_v4().to_string());
            self.voice.expect_turn(&draft, &request, voice);
            let legacy = !self.canonical;
            self.workspace_mut().pending_submissions.insert(
                draft.clone(),
                Prepared {
                    id: request.clone(),
                    text,
                    legacy,
                    launch: launch.clone(),
                    staging: true,
                    files,
                    file_refs: Vec::new(),
                    pictures: Default::default(),
                    picture_urls: Default::default(),
                    skill,
                    queued: false,
                },
            );
            self.persist(cx);
            self.create_chat(draft, request, profile, launch, false);
            cx.notify();
            return;
        };
        let Some(session) = self.sessions.get(&key) else {
            return;
        };
        if !session.attached || session.loading || session.submitting {
            return;
        }
        let running = session.running;
        if self
            .workspace()
            .is_some_and(|workspace| workspace.pending_rewrites.contains_key(&key))
        {
            return;
        }
        let force_queue = running && (!files.is_empty() || skill.is_some() || !session.prompts.is_empty() || voice.is_some());
        if self.has_followups(&key) || force_queue && !self.canonical {
            let followup = Prepared {
                id: Uuid::new_v4().to_string(),
                text,
                legacy: false,
                launch: LaunchOptions::default(),
                staging: true,
                files,
                file_refs: Vec::new(),
                pictures: Default::default(),
                picture_urls: Default::default(),
                skill,
                queued: true,
            };
            self.enqueue_followup(&key, followup, window, cx);
            return;
        }
        let prior = self
            .workspace()
            .and_then(|workspace| workspace.pending_submissions.get(&key))
            .cloned();
        let fresh_busy_text = running && !force_queue && prior.is_none();
        let prepared = match prior {
            Some(prior)
                if (prior.staging || !prior.legacy)
                    && prior.text == text
                    && prior.files == files =>
            {
                prior
            }
            Some(mut prior) if prior.staging => {
                let unchanged = prior
                    .files
                    .iter()
                    .zip(&files)
                    .take_while(|(old, new)| old == new)
                    .count();
                prior.file_refs.truncate(unchanged);
                prior.pictures.retain(|index, _| *index < unchanged);
                prior.picture_urls.retain(|index, _| *index < unchanged);
                prior.files = files;
                prior.text = text;
                prior.skill = skill;
                prior.queued |= running;
                prior
            }
            Some(_) => {
                self.banner = Some(tr("上一条发送尚未确认，请先处理待确认消息").into());
                cx.notify();
                return;
            }
            None => Prepared {
                id: Uuid::new_v4().to_string(),
                text,
                legacy: false,
                launch: LaunchOptions::default(),
                staging: !files.is_empty() || skill.is_some(),
                files,
                file_refs: Vec::new(),
                pictures: Default::default(),
                picture_urls: Default::default(),
                skill,
                queued: force_queue,
            },
        };
        if self.canonical && fresh_busy_text {
            self.send_busy_text(key, prepared, cx);
            cx.notify();
            return;
        }
        self.voice.expect_turn(&key, &prepared.id, voice);
        self.start_submission(key, prepared, cx);
        self.sync_list();
        cx.notify();
    }

    fn create_chat(&mut self, draft: String, request: String, profile: String, launch: LaunchOptions, draft_upload: bool) {
        let mut params = hermes_client_core::create(self.canonical, &request);
        if !profile.is_empty() {
            params["profile"] = json!(profile);
        }
        if let Some(model) = launch.model {
            params["model"] = json!(model.id);
            if !model.provider.is_empty() {
                params["provider"] = json!(model.provider);
            }
        }
        if let Some(effort) = launch.effort {
            params[if self.canonical { "reasoning" } else { "reasoning_effort" }] = json!(effort);
        }
        if let Some(speed) = launch.speed {
            if !self.canonical {
                params["fast"] = json!(speed != "normal");
            }
            if self.canonical || speed == "ultrafast" {
                params["service_tier"] = json!(speed);
            }
        }
        self.call("session.create", params, Call::Create { draft, request, profile, draft_upload });
    }

    fn created(
        &mut self,
        draft: String,
        request: String,
        profile: String,
        draft_upload: bool,
        response: &Value,
        error: Option<&Value>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let runtime = string(response, "session_id");
        if error.is_some() || runtime.is_empty() {
            self.voice.fail_submission(&draft, &request);
            self.banner = Some(
                error
                    .map_or_else(|| tr("未能创建会话").into(), rpc_error)
                    .into(),
            );
            return;
        }
        let key = response["stored_session_id"]
            .as_str()
            .filter(|id| !id.is_empty())
            .unwrap_or(runtime)
            .to_owned();
        let prepared = if draft_upload {
            if self.draft_key_for_tab(&draft).as_deref() != Some(draft.as_str()) {
                return;
            }
            None
        } else {
            let workspace = self.workspace_mut();
            if workspace.pending_submissions.get(&draft).is_none_or(|prepared| prepared.id != request) {
                return;
            }
            workspace.pending_submissions.remove(&draft)
        };
        self.workspace_mut().draft_launch.remove(&draft);
        let mut session = Session::default();
        session.replace_snapshot(response, self.canonical, false);
        session.awaiting_first_history = true;
        let profile = if profile.is_empty() {
            response["info"]["profile"]
                .as_str()
                .filter(|name| !name.is_empty())
                .unwrap_or(&self.profiles.serving)
                .to_owned()
        } else {
            profile
        };
        session.profile.clone_from(&profile);
        if !self.canonical {
            session.epoch = self.process_epoch.clone();
        }
        session
            .parked
            .extend(self.unbound.remove(runtime).unwrap_or_default());
        self.sessions.insert(key.clone(), session);
        self.end_attach(&key);
        self.aliases.insert(runtime.to_owned(), key.clone());
        let Some(prepared) = prepared else {
            self.bind_created_tab(&draft, &key, tr("新会话"), "", window, cx);
            self.persist(cx);
            self.start_eager_attachment(&key, cx);
            return;
        };
        let title: String = prepared
            .text
            .lines()
            .find(|line| !line.trim().is_empty())
            .or_else(|| prepared.files.first()?.file_name()?.to_str())
            .unwrap_or(tr("新会话"))
            .chars()
            .take(45)
            .collect();
        self.insert_profile_session(Summary {
            id: key.clone(),
            title: title.clone().into(),
            pinned: false,
            archived: false,
            unread: false,
            profile,
            updated_at: chrono::Utc::now().timestamp(),
            lineage_root: String::new(),
            branch_parent: String::new(),
        });
        self.bind_created_tab(&draft, &key, &title, &prepared.text, window, cx);
        let prepared = Prepared {
            id: Uuid::new_v4().to_string(),
            legacy: false,
            launch: LaunchOptions::default(),
            ..prepared
        };
        self.voice.promote_turn(&draft, &request, &key, &prepared.id);
        self.start_submission(key, prepared, cx);
    }

    fn submit(&mut self, key: String, prepared: Prepared, cx: &mut Context<Self>) {
        if !self.canonical && !prepared.pictures.is_empty() {
            self.submit_legacy_pictures(key, prepared, cx);
        } else {
            self.submit_wire(key, prepared, Vec::new(), cx);
        }
    }

    fn submit_wire(
        &mut self,
        key: String,
        mut prepared: Prepared,
        legacy_pictures: Vec<String>,
        cx: &mut Context<Self>,
    ) {
        prepared.staging = false;
        let wire_text = prepared.wire_text();
        self.workspace_mut()
            .pending_submissions
            .insert(key.clone(), prepared.clone());
        if prepared.queued {
            if let Err(error) = self.settings.save() {
                if let Some(record) = self.workspace_mut().pending_submissions.get_mut(&key) {
                    record.staging = true;
                }
                self.attachment_failed(
                    &key,
                    crate::i18n::format_text!(
                        "无法保存待发送消息 · {error}",
                        "Could not save the pending message · {error}"
                    ),
                );
                cx.notify();
                return;
            }
        } else {
            self.persist(cx);
        }
        let session = self.sessions.get_mut(&key).unwrap();
        let mut params = json!({"session_id":session.runtime,"text":wire_text});
        if let Some(context) = self.voice.context_for(&key, &prepared.id) {
            params["voice_context"] = json!(context);
            params["surface"] = json!("voice-live");
        }
        if self.voice.owns_turn(&key, &prepared.id) && params["voice_context"].is_null() {
            params["voice_turn"] = json!(true);
        }
        if !legacy_pictures.is_empty() {
            params["text"] = crate::media::vision_prompt(&wire_text, legacy_pictures);
        } else if self.canonical && !prepared.pictures.is_empty() {
            params["attachments"] = json!(prepared.pictures.values().collect::<Vec<_>>());
        }
        if !session.profile.is_empty() {
            params["profile"] = json!(session.profile);
        }
        if !prepared.legacy {
            params["submission_id"] = json!(prepared.id);
        }
        if self.clarify_batch {
            params["clarify_batch"] = json!(true);
        }
        if prepared.queued {
            params["queued"] = json!(true);
        }
        session.submitting = true;
        session.uncertain = false;
        session.error = None;
        session.turn_error = None;
        if !prepared.queued
            && !matches!(session.live.last(), Some(Row::User(text)) if text.raw().as_ref() == wire_text)
        {
            let row = if prepared.skill.is_some() {
                crate::media::Message::user_with_display(
                    wire_text.clone().into(),
                    prepared.display_text().into(),
                )
            } else {
                wire_text.clone().into()
            };
            session.live.push(Row::User(row));
        }
        if !self.call(
            "prompt.submit",
            params,
            Call::Submit(key.clone(), prepared.clone()),
        ) {
            self.lost(Call::Submit(key.clone(), prepared), false);
        }
        if self
            .selected
            .as_ref()
            .is_some_and(|selected| selected == &key)
        {
            self.sync_list();
        }
    }

    fn submitted(
        &mut self,
        key: &str,
        mut prepared: Prepared,
        response: &Value,
        error: Option<&Value>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let wire_text = prepared.wire_text();
        let session = self.sessions.get_mut(key).unwrap();
        session.submitting = false;
        if let Some(error) = error {
            let message = string(error, "message");
            if matches!(error["code"].as_i64(), Some(4000 | 4094))
                && !prepared.legacy
                && !self.canonical
                && (message.contains("submission_id") || error["code"] == 4094)
            {
                prepared.legacy = true;
                self.submit(key.to_owned(), prepared, cx);
                return;
            }
            if matches!(error["code"].as_i64(), Some(4000..=4999 | -32602 | -32601)) {
                if !prepared.queued
                    && matches!(session.live.last(), Some(Row::User(text)) if text.raw().as_ref() == wire_text)
                {
                    session.live.pop();
                }
                self.workspace_mut().pending_submissions.remove(key);
                self.persist(cx);
            } else {
                session.uncertain = true;
            }
            self.sessions.get_mut(key).unwrap().error = Some(rpc_error(error));
            return;
        }
        let status = string(response, "status");
        let canonical_receipt = !self.canonical
            || (response["ref"]["session_id"] == session.runtime
                && response["admission_id"].is_string());
        if (status.is_empty() || !canonical_receipt) && response["voice_stopped"] != true {
            session.uncertain = true;
            session.error = Some(tr("网关未返回发送确认").into());
            self.attach(key, true);
            return;
        }
        if status == "queued" {
            if !prepared.queued
                && matches!(session.live.last(), Some(Row::User(text)) if text.raw().as_ref() == wire_text)
            {
                session.live.pop();
            }
            session.record_queue(
                string(response, "admission_id").to_owned(),
                prepared.display_text().into(),
                response["sequence"].as_u64().unwrap_or(u64::MAX),
                false,
            );
        } else if !session.refresh && matches!(status, "started" | "streaming") {
            session.running = true;
            session.generation = response["execution_generation"]
                .as_u64()
                .unwrap_or(session.generation);
        }
        if response["voice_stopped"] == true
            && !prepared.queued
            && matches!(session.live.last(), Some(Row::User(text)) if text.raw().as_ref() == wire_text)
        {
            session.live.pop();
        }
        self.accept_draft(key, window, cx);
        let session = self.sessions.get_mut(key).unwrap();
        if session.refresh
            || matches!(status, "terminal" | "unknown" | "redirected" | "steered" | "queued")
            || response["voice_stopped"] == true
        {
            session.refresh = false;
            self.attach(key, true);
        }
    }

    fn accept_draft(&mut self, key: &str, window: &mut Window, cx: &mut Context<Self>) {
        let Some(prepared) = self.workspace_mut().pending_submissions.remove(key) else {
            return;
        };
        if let Some(session) = self.sessions.get_mut(key) {
            for path in &prepared.files {
                session.staged_draft_files.remove(path);
                session.draft_upload_errors.remove(path);
            }
        }
        if prepared.queued && self.remove_followup_record(key, &prepared.id) {
            self.persist(cx);
            cx.notify();
            return;
        }
        let workspace = self.workspace_mut();
        if let Some(files) = workspace.draft_files.get_mut(key) {
            files.retain(|path| !prepared.files.contains(path));
            if files.is_empty() {
                workspace.draft_files.remove(key);
            }
        }
        let clear = workspace.drafts.get(key) == Some(&prepared.text);
        if clear {
            workspace.drafts.remove(key);
            workspace.draft_skills.remove(key);
        }
        if clear && self.selected.as_deref() == Some(key) {
            self.restore_draft(window, cx);
        }
        self.persist(cx);
    }

    fn stop(&mut self) {
        let Some(key) = self.selected.clone() else {
            return;
        };
        let Some(session) = self
            .sessions
            .get(&key)
            .filter(|session| session.running && session.attached && !session.loading)
        else {
            return;
        };
        let mut params = json!({"session_id":session.runtime});
        if !session.profile.is_empty() {
            params["profile"] = json!(session.profile);
        }
        if self.canonical {
            params["execution_generation"] = json!(session.generation);
        }
        self.call("session.interrupt", params, Call::Stop(key));
    }

    fn resolve_unknown(&mut self, admission: String) {
        let Some(key) = self.selected.clone() else {
            return;
        };
        let session = &self.sessions[&key];
        let Some((generation, _)) = session.unknown.get(&admission) else {
            return;
        };
        self.call("prompt.resolve_unknown", json!({
            "session_id": session.runtime, "admission_id": admission, "execution_generation": generation
        }), Call::Resolve(key, admission));
    }

    fn answer(&mut self, prompt_key: String, choice: String, cx: &mut Context<Self>) {
        let Some(key) = self.selected.clone() else {
            return;
        };
        let Some(session) = self
            .sessions
            .get(&key)
            .filter(|session| session.attached && !session.loading)
        else {
            return;
        };
        let Some(prompt) = session.prompts.get(&prompt_key) else {
            return;
        };
        let mut params = json!({"session_id":session.runtime});
        if !session.profile.is_empty() {
            params["profile"] = json!(session.profile);
        }
        match &prompt.route {
            PromptRoute::Canonical {
                id,
                generation,
                kind,
            } => {
                params["prompt_id"] = json!(id);
                params["execution_generation"] = json!(generation);
                params[if kind == "approval" {
                    "choice"
                } else {
                    "answer"
                }] = json!(choice);
                let method = format!("{kind}.respond");
                self.call(&method, params, Call::Answer(key, prompt_key));
            }
            PromptRoute::LegacyApproval(id) => {
                params["request_id"] = json!(id);
                params["choice"] = json!(choice);
                self.call("approval.respond", params, Call::Answer(key, prompt_key));
            }
            PromptRoute::Request(id) => {
                let result = json!({"choice":choice});
                if let Some(out) = &self.out {
                    if out
                        .send(json!({"jsonrpc":"2.0","id":id,"result":result}).into())
                        .is_ok()
                    {
                        self.sessions
                            .get_mut(&key)
                            .unwrap()
                            .prompts
                            .remove(&prompt_key);
                    }
                }
            }
        }
        cx.notify();
    }

    fn patch_session(
        &mut self,
        id: &str,
        profile: &str,
        patch: Value,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(gateway) = self.gateway.clone().filter(|_| self.out.is_some()) else {
            return;
        };
        let runtime = self.runtime.clone();
        let current = gateway.url.clone();
        let archived = patch["archived"].as_bool();
        let affects_unread =
            archived.is_some() || patch["unread"].is_boolean() || patch["hidden"].is_boolean();
        let key = id.to_owned();
        let request_id = key.clone();
        let profile = profile.to_owned();
        let rename = patch["title"]
            .is_string()
            .then(|| self.rename_request_for(&profile, &key))
            .flatten();
        cx.spawn_in(window, async move |view, cx| {
            let rpc_profile = profile.clone();
            let payload = patch.clone();
            let result = runtime
                .spawn(async move {
                    gateway
                        .patch_session(&request_id, &rpc_profile, payload)
                        .await
                })
                .await
                .map_err(|error| error.to_string())
                .and_then(|result| result.map_err(|error| error.to_string()));
            let _ = view.update_in(cx, |this, window, cx| {
                if this
                    .gateway
                    .as_ref()
                    .is_none_or(|gateway| gateway.url != current)
                {
                    return;
                }
                match result {
                    Ok(_) => {
                        if patch["pinned"] == false {
                            this.forget_pin_position(&profile, &key, cx);
                        }
                        this.patch_profile_rows(&profile, &key, &patch);
                        if let Some(title) = patch["title"].as_str() {
                            this.apply_renamed_tab_title(&profile, &key, title, cx);
                            this.settle_rename(rename, None, window, cx);
                        }
                        if let Some(archived) = archived {
                            if archived
                                && let Some(id) = this.workspace().and_then(|workspace| {
                                    workspace
                                        .tabs
                                        .iter()
                                        .find(|tab| tab.session.as_deref() == Some(key.as_str()))
                                        .map(|tab| tab.id.clone())
                                })
                            {
                                this.close_chat_tabs(&id, TabClose::Current, window, cx);
                            }
                        }
                        if this.active_profile() == profile {
                            this.fetch_list(0, false, window, cx);
                        }
                        if affects_unread {
                            if let Some(unread) = patch["unread"].as_bool() {
                                this.unread_sessions.record(&profile, &key, unread);
                            } else if patch["archived"] == true || patch["hidden"] == true {
                                this.unread_sessions.record(&profile, &key, false);
                            }
                            this.refresh_unread_sessions(profile, cx);
                        }
                    }
                    Err(error) => {
                        if !this.settle_rename(rename, Some(error.clone()), window, cx) {
                            this.banner = Some(error.into());
                        }
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    fn apply_renamed_tab_title(
        &mut self,
        profile: &str,
        id: &str,
        title: &str,
        cx: &mut Context<Self>,
    ) {
        let serving = self.profiles.serving.clone();
        let workspace = self.workspace_mut();
        let mut changed = false;
        for tab in workspace.tabs.iter_mut().chain(&mut workspace.closed_tabs) {
            let owner = if tab.profile.is_empty() {
                &serving
            } else {
                &tab.profile
            };
            if owner == profile && tab.session.as_deref() == Some(id) && tab.title != title {
                tab.title = title.to_owned();
                changed = true;
            }
        }
        if changed {
            self.persist(cx);
        }
    }
}

fn rpc_error(error: &Value) -> String {
    let message = string(error, "message");
    if message.is_empty() {
        tr("网关请求失败").to_owned()
    } else {
        message.to_owned()
    }
}
