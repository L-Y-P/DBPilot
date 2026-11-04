# DBPilot — Microsoft Store 一览草稿（Submission 1）
> 上传 DBPilot-1.1.3-x64.msix 后，在 Partner Center「Store 一览」填入以下内容。
> 文件已放在桌面：~/Desktop/DBPilot-1.1.3-x64.msix（也可从 Release 下载：
> https://github.com/L-Y-P/DBPilot/releases/download/v1.1.3/DBPilot-1.1.3-x64.msix）

## 语言（zh-CN + en-US）
添加语言后，按语言填写以下字段。

## 中文（zh-CN）文案

### 说明（Description，最长 10,000 字符）
DBPilot — 本地优先的跨平台数据库管理桌面客户端，Flutter + Rust 实现。
支持 MySQL / MariaDB、PostgreSQL、SQLite：SSH 跳板与 TLS 加密、对象浏览、
可视化表设计、数据网格批量编辑、SQL 控制台、查询构建器、Excel 导入、
E-R 关系图、备份还原。macOS / Windows / Linux 三平台，MIT 开源，无服务端，
连接与数据只留在本机。

### 发行说明（Release notes，本提交）
- 新增「数据与卸载」：设置页可查看数据目录占用并一键清空
- Windows 卸载时询问是否删除用户数据（默认保留）
- 修复 Windows 自动更新装错目录的问题（安装包尊重 /D=）
- 关于页精简版本信息
- MSIX 版本：更新通过 Microsoft Store 进行

### 功能列表（Features，至少 5 条）
1. 支持 MySQL / MariaDB、PostgreSQL、SQLite 三种数据库
2. SSH 跳板机隧道与 TLS 加密连接
3. 可视化表设计与数据网格批量编辑
4. SQL 控制台与查询构建器
5. Excel/CSV 导入导出，8 种格式
6. E-R 关系图与结构比对同步
7. 备份还原，数据目录一键查看/清空

### 搜索词（Search terms）
DBPilot, database, mysql, postgresql, sqlite, sql, ssh, 数据库, 客户端

### 应用类型 / 类别
工具 → 开发者工具（Developer tools）

## 英文（en-US）文案

### Description
DBPilot — a local-first, cross-platform database client built with Flutter + Rust.
Supports MySQL / MariaDB, PostgreSQL and SQLite: SSH jump host tunnels, TLS,
object browser, visual table designer, data-grid batch editing, SQL console,
query builder, Excel import, E-R diagrams, backup & restore. macOS / Windows /
Linux. MIT-licensed, no server, connections and data stay on your machine.

### Release notes
- New "Data & uninstall" panel: view data-folder usage and wipe user data
- Windows uninstaller now asks whether to keep user data (kept by default)
- Fixed Windows auto-update installing to the wrong directory
- About page shows a clean version number
- MSIX build updates through the Microsoft Store

### Features
1. MySQL / MariaDB, PostgreSQL and SQLite support
2. SSH tunnel and TLS encrypted connections
3. Visual table designer and batch data-grid editing
4. SQL console with query builder
5. Excel/CSV import & export in 8 formats
6. E-R diagrams, schema compare and sync
7. Backup & restore with one-click data-folder view/wipe

### Search terms
DBPilot, database, mysql, postgresql, sqlite, sql, ssh

## 截图（Screenshots，至少 1 张，建议 4 张，1366x768 或 1920x1080）
1. 连接页（新建 MySQL 连接）
2. 表浏览/数据网格
3. SQL 控制台
4. 查询构建器
说明文字可写 "DBPilot main window" 等。
截图源：desktop/screenshots/ 与 test-report/round69/ 里已有截图。

## 封面图 / Store 标志
使用 assets/images/dbpilot.png（已随包内嵌为 StoreLogo）。
建议另做 300x300 的应用图标上传。

## 定价与可用性
- 免费（Free）
- 可见性：公共（Public）
- 发现性：默认

## 年龄分级
- 微软年龄分级调查表（IARC）：已完成部分，剩余项按提示回答即可
  （DBPilot 无成人内容，全部选"否/无"）

## 属性
- 类别：Developer tools
- 支持的语言：zh-CN、en-US
- 硬件要求：建议 4GB 内存 / 1GB 磁盘；键盘、鼠标
- 网站：https://github.com/L-Y-P/DBPilot
- 支持联系人：https://github.com/L-Y-P/DBPilot/issues

## 提交选项
- 自动归档：建议默认
- 目标发布日期：立即
