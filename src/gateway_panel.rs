use crate::theme::{ink, rgb};

use crate::i18n::text as tr;

use anyhow::{Result, bail};
use gpui::{
    Anchor, AnyElement, Context, Div, FontWeight, IntoElement, SharedString, Task, Window, div,
    prelude::*, px,
};
use gpui_component::{
    button::{Button, ButtonVariants},
    input::Input,
    popover::Popover,
};
use serde_json::{Value, json};

use crate::{
    gateway::Gateway,
    icons,
    local_gateway::LocalTickets,
    settings::{GatewayMode, RemoteAuth, Settings},
    style::{ACCENT, INK, MUTED},
};

use super::{
    Call, Desktop,
    settings_view::SettingsPage,
    view::{control, primary, svg_symbol},
};

const LOCAL_LABEL: &str = "本地网关";
const REMOTE_LABEL: &str = "远程网关";

pub(super) struct GatewayPanel {
    mode: GatewayMode,
    auth: RemoteAuth,
    job: Option<Task<()>>,
    probing: bool,
    feedback: Option<SharedString>,
    switch_open: bool,
    status_open: bool,
    diagnostics_job: Option<Task<()>>,
    diagnostics: Option<Diagnostics>,
    inference: Option<bool>,
    inference_pending: bool,
}

struct Diagnostics {
    running: Option<bool>,
    platforms: Vec<(String, String)>,
    logs: Option<SharedString>,
}

impl GatewayPanel {
    pub fn new(mode: GatewayMode, auth: RemoteAuth) -> Self {
        Self {
            mode,
            auth,
            job: None,
            probing: false,
            feedback: None,
            switch_open: false,
            status_open: false,
            diagnostics_job: None,
            diagnostics: None,
            inference: None,
            inference_pending: false,
        }
    }

    pub fn clear_probe(&mut self) {
        self.feedback = None;
        if self.probing {
            self.job = None;
            self.probing = false;
        }
    }

    pub fn connection_changed(&mut self) {
        self.switch_open = false;
        self.status_open = false;
        self.diagnostics = None;
        self.diagnostics_job = None;
        self.inference = None;
        self.inference_pending = false;
    }
}

impl Desktop {
    pub(super) fn restore_gateway(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        match self.settings.gateway_mode {
            GatewayMode::Local => self.connect_local(true, window, cx),
            GatewayMode::Remote if !self.settings.address.is_empty() => {
                let address = self.settings.address.clone();
                match self.remote_target(&address, self.gateway_panel.auth, "", false) {
                    Ok(gateway) => {
                        if !self.settings.display.restore_session {
                            self.workspace_mut().select_empty_draft();
                        }
                        self.connect(gateway, window, cx);
                    }
                    Err(error) => self.show_connection_error(error.to_string(), cx),
                }
            }
            GatewayMode::Remote => {}
        }
    }

    pub(super) fn remote_address_changed(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.gateway_panel.clear_probe();
        self.settings_view.connection_error = None;
        if !self.token.read(cx).value().is_empty() {
            self.token
                .update(cx, |field, cx| field.set_value("", window, cx));
        }
        cx.notify();
    }

    fn remote_target(
        &self,
        address: &str,
        auth: RemoteAuth,
        typed: &str,
        store: bool,
    ) -> Result<Gateway> {
        if address.trim().is_empty() {
            bail!(tr("请输入远程网关地址"));
        }
        let url = Gateway::normalize_address(address)?;
        let token = if auth == RemoteAuth::Token {
            if typed.trim().is_empty() {
                Settings::saved_token(url.as_str())?
            } else {
                typed.trim().to_owned()
            }
        } else {
            String::new()
        };
        if auth == RemoteAuth::Token && token.is_empty() {
            bail!(tr("请输入此地址的访问令牌"));
        }
        let target = Gateway::new(url.as_str(), auth, token.clone())?;
        if store && auth == RemoteAuth::Token && !typed.trim().is_empty() {
            Settings::credential(url.as_str())?.set_password(&token)?;
        }
        Ok(self
            .gateway
            .as_ref()
            .filter(|gateway| gateway.uses_same_connection(&target))
            .cloned()
            .unwrap_or(target))
    }

