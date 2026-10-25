//! Batched row edits: `api::explorer::apply_row_changes`.
//!
//! The SQLite test runs the real transaction path offline. The MySQL test is
//! `#[ignore]`d (live server, `DBPILOT_TEST_MYSQL_*`), like the other live
//! suites:
//!
//!   cargo test --test apply_row_changes -- --ignored --test-threads=1
//!
//! The pure `change_row_sql` test needs neither a server nor app state: it pins
//! the shared SQL builder that `change_row` and the batch path both use.

use serde_json::{json, Map, Value};
use std::path::PathBuf;

use rust_myadmin_core::api;
use rust_myadmin_core::core::DriverKind;
use rust_myadmin_core::drivers::builtin::driver_for;
use rust_myadmin_core::drivers::qi;

mod common;

fn temp_dir(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("rma-apply-{}-{}", tag, std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("create temp dir");
    dir
}

async fn ok<T>(future: impl std::future::Future<Output = anyhow::Result<T>>) -> T {
    match future.await {
        Ok(value) => value,
        Err(error) => panic!("unexpected error: {error}"),
    }
}

fn obj(value: Value) -> Map<String, Value> {
    match value {
        Value::Object(map) => map,
        other => panic!("object expected, got {other}"),
    }
}

/// The batch path must not invent its own SQL: `change_row` and
/// `apply_row_changes` share [DatabaseDriver::change_row_sql], including the
/// `limit_one` narrowing (ctid / rowid / LIMIT 1) and the key/value validation.
#[test]
fn change_row_sql_is_the_shared_row_change_builder() {
    let sqlite = driver_for(DriverKind::Sqlite);
    let id = obj(json!({ "id": 1 }));
    let id_null = obj(json!({ "id": null }));
    let name = obj(json!({ "name": "Ada" }));
    let qty = obj(json!({ "qty": 2 }));

    // INSERT
    assert_eq!(
        sqlite
            .change_row_sql("main", "items", "insert", &Map::new(), &id, false)
            .unwrap(),
        r#"INSERT INTO "main"."items" ("id") VALUES (1)"#
    );
    // UPDATE
    assert_eq!(
        sqlite
            .change_row_sql("main", "items", "update", &id, &qty, false)
            .unwrap(),
        r#"UPDATE "main"."items" SET "qty" = 2 WHERE "id" = 1"#
    );
    // DELETE; a NULL key becomes IS NULL, exactly like change_row.
    assert_eq!(
        sqlite
            .change_row_sql("main", "items", "delete", &id, &Map::new(), false)
            .unwrap(),
        r#"DELETE FROM "main"."items" WHERE "id" = 1"#
    );
    assert_eq!(
        sqlite
            .change_row_sql("main", "items", "delete", &id_null, &Map::new(), false)
            .unwrap(),
        r#"DELETE FROM "main"."items" WHERE "id" IS NULL"#
    );

    // limit_one: SQLite/PostgreSQL narrow through the implicit row id, MySQL
    // appends LIMIT 1 (same as the single-row change_row path).
    assert_eq!(
        sqlite
            .change_row_sql("main", "items", "update", &name, &qty, true)
            .unwrap(),
        r#"UPDATE "main"."items" SET "qty" = 2 WHERE rowid = (SELECT rowid FROM "main"."items" WHERE "name" = 'Ada' LIMIT 1)"#
    );
    let postgres = driver_for(DriverKind::Postgres);
    assert_eq!(
        postgres
            .change_row_sql("public", "items", "update", &name, &qty, true)
            .unwrap(),
        r#"UPDATE "public"."items" SET "qty" = 2 WHERE ctid = (SELECT ctid FROM "public"."items" WHERE "name" = 'Ada' LIMIT 1)"#
    );
    let mysql = driver_for(DriverKind::Mysql);
    assert_eq!(
        mysql
            .change_row_sql("db", "items", "update", &name, &qty, true)
            .unwrap(),
        "UPDATE `db`.`items` SET `qty` = 2 WHERE `name` = 'Ada' LIMIT 1"
    );

    // Validation is the change_row one, not a copy.
    assert!(sqlite
        .change_row_sql("main", "items", "update", &Map::new(), &qty, false)
        .is_err());
    assert!(sqlite
        .change_row_sql("main", "items", "insert", &Map::new(), &Map::new(), false)
        .is_err());
    assert!(sqlite
        .change_row_sql("main", "items", "delete", &Map::new(), &Map::new(), false)
        .is_err());
    assert!(sqlite
        .change_row_sql("main", "items", "merge", &id, &qty, false)
        .is_err());
}

/// Run one SQL script through the console and return the first result set.
#[allow(deprecated)] // the JSON console shim is the simplest setup path for tests
async fn run(sql: &str) -> Value {
    let response = ok(api::query::run_query(json!({ "sql": sql }))).await;
    assert_eq!(response["failed"], json!(0), "sql failed: {response}");
    response["results"][0].clone()
}

/// A batch edit is one transaction: all rows commit together, and any server
/// error rolls the whole batch back (so the table is never half-edited).
#[tokio::test]
async fn sqlite_batch_edits_are_atomic() {
    let dir = temp_dir("sqlite");
    let db_file = dir.join("items.sqlite");
    std::fs::write(&db_file, b"").expect("create database file");
    let init = api::init_app(dir.to_string_lossy().to_string());
    assert_eq!(init.get("ok"), Some(&Value::Bool(true)), "init: {init}");

    let created = ok(api::connections::create_connection(json!({
        "name": "Apply SQLite",
        "driver": "sqlite",
        "database": db_file.to_string_lossy(),
    })))
    .await;
    let conn_id = created["connection"]["id"].as_str().unwrap().to_string();
    ok(api::connections::connect_connection(conn_id)).await;

    run("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT NOT NULL, qty INTEGER)").await;
    run("INSERT INTO items (id, name, qty) VALUES (1, 'one', 1), (2, 'two', 2), (3, 'three', 3)").await;

    // -------- array form: two updates, one insert and one delete in one batch
    let result = ok(api::explorer::apply_row_changes(
        "main".into(),
        "items".into(),
        json!([
            { "action": "update", "keys": { "id": 1 }, "values": { "name": "ONE", "qty": 10 } },
            { "action": "update", "keys": { "id": 2 }, "values": { "qty": 20 } },
            { "action": "insert", "values": { "id": 4, "name": "four", "qty": 40 } },
            { "action": "delete", "keys": { "id": 3 } },
        ]),
    ))
    .await;
    assert_eq!(result["ok"], json!(true), "{result}");
    assert_eq!(result["rows_affected"], json!(4), "{result}");
    assert_eq!(
        result["zero_row_results"],
        json!([]),
        "every change matched a row: {result}"
    );
    let results = result["results"].as_array().expect("per-row results");
    assert_eq!(results.len(), 4, "{result}");
    assert_eq!(results[0]["action"], json!("update"));
    assert_eq!(results[0]["rows_affected"], json!(1));
    assert_eq!(results[2]["action"], json!("insert"));
    assert_eq!(results[2]["last_insert_id"], json!(4), "{result}");
    assert_eq!(results[3]["action"], json!("delete"));
    // Indices let the page point at the exact dirty row that failed.
    for (index, item) in results.iter().enumerate() {
        assert_eq!(item["index"], json!(index));
    }
    let rows = run("SELECT id, name, qty FROM items ORDER BY id").await;
    assert_eq!(
        rows["rows"],
        json!([[1, "ONE", 10], [2, "two", 20], [4, "four", 40]]),
        "{rows}"
    );

    // -------- object form: {"changes": [...]} is the shape the Dart page sends
    let result = ok(api::explorer::apply_row_changes(
        "main".into(),
        "items".into(),
        json!({ "changes": [
            { "action": "update", "keys": { "id": 4 }, "values": { "qty": 41 } }
        ] }),
    ))
    .await;
    assert_eq!(result["rows_affected"], json!(1), "{result}");
    let rows = run("SELECT qty FROM items WHERE id = 4").await;
    assert_eq!(rows["rows"], json!([[41]]));

    // -------- a failing item rolls the whole transaction back
    let failed = api::explorer::apply_row_changes(
        "main".into(),
        "items".into(),
        json!([
            { "action": "update", "keys": { "id": 1 }, "values": { "name": "MUST ROLL BACK" } },
            { "action": "insert", "values": { "id": 1, "name": "duplicate", "qty": 0 } },
        ]),
    )
    .await
    .expect_err("duplicate primary key must fail the batch");
    let message = failed.to_string();
    assert!(message.contains("第 2 条"), "error must name the failing item: {message}");
    assert!(
        message.contains("UNIQUE") || message.contains("constraint"),
        "error must carry the server message: {message}"
    );
    let rows = run("SELECT id, name, qty FROM items ORDER BY id").await;
    assert_eq!(
        rows["rows"],
        json!([[1, "ONE", 10], [2, "two", 20], [4, "four", 41]]),
        "the first update must have been rolled back: {rows}"
    );

    // -------- zero-row diagnostics: a key matching nothing is reported, but the
    // batch still succeeds (not a failure, transaction unchanged). index stays
    // aligned with the incoming changes array and keys are echoed verbatim.
    let result = ok(api::explorer::apply_row_changes(
        "main".into(),
        "items".into(),
        json!([
            { "action": "update", "keys": { "id": 999 }, "values": { "qty": 0 } },
            { "action": "delete", "keys": { "id": 999 } },
            { "action": "update", "keys": { "id": 2 }, "values": { "qty": 21 } },
            { "action": "insert", "values": { "id": 5, "name": "five", "qty": 5 } },
        ]),
    ))
    .await;
    assert_eq!(result["ok"], json!(true), "{result}");
    assert_eq!(result["rows_affected"], json!(2), "{result}");
    let zero_rows = result["zero_row_results"]
        .as_array()
        .expect("zero_row_results array");
    assert_eq!(zero_rows.len(), 2, "{result}");
    assert_eq!(
        zero_rows[0],
        json!({ "index": 0, "action": "update", "keys": { "id": 999 } }),
        "{result}"
    );
    assert_eq!(
        zero_rows[1],
        json!({ "index": 1, "action": "delete", "keys": { "id": 999 } }),
        "{result}"
    );
    // The matched update committed; the zero-row items changed nothing.
    let rows = run("SELECT id, qty FROM items WHERE id IN (2, 999) ORDER BY id").await;
    assert_eq!(rows["rows"], json!([[2, 21]]), "{rows}");

    // -------- validation happens before BEGIN: a bad item changes nothing
    let invalid = api::explorer::apply_row_changes(
        "main".into(),
        "items".into(),
        json!([{ "action": "merge", "keys": { "id": 1 }, "values": { "qty": 0 } }]),
    )
    .await
    .expect_err("unknown action must be rejected");
    assert!(
        invalid.to_string().contains("unknown row action"),
        "{invalid}"
    );
    let rows = run("SELECT qty FROM items WHERE id = 1").await;
    assert_eq!(rows["rows"], json!([[10]]), "nothing may run: {rows}");

    // -------- empty batch is a no-op success
    let empty = ok(api::explorer::apply_row_changes(
        "main".into(),
        "items".into(),
        json!([]),
    ))
    .await;
    assert_eq!(empty["rows_affected"], json!(0), "{empty}");
    assert_eq!(empty["results"], json!([]), "{empty}");
    assert_eq!(empty["zero_row_results"], json!([]), "{empty}");

    // -------- limit_one: a key made of every column touches a single row
    run("CREATE TABLE dup (name TEXT, qty INTEGER)").await;
    run("INSERT INTO dup (name, qty) VALUES ('x', 1), ('x', 1)").await;
    let result = ok(api::explorer::apply_row_changes(
        "main".into(),
        "dup".into(),
        json!([{
            "action": "update",
            "keys": { "name": "x", "qty": 1 },
            "values": { "qty": 9 },
            "limit_one": true
        }]),
    ))
    .await;
    assert_eq!(result["rows_affected"], json!(1), "{result}");
    assert_eq!(result["zero_row_results"], json!([]), "{result}");
    let rows = run("SELECT qty FROM dup ORDER BY qty").await;
    assert_eq!(rows["rows"], json!([[1], [9]]), "{rows}");

    let _ = api::connections::disconnect().await;
    let _ = std::fs::remove_dir_all(dir);
}

fn mysql_body(name: &str, database: &str) -> Value {
    let endpoint = common::mysql();
    json!({
        "name": name,
        "driver": "mysql",
        "host": endpoint.host,
        "port": endpoint.port,
        "user": endpoint.user,
        "password": endpoint.password,
        "database": database,
    })
}

/// PostgreSQL 连接体：端点来自 DBPILOT_TEST_PG_*。
///
/// 不指定 database：PostgreSQL 会连到用户名同名的库（本机是 postgres），
/// 测试只用自己的临时 schema，不碰任何既有表。
fn pg_body(name: &str) -> Value {
    let endpoint = common::postgres();
    json!({
        "name": name,
        "driver": "postgres",
        "host": endpoint.host,
        "port": endpoint.port,
        "user": endpoint.user,
        "password": endpoint.password,
        "ssl_mode": "disable",
    })
}

/// Live MySQL variant (the first driver the batch path was written for).
#[tokio::test]
#[ignore = "requires DBPILOT_TEST_MYSQL_* (MySQL transaction/rollback)"]
async fn mysql_batch_edits_are_atomic() {
    if !common::mysql_usable().await {
        eprintln!("SKIP: DBPILOT_TEST_MYSQL_* does not authenticate");
        return;
    }
    let endpoint = common::mysql();
    let dir = temp_dir("mysql");
    let init = api::init_app(dir.to_string_lossy().to_string());
    assert_eq!(init.get("ok"), Some(&Value::Bool(true)), "init: {init}");

    let created = ok(api::connections::create_connection(mysql_body(
        "Apply MySQL",
        &endpoint.database,
    )))
    .await;
    let conn_id = created["connection"]["id"].as_str().unwrap().to_string();
    if let Err(error) = api::connections::connect_connection(conn_id).await {
        eprintln!(
            "SKIP: cannot open MySQL database '{}': {error}",
            endpoint.database
        );
        return;
    }

    let table = format!("rma_apply_row_changes_{}", std::process::id());
    run(&format!("DROP TABLE IF EXISTS `{table}`")).await;
    run(&format!(
        "CREATE TABLE `{table}` (id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(32) NOT NULL, qty INT)"
    ))
    .await;
    run(&format!(
        "INSERT INTO `{table}` (id, name, qty) VALUES (1, 'one', 1), (2, 'two', 2)"
    ))
    .await;

    let result = ok(api::explorer::apply_row_changes(
        endpoint.database.clone(),
        table.clone(),
        json!([
            { "action": "update", "keys": { "id": 1 }, "values": { "name": "ONE", "qty": 10 } },
            { "action": "insert", "values": { "name": "three", "qty": 30 } },
        ]),
    ))
    .await;
    assert_eq!(result["rows_affected"], json!(2), "{result}");
    // The AUTO_INCREMENT id comes from the same pinned connection inside the
    // transaction; LAST_INSERT_ID() is per connection, so a pooled one-statement
    // round trip would have reported 0 here.
    assert_eq!(result["results"][1]["last_insert_id"], json!(3), "{result}");
    let rows = run(&format!(
        "SELECT id, name, qty FROM `{table}` ORDER BY id"
    ))
    .await;
    assert_eq!(
        rows["rows"],
        json!([[1, "ONE", 10], [2, "two", 2], [3, "three", 30]])
    );

    // A duplicate key must roll the earlier update back.
    let failed = api::explorer::apply_row_changes(
        endpoint.database.clone(),
        table.clone(),
        json!([
            { "action": "update", "keys": { "id": 2 }, "values": { "name": "ROLL ME BACK" } },
            { "action": "insert", "values": { "id": 1, "name": "dup", "qty": 0 } },
        ]),
    )
    .await
    .expect_err("duplicate primary key must fail the batch");
    assert!(
        failed.to_string().contains("第 2 条"),
        "error must name the failing item: {failed}"
    );
    let rows = run(&format!(
        "SELECT name FROM `{table}` WHERE id = 2"
    ))
    .await;
    assert_eq!(rows["rows"], json!([["two"]]), "rolled back: {rows}");

    run(&format!("DROP TABLE `{table}`")).await;
    let _ = api::connections::disconnect().await;
    let _ = std::fs::remove_dir_all(dir);
}

/// Live PostgreSQL variant: the batch path must be one transaction there too.
///
/// The failing item is an UPDATE that violates a UNIQUE constraint (the task's
/// "1 valid UPDATE + 1 failing UPDATE" shape): the first UPDATE sets a value the
/// second one would collide with, so PostgreSQL rejects the second and the whole
/// batch must roll back — including the first UPDATE.
#[tokio::test]
#[ignore = "requires DBPILOT_TEST_PG_* (PostgreSQL transaction/rollback)"]
async fn postgres_batch_edits_are_atomic() {
    if !common::postgres_usable().await {
        eprintln!("SKIP: DBPILOT_TEST_PG_* does not authenticate");
        return;
    }
    let dir = temp_dir("postgres");
    let init = api::init_app(dir.to_string_lossy().to_string());
    assert_eq!(init.get("ok"), Some(&Value::Bool(true)), "init: {init}");

    let created = ok(api::connections::create_connection(pg_body(
        "Apply PostgreSQL",
    )))
    .await;
    let conn_id = created["connection"]["id"].as_str().unwrap().to_string();
    if let Err(error) = api::connections::connect_connection(conn_id).await {
        eprintln!("SKIP: cannot open a PostgreSQL connection: {error}");
        let _ = std::fs::remove_dir_all(&dir);
        return;
    }

    // 独立 schema：只动自己建的东西，结束时 DROP SCHEMA ... CASCADE。
    let schema = format!("rma_apply_tx_{}", std::process::id());
    let schema_sql = qi(DriverKind::Postgres, &schema);
    let table_sql = format!("{schema_sql}.{}", qi(DriverKind::Postgres, "items"));
    run(&format!("DROP SCHEMA IF EXISTS {schema_sql} CASCADE")).await;
    run(&format!("CREATE SCHEMA {schema_sql}")).await;
    run(&format!(
        "CREATE TABLE {table_sql} (id INT PRIMARY KEY, code TEXT NOT NULL UNIQUE, qty INT)"
    ))
    .await;
    run(&format!(
        "INSERT INTO {table_sql} (id, code, qty) VALUES (1, 'one', 1), (2, 'two', 2)"
    ))
    .await;

    // -------- all-valid batch: commits and the data really is there
    let done = ok(api::explorer::apply_row_changes(
        schema.clone(),
        "items".into(),
        json!([
            { "action": "update", "keys": { "id": 1 }, "values": { "code": "ONE", "qty": 10 } },
            { "action": "update", "keys": { "id": 2 }, "values": { "qty": 20 } },
            { "action": "insert", "values": { "id": 3, "code": "three", "qty": 30 } },
        ]),
    ))
    .await;
    assert_eq!(done["ok"], json!(true), "{done}");
    assert_eq!(done["rows_affected"], json!(3), "{done}");
    let rows = run(&format!(
        "SELECT id, code, qty FROM {table_sql} ORDER BY id"
    ))
    .await;
    assert_eq!(
        rows["rows"],
        json!([[1, "ONE", 10], [2, "two", 20], [3, "three", 30]]),
        "{rows}"
    );

    // -------- mixed batch: 1 valid UPDATE, then 1 UPDATE violating UNIQUE.
    // One transaction, so the valid UPDATE must be rolled back too.
    let failed = api::explorer::apply_row_changes(
        schema.clone(),
        "items".into(),
        json!([
            { "action": "update", "keys": { "id": 1 }, "values": { "code": "MUST ROLL BACK" } },
            { "action": "update", "keys": { "id": 2 }, "values": { "code": "MUST ROLL BACK" } },
        ]),
    )
    .await
    .expect_err("unique violation must fail the whole batch");
    let message = failed.to_string();
    assert!(
        message.contains("第 2 条"),
        "error must name the failing item: {message}"
    );
    let lower = message.to_ascii_lowercase();
    assert!(
        lower.contains("duplicate key") || lower.contains("unique") || lower.contains("23505"),
        "error must carry the server message: {message}"
    );
    let rows = run(&format!(
        "SELECT id, code FROM {table_sql} WHERE id IN (1, 2) ORDER BY id"
    ))
    .await;
    assert_eq!(
        rows["rows"],
        json!([[1, "ONE"], [2, "two"]]),
        "the valid UPDATE must have been rolled back: {rows}"
    );

    // -------- cleanup: only our own schema, then disconnect.
    run(&format!("DROP SCHEMA IF EXISTS {schema_sql} CASCADE")).await;
    let _ = api::connections::disconnect().await;
    let _ = std::fs::remove_dir_all(dir);
}
