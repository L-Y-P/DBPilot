#!/usr/bin/env bash
# ============================================================================
#  生成性能测试用的 5 套 MySQL 8.0 数据集（SQL 文件）。
#
#  用法：
#    bash tools/perf/gen_datasets.sh                # 生成全部
#    bash tools/perf/gen_datasets.sh wide narrow    # 只生成指定数据集
#    OUT_DIR=/tmp/perf-datasets bash tools/perf/gen_datasets.sh
#
#  产物（默认 out/perf-datasets/）：
#    01_wide_100k.sql         宽表：100 列 VARCHAR(100)，10 万行
#    02_narrow_10m.sql        窄大表：4 列，1000 万行
#    03_bigtext_50k.sql       大字段表：TEXT 约 10KB/行，5 万行
#    04_many_tables_5000.sql  多表库：5000 张表，每张 3 列
#    05_mixed_500k.sql        混合类型：JSON/BLOB/DECIMAL/DATETIME，50 万行
#    00_load_all.sh           依次导入全部数据集
#
#  设计说明：
#    * 1000 万行不写 1000 万条 INSERT（文件会到 GB 级），用
#      INSERT ... SELECT + 递归 CTE / 交叉连接让 MySQL 自己算，几秒完成；
#    * 生成的文件本身很小（<100KB），便于反复重建；
#    * 每个文件都可重复执行：先 DROP TABLE IF EXISTS 再建，幂等。
# ============================================================================
set -euo pipefail

OUT_DIR="${OUT_DIR:-out/perf-datasets}"
mkdir -p "$OUT_DIR"

# 目标库（不存在时由 00_load_all.sh 创建）
DB="${PERF_DB:-dbpilot_perf}"

gen_wide() {
  local f="$OUT_DIR/01_wide_100k.sql"
  {
    echo "-- 数据集 1：宽表（100 列 VARCHAR(100)，10 万行）"
    echo "-- 用途：P0-1 大结果集渲染（宽行）、P1-7 对象浏览器列展开"
    echo "DROP TABLE IF EXISTS wide_100k;"
    printf 'CREATE TABLE wide_100k (id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY'
    for i in $(seq 1 100); do
      printf ", c%03d VARCHAR(100) DEFAULT NULL" "$i"
    done
    echo ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;"
    echo ""
    echo "-- 10 万行：递归 CTE 生成序号，逐列拼不同字符串。"
    echo "SET SESSION cte_max_recursion_depth = 200000;"
    echo "INSERT INTO wide_100k (id"
    for i in $(seq 1 100); do printf ", c%03d" "$i"; done
    echo ")"
    echo "WITH RECURSIVE seq(n) AS ("
    echo "  SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 100000"
    echo ")"
    echo "SELECT n"
    for i in $(seq 1 100); do
      printf ", CONCAT('r', n, '-c%03d-', REPEAT(CHAR(97 + (%d %% 26)), 20))" "$i" "$i"
    done
    echo " FROM seq;"
    echo ""
    echo "SELECT COUNT(*) AS wide_rows FROM wide_100k;"
  } > "$f"
  echo "  生成 $f"
}

gen_narrow() {
  local f="$OUT_DIR/02_narrow_10m.sql"
  {
    echo "-- 数据集 2：窄大表（4 列，1000 万行）"
    echo "-- 用途：P0-1 大结果集（1000 万行无 LIMIT）、P1-5 导出、P1-6 并发查询"
    echo "DROP TABLE IF EXISTS narrow_10m;"
    echo "CREATE TABLE narrow_10m ("
    echo "  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,"
    echo "  name VARCHAR(50) NOT NULL,"
    echo "  value DECIMAL(10,2) NOT NULL,"
    echo "  created_at DATETIME NOT NULL"
    echo ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;"
    echo ""
    echo "-- 1000 万行：100 万序号 x 10 行交叉连接，避免递归深度上限。"
    echo "SET SESSION cte_max_recursion_depth = 1100000;"
    echo "INSERT INTO narrow_10m (name, value, created_at)"
    echo "WITH RECURSIVE seq(n) AS ("
    echo "  SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 1000000"
    echo ")"
    echo "SELECT"
    echo "  CONCAT('name-', s.n, '-', t.k),"
    echo "  ROUND(MOD(s.n * 37 + t.k * 11, 100000) / 100.0, 2),"
    echo "  TIMESTAMPADD(SECOND, s.n * 10 + t.k, '2020-01-01 00:00:00')"
    echo "FROM seq s"
    echo "CROSS JOIN (SELECT 1 AS k UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4"
    echo "            UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7"
    echo "            UNION ALL SELECT 8 UNION ALL SELECT 9 UNION ALL SELECT 10) t;"
    echo ""
    echo "SELECT COUNT(*) AS narrow_rows FROM narrow_10m;"
  } > "$f"
  echo "  生成 $f"
}

