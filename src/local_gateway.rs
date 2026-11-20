use std::{env, path::PathBuf, process::Stdio, time::Duration};

use anyhow::{Context, Result, bail};
use serde_json::{Value, json};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
    process::{Child, ChildStdin, ChildStdout, Command},
    sync::Mutex,
    time::timeout,
};
use url::{Host, Url};

use crate::gateway::Gateway;

const BROKER_TIMEOUT: Duration = Duration::from_secs(10);
const WIRE_LIMIT: u64 = 64 * 1024;
const NATIVE_PROTOCOL: &str = "hermes-gateway-v1";

pub struct LocalTickets {
    executable: PathBuf,
    endpoint: Endpoint,
    broker: Mutex<Option<Broker>>,
}

#[derive(PartialEq, Eq)]
struct Endpoint {
    origin: Url,
    instance_id: String,
}

impl Endpoint {
    fn parse(value: &Value) -> Result<Self> {
        let origin = Url::parse(value["api_origin"].as_str().context("本地网关缺少地址")?)?;
        let loopback = match origin.host() {
            Some(Host::Ipv4(ip)) => ip.is_loopback(),
            Some(Host::Ipv6(ip)) => ip.is_loopback(),
            _ => false,
        };
        if !loopback
            || !matches!(origin.scheme(), "http" | "https")
            || !origin.username().is_empty()
            || origin.password().is_some()
            || origin.query().is_some()
            || origin.fragment().is_some()
            || origin.path() != "/"
            || origin.port().is_none()
            || value["runtime_protocol"] != 1
            || !value["capabilities"].as_array().is_some_and(|values| {
                values
                    .iter()
                    .any(|capability| capability == "session-authority-v1")
            })
        {
            bail!("本地网关返回了不兼容的连接地址");
        }
        let instance_id = value["instance_id"]
            .as_str()
            .filter(|id| !id.is_empty())
            .context("本地网关缺少实例标识")?
            .to_owned();
        Ok(Self {
            origin,
            instance_id,
        })
    }
}

impl LocalTickets {
    pub async fn connect() -> Result<Gateway> {
        let executable = hermes_command().context("找不到 Hermes Agent。安装后可从本地网关连接")?;
        let output = timeout(
            Duration::from_secs(72),
            cli(&executable)
                .args(["gateway", "ensure", "--json", "--timeout", "60"])
                .output(),
        )
        .await
        .context("等待本地网关就绪超时")??;
        let reply: Value = serde_json::from_slice(&output.stdout)
            .context("本地 Hermes CLI 未返回网关信息，请更新 Hermes Agent")?;
        if !output.status.success() || reply["state"] != "ready" {
            let reason = reply["reason_code"]
                .as_str()
                .filter(|reason| !reason.is_empty())
                .unwrap_or("未就绪");
            bail!("本地网关未就绪（{reason}）");
        }
        let endpoint = Endpoint::parse(&reply["endpoint"])?;
        let broker = Broker::open(&executable, &endpoint).await?;
        Gateway::new_local(
            endpoint.origin.clone(),
            Self {
                executable,
                endpoint,
                broker: Mutex::new(Some(broker)),
            },
        )
    }

    pub async fn mint(&self, purpose: &str, profile: Option<&str>) -> Result<String> {
        let mut slot = self.broker.lock().await;
        let mut broker = match slot.take() {
            Some(broker) => broker,
            None => Broker::open(&self.executable, &self.endpoint).await?,
        };
        let reply = timeout(BROKER_TIMEOUT, broker.request(purpose, profile))
            .await
            .context("本地网关票据等待超时")??;
        *slot = Some(broker);
        if reply["ok"] != true {
            let code = reply["error"]["code"]
                .as_str()
                .unwrap_or("ticket_unavailable");
            bail!("本地网关无法签发票据（{code}）");
        }
        reply["ticket"]
            .as_str()
            .filter(|ticket| {
                !ticket.is_empty()
                    && ticket
                        .bytes()
                        .all(|byte| byte.is_ascii_alphanumeric() || b"-_.~".contains(&byte))
            })
            .map(str::to_owned)
            .context("本地网关未返回有效票据")
    }

    pub async fn socket_protocols(&self) -> Result<String> {
        let ticket = self.mint("interactive", None).await?;
        Ok(format!("{NATIVE_PROTOCOL}, hermes-gateway-ticket.{ticket}"))
    }
}

struct Broker {
    _child: Child,
    input: ChildStdin,
    output: BufReader<ChildStdout>,
    next_id: u64,
}

impl Broker {
    async fn open(executable: &PathBuf, expected: &Endpoint) -> Result<Self> {
        let mut child = cli(executable)
            .args(["gateway", "tickets", "--serve", "--json"])
            .stdin(Stdio::piped())
            .spawn()
            .context("无法启动本地票据通道")?;
        let input = child.stdin.take().context("无法打开本地票据输入")?;
        let mut output = BufReader::new(child.stdout.take().context("无法打开本地票据输出")?);
        let hello = timeout(BROKER_TIMEOUT, read_message(&mut output))
            .await
            .context("等待本地票据通道超时")??;
        if hello["type"] != "hello"
            || hello["protocol"] != 1
            || Endpoint::parse(&hello["endpoint"])? != *expected
        {
            bail!("本地网关实例已变化，请重新连接");
        }
        Ok(Self {
            _child: child,
            input,
            output,
            next_id: 0,
        })
    }

    async fn request(&mut self, purpose: &str, profile: Option<&str>) -> Result<Value> {
        self.next_id = self.next_id.wrapping_add(1);
        let id = self.next_id;
        let mut request = json!({"id":id, "purpose":purpose});
        if let Some(profile) = profile.filter(|profile| !profile.is_empty()) {
            request["profile"] = json!(profile);
        }
        let mut frame = serde_json::to_vec(&request)?;
        frame.push(b'\n');
        self.input.write_all(&frame).await?;
        self.input.flush().await?;
        let reply = read_message(&mut self.output).await?;
        if reply["id"] != id {
            bail!("本地票据响应与请求不匹配");
        }
        Ok(reply)
    }
}

async fn read_message(output: &mut BufReader<ChildStdout>) -> Result<Value> {
    let mut line = Vec::new();
    output
        .take(WIRE_LIMIT + 1)
        .read_until(b'\n', &mut line)
        .await?;
    if line.len() as u64 > WIRE_LIMIT || !line.ends_with(b"\n") {
        bail!("本地票据通道已关闭或返回无效响应");
    }
    serde_json::from_slice(&line).context("本地票据通道返回无效响应")
}

fn cli(executable: &PathBuf) -> Command {
    let mut command = Command::new(executable);
    command
        .kill_on_drop(true)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    #[cfg(windows)]
    command.creation_flags(0x08000000); // CREATE_NO_WINDOW
    command
}

fn hermes_command() -> Option<PathBuf> {
    let name = if cfg!(windows) {
        "hermes.exe"
    } else {
        "hermes"
    };
    let explicit = env::var_os("HERMES_DESKTOP_HERMES")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute() && path.is_file());
    let installed = if cfg!(windows) {
        dirs::data_local_dir().map(|base| base.join("hermes").join("bin").join(name))
    } else {
        dirs::home_dir().map(|base| base.join(".local").join("bin").join(name))
    };
    explicit
        .or_else(|| {
            env::var_os("PATH").and_then(|path| {
                env::split_paths(&path)
                    .filter(|dir| dir.is_absolute())
                    .map(|dir| dir.join(name))
                    .find(|path| path.is_file())
            })
        })
        .or_else(|| installed.filter(|path| path.is_file()))
}
