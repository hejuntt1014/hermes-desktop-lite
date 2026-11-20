use crate::theme::{ink, rgb};

use crate::i18n::text as tr;

use std::{env, sync::Arc};

use anyhow::{Context as _, Result, bail};
use gpui::{
    Anchor, ClipboardItem, Context, Div, FocusHandle, FontWeight, ListHorizontalSizingBehavior,
    ObjectFit, RenderImage, ScrollHandle, SharedString, UniformListScrollHandle, Window, div, img,
    prelude::*, px, uniform_list,
};
use gpui_component::{
    Sizable,
    button::{Button, ButtonVariants},
    menu::{DropdownMenu, PopupMenuItem},
    scroll::Scrollbar,
    tooltip::Tooltip,
};
use serde::Deserialize;
use serde_json::Value;

use crate::{
    gateway::Gateway,
    icons,
    media::{ChatImage, load_image},
    session::string,
    style::{ACCENT, INK, MUTED},
};

use super::{
    Desktop,
    pane_layout::{DIVIDER, Pane, workspace_dialog_size},
    remote_refs::scoped_path,
    view::{icon_button, markdown, symbol},
    workspace_scope::{WorkspaceRequest, WorkspaceScope as Scope},
};

#[path = "workspace_markdown.rs"]
mod workspace_markdown;
#[path = "workspace_table.rs"]
mod workspace_table;
#[path = "workspace_workbook.rs"]
mod workspace_workbook;
use workspace_markdown::{
    DocumentPreview, DocumentSection, DocumentTarget, is_markdown, prepare_markdown,
};

const ITEM_HEIGHT: f32 = 25.;
const PREVIEW_BYTES: usize = 192 * 1024;

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct FileEntry {
    name: String,
    path: String,
    is_directory: bool,
}

enum FilePreview {
    Pending,
    Text {
        content: SharedString,
        lines: Arc<[SharedString]>,
        widest: Option<usize>,
        shortened: bool,
        markdown: Option<DocumentPreview>,
    },
    Image {
        source: ChatImage,
        pixels: Arc<RenderImage>,
    },
    Workbook(workspace_workbook::Workbook),
    Binary,
    Failed(SharedString),
}

#[derive(Default)]
pub(super) struct FileDownload {
    busy: bool,
    source: Option<(Scope, String)>,
    status: Option<DownloadStatus>,
}

pub(super) enum DownloadStatus {
    Saving(SharedString),
    Saved(SharedString),
    Failed(SharedString),
}

impl DownloadStatus {
    pub(super) fn label(&self) -> SharedString {
        match self {
            Self::Saving(label) | Self::Saved(label) | Self::Failed(label) => label.clone(),
        }
    }
}

pub(super) struct WorkspaceFiles {
    pub open: bool,
    pub collection: super::conversation_files::Collection,
    focus: FocusHandle,
    previous_focus: Option<FocusHandle>,
    scope: Option<Scope>,
    folders: Vec<String>,
    entries: Vec<FileEntry>,
    selected: Option<FileEntry>,
    preview: Option<FilePreview>,
    directory_job: Option<WorkspaceRequest>,
    preview_job: Option<WorkspaceRequest>,
    list_scroll: UniformListScrollHandle,
    preview_scroll: UniformListScrollHandle,
    markdown_scroll: ScrollHandle,
    markdown_source: bool,
    markdown_jump: Option<usize>,
    error: Option<SharedString>,
}

impl WorkspaceFiles {
    pub fn new(focus: FocusHandle) -> Self {
        Self {
            open: false,
            collection: Default::default(),
            focus,
            previous_focus: None,
            scope: None,
            folders: Vec::new(),
            entries: Vec::new(),
            selected: None,
            preview: None,
            directory_job: None,
            preview_job: None,
            list_scroll: Default::default(),
            preview_scroll: Default::default(),
            markdown_scroll: Default::default(),
            markdown_source: false,
            markdown_jump: None,
            error: None,
        }
    }

    pub fn clear(&mut self) {
        *self = Self::new(self.focus.clone());
    }

    fn set_scope(&mut self, scope: Option<Scope>) {
        let open = self.open;
        let previous_focus = self.previous_focus.take();
        self.clear();
        self.open = open;
        self.previous_focus = previous_focus;
        self.scope = scope;
    }
}

impl Desktop {
    pub(super) fn toggle_files(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.files.open {
            self.close_files(window, cx);
        } else {
            self.open_files(window, cx);
            if self.files.open && self.selected.is_some() {
                self.show_session_files(cx);
            }
        }
    }

    pub(super) fn open_files(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.gateway.is_none()
            || self.login_url.is_some()
            || self.settings_open
            || self.media.is_open()
        {
            return;
        }
        self.close_review(window, cx);
        self.close_palette(window, cx);
        self.close_transcript_find(window, cx);
        self.release_turn_rail(window, cx);
        if !self.files.open {
            self.files.previous_focus = window.focused(cx);
            self.files.open = true;
            self.files.focus.focus(window, cx);
        }
        self.files.collection = Default::default();
        self.refresh_files_scope(cx);
        cx.notify();
    }

    pub(super) fn refresh_files_scope(&mut self, cx: &mut Context<Self>) {
        if !self.files.open {
            return;
        }
        let Some(scope) = self.active_workspace_scope() else {
            if self
                .files
                .scope
                .as_ref()
                .is_some_and(|scope| Some(scope.session.as_str()) != self.selected.as_deref())
            {
                self.files.set_scope(None);
            }
            return;
        };
        if self.files.scope.as_ref() != Some(&scope) {
            let collection = self.files.collection.open;
            self.files.set_scope(Some(scope));
            if collection {
                self.show_session_files(cx)
            }
        }
        if self.files.folders.is_empty() && self.files.directory_job.is_none() {
            self.read_folder(Vec::new(), cx);
        }
    }

