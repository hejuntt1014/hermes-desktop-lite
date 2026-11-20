use std::collections::{HashMap, HashSet};

use chrono::{Local, NaiveDate, Utc};
use gpui::{
    Context, Div, IntoElement, ListAlignment, ListOffset, ListSizingBehavior, ListState, div, list,
    prelude::*, px, rgb,
};
use gpui_component::scroll::Scrollbar;

use crate::session::Summary;

use super::{
    ACCENT, Desktop, MUTED, caption, control, icons, local_day, recent_session_cutoff,
    session_date_group, sidebar_tree, svg_symbol,
};

enum Item {
    Section {
        label: &'static str,
        pinned: bool,
    },
    Date(String),
    EmptyPins,
    EmptySessions,
    Session {
        row: Summary,
        depth: usize,
        last: bool,
    },
    More,
}

impl Item {
    fn same_key(&self, other: &Self) -> bool {
        match (self, other) {
            (Self::Section { label: a, .. }, Self::Section { label: b, .. }) => a == b,
            (Self::Date(a), Self::Date(b)) => a == b,
            (Self::Session { row: a, .. }, Self::Session { row: b, .. }) => {
                a.id == b.id && a.profile == b.profile
            }
            (Self::More, Self::More) => true,
            (Self::EmptyPins, Self::EmptyPins) | (Self::EmptySessions, Self::EmptySessions) => true,
            _ => false,
        }
    }
}

pub(in crate::app) struct SidebarList {
    items: Vec<Item>,
    state: ListState,
    dirty: bool,
    today: Option<NaiveDate>,
    query: String,
    profile: String,
    archived: bool,
    more: bool,
    restore_scroll: Option<ListOffset>,
}

impl Default for SidebarList {
    fn default() -> Self {
        Self {
            items: Vec::new(),
            state: ListState::new(0, ListAlignment::Top, px(112.)),
            dirty: true,
            today: None,
            query: String::new(),
            profile: String::new(),
            archived: false,
            more: false,
            restore_scroll: None,
        }
    }
}

impl SidebarList {
    pub(in crate::app) fn invalidate(&mut self) {
        self.dirty = true;
    }

    pub(in crate::app) fn scroll_position(&self) -> ListOffset {
        self.restore_scroll
            .unwrap_or_else(|| self.state.logical_scroll_top())
    }

    pub(in crate::app) fn change_scope(&mut self, scroll: Option<ListOffset>) {
        self.restore_scroll = scroll;
        self.dirty = true;
    }
}

impl Desktop {
    pub(super) fn pin_index(&self, key: &str) -> Option<usize> {
        self.sidebar_list.items.iter().position(
            |item| matches!(item, Item::Session { row, .. } if row.pinned && row.pin_order_key() == key),
        )
    }

