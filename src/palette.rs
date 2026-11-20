use crate::i18n::text as tr;

use std::{
    collections::{HashMap, HashSet},
    time::Duration,
};

use gpui::{
    Context, Div, Entity, EntityInputHandler, FocusHandle, ScrollStrategy, SharedString, Stateful,
    Task, UniformListScrollHandle, Window, div, prelude::*, px, rgb, uniform_list,
};
use gpui_component::input::{Input, InputState};

use crate::{
    session::{Summary, compact_preview, string},
    settings::ChatTab,
};

use super::Desktop;

const ROW_HEIGHT: f32 = 29.;

#[derive(Clone, Copy, PartialEq, Eq)]
enum Command {
    New,
    Settings,
    Files,
    Review,
    Find,
    Sidebar,
    Reopen,
}

impl Command {
    fn icon(self) -> &'static str {
        match self {
            Self::New => crate::icons::ADD,
            Self::Settings => crate::icons::SETTINGS,
            Self::Files => crate::icons::FOLDER_OPEN,
            Self::Review => crate::icons::BRANCH,
            Self::Find => crate::icons::SEARCH,
            Self::Sidebar => crate::icons::SIDEBAR_LEFT,
            Self::Reopen => crate::icons::REFRESH,
        }
    }

    fn shortcut(self) -> &'static str {
        let (new, find, reopen) = if cfg!(target_os = "macos") {
            ("⌘N", "⌘F", "⌘⇧T")
        } else {
            ("Ctrl+N", "Ctrl+F", "Ctrl+Shift+T")
        };
        match self {
            Self::New => new,
            Self::Find => find,
            Self::Files => "Ctrl+Shift+E",
            Self::Review => {
                if cfg!(target_os = "macos") {
                    "⌘G"
                } else {
                    "Ctrl+G"
                }
            }
            Self::Reopen => reopen,
            _ => "",
        }
    }
}

#[derive(Clone)]
enum Entry {
    Bookmark(crate::settings::MessageBookmark),
    Command(Command, &'static str),
    Tab(ChatTab),
    Session(Summary, SharedString),
}

impl Entry {
    fn title(&self) -> SharedString {
        match self {
            Self::Bookmark(mark) => mark.excerpt.clone().into(),
            Self::Command(_, name) => (*name).into(),
            Self::Tab(tab) => tab.display_title().to_owned().into(),
            Self::Session(row, _) => row.title.clone(),
        }
    }

    fn same_target(&self, other: &Self) -> bool {
        match (self, other) {
            (Self::Bookmark(a), Self::Bookmark(b)) => super::message_bookmarks::same_message(a, b),
            (Self::Command(a, _), Self::Command(b, _)) => a == b,
            (Self::Tab(a), Self::Tab(b)) => a.id == b.id,
            (Self::Session(a, _), Self::Session(b, _)) => a.id == b.id && a.profile == b.profile,
            _ => false,
        }
    }
}

#[derive(Clone)]
enum ListRow {
    Header(&'static str),
    Entry(Entry),
}

pub(super) struct Palette {
    pub input: Entity<InputState>,
    pub open: bool,
    previous_focus: Option<FocusHandle>,
    query: String,
    rows: Vec<ListRow>,
    remote_hits: Vec<(Summary, SharedString)>,
    recent: Vec<Summary>,
    active: Option<usize>,
    task: Option<Task<()>>,
    error: Option<SharedString>,
    scroll: UniformListScrollHandle,
}

impl Palette {
    pub fn new(input: Entity<InputState>) -> Self {
        Self {
            input,
            open: false,
            previous_focus: None,
            query: String::new(),
            rows: Vec::new(),
            remote_hits: Vec::new(),
            recent: Vec::new(),
            active: None,
            task: None,
            error: None,
            scroll: UniformListScrollHandle::default(),
        }
    }

