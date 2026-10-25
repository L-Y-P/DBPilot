//! Differential test: the P0 fast delimited CSV path must produce exactly the
//! same rows / errors as the original generic path.
//!
//! The generic path is forced with DBPILOT_IMPORT_LEGACY=1.  Both imports run in
//! one process, so this test lives in its own integration-test binary (no other
//! test can observe the environment variable).

use std::time::Duration;

use rust_myadmin_core::api;
use serde_json::{json, Value};

async fn run(sql: &str) -> Value {
    api::query::run_query(json!({ "sql": sql }))
        .await
        .unwrap_or_else(|error| panic!("query failed: {error}\n{sql}"))
}

async fn wait_job(job_id: &str) -> Value {
    for _ in 0..1200 {
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

fn mapping(source_names: &[&str]) -> Value {
    let columns: Vec<Value> = source_names
        .iter()
        .map(|name| json!({ "column": name, "source": name }))
        .collect();
    json!({
        "columns": columns,
        "ignore_unknown": true,
        "empty_as_null": false,
        "null_tokens": ["\\N"],
        "trim_values": true
    })
}

fn positional_mapping(columns: &[&str]) -> Value {
    let columns: Vec<Value> = columns
        .iter()
        .enumerate()
        .map(|(index, name)| json!({ "column": name, "source": index }))
        .collect();
    json!({
        "columns": columns,
        "ignore_unknown": true,
        "empty_as_null": false,
        "null_tokens": ["\\N"],
        "trim_values": true
    })
}

async fn import_into(
    csv: &str,
    info: &Value,
    table: &str,
    mapping: &Value,
    options: Value,
    legacy: bool,
) -> Value {
    if legacy {
        std::env::set_var("DBPILOT_IMPORT_LEGACY", "1");
    } else {
        std::env::remove_var("DBPILOT_IMPORT_LEGACY");
    }
    let start = api::data_import::import_execute_start(json!({
        "path": csv,
        "read": info["read"],
        "fields": info["fields"],
        "mapping": mapping,
        "database": "main",
        "table": table,
        "options": options,
    }))
    .await
    .unwrap();
    let job = wait_job(start["job_id"].as_str().unwrap()).await;
    std::env::remove_var("DBPILOT_IMPORT_LEGACY");
    job
}

async fn table_rows(table: &str, columns: &str) -> Value {
    let result = run(&format!("SELECT {columns} FROM {table} ORDER BY id")).await;
    assert!(result["results"][0]["error"].is_null(), "{result}");
    result["results"][0]["rows"].clone()
}

#[tokio::test]
async fn fast_csv_path_matches_legacy_rows_and_errors() {
    let root = std::env::temp_dir().join(format!("rma-fast-import-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&root).unwrap();
    let db_file = root.join("main.sqlite");
    std::fs::write(&db_file, []).unwrap();
    let initialized = api::init_app(root.join("app").to_string_lossy().into());
    assert_eq!(initialized["ok"], json!(true), "{initialized}");
    let made = api::connections::create_connection(json!({
        "name": "Fast import test",
        "driver": "sqlite",
        "database": db_file.to_string_lossy(),
    }))
    .await
    .unwrap();
    api::connections::connect_connection(made["connection"]["id"].as_str().unwrap().to_string())
        .await
        .unwrap();

    let ddl = "CREATE TABLE {table}(id INTEGER PRIMARY KEY, name TEXT, age INTEGER, score REAL, note TEXT);";
    for table in ["t_fast", "t_legacy"] {
        let result = run(&ddl.replace("{table}", table)).await;
        assert!(result["results"][0]["error"].is_null(), "{result}");
    }

    // Header + 7 rows covering: quoted comma, doubled quote, embedded newline,
    // negative int, underscore decimal, NULL token, empty string, unicode, a
    // backslash, a 70 KB field that crosses the 64 KiB scanner buffer, and
    // enough rows to span several batches (batch_size = 2).
    let long_note = "x".repeat(70_000);
    let csv_content = format!(
        "id,name,age,score,note\n\
         1,Ada,36,9.5,hello\n\
         2,\"Bob, Jr.\",41,10.25,\"line1\nline2\"\n\
         3,\"quote\"\" inside\",-5,1_234.50,\\N\n\
         4,中文名字,0,1,\n\
         5,\"back\\slash\",7,2.5,\"a\"\"b\"\n\
         6,🙂 emoji,8,3.75,\n\
         7,Long,9,4.5,{long_note}\n"
    );
    let csv = write_file(&root, "tricky.csv", &csv_content);
    let info = api::data_import::import_inspect(csv.clone()).await.unwrap();
    assert_eq!(info["format"], json!("delimited"), "{info}");
    assert_eq!(info["fields"]["header"], json!(true), "{info}");
    let map = mapping(&["id", "name", "age", "score", "note"]);
    let options = json!({ "batch_size": 2, "on_error": "stop", "max_issues": 10 });

    let fast = import_into(&csv, &info, "t_fast", &map, options.clone(), false).await;
    let legacy = import_into(&csv, &info, "t_legacy", &map, options, true).await;
    assert_eq!(fast["state"], json!("done"), "{fast}");
    assert_eq!(legacy["state"], json!("done"), "{legacy}");
    assert_eq!(fast["result"]["rows_inserted"], json!(7), "{fast}");
    assert_eq!(legacy["result"]["rows_inserted"], json!(7), "{legacy}");
    assert_eq!(fast["result"]["rows_failed"], json!(0), "{fast}");
    assert_eq!(fast["result"]["issues"], json!([]), "{fast}");

    let columns = "id, name, age, score, note";
    let fast_rows = table_rows("t_fast", columns).await;
    let legacy_rows = table_rows("t_legacy", columns).await;
    assert_eq!(fast_rows, legacy_rows, "fast vs legacy rows differ");
    assert_eq!(fast_rows.as_array().unwrap().len(), 7);
    // Spot-check the tricky values in the fast result too.
    assert_eq!(fast_rows[1][1], json!("Bob, Jr."));
    assert_eq!(fast_rows[1][4], json!("line1\nline2"));
    assert_eq!(fast_rows[2][1], json!("quote\" inside"));
    assert_eq!(fast_rows[2][4], Value::Null);
    assert_eq!(fast_rows[3][1], json!("中文名字"));
    assert_eq!(fast_rows[3][4], json!(""));
    assert_eq!(fast_rows[4][1], json!("back\\slash"));
    assert_eq!(fast_rows[6][4].as_str().unwrap().len(), 70_000);

    // ------------------------------------------------ error handling: skip mode
    for table in ["e_fast", "e_legacy"] {
        let result = run(&format!(
            "CREATE TABLE {table}(id INTEGER PRIMARY KEY, name TEXT, age INTEGER);"
        ))
        .await;
        assert!(result["results"][0]["error"].is_null(), "{result}");
    }
    let bad_csv = write_file(
        &root,
        "errors.csv",
        "id,name,age\n1,Ada,36\n2,Bob,notanumber\n3,Cy,29\n",
    );
    let bad_info = api::data_import::import_inspect(bad_csv.clone())
        .await
        .unwrap();
    let bad_map = mapping(&["id", "name", "age"]);
    let mut skip_options = json!({ "batch_size": 2, "on_error": "skip", "max_issues": 10 });
    let fast_skip = import_into(
        &bad_csv,
        &bad_info,
        "e_fast",
        &bad_map,
        skip_options.clone(),
        false,
    )
    .await;
    let legacy_skip = import_into(
        &bad_csv,
        &bad_info,
        "e_legacy",
        &bad_map,
        skip_options.clone(),
        true,
    )
    .await;
    for key in ["rows_inserted", "rows_failed", "stopped", "ok"] {
        assert_eq!(
            fast_skip["result"][key], legacy_skip["result"][key],
            "skip mode key {key}: fast={fast_skip} legacy={legacy_skip}"
        );
    }
    assert_eq!(
        fast_skip["result"]["rows_inserted"],
        json!(2),
        "{fast_skip}"
    );
    assert_eq!(
        fast_skip["result"]["issues"],
        legacy_skip["result"]["issues"]
    );
    assert_eq!(
        table_rows("e_fast", "id, name, age").await,
        table_rows("e_legacy", "id, name, age").await
    );

    // ------------------------------------------------ error handling: stop mode
    for table in ["s_fast", "s_legacy"] {
        let result = run(&format!(
            "CREATE TABLE {table}(id INTEGER PRIMARY KEY, name TEXT, age INTEGER);"
        ))
        .await;
        assert!(result["results"][0]["error"].is_null(), "{result}");
    }
    skip_options["on_error"] = json!("stop");
    let fast_stop = import_into(
        &bad_csv,
        &bad_info,
        "s_fast",
        &bad_map,
        skip_options.clone(),
        false,
    )
    .await;
    let legacy_stop = import_into(
        &bad_csv,
        &bad_info,
        "s_legacy",
        &bad_map,
        skip_options,
        true,
    )
    .await;
    for key in ["rows_inserted", "rows_failed", "stopped", "ok", "message"] {
        assert_eq!(
            fast_stop["result"][key], legacy_stop["result"][key],
            "stop mode key {key}: fast={fast_stop} legacy={legacy_stop}"
        );
    }
    assert_eq!(
        fast_stop["result"]["issues"],
        legacy_stop["result"]["issues"]
    );
    assert_eq!(
        table_rows("s_fast", "id, name, age").await,
        table_rows("s_legacy", "id, name, age").await
    );

    // ------------------------------------- no header + positional mapping path
    for table in ["p_fast", "p_legacy"] {
        let result = run(&format!(
            "CREATE TABLE {table}(id INTEGER PRIMARY KEY, name TEXT, age INTEGER);"
        ))
        .await;
        assert!(result["results"][0]["error"].is_null(), "{result}");
    }
    let no_header_csv = write_file(
        &root,
        "no_header.csv",
        "10,Ann,30\n11,\"D, E\",31\n12,\\N,32\n",
    );
    let no_header_info = api::data_import::import_inspect(no_header_csv.clone())
        .await
        .unwrap();
    assert_eq!(
        no_header_info["fields"]["header"],
        json!(false),
        "{no_header_info}"
    );
    let positional = positional_mapping(&["id", "name", "age"]);
    let fast_no_header = import_into(
        &no_header_csv,
        &no_header_info,
        "p_fast",
        &positional,
        json!({ "batch_size": 2, "on_error": "stop", "max_issues": 10 }),
        false,
    )
    .await;
    let legacy_no_header = import_into(
        &no_header_csv,
        &no_header_info,
        "p_legacy",
        &positional,
        json!({ "batch_size": 2, "on_error": "stop", "max_issues": 10 }),
        true,
    )
    .await;
    assert_eq!(
        fast_no_header["result"]["rows_inserted"], legacy_no_header["result"]["rows_inserted"],
        "fast={fast_no_header} legacy={legacy_no_header}"
    );
    assert_eq!(
        table_rows("p_fast", "id, name, age").await,
        table_rows("p_legacy", "id, name, age").await
    );
    assert_eq!(fast_no_header["result"]["rows_inserted"], json!(3));

    // ------------------------------- P1: grouped transactions keep row semantics
    for table in ["g_fast", "g_legacy"] {
        let result = run(&format!(
            "CREATE TABLE {table}(id INTEGER PRIMARY KEY, name TEXT, age INTEGER, score REAL, note TEXT);"
        ))
        .await;
        assert!(result["results"][0]["error"].is_null(), "{result}");
    }
    let fast_grouped = import_into(
        &csv,
        &info,
        "g_fast",
        &map,
        json!({ "batch_size": 2, "on_error": "stop", "max_issues": 10, "transaction_batches": 4 }),
        false,
    )
    .await;
    let legacy_single = import_into(
        &csv,
        &info,
        "g_legacy",
        &map,
        json!({ "batch_size": 2, "on_error": "stop", "max_issues": 10 }),
        true,
    )
    .await;
    assert_eq!(fast_grouped["state"], json!("done"), "{fast_grouped}");
    assert_eq!(
        fast_grouped["result"]["rows_inserted"], legacy_single["result"]["rows_inserted"],
        "{fast_grouped}"
    );
    assert_eq!(
        table_rows("g_fast", columns).await,
        table_rows("g_legacy", columns).await
    );

    // A grouped transaction that hits a bad batch must roll back and replay so
    // that earlier batches stay committed, exactly like the autocommit path.
    for table in ["gs_fast", "gs_legacy"] {
        let result = run(&format!(
            "CREATE TABLE {table}(id INTEGER PRIMARY KEY, name TEXT, age INTEGER);"
        ))
        .await;
        assert!(result["results"][0]["error"].is_null(), "{result}");
    }
    let mut grouped_stop = json!({
        "batch_size": 1,
        "on_error": "stop",
        "max_issues": 10,
        "transaction_batches": 4,
    });
    let fast_grouped_stop = import_into(
        &bad_csv,
        &bad_info,
        "gs_fast",
        &bad_map,
        grouped_stop.clone(),
        false,
    )
    .await;
    grouped_stop["transaction_batches"] = json!(1);
    let legacy_grouped_stop = import_into(
        &bad_csv,
        &bad_info,
        "gs_legacy",
        &bad_map,
        grouped_stop,
        true,
    )
    .await;
    for key in ["rows_inserted", "rows_failed", "stopped", "ok", "message"] {
        assert_eq!(
            fast_grouped_stop["result"][key], legacy_grouped_stop["result"][key],
            "grouped stop key {key}: fast={fast_grouped_stop} legacy={legacy_grouped_stop}"
        );
    }
    assert_eq!(
        table_rows("gs_fast", "id, name, age").await,
        table_rows("gs_legacy", "id, name, age").await
    );

    // ------------------------------- P3: bounded pipeline (capacity 2 and 4)
    for table in ["pl2_fast", "pl2_legacy", "pl4_fast", "pl4_legacy"] {
        let result = run(&format!(
            "CREATE TABLE {table}(id INTEGER PRIMARY KEY, name TEXT, age INTEGER, score REAL, note TEXT);"
        ))
        .await;
        assert!(result["results"][0]["error"].is_null(), "{result}");
    }
    let fast_pipe2 = import_into(
        &csv,
        &info,
        "pl2_fast",
        &map,
        json!({ "batch_size": 2, "on_error": "stop", "pipeline_batches": 2 }),
        false,
    )
    .await;
    let legacy_pipe = import_into(
        &csv,
        &info,
        "pl2_legacy",
        &map,
        json!({ "batch_size": 2, "on_error": "stop" }),
        true,
    )
    .await;
    let fast_pipe4 = import_into(
        &csv,
        &info,
        "pl4_fast",
        &map,
        json!({ "batch_size": 2, "on_error": "stop", "pipeline_batches": 4 }),
        false,
    )
    .await;
    let legacy_pipe4 = import_into(
        &csv,
        &info,
        "pl4_legacy",
        &map,
        json!({ "batch_size": 2, "on_error": "stop" }),
        true,
    )
    .await;
    for (fast, legacy) in [(&fast_pipe2, &legacy_pipe), (&fast_pipe4, &legacy_pipe4)] {
        assert_eq!(fast["state"], json!("done"), "{fast}");
        for key in [
            "rows_inserted",
            "rows_failed",
            "data_records",
            "records",
            "ok",
            "stopped",
        ] {
            assert_eq!(
                fast["result"][key], legacy["result"][key],
                "pipeline key {key}: fast={fast} legacy={legacy}"
            );
        }
        assert_eq!(
            fast["result"]["issues"], legacy["result"]["issues"],
            "{fast}"
        );
    }
    assert_eq!(
        table_rows("pl2_fast", columns).await,
        table_rows("pl2_legacy", columns).await
    );
    assert_eq!(
        table_rows("pl4_fast", columns).await,
        table_rows("pl4_legacy", columns).await
    );

    // Pipeline DB failure: duplicate PK in the middle batch (stop mode).
    for table in ["pf_fast", "pf_legacy"] {
        let result = run(&format!(
            "CREATE TABLE {table}(id INTEGER PRIMARY KEY, name TEXT, age INTEGER);"
        ))
        .await;
        assert!(result["results"][0]["error"].is_null(), "{result}");
    }
    let dup_csv = write_file(
        &root,
        "duplicate_pk.csv",
        "id,name,age\n1,Ada,1\n2,Bob,2\n3,Cy,3\n1,Dup,4\n5,Eve,5\n6,Fin,6\n",
    );
    let dup_info = api::data_import::import_inspect(dup_csv.clone())
        .await
        .unwrap();
    let dup_map = mapping(&["id", "name", "age"]);
    let fast_dup = import_into(
        &dup_csv,
        &dup_info,
        "pf_fast",
        &dup_map,
        json!({ "batch_size": 2, "on_error": "stop", "pipeline_batches": 2 }),
        false,
    )
    .await;
    let legacy_dup = import_into(
        &dup_csv,
        &dup_info,
        "pf_legacy",
        &dup_map,
        json!({ "batch_size": 2, "on_error": "stop" }),
        true,
    )
    .await;
    for key in [
        "rows_inserted",
        "rows_failed",
        "data_records",
        "records",
        "batches",
        "ok",
        "stopped",
    ] {
        assert_eq!(
            fast_dup["result"][key], legacy_dup["result"][key],
            "pipeline DB failure key {key}: fast={fast_dup} legacy={legacy_dup}"
        );
    }
    // The DB error text embeds the table name, which necessarily differs
    // between the two target tables; compare with the names normalised.
    assert_eq!(
        fast_dup["result"]["message"]
            .as_str()
            .unwrap()
            .replace("pf_fast", "t"),
        legacy_dup["result"]["message"]
            .as_str()
            .unwrap()
            .replace("pf_legacy", "t")
    );
    assert_eq!(
        table_rows("pf_fast", "id, name, age").await,
        table_rows("pf_legacy", "id, name, age").await
    );

    // Pipeline skip-errors DB failure: duplicate PK reported, others inserted.
    for table in ["ps_fast", "ps_legacy"] {
        let result = run(&format!(
            "CREATE TABLE {table}(id INTEGER PRIMARY KEY, name TEXT, age INTEGER);"
        ))
        .await;
        assert!(result["results"][0]["error"].is_null(), "{result}");
    }
    let fast_dup_skip = import_into(
        &dup_csv,
        &dup_info,
        "ps_fast",
        &dup_map,
        json!({ "batch_size": 2, "on_error": "skip", "pipeline_batches": 2 }),
        false,
    )
    .await;
    let legacy_dup_skip = import_into(
        &dup_csv,
        &dup_info,
        "ps_legacy",
        &dup_map,
        json!({ "batch_size": 2, "on_error": "skip" }),
        true,
    )
    .await;
    for key in [
        "rows_inserted",
        "rows_failed",
        "data_records",
        "records",
        "ok",
    ] {
        assert_eq!(
            fast_dup_skip["result"][key], legacy_dup_skip["result"][key],
            "pipeline skip key {key}: fast={fast_dup_skip} legacy={legacy_dup_skip}"
        );
    }
    // Issue order must also match the serial event order (table name differs
    // between the two target tables, so normalise it first).
    let fast_issues = fast_dup_skip["result"]["issues"]
        .to_string()
        .replace("ps_fast", "t");
    let legacy_issues = legacy_dup_skip["result"]["issues"]
        .to_string()
        .replace("ps_legacy", "t");
    assert_eq!(fast_issues, legacy_issues, "pipeline skip issues order");
    assert_eq!(
        table_rows("ps_fast", "id, name, age").await,
        table_rows("ps_legacy", "id, name, age").await
    );

    // Pipeline parse failure: unterminated quote after one complete batch.
    for table in ["pp_fast", "pp_legacy"] {
        let result = run(&format!(
            "CREATE TABLE {table}(id INTEGER PRIMARY KEY, name TEXT, age INTEGER);"
        ))
        .await;
        assert!(result["results"][0]["error"].is_null(), "{result}");
    }
    let broken_csv = write_file(
        &root,
        "broken_quote.csv",
        "id,name,age\n1,Ada,1\n2,Bob,2\n3,\"unterminated,3\n",
    );
    let broken_info = api::data_import::import_inspect(broken_csv.clone())
        .await
        .unwrap();
    let fast_broken = import_into(
        &broken_csv,
        &broken_info,
        "pp_fast",
        &dup_map,
        json!({ "batch_size": 1, "on_error": "stop", "pipeline_batches": 2 }),
        false,
    )
    .await;
    let legacy_broken = import_into(
        &broken_csv,
        &broken_info,
        "pp_legacy",
        &dup_map,
        json!({ "batch_size": 1, "on_error": "stop" }),
        true,
    )
    .await;
    for key in [
        "rows_inserted",
        "rows_failed",
        "data_records",
        "records",
        "ok",
        "stopped",
    ] {
        assert_eq!(
            fast_broken["result"][key], legacy_broken["result"][key],
            "pipeline parse failure key {key}: fast={fast_broken} legacy={legacy_broken}"
        );
    }
    assert_eq!(
        table_rows("pp_fast", "id, name, age").await,
        table_rows("pp_legacy", "id, name, age").await
    );

    // Pipeline cancellation while the bounded queue is busy: must terminate
    // promptly (no producer stuck on send), keep rows <= total, and release
    // resources so a following import still works.
    let mut big = String::from("id,name,age\n");
    for id in 1..=20_000u64 {
        big.push_str(&format!("{id},Row{id},{}\n", id % 90));
    }
    let slow_csv = write_file(&root, "slow.csv", &big);
    let slow_info = api::data_import::import_inspect(slow_csv.clone())
        .await
        .unwrap();
    let result =
        run("CREATE TABLE pc_cancel(id INTEGER PRIMARY KEY, name TEXT, age INTEGER);").await;
    assert!(result["results"][0]["error"].is_null(), "{result}");
    let start = api::data_import::import_execute_start(json!({
        "path": slow_csv,
        "read": slow_info["read"],
        "fields": slow_info["fields"],
        "mapping": dup_map,
        "database": "main",
        "table": "pc_cancel",
        "options": { "batch_size": 1, "on_error": "stop", "pipeline_batches": 2 },
    }))
    .await
    .unwrap();
    let job_id = start["job_id"].as_str().unwrap().to_string();
    tokio::time::sleep(Duration::from_millis(5)).await;
    let _ = api::data_import::import_job_cancel(job_id.clone());
    let cancelled_job = wait_job(&job_id).await;
    assert!(
        cancelled_job["state"] == json!("cancelled") || cancelled_job["state"] == json!("done"),
        "{cancelled_job}"
    );
    let inserted = cancelled_job["result"]["rows_inserted"]
        .as_u64()
        .unwrap_or(0);
    assert!(inserted <= 20_000, "{cancelled_job}");
    assert_eq!(
        cancelled_job["result"]["cancelled"],
        json!(true),
        "cancellation should be observed with batch_size=1: {cancelled_job}"
    );
    // A subsequent pipeline import must still work after cancellation.
    let result =
        run("CREATE TABLE pc_after(id INTEGER PRIMARY KEY, name TEXT, age INTEGER);").await;
    assert!(result["results"][0]["error"].is_null(), "{result}");
    let after = import_into(
        &bad_csv,
        &bad_info,
        "pc_after",
        &bad_map,
        json!({ "batch_size": 2, "on_error": "skip", "pipeline_batches": 2 }),
        false,
    )
    .await;
    assert_eq!(after["state"], json!("done"), "{after}");
    assert_eq!(after["result"]["rows_inserted"], json!(2), "{after}");

    let _ = std::fs::remove_dir_all(&root);
}
