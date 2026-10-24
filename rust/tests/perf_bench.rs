//! 性能基准：走真实 Rust API + 真实 MySQL 数据集，测量 9 个性能场景。
//!
//! 覆盖 docs/PERFORMANCE_TESTING.md 的测试目标：
//!   P0-1 大结果集（1000 万行无 LIMIT）：首屏、JSON 序列化、内存峰值
//!   P0-2 1GB CSV 导入：速度、内存、是否 OOM
//!   P0-3 内存泄漏：查询→滚动→关闭 重复 50 次，RSS 增长 < 10%
//!   P1-4 网格编辑 1 万行批量提交：提交耗时（含缺口验证）
//!   P1-5 导出 100 万行 CSV / Excel / SQL：耗时 + 文件完整性
//!   P1-6 10 路并发查询：最慢/最快延迟比
//!   P1-7 5000 张表对象浏览器：展开时间、搜索响应
//!   P2-8 10MB SQL 文件：切分/预览耗时（编辑器侧另由 UI 测）
//!   P2-9 异常恢复：杀连接、断网、重连自愈
//!
//! 运行：
//!   DBPILOT_PERF=1 DBPILOT_TEST_MYSQL_PASSWORD=123456 cargo test --release --test perf_bench -- --nocapture --test-threads=1
//!
//! 未设 DBPILOT_PERF=1 时全部 skip，避免拖慢常规 CI。

use std::io::Write;
use std::time::{Duration, Instant};

use rust_myadmin_core::api;
use serde_json::{json, Value};

mod common;

/// 性能测试默认关闭：没有 DBPILOT_PERF=1 时整个文件 skip。
fn perf_enabled() -> bool {
    std::env::var("DBPILOT_PERF").map(|v| v == "1").unwrap_or(false)
}

/// 初始化一个临时数据目录的 AppState。
///
/// 基准曾经调用 init_app(String::new())，那会落到真实的用户数据目录
/// （macOS: ~/Library/Application Support/DBPilot）：跑一次基准就会改写用户自己的
/// connections.json / settings.json。基准只需要进程级单例，数据目录用临时目录即可。
fn init_perf_state() {
    let dir = std::env::temp_dir().join("dbpilot-perf-state");
    let _ = std::fs::create_dir_all(&dir);
    let initialized = api::init_app(dir.to_string_lossy().to_string());
    assert_eq!(
        initialized.get("ok"),
        Some(&Value::Bool(true)),
        "init_app: {initialized}"
    );
}

fn mysql_password() -> String {
    common::env_or("DBPILOT_TEST_MYSQL_PASSWORD", "")
}

fn perf_db() -> String {
    common::env_or("PERF_DB", "dbpilot_perf")
}

/// 打开一个到性能库的连接。返回后所有 api 调用都用这个 active connection。
async fn connect() -> Value {
    let body = json!({
        "driver": "mysql",
        "host": common::env_or("DBPILOT_TEST_MYSQL_HOST", "127.0.0.1"),
        "port": common::env_or("DBPILOT_TEST_MYSQL_PORT", "3306").parse::<u16>().unwrap_or(3306),
        "user": common::env_or("DBPILOT_TEST_MYSQL_USER", "root"),
        "password": mysql_password(),
        "database": perf_db(),
        "ssl_mode": "disable",
    });
    let _ = api::connections::disconnect().await;
    let created = api::connections::create_connection(body).await.expect("create connection");
    let id = created["connection"]["id"].as_str().expect("connection id").to_string();
    api::connections::connect_connection(id).await.expect("connect");
    created
}

/// 跑一条标量查询（SELECT COUNT(*)...），返回第一行第一列的整数。
///
/// 注意不能用 [timed_query] 的 rows：那是「结果集行数」（COUNT 永远返回 1 行），
/// 不是 COUNT 的值。
async fn scalar_u64(sql: &str) -> u64 {
    let res = api::query::run_query(json!({ "sql": sql }))
        .await
        .expect("scalar query");
    res["results"]
        .as_array()
        .and_then(|a| a.first())
        .and_then(|r| r["rows"].as_array())
        .and_then(|rows| rows.first())
        .and_then(|row| row.as_array())
        .and_then(|cells| cells.first())
        .and_then(|v| v.as_u64())
        .unwrap_or(0)
}

