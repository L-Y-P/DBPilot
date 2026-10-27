# 验证 DBPilot 的签名与完整性

DBPilot 的每个 Linux 产物都带一份 **GPG 分离签名**（detached ASCII-armored signature）。
本文件说明用户如何验证下载到的文件确实来自官方发布、且传输过程中没有被篡改。

---

## 1. 发布产物一览

每次发版，Release 页面上会有这些文件：

| 文件 | 说明 |
| --- | --- |
| `DBPilot-<版本>-linux-x64.AppImage` | AppImage（免安装） |
| `dbpilot_<版本>_amd64.deb` | Debian / Ubuntu 安装包 |
| `dbpilot-<版本>-1.x86_64.rpm` | Fedora / RHEL / openSUSE 安装包 |
| `<上面任一文件名>.asc` | 该产物的**分离签名**（一对一） |
| `SHA256SUMS` | 所有产物的 sha256 汇总（**推荐验证这个**） |
| `SHA256SUMS.asc` | `SHA256SUMS` 的分离签名 |
| `DBPILOT-GPG-KEY.asc` | DBPilot 发布公钥 |

文件名示例（版本 1.1.3）：

```text
DBPilot-1.1.3-linux-x64.AppImage
DBPilot-1.1.3-linux-x64.AppImage.asc
dbpilot_1.1.3_amd64.deb
dbpilot_1.1.3_amd64.deb.asc
dbpilot-1.1.3-1.x86_64.rpm
dbpilot-1.1.3-1.x86_64.rpm.asc
SHA256SUMS
SHA256SUMS.asc
DBPILOT-GPG-KEY.asc
```

> **关于 AppImage 的 `.asc`**
> AppImage 的 `.asc` 是和 AppImage 文件**并列的外置签名文件**，它跟 AppImage 内部
> 可能自带的更新信息（zsync / 嵌入的签名）**没有任何关系**。内置的 zsync 只用来做增量
> 更新，不证明发布者身份；真正的来源证明只有这里的外置 `.asc`。

---

## 2. 拿到公钥

### 2.1 从 Release 页面下载（最省事）

从同一 Release 下载 `DBPILOT-GPG-KEY.asc`，然后导入：

```bash
gpg --import DBPILOT-GPG-KEY.asc
```

### 2.2 校验公钥指纹（强烈建议做一次）

导入后打印指纹，并与官方公布的指纹逐字比对：

```bash
gpg --show-keys --with-fingerprint DBPILOT-GPG-KEY.asc
# 或用下面这条看已导入的密钥
gpg --list-keys --fingerprint
```

> 公钥指纹是**唯一**可信的锚点。请以 README / 官网 / Release 说明里公布的指纹为准。
> 只看「签名有效」是不够的——攻击者完全可以换一个自己的公钥重新签名。

---

## 3. 验证（推荐流程：先验 SHA256SUMS，再核对文件哈希）

这一步同时能证明两件事：**发布者身份**（GPG）和**文件完整性**（sha256）。

### 3.1 安装 gpg

```bash
# Ubuntu / Debian
sudo apt-get update && sudo apt-get install -y gnupg

# Fedora / RHEL / openSUSE
sudo dnf install -y gnupg2

# macOS
brew install gnupg
```

### 3.2 导入公钥

```bash
gpg --import DBPILOT-GPG-KEY.asc
```

（可选，更安全：只信任这一把密钥）

```bash
# 交互式设置信任级别；提示输入指纹时粘贴第 2.2 步拿到的完整指纹
gpg --edit-key <指纹> trust
# 选 5 (I trust ultimately)，然后 quit
```

### 3.3 验证 SHA256SUMS 的签名

```bash
gpg --verify SHA256SUMS.asc SHA256SUMS
```

**通过时**会看到类似输出（关键是出现 `Good signature`）：

```text
gpg: Signature made Tue Oct 27 12:00:00 2026 CST
gpg:                using RSA key 0123456789ABCDEF...
gpg: Good signature from "DBPilot Release <release@dbpilot.example>" [unknown]
```

> 出现 `WARNING: This key is not certified with a trusted signature!` 是**正常的**：
> 它只表示你还没用 `gpg --edit-key ... trust` 把这把密钥标为可信，不代表签名有问题。
> 只要上面是 `Good signature`，且指纹与官方公布的一致，就算验证通过。

