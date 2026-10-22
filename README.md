# DBPilot

**用 Flutter + Rust 写的跨平台数据库管理桌面客户端**，支持 MySQL / MariaDB、PostgreSQL、SQLite。
本地单机应用，进程内 FFI 调用，没有服务端和账号体系，连接信息与备份都留在自己机器上。

![DBPilot](docs/images/main-connections.png)

| | |
| --- | --- |
| 界面 | Flutter 3.47.7 / Dart 3.13（Material 3，中英双语，深浅色 + 6 套主题色） |
| 内核 | Rust 2021（sqlx 0.8 / tokio 1 / russh 0.45 / rustls） |
| 桥接 | flutter_rust_bridge 2.13（类型安全 FFI，无 HTTP、无本地端口） |
| 平台 | macOS（universal x86_64 + arm64）、Windows x64、Linux（GTK3） |
| 许可 | MIT，见 [LICENSE](LICENSE) |

---

## 技术栈

| 层 | 组件 | 说明 |
| --- | --- | --- |
| UI | **Flutter 3.47.7 / Dart 3.13** | Material 3；`window_manager` 管窗口、`file_picker` 管文件对话框、`path_provider` 管数据目录 |
| FFI | **flutter_rust_bridge 2.13** | 类型安全的进程内调用，不起 HTTP 服务、不开本地端口 |
| 契约层 | **dbpilot-core**（独立 crate） | `DatabaseDialect` / `DatabaseDriver` / `DriverRegistry` / `ConnectionHandle`，不依赖任何驱动实现 |
| 驱动 | **sqlx 0.8**（mysql / postgres / sqlite） | 三个内置驱动作为静态插件注册，方言 SQL 落在 `drivers/<id>/dialect.rs` |
| 运行时 | **tokio 1**（多线程） | 长任务（导入 / SQL 文件）`tokio::spawn` + 进度/取消 |
| 网络 | **russh 0.45** + **rustls** | SSH 本地端口转发（跳板机）、TLS / mTLS 证书校验 |
| 序列化 | serde / serde_json / chrono / uuid | 跨 FFI 数据统一是 JSON |

分层：

```text
Flutter UI（Dart）              lib/src/**：shell / views / components / builder
      │  flutter_rust_bridge 2.13（JSON 进出）
Rust api 层（唯一 FFI 表面）    rust/src/api/*
      │
Rust 编排层                     state.rs（授权边界）· pools.rs（连接池 LRU 5 + 隧道）
      │
契约层 dbpilot-core             trait / 方言 / 注册表 / DTO / SQL 工具
      │
驱动层                          drivers/{mysql,postgres,sqlite}
      │
引擎与持久化                    importer · exporters · ssh · secure（0600 原子写）
```

## 支持的数据库

| 数据库 | 实测版本 | 说明 |
| --- | --- | --- |
| MySQL | **8.4.11** | 也支持 MariaDB（同驱动、同方言） |
| PostgreSQL | **17.11** | 多 schema、实例级连接、`pg_stat_activity` / 角色管理 |
| SQLite | 文件 3.54 / 内置运行时 3.46 | 一个连接 = 一个目录（主文件 + 自动 ATTACH 同目录其它文件） |

标识符引号、布尔/二进制字面量、`EXPLAIN`、`USE` / `SET search_path`、系统库与权限过滤
都在各自驱动的 `dialect.rs` 里，UI 不感知方言差异。

## 功能

**连接管理** —— 多连接并列（颜色 / 分组 / 驱动徽标）；SSH 跳板（密码 / 私钥 / agent，主机密钥 TOFU 或严格校验）；
TLS / mTLS（`disable` / `require` / `verify-ca` / `verify-full` + 自定义 CA 与客户端证书）；
连接字符集、默认库、`only_db` / `hide_db` 可见性边界；测试连接、分阶段打开反馈（5 秒后可取消）。

**对象浏览** —— 库 / 模式 → 表、视图、存储过程 / 函数、触发器、事件，每页 50 条；
行数估算、大小、备注；权限不足的对象隐藏并提示数量；查看 DDL、清空、删除、新建。

![库与对象浏览](docs/images/db-objects.png)

**表设计器** —— 可视化 ALTER TABLE：表选项、字段、索引、外键，全部带 SQL 预览后再应用；独立 DDL 页签。

![表设计器](docs/images/table-design.png)

**数据网格** —— 列显示 / 隐藏、逐列筛选、多列排序、批量删除、单元格复制与展开、行内编辑；
keyset 游标分页；自动列宽开关与大字段延迟加载（设置 → 性能）。

![表浏览与数据网格](docs/images/table-browse.png)