    pub(super) fn close_files(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.files.open {
            return;
        }
        self.files.collection = Default::default();
        self.files.open = false;
        self.files
            .previous_focus
            .take()
            .unwrap_or_else(|| self.workspace_focus.clone())
            .focus(window, cx);
        cx.notify();
    }

    fn read_folder(&mut self, mut trail: Vec<String>, cx: &mut Context<Self>) {
        let (Some(gateway), Some(scope)) = (self.gateway.clone(), self.files.scope.clone()) else {
            return;
        };
        self.files.error = None;
        self.files.preview_job = None;
        self.files.selected = None;
        self.files.preview = None;
        let fetch = self.runtime.spawn(async move {
            if trail.is_empty() {
                let root = scope.root(&gateway).await?;
                trail.push(root);
            }
            let path = trail.last().context(tr("没有可用的工作区目录"))?;
            let entries = load_entries(&gateway, &scope, path).await?;
            Ok::<_, anyhow::Error>((trail, entries))
        });
        let abort = fetch.abort_handle();
        let task = cx.spawn(async move |view, cx| {
            let result = fetch.await;
            let _ = view.update(cx, |this, cx| {
                this.files.directory_job = None;
                match result {
                    Ok(Ok((trail, entries))) => {
                        this.files.folders = trail;
                        this.files.entries = entries;
                        this.files.list_scroll = Default::default();
                    }
                    Ok(Err(error)) => this.files.error = Some(error.to_string().into()),
                    Err(_) => this.files.error = Some(tr("无法读取远程目录").into()),
                }
                cx.notify();
            });
        });
        self.files.directory_job = Some(WorkspaceRequest { _task: task, abort });
        cx.notify();
    }

    fn select_file(&mut self, entry: FileEntry, cx: &mut Context<Self>) {
        if !self.files.open
            || self.files.directory_job.is_some()
            || !self
                .files
                .entries
                .iter()
                .any(|item| item.path == entry.path)
        {
            return;
        }
        if entry.is_directory {
            let mut trail = self.files.folders.clone();
            trail.push(entry.path);
            self.read_folder(trail, cx);
            return;
        }
        self.preview_file(entry, None, cx);
    }

    fn visit_folder(&mut self, index: usize, expected: &str, cx: &mut Context<Self>) {
        if !self.files.open || self.files.directory_job.is_some() {
            return;
        }
        if self
            .files
            .folders
            .get(index)
            .is_some_and(|path| path == expected)
        {
            self.read_folder(self.files.folders[..=index].to_vec(), cx);
        }
    }

    pub(super) fn open_conversation_file(
        &mut self,
        session: &str,
        path: String,
        fragment: Option<String>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.selected.as_deref() != Some(session) {
            return;
        }
        self.open_files(window, cx);
        if self.files.open
            && let Some(scope) = &self.files.scope
        {
            let path = scoped_path(&scope.cwd, &path).into_owned();
            self.preview_file(
                FileEntry {
                    name: path_name(&path).to_owned(),
                    path,
                    is_directory: false,
                },
                fragment,
                cx,
            );
        }
    }

    fn preview_file(&mut self, entry: FileEntry, fragment: Option<String>, cx: &mut Context<Self>) {
        let (Some(gateway), Some(scope)) = (self.gateway.clone(), self.files.scope.clone()) else {
            return;
        };
        self.files.preview = Some(FilePreview::Pending);
        self.files.preview_scroll = Default::default();
        self.files.markdown_scroll = ScrollHandle::new();
        self.files.markdown_source = false;
        self.files.markdown_jump = None;
        self.files.selected = Some(entry.clone());
        let fetch = self.runtime.spawn(async move {
            let path = scope.file_path(&gateway, &entry.path).await?;
            if let Some(image) = ChatImage::from_reference(&path) {
                let pixels =
                    load_image(gateway, scope.session, scope.profile, image.clone(), true).await?;
                return Ok(FilePreview::Image {
                    source: image,
                    pixels,
                });
            }
            if path
                .rsplit_once('.')
                .is_some_and(|(_, ext)| ext.eq_ignore_ascii_case("xlsx"))
            {
                let bytes = gateway
                    .workspace_preview_bytes(
                        &path,
                        &scope.session,
                        &scope.profile,
                        workspace_workbook::WORKBOOK_BYTES,
                    )
                    .await?;
                let book =
                    tokio::task::spawn_blocking(move || workspace_workbook::Workbook::open(bytes))
                        .await??;
                return Ok(FilePreview::Workbook(book));
            }
            read_text_file(&gateway, &scope, &path).await
        });
        let abort = fetch.abort_handle();
        let task = cx.spawn(async move |view, cx| {
            let result = fetch.await;
            let _ = view.update(cx, |this, cx| {
                this.files.preview_job = None;
                let preview = match result {
                    Ok(Ok(preview)) => preview,
                    Ok(Err(error)) => FilePreview::Failed(error.to_string().into()),
                    Err(_) => FilePreview::Failed(tr("无法读取文件").into()),
                };
                if let Some(fragment) = &fragment
                    && let FilePreview::Text {
                        markdown: Some(document),
                        ..
                    } = &preview
                {
                    this.files.markdown_jump = document.heading_index(fragment);
                }
                this.files.preview = Some(preview);
                cx.notify();
            });
        });
        self.files.preview_job = Some(WorkspaceRequest { _task: task, abort });
        cx.notify();
    }

