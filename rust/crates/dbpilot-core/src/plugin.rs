//! 静态插件入口。
//!
//! 本轮**不实现动态加载**（没有 libloading / WASM）。插件在这里只是
//! 「内置驱动注册入口」：启动时激活内置插件，插件把驱动注册进
//! [`DriverRegistry`]。
//!
//! 以后要做动态化时，插件发现/加载/ABI 版本会加在这一层，驱动 trait 与
//! api 调用点都不用改 —— 这正是现在先把 `PluginContext` 定义出来的原因。

use std::sync::Arc;

use crate::error::AppResult;

use super::driver::DatabaseDriver;
use super::registry::DriverRegistry;

/// 插件激活上下文：插件只能通过它注册能力，拿不到 `AppState`。
pub struct PluginContext<'a> {
    registry: &'a DriverRegistry,
}

impl<'a> PluginContext<'a> {
    pub fn new(registry: &'a DriverRegistry) -> Self {
        PluginContext { registry }
    }

    pub fn registry(&self) -> &'a DriverRegistry {
        self.registry
    }

    /// 注册一个驱动。
    pub fn register_driver(&self, driver: Arc<dyn DatabaseDriver>) -> AppResult<()> {
        self.registry.register(driver)
    }
}

/// 插件契约。`id` 用于去重与诊断，`activate` 幂等（重复激活由注册表报错）。
pub trait Plugin: Send + Sync {
    fn id(&self) -> &'static str;
    fn name(&self) -> &'static str;
    fn activate(&self, ctx: &PluginContext<'_>) -> AppResult<()>;
}

/// 依次激活插件，返回激活顺序的 id；任一失败即中止并返回错误。
pub fn activate(
    plugins: &[Box<dyn Plugin>],
    registry: &DriverRegistry,
) -> AppResult<Vec<&'static str>> {
    let ctx = PluginContext::new(registry);
    let mut activated = Vec::with_capacity(plugins.len());
    for plugin in plugins {
        plugin.activate(&ctx)?;
        activated.push(plugin.id());
    }
    Ok(activated)
}
