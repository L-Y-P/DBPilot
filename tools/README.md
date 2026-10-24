# tools/

| 脚本 | 作用 |
| --- | --- |
| `check_api_surface.py` | CI/Makefile 架构守卫：FRB api 模块不得出现 dbpilot-core 结果类型、生成文件不得含 opaque db 类型、api 不得有 `pub(crate) trait/struct`、Rust/Dart kind 常量逐项一致、`value_to_json` 与 `raw_cell` 类型分发表一致。入口：`make api-guard` 或 `python3 tools/check_api_surface.py`。 |
| `format.sh` | 只格式化手写代码：Rust `rust/src/**`（排除 `frb_generated.rs`）、Dart `lib/src` + `lib/main.dart` + `test`（`lib/src/rust/**` 由 codegen 生成）。**新增手写文件无需登记**（脚本按目录遍历）；只有新增的生成文件需要加进排除列表。 |
| `patches/` | 上游依赖补丁（目前只有 FRB 2.13 的 SSE 异步零拷贝 patch + 应用说明），默认不应用。 |
| `run_live_tests.sh` / `tls_fixture.sh` / `perf/` | 既有测试/性能脚本。 |