#!/usr/bin/env bash
# =============================================================================
# tools/run_live_tests.sh
#
# 本地 / CI 共用的 Rust 测试入口：先跑 hermetic 套件，再跑需要真实数据库的
# live 套件。
#
#   hermetic:  cd rust && cargo test --offline -- --test-threads=1
#   live:      cd rust && cargo test --offline \
#                --test live_script --test live_databases --test live_import \
#                --test live_cancel_processlist -- --ignored --test-threads=1
#
# 行为：
#   * 跑之前先等 MySQL / PostgreSQL 端口就绪；超时即失败（退出码 3）。
#   * 任一步非 0 立即停止，打印该步日志尾部与汇总。
#   * 每步完整输出写入 rust/target/live-test-logs/NN-<step>.log，
#     可用 RMA_LOG_DIR 覆盖；不使用 /tmp 硬编码路径。
#   * CARGO_HOME 不做任何覆盖，沿用环境（默认值即可）。
#
# 兼容 bash 3.2（macOS 自带 /usr/bin/env bash），不使用 bash 4+ 语法。
#
# 用法：
#   tools/run_live_tests.sh [选项]
#
# 选项：
#   --skip-hermetic   只跑 live 套件
#   --skip-live       只跑 hermetic 套件（快速冒烟）
#   --no-wait         不等数据库端口（例如 compose 已用 --wait 起好）
#   --dry-run         只打印将执行的命令，不执行、不等端口
#   -h, --help        显示帮助
#
# 环境变量（全部可覆盖）：
#   MYSQL_HOST=127.0.0.1  MYSQL_PORT=3306  MYSQL_USER=root  MYSQL_PASSWORD=""
#   PG_HOST=127.0.0.1     PG_PORT=5432     PG_USER=postgres PG_PASSWORD=""
#   PG_DB=rustmyadmin_demo
#   RMA_WAIT_TIMEOUT=60      端口等待超时（秒）
#   RMA_LIVE_TESTS           覆盖 live 测试二进制列表（空格分隔）
#   RMA_LOG_DIR              日志目录，默认 rust/target/live-test-logs
#   RMA_OFFLINE=0            去掉 cargo 的 --offline（默认 1，保留）
#   RMA_SAKILA_DUMP          透传给 live_script 的 sakila dump 路径（缺失即 SKIP）
#
# 关于凭据：仓库里不保存任何账号密码。脚本里这些变量只用于端口就绪探测和
# mysqladmin/psql 的尽力探测，**默认密码为空**（docker-compose.live.yml 起的
# MySQL 用 MYSQL_ALLOW_EMPTY_PASSWORD、PostgreSQL 用 trust）。
#
# 真正连库的是 Rust 测试，它们读取另一组变量（见 rust/tests/common/mod.rs）：
#   DBPILOT_TEST_MYSQL_{HOST,PORT,USER,PASSWORD,DB}
#   DBPILOT_TEST_PG_{HOST,PORT,USER,PASSWORD,DB}
# 脚本会把 MYSQL_* / PG_* 映射成对应的 DBPILOT_TEST_* 再导出，所以只配一套
# 环境变量就能同时驱动脚本探测和测试连接。
# =============================================================================
set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
RUST_DIR="$REPO_ROOT/rust"

# ---- 可覆盖的端点配置 -------------------------------------------------------
MYSQL_HOST=${MYSQL_HOST:-127.0.0.1}
MYSQL_PORT=${MYSQL_PORT:-3306}
MYSQL_USER=${MYSQL_USER:-root}
MYSQL_PASSWORD=${MYSQL_PASSWORD:-}

PG_HOST=${PG_HOST:-127.0.0.1}
PG_PORT=${PG_PORT:-5432}
PG_USER=${PG_USER:-postgres}
PG_PASSWORD=${PG_PASSWORD:-}
PG_DB=${PG_DB:-rustmyadmin_demo}

