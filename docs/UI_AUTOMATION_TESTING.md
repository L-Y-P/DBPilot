# DBPilot UI 层自动化测试（CUA + AppleScript + FrameTiming）

> 承接 [性能测试报告](PERFORMANCE_TESTING.md)。那份文档的 P0/P1 场景里，凡是需要**真实界面交互**的
> 指标（首屏渲染、滚动、UI 阻塞、输入响应）都只能在 UI 层测。
>
> 本文记录当前选型：**CUA（macOS Accessibility）+ AppleScript（键盘/剪贴板输入）+ 应用内
> FrameTiming 采样**，以及实测数据与踩过的坑。仓库里不存在其它 UI 测试框架的残留设施。

## 0. 结论速览

| 能力 | 方案 | 状态 |
| --- | --- | --- |
| 启动应用、读控件树、点击 | CUA `launch_app` / `get_window_state` / `click` | ✅ 可用 |
| 读取完整 AX 树（含深层文本） | CUA `get_window_state` | ✅ 可用（AppleScript 只能看到 5 层） |
| 往 Flutter 自绘输入框写文本 | AppleScript 剪贴板粘贴 | ✅ 可用（`keystroke` 会被输入法污染） |
| 备用文本注入通道 | 应用内 `RMA_CU_INPUT=1` 回环 HTTP 桥 | ✅ 可用（仅调试，默认关闭） |
| 执行按钮点击 | CUA `click`（回退像素坐标） | ⚠️ 部分按钮 AXPress 无效 |
| 采集进程 RSS / 查询耗时 | shell `ps` + 时间戳 | ✅ 可用 |
| 帧耗时 / 滚动流畅度 | 应用内 FrameTiming 采样（`DBPILOT_FRAME_TRACE=1`） | ✅ 已实现，数字待采集 |

**一句话**：点击和读状态交给 CUA，输入交给剪贴板粘贴，帧率交给应用自己报。

## 1. 测试环境

