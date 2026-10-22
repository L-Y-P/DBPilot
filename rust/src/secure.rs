//! Filesystem hardening helpers for the JSON/backup data files.
//!
//! These files hold credentials (`connections.json`), SQL history and database
//! dumps, so they must never be world-readable and must not be left partially
//! written if the process dies mid-save. Every writer therefore goes through
//! [`write_private`], which writes to a sibling temp file, tightens its mode and
//! then atomically renames it over the target.

use std::io;
use std::path::{Path, PathBuf};

#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;

/// Restrict a file to its owner (0600). No-op on non-Unix platforms.
pub fn set_file_mode(path: &Path, mode: u32) {
    #[cfg(unix)]
    {
        let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode));
    }
    #[cfg(not(unix))]
    {
        let _ = (path, mode);
    }
}

/// Tighten an already existing file (used on load, so files created by older
/// builds stop being world-readable the next time the service starts).
pub fn harden_file(path: &Path) {
    if path.exists() {
        set_file_mode(path, 0o600);
    }
}

/// Create `dir` (and parents) and restrict it to its owner (0700).
pub fn ensure_private_dir(dir: &Path) -> io::Result<()> {
    std::fs::create_dir_all(dir)?;
    #[cfg(unix)]
    {
        let _ = std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700));
    }
    Ok(())
}

fn temp_path(path: &Path) -> PathBuf {
    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "rma".to_string());
    let tmp_name = format!(".{}.{}.tmp", name, std::process::id());
    match path.parent() {
        Some(parent) if !parent.as_os_str().is_empty() => parent.join(tmp_name),
        _ => PathBuf::from(tmp_name),
    }
}

/// Atomically write `contents` to `path` with owner-only permissions.
///
/// A temp file plus rename means readers either see the old content or the new
/// content, never a half-written file, and the 0600 mode is applied before the
/// rename so the data is never momentarily world-readable.
pub fn write_private(path: &Path, contents: &str) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent)?;
        }
    }
    let tmp = temp_path(path);
    std::fs::write(&tmp, contents)?;
    set_file_mode(&tmp, 0o600);
    match std::fs::rename(&tmp, path) {
        Ok(()) => {
            set_file_mode(path, 0o600);
            Ok(())
        }
        Err(e) => {
            let _ = std::fs::remove_file(&tmp);
            Err(e)
        }
    }
}