WAIT_TIMEOUT=${RMA_WAIT_TIMEOUT:-60}
LIVE_TESTS=${RMA_LIVE_TESTS:-"live_script live_databases live_import live_cancel_processlist"}
LOG_DIR=${RMA_LOG_DIR:-"$RUST_DIR/target/live-test-logs"}
OFFLINE=${RMA_OFFLINE:-1}

# ---- 运行开关 ---------------------------------------------------------------
DO_HERMETIC=1
DO_LIVE=1
DO_WAIT=1
DRY_RUN=0

usage() {
    sed -n '2,51p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --skip-hermetic) DO_HERMETIC=0 ;;
        --skip-live)     DO_LIVE=0 ;;
        --no-wait)       DO_WAIT=0 ;;
        --dry-run)       DRY_RUN=1; DO_WAIT=0 ;;
        -h|--help)       usage ;;
        *)
            echo "未知参数: $1（用 --help 查看用法）" >&2
            exit 2
            ;;
    esac
    shift
done

# live 测试二进制名安全性校验（避免拼接进 cargo 参数的可疑内容）
for t in $LIVE_TESTS; do
    case "$t" in
        *[!A-Za-z0-9_]*)
            echo "RMA_LIVE_TESTS 含有非法测试名: $t" >&2
            exit 2
            ;;
    esac
done

if [ ! -d "$RUST_DIR" ]; then
    echo "找不到 Rust crate 目录: $RUST_DIR" >&2
    exit 2
fi

# ---- 汇总 -------------------------------------------------------------------
STEP_NO=0
SUMMARY=""
FAILED_STEP=""

record() {
    # $1=名称 $2=状态 $3=耗时
    SUMMARY="${SUMMARY}$1|$2|$3
"
}

print_summary() {
    echo ""
    echo "=================== 测试汇总 ==================="
    if [ -z "$SUMMARY" ]; then
        echo "  (没有执行任何步骤)"
    else
        printf '%s' "$SUMMARY" | while IFS='|' read -r name status detail; do
            [ -n "$name" ] || continue
            printf '  %-24s %-12s %s\n' "$name" "$status" "$detail"
        done
    fi
    echo "  日志目录: $LOG_DIR"
    echo "  端点: MySQL $MYSQL_HOST:$MYSQL_PORT (user=$MYSQL_USER) | PostgreSQL $PG_HOST:$PG_PORT (user=$PG_USER, db=$PG_DB)"
    if [ -n "$FAILED_STEP" ]; then
        echo "结果: FAILED（失败步骤: ${FAILED_STEP}）"
    else
        echo "结果: OK"
    fi
    echo "==============================================="
}

fail_summary() {
    # $1=原因 $2=退出码
    reason=$1
    code=$2
    FAILED_STEP=$reason
    echo ""
    echo "!! 失败: $reason" >&2
    print_summary
    exit "$code"
}

# ---- 端口探测 ---------------------------------------------------------------
USE_NC=0
if command -v nc >/dev/null 2>&1; then
    USE_NC=1
fi

port_open() {
    host=$1
    port=$2
    if [ "$USE_NC" = "1" ]; then
        nc -z -w 2 "$host" "$port" >/dev/null 2>&1
    else
        # bash 内建 /dev/tcp（bash 3.2 亦支持），重定向在子 shell 中执行
        (exec 3<>"/dev/tcp/$host/$port") >/dev/null 2>&1
    fi
}

wait_for_port() {
    # $1=标签 $2=host $3=port
    label=$1
    host=$2
    port=$3
    echo "==> 等待 $label 就绪 ($host:$port)，超时 ${WAIT_TIMEOUT}s"
    started=$(date +%s)
    while : ; do
        if port_open "$host" "$port"; then
            echo "    OK: $label 端口已开放"
            return 0
        fi
        now=$(date +%s)
        elapsed=$((now - started))
        if [ "$elapsed" -ge "$WAIT_TIMEOUT" ]; then
            return 1
        fi
        if [ $((elapsed % 5)) -eq 0 ]; then
            echo "    ... 已等待 ${elapsed}s"
        fi
        sleep 1
    done
}

