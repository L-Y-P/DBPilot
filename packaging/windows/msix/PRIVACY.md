# DBPilot 隐私政策 / Privacy Policy

_最后更新：2026-10-27_

DBPilot 是一个**本地运行**的数据库桌面客户端。它不附带任何账号体系，不上报遥测，
不向开发者服务器发送你的数据。

## 我们收集什么

**什么都不收集。** 具体地：

- 没有崩溃上报、使用统计、埋点或广告 SDK；
- 没有开发者运营的服务器接收你的数据（唯一的网络请求见下一节）；
- 不收集设备标识、位置、联系人、摄像头或麦克风信息。

## 应用访问什么，为什么

| 数据 | 用途 | 去向 |
| --- | --- | --- |
| 你填写的数据库连接信息（主机、端口、用户名、密码、SSL 配置） | 连接并操作你指定的数据库 | 仅保存在本机数据目录 |
| 你执行的 SQL、查询历史、表结构 | 在界面里查看与复用 | 仅保存在本机数据目录 |
| 导出的文件（CSV / SQL / Excel） | 你主动发起的导出 | 仅写入你选择的路径 |
| 备份文件 | 你主动发起的备份 | 仅写入你选择的路径 |

数据目录位置（设置 → 数据与卸载 → 数据目录可见）：

- Windows 独立安装包：`%APPDATA%\DBPilot`
- Windows Microsoft Store（MSIX）：`%LOCALAPPDATA%\Packages\<PackageFamilyName>\LocalCache\Roaming\com.rustmyadmin\DBPilot`
- macOS：`~/Library/Application Support/DBPilot`
- Linux：`$XDG_DATA_HOME/rust-myadmin`（默认 `~/.local/share/rust-myadmin`）

## 唯一的网络请求

「设置 → 检查更新」会 GET 一个公开 JSON 文件：

```
https://raw.githubusercontent.com/L-Y-P/DBPilot/main/update.json
```

请求里不携带任何用户数据（没有 ID、没有连接信息、没有版本之外的参数；GitHub 作为托管方
可能记录请求 IP，这属于其自身政策范围）。

- 安装包（NSIS）版本：发现新版本后会从 GitHub Releases 下载安装包并安装。
- **Microsoft Store（MSIX）版本：不做也不允许应用内下载与安装**，检查只显示新版本号，
  更新请通过 Microsoft Store 完成（商店渠道的下载与安装由 Microsoft 负责）。

除此之外，应用只连接**你本人配置的**数据库服务地址。

## 数据库凭据

连接密码只保存在本机数据目录，用于自动重连；不会上传到任何地方。你可以随时在
「设置 → 数据与卸载 → 执行清空…」删除全部本地数据。

## 第三方组件

应用内置 Flutter 与 Rust 运行时、MySQL/MariaDB 与 PostgreSQL 驱动；这些组件不联网，
也不收集数据。

## Microsoft Store 版本

通过 Microsoft Store 分发时，Microsoft 会按其自身隐私声明收集安装与使用统计，
与我们无关。应用本身的行为与上表完全一致。

## 联系方式

问题与反馈：<https://github.com/L-Y-P/DBPilot/issues>

---

## English summary

DBPilot is a local-first desktop database client: no account, no telemetry, no
analytics, no crash reporting, no developer-operated server. Connection
settings, SQL text, query history and backups stay in your local data folder.
The only outbound request the app makes on its own is a GET of the public
update manifest `update.json` in this repository (no user data in the
request). **Microsoft Store (MSIX) builds never download or install updates
themselves**; they only report that a newer version exists and leave the
update to the Store. Everything else is traffic to the database servers you
configure yourself.

Contact: <https://github.com/L-Y-P/DBPilot/issues>