**SQL 控制台** —— 语法高亮（>120 KiB 退化为纯文本）、执行 / EXPLAIN / 取消（`KILL QUERY` / `pg_cancel_backend`）、
结果每页 50 行、查询历史；导入 SQL 文件（小文件进编辑器，大文件流式执行）。

**查询构建器** —— 数据源树、输出字段 / 连接关系 / 筛选条件 / 排序四个工作区；聚合、去重、别名；
参数化 SQL 预览；多方言适配（FULL OUTER JOIN 原生或 UNION 改写、ILIKE、字面量转义）；跨库查询；
结果分页预览与导出，可保存为查询模块。

![查询构建器](docs/images/query-builder.png)

**数据导入向导** —— 四步：选文件 → 读取规则 → 字段映射 → 执行。
支持分隔文本 / JSON 数组 / JSON Lines / XML / HTML / Excel(SpreadsheetML) / Markdown / SQL 脚本；
自动识别格式；整文件校验报「第 N 行（第 X 条，字节 Y）：原因」；试插入（事务内 INSERT + 回读 + ROLLBACK）；
流式分批写入（64 KiB 分块、默认 500 行/批、可取消）；NULL 与空串在所有格式里可区分。

![数据导入向导](docs/images/import-wizard.png)

**导出** —— SQL / CSV / JSON / XML / HTML / TXT / Excel / Markdown 八种格式；
表页、整库、查询结果共用同一套 writer，全部流式写出。

**备份与恢复** —— 按库或按表备份成 .sql（带头部元信息），备份目录可切换，每页 20 条；恢复前确认并报告语句数。

**结构比对与同步** —— 同连接内任选源 / 目标库或模式，逐表比对字段、主键、索引、注释；只生成 DDL，可预览，
可选删除目标多余字段 / 索引（外键、触发器、函数不创建，界面明示）。

**服务器与账号** —— 状态 / 变量 / 进程 / 账号四个页签；MySQL 进程终止与权限矩阵，PostgreSQL
`pg_stat_activity` 与角色属性，SQLite 文件级信息（按驱动与权限显示）。

**界面** —— 中英双语（含 Rust 后端错误）；深浅色 + 6 套主题色；窗口尺寸记忆，最小 960×600。

<img src="docs/images/settings.png" width="420" alt="设置：语言 / 主题 / 性能 / 备份 / 检查更新">

## 性能

本机实测，同机前后对照（含约 14 ms 测试框架开销）：

| 场景 | 优化前 | 优化后 | 做法 |
| --- | --- | --- | --- |
| DataGrid 40 列 × 500 行首帧 | 2.40 s | **1.30 s** | 列宽缓存 + 列虚拟化 + 采样 200 → 50 行 |
| DataGrid 父级重建 | 734 ms | **157 ms** | 同上；单帧单元格 1200 → 390 |
| GridTable 600 行首帧 | 1297 ms | **137 ms** | 行虚拟化（>150 行走固定表头 + ListView.builder） |
| 构建器结果预览单帧单元格 | 943 | **207** | 按（结果身份, 页码）复用 widget + 列虚拟化 |
| 构建器结果预览翻页 | 301 ms | **118.9 ms** | 同上 |
| 查询构建器 tab 切换 | 37 ms | **13.7 ms** | ValueNotifier 局部重建 + IndexedStack 常驻 |

其它与数据处理相关的设计：

- **keyset 游标分页**替代 OFFSET（单列主键升序时走索引范围扫描），配合延迟关联；游标页不发 `COUNT(*)`。
- **大字段延迟加载**：超过 200 字符只渲染前 120 字符 + 徽标，双击看全文。
- **自动列宽可关闭**：关掉后所有列固定 160 px，完全不跑 `TextPainter` 测量。
- **导入流式**：64 KiB 分块、批量 INSERT 默认 500 行、可取消；单记录 8 MiB / 单语句 16 MiB 上限。
- **导出流式**：逐行写出，不把整表拼成一个大字符串。

## 使用

