// Identifier quoting is built character by character in the test helpers.
// ignore_for_file: prefer_interpolation_to_compose_strings
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/builder/query_model.dart';

String pgQuote(String name) => '"' + name.replaceAll('"', '""') + '"';
String mysqlQuote(String name) => '`' + name.replaceAll('`', '``') + '`';

List<BuilderTable> schema() => <BuilderTable>[
      BuilderTable(
        name: 'order',
        columns: <BuilderColumn>[
          BuilderColumn(name: 'id', type: 'integer', key: 'PRI'),
          BuilderColumn(name: 'user_id', type: 'integer'),
          BuilderColumn(name: 'status', type: 'varchar'),
          BuilderColumn(name: 'amount', type: 'numeric'),
          BuilderColumn(name: 'region', type: 'varchar'),
          BuilderColumn(name: 'created_at', type: 'timestamp'),
        ],
        foreignKeys: <BuilderForeignKey>[
          BuilderForeignKey(
              column: 'user_id', refTable: 'user', refColumn: 'id'),
        ],
      ),
      BuilderTable(
        name: 'user',
        columns: <BuilderColumn>[
          BuilderColumn(name: 'id', type: 'integer', key: 'PRI'),
          BuilderColumn(name: 'name', type: 'varchar'),
          BuilderColumn(name: 'phone', type: 'varchar'),
        ],
      ),
      BuilderTable(
        name: 'access_log',
        columns: <BuilderColumn>[
          BuilderColumn(name: 'id', type: 'integer', key: 'PRI'),
          BuilderColumn(name: 'user_id', type: 'integer'),
          BuilderColumn(name: 'path', type: 'varchar'),
        ],
      ),
    ];

/// Default test dialect stays PostgreSQL-quoted (the historical expectation of
/// every case below); pass `dialect:` to exercise an engine-specific branch.
BuilderSql build(BuilderQuery query,
        {bool isMysql = false,
        BuilderDialect? dialect,
        List<BuilderTable>? tables}) =>
    buildBuilderSql(
      query,
      tables ?? schema(),
      quote: (dialect ?? (isMysql ? BuilderDialect.mysql : BuilderDialect.postgres)) ==
              BuilderDialect.mysql
          ? mysqlQuote
          : pgQuote,
      dialect: dialect,
      isMysql: isMysql,
    );

/// Table names a UNION branch references through FROM / JOIN, in order.
///
/// Identifiers are stripped of their quoting and namespace, so the two branches
/// can be compared as table sets (the round-34 P1-01 bug duplicated `film` in
/// the second branch: MySQL rejected the statement with 42000, "Not unique
/// table/alias").
List<String> branchTables(String branch) => RegExp(
        r'(?:FROM|JOIN)\s+((?:`[^`]+`|"[^"]+")(?:\.(?:`[^`]+`|"[^"]+"))?)')
    .allMatches(branch)
    .map((match) => match
        .group(1)!
        .split('.')
        .last
        .replaceAll(RegExp(r'[`"]'), ''))
    .toList();

/// The round-34 P1-01 schema: `film` plus its language and three FK children.
List<BuilderTable> filmSchema() => <BuilderTable>[
      BuilderTable(name: 'film', columns: <BuilderColumn>[
        BuilderColumn(name: 'film_id', type: 'int', key: 'PRI'),
        BuilderColumn(name: 'language_id', type: 'int'),
        BuilderColumn(name: 'original_language_id', type: 'int'),
      ]),
      BuilderTable(name: 'language', columns: <BuilderColumn>[
        BuilderColumn(name: 'language_id', type: 'int', key: 'PRI'),
        BuilderColumn(name: 'name', type: 'varchar'),
      ]),
      BuilderTable(name: 'film_actor', columns: <BuilderColumn>[
        BuilderColumn(name: 'actor_id', type: 'int', key: 'PRI'),
        BuilderColumn(name: 'film_id', type: 'int'),
      ]),
      BuilderTable(name: 'film_category', columns: <BuilderColumn>[
        BuilderColumn(name: 'category_id', type: 'int', key: 'PRI'),
        BuilderColumn(name: 'film_id', type: 'int'),
      ]),
      BuilderTable(name: 'inventory', columns: <BuilderColumn>[
        BuilderColumn(name: 'inventory_id', type: 'int', key: 'PRI'),
        BuilderColumn(name: 'film_id', type: 'int'),
      ]),
    ];

