//! Aggregated zero-row diagnostics for batch row edits.
//!
//! This lives **outside `crate::api`** on purpose. flutter_rust_bridge scans
//! every item in the `api` module tree and generates codecs for the types it
//! finds there — including private structs that only exist as an internal
//! aggregate. Because the struct and its fields are private, the generated
//! `SseEncode`/`IntoDart` impls (emitted in the same crate but outside this
//! module) cannot touch them, and the crate stops compiling with
//! E0603/E0616 (`struct ZeroRowReasons is private` / `field not_found is
//! private`). The FRB-facing `api` surface only ever sees the JSON this module
//! produces, which is exactly what the `check_api_surface.py` invariant asks
//! for: `rust/src/api` stays a thin FRB surface.

use serde_json::{json, Value};

/// Aggregated reasons for the zero-row UPDATE / DELETE diagnostics.
#[derive(Default)]
pub(crate) struct ZeroRowReasons {
    not_found: u64,
    unchanged: u64,
    unknown: u64,
}

impl ZeroRowReasons {
    pub(crate) fn count(&mut self, reason: &str) {
        match reason {
            "not_found" => self.not_found += 1,
            "unchanged" => self.unchanged += 1,
            _ => self.unknown += 1,
        }
    }

    pub(crate) fn to_json(&self) -> Value {
        json!({
            "not_found": self.not_found,
            "unchanged": self.unchanged,
            "unknown": self.unknown,
        })
    }
}
