use std::time::Duration;

use anyhow::{Result, ensure};
use base64::{Engine as _, engine::general_purpose::STANDARD};
use futures_util::SinkExt;
use serde_json::Value;
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite},
    time,
};
use tokio_tungstenite::{
    WebSocketStream,
    tungstenite::{
        Message,
        protocol::frame::{
            Frame,
            coding::{Data, OpCode},
        },
    },
};

const IO_TIMEOUT: Duration = Duration::from_secs(15);
const CHUNK_SIZE: usize = 48 * 1024;

pub(crate) async fn send<S, R>(
    socket: &mut WebSocketStream<S>,
    id: u64,
    params: &Value,
    mut file: R,
) -> Result<()>
where
    S: AsyncRead + AsyncWrite + Unpin,
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
    loop {
        let read = time::timeout(IO_TIMEOUT, file.read(&mut buffer[remainder..])).await??;
        if read == 0 {
            let mut tail = STANDARD.encode(&buffer[..remainder]);
            tail.push_str(r#""}}"#);
            return send_fragment(socket, tail, Data::Continue, true).await;
        }
        let filled = remainder + read;
        let complete = filled - filled % 3;
        if complete != 0 {
            let encoded = STANDARD.encode(&buffer[..complete]);
            send_fragment(socket, encoded, Data::Continue, false).await?;
        }
        // Padding belongs only at the end, even when a read ends mid-triplet.
        buffer.copy_within(complete..filled, 0);
        remainder = filled - complete;
    }
}

async fn send_fragment<S>(
    socket: &mut WebSocketStream<S>,
    text: String,
    opcode: Data,
    last: bool,
) -> Result<()>
where
    S: AsyncRead + AsyncWrite + Unpin,
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
    use tokio_tungstenite::tungstenite::protocol::Role;

    #[tokio::test]
    async fn sends_files_above_the_former_limit_in_a_single_rpc_message() -> Result<()> {
        let (client, server) = duplex(8192);
        let mut socket = WebSocketStream::from_raw_socket(client, Role::Client, None).await;
        let mut peer = WebSocketStream::from_raw_socket(server, Role::Server, None).await;
        let size = 26 * 1024 * 1024 + 2;
        let name = "附件 \"测试\".exe";
        let params = json!({"session_id":"example","name":name});
        let transmit =
            async { send(&mut socket, 42, &params, tokio::io::repeat(0xa1).take(size)).await };
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
        let transmit = send(&mut socket, 1, &params, reader);
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
