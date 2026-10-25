//! PostgreSQL transaction semantics of the server-write paths.
//!
//! Live tests only: they need a reachable PostgreSQL (endpoint from
//! DBPILOT_TEST_PG_*, see tests/common/mod.rs) and are #[ignore]d so the default
//! cargo test stays hermetic:
//!
//!   cargo test --test live_transactions -- --ignored --nocapture --test-threads=1
//!
//! The restore test creates a schema named rma_restore_tx_<pid> in the
//! maintenance database and DROPs it at the end; no existing table or database
//! is touched. It also DROPs IF EXISTS at the start, so a previous failed run
//! cannot make the next one fail.
//!
//! Since round 58 the backup restore path for PostgreSQL / SQLite uses
//! dbpilot_core::ops::restore_sql_atomic: the whole dump is one transaction, so
//! a failing dump leaves no table or row behind. MySQL keeps the grouped
//! restore_sql path (its DDL implicitly commits, so a whole-dump transaction is
//! impossible there); the grouped/non-atomic behaviour is covered by the
//! fake-session unit tests in dbpilot-core/src/ops.rs.
//!
//! The SQLite test below needs no server (a temp database file), so it runs in
//! the normal cargo test run as well; only the PostgreSQL test is #[ignore]d.

use rust_myadmin_core::core::{DriverKind, SessionHandle};
use rust_myadmin_core::db::ResultSet;
use rust_myadmin_core::drivers::{builtin::driver_for, qi, ConnSpec};
use rust_myadmin_core::pools::PoolRegistry;

mod common;

fn pg_spec() -> ConnSpec {
    let endpoint = common::postgres();
    ConnSpec {
        driver: DriverKind::Postgres,
        host: endpoint.host,
        port: Some(endpoint.port),
        user: endpoint.user,
        password: endpoint.password,
        ssl_mode: Some("disable".to_string()),
        ..Default::default()
    }
}

/// Open one pinned PG session, the way the restore path really executes.
///
/// Tries DBPILOT_TEST_PG_DB first (repository default: rustmyadmin_demo), then
/// the maintenance database, then the driver default. The session keeps its own
/// clone of the pool, so the registry can be dropped right after.
async fn pinned_session(spec: &ConnSpec) -> Option<Box<dyn SessionHandle>> {
    let driver = driver_for(DriverKind::Postgres);
    let registry = PoolRegistry::default();
    let configured = common::postgres().database;
    for database in [Some(configured.as_str()), Some("postgres"), None] {
        if let Ok(session) = driver.open_session(&registry, spec, database).await {
            return Some(session);
        }
    }
    None
}

async fn run_on(session: &mut dyn SessionHandle, sql: &str) -> ResultSet {
    session.run_limited(sql.to_string(), 1_000_000).await
}

async fn run_ok(session: &mut dyn SessionHandle, sql: &str) {
    let result = run_on(session, sql).await;
    assert!(
        result.error.is_none(),
        "statement failed: {sql}: {:?}",
        result.error
    );
}

fn duplicate_message(error: &str) -> bool {
    let lower = error.to_ascii_lowercase();
    lower.contains("duplicate key") || lower.contains("unique") || lower.contains("23505")
}

