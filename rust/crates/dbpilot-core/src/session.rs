//! 被固定的会话（multi-statement console）。
//!
//! P3 Step 1：把「整段脚本固定一条连接」的语义抽成 core trait，api 只持有
//! \`Box<dyn SessionHandle>\`，不再认识 \`drivers::ScriptSession\` / \`SessionConn\`。
//!
//! 为什么需要它（不是多余的抽象）：
//! * 会话级状态（MySQL 的 \`SET FOREIGN_KEY_CHECKS=0\`/用户变量/\`LOCK TABLES\`、
//!   PostgreSQL 的 \`SET search_path\`）只存在于它被设置的那条连接上；
//! * SQL 控制台整段脚本必须复用同一条连接，否则下一条语句可能落到池里另一条
//!   连接，静默丢掉这些状态（30 轮修掉的 P3/P5）；
//! * 中途 \`USE <db>\` 需要换池并重放会话前导语句，\`DROP DATABASE\` 前要先
//!   释放固定连接（否则 \`Pool::close()\` 等待 checked-out 连接会死锁）。
//!
//! 实现固定在驱动侧（当前是 \`drivers::ScriptSession\`，内部按池类型分派），
//! api 只调用本 trait。

use async_trait::async_trait;

use crate::db::ResultSet;

#[async_trait]
pub trait SessionHandle: Send + Sync {
    /// 稳定驱动 id（"mysql" / "postgres" / "sqlite"）。
    fn driver_id(&self) -> &'static str;

    /// 在这条固定连接上执行一条语句，并限制返回行数
    /// （超限时按现有语义：关闭该连接、下一条语句重新获取）。
    async fn run_limited(&mut self, statement: String, max_rows: usize) -> ResultSet;

    /// 当前会话的默认 schema / 数据库（PostgreSQL 必须读固定连接上的
    /// search_path，读池会拿到别的连接的值）。
    async fn search_path(&mut self) -> String;

    /// 释放固定连接（逐出池之前调用，避免 close 等待 checked-out 连接）。
    async fn release(&mut self);
}
