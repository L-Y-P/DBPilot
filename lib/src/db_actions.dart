// Shared database/table actions used by the toolbar buttons, the sidebar tree
// and the context menus.
//
// The same action must behave identically no matter where it is triggered, so
// every entry point calls into this file instead of re-implementing refresh /
// create-table / relationship-diagram. That also keeps the context menu and the
// visible toolbar from drifting apart.
import 'package:flutter/material.dart' hide Text, Tooltip;

import 'api.dart';
import 'app_menu.dart';

// Call sites (views and the sidebar) import this file for the actions; the menu
// widget lives in app_menu.dart, so re-export it rather than making every view
// import both.
export 'app_menu.dart' show AppMenuEntry, ContextMenuRegion, showAppContextMenu;
import 'app_state.dart';
import 'i18n_literals.dart';
import 'nav.dart';
import 'notice.dart';
import 'theme.dart';
import 'views/create_table_dialog.dart';
import 'views/quick_create_table_wizard.dart';
import 'views/relation_designer.dart';

/// Fallback notice for entry points that do not own one (context menus built
/// from a tree row, for example). The wizard requires a [Notice] to report its
/// result; without a caller-supplied banner the toast still has to appear
/// somewhere, so one app-wide instance backs it.
final Notice _fallbackNotice = Notice();

Notice _noticeOf(Notice? notice) => notice ?? _fallbackNotice;

/// Reload the explorer (databases, schemas, tables) after a schema change.
Future<void> refreshExplorer({Notice? notice}) async {
  final state = AppState.instance;
  final nav = Navigation.instance;
  state.bumpExplorer();
  await state.refreshInstanceDatabases();
  await state.refreshDatabases(refreshFiles: true);
  nav.clearTablesCache();
  nav.clearSchemas();
  notice?.show(pickText('已刷新', 'Refreshed'));
}

/// True when [name] is a physical database the server reported, as opposed to a
/// PostgreSQL schema (which the sidebar also shows as a tree level).
bool _isPhysicalDatabase(AppState state, String name) {
  bool has(List<Json> list) =>
      list.any((db) => (db['name'] ?? '').toString() == name);
  return has(state.instanceDatabases) || has(state.databases);
}

/// Make [database] the active database before acting on it.
///
/// MySQL databases need the connection pointed at the right physical database
/// first; a context menu on a database the user has not opened yet must
/// therefore switch before it creates or browses anything.
///
/// PostgreSQL is the exception: its tree nests schemas under the connected
/// database, so the name handed in from a schema node is *not* a database.
/// Switching to it would fail with "database does not exist" and the action
/// would never open — the connection is already on the right database, so the
/// only correct move is to leave it alone.
Future<void> activateDatabase(String database) async {
  final state = AppState.instance;
  if (state.isSqlite) return;
  if (state.activeDatabase == database) return;
  if (!_isPhysicalDatabase(state, database)) return;
  try {
    await state.selectDatabase(database);
  } catch (_) {
    // Switching is a convenience: the action itself still runs against the
    // open connection and reports its own error where the user can see it.
  }
}

/// Open the create-table designer for [database].
///
/// Returns true when a table was created so callers can refresh their own list.
Future<bool> createTableIn(
  BuildContext context,
  String database, {
  Notice? notice,
  void Function(Object error)? onError,
}) async {
  await activateDatabase(database);
  if (!context.mounted) return false;
  final created = await showCreateTableDialog(
    context,
    database: database,
    onError: onError,
    onQuickCreate: () => quickCreateTablesIn(context, database, notice: notice),
  );
  if (created) {
    AppState.instance.bumpExplorer();
    notice?.show('表已创建');
  }
  return created;
}

/// Open the "create tables from a data file" wizard for [database].
Future<bool> quickCreateTablesIn(
  BuildContext context,
  String database, {
  Notice? notice,
}) async {
  await activateDatabase(database);
  if (!context.mounted) return false;
  final created = await showQuickCreateTableWizard(
    context,
    database: database,
    notice: _noticeOf(notice),
  );
  if (created) AppState.instance.bumpExplorer();
  return created;
}

/// Open the E-R relationship designer for [database].
///
/// [initialTables] seeds the canvas. Passing the table currently open in the
/// table page is what makes "关系图" from a table land on that table instead of
/// an empty canvas.
Future<void> openRelationshipDiagram(
  BuildContext context,
  String database, {
  List<String> initialTables = const <String>[],
  Notice? notice,
}) async {
  await activateDatabase(database);
  if (!context.mounted) return;
  await showRelationDesigner(
    context,
    database: database,
    initialTables: initialTables,
    notice: notice,
    onChanged: () async {
      AppState.instance.bumpExplorer();
    },
  );
}

/// Menu entries shared by the database page and the sidebar's database node.
///
/// [onChanged] runs after an action that can change the table list, so the
/// caller can reload its own view.
List<AppMenuEntry> databaseMenuEntries(
  BuildContext context,
  String database, {
  Notice? notice,
  Future<void> Function()? onChanged,
}) {
  Future<void> run(Future<bool> Function() action) async {
    final changed = await action();
    if (changed) await onChanged?.call();
  }

  return <AppMenuEntry>[
    AppMenuEntry(
      label: '刷新',
      onSelected: () async {
        await refreshExplorer(notice: notice);
        await onChanged?.call();
      },
    ),
    AppMenuEntry(
      label: '新建表',
      separatorBefore: true,
      onSelected: () =>
          run(() => createTableIn(context, database, notice: notice)),
    ),
    AppMenuEntry(
      label: '从文件建表',
      onSelected: () =>
          run(() => quickCreateTablesIn(context, database, notice: notice)),
    ),
    AppMenuEntry(
      label: '关系图',
      onSelected: () =>
          openRelationshipDiagram(context, database, notice: notice),
    ),
  ];
}

/// Menu entries for one table row / table page.
///
/// The relationship entry seeds the canvas with [table], so opening it from a
/// table page shows that table and its neighbours immediately.
List<AppMenuEntry> tableMenuEntries(
  BuildContext context,
  String database,
  String table, {
  Notice? notice,
  Future<void> Function()? onChanged,
}) {
  return <AppMenuEntry>[
    AppMenuEntry(
      label: '刷新',
      onSelected: () async {
        await refreshExplorer(notice: notice);
        await onChanged?.call();
      },
    ),
    AppMenuEntry(
      label: '新建表',
      separatorBefore: true,
      onSelected: () async {
        final created = await createTableIn(context, database, notice: notice);
        if (created) await onChanged?.call();
      },
    ),
    AppMenuEntry(
      label: '关系图',
      onSelected: () => openRelationshipDiagram(
        context,
        database,
        initialTables: <String>[table],
        notice: notice,
      ),
    ),
  ];
}
/// A thin divider that separates a toolbar's action groups.
///
/// The database and table toolbars mix destructive actions with the everyday
/// ones; a 1px rule keeps "delete" from sitting shoulder to shoulder with
/// "refresh" and makes the grouping readable at a glance.
class ToolbarDivider extends StatelessWidget {
  const ToolbarDivider({super.key});

  @override
  Widget build(BuildContext context) => Container(
    width: 1,
    height: 22,
    margin: const EdgeInsets.symmetric(horizontal: 2),
    color: AppColors.border,
  );
}