/// PostgreSQL restore is all-or-nothing (round 58): DBPilot uses
/// restore_sql_atomic there, so a dump that fails halfway rolls the schema and
/// every row back. The old grouped behaviour (DDL autocommit + prefix replay) is
/// gone for PostgreSQL and is asserted for MySQL by the dbpilot-core unit tests.
#[tokio::test]
#[ignore = "requires DBPILOT_TEST_PG_* (PostgreSQL atomic restore)"]
async fn postgres_restore_is_atomic_and_a_failing_dump_leaves_nothing_behind() {
    if !common::postgres_usable().await {
        eprintln!("SKIP: DBPILOT_TEST_PG_* does not authenticate");
        return;
    }
    let spec = pg_spec();
    let Some(mut session) = pinned_session(&spec).await else {
        eprintln!("SKIP: cannot open a PostgreSQL session with DBPILOT_TEST_PG_*");
        return;
    };
    assert_eq!(session.driver_id(), "postgres");

    let schema = format!("rma_restore_tx_{}", std::process::id());
    let schema_sql = qi(DriverKind::Postgres, &schema);
    let table_sql = format!("{schema_sql}.{}", qi(DriverKind::Postgres, "items"));
    // Idempotent cleanup: a leftover from a previous failed run must not make
    // this run fail, and nothing outside our own schema is touched.
    run_ok(&mut *session, &format!("DROP SCHEMA IF EXISTS {schema_sql} CASCADE")).await;
    run_ok(&mut *session, &format!("CREATE SCHEMA {schema_sql}")).await;

    // -------- failing dump: DDL + 2 good INSERTs + 1 UNIQUE-violating INSERT +
    // 1 UPDATE after it. The whole dump is one transaction, so neither the table
    // nor the rows may survive.
    let script = format!(
        "CREATE TABLE {table_sql} (id INT PRIMARY KEY, code TEXT UNIQUE, qty INT);\n\
         INSERT INTO {table_sql} (id, code, qty) VALUES (1, 'a', 1);\n\
         INSERT INTO {table_sql} (id, code, qty) VALUES (2, 'b', 2);\n\
         INSERT INTO {table_sql} (id, code, qty) VALUES (2, 'dup', 9);\n\
         UPDATE {table_sql} SET qty = qty + 100;"
    );
    let report = dbpilot_core::ops::restore_sql_atomic(session.as_mut(), &script).await;

    assert!(report.atomic, "PostgreSQL restore must use the transaction path");
    assert!(report.rolled_back, "a failing dump must be rolled back");
    assert_eq!(report.total_statements, 5);
    assert_eq!(
        report.statements(),
        4,
        "results hold the executed statements only (CREATE + 2 INSERTs + failing INSERT)"
    );
    assert_eq!(report.failed(), 1, "only the duplicate INSERT fails");
    assert_eq!(
        report.skipped_statements(),
        1,
        "the UPDATE after the failure must not run"
    );
    assert_eq!(report.transaction_batches, 0);
    assert_eq!(report.statements_in_transactions, 0);
    let errors: Vec<&str> = report
        .results
        .iter()
        .filter_map(|result| result.error.as_deref())
        .collect();
    assert_eq!(errors.len(), 1);
    assert!(
        duplicate_message(errors[0]),
        "server message must be visible: {errors:?}"
    );

    // The rollback removed the table created earlier in the same dump.
    let absent = run_on(
        &mut *session,
        &format!("SELECT to_regclass('{schema}.items') IS NULL"),
    )
    .await;
    assert!(absent.error.is_none(), "{:?}", absent.error);
    assert_eq!(
        absent.rows,
        vec![vec![serde_json::json!(true)]],
        "the table must not exist after the atomic rollback: {:?}",
        absent.rows
    );

    // -------- successful dump: one transaction, data committed at the end.
    let script = format!(
        "CREATE TABLE {table_sql} (id INT PRIMARY KEY, code TEXT UNIQUE, qty INT);\n\
         INSERT INTO {table_sql} (id, code, qty) VALUES (1, 'a', 1);\n\
         INSERT INTO {table_sql} (id, code, qty) VALUES (2, 'b', 2);\n\
         UPDATE {table_sql} SET qty = qty + 100;"
    );
    let report = dbpilot_core::ops::restore_sql_atomic(session.as_mut(), &script).await;
    assert!(report.atomic);
    assert!(!report.rolled_back);
    assert_eq!(report.failed(), 0);
    assert_eq!(report.total_statements, 4);
    assert_eq!(report.statements(), 4);
    assert_eq!(report.skipped_statements(), 0);
    assert_eq!(report.transaction_batches, 1);
    assert_eq!(report.statements_in_transactions, 4);
    let rows = run_on(
        &mut *session,
        &format!("SELECT id, code, qty FROM {table_sql} ORDER BY id"),
    )
    .await;
    assert!(rows.error.is_none(), "{:?}", rows.error);
    assert_eq!(
        rows.rows,
        vec![
            vec![
                serde_json::json!(1),
                serde_json::json!("a"),
                serde_json::json!(101)
            ],
            vec![
                serde_json::json!(2),
                serde_json::json!("b"),
                serde_json::json!(102)
            ],
        ]
    );

    // Cleanup: only our own schema; release the pinned connection.
    let cleanup = run_on(
        &mut *session,
        &format!("DROP SCHEMA IF EXISTS {schema_sql} CASCADE"),
    )
    .await;
    assert!(cleanup.error.is_none(), "{:?}", cleanup.error);
    session.release().await;
}

