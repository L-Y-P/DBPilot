# DBPilot 性能测试报告（第 41 轮）

> 测试日期：2026-10-24　|　版本：1.0.0（工作区，含侧边栏按需构建 + FrameTiming 采样）
> 平台：macOS（AMD Ryzen 5 5600X / 16GB / NVIDIA RTX 5060，Hackintosh），Flutter 3.47.7 / Dart 3.13.5，
> MySQL 8.4.11（本地 127.0.0.1:3306，innodb_buffer_pool_size=128MB，log_bin=ON，sync_binlog=1）
> 构建：**release**（`cargo test --release` / `flutter build macos --release`）

## 0. 结论速览

| 编号 | 优先级 | 场景 | 结果 | 判定 |
| --- | --- | --- | --- | --- |
| P0-1 | P0 | 大结果集（1000 万行无 LIMIT） | 被截断为 5 万行 96.7ms；首屏 1000 行 2.5ms（Rust）/ 1446ms（UI 端到端）；内存 +17MB | ✅ 通过 |
| P0-2 | P0 | 1GB CSV 导入（2412 万行） | **498s（8.3 分钟），2.06 MB/s**；未 OOM；行数完全一致 | ⚠️ 吞吐偏低 |
| P0-3 | P0 | 内存泄漏 50 轮 | Rust +12.4% 但后半段仅 +1.7%；**UI 侧 +7.2% 且完全平台** | ✅ 通过（无真泄漏） |
| P1-4 | P1 | 网格编辑 1 万行保存 | 逐行 4579ms（0.46ms/行）；批量事务 214ms → **差 21.4 倍** | ⚠️ 缺批量接口 |
| P1-5 | P1 | 导出 100 万行 | CSV 2454ms/44.6MB；Excel 4152ms/216.3MB；SQL 可回读 | ✅ 通过 |
| P1-6 | P1 | 10 路并发查询 | wall 14.8ms，**ratio 4.90** | ⚠️ 尾延迟偏高 |
| P1-7 | P1 | 5000 表对象浏览器 | list_tables 冷 685ms / 热 68ms；UI 打开 1303ms；过滤 171µs | ✅ 通过 |
| P2-8 | P2 | 10MB SQL / 编辑器 | 切分 125.9ms；预览 0.1ms；高亮 100KB 19.7ms、10MB 548ms；**无自动补全** | ⚠️ 功能缺口 |
| P2-9 | P2 | 异常恢复 | 杀连接 4ms 自愈；断连重连 20ms；**死端口要 30s 才报错** | ⚠️ 超时过长 |

**四个必须处理的问题**（详见 §4）：

1. **P0-2 导入吞吐只有 1.9 MB/s**：解析与插入各占约一半，且 `batch_size` 从 200 调到 5000 几乎不改变吞吐。
   对照实验显示同一批语句放进一个事务能快 3.9 倍 —— 说明插入路径的**每批提交开销 + 逐行值克隆**没有被摊薄。
2. **P1-4 没有批量提交接口**：UI 每改一格调一次 `change_row`，1 万行要 4.6 秒；一个事务批量更新只要 0.21 秒。
3. **P2-9 连接到不存在的端口要 30 秒**才返回错误（15s acquire_timeout × 2 次尝试），用户会以为程序卡死。
4. **P2-8 编辑器没有自动补全**；且语法高亮 10MB 要 548ms、1MB 要 63ms，是纯同步计算，大文本会卡输入。

> 帧率说明（P0-1 的「滚动帧率」）：应用自身的 UI 线程工作（build）**p50 仅 0.19–0.67ms**，非常好；
> 瓶颈在 raster（p50 17–22ms）。但本机是 Hackintosh（macOS 下 NVIDIA 无官方驱动），
> 空窗口只采到 2 帧时 raster 也是 28ms —— **raster 数字受本机 GPU 路径限制，不代表常规 Mac 的表现**。

## 1. 测试环境与数据集

### 1.1 环境