    fn entry_at(&self, index: usize) -> Option<&Entry> {
        match self.rows.get(index)? {
            ListRow::Entry(entry) => Some(entry),
            ListRow::Header(_) => None,
        }
    }
}

impl Desktop {
    pub(super) fn toggle_palette(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.palette.open {
            self.close_palette(window, cx);
            return;
        }
        if self.media.is_open() {
            return;
        }
        self.close_files(window, cx);
        self.close_review(window, cx);
        self.close_transcript_find(window, cx);
        self.palette.open = true;
        self.palette.previous_focus = window.focused(cx);
        self.palette
            .input
            .update(cx, |field, cx| field.focus(window, cx));
        self.refresh_palette(false, cx);
        self.request_palette(cx);
    }

    pub(super) fn close_palette(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.palette.open {
            return;
        }
        self.palette.open = false;
        self.palette.query.clear();
        self.palette.task = None;
        self.palette.remote_hits.clear();
        self.palette.error = None;
        self.palette.rows.clear();
        self.palette.active = None;
        self.palette.scroll = UniformListScrollHandle::default();
        if let Some(focus) = self.palette.previous_focus.take() {
            focus.focus(window, cx);
        } else {
            self.workspace_focus.focus(window, cx);
        }
        self.palette
            .input
            .update(cx, |field, cx| field.set_value("", window, cx));
        cx.notify();
    }

    pub(super) fn palette_query_changed(&mut self, cx: &mut Context<Self>) {
        let query = self.palette.input.read(cx).value().trim().to_owned();
        if !self.palette.open || self.palette.query == query {
            return;
        }
        self.palette.query = query;
        self.palette.task = None;
        self.palette.remote_hits.clear();
        self.palette.error = None;
        self.refresh_palette(false, cx);
        self.request_palette(cx);
    }

    fn request_palette(&mut self, cx: &mut Context<Self>) {
        let Some(gateway) = self.gateway.clone().filter(|_| self.out.is_some()) else {
            return;
        };
        let query = self.palette.query.clone();
        let profile = self
            .workspace()
            .and_then(|workspace| {
                workspace
                    .active_tab
                    .as_deref()
                    .and_then(|id| workspace.tabs.iter().find(|tab| tab.id == id))
                    .map(|tab| tab.profile.clone())
            })
            .unwrap_or_default();
        let runtime = self.runtime.clone();
        self.palette.task = Some(cx.spawn(async move |view, cx| {
            let search = !query.is_empty();
            if search {
                cx.background_executor()
                    .timer(Duration::from_millis(175))
                    .await;
            }
            let request = runtime
                .spawn(async move {
                    if !search {
                        return gateway
                            .sessions("", 0, "", false)
                            .await
                            .map(|page| page.rows);
                    }
                    gateway.search_sessions(&query, &profile, 48).await
                })
                .await;
            let _ = view.update(cx, |this, cx| {
                this.palette.task = None;
                if let Ok(Ok(results)) = request {
                    if search {
                        this.palette.remote_hits = results
                            .into_iter()
                            .filter_map(|row| {
                                Some((
                                    Summary::from_wire(&row)?,
                                    compact_preview(string(&row, "snippet"), 96),
                                ))
                            })
                            .collect();
                    } else {
                        this.palette.recent =
                            results.iter().filter_map(Summary::from_wire).collect();
                    }
                } else if search {
                    this.palette.error = Some(tr("网关搜索暂不可用").into());
                }
                this.refresh_palette(true, cx);
            });
        }));
        cx.notify();
    }