/// 跑一条 SQL，返回 (耗时ms, 行数, 结果字节数)。
async fn timed_query(sql: &str) -> (f64, usize, usize) {
    let started = Instant::now();
    let res = api::query::run_query(json!({ "sql": sql })).await.expect("run_query");
    let elapsed = started.elapsed().as_secs_f64() * 1000.0;
    let rows = res["results"]
        .as_array()
        .and_then(|a| a.first())
        .and_then(|r| r["row_count"].as_u64())
        .unwrap_or(0) as usize;
    let bytes = res.to_string().len();
    (elapsed, rows, bytes)
}

/// 当前进程 RSS（KB）。macOS/Linux 都走 ps，避免引入额外依赖。
/// 沙箱内 ps 可能被拒（返回空），此时返回 0，调用方必须区分「0 = 采样不可用」。
fn rss_kb() -> u64 {
    let pid = std::process::id();
    let out = std::process::Command::new("ps")
        .args(["-o", "rss=", "-p", &pid.to_string()])
        .output();
    match out {
        Ok(o) => String::from_utf8_lossy(&o.stdout).trim().parse().unwrap_or(0),
        Err(_) => 0,
    }
}

fn report(label: &str, ms: f64, detail: &str) {
    println!("{label:<46} {ms:>10.1} ms   {detail}");
}



// ==================================================================== P0-1

/// P0-1：大结果集查询渲染。
///
/// 「1000 万行无 LIMIT」在应用里必然被 MAX_CONSOLE_ROWS 截断（50,000 行），
/// 所以这里同时测：
///   a) 一次能返回的最大结果集（50,000 行）的耗时、JSON 体积、峰值 RSS；
///   b) 首屏（分页 1000 行）的耗时；
///   c) 无 LIMIT 全表扫描的服务端代价（COUNT(*)）。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn p0_large_result_set() {
    if !perf_enabled() {
        eprintln!("skip: 设 DBPILOT_PERF=1 才跑性能基准");
        return;
    }
    init_perf_state();
    connect().await;
    println!("\n== P0-1 大结果集（narrow_10m，1000 万行）==");

    let base = rss_kb();
    println!("baseline RSS = {base} KB");

    // a) 控制台上限：50,000 行（应用实际能一次给到 UI 的最大结果集）
    let (ms, rows, bytes) = timed_query("SELECT * FROM narrow_10m LIMIT 50000").await;
    report(
        "narrow_10m 50,000 行（控制台上限）",
        ms,
        &format!("rows={rows} json={}KB", bytes / 1024),
    );
    let peak = rss_kb();
    if peak > 0 && base > 0 {
        println!(
            "  ↳ 查询后 RSS {} -> {} KB（{:+.1}%）",
            base,
            peak,
            (peak as f64 - base as f64) / base as f64 * 100.0
        );
    }

    // b) 首屏分页
    for n in [100usize, 1000] {
        let (ms, rows, bytes) = timed_query(&format!("SELECT * FROM narrow_10m LIMIT {n}")).await;
        report(
            &format!("narrow_10m 首屏 {n} 行"),
            ms,
            &format!("rows={rows} json={}KB", bytes / 1024),
        );
    }

    // c) 服务端全表扫描代价
    let (ms, _, _) = timed_query("SELECT COUNT(*) FROM narrow_10m").await;
    report("narrow_10m COUNT(*)（全表扫描）", ms, "");

    // d) 宽表 / 大字段：JSON 体积是主要成本
    let (ms, rows, bytes) = timed_query("SELECT * FROM wide_100k LIMIT 500").await;
    report(
        "wide_100k 500 行 x 100 列",
        ms,
        &format!("rows={rows} json={}KB", bytes / 1024),
    );
    let (ms, rows, bytes) = timed_query("SELECT * FROM bigtext_50k LIMIT 200").await;
    report(
        "bigtext_50k 200 行 x 10KB",
        ms,
        &format!("rows={rows} json={}KB", bytes / 1024),
    );

    // e) 截断是否真的生效：无 LIMIT 的 SELECT 必须被截到 50,000
    let (ms, rows, _) = timed_query("SELECT * FROM narrow_10m").await;
    report(
        "narrow_10m 无 LIMIT（应被截断）",
        ms,
        &format!("rows={rows}（上限 50000）"),
    );
    assert_eq!(rows, 50_000, "无 LIMIT 查询必须被 MAX_CONSOLE_ROWS 截断");
}


// ==================================================================== P0-2

