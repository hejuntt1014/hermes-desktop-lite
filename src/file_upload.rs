use std::time::Duration;

use anyhow::{Result, ensure};
use base64::{Engine as _, engine::general_purpose::STANDARD};
use futures_util::{Sink, SinkExt};
use serde_json::Value;
use tokio::{
    io::{AsyncRead, AsyncReadExt},
    sync::watch,
    time,
};
use tokio_tungstenite::tungstenite::{
    Message,
    protocol::frame::{
        Frame,
        coding::{Data, OpCode},
    },
};

use crate::{
    gateway::Gateway,
    i18n::text as tr,
    upload_progress::{Cancel, Reporter},
};

const HTTP_UPLOAD_RANGE: std::ops::RangeInclusive<u64> = (16 * 1024 * 1024)..=(100 * 1024 * 1024);
const IO_TIMEOUT: Duration = Duration::from_secs(15);
const CHUNK_SIZE: usize = 48 * 1024;
// 768 KiB of file bytes becomes 1 MiB on the wire. Leave space for the peer's
// pong on a slow relay that acknowledges TCP long before forwarding those bytes.
const ACK_WINDOW: u64 = 768 * 1024;
const ACK_TIMEOUT: Duration = Duration::from_secs(30);

pub(crate) struct Attachment {
    pub file: tokio::fs::File,
    pub total: u64,
    pub progress: Reporter,
    pub cancel: Cancel,
}

pub(crate) enum Ready {
    Socket(Attachment),
    Staged(StagedFile),
}

pub(crate) struct StagedFile {
    pub path: String,
    pub profile: String,
    directory: String,
}

impl StagedFile {
    pub async fn remove(self, gateway: Gateway) {
        let scope = [("profile", self.profile)];
        for path in [self.path, self.directory] {
            let _ = gateway
                .api(
                    reqwest::Method::DELETE,
                    "api/files",
                    &scope,
                    Some(serde_json::json!({"path": path, "recursive": false})),
                )
                .await;
        }
    }
}

pub(crate) async fn prepare(
    path: std::path::PathBuf,
    name: &str,
    gateway: Option<Gateway>,
    profile: String,
    home: Option<String>,
    progress: Reporter,
    transport: crate::settings::AttachmentTransport,
    cancel: Cancel,
) -> Result<Ready> {
    let file = tokio::fs::File::open(&path).await?;
    let metadata = file.metadata().await?;
    ensure!(metadata.is_file(), tr("无法读取附件"));
    let total = metadata.len();
    if let (Some(gateway), Some(home)) = (gateway, home)
        && transport == crate::settings::AttachmentTransport::Auto
        && HTTP_UPLOAD_RANGE.contains(&total)
    {
        let directory = format!(
            "{}/uploads/lite-{}",
            home.trim_end_matches(['/', '\\']),
            uuid::Uuid::new_v4()
        );
        let name = name.replace(['/', '\\', '"'], "_");
        let staged = StagedFile {
            path: format!("{directory}/{name}"),
            directory,
            profile,
        };
        let result = tokio::select! {
            biased;
            _ = cancel.cancelled() => {
                staged.remove(gateway).await;
                anyhow::bail!(tr("取消上传"));
            }
            result = upload_http(&gateway, &staged, name, file, total, progress.clone()) => result,
        };
        match result {
            Ok(()) => return Ok(Ready::Staged(staged)),
            Err(error) if crate::gateway::managed_upload_unavailable(&error) => {
                progress.preparing();
                let file = tokio::fs::File::open(&path).await?;
                return Ok(Ready::Socket(Attachment {
                    file,
                    total,
                    progress,
                    cancel,
                }));
            }
            Err(error) => return Err(error),
        }
    }
    Ok(Ready::Socket(Attachment {
        file,
        total,
        progress,
        cancel,
    }))
}

