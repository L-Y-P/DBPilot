# 发版流程（GitHub Actions 自动出包 + 更新清单）

本文说明 DBPilot 的发布流水线：**打一个 tag，CI 自动出 macOS / Windows 包、建 GitHub Release、
并更新仓库根的 `update.json`**。仓库根 = 本目录（`desktop/`），所以下面所有路径都没有 `desktop/` 前缀。

客户端固定读取：

```
https://raw.githubusercontent.com/L-Y-P/DBPilot/main/update.json
```

## 0. 速查

| 目的 | 操作 |
| --- | --- |
| 日常构建（不发布） | push 到 `main` / 开 PR / 手动跑 **build** 工作流 |
| 正式发版 | 改版本号 → 提交 → `git tag v1.1.0 && git push origin v1.1.0` |
| 补发 / 重跑同一版本 | Actions 里手动跑 **release** 工作流，`version` 填 `1.1.0` |
| 只跑 Rust live 套件 | push 命中 `rust/**` 等路径，或手动跑 **rust-live** |

三个工作流：

| 文件 | 触发 | 产物 |
| --- | --- | --- |
| `.github/workflows/build.yml` | push `main`/`master`（纯 `*.md` / `update.json` 改动跳过）、PR、`workflow_dispatch` | artifact `dbpilot-macos` / `dbpilot-windows-x64`（保留 14 天） |
| `.github/workflows/release.yml` | push tag `v*`、`workflow_dispatch`（带 `version`） | GitHub Release + 2 个 zip + 更新后的 `update.json` |
| `.github/workflows/rust-live.yml` | push/PR 命中 `rust/**`、`tools/run_live_tests.sh`、`docker-compose.live.yml`、`Makefile` | 测试日志 artifact（保留 7 天） |

## 1. 需要配置的 secrets

**没有。** 全部使用仓库内置的 `GITHUB_TOKEN`：工作流整体 `permissions: contents: read`，
只有 `release` 与 `manifest` 两个 job 单独声明 `contents: write`（最小权限）。
不需要 Apple 开发者证书、不需要签名密钥、不需要 PAT —— 代价见 §5「未签名说明」。

如果仓库开启了分支保护，需要允许 `github-actions[bot]` 直接推送 `main`（否则 §2.3 第 4 步会失败）。

## 2. 发版步骤（正常流程）

### 2.1 改版本号（两处手改 + 一处自动）

| 位置 | 内容 | 说明 |
| --- | --- | --- |
| `pubspec.yaml` | `version: 1.1.0+1` | 唯一版本源；`+1` 是 build number，不参与版本比较 |
| `lib/src/app_version.dart` | `kAppVersion = '1.1.0'`、`kAppBuildNumber = 1` | 设置/关于界面显示，客户端用它和清单比大小 |
| `update.json` | `"version": "1.1.0"` | **不用手改**，release 工作流会自动写 |

前两处都由 CI 校验（`release.yml` 的 `meta` job）：tag 去掉 `v` 后必须同时等于 `pubspec.yaml` 的 version
与 `lib/src/app_version.dart` 的 `kAppVersion`，否则直接失败并给出
`版本不一致：tag/输入 = 1.1.0，pubspec.yaml = 1.0.0` 或
`版本不一致：tag/输入 = 1.1.0，lib/src/app_version.dart kAppVersion = 1.0.0`。

为什么两处都要校验：客户端「检查更新」比较的是 **`kAppVersion` 与清单里的 `version`**，
与 `pubspec.yaml` 无关。只改 `pubspec.yaml` 就发版时，Release 和 `update.json` 都更新了，
但装上去的客户端仍报告旧版本号，于是永远提示「已是最新」——这类事故在发布后很难立刻发现，
所以让 CI 在打 tag 时就拦住。

### 2.2 打 tag 并推送

```bash
git tag v1.1.0
git push origin v1.1.0
```

### 2.3 CI 自动做什么

1. **meta**（ubuntu，约 10s）：解析版本、校验与 `pubspec.yaml` 一致、用
   `git describe --tags --abbrev=0 v1.1.0^` 找上一个 tag，生成 `release-body.md`
   （变更清单 + 下载表格 + macOS 未签名说明）。
2. **build**（macos-latest + windows-latest，并行）：装 Flutter 3.47.7 与 Rust stable，
   `flutter pub get` → `flutter build macos --release` / `flutter build windows --release`，
   打包 zip 并上传 artifact。
3. **release**（ubuntu）：`softprops/action-gh-release@v2` 用 `tag_name=v1.1.0` 建 Release 并上传
   `DBPilot-1.1.0-macos.zip`、`DBPilot-1.1.0-windows-x64-setup.exe`、`DBPilot-1.1.0-windows-x64-portable.zip`；同版本重跑会覆盖资产
   （`overwrite_files: true`），不会报 "already exists"。
