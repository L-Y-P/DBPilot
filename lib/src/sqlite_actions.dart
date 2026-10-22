import 'package:flutter/material.dart' hide Text, Tooltip;
import 'text.dart';

import 'api.dart';
import 'app_state.dart';
import 'dialogs.dart';
import 'i18n.dart';
import 'nav.dart';
import 'notice.dart';
import 'sqlite_sources.dart';
import 'theme.dart';
import 'widgets.dart';

/// Actions behind the sidebar's "+" button.
///
/// One entry point for every driver: for MySQL / PostgreSQL it is the familiar
/// "create database" dialog, while a SQLite connection can only ever create or
/// import *files*, so the same button offers that instead. Dispatching here
/// keeps the sidebar free of driver-specific UI.
Future<void> showNewDatabase(BuildContext context, Notice notice) async {
  if (!AppState.instance.isSqlite) {
    await showCreateDatabaseDialog(context, notice);
    return;
  }
  final choice = await showAppModal<String>(
    context: context,
    title: '新建数据库',
    builder: (context) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('SQLite 的数据库就是一个文件。选择要执行的操作：', style: kSmallMuted),
        const SizedBox(height: 12),
        _choice(
          context,
          icon: Icons.add_box_outlined,
          title: '新建数据库文件',
          detail: '输入文件名，选择保存目录，创建后立即打开。',
          value: 'create',
        ),
        _choice(
          context,
          icon: Icons.insert_drive_file_outlined,
          title: '导入数据库文件',
          detail: '选择一个或多个已有的 .sqlite / .db 文件，分别作为连接打开。',
          value: 'file',
        ),
        _choice(
          context,
          icon: Icons.folder_open_outlined,
          title: '导入数据库目录',
          detail: '选择一个目录，递归找出其中的所有数据库文件。',
          value: 'folder',
        ),
      ],
    ),
    actions: [
      Builder(
        builder: (context) =>
            Btn(t('cancel'), onPressed: () => Navigator.of(context).pop()),
      ),
    ],
  );
  if (choice == null || !context.mounted) return;
  switch (choice) {
    case 'create':
      await createSqliteDatabase(context, notice);
    case 'file':
      await importSqliteFiles(context, notice);
    case 'folder':
      await importSqliteFolder(context, notice);
  }
}

Widget _choice(
  BuildContext context, {
  required IconData icon,
  required String title,
  required String detail,
  required String value,
}) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: InkWell(
      onTap: () => Navigator.of(context).pop(value),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.border),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: AppColors.muted),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(detail, style: kSmallMuted),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Create a database file in a folder the user picks, then open it.
///
/// The folder defaults to the current connection's folder, because that is
/// where the other databases are, but it can be any writable directory.
Future<void> createSqliteDatabase(BuildContext context, Notice notice) async {
  final result = await showCreateSqliteDatabaseDialog(
    context,
    initialDir: AppState.instance.sqliteFolder,
  );
  if (result == null) return;
  if (!context.mounted) return;
  await AppState.instance.syncActive();
  final created = (result['path'] ?? '').toString();
  final database = AppState.instance.databases.firstWhere(
    (d) => (d['path'] ?? '').toString() == created,
    orElse: () => <String, dynamic>{'name': 'main'},
  );
  Navigation.instance.go(AppRoute.database((database['name'] ?? 'main').toString()));
  notice.show('数据库已创建');
}