async fn upload_http(
    gateway: &Gateway,
    staged: &StagedFile,
    name: String,
    file: tokio::fs::File,
    total: u64,
    mut progress: Reporter,
) -> Result<()> {
    use futures_util::{StreamExt as _, stream};
    use std::io::{Error, ErrorKind};

    let boundary = format!("hermes-lite-{}", uuid::Uuid::new_v4());
    let name = name.replace(|ch: char| ch.is_control(), "_");
    let prefix = format!(
        "--{boundary}\r\nContent-Disposition: form-data; name=\"path\"\r\n\r\n{}\r\n--{boundary}\r\nContent-Disposition: form-data; name=\"overwrite\"\r\n\r\nfalse\r\n--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{name}\"\r\nContent-Type: application/octet-stream\r\n\r\n",
        staged.path
    );
    let suffix = format!("\r\n--{boundary}--\r\n");
    let length = prefix.len() as u64 + total + suffix.len() as u64;

    let request = gateway
        .api_request_builder(
            reqwest::Method::POST,
            "api/files/upload-stream",
            &[("profile", staged.profile.clone())],
            None,
        )
        .await?;
    progress.sending(0, total);
    let content = stream::try_unfold(
        (file, 0u64, Some(suffix), progress),
        move |(mut file, sent, suffix, mut progress)| async move {
            if sent == total {
                return Ok(suffix.map(|end| {
                    progress.awaiting(sent);
                    (end.into_bytes(), (file, sent, None, progress))
                }));
            }
            let mut block = vec![0; ((total - sent) as usize).min(64 * 1024)];
            let size = time::timeout(IO_TIMEOUT, file.read(&mut block)).await??;
            if size == 0 {
                return Err(Error::new(ErrorKind::UnexpectedEof, tr("无法读取附件")));
            }
            block.truncate(size);
            let sent = sent + size as u64;
            progress.sending(sent, total);
            Ok(Some((block, (file, sent, suffix, progress))))
        },
    );
    let body = stream::once(async move { Ok::<_, Error>(prefix.into_bytes()) }).chain(content);
    let response = request
        .timeout(Duration::from_secs(600))
        .header(
            reqwest::header::CONTENT_TYPE,
            format!("multipart/form-data; boundary={boundary}"),
        )
        .header(reqwest::header::CONTENT_LENGTH, length)
        .body(reqwest::Body::wrap_stream(body))
        .send()
        .await
        .map_err(|error| error.without_url())?;
    let result = Gateway::api_response(response).await?;
    ensure!(
        result["ok"] == true && result["entry"]["size"].as_u64() == Some(total),
        tr("未收到附件上传确认")
    );
    Ok(())
}

fn upload_ping(id: u64, offset: u64) -> [u8; 24] {
    let mut token = [0; 24];
    token[..8].copy_from_slice(b"litefile");
    token[8..16].copy_from_slice(&id.to_be_bytes());
    token[16..].copy_from_slice(&offset.to_be_bytes());
    token
}

pub(crate) fn upload_ack(id: u64, token: &[u8]) -> Option<u64> {
    let offset = u64::from_be_bytes(token.get(16..)?.try_into().ok()?);
    (token == upload_ping(id, offset)).then_some(offset)
}