    fn refresh_palette(&mut self, retain_selection: bool, cx: &mut Context<Self>) {
        let active = self
            .palette
            .active
            .and_then(|index| self.palette.entry_at(index))
            .cloned();
        let query = self.palette.query.to_lowercase();
        let matches = |label: &str| {
            if query.is_empty() {
                return true;
            }
            let label = label.to_lowercase();
            query.split_whitespace().all(|token| label.contains(token))
        };
        let workspace = self.workspace();
        let can_chat = self.gateway.is_some() && !self.settings_open;
        let mut commands = Vec::new();
        for (available, command, name, alias) in [
            (can_chat, Command::New, tr("新建会话"), "new chat"),
            (true, Command::Settings, tr("网关设置"), "settings gateway"),
            (can_chat, Command::Files, tr("工作区文件"), "files explorer"),
            (
                can_chat,
                Command::Review,
                tr("审查 Git 变更"),
                "git review diff",
            ),
            (
                can_chat && self.selected.is_some(),
                Command::Find,
                tr("在会话内查找"),
                "find in chat",
            ),
            (
                can_chat,
                Command::Sidebar,
                if self.sidebar_open {
                    tr("隐藏会话侧栏")
                } else {
                    tr("显示会话侧栏")
                },
                "sidebar",
            ),
            (
                can_chat && workspace.is_some_and(|workspace| !workspace.closed_tabs.is_empty()),
                Command::Reopen,
                tr("重新打开已关闭的标签"),
                "reopen closed tab",
            ),
        ] {
            if available && (matches(name) || matches(alias)) {
                commands.push(Entry::Command(command, name));
            }
        }
        let tabs = workspace
            .map(|workspace| workspace.tabs.as_slice())
            .unwrap_or_default();
        let mut seen: HashSet<_> = tabs
            .iter()
            .filter_map(|tab| tab.session.as_deref())
            .collect();
        let snippets: HashMap<_, _> = self
            .palette
            .remote_hits
            .iter()
            .map(|(row, snippet)| (row.id.as_str(), snippet))
            .collect();
        let mut rows = Vec::new();
        let matching_tabs = tabs
            .iter()
            .filter(|tab| {
                matches(tab.display_title())
                    || tab
                        .session
                        .as_deref()
                        .is_some_and(|key| matches(key) || snippets.contains_key(key))
            })
            .cloned()
            .map(Entry::Tab);
        if query.is_empty() {
            append(&mut rows, tr("前往"), std::mem::take(&mut commands));
            append(&mut rows, tr("已打开"), matching_tabs);
        } else {
            append(&mut rows, tr("已打开"), matching_tabs);
        }
        if let Some(ws) = workspace {
            append(
                &mut rows,
                tr("收藏的消息"),
                ws.bookmarks
                    .iter()
                    .rev()
                    .filter(|b| {
                        b.profile == self.active_profile()
                            && (matches(&b.excerpt)
                                || matches(&b.title)
                                || matches(tr("收藏 书签 bookmarks")))
                    })
                    .cloned()
                    .map(Entry::Bookmark),
            );
        }
        let recents = self.rows.iter().chain(&self.palette.recent);
        let history = recents
            .filter(|row| {
                (query.is_empty() && !row.archived)
                    || (!query.is_empty() && (matches(&row.title) || matches(&row.id)))
            })
            .filter(|row| seen.insert(&row.id))
            .take(if query.is_empty() { 12 } else { 36 })
            .map(|row| {
                Entry::Session(
                    row.clone(),
                    snippets
                        .get(row.id.as_str())
                        .map(|snippet| (*snippet).clone())
                        .unwrap_or_default(),
                )
            })
            .collect::<Vec<_>>();
        let remaining = self
            .palette
            .remote_hits
            .iter()
            .filter(|(row, _)| seen.insert(&row.id))
            .map(|(row, snippet)| Entry::Session(row.clone(), snippet.clone()));
        append(
            &mut rows,
            if query.is_empty() {
                tr("最近会话")
            } else {
                tr("历史会话")
            },
            history.into_iter().chain(remaining),
        );
        if !query.is_empty() {
            append(&mut rows, tr("前往"), commands);
        }
        self.palette.rows = rows;
        let selected = if retain_selection {
            active.as_ref()
        } else {
            None
        };
        self.palette.active = selected
            .and_then(|selected| {
                self.palette.rows.iter().position(
                    |row| matches!(row, ListRow::Entry(entry) if entry.same_target(selected)),
                )
            })
            .or_else(|| {
                self.palette
                    .rows
                    .iter()
                    .position(|row| matches!(row, ListRow::Entry(_)))
            });
        if let Some(index) = self.palette.active {
            self.palette
                .scroll
                .scroll_to_item(index, ScrollStrategy::Top);
        }
        cx.notify();
    }