    fn select_worksheet(&mut self, index: usize, cx: &mut Context<Self>) {
        let Some(FilePreview::Workbook(book)) = &mut self.files.preview else {
            return;
        };
        if book.selected == index {
            return;
        }
        let Some(read) = book.reader_for(index) else {
            return;
        };
        book.selected = index;
        book.sheet = None;
        self.files.preview_scroll = Default::default();
        let parse = self.runtime.spawn_blocking(read);
        let abort = parse.abort_handle();
        let task = cx.spawn(async move |view, cx| {
            let result = parse
                .await
                .unwrap_or_else(|_| Err(tr("无法读取工作表").into()));
            let _ = view.update(cx, |this, cx| {
                if let Some(FilePreview::Workbook(book)) = &mut this.files.preview
                    && book.selected == index
                {
                    book.sheet = Some(result);
                    this.files.preview_job = None;
                    cx.notify();
                }
            });
        });
        self.files.preview_job = Some(WorkspaceRequest { _task: task, abort });
        cx.notify();
    }

    fn jump_to_heading(&mut self, index: usize, cx: &mut Context<Self>) {
        self.files.markdown_source = false;
        self.files.markdown_jump = Some(index);
        cx.notify();
    }

    fn preview_workspace_image(&mut self, path: &str, window: &mut Window, cx: &mut Context<Self>) {
        if !self.files.open
            || self
                .files
                .selected
                .as_ref()
                .is_none_or(|entry| entry.path != path)
        {
            return;
        }
        if let (Some(scope), Some(FilePreview::Image { source, pixels })) =
            (&self.files.scope, &self.files.preview)
        {
            self.open_loaded_image(
                scope.session.clone(),
                scope.profile.clone(),
                source.clone(),
                pixels.clone(),
                window,
                cx,
            );
        }
    }

    fn follow_document_link(&mut self, target: DocumentTarget, cx: &mut Context<Self>) {
        match target {
            DocumentTarget::Heading(fragment) => {
                if let Some(FilePreview::Text {
                    markdown: Some(document),
                    ..
                }) = &self.files.preview
                    && let Some(index) = document.heading_index(&fragment)
                {
                    self.jump_to_heading(index, cx);
                }
            }
            DocumentTarget::File { path, .. } if path.ends_with(['/', '\\']) => {
                let mut trail = self.files.folders.clone();
                trail.push(path);
                self.read_folder(trail, cx);
            }
            DocumentTarget::File { path, fragment } => {
                let entry = FileEntry {
                    name: path_name(&path).to_owned(),
                    path,
                    is_directory: false,
                };
                self.preview_file(entry, fragment, cx);
            }
        }
    }

    fn download_workspace_file(&mut self, cx: &mut Context<Self>) {
        let (Some(scope), Some(file)) = (self.files.scope.clone(), self.files.selected.clone())
        else {
            return;
        };
        self.start_file_download(scope, file, cx);
    }

    pub(super) fn download_conversation_file(
        &mut self,
        session: &str,
        path: &str,
        cx: &mut Context<Self>,
    ) {
        let Some(scope) = self
            .active_workspace_scope()
            .filter(|scope| scope.session == session)
        else {
            return;
        };
        let path = scoped_path(&scope.cwd, path).into_owned();
        self.start_file_download(
            scope,
            FileEntry {
                name: path_name(&path).to_owned(),
                path,
                is_directory: false,
            },
            cx,
        );
    }

    pub(super) fn conversation_download_status(
        &self,
        session: &str,
        path: &str,
    ) -> (bool, Option<&DownloadStatus>) {
        let Some((scope, source)) = &self.file_download.source else {
            return (false, None);
        };
        let same_file =
            scope.session == session && scoped_path(&scope.cwd, path).as_ref() == source;
        (
            self.file_download.busy && same_file,
            same_file
                .then_some(self.file_download.status.as_ref())
                .flatten(),
        )
    }

    fn start_file_download(&mut self, scope: Scope, file: FileEntry, cx: &mut Context<Self>) {
        let Some(gateway) = self.gateway.clone().filter(|_| !self.file_download.busy) else {
            return;
        };
        let Some(directory) = dirs::download_dir()
            .or_else(dirs::document_dir)
            .or_else(|| env::current_dir().ok())
        else {
            return;
        };
        let filename = download_name(&file.name);
        let target = cx.prompt_for_new_path(&directory, Some(&filename));
        self.file_download.busy = true;
        self.file_download.source = Some((scope.clone(), file.path.clone()));
        self.file_download.status = None;
        let runtime = self.runtime.clone();
        cx.spawn(async move |view, cx| {
            let result = async {
                let Some(destination) = target.await.context(tr("保存对话框已关闭"))??
                else {
                    return Ok(None);
                };
                let name = destination
                    .file_name()
                    .unwrap_or_default()
                    .to_string_lossy()
                    .into_owned();
                let _ = view.update(cx, |this, cx| {
                    this.file_download.status = Some(DownloadStatus::Saving(
                        crate::i18n::format_text!("正在保存 {name}", "Saving {name}").into(),
                    ));
                    cx.notify();
                });
                runtime
                    .spawn(async move {
                        let path = scope.file_path(&gateway, &file.path).await?;
                        gateway
                            .save_workspace_file(&path, &scope.session, &scope.profile, destination)
                            .await
                    })
                    .await??;
                Ok::<_, anyhow::Error>(Some(name))
            }
            .await;
            let _ = view.update(cx, |this, cx| {
                this.file_download.busy = false;
                this.file_download.status = match result {
                    Ok(Some(name)) => Some(DownloadStatus::Saved(
                        crate::i18n::format_text!("已保存 {name}", "Saved {name}").into(),
                    )),
                    Ok(None) => None,
                    Err(error) => Some(DownloadStatus::Failed(
                        crate::i18n::format_text!("保存失败 · {error}", "Save failed · {error}")
                            .into(),
                    )),
                };
                cx.notify();
            });
        })
        .detach();
        cx.notify();
    }