    pub(super) fn refresh_sidebar_layout(&mut self) {
        let now = Utc::now().timestamp();
        let today = local_day(now).unwrap_or_else(|| Local::now().date_naive());
        let searching = !self.query.is_empty();
        let more = self.next.is_some() && !searching;
        let profile = &self.profiles.scope.profile;
        let visible = &self.sidebar_list;
        let switched = visible.query != self.query
            || visible.profile != self.profiles.scope.profile
            || visible.archived != self.archived_only;
        if !visible.dirty && !switched && visible.today == Some(today) && visible.more == more {
            return;
        }
        let order = self
            .workspace()
            .and_then(|workspace| workspace.pinned_order.get(profile))
            .map(Vec::as_slice)
            .unwrap_or_default();
        let mut items = project(
            &self.rows,
            today,
            searching,
            self.archived_only,
            self.profiles.ready,
            order,
        );
        if more {
            items.push(Item::More);
        }
        let visible = &mut self.sidebar_list;
        if switched || (visible.items.is_empty() && !items.is_empty()) {
            visible.state.reset(items.len());
            let scroll = visible.restore_scroll.take().unwrap_or(ListOffset {
                item_ix: 0,
                offset_in_item: px(0.),
            });
            visible.state.scroll_to(ListOffset {
                item_ix: scroll.item_ix.min(items.len().saturating_sub(1)),
                ..scroll
            });
        } else {
            let prefix = visible
                .items
                .iter()
                .zip(&items)
                .take_while(|(a, b)| a.same_key(b))
                .count();
            if prefix != visible.items.len() || prefix != items.len() {
                let cursor = visible.state.logical_scroll_top();
                let mapped = visible
                    .items
                    .get(cursor.item_ix)
                    .and_then(|chosen| items.iter().position(|item| item.same_key(chosen)));
                visible
                    .state
                    .splice(prefix..visible.items.len(), items.len() - prefix);
                if let Some(item_ix) = mapped {
                    visible.state.scroll_to(ListOffset {
                        item_ix,
                        offset_in_item: cursor.offset_in_item,
                    });
                }
            }
        }
        visible.items = items;
        visible.today = Some(today);
        visible.query.clone_from(&self.query);
        visible.profile.clone_from(&self.profiles.scope.profile);
        visible.archived = self.archived_only;
        visible.more = more;
        visible.dirty = false;
    }

    pub(super) fn sidebar_sessions(&self, cx: &mut Context<Self>) -> Div {
        if self.sidebar_list.items.is_empty() {
            let label = if self.out.is_none() {
                ""
            } else if self.refreshing && !self.profiles.ready {
                "正在读取会话…"
            } else if !self.query.is_empty() {
                "没有匹配的会话"
            } else if self.archived_only {
                "暂无归档会话"
            } else {
                "暂无会话"
            };
            return div().flex_1().min_h_0().px_4().pt_2().child(caption(label));
        }
        let entity = cx.entity();
        let now = Utc::now().timestamp();
        let list = list(self.sidebar_list.state.clone(), move |index, _, app| {
            let desktop = entity.read(app);
            let Some(item) = desktop.sidebar_list.items.get(index) else {
                return div().into_any_element();
            };
            let row = match item {
                Item::Section { label, pinned } => div()
                    .h(px(26.))
                    .flex()
                    .items_center()
                    .gap_2()
                    .px_2()
                    .text_size(px(11.))
                    .font_weight(gpui::FontWeight::SEMIBOLD)
                    .text_color(rgb(ACCENT))
                    .child(svg_symbol(
                        if *pinned {
                            icons::PIN
                        } else {
                            icons::DISCUSSION
                        },
                        11.,
                        ACCENT,
                    ))
                    .child(*label)
                    .into_any_element(),
                Item::Date(label) => div()
                    .h(px(25.))
                    .flex()
                    .items_center()
                    .px_2()
                    .text_size(px(11.))
                    .text_color(rgb(MUTED))
                    .child(label.clone())
                    .into_any_element(),
                Item::Session { row, depth, last } => desktop.session_row(
                    sidebar_tree::Entry {
                        row,
                        depth: *depth,
                        last: *last,
                    },
                    now,
                    entity.downgrade(),
                ),
                Item::EmptyPins => div()
                    .py_1()
                    .pl(px(27.))
                    .pr_2()
                    .text_size(px(11.))
                    .line_height(px(16.))
                    .text_color(rgb(MUTED))
                    .child("Shift + 单击置顶 · 拖动排序")
                    .into_any_element(),
                Item::EmptySessions => div()
                    .px_2()
                    .py_1()
                    .child(caption("暂无会话"))
                    .into_any_element(),
                Item::More => {
                    let label = if desktop.refreshing {
                        "正在读取会话…"
                    } else {
                        "加载更多"
                    };
                    let weak = entity.downgrade();
                    control("sidebar-more", label)
                        .on_click(move |_, window, app| {
                            let _ = weak.update(app, |desktop, cx| {
                                if let Some(next) = desktop
                                    .next
                                    .filter(|_| !desktop.refreshing && desktop.query.is_empty())
                                {
                                    desktop.fetch_list(next, false, window, cx);
                                }
                            });
                        })
                        .into_any_element()
                }
            };
            div()
                .w_full()
                .px_2()
                .pb(px(2.))
                .child(row)
                .into_any_element()
        })
        .with_sizing_behavior(ListSizingBehavior::Auto)
        .flex_1()
        .min_h_0();
        div()
            .relative()
            .flex_1()
            .min_h_0()
            .flex()
            .flex_col()
            .child(list)
            .child(Scrollbar::vertical(&self.sidebar_list.state))
    }

