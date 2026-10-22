//! SSH tunnel: connect to the database through a jump host.
//!
//! "SSH" tab: the app opens an SSH session to the jump host and
//! forwards a local TCP port to the database server. sqlx then connects to
//! 127.0.0.1:<local_port> as if the database were local, so no driver code
//! needs to know about SSH.
//!
//! Design notes:
//! * Pure Rust (russh). Requiring an external ssh binary would fail on machines
//!   without one and make behaviour depend on the user's ssh config.
//! * One tunnel per connection spec. The tunnel lives as long as the forwarding
//!   task; dropping SshTunnel stops it and closes the local port.
//! * Authentication: password, unencrypted OpenSSH private key, and ssh-agent.
//! * Host-key checking is explicit: a first connection can trust-on-first-use
//!   when allowed, otherwise a mismatch is an error. The caller persists the
//!   fingerprint so later connections are pinned.

use std::net::{Ipv4Addr, SocketAddr};
use std::sync::Arc;
use std::time::Duration;

use russh::client::{self, Handle};
use russh::keys::{key, load_secret_key};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::oneshot;

use crate::error::{AppError, AppResult};

// 33 轮拆 crate：SSH 连接参数（SshSpec / SshAuth / SshHostKeyPolicy）属于连接
// 配置契约，已搬进 dbpilot_core；隧道实现（russh）仍在本模块。
pub use dbpilot_core::ssh::{SshAuth, SshHostKeyPolicy, SshSpec};

/// A running tunnel. Dropping it stops forwarding and closes the local port,
/// so a dead tunnel fails fast instead of hanging the next connect.
pub struct SshTunnel {
    /// Local address the database driver should connect to.
    pub local_addr: SocketAddr,
    /// Fingerprint of the jump host key actually used (for first-use pinning).
    pub host_key_fingerprint: String,
    _stop: oneshot::Sender<()>,
}

/// Open a tunnel to target_host:target_port through the configured jump host.
///
/// target_host is resolved on the jump host, which makes a database that only
/// listens on the remote loopback / private network reachable. The local
/// listener binds 127.0.0.1 only, so the forwarded port is not exposed to the
/// local network.
pub async fn open(
    spec: &SshSpec,
    target_host: &str,
    target_port: u16,
    connect_timeout: Duration,
) -> AppResult<SshTunnel> {
    if !spec.enabled() {
        return Err(AppError::bad("SSH 隧道未配置跳板机地址"));
    }
    if spec.ssh_user.trim().is_empty() {
        return Err(AppError::bad("SSH 用户名不能为空"));
    }
    let expected = spec
        .ssh_host_key
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string);

    let config = Arc::new(client::Config {
        inactivity_timeout: Some(Duration::from_secs(3600)),
        keepalive_interval: Some(Duration::from_secs(60)),
        keepalive_max: 3,
        ..Default::default()
    });
    // Trust-on-first-use is only allowed by the `accept-new` policy. A `strict`
    // policy with no stored fingerprint has nothing to compare against, so it
    // refuses rather than silently trusting an unknown host key.
    let handler = HostKeyHandler {
        expected: expected.clone(),
        accept_new: spec.ssh_host_key_policy == SshHostKeyPolicy::AcceptNew,
        seen: Arc::new(tokio::sync::Mutex::new(None)),
    };
    let seen = handler.seen.clone();
    let addr = format!("{}:{}", spec.ssh_host.trim(), spec.port());
    let mut session: Handle<HostKeyHandler> = tokio::time::timeout(
        connect_timeout,
        client::connect(config, addr.as_str(), handler),
    )
    .await
    .map_err(|_| {
        AppError::BadRequest(format!(
            "SSH 连接超时（{} 秒）：{}",
            connect_timeout.as_secs(),
            addr
        ))
    })?
    .map_err(|e| AppError::BadRequest(format!("SSH 连接失败 {addr}：{e}")))?;

    authenticate(&mut session, spec).await?;

    let fingerprint = seen
        .lock()
        .await
        .clone()
        .ok_or_else(|| AppError::BadRequest("SSH 服务端没有提供主机密钥".to_string()))?;

    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0))
        .await
        .map_err(|e| AppError::Internal(format!("无法创建本地转发端口：{e}")))?;
    let local_addr = listener
        .local_addr()
        .map_err(|e| AppError::Internal(format!("无法读取本地转发端口：{e}")))?;
    let (stop_tx, mut stop_rx) = oneshot::channel::<()>();
    let target_host = target_host.trim().to_string();
    let session = Arc::new(session);
    let session_for_task = session.clone();
    tokio::spawn(async move {
        loop {
            tokio::select! {
                _ = &mut stop_rx => break,
                accepted = listener.accept() => {
                    let Ok((socket, _peer)) = accepted else {
                        break;
                    };
                    let session = session_for_task.clone();
                    let host = target_host.clone();
                    tokio::spawn(async move {
                        let _ = forward_connection(session, socket, host, target_port).await;
                    });
                }
            }
        }
        let _ = session_for_task
            .disconnect(russh::Disconnect::ByApplication, "client closed", "en")
            .await;
    });

    Ok(SshTunnel {
        local_addr,
        host_key_fingerprint: fingerprint,
        _stop: stop_tx,
    })
}