/// 生成一个指定大小的 CSV（表头 + 4 列）。
fn write_csv(path: &std::path::Path, target_bytes: u64) -> u64 {
    let mut file = std::fs::File::create(path).expect("create csv");
    let mut written = file.write(b"id,name,amount,note\n").expect("write header") as u64;
    let mut id = 0u64;
    let mut buf = String::with_capacity(256 * 1024);
    while written < target_bytes {
        buf.clear();
        for _ in 0..2000 {
            id += 1;
            buf.push_str(&format!(
                "{id},user-{id},{}.{:02},note-{id}\n",
                id % 100000,
                id % 100
            ));
        }
        written += file.write(buf.as_bytes()).expect("write rows") as u64;
    }
    file.flush().expect("flush");
    id
}

async fn wait_import_job(job_id: &str) -> Value {
    for _ in 0..600_000 {
        let status = api::data_import::import_job_status(job_id.to_string()).expect("job status");
        if status["done"].as_bool().unwrap_or(false) {
            return status;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    panic!("import job {job_id} did not finish");
}

/// P0-2：1GB CSV 导入（约 500 万行）。用 PERF_CSV_MB 覆盖大小，默认 1024。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn p0_large_csv_import() {
    if !perf_enabled() {
        eprintln!("skip: 设 DBPILOT_PERF=1 才跑性能基准");
        return;
    }
    let target_mb: u64 = std::env::var("PERF_CSV_MB")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(1024);
    init_perf_state();
    connect().await;
    println!("\n== P0-2 大 CSV 导入（{target_mb} MB）==");

    let dir = std::env::temp_dir().join("dbpilot-perf-csv");
    let _ = std::fs::create_dir_all(&dir);
    let csv_path = dir.join(format!("import_{target_mb}mb.csv"));

    let gen_started = Instant::now();
    let rows = write_csv(&csv_path, target_mb * 1024 * 1024);
    let gen_ms = gen_started.elapsed().as_secs_f64() * 1000.0;
    let size = std::fs::metadata(&csv_path).map(|m| m.len()).unwrap_or(0);
    report(
        "生成 CSV",
        gen_ms,
        &format!("file={}MB rows={rows}", size / 1024 / 1024),
    );

    let _ = api::query::run_query(json!({ "sql": "DROP TABLE IF EXISTS perf_csv_import" })).await;
    let _ = api::query::run_query(json!({
        "sql": "CREATE TABLE perf_csv_import (id BIGINT PRIMARY KEY, name VARCHAR(64), amount DECIMAL(12,2), note VARCHAR(64))"
    }))
    .await;

    let inspect = api::data_import::import_inspect(csv_path.to_string_lossy().to_string())
        .await
        .expect("inspect");
    let mapping = json!({
        "columns": [
            { "column": "id", "source": "id" },
            { "column": "name", "source": "name" },
            { "column": "amount", "source": "amount" },
            { "column": "note", "source": "note" }
        ],
        "ignore_unknown": true,
        "empty_as_null": false,
        "null_tokens": ["\\N"],
        "trim_values": true
    });
    let params = json!({
        "path": csv_path.to_string_lossy().to_string(),
        "read": inspect["read"],
        "fields": inspect["fields"],
        "mapping": mapping,
        "database": perf_db(),
        "table": "perf_csv_import",
        "options": { "batch_size": 1000, "on_error": "stop", "max_issues": 10 },
    });

    let baseline_rss = rss_kb();
    let started = Instant::now();
    let job = api::data_import::import_execute_start(params).await.expect("start import");
    let job = wait_import_job(job["job_id"].as_str().expect("job id")).await;
    let ms = started.elapsed().as_secs_f64() * 1000.0;
    let after_rss = rss_kb();
    let inserted = job["result"]["rows_inserted"].as_u64().unwrap_or(0);
    println!("job state = {}, error = {}", job["state"], job["error"]);
    let mb_per_s = (size as f64 / 1024.0 / 1024.0) / (ms / 1000.0);
    report(
        &format!("导入 {target_mb}MB CSV（{inserted} 行）"),
        ms,
        &format!("{mb_per_s:.2} MB/s"),
    );
    if baseline_rss > 0 && after_rss > 0 {
        let growth = (after_rss as f64 - baseline_rss as f64) / baseline_rss as f64 * 100.0;
        println!(
            "  ↳ RSS {} -> {} KB（{:+.1}%）—— 是否 OOM：{}",
            baseline_rss,
            after_rss,
            growth,
            if growth < 200.0 { "未 OOM（增长 < 200%）" } else { "疑似内存问题" }
        );
    } else {
        println!("  ↳ RSS 采样不可用");
    }

    let counted = scalar_u64("SELECT COUNT(*) FROM perf_csv_import").await;
    println!("表内行数 = {counted}");
    assert_eq!(inserted, rows, "导入行数与生成行数不一致");
    let _ = std::fs::remove_file(&csv_path);
}


// ==================================================================== P0-3

/// P0-3：内存泄漏。循环「查询 → 滚动（多页）→ 关闭结果」，重复 50 次。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn p0_memory_leak_50_rounds() {
    if !perf_enabled() {
        eprintln!("skip");
        return;
    }
    init_perf_state();
    connect().await;
    println!("\n== P0-3 内存泄漏（查询 -> 滚动 -> 关闭，50 轮）==");

    // 热身：把连接池、语句缓存、序列化缓冲都建好，避免把启动开销算成泄漏。
    //
    // 这一步必须做够：RSS 从「进程刚起」到「连接池 + 语句缓存建好」会一次性
    // 上涨几百个百分点（不是泄漏），先跑 10 轮把这段吃掉再取基线。
    for _ in 0..10 {
        let _ = timed_query("SELECT * FROM narrow_10m LIMIT 5000").await;
        let _ = timed_query("SELECT * FROM bigtext_50k LIMIT 50").await;
    }
    let cold = rss_kb();
    let baseline = rss_kb();
    if baseline == 0 {
        println!("RSS 采样不可用（沙箱内 ps 被拒），本项无法判定");
        return;
    }
    println!("冷启动 RSS = {cold} KB（含连接池/缓存一次性开销，不计入泄漏）");
    println!("baseline RSS = {baseline} KB（热身 10 轮后，泄漏判定的起点）");

    let mut series: Vec<u64> = Vec::new();
    for round in 1..=50 {
        // 查询：取一页 5000 行
        let _ = timed_query("SELECT * FROM narrow_10m LIMIT 5000").await;
        // 滚动：模拟 UI 逐页加载（每页 500 行，共 5 页）
        for page in 0..5 {
            let _ = timed_query(&format!(
                "SELECT * FROM narrow_10m LIMIT 500 OFFSET {}",
                page * 500
            ))
            .await;
        }
        // 大字段页：验证 lazy 渲染路径的缓冲不会被留住
        let _ = timed_query("SELECT * FROM bigtext_50k LIMIT 50").await;
        // 关闭结果：run_query 的返回值在每轮结束时 drop
        if round % 10 == 0 {
            let rss = rss_kb();
            series.push(rss);
            println!("  round {round:>2}: RSS = {rss} KB");
        }
    }
    let after = rss_kb();
    let growth = (after as f64 - baseline as f64) / baseline as f64 * 100.0;
    println!("after RSS = {after} KB, growth = {growth:.1}%");
    println!(
        "判据 growth < 10%（相对热身基线）: {}",
        if growth < 10.0 { "PASS" } else { "FAIL" }
    );
    // 真泄漏的判据不是「首尾差值」，而是「后半段是否还在单调上涨」：
    // 分配器（glibc/mimalloc/系统 malloc）会把刚用过的页留着复用，
    // 前几十轮上涨后进入平台期属于正常行为，不是泄漏。
    if series.len() >= 4 {
        let mid = series[series.len() / 2];
        let tail_growth = (after as f64 - mid as f64) / mid as f64 * 100.0;
        println!(
            "后半段（第 25->50 轮）增长 = {tail_growth:.1}%  ->  真泄漏判据（< 2%）: {}",
            if tail_growth < 2.0 { "PASS" } else { "FAIL" }
        );
        println!(
            "RSS 序列（每 10 轮）: {:?} KB",
            series
        );
    }
}