    pub(super) fn files_element(&self, window: &mut Window, cx: &mut Context<Self>) -> Div {
        let pane_width = self.file_list_width(window);
        let selected = self.files.selected.as_ref().map(|entry| entry.path.clone());
        let loading = self.files.directory_job.is_some();
        let entity = cx.entity();
        let rows = uniform_list(
            "workspace-entries",
            self.files.entries.len(),
            move |range, _, app| {
                range
                    .filter_map(|index| {
                        let item = entity.read(app).files.entries.get(index)?.clone();
                        let active = selected.as_ref() == Some(&item.path);
                        let name = item.name.clone();
                        let tooltip: SharedString = item.path.clone().into();
                        let weak = entity.downgrade();
                        Some(
                            div()
                                .id(("workspace-entry", index))
                                .h(px(ITEM_HEIGHT))
                                .w_full()
                                .px_2()
                                .flex()
                                .items_center()
                                .gap_2()
                                .rounded(px(3.))
                                .cursor_pointer()
                                .text_size(px(12.))
                                .text_color(ink(0x354459))
                                .when(active, |row| row.bg(rgb(0xe5eefc)))
                                .hover(|row| row.bg(rgb(0xeaf0f8)))
                                .when(loading, |row| row.opacity(0.65))
                                .tooltip(move |window, cx| {
                                    Tooltip::new(tooltip.clone()).build(window, cx)
                                })
                                .child(symbol(
                                    if item.is_directory {
                                        icons::FOLDER
                                    } else {
                                        icons::FILE
                                    },
                                    14.,
                                ))
                                .child(div().min_w_0().truncate().child(name))
                                .on_click(move |_, _, app| {
                                    let _ = weak
                                        .update(app, |this, cx| this.select_file(item.clone(), cx));
                                }),
                        )
                    })
                    .collect::<Vec<_>>()
            },
        )
        .track_scroll(&self.files.list_scroll)
        .flex_1()
        .min_h_0()
        .w_full();
        let status: Option<SharedString> = if loading {
            Some(tr("正在读取目录…").into())
        } else if let Some(error) = &self.files.error {
            Some(error.clone())
        } else if self.files.scope.is_none() {
            self.selected
                .as_ref()
                .and_then(|key| self.sessions.get(key))
                .and_then(|session| session.error.clone())
                .map(Into::into)
                .or_else(|| Some(tr("正在恢复会话目录…").into()))
        } else if self.files.entries.is_empty() {
            Some(tr("此目录为空").into())
        } else {
            None
        };
        let pane = div()
            .w(px(pane_width))
            .h_full()
            .flex_none()
            .flex()
            .flex_col()
            .bg(rgb(0xfbfcfe))
            .border_r_1()
            .border_color(rgb(0xe5eaf2))
            .child(self.folder_toolbar(cx))
            .child(rows)
            .children(status.map(|status| {
                div()
                    .px_2()
                    .py_2()
                    .text_size(px(11.))
                    .text_color(ink(0x6c7786))
                    .child(status)
            }));
        div()
            .flex_1()
            .min_h_0()
            .w_full()
            .flex()
            .key_context("HermesFiles")
            .track_focus(&self.files.focus)
            .child(pane)
            .child(self.pane_divider(Pane::Files, cx))
            .child(self.preview_element(window, pane_width + DIVIDER, cx))
    }

