use crate::i18n::text as tr;

use chrono::Utc;
use gpui::{
    Context, Div, IntoElement, SharedString, Stateful, Window, div, prelude::*, px, rgb, rgba,
};
use gpui_component::{
    Sizable,
    input::{Input, Textarea},
};

use crate::app::cron_tasks::{CronEditor, CronJob, JobAction, JobPage, cron_datetime};

use super::{
    ACCENT, DANGER, Desktop, INK, LINE, MUTED, SECONDARY, SELECTED, SURFACE, control, icon_button,
    icons, panel, primary, svg_symbol,
};

const RECENT_LIMIT: usize = 3;

impl Desktop {
    pub(super) fn cron_sidebar(&self, cx: &mut Context<Self>) -> Div {
        let expanded = self.cron_expanded();
        let page = self.cron.pages.get(&self.cron.profile);
        let mut section = div().flex_none().px_2().pt_1().pb_2().child(
            div()
                .id("cron-disclosure")
                .flex()
                .h(px(29.))
                .px_2()
                .items_center()
                .gap_2()
                .rounded(px(4.))
                .text_size(px(11.))
                .font_weight(gpui::FontWeight::SEMIBOLD)
                .text_color(rgb(ACCENT))
                .cursor_pointer()
                .hover(|style| style.bg(rgb(super::sidebar_view::SIDEBAR_HOVER)))
                .child(svg_symbol(icons::CLOCK, 13., ACCENT))
                .child(div().flex_1().child(tr("定时任务")))
                .child(svg_symbol(
                    if expanded {
                        icons::CHEVRON_DOWN
                    } else {
                        icons::CHEVRON_RIGHT
                    },
                    12.,
                    MUTED,
                ))
                .on_click(cx.listener(|this, _, window, cx| this.toggle_cron_sidebar(window, cx))),
        );
        if expanded {
            let jobs = page.map_or(&[][..], |page| page.jobs.as_slice());
            section = section
                .children(
                    jobs.iter()
                        .take(RECENT_LIMIT)
                        .map(|job| self.cron_row(job, None, cx)),
                )
                .children(jobs.is_empty().then(|| {
                    div()
                        .px_2()
                        .py_1()
                        .child(quiet(self.cron_list_status(page)))
                }))
                .child(
                    div().flex().justify_end().pr_1().child(
                        icon_button("cron-all", icons::ELLIPSIS, tr("管理定时任务"))
                            .size(px(23.))
                            .on_click(
                                cx.listener(|this, _, window, cx| this.open_cron(None, window, cx)),
                            ),
                    ),
                );
        }
        section
    }

