#!/bin/bash
#
# 一键构建并安装到 /Applications。
#
#   ./Scripts/build.sh          构建 + 安装 + 注册扩展
#   ./Scripts/build.sh build    只构建
#
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
BUILD_DIR="$ROOT/.build"
APP_NAME="SwiftRight.app"
DEST="/Applications/$APP_NAME"

echo "==> 生成 Xcode 工程"
xcodegen generate --quiet

echo "==> 编译 Release"
xcodebuild \
  -project SwiftRight.xcodeproj \
  -scheme SwiftRight \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGN_STYLE=Automatic \
  build | \
  { grep -E '(error|warning|BUILD)' || true; }

BUILT="$BUILD_DIR/Build/Products/Release/$APP_NAME"
if [ ! -d "$BUILT" ]; then
  echo "构建产物不存在：$BUILT" >&2
  exit 1
fi

if [ "${1:-install}" = "build" ]; then
  echo "==> 完成：$BUILT"
  exit 0
fi

echo "==> 安装到 $DEST"
# 旧版本还开着的话先退掉，否则替换后仍然跑的是老代码。
osascript -e 'tell application "SwiftRight" to quit' 2>/dev/null || true
pkill -x SwiftRight 2>/dev/null || true
sleep 1

rm -rf "$DEST"
cp -R "$BUILT" "$DEST"

echo "==> 注册访达扩展"
pluginkit -a "$DEST/Contents/PlugIns/FinderExtension.appex" 2>/dev/null || true
pluginkit -m -p com.apple.FinderSync -vvv 2>/dev/null | grep -i swiftright || true

echo
echo "完成。接下来："
echo "  1. 打开 $DEST"
echo "  2. 系统设置 › 通用 › 登录项与扩展 › 访达扩展，勾选 SwiftRight"
echo "  3. 如果菜单没出现：killall Finder"