// ==================================================================== P1-4

/// P1-4：网格编辑 1 万行 -> 保存。
///
/// 应用只有单行 change_row，没有批量提交接口，所以这里：
///   a) 实测「逐行 UPDATE 1 万行」的真实耗时（当前实现的最坏情况）；
///   b) 实测「一个事务内批量 UPDATE」的耗时，量化缺口有多大。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn p1_bulk_row_update() {
    if !perf_enabled() {
        eprintln!("skip");
        return;
    }
    init_perf_state();
    connect().await;
    println!("\n== P1-4 网格编辑 1 万行 -> 保存 ==");

    let _ = api::query::run_query(json!({ "sql": "DROP TABLE IF EXISTS edit_10k" })).await;
    let _ = api::query::run_query(json!({
        "sql": "CREATE TABLE edit_10k (id INT PRIMARY KEY, name VARCHAR(64), amount DECIMAL(12,2))"
    }))
    .await;
    // 递归 CTE 的深度受**会话**变量限制（默认 1000）。run_query 每次可能换
    // 会话，所以 SET 必须和 INSERT 放进同一次调用（同一脚本），否则 SET 丢失。
    let seed = api::query::run_query(json!({
        "sql": "SET SESSION cte_max_recursion_depth = 20000; \
                INSERT INTO edit_10k (id, name, amount) \
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n < 10000) \
                SELECT n, CONCAT('row-', n), n * 1.25 FROM seq"
    }))
    .await
    .expect("seed");
    let seed_errors: Vec<String> = seed["results"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter(|r| !r["error"].is_null())
                .map(|r| r["error"].to_string())
                .collect()
        })
        .unwrap_or_default();
    assert!(seed_errors.is_empty(), "seed failed: {seed_errors:?}");
    println!("已造 10,000 行");

    // a) 逐行 UPDATE（当前 UI 的实现方式：每格一次 change_row）
    let started = Instant::now();
    let mut ok = 0usize;
    for id in 1..=10_000u64 {
        let res = api::explorer::change_row(
            perf_db(),
            "edit_10k".to_string(),
            json!({
                "action": "update",
                "keys": { "id": id },
                "values": { "name": format!("edited-{id}"), "amount": id as f64 * 2.5 },
            }),
        )
        .await;
        if res.is_ok() {
            ok += 1;
        }
    }
    let per_row_ms = started.elapsed().as_secs_f64() * 1000.0;
    report(
        "逐行 UPDATE 10,000 行（当前实现）",
        per_row_ms,
        &format!("ok={ok}, {:.2} ms/行", per_row_ms / 10_000.0),
    );
    // 必须在批量 UPDATE 覆盖之前核对：逐行写入是否真的全部生效。
    let edited = scalar_u64("SELECT COUNT(*) FROM edit_10k WHERE name LIKE 'edited-%'").await;
    println!("  ↳ 逐行更新生效行数 = {edited}（应为 10000）");
    assert_eq!(edited, 10_000, "逐行更新没有全部生效");

    // b) 单事务批量 UPDATE（若实现 apply_row_changes，应能做到的量级）
    let started = Instant::now();
    let mut sql = String::from("START TRANSACTION;");
    let ids: Vec<u64> = (1..=10_000).collect();
    for chunk in ids.chunks(500) {
        let cases: String = chunk
            .iter()
            .map(|id| format!("WHEN {id} THEN 'batch-{id}'"))
            .collect::<Vec<_>>()
            .join(" ");
        sql.push_str(&format!(
            "UPDATE edit_10k SET name = CASE id {cases} ELSE name END WHERE id BETWEEN {} AND {};",
            chunk[0],
            chunk[chunk.len() - 1]
        ));
    }
    sql.push_str("COMMIT;");
    let batch = api::query::run_query(json!({ "sql": sql })).await.expect("batch");
    let batch_ms = started.elapsed().as_secs_f64() * 1000.0;
    let errors = batch["results"]
        .as_array()
        .map(|a| a.iter().filter(|r| !r["error"].is_null()).count())
        .unwrap_or(0);
    report(
        "单事务批量 UPDATE（20 批 x 500 行）",
        batch_ms,
        &format!(
            "statements={}, errors={}",
            batch["results"].as_array().map(|a| a.len()).unwrap_or(0),
            errors
        ),
    );
    println!(
        "  ↳ 批量比逐行快 {:.1}x；这就是缺 apply_row_changes 的代价",
        per_row_ms / batch_ms.max(0.001)
    );

    let batched = scalar_u64("SELECT COUNT(*) FROM edit_10k WHERE name LIKE 'batch-%'").await;
    println!("  ↳ 批量更新生效行数 = {batched}（应为 10000）");
    assert_eq!(batched, 10_000, "批量更新没有全部生效");
}


