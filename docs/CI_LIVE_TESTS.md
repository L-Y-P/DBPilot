# Rust live 测试与 CI 说明

本文说明 `rust/`（Rust workspace：主 crate `rust_myadmin_core` + `crates/dbpilot-core`）
的 hermetic / live 两层测试如何在本地与 CI 中运行。

> 发布仓库根就是原来的 `desktop/` 目录，因此下文所有路径都相对该根：`rust/`、
> `tools/`、`docker-compose.live.yml`、`Makefile`。

## 0. 速查

| 目的 | 命令 |
| --- | --- |
| 只跑 hermetic（不需要数据库） | `make rust-test` |
| 用 Docker 起 MySQL + PostgreSQL | `make rust-live-up` |
| 等库就绪 + hermetic + live 全套 | `make rust-live` |
| 停库并删数据卷 | `make rust-live-down` |
| 只看将要执行的命令 | `bash tools/run_live_tests.sh --dry-run` |
| 直接跑脚本（等价 make rust-live） | `bash tools/run_live_tests.sh` |

相关文件：

| 文件 | 作用 |
| --- | --- |
| `tools/run_live_tests.sh` | 唯一测试入口：等端口 → hermetic → live，任一步失败立即退出 |
| `docker-compose.live.yml` | mysql:8.4 + postgres:17，空密码 / trust 认证，带 healthcheck |
| `Makefile` | `rust-test` / `rust-live` / `rust-live-up` / `rust-live-down` |
| `tools/tls_fixture.sh` | 起需要 TLS/mTLS 的临时 MySQL / PostgreSQL，密码随机生成 |
| `rust/tests/common/mod.rs` | live 测试的端点 helper：全部从环境变量读取 |
| `docs/CI_LIVE_TESTS.md` | 本文 |

## 1. 前置条件

1. Rust 工具链（rustup + cargo）。脚本不会覆盖 `CARGO_HOME`，沿用环境默认值。
2. 本地已能 `cargo test --offline`：依赖需要在 `~/.cargo` 里。若报缺依赖，先联网跑一次
   `cd rust && cargo fetch`（CI 工作流里已有这一步）。
3. 两个数据库端点。**仓库里不保存任何账号或密码**，端点全部由环境变量提供：

   | 数据库 | 默认地址 | 默认账号 | 默认密码 | 需要的库 |
   | --- | --- | --- | --- | --- |
   | MySQL | `127.0.0.1:3306` | `root` | 空 | `rustmyadmin_demo` |
   | PostgreSQL | `127.0.0.1:5432` | `postgres` | 空 | `rustmyadmin_demo` |

   `docker-compose.live.yml` 起的实例正好匹配这套默认值（MySQL 用
   `MYSQL_ALLOW_EMPTY_PASSWORD`，PostgreSQL 用 `POSTGRES_HOST_AUTH_METHOD=trust`），
   所以“起库 + 直接跑”不需要任何密码配置。本机已有自己的数据库时，用环境变量
   指向它即可（见 2.4）。

4. （可选）Docker + Docker Compose v2，用 `docker-compose.live.yml` 一键起库。

## 2. 本地怎么跑

### 2.1 hermetic（默认 `cargo test`）

```bash
cd rust
cargo test --offline -- --test-threads=1
# 或者（在仓库根）
make rust-test
```

hermetic 套件不需要数据库，全部 live 用例都带 `#[ignore]` 因而被跳过。

### 2.2 live（需要真实数据库）

脚本默认执行的 live 命令就是下面这条：

```bash
cd rust
cargo test --offline \
  --test live_script --test live_databases --test live_import --test live_cancel_processlist \
  -- --ignored --test-threads=1
```

用脚本跑（含等待端口 + 顺序执行 + 日志隔离 + 失败摘要）：

```bash
# 库已经在跑（例如本机 MySQL/PG）：
bash tools/run_live_tests.sh

# compose 已用 --wait 起好，跳过脚本里的端口等待：
bash tools/run_live_tests.sh --no-wait

# 只想跑 live，不想重复 hermetic：
bash tools/run_live_tests.sh --skip-hermetic

# 只做 hermetic 冒烟：
bash tools/run_live_tests.sh --skip-live
```

