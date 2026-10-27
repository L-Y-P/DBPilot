#!/usr/bin/env bash
# ============================================================================
#  把 flutter build linux --release 的产物打成 AppImage / deb / rpm。
#
#  用法（在仓库根执行）：
#    VERSION=1.0.0 bash packaging/linux/build-packages.sh
#
#  输入：build/linux/x64/release/bundle/  （Flutter 输出，含 DBPilot + lib/ + data/）
#  输出：dist/DBPilot-<version>-linux-x64.AppImage
#        dist/dbpilot_<version>_amd64.deb
#        dist/dbpilot-<version>-1.x86_64.rpm
#
#  可选签名：设置 GPG_PRIVATE_KEY（base64 的 armored 私钥）后，本脚本在打包结束时
#  自动调用 packaging/linux/sign-artifacts.sh 生成 <产物>.asc / SHA256SUMS(.asc) /
#  DBPILOT-GPG-KEY.asc。**未设置时不签名、也不失败**，保持原有发版流程可用。
#  详细说明见 packaging/linux/VERIFYING.md。
#
#  依赖（Ubuntu 24.04）：
#    apt-get install -y file libfuse2 rpm zstd desktop-file-utils
#    AppImage 需要 appimagetool（https://github.com/AppImage/AppImageKit/releases）
# ============================================================================
set -euo pipefail

VERSION="${VERSION:-1.0.0}"
BUNDLE="build/linux/x64/release/bundle"
OUT="dist"
APP=DBPilot
PKG_ID=dbpilot

[ -d "$BUNDLE" ] || { echo "找不到 ${BUNDLE}，先跑 flutter build linux --release" >&2; exit 1; }
[ -x "$BUNDLE/$APP" ] || { echo "$BUNDLE/$APP 不存在" >&2; exit 1; }
mkdir -p "$OUT"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# ------------------------------------------------------------------ 文件树
# /usr/lib/dbpilot 放 bundle 本体；/usr/bin/dbpilot 是指向它的软链接。
install_tree() {
  local root="$1"
  mkdir -p "$root/usr/lib/dbpilot" "$root/usr/bin" \
           "$root/usr/share/applications" \
           "$root/usr/share/icons/hicolor/256x256/apps"
  cp -a "$BUNDLE"/. "$root/usr/lib/dbpilot/"
  ln -sf /usr/lib/dbpilot/"$APP" "$root/usr/bin/$PKG_ID"
  cp packaging/linux/dbpilot.desktop "$root/usr/share/applications/$PKG_ID.desktop"
  # 图标：用仓库里已有的产品图标（256x256 已足够，hicolor 会缩放）
  cp assets/images/dbpilot.png "$root/usr/share/icons/hicolor/256x256/apps/$PKG_ID.png"
}

echo "== 准备文件树 =="
install_tree "$STAGE/root"
du -sh "$STAGE/root"

# ------------------------------------------------------------------ AppImage
echo "== 构建 AppImage =="
APPDIR="$STAGE/DBPilot.AppDir"
mkdir -p "$APPDIR"
cp -a "$STAGE/root/usr" "$APPDIR/usr"
cp packaging/linux/AppRun "$APPDIR/AppRun" && chmod +x "$APPDIR/AppRun"
cp packaging/linux/dbpilot.desktop "$APPDIR/$PKG_ID.desktop"
cp assets/images/dbpilot.png "$APPDIR/$PKG_ID.png"

if command -v appimagetool >/dev/null 2>&1; then
  # --no-appstream：仓库里没有 AppStream 元数据，避免工具报错退出
  ARCH=x86_64 appimagetool --no-appstream "$APPDIR" "$OUT/$APP-$VERSION-linux-x64.AppImage"
  chmod +x "$OUT/$APP-$VERSION-linux-x64.AppImage"
  echo "  完成：$OUT/$APP-$VERSION-linux-x64.AppImage"
else
  echo "  跳过 AppImage：未找到 appimagetool" >&2
fi

