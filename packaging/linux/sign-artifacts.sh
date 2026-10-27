#!/usr/bin/env bash
# ============================================================================
#  对 Linux 产物做 GPG 分离签名（detached, ASCII-armored）。
#
#  用法（在 desktop/ 目录执行）：
#    bash packaging/linux/sign-artifacts.sh [要签名的目录，默认 dist]
#
#  环境变量：
#    GPG_PRIVATE_KEY   base64 编码的 armored 私钥（为空则只警告并跳过签名，退出码 0）
#    GPG_PASSPHRASE    私钥口令（可选；空口令密钥留空即可）
#    GPG_PUBLIC_KEY    base64 编码的 armored 公钥（可选；缺省时从私钥推导）
#    GPG_KEY_ID        签名用的密钥 ID / 邮箱（可选；缺省用临时 GNUPGHOME 里的第一个私钥）
#    GPG_BIN           指定 gpg 可执行文件（可选；缺省自动探测 gpg / gpg2）
#
#  产出（全部落在目标目录，默认 dist/）：
#    <产物>.asc            每个产物的分离 ASCII 签名，例如：
#                          DBPilot-1.1.3-linux-x64.AppImage.asc
#                          dbpilot_1.1.3_amd64.deb.asc
#                          dbpilot-1.1.3-1.x86_64.rpm.asc
#    SHA256SUMS            所有产物的 sha256 汇总（用户最容易验证的形式）
#    SHA256SUMS.asc        SHA256SUMS 的分离签名
#    DBPILOT-GPG-KEY.asc   公钥，供用户 gpg --import 后验证
#
#  安全约定：
#    * 私钥只导入 mktemp -d 出来的临时 GNUPGHOME，脚本退出（含异常/中断）时整目录删除。
#    * 绝不把私钥写进工作区，也绝不打印到日志（只报告字节数）。
#    * 未配置 GPG_PRIVATE_KEY 时**不返回非 0**：只打印警告后正常退出，
#      保证现有发版流程不被破坏（产物照常上传，只是没有 .asc）。
# ============================================================================
set -euo pipefail

# ---------------------------------------------------------------- 参数/常量
TARGET_DIR="${1:-dist}"
PUBKEY_NAME="DBPILOT-GPG-KEY.asc"
SUMS_NAME="SHA256SUMS"
SUMS_SIG="${SUMS_NAME}.asc"

# 只认这三个 Linux 产物后缀。显式列出而不是 *，避免把 .asc 自己算进 SHA256SUMS
# （否则用户校验时 SHA256SUMS 里会包含它自己的签名文件，形成无意义的自引用）。
SIGN_GLOBS=('*.AppImage' '*.deb' '*.rpm')

