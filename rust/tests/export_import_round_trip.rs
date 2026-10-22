
#[cfg(test)]
mod api_round_trip {
    use rust_myadmin_core::api;
    use serde_json::json;

    fn sqlite_path(root: &std::path::Path) -> std::path::PathBuf {
        let dir = root.join("db");
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("main.sqlite");
        std::fs::write(&file, []).unwrap();
        file
    }

    /// Export the same table in every format through the public API, then read
    /// each file back through inspect()/preview() and check the NULL and the
    /// empty string survive.
    #[tokio::test]
    async fn every_exported_format_can_be_imported_back() {
        let root = std::env::temp_dir().join(format!("rma-e2e-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&root).unwrap();
        let db_file = sqlite_path(&root);
        let init = api::init_app(root.join("app").to_string_lossy().into());
        assert_eq!(init["ok"], json!(true), "{init}");
        let made = api::connections::create_connection(json!({
            "name": "e2e",
            "driver": "sqlite",
            "database": db_file,
        }))
        .await
        .unwrap();
        api::connections::connect_connection(made["connection"]["id"].as_str().unwrap().into())
            .await
            .unwrap();

        let setup = api::query::run_query(json!({
            "sql": "CREATE TABLE t(id INTEGER, name TEXT, note TEXT); \
                    INSERT INTO t VALUES (1, 'alice', NULL), (2, NULL, 'has,comma'), (3, 'bob', ''), (4, 'a & b < c', 'x | y');"
        }))
        .await
        .unwrap();
        assert!(
            setup["results"].as_array().unwrap().iter().all(|r| r["error"].is_null()),
            "setup: {setup}"
        );

        for format in ["csv", "txt", "json", "xml", "html", "xls", "md"] {
            let path = root.join(format!("t.{format}"));
            let exported = api::export::export_table(
                "main".into(),
                "t".into(),
                json!({ "format": format, "path": path.to_string_lossy() }),
            )
            .await
            .unwrap();
            assert_eq!(exported["rows"], json!(4), "{format}: {exported}");

            let info = api::data_import::import_inspect(path.to_string_lossy().into())
                .await
                .unwrap();
            let spec = json!({
                "path": path.to_string_lossy(),
                "read": info["read"],
                "fields": info["fields"],
            });
            let preview = api::data_import::import_preview(path.to_string_lossy().into(), spec).await.unwrap();
            let records = preview["records"].as_array().unwrap();
            let data: Vec<&serde_json::Value> = records
                .iter()
                .filter(|r| r["header"] != json!(true))
                .collect();
            assert_eq!(data.len(), 4, "{format}: four rows back: {preview}");
            for record in &data {
                assert_eq!(
                    record["field_count"].as_u64().unwrap(),
                    3,
                    "{format}: every row keeps 3 cells: {record}"
                );
            }
            // Row 1 (index 0) has a NULL note; row 3 (index 2) has an empty one.
            let note = |i: usize| -> serde_json::Value {
                match &data[i]["values"] {
                    serde_json::Value::Object(map) => {
                        map.get("note").cloned().unwrap_or(serde_json::Value::Null)
                    }
                    serde_json::Value::Array(items) => {
                        items.get(2).cloned().unwrap_or(serde_json::Value::Null)
                    }
                    other => other.clone(),
                }
            };
            assert!(note(0).is_null(), "{format}: NULL note lost, got {}", note(0));
            assert_eq!(note(2), json!(""), "{format}: empty note lost");
        }
    }
}