4. **manifest**（ubuntu）：`gh api repos/<owner>/<repo>/releases/tags/v1.1.0` 取 `html_url` 与 `body`，
   写 `update.json` 后以 `github-actions[bot]` 身份提交回 `main`：

   ```json
   {
     "version": "1.1.0",
     "url": "https://github.com/L-Y-P/DBPilot/releases/tag/v1.1.0",
     "notes": "DBPilot v1.1.0 自 v1.0.0 以来的变更：- ... ## 下载 ..."
   }
   ```

   `notes` 会被压成单行（连续空白折叠、超过 500 字符截断到 497 + `...`），因为设置弹窗里是单行展示。
   `update.json` 无变化时（同版本重跑）跳过提交，不会产生空 commit。

客户端下一次「检查更新」时：`compareVersions("1.1.0", "1.0.0") > 0` → 显示新版本 + notes + 下载按钮。

### 2.4 发版后确认

- Release 页面有 2 个 zip 且大小合理（macOS 约 30-40 MB，Windows 约 20-30 MB）；
- `main` 上多了一个 `chore(release): update.json -> v1.1.0` 提交；
- `https://raw.githubusercontent.com/L-Y-P/DBPilot/main/update.json` 返回新版本（raw 有几分钟 CDN 缓存）；
- 已安装的旧版本在设置里点「检查更新」能看到新版本。

## 3. 手动触发（补发 / 重跑）

```
Actions → release → Run workflow → version: 1.1.0
```

- `version` 可以带 `v` 前缀，会被去掉；必须与 `pubspec.yaml` 一致。
- 若该 tag 不存在，`softprops/action-gh-release` 会在触发提交上自动建 tag；
  若已存在则更新同一个 Release 的资产。
- `workflow_dispatch` 触发的 `build` job 用 `ref: ${{ github.ref }}`（即触发分支），
  所以要从 `main` 上触发，别在旧分支上发版。

## 4. 产物命名与内容

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| macOS | `DBPilot-<version>-macos.dmg` | `DBPilot.app`（universal：x86_64 + arm64，约 92 MB 未压缩），拖入 Applications |
| macOS | `DBPilot-<version>-macos.zip` | 同上，CI 产出的 zip 形式（`ditto` 打包，保留 .app 内符号链接） |
| Windows x64 | `DBPilot-<version>-windows-x64-setup.exe` | **NSIS 安装包（主产物）**：开始菜单/桌面快捷方式、卸载项、版本信息，默认装到 `Program Files` |
| Windows x64 | `DBPilot-<version>-windows-x64-portable.zip` | 免安装版：`DBPilot.exe` + `rust_myadmin_core.dll` + `flutter_windows.dll` + `data/`，解压即用 |
| Linux x64 | `DBPilot-<version>-linux-x64.AppImage` | 免安装单文件：`chmod +x` 后直接运行（需 `libfuse2`） |
| Linux x64 | `dbpilot_<version>_amd64.deb` | Debian / Ubuntu 包，装到 `/usr/lib/dbpilot` + `/usr/bin/dbpilot` |
| Linux x64 | `dbpilot-<version>-1.x86_64.rpm` | Fedora / RHEL / openSUSE 包，目录布局与 deb 相同 |

构建目录（CI 与本地一致）：

| 平台 | 路径 |
| --- | --- |
| macOS | `build/macos/Build/Products/Release/DBPilot.app` |
| Windows | `build/windows/x64/runner/Release/`（整个目录） |

- macOS 用 `ditto -c -k --sequesterRsrc --keepParent` 打包，保留 .app 内的符号链接与扩展属性；
  用普通 `zip` 打包 .app 容易丢符号链接，解压后打不开。
- Windows 免安装 zip 用 `Compress-Archive -Path <Release>/*` 把目录**内容**打平进 zip，解压即用（不套一层文件夹）。
- Windows 安装包用 **NSIS**（`packaging/windows/installer.nsi`），`windows-latest` 镜像预装 NSIS 3.10，
  路径 `C:\Program Files (x86)\NSIS\makensis.exe`，无需额外安装。
- Windows 可执行文件已改名为 `DBPilot.exe`（`windows/CMakeLists.txt` 的 `BINARY_NAME`）。
- 版本号来自 `pubspec.yaml` 的 `version:` 前缀（`+` 之后是 build number，不参与命名）。

### 4.1 Linux 打包（AppImage / deb / rpm）

Linux 三种包由 **`.github/workflows/linux.yml`** 在 GitHub 托管的 `ubuntu-24.04` runner 上构建，
本地可用同一份脚本复现：

