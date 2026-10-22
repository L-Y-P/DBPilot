#!/usr/bin/env bash
# Start throwaway MySQL and PostgreSQL instances that REQUIRE TLS.
#
# Used by rust/tests/tls_mysql.rs, tls_postgres.rs, tls_mtls.rs and
# tls_verify_ca_nosan.rs to verify that verify-ca / verify-full really work
# against a server that refuses plaintext, and that mutual TLS (a required client
# certificate) is enforced. Nothing here touches the developer's normal MySQL
# (3306) or PostgreSQL (5432).
#
# 凭据策略：仓库里不保存任何密码。每次 `up` 都用 openssl rand 生成随机密码，
# 写到 <fixture 目录>/credentials.env（只在本机 /tmp 下，权限 600），并打印
# “source 这个文件”的提示。测试从环境变量读取，见 rust/tests/common/mod.rs：
#
#   DBPILOT_TLS_MYSQL_HOST / _PORT / _USER / _PASSWORD        （普通 TLS 账号）
#   DBPILOT_TLS_MYSQL_MTLS_USER / _PASSWORD                   （mTLS 账号，REQUIRE X509）
#   DBPILOT_TLS_NOSAN_PORT / _USER / _PASSWORD / _CA          （无 SAN 证书回归用例，
#                                                              需自己起 3308 实例，本脚本不代管）
#   DBPILOT_TLS_PG_HOST / _PORT / _USER / _PASSWORD           （普通 TLS 角色）
#   DBPILOT_TLS_PG_MTLS_USER / _PASSWORD                      （mTLS 角色，cert 认证）
#   DBPILOT_TLS_MYSQL_DIR / DBPILOT_TLS_PG_DIR                （证书目录）
#
# The mTLS part uses a second account per server:
#   MySQL  user "mtlstest" with REQUIRE X509
#   PG     role "mtlstest" with cert clientcert=verify-full (CN must match)
# Both authenticate with the fixture client certificate only (no password).
#
# Usage:
#   tools/tls_fixture.sh up     # create certs, init data dirs, start both
#   tools/tls_fixture.sh down   # stop both
#   tools/tls_fixture.sh status
set -euo pipefail

MYSQL_BASE=${RMA_TLS_MYSQL_BASE:-/tmp/rma-tls-mysql}
PG_BASE=${RMA_TLS_PG_BASE:-/tmp/rma-tls-pg}
MYSQL_PORT=${DBPILOT_TLS_MYSQL_PORT:-3307}
PG_PORT=${DBPILOT_TLS_PG_PORT:-5434}
MYSQLD=${MYSQLD:-/opt/local/lib/mysql8/bin/mysqld}
MYSQL_CLIENT=${MYSQL_CLIENT:-/opt/local/bin/mysql}
PG_BIN=${PG_BIN:-/opt/local/lib/postgresql17/bin}

# 随机密码：只在本次 fixture 生命周期内有效，写进 credentials.env。
rand_password() {
  openssl rand -hex 16
}

MYSQL_TLS_PASSWORD=$(rand_password)
MYSQL_MTLS_PASSWORD=$(rand_password)
PG_TLS_PASSWORD=$(rand_password)
PG_MTLS_PASSWORD=$(rand_password)

write_credentials() {
  # 两个 fixture 目录都写一份，方便单独 source。
  local file="$1"
  cat > "$file" <<EOF
# 由 tools/tls_fixture.sh 生成的临时凭据（仅本机 /tmp，不要提交）。
# 用法： source "$file"
export DBPILOT_TLS_MYSQL_HOST=127.0.0.1
export DBPILOT_TLS_MYSQL_PORT=$MYSQL_PORT
export DBPILOT_TLS_MYSQL_USER=tlstest
export DBPILOT_TLS_MYSQL_PASSWORD=$MYSQL_TLS_PASSWORD
export DBPILOT_TLS_MYSQL_MTLS_USER=mtlstest
export DBPILOT_TLS_MYSQL_MTLS_PASSWORD=$MYSQL_MTLS_PASSWORD
export DBPILOT_TLS_MYSQL_DIR="$MYSQL_BASE/certs"
export DBPILOT_TLS_PG_HOST=127.0.0.1
export DBPILOT_TLS_PG_PORT=$PG_PORT
export DBPILOT_TLS_PG_USER=postgres
export DBPILOT_TLS_PG_PASSWORD=$PG_TLS_PASSWORD
export DBPILOT_TLS_PG_MTLS_USER=mtlstest
export DBPILOT_TLS_PG_MTLS_PASSWORD=$PG_MTLS_PASSWORD
export DBPILOT_TLS_PG_DIR="$PG_BASE/certs"
EOF
  chmod 600 "$file"
}