/// SQLite has transactional DDL too, so the same atomic restore path is used
/// there. This one is hermetic (temp file, no server), so it runs in the normal
/// test suite: a dump that fails halfway must leave neither the table nor rows.
#[tokio::test]
async fn sqlite_restore_is_atomic_and_a_failing_dump_leaves_nothing_behind() {
    let dir = std::env::temp_dir().join(format!("rma-atomic-restore-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("create temp dir");
    let db = dir.join("atomic.sqlite");
    std::fs::write(&db, b"").expect("create empty database file");
    let spec = ConnSpec {
        driver: DriverKind::Sqlite,
        database: Some(db.to_string_lossy().to_string()),
        ..Default::default()
    };
    let driver = driver_for(DriverKind::Sqlite);
    let registry = PoolRegistry::default();
    let Ok(mut session) = driver.open_session(&registry, &spec, None).await else {
        eprintln!("SKIP: cannot open a SQLite session");
        let _ = std::fs::remove_dir_all(&dir);
        return;
    };

    // -------- failing dump: CREATE + good INSERT + duplicate PK INSERT.
    let report = dbpilot_core::ops::restore_sql_atomic(
        session.as_mut(),
        "CREATE TABLE t (id INTEGER PRIMARY KEY);
         INSERT INTO t VALUES (1);
         INSERT INTO t VALUES (1);",
    )
    .await;
    assert!(report.atomic, "SQLite must use the transaction path");
    assert!(report.rolled_back);
    assert_eq!(report.total_statements, 3);
    assert_eq!(report.statements(), 3, "CREATE + INSERT + failing INSERT");
    assert_eq!(report.failed(), 1);
    assert_eq!(report.skipped_statements(), 0);
    let tables = run_on(
        &mut *session,
        "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 't'",
    )
    .await;
    assert!(tables.error.is_none(), "{:?}", tables.error);
    assert_eq!(
        tables.rows,
        vec![vec![serde_json::json!(0)]],
        "the table must not exist after the atomic rollback"
    );

    // -------- successful dump: one transaction, both rows committed.
    let report = dbpilot_core::ops::restore_sql_atomic(
        session.as_mut(),
        "CREATE TABLE t (id INTEGER PRIMARY KEY);
         INSERT INTO t VALUES (1);
         INSERT INTO t VALUES (2);",
    )
    .await;
    assert!(report.atomic);
    assert!(!report.rolled_back);
    assert_eq!(report.failed(), 0);
    assert_eq!(report.transaction_batches, 1);
    assert_eq!(report.statements_in_transactions, 3);
    let rows = run_on(&mut *session, "SELECT id FROM t ORDER BY id").await;
    assert!(rows.error.is_none(), "{:?}", rows.error);
    assert_eq!(
        rows.rows,
        vec![vec![serde_json::json!(1)], vec![serde_json::json!(2)]]
    );

    session.release().await;
    let _ = std::fs::remove_dir_all(dir);
}