### 2.3 脚本选项与退出码

| 选项 | 说明 |
| --- | --- |
| `--skip-hermetic` | 跳过 hermetic 步骤 |
| `--skip-live` | 跳过 live 步骤 |
| `--no-wait` | 不等待数据库端口（假定已就绪） |
| `--dry-run` | 只打印命令，不执行、不等端口 |
| `-h` / `--help` | 打印脚本头部用法 |

| 退出码 | 含义 |
| --- | --- |
| 0 | 全部通过 |
| 1 | 某个 cargo 步骤失败（日志尾部已打印） |
| 2 | 用法/配置错误（未知参数、非法 `RMA_LIVE_TESTS`、找不到 crate） |
| 3 | 等待 MySQL / PostgreSQL 端口超时 |

### 2.4 环境变量

脚本侧的变量（端口就绪探测 + 尽力探测）：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `MYSQL_HOST` | `127.0.0.1` | MySQL 探测地址 |
| `MYSQL_PORT` | `3306` | MySQL 端口 |
| `MYSQL_USER` | `root` | 账号（用于可选探测提示） |
| `MYSQL_PASSWORD` | 空 | 密码（默认空，用于可选探测提示） |
| `PG_HOST` | `127.0.0.1` | PostgreSQL 探测地址 |
| `PG_PORT` | `5432` | PostgreSQL 端口 |
| `PG_USER` | `postgres` | 账号 |
| `PG_PASSWORD` | 空 | 空密码，与测试默认一致 |
| `PG_DB` | `rustmyadmin_demo` | 提示用：库不存在时会给出创建建议 |
| `RMA_WAIT_TIMEOUT` | `60` | 端口等待超时（秒） |
| `RMA_LIVE_TESTS` | `live_script live_databases live_import live_cancel_processlist` | 覆盖 live 测试二进制列表（空格分隔） |
| `RMA_LOG_DIR` | `rust/target/live-test-logs` | 每步日志目录（相对仓库根） |
| `RMA_OFFLINE` | `1` | 置 0 则去掉 cargo 的 `--offline` |
| `RMA_SAKILA_DUMP` | 未设置 | 透传给 live_script 的 sakila dump 路径 |

测试侧的变量（`rust/tests/common/mod.rs` 读取）。脚本会把上面的 `MYSQL_*` / `PG_*`
映射成下表变量再导出，所以只配一套即可；显式设置下表变量时以它为准：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `DBPILOT_TEST_MYSQL_HOST` | `127.0.0.1` | MySQL 地址 |
| `DBPILOT_TEST_MYSQL_PORT` | `3306` | MySQL 端口（字符串，解析为 u16） |
| `DBPILOT_TEST_MYSQL_USER` | `root` | MySQL 账号 |
| `DBPILOT_TEST_MYSQL_PASSWORD` | 空 | MySQL 密码 |
| `DBPILOT_TEST_MYSQL_DB` | `rustmyadmin_demo` | MySQL 库名 |
| `DBPILOT_TEST_PG_HOST` | `127.0.0.1` | PostgreSQL 地址 |
| `DBPILOT_TEST_PG_PORT` | `5432` | PostgreSQL 端口 |
| `DBPILOT_TEST_PG_USER` | `postgres` | PostgreSQL 账号 |
| `DBPILOT_TEST_PG_PASSWORD` | 空 | PostgreSQL 密码 |
| `DBPILOT_TEST_PG_DB` | `rustmyadmin_demo` | PostgreSQL 库名 |
| `DBPILOT_TEST_PAGILA_SCRIPT` | 未设置 | `postgres_dump_script_*` 用的 pg_dump 合并脚本；缺失时该用例 SKIP |

例：端口冲突时把 MySQL 映射到 13306，并把测试也指到 13306（现在测试读环境变量，
不再需要端口转发）：

