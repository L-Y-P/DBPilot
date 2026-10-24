library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// Extensions treated as SQLite database files.
///
/// SQLite itself does not require one, but a scan has to draw the line
/// somewhere: without a filter, pointing at a folder of unrelated files would
/// produce hundreds of useless connections.
const List<String> sqliteExtensions = <String>[
  'sqlite',
  'sqlite3',
  'db',
  'db3',
];

/// Last path component, regardless of which separator the string uses.
///
/// Splitting on [Platform.pathSeparator] alone breaks two normal cases: a
/// Windows path pasted into the Linux/macOS form (or the reverse), and a file
/// name returned by a plugin that always uses `/`. Both separators are
/// therefore accepted, which is what `p.basename` does — but this avoids taking
/// a dependency just for one call.
String baseNameOf(String path) {
  var end = path.length;
  while (end > 0 && (path[end - 1] == '/' || path[end - 1] == '\\')) {
    end--;
  }
  var start = end;
  while (start > 0 && path[start - 1] != '/' && path[start - 1] != '\\') {
    start--;
  }
  return path.substring(start, end);
}

bool isSqliteFile(String path) {
  final name = baseNameOf(path).toLowerCase();
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return false;
  return sqliteExtensions.contains(name.substring(dot + 1));
}

/// Name for a connection created from a database file: its base name without
/// the extension, so a folder of files becomes a readable list.
String connectionNameFor(String path) {
  final name = baseNameOf(path);
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name;
  return stem.isEmpty ? name : stem;
}

/// Recursively collect SQLite files under [root].
///
/// "输入文件夹则遍历目录": when a folder is given the files are not known up
/// front, so it is walked. The walk is bounded — pointing it at a home directory
/// must not build a 100k-entry list — and an unreadable subdirectory is skipped
/// rather than aborting the whole scan.
List<String> scanSqliteFolder(
  String root, {
  int maxFiles = 200,
  int maxDepth = 6,
}) {
  final found = <String>[];
  final visited = <String>{};

  void walk(Directory dir, int depth) {
    if (found.length >= maxFiles || depth > maxDepth) return;
    if (!visited.add(dir.path)) return;
    List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } on FileSystemException {
      return;
    }
    // Sorted so the resulting list is stable between scans.
    entries.sort((a, b) => a.path.compareTo(b.path));
    for (final entry in entries) {
      if (found.length >= maxFiles) return;
      final name = entry.uri.pathSegments.last;
      if (name.startsWith('.')) continue;
      if (entry is Directory) {
        walk(entry, depth + 1);
      } else if (entry is File && isSqliteFile(entry.path)) {
        found.add(entry.path);
      }
    }
  }

  final dir = Directory(root);
  if (dir.existsSync()) walk(dir, 0);
  return found;
}

/// Split user-typed paths into existing files, existing folders and missing ones.
///
/// Accepts what people actually paste: one or more absolute paths, one per line,
/// each either a database file or a folder to be scanned. A typed folder is
/// scanned; a typed file becomes a single connection.
({List<String> files, List<String> folders, List<String> missing})
resolveSqlitePaths(Iterable<String> inputs) {
  final files = <String>[];
  final folders = <String>[];
  final missing = <String>[];
  for (final raw in inputs) {
    final path = raw.trim();
    if (path.isEmpty) continue;
    final type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.directory) {
      folders.add(path);
    } else if (type == FileSystemEntityType.file) {
      files.add(path);
    } else {
      missing.add(path);
    }
  }
  return (files: files, folders: folders, missing: missing);
}

/// Everything a bulk import should add.
class SqliteImport {
  const SqliteImport({
    required this.files,
    this.scannedFolders = const <String>[],
  });

  /// Absolute paths of the database files to add.
  final List<String> files;

  /// Folders that were scanned (for the user-facing summary).
  final List<String> scannedFolders;

  SqliteImport merge(SqliteImport other) => SqliteImport(
    files: <String>{...files, ...other.files}.toList(),
    scannedFolders: <String>{
      ...scannedFolders,
      ...other.scannedFolders,
    }.toList(),
  );
}

/// Result of picking files / a folder.
class SqliteScan {
  const SqliteScan({required this.files, required this.folders});

  final List<String> files;
  final List<String> folders;
}

