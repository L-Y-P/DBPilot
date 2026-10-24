#!/usr/bin/env bash
# Format first-party code only; generated bindings are excluded on purpose.
#  * rust/src/frb_generated.rs is skipped from the module tree via
#    #[rustfmt::skip] on `mod frb_generated;` in src/lib.rs;
#  * Dart bindings live under lib/src/rust/ and are produced by codegen.
#
# 新增手写文件：放在 rust/src/ 或 lib/src/、test/ 下会被自动纳入，无需登记。
# 只有新增的*生成*文件需要加入本脚本的排除列表（见下方 find 条件）。
#
# rustfmt 1.10-stable does not support `ignore` in rustfmt.toml (nightly only),
# so this script passes an explicit file list instead of relying on cargo fmt.
set -euo pipefail
cd "$(dirname "$0")/.."

if command -v rustfmt >/dev/null 2>&1; then
  ( cd rust && find src -name '*.rs' ! -name 'frb_generated.rs' -print0 | xargs -0 rustfmt --edition 2021 )
else
  echo 'rustfmt not installed; skipping Rust formatting' >&2
fi

if command -v dart >/dev/null 2>&1; then
  dart format lib/src lib/main.dart test
else
  echo 'dart not on PATH; skipping Dart formatting' >&2
fi