### 3.4 核对下载文件的哈希

把 `SHA256SUMS` 和要校验的产物放在**同一个目录**下：

```bash
# Linux
sha256sum -c SHA256SUMS

# macOS（没有 sha256sum，用 shasum）
shasum -a 256 -c SHA256SUMS
```

只想校验其中一个文件：

```bash
# Linux
sha256sum -c SHA256SUMS --ignore-missing

# macOS
grep ' dbpilot_' SHA256SUMS > /tmp/one.sums && shasum -a 256 -c /tmp/one.sums
```

**通过时**每个文件一行 `<文件名>: OK`；有任何 `FAILED` 就说明文件被改过或下载不完整，
**不要安装**。

### 3.5 完整一键脚本（Linux）

把这一整段存成 `verify.sh`，和下载的文件放在同一目录，然后 `bash verify.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail

# 1) 导入公钥（Release 页面同目录下载）
gpg --import DBPILOT-GPG-KEY.asc

# 2) 验证指纹（把下面这行换成官方公布的完整指纹）
EXPECTED_FPR="XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
ACTUAL_FPR="$(gpg --show-keys --with-colons DBPILOT-GPG-KEY.asc | awk -F: '/^fpr:/ {print $10; exit}')"
echo "公钥指纹：$ACTUAL_FPR"
if [ "$ACTUAL_FPR" != "$EXPECTED_FPR" ]; then
  echo "!! 公钥指纹不匹配，停止验证" >&2
  exit 1
fi

# 3) 验证 SHA256SUMS 的签名
gpg --verify SHA256SUMS.asc SHA256SUMS

# 4) 核对所有产物哈希
sha256sum -c SHA256SUMS
echo "全部通过 ✔"
```

---

## 4. 验证单个产物的签名（.asc，可选）

如果你只想验证某一个文件（例如只下 AppImage），可以直接用它的专属签名：

```bash
gpg --verify DBPilot-1.1.3-linux-x64.AppImage.asc DBPilot-1.1.3-linux-x64.AppImage
gpg --verify dbpilot_1.1.3_amd64.deb.asc   dbpilot_1.1.3_amd64.deb
gpg --verify dbpilot-1.1.3-1.x86_64.rpm.asc dbpilot-1.1.3-1.x86_64.rpm
```

注意：**签名和文件必须成对**。签名写进任意一个临时文件也能对上，所以
`gpg --verify <签名> <文件>` 里两个参数都要给对。

---

## 5. 只验签名不导入到日常 keyring（更干净的姿势）

不想污染自己的 keyring，可以用一次性 GNUPGHOME：

```bash
TMPH=$(mktemp -d)
GNUPGHOME="$TMPH" gpg --import DBPILOT-GPG-KEY.asc
GNUPGHOME="$TMPH" gpg --verify SHA256SUMS.asc SHA256SUMS
sha256sum -c SHA256SUMS
rm -rf "$TMPH"
```

---

## 6. 常见问题

| 现象 | 含义 / 处理 |
| --- | --- |
| `Can't check signature: No public key` | 还没导入公钥，回到第 2 节 |
| `BAD signature` | **签名不匹配**。文件可能被篡改，或 `.asc` 与文件不配对。**不要安装** |
| `WARNING: This key is not certified...` | 正常。只是没在本地信任这把密钥，不影响 `Good signature` 结论 |
| `sha256sum: WARNING: 1 computed checksum did NOT match` | 文件损坏或被改过，重新下载；仍失败则**不要安装** |
| `gpg: no valid OpenPGP data found` | 拿到的是 GitHub 的 HTML 页面而不是文件本身（下载链接没点对） |
| 完全没有 `.asc` 文件 | 该版本发版时未配置签名密钥，产物可用但无法验证来源 |

---

## 7. 发布者：配置签名密钥

> 以下是**维护者**要做的事，普通用户可跳过。

### 7.1 生成密钥（交互式）

在**自己的机器**上执行（不要放 CI）：

```bash
gpg --full-generate-key
```

交互步骤：