/// Pick one or more SQLite files (batch add).
///
/// `FilePicker.pickFiles` is the multi-select entry point in file_picker 13
/// (there is no `allowMultiple` flag any more; `pickFile` is the single one).
Future<SqliteScan?> pickSqliteSources() async {
  final picked = await FilePicker.pickFiles(
    dialogTitle: '选择 SQLite 数据库文件（可多选）',
    type: FileType.any,
  );
  if (picked.isEmpty) return null;
  final files = picked.map((f) => f.path).whereType<String>().toList();
  return SqliteScan(files: files, folders: const <String>[]);
}

/// Pick a folder and scan it recursively for SQLite files.
Future<SqliteScan?> pickSqliteFolder() async {
  final dir = await FilePicker.getDirectoryPath(
    dialogTitle: '选择包含 SQLite 数据库的文件夹（会递归查找）',
  );
  if (dir == null || dir.isEmpty) return null;
  return SqliteScan(files: scanSqliteFolder(dir), folders: <String>[dir]);
}

/// Pick a folder, with no scan attached.
///
/// Used by the "new database" flow (choose where the file is saved) and by any
/// field that takes a directory, so every path input gets a real browse button
/// instead of asking the user to type an absolute path.
Future<String?> pickFolder({String? title}) async {
  final dir = await FilePicker.getDirectoryPath(dialogTitle: title ?? '选择文件夹');
  if (dir == null || dir.isEmpty) return null;
  return dir;
}

/// Ask where to save [content] and write it there with a native save dialog.
///
/// Returns the chosen path, or null when the user cancelled. Using the dialog
/// instead of a typed path means exports and backups land where the user can
/// actually see them, without them having to type an absolute path.
Future<String?> saveTextFile({
  required String content,
  String? title,
  String? fileName,
  String? initialDirectory,
}) async {
  final uri = await FilePicker.saveFile(
    dialogTitle: title ?? '保存文件',
    fileName: fileName ?? 'export.sql',
    bytes: utf8.encode(content),
    initialDirectory: initialDirectory,
  );
  if (uri == null) return null;
  return uri.toFilePath();
}

/// Ask where to save a file and return the chosen path without writing the
/// payload from Dart.
///
/// Large exports are streamed by the Rust core straight into this path, so the
/// document never has to cross the FFI bridge as one giant String (P1: 1M-row
/// export used ~1 GB RSS). The save dialog still creates/truncates the file, so
/// the caller must delete it if the streamed export fails.
Future<String?> pickSavePath({
  String? title,
  String? fileName,
  String? initialDirectory,
}) async {
  final uri = await FilePicker.saveFile(
    dialogTitle: title ?? '保存文件',
    fileName: fileName ?? 'export.dat',
    bytes: Uint8List(0),
    initialDirectory: initialDirectory,
  );
  return uri?.toFilePath();
}

/// Pick any single file (certificates, keys, scripts).
Future<String?> pickAnyFile({String? title}) async {
  final picked = await FilePicker.pickFile(
    dialogTitle: title ?? '选择文件',
    type: FileType.any,
  );
  return picked?.path;
}

/// Extensions the guided data import can parse out of the box.
///
/// Keep this list in sync with the Rust importer: every extension offered here
/// must be recognised by inspect(), otherwise the picker filters out a file the
/// import could read. Round 50 added the workbook formats — before that the
/// native picker greyed out .xls/.xlsx files, which looked like "the import
/// cannot open Excel" to the user.
///
/// .xls covers two very different files: BIFF (OLE2) workbooks and the
/// SpreadsheetML (XML) workbooks the exporter writes. Both are recognised by
/// content, so one entry is enough here.
const List<String> dataFileExtensions = <String>[
  // Delimited text.
  'csv',
  'tsv',
  'txt',
  'tab',
  'log',
  'dat',
  'data',
  // Structured text the exporter also writes.
  'json',
  'jsonl',
  'ndjson',
  'xml',
  'html',
  'htm',
  'md',
  'markdown',
  // Excel / OpenDocument workbook files (read as worksheets, not as bytes).
  'xls',
  'xlsx',
  'xlsm',
  'xlsb',
  'ods',
];