    fn folder_toolbar(&self, cx: &mut Context<Self>) -> Div {
        let folders = &self.files.folders;
        let mut path_bar = div().flex().items_center().min_w_0().flex_1();
        let nested = folders.len() > 1;
        if let Some(root) = folders.first().filter(|_| nested) {
            let root = root.clone();
            let label: SharedString =
                crate::i18n::format_text!("工作区根目录 · {root}", "Workspace root · {root}")
                    .into();
            path_bar = path_bar
                .child(
                    Button::new("folder-root")
                        .ghost()
                        .compact()
                        .size(px(21.))
                        .p_0()
                        .tooltip(label)
                        .child(symbol(icons::FOLDER_OPENED, 14.))
                        .on_click(
                            cx.listener(move |this, _, _, cx| this.visit_folder(0, &root, cx)),
                        ),
                )
                .child(symbol(icons::CHEVRON_RIGHT, 9.));
        } else {
            path_bar = path_bar.child(symbol(icons::FOLDER_OPENED, 14.)).gap_1();
        }
        if folders.len() > 2 {
            let ancestors = folders[1..folders.len() - 1].to_vec();
            let desktop = cx.entity().downgrade();
            path_bar = path_bar
                .child(
                    Button::new("folder-ancestors")
                        .ghost()
                        .compact()
                        .size(px(20.))
                        .p_0()
                        .tooltip(tr("上级目录"))
                        .child(symbol(icons::ELLIPSIS, 13.))
                        .dropdown_menu_with_anchor(Anchor::TopLeft, move |menu, _, _| {
                            ancestors
                                .iter()
                                .enumerate()
                                .fold(menu, |menu, (index, path)| {
                                    let path = path.clone();
                                    let label = path_name(&path).to_owned();
                                    let desktop = desktop.clone();
                                    menu.item(
                                        PopupMenuItem::element(move |_, _| {
                                            div().max_w(px(240.)).truncate().child(label.clone())
                                        })
                                        .on_click(
                                            move |_, window, cx| {
                                                let desktop = desktop.clone();
                                                let path = path.clone();
                                                window.defer(cx, move |_, cx| {
                                                    let _ = desktop.update(cx, |this, cx| {
                                                        this.visit_folder(index + 1, &path, cx)
                                                    });
                                                });
                                            },
                                        ),
                                    )
                                })
                        }),
                )
                .child(symbol(icons::CHEVRON_RIGHT, 9.));
        }
        let folder_path = folders.last().map(String::as_str);
        let current = folder_path
            .map(path_name)
            .unwrap_or(tr("工作区"))
            .to_owned();
        path_bar = path_bar.child(
            div()
                .id("folder-current")
                .min_w_0()
                .truncate()
                .text_size(px(11.5))
                .text_color(ink(INK))
                .when_some(
                    folder_path.map(|path| SharedString::from(path.to_owned())),
                    |label, path| {
                        label
                            .tooltip(move |window, cx| Tooltip::new(path.clone()).build(window, cx))
                    },
                )
                .child(current),
        );
        div()
            .h(px(33.))
            .flex_none()
            .flex()
            .items_center()
            .gap(px(2.))
            .px_2()
            .border_b_1()
            .border_color(rgb(0xe8edf4))
            .child(path_bar)
            .children(nested.then(|| {
                let parent = folders.len() - 2;
                let path = folders[parent].clone();
                icon_button("folder-parent", icons::BACK, tr("上一级目录"))
                    .size(px(21.))
                    .on_click(
                        cx.listener(move |this, _, _, cx| this.visit_folder(parent, &path, cx)),
                    )
            }))
            .child(
                icon_button("folder-refresh", icons::REFRESH, tr("刷新目录"))
                    .size(px(21.))
                    .on_click(cx.listener(|this, _, _, cx| {
                        if this.files.directory_job.is_some() {
                            return;
                        }
                        if this.files.scope.is_some() {
                            this.read_folder(this.files.folders.clone(), cx);
                        } else if let Some(session) = this.selected.clone() {
                            this.attach(&session, true);
                            cx.notify();
                        }
                    })),
            )
    }

    fn preview_element(&self, window: &mut Window, pane_width: f32, cx: &mut Context<Self>) -> Div {
        let Some(file) = &self.files.selected else {
            return preview_status(Some(tr("选择文件预览").into()));
        };
        let path = file.path.clone();
        let filename_tip: SharedString = file.path.clone().into();
        let mut toolbar = div()
            .w_full()
            .h(px(33.))
            .px_3()
            .flex_none()
            .flex()
            .items_center()
            .gap_2()
            .border_b_1()
            .border_color(rgb(0xe5eaf2))
            .text_size(px(12.))
            .text_color(ink(0x35455b))
            .child(symbol(
                if matches!(self.files.preview, Some(FilePreview::Image { .. })) {
                    icons::PHOTO
                } else {
                    icons::FILE
                },
                14.,
            ))
            .child(
                div()
                    .id("workspace-preview-filename")
                    .flex_1()
                    .min_w_0()
                    .truncate()
                    .tooltip(move |window, cx| Tooltip::new(filename_tip.clone()).build(window, cx))
                    .child(file.name.clone()),
            )
            .child(
                icon_button("copy-remote-file-path", icons::LINK, tr("复制远程路径")).on_click(
                    move |_, _, app| {
                        app.write_to_clipboard(ClipboardItem::new_string(path.clone()));
                    },
                ),
            );
        let download_busy = self.file_download.busy;
        let show_status = download_busy
            || self
                .file_download
                .source
                .as_ref()
                .is_some_and(|(scope, path)| {
                    self.files.scope.as_ref() == Some(scope) && &file.path == path
                });
        toolbar = toolbar
            .children(
                self.file_download
                    .status
                    .as_ref()
                    .filter(|_| show_status)
                    .map(|status| {
                        div()
                            .min_w_0()
                            .max_w(px(270.))
                            .truncate()
                            .text_size(px(11.))
                            .text_color(ink(0x68758b))
                            .child(status.label())
                    }),
            )
            .child(
                icon_button("download-remote-file", icons::DOWNLOAD, tr("保存到本机"))
                    .when(download_busy, |button| button.opacity(0.45))
                    .on_click(cx.listener(|this, _, _, cx| this.download_workspace_file(cx))),
            );
        let mut mode_bar = None;
        let body = match &self.files.preview {
            Some(FilePreview::Text {
                content,
                lines,
                widest,
                shortened,
                markdown,
            }) => {
                let copy = content.clone();
                toolbar = toolbar.child(
                    icon_button(
                        "copy-remote-file-content",
                        crate::icons::COPY,
                        if *shortened {
                            tr("复制预览内容")
                        } else {
                            tr("复制文件内容")
                        },
                    )
                    .on_click(move |_, _, app| {
                        app.write_to_clipboard(ClipboardItem::new_string(copy.to_string()))
                    }),
                );
                mode_bar = markdown
                    .as_ref()
                    .map(|document| self.markdown_mode_bar(file, document, cx));
                let preview = if let Some(document) =
                    markdown.as_ref().filter(|_| !self.files.markdown_source)
                {
                    self.document_preview(file, document, pane_width, window, cx)
                } else {
                    source_preview(lines.clone(), *widest, &self.files.preview_scroll)
                };
                div()
                    .flex_1()
                    .min_h_0()
                    .flex()
                    .flex_col()
                    .child(preview)
                    .when(*shortened, |body| {
                        body.child(
                            div()
                                .px_3()
                                .py_2()
                                .text_size(px(11.))
                                .text_color(ink(0x68778b))
                                .child(tr("仅显示文件开头")),
                        )
                    })
            }
            Some(FilePreview::Image { pixels, .. }) => {
                let view = workspace_dialog_size(window);
                let max_width = (f32::from(view.width) - pane_width - 30.).max(40.);
                let max_height = (f32::from(view.height) - 84.).max(40.);
                let size = pixels.size(0);
                let width = size.width.0.max(1) as f32;
                let height = size.height.0.max(1) as f32;
                let scale = (max_width / width).min(max_height / height).min(1.);
                let path = file.path.clone();
                div()
                    .flex_1()
                    .min_h_0()
                    .flex()
                    .items_center()
                    .justify_center()
                    .overflow_hidden()
                    .child(
                        div()
                            .id("workspace-image")
                            .w(px(width * scale))
                            .h(px(height * scale))
                            .rounded(px(5.))
                            .overflow_hidden()
                            .cursor_pointer()
                            .tooltip(|window, cx| Tooltip::new(tr("查看大图")).build(window, cx))
                            .on_click(cx.listener(move |this, _, window, cx| {
                                this.preview_workspace_image(&path, window, cx);
                            }))
                            .child(
                                img(pixels.clone())
                                    .size_full()
                                    .object_fit(ObjectFit::Contain),
                            ),
                    )
            }
            Some(FilePreview::Workbook(book)) => self.workbook_preview(book, cx),
            Some(FilePreview::Pending) => preview_status(Some(tr("正在读取文件…").into())),
            Some(FilePreview::Binary) => preview_status(Some(tr("此文件类型没有文本预览").into())),
            Some(FilePreview::Failed(error)) => preview_status(Some(error.clone())),
            None => preview_status(None),
        };
        div()
            .flex_1()
            .min_w_0()
            .h_full()
            .flex()
            .flex_col()
            .child(toolbar)
            .children(mode_bar)
            .child(body)
    }