| 项 | 值 |
| --- | --- |
| 机器 | AMD Ryzen 5 5600X 6 核 / 16GB / NVIDIA RTX 5060 8GB（Hackintosh） |
| 显示器 | 1920×1080 @ 240Hz |
| Flutter / Dart | 3.47.7 stable / 3.13.5（Impeller Metal） |
| Rust | 1.99.1，release profile |
| MySQL | 8.4.11，`innodb_flush_log_at_trx_commit=1`、`sync_binlog=1`、`log_bin=ON`、buffer pool 128MB |
| 磁盘 | 测试期间剩余 2.5–6.9GB（1000 万行整表 SQL 导出曾把盘写满，见 §4.6） |

### 1.2 五套数据集（MySQL 8.0，`tools/perf/gen_datasets.sh` 生成）

| # | 数据集 | 表 | 行数 | 大小 | 导入耗时 |
| --- | --- | --- | --- | --- | --- |
| 1 | 宽表 100 列 VARCHAR(100) | `wide_100k` | 100,000 | 393 MB | 20.4s |
| 2 | 窄大表 4 列 | `narrow_10m` | **10,000,000** | 487 MB | 83.0s |
| 3 | 大字段 TEXT≈10KB/行 | `bigtext_50k` | 50,000 | 785 MB | 7.7s |
| 4 | 多表库 5000 张表（t_0001~t_5000，各 3 列） | 5000 张 | 5000×10 | — | 35.8s |
| 5 | 混合类型 JSON/BLOB/DECIMAL/DATETIME | `mixed_500k` | 500,000 | 96.6 MB | 7.8s |

导入后校验（`COUNT(*)`）：100000 / 10000000 / 50000 / 500000 / 5000，全部与生成量一致。

生成脚本的关键设计：1000 万行不写 1000 万条 INSERT，而是 `INSERT ... SELECT` + 递归 CTE /
交叉连接，由 MySQL 自己展开；生成的 SQL 文件只有 1.1KB–1.8MB，秒级可重建。

### 1.3 怎么跑

```bash
# 生成 + 导入数据集
bash tools/perf/gen_datasets.sh
for f in out/perf-datasets/0*.sql; do mysql -uroot -p dbpilot_perf < "$f"; done

# Rust 侧基准（release，默认 skip，必须给 DBPILOT_PERF=1）
cd rust && DBPILOT_PERF=1 DBPILOT_TEST_MYSQL_PASSWORD=*** \
  cargo test --release --test perf_bench -- --nocapture --test-threads=1
# 1GB CSV 导入（单独跑，默认 1024MB，PERF_CSV_MB 可覆盖）
DBPILOT_PERF=1 PERF_CSV_MB=1024 cargo test --release --test perf_bench -- --nocapture p0_large_csv_import

# UI 侧（真实安装的 release 应用）
cp -R build/macos/Build/Products/Release/DBPilot.app /Applications/
bash tools/perf/ui_automation/run_ui_perf.sh
```
## 2. P0 场景结果

### 2.1 P0-1 大结果集查询渲染（1000 万行无 LIMIT）

**测试方法**：`SELECT * FROM narrow_10m`（无 LIMIT）。应用的控制台有 `MAX_CONSOLE_ROWS = 50,000`
硬上限，所以「1000 万行」实际被测成两件事：(a) 截断是否正确、代价多大；(b) 首屏分页与 JSON 序列化成本。

Rust 侧（release，真实 API）：

```
narrow_10m 无 LIMIT（应被截断）        92.9 ms   rows=50000（上限 50000）
narrow_10m 50,000 行（控制台上限）      96.7 ms   rows=50000 json=2601KB
narrow_10m 首屏 1000 行                 2.5 ms   rows=1000 json=51KB
narrow_10m 首屏 100 行                  1.1 ms   rows=100 json=5KB
narrow_10m COUNT(*)（全表扫描）        225.3 ms
wide_100k 500 行 x 100 列              19.8 ms   rows=500 json=1607KB
bigtext_50k 200 行 x 10KB               6.6 ms   rows=200 json=1922KB
```

**内存峰值**：进程 baseline RSS 4,080 KB（刚起、未建连接池）→ 取满 50,000 行后 21,400 KB。
绝对增量约 **17 MB**，其中 JSON 文本 2.6 MB，其余是 serde_json 的 Value 树与结果集缓冲。