log()  { printf '%s\n' "$*"; }
warn() { printf '::warning::%s\n' "$*" >&2; }
err()  { printf '::error::%s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

# ---------------------------------------------------------------- gpg 探测
detect_gpg() {
  if [ -n "${GPG_BIN:-}" ]; then
    command -v "$GPG_BIN" >/dev/null 2>&1 || return 1
    printf '%s' "$GPG_BIN"
    return 0
  fi
  local c
  for c in gpg gpg2; do
    if command -v "$c" >/dev/null 2>&1; then
      printf '%s' "$c"
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------- 缺密钥降级
# 本脚本最重要的一条路径：密钥缺失必须 exit 0，只是不签名。
no_key_bailout() {
  warn "未配置 GPG_PRIVATE_KEY，产物将不签名（继续上传未签名产物）。"
  warn "原因：$*"
  warn "如需签名，见 packaging/linux/VERIFYING.md 的「发布者：配置签名密钥」。"
  exit 0
}

[ -d "$TARGET_DIR" ] || die "找不到目录 ${TARGET_DIR}（先跑 packaging/linux/build-packages.sh）"

if [ -z "${GPG_PRIVATE_KEY:-}" ]; then
  no_key_bailout "环境变量 GPG_PRIVATE_KEY 为空"
fi

if ! GPG="$(detect_gpg)"; then
  no_key_bailout "本机没有 gpg（apt-get install -y gnupg / brew install gnupg）"
fi

# gpgconf 跟 gpg 通常同目录（Homebrew / 自编译前缀常见二者不在 PATH 里），
# 先按 gpg 所在目录推，再退回 PATH。
resolve_gpgconf() {
  local gpgdir
  gpgdir="$(cd "$(dirname "$(command -v "$GPG")")" 2>/dev/null && pwd)" || gpgdir=""
  if [ -n "$gpgdir" ] && [ -x "$gpgdir/gpgconf" ]; then
    printf '%s' "$gpgdir/gpgconf"
  elif command -v gpgconf >/dev/null 2>&1; then
    command -v gpgconf
  fi
}
GPGCONF="$(resolve_gpgconf || true)"

# ---------------------------------------------------------------- 收集产物
ARTIFACTS=()
shopt -s nullglob
for pat in "${SIGN_GLOBS[@]}"; do
  for f in "$TARGET_DIR"/$pat; do
    [ -f "$f" ] && ARTIFACTS+=("$f")
  done
done
shopt -u nullglob

if [ "${#ARTIFACTS[@]}" -eq 0 ]; then
  # 没有产物就没什么可签，同样不该让 CI 挂掉。
  warn "在 $TARGET_DIR 下没有找到可签名的产物（*.AppImage / *.deb / *.rpm），跳过签名。"
  exit 0
fi

log "== 待签名产物 =="
printf '  %s\n' "${ARTIFACTS[@]}"

# ---------------------------------------------------------------- 临时 GNUPGHOME
# 关键：私钥只活在这个目录里。trap 覆盖 EXIT/INT/TERM，异常路径也会清理。
GNUPGHOME_TMP="$(mktemp -d "${TMPDIR:-/tmp}/dbpilot-gnupg.XXXXXXXX")"
chmod 700 "$GNUPGHOME_TMP"
export GNUPGHOME="$GNUPGHOME_TMP"
# 防止任何 pinentry / curses 交互（CI 上没有终端）
export GPG_TTY=""

cleanup_gnupghome() {
  # 先让 gpg-agent 退出，否则临时目录可能删不干净 / 残留 agent 进程
  if [ -n "${GPGCONF:-}" ]; then
    "$GPGCONF" --kill all >/dev/null 2>&1 || true
  fi
  rm -rf "$GNUPGHOME_TMP" || true
}
trap cleanup_gnupghome EXIT INT TERM
# 注意：$VAR 后面紧跟中文时必须写成 ${VAR}，否则 bash 会把多字节字符
# 当作变量名的一部分（set -u 下报 "unbound variable"）。全脚本都遵守这一条。
log "临时 GNUPGHOME：${GNUPGHOME_TMP}（脚本结束自动删除，私钥不落工作区）"

# ---------------------------------------------------------------- 导入私钥
# 私钥先解码到临时 GNUPGHOME（权限 600），导入后立即删除，全程不进工作区。
PRIV_TMP="$GNUPGHOME_TMP/__private.asc"
if ! ( umask 077; printf '%s' "$GPG_PRIVATE_KEY" | base64 -d > "$PRIV_TMP" ); then
  die "GPG_PRIVATE_KEY base64 解码失败（该 secret 应是 base64 编码的 armored 私钥）"
fi
[ -s "$PRIV_TMP" ] || die "GPG_PRIVATE_KEY 解码后为空（检查 secret 是否完整粘贴）"
if ! grep -q 'BEGIN PGP PRIVATE KEY BLOCK' "$PRIV_TMP"; then
  die "GPG_PRIVATE_KEY 解码后不是 armored 私钥（缺少 'BEGIN PGP PRIVATE KEY BLOCK'）"
fi
log "  私钥已解码：$(wc -c < "$PRIV_TMP" | tr -d ' ') bytes"

log "== 导入私钥 =="
# 口令走 fd 3，不出现在 ps 的命令行里。
# 空口令也必须显式 loopback，否则 gpg 2.1+ 在无 TTY 环境会卡在 pinentry。
if [ -n "${GPG_PASSPHRASE:-}" ]; then
  "$GPG" --batch --no-tty --pinentry-mode loopback --passphrase-fd 3 \
    --import "$PRIV_TMP" 3<<<"$GPG_PASSPHRASE" \
    || die "私钥导入失败（口令不对或密钥块损坏）"
else
  "$GPG" --batch --no-tty --pinentry-mode loopback --passphrase "" \
    --import "$PRIV_TMP" \
    || die "私钥导入失败（若该密钥有口令，请设置 GPG_PASSPHRASE）"
fi
rm -f "$PRIV_TMP"

# 确认确实有可用的私钥（secret key）
if ! "$GPG" --batch --list-secret-keys --with-colons 2>/dev/null | grep -q '^sec:'; then
  die "导入后没有找到任何私钥（secret key）"
fi

# 决定用哪把密钥签：GPG_KEY_ID 优先，否则取第一个私钥的 fingerprint
if [ -n "${GPG_KEY_ID:-}" ]; then
  SIGN_KEY="$GPG_KEY_ID"
else
  SIGN_KEY="$("$GPG" --batch --list-secret-keys --with-colons 2>/dev/null \
    | awk -F: '/^fpr:/ {print $10; exit}')"
  [ -n "$SIGN_KEY" ] || die "无法确定签名密钥指纹"
fi
log "  签名密钥：$SIGN_KEY"

# 签名公共参数：--armor（ASCII 装甲）、--detach-sign（分离签名）、--yes（覆盖旧签名）
SIGN_CMD=("$GPG" --batch --no-tty --yes --armor --detach-sign --local-user "$SIGN_KEY")
if [ -n "${GPG_PASSPHRASE:-}" ]; then
  SIGN_CMD+=(--pinentry-mode loopback --passphrase-fd 3)
else
  SIGN_CMD+=(--pinentry-mode loopback --passphrase "")
fi

sign_file() {
  local src="$1" out="$2"
  if [ -n "${GPG_PASSPHRASE:-}" ]; then
    "${SIGN_CMD[@]}" --output "$out" "$src" 3<<<"$GPG_PASSPHRASE" \
      || die "签名失败：$src"
  else
    "${SIGN_CMD[@]}" --output "$out" "$src" \
      || die "签名失败：$src"
  fi
}

# ---------------------------------------------------------------- 逐产物签名
log "== 生成分离签名（.asc）=="
for f in "${ARTIFACTS[@]}"; do
  sig="${f}.asc"
  sign_file "$f" "$sig"
  # 立刻自检：签名必须能被验证通过，否则宁可失败也别上传坏签名
  "$GPG" --batch --no-tty --verify "$sig" "$f" >/dev/null 2>&1 \
    || die "自检失败：$sig 无法验证（gpg --verify）"
  log "  签名完成：$(basename "$sig")"
done

# ---------------------------------------------------------------- SHA256SUMS
# 在目标目录内计算，保证清单里是裸文件名（sha256sum -c 才能直接跑）。
log "== 生成 $SUMS_NAME =="
SUMS_PATH="$TARGET_DIR/$SUMS_NAME"
: > "$SUMS_PATH"
for f in "${ARTIFACTS[@]}"; do
  # 统一用 GNU/Linux 的 sha256sum；macOS 没有时退回 shasum -a 256（输出格式一致）
  if command -v sha256sum >/dev/null 2>&1; then
    ( cd "$TARGET_DIR" && sha256sum "$(basename "$f")" ) >> "$SUMS_PATH"
  else
    ( cd "$TARGET_DIR" && shasum -a 256 "$(basename "$f")" ) >> "$SUMS_PATH"
  fi
done
# 文件顺序：在 SHA256SUMS 里按名称排序，保证同一批产物两次生成结果稳定
sort -k2 "$SUMS_PATH" -o "$SUMS_PATH"
cat "$SUMS_PATH"

log "== 签名 $SUMS_NAME =="
sign_file "$SUMS_PATH" "$TARGET_DIR/$SUMS_SIG"
"$GPG" --batch --no-tty --verify "$TARGET_DIR/$SUMS_SIG" "$SUMS_PATH" >/dev/null 2>&1 \
  || die "自检失败：$SUMS_SIG 无法验证"
log "  签名完成：$SUMS_SIG"

# ---------------------------------------------------------------- 公钥导出
log "== 导出公钥 $PUBKEY_NAME =="
KEY_ASC="$TARGET_DIR/$PUBKEY_NAME"
if [ -n "${GPG_PUBLIC_KEY:-}" ]; then
  # 优先用显式提供的公钥 secret（可在私钥不在时的场景使用）
  if ! ( umask 077; printf '%s' "$GPG_PUBLIC_KEY" | base64 -d > "$KEY_ASC" ); then
    die "GPG_PUBLIC_KEY base64 解码失败"
  fi
  grep -q 'BEGIN PGP PUBLIC KEY BLOCK' "$KEY_ASC" \
    || die "GPG_PUBLIC_KEY 解码后不是 armored 公钥"
  log "  使用 GPG_PUBLIC_KEY 提供的公钥"
else
  # 缺省从私钥推导：临时 GNUPGHOME 里刚导入的那把
  "$GPG" --batch --no-tty --armor --export "$SIGN_KEY" > "$KEY_ASC" \
    || die "从私钥导出公钥失败"
  [ -s "$KEY_ASC" ] || die "导出的公钥为空"
  log "  从私钥推导公钥"
fi
chmod 644 "$KEY_ASC"

# ---------------------------------------------------------------- 结果
log ""
log "== 签名产物 =="
ls -lh "$TARGET_DIR"/*.asc "$SUMS_PATH" "$TARGET_DIR/$PUBKEY_NAME" 2>/dev/null \
  | sed 's/^/  /' || true
log ""
log "签名完成：$(basename "$TARGET_DIR") 下共 ${#ARTIFACTS[@]} 个产物已签名。"
log "用户验证方式见 packaging/linux/VERIFYING.md"
