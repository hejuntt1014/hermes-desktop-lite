use crate::i18n::text as tr;

use crate::gateway::{Gateway, Update};
use anyhow::{Context, Result, bail};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use serde::{Deserialize, Serialize};
use serde_json::json;
use sha2::{Digest, Sha256};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
    net::TcpListener,
    sync::mpsc,
    time::timeout,
};
use url::Url;
use uuid::Uuid;

#[derive(Deserialize)]
pub struct Tokens {
    pub access_token: String,
    pub expires_at: f64,
    refresh_token: String,
    provider: String,
}

#[derive(Serialize, Deserialize)]
pub struct Renewal {
    refresh_token: String,
    provider: String,
}

impl Tokens {
    pub fn current(&self) -> bool {
        self.expires_at
            > SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs_f64()
                + 30.
    }
}

impl Gateway {
    fn vault(&self) -> Result<keyring::Entry> {
        Ok(keyring::Entry::new(
            "Hermes Desktop Lite OAuth",
            self.url.as_str(),
        )?)
    }

    async fn remember(&self, tokens: Tokens) -> Result<String> {
        let renewal = Renewal {
            refresh_token: tokens.refresh_token.clone(),
            provider: tokens.provider.clone(),
        };
        self.vault()?
            .set_password(&serde_json::to_string(&renewal)?)?;
        let bearer = tokens.access_token.clone();
        *self.oauth.lock().await = Some(tokens);
        Ok(bearer)
    }

    pub async fn bearer(&self) -> Result<Option<String>> {
        self.refresh_bearer(None).await
    }

    pub async fn refresh_bearer(&self, rejected: Option<&str>) -> Result<Option<String>> {
        let _guard = self.renew.lock().await;
        if let Some(tokens) = self
            .oauth
            .lock()
            .await
            .as_ref()
            .filter(|tokens| tokens.current() && rejected != Some(tokens.access_token.as_str()))
        {
            return Ok(Some(tokens.access_token.clone()));
        }
        let stored = match self.vault()?.get_password() {
            Ok(value) => value,
            Err(keyring::Error::NoEntry) => return Ok(None),
            Err(error) => return Err(error.into()),
        };
        let renewal: Renewal = serde_json::from_str(&stored)?;
        let response = self
            .http
            .post(self.endpoint("auth/native/refresh"))
            .json(&renewal)
            .send()
            .await?;
        if response.status().as_u16() == 401 {
            self.forget_saved_renewal()?;
            *self.oauth.lock().await = None;
            return Ok(None);
        }
        let tokens = response.error_for_status()?.json().await?;
        Ok(Some(self.remember(tokens).await?))
    }

    fn forget_saved_renewal(&self) -> Result<()> {
        match self.vault()?.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(error) => Err(error.into()),
        }
    }

    pub async fn forget_oauth(&self) -> Result<()> {
        let _guard = self.renew.lock().await;
        self.forget_saved_renewal()?;
        *self.oauth.lock().await = None;
        Ok(())
    }

    pub async fn login(&self, tx: &mpsc::UnboundedSender<Update>) -> Result<String> {
        let listener = TcpListener::bind(("127.0.0.1", 0)).await?;
        let redirect = format!("http://{}/callback", listener.local_addr()?);
        let state = Uuid::new_v4().simple().to_string();
        let verifier = format!("{}{}", Uuid::new_v4().simple(), Uuid::new_v4().simple());
        let challenge = URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()));
        let mut url = self.endpoint("auth/native/authorize");
        url.query_pairs_mut().extend_pairs([
            ("state", state.as_str()),
            ("code_challenge", &challenge),
            ("code_challenge_method", "S256"),
            ("redirect_uri", &redirect),
        ]);
        tx.send(Update::SignIn(url.to_string()))
            .context(tr("登录窗口已关闭"))?;
        timeout(Duration::from_secs(300), async {
            loop {
                let (stream, _) = listener.accept().await?;
                let mut stream = BufReader::new(stream);
                let mut line = String::new();
                let read = timeout(Duration::from_secs(3), (&mut stream).take(8192).read_line(&mut line)).await;
                if !matches!(read, Ok(Ok(_))) { continue; }
                let target = line.strip_prefix("GET ").and_then(|s| s.split_whitespace().next()).unwrap_or("");
                let callback = Url::parse(&redirect)?.join(target)?;
                let field = |name: &str| callback.query_pairs().find(|(k,_)| k == name).map(|(_,v)| v.into_owned());
                if callback.path() != "/callback" || field("state").as_deref() != Some(&state) {
                    stream.write_all(b"HTTP/1.1 404 Not Found\r\nConnection: close\r\nContent-Length: 0\r\n\r\n").await?;
                    continue;
                }
                let code = field("code").context(tr("登录未获授权"))?;
                let response = self.http.post(self.endpoint("auth/native/token"))
                    .json(&json!({"code":code,"code_verifier":verifier})).send().await?;
                if !response.status().is_success() { bail!(crate::i18n::format_text!("网关拒绝了登录授权（{}）", "The gateway denied sign-in ({})", response.status())); }
                let bearer = self.remember(response.json().await?).await?;
                let message = tr("登录成功，可以返回 Hermes Lite。");
                let _ = stream.write_all(format!("HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: {}\r\n\r\n{message}", message.len()).as_bytes()).await;
                return Ok(bearer);
            }
        }).await.context(tr("登录已超时，请重新连接"))?
    }
}