1. `Please select what kind of key you want` → 选 **1 (RSA and RSA)** 或直接回车默认；
   RSA 建议 4096 位：`What keysize do you want?` 输入 `4096`。
2. `Please specify how long the key should be valid` → 输入 `0`（永不过期）或按需填 `2y`。
   确认提示输入 `y`。
3. `Real name` → 例如 `DBPilot Release`
4. `Email address` → 例如 `release@your-domain`
5. `Comment` → 可留空，或填 `DBPilot Linux packages`
6. 确认信息输入 `O`(Okay)
7. `Enter passphrase` → 设置口令（**推荐设置**，记进密码管理器）。
   想让 CI 无需口令输入，也可以直接回车留空（不推荐）。

生成完拿到指纹：

```bash
gpg --list-secret-keys --keyid-format LONG
# 输出里 sec   rsa4096/ABCDEF0123456789 ... 这一段就是 Key ID
gpg --fingerprint --with-colons <你的邮箱> | awk -F: '/^fpr:/ {print $10; exit}'
```

### 7.2 导出并 base64 编码

```bash
KEY_ID="<第 7.1 步拿到的主密钥指纹或 Key ID>"

# 私钥（armored → base64，单行）
gpg --batch --armor --export-secret-keys "$KEY_ID" | base64 | tr -d '\n' > gpg-private-key.b64

# 公钥（armored → base64，单行）
gpg --batch --armor --export "$KEY_ID" | base64 | tr -d '\n' > gpg-public-key.b64

# 看看大小，确认非空
wc -c gpg-private-key.b64 gpg-public-key.b64
```

> **私钥只留在本机**。`gpg-private-key.b64` 是等价于私钥的敏感文件，
> 提交到 GitHub Secret 后立刻 `shred -u gpg-private-key.b64`（macOS 用 `rm -P`）。
> 千万别提交进仓库、别贴到聊天工具。

macOS 上没有 `shred`，用：

```bash
rm -P gpg-private-key.b64
```

### 7.3 写进 GitHub Secrets

仓库 → Settings → Secrets and variables → Actions → New repository secret：

| Secret 名称 | 必需 | 内容 |
| --- | --- | --- |
| `GPG_PRIVATE_KEY` | **必需** | `gpg-private-key.b64` 的**全部内容**（单行 base64） |
| `GPG_PASSPHRASE` | 可选 | 第 7.1 步设置的口令；空口令密钥则**不建**这个 secret |
| `GPG_PUBLIC_KEY` | 可选 | `gpg-public-key.b64`；不建也没关系，CI 会从私钥推导公钥 |

用 `gh` 命令行可以直接写：

```bash
gh secret set GPG_PRIVATE_KEY < gpg-private-key.b64
# 口令（可选，有空口令密钥就不用建）
gh secret set GPG_PASSPHRASE
# 公钥（可选）
gh secret set GPG_PUBLIC_KEY < gpg-public-key.b64
```

### 7.4 CI 行为

- **配了 `GPG_PRIVATE_KEY`**：每个产物生成 `<文件名>.asc`，另出
  `SHA256SUMS` / `SHA256SUMS.asc` / `DBPILOT-GPG-KEY.asc`，一起进 artifact 和 Release。
- **没配 `GPG_PRIVATE_KEY`**：只打印警告 `未配置 GPG_PRIVATE_KEY，产物将不签名`，
  **不影响构建、不失败**，产物照常上传（只是没有 `.asc`）。
- 签名全程在 `mktemp -d` 出来的临时 `GNUPGHOME` 里做，脚本结束时删除；
  私钥不会写进工作区，也不会进日志。

### 7.5 本地手动签名

```bash
# 先打好包：dist/ 里有 AppImage / deb / rpm
cd desktop
VERSION=1.1.3 bash packaging/linux/build-packages.sh   # 打包（若还没打）

# 只做签名（把第 7.2 步的 base64 内容塞进环境变量）
export GPG_PRIVATE_KEY="$(cat gpg-private-key.b64)"
export GPG_PASSPHRASE="<口令，没有就不设>"
bash packaging/linux/sign-artifacts.sh dist

ls -l dist/*.asc dist/SHA256SUMS dist/DBPILOT-GPG-KEY.asc
```
