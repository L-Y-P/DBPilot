//! P1 regression: a refused port must fail fast, not wait for the pool
//! acquire timeout twice (the old connect_admin fallback took 30s).

use serde_json::json;

use rust_myadmin_core::api;

#[tokio::test]
async fn refused_port_fails_fast() {
    let dir = std::env::temp_dir().join(format!("rma-fastfail-{}", std::process::id()));
    let _ = std::fs::create_dir_all(&dir);
    let result = api::init_app(dir.to_string_lossy().to_string());
    assert_eq!(result.get("ok"), Some(&serde_json::Value::Bool(true)));

    let created = api::connections::create_connection(json!({
        "name": "dead port",
        "driver": "mysql",
        "host": "127.0.0.1",
        "port": 3399,
        "user": "root",
        "password": "x",
    }))
    .await
    .expect("create_connection");
    let id = created["connection"]["id"].as_str().unwrap().to_string();

    let started = std::time::Instant::now();
    let outcome = api::connections::connect_connection(id).await;
    let elapsed = started.elapsed();
    assert!(outcome.is_err(), "dead port should fail: {outcome:?}");
    assert!(
        elapsed < std::time::Duration::from_secs(5),
        "refused port took {elapsed:?}; the fast-fail path is broken"
    );
    let text = format!("{:?}", outcome.unwrap_err());
    assert!(
        text.contains("连接被拒绝") || text.contains("无法连接"),
        "unexpected error: {text}"
    );
}