/// Whether an unknown jump-host key may be trusted on first use.
///
/// Only the explicit `accept-new` policy allows it. `strict` with no saved
/// fingerprint has nothing to compare against, so it must refuse.
pub fn may_trust_new_host_key(spec: &SshSpec) -> bool {
    spec.ssh_host_key_policy == SshHostKeyPolicy::AcceptNew
}

fn auth_error(detail: impl std::fmt::Display) -> AppError {
    AppError::BadRequest(format!(
        "SSH 认证失败：{detail}。请检查用户名、认证方式与凭据。"
    ))
}

async fn authenticate<H: client::Handler>(session: &mut Handle<H>, spec: &SshSpec) -> AppResult<()> {
    let user = spec.ssh_user.trim();
    match spec.ssh_auth {
        SshAuth::Password => {
            if spec.ssh_password.is_empty() {
                return Err(AppError::bad("SSH 密码认证需要填写密码"));
            }
            let ok = session
                .authenticate_password(user, &spec.ssh_password)
                .await
                .map_err(auth_error)?;
            if !ok {
                return Err(auth_error("密码被拒绝"));
            }
        }
        SshAuth::KeyFile => {
            let path = spec
                .ssh_key
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .ok_or_else(|| AppError::bad("SSH 私钥认证需要选择私钥文件"))?;
            let passphrase = if spec.ssh_password.is_empty() {
                None
            } else {
                Some(spec.ssh_password.as_str())
            };
            let key = load_secret_key(path, passphrase).map_err(|e| {
                AppError::BadRequest(format!(
                    "无法读取 SSH 私钥 {path}：{e}。加密私钥请填写口令。"
                ))
            })?;
            let key = Arc::new(key);
            let ok = session
                .authenticate_publickey(user, key)
                .await
                .map_err(auth_error)?;
            if !ok {
                return Err(auth_error("私钥被拒绝"));
            }
        }
        SshAuth::Agent => {
            // `connect_uds` only exists on Unix: russh-keys gates the whole
            // UnixStream impl behind `#[cfg(unix)]`, so naming it on Windows is
            // a compile error, not merely a runtime failure. Windows has no
            // SSH_AUTH_SOCK either (Pageant/OpenSSH use a named pipe), so the
            // method is reported as unsupported there rather than being
            // half-implemented against a Unix socket.
            authenticate_agent(session, user, spec).await?;
        }
    }
    Ok(())
}

