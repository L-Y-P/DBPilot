#!/usr/bin/env bash
# ============================================================================
#  tools/perf/load_datasets.sh
#
#  把 gen_datasets.sh 生成的全部数据集导入 MySQL（默认 dbpilot_perf）。
#
#  用法：
#    bash tools/perf/load_datasets.sh
#    MYSQL_HOST=127.0.0.1 MYSQL_USER=root MYSQL_PASSWORD=*** bash tools/perf/load_datasets.sh
#
#  前置：先跑 tools/perf/gen_datasets.sh（或在下面加 --gen）。
#
#  说明：
#    * 幂等：每个 SQL 文件自己带 DROP TABLE IF EXISTS；
#    * 1000 万行/5000 张表的导入耗时以分钟计（本机实测 83s / 36s）；
#    * 导入前确认磁盘至少剩 2GB（数据文件在 MySQL 数据目录）。
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
DIR="${OUT_DIR:-$ROOT/out/perf-datasets}"
DB="${PERF_DB:-dbpilot_perf}"
HOST="${MYSQL_HOST:-127.0.0.1}"
PORT="${MYSQL_PORT:-3306}"
USER="${MYSQL_USER:-root}"
PASS="${MYSQL_PASSWORD:-}"

if [ "${1:-}" = "--gen" ]; then
  bash "$HERE/gen_datasets.sh"
fi

if [ ! -d "$DIR" ]; then
  echo "找不到数据集目录 $DIR：先跑 bash tools/perf/gen_datasets.sh" >&2
  exit 1
fi

mysql_args=(-h"$HOST" -P"$PORT" -u"$USER")
# 注意用 if 而不是 [ ... ] && ...：脚本开头是 set -e，
# 后者在 PASS 为空时返回 1，会让整个脚本直接退出。
if [ -n "$PASS" ]; then
  mysql_args+=(-p"$PASS")
fi

echo "== 导入到 $DB @ $HOST:$PORT =="
mysql "${mysql_args[@]}" -e "CREATE DATABASE IF NOT EXISTS \`$DB\` DEFAULT CHARSET utf8mb4;"

for f in "$DIR"/0*.sql; do
  echo "-- $(basename "$f")"
  start=$(date +%s)
  mysql "${mysql_args[@]}" "$DB" < "$f" 2>/dev/null | tail -1 | sed 's/^/   /'
  echo "   耗时 $(( $(date +%s) - start ))s"
done

echo ""
echo "== 校验行数 =="
mysql "${mysql_args[@]}" -N "$DB" -e "
  SELECT 'wide_100k', COUNT(*) FROM wide_100k
  UNION ALL SELECT 'narrow_10m', COUNT(*) FROM narrow_10m
  UNION ALL SELECT 'bigtext_50k', COUNT(*) FROM bigtext_50k
  UNION ALL SELECT 'mixed_500k', COUNT(*) FROM mixed_500k
  UNION ALL SELECT 'many_tables', COUNT(*) FROM information_schema.TABLES
    WHERE TABLE_SCHEMA='$DB' AND TABLE_NAME LIKE 't\\_%';" 2>/dev/null
echo ""
echo "期望：100000 / 10000000 / 50000 / 500000 / 5000"