    pub(super) fn step_palette(
        &mut self,
        reverse: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.palette.open || self.palette_composing(window, cx) {
            return;
        }
        let indices: Vec<_> = self
            .palette
            .rows
            .iter()
            .enumerate()
            .filter_map(|(index, row)| matches!(row, ListRow::Entry(_)).then_some(index))
            .collect();
        if indices.is_empty() {
            return;
        }
        let current = self
            .palette
            .active
            .and_then(|index| indices.iter().position(|candidate| *candidate == index))
            .unwrap_or(0);
        let next = if reverse {
            (current + indices.len() - 1) % indices.len()
        } else {
            (current + 1) % indices.len()
        };
        let row = indices[next];
        self.palette.active = Some(row);
        self.palette.scroll.scroll_to_item(
            row,
            if reverse {
                ScrollStrategy::Top
            } else {
                ScrollStrategy::Bottom
            },
        );
        cx.notify();
    }

    pub(super) fn commit_palette(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.palette.open || self.palette_composing(window, cx) {
            return;
        }
        if let Some(entry) = self
            .palette
            .active
            .and_then(|index| self.palette.entry_at(index))
            .cloned()
        {
            self.choose_palette(entry, window, cx);
        }
    }

    fn palette_composing(&self, window: &mut Window, cx: &mut Context<Self>) -> bool {
        self.palette.input.update(cx, |field, cx| {
            field.marked_text_range(window, cx).is_some()
        })
    }

    fn choose_palette(&mut self, entry: Entry, window: &mut Window, cx: &mut Context<Self>) {
        if !self.palette.open {
            return;
        }
        self.close_palette(window, cx);
        match entry {
            Entry::Bookmark(mark) => self.visit_bookmark(mark, window, cx),
            Entry::Tab(tab) => self.select_tab(&tab.id, window, cx),
            Entry::Session(summary, _) => self.open_session(&summary, true, window, cx),
            Entry::Command(command, _) => match command {
                Command::New => self.new_chat_tab(window, cx),
                Command::Find => self.open_transcript_find(window, cx),
                Command::Files => self.open_files(window, cx),
                Command::Review => self.open_review(window, cx),
                Command::Reopen => self.reopen_chat_tab(window, cx),
                Command::Sidebar => {
                    self.set_sidebar_open(!self.sidebar_open, window, cx);
                }
                Command::Settings => {
                    self.release_turn_rail(window, cx);
                    self.settings_open = true;
                    self.address.update(cx, |field, cx| field.focus(window, cx));
                    cx.notify();
                }
            },
        }
    }