    fn test_gateway(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.gateway_panel.job.is_some() {
            return;
        }
        self.settings_view.connection_error = None;
        self.gateway_panel.feedback = None;
        let address = self.address.read(cx).value();
        let typed = self.token.read(cx).value();
        let gateway = match self.remote_target(&address, self.gateway_panel.auth, &typed, false) {
            Ok(gateway) => gateway,
            Err(error) => {
                self.show_connection_error(error.to_string(), cx);
                return;
            }
        };
        let job = self
            .runtime
            .spawn(async move { gateway.test_remote().await });
        self.gateway_panel.probing = true;
        self.gateway_panel.job = Some(cx.spawn_in(window, async move |view, cx| {
            let result = job.await;
            let _ = view.update_in(cx, |this, _, cx| {
                this.gateway_panel.job = None;
                this.gateway_panel.probing = false;
                match result {
                    Ok(Ok(version)) => {
                        let label = version.map_or_else(
                            || tr("连接与认证通过").to_owned(),
                            |version| {
                                crate::i18n::format_text!(
                                    "连接与认证通过 · v{}",
                                    "Connection and authentication successful · v{}",
                                    version.trim_start_matches('v')
                                )
                            },
                        );
                        this.gateway_panel.feedback = Some(label.into());
                    }
                    Ok(Err(error)) => this.show_connection_error(error.to_string(), cx),
                    Err(_) => this.show_connection_error(tr("无法完成远程连接测试").into(), cx),
                }
                cx.notify();
            });
        }));
        cx.notify();
    }

    fn apply_gateway(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.gateway_panel.job.is_some() {
            return;
        }
        if self.gateway_panel.mode == GatewayMode::Local {
            self.connect_local(false, window, cx);
            return;
        }
        let address = self.address.read(cx).value();
        let typed = self.token.read(cx).value();
        let target = match self.remote_target(&address, self.gateway_panel.auth, &typed, true) {
            Ok(target) => target,
            Err(error) => {
                self.show_connection_error(error.to_string(), cx);
                return;
            }
        };
        self.remember_reading();
        self.settings.gateway_mode = GatewayMode::Remote;
        self.settings.remote_auth = Some(target.auth);
        self.settings.address = target.url.as_str().to_owned();
        self.token
            .update(cx, |field, cx| field.set_value("", window, cx));
        self.close_settings(window, cx);
        self.persist(cx);
        self.activate_gateway(target, window, cx);
    }

    fn connect_local(&mut self, restore: bool, window: &mut Window, cx: &mut Context<Self>) {
        if self.gateway_panel.job.is_some() {
            return;
        }
        self.settings_view.connection_error = None;
        self.gateway_panel.feedback = None;
        let local = self.runtime.spawn(LocalTickets::connect());
        self.gateway_panel.job = Some(cx.spawn_in(window, async move |view, cx| {
            let result = local.await;
            let _ = view.update_in(cx, |this, window, cx| {
                this.gateway_panel.job = None;
                if this.out.is_none() {
                    this.status = "未连接";
                }
                match result {
                    Ok(Ok(target)) => {
                        this.remember_reading();
                        this.settings.gateway_mode = GatewayMode::Local;
                        if restore && !this.settings.display.restore_session {
                            this.workspace_mut().select_empty_draft();
                        }
                        this.close_settings(window, cx);
                        this.persist(cx);
                        this.activate_gateway(target, window, cx);
                    }
                    Ok(Err(error)) => this.show_connection_error(error.to_string(), cx),
                    Err(_) => this.show_connection_error(tr("无法准备本地网关").into(), cx),
                }
                cx.notify();
            });
        }));
        if self.out.is_none() {
            self.status = "正在准备本地网关";
        }
        cx.notify();
    }