| 项 | 值 |
| --- | --- |
| 机器 | macOS 15.8.1，x86_64 |
| 应用 | DBPilot 1.0.0 release（`/Applications/DBPilot.app`） |
| 数据库 | MySQL 8.4.11，`dbpilot_perf` 数据集（5 套，见[性能测试报告 §2](PERFORMANCE_TESTING.md#2-测试数据)） |
| 权限 | 终端/IDE 已获「辅助功能」授权（CUA 与 System Events 都依赖它） |
| Flutter | 3.47.7 stable / Dart 3.13.5 |

## 2. 为什么是这三件套

| 需求 | 为什么不用别的 |
| --- | --- |
| 点按钮、读界面状态 | Xcode 的 UI 测试需要交互式 automation session，本机起不来；CUA 直接走 AXUIElement，不需要 |
| 输入 SQL | 逐字符 `keystroke` 会被输入法污染（见 §4.4），剪贴板粘贴是唯一稳定路径 |
| 帧耗时 | AX 树里没有帧信息，任何外部工具都测不到；只能由应用内 `SchedulerBinding.addTimingsCallback` 自己报 |

三者互补，没有重叠：CUA 管「看得见的东西」，AppleScript 管「输入」，FrameTiming 管「快不快」。

## 3. 实测数据（release 应用，CUA 计时）

> 本轮所有 UI 数字都在 `flutter build macos --release` 的产物上采集，
> 由 CUA（Accessibility）驱动并计时，应用带 `DBPILOT_FRAME_TRACE=1` 启动。

### 3.1 连接建立

```
点「打开」→ 侧边栏出现「N 张表」
  CUA 计时：1285 ms
```

### 3.2 5000 张表的库（展开 + 打开 + 搜索）

```
打开 5000 张表的数据库页（出现「5005 张表」）   1303 ms（首次 1784 ms）
侧边栏展开 5000 张表（出现 t_0001）            1352 ms
```

对照上一轮（同一台机器、debug 时代安装的旧构建）：**7364 ms → 1303 ms**。
差距来自三处：release 构建、侧边栏按需构建（见[性能测试报告 §3.4](PERFORMANCE_TESTING.md)）、
以及数据库页本身的 50 行/页分页 + GridTable 虚拟化（这两项此前就存在）。

Rust 侧同库 `list_tables` 是 68ms（预热）/ 685ms（冷），UI 的 1.3s 里含导航、取数、渲染第一页。

**搜索响应**：

```
客户端过滤 5000 个表名（纯 Dart）      0.17 ms / 次
服务端 information_schema LIKE 查询   7.1 ms
```

过滤本身极快，但 **表列表卡片没有搜索框**（`_objectFilter` 只作用于「对象」卡片的视图/例程），
5000 张表只能按 50 行/页翻 100 页 —— 见性能报告 §5.6。

### 3.3 大结果集查询（UI 端到端）

```
SELECT * FROM narrow_10m LIMIT 5000    1389 / 1448 / 1446 ms （3 轮）
SELECT * FROM narrow_10m LIMIT 50000           1431 ms
表格分页：显示 50 / N 行（kDbTablePageSize=50）
```

这 ~1.4s 是「点执行 → 首屏 50 行出现」的完整链路（FFI + 后端查询 + JSON 反序列化 + 首帧渲染），
其中 Rust 侧查询本身只要 2.5ms（5000 行）/ 96.7ms（50000 行，见性能报告 §2.1）。

### 3.4 内存（UI 侧，50 轮）

每轮：执行 5000 行查询 → 翻页滚动 4 次 → 清空结果。

```
BASE_RSS    110880 KB
ROUND_10    116644 KB
ROUND_20    116724 KB
ROUND_30    118648 KB
ROUND_40    118824 KB
ROUND_50    118848 KB
总增长 +7.2%    判据 < 10%: PASS
第 30→50 轮 +0.17%  →  完全平台（无泄漏）
```

### 3.5 帧耗时（应用内 FrameTiming，已采到真实数字）

```
空闲/交互窗口：  build(ms) p50=0.19 p95=0.70  max=15.01
                raster(ms) p50=17.83 p95=19.94 max=46.00
                total(ms)  p50=33.78 p95=43.77 max=72.17
滚动突发：      60 帧 / 1347ms（≈44 fps）、52 帧 / 2801ms（≈18.5 fps）
jank 率（total > 16.67ms）：100%
```

**怎么解读**：

* **build p50 只有 0.19–0.67ms** —— 应用自身（Dart 布局 + 绘制指令）完全不是瓶颈，
  这直接印证了侧边栏按需构建 / 表格分页 / 虚拟化的效果。
* **瓶颈是 raster（GPU 合成）p50 17–22ms**，单这一项就超出 60fps 的 16.67ms 预算。
* **但这个数字受本机环境限制**：本机是 Hackintosh（AMD Ryzen + NVIDIA RTX 5060，
  macOS 下 NVIDIA 没有官方驱动）。证据是一个只采到 **2 帧**的空闲窗口 raster 也有 28.3ms，
  所有窗口的 raster p50 稳定落在 17–22ms —— 与内容无关的固定底噪。
  **常规 Mac 上必须复测**，不能把这个数字当成应用缺陷。
* Flutter 是**按需渲染**：空闲时不出帧（一个 63 秒窗口只有 22 帧），
  所以「平均帧率」在空闲场景没有意义，要看**交互突发期间**的帧间隔。

## 4. 踩过的坑（重要，避免重复）

### 4.1 AppleScript 看不到深层控件

Flutter 的 AX 树对 System Events 只暴露 **5 层**：

```applescript
-- 只能拿到 5 个元素
tell process "DBPilot" to count UI elements of window 1   -- => 5
-- 再往下一层就只剩 1 个 AXGroup
```

**结论**：读文本用 **CUA**（它能拿到 157 个元素），不要指望 AppleScript 遍历。

### 4.2 `load script` 在 /tmp 上失效

本机 `/tmp` 是指向 `/private/tmp` 的符号链接：

```
osascript -e 'set L to load script (POSIX file "/tmp/lib.scpt")'
→ error -1752: 脚本看起来不属于AppleScript
```

**结论**：把库文件与调用**内联拼成一个脚本**再执行（`run_ui_perf.sh` 里的 `osa()` 函数就是这么做的）。

### 4.3 AppleScript 保留字冲突

`on screenPoint(winOrigin, offset)` 里的 `offset` 是 AppleScript 保留字，编译直接报
`Expected expression but found command name (-2741)`。改名或去掉即可。

### 4.4 Flutter 输入框收不到 keystroke

```applescript
keystroke "SELECT * FROM narrow_10m LIMIT 5000"
-- 实际写入：SELECT* FROM narrow啊0吗LIMIT5000
--            ↑ 空格丢失      ↑ 输入法插入了中文
```

**结论**：用**剪贴板粘贴**（`set the clipboard` + `keystroke "v" using command down`），
这是最可靠的方式。需要更稳的注入时，可开应用内的 `RMA_CU_INPUT=1` 桥
（`desktop/lib/src/cu_input.dart`，仅监听 `127.0.0.1:47823`，默认关闭）：
点一下输入框 → `POST /text`，文本直接进 `TextEditingController`，完全绕开键盘。

### 4.5 Flutter 按钮的 AXPress 常常无效

```
click button "执行"  → AXUIElementPerformAction(AXPress) returned -25206
```

`-25206` = `kAXErrorActionUnsupported`。Flutter 自绘控件只暴露部分 AX action。
**结论**：优先用 CUA 的 `click`（它会回退到像素点击），或用坐标点击。

### 4.6 CUA 的截图坐标系 ≠ 窗口坐标系

截图显示 1024×628，但 `window_bounds` 是 1300×794。按截图坐标点会偏。
**结论**：用 AX `frame`（窗口内坐标）+ 窗口原点换算，不要用截图像素。

## 5. 帧耗时采样（已实现）

```
desktop/lib/src/frame_trace.dart     采样与统计（纯逻辑可单测）
desktop/lib/main.dart                首帧前 FrameTrace.instance.maybeStart()
desktop/test/frame_trace_test.dart   15 个单测（本轮重跑全绿）
```

启用：

```bash
DBPILOT_FRAME_TRACE=1 open -a DBPilot          # 或
cd desktop && DBPILOT_FRAME_TRACE=1 ../.flutter-sdk/bin/flutter run -d macos
```

输出（每 60 帧或每 2 秒一行，毫秒；p50/p95 用最近秩法，jank 判据 `total > 16.67ms`）：

```
FRAME_TRACE enabled (DBPILOT_FRAME_TRACE=1): flush every 60 frames or 2000ms; jank > 16.67ms
FRAME_TRACE frames=60 jank=3(5.0%) window=2016ms | build(ms) p50=0.42 p95=1.85 max=7.31 | raster(ms) p50=0.90 p95=3.20 max=9.44 | total(ms) p50=1.40 p95=5.20 max=16.90
```

（上面是格式示例，不是本机实测数据。）

采集流程：

```bash
# 1) 开采样启动应用，日志重定向到文件
DBPILOT_FRAME_TRACE=1 /Applications/DBPilot.app/Contents/MacOS/DBPilot > /tmp/frame.log 2>&1 &

# 2) 用 CUA 驱动一次「展开 5000 表库 / 滚动结果集 / 切 tab」

# 3) 从日志里取统计行
grep '^FRAME_TRACE' /tmp/frame.log
```

> 关闭时**不注册任何回调**，正常用户零开销；用环境变量而不是设置项，是因为它只服务于
> 自动化/排查，且必须在首帧之前生效。

## 6. 工具与脚本

| 文件 | 作用 |
| --- | --- |
| `desktop/tools/perf/ui_automation/lib.applescript` | AppleScript 基础库：激活应用、点按钮、读文本、写 SQL、读 PID/RSS（配合 CUA 用：遍历交给 CUA，输入交给它） |
| `desktop/tools/perf/ui_automation/run_ui_perf.sh` | 采集驱动：连接 → 展开 → 查询循环 → 内存，输出报告到 `out/perf-results/` |
| `desktop/lib/src/frame_trace.dart` | 应用内帧耗时采样（§5） |
| `desktop/lib/src/cu_input.dart` | 备用文本注入桥（`RMA_CU_INPUT=1`，仅调试） |

运行：

```bash
MYSQL_PASSWORD=123456 bash desktop/tools/perf/ui_automation/run_ui_perf.sh
```

输出示例（`out/perf-results/ui-perf-<stamp>.txt`）：

```
== DBPilot UI 性能采集  20261024-023008 ==
app pid = 55191
启动后 RSS = 164840 KB
-- 3) 查询循环（5 轮）--
  round 1: 2222 ms, RSS = 168616 KB
  ...
-- 4) 内存 --
RSS: 164840 KB -> 172680 KB，增长 4.8%
判据 < 10%: PASS
```

## 7. 问题与建议

### ✅ 已解决：侧边栏 5000 表展开 7.4s

根因是侧边栏全量构建（不是表格虚拟化）。已改为 `ListView.builder` + 惰性节点构建器
（`desktop/lib/src/shell.dart`，回归测试 `desktop/test/sidebar_lazy_tables_test.dart`）。
本轮 release 实测：**打开 5000 表数据库页 1303ms**（旧构建 7364ms）。

### ✅ 已解决：帧耗时有了真实数字

`desktop/lib/src/frame_trace.dart` 落地并采到真实数据（§3.5）：
build p50 0.19ms（应用自身很轻）、raster p50 17.8ms（**本机 Hackintosh GPU 限制，需在常规 Mac 复测**）。

### ⚠️ 新发现：raster 数字必须在正常硬件上复测

本机是 Hackintosh（NVIDIA 在 macOS 无官方驱动），空窗口 2 帧时 raster 也是 28ms。
**在拿这个数字下结论前，必须在一台原生 Mac 上重跑 §3.5 的采集。**

### P1：关键按钮缺 Semantics label

部分 Flutter 按钮 AXPress 无效（§4.5），自动化只能退回像素坐标，窗口尺寸一变就失效。
建议给关键按钮补 `Semantics(button: true, label: ...)`，自动化会稳定很多。

### P1：采集脚本还要补「首屏时间」与「排序/翻页响应」

`run_ui_perf.sh` 现在采：连接、打开库页、侧边栏展开、查询循环、RSS、帧统计。
首屏渲染时间需要「启动 → 首帧」打点，建议加 `DBPILOT_FIRST_FRAME` 环境变量输出；
另外表格排序、翻页、切换 tab 的响应也值得纳入。

### P2：采集未进 CI

`build.yml` 的 macOS job 已能出包，但没跑 UI 采集。接进去（跑 `run_ui_perf.sh` + 上传报告）
就能对每个 PR 做 UI 性能回归；注意 runner 需要辅助功能授权，可能得用 self-hosted。

### P2-5 采集未进 CI

`build.yml` 的 macOS job 已经能出包，但没跑 UI 采集。接进去（跑 `run_ui_perf.sh`
+ 上传报告 artifact）就能对每个 PR 做 UI 性能回归；注意需要辅助功能授权的 runner。

### P2-6 AppleScript 库是内联拼接，难复用

`osa()` 每次把整个库拼进临时脚本，脚本一长就难维护。可考虑用 CUA 的 `click` /
`get_window_state` 替代大部分 AppleScript 动作，只保留剪贴板写入。

## 8. 与 Rust 基准的分工

| 指标 | 用哪个 |
| --- | --- |
| 数据库往返、SQL 执行、导出耗时 | Rust 基准（`desktop/rust/tests/perf_bench.rs`） |
| JSON 序列化、结果集构造 | Rust 基准 |
| 首屏渲染、Widget 构建、滚动 | **UI 层（本文）** |
| 端到端「点一下到看见结果」 | **UI 层（本文）** |
| 帧耗时 / jank | **应用内 FrameTiming（§5）** |
| 内存（进程级） | 两者都能测，UI 侧更真实 |

## 9. 复现步骤

```bash
# 1) 数据集（幂等；生成的是 SQL 文件，再由 mysql 客户端导入）
cd desktop && bash tools/perf/gen_datasets.sh
for f in out/perf-datasets/0*.sql; do
  mysql -h127.0.0.1 -uroot -p dbpilot_perf < "$f"     # 约 2.5 分钟
done

# 2) release 应用并安装
flutter build macos --release
cp -R build/macos/Build/Products/Release/DBPilot.app /Applications/
xattr -dr com.apple.quarantine /Applications/DBPilot.app

# 3) 授权「辅助功能」给终端（系统设置 → 隐私与安全性 → 辅助功能）

# 4) 采集 UI 指标（连接 / 打开 5000 表库 / 查询循环 / RSS / 帧统计）
bash tools/perf/ui_automation/run_ui_perf.sh        # 报告写到 out/perf-results/
```

脚本会自动带 `DBPILOT_FRAME_TRACE=1` 启动应用，所以帧统计和 UI 计时是同一次采集拿到的；
需要手工采帧时：

```bash
DBPILOT_FRAME_TRACE=1 /Applications/DBPilot.app/Contents/MacOS/DBPilot > /tmp/frame.log 2>&1 &
# ... 用 CUA 驱动滚动/展开 ...
grep 'FRAME_TRACE frames=' /tmp/frame.log
```

回归测试：

```bash
cd desktop
.flutter-sdk/bin/flutter test test/frame_trace_test.dart            # 帧统计逻辑（15 例）
.flutter-sdk/bin/flutter test test/sidebar_lazy_tables_test.dart   # 5000 表首帧只建 82 行
.flutter-sdk/bin/flutter test test/sql_highlight_perf_test.dart    # 200KB 高亮 < 120ms
```