    fn workbook_preview(&self, book: &workspace_workbook::Workbook, cx: &mut Context<Self>) -> Div {
        let sheets = div()
            .id("workbook-sheets")
            .h(px(34.))
            .w_full()
            .flex_none()
            .px_2()
            .gap_1()
            .flex()
            .items_center()
            .overflow_x_scroll()
            .bg(rgb(0xf7f9fc))
            .border_b_1()
            .border_color(rgb(0xe5eaf2))
            .children(book.names.iter().enumerate().map(|(index, name)| {
                let active = index == book.selected;
                let title = name.clone();
                div()
                    .id(("workbook-sheet", index))
                    .flex_none()
                    .h(px(28.))
                    .max_w(px(185.))
                    .flex()
                    .items_center()
                    .px_2()
                    .border_b_2()
                    .border_color(rgb(if active { ACCENT } else { 0xf7f9fc }))
                    .text_color(ink(if active { INK } else { MUTED }))
                    .text_size(px(12.))
                    .when(!active, |tab| {
                        tab.cursor_pointer().hover(|tab| tab.bg(rgb(0xecf1f7)))
                    })
                    .tooltip(move |window, cx| Tooltip::new(title.clone()).build(window, cx))
                    .child(div().truncate().child(name.clone()))
                    .on_click(cx.listener(move |this, _, _, cx| this.select_worksheet(index, cx)))
            }));
        let sheet = match &book.sheet {
            Some(Ok(sheet)) => workspace_workbook::grid(sheet.clone(), &self.files.preview_scroll),
            Some(Err(error)) => preview_status(Some(error.clone())),
            None => preview_status(Some(tr("正在读取工作表…").into())),
        };
        div()
            .flex_1()
            .min_h_0()
            .min_w_0()
            .flex()
            .flex_col()
            .child(sheets)
            .child(sheet)
    }

