// Round 18 requirements pinned by these tests:
//
//  1. Anything rendered inside a fixed-size / truncating container must expose
//     the *complete* value on hover. The reported case was the JOIN table
//     picker: `rustmyadmin_demo.websites` was cut to `rustmyadmin_demo.dn...`
//     with no way to read it.
//  2. In Chinese the builder's controls speak plain Chinese (the SQL token is
//     kept in parentheses); in English they show the raw SQL keywords, because
//     the app's English mode mirrors the SQL vocabulary.
//  3. The generated SQL is adapted to the connection's engine (native vs
//     emulated FULL OUTER JOIN, ILIKE, literal escaping) — the model coverage
//     lives in builder_model_test.dart, the label mapping is asserted here.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/builder/builder_editors.dart';
import 'package:rust_myadmin_desktop/src/builder/builder_labels.dart';
import 'package:rust_myadmin_desktop/src/builder/query_model.dart';
import 'package:rust_myadmin_desktop/src/i18n.dart';
import 'package:rust_myadmin_desktop/src/theme.dart';
import 'package:rust_myadmin_desktop/src/widgets.dart';

Widget host(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: Scaffold(body: child),
    );

/// All tooltip messages currently mounted.
List<String> tooltipMessages(WidgetTester tester) => tester
    .widgetList<Tooltip>(find.byType(Tooltip))
    .map((tooltip) => tooltip.message ?? '')
    .toList();

List<BuilderTable> tables() => <BuilderTable>[
      BuilderTable(
        name: 'websites',
        database: 'rustmyadmin_demo',
        columns: <BuilderColumn>[
          BuilderColumn(name: 'id', type: 'int', key: 'PRI'),
          BuilderColumn(name: 'site_id', type: 'int'),
        ],
        foreignKeys: <BuilderForeignKey>[
          BuilderForeignKey(
              column: 'site_id', refTable: 'access_log', refColumn: 'aid'),
        ],
      ),
      BuilderTable(
        name: 'access_log',
        database: 'rustmyadmin_demo',
        columns: <BuilderColumn>[
          BuilderColumn(name: 'aid', type: 'int', key: 'PRI'),
        ],
      ),
    ];