    pub(super) fn palette_element(
        &self,
        window: &Window,
        cx: &mut Context<Self>,
    ) -> Option<Stateful<Div>> {
        if !self.palette.open {
            return None;
        }
        let viewport = window.viewport_size();
        let width = (f32::from(viewport.width) - 36.).min(526.).max(260.);
        let max_height = (f32::from(viewport.height) * 0.55).clamp(120., 380.);
        let height = (self.palette.rows.len() as f32 * ROW_HEIGHT).min(max_height);
        let entity = cx.entity();
        let list = uniform_list("palette-results", self.palette.rows.len(), move |range, _, app| {
            let desktop = entity.read(app);
            range.filter_map(|index| {
                let row = desktop.palette.rows.get(index)?;
                if let ListRow::Header(label) = row {
                    return Some(div().id(("palette-section", index)).h(px(ROW_HEIGHT)).flex().items_end()
                        .px_2().pb(px(4.)).text_size(px(11.)).text_color(rgb(0x2457b4)).child(*label));
                }
                let ListRow::Entry(entry) = row else { return None };
                let active = desktop.palette.active == Some(index);
                let title = entry.title();
                let (icon, suffix, secondary) = match entry {
                    Entry::Bookmark(mark) => (crate::icons::MODEL_STAR, tr("收藏"), mark.title.clone().into()),
                    Entry::Command(command, _) => (command.icon(), command.shortcut(), "".into()),
                    Entry::Tab(tab) => (crate::icons::DESKTOP, if tab.session.is_none() { tr("草稿") } else { "" }, "".into()),
                    Entry::Session(summary, snippet) => (crate::icons::DISCUSSION, if summary.archived { tr("已归档") } else { "" }, snippet.clone())
                };
                let current = matches!(entry, Entry::Tab(tab) if desktop.workspace().and_then(|workspace| workspace.active_tab.as_deref()) == Some(&tab.id));
                let weak = entity.downgrade();
                let entry = entry.clone();
                Some(div().id(("palette-entry", index)).h(px(ROW_HEIGHT)).w_full()
                    .rounded(px(3.)).px_2().flex().items_center().gap_2().cursor_pointer()
                    .bg(rgb(if active { 0xe7eefc } else { 0xfbfcfe }))
                    .hover(|style| style.bg(rgb(0xe9effa)))
                    .text_size(px(12.)).text_color(rgb(0x273447))
                    .child(super::view::svg_symbol(icon, 13., if current { 0x185aff } else { 0x627087 }))
                    .child(div().min_w_0().flex_1().truncate().child(title))
                    .when(!secondary.is_empty(), |item| item.child(div().min_w_0().max_w(px(210.))
                        .truncate().text_size(px(11.)).text_color(rgb(0x677487)).child(secondary)))
                    .when(!suffix.is_empty(), |item| item.child(div().flex_none().text_size(px(10.))
                        .text_color(rgb(0x65758b)).child(suffix)))
                    .on_click(move |_, window, app| {
                        let _ = weak.update(app, |this, cx| this.choose_palette(entry.clone(), window, cx));
                    }))
            }).collect::<Vec<_>>()
        }).w_full().h(px(height)).track_scroll(&self.palette.scroll);
        let status: Option<SharedString> =
            if !self.palette.query.is_empty() && self.palette.task.is_some() {
                Some(tr("正在搜索历史会话…").into())
            } else if let Some(error) = &self.palette.error {
                Some(error.clone())
            } else if self.palette.active.is_none() {
                Some(tr("没有匹配的会话或操作").into())
            } else {
                None
            };
        Some(
            div()
                .id("palette-backdrop")
                .absolute()
                .inset_0()
                .occlude()
                .flex()
                .items_start()
                .justify_center()
                .pt(px(10.))
                .on_click(cx.listener(|this, _, window, cx| this.close_palette(window, cx)))
                .child(
                    div()
                        .id("command-palette")
                        .key_context("HermesPaletteInput")
                        .w(px(width))
                        .rounded(px(6.))
                        .border_1()
                        .border_color(rgb(0xdce3ee))
                        .bg(rgb(0xfbfcfe))
                        .shadow_lg()
                        .overflow_hidden()
                        .on_click(|_, _, app| app.stop_propagation())
                        .child(
                            div()
                                .h(px(41.))
                                .flex()
                                .items_center()
                                .gap_2()
                                .px_3()
                                .border_b_1()
                                .border_color(rgb(0x185aff))
                                .child(super::view::svg_symbol(crate::icons::SEARCH, 13., 0x657286))
                                .child(
                                    div().min_w_0().flex_1().child(
                                        Input::new(&self.palette.input)
                                            .appearance(false)
                                            .bordered(false)
                                            .focus_bordered(false)
                                            .h(px(31.)),
                                    ),
                                ),
                        )
                        .when(!self.palette.rows.is_empty(), |panel| {
                            panel.child(div().px_1().pb_1().child(list))
                        })
                        .children(status.map(|status| {
                            div()
                                .px_4()
                                .py_2()
                                .text_size(px(11.))
                                .text_color(rgb(0x697586))
                                .child(status)
                        })),
                ),
        )
    }
}

fn append(rows: &mut Vec<ListRow>, label: &'static str, entries: impl IntoIterator<Item = Entry>) {
    let mut entries = entries.into_iter().peekable();
    if entries.peek().is_some() {
        rows.push(ListRow::Header(label));
        rows.extend(entries.map(ListRow::Entry));
    }
}