    fn markdown_mode_bar(
        &self,
        file: &FileEntry,
        document: &DocumentPreview,
        cx: &mut Context<Self>,
    ) -> Div {
        let headings: Vec<_> = document
            .sections
            .iter()
            .enumerate()
            .filter_map(|(index, section)| {
                let DocumentSection::Heading { depth, label, .. } = section else {
                    return None;
                };
                (!label.trim().is_empty()).then(|| (index, *depth, label.clone()))
            })
            .collect();
        let origin = file.path.clone();
        let owner = self.files.scope.clone();
        let desktop = cx.entity().downgrade();
        div()
            .h(px(28.))
            .px_3()
            .flex_none()
            .flex()
            .justify_end()
            .items_center()
            .gap_1()
            .border_b_1()
            .border_color(rgb(0xe5eaf2))
            .children((!headings.is_empty()).then(|| {
                Button::new("document-outline")
                    .ghost()
                    .small()
                    .compact()
                    .h(px(21.))
                    .tooltip(tr("跳转到文档标题"))
                    .child(symbol(icons::LIST_DETAILS, 12.))
                    .label(tr("目录"))
                    .dropdown_menu_with_anchor(Anchor::TopRight, move |menu, _, _| {
                        let mut menu = menu.min_w(px(225.)).max_w(px(370.)).max_h(px(340.));
                        for (index, depth, heading) in &headings {
                            let label = heading.clone();
                            let depth = *depth;
                            let index = *index;
                            let origin = origin.clone();
                            let owner = owner.clone();
                            let desktop = desktop.clone();
                            menu = menu.item(
                                PopupMenuItem::element(move |_, _| {
                                    div()
                                        .pl(px(f32::from(depth.saturating_sub(1)) * 10.))
                                        .min_w_0()
                                        .max_w(px(325.))
                                        .truncate()
                                        .child(label.clone())
                                })
                                .on_click(move |_, window, cx| {
                                    let origin = origin.clone();
                                    let owner = owner.clone();
                                    let desktop = desktop.clone();
                                    window.defer(cx, move |_, cx| {
                                        let _ = desktop.update(cx, |this, cx| {
                                            if this.files.open
                                                && this.files.scope == owner
                                                && this
                                                    .files
                                                    .selected
                                                    .as_ref()
                                                    .map(|file| &file.path)
                                                    == Some(&origin)
                                            {
                                                this.jump_to_heading(index, cx);
                                            }
                                        });
                                    });
                                }),
                            );
                        }
                        menu
                    })
            }))
            .children(
                [
                    ("preview-markdown", tr("预览"), false),
                    ("preview-source", tr("源码"), true),
                ]
                .into_iter()
                .map(|(id, label, source)| {
                    let active = source == self.files.markdown_source;
                    Button::new(id)
                        .ghost()
                        .small()
                        .compact()
                        .h(px(21.))
                        .label(label)
                        .when(active, |button| {
                            button.bg(rgb(0xe9f0fc)).text_color(ink(ACCENT))
                        })
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.files.markdown_source = source;
                            cx.notify();
                        }))
                }),
            )
    }

    fn document_preview(
        &self,
        file: &FileEntry,
        document: &DocumentPreview,
        pane_width: f32,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Div {
        if let Some(index) = self.files.markdown_jump {
            let origin = file.path.clone();
            let owner = self.files.scope.clone();
            let desktop = cx.entity().downgrade();
            // The newly loaded document needs one layout before scrolling to a heading.
            window.on_next_frame(move |_, cx| {
                let _ = desktop.update(cx, |this, cx| {
                    if this.files.open
                        && !this.files.markdown_source
                        && this.files.scope == owner
                        && this.files.selected.as_ref().map(|file| &file.path) == Some(&origin)
                        && this.files.markdown_jump == Some(index)
                    {
                        this.files.markdown_jump = None;
                        this.files.markdown_scroll.scroll_to_top_of_item(index);
                        cx.notify();
                    }
                });
            });
        }
        let available = (f32::from(workspace_dialog_size(window).width) - pane_width).min(760.)
            - f32::from(window.rem_size()) * 2.5;
        let mut page = div()
            .id("workspace-document-scroll")
            .size_full()
            .py_3()
            .text_size(px(13.))
            .line_height(px(19.))
            .text_color(ink(INK))
            .overflow_y_scroll()
            .track_scroll(&self.files.markdown_scroll);
        for (index, section) in document.sections.iter().enumerate() {
            let id = SharedString::from(format!("workspace-document:{}:{index}", file.path));
            let column = document_column();
            let column = match section {
                DocumentSection::Markdown(body) => {
                    column.child(markdown(id, body.clone(), false, px(13.), window))
                }
                DocumentSection::Heading { depth, content, .. } => {
                    let size =
                        [26., 20., 17., 15., 14., 13.][usize::from(depth.saturating_sub(1)).min(5)];
                    let heading = markdown(id, content.clone(), false, px(size), window);
                    column
                        .whitespace_normal()
                        .text_size(px(size))
                        .line_height(px(size * 1.23))
                        .font_weight(if *depth == 1 {
                            FontWeight::BOLD
                        } else {
                            FontWeight::SEMIBOLD
                        })
                        .pt(px(if index == 0 { 0. } else { 10. }))
                        .pb(px(4.))
                        .child(heading)
                }
                DocumentSection::Table(table) => column.child(workspace_table::render_table(
                    table, id, available, window, cx,
                )),
            };
            page = page.child(column);
        }
        if let Some(scope) = &self.files.scope
            && !document.links.is_empty()
        {
            page = page.child(
                document_column().child(
                    div()
                        .mt_4()
                        .pt_2()
                        .border_t_1()
                        .border_color(rgb(0xe5eaf2))
                        .flex()
                        .flex_wrap()
                        .gap_1()
                        .children(document.links.iter().enumerate().map(|(index, link)| {
                            let target = link.target.clone();
                            let scope = scope.clone();
                            let origin = file.path.clone();
                            let icon = match &target {
                                DocumentTarget::Heading(_) => icons::HASH,
                                DocumentTarget::File { path, .. }
                                    if path.ends_with(['/', '\\']) =>
                                {
                                    icons::FOLDER_OPEN
                                }
                                DocumentTarget::File { .. } => icons::FILE_TEXT,
                            };
                            Button::new(("document-file-link", index))
                                .ghost()
                                .small()
                                .compact()
                                .h(px(23.))
                                .tooltip(target.location())
                                .child(
                                    div()
                                        .flex()
                                        .items_center()
                                        .gap_1()
                                        .text_size(px(11.))
                                        .text_color(ink(MUTED))
                                        .child(symbol(icon, 12.))
                                        .child(
                                            div()
                                                .max_w(px(220.))
                                                .truncate()
                                                .child(link.label.clone()),
                                        ),
                                )
                                .on_click(cx.listener(move |this, _, _, cx| {
                                    if !this.files.open
                                        || this.files.scope.as_ref() != Some(&scope)
                                        || this.files.selected.as_ref().map(|entry| &entry.path)
                                            != Some(&origin)
                                    {
                                        return;
                                    }
                                    this.follow_document_link(target.clone(), cx);
                                }))
                        })),
                ),
            );
        }
        div()
            .relative()
            .flex_1()
            .min_h_0()
            .child(page)
            .child(Scrollbar::vertical(&self.files.markdown_scroll))
    }
}