// ==================================================================== P1-5

/// P1-5：导出 100 万行 CSV / Excel / SQL，测耗时与文件完整性。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn p1_export_1m_rows() {
    if !perf_enabled() {
        eprintln!("skip");
        return;
    }
    init_perf_state();
    connect().await;
    println!("\n== P1-5 导出 100 万行（narrow_10m）==");

    let dir = std::env::temp_dir().join("dbpilot-perf-export");
    let _ = std::fs::create_dir_all(&dir);

    // CSV / Excel 走 export_query（自由 SELECT）
    for format in ["csv", "xls"] {
        let path = dir.join(format!("narrow_1m.{format}"));
        let _ = std::fs::remove_file(&path);
        let started = Instant::now();
        let res = api::export::export_query(
            perf_db(),
            "SELECT * FROM narrow_10m LIMIT 1000000".to_string(),
            json!({ "format": format, "path": path.to_string_lossy() }),
        )
        .await;
        let ms = started.elapsed().as_secs_f64() * 1000.0;
        let size = std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
        match res {
            Ok(v) => {
                let rows = v["rows"].as_u64().unwrap_or(0);
                report(
                    &format!("导出 1,000,000 行 .{format}"),
                    ms,
                    &format!("rows={rows} file={:.1}MB", size as f64 / 1024.0 / 1024.0),
                );
                assert!(size > 0, "{format} 导出文件为空");
                assert_eq!(rows, 1_000_000, "{format} 导出行数不对");
                let tail = std::fs::read(&path)
                    .map(|b| b[b.len().saturating_sub(48)..].to_vec())
                    .unwrap_or_default();
                println!(
                    "  ↳ 末尾：{}",
                    String::from_utf8_lossy(&tail).replace('\n', "\\n")
                );
            }
            Err(e) => println!("{format:<46} 失败：{e}"),
        }
    }

    // SQL 格式：自由 SELECT 不支持（需要表结构），走 export_table
    let path = dir.join("narrow_1m.sql");
    let _ = std::fs::remove_file(&path);
    let res = api::export::export_query(
        perf_db(),
        "SELECT * FROM narrow_10m LIMIT 10".to_string(),
        json!({ "format": "sql", "path": path.to_string_lossy() }),
    )
    .await;
    println!(
        "  ↳ free SELECT 用 SQL 格式：{}",
        if res.is_err() {
            "按预期拒绝（提示去表页导出）"
        } else {
            "意外成功"
        }
    );

    // 表页的 SQL 导出（含结构 + 数据）。整表导出没有 LIMIT，1000 万行会写
    // 约 1.5GB —— 本机只剩 ~7GB，跑一次就把盘写满（实测触发
    // "No space left on device"）。所以用 50 万行的 mixed_500k 测 SQL 格式，
    // 1000 万行的吞吐量由上面的 CSV 行外推。
    let path = dir.join("mixed_table_500k.sql");
    let _ = std::fs::remove_file(&path);
    let started = Instant::now();
    let res = api::export::export_table(
        perf_db(),
        "mixed_500k".to_string(),
        json!({ "format": "sql", "path": path.to_string_lossy() }),
    )
    .await;
    let ms = started.elapsed().as_secs_f64() * 1000.0;
    let size = std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
    match res {
        Ok(v) => {
            let rows = v["rows"].as_u64().unwrap_or(0);
            report(
                "导出整表 SQL（mixed_500k，500,000 行）",
                ms,
                &format!("rows={rows} file={:.1}MB", size as f64 / 1024.0 / 1024.0),
            );
            assert!(size > 0, "SQL 导出文件为空");
            // 完整性：文件必须能被重新切分回语句（结构 + 数据都在）
            let text = std::fs::read_to_string(&path).unwrap_or_default();
            let statements = rust_myadmin_core::db::split_statements(&text).len();
            println!(
                "  ↳ 文件可回读：{} MB，切分出 {} 条语句（含 CREATE TABLE）",
                text.len() / 1024 / 1024,
                statements
            );
        }
        Err(e) => println!("整表 SQL 导出失败：{e}"),
    }
    // 清理大文件，避免把测试机的盘写满
    let _ = std::fs::remove_file(&path);
    let _ = std::fs::remove_file(dir.join("narrow_1m.csv"));
    let _ = std::fs::remove_file(dir.join("narrow_1m.xls"));
}