```bash
# 依赖（Ubuntu 24.04）
sudo apt-get install -y clang cmake ninja-build pkg-config \
  libgtk-3-dev liblzma-dev libblkid-dev libstdc++-12-dev \
  file desktop-file-utils rpm zstd libfuse2
# AppImage 工具（一次性）
curl -fsSL -o /tmp/appimagetool \
  https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage
sudo install -m 0755 /tmp/appimagetool /usr/local/bin/appimagetool

# 构建
flutter build linux --release
VERSION=1.0.0 bash packaging/linux/build-packages.sh
```

`packaging/linux/build-packages.sh` 做的事：

1. 把 `build/linux/x64/release/bundle/` 装成 `/usr/lib/dbpilot/`；
2. 生成 `/usr/bin/dbpilot` 软链接、`.desktop` 入口与 hicolor 图标；
3. `appimagetool --no-appstream` 出 AppImage（入口脚本 `packaging/linux/AppRun`）；
4. `dpkg-deb --root-owner-group` 出 deb（带 `Depends` 与 postinst/postrm 刷新桌面缓存）；
5. `rpmbuild` 出 rpm（同样目录布局，`AutoReqProv: no` 避免 runner 上解析不到依赖）。

> CI 里 `APPIMAGE_EXTRACT_AND_RUN=1`：appimagetool 自身也是 AppImage，runner 没有 FUSE，
> 用解包运行模式避免挂载失败。

## 5. 代码签名

### 5.1 Windows（已接入，证书待购买）

签名流程已经接好，**证书配了就会签，没配就自动跳过**（PR 构建仍然出包，只是产物未签名）。

签名覆盖：`build/windows/x64/runner/Release/` 下所有 `*.exe` / `*.dll`，以及 NSIS 安装包本身
（安装包必须在 `makensis` 之后签，否则字节一变签名就失效）。

**启用方式**：到 GitHub → Settings → Secrets and variables → Actions 添加：

| Secret | 说明 | 必需 |
| --- | --- | --- |
| `WINDOWS_CERT_PFX_BASE64` | `.pfx` 证书的 base64 | 二选一 |
| `WINDOWS_CERT_PFX_PASSWORD` | `.pfx` 密码 | 用 PFX 时必填 |
| `WINDOWS_CERT_THUMBPRINT` | 已装进证书存储的证书 SHA-1 指纹 | 二选一 |

生成 base64：

```bash
# macOS / Linux
base64 -i dbpilot-code-signing.pfx | tr -d '\n' | pbcopy
# Windows PowerShell
[Convert]::ToBase64String([IO.File]::ReadAllBytes('dbpilot-code-signing.pfx')) | Set-Clipboard
```

脚本：`packaging/windows/sign-windows.ps1`（自动找 Windows SDK 的 `signtool.exe`，
用 SHA-256 摘要 + DigiCert RFC3161 时间戳，签完逐个 `signtool verify /pa` 校验）。

**证书要求**：Windows 代码签名证书分 OV / EV 两种。OV 证书签名后仍需累积 SmartScreen 信誉
（新证书头几百次下载仍可能警告）；EV 证书立即获得信誉，但需要硬件令牌（CI 里要用
Azure Trusted Signing 或云 HSM，成本更高）。

### 5.2 macOS（未签名）

用 Xcode 默认的 ad-hoc 签名（`CODE_SIGN_IDENTITY = "-"`），**没有公证**。
首次打开会被 Gatekeeper 拦下，右键 → 打开，或：

```bash
xattr -dr com.apple.quarantine DBPilot.app
```

要消除提示需要 Apple Developer ID + `codesign`/`notarytool`，需要付费证书与 secrets。

## 6. 本地复现构建

前置：Flutter 3.47.7（项目实测版本）、Rust stable、Xcode（macOS）/ VS Build Tools 2022 + Windows SDK（Windows）。

```bash
cd desktop            # 发布仓库根
flutter pub get

# macOS（产物 build/macos/Build/Products/Release/DBPilot.app）
flutter build macos --release

# Windows（产物 build/windows/x64/runner/Release/）
flutter build windows --release
```

macOS 打包 zip（与 CI 完全一致）：

```bash
VERSION=1.0.0
ditto -c -k --sequesterRsrc --keepParent \
  "build/macos/Build/Products/Release/DBPilot.app" "DBPilot-${VERSION}-macos.zip"
```

Windows 打包（PowerShell，与 CI 一致）：

```powershell
$VERSION = "1.0.0"

# 1) 免安装 zip
Compress-Archive -Path "build/windows/x64/runner/Release/*" `
  -DestinationPath "DBPilot-$VERSION-windows-x64-portable.zip" -Force