/// Pick a data file.
///
/// Covers the delimited / structured text formats the importer reads and the
/// Excel / ODS workbook formats (which it reads as worksheets). Keeping the
/// workbook extensions in [dataFileExtensions] is what makes the native picker
/// offer .xls/.xlsx files at all.
Future<String?> pickDataFile({String? title}) async {
  try {
    final picked = await FilePicker.pickFile(
      dialogTitle: title ?? '选择要导入的数据文件',
      type: FileType.custom,
      allowedExtensions: dataFileExtensions,
    );
    return picked?.path;
  } catch (_) {
    // Some platforms reject a custom filter; fall back to any file rather than
    // dead-ending the import.
    final picked = await FilePicker.pickFile(
      dialogTitle: title ?? '选择要导入的数据文件',
      type: FileType.any,
    );
    return picked?.path;
  }
}

/// Pick a .sql script (import into a table or execute from the SQL console).
Future<String?> pickSqlFile({String? title}) async {
  try {
    final picked = await FilePicker.pickFile(
      dialogTitle: title ?? '选择 SQL 文件',
      type: FileType.custom,
      allowedExtensions: const <String>['sql', 'ddl', 'txt'],
    );
    return picked?.path;
  } catch (_) {
    final picked = await FilePicker.pickFile(
      dialogTitle: title ?? '选择 SQL 文件',
      type: FileType.any,
    );
    return picked?.path;
  }
}

/// Pick a single SQLite database file.
Future<String?> pickSqliteFile() async {
  final picked = await FilePicker.pickFile(
    dialogTitle: '选择 SQLite 数据库文件',
    type: FileType.any,
  );
  return picked?.path;
}

/// Reveal [path] in the system file manager.
///
/// Used by "打开数据库目录" for SQLite connections: the database is a plain file,
/// so its folder is what the user wants. Failures are reported to the caller
/// instead of thrown, because a missing folder is a normal state.
Future<bool> revealInFileManager(String path) async {
  if (path.trim().isEmpty) return false;
  final type = FileSystemEntity.typeSync(path);
  final target = type == FileSystemEntityType.directory
      ? path
      : File(path).parent.path;
  if (FileSystemEntity.typeSync(target) == FileSystemEntityType.notFound) {
    return false;
  }
  try {
    // `open -R` selects the file in Finder; for a folder `open` is enough.
    final args = type == FileSystemEntityType.directory
        ? <String>[target]
        : <String>['-R', path];
    final result = Platform.isMacOS
        ? await Process.run('open', args)
        : Platform.isWindows
        ? await Process.run('explorer', <String>[target])
        : await Process.run('xdg-open', <String>[target]);
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// Port of the backend's `name_visible` rule (only_db / hide_db).
///
/// A folder scan can find many files; the connection's 仅显示 / 隐藏 patterns are
/// applied to the file names so an import can be narrowed the same way the
/// database list is. `%` and `_` are the SQL LIKE wildcards, as in the backend.
bool nameVisible({String? only, String? hide, required String name}) {
  bool matches(String pattern, String value) {
    if (pattern == value) return true;
    if (!pattern.contains('%') && !pattern.contains('_')) return false;
    final p = pattern.split('');
    final v = value.split('');
    var pi = 0;
    var vi = 0;
    var star = -1;
    var mark = 0;
    while (vi < v.length) {
      if (pi < p.length && (p[pi] == '_' || p[pi] == v[vi])) {
        pi++;
        vi++;
      } else if (pi < p.length && p[pi] == '%') {
        star = pi++;
        mark = vi;
      } else if (star >= 0) {
        pi = star + 1;
        vi = ++mark;
      } else {
        return false;
      }
    }
    while (pi < p.length && p[pi] == '%') {
      pi++;
    }
    return pi == p.length;
  }

  bool anyIn(String? patterns) {
    if (patterns == null) return false;
    return patterns
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .any((pattern) => matches(pattern, name));
  }

  if (only != null && only.trim().isNotEmpty && !anyIn(only)) return false;
  if (anyIn(hide)) return false;
  return true;
}

/// Keep only the files whose connection name passes the 仅显示 / 隐藏 patterns.
List<String> filterSqliteFiles(
  List<String> files, {
  String? only,
  String? hide,
}) {
  return files
      .where(
        (file) =>
            nameVisible(only: only, hide: hide, name: connectionNameFor(file)),
      )
      .toList();
}