```bash
MYSQL_PORT=13306 DBPILOT_TEST_MYSQL_PORT=13306 \
  RMA_WAIT_TIMEOUT=120 bash tools/run_live_tests.sh
```

例：额外跑 `live_sync`（默认不在 live 列表里）：

```bash
RMA_LIVE_TESTS="live_sync" bash tools/run_live_tests.sh --skip-hermetic --no-wait
```

### 2.5 日志

每步完整输出写到 `rust/target/live-test-logs/NN-<step>.log`（`hermetic` / `live`），
失败时终端会打印对应日志末尾 40 行，最后是含耗时与状态的汇总表。

## 3. 用 Docker 起库

### 3.1 起停

```bash
docker compose -f docker-compose.live.yml up -d --wait   # 起库并等 healthcheck 通过
docker compose -f docker-compose.live.yml ps
docker compose -f docker-compose.live.yml down -v        # 停库并删数据卷（干净重建）
# 或者
make rust-live-up
make rust-live-down
```

`--wait` 会阻塞到两个 healthcheck 变 healthy，所以随后可以用 `--no-wait` 跑脚本。

### 3.2 容器内容

| 服务 | 镜像 | 端口（可用环境变量覆盖） | 环境 | healthcheck |
| --- | --- | --- | --- | --- |
| `mysql` | `mysql:8.4` | `${MYSQL_PORT:-3306}:3306` | `MYSQL_ALLOW_EMPTY_PASSWORD=yes`、`MYSQL_DATABASE=rustmyadmin_demo` | `mysqladmin ping -h 127.0.0.1 -uroot --silent` |
| `postgres` | `postgres:17` | `${PG_PORT:-5432}:5432` | `POSTGRES_USER=postgres`、`POSTGRES_HOST_AUTH_METHOD=trust`、`POSTGRES_DB=rustmyadmin_demo` | `pg_isready -U postgres -d rustmyadmin_demo` |

两个服务用命名卷 `mysql-live-data` / `pg-live-data` 持久化，`down -v` 才会删除。
**compose 文件里没有任何密码字面量**：MySQL 允许空密码，PostgreSQL 用 trust。

### 3.3 端口被本机服务占用怎么办

本机可能已经装了 MySQL/PG，此时直接复用即可：

```bash
# 本机已有 3306/5432 时不需要 compose
bash tools/run_live_tests.sh
```

如果一定要用 compose，而 3306/5432 已被占用，可以改端口映射并同步告诉测试：

```bash
MYSQL_PORT=13306 docker compose -f docker-compose.live.yml up -d --wait mysql
DBPILOT_TEST_MYSQL_PORT=13306 bash tools/run_live_tests.sh --no-wait
```

## 4. CI 怎么跑

Rust live 套件在 GitHub Actions 的 `rust-live` 工作流里跑（见
`.github/workflows/rust-live.yml`），触发路径为 `rust/**`、`tools/run_live_tests.sh`、
`docker-compose.live.yml`、`Makefile` 与工作流自身。

步骤顺序：

1. `actions/checkout@v4`
2. `docker compose -f docker-compose.live.yml up -d --wait` 起 MySQL 8.4 + PostgreSQL 17
3. `rustup toolchain install stable --profile minimal` + `rustup default stable`
4. `actions/cache@v4` 缓存 `~/.cargo/registry`、`~/.cargo/git/db`、`rust/target`
5. `cd rust && cargo fetch`：先联网把依赖抓到 registry 缓存
6. `bash tools/run_live_tests.sh --no-wait`：hermetic → live（脚本内部仍是 `--offline`）
7. 失败时 dump `compose ps` / `logs --tail=200` / 端口探测
8. `if: always()` 上传 `rust/target/live-test-logs` 为 artifact（保留 7 天）
9. `if: always()` `docker compose ... down -v` 清理

CI 里数据库是空密码 + trust，工作流不注入任何密码 secret。

## 5. live 用例清单与忽略原因

live 测试全部带 `#[ignore = "..."]`，所以 hermetic 跑法会报告一批 ignored。
脚本默认执行 4 个测试二进制，共 14 个用例：

