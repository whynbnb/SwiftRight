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

# 构建产物一落盘就会被 LaunchServices 自动登记，于是同一个 bundle id
# 出现多份注册。系统挑哪一份是不确定的 —— 实测过访达菜单被 DerivedData
# 里的 Debug 副本接管，一旦清理 DerivedData 右键菜单就整个失效。
# 所以装完必须把构建目录里的副本全部注销，只留 /Applications 这一份。
echo "==> 注销构建目录里的副本"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
for stray in \
  "$BUILD_DIR/Build/Products/Debug/$APP_NAME" \
  "$BUILD_DIR/Build/Products/Release/$APP_NAME" \
  "$HOME/Library/Developer/Xcode/DerivedData"/SwiftRight-*/Build/Products/*/"$APP_NAME" ; do
  [ -d "$stray" ] || continue
  pluginkit -r "$stray/Contents/PlugIns/FinderExtension.appex" 2>/dev/null || true
  "$LSREGISTER" -u "$stray" 2>/dev/null || true
done

echo "==> 注册访达扩展"
"$LSREGISTER" -f "$DEST" 2>/dev/null || true
pluginkit -a "$DEST/Contents/PlugIns/FinderExtension.appex" 2>/dev/null || true
sleep 1

ACTIVE=$(pluginkit -m -p com.apple.FinderSync -vvv 2>/dev/null \
         | grep -A1 "me.whynbnb" | grep "Path =" | sed 's/.*Path = //')
if [ "$ACTIVE" = "$DEST/Contents/PlugIns/FinderExtension.appex" ]; then
  echo "    生效的扩展: $ACTIVE ✓"
else
  echo "    ⚠️  生效的扩展不是 /Applications 那份：${ACTIVE:-未找到}" >&2
fi

echo
echo "完成。接下来："
echo "  1. 打开 $DEST"
echo "  2. 系统设置 › 通用 › 登录项与扩展 › 访达扩展，勾选 SwiftRight"
echo "  3. 如果菜单没出现：killall Finder"
