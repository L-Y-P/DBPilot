import 'package:flutter/foundation.dart' show visibleForTesting;

import 'api.dart';
import 'i18n_literals.dart';

/// 「数据与卸载」面板要显示的一份数据目录快照。
///
/// Rust 的 `data_dir_summary` 返回的是裸 JSON，直接把 Map 塞进 widget 会让
/// 视图里遍布 `value['files'] as List?` 这样的防御代码；这里一次性做完解析，
/// 字段缺失或类型不对都退化成“空/0”，面板因此永远不会因为一个坏字段炸掉。
class DataDirOverview {
  const DataDirOverview({
    required this.path,
    required this.exists,
    required this.totalBytes,
    required this.fileCount,
    required this.entries,
    required this.containsSecrets,
  });

  /// 数据目录的真实路径（Rust 侧给的是规范化的绝对路径）。
  final String path;

  /// 目录是否已经创建。false 时面板显示“尚未创建”而不是 0 字节的占用。
  final bool exists;

  final int totalBytes;
  final int fileCount;

  /// 顶层子项，已按体积降序（排序由 Rust 完成，这里保持原序）。
  final List<DataDirEntry> entries;

  /// 连接配置等敏感文件是否还在。清空之后应为 false，面板据此切换提示文案。
  final bool containsSecrets;

  static const DataDirOverview empty = DataDirOverview(
    path: '',
    exists: false,
    totalBytes: 0,
    fileCount: 0,
    entries: <DataDirEntry>[],
    containsSecrets: false,
  );

  /// 解析 `data_dir_summary` 的返回体。
  ///
  /// 任何字段缺失或类型不符都降级成默认值：Rust 核心版本较旧、字段改名、
  /// 或者返回体是空 Map 时，面板应该显示“暂无数据”，而不是抛异常让设置页白屏。
  factory DataDirOverview.fromJson(Json json) {
    final rawEntries = json['files'];
    final entries = <DataDirEntry>[];
    if (rawEntries is List) {
      for (final raw in rawEntries) {
        if (raw is Map) {
          final entry = DataDirEntry.fromJson(Map<String, dynamic>.from(raw));
          if (entry.name.isNotEmpty) entries.add(entry);
        }
      }
    }
    return DataDirOverview(
      path: _asText(json['path']),
      exists: json['exists'] == true,
      totalBytes: _asInt(json['total_bytes']),
      fileCount: _asInt(json['file_count']),
      entries: entries,
      containsSecrets: json['contains_secrets'] == true,
    );
  }

}

/// 数据目录下的一个顶层子项（连接配置、历史、备份目录……）。
class DataDirEntry {
  const DataDirEntry({
    required this.name,
    required this.path,
    required this.bytes,
    required this.count,
    required this.isDir,
  });

  final String name;
  final String path;
  final int bytes;

  /// 文件数：普通文件为 1，目录为其下所有普通文件的数量。
  final int count;
  final bool isDir;

  factory DataDirEntry.fromJson(Json json) => DataDirEntry(
        name: _asText(json['name']),
        path: _asText(json['path']),
        bytes: _asInt(json['bytes']),
        count: _asInt(json['count']),
        // Rust 只给 "file" / "dir" 两个取值；未知值按文件处理，这样它的
        // 体积照样计入展示，不会被悄悄丢掉。
        isDir: _asText(json['kind']) == 'dir',
      );

}

/// 内容摘要的一行：`connections.json · 1 个文件 · 1.00 KB`。
///
/// 整行在这里一次拼好，调用方用 noTranslate 原样渲染。为什么不像别处那样
/// 交给翻译器逐句替换：[trLiteral] 只认整句词典与正则重写，而这一行的
/// 文件名、计数、体积全是变量，拼出来永远命不中任何条目，英文界面就会整行
/// 露出中文。文案部分（“N 个文件”）因此由 [pickText] 在拼接前按语言选好。
String entryRowText(DataDirEntry entry) {
  final count = entry.isDir ? entry.count : 1;
  final countText = pickText('$count 个文件', fileCountLabelEn(count));
  return '${entry.name} · $countText · ${formatBytes(entry.bytes)}';
}

/// 英文的文件数文案，处理单复数（`1 file` / `2 files`）。
///
/// 中文不区分单复数，把这件事留在 [pickText] 的英文分支里，中文侧读起来
/// 仍然是最自然的原句。
@visibleForTesting
String fileCountLabelEn(int count) => count == 1 ? '1 file' : '$count files';

String _asText(Object? value) => value == null ? '' : value.toString();

int _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim()) ?? 0;
  return 0;
}