# One CA + a server certificate + a client certificate per fixture.
# The client cert uses CN=mtlstest so PostgreSQL's cert auth can map it to the
# role of the same name.
make_certs() {
  local dir="$1" cn="$2"
  mkdir -p "$dir"
  ( cd "$dir"
    openssl req -x509 -newkey rsa:2048 -nodes -keyout ca-key.pem -out ca.pem \
      -days 3 -subj "/CN=$cn" 2>/dev/null
    openssl req -newkey rsa:2048 -nodes -keyout server-key.pem -out server.csr \
      -subj "/CN=localhost" 2>/dev/null
    printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n' > server.ext
    openssl x509 -req -in server.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial \
      -out server-cert.pem -days 3 -extfile server.ext 2>/dev/null
    # Mutual TLS client certificate (no passphrase: the tests read it directly).
    openssl req -newkey rsa:2048 -nodes -keyout client-key.pem -out client.csr \
      -subj "/CN=mtlstest" 2>/dev/null
    printf 'basicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=clientAuth\n' > client.ext
    openssl x509 -req -in client.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial \
      -out client-cert.pem -days 3 -extfile client.ext 2>/dev/null
    chmod 600 server-key.pem ca-key.pem client-key.pem
  )
}

mysql_running() {
  [ -f "$MYSQL_BASE/run/mysqld.pid" ] &&
    kill -0 "$(cat "$MYSQL_BASE/run/mysqld.pid")" 2>/dev/null
}

up_mysql() {
  # Fixtures created before mTLS support have no client cert: recreate them so
  # the mTLS account/cert pair exists. The marker also makes re-runs cheap.
  if [ -f "$MYSQL_BASE/.mtls-ready" ] && [ -f "$MYSQL_BASE/data/auto.cnf" ]; then
    echo "MySQL TLS/mTLS fixture already initialised"
  else
    rm -rf "$MYSQL_BASE"; mkdir -p "$MYSQL_BASE/data" "$MYSQL_BASE/run"
    make_certs "$MYSQL_BASE/certs" rma-test-ca
    "$MYSQLD" --initialize-insecure --datadir="$MYSQL_BASE/data" --basedir=/opt/local/lib/mysql8 > "$MYSQL_BASE/init.log" 2>&1
    cat > "$MYSQL_BASE/my.cnf" <<EOF
[mysqld]
port=$MYSQL_PORT
bind-address=127.0.0.1
datadir=$MYSQL_BASE/data
socket=$MYSQL_BASE/run/mysqld.sock
pid-file=$MYSQL_BASE/run/mysqld.pid
log-error=$MYSQL_BASE/error.log
ssl-ca=$MYSQL_BASE/certs/ca.pem
ssl-cert=$MYSQL_BASE/certs/server-cert.pem
ssl-key=$MYSQL_BASE/certs/server-key.pem
require_secure_transport=ON
skip-name-resolve
EOF
    touch "$MYSQL_BASE/.mtls-ready"
  fi
  if ! mysql_running; then
    "$MYSQLD" --defaults-file="$MYSQL_BASE/my.cnf" --user="$(whoami)" > /dev/null 2>&1 &
    sleep 6
  fi
  # 账号密码用本次随机值（已导出到 credentials.env）；重跑时用 IF NOT EXISTS
  # 之后再用 ALTER USER 保证密码与本次生成的一致。
  "$MYSQL_CLIENT" --socket="$MYSQL_BASE/run/mysqld.sock" -uroot <<SQL
CREATE USER IF NOT EXISTS 'tlstest'@'127.0.0.1' IDENTIFIED WITH caching_sha2_password BY '$MYSQL_TLS_PASSWORD';
ALTER USER 'tlstest'@'127.0.0.1' IDENTIFIED WITH caching_sha2_password BY '$MYSQL_TLS_PASSWORD';
GRANT ALL PRIVILEGES ON *.* TO 'tlstest'@'127.0.0.1';
CREATE USER IF NOT EXISTS 'mtlstest'@'127.0.0.1' IDENTIFIED WITH caching_sha2_password BY '$MYSQL_MTLS_PASSWORD' REQUIRE X509;
ALTER USER 'mtlstest'@'127.0.0.1' IDENTIFIED WITH caching_sha2_password BY '$MYSQL_MTLS_PASSWORD' REQUIRE X509;
GRANT ALL PRIVILEGES ON *.* TO 'mtlstest'@'127.0.0.1';
CREATE DATABASE IF NOT EXISTS tlsdemo;
FLUSH PRIVILEGES;
SQL
  echo "MySQL TLS fixture on 127.0.0.1:$MYSQL_PORT (mTLS user mtlstest, REQUIRE X509)"
}

pg_running() {
  [ -f "$PG_BASE/data/PG_VERSION" ] &&
    "$PG_BIN/pg_ctl" -D "$PG_BASE/data" status > /dev/null 2>&1
}