    fn activate_gateway(&mut self, gateway: Gateway, window: &mut Window, cx: &mut Context<Self>) {
        self.banner = None;
        self.gateway_panel.connection_changed();
        if self
            .gateway
            .as_ref()
            .is_some_and(|current| current.uses_same_connection(&gateway))
            && !gateway.is_local()
        {
            self.restart_active_connection(gateway, window, cx);
        } else {
            self.connect(gateway, window, cx);
        }
    }

    fn restart_active_connection(
        &mut self,
        gateway: Gateway,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.gateway_panel.connection_changed();
        self.connection = None;
        self.out = None;
        for session in self.sessions.values_mut() {
            session.attached = false;
            session.loading = false;
            session.submitting = false;
        }
        for (_, call) in std::mem::take(&mut self.pending) {
            self.lost(call, false);
        }
        self.restart(gateway, window, cx);
    }

    fn switch_gateway(&mut self, mode: GatewayMode, window: &mut Window, cx: &mut Context<Self>) {
        self.gateway_panel.switch_open = false;
        if self.gateway_panel.job.is_some() && !self.gateway_panel.probing {
            cx.notify();
            return;
        }
        self.gateway_panel.mode = mode;
        self.gateway_panel.clear_probe();
        if mode == self.settings.gateway_mode && self.out.is_some() {
            cx.notify();
            return;
        }
        if mode == GatewayMode::Local {
            self.connect_local(false, window, cx);
        } else {
            let address = self.settings.address.clone();
            let auth = self.settings.suggested_auth();
            self.gateway_panel.auth = auth;
            self.address
                .update(cx, |field, cx| field.set_value(&address, window, cx));
            match self.remote_target(&address, auth, "", false) {
                Ok(gateway) => {
                    self.remember_reading();
                    self.settings.gateway_mode = GatewayMode::Remote;
                    self.persist(cx);
                    self.activate_gateway(gateway, window, cx);
                }
                Err(_) => self.open_settings(SettingsPage::Connection, window, cx),
            }
        }
    }

    fn sign_out_remote(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.gateway_panel.job.is_some() {
            return;
        }
        let Some(gateway) = self
            .gateway
            .clone()
            .filter(|gateway| !gateway.is_local() && gateway.auth == RemoteAuth::Password)
        else {
            return;
        };
        let auth = gateway.clone();
        let job = self.runtime.spawn(async move { auth.forget_oauth().await });
        self.gateway_panel.job = Some(cx.spawn_in(window, async move |view, cx| {
            let result = job.await;
            let _ = view.update_in(cx, |this, window, cx| {
                this.gateway_panel.job = None;
                match result {
                    Ok(Ok(())) => {
                        this.close_settings(window, cx);
                        this.activate_gateway(gateway, window, cx);
                    }
                    Ok(Err(error)) => this.show_connection_error(error.to_string(), cx),
                    Err(_) => this.show_connection_error(tr("无法退出本机登录").into(), cx),
                }
                cx.notify();
            });
        }));
        cx.notify();
    }