| 套件 | 用例 | 依赖 | 忽略原因 / 备注 |
| --- | --- | --- | --- |
| live_databases | `postgres_instance_tree` | PG + `rustmyadmin_demo` | 需要 `DBPILOT_TEST_PG_*` 指向的库存在 |
| live_databases | `postgres_cancel_query` | PG | 取消查询 |
| live_databases | `postgres_restricted_role` | PG + `rustmyadmin_demo` | 会建/删受限角色 `rma_limited`（密码运行时随机生成） |
| live_databases | `mysql_cancel_query` | MySQL | 取消查询 |
| live_databases | `mysql_round_trip` | MySQL | 建/删 scratch 库 |
| live_import | `mysql_import_and_probe` | MySQL + `rustmyadmin_demo` | 多行 INSERT / 探针事务 |
| live_script | `postgres_dump_script_keeps_functions_and_triggers` | PG + pg_dump 夹具 | 会 DROP/CREATE `rma_round30_pg`；夹具缺失时 SKIP |
| live_script | `postgres_session_state_survives_statements` | PG | 同上 |
| live_script | `mysql_session_state_and_recreated_database` | MySQL | 会 DROP/CREATE `rma_round30_my`（破坏性） |
| live_script | `mysql_official_sakila_dump_imports_views_triggers_and_routines` | MySQL + sakila dump | dump 缺失时**按设计 SKIP**（不算失败） |
| live_cancel_processlist | `mysql_process_list_and_cancel` | MySQL | processlist + 取消 |
| live_cancel_processlist | `postgres_process_list_and_cancel` | PG | processlist + 取消 |
| live_cancel_processlist | `mysql_kill_session_closes_the_victim` | MySQL | KILL 会话 |
| live_cancel_processlist | `postgres_kill_session_closes_the_victim` | PG | KILL 会话 |

默认不跑（`RMA_LIVE_TESTS=live_sync` 可单独跑）：

| 套件 | 用例 | 依赖 |
| --- | --- | --- |
| live_sync | `mysql_sync_round_trip` | MySQL + `rustmyadmin_demo` |
| live_sync | `postgres_cross_database_sync` | PG + `rustmyadmin_demo` |
| live_sync | `postgres_sync_round_trip` | PG + `rustmyadmin_demo` |

另外 `ssh_fingerprint` / `ssh_real_mysql` / `sql_result_limit` 里的 MySQL 用例、
`tls_*` 里的 TLS 用例同样是 `#[ignore]` 或条件 SKIP，端点分别来自
`DBPILOT_TEST_MYSQL_*` 与 `DBPILOT_TLS_*`。

## 6. TLS / mTLS fixture

`tools/tls_fixture.sh up` 会起两个**一次性**实例（默认 3307 / 5434，数据在
`/tmp/rma-tls-mysql`、`/tmp/rma-tls-pg`，可用 `RMA_TLS_MYSQL_BASE` /
`RMA_TLS_PG_BASE` 覆盖），并生成随机密码：

```bash
bash tools/tls_fixture.sh up
source /tmp/rma-tls-mysql/credentials.env   # 打印的路径为准
cargo test --test tls_mysql -- --nocapture
bash tools/tls_fixture.sh down
```

fixture 的账号/密码（`DBPILOT_TLS_MYSQL_*`、`DBPILOT_TLS_PG_*`、
`DBPILOT_TLS_NOSAN_*`）**每次 up 都重新随机生成**，只写在本机 `/tmp` 下的
`credentials.env`（权限 600），仓库里没有任何密码字面量。fixture 没起时这些测试
打印 SKIP 并直接返回（算通过）。

## 7. 常见失败与排查

### 7.1 端口被占用 / 等待超时（退出码 3）

现象：`等待 MySQL (127.0.0.1:3306) 超时`。

