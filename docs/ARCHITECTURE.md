# DBPilot 架构

本文说明 DBPilot 的分层、驱动插件模型、FFI 契约与数据流。
目标读者是想改代码的人：读完应当知道"一个功能该落在哪个文件"。

- 使用说明见 [USAGE.md](USAGE.md)
- 发版流程见 [RELEASE.md](RELEASE.md)
- live 测试见 [CI_LIVE_TESTS.md](CI_LIVE_TESTS.md)

## 目录

- [分层总览](#分层总览)
- [FFI 契约](#ffi-契约)
- [契约层 dbpilot-core](#契约层-dbpilot-core)
- [驱动插件与注册](#驱动插件与注册)
- [新增一种数据库驱动](#新增一种数据库驱动)
- [进程 / 线程 / 锁](#进程--线程--锁)
- [连接 / 池 / 隧道生命周期](#连接--池--隧道生命周期)
- [一次查询的完整数据流](#一次查询的完整数据流)
- [长任务模型（导入 / SQL 文件）](#长任务模型导入--sql-文件)
- [持久化与安全](#持久化与安全)
- [UI 层的结构](#ui-层的结构)
- [改动落点速查](#改动落点速查)
- [约束与不变量](#约束与不变量)

---

## 分层总览

```text
┌──────────────────────────────────────────────────────────────────────────┐
│ L0  Flutter / Dart        lib/src/**（shell / views / components / builder）│
│                           lib/src/api.dart（Api 单例 + JSON 封装 + 错误清洗） │
│                           lib/src/rust/**（codegen 产物，勿手改）             │
└───────────────────────────────────┬──────────────────────────────────────┘
                                    │ flutter_rust_bridge 2.13（JSON 进出）
┌───────────────────────────────────▼──────────────────────────────────────┐
│ L1  FFI 粘合              rust/src/frb_generated.rs                       │
│                           flutter_rust_bridge.yaml：crate::api → lib/src/rust│
└───────────────────────────────────┬──────────────────────────────────────┘
┌───────────────────────────────────▼──────────────────────────────────────┐
│ L2  api（唯一 FFI 表面）   rust/src/api/*：原 HTTP handler → async fn        │
│                           STATE: OnceLock<Arc<AppState>> · parse() · 共享 SQL│
└───────────────────────────────────┬──────────────────────────────────────┘
┌───────────────────────────────────▼──────────────────────────────────────┐
│ L3  编排 / 会话            state.rs（AppState · 唯一授权边界 ensure_visible） │
│                           pools.rs（LRU 5 池 + 隧道注册表）                  │
└───────────────────────────────────┬──────────────────────────────────────┘
┌───────────────────────────────────▼──────────────────────────────────────┐
│ L4  契约层                 rust/crates/dbpilot-core                       │
│                           dialect / driver / registry / plugin / connection │
│                           connection handle / session / DTO / sql / filter  │
└───────────────────────────────────┬──────────────────────────────────────┘
┌───────────────────────────────────▼──────────────────────────────────────┐
│ L5  驱动                   rust/src/drivers/{mysql,postgres,sqlite}/       │
│                           {dialect,driver,account,exec,row}.rs             │
└───────────────────────────────────┬──────────────────────────────────────┘
┌───────────────────────────────────▼──────────────────────────────────────┐
│ L6  引擎 / 横切            importer · exporters · ssh · privileges · db     │
│ L7  持久化                 config · connections · history · backups         │
│                            └── 全部经 secure.rs（私有目录 + 0600 + 原子写）  │
└──────────────────────────────────────────────────────────────────────────┘
```

**依赖方向**由 Cargo 固定，不是口头约定：

- 主 crate `rust_myadmin_core` → `dbpilot-core`，反向编译不成立；
- `api` → `state` → `pools` / `drivers` → `dbpilot-core`；
- 契约层**不认识** `AppState`、`api`、任何具体 sqlx 池类型。

主 crate 的 `pub mod core { pub use dbpilot_core::… }` 只是**兼容别名**，
让 30 多个既有 `crate::core::*` 调用点不用批量改名，不是模块归属。

---

## FFI 契约

### 约定

| 约定 | 说明 |
| --- | --- |
| 入参 | 结构化输入统一 `serde_json::Value`，用 `parse(label, value)` 反序列化成请求结构体 |
| 出参 | `anyhow::Result<Value>`，形状与早期 Web 版的响应体逐字一致 |
| 错误 | `anyhow::Error` 的 message 就是用户可见文案；Dart 侧 `_cleanMessage` 去掉 `AnyhowException(...)` 包装 |
| 同步 vs 异步 | `#[flutter_rust_bridge::frb(sync)]` 只用在真正便宜的函数（`init_app` / `core_version` / `app_config` / `driver_options` / `files::*`） |

`api/` 里的 11 个模块：`mod`（初始化 / 设置 / 驱动选项）、`connections`、`explorer`、
`query`、`server`、`export`、`data_import`、`sqlite`、`sync`、`backup`、`files`。

### 什么时候必须跑 codegen

```bash
flutter_rust_bridge_codegen generate   # 配置见 flutter_rust_bridge.yaml
```

- **必须**：`api/` 里新增 `pub fn` / `pub async fn`，或修改已有函数的签名；
- **不需要**：只改返回 `Value` 里的字段、只改内部实现。

生成物 `rust/src/frb_generated.rs` 与 `lib/src/rust/**` **不要手改**。
Dart 侧 `lib/src/api.dart` 是唯一出口：`Api` 单例 + `Json` 别名 + `_guard` 错误包装，
UI 不直接调用 `lib/src/rust/**`。

---

## 契约层 dbpilot-core

`rust/crates/dbpilot-core/src/`：

| 文件 | 职责 |
| --- | --- |
| `dialect.rs` | `DatabaseDialect`：只**生成 SQL**，不执行。标识符/字符串引号、布尔与二进制字面量、元数据 SQL、`EXPLAIN`、系统库、能力位 |
| `driver.rs` | `DatabaseDriver`：连接、执行、元数据、账号管理、能力判断；`DriverMetadata`；`PoolProvider`（驱动唯一的取池入口） |
| `registry.rs` | `DriverRegistry`：线程安全注册表，按 `driver_id` 取 `Arc<dyn DatabaseDriver>`，注册顺序 = 表单展示顺序 |
| `plugin.rs` | `Plugin` / `PluginContext`：静态插件，启动时激活 |
| `connection.rs` | `ConnectionHandle`（对外的连接句柄）、`SqlSession`（执行接口）、`TunnelInfo` |
| `session.rs` | `SessionHandle`：被固定的会话（SQL 控制台整段脚本共用一个连接） |
| `db.rs` | `ResultSet` / `ColumnMeta` / `ScanStats` / `split_statements` |
| `account.rs` | `AccountAdmin` 与账号 / 权限 DTO |
| `ops.rs` / `spec.rs` | 建表 / 改表的通用编排与 DTO |
| `sql.rs` | `qi` / `qualify` / `literal` / `safe_ident` / `safe_default` 等 SQL 工具 |
| `error.rs` / `filter.rs` / `paging.rs` / `config.rs` / `ssh.rs` | 错误类型、WHERE 严格解析、分页、`DriverKind` / `ConnSpec` / 池身份 key、SSH 纯数据类型 |

两个关键设计：

1. **`ConnectionHandle` 不暴露 sqlx 类型**。内部是 `Arc<dyn SqlSession>`，
   对外只有 `execute` / `query_rows` / `query_i64` / `dialect()` 等；
   所以 `api` 与 `state` 看不到 `MySqlPool` / `PgPool` / `SqlitePool`。
2. **方言 SQL 只有一份**。所有 `SHOW` / `information_schema` / `PRAGMA` 都落在
   `drivers/<id>/dialect.rs`，`api` 里不再出现任何方言 SQL。

---

## 驱动插件与注册

启动时（`AppState::new`）依次激活插件，插件把驱动注册进注册表：

```rust
// rust/src/drivers/builtin.rs
pub fn builtin_plugins() -> Vec<Box<dyn Plugin>> {
    vec![Box::new(BuiltinDriversPlugin)]
}

impl Plugin for BuiltinDriversPlugin {
    fn id(&self) -> &'static str { "builtin.drivers" }
    fn activate(&self, ctx: &PluginContext<'_>) -> AppResult<()> {
        ctx.register_driver(Arc::new(MySqlDriver))?;
        ctx.register_driver(Arc::new(PostgresDriver))?;
        ctx.register_driver(Arc::new(SqliteDriver))?;
        Ok(())
    }
}
```

- 重复注册同一个 `id` 会**报错**（插件重复激活是编程错误，不是静默覆盖）。
- 注册顺序决定连接表单里驱动的展示顺序。
- 注册表用 `std::sync::RwLock`（不是 tokio）：注册发生在启动期，读取只是 clone `Arc`，
  临界区内**不 await**。锁中毒用 `into_inner()` 恢复，一次 panic 不会永久毒化。
- 未知 `driver_id` 返回 `AppError::bad`（用户错误），不 panic。

驱动是**零状态**的 `static` 实例：所有连接状态都在 `ConnectionHandle` 里，
所以 `&self` 方法可以并发调用，不需要 `&mut self`。

---

## 新增一种数据库驱动

以加 `mssql` 为例，只需要动驱动目录与一行注册，**api / state / UI 都不用改**：

1. `rust/src/drivers/mssql/dialect.rs`：实现 `DatabaseDialect`
   （引号规则、元数据 SQL、`EXPLAIN`、系统库、能力位）；
2. `rust/src/drivers/mssql/driver.rs`：实现 `DatabaseDriver`
   （`metadata()`、`dialect()`、`connect()`、`resolve_database()`；元数据方法有默认实现，
   只在方言确实不同处覆盖）；
3. `rust/src/drivers/mssql/mod.rs`：导出 `MssqlDriver` 与 `MSSQL_METADATA`；
4. `rust/src/drivers/builtin.rs`：`ctx.register_driver(Arc::new(MssqlDriver))?`；
5. `rust/src/drivers/mod.rs` 的 `DriverKind` 加一个变体（`ConnSpec` 解析需要）；
6. 如需账号管理，实现 `AccountAdmin`（没有账号体系就返回 `None`）。

`PoolProvider` 由 `PoolRegistry` 实现，驱动**不持有池的生命周期**：
它只提交"连接配置 + 物理库名"，拿到一个 `ConnectionHandle`；LRU 与 SSH 隧道仍在 `pools.rs`。

---

## 进程 / 线程 / 锁

```text
一个进程（桌面 App）
├── static STATE: OnceLock<Arc<AppState>>      init_app 只初始化一次，重复调用是 no-op
├── AppState（Arc 共享）
│   ├── config:        Arc<DesktopConfig>                不可变路径集
│   ├── driver_registry: Arc<DriverRegistry>             std RwLock
│   ├── pools:         PoolRegistry                      tokio RwLock（LRU 5）
│   ├── active:        Arc<RwLock<Option<ActiveConnection>>>
│   ├── settings:      Arc<std RwLock<Settings>>          同步 FFI 也要读
│   └── connections / backups / history                  各自内部锁，写盘走 secure.rs
├── static tunnels(): Mutex<HashMap<u16, SshTunnel>>      本地端口 → 隧道
└── static jobs():    Mutex<HashMap<String, Arc<Job>>>    长任务表（仅进程内）
```

| 不变量 | 原因 |
| --- | --- |
| `init_app` 幂等 | Flutter 可能重建根 widget |
| 未初始化返回错误而非 panic | 误用不该让整个进程崩掉 |
| `settings` 用 **std** 锁 | `app_config` / `files::data_dir` 是 FRB **同步**函数；临界区内只 clone，**绝不跨 await 持锁** |
| 任务表仅进程内 | 重启后旧任务不可查询，设计如此 |
| 隧道生命周期 ≥ 池 | 先关隧道会让所有查询报 connection reset |

---

## 连接 / 池 / 隧道生命周期

```text
Dart            api/connections        state            pools            ssh        drivers
 │ connect_connection(id)  │              │                │               │            │
 ├────────────────────────►│              │                │               │            │
 │                         ├─ bind ──────►│                │               │            │
 │                         │              ├─ uses_ssh? ────►│               │            │
 │                         │              │                ├─ 建本地转发 ──►│            │
 │                         │              │                │  (校验 host key)           │
 │                         │              │                │◄─ register_tunnel          │
 │                         │              ├─ ping() ───────────────────────────────────►│
 │                         │              ├─ 选初始库（only_db / hide_db，跳过系统库）    │
 │                         │              ├─ get(spec, db) ─►│ 命中缓存或新建池          │
 │                         │◄─ {connection, server_version}   │                          │
 │ disconnect()            │              ├─ evict(spec) ───►│ 关池 → release_tunnel ──►│
```

- **池 key** = 连接身份 + 物理库名（SQLite 额外带目录），由
  `dbpilot_core::config::pool_identity_key` 统一计算；
- **LRU 上限 5**：超限逐出最久未用的池，逐出会一并释放隧道；
- **每次 api 调用**都是 `state.connection_for(Some(db))`：命中缓存或按 key 新建；
- **`only_db` / `hide_db` 在"列出"与"执行"两侧都校验**（`ensure_visible`），
  它取代了 Web 版的登录 / 角色授权，是桌面端唯一的数据访问边界。

---

## 一次查询的完整数据流

以 SQL 控制台执行一段脚本为例：

```text
1  lib/src/views/sql_view.dart        用户点「执行」
2  lib/src/api.dart                   Api.instance.runQuery({database, sql})
3  lib/src/rust/**（codegen）          crateApiQueryRunQuery(body)
4  rust/src/api/query.rs              run_query(Value)
     ├─ split_statements_for(dialect, sql)     按方言切分（DELIMITER 是方言能力）
     ├─ open_console_session()                 固定一个会话，整段脚本共用
     ├─ 每条语句：
     │    ├─ 是 USE？ → ensure_visible + 切换 active_database（原始 USE 不下发服务器）
     │    └─ 否则     → session.run_limited(sql, MAX_CONSOLE_ROWS=50_000)
     ├─ 取消：每条语句带 /*rma_cancel:<uuid>*/ 标记，
     │        驱动按标记在 information_schema.PROCESSLIST / pg_stat_activity 里找后端并 KILL
     └─ history.append(entry)                  写查询历史（≤32 K/条）
5  ResultSet { columns, rows, stats }  →  { results: [...], use_database, duration_ms }
6  lib/src/views/result_table.dart    每页 50 行渲染 + 导出菜单
```

要点：

- **USE 不直接下发**：控制台里写 `USE db;` 会被当成"经过校验的库切换"，
  后续语句在新的库上执行，而 `only_db` / `hide_db` 的规则一条都不会被绕过。
- **整段脚本共用一个会话**：`FOREIGN_KEY_CHECKS`、用户变量、`search_path`、
  `LOCK TABLES` 这类会话级状态才会跨语句生效（和 `mysql` / `psql` CLI 一致）。
- **行数上限**在驱动层执行（逐行转换），不是把全部结果拿回来再截断。

---

## 长任务模型（导入 / SQL 文件）

```text
Dart ImportJobPoller（250ms）
  │  import_validate_start / import_execute_start / sql_file_execute_start
  ▼
rust/src/api/data_import.rs
  ├─ tokio::spawn(工作线程)
  ├─ Job { progress: Mutex<Progress>, cancel: AtomicBool, state, result, error }
  ├─ register(job) → jobs(): Mutex<HashMap<job_id, Arc<Job>>>
  └─ 工作线程只碰 importer.rs 的纯逻辑：
        ByteStream（64 KiB 分块）→ RecordScanner → resolve_mapping → 批量 INSERT（默认 500 行）
  │
  ├─ import_job_status(job_id)   轮询进度 / 取结果（完成后从表里移除）
  └─ import_job_cancel(job_id)   置 cancel 标志，工作线程在记录/批次/语句边界检查
```

- 进度按**已读字节**算百分比，执行阶段另带 rows / failed / elapsed_ms；
- 取消在边界生效，**已提交的批次不回滚**（界面上有明确提示）；
- 文件从不整份读入内存：单记录 8 MiB、单语句 16 MiB 上限，超限报可见错误；
- 已结束超过 5 分钟的任务会被清理，长时间使用不会累积。

---

## 持久化与安全

```text
<data_dir>（Dart 从 path_provider 传入；Rust 侧有同语义的 default_data_dir 兜底）
├── connections.json      ConnectionStore   0600（含口令）
├── settings.json         Settings          0600（language / theme / theme_color / page_size /
│                                                  backup_dir / window / 性能开关）
├── query_history.json    HistoryStore      0600（每条 ≤32K；启动压缩旧文件并留 .bak）
└── backups/              BackupStore       0700
    ├── index.json
    └── *.sql             （可在设置里热切换到别的目录）
```

- **`secure.rs` 是唯一落盘通道**：`ensure_private_dir` + `write_private`
  （写临时文件 → 收紧 0600 → 原子 rename）。进程中途崩溃不会留下半截文件；
- 加载旧文件时会**再收紧一次权限**，早期版本留下的宽权限文件会被修正；
- `save_settings` 不只是写文件：生效备份目录变化时，先 `BackupStore::set_dir`
  （建私有目录 + 重载 `index.json`）再更新内存设置，保证 `app_config` / `files::data_dir` /
  备份 store 三者始终指向同一目录；
- 连接文件损坏时**原样保留**成备份并从空列表开始，绝不静默覆盖用户数据。

---

## UI 层的结构

`lib/src/`：

| 目录 / 文件 | 职责 |
| --- | --- |
| `main.dart` | 入口：`RustLib.init()` → `Api.init(dataDir)` → 窗口设置 → `runApp` |
| `api.dart` | FFI 唯一出口：`Api` 单例、`Json` 别名、`_guard` / `_cleanMessage` |
| `app_state.dart` | 全局状态：当前连接、库树、设置、语言；`ChangeNotifier` 风格 |
| `shell.dart` | 顶栏（导航 + 连接信息 + 设置按钮）+ 侧栏（库树 / SQLite 目录分组）+ 路由 |
| `nav.dart` | 轻量路由（`AppRoute`），不是 Navigator 栈 |
| `views/` | 每个页面一个文件：connections / database / table / sql / builder / server / backups / sync / history / settings / data_import_wizard |
| `components/data_grid.dart` | 主数据网格（列虚拟化 + 列宽缓存 + 排序 / 筛选 / 行内编辑） |
| `builder/` | 查询构建器（模型 / 编辑器 / 预览表） |
| `i18n.dart` + `i18n_en/` | 语言切换与英文词典（按区域拆分）；`text.dart` / `tooltip.dart` 是自动过翻译的包装器 |
| `theme.dart` | 运行时调色板 `AppPalette` + 6 套主题预设（`AppColors` 保留旧字段名） |
| `widgets.dart` | 通用控件（Btn / Field / CardBox / GridTable / TablePager / 弹窗 …） |
| `update_check.dart` | 版本比较 + 更新清单解析（可注入 `HttpClient`，测试用本地服务器） |
| `update_source.dart` | `kUpdateManifestUrl` 等常量（更新源固定在代码里） |
| `cu_input.dart` | **仅调试用**的文本注入桥：只在 `RMA_CU_INPUT=1` 时启动，仅监听 `127.0.0.1`，用于桌面自动化；默认关闭，正常运行时没有任何本地端口 |

渲染约定：

- **所有用户可见文案**都要能过翻译层（`Text` / `Tooltip` 包装器或 `trLiteral`），
  `test/english_ui_test.dart` 是"英文界面无中文残留"的门禁；
- 超长文本统一用 `EllipsisText`（真截断才弹提示）；
- 桌面端鼠标拖动需要显式把 `mouse` 加进 `ScrollBehavior.dragDevices`，
  横向滚动条要自己挂（Flutter 只给纵向自动加）。

---

## 改动落点速查

| 想做的事 | 落到哪 |
| --- | --- |
| 新增前端可调用接口 | `rust/src/api/<域>.rs` 加 `pub fn` → 需要时在 `api/mod.rs` 导出 → **跑 codegen** |
| 只改返回字段 | 直接改 `Value` 组装，**不用 codegen** |
| 新增设置项 | `rust/src/config.rs` 的 `Settings` + `sanitize()`（`#[serde(default)]`）→ 需要副作用时挂到 `api/mod.rs::save_settings` |
| 新增数据库驱动 | 见 [新增一种数据库驱动](#新增一种数据库驱动) |
| 新增导出格式 | `rust/src/exporters.rs`（`render` / `formats` / `ExportStream`）+ `api/export.rs` |
| 新增导入格式 | `rust/src/importer.rs`（`ReadSpec` / `FieldSpec` / `inspect` / `preview` / `validate`） |
| 新增落盘文件 | **必须**走 `secure::write_private` / `ensure_private_dir` |
| 新增 UI 页面 | `lib/src/views/` + `nav.dart` 的 `AppRoute` + `shell.dart` 路由分支 |
| 新增主题色 | `lib/src/theme.dart` 的 `kThemePresets`（只需给 accent / header / link 等身份色） |
| 改表格性能 | `lib/src/components/data_grid.dart`（列宽缓存键、列虚拟化）与 `widgets.dart` 的 `GridTable`（行虚拟化） |

---

## 约束与不变量

改代码前请确认这些没被破坏（都有测试或结构守卫）：

1. **`ensure_visible` 是唯一授权边界**：每个命名数据库 / 模式的操作都必须先过它，
   "列表过滤"不能替代它。
2. **FFI 形状稳定**：`api/` 的函数签名与返回 JSON 形状是对 Dart 的契约；
   改形状 = 改契约，要同步 Dart 与测试。
3. **方言 SQL 只在 `dialect.rs`**：`api` / `state` 里出现 `SHOW` / `PRAGMA` / `information_schema`
   就是走错了层。
4. **依赖方向由 Cargo 固定**：契约层不得依赖驱动、`api`、`state`。
5. **大文件不整份读入内存**：导入、SQL 文件执行、导出都必须流式。
6. **所有落盘经 `secure.rs`**：0600 + 原子写，没有例外。
7. **锁不跨 await**：`settings` 是 std 锁，临界区内只 clone。
8. **隧道晚于池销毁**：先关隧道会让所有查询失败。
9. **用户可见文案必须可翻译**：新增中文字面量要同步 `lib/src/i18n_en/`，
   否则 `english_ui_test.dart` 会红。
10. **改了 Rust API 就重跑 codegen**，并核对 `frb_generated.rs` 的 diff 只包含预期变更。