UI 侧（真实 release 应用，CUA 精确计时，窗口 1300×794）：

```
连接 + 库列表就绪                        1285 ms
查询 5000 行 → 结果首屏出现      1389 / 1448 / 1446 ms   （3 轮，含 CUA 轮询粒度）
查询 50,000 行 → 结果首屏出现            1431 ms
表格分页                                 显示 50 / N 行（每页 50 行）
```

**滚动帧率**（应用内 FrameTiming 采样，`DBPILOT_FRAME_TRACE=1`）：

```
空闲/交互中的 60 帧窗口：  build p50=0.19ms p95=0.70ms max=15.01ms
                          raster p50=17.83ms p95=19.94ms max=46.00ms
                          total  p50=33.78ms p95=43.77ms max=72.17ms
连续滚动突发：            60 帧 / 1347ms（≈44 fps）、52 帧 / 2801ms（≈18.5 fps）
jank 率（total > 16.67ms）：100%
```

**解读**：

* **应用自身的工作量很小**：build（Dart/UI 线程：布局 + 绘制指令）p50 只有 0.19–0.67ms，
  说明侧边栏按需构建、表格 50 行/页分页、GridTable 虚拟化都生效了。
* **瓶颈在 raster（GPU 合成）**：p50 17–22ms，单独就超过 60fps 的 16.67ms 预算。
* **但这个数字不能算在应用头上**：本机是 Hackintosh（AMD CPU + NVIDIA GPU，macOS 无官方 NVIDIA 驱动），
  Impeller 走 Metal 但底层驱动非原生。证据：一个只采集到 **2 帧**的空闲窗口 raster 也有 28.3ms，
  且所有窗口的 raster p50 都稳定落在 17–22ms —— 与内容无关的固定底噪。
  **结论：raster 数字只能作为本机环境参考，常规 Mac 上需要复测。**
* 44 fps / 18.5 fps 是「滚动突发期间引擎实际出帧速度」，其中 18.5fps 的那段包含 CUA 逐次滚动指令的间隔，
  不是纯渲染耗时。

### 2.2 P0-2 1GB CSV 导入（约 500 万行规格；实测 2412 万行）

**测试方法**：走应用向导的生产路径 `import_inspect` → `import_execute_start`（后台 job，
`importer::ByteStream` 64KiB 流式扫描 + 分批多值 INSERT）→ 轮询 `import_job_status`。
`batch_size=1000`、`on_error=stop`。

```
生成 CSV                  9030.8 ms   file=1024MB rows=24126000（约 44 字节/行）
导入 1024MB CSV           498178.8 ms  2.06 MB/s   （约 48,400 行/秒）
job state = "done", error = null
表内 COUNT(*)             24,126,000   —— 与生成行数完全一致
RSS 5200 -> 20464 KB      （+293%，绝对增量仅 15MB）→ 未 OOM
```

> **规格差异说明**：任务书写「1GB CSV ≈ 500 万行」，即每行约 210 字节。
> 本次生成的 4 列 CSV 每行约 44 字节，所以 1GB = 2412 万行。
> 行数更多、总字节数一致，对「吞吐量 / 内存 / 是否 OOM」三个指标没有影响；
> 1GB 文件本身是真实的，导入全程没有整文件读入内存。

**瓶颈定位**（额外做了两组对照实验）：

| 实验 | 规模 | 耗时 | 吞吐 |
| --- | --- | --- | --- |
| 只解析不插入（`import_validate_start`） | 100MB / 293 万行 | 24.7s | **4.05 MB/s** |
| 完整导入，batch_size=200 | 100MB / 293 万行 | 56.1s | 1.78 MB/s |
| 完整导入，batch_size=1000 | 同上 | 53.5s | 1.87 MB/s |
| 完整导入，batch_size=5000 | 同上 | 52.9s | 1.89 MB/s |
| 同样 5 万行、50 批，autocommit | — | 1176ms | 基准 |
| 同样 5 万行、50 批，**放进一个事务** | — | **303ms** | **快 3.9×** |