- 确认服务在跑：`nc -z 127.0.0.1 3306`、`nc -z 127.0.0.1 5432`；
- 容器没起：`docker compose -f docker-compose.live.yml up -d --wait`；
- 3306/5432 被本机别的进程占用：直接复用本机服务，或给 compose 换端口并同步
  设置 `DBPILOT_TEST_MYSQL_PORT` / `DBPILOT_TEST_PG_PORT`；
- 启动慢：`RMA_WAIT_TIMEOUT=180 bash tools/run_live_tests.sh`。

### 7.2 PostgreSQL 缺 `rustmyadmin_demo`

`live_databases::postgres_instance_tree` 会断言数据库列表里存在 `rustmyadmin_demo`，
库不存在时该用例失败（不是 SKIP）。compose 通过 `POSTGRES_DB=rustmyadmin_demo` 在
**首次初始化**时创建；如果数据卷是旧的，改环境变量不会补建，需要：

```bash
docker compose -f docker-compose.live.yml down -v   # 删旧卷
docker compose -f docker-compose.live.yml up -d --wait
# 或者手工补建：
psql -h 127.0.0.1 -p 5432 -U postgres -c 'CREATE DATABASE rustmyadmin_demo'
```

脚本在等待端口后会尽力探测该库是否存在并给出提示（需要本机有 `psql`）。

### 7.3 sakila / pagila dump 缺失 = 正常 SKIP

`mysql_official_sakila_dump_*` 在 `$RMA_SAKILA_DUMP` 不存在时打印
`SKIP: sakila dump not found at ...` 并直接返回；`postgres_dump_script_*` 在
`$DBPILOT_TEST_PAGILA_SCRIPT`（及其相对路径回退）不存在时同样 SKIP。两者**都算通过**。
要真正跑它们：`RMA_SAKILA_DUMP=/path/to/sakila.sql`、
`DBPILOT_TEST_PAGILA_SCRIPT=/path/to/pagila_combined.sql`，
注意它们会 DROP/CREATE 对应的库/schema。

### 7.4 `cargo test --offline` 报依赖缺失

现象：`error: no matching package named ... found` / `failed to load source`。
原因：`~/.cargo` 里没有缓存。解决：先联网 `cd rust && cargo fetch`，再重跑；
或临时 `RMA_OFFLINE=0 bash tools/run_live_tests.sh`。CI 工作流已包含 fetch 步骤。

### 7.5 hermetic 编译失败

脚本 fail-fast：打印失败步骤、rc、日志路径与日志末尾 40 行，然后退出 1。
完整日志：`rust/target/live-test-logs/01-hermetic.log`。

### 7.6 维护提示：bash 3.2

macOS 自带 bash 3.2，脚本刻意不用 bash 4+ 语法（无 `${var,,}`、无关联数组、无 `mapfile`）。
另外：`$VAR` 后面**紧跟中文字符**时必须写成 `${VAR}`，否则 bash 3.2 会把多字节字符当成
变量名的一部分而报 `unbound variable`。脚本改动后请在本机执行
`bash -n tools/run_live_tests.sh`。

### 7.7 破坏性说明

live 用例会 CREATE/DROP 临时库（`rma_round30_my`、`rma_round30_pg` 及随机 scratch 名），
sakila / pagila 用例还会重建对应库。**不要**把端点指向生产实例。

### 7.8 手工直接跑测试二进制时的工作目录

`cargo test` 会以包根 `rust/` 作为 cwd；如果绕过 cargo 直接在 `target/debug/deps/`
下运行测试二进制，依赖相对路径的夹具会解析失败。手工复现时请先 `cd rust`。

## 8. 复核清单

```bash
bash -n tools/run_live_tests.sh
bash -n tools/tls_fixture.sh
make -n rust-test && make -n rust-live && make -n rust-live-up && make -n rust-live-down
bash tools/run_live_tests.sh            # 期望 hermetic 全绿 + live 14 个用例通过（sakila/pagila 视夹具定）
```

CI 侧：推一个改动 `rust/**` 的 commit，确认 `rust-live` 工作流绿色，
失败时可在 artifact `rust-live-test-logs` 与 job 日志的 compose dump 中定位。