    pub(super) fn gateway_form(&self, compact: bool, cx: &mut Context<Self>) -> Div {
        let mode = self.gateway_panel.mode;
        let auth = self.gateway_panel.auth;
        let busy = self.gateway_panel.job.is_some();
        let mut form = div().w_full().min_w_0().flex().flex_col().gap_3();
        if let Some(url) = self.login_url.clone() {
            return form
                .child(
                    div()
                        .max_w(px(320.))
                        .text_size(px(13.))
                        .line_height(px(21.))
                        .text_color(ink(0x66718b))
                        .child(tr(
                            "在浏览器中使用网关用户名和密码登录。登录完成后，客户端会自动连接。",
                        )),
                )
                .child(
                    div()
                        .flex()
                        .items_center()
                        .gap(px(9.))
                        .child(
                            div()
                                .id("gateway-browser-login")
                                .h(px(38.))
                                .px_3()
                                .rounded(px(7.))
                                .aria_label(tr("在浏览器中登录"))
                                .flex()
                                .flex_none()
                                .items_center()
                                .gap(px(8.))
                                .bg(rgb(0x3e53ad))
                                .text_color(ink(0xffffff))
                                .text_size(px(13.))
                                .font_weight(FontWeight::SEMIBOLD)
                                .cursor_pointer()
                                .hover(|button| button.bg(rgb(0x344998)))
                                .child(tr("在浏览器中登录"))
                                .child(svg_symbol(icons::LINK_EXTERNAL, 13., 0xf0f2ff))
                                .on_click(move |_, _, cx| cx.open_url(&url)),
                        )
                        .child(
                            control("gateway-cancel-login", tr("返回"))
                                .h(px(38.))
                                .px_3()
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.connection = None;
                                    this.gateway = None;
                                    this.login_url = None;
                                    this.status = "未连接";
                                    cx.notify();
                                })),
                        ),
                );
        }
        form = form.child(heading(tr("连接模式"))).child(
            div().flex().gap_2().children(
                [
                    (
                        GatewayMode::Local,
                        tr(LOCAL_LABEL),
                        icons::DESKTOP,
                        tr("连接本机安装的 Hermes Agent"),
                    ),
                    (
                        GatewayMode::Remote,
                        tr(REMOTE_LABEL),
                        icons::WORLD,
                        tr("连接已部署的 Hermes 网关"),
                    ),
                ]
                .into_iter()
                .enumerate()
                .map(|(index, (choice, label, icon, text))| {
                    let selected = choice == mode;
                    div()
                        .id(("gateway-mode", index))
                        .flex_1()
                        .min_w_0()
                        .rounded(px(5.))
                        .p_2()
                        .border_1()
                        .border_color(rgb(if selected { ACCENT } else { 0xdde5ef }))
                        .bg(rgb(if selected { 0xf0f5ff } else { 0xf6f8fb }))
                        .flex()
                        .flex_col()
                        .gap_1()
                        .when(!busy, |card| {
                            card.cursor_pointer().hover(|card| card.bg(rgb(0xeaf1fd)))
                        })
                        .child(
                            div()
                                .flex()
                                .items_center()
                                .gap_2()
                                .text_size(px(13.))
                                .text_color(ink(INK))
                                .child(svg_symbol(icon, 15., MUTED))
                                .child(div().flex_1().child(label))
                                .when(selected, |row| {
                                    row.child(div().text_color(ink(ACCENT)).child("✓"))
                                }),
                        )
                        .child(div().text_size(px(11.)).text_color(ink(MUTED)).child(text))
                        .on_click(cx.listener(move |this, _, _, cx| {
                            if !busy {
                                this.gateway_panel.mode = choice;
                                this.gateway_panel.clear_probe();
                                this.settings_view.connection_error = None;
                                cx.notify();
                            }
                        }))
                }),
            ),
        );
        if mode == GatewayMode::Remote {
            let signed_in = auth == RemoteAuth::Password
                && self.out.is_some()
                && Gateway::normalize_address(&self.address.read(cx).value())
                    .ok()
                    .is_some_and(|url| {
                        self.gateway.as_ref().is_some_and(|gateway| {
                            !gateway.is_local() && gateway.auth == auth && gateway.url == url
                        })
                    });
            form = form
                .child(field(tr("远程 URL"), Input::new(&self.address)))
                .child(
                    div()
                        .flex()
                        .flex_col()
                        .gap_1()
                        .child(heading(tr("认证方式")))
                        .child(
                            div().flex().gap_1().children(
                                [
                                    (RemoteAuth::Password, tr("用户名和密码")),
                                    (RemoteAuth::Token, tr("访问令牌")),
                                ]
                                .into_iter()
                                .enumerate()
                                .map(|(index, (choice, label))| {
                                    menu_button(("remote-auth", index), label, auth == choice)
                                        .on_click(cx.listener(move |this, _, _, cx| {
                                            if !busy {
                                                this.gateway_panel.auth = choice;
                                                this.gateway_panel.clear_probe();
                                                this.settings_view.connection_error = None;
                                                cx.notify();
                                            }
                                        }))
                                }),
                            ),
                        ),
                )
                .when(auth == RemoteAuth::Token, |form| {
                    form.child(field(tr("访问令牌"), Input::new(&self.token)))
                        .child(note(tr("留空时沿用此 URL 已保存的令牌。")))
                })
                .when(auth == RemoteAuth::Password, |form| {
                    if signed_in {
                        form.child(
                            div()
                                .flex()
                                .items_center()
                                .gap_2()
                                .child(note(tr("已登录 · 会话自动续期")))
                                .child(control("gateway-sign-out", tr("退出本机登录")).on_click(
                                    cx.listener(|this, _, window, cx| {
                                        this.sign_out_remote(window, cx)
                                    }),
                                )),
                        )
                    } else {
                        form.child(note(tr("连接后在浏览器完成登录。")))
                    }
                });
        }
        form.child(
            div()
                .pt_1()
                .flex()
                .items_center()
                .gap_2()
                .when(mode == GatewayMode::Remote, |row| {
                    row.child(
                        control(
                            "gateway-test",
                            if self.gateway_panel.probing {
                                tr("正在测试")
                            } else {
                                tr("测试远程")
                            },
                        )
                        .when(busy, |button| button.opacity(0.55))
                        .when(!busy, |button| {
                            button.on_click(
                                cx.listener(|this, _, window, cx| this.test_gateway(window, cx)),
                            )
                        }),
                    )
                })
                .child(div().flex_1())
                .child(
                    primary(
                        "save-gateway",
                        if busy && mode == GatewayMode::Local {
                            tr("正在准备…")
                        } else if compact {
                            tr("保存并重连")
                        } else {
                            tr("连接网关")
                        },
                        !busy,
                    )
                    .when(!busy, |button| {
                        button.on_click(
                            cx.listener(|this, _, window, cx| this.apply_gateway(window, cx)),
                        )
                    }),
                ),
        )
        .children(self.gateway_panel.feedback.clone().map(|status| {
            div()
                .text_size(px(12.))
                .text_color(ink(0x26785e))
                .child(status)
        }))
    }

    pub(super) fn gateway_switcher(&self, host: String, cx: &mut Context<Self>) -> AnyElement {
        let mode = self.settings.gateway_mode;
        let owner = cx.entity().downgrade();
        let toggle = owner.clone();
        let remote_host = Gateway::normalize_address(&self.settings.address)
            .ok()
            .filter(|_| !self.settings.address.is_empty())
            .map_or_else(|| tr(REMOTE_LABEL).to_owned(), |url| display_host(&url));
        let label = if mode == GatewayMode::Local {
            tr("本机").to_owned()
        } else {
            host
        };
        let icon = if mode == GatewayMode::Local {
            icons::DESKTOP
        } else {
            icons::WORLD
        };
        Popover::new("gateway-switcher")
            .anchor(Anchor::BottomLeft)
            .open(self.gateway_panel.switch_open)
            .on_open_change(move |open, _, cx| {
                let _ = toggle.update(cx, |this, cx| {
                    this.gateway_panel.switch_open = *open;
                    cx.notify();
                });
            })
            .trigger(status_button("gateway-switcher-button", icon, label, true))
            .content(move |_, _, _| {
                let manage = owner.clone();
                div()
                    .w(px(206.))
                    .flex()
                    .flex_col()
                    .gap_1()
                    .children(
                        [
                            (GatewayMode::Local, tr("本机").to_owned(), icons::DESKTOP),
                            (GatewayMode::Remote, remote_host.clone(), icons::WORLD),
                        ]
                        .into_iter()
                        .enumerate()
                        .map(|(index, (choice, label, icon))| {
                            let owner = owner.clone();
                            gateway_menu_row(
                                ("switch-gateway-choice", index),
                                icon,
                                label,
                                choice == mode,
                            )
                            .on_click(move |_, window, cx| {
                                let _ = owner
                                    .update(cx, |this, cx| this.switch_gateway(choice, window, cx));
                            })
                        }),
                    )
                    .child(
                        div().border_t_1().border_color(rgb(0xe2e8f0)).pt_1().child(
                            gateway_menu_row(
                                "open-gateway-settings",
                                icons::SETTINGS,
                                tr("管理网关…"),
                                false,
                            )
                            .on_click(move |_, window, cx| {
                                let _ = manage.update(cx, |this, cx| {
                                    this.gateway_panel.switch_open = false;
                                    this.open_settings(SettingsPage::Connection, window, cx);
                                });
                            }),
                        ),
                    )
            })
            .into_any_element()
    }

    pub(super) fn gateway_health(&self, cx: &mut Context<Self>) -> AnyElement {
        let owner = cx.entity().downgrade();
        let toggle = owner.clone();
        Popover::new("gateway-health")
            .anchor(Anchor::BottomLeft)
            .open(self.gateway_panel.status_open)
            .on_open_change(move |open, window, cx| {
                let _ = toggle.update(cx, |this, cx| {
                    this.gateway_panel.status_open = *open;
                    if *open {
                        this.load_gateway_health(false, window, cx);
                    }
                    cx.notify();
                });
            })
            .trigger(status_button(
                "gateway-health-button",
                icons::ACTIVITY,
                tr(self.status),
                false,
            ))
            .content(move |_, _, cx| {
                let Some(entity) = owner.upgrade() else {
                    return div();
                };
                let this = entity.read(cx);
                let health = this.gateway_panel.diagnostics.as_ref();
                let logs = health.and_then(|data| data.logs.clone());
                let refresh = owner.clone();
                let history = owner.clone();
                let online = this.out.is_some();
                let label =
                    health
                        .and_then(|data| data.running)
                        .map_or(tr("网关状态"), |running| {
                            if running {
                                tr("网关运行中")
                            } else {
                                tr("网关未运行")
                            }
                        });
                div()
                    .w(px(294.))
                    .flex()
                    .flex_col()
                    .gap_2()
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap_2()
                            .child(div().size(px(6.)).rounded_full().bg(rgb(if online {
                                0x28876f
                            } else {
                                0xa0a8b4
                            })))
                            .child(div().flex_1().text_size(px(13.)).child(tr(this.status)))
                            .child(control("refresh-gateway-health", tr("刷新")).on_click(
                                move |_, window, cx| {
                                    let _ = refresh.update(cx, |this, cx| {
                                        this.load_gateway_health(false, window, cx)
                                    });
                                },
                            )),
                    )
                    .child(note(label))
                    .children(
                        this.gateway_panel
                            .inference
                            .filter(|_| online)
                            .map(|ready| {
                                note(if ready {
                                    tr("推理已就绪")
                                } else {
                                    tr("推理未就绪")
                                })
                            }),
                    )
                    .child(
                        div()
                            .border_t_1()
                            .border_color(rgb(0xe2e8f0))
                            .pt_2()
                            .flex()
                            .items_center()
                            .child(div().flex_1().child(heading(tr("最近活动"))))
                            .when(online, |row| {
                                row.child(control("gateway-more-logs", tr("更多日志")).on_click(
                                    move |_, window, cx| {
                                        let _ = history.update(cx, |this, cx| {
                                            this.load_gateway_health(true, window, cx)
                                        });
                                    },
                                ))
                            }),
                    )
                    .child(
                        div()
                            .id("gateway-recent-activity")
                            .max_h(px(154.))
                            .overflow_y_scroll()
                            .text_size(px(11.))
                            .line_height(px(16.))
                            .font_family(crate::theme::code_family())
                            .text_color(ink(MUTED))
                            .child(logs.unwrap_or_else(|| {
                                if this.gateway_panel.diagnostics_job.is_some() {
                                    tr("正在读取…").into()
                                } else {
                                    tr("暂无可显示的日志").into()
                                }
                            })),
                    )
                    .children(
                        health
                            .filter(|health| !health.platforms.is_empty())
                            .map(|health| {
                                div()
                                    .border_t_1()
                                    .border_color(rgb(0xe2e8f0))
                                    .pt_2()
                                    .flex()
                                    .flex_col()
                                    .gap_1()
                                    .child(heading(tr("消息平台")))
                                    .child(
                                        div()
                                            .id("gateway-platforms")
                                            .max_h(px(175.))
                                            .overflow_y_scroll()
                                            .flex()
                                            .flex_col()
                                            .gap_1()
                                            .children(health.platforms.iter().map(
                                                |(name, state)| {
                                                    let ready = matches!(
                                                        state.as_str(),
                                                        "connected" | "running" | "ready"
                                                    );
                                                    div()
                                                        .flex()
                                                        .items_center()
                                                        .gap_2()
                                                        .text_size(px(12.))
                                                        .child(
                                                            div()
                                                                .flex_1()
                                                                .min_w_0()
                                                                .truncate()
                                                                .child(name.clone()),
                                                        )
                                                        .child(
                                                            div().size(px(5.)).rounded_full().bg(
                                                                rgb(if ready {
                                                                    0x27876f
                                                                } else {
                                                                    0xaab0bb
                                                                }),
                                                            ),
                                                        )
                                                        .child(note(if ready {
                                                            tr("已连接")
                                                        } else if state == "disabled" {
                                                            tr("已停用")
                                                        } else {
                                                            tr("未连接")
                                                        }))
                                                },
                                            )),
                                    )
                            }),
                    )
            })
            .into_any_element()
    }

    fn load_gateway_health(&mut self, full: bool, window: &mut Window, cx: &mut Context<Self>) {
        if self.gateway_panel.diagnostics_job.is_some() || self.out.is_none() {
            return;
        }
        let Some(gateway) = self.gateway.clone() else {
            return;
        };
        if !full && !self.gateway_panel.inference_pending {
            let profile = self.model_profile();
            let params = if profile.is_empty() {
                json!({})
            } else {
                json!({"profile":profile})
            };
            self.gateway_panel.inference_pending =
                self.call("setup.runtime_check", params, Call::GatewayInference);
        }
        let task = self.runtime.spawn(async move {
            let log_params = [
                ("file", "gateway".to_owned()),
                ("lines", if full { "120" } else { "8" }.to_owned()),
            ];
            let (status, logs) = tokio::join!(
                gateway.api(reqwest::Method::GET, "api/status", &[], None),
                gateway.api(reqwest::Method::GET, "api/logs", &log_params, None),
            );
            Diagnostics::from_replies(status.ok(), logs.ok())
        });
        self.gateway_panel.diagnostics_job = Some(cx.spawn_in(window, async move |view, cx| {
            let result = task.await.ok();
            let _ = view.update_in(cx, |this, _, cx| {
                this.gateway_panel.diagnostics_job = None;
                this.gateway_panel.diagnostics = result;
                cx.notify();
            });
        }));
        cx.notify();
    }

    pub(super) fn finish_gateway_inference(&mut self, ready: Option<bool>) {
        self.gateway_panel.inference_pending = false;
        if ready.is_some() {
            self.gateway_panel.inference = ready;
        }
    }

    pub(super) fn reconnect_gateway(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        match self.settings.gateway_mode {
            GatewayMode::Local => self.connect_local(false, window, cx),
            GatewayMode::Remote => {
                if let Some(gateway) = self.gateway.clone() {
                    self.banner = None;
                    self.restart_active_connection(gateway, window, cx);
                } else {
                    self.restore_gateway(window, cx);
                }
            }
        }
    }
}

