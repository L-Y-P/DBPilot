# 数据传输优化（第 42 轮）：typed struct + StreamSink 分批流式

> 目标：削减 Rust → Flutter 结果集传输的「文本化 + 整份物化」成本，改善 SQL 控制台首屏。
> 基线：flutter_rust_bridge 2.13.0 / Flutter 3.47.7 / Rust 1.99.1 / MySQL 8.4（dbpilot_perf）。
> 本文对应代码改动，详细证据与基准脚本见仓库外 `analysis/OPT_RESULT.md` 与 `analysis/probe/`。

## 0. 结论速览

| 指标（MySQL，release dylib） | 改动前（旧二进制，第 41 轮基线） | 改动后 |
| --- | --- | --- |
| 控制台 50k 行查询→结果可用 | ~147–156 ms（整包 JSON 过桥 + jsonDecode） | **首批 2.0–2.3 ms 可上屏；全部完成 102.7 ms** |
| 控制台 5k 行查询 | ~13 ms | **首批 2.0 ms；全部完成 11.7 ms** |
| 共享 `Api.query`（非控制台视图） | ~3 / 13.7 / 148 ms（1k/5k/50k） | 6.7 / 12.1 / **107.4 ms** |
| 单次 typed 返回（对照） | — | 6.4 / 13.2 / 164.9 ms |
| 兼容层 `run_query`（仅 Rust 测试用） | ~148 ms（50k） | 188 ms（多一层 CellValue 中间态，见 §5） |

关键点：**50k 行控制台查询的总传输耗时降低约 30%，首屏等待从「整包完成」变成「第一批 500 行」≈2 ms。**

## 1. 第 1 层：typed struct 边界

- 新增 `rust/src/api/query_types.rs`：`CellValue`（kind 码 0..5，避免带字段 enum → freezed 依赖）、`ColumnDto`、
  `ResultSetDto`、`QuerySummaryDto`、`QueryResponseDto`、`QueryEvent`。
- 新增 `rust/src/query_engine.rs`（内部实现，移出 `crate::api`）：单一 `run_engine` + observer，
  同时支撑 `run_query`（JSON 兼容）、`run_query_typed`（typed）、`run_query_stream`（流式），
  保留多语句切分、USE 切换 / prelude 重放、cancel token、DDL 池驱逐、search_path、history。
- `api/query.rs` 只剩 FRB 面：`run_query` / `run_query_typed` / `run_query_stream` + 原有 cancel/explain/history。
- **消除**：Rust `json!({...})` 的 `to_value` 深拷贝、`serde_json::to_string`、Dart `jsonDecode`。
- Dart：`Api.query()` 改为消费流式事件聚合（见 §2）；`cellValueToJson` 把 CellValue 映射回旧 Map cell 形状
  （bytes → `{"__binary__": base64, "len": n}`），所有既有视图的 Map 契约不变。

## 2. 第 3 层：StreamSink 分批流式（本轮主要收益）

- `run_query_stream(sink: StreamSink<QueryEvent>, body)` 事件：`started` → N×`batch`(500 行/批) → `statement_done` → `done`；
  顶层失败 `failed`。MySQL 驱动在 sqlx `fetch` 循环里边读边发；PG/SQLite 走默认「先物化再切块」（行为不变）。
- SQL 控制台 `sql_view._run()` 改为 `await for` 流式事件，逐批 `setState` 追加 rows；首批到达即可显示前 50 行，
  `done` 时写 summary + `search_path` + 触发 DDL 后的树刷新。
- 非控制台的 `Api.query()` 也改为流式聚合：边收边拼旧 Map，避免 5 万 ×4 个 `CellValue` 对象整包物化。
  实测比 typed 一次性返回快 23–48%（1k/5k/50k：8.1→4.2 / 15.5→11.9 / 169→116 ms，同进程对比）。
- `session.rs` 新增 `SessionHandle::run_batched`（默认切块、MySQL 覆盖为真流式）；
  `drivers/mysql/exec.rs` 的 `run_one_limited_batched_owned` 负责逐行读取与截断/close 语义。

## 3. 为什么不按原方案做「第 2 层 ZeroCopyBuffer + bincode/rkyv」

经核实（FRB 2.13.0 源码）：

