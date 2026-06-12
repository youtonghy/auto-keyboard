#!/bin/bash
# 构建并打包 AutoKeyboard.app（辅助功能权限需要以 .app 形式运行）
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=build/AutoKeyboard.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/AutoKeyboard "$APP/Contents/MacOS/AutoKeyboard"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# ad-hoc 签名；重新打包后 TCC 可能需要重新授权辅助功能
codesign --force --sign - "$APP"

echo "已生成 $APP"
echo "首次运行请在 系统设置 → 隐私与安全性 → 辅助功能 中授权"