fn document_column() -> Div {
    div().w_full().min_w_0().max_w(px(760.)).mx_auto().px_5()
}

fn source_preview(
    lines: Arc<[SharedString]>,
    widest: Option<usize>,
    scroll: &UniformListScrollHandle,
) -> Div {
    let scroller = uniform_list("workspace-file-lines", lines.len(), move |range, _, _| {
        range
            .filter_map(|index| {
                let line = lines.get(index)?;
                Some(
                    div()
                        .h(px(20.))
                        .px_2()
                        .flex()
                        .items_center()
                        .font_family(crate::theme::code_family())
                        .text_size(px(12.))
                        .child(
                            div()
                                .w(px(45.))
                                .flex_none()
                                .pr_2()
                                .text_right()
                                .text_color(ink(0x8e9bad))
                                .child((index + 1).to_string()),
                        )
                        .child(
                            div()
                                .flex_none()
                                .whitespace_nowrap()
                                .text_color(ink(0x2d3d53))
                                .child(line.clone()),
                        ),
                )
            })
            .collect::<Vec<_>>()
    })
    .track_scroll(&scroll)
    .with_width_from_item(widest)
    .with_horizontal_sizing_behavior(ListHorizontalSizingBehavior::Unconstrained)
    .flex_1()
    .min_h_0();
    div()
        .relative()
        .flex()
        .flex_col()
        .flex_1()
        .min_h_0()
        .pt_2()
        .child(scroller)
        .child(Scrollbar::vertical(scroll))
        .child(Scrollbar::horizontal(scroll))
}

fn preview_status(status: Option<SharedString>) -> Div {
    div()
        .flex_1()
        .min_w_0()
        .min_h_0()
        .flex()
        .items_center()
        .justify_center()
        .text_size(px(12.))
        .text_color(ink(0x69778b))
        .children(status)
}

fn path_name(path: &str) -> &str {
    path.trim_end_matches(['/', '\\'])
        .rsplit(['/', '\\'])
        .next()
        .filter(|name| !name.is_empty())
        .unwrap_or(path)
}

async fn file_api(
    gateway: &Gateway,
    scope: &Scope,
    endpoint: &str,
    path: Option<&str>,
    session: bool,
) -> Result<Value> {
    let params = path
        .into_iter()
        .map(|path| ("path", path.to_owned()))
        .collect();
    scope.get(gateway, endpoint, params, session).await
}

async fn load_entries(gateway: &Gateway, scope: &Scope, path: &str) -> Result<Vec<FileEntry>> {
    let mut value = file_api(gateway, scope, "api/fs/list", Some(path), false).await?;
    if !string(&value, "error").is_empty() {
        bail!(tr("网关无法读取此目录"));
    }
    let mut entries: Vec<FileEntry> =
        serde_json::from_value(value["entries"].take()).context(tr("网关未返回有效目录"))?;
    entries.retain(|entry| !entry.name.is_empty() && !entry.path.is_empty());
    entries.sort_by_cached_key(|entry| (!entry.is_directory, entry.name.to_lowercase()));
    Ok(entries)
}

async fn read_text_file(gateway: &Gateway, scope: &Scope, path: &str) -> Result<FilePreview> {
    let mut value = file_api(gateway, scope, "api/fs/read-text", Some(path), true).await?;
    if value["binary"] == true {
        return Ok(FilePreview::Binary);
    }
    let shortened = value["truncated"] == true;
    let Value::String(mut content) = value["text"].take() else {
        bail!(tr("网关未返回可预览的文本"))
    };
    let shortened = shortened || content.len() > PREVIEW_BYTES;
    if content.len() > PREVIEW_BYTES {
        content.truncate(content.floor_char_boundary(PREVIEW_BYTES));
    }
    let actual_path = value["path"]
        .as_str()
        .filter(|path| !path.is_empty())
        .unwrap_or(path);
    let markdown = if is_markdown(actual_path, string(&value, "language")) || is_markdown(path, "")
    {
        prepare_markdown(&content, actual_path)
    } else {
        None
    };
    let lines: Vec<SharedString> = content
        .split('\n')
        .map(|line| line.trim_end_matches('\r').to_owned().into())
        .collect();
    let widest = lines
        .iter()
        .enumerate()
        .max_by_key(|(_, line)| {
            line.chars()
                .map(|character| {
                    if character == '\t' {
                        4
                    } else if character.is_ascii() {
                        1
                    } else {
                        2
                    }
                })
                .sum::<usize>()
        })
        .map(|(index, _)| index);
    Ok(FilePreview::Text {
        content: content.into(),
        lines: lines.into(),
        widest,
        shortened,
        markdown,
    })
}

pub(super) fn download_name(name: &str) -> String {
    let filename: String = path_name(name)
        .chars()
        .take(150)
        .map(|character| {
            if character.is_control() || "<>:\"/\\|?*".contains(character) {
                '_'
            } else {
                character
            }
        })
        .collect();
    let filename = filename.trim_matches([' ', '.']);
    if filename.is_empty() {
        tr("远程文件").to_owned()
    } else {
        filename.to_owned()
    }
}
