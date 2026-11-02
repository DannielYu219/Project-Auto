#!/usr/bin/env bash
# 安装 smolvm（macOS arm64）
#
# 用法：
#   ./install-smolvm.sh ~/Downloads/smolvm-1.32.4-darwin-arm64.tar
#
# 做四件事：
#   1. 解压到 /usr/local/lib/smolvm
#   2. 去掉 quarantine
#   3. 重新签名，并给主二进制加 com.apple.security.hypervisor
#      （缺这个 entitlement 时 libkrun 启动会返回 -22）
#   4. 建立 /usr/local/bin/smolvm 软链
set -euo pipefail

TARBALL="${1:?用法: install-smolvm.sh <smolvm-...tar>}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

tar xf "$TARBALL" -C "$WORK"
SRC="$(find "$WORK" -maxdepth 1 -type d -name 'smolvm-*' | head -1)"
[ -n "${SRC}" ] || { echo "找不到解压出来的 smolvm-* 目录" >&2; exit 1; }

DEST=/usr/local/lib/smolvm
sudo rm -rf "$DEST"
sudo mkdir -p "$DEST"
sudo rsync -a "$SRC/" "$DEST/"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

cat > "$WORK/hv.entitlements" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.hypervisor</key>
    <true/>
</dict>
</plist>
EOF

sudo codesign --force --sign - "$DEST"/lib/*.dylib
sudo codesign --force --sign - --entitlements "$WORK/hv.entitlements" "$DEST/smolvm-bin"
sudo ln -sf "$DEST/smolvm" /usr/local/bin/smolvm
sudo ln -sf "$DEST/smolvm-bin" /usr/local/bin/smolvm-bin

echo "installed: $(/usr/local/bin/smolvm --help | head -1)"