impl Diagnostics {
    fn from_replies(status: Option<Value>, logs: Option<Value>) -> Self {
        let running = status
            .as_ref()
            .and_then(|status| status["gateway_running"].as_bool());
        let mut platforms: Vec<_> = status
            .as_ref()
            .and_then(|status| status["gateway_platforms"].as_object())
            .into_iter()
            .flatten()
            .filter_map(|(name, platform)| {
                let state = platform["state"]
                    .as_str()
                    .or_else(|| platform["status"].as_str())
                    .or_else(|| platform.as_str())?;
                Some((name.clone(), state.to_ascii_lowercase()))
            })
            .collect();
        platforms.sort_by(|left, right| left.0.to_lowercase().cmp(&right.0.to_lowercase()));
        let logs = logs
            .as_ref()
            .and_then(|logs| logs["lines"].as_array())
            .map(|lines| {
                lines
                    .iter()
                    .filter_map(Value::as_str)
                    .map(|line| &line[..line.floor_char_boundary(1500)])
                    .collect::<Vec<_>>()
                    .join("\n")
            })
            .filter(|logs| !logs.is_empty())
            .map(Into::into);
        Self {
            running,
            platforms,
            logs,
        }
    }
}

fn display_host(url: &url::Url) -> String {
    let hostname = url.host_str().unwrap_or_default();
    url.port()
        .map_or_else(|| hostname.to_owned(), |port| format!("{hostname}:{port}"))
}