1. **`ZeroCopyBuffer` 已被移除**：codegen 直接报错
   `"ZeroCopyBuffer<T> is no longer needed, since zero-copy is automatically utilized, just directly use T instead."`
   （`flutter_rust_bridge_codegen-2.13.0/src/library/codegen/parser/mir/parser/ty/concrete.rs:52`）。
2. **没有 `zero-copy` cargo feature**：`flutter_rust_bridge-2.13.0/Cargo.toml` 的 features 列表里不存在该 feature。
3. **FFI 交接本来就已经是「指针过界」**：`Vec<u8>` 用 `Dart_CObject_kExternalTypedData`（ptr+len+finalizer）移交，
   0 拷贝；真正剩下的唯一一次复制在 Dart 运行时 `read_buffer.getUint8List`（注释自认非 sync 路径可不复制但目前仍复制）。
4. 实测 bincode 1.3.3（离线缓存）：50k×4 cell 朴素 struct 编码 1.54 ms，但载荷 2.89 MB（比 JSON 的 2.6 MB 还大）；
   且需要自己维护 Dart 解码器 + 仍有一次 Dart 字节复制。相对已经落地的 typed SSE + 流式的净收益预计 <10 ms/50k 行，
   而复杂度与维护成本明显上升 —— **本轮不落地**。若确实需要「真零拷贝」，正确方向是 RustOpaque 结果句柄 + 按页取数（不是 bincode）。

> 附：FRB 2.13 的带字段 enum 会生成 `@freezed` Dart 类，而本工程没有 freezed 依赖，因此 DTO 全部用
> `struct + kind 码` 表达（`CellValue.kind`/QueryEvent.kind`），避免引入 freezed/build_runner。

## 4. 验证

- Rust：`cargo build --offline --lib` ✅；`cargo test --offline --lib` ✅（core 18 + 主 crate 141）；
  `cargo test --offline --workspace` ✅（28 targets 全绿）。
- Flutter：`flutter test` ✅ **409 passed / 8 skipped**（含新增 `test/query_adapter_test.dart` 8 例）；
  `dart analyze` ✅ No issues。
- 兼容性：typed 适配与旧 `runQuery` JSON **逐字段深度相等**（含 mixed_500k 的 BLOB/DECIMAL/JSON、bigtext、
  COUNT、SHOW TABLES；仅 `elapsed_ms` 因两次调用各测各的而不同）。
- 流式语义：50k 截断（101 批 / 50,000 行 / `truncated=true`）、错误语句（`StatementDone.error` + `failed=1`）、
  `USE db; SELECT 1` 多语句（2 个 statement、事件索引对齐）均实测通过。
- codegen 幂等：重复 `flutter_rust_bridge_codegen generate` 后生成文件哈希不变。

## 5. 已知取舍 / 后续

| 项 | 说明 |
| --- | --- |
| PG / SQLite 流式 | 仍「先物化再切块」，没有 MySQL 的真流式首屏收益（行为不变）。 |
| 兼容层 `run_query` | 现在是 typed → JSON（多一层 CellValue 中间态），50k 基准 ~188 ms，比旧实现慢；只被 Rust 集成测试使用，不影响 UI。若要保性能，可后续给 engine 加一个「直接产出 JSON」的 observer。 |
| 流式期间分页 | 每批 setState 会让结果表重建，`_RowsResultView` 的分页可能被重置到第 1 页；流式通常亚秒结束，属可接受观察项。 |
| 控制台截断 | 仍受 `MAX_CONSOLE_ROWS = 50_000` 限制；流式不会改变该上限。 |
| 生成文件格式 | 本机未安装 rustfmt，codegen 跳过 `frb_generated.rs` 格式化（可编译）；需要格式化时 `rustup component add rustfmt` 后重跑 codegen。 |
| 内存 | 流式不再同时持有「整包 JSON 文本 + wire + Dart 对象树」；Dart 侧仍按 UI 需要累积结果 Map（分页需要）。 |

## 6. 关键文件

- `desktop/rust/src/api/query_types.rs`：DTO（CellValue/ResultSetDto/QueryEvent/…）
- `desktop/rust/src/query_engine.rs`：单一执行引擎 + observer + 流式/批量驱动接入
- `desktop/rust/src/api/query.rs`：FRB 面 `run_query` / `run_query_typed` / `run_query_stream`
- `desktop/rust/crates/dbpilot-core/src/session.rs`：`SessionHandle::run_batched` 默认实现
- `desktop/rust/src/drivers/mysql/exec.rs`：MySQL 真流式（500 行/批）
- `desktop/lib/src/api.dart`：`query()` 流式聚合、`queryStream()`、CellValue→Map 适配
- `desktop/lib/src/views/sql_view.dart`：控制台渐进渲染
- `desktop/test/query_adapter_test.dart`：8 个纯 Dart 适配/聚合用例
## 7. 第 43 轮补漏（评审意见落实）

### 7.1 剩下的那次复制（read_buffer）

`flutter_rust_bridge-2.13.0` 的 SSE 解码在 `read_buffer.dart` 里对每个字节切片做 `Uint8List.fromList`。
异步消息的底层 buffer 是 `ExternalTypedData`（指针+所有权已移交 Dart VM），本可返回视图；只有
同步 FFI 路径必须复制（Rust 返回后立即释放）。实测复制成本：2.6 MB → 1.94 ms，4 MB → 2.61 ms，
流式 100×40 KB → 0.33 ms。**结论：复制存在但已很小（50k 查询 0.3–4 ms，约占 103 ms 的 0.3–4%），
不为它 vendoring 632 KB 的 FRB Dart 运行时**；已产出上游 patch（异步 copy=false / 同步 copy=true）：
`desktop/tools/patches/flutter_rust_bridge-2.13.0-zero-copy-sse.patch`（附应用步骤）。

### 7.2 兼容层 deprecated

`api/query.rs::run_query` 已加 `#[deprecated]`（note 写明仅集成测试/兼容，新代码用 `run_query_typed`/
`run_query_stream`）；Dart facade 已不再调用它。