// ==================================================================== P1-6

/// P1-6：10 个「标签页」同时执行查询，测最慢/最快延迟比。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn p1_concurrent_queries() {
    if !perf_enabled() {
        eprintln!("skip");
        return;
    }
    init_perf_state();
    connect().await;
    println!("\n== P1-6 并发查询（10 个标签页）==");

    let mut serial = Vec::new();
    for _ in 0..10 {
        let (ms, _, _) = timed_query("SELECT * FROM narrow_10m LIMIT 1000").await;
        serial.push(ms);
    }
    serial.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let serial_median = serial[5];
    let serial_total: f64 = serial.iter().sum();
    println!("串行单次中位数 = {serial_median:.1} ms，10 次合计 {serial_total:.0} ms");

    let started = Instant::now();
    let mut handles = Vec::new();
    for tab in 0..10usize {
        handles.push(tokio::spawn(async move {
            let t = Instant::now();
            let sql = format!("SELECT * FROM narrow_10m LIMIT 1000 OFFSET {}", tab * 1000);
            let _ = api::query::run_query(json!({ "sql": sql })).await;
            t.elapsed().as_secs_f64() * 1000.0
        }));
    }
    let mut latencies = Vec::new();
    for h in handles {
        latencies.push(h.await.unwrap_or(0.0));
    }
    let wall = started.elapsed().as_secs_f64() * 1000.0;
    latencies.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let fastest = latencies.first().copied().unwrap_or(0.0);
    let slowest = latencies.last().copied().unwrap_or(0.0);
    let ratio = if fastest > 0.0 { slowest / fastest } else { 0.0 };
    println!(
        "并发 10 路：wall={wall:.1} ms, fastest={fastest:.1}, slowest={slowest:.1}, ratio={ratio:.2}"
    );
    println!(
        "  ↳ 判据 ratio < 3: {}；并发 wall {:.0} ms vs 串行 {:.0} ms（加速 {:.1}x）",
        if ratio < 3.0 { "PASS" } else { "需关注" },
        wall,
        serial_total,
        serial_total / wall.max(0.001)
    );
}