    pub(super) fn reorder_pins(
        &mut self,
        profile: &str,
        source: &str,
        target: &str,
        cx: &mut Context<Self>,
    ) {
        if source == target
            || self.profiles.scope.profile != profile
            || self.archived_only
            || !self.query.is_empty()
        {
            return;
        }
        let mut order: Vec<_> = self
            .sidebar_list
            .items
            .iter()
            .filter_map(|item| match item {
                Item::Session { row, .. } if row.pinned => Some(row.pin_order_key().to_owned()),
                _ => None,
            })
            .collect();
        let Some(from) = order.iter().position(|key| key == source) else {
            return;
        };
        let Some(to) = order.iter().position(|key| key == target) else {
            return;
        };
        let moved = order.remove(from);
        order.insert(to, moved);
        self.workspace_mut()
            .pinned_order
            .insert(profile.to_owned(), order);
        self.sidebar_list.invalidate();
        self.persist(cx);
        cx.notify();
    }
}

fn project(
    rows: &[Summary],
    today: NaiveDate,
    searching: bool,
    archived: bool,
    ready: bool,
    order: &[String],
) -> Vec<Item> {
    let mut items = Vec::with_capacity(rows.len());
    for pinned in [true, false] {
        let matching: Vec<_> = rows.iter().filter(|row| row.pinned == pinned).collect();
        if matching.is_empty() && (!ready || searching || archived) {
            continue;
        }
        if !archived || searching {
            items.push(Item::Section {
                label: if pinned {
                    "已置顶"
                } else if searching {
                    "搜索结果"
                } else {
                    "会话"
                },
                pinned,
            });
        }
        if matching.is_empty() {
            items.push(if pinned {
                Item::EmptyPins
            } else {
                Item::EmptySessions
            });
            continue;
        }
        let mut entries = if searching {
            matching
                .into_iter()
                .map(|row| sidebar_tree::Entry {
                    row,
                    depth: 0,
                    last: true,
                })
                .collect()
        } else {
            sidebar_tree::entries(&matching, pinned)
        };
        if pinned && !searching && !archived {
            let order: HashMap<_, _> = order
                .iter()
                .enumerate()
                .map(|(i, id)| (id.as_str(), i))
                .collect();
            entries.sort_by_key(|entry| {
                order
                    .get(entry.row.pin_order_key())
                    .copied()
                    .unwrap_or(usize::MAX)
            });
            for entry in &mut entries {
                entry.depth = 0;
                entry.last = true;
            }
        }
        let grouped = !pinned && !searching;
        let cutoff = if grouped {
            let roots = entries
                .iter()
                .filter(|entry| entry.depth == 0)
                .map(|entry| entry.row)
                .collect::<Vec<_>>();
            recent_session_cutoff(&roots, today)
        } else {
            i64::MIN
        };
        let mut dates = HashSet::new();
        for (position, entry) in entries.into_iter().enumerate() {
            if grouped && entry.depth == 0 && entry.row.updated_at < cutoff {
                let date = session_date_group(entry.row.updated_at, today);
                if !date.is_empty() && dates.insert(date.clone()) && position > 0 {
                    items.push(Item::Date(date));
                }
            }
            items.push(Item::Session {
                row: entry.row.clone(),
                depth: entry.depth,
                last: entry.last,
            });
        }
    }
    items
}
