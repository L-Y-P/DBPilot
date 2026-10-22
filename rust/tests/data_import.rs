//! End-to-end tests for the guided data-file import and the streaming SQL-file
//! runner (both live on api::data_import + importer).
//!
//! They use a throwaway SQLite database, so no server is required. The same
//! code path is used by MySQL/PostgreSQL: rules -> parse -> convert -> batched
//! INSERT.

use std::time::Duration;

use rust_myadmin_core::api;
use serde_json::{json, Value};

async fn run(sql: &str) -> Value {
    api::query::run_query(json!({ "sql": sql })).await.unwrap()
}

async fn wait_job(job_id: &str) -> Value {
    for _ in 0..600 {
        let status = api::data_import::import_job_status(job_id.to_string()).unwrap();
        if status["done"].as_bool().unwrap_or(false) {
            return status;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    panic!("job {job_id} did not finish");
}

fn write_file(root: &std::path::Path, name: &str, content: &str) -> String {
    let path = root.join(name);
    std::fs::write(&path, content).unwrap();
    path.to_string_lossy().to_string()
}

fn mapping(columns: &[(&str, Value)]) -> Value {
    let columns: Vec<Value> = columns
        .iter()
        .map(|(column, source)| json!({ "column": column, "source": source }))
        .collect();
    json!({
        "columns": columns,
        "ignore_unknown": true,
        "empty_as_null": false,
        "null_tokens": ["\\N"],
        "trim_values": true
    })
}

#[tokio::test]
async fn guided_import_and_sql_file_runner() {
    let root = std::env::temp_dir().join(format!("rma-import-test-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&root).unwrap();
    let db_file = root.join("main.sqlite");
    std::fs::write(&db_file, []).unwrap();
    let initialized = api::init_app(root.join("app").to_string_lossy().into());
    assert_eq!(initialized["ok"], json!(true), "{}", initialized);
    let made = api::connections::create_connection(json!({
        "name": "Import test",
        "driver": "sqlite",
        "database": db_file.to_string_lossy(),
    }))
    .await
    .unwrap();
    api::connections::connect_connection(
        made["connection"]["id"].as_str().unwrap().to_string(),
    )
    .await
    .unwrap();
    let setup = run(
        "CREATE TABLE people(id INTEGER PRIMARY KEY, name TEXT, age INTEGER, note TEXT);",
    )
    .await;
    assert!(setup["results"][0]["error"].is_null(), "{}", setup);

    // ---------------------------------------------------------- CSV + header
    let csv = write_file(
        &root,
        "people.csv",
        "id,name,age,note\n1,Ada,36,\n2,Bob,41,\"hi, there\"\n3,Cy,29,\n4,Di,notanumber,\n",
    );

    let info = api::data_import::import_inspect(csv.clone()).await.unwrap();
    assert_eq!(info["format"], json!("delimited"));
    assert_eq!(info["fields"]["header"], json!(true));
    let preview = api::data_import::import_preview(
        csv.clone(),
        json!({ "read": info["read"], "fields": info["fields"], "limit": 3 }),
    )
    .await
    .unwrap();
    assert_eq!(preview["header"], json!(["id", "name", "age", "note"]));
    assert_eq!(preview["records"].as_array().unwrap().len(), 3);
    // records[0] is the header, records[1] row 1, records[2] row 2.
    assert_eq!(preview["records"][2]["values"][3], json!("hi, there"));

    // Read-rule validation: the file splits cleanly.
    let start = api::data_import::import_validate_start(json!({
        "path": csv,
        "read": info["read"],
        "fields": info["fields"],
    }))
    .await
    .unwrap();
    let job = wait_job(start["job_id"].as_str().unwrap()).await;
    assert_eq!(job["state"], json!("done"), "{}", job);
    assert_eq!(job["result"]["invalid"], json!(0), "{}", job);
    assert_eq!(job["result"]["data_records"], json!(4), "{}", job);

    // Field validation with the mapping catches the bad number and names the
    // line.
    let csv_mapping = mapping(&[
        ("id", json!("id")),
        ("name", json!("name")),
        ("age", json!("age")),
        ("note", json!("note")),
    ]);
    let start = api::data_import::import_validate_start(json!({
        "path": csv,
        "read": info["read"],
        "fields": info["fields"],
        "mapping": csv_mapping,
        "database": "main",
        "table": "people",
    }))
    .await
    .unwrap();
    let job = wait_job(start["job_id"].as_str().unwrap()).await;
    assert_eq!(job["result"]["invalid"], json!(1), "{}", job);
    let issue = &job["result"]["issues"][0];
    assert_eq!(issue["line"], json!(5), "{}", job);
    assert!(
        issue["message"].as_str().unwrap().contains("整数"),
        "{}",
        job
    );

    // Probe: the first row is inserted and rolled back.
    let probe = api::data_import::import_probe(
        "main".into(),
        "people".into(),
        json!({
            "path": csv,
            "read": info["read"],
            "fields": info["fields"],
            "mapping": csv_mapping,
        }),
    )
    .await
    .unwrap();
    assert_eq!(probe["affected"], json!(1), "{}", probe);
    assert_eq!(probe["row"]["name"], json!("Ada"), "{}", probe);
    assert!(probe["insert_sql"]
        .as_str()
        .unwrap()
        .contains("INSERT INTO"));
    let count = run("SELECT COUNT(*) AS c FROM people;").await;
    assert_eq!(count["results"][0]["rows"][0][0], json!(0), "probe must roll back");

    // Real import in skip mode: 3 rows inserted, the bad one reported.
    let start = api::data_import::import_execute_start(json!({
        "path": csv,
        "read": info["read"],
        "fields": info["fields"],
        "mapping": csv_mapping,
        "database": "main",
        "table": "people",
        "options": { "batch_size": 2, "on_error": "skip", "max_issues": 10 },
    }))
    .await
    .unwrap();
    let job = wait_job(start["job_id"].as_str().unwrap()).await;
    assert_eq!(job["state"], json!("done"), "{}", job);
    assert_eq!(job["result"]["rows_inserted"], json!(3), "{}", job);
    assert_eq!(job["result"]["rows_failed"], json!(1), "{}", job);
    assert_eq!(job["result"]["issues"][0]["line"], json!(5), "{}", job);
    let count = run("SELECT COUNT(*) AS c FROM people;").await;
    assert_eq!(count["results"][0]["rows"][0][0], json!(3));

    // ------------------------------------------------- pending batch is flushed
    run("DELETE FROM people;").await;
    let big = write_file(
        &root,
        "big.csv",
        "id,name,age,note\n1,Ada,36,\n2,Bob,41,\n3,Cy,29,\n",
    );
    let info = api::data_import::import_inspect(big.clone()).await.unwrap();
    let start = api::data_import::import_execute_start(json!({
        "path": big,
        "read": info["read"],
        "fields": info["fields"],
        "mapping": mapping(&[
            ("id", json!("id")),
            ("name", json!("name")),
            ("age", json!("age")),
            ("note", json!("note")),
        ]),
        "database": "main",
        "table": "people",
        "options": { "batch_size": 100, "on_error": "stop" },
    }))
    .await
    .unwrap();
    let job = wait_job(start["job_id"].as_str().unwrap()).await;
    assert_eq!(job["result"]["rows_inserted"], json!(3), "{}", job);
    let count = run("SELECT COUNT(*) AS c FROM people;").await;
    assert_eq!(count["results"][0]["rows"][0][0], json!(3));

    // ------------------------------------------------- JSON array, keyed records
    run("CREATE TABLE items(id INTEGER, title TEXT, payload TEXT);").await;
    let json_file = write_file(
        &root,
        "items.json",
        "[\n  {\"id\": 1, \"title\": \"first\", \"payload\": {\"a\": 1}},\n  \
         {\"id\": 2, \"title\": \"second\", \"payload\": {\"b\": [1, 2]}}\n]\n",
    );
    let info = api::data_import::import_inspect(json_file.clone()).await.unwrap();
    assert_eq!(info["format"], json!("json_array"));
    let preview = api::data_import::import_preview(
        json_file.clone(),
        json!({ "read": info["read"], "fields": info["fields"], "limit": 5 }),
    )
    .await
    .unwrap();
    assert_eq!(preview["records"].as_array().unwrap().len(), 2, "{}", preview);
    assert_eq!(preview["records"][0]["kind"], json!("object"));
    let start = api::data_import::import_execute_start(json!({
        "path": json_file,
        "read": info["read"],
        "fields": info["fields"],
        "mapping": mapping(&[
            ("id", json!("id")),
            ("title", json!("title")),
            ("payload", json!("payload")),
        ]),
        "database": "main",
        "table": "items",
        "options": { "batch_size": 100, "on_error": "stop" },
    }))
    .await
    .unwrap();
    let job = wait_job(start["job_id"].as_str().unwrap()).await;
    assert_eq!(job["result"]["rows_inserted"], json!(2), "{}", job);
    let items = run("SELECT id, title, payload FROM items ORDER BY id;").await;
    assert_eq!(items["results"][0]["rows"][0][1], json!("first"));
    assert!(
        items["results"][0]["rows"][0][2]
            .as_str()
            .unwrap()
            .contains("\"a\""),
        "{}",
        items
    );

    // ------------------------------------------------- SQL file, streaming runner
    let sql_file = write_file(
        &root,
        "script.sql",
        "-- comment\nCREATE TABLE colors(name TEXT);\n\
         INSERT INTO colors VALUES ('red'), ('green');\n\
         INSERT INTO colors VALUES ('blue');\n",
    );
    let start = api::data_import::sql_file_execute_start(
        "main".into(),
        sql_file.clone(),
        json!({ "on_error": "stop" }),
    )
    .await
    .unwrap();
    let job = wait_job(start["job_id"].as_str().unwrap()).await;
    assert_eq!(job["state"], json!("done"), "{}", job);
    assert_eq!(job["result"]["statements"], json!(3), "{}", job);
    assert_eq!(job["result"]["succeeded"], json!(3), "{}", job);
    let colors = run("SELECT COUNT(*) AS c FROM colors;").await;
    assert_eq!(colors["results"][0]["rows"][0][0], json!(3));

    // A failing statement stops the run and names the line.
    let bad_sql = write_file(
        &root,
        "bad.sql",
        "INSERT INTO colors VALUES ('ok');\nINSERT INTO missing_table VALUES (1);\n\
         INSERT INTO colors VALUES ('never');\n",
    );
    let start = api::data_import::sql_file_execute_start(
        "main".into(),
        bad_sql,
        json!({ "on_error": "stop" }),
    )
    .await
    .unwrap();
    let job = wait_job(start["job_id"].as_str().unwrap()).await;
    assert_eq!(job["result"]["stopped"], json!(true), "{}", job);
    assert_eq!(job["result"]["issues"][0]["line"], json!(2), "{}", job);
    let colors = run("SELECT COUNT(*) AS c FROM colors;").await;
    assert_eq!(colors["results"][0]["rows"][0][0], json!(4));

    // ------------------------------------------- large CSV streams in batches
    run("CREATE TABLE big(id INTEGER, name TEXT);").await;
    let mut big = String::from("id,name\n");
    for i in 0..20000 {
        big.push_str(&format!("{},row{}\n", i, i));
    }
    let big_path = write_file(&root, "big.csv", &big);
    let info = api::data_import::import_inspect(big_path.clone()).await.unwrap();
    let start = api::data_import::import_execute_start(json!({
        "path": big_path,
        "read": info["read"],
        "fields": info["fields"],
        "mapping": mapping(&[("id", json!("id")), ("name", json!("name"))]),
        "database": "main",
        "table": "big",
        "options": { "batch_size": 500, "on_error": "stop" },
    }))
    .await
    .unwrap();
    let job = wait_job(start["job_id"].as_str().unwrap()).await;
    assert_eq!(job["state"], json!("done"), "{}", job);
    assert_eq!(job["result"]["rows_inserted"], json!(20000), "{}", job);
    assert_eq!(job["result"]["batches"], json!(40), "{}", job);
    let count = run("SELECT COUNT(*) AS c FROM big;").await;
    assert_eq!(count["results"][0]["rows"][0][0], json!(20000));

    // ----------------------------------------------- USE is not SQLite syntax
    let use_attempt = api::query::run_query(json!({ "sql": "USE main; SELECT 1" }))
        .await
        .unwrap();
    let use_results = use_attempt["results"].as_array().unwrap();
    assert_eq!(use_results.len(), 1, "{}", use_attempt);
    assert!(
        use_results[0]["error"]
            .as_str()
            .unwrap()
            .contains("SQLite 没有 USE"),
        "{}",
        use_attempt
    );

    // ------------------------------------------------- bounded SQL file preview
    let preview = api::data_import::sql_file_preview(sql_file, Some(16))
        .await
        .unwrap();
    assert_eq!(preview["truncated"], json!(true), "{}", preview);
    assert!(preview["text"].as_str().unwrap().len() <= 16);

    api::connections::disconnect().await.unwrap();
    std::fs::remove_dir_all(&root).unwrap();
}