### 7.3 生成文件不参与格式化

- Rust：stable rustfmt 不支持 `rustfmt.toml` 的 `ignore`（nightly-only），改为 `src/lib.rs` 里
  `#[rustfmt::skip] mod frb_generated;`（实测 rustfmt 跳过该文件）；`tools/format.sh` 用显式文件列表。
- Dart：`analysis_options.yaml` exclude `lib/src/rust/**`；`tools/format.sh` 只格式化非生成文件。

### 7.4 架构守卫进 CI

`tools/check_api_surface.py`（`make api-guard` + `rust-live.yml` 步骤）检查：api 模块不得出现 db 类型、
生成文件不得出现 opaque db 类型、api 不得有 `pub(crate) trait/struct`、Rust/Dart kind 常量逐项一致。

### 7.5 Rust-only profile（给下一轮专项定方向）

| 查询 | Rust-only typed | Rust-only legacy JSON |
| --- | --- | --- |
| LIMIT 1,000 | 2.75 ms | 3.10 ms |
| LIMIT 5,000 | 9.24 ms | 13.28 ms |
| LIMIT 50,000 | 95.36 ms | 139.31 ms |

Dart typed 50k 总 165 ms → 桥+解码 ≈ 70 ms；流式 50k 总 103 ms，而 Rust 引擎 ~95 ms —— 流式把
Rust 取数/编码与 Dart 解码**流水线重叠**了（墙钟 ≈ max 而非 sum）。
对 RustOpaque 按页 fetch 的含义：流式首批 2 ms 已是「取前 500 行」的下限；opaque 仍要跑完整查询
（~95 ms）才拿到句柄，**首屏不会更快**，收益在随机翻页与 Dart 内存/GC。专项验收应看翻页延迟与内存。

### 7.6 bincode 措辞修正

「载荷比 JSON 大」只对默认 fixed-int 配置成立；varint/postcard 会更紧凑。结论不变的理由是
**它优化错了环节**：真实成本是对象树构建/GC/解码，wire 字节只是小头；且 FRB 2.13 已移除 ZeroCopyBuffer、
FFI 交接本就零拷贝。
### 7.7 PG / SQLite 真流式（第 43 轮补上）

- SQLite：`drivers/sqlite/mod.rs::run_one_limited_batched_owned` 改为 sqlx `fetch` 逐行、500 行/批回调；
  3 个驱动级测试（1200 行三批、cap=1100 截断只标最后一批、consumer 返回 false 立即停）。
  截断发生在语句中途，**该连接按契约必须关闭、不能复用**（复用会挂起）；`run_batched` 在 truncated/stopped 时
  已 close，测试按契约修复。
