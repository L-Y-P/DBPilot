# 发布仓库根 Makefile —— Rust 测试入口（hermetic / live）
#
#   make rust-test       只跑 hermetic 套件（离线，不需要数据库）
#   make rust-live       等库就绪 + hermetic + live 全套（调 tools/run_live_tests.sh）
#   make rust-live-up    用 docker compose 起 MySQL/PG 并等 healthcheck
#   make rust-live-down  停库并删除数据卷
#
# 可用 COMPOSE 覆盖 compose 命令，例如：make rust-live-up COMPOSE="docker-compose"
#
# live 测试需要的账号/密码/地址全部来自环境变量（见 rust/tests/common/mod.rs 与
# tools/run_live_tests.sh 的注释），仓库里不含任何凭据；compose 默认起空密码实例。

SHELL := /bin/sh
RUST_DIR := rust
COMPOSE_FILE := docker-compose.live.yml
COMPOSE ?= docker compose

.PHONY: help rust-test rust-live rust-live-up rust-live-down

help:
	@echo "make rust-test        hermetic 测试 (cd $(RUST_DIR) && cargo test --offline)"
	@echo "make rust-live        hermetic + live 套件 (tools/run_live_tests.sh)"
	@echo "make rust-live-up     docker compose 起 MySQL/PG"
	@echo "make rust-live-down   docker compose 停库并删卷"

rust-test:
	cd $(RUST_DIR) && cargo test --offline -- --test-threads=1

rust-live:
	bash tools/run_live_tests.sh

rust-live-up:
	$(COMPOSE) -f $(COMPOSE_FILE) up -d --wait

rust-live-down:
	$(COMPOSE) -f $(COMPOSE_FILE) down -v