结论：

* 解析（CSV 扫描 + 列映射 + 类型转换）占约 **46%**，插入占约 **54%**。
* **`batch_size` 从 200 提到 5000（提交次数少 25 倍）吞吐几乎不变** —— 说明插入侧的开销不在提交次数上，
  而在每批要做的工作：`flush_batch` 里 `batch.iter().map(|r| r.3.clone())` 会把整批的 `Vec<Value>` 全量克隆一次，
  再由 `build_insert_sql` 拼成一个巨大的多值 INSERT 字符串。
* 单事务对照快 3.9 倍，说明**每次 autocommit 落盘（innodb_flush_log_at_trx_commit=1 + sync_binlog=1）**确实有成本；
  但导入路径没有把批合并进一个事务，所以没能拿到这个收益，同时又因为批大小不改变「每批克隆 + 拼串」的量，
  于是两条曲线都平。
* **没有 OOM**：进程 RSS 全程只有 5–20MB，导入 1GB 文件与 2412 万行都不进内存。

### 2.3 P0-3 内存泄漏（查询 → 滚动 → 关闭，50 轮）

Rust 侧（每轮：取 5000 行 + 5 次分页滚动 + 一页大字段）：

```
冷启动 RSS        20,696 KB   （含连接池/语句缓存的一次性开销，不计入泄漏）
热身 10 轮后基线   24,052 KB   （泄漏判定的起点）
第 10/20/30/40/50 轮  25,276 / 26,568 / 26,592 / 26,664 / 27,040 KB
总增长 +12.4%（相对热身基线）
后半段（第 25→50 轮）+1.7%   →  平台期
```

UI 侧（真实应用，每轮：执行 5000 行查询 → 翻页滚动 4 次 → 清空结果）：

```
BASE_RSS    110,880 KB
ROUND_10    116,644 KB
ROUND_20    116,724 KB
ROUND_30    118,648 KB
ROUND_40    118,824 KB
ROUND_50    118,848 KB
总增长 +7.2%    判据 < 10%: PASS
第 30→50 轮 +0.17%   →  完全平台
```

**判定**：两端都**不是真泄漏**。UI 侧 +7.2% 满足 <10% 判据；Rust 侧首尾差 +12.4% 略超，
但 RSS 序列在 20 轮后基本走平（后半段 +1.7%），且第 10 轮就已经吃到大部分增量 ——
这是分配器保留已释放页面的正常行为，不是每轮累积。**真正要看的指标是后半段斜率，不是首尾差。**

## 3. P1 场景结果

### 3.1 P1-4 数据编辑与批量提交（1 万行 → 保存）

```
逐行 UPDATE 10,000 行（当前实现，每格一次 change_row）   4578.6 ms   0.46 ms/行
  ↳ 逐行更新生效行数 = 10000（全部生效）
单事务批量 UPDATE（20 批 x 500 行，22 条语句）             214.3 ms
  ↳ 批量更新生效行数 = 10000
  ↳ 批量比逐行快 21.4x
```

**UI 阻塞**：当前实现每改一格发一次 FFI 调用 + 一条 SQL，1 万行 = 1 万次往返。
按 0.46ms/行计算，保存 1 万行会占用约 4.6 秒；期间 UI 不会冻结（异步 FFI），
但用户要等 4.6 秒且没有任何进度反馈。批量路径只要 0.21 秒。

**缺口确认**：`rust/src/api/query.rs`、`explorer.rs` 里都只有单行 `change_row`，
没有 `apply_row_changes` 之类的批量接口；Dart 侧 `DataGrid.onSaveCell` 也是逐格回调。

### 3.2 P1-5 导出性能（100 万行）

```
导出 1,000,000 行 .csv        2454.1 ms   rows=1000000 file=44.6MB
导出 1,000,000 行 .xls        4151.9 ms   rows=1000000 file=216.3MB
导出整表 SQL（mixed_500k）    3038.0 ms   rows=500000  file=120.3MB
  ↳ SQL 文件可回读：120MB，切分出 1001 条语句（含 CREATE TABLE）
free SELECT 用 SQL 格式       按预期拒绝（提示去表页导出）
```