- PostgreSQL：`drivers/postgres/mod.rs::run_one_limited_batched_owned` 用同样的 fetch 逐行模式；本机无 PG 服务，
  仅编译 + workspace 测试通过，live 流式验证留待有 PG 的环境。
- 最终验证：Rust lib core 18 + 主 crate 145 passed；workspace 28 targets 全绿；Flutter 409 passed / 8 skipped；
  `dart analyze` 干净；`tools/check_api_surface.py` OK。
## 8. 第 45 轮：RawCell 直通（SQL 控制台跳过 `serde_json::Value`）

- MySQL 控制台路径（typed/streaming）改为 `sqlx::Row → RawCell → CellValue`，不再构造 `serde_json::Value`；
  PG/SQLite 通过 `run_batched_raw` 默认实现兜底（Value→RawCell），行为不变。
- microbench（50k×4 cell）：`fetch_all` 25.0 ms；+row_values(Value) 84.0 ms；+raw_row_values(RawCell) 78.0 ms；
  引擎 typed **95.5 → 87.1 ms（−9%）**。Value 特有开销只有 ~6 ms，**每 cell 物化 ~53 ms 才是大头**
  （每格 String decode + Vec 分配）。
- 墙钟：流式 50k 101.5 → **89.2 ms**，`Api.query` 107.5 → **94.1 ms**，typed 161.8 → **143.1 ms**（约 −12%）；
  前缀仍 ~1.8 ms（取数下限）。
- legacy `run_query` JSON 契约不变（16 形态单测 + MySQL 18 列全类型对照）；未改 FRB 面，无需 codegen。

## 9. 下一步（由数据决定）

1. **cell 物化 53 ms** 是当前最大头：方向是 driver 直写 wire/列式缓冲，避免每格中间 String/Vec；这是比
   RustOpaque 更贴近瓶颈的优化。
2. 流式墙钟 89 ms ≈ Rust 87 ms，Dart decode 仍几乎被流水线掩盖；若 Rust 降到 ~50 ms，需重新观察 Dart decode
   （届时 read_buffer patch 可能重新值得评估）。
3. RustOpaque + 按页 fetch 暂缓：首屏瓶颈是「取数」，opaque 仍要跑完整查询；它只对「完整浏览 + 随机翻页」
   的产品路径有意义，先确定产品主流程。
> 第 45 轮补漏：PG 17 live 验证了截断/consumer stop/连接复用三条路径（临时库，见 analysis/OPT_RESULT.md §12）；
> 最终基线：Rust core 23 + 主 crate 150、workspace 28 全绿；Flutter 409/8；analyze/guard 干净。
> 第 46 轮补漏：已验证 FRB 当前配置（full_dep 默认 false）强制 SSE，`Vec<u8>` 返回仍是 SSE 逐字节编码，
> 因此「driver 直接写 wire」方向关闭；`full_dep=true` 会走 DCO/ExternalTypedData 零拷贝，但需要 ffigen 且
> native 下 `serde_json::Value` 无 `IntoDart`（80 个 API 编不过），属全局迁移。已新增 `value_to_json`/`raw_cell`
> 类型分发一致性守卫（含人为漂移自测），并确认 `#[allow(deprecated)]` 在 lib.rs 的 mod 声明上。
## 10. 第 47 轮：行数分布埋点 + 决策前置

- 新增 `lib/src/query_metrics.dart`：本地 JSONL（`data_dir/query_metrics.jsonl`），只存 SQL 的 SHA-256 前 16 位，
  不存原文；字段含 result_rows / truncated / elapsed_ms_rust / wall_ms / stmt_type / source / paged 事件，
  `DBPILOT_QUERY_METRICS=0` 可关闭；用于 1–2 周后判断 50k 优化是否值得继续。
- 「已评估未采纳」：bincode、Vec<u8> 直写 wire、full_dep/DCO、列式缓冲、opaque 暂缓、RustOpaque raw pointer
  （每条实测/约束/关闭理由见 analysis/OPT_RESULT.md §14）。
- `Makefile` 新增 `make test` / `make test-flutter`：自动检查并补 debug dylib 后再跑测试。
- 守卫扩展：`value_to_json` 与 `raw_cell` 的类型字面量、`tname` 次数、`if` 分支数、`=>` 数量一致。
## 11. P99 测试与决策（第 48 轮）