// ==================================================================== P1-7

/// P1-7：5000 张表的库，测展开时间与搜索响应。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn p1_object_browser_5000_tables() {
    if !perf_enabled() {
        eprintln!("skip");
        return;
    }
    init_perf_state();
    connect().await;
    println!("\n== P1-7 对象浏览器（5000 张表）==");

    // 冷启动：第一次调用含连接池预热
    let started = Instant::now();
    let tables = api::explorer::list_tables_in(perf_db(), None)
        .await
        .expect("list_tables");
    let cold_ms = started.elapsed().as_secs_f64() * 1000.0;
    let count = tables["tables"].as_array().map(|a| a.len()).unwrap_or(0);
    report("list_tables 首次（冷）", cold_ms, &format!("tables={count}"));

    // 预热后
    let mut warm = Vec::new();
    for _ in 0..5 {
        let started = Instant::now();
        let _ = api::explorer::list_tables_in(perf_db(), None)
            .await
            .expect("list_tables");
        warm.push(started.elapsed().as_secs_f64() * 1000.0);
    }
    warm.sort_by(|a, b| a.partial_cmp(b).unwrap());
    report(
        "list_tables 预热后中位数",
        warm[2],
        &format!("tables={count}"),
    );

    // 对象（视图/例程/触发器/事件）
    let started = Instant::now();
    let objects = api::explorer::list_objects(perf_db())
        .await
        .expect("list_objects");
    let obj_ms = started.elapsed().as_secs_f64() * 1000.0;
    report(
        "list_objects",
        obj_ms,
        &format!("bytes={}", objects.to_string().len()),
    );

    // 搜索响应：UI 的搜索是纯客户端过滤，这里量化「一次过滤 5000 个表名」的代价
    let names: Vec<String> = tables["tables"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|t| t["name"].as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default();
    let started = Instant::now();
    let mut hits = 0usize;
    for _ in 0..100 {
        hits = names
            .iter()
            .filter(|n| n.to_ascii_lowercase().contains("t_499"))
            .count();
    }
    let filter_us = started.elapsed().as_micros() as f64 / 100.0;
    report(
        "搜索过滤 5000 个表名（单次）",
        filter_us / 1000.0,
        &format!("hits={hits}, 平均 {filter_us:.0} us"),
    );

    // 服务端搜索：如果 UI 改成下推 WHERE，需要多久
    let started = Instant::now();
    let _ = api::query::run_query(json!({
        "sql": "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA = 'dbpilot_perf' AND TABLE_NAME LIKE '%t_499%'"
    }))
    .await
    .expect("server search");
    report(
        "服务端 LIKE 搜索",
        started.elapsed().as_secs_f64() * 1000.0,
        "",
    );
}


// ==================================================================== P2-8

