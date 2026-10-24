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

use crate::db::{RawResultBatch, ResultBatch, ResultSet};

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

    /// 执行一条语句，把结果行按 `batch_size` 分批交给 `on_batch`
    /// （第 3 层分批流式；`run_query_stream` 的驱动入口）。
    ///
    /// 返回的 [ResultSet] 只带元信息（`rows` 为空）：行已经全部走回调。
    /// `on_batch` 返回 false 表示调用方要求停止（Dart 端取消了 stream），
    /// 驱动应停止读取并关闭该连接；`truncated` 只出现在最后一批上。
    ///
    /// 默认实现给没有原生行流的驱动（PostgreSQL / SQLite）用：先走现有
    /// `run_limited`（行为不变、整份物化），再按 [ResultBatch] 切块回调。
    /// 有原生流式能力的驱动（MySQL）覆盖此方法。
    ///
    /// 回调类型写死成 `&mut (dyn FnMut(ResultBatch) -> bool + Send)` 而不是
    /// 泛型，trait 才能保持对象安全（api 只持有 `Box<dyn SessionHandle>`）。
    async fn run_batched(
        &mut self,
        statement: String,
        max_rows: usize,
        batch_size: usize,
        on_batch: &mut (dyn FnMut(ResultBatch) -> bool + Send),
    ) -> ResultSet {
        let result = self.run_limited(statement, max_rows).await;
        chunk_result_set(result, batch_size, on_batch)
    }

    /// 执行一条语句，把结果行按 `batch_size` 分批以 [RawResultBatch] 交给
    /// `on_batch`（SQL 控制台 typed / streaming 路径的驱动入口）。
    ///
    /// 语义与 [SessionHandle::run_batched] 完全相同（行数上限、`truncated` 只在
    /// 最后一批、consumer 返回 false 时停止并关闭连接），区别只在行的中间表示是
    /// [crate::db::RawCell]：有原生解码能力的驱动（MySQL）直接从 sqlx 的
    /// `Row` 解码，不构造 `serde_json::Value`（一次性结果集里这是最大的一笔
    /// 开销）。
    ///
    /// 默认实现给没有原生 raw 解码的驱动（PostgreSQL / SQLite）用：走现有的
    /// `run_batched`（行为不变），再把每批 [ResultBatch] 逐格反向转成
    /// [RawResultBatch]。反向规则与 MySQL 的 `value_to_json` 严格镜像，
    /// 见 [crate::db::RawCell::from_legacy_json]。
    async fn run_batched_raw(
        &mut self,
        statement: String,
        max_rows: usize,
        batch_size: usize,
        on_batch: &mut (dyn FnMut(RawResultBatch) -> bool + Send),
    ) -> ResultSet {
        let mut convert = |batch: ResultBatch| -> bool {
            on_batch(RawResultBatch::from_result_batch(batch))
        };
        self.run_batched(statement, max_rows, batch_size, &mut convert)
            .await
    }
}

/// 默认分批实现：把已经物化的 [ResultSet] 按 `batch_size` 切块回调。
///
/// 独立成函数是为了让覆盖了 `run_batched` 的驱动（MySQL 只对行语句真流式，
/// 非行语句仍复用 `run_limited`）也能复用同一套切块语义。
pub fn chunk_result_set(
    result: ResultSet,
    batch_size: usize,
    on_batch: &mut (dyn FnMut(ResultBatch) -> bool + Send),
) -> ResultSet {
    let batch_size = batch_size.max(1);
    let ResultSet {
        columns,
        rows: mut pending,
        row_count,
        last_insert_id,
        statement,
        kind,
        error,
        truncated,
    } = result;
    while !pending.is_empty() {
        // O(1) carve-out: `split_off` then drop the delivered chunk, so a huge
        // materialised result shrinks as it is handed over instead of being
        // cloned chunk by chunk.
        let rest = pending.split_off(batch_size.min(pending.len()));
        let chunk = std::mem::replace(&mut pending, rest);
        let last = pending.is_empty();
        let batch = ResultBatch {
            columns: columns.clone(),
            rows: chunk,
            truncated: last && truncated,
        };
        if !on_batch(batch) {
            break;
        }
    }
    ResultSet {
        columns,
        // Delivered through the callback; keeping them would double the memory.
        rows: Vec::new(),
        row_count,
        last_insert_id,
        statement,
        kind,
        error,
        truncated,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::ColumnMeta;
    use serde_json::{json, Value};

    fn sample(rows: usize, truncated: bool) -> ResultSet {
        ResultSet {
            columns: vec![ColumnMeta {
                name: "x".to_string(),
                type_name: "INT".to_string(),
            }],
            rows: (0..rows).map(|i| vec![json!(i as i64)]).collect(),
            row_count: rows as u64,
            last_insert_id: 0,
            statement: "SELECT x".to_string(),
            kind: "rows".to_string(),
            error: None,
            truncated,
        }
    }

    #[test]
    fn default_batching_chunks_rows_and_clears_rows() {
        let mut batches: Vec<ResultBatch> = Vec::new();
        let result = chunk_result_set(sample(5, true), 2, &mut |batch| {
            batches.push(batch);
            true
        });
        let sizes: Vec<usize> = batches.iter().map(|batch| batch.rows.len()).collect();
        assert_eq!(sizes, vec![2, 2, 1]);
        // Only the final batch carries the truncation flag.
        let flags: Vec<bool> = batches.iter().map(|batch| batch.truncated).collect();
        assert_eq!(flags, vec![false, false, true]);
        // Every batch repeats the column metadata.
        assert!(batches.iter().all(|batch| batch.columns.len() == 1));
        assert!(result.rows.is_empty(), "rows must go through the callback only");
        assert_eq!(result.row_count, 5);
        assert!(result.truncated);
    }

    #[test]
    fn default_batching_stops_when_callback_returns_false() {
        let mut seen = 0usize;
        let result = chunk_result_set(sample(10, false), 2, &mut |_batch| {
            seen += 1;
            seen < 2
        });
        assert_eq!(seen, 2, "callback stop must stop delivery");
        assert!(result.rows.is_empty());
        assert_eq!(result.row_count, 10);
        assert!(!result.truncated);
    }

    #[test]
    fn default_batching_of_an_empty_result_calls_nothing() {
        let mut calls = 0usize;
        let result = chunk_result_set(sample(0, false), 2, &mut |_batch| {
            calls += 1;
            true
        });
        assert_eq!(calls, 0);
        assert!(result.rows.is_empty());
        // Column metadata is still available for the DTO.
        assert_eq!(result.columns.len(), 1);
        let _: Vec<Value> = Vec::new();
    }

}
