use super::{
    Desktop,
    attachment_ops::leading_file_refs,
    reading_position::{find_anchor, make_anchor},
    remote_refs::{ReplyPart, gateway_path, reply_files, reply_links, scoped_path},
    view::{control, svg_symbol},
};
use crate::{
    icons,
    media::{ChatImage, ImageSource},
    session::Row,
    settings::ReadingAnchor,
};
use gpui::{Context, Div, Task, Window, div, prelude::*, px, rgb, uniform_list};
use gpui_component::tooltip::Tooltip;
use std::{collections::HashSet, sync::Arc};

#[derive(Clone)]
struct Entry {
    name: String,
    path: String,
    image: Option<ChatImage>,
    fragment: Option<String>,
    anchor: ReadingAnchor,
}

#[derive(Default)]
pub(super) struct Collection {
    pub open: bool,
    entries: Arc<[Entry]>,
    job: Option<Task<()>>,
}

impl Desktop {
    pub(super) fn show_session_files(&mut self, cx: &mut Context<Self>) {
        self.files.collection = Collection {
            open: true,
            ..Default::default()
        };
        let Some(session) = self
            .selected
            .as_ref()
            .and_then(|key| self.sessions.get(key))
        else {
            cx.notify();
            return;
        };
        let cwd = session.cwd.to_string();
        let rows = session
            .rows
            .iter()
            .chain(&session.live)
            .enumerate()
            .filter(|(_, r)| {
                matches!(
                    r,
                    Row::User(_)
                        | Row::Answer(_)
                        | Row::Tool(crate::session::Tool { image: Some(_), .. })
                )
            })
            .map(|(i, r)| (make_anchor(session, i), r.clone()))
            .collect::<Vec<_>>();
        let work = cx.background_executor().spawn(async move {
            let mut entries = Vec::new();
            for (anchor, row) in rows.into_iter().rev() {
                let mut seen = HashSet::new();
                let mut add = |name: String,
                               path: String,
                               image: Option<ChatImage>,
                               fragment: Option<String>| {
                    if seen.insert((
                        path.clone(),
                        image.as_ref().map(ChatImage::identity),
                        fragment.clone(),
                    )) {
                        entries.push(Entry {
                            name,
                            path,
                            image,
                            fragment,
                            anchor: anchor.clone(),
                        });
                    }
                };
                let (message, user) = match &row {
                    Row::User(m) => (Some(m), true),
                    Row::Answer(a) => (Some(&a.body), false),
                    _ => (None, false),
                };
                let mut images = Vec::new();
                if let Some(m) = message {
                    images.extend_from_slice(m.images());
                    let mut paths = Vec::new();
                    if user {
                        paths.extend(
                            leading_file_refs(m.display())
                                .0
                                .into_iter()
                                .map(|(p, n)| (p.to_owned(), n.to_owned(), None)),
                        );
                    } else {
                        paths.extend(reply_files(m.display()).into_iter().filter_map(|part| {
                            match part {
                                ReplyPart::File { path, label } => {
                                    Some((path.to_owned(), label.to_owned(), None))
                                }
                                _ => None,
                            }
                        }));
                        paths.extend(
                            reply_links(m.display())
                                .1
                                .into_iter()
                                .map(|l| (l.path, l.label, l.fragment)),
                        );
                    }
                    for (path, name, fragment) in paths {
                        if !gateway_path(&path, true) {
                            continue;
                        }
                        let path = scoped_path(&cwd, &path).into_owned();
                        if let Some(img) = ChatImage::from_reference(&path) {
                            images.push(img)
                        } else {
                            add(name, path, None, fragment)
                        }
                    }
                } else if let Row::Tool(t) = row {
                    images.extend(t.image);
                }
                for mut image in images {
                    let path = match &image.source {
                        ImageSource::Gateway(p) => scoped_path(&cwd, p).into_owned(),
                        ImageSource::Inline { .. } => String::new(),
                    };
                    if !path.is_empty() {
                        image.source = ImageSource::Gateway(path.clone().into())
                    }
                    add(image.name.to_string(), path, Some(image), None);
                }
            }
            entries
        });
        self.files.collection.job = Some(cx.spawn(async move |view, cx| {
            let entries = work.await;
            let _ = view.update(cx, |this, cx| {
                this.files.collection.entries = entries.into();
                this.files.collection.job = None;
                cx.notify();
            });
        }));
        cx.notify();
    }