/// Dialog: file name + destination folder + optional starter script.
Future<Json?> showCreateSqliteDatabaseDialog(
  BuildContext context, {
  String initialDir = '',
}) {
  final name = TextEditingController();
  final script = TextEditingController();
  final dir = TextEditingController(text: initialDir);
  final handle = ModalHandle();
  String? error;
  bool busy = false;

  Future<void> browse() async {
    try {
      final picked = await pickFolder(title: '选择数据库文件的保存目录');
      if (picked == null) return;
      dir.text = picked;
      handle.rebuild();
    } catch (e) {
      // A native picker failure used to be swallowed, so 浏览 looked dead.
      error = '无法打开文件夹选择器：$e';
      handle.rebuild();
    }
  }

  Future<void> submit() async {
    busy = true;
    error = null;
    handle.rebuild();
    try {
      final res = await Api.instance.sqliteCreateDatabase(
        dir: dir.text.trim(),
        name: name.text.trim(),
        content: script.text.trim().isEmpty ? null : script.text,
      );
      handle.close(res);
    } catch (e) {
      busy = false;
      error = e.toString();
      handle.rebuild();
    }
  }

  return showModalShell<Json>(
    context: context,
    title: '新建数据库文件',
    handle: handle,
    builder: (context, setModal) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Field(
          label: '文件名',
          controller: name,
          hint: 'my_database.sqlite',
        ),
        FormRow(
          label: '保存目录',
          child: Field(
            label: '',
            controller: dir,
            hint: '/path/to/folder',
            trailing: IconBtn(Icons.folder_open_outlined,
                tooltip: '浏览', small: true, onPressed: browse),
          ),
        ),
        Field(
          label: '初始化 SQL（可选）',
          controller: script,
          hint: 'CREATE TABLE ...',
          maxLines: 4,
        ),
        Text(
          '文件会直接创建在所选目录里；目录不可写或没有权限时，系统会返回具体错误。',
          style: kSmallMuted,
        ),
        if (error != null) ...[
          const SizedBox(height: 8),
          AlertBox(error!),
        ],
      ],
    ),
    actions: [
      Btn(t('cancel'), onPressed: () => handle.close()),
      Btn(busy ? '创建中…' : '创建',
          primary: true, busy: busy, onPressed: busy ? null : submit),
    ],
  );
}

/// Import one or more database files as separate connections.
Future<void> importSqliteFiles(BuildContext context, Notice notice) async {
  try {
    final scan = await pickSqliteSources();
    if (scan == null || !context.mounted) return;
    await _import(context, notice, scan.files);
  } catch (e) {
    if (context.mounted) {
      await showAppModal(
        context: context,
        title: '无法打开文件选择器',
        builder: (context) => AlertBox(e.toString()),
      );
    }
  }
}

/// Import a folder: every database file inside it becomes a connection.
Future<void> importSqliteFolder(BuildContext context, Notice notice) async {
  try {
    final dir = await pickFolder(title: '选择包含 SQLite 数据库的文件夹');
    if (dir == null || !context.mounted) return;
    await _import(context, notice, <String>[dir]);
  } catch (e) {
    if (context.mounted) {
      await showAppModal(
        context: context,
        title: '无法打开文件夹选择器',
        builder: (context) => AlertBox(e.toString()),
      );
    }
  }
}

Future<void> _import(
  BuildContext context,
  Notice notice,
  List<String> paths,
) async {
  if (paths.isEmpty) return;
  try {
    final res = await Api.instance.sqliteImport(paths);
    if (!context.mounted) return;
    await AppState.instance.syncActive();
    final created = res['created'];
    final count = created is List ? created.length : 0;
    final failed = res['failed'];
    if (failed is List && failed.isNotEmpty && context.mounted) {
      await _showImportErrors(context, failed);
    }
    notice.show('已导入 $count 个数据库连接');
  } catch (e) {
    if (!context.mounted) return;
    await showAppModal(
      context: context,
      title: '导入失败',
      builder: (context) => AlertBox(e.toString()),
    );
  }
}

Future<void> _showImportErrors(BuildContext context, List<dynamic> failed) {
  return showAppModal(
    context: context,
    title: '部分文件未导入',
    wide: true,
    builder: (context) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final raw in failed)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: AlertBox(
              "${(raw as Map)['path'] ?? ''}\n${(raw)['error'] ?? ''}",
            ),
          ),
      ],
    ),
  );
}

/// Reveal a database file (or its folder) in the system file manager.
Future<void> revealDatabasePath(
  BuildContext context,
  Notice notice,
  String path,
) async {
  if (path.trim().isEmpty) {
    notice.show('该数据库没有对应的文件路径');
    return;
  }
  final ok = await revealInFileManager(path);
  if (!ok) {
    notice.show('无法打开目录（文件或目录可能已不存在）：$path');
  }
}
