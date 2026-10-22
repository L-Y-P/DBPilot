import 'package:flutter/material.dart' hide Text, Tooltip;
import 'text.dart';

import 'api.dart';
import 'app_state.dart';
import 'db_options.dart';
import 'i18n.dart';
import 'nav.dart';
import 'notice.dart';
import 'theme.dart';
import 'widgets.dart';

/// Create-database dialog, opened from the sidebar. Ports the Layout.vue modal:
/// name, charset, collation, a live SQL preview via a dry run, and a muted hint
/// about the server defaults.
///
/// The charset / collation selects are only shown when the driver can actually
/// use them (`features.table_charset`). PostgreSQL creates a schema, whose
/// encoding cannot be chosen, and SQLite cannot create a database at all — the
/// controls used to render anyway and silently changed nothing.
Future<void> showCreateDatabaseDialog(BuildContext context, Notice notice) async {
  // SQLite has no CREATE DATABASE: a "database" is a file. That flow lives in
  // sqlite_actions.dart and is reached from the sidebar's "+" button instead.
  if (AppState.instance.isSqlite) {
    notice.show('SQLite 的数据库就是文件，请用左侧「+」新建数据库文件或导入');
    return;
  }
  if (!AppState.instance.isSqlite && !AppState.instance.can('database')) {
    notice.show('当前账号没有建库权限（需要 CREATEDB / 全局 CREATE）');
    return;
  }
  final name = TextEditingController();
  final pgTemplate = TextEditingController(text: 'template1');
  final pgEncoding = TextEditingController();
  final pgCollation = TextEditingController();
  final pgOwner = TextEditingController();
  final pgTablespace = TextEditingController();
  var charset = '';
  var collation = '';
  var advanced = false;
  var setActive = true;
  String? error;
  String? preview;
  final isPostgres = AppState.instance.isPostgres;
  const word = '数据库';

  Json meta = <String, dynamic>{};
  try {
    meta = await AppState.instance.loadMetaOptions();
  } catch (_) {
    // The dialog still works without metadata; the selects just stay empty.
  }
  final features = DbFeatures.of(meta);
  final supportsCharset = features.tableCharset;
  final charsets = (meta['charsets'] as List?) ?? const [];
  final collations = (meta['collations'] as List?) ?? const [];
  if (!supportsCharset) {
    charset = '';
    collation = '';
  }

  Json requestBody() => <String, dynamic>{
        'name': name.text.trim(),
        // MySQL uses charset/collation; PostgreSQL's collation maps to
        // LC_COLLATE and encoding is a separate advanced field.
        'charset': isPostgres || charset.isEmpty ? null : charset,
        'collation': isPostgres
            ? (pgCollation.text.trim().isEmpty
                ? null
                : pgCollation.text.trim())
            : (collation.isEmpty ? null : collation),
        if (isPostgres) ...{
          'template': pgTemplate.text.trim().isEmpty
              ? null
              : pgTemplate.text.trim(),
          'encoding': pgEncoding.text.trim().isEmpty
              ? null
              : pgEncoding.text.trim(),
          'owner': pgOwner.text.trim().isEmpty ? null : pgOwner.text.trim(),
          'tablespace': pgTablespace.text.trim().isEmpty
              ? null
              : pgTablespace.text.trim(),
        },
      };

  if (!context.mounted) return;
  await showAppModal(
    context: context,
    title: '新建$word',
    builder: (context) => StatefulBuilder(
      builder: (context, setModal) {
        // Collations belonging to the selected charset.
        final filtered = collations.where((c) {
          if (charset.isEmpty) return true;
          return (c as Map)['charset'] == charset;
        }).toList();

        Future<void> runPreview() async {
          try {
            final res =
                await Api.instance.createDatabase(requestBody(), dryRun: true);
            setModal(() {
              preview = (res['sql'] ?? '').toString();
              error = null;
            });
          } catch (e) {
            setModal(() => error = e.toString());
          }
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (isPostgres)
              Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  '将创建 PostgreSQL 数据库（CREATE DATABASE）。库中的模式请在数据库页用「新建模式」创建。',
                  style: kSmallMuted,
                ),
              ),
            Field(
              label: t('name'),
              controller: name,
              hint: 'my_database',
              onChanged: (_) => runPreview(),
            ),
            if (isPostgres) ...[
              InkWell(
                onTap: () => setModal(() => advanced = !advanced),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(advanced ? Icons.expand_less : Icons.expand_more,
                          size: 16, color: AppColors.muted),
                      const SizedBox(width: 4),
                      Text('高级选项',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AppColors.bodyText)),
                    ],
                  ),
                ),
              ),
              if (advanced) ...[
                FormRow(
                  label: '模板',
                  child: Field(
                    label: '',
                    controller: pgTemplate,
                    hint: '默认 template1；改编码/排序规则时通常选 template0',
                  ),
                ),
                FormRow(
                  label: '编码',
                  child: Field(
                    label: '',
                    controller: pgEncoding,
                    hint: '留空 = 服务端默认；例如 UTF8',
                  ),
                ),
                FormRow(
                  label: '排序规则',
                  child: Field(
                    label: '',
                    controller: pgCollation,
                    hint: '留空 = 服务端默认；例如 en_US.UTF-8',
                  ),
                ),
                FormRow(
                  label: '属主',
                  child: Field(
                    label: '',
                    controller: pgOwner,
                    hint: '留空 = 当前用户',
                  ),
                ),
                FormRow(
                  label: '表空间',
                  child: Field(
                    label: '',
                    controller: pgTablespace,
                    hint: '留空 = pg_default',
                  ),
                ),
                Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text(
                    '编码/排序规则与模板不兼容时 PostgreSQL 会拒绝创建；此时请把模板改为 template0。',
                    style: kSmallMuted,
                  ),
                ),
              ],
            ],
            if (supportsCharset) ...[
              FormRow(
                label: '字符集',
                child: SelectBox<String>(
                  value: charset.isEmpty ? '' : charset,
                  onChanged: (v) {
                    charset = v ?? '';
                    collation = '';
                    runPreview();
                    setModal(() {});
                  },
                  items: [
                    const DropdownMenuItem(value: '', child: Text('（默认）')),
                    for (final cs in charsets)
                      DropdownMenuItem(
                        value: (cs as Map)['charset'].toString(),
                        child: Text((cs)['charset'].toString() +
                            ((cs['description'] ?? '').toString().isEmpty
                                ? ''
                                : ' — ${cs['description']}')),
                      ),
                  ],
                ),
              ),
              FormRow(
                label: '排序规则',
                child: SelectBox<String>(
                  value: collation.isEmpty ? '' : collation,
                  onChanged: (v) {
                    collation = v ?? '';
                    runPreview();
                    setModal(() {});
                  },
                  items: [
                    const DropdownMenuItem(value: '', child: Text('（默认）')),
                    for (final co in filtered)
                      DropdownMenuItem(
                        value: (co as Map)['collation'].toString(),
                        child: Text((co)['collation'].toString() +
                            (co['is_default'] == true ? ' *' : '')),
                      ),
                  ],
                ),
              ),
            ],
            if (supportsCharset &&
                (meta['default_charset'] ?? '').toString().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  '服务器默认：${meta['default_charset']} / ${meta['default_collation'] ?? ''}',
                  style: kSmallMuted,
                ),
              ),
            CheckBox(
              label: '设为当前数据库',
              value: setActive,
              onChanged: (v) => setModal(() => setActive = v),
            ),
            if (preview != null && preview!.isNotEmpty) ...[
              const SectionLabel('SQL 预览'),
              const SizedBox(height: 6),
              CodeBlock(preview!),
            ],
            if (error != null) AlertBox(error!),
          ],
        );
      },
    ),
    actions: [
      Builder(
        builder: (context) => Btn('预览 SQL', onPressed: () async {
          try {
            final res =
                await Api.instance.createDatabase(requestBody(), dryRun: true);
            notice.show((res['sql'] ?? '').toString());
          } catch (e) {
            notice.show(e.toString());
          }
        }),
      ),
      Builder(
        builder: (context) => Btn(t('cancel'),
            onPressed: () => Navigator.of(context).pop()),
      ),
      Builder(
        builder: (context) => Btn(t('create'), primary: true, onPressed: () async {
          final created = name.text.trim();
          if (created.isEmpty) {
            notice.show('请填写数据库名');
            return;
          }
          try {
            await Api.instance.createDatabase(requestBody());
            if (context.mounted) Navigator.of(context).pop();
            final state = AppState.instance;
            await state.refreshInstanceDatabases();
            var switched = false;
            if (setActive) {
              // The checkbox is on by default: the new database becomes the one
              // the tree and SQL console operate on.
              try {
                await state.selectDatabase(created);
                switched = true;
              } catch (_) {
                // The instance refresh still shows the new database.
              }
            }
            await state.refreshDatabases();
            if (switched) {
              final next = state.defaultDatabase;
              if (next != null) {
                Navigation.instance.go(AppRoute.database(next));
              }
            }
            notice.show('$word已创建');
          } catch (e) {
            notice.show(e.toString());
          }
        }),
      ),
    ],
  );
}