up_pg() {
  if [ -f "$PG_BASE/.mtls-ready" ] && [ -f "$PG_BASE/data/PG_VERSION" ]; then
    echo "PostgreSQL TLS/mTLS fixture already initialised"
  else
    rm -rf "$PG_BASE"; mkdir -p "$PG_BASE/data" "$PG_BASE/run"
    make_certs "$PG_BASE/certs" rma-pg-test-ca
    "$PG_BIN/initdb" -D "$PG_BASE/data" -U postgres --auth=trust > "$PG_BASE/init.log" 2>&1
    cp "$PG_BASE/certs/server-cert.pem" "$PG_BASE/data/server.crt"
    cp "$PG_BASE/certs/server-key.pem" "$PG_BASE/data/server.key"
    # The CA is also needed on the server side to verify client certificates.
    cp "$PG_BASE/certs/ca.pem" "$PG_BASE/data/ca.pem"
    chmod 600 "$PG_BASE/data/server.key" "$PG_BASE/data/ca.pem"
    cat >> "$PG_BASE/data/postgresql.conf" <<EOF
port = $PG_PORT
listen_addresses = '127.0.0.1'
unix_socket_directories = '$PG_BASE/run'
ssl = on
ssl_cert_file = 'server.crt'
ssl_key_file = 'server.key'
ssl_ca_file = 'ca.pem'
EOF
    # mTLS: role mtlstest must present a valid client certificate whose CN is
    # mtlstest; everyone else keeps the plain-TLS trust rule used by the
    # existing TLS tests.
    cat > "$PG_BASE/data/pg_hba.conf" <<'HBA'
hostssl all "mtlstest" 127.0.0.1/32 cert clientcert=verify-full
hostssl all all 127.0.0.1/32 trust
hostnossl all all 127.0.0.1/32 reject
HBA
    touch "$PG_BASE/.mtls-ready"
  fi
  if ! pg_running; then
    "$PG_BIN/pg_ctl" -D "$PG_BASE/data" -l "$PG_BASE/pg.log" start > /dev/null 2>&1
    sleep 1
  fi
  # Role for the client certificate (idempotent: duplicate errors are ignored).
  "$PG_BIN/psql" -h 127.0.0.1 -p "$PG_PORT" -U postgres -d postgres \
    -c "CREATE ROLE mtlstest LOGIN" > /dev/null 2>&1 || true
  # trust 认证下密码不参与校验，但仍然设置一次，保持“账号一定有密码”的语义。
  "$PG_BIN/psql" -h 127.0.0.1 -p "$PG_PORT" -U postgres -d postgres \
    -c "ALTER ROLE mtlstest PASSWORD '$PG_MTLS_PASSWORD'" > /dev/null 2>&1 || true
  "$PG_BIN/psql" -h 127.0.0.1 -p "$PG_PORT" -U postgres -d postgres \
    -c "ALTER ROLE postgres PASSWORD '$PG_TLS_PASSWORD'" > /dev/null 2>&1 || true
  echo "PostgreSQL TLS fixture on 127.0.0.1:$PG_PORT (mTLS role mtlstest, cert auth)"
}

down() {
  if [ -f "$MYSQL_BASE/run/mysqld.pid" ]; then
    kill "$(cat "$MYSQL_BASE/run/mysqld.pid")" 2>/dev/null || true
  fi
  if [ -f "$PG_BASE/data/PG_VERSION" ]; then
    "$PG_BIN/pg_ctl" -D "$PG_BASE/data" stop -m fast > /dev/null 2>&1 || true
  fi
  rm -f "$MYSQL_BASE/credentials.env" "$PG_BASE/credentials.env"
  echo "stopped"
}

action="${1:-up}"
case "$action" in
  up)
    up_mysql
    up_pg
    write_credentials "$MYSQL_BASE/credentials.env"
    write_credentials "$PG_BASE/credentials.env"
    echo ""
    echo "凭据已写入 $MYSQL_BASE/credentials.env（随机生成，仅本机）："
    echo "  source $MYSQL_BASE/credentials.env"
    echo "然后运行，例如： cargo test --test tls_mysql -- --nocapture"
    ;;
  down) down ;;
  status)
    echo -n "MySQL  $MYSQL_PORT: "; (lsof -nP -iTCP:$MYSQL_PORT -sTCP:LISTEN > /dev/null 2>&1 && echo up) || echo down
    echo -n "PG     $PG_PORT: "; (lsof -nP -iTCP:$PG_PORT -sTCP:LISTEN > /dev/null 2>&1 && echo up) || echo down
    ;;
  *) echo "usage: $0 {up|down|status}"; exit 2 ;;
esac