pub(crate) async fn send<S, R>(
    socket: &mut S,
    id: u64,
    params: &Value,
    mut file: R,
    mut ack: Option<watch::Receiver<u64>>,
    mut progress: impl FnMut(u64, bool),
) -> Result<()>
where
    S: Sink<Message, Error = tokio_tungstenite::tungstenite::Error> + Unpin,
    R: AsyncRead + Unpin,
{
    let Some(fields) = params.as_object() else {
        anyhow::bail!("file.attach parameters must be an object")
    };
    ensure!(
        !fields.contains_key("data_url"),
        "file.attach already has a data URL"
    );
    let mut fields_json = serde_json::to_string(fields)?;
    fields_json.pop(); // Leave the parameters object open for the streamed field.
    let separator = if fields.is_empty() { "" } else { "," };
    let prefix = format!(
        r#"{{"jsonrpc":"2.0","id":{id},"method":"file.attach","params":{fields_json}{separator}"data_url":"data:application/octet-stream;base64,"#
    );
    send_fragment(socket, prefix, Data::Text, false).await?;

    let mut buffer = vec![0; CHUNK_SIZE + 2];
    let mut remainder = 0;
    let mut sent = 0u64;
    let mut acknowledged = 0u64;
    progress(sent, false);
    loop {
        let read = time::timeout(IO_TIMEOUT, file.read(&mut buffer[remainder..])).await??;
        if read == 0 {
            let mut tail = STANDARD.encode(&buffer[..remainder]);
            tail.push_str(r#""}}"#);
            send_fragment(socket, tail, Data::Continue, true).await?;
            progress(sent + remainder as u64, true);
            return Ok(());
        }
        let filled = remainder + read;
        let complete = filled - filled % 3;
        if complete != 0 {
            let encoded = STANDARD.encode(&buffer[..complete]);
            send_fragment(socket, encoded, Data::Continue, false).await?;
            sent += complete as u64;
            match &mut ack {
                Some(ack) if sent - acknowledged >= ACK_WINDOW => {
                    time::timeout(
                        IO_TIMEOUT,
                        socket.send(Message::Ping(upload_ping(id, sent).to_vec().into())),
                    )
                    .await??;
                    time::timeout(ACK_TIMEOUT, ack.wait_for(|offset| *offset == sent)).await??;
                    acknowledged = sent;
                    progress(sent, false);
                }
                None => progress(sent, false),
                _ => {}
            }
        }
        // Padding belongs only at the end, even when a read ends mid-triplet.
        buffer.copy_within(complete..filled, 0);
        remainder = filled - complete;
    }
}

async fn send_fragment<S>(socket: &mut S, text: String, opcode: Data, last: bool) -> Result<()>
where
    S: Sink<Message, Error = tokio_tungstenite::tungstenite::Error> + Unpin,
{
    let frame = Frame::message(text.into_bytes(), OpCode::Data(opcode), last);
    time::timeout(IO_TIMEOUT, socket.send(Message::Frame(frame))).await??;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use futures_util::StreamExt;
    use serde_json::json;
    use tokio::io::{AsyncWriteExt, duplex};
    use tokio_tungstenite::{WebSocketStream, tungstenite::protocol::Role};

    #[tokio::test]
    async fn sends_files_above_the_former_limit_in_a_single_rpc_message() -> Result<()> {
        let (client, server) = duplex(8192);
        let mut socket = WebSocketStream::from_raw_socket(client, Role::Client, None).await;
        let mut peer = WebSocketStream::from_raw_socket(server, Role::Server, None).await;
        let size = 26 * 1024 * 1024 + 2;
        let name = "附件 \"测试\".exe";
        let params = json!({"session_id":"example","name":name});
        let transmit = async {
            send(
                &mut socket,
                42,
                &params,
                tokio::io::repeat(0xa1).take(size),
                None,
                |_, _| {},
            )
            .await
        };
        let receive = async {
            let message = peer.next().await.expect("file.attach message")?;
            let json: Value = serde_json::from_str(message.to_text()?)?;
            assert_eq!(json["id"], 42);
            assert_eq!(json["method"], "file.attach");
            assert_eq!(json["params"]["name"], name);
            let encoded = json["params"]["data_url"]
                .as_str()
                .unwrap()
                .strip_prefix("data:application/octet-stream;base64,")
                .unwrap();
            let bytes = STANDARD.decode(encoded)?;
            assert_eq!(bytes.len() as u64, size);
            assert!(bytes.iter().all(|value| *value == 0xa1));
            Ok::<_, anyhow::Error>(())
        };
        tokio::try_join!(transmit, receive)?;
        Ok(())
    }

    #[tokio::test]
    async fn short_reads_keep_base64_triplets_intact() -> Result<()> {
        let (client, server) = duplex(64);
        let (mut file, reader) = duplex(1);

        let mut socket = WebSocketStream::from_raw_socket(client, Role::Client, None).await;
        let mut peer = WebSocketStream::from_raw_socket(server, Role::Server, None).await;
        let params = json!({});
        let feed = async move {
            file.write_all(b"abcdefg").await?;
            drop(file);
            Ok::<_, anyhow::Error>(())
        };
        let transmit = send(&mut socket, 1, &params, reader, None, |_, _| {});
        let receive = async {
            let message = peer.next().await.expect("file.attach message")?;
            let json: Value = serde_json::from_str(message.to_text()?)?;
            assert_eq!(
                json["params"]["data_url"],
                "data:application/octet-stream;base64,YWJjZGVmZw=="
            );
            Ok::<_, anyhow::Error>(())
        };
        tokio::try_join!(feed, transmit, receive)?;
        Ok(())
    }
}