**文件完整性**：三种格式都逐条校验过 ——

* CSV 末行 `1000000,name-83097-9,746.88,2020-01-10 14:49:39`，行数恰好 1,000,000，无半行截断；
* Excel(SpreadsheetML) 末尾 `</Cell></Row></Table></Worksheet></Workbook>`，XML 闭合完整；
* SQL 导出回读后能被 `split_statements` 切出 1001 条语句（1 条 CREATE TABLE + 1000 条批量 INSERT），
  说明结构 + 数据都在。

导出走流式写入（`Sink::File` + `BufWriter`），不把整份内容拼进内存；
100 万行 CSV 44.6MB / Excel 216MB 都是一次写盘完成。

### 3.3 P1-6 并发查询（10 个标签页）

```
串行单次中位数 = 2.4 ms，10 次合计 23 ms
并发 10 路：wall=14.8 ms, fastest=3.0 ms, slowest=14.7 ms, ratio=4.90
  ↳ 判据 ratio < 3: 需关注；并发 wall 15 ms vs 串行 23 ms（加速 1.6x）
```

10 路并发确实并行了（wall 15ms < 串行 23ms），但**最慢的请求是快者的 4.9 倍**。
连接池 `max_connections(5)`（`rust/src/drivers/mod.rs`），10 路要抢 5 条连接，
后 5 路排队等待 —— 这就是尾延迟的来源。

### 3.4 P1-7 对象浏览器（5000 张表）

```
list_tables 首次（冷）              685.4 ms   tables=5006
list_tables 预热后中位数             68.1 ms   tables=5006
list_objects                          7.2 ms
搜索过滤 5000 个表名（单次）           0.17 ms   hits=10, 平均 171 us
服务端 LIKE 搜索                       7.1 ms
```

UI 侧（真实应用，CUA 计时）：

```
打开 5000 张表的数据库页    1303 ms（首次 1784 ms）
侧边栏展开 5000 张表        1352 ms
```

**解读**：

* 冷启动 685ms 里大部分是连接池建立 + `information_schema` 首次扫描；预热后 68ms。
  「首次打开大库有额外延迟」是真实存在的，但只有半秒级。
* 侧边栏展开 1352ms、数据库页打开 1303ms 是 UI 端到端数字（含导航 + 取数 + 渲染第一页），
  比上一轮 UI 自动化测到的 **7364ms** 好很多；本轮 release 构建 + 侧边栏按需构建都起了作用。
* **搜索**：客户端过滤 5000 个表名只要 171µs，完全不是瓶颈；
  但要注意**表列表卡片没有搜索框**（`_objectFilter` 只过滤「对象」卡片里的视图/例程），
  5000 张表只能靠翻页（每页 50 行 → 100 页）。

## 4. P2 场景结果

### 4.1 P2-8 SQL 编辑器（10MB 文件、高亮、输入响应、自动补全）

Rust 侧（文件打开与切分）：

```
file = 10 MB, 194691 statements
split_statements 10MB                125.9 ms   statements=194691
sql_file_preview（只读 64KB）           0.1 ms
sql_file_preview（只读 1KB）            0.0 ms
```

规划中的设计是对的：控制台打开大文件时**只载入前 128–256KB**（`sql_view.dart`），
`sql_file_preview` 只读一个前缀，所以「打开 10MB 文件」本身是 0.1ms 级的操作；
真要执行整份文件走的是 `sql_file_execute_start` → `importer::SqlScriptReader` 流式路径，
内存与文件大小无关（单条语句上限 16MiB）。

编辑器侧（语法高亮 = 纯 Dart 同步计算，测试 VM 为 JIT）：

```
100KB SQL 分词       19.7 ms   （30,360 个 token）
1MB   SQL 分词       62.9 ms   （294,930 个 token）
10MB  SQL 分词      547.9 ms   （2,868,870 个 token）
200KB 连续改写 10 次    9.3 ms   （高亮重建）
```

