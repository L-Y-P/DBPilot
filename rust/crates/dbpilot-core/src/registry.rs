//! 驱动注册表：`AppState` 持有它，api 通过它按 `driver_id` 取驱动。
//!
//! 线程安全（`std::sync::RwLock`）：注册发生在启动期（插件激活），
//! 读取发生在每个请求里；临界区内只 clone `Arc`，不跨 await。

use std::collections::HashMap;
use std::sync::{Arc, RwLock};

use crate::error::{AppError, AppResult};

use super::driver::{DatabaseDriver, DriverMetadata};

#[derive(Default)]
struct RegistryInner {
    drivers: HashMap<&'static str, Arc<dyn DatabaseDriver>>,
    /// 注册顺序：`driver_options` 的展示顺序必须稳定。
    order: Vec<&'static str>,
}

/// 进程级驱动注册表。
#[derive(Default)]
pub struct DriverRegistry {
    inner: RwLock<RegistryInner>,
}

impl std::fmt::Debug for DriverRegistry {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DriverRegistry")
            .field("drivers", &self.ids())
            .finish()
    }
}

impl DriverRegistry {
    pub fn new() -> Self {
        DriverRegistry::default()
    }

    /// 注册一个驱动。重复 id 是编程错误（插件重复激活），直接报错。
    pub fn register(&self, driver: Arc<dyn DatabaseDriver>) -> AppResult<()> {
        let id = driver.id();
        if id.trim().is_empty() {
            return Err(AppError::Internal("驱动 id 不能为空".to_string()));
        }
        let mut guard = self.write();
        if guard.drivers.contains_key(id) {
            return Err(AppError::Internal(format!("驱动 '{}' 重复注册", id)));
        }
        guard.order.push(id);
        guard.drivers.insert(id, driver);
        Ok(())
    }

    pub fn get(&self, driver_id: &str) -> AppResult<Arc<dyn DatabaseDriver>> {
        let guard = self.read();
        guard
            .drivers
            .get(driver_id)
            .cloned()
            .ok_or_else(|| AppError::bad(format!("未知的数据库驱动 '{}'", driver_id)))
    }

    pub fn contains(&self, driver_id: &str) -> bool {
        self.read().drivers.contains_key(driver_id)
    }

    /// 已注册的驱动 id（按注册顺序）。
    pub fn ids(&self) -> Vec<&'static str> {
        self.read().order.clone()
    }

    /// 驱动实例（按注册顺序）。
    pub fn drivers(&self) -> Vec<Arc<dyn DatabaseDriver>> {
        let guard = self.read();
        guard
            .order
            .iter()
            .filter_map(|id| guard.drivers.get(id).cloned())
            .collect()
    }

    pub fn metadata(&self) -> Vec<&'static DriverMetadata> {
        // 先绑定 guard 再迭代：避免持读锁时再次 self.read()（递归读锁在有写者
        // 排队时可能被 std 实现拖延，而且本来就是无谓的重复加锁）。
        let guard = self.read();
        guard
            .order
            .iter()
            .filter_map(|id| guard.drivers.get(id).map(|driver| driver.metadata()))
            .collect()
    }

    pub fn len(&self) -> usize {
        self.read().drivers.len()
    }

    pub fn is_empty(&self) -> bool {
        self.read().drivers.is_empty()
    }

    fn read(&self) -> std::sync::RwLockReadGuard<'_, RegistryInner> {
        self.inner
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn write(&self) -> std::sync::RwLockWriteGuard<'_, RegistryInner> {
        self.inner
            .write()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

/// `driver_options()` 的 JSON 形态（保持旧 FFI 返回结构不变）。
pub fn driver_options_json(registry: &DriverRegistry) -> serde_json::Value {
    serde_json::Value::Array(
        registry
            .metadata()
            .into_iter()
            .map(|metadata| metadata.to_json())
            .collect(),
    )
}