# ------------------------------------------------------------------ deb
echo "== 构建 deb =="
DEBROOT="$STAGE/deb"
mkdir -p "$DEBROOT/DEBIAN"
cp -a "$STAGE/root/." "$DEBROOT/"
INSTALLED_KB=$(du -sk --apparent-size "$DEBROOT/usr" | cut -f1)
cat > "$DEBROOT/DEBIAN/control" <<EOF
Package: $PKG_ID
Version: $VERSION
Section: database
Priority: optional
Architecture: amd64
Maintainer: L-Y-P <17288034857@163.com>
Installed-Size: $INSTALLED_KB
Depends: libgtk-3-0, libblkid1, liblzma5, libstdc++6
Homepage: https://github.com/L-Y-P/DBPilot
Description: DBPilot - database client for MySQL / MariaDB / PostgreSQL / SQLite
 DBPilot is a cross-platform desktop database client built with Flutter and Rust.
 It supports MySQL / MariaDB, PostgreSQL and SQLite with a query builder,
 data import/export in 8 formats, backups, schema sync and more.
EOF
# 每次安装/卸载后刷新桌面与图标缓存（缺失时静默跳过）
cat > "$DEBROOT/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q /usr/share/applications || true
command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
exit 0
EOF
cp "$DEBROOT/DEBIAN/postinst" "$DEBROOT/DEBIAN/postrm"
chmod 755 "$DEBROOT/DEBIAN/postinst" "$DEBROOT/DEBIAN/postrm"
dpkg-deb --root-owner-group --build "$DEBROOT" "$OUT/${PKG_ID}_${VERSION}_amd64.deb" >/dev/null
echo "  完成：$OUT/${PKG_ID}_${VERSION}_amd64.deb"

# ------------------------------------------------------------------ rpm
echo "== 构建 rpm =="
if command -v rpmbuild >/dev/null 2>&1; then
  RPMTOP="$STAGE/rpmbuild"
  mkdir -p "$RPMTOP"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
  cat > "$RPMTOP/SPECS/dbpilot.spec" <<EOF
Name:           $PKG_ID
Version:        $VERSION
Release:        1
Summary:        Database client for MySQL / MariaDB / PostgreSQL / SQLite
License:        MIT
URL:            https://github.com/L-Y-P/DBPilot
BuildArch:      x86_64
AutoReqProv:    no
Requires:       gtk3, libstdc++

%description
DBPilot is a cross-platform desktop database client built with Flutter and Rust.
It supports MySQL / MariaDB, PostgreSQL and SQLite.

%install
cp -a %{_sourcedir}/root/. %{buildroot}/

%files
/usr/lib/dbpilot
/usr/bin/dbpilot
/usr/share/applications/dbpilot.desktop
/usr/share/icons/hicolor/256x256/apps/dbpilot.png

%post
update-desktop-database -q /usr/share/applications >/dev/null 2>&1 || :
gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor >/dev/null 2>&1 || :

%changelog
* $(date +"%a %b %d %Y") L-Y-P - $VERSION-1
- Release $VERSION
EOF
  cp -a "$STAGE/root" "$RPMTOP/SOURCES/root"
  rpmbuild -bb --define "_topdir $RPMTOP" "$RPMTOP/SPECS/dbpilot.spec" >/dev/null
  cp "$RPMTOP"/RPMS/x86_64/*.rpm "$OUT/"
  echo "  完成：$(ls "$OUT"/*.rpm | head -1)"
else
  echo "  跳过 rpm：未找到 rpmbuild（apt-get install -y rpm）" >&2
fi

# ------------------------------------------------------------------ 签名（可选）
# GPG_PRIVATE_KEY 为空时直接跳过，**不影响退出码**，产物照常可用。
# 真正不签名的逻辑在 sign-artifacts.sh 里，这里只负责转发环境变量。
echo "== GPG 签名 =="
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/sign-artifacts.sh" ]; then
  # 注意：不能把 sign-artifacts.sh 的非 0 当成整体失败 —— 它在缺密钥时本来就返回 0，
  # 只有真正的签名错误（密钥损坏等）才返回非 0，这种才应该让 CI 失败。
  bash "$SCRIPT_DIR/sign-artifacts.sh" "$OUT"
else
  echo "  跳过：未找到 $SCRIPT_DIR/sign-artifacts.sh" >&2
fi

echo
echo "== 产物 =="
ls -lh "$OUT"