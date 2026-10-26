//! DBPilot desktop core.
//!
//! This crate is the backend of the desktop application. It is a direct port
//! of the web server's `server/src` tree with the HTTP, session and
//! website-user layers removed:
//!
//! * `drivers`, `exporters`, `secure`, `pools`, `connections`, `backups`,
//!   `history` and `ssh` are copied essentially verbatim.
//! * the contract layer (`core`, `db`, `error`, `filter`, `ops`) now lives in
//!   the separate `dbpilot-core` crate so the dependency direction
//!   (`api -> state -> drivers -> contract`) is enforced by Cargo.
//! * `config`/`state` replace the cookie session + app-user store with a
//!   single active connection and a platform-native data directory.
//! * `api` exposes the former HTTP handlers as plain async functions that
//!   `flutter_rust_bridge` turns into Dart bindings.
//!
//! The web build's authorization model had three layers: the website user, the
//! admin role, and the connection's `only_db`/`hide_db` rules. Only the last
//! one still makes sense for a local single-user tool, and it is preserved in
//! full (`ActiveConnection::ensure_visible`) because it is a real data-access
//! boundary rather than an authentication concern.

pub mod api;
pub mod backups;
pub mod config;
pub mod connections;
pub mod drivers;
/// Excel 数据文件读取与建表类型推断（import_inspect / import_preview 的内部实现）。
pub(crate) mod excel_import;
/// xls（BIFF8）Record 级流式读取（第 51 轮）。
pub(crate) mod xls_stream;
/// xlsb（ZIP + BRT）Row 级流式读取（第 51 轮）。
pub(crate) mod xlsb_stream;
/// Excel 逐行流式读取层（xlsx/xlsm/ODS/SpreadsheetML/xls/xlsb）。
pub(crate) mod excel_stream;
pub mod exporters;
pub mod history;
pub mod importer;
pub mod pools;
/// Internal SQL-console engine (outside the FRB `api` scan).
mod query_engine;
/// 批量改行的零行命中原因聚合（第 70 轮从 api 移出，见模块文档）。
mod zero_rows;
pub mod privileges;
pub mod secure;
pub mod ssh;
pub mod state;

// ---------------------------------------------------------------------------
// 兼容别名：契约层已拆成独立 crate `dbpilot_core`（33 轮）。
//
// 保留 `crate::core::*` / `crate::db::*` / `crate::error::*` / `crate::filter::*`
// 这些旧路径，api/state/drivers 的 30+ 个调用点不需要批量改名。真正的依赖
// 方向由 Cargo.toml 固定：主 crate 依赖 dbpilot-core，反向编译不成立。
// ---------------------------------------------------------------------------

/// 契约层（驱动/方言/连接/注册表/插件/会话/账号 + DTO）。
pub mod core {
    pub use dbpilot_core::{
        account, config, connection, dialect, driver, paging, plugin, registry, session,
    };
    pub use dbpilot_core::{
        ConnSpec, ConnectionConfig, ConnectionHandle, DatabaseDialect, DatabaseDriver,
        DialectCapability, DriverKind, DriverMetadata, DriverRegistry, PoolProvider,
        SessionHandle, SqlParam, SqlQuery, SqlSession,
    };
}

/// 结果类型（ResultSet / ColumnMeta / ScanStats）与语句工具。
pub mod db {
    pub use dbpilot_core::db::*;
}

/// 统一错误（AppError / AppResult）。
pub mod error {
    pub use dbpilot_core::error::*;
}

/// 表浏览筛选解析（严格文法，防注入）。
pub mod filter {
    pub use dbpilot_core::filter::*;
}

#[cfg(test)]
mod modular_tests;

#[cfg(test)]
mod security_tests;

#[allow(deprecated)]
#[rustfmt::skip]
mod frb_generated;