    pub(super) fn session_files_element(&self, cx: &mut Context<Self>) -> Div {
        let files = self.files.collection.entries.clone();
        let body = div()
            .w_full()
            .flex_1()
            .min_h_0()
            .flex()
            .flex_col()
            .px_3()
            .py_2();
        if files.is_empty() {
            let loading = self.files.collection.job.is_some()
                || self
                    .selected
                    .as_ref()
                    .is_some_and(|k| self.history_reads.contains_key(k));
            return body
                .items_center()
                .justify_center()
                .text_size(px(13.))
                .text_color(rgb(0x788393))
                .child(if loading {
                    "正在整理会话文件…"
                } else {
                    "本次会话暂无文件"
                });
        }
        let weak = cx.entity().downgrade();
        body.child(
            uniform_list("session-files", files.len(), move |range, _, _| {
                range
                    .map(|i| {
                        let entry = &files[i];
                        let mut row = div()
                            .id(("session-file-row", i))
                            .w_full()
                            .rounded(px(5.))
                            .px_2()
                            .hover(|s| s.bg(rgb(0xf5f7fa)))
                            .h(px(44.))
                            .flex()
                            .items_center()
                            .gap_2()
                            .border_b_1()
                            .border_color(rgb(0xebeef3))
                            .child(svg_symbol(
                                if entry.image.is_some() {
                                    icons::PHOTO
                                } else {
                                    icons::FILE_TEXT
                                },
                                16.,
                                0x617994,
                            ))
                            .child(
                                div()
                                    .flex_1()
                                    .min_w_0()
                                    .flex()
                                    .flex_col()
                                    .child(
                                        div()
                                            .truncate()
                                            .text_size(px(13.))
                                            .child(entry.name.clone()),
                                    )
                                    .child(
                                        div()
                                            .truncate()
                                            .text_size(px(10.))
                                            .text_color(rgb(0x84909d))
                                            .child(entry.path.clone()),
                                    ),
                            );
                        for (action, label) in ["定位消息", "预览", "下载"].into_iter().enumerate()
                        {
                            let entry = entry.clone();
                            let weak = weak.clone();
                            row = row.child(
                                control(label, label)
                                    .tooltip(move |w, c| Tooltip::new(label).build(w, c))
                                    .on_click(move |_, window, cx| {
                                        let _ = weak.update(cx, |this, cx| {
                                            this.activate_file(&entry, action, window, cx)
                                        });
                                    }),
                            );
                        }
                        row
                    })
                    .collect::<Vec<_>>()
            })
            .size_full(),
        )
    }

    fn activate_file(
        &mut self,
        entry: &Entry,
        action: usize,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(key) = self.selected.clone() else {
            return;
        };
        if action == 0 {
            let row = self
                .sessions
                .get(&key)
                .and_then(|s| find_anchor(s, &entry.anchor));
            self.close_files(window, cx);
            if let Some(row) = row {
                self.jump_message(row)
            } else {
                self.banner = Some("原消息已不在当前会话记录中".into())
            }
        } else if let Some(image) = &entry.image {
            self.collection_image(
                key,
                self.active_profile().to_owned(),
                image.clone(),
                action == 2,
                window,
                cx,
            )
        } else if action == 2 {
            self.download_conversation_file(&key, &entry.path, cx)
        } else {
            self.open_conversation_file(
                &key,
                entry.path.clone(),
                entry.fragment.clone(),
                window,
                cx,
            )
        }
        cx.notify();
    }
}