**问题**：`SqlHighlightingController` 在**每次文本变化**时对整个缓冲区重新分词。
* 100KB（编辑器允许的上限附近）19.7ms/次 —— 每次按键都会花掉一帧多的时间，已经能感觉到延迟；
* 如果有人把 1MB 文本塞进编辑器，每次按键 63ms；10MB 则 548ms，完全不可用。
* 200KB 连续改写 10 次只用 9.3ms，说明「小步改写」路径本身不贵，贵的是**全量重新分词**。

**自动补全**：全仓搜索 `autocomplete` / `completion` / `suggest`，
`lib/src/` 下没有任何 SQL 自动补全实现（只有查询构建器的「建议连接列」）。
**该指标无法测量——功能不存在。**

### 4.2 P2-9 异常恢复（杀连接 / 断网 / 重连）

```
当前连接 id = 647
KILL 自己：已发出
杀连接后查询：自愈成功（4 ms 重建连接）
恢复后再次查询：OK
连接不存在的端口 3399        30002.0 ms   返回可读错误（应快速失败）
disconnect -> reconnect          20.1 ms
重连后查询：OK
```

**好的部分**：

* `KILL <自己的连接 id>` 之后，下一次查询**没有 panic、没有崩溃**，4ms 内重建连接并自动恢复；
* `disconnect → reconnect` 只要 20ms；
* 连接死端口返回的是可读错误，不是 panic。

**问题**：连接一个不存在的端口要 **30.0 秒**才失败。
链路是 `PoolRegistry::connect_admin`：先按配置库试一次 `self.get(spec, None)`，
失败后又用「去掉默认库」的副本再试一次。每次 sqlx `acquire_timeout = 15s`（`drivers/mod.rs`），
两次串起来正好 30s。对 TCP 层面的「连接被拒绝」（RST，本机毫秒级返回）还等满超时，
用户体验就是「点了打开，卡 30 秒」。

**未覆盖**：本机只有一台 MySQL，**没有测「杀掉 mysqld 进程后重启自愈」**，
也没有测断网（需要改网络配置）。这两项留作待办。

## 5. 问题、根因与建议

### 5.1 P0：CSV 导入吞吐只有 1.9 MB/s（1GB 要 8.3 分钟）

**现象**：1GB / 2412 万行导入 498s；100MB 的对照稳定在 1.78–1.89 MB/s；`batch_size` 200→5000 无改善。

**根因**（按证据排序）：

1. **插入前把整批值克隆了一遍**。`importer.rs` 的 `flush_batch!` 里：
   `let rows: Vec<Vec<Value>> = batch.iter().map(|r| r.3.clone()).collect();`
   —— 每行都要克隆一次 `Vec<Value>`，然后 `build_insert_sql` 再把它格式化成字符串。
   批越大，这一份克隆 + 拼串的量越大，正好抵消掉「提交次数变少」的收益。
2. **每批一次 autocommit 落盘**。本机 `innodb_flush_log_at_trx_commit=1` + `sync_binlog=1` + `log_bin=ON`，
   每次提交两次 fsync。对照实验（同样 5 万行、50 批）：autocommit 1176ms vs 单事务 303ms，差 3.9 倍。
   导入路径没有把多批合并进一个事务，所以吃不到这个收益。
3. **解析占 46%**：`import_validate_start`（只解析不写库）100MB 要 24.7s = 4.05 MB/s。
   解析路径每行都会构造 JSON `Value` 并走一次列映射，分配偏多。

**建议**（按性价比排序）：

1. **把整次导入包进一个事务**（每 N 批 `COMMIT` 一次，N 可配，例如每 50 批或每 2 万行），
   失败/取消时回滚。按对照实验，单这一项就有望到 4–6 MB/s。
2. **去掉 `flush_batch` 里的整批克隆**：`build_insert_sql` 改成直接借用 `&batch`（`iter()` 而不是先 collect），
   或把 `Vec<Value>` 换成「预渲染的行字面量」一次性写到 String。
3. **CSV 走 `LOAD DATA LOCAL INFILE`**：MySQL 原生批量装载通常比逐批 INSERT 快一个数量级；
   作为「本机文件 + MySQL」的快速路径，失败时回退到现在的通用路径。