/// Authenticate through the running ssh-agent.
///
/// Only compiled on Unix: russh-keys exposes `connect_uds` exclusively for
/// `tokio::net::UnixStream` behind `#[cfg(unix)]`, so the call does not exist on
/// Windows. Windows agents (Pageant, the OpenSSH agent service) listen on a
/// named pipe instead, which russh 0.45 has no client for — the method is
/// therefore reported as unsupported rather than silently failing to connect.
#[cfg(unix)]
async fn authenticate_agent<H: client::Handler>(
    session: &mut Handle<H>,
    user: &str,
    spec: &SshSpec,
) -> AppResult<()> {
    let mut agent = match spec
        .ssh_agent
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
    {
        Some(path) => russh_keys::agent::client::AgentClient::connect_uds(path)
            .await
            .map_err(|e| {
                AppError::BadRequest(format!("无法连接 SSH agent 套接字 {path}：{e}"))
            })?,
        None => russh_keys::agent::client::AgentClient::connect_env()
            .await
            .map_err(|e| {
                AppError::BadRequest(format!("无法连接 SSH agent（SSH_AUTH_SOCK）：{e}"))
            })?,
    };
    let identities = agent
        .request_identities()
        .await
        .map_err(|e| AppError::BadRequest(format!("无法读取 SSH agent 密钥：{e}")))?;
    if identities.is_empty() {
        return Err(AppError::bad(
            "SSH agent 里没有可用密钥，请先运行 ssh-add 加载私钥",
        ));
    }
    let mut last = String::new();
    for identity in identities {
        // `authenticate_future` lets the agent sign the challenge in place; the
        // private key never leaves the agent.
        let (_agent, result) = session.authenticate_future(user, identity, agent).await;
        agent = _agent;
        match result {
            Ok(true) => return Ok(()),
            Ok(false) => last = "agent 密钥被拒绝".to_string(),
            Err(e) => last = format!("agent 认证出错：{e}"),
        }
    }
    Err(auth_error(last))
}

/// SSH-agent authentication is not available on this platform.
///
/// Windows agents use a named pipe, and russh 0.45 only ships a Unix-socket
/// client, so the method fails with an explanation instead of a compile error.
#[cfg(not(unix))]
async fn authenticate_agent<H: client::Handler>(
    _session: &mut Handle<H>,
    _user: &str,
    _spec: &SshSpec,
) -> AppResult<()> {
    Err(AppError::bad(
        "当前平台不支持 SSH agent 认证：Windows 的 ssh-agent 使用命名管道，本版本仅支持 Unix 套接字；请改用密码或私钥文件认证",
    ))
}

/// Pump one accepted local connection through a direct-tcpip channel.
///
/// The channel is turned into an AsyncRead+AsyncWrite stream and copied
/// bidirectionally with the local socket. Doing the pump by hand used to close
/// the socket early because the read half and write half were polled in the
/// same select, so both directions now run in one well-tested helper.
async fn forward_connection<H: client::Handler>(
    session: Arc<Handle<H>>,
    mut socket: TcpStream,
    target_host: String,
    target_port: u16,
) -> Result<(), russh::Error> {
    let channel = session
        .channel_open_direct_tcpip(target_host.clone(), u32::from(target_port), "127.0.0.1", 0)
        .await?;
    let stream = channel.into_stream();
    let mut stream = stream;
    let _ = tokio::io::copy_bidirectional(&mut socket, &mut stream).await;
    Ok(())
}

struct HostKeyHandler {
    expected: Option<String>,
    accept_new: bool,
    seen: Arc<tokio::sync::Mutex<Option<String>>>,
}

#[async_trait::async_trait]
impl client::Handler for HostKeyHandler {
    type Error = russh::Error;

    async fn check_server_key(
        &mut self,
        server_public_key: &key::PublicKey,
    ) -> Result<bool, Self::Error> {
        // russh returns the bare base64 digest; the conventional `ssh-keygen -l`
        // form (and the form users paste back into the connection form) carries
        // the `SHA256:` algorithm prefix.
        let fingerprint = format!("SHA256:{}", server_public_key.fingerprint());
        *self.seen.lock().await = Some(fingerprint.clone());
        match self.expected.as_deref() {
            Some(expected) => Ok(expected == fingerprint),
            // First use: remember it; the caller persists the fingerprint.
            None => Ok(self.accept_new),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn disabled_instance_has_no_host() {
        let spec = SshSpec::default();
        assert!(!spec.enabled());
        assert_eq!(spec.port(), 22);
    }

    #[test]
    fn strict_policy_without_pin_refuses_unknown_host() {
        let spec = SshSpec {
            ssh_host_key_policy: SshHostKeyPolicy::Strict,
            ..Default::default()
        };
        assert!(!may_trust_new_host_key(&spec));
        let permissive = SshSpec {
            ssh_host_key_policy: SshHostKeyPolicy::AcceptNew,
            ..Default::default()
        };
        assert!(may_trust_new_host_key(&permissive));
    }
}
