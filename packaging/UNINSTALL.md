# 卸载行为说明（三平台）

这份文档说明 **DBPilot 卸载时会不会动用户数据**，以及卸载后数据残留怎么手动清掉。
它也是 `desktop/packaging/windows/installer.nsi` 里卸载逻辑的说明书。

> 前提：DBPilot 是本地单用户工具，没有登录，也没有云端账号；它的"数据"就是下面这
> 一个目录，删掉就真的没了（尤其是 `connections.json` 里的**明文密码**）。

---

## 1. 用户数据在哪

| 平台 | 目录 |
| --- | --- |
| Windows | `%APPDATA%\com.rustmyadmin\DBPilot` |
| macOS | `~/Library/Application Support/com.rustmyadmin.rustMyadminDesktop/` |
| Linux | `~/.local/share/com.rustmyadmin.rust_myadmin_desktop/` |

内容（详见 `desktop/docs/USAGE.md`「数据存放与安全」一节）：

| 文件 | 内容 |
| --- | --- |
| `connections.json` | 连接配置，**含数据库密码** |
| `settings.json` | 语言、主题、性能开关、备份目录、窗口尺寸 |
| `query_history.json` | 查询历史 |
| `backups/` | 备份文件与 `index.json` |

---

## 2. 行为矩阵

| 平台 | 卸载方式 | 是否提示 | 用户数据 |
| --- | --- | --- | --- |
| **Windows** | 图形化卸载（开始菜单 /「应用和功能」） | ✅ 弹窗询问，默认按钮为 **否** | 选"否"保留（并弹出路径提示）；选"是"删除 |
| **Windows** | 静默 `uninstall.exe /S`（含「应用和功能」的 QuietUninstallString） | ❌ 不弹任何窗 | **保留**（安全默认） |
| **Windows** | 静默 + `uninstall.exe /S /DELETEUSERDATA` | ❌ 不弹任何窗 | 删除 |
| **Windows** | 有数据但选"否" | 结束后再弹一次"数据已保留 + 路径" | 保留 |
| **Windows** | 根本没有数据目录 | 不询问、不提示 | 无事发生 |
| **Windows** | 选"是"但没删干净（文件占用/权限） | 弹出警告，给出路径让用户手动删 | 残留，需要手动清理 |
| **macOS** | 拖到废纸篓 / 删除 `DBPilot.app` | ❌ 系统没有卸载钩子 | **保留**，需手动删 |
| **macOS** | `brew uninstall --cask dbpilot`（若日后上架 cask） | ❌ | 保留，需手动删 |
| **Linux** | `sudo dpkg -r dbpilot` / `sudo apt remove dbpilot` | ❌（Debian 包没有"是否删用户数据"的机制） | 保留，需手动删 |
| **Linux** | `sudo rpm -e dbpilot` | ❌ | 保留，需手动删 |
| **Linux** | AppImage | 本质上没"安装"，删文件即卸载 | 保留，需手动删 |

**一句话总结**：只有 Windows 安装包会在卸载时问；其余平台（以及 Windows 静默卸载）一律
**安全默认保留**用户数据，并告知用户手动清理的位置。

---

## 3. Windows：卸载流程顺序（`installer.nsi`）

```text
MUI_UNPAGE_CONFIRM   "确定要卸载吗"  ← 用户最后一次反悔机会
  ↓
taskkill /F /IM DBPilot.exe           关掉正在跑的实例
  ↓
检测用户数据目录是否存在
  ├─ 不存在 → 不问（不打扰）
  └─ 存在   → MessageBox MB_YESNO|MB_ICONQUESTION|MB_DEFBUTTON2
              默认按钮 =「否」 = 保留
  ↓
删桌面/开始菜单快捷方式、RMDir /r $INSTDIR、删注册表键
  ↓
若选了「是」：RMDir /r 数据目录 → 父目录 com.rustmyadmin 空了才 RMDir（不带 /r）
  ↓
收尾提示（静默卸载时全部跳过）：
  · 选了"是"且删干净   → "已一并删除"
  · 选了"是"但没删干净 → 警告 + 路径
  · 选了"否"（有数据）  → "已保留" + 路径
```

为什么**先问再删程序**：这样用户如果在"确定卸载"之后又反悔，直接 Alt+F4 中止，
数据和程序都还在；反过来（先删程序再问）就做不到"可撤销"了。

### 命令行用法

```bat
:: 图形化卸载：弹窗询问，回车（默认）＝ 保留数据
"C:\Program Files\DBPilot\uninstall.exe"

:: 静默卸载：保留数据（CI / 批量部署用这个）
"C:\Program Files\DBPilot\uninstall.exe" /S

:: 静默卸载并删除数据：只在明确要清干净时用
"C:\Program Files\DBPilot\uninstall.exe" /S /DELETEUSERDATA
```

`/DELETEUSERDATA` 在图形化卸载里也可以加，效果等同直接选"是"（不再询问）。
参数按**整词**匹配，`/SOMETHING` 不会被误判成 `/S`。

---

## 4. 应用内查看同一份数据（不用卸载）

不需要卸载也能看到/清理同一份数据：打开「设置 → 数据与卸载」。

- 它展示的就是**同一个目录**——Windows 上是 `%APPDATA%\com.rustmyadmin\DBPilot`
  （macOS / Linux 同理，见上面第 1 节表格），不是另建一份、也不是另一套缓存。
- 所以在应用里看到的大小/条数，就是卸载弹窗里问的那堆东西。
- **卸载弹窗**和**应用内面板**是两个入口、同一份数据；无论走哪个入口清掉，
  另一个再执行都只是"本来就没有"，不会报错。

> 这个入口的交互细节以应用实现为准（见 `desktop/lib/src/data_dir_overview.dart`），
> 本文档只描述它和卸载流程共用同一个目录这件事。

---

## 5. 卸载后想彻底清理：手动删除

```bat
:: Windows（%APPDATA% 在资源管理器地址栏输入即可）
rmdir /s /q "%APPDATA%\com.rustmyadmin"
```

```bash
# macOS
rm -rf "$HOME/Library/Application Support/com.rustmyadmin.rustMyadminDesktop"

# Linux（deb / rpm / AppImage 都在这一个位置）
rm -rf "${XDG_DATA_HOME:-$HOME/.local/share}/com.rustmyadmin.rust_myadmin_desktop"
```

删除前建议先备份 `connections.json`（里面是明文密码，请自行注意安全）。

---

## 6. 已知边界

- **Windows 多账户**：卸载程序按"当前用户"的 `%APPDATA%` 找数据。安装包本身需要管理员
  权限（UAC），如果提权后进程拿到的是管理员账户的 `%APPDATA%`，可能"检测不到数据"
  （于是不弹窗、不删任何东西）。这种情况不会误删，只是少了一个提示；要精确对准原安装
  者需要额外读取其 SID，目前未实现。
- **macOS / Linux 没有卸载提示**：这两种平台的包管理器没有"卸载时询问"的标准做法，
  硬加 postrm 脚本静默删数据反而更危险（用户 `apt remove` 一下就丢配置）。所以统一
  **保留**，并在本文档与 README 里写清楚位置。
- 升级/覆盖安装**永远**不碰用户数据。