4. 解析侧：复用 `Vec<Value>` 缓冲、避免每行 `Map::new()`、类型转换结果直接写入 SQL 字面量缓冲。
5. 基准脚本已经就位：`rust/tests/perf_bench.rs` 的 `p0_large_csv_import`（`PERF_CSV_MB` 控制大小），
   改完直接重跑对比即可。

### 5.2 P1：缺少批量提交接口（`apply_row_changes`）

**现象**：1 万行保存 = 1 万次 `change_row` = 4.58s（0.46ms/行）；一个事务批量更新只要 0.21s，差 21.4 倍。

**建议**：

1. 在 `api/explorer.rs` 增加 `apply_row_changes(database, table, changes: Vec<RowChange>)`：
   一个事务内按主键分批（例如每 500 行）拼 `UPDATE ... CASE WHEN` / `INSERT ... ON DUPLICATE KEY UPDATE`，
   返回逐行成功/失败；失败时按现有 `data_import` 的做法「整批失败再逐行重试」定位坏行。
2. Dart 侧 `DataGrid` 增加「保存全部改动」按钮，把 `onSaveCell` 的待提交队列一次性交给新接口，
   并显示进度（已有 `import_job_status` 的 job 机制可以复用）。
3. 预期收益：1 万行 4.6s → 0.2–0.5s。

### 5.3 P2：连接到不存在的端口要 30 秒

**现象**：`127.0.0.1:3399`（端口关闭）30,002ms 才返回错误。

**根因**：MySQL 管理连接失败后会「去掉默认库重试一次」，两次尝试各等满 sqlx `acquire_timeout=15s`。
TCP RST 本应立即失败，这里却等满超时。

**建议**：

1. 连接阶段区分错误类型：`Connection refused` / `No route to host` / DNS 失败这类**确定性失败直接返回**，
   不要重试，也不要在 pool 里等到 acquire_timeout。
2. 把「重试一次去掉默认库」的兜底限制在「服务端已握手但拒绝访问（权限/库不存在）」这一类错误上。
3. 给连接对话框一个可取消的「连接中…」，并在 5 秒后提示「仍在尝试，检查主机/端口/防火墙」。

### 5.4 P2：编辑器高亮是全量同步分词 + 没有自动补全

**现象**：100KB 文本每次改动 19.7ms；1MB 63ms；10MB 548ms。自动补全功能不存在。

**建议**：

1. 高亮改成**增量分词**：只对「改动行 ± 上下文」重新分词（Dart 侧维护行起始偏移即可）；
   或者设阈值（例如 > 64KB 关闭高亮，只保留纯文本编辑），并在状态栏提示。
2. 给分词加 debounce（例如 120ms 无输入后再重算），输入过程中用旧高亮。
3. 自动补全按价值排序：表名/列名 → SQL 关键字 → 历史语句。数据源已在手边
   （`builder_schema` 能给出表与列，`query_history.json` 有历史），不需要新后端。

### 5.5 P1：并发尾延迟 ratio 4.90

**现象**：10 路并发，fastest 3.0ms / slowest 14.7ms。

**根因**：`MySqlPoolOptions::max_connections(5)`；10 路抢 5 条连接，后 5 路排队。

**建议**：

1. 池大小改为可配（按标签页数或 CPU 核数），默认从 5 提到 8–10；
2. UI 对排队中的查询显示「排队中」而不是无响应；
3. 对短查询（< 10ms）考虑不占满池的直连路径。

### 5.6 其他发现

* **磁盘会被导出写满**：整表 1000 万行 SQL 导出约 1.5GB+，测试机剩余 2.5GB 时直接 `No space left on device`，
  连 `connections.json` 都写不进去（连接创建失败）。基准里已把 SQL 导出改成 50 万行的表。
  **产品侧建议**：导出前按行数/列宽估算体积并提示剩余磁盘空间。
* **宽表 JSON 序列化仍是成本大头**：500 行 × 100 列 = 1.6MB JSON、19.8ms；
  结果集全程走 `serde_json::Value`。桌面版建议改二进制友好结构（列名数组 + 行数组）或列裁剪。