best_effort_probe() {
    # 有客户端工具时做一次更深的探测，仅提示，不影响退出码。
    if command -v pg_isready >/dev/null 2>&1; then
        if pg_isready -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" >/dev/null 2>&1; then
            echo "    pg_isready: PostgreSQL 接受连接"
        else
            echo "    提示: pg_isready 未就绪（端口已开放，稍后测试可能仍可用）"
        fi
    fi
    if command -v psql >/dev/null 2>&1; then
        if PGPASSWORD="$PG_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d postgres -tAc \
            "SELECT 1 FROM pg_database WHERE datname='$PG_DB'" 2>/dev/null | grep -q 1; then
            echo "    提示: PostgreSQL 库 $PG_DB 已存在"
        else
            echo "    提示: 未确认 PostgreSQL 库 $PG_DB 存在；live_databases::postgres_instance_tree 需要它"
            echo "          （本地: docker compose -f docker-compose.live.yml up -d；或 psql -c 'CREATE DATABASE $PG_DB'）"
        fi
    fi
    if command -v mysqladmin >/dev/null 2>&1; then
        if MYSQL_PWD="$MYSQL_PASSWORD" mysqladmin -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" ping >/dev/null 2>&1; then
            echo "    mysqladmin ping: MySQL 接受连接"
        else
            echo "    提示: mysqladmin ping 未通过（端口已开放，稍后测试可能仍可用）"
        fi
    fi
}

# ---- cargo 步骤 -------------------------------------------------------------
cargo_flags() {
    if [ "$OFFLINE" = "1" ]; then
        echo --offline
    fi
}

run_step() {
    # $1=步骤名 $2=工作目录，其后是命令与参数
    name=$1
    workdir=$2
    shift 2
    STEP_NO=$((STEP_NO + 1))
    log="$LOG_DIR/$(printf '%02d' "$STEP_NO")-$name.log"

    echo ""
    echo "=== [$STEP_NO] $name ==="
    echo "  目录: $workdir"
    echo "  命令: $*"

    if [ "$DRY_RUN" = "1" ]; then
        record "$name" "DRY-RUN" "-"
        echo "  (dry-run) 未执行"
        return 0
    fi

    started=$(date +%s)
    ( cd "$workdir" && "$@" ) >"$log" 2>&1
    rc=$?
    ended=$(date +%s)
    dur=$((ended - started))

    if [ "$rc" -ne 0 ]; then
        record "$name" "FAIL(rc=$rc)" "${dur}s"
        echo "  x 失败 (rc=$rc, ${dur}s)，完整日志: $log"
        echo "  --- 日志末尾 40 行 ---"
        tail -n 40 "$log" | sed 's/^/  | /'
        fail_summary "$name 失败 (rc=$rc)，见 $log" 1
    fi

    record "$name" "PASS" "${dur}s"
    echo "  ok 通过 (${dur}s)，完整日志: $log"
    grep -E '^test result:' "$log" | sed 's/^/  | /' || true

    # live_script 的 sakila 用例在 dump 缺失时按设计 SKIP，单独提示
    if grep -q 'SKIP: sakila dump not found' "$log" 2>/dev/null; then
        echo "  note: sakila dump 缺失，mysql_official_sakila_dump_* 已按设计 SKIP"
    fi
    return 0
}

