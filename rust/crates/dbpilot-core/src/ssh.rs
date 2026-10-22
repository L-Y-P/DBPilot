//! SSH 连接参数（纯数据）。
//!
//! 33 轮拆 crate 时从主 crate 的 ssh.rs 搬进契约层：ConnSpec 通过
//! #[serde(flatten)] 内嵌它，core 不能反向依赖隧道实现（russh）。
//! 隧道实现仍在主 crate 的 ssh.rs，并从本模块 re-export 这些类型。

use serde::{Deserialize, Serialize};

/// How the SSH session authenticates.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SshAuth {
    #[default]
    Password,
    /// A private key file on disk (OpenSSH or PEM).
    KeyFile,
    /// The running ssh-agent, selected by key fingerprint or first identity.
    Agent,
}

/// Host-key policy for the jump host.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum SshHostKeyPolicy {
    /// Trust the key on first use and remember its fingerprint.
    #[default]
    AcceptNew,
    /// Only accept the fingerprint stored in ssh_host_key.
    Strict,
}

/// SSH parameters of a connection. An empty ssh_host means "no tunnel".
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct SshSpec {
    #[serde(default)]
    pub ssh_host: String,
    #[serde(default)]
    pub ssh_port: Option<u16>,
    #[serde(default)]
    pub ssh_user: String,
    #[serde(default, deserialize_with = "de_opt_default")]
    pub ssh_auth: SshAuth,
    /// Password, or the passphrase of an encrypted key.
    #[serde(default)]
    pub ssh_password: String,
    /// Private key file for SshAuth::KeyFile.
    #[serde(default)]
    pub ssh_key: Option<String>,
    /// ssh-agent socket; empty uses $SSH_AUTH_SOCK.
    #[serde(default)]
    pub ssh_agent: Option<String>,
    /// SHA256 fingerprint remembered after the first accepted connection.
    #[serde(default)]
    pub ssh_host_key: Option<String>,
    #[serde(default, deserialize_with = "de_opt_default")]
    pub ssh_host_key_policy: SshHostKeyPolicy,
}

/// Accept an explicit JSON `null` for a field with a `Default` value.
///
/// Flattened structs are strict about types, so a client that sends
/// `"ssh_auth": null` (older builds did) would otherwise fail the whole
/// connection object. This maps null to the default value instead.
fn de_opt_default<'de, D, T>(deserializer: D) -> Result<T, D::Error>
where
    D: serde::Deserializer<'de>,
    T: serde::Deserialize<'de> + Default,
{
    Ok(Option::<T>::deserialize(deserializer)?.unwrap_or_default())
}

impl SshSpec {
    pub fn enabled(&self) -> bool {
        !self.ssh_host.trim().is_empty()
    }

    pub fn port(&self) -> u16 {
        self.ssh_port.unwrap_or(22)
    }
}
