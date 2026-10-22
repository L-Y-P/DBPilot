//! 内置驱动注册入口（静态插件）。
//!
//! `register_builtin_drivers` 被 `core::plugin` 的内置插件调用，
//! `AppState::new` 在启动时激活一次。新增数据库驱动时只需要：
//! 1. 在 `drivers/<id>/` 下实现 `DatabaseDialect` + `DatabaseDriver`；
//! 2. 在这里注册；
//! 3. （可选）加一个 `Plugin` 子类型 —— api 与 state 都不用改。

use std::sync::Arc;

use crate::core::dialect::DatabaseDialect;
use crate::core::driver::{DatabaseDriver, DriverMetadata};
use crate::core::plugin::{Plugin, PluginContext};
use crate::core::registry::DriverRegistry;
use crate::error::AppResult;

use super::mysql::dialect::MYSQL_DIALECT;
use super::mysql::driver::{MySqlDriver, MYSQL_METADATA};
use super::postgres::dialect::POSTGRES_DIALECT;
use super::postgres::driver::{PostgresDriver, POSTGRES_METADATA};
use super::sqlite::dialect::SQLITE_DIALECT;
use super::sqlite::driver::{SqliteDriver, SQLITE_METADATA};
use super::DriverKind;

/// 注册三个内置驱动。重复注册会返回错误（注册表据此发现插件重复激活）。
pub fn register_builtin_drivers(registry: &DriverRegistry) -> AppResult<()> {
    registry.register(Arc::new(MySqlDriver) as Arc<dyn DatabaseDriver>)?;
    registry.register(Arc::new(PostgresDriver) as Arc<dyn DatabaseDriver>)?;
    registry.register(Arc::new(SqliteDriver) as Arc<dyn DatabaseDriver>)?;
    Ok(())
}

/// `DriverKind` → 方言实例。过渡期给旧 `Db` 门面用。
pub fn dialect_for(kind: DriverKind) -> &'static dyn DatabaseDialect {
    match kind {
        DriverKind::Mysql => &MYSQL_DIALECT,
        DriverKind::Postgres => &POSTGRES_DIALECT,
        DriverKind::Sqlite => &SQLITE_DIALECT,
    }
}

/// 内置驱动的静态元数据（注册表之外的唯一来源）。
pub fn builtin_metadata() -> Vec<&'static DriverMetadata> {
    vec![&MYSQL_METADATA, &POSTGRES_METADATA, &SQLITE_METADATA]
}

/// 未初始化时 `driver_options()` 的兜底 JSON（字段与注册表输出一致）。
pub fn builtin_options_json() -> serde_json::Value {
    serde_json::Value::Array(
        builtin_metadata()
            .into_iter()
            .map(|metadata| metadata.to_json())
            .collect(),
    )
}

/// 内置驱动插件：唯一职责是把驱动注册进注册表。
pub struct BuiltinDriversPlugin;

impl Plugin for BuiltinDriversPlugin {
    fn id(&self) -> &'static str {
        "builtin.drivers"
    }

    fn name(&self) -> &'static str {
        "内置数据库驱动"
    }

    fn activate(&self, ctx: &PluginContext<'_>) -> AppResult<()> {
        register_builtin_drivers(ctx.registry())
    }
}

/// 本轮的全部插件（顺序即驱动展示顺序）。
pub fn builtin_plugins() -> Vec<Box<dyn Plugin>> {
    vec![Box::new(BuiltinDriversPlugin)]
}

// --------------------------------------------------- 静态驱动实例（P5）

// 旧门面 Db 的方法现在只做委派；委派目标就是这三个零状态实例。
// 新增驱动时在这里补一行即可（与 register_builtin_drivers 保持一致）。
static MYSQL_DRIVER: MySqlDriver = MySqlDriver;
static POSTGRES_DRIVER: PostgresDriver = PostgresDriver;
static SQLITE_DRIVER: SqliteDriver = SqliteDriver;

/// DriverKind -> 驱动实例。供旧门面与需要按族取驱动的内部代码使用；
/// api 走注册表（AppState::driver / driver_for_active），不直接调这里。
pub fn driver_for(kind: DriverKind) -> &'static dyn DatabaseDriver {
    match kind {
        DriverKind::Mysql => &MYSQL_DRIVER,
        DriverKind::Postgres => &POSTGRES_DRIVER,
        DriverKind::Sqlite => &SQLITE_DRIVER,
    }
}
