#!/usr/bin/env bash
# Build a self-contained .deb: PyInstaller bundle in /opt/kotodl, `kotodl` on PATH, menu entry and icon.
#   packaging/build-deb.sh            -> dist/kotodl_<version>_<arch>.deb
#   VERSION=1.2.0 packaging/build-deb.sh
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PKG=kotodl
VERSION=${VERSION:-1.0.0}
ARCH=$(dpkg --print-architecture)
BUILD=$ROOT/build
VENV=$BUILD/venv
STAGE=$BUILD/deb/${PKG}_${VERSION}_${ARCH}
OUT=$ROOT/dist/${PKG}_${VERSION}_${ARCH}.deb

# 1. Isolated build venv (the project-root venv is left alone).
if [[ ! -x $VENV/bin/python ]]; then
    "${PYTHON:-python3}" -m venv "$VENV"
fi
"$VENV/bin/pip" install -q --upgrade pip
"$VENV/bin/pip" install -q -r "$ROOT/requirements.txt" pyinstaller

# 2. Freeze into a one-folder bundle (starts faster than --onefile).
"$VENV/bin/python" "$ROOT/packaging/freeze.py"

# 3. Lay out the package tree.
rm -rf "$STAGE"
install -d "$STAGE/DEBIAN" "$STAGE/opt" "$STAGE/usr/bin" \
    "$STAGE/usr/share/applications" "$STAGE/usr/share/icons/hicolor/scalable/apps"
cp -a "$BUILD/pyi-dist/$PKG" "$STAGE/opt/$PKG"
ln -s "/opt/$PKG/$PKG" "$STAGE/usr/bin/$PKG"
install -m644 "$ROOT/packaging/kotodl.desktop" "$STAGE/usr/share/applications/$PKG.desktop"
install -m644 "$ROOT/packaging/kotodl.svg" "$STAGE/usr/share/icons/hicolor/scalable/apps/$PKG.svg"

chmod -R u+rwX,go+rX,go-w "$STAGE"
SIZE=$(du -sk --exclude=DEBIAN "$STAGE" | cut -f1)
cat > "$STAGE/DEBIAN/control" <<EOF
Package: $PKG
Version: $VERSION
Section: video
Priority: optional
Architecture: $ARCH
Depends: ffmpeg, libc6, libgl1, libegl1, libxkbcommon0, libfontconfig1, libdbus-1-3, libxcb-cursor0
Installed-Size: $SIZE
Maintainer: Sadiq <sediqabdullahi01@gmail.com>
Description: Anikoto English-dub bulk downloader
 Search Anikoto for a title (or paste a watch URL), pick episodes and a
 resolution, and download the English dub as .mp4 files. Classic
 Windows 2000 style interface.
EOF

cat > "$STAGE/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
command -v update-desktop-database >/dev/null && update-desktop-database -q /usr/share/applications || true
command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q -f /usr/share/icons/hicolor || true
EOF
cp "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/postrm"
chmod 755 "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/postrm"

# 4. Build the .deb with root-owned files.
mkdir -p "$ROOT/dist"
dpkg-deb --root-owner-group --build "$STAGE" "$OUT"
echo "Built $OUT"