    fn cron_list_status(&self, page: Option<&JobPage>) -> &'static str {
        if self.out.is_none() {
            tr("网关未连接")
        } else if page.is_some_and(|page| page.error.is_some()) {
            tr("定时任务读取失败")
        } else if page.is_some_and(|page| page.ready) {
            tr("暂无定时任务")
        } else {
            tr("正在读取定时任务…")
        }
    }

    fn cron_row(
        &self,
        job: &CronJob,
        selected: Option<bool>,
        cx: &mut Context<Self>,
    ) -> Stateful<Div> {
        let id = job.id.clone();
        let (state, color) = self.cron_status(job);
        let management = selected.is_some();
        div()
            .id(SharedString::from(format!("cron-job-{}", job.id)))
            .flex()
            .flex_none()
            .h(px(if management { 34. } else { 26. }))
            .items_center()
            .gap_2()
            .px_2()
            .rounded(px(4.))
            .text_size(px(12.))
            .cursor_pointer()
            .when(selected == Some(true), |row| row.bg(rgb(SELECTED)))
            .hover(|style| {
                style.bg(rgb(if selected == Some(true) {
                    SELECTED
                } else if management {
                    0xf1f4f9
                } else {
                    super::sidebar_view::SIDEBAR_HOVER
                }))
            })
            .child(
                div()
                    .size(px(5.))
                    .mx(px(3.))
                    .flex_none()
                    .rounded_full()
                    .bg(rgb(color)),
            )
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .truncate()
                    .text_color(rgb(SECONDARY))
                    .child(job.title().to_owned()),
            )
            .child(
                div()
                    .flex_none()
                    .text_size(px(10.5))
                    .text_color(rgb(MUTED))
                    .child(state),
            )
            .on_click(cx.listener(move |this, _, window, cx| {
                if !management || !this.cron.busy {
                    this.open_cron(Some(id.clone()), window, cx);
                }
            }))
    }

    fn cron_status(&self, job: &CronJob) -> (String, u32) {
        if self
            .cron
            .triggering
            .contains(&(self.cron.profile.clone(), job.id.clone()))
        {
            (tr("执行中").into(), ACCENT)
        } else {
            job.status(Utc::now().timestamp())
        }
    }

    pub(super) fn cron_overlay(
        &self,
        window: &Window,
        cx: &mut Context<Self>,
    ) -> Option<Stateful<Div>> {
        if !self.cron.open {
            return None;
        }
        let page = self.cron.pages.get(&self.cron.profile);
        let jobs = page.map_or(&[][..], |page| page.jobs.as_slice());
        let selected = self.cron.selected.as_deref();
        let editor = self.cron.editor.as_ref();
        let job = jobs.iter().find(|job| Some(job.id.as_str()) == selected);
        let available = self.out.is_some() && !self.cron.busy;
        let width = (window.viewport_size().width - px(32.)).min(px(740.));
        let height = (window.viewport_size().height - px(104.)).min(px(550.));
        let content = match (editor, job) {
            (Some(editor), _) => self.cron_form(editor, available, cx),
            (None, Some(job)) => self.cron_detail(job, available, cx),
            (None, None) => div()
                .size_full()
                .flex()
                .flex_col()
                .items_center()
                .justify_center()
                .gap_2()
                .px_3()
                .child(svg_symbol(icons::CLOCK, 24., MUTED))
                .child(quiet(if jobs.is_empty() {
                    self.cron_list_status(page)
                } else {
                    tr("选择一项定时任务")
                }))
                .children(page.and_then(|page| page.error.clone()).map(cron_error)),
        };
        Some(
            div()
                .id("cron-backdrop")
                .absolute()
                .left_0()
                .right_0()
                .top(px(34.))
                .bottom(px(23.))
                .occlude()
                .bg(rgba(0x28374d3d))
                .flex()
                .items_center()
                .justify_center()
                .on_click(cx.listener(|this, _, window, cx| this.close_cron(window, cx)))
                .child(
                    panel()
                        .id("cron-overlay")
                        .w(width)
                        .h(height)
                        .shadow_lg()
                        .overflow_hidden()
                        .flex()
                        .flex_col()
                        .on_click(|_, _, cx| cx.stop_propagation())
                        .child(
                            div()
                                .h(px(43.))
                                .px_3()
                                .flex_none()
                                .flex()
                                .items_center()
                                .gap_2()
                                .border_b_1()
                                .border_color(rgb(LINE))
                                .bg(rgb(0xfafbfd))
                                .child(svg_symbol(icons::CLOCK, 15., MUTED))
                                .child(
                                    div()
                                        .font_weight(gpui::FontWeight::SEMIBOLD)
                                        .child(tr("定时任务")),
                                )
                                .child(
                                    div()
                                        .px(px(6.))
                                        .py(px(2.))
                                        .rounded(px(4.))
                                        .bg(rgb(0xedf1f7))
                                        .text_size(px(10.))
                                        .text_color(rgb(MUTED))
                                        .child(self.profile_label(&self.cron.profile)),
                                )
                                .child(div().flex_1())
                                .child(
                                    icon_button("reload-cron", icons::REFRESH, tr("刷新定时任务"))
                                        .on_click(cx.listener(|this, _, _, cx| {
                                            this.refresh_cron_jobs(cx);
                                            this.refresh_cron_runs(cx);
                                        })),
                                )
                                .child(
                                    icon_button("close-cron", icons::TAB_CLOSE, tr("关闭定时任务"))
                                        .on_click(cx.listener(|this, _, window, cx| {
                                            this.close_cron(window, cx)
                                        })),
                                ),
                        )
                        .child(
                            div()
                                .flex()
                                .flex_1()
                                .min_h_0()
                                .child(
                                    div()
                                        .w((width * 0.35).min(px(235.)))
                                        .flex_none()
                                        .flex()
                                        .flex_col()
                                        .border_r_1()
                                        .border_color(rgb(LINE))
                                        .bg(rgb(0xfafbfd))
                                        .child(
                                            div()
                                                .id("cron-job-list")
                                                .flex_1()
                                                .min_h_0()
                                                .overflow_y_scroll()
                                                .p_2()
                                                .children(jobs.iter().map(|job| {
                                                    self.cron_row(
                                                        job,
                                                        Some(
                                                            Some(job.id.as_str()) == selected
                                                                && editor.is_none(),
                                                        ),
                                                        cx,
                                                    )
                                                })),
                                        )
                                        .child(
                                            div()
                                                .p_2()
                                                .flex_none()
                                                .border_t_1()
                                                .border_color(rgb(LINE))
                                                .child(cron_button(
                                                    "cron-create",
                                                    tr("新建任务"),
                                                    available,
                                                    |this, window, cx| {
                                                        this.edit_cron(None, window, cx)
                                                    },
                                                    cx,
                                                )),
                                        ),
                                )
                                .child(div().flex_1().min_w_0().min_h_0().child(content)),
                        ),
                ),
        )
    }

    fn cron_detail(&self, job: &CronJob, available: bool, cx: &mut Context<Self>) -> Div {
        let (status, color) = self.cron_status(job);
        let busy_job = self
            .cron
            .triggering
            .contains(&(self.cron.profile.clone(), job.id.clone()));
        let running = busy_job || job.running();
        let toggle = if job.enabled {
            JobAction::Pause
        } else {
            JobAction::Resume
        };
        let id = job.id.clone();
        let edit = job.clone();
        let confirm_key = job.id.clone();
        let runs = self
            .cron
            .runs
            .get(&(self.cron.profile.clone(), job.id.clone()));
        let command = job
            .prompt
            .as_deref()
            .or(job.script.as_deref())
            .filter(|text| !text.trim().is_empty());
        div()
            .size_full()
            .flex()
            .flex_col()
            .child(
                div()
                    .id("cron-detail-scroll")
                    .flex_1()
                    .min_h_0()
                    .overflow_y_scroll()
                    .p_4()
                    .flex()
                    .flex_col()
                    .gap_3()
                    .child(
                        div()
                            .flex_none()
                            .text_size(px(16.))
                            .font_weight(gpui::FontWeight::SEMIBOLD)
                            .text_color(rgb(INK))
                            .child(job.title().to_owned()),
                    )
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap_2()
                            .flex_none()
                            .child(div().size(px(6.)).rounded_full().bg(rgb(color)))
                            .child(quiet(status)),
                    )
                    .child(detail(tr("计划"), job.schedule_label()))
                    .children(
                        cron_datetime(job.next_run_at.as_deref())
                            .map(|time| detail(tr("下次执行"), time)),
                    )
                    .children(
                        cron_datetime(job.last_run_at.as_deref())
                            .map(|time| detail(tr("上次执行"), time)),
                    )
                    .children(
                        job.deliver
                            .as_deref()
                            .filter(|target| !target.is_empty())
                            .map(|target| {
                                detail(
                                    tr("投递"),
                                    if target == "local" {
                                        tr("仅本地保存")
                                    } else {
                                        target
                                    },
                                )
                            }),
                    )
                    .children(
                        job.last_error
                            .as_deref()
                            .filter(|error| !error.is_empty())
                            .map(|error| cron_error(error.to_owned())),
                    )
                    .children(command.map(|text| {
                        div()
                            .flex_none()
                            .border_t_1()
                            .border_color(rgb(LINE))
                            .pt_2()
                            .child(detail(
                                if job.prompt.as_deref().is_none_or(str::is_empty) {
                                    tr("脚本")
                                } else {
                                    tr("执行指令")
                                },
                                text,
                            ))
                    }))
                    .child(
                        div()
                            .flex_none()
                            .border_t_1()
                            .border_color(rgb(LINE))
                            .pt_2()
                            .child(
                                div()
                                    .pb_1()
                                    .text_size(px(11.))
                                    .font_weight(gpui::FontWeight::SEMIBOLD)
                                    .text_color(rgb(MUTED))
                                    .child(tr("最近执行")),
                            )
                            .children(runs.and_then(|runs| runs.error.clone()).map(cron_error))
                            .children(runs.is_none_or(|runs| runs.rows.is_empty()).then(|| {
                                quiet(if runs.is_some_and(|runs| runs.ready) {
                                    tr("暂无执行记录")
                                } else if self.out.is_none() {
                                    tr("网关未连接")
                                } else if runs.is_some_and(|runs| runs.error.is_some()) {
                                    tr("执行记录读取失败")
                                } else {
                                    tr("正在读取执行记录…")
                                })
                            }))
                            .children(runs.into_iter().flat_map(|runs| &runs.rows).map(|run| {
                                let row = run.row.clone();
                                div()
                                    .id(SharedString::from(format!("cron-run-{}", run.row.id)))
                                    .px_2()
                                    .py(px(6.))
                                    .rounded(px(4.))
                                    .border_b_1()
                                    .border_color(rgb(LINE))
                                    .child(
                                        div()
                                            .flex()
                                            .items_center()
                                            .gap_2()
                                            .child(quiet(run.label.clone()).flex_none())
                                            .children(run.outcome.map(|(label, color)| {
                                                quiet(label).flex_none().text_color(rgb(color))
                                            }))
                                            .child(
                                                div()
                                                    .min_w_0()
                                                    .flex_1()
                                                    .truncate()
                                                    .text_color(rgb(SECONDARY))
                                                    .text_size(px(11.))
                                                    .child(run.row.title.clone()),
                                            )
                                            .children(run.can_open.then(|| {
                                                svg_symbol(icons::CHEVRON_RIGHT, 12., MUTED)
                                            })),
                                    )
                                    .children(
                                        (!run.can_open)
                                            .then(|| run.preview.as_deref())
                                            .flatten()
                                            .filter(|text| {
                                                !text.is_empty() && *text != run.row.title.as_ref()
                                            })
                                            .map(|text| quiet(text.to_owned()).pt_1()),
                                    )
                                    .when(run.can_open, |view| {
                                        view.cursor_pointer()
                                            .hover(|style| style.bg(rgb(0xf1f4f9)))
                                            .on_click(cx.listener(move |this, _, window, cx| {
                                                this.close_cron(window, cx);
                                                this.open_session(&row, true, window, cx);
                                            }))
                                    })
                            })),
                    ),
            )
            .children(
                self.cron
                    .error
                    .clone()
                    .map(|error| cron_error(error).mx_3().mb_2()),
            )
            .child(
                div()
                    .flex_none()
                    .px_3()
                    .py_2()
                    .border_t_1()
                    .border_color(rgb(LINE))
                    .child(if let Some(action) = self.cron.confirmation {
                        div()
                            .flex()
                            .flex_wrap()
                            .items_center()
                            .gap_2()
                            .child(
                                quiet(match action {
                                    JobAction::Delete => tr("删除此定时任务？"),
                                    _ => tr("现在执行此定时任务？"),
                                })
                                .flex_1(),
                            )
                            .child(
                                control("cron-cancel-action", tr("取消")).on_click(cx.listener(
                                    |this, _, _, cx| {
                                        this.cron.confirmation = None;
                                        cx.notify();
                                    },
                                )),
                            )
                            .child(
                                primary("cron-confirm-action", action.label(), available).on_click(
                                    cx.listener(move |this, _, _, cx| {
                                        if available {
                                            this.act_on_cron(confirm_key.clone(), action, cx);
                                        }
                                    }),
                                ),
                            )
                    } else {
                        div()
                            .flex()
                            .flex_wrap()
                            .items_center()
                            .gap_1()
                            .child(cron_button(
                                "cron-edit",
                                tr("编辑"),
                                available && !running,
                                move |this, window, cx| this.edit_cron(Some(&edit), window, cx),
                                cx,
                            ))
                            .child(cron_button(
                                "cron-toggle",
                                toggle.label(),
                                available && !running && job.state.as_deref() != Some("completed"),
                                move |this, _, cx| this.act_on_cron(id.clone(), toggle, cx),
                                cx,
                            ))
                            .child(cron_button(
                                "cron-run-now",
                                if running {
                                    tr("执行中")
                                } else {
                                    tr("立即执行")
                                },
                                available && !running,
                                |this, _, cx| {
                                    this.cron.confirmation = Some(JobAction::Run);
                                    cx.notify();
                                },
                                cx,
                            ))
                            .child(div().flex_1())
                            .child(cron_button(
                                "cron-delete",
                                tr("删除"),
                                available && !running,
                                |this, _, cx| {
                                    this.cron.confirmation = Some(JobAction::Delete);
                                    cx.notify();
                                },
                                cx,
                            ))
                    }),
            )
    }

    fn cron_form(&self, editor: &CronEditor, available: bool, cx: &mut Context<Self>) -> Div {
        div()
            .size_full()
            .flex()
            .flex_col()
            .child(
                div()
                    .id("cron-form-scroll")
                    .flex_1()
                    .min_h_0()
                    .overflow_y_scroll()
                    .p_4()
                    .flex()
                    .flex_col()
                    .gap_3()
                    .child(
                        div()
                            .flex_none()
                            .text_size(px(16.))
                            .font_weight(gpui::FontWeight::SEMIBOLD)
                            .child(if editor.id.is_some() {
                                tr("编辑任务")
                            } else {
                                tr("新建任务")
                            }),
                    )
                    .child(field(
                        tr("任务名称"),
                        Input::new(&editor.name).small().disabled(!available),
                    ))
                    .child(field(
                        tr("计划"),
                        Input::new(&editor.schedule).small().disabled(!available),
                    ))
                    .child(field(
                        tr("投递目标"),
                        Input::new(&editor.deliver).small().disabled(!available),
                    ))
                    .children((!editor.script_only).then(|| {
                        field(
                            tr("执行指令"),
                            Textarea::new(&editor.prompt).small().disabled(!available),
                        )
                    })),
            )
            .children(
                self.cron
                    .error
                    .clone()
                    .map(|error| cron_error(error).mx_3().mb_2()),
            )
            .child(
                div()
                    .flex_none()
                    .flex()
                    .justify_end()
                    .gap_2()
                    .p_2()
                    .border_t_1()
                    .border_color(rgb(LINE))
                    .child(cron_button(
                        "cron-cancel-edit",
                        tr("取消"),
                        !self.cron.busy,
                        |this, _, cx| {
                            this.cron.editor = None;
                            this.cron.error = None;
                            cx.notify();
                        },
                        cx,
                    ))
                    .child(
                        primary(
                            "cron-save",
                            if self.cron.busy {
                                tr("正在保存…")
                            } else {
                                tr("保存")
                            },
                            available,
                        )
                        .on_click(cx.listener(move |this, _, _, cx| {
                            if available {
                                this.save_cron(cx);
                            }
                        })),
                    ),
            )
    }
}

