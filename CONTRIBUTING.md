# 贡献指南

感谢你想改进 DBPilot。本文说明本地开发、测试门禁与提交规范。

- 项目总览与编译步骤见 [README.md](README.md)
- 使用手册见 [docs/USAGE.md](docs/USAGE.md)
- 架构与改动落点见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- 发版流程见 [docs/RELEASE.md](docs/RELEASE.md)
- live 测试见 [docs/CI_LIVE_TESTS.md](docs/CI_LIVE_TESTS.md)

## 目录

- [开发环境](#开发环境)
- [第一次跑起来](#第一次跑起来)
- [测试门禁](#测试门禁)
- [提交规范](#提交规范)
- [改动的边界](#改动的边界)
- [Pull Request 检查清单](#pull-request-检查清单)
- [报告问题](#报告问题)
- [不要提交的内容](#不要提交的内容)
- [许可证](#许可证)

---

## 开发环境

| 依赖 | 版本 / 说明 |
| --- | --- |
| Flutter | **3.47.7**（stable，Dart 3.13.5）——版本不一致时 golden 快照会因字体/布局差异失败 |
| Rust | stable（2021 edition） |
| macOS | Xcode（完整版）+ CocoaPods；`rustup target add aarch64-apple-darwin x86_64-apple-darwin` |
| Windows | Visual Studio 2022「使用 C++ 的桌面开发」+ Windows SDK 10；`x86_64-pc-windows-msvc` target |
| Linux | GTK3 开发库、CMake、Ninja、`pkg-config` |
| codegen | `cargo install flutter_rust_bridge_codegen --version 2.13.0` |
| 可选 | Docker + Compose v2（跑 live 测试用） |

三个桌面平台**不能交叉编译**，请在目标平台上开发与验证。

## 第一次跑起来

```bash
flutter pub get
flutter run -d macos          # 或 -d windows / -d linux
```

Rust 内核由 **cargokit** 在 `flutter build` / `flutter run` 内部自动编译，不需要手动 `cargo build`。

### 跑 Dart 测试前要先编 Rust 动态库

界面测试会通过 `ExternalLibrary.open()` 加载 debug 动态库：

```bash
cd rust && cargo build --lib          # 产出 target/debug/librust_myadmin_core.dylib（.so / .dll）
cd .. && flutter test
```

### 改了 Rust API 之后

`rust/src/api/` 里新增或改签名的 `pub fn` 之后必须重新生成绑定：

```bash
flutter_rust_bridge_codegen generate
```

只改返回 `Value` 的字段不需要 codegen。生成物 `rust/src/frb_generated.rs` 与
`lib/src/rust/**` 由工具维护，**不要手改**。

---

## 测试门禁

提交前至少跑通下面三条（对应你改动的范围再加跑 live）：

```bash
# 1. Dart 静态检查，必须 0 issue
dart analyze

# 2. Flutter 全量
cd . && flutter test

# 3. Rust hermetic（不需要数据库）
cd rust && cargo test --offline -- --test-threads=1
# 或在仓库根：
make rust-test
```

需要真实数据库时（改了驱动 / 方言 / 导入导出 / 权限过滤等）：

```bash
make rust-live-up     # docker compose 起 MySQL 8.4 + PostgreSQL 17
make rust-live        # 等端口 → hermetic → live
make rust-live-down
```

live 测试的端点、账号、库名全部来自环境变量
（`DBPILOT_TEST_MYSQL_*` / `DBPILOT_TEST_PG_*`），**仓库里不允许出现任何真实凭据**。
细节与排错见 [docs/CI_LIVE_TESTS.md](docs/CI_LIVE_TESTS.md)。

### 按改动范围加跑

| 改了什么 | 额外要跑 |
| --- | --- |
| `api/` 的签名 / 返回形状 | codegen + `cargo test` + `flutter test` |
| 数据网格 / 表格布局 | `flutter test test/data_grid_*_test.dart test/grid_table_*_test.dart` |
| UI 布局（像素级变化） | 重生成 golden 快照（见下） |
| SQLite 目录 / ATTACH / 池缓存键 | `cargo test --test sqlite_flow --test sqlite_attach --test sqlite_discovery --test sqlite_attach_limit` |
| 导入 / 导出格式 | `cargo test --test data_import --test export_import_round_trip --test export_stream` |
| SSH / TLS / mTLS | `bash tools/tls_fixture.sh up` → `cargo test --test tls_mysql --test tls_postgres --test tls_mtls` → `down` |
| 驱动 / 方言 SQL | `make rust-live`（真实 MySQL + PostgreSQL 必跑） |
| 英文文案 | `flutter test test/english_ui_test.dart`（英文界面不得残留中文） |

### golden 快照

UI 布局有意改变时才重生成，**无预期变化不要手改 PNG**：

```bash
flutter test --update-goldens test/ui_golden_test.dart \
  test/app_shell_test.dart test/views_golden_test.dart
```

---


## 许可证

提交即表示你同意以 [MIT](LICENSE) 许可证授权你的贡献。