# 把脚本的端点变量映射成测试读取的 DBPILOT_TEST_* 变量（只在未显式设置时），
# 这样“只配一套环境变量”就能同时驱动端口探测与 Rust 测试的连接。
export_test_env() {
    : "${DBPILOT_TEST_MYSQL_HOST:=$MYSQL_HOST}"
    : "${DBPILOT_TEST_MYSQL_PORT:=$MYSQL_PORT}"
    : "${DBPILOT_TEST_MYSQL_USER:=$MYSQL_USER}"
    : "${DBPILOT_TEST_MYSQL_PASSWORD:=$MYSQL_PASSWORD}"
    : "${DBPILOT_TEST_MYSQL_DB:=rustmyadmin_demo}"

    : "${DBPILOT_TEST_PG_HOST:=$PG_HOST}"
    : "${DBPILOT_TEST_PG_PORT:=$PG_PORT}"
    : "${DBPILOT_TEST_PG_USER:=$PG_USER}"
    : "${DBPILOT_TEST_PG_PASSWORD:=$PG_PASSWORD}"
    : "${DBPILOT_TEST_PG_DB:=$PG_DB}"

    export DBPILOT_TEST_MYSQL_HOST DBPILOT_TEST_MYSQL_PORT DBPILOT_TEST_MYSQL_USER
    export DBPILOT_TEST_MYSQL_PASSWORD DBPILOT_TEST_MYSQL_DB
    export DBPILOT_TEST_PG_HOST DBPILOT_TEST_PG_PORT DBPILOT_TEST_PG_USER
    export DBPILOT_TEST_PG_PASSWORD DBPILOT_TEST_PG_DB
}

# ---- 主流程 -----------------------------------------------------------------
echo "==============================================="
echo " DBPilot live 测试入口"
echo " 仓库根: $REPO_ROOT"
echo " crate:   $RUST_DIR"
echo " 模式:    hermetic=$DO_HERMETIC live=$DO_LIVE wait=$DO_WAIT dry-run=$DRY_RUN offline=$OFFLINE"
echo " bash:    ${BASH_VERSION:-unknown}"
echo " 探测:    $(if [ "$USE_NC" = "1" ]; then echo 'nc -z'; else echo '/dev/tcp'; fi)"
echo "==============================================="

export MYSQL_HOST MYSQL_PORT MYSQL_USER MYSQL_PASSWORD
export PG_HOST PG_PORT PG_USER PG_PASSWORD PG_DB
export_test_env

if [ "$DRY_RUN" = "0" ]; then
    mkdir -p "$LOG_DIR" || { echo "无法创建日志目录: $LOG_DIR" >&2; exit 2; }
fi

if [ "$DO_WAIT" = "1" ]; then
    if ! wait_for_port "MySQL" "$MYSQL_HOST" "$MYSQL_PORT"; then
        echo "等待 MySQL ($MYSQL_HOST:$MYSQL_PORT) 超时（${WAIT_TIMEOUT}s）。" >&2
        echo "  提示: docker compose -f docker-compose.live.yml up -d --wait；" >&2
        echo "        或本地已有服务时用 --no-wait 跳过。" >&2
        fail_summary "MySQL 端口等待超时" 3
    fi
    if ! wait_for_port "PostgreSQL" "$PG_HOST" "$PG_PORT"; then
        echo "等待 PostgreSQL ($PG_HOST:$PG_PORT) 超时（${WAIT_TIMEOUT}s）。" >&2
        echo "  提示: docker compose -f docker-compose.live.yml up -d --wait；" >&2
        echo "        或本地已有服务时用 --no-wait 跳过。" >&2
        fail_summary "PostgreSQL 端口等待超时" 3
    fi
    best_effort_probe
else
    echo "==> 跳过端口等待（--no-wait/--dry-run）"
fi

if [ "$DO_HERMETIC" = "1" ]; then
    # shellcheck disable=SC2046
    run_step "hermetic" "$RUST_DIR" cargo test $(cargo_flags) -- --test-threads=1
fi

if [ "$DO_LIVE" = "1" ]; then
    set -- cargo test
    if [ "$OFFLINE" = "1" ]; then
        set -- "$@" --offline
    fi
    for t in $LIVE_TESTS; do
        set -- "$@" --test "$t"
    done
    set -- "$@" -- --ignored --test-threads=1
    run_step "live" "$RUST_DIR" "$@"
fi

print_summary
exit 0
