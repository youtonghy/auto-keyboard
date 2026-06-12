#!/bin/bash
# 构建并打包 AutoKeyboard.app（辅助功能权限需要以 .app 形式运行）
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-${VERSION:-}}"
BUILD_NUMBER="${BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-1}}"

swift build -c release

APP=build/AutoKeyboard.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/AutoKeyboard "$APP/Contents/MacOS/AutoKeyboard"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [[ -n "$VERSION" ]]; then
  plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
  plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"
fi

# ad-hoc 签名；重新打包后 TCC 可能需要重新授权辅助功能
codesign --force --sign - "$APP"

echo "已生成 $APP"
if [[ -n "$VERSION" ]]; then
  echo "版本号 $VERSION ($BUILD_NUMBER)"
fi
echo "首次运行请在 系统设置 → 隐私与安全性 → 辅助功能 中授权"