# 2) NSIS 安装包（需先装 NSIS：choco install nsis）
& "C:\Program Files (x86)\NSIS\makensis.exe" `
  /DVERSION=$VERSION `
  /DSRCDIR=build\windows\x64\runner\Release `
  /DOUTFILE=DBPilot-$VERSION-windows-x64-setup.exe `
  /DAPP_ICON=windows\runner\resources\app_icon.ico `
  packaging\windows\installer.nsi

# 3) 可选：签名（没有证书时会自动跳过）
.\packaging\windows\sign-windows.ps1 -Path "DBPilot-$VERSION-windows-x64-setup.exe" `
  -PfxPath cert.pfx -PfxPassword "***"
```

### 6.1 本地构建注意事项

- **不要用 `--no-pub`**：`flutter build macos --release --no-pub` 在 SPM/CocoaPods 混合状态下会链接失败
  并清掉插件 framework，必须让它跑 `pod install`（见第 35 轮交接）。
- macOS 需要真实 `HOME` 与 `PUB_CACHE=~/.pub-cache`；沙箱里跑会卡在 SwiftPM 缓存权限。
- Rust 部分由 **cargokit** 在 `flutter build` 内部触发（`rust_builder/macos/*.podspec` 的
  `script_phase` 与 `rust_builder/windows/CMakeLists.txt`），产物落在 `build/` 下的临时目录
  （`CARGOKIT_TARGET_TEMP_DIR`），**不复用 `rust/target`**。所以 `build.yml` / `release.yml`
  只缓存 `~/.cargo` 的 registry/git 下载缓存，**不缓存 `rust/target`**（全新 checkout 里它不存在，
  缓存它会让 `actions/cache` 报路径不存在并白占仓库 10 GB 缓存配额）。
  只有 `rust-live.yml` 缓存 `rust/target`，因为那里真的会 `cargo test`。
- macOS universal 包要求两个 Rust target 都装好：
  `rustup target add aarch64-apple-darwin x86_64-apple-darwin`（workflow 已通过
  `dtolnay/rust-toolchain` 的 `targets:` 自动安装）。
- Windows 上 Flutter 的 CMake 构建会调用 `rustup run stable cargo build`，需要 `rustup` 在 PATH 上
  （`dtolnay/rust-toolchain` 已提供）。

## 7. 常见失败

| 现象 | 原因 / 处理 |
| --- | --- |
| `meta` 失败：`版本不一致` | tag 与 `pubspec.yaml` 的 `version:` 不一致；改 `pubspec.yaml` 后重新打 tag（先删旧 tag：`git tag -d v1.1.0 && git push origin :refs/tags/v1.1.0`） |
| `meta` 失败：`kAppVersion` 不一致 | `lib/src/app_version.dart` 没跟着改；同步 `kAppVersion`（`kAppBuildNumber` 可自增）后重新打 tag |
| `meta` 失败：`workflow_dispatch 必须填 version` | 手动触发时 `version` 留空了 |
| `manifest` 失败：`git push` 被拒 | 目标分支保护规则禁止 bot 推送，或并发提交导致非快进；工作流用 `HEAD:main` 推送，冲突时重跑一次即可 |
| Release 资产名不匹配 `fail_on_unmatched_files` | `Package` 步骤没产出 zip（看该步日志里的 `找不到 build/...` 报错） |
| macOS 构建失败 `Undefined symbols ... SCDynamicStore` | Runner 的 `OTHER_LDFLAGS` 缺 `SystemConfiguration`（`macos/Runner/Configs/Release.xcconfig` 已带，若改过 xcconfig 注意保留） |
| Windows 构建卡在 Rust 编译 | 首次无缓存，Rust 依赖全量编译约 7-9 分钟；`timeout-minutes: 90` 足够 |
| `rust-live` 失败但本地通过 | 先看 artifact `rust-live-test-logs` 里的 `01-hermetic.log` / `02-live.log`，再看 job 日志里 compose 的 `logs --tail=200` |

## 8. 与客户端更新检查的关系

客户端（`lib/src/update_check.dart`）只认三个字段：

| 字段 | 必填 | 用途 |
| --- | --- | --- |
| `version` | 是 | 与 `kAppVersion` 做数值比较（容忍 `v` 前缀、`+build`、`-rc1`） |
| `url` | 否 | 「下载」按钮跳转地址 |
| `notes` | 否 | 结果面板里的一行说明 |

缺 `version` 会被判为「更新清单缺少 version 字段」；字段多余不影响解析。
更新源固定为 `lib/src/update_source.dart` 里的 `kUpdateManifestUrl`，用户不可改。