- 507 次查询（340 受控分层 + 167 条历史回放）实测：历史回放 result_rows P50/P90/P99 = 500/1000/5000，
  truncated 0/167，wall P50 2.7 ms / P99 263.9 ms（P99 是 3 条 COUNT(*) 10M）；50k 首批 P50 1.9–3.4 ms。
- **决策：停止继续压 50k 行取数，保留 cap 50000，不放开 cap、暂缓 opaque 分页；转 UI**（结果按可见页转换、慢查询反馈/取消、截断 banner）。
- 复开阈值：14 天真实埋点 ≥800 runs，R1 P99(rows)≥5000 ∧ R2 truncated≥2% ∧ R3 ≥5k 结果 paged≥30%，R4 佐证。
- 见 [analysis/P99_REPORT.md](../../analysis/P99_REPORT.md)（含看板 SQL、样本量、局限）。

## 12. RustOpaque raw pointer（机制验证，第 48 轮）

- 新增 `rust/src/api/raw_buffer.rs` + `lib/src/raw_buffer.dart`：opaque `RawRowBuffer`、ptr/len、Dart `Pointer.fromAddress().asTypedList()` 零拷贝视图、按 tag 分页 skip、finally dispose。
- 50k×4：typed 147.3 ms vs raw 调用 94.3 ms（省 ~53 ms 桥接编解码）；视图 0.08 ms、首 50 行 0.01 ms、第 25k 行 1.05 ms；
  全量解析 38–56 ms → 全量物化与 typed 打平；**价值在随机分页/导出，首屏仍走流式**。
- 安全边界：视图不受 GC 追踪，必须 handle 存活 + 显式 dispose；不接 UI、不新增依赖；见 [analysis/OPAQUE_REPORT.md](../../analysis/OPAQUE_REPORT.md)。

## 13. 查询构建器 UI 与其它页面统一（第 48 轮）

- 原构建器使用自绘 15px 标题 + 带边框工具栏 + 30px 小按钮 + 10/12px 内边距，与数据库/服务器页的 `PageHead` 规范不一致。
- 改为标准 `PageHead`（mono 20 标题、数据源选择器/状态 chip 放 meta、右侧标准按钮）、去掉 toolbar 边框、统一 `AppMetrics.mainPadding`(16)。
- 保留快捷键与所有 ValueKey；builder 24 项测试通过，golden `app_08_builder.png` 已更新。

## 14. 取消按钮是否真停数据库查询（第 48 轮 live 验证）

- **MySQL：是**（`KILL CONNECTION` 匹配 cancel token 的 PROCESSLIST 会话；池失效、自动重连；live 测试通过）。
- **PostgreSQL：是（取消当前语句）**（`pg_cancel_backend`；会话保留可用；live 测试通过）。
- **SQLite：否**（进程内执行，API 返回无法安全取消，查询继续）。
- 边界：取消服务端当前语句；本地脚本循环不会立即中止；单语句查询即“停查询”。
## 15. 第 49 轮：交接问题修复与表浏览优化复用

- 导入：去整批 clone / 每 cell literal / 每行 Map，改文本协议直写，100MB 1.87→**1.98 MB/s（+5%）**；
  oracle 4.65–5.54 MB/s，Rust 剩余 ~29s/100MB，**未达 4MB/s**，下一步 prepared 二进制 INSERT + 并行 + pinned transaction。
- 新增 `apply_row_changes`（单事务批量更新）与 DataGrid 脏格「保存全部改动」；表页/SQL 结果页接入。
- 备份：流式 temp 文件，17.4→**10.3s（-41%）**、RSS +1.2GB→+1.6MB；恢复：DML 分批事务，22.5→**13.9s（-38%）**，commit 1002→8；
  顺带修复旧 dump 单条 120MiB INSERT 超过 max_allowed_packet 的问题。
- 查询构建器：数据源 5000 表单帧只建 19 行（远跳 20.9s→0.24s），预览只转换前 1000 行；结构同步结果/执行结果各 50/页。
- 表页 SQL 新增取消按钮（MySQL KILL / PG pg_cancel_backend / SQLite 不支持）；死端口 30s→<5s；池大小默认 8 可配；
  高亮 8–120KB debounce 120ms。
- 验证：Rust core 28 + 主 163 passed；Flutter 454 passed / 8 skipped；analyze/guard 绿。