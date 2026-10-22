//! DBPilot 契约层（独立 crate）。
//!
//! 这一层只定义**契约与纯数据**，不依赖任何具体驱动、sqlx 池类型或 SSH 实现：
//! * config：DriverKind / ConnSpec / 池身份 key；
//! * connection：与 sqlx 解耦的 ConnectionHandle + SqlSession + 结果类型；
//! * dialect：DatabaseDialect（SQL 文本、引用规则、能力位）；
//! * driver：DatabaseDriver（连接、执行、元数据）+ PoolProvider；
//! * registry / plugin：驱动注册表与静态插件入口；
//! * session / account：固定会话与账号能力；
//! * ops：与驱动无关的通用编排（分页/行编辑/DDL 组装/脚本执行）；
//! * paging：表数据分页的纯 SQL 生成（keyset 游标 + 延迟关联）；
//! * spec / sql / filter / db / error / ssh：DTO、SQL 工具、筛选解析、
//!   结果类型、错误类型与 SSH 连接参数。
//!
//! 依赖方向由 Cargo 强制：主 crate（rust_myadmin_core）→ 本 crate；本 crate
//! 不再出现 crate::drivers，从结构上不可能反向依赖具体驱动。

pub mod account;
pub mod config;
pub mod connection;
pub mod db;
pub mod dialect;
pub mod driver;
pub mod error;
pub mod filter;
pub mod ops;
pub mod paging;
pub mod plugin;
pub mod registry;
pub mod session;
pub mod spec;
pub mod sql;
pub mod ssh;

pub use config::{ConnSpec, ConnectionConfig, DriverKind};
pub use connection::{ConnectionHandle, SqlSession, TunnelInfo};
pub use dialect::{DatabaseDialect, DialectCapability, SqlParam, SqlQuery};
pub use driver::{DatabaseDriver, DriverMetadata, PoolProvider};
pub use registry::DriverRegistry;
pub use session::SessionHandle;