/// `film` with the first (auto) FK join switched to FULL OUTER and three more
/// LEFT joins — the shape that produced the invalid second UNION branch.
BuilderQuery filmFullOuterQuery() {
  final query = BuilderQuery()..primaryTable = 'film';
  query.joins.addAll(<JoinSpec>[
    JoinSpec(
      type: 'FULL OUTER',
      leftTable: 'film',
      rightTable: 'language',
      leftColumn: 'language_id',
      rightColumn: 'language_id',
    ),
    JoinSpec(
      type: 'LEFT',
      leftTable: 'film',
      rightTable: 'film_actor',
      leftColumn: 'film_id',
      rightColumn: 'film_id',
    ),
    JoinSpec(
      type: 'LEFT',
      leftTable: 'film',
      rightTable: 'film_category',
      leftColumn: 'film_id',
      rightColumn: 'film_id',
    ),
    JoinSpec(
      type: 'LEFT',
      leftTable: 'film',
      rightTable: 'inventory',
      leftColumn: 'film_id',
      rightColumn: 'film_id',
    ),
  ]);
  query.outputs.addAll(<OutputField>[
    OutputField(table: 'film', column: 'film_id'),
    OutputField(table: 'language', column: 'name'),
  ]);
  return query;
}
void main() {
  test('incomplete query renders a comment instead of SQL', () {
    final query = BuilderQuery();
    final sql = build(query);
    expect(sql.preview, '-- 请先选择主表');
    expect(sql.executable, '-- 请先选择主表');
    expect(sql.params, isEmpty);
  });

  test('single table without outputs selects every column', () {
    final query = BuilderQuery()..primaryTable = 'order';
    final sql = build(query);
    expect(sql.preview, contains('SELECT "order".*'));
    expect(sql.preview, contains('FROM "order"'));
    expect(sql.preview, contains('LIMIT 100'));
    expect(sql.params, isEmpty);
  });

  test('DISTINCT and limit are rendered', () {
    final query = BuilderQuery()
      ..primaryTable = 'order'
      ..distinct = true
      ..limit = 7;
    final sql = build(query);
    expect(sql.preview, startsWith('SELECT DISTINCT'));
    expect(sql.preview, contains('LIMIT 7'));
  });

  test('aggregates, aliases and GROUP BY', () {
    final query = BuilderQuery()..primaryTable = 'order';
    query.outputs.addAll(<OutputField>[
      OutputField(table: 'order', column: 'region'),
      OutputField(
          table: 'order',
          column: 'id',
          aggregate: 'COUNT',
          alias: 'cnt'),
    ]);
    final sql = build(query);
    expect(sql.preview, contains('COUNT("order"."id") AS "cnt"'));
    expect(sql.preview, contains('GROUP BY "order"."region"'));
    expect(sql.groupBy, <String>['region']);
  });

  test('multi-table output columns are qualified with an alias', () {
    final query = BuilderQuery()..primaryTable = 'order';
    query.joins.add(JoinSpec(
      type: 'LEFT',
      leftTable: 'order',
      rightTable: 'user',
      leftColumn: 'user_id',
      rightColumn: 'id',
    ));
    query.outputs
        .add(OutputField(table: 'order', column: 'id', alias: 'order_id'));
    query.outputs.add(OutputField(table: 'user', column: 'name'));
    final sql = build(query);
    expect(sql.preview, contains('LEFT JOIN "user" ON '
        '"order"."user_id" = "user"."id"'));
    expect(sql.preview, contains('"order"."id" AS "order_id"'));
    expect(sql.preview, contains('"user"."name" AS "user.name"'));
    expect(sql.tables, <String>['order', 'user']);
  });

  test('filter values become parameters in the preview and literals on run',
      () {
    final query = BuilderQuery()..primaryTable = 'order';
    query.filters.add(FilterEntry.condition(FilterCondition(
      table: 'order',
      column: 'status',
      op: '=',
      value: 'paid',
    )));
    final sql = build(query);
    expect(sql.preview, contains('WHERE "order"."status" = \$1'));
    expect(sql.params, hasLength(1));
    expect(sql.params.first.numeric, isFalse);
    expect(sql.params.first.displayValue, "'paid'");
    expect(sql.executable, contains(' WHERE "order"."status" = \'paid\''));
  });

  test('numeric column values are not quoted', () {
    final query = BuilderQuery()..primaryTable = 'order';
    query.filters.add(FilterEntry.condition(FilterCondition(
      table: 'order',
      column: 'amount',
      op: '>',
      value: '1000',
    )));
    final sql = build(query);
    expect(sql.params.first.numeric, isTrue);
    expect(sql.executable, contains('"order"."amount" > 1000'));
  });

  test('IN binds one parameter per value, LIKE wraps the value', () {
    final query = BuilderQuery()..primaryTable = 'order';
    query.filters.add(FilterEntry.condition(FilterCondition(
      table: 'order',
      column: 'status',
      op: 'IN',
      value: 'paid, shipped',
    )));
    query.filters.add(FilterEntry.condition(FilterCondition(
      table: 'order',
      column: 'region',
      op: 'LIKE',
      value: 'east',
    )));
    final sql = build(query);
    expect(sql.preview, contains('IN (\$1, \$2)'));
    expect(sql.params, hasLength(3));
    expect(sql.params[2].displayValue, "'%east%'");
    expect(sql.executable, contains("LIKE '%east%'"));
  });

  test('groups are parenthesised and keep connectors', () {
    final query = BuilderQuery()..primaryTable = 'order';
    query.filters.add(FilterEntry.condition(FilterCondition(
      table: 'order',
      column: 'status',
      op: '=',
      value: 'paid',
    )));
    final group = FilterEntry.group(logic: 'OR', children: <FilterCondition>[
      FilterCondition(table: 'order', column: 'region', op: '=', value: 'east'),
      FilterCondition(
          table: 'order', column: 'region', op: '=', value: 'south'),
    ]);
    group.connector = 'AND';
    query.filters.add(group);
    final sql = build(query);
    expect(
      sql.preview,
      contains('WHERE "order"."status" = \$1 AND '
          '("order"."region" = \$2 OR "order"."region" = \$3)'),
    );
  });

  test('IS NULL rows do not bind a value', () {
    final query = BuilderQuery()..primaryTable = 'order';
    query.filters.add(FilterEntry.condition(FilterCondition(
      table: 'order',
      column: 'region',
      op: 'IS NULL',
    )));
    final sql = build(query);
    expect(sql.preview, contains('"order"."region" IS NULL'));
    expect(sql.params, isEmpty);
  });

  test('quotes are escaped in the executable SQL', () {
    final query = BuilderQuery()..primaryTable = 'order';
    query.filters.add(FilterEntry.condition(FilterCondition(
      table: 'order',
      column: 'status',
      op: '=',
      value: "O'Brien",
    )));
    expect(build(query).executable, contains("= 'O''Brien'"));
  });

  test('MySQL FULL OUTER becomes a UNION of two branches', () {
    final query = BuilderQuery()..primaryTable = 'order';
    query.joins.add(JoinSpec(
      type: 'FULL OUTER',
      leftTable: 'order',
      rightTable: 'user',
      leftColumn: 'user_id',
      rightColumn: 'id',
    ));
    query.outputs.add(OutputField(table: 'order', column: 'id', alias: 'oid'));
    query.outputs.add(OutputField(table: 'user', column: 'name'));
    final sql = build(query, isMysql: true);
    expect(sql.preview, contains('UNION'));
    expect(sql.preview, contains('FROM `order`'));
    expect(sql.preview, contains('FROM `user`'));
    expect(sql.preview, contains('LEFT JOIN `order`'));
  });

  test('query JSON round-trips every clause', () {
    final query = BuilderQuery()
      ..primaryTable = 'order'
      ..distinct = true
      ..limit = 50
      ..maxReturn = 500;
    query.outputs.add(OutputField(
        table: 'order', column: 'id', aggregate: 'MIN', alias: 'smallest'));
    query.joins.add(JoinSpec(
      type: 'LEFT',
      leftTable: 'order',
      rightTable: 'user',
      leftColumn: 'user_id',
      rightColumn: 'id',
    ));
    query.filters.add(FilterEntry.condition(FilterCondition(
      table: 'order',
      column: 'status',
      op: '=',
      value: 'paid',
    )));
    final group = FilterEntry.group(logic: 'OR', children: <FilterCondition>[
      FilterCondition(table: 'order', column: 'region', op: '=', value: 'east'),
    ]);
    group.connector = 'OR';
    query.filters.add(group);
    query.orders.add(OrderSpec(table: 'order', column: 'created_at', dir: 'DESC'));

    final copy = BuilderQuery.fromJson(query.toJson());
    expect(copy.primaryTable, 'order');
    expect(copy.distinct, isTrue);
    expect(copy.limit, 50);
    expect(copy.maxReturn, 500);
    expect(copy.outputs.single.alias, 'smallest');
    expect(copy.joins.single.rightTable, 'user');
    expect(copy.filters, hasLength(2));
    expect(copy.filters.last.isGroup, isTrue);
    expect(copy.filters.last.connector, 'OR');
    expect(copy.filters.last.logic, 'OR');
    expect(copy.orders.single.dir, 'DESC');
  });

  test('autoFillJoin prefers the declared foreign key', () {
    final join = JoinSpec(type: 'LEFT', leftTable: 'order', rightTable: 'user');
    final note = autoFillJoin(join, schema());
    expect(note, isNull);
    expect(join.leftColumn, 'user_id');
    expect(join.rightColumn, 'id');
  });


  test('cross-database tables render qualified SQL', () {
    final tables = <BuilderTable>[
      BuilderTable(
        name: 'orders',
        database: 'shop',
        columns: <BuilderColumn>[
          BuilderColumn(name: 'id', type: 'integer', key: 'PRI'),
          BuilderColumn(name: 'user_id', type: 'integer'),
        ],
      ),
      BuilderTable(
        name: 'users',
        database: 'crm',
        columns: <BuilderColumn>[
          BuilderColumn(name: 'id', type: 'integer', key: 'PRI'),
          BuilderColumn(name: 'name', type: 'varchar'),
        ],
      ),
    ];
    final query = BuilderQuery()
      ..primaryTable = 'shop.orders'
      ..limit = 10;
    query.joins.add(JoinSpec(
      type: 'LEFT',
      leftTable: 'shop.orders',
      rightTable: 'crm.users',
      leftColumn: 'user_id',
      rightColumn: 'id',
    ));
    query.outputs.add(OutputField(table: 'shop.orders', column: 'id'));
    final sql = build(query, tables: tables);
    expect(sql.preview, contains('FROM "shop"."orders"'));
    expect(sql.preview, contains('LEFT JOIN "crm"."users" ON '
        '"shop"."orders"."user_id" = "crm"."users"."id"'));
    expect(sql.preview, contains('"shop"."orders"."id"'));
    expect(query.queryDatabases(), <String>['shop', 'crm']);
    expect(query.isCrossDatabase, isTrue);
  });

  test('cross-database joins never guess an ON condition', () {
    final tables = <BuilderTable>[
      BuilderTable(
        name: 'a',
        database: 'db1',
        columns: <BuilderColumn>[BuilderColumn(name: 'id', type: 'integer')],
      ),
      BuilderTable(
        name: 'b',
        database: 'db2',
        columns: <BuilderColumn>[BuilderColumn(name: 'id', type: 'integer')],
      ),
    ];
    final join = JoinSpec(type: 'LEFT', leftTable: 'db1.a', rightTable: 'db2.b');
    expect(isCrossDatabaseJoin(join, tables), isTrue);
    final note = autoFillJoin(join, tables);
    expect(note, isNotNull);
    expect(join.leftColumn, isEmpty);
    expect(join.rightColumn, isEmpty);
  });

  test('builderTablesFromMultiSchema merges namespaces and reports denied', () {
    final raw = <String, dynamic>{
      'schemas': <dynamic>[
        <String, dynamic>{
          'database': 'shop',
          'tables': <dynamic>[
            <String, dynamic>{'name': 'orders', 'columns': <dynamic>[]},
          ],
        },
        <String, dynamic>{
          'database': 'crm',
          'tables': <dynamic>[
            <String, dynamic>{'name': 'users', 'columns': <dynamic>[]},
          ],
        },
      ],
      'denied': <dynamic>[
        <String, dynamic>{'database': 'private', 'error': '没有权限'},
      ],
    };
    final schema = builderTablesFromMultiSchema(raw);
    expect(schema.tables.map((t) => t.key), <String>['shop.orders', 'crm.users']);
    expect(schema.denied, <String>['private']);
  });

  test('an incomplete join never leaks an unknown table into SELECT', () {
    final tables = <BuilderTable>[
      BuilderTable(
        name: 'orders',
        database: 'shop',
        columns: <BuilderColumn>[
          BuilderColumn(name: 'id', type: 'integer', key: 'PRI'),
        ],
      ),
      BuilderTable(
        name: 'users',
        database: 'crm',
        columns: <BuilderColumn>[
          BuilderColumn(name: 'id', type: 'integer', key: 'PRI'),
        ],
      ),
    ];
    final query = BuilderQuery()
      ..primaryTable = 'shop.orders'
      ..limit = 10;
    query.joins.add(JoinSpec(
      type: 'LEFT',
      leftTable: 'shop.orders',
      rightTable: 'crm.users',
    ));
    final sql = build(query, tables: tables);
    expect(sql.preview, isNot(contains('crm')));
    expect(sql.preview, contains('FROM "shop"."orders"'));
    expect(sql.warnings, isNotEmpty);
    expect(sql.warnings.first, contains('跨库'));
    // The warning explains the situation in plain Chinese instead of asking the
    // user about "ON"; it must still point at the missing match condition.
    expect(sql.warnings.first, contains('匹配'));
  });

  test('a configured cross-database join renders and keeps both tables', () {
    final tables = <BuilderTable>[
      BuilderTable(
        name: 'orders',
        database: 'shop',
        columns: <BuilderColumn>[
          BuilderColumn(name: 'id', type: 'integer', key: 'PRI'),
          BuilderColumn(name: 'user_id', type: 'integer'),
        ],
      ),
      BuilderTable(
        name: 'users',
        database: 'crm',
        columns: <BuilderColumn>[
          BuilderColumn(name: 'id', type: 'integer', key: 'PRI'),
        ],
      ),
    ];
    final query = BuilderQuery()
      ..primaryTable = 'shop.orders'
      ..limit = 10;
    query.joins.add(JoinSpec(
      type: 'LEFT',
      leftTable: 'shop.orders',
      rightTable: 'crm.users',
      leftColumn: 'user_id',
      rightColumn: 'id',
    ));
    final sql = build(query, tables: tables);
    expect(sql.warnings, isEmpty);
    expect(sql.preview, contains('"shop"."orders".*'));
    expect(sql.preview, contains('"crm"."users".*'));
    expect(sql.preview,
        contains('LEFT JOIN "crm"."users" ON "shop"."orders"."user_id"'));
  });

  test('dialects: FULL OUTER is native on PG/SQLite and a UNION on MySQL', () {
    BuilderQuery fullOuter() {
      final query = BuilderQuery()..primaryTable = 'order';
      query.joins.add(JoinSpec(
        type: 'FULL OUTER',
        leftTable: 'order',
        rightTable: 'user',
        leftColumn: 'user_id',
        rightColumn: 'id',
      ));
      query.outputs.add(OutputField(table: 'order', column: 'id', alias: 'oid'));
      query.outputs.add(OutputField(table: 'user', column: 'name'));
      return query;
    }

    final pg = build(fullOuter(), dialect: BuilderDialect.postgres);
    expect(pg.preview, contains('FULL OUTER JOIN "user"'));
    expect(pg.preview, isNot(contains('UNION')));
    expect(pg.preview, isNot(contains('RIGHT JOIN')));

    final sqlite = build(fullOuter(), dialect: BuilderDialect.sqlite);
    expect(sqlite.preview, contains('FULL OUTER JOIN "user"'));
    expect(sqlite.preview, isNot(contains('UNION')));
    expect(sqlite.preview, isNot(contains('RIGHT JOIN')));

    // MySQL cannot parse FULL OUTER: the emulation must never emit it, and the
    // first branch has to be a LEFT JOIN (a latter regression emitted the
    // literal keyword and the server rejected the whole statement).
    final mysql = build(fullOuter(), dialect: BuilderDialect.mysql);
    expect(mysql.preview, isNot(contains('FULL OUTER')));
    expect(mysql.preview, contains('LEFT JOIN `user`'));
    expect(mysql.preview, contains('UNION'));
    expect(mysql.preview, contains('FROM `user`'));
    expect(mysql.preview, contains('LEFT JOIN `order`'));
  });

  test('MySQL FULL OUTER rewrite refuses table.* without explicit outputs', () {
    final query = BuilderQuery()..primaryTable = 'order';
    query.joins.add(JoinSpec(
      type: 'FULL OUTER',
      leftTable: 'order',
      rightTable: 'user',
      leftColumn: 'user_id',
      rightColumn: 'id',
    ));
    final sql = build(query, dialect: BuilderDialect.mysql);
    expect(sql.preview, isNot(contains('UNION')));
    expect(sql.preview, isNot(contains('RIGHT JOIN')));
    expect(sql.preview, contains('LEFT JOIN `user`'));
    expect(sql.warnings.join(' '), contains('UNION'));
  });

  test('MySQL FULL OUTER rewrite keeps cross-database qualifiers', () {
    final tables = <BuilderTable>[
      BuilderTable(
        name: 'orders',
        database: 'shop',
        columns: <BuilderColumn>[
          BuilderColumn(name: 'id', type: 'integer', key: 'PRI'),
        ],
      ),
      BuilderTable(
        name: 'users',
        database: 'crm',
        columns: <BuilderColumn>[
          BuilderColumn(name: 'id', type: 'integer', key: 'PRI'),
        ],
      ),
    ];
    final query = BuilderQuery()
      ..primaryTable = 'shop.orders'
      ..limit = 10;
    query.joins.add(JoinSpec(
      type: 'FULL OUTER',
      leftTable: 'shop.orders',
      rightTable: 'crm.users',
      leftColumn: 'id',
      rightColumn: 'id',
    ));
    query.outputs.add(OutputField(table: 'shop.orders', column: 'id'));
    final sql = build(query, dialect: BuilderDialect.mysql, tables: tables);
    expect(sql.preview, contains('FROM `shop`.`orders`'));
    // The mirrored branch must be namespace-qualified too (a bare table name
    // silently queried the wrong database).
    expect(sql.preview, contains('FROM `crm`.`users`'));
  });

  test('PostgreSQL ILIKE stays ILIKE and degrades to LIKE elsewhere', () {
    final query = BuilderQuery()..primaryTable = 'order';
    query.filters.add(FilterEntry.condition(FilterCondition(
      table: 'order',
      column: 'status',
      op: 'ILIKE',
      value: 'PAID',
    )));
    final pg = build(query, dialect: BuilderDialect.postgres);
    expect(pg.preview, contains('ILIKE'));
    expect(pg.warnings, isEmpty);

    final mysql = build(query, dialect: BuilderDialect.mysql);
    expect(mysql.preview, contains(' LIKE '));
    expect(mysql.preview, isNot(contains('ILIKE')));
    expect(mysql.warnings.join(' '), contains('ILIKE'));
  });

  test('operators offered per dialect', () {
    expect(builderOperatorsFor(BuilderDialect.postgres), contains('ILIKE'));
    expect(builderOperatorsFor(BuilderDialect.mysql), isNot(contains('ILIKE')));
    expect(builderOperatorsFor(BuilderDialect.sqlite), isNot(contains('ILIKE')));
    // The common set is unchanged, so saved modules stay loadable.
    expect(builderOperatorsFor(BuilderDialect.mysql), containsAll(kOperators));
  });

  test('string literals escape backslashes for MySQL only', () {
    final raw = r'a\b';
    final query = BuilderQuery()..primaryTable = 'order';
    query.filters.add(FilterEntry.condition(FilterCondition(
      table: 'order',
      column: 'status',
      op: '=',
      value: raw,
    )));
    expect(build(query, dialect: BuilderDialect.mysql).executable,
        contains(r"'a\\b'"));
    expect(build(query, dialect: BuilderDialect.postgres).executable,
        contains(r"'a\b'"));
    expect(build(query, dialect: BuilderDialect.sqlite).executable,
        contains(r"'a\b'"));
  });

  test('DISTINCT / GROUP BY sorts are adapted to the select list', () {
    final tables = <BuilderTable>[
      BuilderTable(name: 'websites', columns: <BuilderColumn>[
        BuilderColumn(name: 'id', type: 'integer', key: 'PRI'),
        BuilderColumn(name: 'name', type: 'varchar'),
        BuilderColumn(name: 'alexa', type: 'integer'),
      ]),
    ];

    // DISTINCT + sorting by a column that is not selected is rejected by MySQL
    // ("ORDER BY clause is not in SELECT list") and by PostgreSQL; the builder
    // drops it with a warning instead of producing a failing statement.
    final distinct = BuilderQuery()
      ..primaryTable = 'websites'
      ..distinct = true;
    distinct.outputs.add(OutputField(table: 'websites', column: 'name'));
    distinct.orders
        .add(OrderSpec(table: 'websites', column: 'alexa', dir: 'DESC'));
    final distinctSql = build(distinct, tables: tables);
    expect(distinctSql.preview, isNot(contains('ORDER BY')));
    expect(distinctSql.warnings.join(' '), contains('去重'));

    // Sorting by a selected column keeps the sort (using the output alias when
    // the statement is a UNION, or the plain column otherwise).
    final selected = BuilderQuery()
      ..primaryTable = 'websites'
      ..distinct = true;
    selected.outputs.add(OutputField(table: 'websites', column: 'name'));
    selected.orders
        .add(OrderSpec(table: 'websites', column: 'name', dir: 'DESC'));
    final selectedSql = build(selected, tables: tables);
    expect(selectedSql.preview, contains('ORDER BY "websites"."name" DESC'));

    // Aggregates follow GROUP BY semantics: sort by a grouped column works,
    // sorting by an ungrouped one is dropped with a warning.
    final aggregate = BuilderQuery()..primaryTable = 'websites';
    aggregate.outputs.add(
        OutputField(table: 'websites', column: 'name', aggregate: 'COUNT'));
    aggregate.outputs.add(OutputField(table: 'websites', column: 'name'));
    aggregate.orders
        .add(OrderSpec(table: 'websites', column: 'alexa', dir: 'ASC'));
    final aggregateSql = build(aggregate, tables: tables);
    expect(aggregateSql.preview, contains('GROUP BY "websites"."name"'));
    expect(aggregateSql.preview, isNot(contains('ORDER BY')));
    expect(aggregateSql.warnings.join(' '), contains('聚合'));
  });

  test('without explicit outputs the sort survives DISTINCT (already selected)',
      () {
    final tables = <BuilderTable>[
      BuilderTable(name: 'websites', columns: <BuilderColumn>[
        BuilderColumn(name: 'id', type: 'integer', key: 'PRI'),
        BuilderColumn(name: 'alexa', type: 'integer'),
      ]),
    ];
    final query = BuilderQuery()
      ..primaryTable = 'websites'
      ..distinct = true;
    query.orders
        .add(OrderSpec(table: 'websites', column: 'alexa', dir: 'DESC'));
    final sql = build(query, tables: tables);
    // SELECT "websites".* covers every column, so ORDER BY is valid as written.
    expect(sql.preview, contains('SELECT DISTINCT "websites".*'));
    expect(sql.preview, contains('ORDER BY "websites"."alexa" DESC'));
    expect(sql.warnings, isEmpty);
  });

  test('builderDialectOf maps the connection driver ids', () {
    expect(builderDialectOf('mysql'), BuilderDialect.mysql);
    expect(builderDialectOf('postgres'), BuilderDialect.postgres);
    expect(builderDialectOf('sqlite'), BuilderDialect.sqlite);
    // Unknown/empty drivers fall back to the PostgreSQL-style quoting the app
    // uses for every non-MySQL connection.
    expect(builderDialectOf(''), BuilderDialect.postgres);
    expect(builderSupportsFullOuter(BuilderDialect.mysql), isFalse);
    expect(builderSupportsFullOuter(BuilderDialect.postgres), isTrue);
    expect(builderSupportsFullOuter(BuilderDialect.sqlite), isTrue);
  });
  test('a join whose left table is not in FROM is skipped', () {
    final tables = <BuilderTable>[
      BuilderTable(name: 'order', columns: <BuilderColumn>[
        BuilderColumn(name: 'id', type: 'integer', key: 'PRI'),
        BuilderColumn(name: 'user_id', type: 'integer'),
      ]),
      BuilderTable(name: 'user', columns: <BuilderColumn>[
        BuilderColumn(name: 'id', type: 'integer', key: 'PRI'),
      ]),
      BuilderTable(name: 'access_log', columns: <BuilderColumn>[
        BuilderColumn(name: 'id', type: 'integer', key: 'PRI'),
        BuilderColumn(name: 'user_id', type: 'integer'),
      ]),
    ];
    final query = BuilderQuery()..primaryTable = 'order';
    // The left table never appears in FROM: rendering it would reference an
    // unknown table (the same class of bug as the round-17 SELECT leak).
    query.joins.add(JoinSpec(
      type: 'LEFT',
      leftTable: 'user',
      rightTable: 'access_log',
      leftColumn: 'id',
      rightColumn: 'user_id',
    ));
    final sql = build(query, tables: tables);
    expect(sql.preview, isNot(contains('access_log')));
    expect(sql.preview, contains('FROM "order"'));
    expect(sql.warnings.join(' '), contains('尚未接入'));
  });

  // ------------------------------------------------------- P1-01 regressions
  // MySQL FULL OUTER used to mirror *every* join into the second UNION branch,
  // so that branch started from `language` and then emitted `RIGHT JOIN film`
  // for each remaining join: MySQL rejected it with 42000, "Not unique
  // table/alias" (round 34, P1-01).

  test('MySQL FULL OUTER with auto joins stays legal in both branches', () {
    final sql = build(filmFullOuterQuery(),
        dialect: BuilderDialect.mysql, tables: filmSchema());
    expect(sql.preview, isNot(contains('RIGHT JOIN')));
    expect(sql.warnings, isEmpty);

    final branches = sql.preview.split('\nUNION\n');
    expect(branches, hasLength(2));
    expect(branches[0], contains('FROM `film`'));
    expect(branches[1], contains('FROM `language`'));
    expect(branches[1],
        contains('LEFT JOIN `film` ON '
            '`language`.`language_id` = `film`.`language_id`'));

    // Every table is referenced once and both branches agree on the table set,
    // which is what makes the UNION's column list line up.
    final first = branchTables(branches[0]);
    final second = branchTables(branches[1]);
    expect(first.toSet(), <String>{
      'film',
      'language',
      'film_actor',
      'film_category',
      'inventory',
    });
    expect(second.toSet(), first.toSet());
    expect(first.toSet(), hasLength(first.length));
    expect(second.toSet(), hasLength(second.length));
  });

  test('two MySQL full joins cannot form one UNION and degrade safely', () {
    final query = BuilderQuery()..primaryTable = 'film';
    query.joins.addAll(<JoinSpec>[
      JoinSpec(
        type: 'FULL OUTER',
        leftTable: 'film',
        rightTable: 'language',
        leftColumn: 'language_id',
        rightColumn: 'language_id',
      ),
      JoinSpec(
        type: 'FULL OUTER',
        leftTable: 'film',
        rightTable: 'film_actor',
        leftColumn: 'film_id',
        rightColumn: 'film_id',
      ),
    ]);
    query.outputs.addAll(<OutputField>[
      OutputField(table: 'film', column: 'film_id'),
      OutputField(table: 'language', column: 'name'),
    ]);
    final sql =
        build(query, dialect: BuilderDialect.mysql, tables: filmSchema());
    expect(sql.preview, isNot(contains('RIGHT JOIN')));
    expect(sql.preview, isNot(contains('UNION')));
    expect(sql.preview, contains('LEFT JOIN `language`'));
    expect(sql.preview, contains('LEFT JOIN `film_actor`'));
    expect(sql.warnings.join(' '), contains('多个全连接'));
  });

  test('a MySQL full join whose pivot is not the primary degrades', () {
    final query = BuilderQuery()..primaryTable = 'order';
    query.joins.addAll(<JoinSpec>[
      JoinSpec(
        type: 'LEFT',
        leftTable: 'order',
        rightTable: 'user',
        leftColumn: 'user_id',
        rightColumn: 'id',
      ),
      JoinSpec(
        type: 'FULL OUTER',
        leftTable: 'user',
        rightTable: 'access_log',
        leftColumn: 'id',
        rightColumn: 'user_id',
      ),
    ]);
    query.outputs.addAll(<OutputField>[
      OutputField(table: 'order', column: 'id'),
      OutputField(table: 'user', column: 'name'),
    ]);
    final sql = build(query, dialect: BuilderDialect.mysql, tables: schema());
    expect(sql.preview, isNot(contains('RIGHT JOIN')));
    expect(sql.preview, isNot(contains('UNION')));
    expect(sql.preview, contains('FROM `order`'));
    expect(sql.preview,
        contains('LEFT JOIN `user` ON `order`.`user_id` = `user`.`id`'));
    expect(sql.preview,
        contains('LEFT JOIN `access_log` ON '
            '`user`.`id` = `access_log`.`user_id`'));
    expect(sql.warnings.join(' '), contains('表集合一致'));
  });
  // ------------------------------------------------------- P2-07 regressions
  // A filter row with an empty value used to render as `= ''` / `= $1`; a group
  // whose only row was dropped left a dangling `AND (...)` that PostgreSQL
  // rejected with 42601, `syntax error at or near "AND"`.

  test('an empty filter value is dropped from the SQL and reported', () {
    final query = BuilderQuery()..primaryTable = 'order';
    query.filters.add(FilterEntry.condition(FilterCondition(
      table: 'order',
      column: 'status',
      op: '=',
      value: '',
    )));
    final group = FilterEntry.group(logic: 'OR', children: <FilterCondition>[
      FilterCondition(table: 'order', column: 'region', op: '=', value: 'east'),
    ]);
    query.filters.add(group);

    final sql = build(query);
    // Only the group's value is bound: the value-less row must neither add a
    // parameter nor leave its column (or a dangling AND) in the statement.
    expect(sql.params, hasLength(1));
    expect(sql.preview, isNot(contains('"order"."status"')));
    expect(sql.preview, isNot(matches(RegExp(r'WHERE\s+AND'))));
    expect(sql.preview, contains('WHERE ("order"."region" = \$1)'));
    expect(sql.warnings.join(' '), contains('请填写条件值'));

    final missing = builderMissingConditionValue(query);
    expect(missing, isNotNull);
    expect(missing!.field, 'order.status');
    expect(missing.op, '=');
  });

  test('a group left without values produces no dangling WHERE fragment', () {
    final query = BuilderQuery()..primaryTable = 'order';
    query.filters
        .add(FilterEntry.group(logic: 'AND', children: <FilterCondition>[
      FilterCondition(table: 'order', column: 'status', op: '=', value: '   '),
    ]));
    final sql = build(query);
    expect(sql.preview, isNot(contains('WHERE')));
    expect(sql.preview, isNot(contains(r'$1')));
    expect(builderMissingConditionValue(query)!.field, 'order.status');
  });

  test('IS NULL needs no value while IN does', () {
    final ok = BuilderQuery()..primaryTable = 'order';
    ok.filters.add(FilterEntry.condition(FilterCondition(
      table: 'order',
      column: 'created_at',
      op: 'IS NULL',
      value: '',
    )));
    expect(builderMissingConditionValue(ok), isNull);
    expect(build(ok).warnings, isEmpty);
    expect(build(ok).preview, contains('"order"."created_at" IS NULL'));

    final bad = BuilderQuery()..primaryTable = 'order';
    bad.filters.add(FilterEntry.condition(FilterCondition(
      table: 'order',
      column: 'status',
      op: 'IN',
      value: ' , ',
    )));
    expect(builderMissingConditionValue(bad)!.field, 'order.status');
    expect(build(bad).warnings.join(' '), contains('请填写条件值'));
  });
  test('field keys survive tables and columns with dots', () {
    final key = builderFieldKey('weird.table', 'a.col');
    expect(splitBuilderFieldKey(key), ('weird.table', 'a.col'));
  });
}