gen_bigtext() {
  local f="$OUT_DIR/03_bigtext_50k.sql"
  {
    echo "-- 数据集 3：大字段表（TEXT 约 10KB/行，5 万行）"
    echo "-- 用途：P0-1 大字段渲染（lazy_big_fields 开关）、P0-3 内存泄漏"
    echo "DROP TABLE IF EXISTS bigtext_50k;"
    echo "CREATE TABLE bigtext_50k ("
    echo "  id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,"
    echo "  title VARCHAR(200) NOT NULL,"
    echo "  body TEXT NOT NULL,"
    echo "  bytes INT UNSIGNED NOT NULL"
    echo ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;"
    echo ""
    echo "-- 每行 body 约 10KB（10 段 x 约 1KB）。"
    echo "SET SESSION cte_max_recursion_depth = 60000;"
    echo "INSERT INTO bigtext_50k (title, body, bytes)"
    echo "WITH RECURSIVE seq(n) AS ("
    echo "  SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 50000"
    echo ")"
    echo "SELECT"
    echo "  CONCAT('doc-', n),"
    echo "  REPEAT(CONCAT('payload-', n, '-', REPEAT('x', 970)), 10),"
    echo "  10000"
    echo "FROM seq;"
    echo ""
    echo "SELECT COUNT(*) AS bigtext_rows, AVG(LENGTH(body)) AS avg_body FROM bigtext_50k;"
  } > "$f"
  echo "  生成 $f"
}

gen_many_tables() {
  local f="$OUT_DIR/04_many_tables_5000.sql"
  {
    echo "-- 数据集 4：多表库（5000 张表 t_0001 ~ t_5000，每张 3 列）"
    echo "-- 用途：P1-7 对象浏览器展开与搜索响应"
    echo "-- 每张表 10 行数据，保证展开后能取到内容。"
    for i in $(seq 1 5000); do
      t=$(printf "t_%04d" "$i")
      echo "DROP TABLE IF EXISTS $t;"
      echo "CREATE TABLE $t (id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY, label VARCHAR(50) NOT NULL, amount DECIMAL(10,2) NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;"
      echo "INSERT INTO $t (label, amount) VALUES ('a', 1.00), ('b', 2.00), ('c', 3.00), ('d', 4.00), ('e', 5.00), ('f', 6.00), ('g', 7.00), ('h', 8.00), ('i', 9.00), ('j', 10.00);"
    done
    echo "SELECT COUNT(*) AS tables_created FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name LIKE 't\\_%';"
  } > "$f"
  echo "  生成 $f"
}

gen_mixed() {
  local f="$OUT_DIR/05_mixed_500k.sql"
  {
    echo "-- 数据集 5：混合类型（JSON / BLOB / DECIMAL / DATETIME，50 万行）"
    echo "-- 用途：P1-4 网格编辑与批量提交、P1-5 多格式导出"
    echo "DROP TABLE IF EXISTS mixed_500k;"
    echo "CREATE TABLE mixed_500k ("
    echo "  id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,"
    echo "  uid CHAR(36) NOT NULL,"
    echo "  amount DECIMAL(12,2) NOT NULL,"
    echo "  ratio DOUBLE NOT NULL,"
    echo "  flag TINYINT(1) NOT NULL,"
    echo "  payload JSON NOT NULL,"
    echo "  blob_data BLOB NOT NULL,"
    echo "  created_at DATETIME NOT NULL,"
    echo "  updated_at DATETIME NOT NULL,"
    echo "  note VARCHAR(255) DEFAULT NULL"
    echo ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;"
    echo ""
    echo "SET SESSION cte_max_recursion_depth = 600000;"
    echo "INSERT INTO mixed_500k (uid, amount, ratio, flag, payload, blob_data, created_at, updated_at, note)"
    echo "WITH RECURSIVE seq(n) AS ("
    echo "  SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 500000"
    echo ")"
    echo "SELECT"
    echo "  UUID(),"
    echo "  ROUND(MOD(n * 137, 10000000) / 100.0, 2),"
    echo "  ROUND(MOD(n * 17, 10000) / 100.0, 4),"
    echo "  MOD(n, 2),"
    echo "  JSON_OBJECT('id', n, 'tags', JSON_ARRAY('a', 'b'), 'score', MOD(n, 100)),"
    echo "  UNHEX(SHA2(CONCAT('blob-', n), 256)),"
    echo "  TIMESTAMPADD(SECOND, n, '2021-01-01 00:00:00'),"
    echo "  TIMESTAMPADD(SECOND, n * 2, '2021-01-01 00:00:00'),"
    echo "  CONCAT('note-', n)"
    echo "FROM seq;"
    echo ""
    echo "SELECT COUNT(*) AS mixed_rows FROM mixed_500k;"
  } > "$f"
  echo "  生成 $f"
}

TARGETS=("$@")
if [ ${#TARGETS[@]} -eq 0 ]; then
  TARGETS=(wide narrow bigtext many_tables mixed)
fi

echo "== 生成数据集到 ${OUT_DIR}（目标库 ${DB}）=="
for t in "${TARGETS[@]}"; do
  case "$t" in
    wide) gen_wide ;;
    narrow) gen_narrow ;;
    bigtext) gen_bigtext ;;
    many_tables) gen_many_tables ;;
    mixed) gen_mixed ;;
    *) echo "未知数据集: $t" >&2; exit 1 ;;
  esac
done

echo ""
echo "== 产物 =="
ls -lh "$OUT_DIR"