fn quiet(text: impl Into<SharedString>) -> Div {
    div()
        .text_size(px(11.))
        .line_height(px(16.))
        .text_color(rgb(MUTED))
        .child(text.into())
}

fn cron_error(text: impl Into<SharedString>) -> Div {
    quiet(text)
        .text_color(rgb(DANGER))
        .bg(rgb(0xfff3f2))
        .rounded(px(4.))
        .px_2()
        .py_1()
}

fn detail(label: &'static str, text: impl Into<SharedString>) -> Div {
    div()
        .flex_none()
        .flex()
        .items_start()
        .gap_2()
        .child(quiet(label).w(px(62.)).flex_none())
        .child(
            div()
                .min_w_0()
                .text_size(px(12.))
                .line_height(px(17.))
                .text_color(rgb(SECONDARY))
                .child(text.into()),
        )
}

fn field(label: &'static str, input: impl IntoElement) -> Div {
    div()
        .flex_none()
        .flex()
        .flex_col()
        .gap_1()
        .child(quiet(label))
        .child(input)
}

fn cron_button(
    id: &'static str,
    label: &'static str,
    enabled: bool,
    action: impl Fn(&mut Desktop, &mut Window, &mut Context<Desktop>) + 'static,
    cx: &mut Context<Desktop>,
) -> Stateful<Div> {
    control(id, label)
        .bg(rgb(SURFACE))
        .when(!enabled, |button| button.opacity(0.55).cursor_default())
        .on_click(cx.listener(move |this, _, window, cx| {
            if enabled {
                action(this, window, cx);
            }
        }))
}
