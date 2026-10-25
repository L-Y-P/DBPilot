//! PostgreSQL transaction semantics of the two server-write paths.
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

/// restore_sql groups consecutive DML statements into one transaction, but it is
/// deliberately NOT atomic as a whole script:
///
/// * DDL / SET / USE statements are barriers that run in autocommit;
/// * a failed DML batch is rolled back, then its successful prefix is replayed
///   in autocommit mode and the statements after the failure still run (the
///   legacy "every statement is attempted exactly once" semantics documented in
///   dbpilot-core/src/ops.rs).
///
/// This test pins that current behaviour against a real PostgreSQL: the failure
/// is reported, the failing statement has no effect, but the table + prefix
/// INSERTs + post-failure UPDATE are still there. The task explicitly asks to
/// record the gap instead of changing product logic.
#[tokio::test]
#[ignore = "requires DBPILOT_TEST_PG_* (PostgreSQL restore transaction semantics)"]
async fn postgres_restore_sql_reports_the_failing_statement_and_is_not_atomic_as_a_whole() {
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

    // DDL barrier + 2 successful INSERTs + 1 UNIQUE-violating INSERT + 1 UPDATE.
    // The UPDATE sits after the failure so we can observe that later statements
    // still run.
    let script = format!(
        "CREATE TABLE {table_sql} (id INT PRIMARY KEY, code TEXT UNIQUE, qty INT);\n\
         INSERT INTO {table_sql} (id, code, qty) VALUES (1, 'a', 1);\n\
         INSERT INTO {table_sql} (id, code, qty) VALUES (2, 'b', 2);\n\
         INSERT INTO {table_sql} (id, code, qty) VALUES (2, 'dup', 9);\n\
         UPDATE {table_sql} SET qty = qty + 100;"
    );
    let report = dbpilot_core::ops::restore_sql(session.as_mut(), &script).await;

    assert_eq!(report.statements(), 5, "one result per dump statement");
    assert_eq!(report.failed(), 1, "only the duplicate INSERT fails");
    let errors: Vec<&str> = report
        .results
        .iter()
        .filter_map(|result| result.error.as_deref())
        .collect();
    assert_eq!(errors.len(), 1);
    let message = errors[0].to_ascii_lowercase();
    assert!(
        message.contains("duplicate key")
            || message.contains("unique")
            || message.contains("23505"),
        "server message must be visible: {errors:?}"
    );

    // Current behaviour, recorded rather than "fixed": the failed batch was
    // rolled back and its successful prefix replayed in autocommit, and the
    // UPDATE after the failure still ran, so the script is not atomic.
    let rows = run_on(
        &mut *session,
        &format!("SELECT id, code, qty FROM {table_sql} ORDER BY id"),
    )
    .await;
    assert!(rows.error.is_none(), "{:?}", rows.error);
    let rows = rows.rows;
    assert_eq!(
        rows,
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
        ],
        "prefix INSERTs replayed and the later UPDATE applied: {rows:?}"
    );
    // The failing statement itself left no trace.
    assert!(
        !rows
            .iter()
            .any(|row| row.get(1) == Some(&serde_json::json!("dup"))),
        "the failed INSERT must not be applied: {rows:?}"
    );
    // A failed batch never counts as a committed transaction group.
    assert_eq!(report.transaction_batches, 0);
    assert_eq!(report.statements_in_transactions, 0);

    // A fully successful run of consecutive DML statements: one BEGIN/COMMIT
    // group, and the diagnostics report it.
    let script = format!(
        "INSERT INTO {table_sql} (id, code, qty) VALUES (5, 'e', 5);\n\
         INSERT INTO {table_sql} (id, code, qty) VALUES (6, 'f', 6);\n\
         UPDATE {table_sql} SET qty = qty + 1 WHERE id IN (5, 6);"
    );
    let report = dbpilot_core::ops::restore_sql(session.as_mut(), &script).await;
    assert_eq!(report.failed(), 0);
    assert_eq!(
        report.transaction_batches, 1,
        "consecutive DML statements share one transaction"
    );
    assert_eq!(report.statements_in_transactions, 3);
    let rows = run_on(
        &mut *session,
        &format!("SELECT id, qty FROM {table_sql} WHERE id IN (5, 6) ORDER BY id"),
    )
    .await;
    assert!(rows.error.is_none(), "{:?}", rows.error);
    assert_eq!(
        rows.rows,
        vec![
            vec![serde_json::json!(5), serde_json::json!(6)],
            vec![serde_json::json!(6), serde_json::json!(7)],
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
