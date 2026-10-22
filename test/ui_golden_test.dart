// Golden tests that render the shared UI kit and write PNGs.
//
// The web app was verified by looking at it in a browser; a desktop app cannot
// be screenshotted by the OS without granting Screen Recording permission, so
// these goldens are the reproducible visual check. Running
//   flutter test --update-goldens test/ui_golden_test.dart
// writes the PNGs under test/goldens/, which can be opened and compared against
// the web screenshots in screenshots/.
//
// The widgets under test are pure presentation (no Rust calls), so the test
// needs no database and runs anywhere.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/components/data_grid.dart';
import 'package:rust_myadmin_desktop/src/theme.dart';
import 'package:rust_myadmin_desktop/src/widgets.dart';

/// Wrap a widget in the app theme and a fixed-size surface so the golden is
/// deterministic regardless of the host window size.
Widget harness(Widget child, {double width = 900, double height = 600}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildAppTheme(),
    home: Scaffold(
      backgroundColor: AppColors.bg,
      body: Center(
        child: SizedBox(
          width: width,
          height: height,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: child,
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('buttons, pills and alerts', (tester) async {
    await tester.pumpWidget(harness(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: const [
              Btn('普通按钮'),
              Btn('主按钮', primary: true),
              Btn('危险按钮', danger: true),
              Btn('小按钮', small: true),
              Btn('禁用', onPressed: null),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: const [
              Pill('12'),
              Pill('ok', tone: PillTone.ok),
              Pill('锁定', tone: PillTone.warn),
              Pill('info', tone: PillTone.info),
              Pill('failed', tone: PillTone.danger),
            ],
          ),
          const SizedBox(height: 12),
          const AlertBox('这是一条错误提示，颜色与 Web 版一致。'),
          const AlertBox('这是一条成功提示。', tone: AlertTone.ok),
          const AlertBox('这是一条信息提示。', tone: AlertTone.info),
        ],
      ),
    ));
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/01_controls.png'));
  });

  testWidgets('card, page head and code block', (tester) async {
    await tester.pumpWidget(harness(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PageHead(
            title: '连接管理',
            actions: [const Pill('4'), const SizedBox(width: 8), const Btn('新建连接', primary: true)],
          ),
          CardBox(
            title: '数据表',
            actions: [const Btn('刷新', small: true)],
            child: const Text('卡片内容：圆角 6px、1px 边框、14px 内边距。'),
          ),
          const SectionLabel('SQL 预览'),
          const SizedBox(height: 6),
          const CodeBlock('SELECT * FROM `users` WHERE `id` > 10;'),
          const SizedBox(height: 10),
          const CodeBlock('SELECT 1;', dark: true),
        ],
      ),
    ));
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/02_layout.png'));
  });

  testWidgets('grid table', (tester) async {
    await tester.pumpWidget(harness(
      CardBox(
        title: '索引',
        child: GridTable(
          headers: const [
            Text('索引名'),
            Text('唯一'),
            Text('字段'),
            Text('基数'),
          ],
          rows: const [
            TableRow(children: [
              Text('PRIMARY'),
              Text('是'),
              Text('id'),
              Text('1024'),
            ]),
            TableRow(children: [
              Text('idx_name'),
              Text('否'),
              Text('name'),
              Text('980'),
            ]),
          ],
        ),
      ),
    ));
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/03_grid_table.png'));
  });

  testWidgets('data grid with sort, null and blob cells', (tester) async {
    await tester.pumpWidget(harness(
      DataGrid(
        columns: const [
          {'name': 'id', 'type_name': 'INT'},
          {'name': 'name', 'type_name': 'VARCHAR'},
          {'name': 'avatar', 'type_name': 'BLOB'},
          {'name': 'note', 'type_name': 'TEXT'},
        ],
        rows: const [
          [1, 'Ada', {'__binary__': 'AAAA', 'len': 2048}, 'first'],
          [2, 'Bob', null, null],
          [3, 'Cy', null, 'third row'],
        ],
        sorts: const [SortSpec('id', 'asc')],
        primaryKey: const ['id'],
        rowOps: true,
        editable: true,
        maxHeight: 240,
      ),
      height: 400,
    ));
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/04_data_grid.png'));
  });

  testWidgets('form controls', (tester) async {
    await tester.pumpWidget(harness(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Field(label: '主机', hint: '127.0.0.1'),
          FormRow(
            label: '数据库类型',
            child: SelectBox<String>(
              value: 'mysql',
              onChanged: (_) {},
              items: const [
                DropdownMenuItem(value: 'mysql', child: Text('MySQL / MariaDB')),
                DropdownMenuItem(value: 'postgres', child: Text('PostgreSQL')),
              ],
            ),
          ),
          Row(
            children: [
              CheckBox(label: '结构', value: true, onChanged: (_) {}),
              const SizedBox(width: 12),
              CheckBox(label: '数据', value: false, onChanged: (_) {}),
            ],
          ),
        ],
      ),
    ));
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/05_form.png'));
  });
}