**获取**：从 [Releases](https://github.com/L-Y-P/DBPilot/releases) 下载压缩包，或按下一节自行编译。

| 平台 | 解压后 |
| --- | --- |
| macOS | `DBPilot.app`（universal）——ad-hoc 签名未公证，首次打开需右键 → 打开，或 `xattr -dr com.apple.quarantine DBPilot.app` |
| Windows x64 | `rust_myadmin_desktop.exe` + `rust_myadmin_core.dll` + `flutter_windows.dll` + `data/`——未签名，SmartScreen 选「仍要运行」 |

**第一次使用**：

1. 打开应用 → **新建连接**，选驱动填主机 / 端口 / 账号 / 密码 / 数据库；需要时在 **SSL** 页签配 TLS、
   在 **SSH** 页签配跳板机。
2. **测试连接** 通过后保存，回到连接管理点 **打开**。
3. 左侧树选库 / 模式 → 表；右侧表页有浏览 / 结构 / 设计 / DDL / 插入 / SQL / 导出 / 导入 / 操作九个页签。
4. 顶栏进 **查询构建器**、**SQL 控制台**、**服务器**、**工具**（备份 / 结构同步 / 历史），右上角齿轮打开设置。

**数据存放**（文件 0600、目录 0700）：

| 平台 | 目录 |
| --- | --- |
| macOS | `~/Library/Application Support/com.rustmyadmin.rustMyadminDesktop/` |
| Windows | `%APPDATA%\com.rustmyadmin\DBPilot\` |
| Linux | `~/.local/share/com.rustmyadmin.rust_myadmin_desktop/` |

包含 `connections.json`（含密码，明文 0600）、`settings.json`、`query_history.json`、`backups/`。
没有接系统钥匙串，介意的话请用只有该库权限的专用账号。

**检查更新**：设置 → 关于 → 检查更新，读取仓库根 `update.json`（地址编译在
`lib/src/update_source.dart`，界面不提供输入框）；发版流程见 [docs/RELEASE.md](docs/RELEASE.md)。

逐页操作见 [docs/USAGE.md](docs/USAGE.md)。

## 编译

**前置**

| 依赖 | 版本 |
| --- | --- |
| Flutter | **3.47.7**（stable，Dart 3.13.5） |
| Rust | stable（2021 edition，开发机实测 1.99.1） |
| macOS | Xcode 完整版 + CocoaPods；universal 包需 `aarch64-apple-darwin` 与 `x86_64-apple-darwin` |
| Windows | VS 2022「使用 C++ 的桌面开发」（MSVC 14.4x + Win SDK 10）+ `x86_64-pc-windows-msvc` |
| Linux | GTK3 开发库、CMake、Ninja、`pkg-config` |
| codegen | `cargo install flutter_rust_bridge_codegen --version 2.13.0`（只在改 Rust API 后需要） |

三个桌面平台不能交叉编译，各自在本平台构建。

**构建**

```bash
flutter pub get

flutter build macos   --release   # build/macos/Build/Products/Release/DBPilot.app
flutter build windows --release   # build/windows/x64/runner/Release/
flutter build linux   --release   # build/linux/x64/release/bundle/
```

Rust 部分由 cargokit 在 `flutter build` 内部自动触发，产物落在 `build/` 下，不复用 `rust/target`。

**改了 Rust API 之后**

`api/` 里新增或改签名的 `pub fn` 必须重新生成 Dart 绑定：

```bash
flutter_rust_bridge_codegen generate   # 配置见 flutter_rust_bridge.yaml
```

只改返回字段的组装不需要 codegen。

**测试**

```bash
dart analyze                                          # 应为 0 issue
cd rust && cargo test --offline -- --test-threads=1    # hermetic，不需要数据库
cd .. && flutter test                                  # 需先 cargo build --lib 生成 debug 动态库

make rust-live-up   # Docker 起 MySQL 8.4 + PostgreSQL 17
make rust-live      # hermetic + live 全套
make rust-live-down # 停库并删卷
```

live 套件的端点全部来自环境变量 `DBPILOT_TEST_MYSQL_*` / `DBPILOT_TEST_PG_*`，
仓库里不含任何账号密码；详见 [docs/CI_LIVE_TESTS.md](docs/CI_LIVE_TESTS.md)。

当前基线：`dart analyze` 0 issue、`flutter test` 380 passed + 11 skip、`cargo test` 183 passed / 17 ignored。

**常见构建坑**

- 不要用 `flutter build macos --release --no-pub`：SPM/CocoaPods 混合状态下会链接失败并清掉插件 framework。
- macOS 需要真实 `HOME` 与 `PUB_CACHE=~/.pub-cache`，受限沙箱里会卡在 SwiftPM 缓存权限。
- Windows 上 Flutter 的 CMake 会调 `rustup run stable cargo build`，`rustup` 必须在 PATH 上。
- 首次无缓存时 Rust 依赖全量编译约 7–9 分钟。

更多文档：[ARCHITECTURE.md](docs/ARCHITECTURE.md)（分层与驱动插件）、
[RELEASE.md](docs/RELEASE.md)（发版与更新清单）、[CONTRIBUTING.md](CONTRIBUTING.md)（提交规范与测试门禁）。

## 许可证

[MIT](LICENSE) © 2026 L-Y-P
