# Windows MSIX（Microsoft Store）打包

DBPilot 的 Windows 版有**两种**安装形态，产物互不替代：

| 形态 | 产物 | 更新方式 | 脚本 |
| --- | --- | --- | --- |
| 独立安装包（主渠道） | `DBPilot-<ver>-windows-x64-setup.exe` | 应用内自动更新（下载 NSIS 安装包静默升级） | `packaging/windows/installer.nsi` |
| 商店包（MSIX） | `DBPilot-<ver>-x64.msix` | **只能从 Microsoft Store 更新** | 本目录 `make-msix.ps1` |

商店会**重新签名**每个提交，所以本目录产出的包不需要我们签名；签名只在「本地安装验证」时需要。

## 1. 需要用户提供的参数（提交商店前必须拿到）

在 [Partner Center](https://partner.microsoft.com/dashboard) → 你的应用 → **产品管理 → 产品标识** 页面复制：

| 参数 | Partner Center 字段 | 形如 | 用在哪 |
| --- | --- | --- | --- |
| Identity Name | Package/Identity/Name | `1234ABCD.DBPilot` | `-IdentityName` → `<Identity Name>` |
| Publisher ID | Package/Identity/Publisher | `CN=1A2B3C4D-1234-5678-9ABC-DEF012345678` | `-Publisher` → `<Identity Publisher>` |
| Publisher display name | 应用名称/发布者显示名 | `L-Y-P`（自定） | `-PublisherDisplayName` |
| Package Family Name | 首次提交**通过后**才有 | `DBPilot_8wekyb3d8bbwe` | 仅文档用；运行时靠 `%APPX_PACKAGE_FAMILY_NAME%` 自动取 |

这两个值缺一不可：包里的 `Publisher` 与商店登记的 Publisher 不一致时，上传会以
`0x800B0109`（证书与清单不匹配）或「Package/Identity/Publisher 不匹配」被拒。

CI 里对应两个 **repository variables**（Settings → Secrets and variables → Actions → Variables）：

```
MSIX_IDENTITY_NAME = 1234ABCD.DBPilot
MSIX_PUBLISHER     = CN=1A2B3C4D-1234-5678-9ABC-DEF012345678
```

没配时工作流仍然出包，但会打印警告并使用占位符（`DBPilot.Placeholder` / `CN=DBPilot-Local-Test`），
这种包**不能提交**，只用于验证流水线与清单结构。

## 2. 本地/CI 打包

```powershell
# 1) 先出 Flutter Windows Release 构建
flutter build windows --release            # desktop/ 目录下

# 2) 打 MSIX（不签名，可直接上传商店）
pwsh desktop/packaging/windows/msix/make-msix.ps1 `
    -SourceDir desktop/build/windows/x64/runner/Release `
    -Version 1.1.3 `
    -IdentityName 1234ABCD.DBPilot `
    -Publisher "CN=1A2B3C4D-1234-5678-9ABC-DEF012345678" `
    -OutFile DBPilot-1.1.3-x64.msix
```

参数一览：

| 参数 | 必填 | 说明 |
| --- | --- | --- |
| `-SourceDir` | ✅ | `build\windows\x64\runner\Release`（整个目录会被打进包） |
| `-Version` | ✅ | 三段（`1.1.3`）或四段（`1.1.3.0`）；MSIX 必须是四段数字，缺的补 0 |
| `-OutFile` | ✅ | 输出 `.msix` 路径（相对路径按当前目录解析） |
| `-IdentityName` | 商店必需 | 缺省 `DBPilot.Placeholder` + 警告 |
| `-Publisher` | 商店必需 | 缺省 `CN=DBPilot-Local-Test` + 警告 |
| `-Arch` | | `x64`（默认）/ `x86` / `arm64`（扩展位，清单处理器架构与打包一致） |
| `-DisplayName` | | 包内显示名，默认 `DBPilot` |
| `-PublisherDisplayName` | | 发布者显示名，默认 `DBPilot` |
| `-AppIconPng` | | 图标源，默认自动找 `windows\runner\resources\app_icon.ico`，其次 `assets\images\dbpilot.png` |
| `-MakeAppxPath` | | 指定 `makeappx.exe`，默认在 Windows SDK 里找最新的 x64 版本 |
| `-CertPath` / `-CertPassword` | | 仅本地安装测试用自签证书；不传则不签名 |
| `-KeepLayout` | | 保留 staging 目录便于排查 |

脚本做四件事：渲染清单 → 用 `System.Drawing` 从图标裁出全部磁贴 → `makeappx pack` →
`makeappx unpack` 自检（清单、资源、入口 exe 缺一即失败，不会带着坏包去 Partner Center）。

**依赖**：Windows 10/11 + Windows SDK 的 `MakeAppx` 组件（`makeappx.exe`）；签名另需 `signtool.exe`。
Windows Server 2022 / windows-latest 上两者都在。

## 3. 本地安装测试（自签证书）

```powershell
# 证书 Subject 必须与 -Publisher **完全一致**，否则安装报 0x800B0109
$pwd = ConvertTo-SecureString -String "test123" -Force -AsPlainText
$c = New-SelfSignedCertificate -Type Custom -Subject "CN=1A2B3C4D-1234-5678-9ABC-DEF012345678" `
     -KeyUsage DigitalSignature -CertStoreLocation "Cert:\CurrentUser\My" `
     -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.3","2.5.29.19={text}")
Export-PfxCertificate -Cert $c -FilePath C:\verify\test.pfx -Password $pwd

.make-msix.ps1 ... -CertPath C:\verify\test.pfx -CertPassword test123

# 自签证书链默认不被信任，安装前导入到「受信任的根证书颁发机构」
Import-Certificate -FilePath C:\verify\test.cer -CertStoreLocation Cert:\LocalMachine\Root

# 安装（需要开发者模式或已信任的证书）
Add-AppxPackage -Path .\DBPilot-1.1.3-x64.msix
```

`signtool verify /pa` 对自签证书会失败（链不可信），脚本只警告不报错——商店会重签，
这一步不影响提交。

## 4. 结构

```
packaging/windows/msix/
├─ AppxManifest.template.xml   # 清单模板，__XXX__ 占位符由脚本替换
├─ make-msix.ps1               # 打包脚本（渲染清单 / 生成磁贴 / makeappx pack / 解包自检 / 可选签名）
├─ PRIVACY.md                  # 商店要求的隐私政策
└─ README.md                   # 本文
```

产物里只有应用 payload（`DBPilot.exe`、`flutter_windows.dll`、`rust_myadmin_core.dll`、
`data\…`）加上 `AppxManifest.xml`、`AppxBlockMap.xml` 和 `Assets\*.png`。

### 清单要点

- `EntryPoint="Windows.FullTrustApplication"`：桌面 exe 必须用它，否则包能装但启动即退出；
- `<rescap:Capability Name="runFullTrust" />`：全信任桌面应用唯一必需的能力，网络/文件/子进程都不受限；
- `TargetDeviceFamily Windows.Desktop`，`MinVersion 10.0.19041.0`（Windows 10 2004）；
- 磁贴由脚本按 Microsoft 的尺寸表生成：`Square44x44`、`Square71x71`、`Square150x150`、
  `Square310x310(LargeTile)`、`Wide310x150`、`StoreLogo 50x50`，另加 44/24 unplated 与 100/200 scale 变体。
  清单只引用纯文件名，换图标不用改清单。

### 编码约束（踩过的坑）

- **`make-msix.ps1` 与 `AppxManifest.template.xml` 必须保持纯 ASCII**：
  Windows PowerShell 5.1 用 `Get-Content` 读无 BOM 文本时按 ANSI 代码页解码，
  中文会变成乱码，表现为 `UnexpectedToken` / `makeappx: 0x80080204 The package manifest is not valid`。
  需要本地化文案请放 PRI 资源，不要写进清单。
- 脚本里 `MakeAppx` 的输出重定向到文件时用 UTF-8；日志里出现乱码不影响出包。

## 5. 运行形态适配（应用侧）

应用靠 `lib/src/platform_shape.dart` 的纯函数 `isMsixPackaged(executablePath, environment)` 判断：

1. 环境变量 `%APPX_PACKAGE_FAMILY_NAME%` 非空 → 是 MSIX（商店版本必有，未打包进程没有）；
2. 否则回退看 exe 路径是否位于 `\WindowsApps\` 下（大小写与 `/`、`\` 都认，
   `WindowsApps-backup` 这类兄弟目录不算）。

判定为 MSIX 后：

- `autoUpdateAssetUrl()` 返回 `null` → 设置页不会去下载 NSIS 安装包；
- `applyUpdateAndRestart()` 直接抛 `UpdateApplyException`（「请从 Microsoft Store 更新」）；
- 设置页把「更新源：GitHub」改成「更新方式：Microsoft Store」，并说明应用内更新已停用。

**数据目录**不需要适配：Dart 侧走 `path_provider` 的 `getApplicationSupportDirectory()`
（MSIX 下是 `%LOCALAPPDATA%\Packages\<PackageFamilyName>\LocalCache\Roaming\<org>\<app>`），
Rust 侧只认 Dart 传进来的路径（`init_app(data_dir)`），没有写 `Program Files` 或安装目录的代码。