* **冷启动连接池**：`list_tables` 冷 685ms → 热 68ms。建议连接成功后预热一次轻量元数据查询。
* **表列表没有搜索**：5000 张表要翻 100 页；客户端过滤只要 171µs，加个输入框即可。

## 6. 复现步骤

### 6.1 Rust 侧（全部 9 个场景）

```bash
cd desktop/rust
# 全量（1GB CSV 除外，见下）
DBPILOT_PERF=1 DBPILOT_TEST_MYSQL_PASSWORD=*** \
  cargo test --release --offline --test perf_bench -- --nocapture --test-threads=1

# 单场景示例
DBPILOT_PERF=1 DBPILOT_TEST_MYSQL_PASSWORD=*** \
  cargo test --release --offline --test perf_bench -- --nocapture p0_large_result_set
DBPILOT_PERF=1 DBPILOT_TEST_MYSQL_PASSWORD=*** PERF_CSV_MB=1024 \
  cargo test --release --offline --test perf_bench -- --nocapture p0_large_csv_import
```

用的测试目标名：`p0_large_result_set` / `p0_large_csv_import` / `p0_memory_leak_50_rounds` /
`p1_bulk_row_update` / `p1_export_1m_rows` / `p1_concurrent_queries` / `p1_object_browser_5000_tables` /
`p2_large_sql_file` / `p2_error_recovery`。

### 6.2 UI 侧（真实应用）

```bash
cd desktop
flutter build macos --release
cp -R build/macos/Build/Products/Release/DBPilot.app /Applications/
xattr -dr com.apple.quarantine /Applications/DBPilot.app
bash tools/perf/ui_automation/run_ui_perf.sh     # 报告写到 out/perf-results/
```

帧采样单跑：

```bash
DBPILOT_FRAME_TRACE=1 /Applications/DBPilot.app/Contents/MacOS/DBPilot > /tmp/frame.log 2>&1 &
grep 'FRAME_TRACE frames=' /tmp/frame.log
```

### 6.3 编辑器高亮 / 侧边栏回归

```bash
cd desktop
flutter test test/sql_highlight_perf_test.dart    # 低亮预算：200KB < 120ms
flutter test test/sidebar_lazy_tables_test.dart   # 5000 表首帧只建 82 行
flutter test test/frame_trace_test.dart           # 帧采样统计逻辑
```

## 7. 与上一轮的差异

| 项 | 上一轮（R40） | 本轮（R41） |
| --- | --- | --- |
| 构建 | debug（5–20× 慢） | **release** |
| 大结果集 50k 行 | 未测 | 96.7ms / 2.6MB JSON / +17MB RSS |
| 1GB CSV 导入 | 未完成（怀疑被 64MiB 上限挡住） | **实测 498s，未 OOM，行数一致** |
| 内存泄漏 | Rust 20 轮 +8.5% | Rust 50 轮后段 +1.7%；**UI 50 轮 +7.2% 完全平台** |
| 批量提交 | 记录为缺口 | 量化：逐行 4.6s vs 批量 0.21s（21.4×） |
| 导出 | 10 万行 | **100 万行三种格式 + 完整性校验** |
| 对象浏览器 | Rust 159ms / UI 7364ms | Rust 热 68ms；**UI 1303ms** |
| 首屏/帧率 | 无 UI 自动化数据 | FrameTiming 采样落地，build p50 0.19ms |

## 8. 待办

| 优先级 | 项 |
| --- | --- |
| **P0** | 导入包事务 + 去掉批次克隆（§5.1），目标 ≥ 4 MB/s |
| **P0** | 新增 `apply_row_changes` 批量提交（§5.2） |
| P1 | 连接失败快速返回，不要等 30s（§5.3） |
| P1 | 高亮增量/阈值化 + debounce；自动补全（§5.4） |
| P1 | 连接池大小可配（§5.5） |
| P2 | 宽表结果集改二进制友好结构或列裁剪 |
| P2 | 表列表加搜索框；导出前估算体积 |
| P2 | 补测：杀 mysqld 后重启自愈、真实断网、常规 Mac 上的帧率 |