fn heading(label: &'static str) -> Div {
    div()
        .text_size(px(12.))
        .text_color(ink(INK))
        .font_weight(FontWeight::SEMIBOLD)
        .child(label)
}

fn note(label: &'static str) -> Div {
    div().text_size(px(11.)).text_color(ink(MUTED)).child(label)
}

fn field(label: &'static str, input: impl IntoElement) -> Div {
    div()
        .flex()
        .flex_col()
        .gap_1()
        .child(heading(label))
        .child(input)
}

fn menu_button(
    id: impl Into<gpui::ElementId>,
    label: impl Into<SharedString>,
    selected: bool,
) -> gpui::Stateful<Div> {
    div()
        .id(id)
        .h(px(28.))
        .px_2()
        .gap_2()
        .rounded(px(4.))
        .flex()
        .items_center()
        .text_size(px(12.))
        .text_color(ink(if selected { ACCENT } else { INK }))
        .when(selected, |button| button.bg(rgb(0xeaf1fd)))
        .cursor_pointer()
        .hover(|button| button.bg(rgb(0xecf1f7)))
        .child(div().min_w_0().truncate().child(label.into()))
}

fn gateway_menu_row(
    id: impl Into<gpui::ElementId>,
    icon: &'static str,
    label: impl Into<SharedString>,
    selected: bool,
) -> gpui::Stateful<Div> {
    div()
        .id(id)
        .h(px(28.))
        .px_2()
        .gap_2()
        .rounded(px(4.))
        .flex()
        .items_center()
        .text_size(px(12.))
        .text_color(ink(INK))
        .when(selected, |row| row.bg(rgb(0xeaf1fd)))
        .cursor_pointer()
        .hover(|row| row.bg(rgb(0xecf1f7)))
        .child(svg_symbol(icon, 13., MUTED).flex_none())
        .child(div().min_w_0().flex_1().truncate().child(label.into()))
        .when(selected, |row| {
            row.child(div().text_color(ink(ACCENT)).child("✓"))
        })
}

fn status_button(
    id: &'static str,
    icon: &'static str,
    label: impl Into<SharedString>,
    chevron: bool,
) -> Button {
    Button::new(id).ghost().compact().h(px(20.)).child(
        div()
            .flex()
            .items_center()
            .gap_1()
            .max_w(px(198.))
            .text_size(px(11.))
            .text_color(ink(MUTED))
            .child(svg_symbol(icon, 13., MUTED))
            .child(div().min_w_0().truncate().child(label.into()))
            .when(chevron, |row| {
                row.child(svg_symbol(icons::CHEVRON_DOWN, 10., MUTED))
            }),
    )
}
