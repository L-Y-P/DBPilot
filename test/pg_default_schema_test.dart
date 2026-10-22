// Regression tests for the P13 PostgreSQL default-schema subtitle.
//
// The database page and the SQL console used to print "（未知）" whenever
// AppState.searchPath was empty. Expanding a database in the tree, restoring a
// route or refreshing the explorer can switch the active database without a
// selectDatabase response carrying the search_path, while PostgreSQL's actual
// default schema is still public. The subtitle now uses defaultSchemaLabel,
// which falls back to public for PostgreSQL only.

import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/app_state.dart';

void main() {
  final state = AppState.instance;
  Map<String, dynamic>? previousConnection;
  String? previousDatabase;
  String previousSearchPath = '';

  setUp(() {
    previousConnection = state.connection;
    previousDatabase = state.activeDatabase;
    previousSearchPath = state.searchPath;
  });

  tearDown(() {
    state.connection = previousConnection;
    state.activeDatabase = previousDatabase;
    state.searchPath = previousSearchPath;
  });

  group('defaultSchemaLabel (P13)', () {
    test('PostgreSQL falls back to public before search_path is known', () {
      state.connection = <String, dynamic>{'driver': 'postgres'};
      state.searchPath = '';
      expect(state.defaultSchemaLabel, 'public');
      // It is never the "unknown" placeholder.
      expect(state.defaultSchemaLabel, isNot(contains('未知')));
    });

    test('PostgreSQL uses the first explicit search_path schema', () {
      state.connection = <String, dynamic>{'driver': 'postgres'};
      state.searchPath = 'myschema, public';
      expect(state.defaultSchemaLabel, 'myschema');
    });

    test('implicit / system search_path entries are skipped', () {
      state.connection = <String, dynamic>{'driver': 'postgres'};
      state.searchPath = '"\$user", public';
      expect(state.defaultSchemaLabel, 'public');

      state.searchPath = 'pg_catalog, pg_temp_3, reporting, public';
      expect(state.defaultSchemaLabel, 'reporting');
    });

    test('MySQL and SQLite have no default-schema label', () {
      state.connection = <String, dynamic>{'driver': 'mysql'};
      state.searchPath = 'sakila';
      expect(state.defaultSchemaLabel, isEmpty);

      state.connection = <String, dynamic>{'driver': 'sqlite'};
      state.searchPath = 'main';
      expect(state.defaultSchemaLabel, isEmpty);
    });

    test('quoted schema names are unquoted for display', () {
      state.connection = <String, dynamic>{'driver': 'postgres'};
      state.searchPath = '"My Schema", public';
      expect(state.defaultSchemaLabel, 'My Schema');
    });
  });
}