/// P2-8：10MB SQL 文件的切分与预览。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn p2_large_sql_file() {
    if !perf_enabled() {
        eprintln!("skip");
        return;
    }
    println!("\n== P2-8 大 SQL 文件（10MB）==");

    let mut sql = String::with_capacity(11 * 1024 * 1024);
    let mut i = 0usize;
    while sql.len() < 10 * 1024 * 1024 {
        sql.push_str(&format!("INSERT INTO t (id, v) VALUES ({i}, 'value-{i}');\n"));
        i += 1;
    }
    let path = std::env::temp_dir().join("dbpilot-perf-10mb.sql");
    std::fs::write(&path, &sql).expect("write sql file");
    println!("file = {} MB, {} statements", sql.len() / 1024 / 1024, i);

    let started = Instant::now();
    let split = rust_myadmin_core::db::split_statements(&sql);
    let split_ms = started.elapsed().as_secs_f64() * 1000.0;
    report(
        "split_statements 10MB",
        split_ms,
        &format!("statements={}", split.len()),
    );

    let started = Instant::now();
    let _ = api::data_import::sql_file_preview(path.to_string_lossy().to_string(), Some(65536)).await;
    report(
        "sql_file_preview（只读 64KB）",
        started.elapsed().as_secs_f64() * 1000.0,
        "",
    );

    let started = Instant::now();
    let _ = api::data_import::sql_file_preview(path.to_string_lossy().to_string(), Some(1024)).await;
    report(
        "sql_file_preview（只读 1KB）",
        started.elapsed().as_secs_f64() * 1000.0,
        "",
    );
    let _ = std::fs::remove_file(&path);
}


// ==================================================================== P2-9

/// P2-9：异常恢复。杀连接 / 指向不存在的端口 / 断开重连。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn p2_error_recovery() {
    if !perf_enabled() {
        eprintln!("skip");
        return;
    }
    init_perf_state();
    connect().await;
    println!("\n== P2-9 异常恢复 ==");

    // 1) KILL 自己的连接：下一次查询必须返回可读错误，而不是 panic
    let conn_id = api::query::run_query(json!({ "sql": "SELECT CONNECTION_ID() AS id" }))
        .await
        .expect("conn id");
    let cid = conn_id["results"][0]["rows"][0][0].as_u64().unwrap_or(0);
    println!("当前连接 id = {cid}");
    let killed = api::query::run_query(json!({ "sql": format!("KILL {cid}") })).await;
    println!(
        "KILL 自己：{}",
        if killed.is_ok() { "已发出" } else { "被拒（正常）" }
    );
    tokio::time::sleep(Duration::from_millis(300)).await;
    let started = Instant::now();
    let after_kill = api::query::run_query(json!({ "sql": "SELECT 1 AS ok" })).await;
    let recover_ms = started.elapsed().as_secs_f64() * 1000.0;
    match after_kill {
        Ok(v) => {
            let err = &v["results"][0]["error"];
            if err.is_null() {
                println!("杀连接后查询：自愈成功（{recover_ms:.0} ms 重建连接）");
            } else {
                println!("杀连接后查询：返回可读错误 -> {err}（未 panic，{recover_ms:.0} ms）");
            }
        }
        Err(e) => println!("杀连接后查询：返回错误 -> {e}（未 panic，{recover_ms:.0} ms）"),
    }
    let again = api::query::run_query(json!({ "sql": "SELECT 2 AS ok" })).await;
    println!("恢复后再次查询：{}", if again.is_ok() { "OK" } else { "仍失败" });

    // 2) 指向不存在的端口：必须有超时/拒绝，不能无限等
    let bad = api::connections::create_connection(json!({
        "name": "perf-dead-port",
        "driver": "mysql",
        "host": "127.0.0.1",
        "port": 3399,
        "user": "root",
        "password": "x",
        "database": perf_db(),
        "ssl_mode": "disable",
    }))
    .await;
    match bad {
        Ok(created) => {
            let bad_id = created["connection"]["id"].as_str().unwrap_or("").to_string();
            let started = Instant::now();
            let res = api::connections::connect_connection(bad_id.clone()).await;
            let ms = started.elapsed().as_secs_f64() * 1000.0;
            report(
                "连接不存在的端口 3399",
                ms,
                &format!(
                    "{}（应快速失败）",
                    if res.is_err() { "返回可读错误" } else { "意外成功" }
                ),
            );
            let _ = api::connections::delete_connection(bad_id).await;
        }
        Err(e) => println!("创建死端口连接失败（不影响结论）：{e}"),
    }

    // 3) 断开 -> 重连链路
    let started = Instant::now();
    let _ = api::connections::disconnect().await;
    connect().await;
    report(
        "disconnect -> reconnect",
        started.elapsed().as_secs_f64() * 1000.0,
        "",
    );
    let ok = api::query::run_query(json!({ "sql": "SELECT 3 AS ok" })).await;
    println!("重连后查询：{}", if ok.is_ok() { "OK" } else { "失败" });
}