void main() {
  tearDown(() => I18n.setLang(AppLang.zh));

  group('hover reveals truncated content', () {
    testWidgets('EllipsisText adds a tooltip only when the text overflows',
        (tester) async {
      await tester.pumpWidget(host(Column(children: const [
        SizedBox(width: 200, child: EllipsisText('short')),
        SizedBox(
          width: 80,
          child: EllipsisText(
            'rustmyadmin_demo.websites_really_long_name',
            tooltipMaxWidth: 300,
          ),
        ),
      ])));
      await tester.pumpAndSettle();
      final messages = tooltipMessages(tester);
      expect(messages, contains('rustmyadmin_demo.websites_really_long_name'),
          reason: 'the clipped value must be readable in full on hover');
      expect(messages, isNot(contains('short')),
          reason: 'a value that fits must not pop an unnecessary tooltip');
    });

    testWidgets('join table badges expose the full db.table name',
        (tester) async {
      await tester.pumpWidget(host(SizedBox(
        width: 900,
        child: BuilderJoinRow(
          index: 0,
          join: JoinSpec(
            type: 'LEFT',
            leftTable: 'rustmyadmin_demo.websites',
            rightTable: 'rustmyadmin_demo.access_log',
            leftColumn: 'site_id',
            rightColumn: 'aid',
          ),
          tables: tables(),
          participating: const [
            'rustmyadmin_demo.websites',
            'rustmyadmin_demo.access_log',
          ],
          onChanged: () {},
          onRemove: () {},
        ),
      )));
      await tester.pumpAndSettle();
      final messages = tooltipMessages(tester);
      expect(messages, contains('rustmyadmin_demo.websites'));
      expect(messages, contains('rustmyadmin_demo.access_log'));
    });

    testWidgets('the table picker menu is wider than the closed control',
        (tester) async {
      await tester.pumpWidget(host(SizedBox(
        width: 900,
        child: BuilderJoinRow(
          index: 0,
          join: JoinSpec(
            type: 'LEFT',
            leftTable: 'rustmyadmin_demo.websites',
            rightTable: 'rustmyadmin_demo.access_log',
            leftColumn: 'site_id',
            rightColumn: 'aid',
          ),
          tables: tables(),
          participating: const [
            'rustmyadmin_demo.websites',
            'rustmyadmin_demo.access_log',
          ],
          onChanged: () {},
          onRemove: () {},
        ),
      )));
      await tester.pumpAndSettle();
      // Open the left-table picker.
      await tester.tap(find.byKey(const ValueKey('builder-join-0-left')));
      await tester.pumpAndSettle();
      final menus = tester
          .widgetList<DropdownButton<String>>(find.byType(DropdownButton<String>));
      expect(menus, isNotEmpty);
      final withMenuWidth = menus
          .map((menu) => menu.menuWidth)
          .whereType<double>()
          .toList();
      expect(withMenuWidth, isNotEmpty,
          reason: 'a narrow picker must open a wide-enough menu');
      expect(withMenuWidth.first, greaterThan(122));
    });

    testWidgets('cross-database ON hint is a warning tag with a tooltip',
        (tester) async {
      final crossTables = <BuilderTable>[
        BuilderTable(
          name: 'users',
          database: 'crm',
          columns: <BuilderColumn>[BuilderColumn(name: 'id', type: 'int')],
        ),
        BuilderTable(
          name: 'orders',
          database: 'shop',
          columns: <BuilderColumn>[BuilderColumn(name: 'id', type: 'int')],
        ),
      ];
      await tester.pumpWidget(host(SizedBox(
        width: 900,
        child: BuilderJoinRow(
          index: 0,
          join: JoinSpec(
            type: 'LEFT',
            leftTable: 'shop.orders',
            rightTable: 'crm.users',
          ),
          tables: crossTables,
          participating: const ['shop.orders', 'crm.users'],
          onChanged: () {},
          onRemove: () {},
        ),
      )));
      await tester.pumpAndSettle();
      expect(find.text('跨库需手动选匹配字段'), findsOneWidget);
      expect(tooltipMessages(tester).join(' '), contains('跨库连接无法自动推导外键'));
    });
  });

  group('Chinese labels explain SQL, English labels stay SQL', () {
    test('operators are translated with their SQL token kept', () {
      I18n.setLang(AppLang.zh);
      expect(operatorLabel('='), contains('等于'));
      expect(operatorLabel('IS NULL'), contains('为空'));
      expect(operatorLabel('LEFI'), 'LEFI',
          reason: 'unknown tokens pass through instead of being mangled');
      I18n.setLang(AppLang.en);
      expect(operatorLabel('='), '=');
      expect(operatorLabel('IS NULL'), 'IS NULL');
      expect(operatorLabel('IN'), 'IN');
    });

    test('join types are translated', () {
      I18n.setLang(AppLang.zh);
      expect(joinTypeLabel('INNER'), '内连接');
      expect(joinTypeLabel('LEFT'), '左连接');
      expect(joinTypeLabel('RIGHT'), '右连接');
      expect(joinTypeLabel('FULL OUTER'), '全连接');
      expect(joinTypeLabel('CROSS'), '交叉连接');
      expect(joinTypeMenuLabel('LEFT'), contains('LEFT'));
      expect(joinTypeDescription('LEFT'), contains('左边表'));
      I18n.setLang(AppLang.en);
      expect(joinTypeLabel('LEFT'), 'LEFT');
      expect(joinTypeMenuLabel('LEFT'), 'LEFT');
    });

    test('aggregates, connectors, sort directions and captions', () {
      I18n.setLang(AppLang.zh);
      expect(aggregateLabel(''), '原始值');
      expect(aggregateLabel('COUNT'), contains('计数'));
      expect(connectorLabel('AND'), contains('并且'));
      expect(connectorLabel('OR'), contains('或者'));
      expect(orderDirectionLabel('ASC'), contains('升序'));
      expect(orderDirectionLabel('DESC'), contains('降序'));
      expect(whereLabel(), isNot('WHERE'));
      expect(onLabel(), isNot('ON'));
      expect(distinctLabel(), contains('去重'));
      I18n.setLang(AppLang.en);
      expect(aggregateLabel(''), 'Raw');
      expect(aggregateLabel('COUNT'), 'COUNT');
      expect(connectorLabel('AND'), 'AND');
      expect(orderDirectionLabel('ASC'), 'ASC');
      expect(whereLabel(), 'WHERE');
      expect(onLabel(), 'ON');
    });

    test('the filter operator picker reflects the active dialect', () {
      expect(builderOperatorsFor(BuilderDialect.postgres), contains('ILIKE'));
      expect(builderOperatorsFor(BuilderDialect.mysql), isNot(contains('ILIKE')));
    });

    test('the data source label qualifies PostgreSQL schemas', () {
      // PostgreSQL lists schemas of the active database, MySQL lists
      // databases; 'db.schema' makes the picker read the same way (P3-07).
      expect(
          dataSourceOptionLabel('public',
              database: 'pagila_r34', postgres: true),
          'pagila_r34.public');
      expect(
          dataSourceOptionLabel('public',
              database: 'pagila_r34', postgres: false),
          'public');
      // The database is not repeated when it is the namespace itself.
      expect(
          dataSourceOptionLabel('sakila',
              database: 'sakila', postgres: true),
          'sakila');
      expect(dataSourceOptionLabel('sakila'), 'sakila');
      expect(
          dataSourceOptionLabel('public', postgres: true),
          'public');
    });
  });
}
