# flutter_rust_bridge 2.13.0 — zero-copy SSE byte slices (optional patch)

## 问题

FRB 2.13 的 SSE 解码器把每个字节切片都复制一次：

```dart
// flutter_rust_bridge-2.13.0/lib/src/third_party/.../read_buffer.dart
return Uint8List.fromList(listView);
// NOTE: Must copy when in `sync` mode ... (but in non-sync mode, we can
// optimize this and do not copy)
```

异步路径的 buffer 本身就是 `Dart_CObject_kExternalTypedData`（Rust 把 ptr+len 交给 Dart VM，
所有权已移交，VM 负责 finalizer 释放）。返回 `Uint8List.sublistView`/buffer view 是安全的；
只有同步 FFI 路径（`decodeWireSyncType`）必须复制，因为 Rust 在调用返回时就释放了 buffer。

## 本机实测（Dart JIT，`analysis/_copy_bench.dart`）

| 载荷 | `Uint8List.fromList` | 视图 |
| --- | --- | --- |
| 0.5 MB | 0.287 ms | ~0 ms |
| 2.6 MB | **1.935 ms** | ~0 ms |
| 4.0 MB | 2.605 ms | ~0 ms |
| 100 × 40 KB（流式总量级） | 0.327 ms | ~0 ms |

## 为什么不默认采用

- 第 42 轮后 UI 已走流式（500 行/批），单条消息只有几十 KB，一次 50k 查询的复制总量约 **0.3–4 ms**
  （占 103 ms 的 0.3–4%），收益远小于 bincode 的复杂度，但也不值得为此 vendoring 整个 FRB 运行时
  （632 KB / 98 个 Dart 文件）并长期维护 fork。
- 结论：**作为上游 PR 提交**（patch 已就绪），或等 FRB 后续版本；如果将来要落地，按下面步骤做。

## 应用步骤（需要时）

```bash
cp -R ~/.pub-cache/hosted/pub.dev/flutter_rust_bridge-2.13.0 third_party/flutter_rust_bridge-2.13.0
cd third_party/flutter_rust_bridge-2.13.0
patch -p1 < ../../tools/patches/flutter_rust_bridge-2.13.0-zero-copy-sse.patch
```

在 `desktop/pubspec.yaml` 加：

```yaml
dependency_overrides:
  flutter_rust_bridge:
    path: third_party/flutter_rust_bridge-2.13.0
```

然后 `flutter pub get` 并跑全量测试。注意 Rust crate 仍固定 `=2.13.0`，Dart 包版本必须保持一致。