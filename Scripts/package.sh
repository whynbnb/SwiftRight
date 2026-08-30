#!/bin/bash
#
# 打包可分发的二进制产物。
#
#   ./Scripts/package.sh
#
# 产出 dist/SwiftRight-<版本>.zip 和 dist/SwiftRight-<版本>.dmg
#
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
BUILD_DIR="$ROOT/.build"
DIST="$ROOT/dist"
APP_NAME="SwiftRight.app"
BUILT="$BUILD_DIR/Build/Products/Release/$APP_NAME"

VERSION=$(grep 'MARKETING_VERSION' project.yml | head -1 | sed 's/.*"\(.*\)".*/\1/')
[ -n "$VERSION" ] || { echo "读不到 MARKETING_VERSION" >&2; exit 1; }

echo "==> 生成 Xcode 工程"
xcodegen generate --quiet

echo "==> 编译 Release ($VERSION)"
xcodebuild \
  -project SwiftRight.xcodeproj \
  -scheme SwiftRight \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGN_STYLE=Automatic \
  build | { grep -E '(error:|BUILD)' || true; }

[ -d "$BUILT" ] || { echo "构建产物不存在：$BUILT" >&2; exit 1; }

rm -rf "$DIST"
mkdir -p "$DIST"
STAGE="$DIST/stage"
mkdir -p "$STAGE"
cp -R "$BUILT" "$STAGE/$APP_NAME"

# 改用 ad-hoc 重签，理由有两条：
#
# 1. 不会过期。开发证书一年到期，而 Xcode 只在 Developer ID 签名时才向苹果
#    时间戳服务器申请安全时间戳（codesign 里显示 Timestamp=）；开发证书签出来
#    的只有 Signed Time=，那是签名内部未经认证的时间，证书一过期签名就失效。
#    ad-hoc 压根没有证书，也就没有有效期。
#
# 2. 反正都过不了 Gatekeeper。没有 Developer ID 就无法公证，使用者无论如何
#    都要解除隔离标记，开发证书那点身份信息换不来任何实际便利。
#
# 由内向外签：先 appex 再 app。反过来的话外层签名会因为内容变动而失效。
# entitlements 必须显式传，codesign 重签时不会自动保留。
echo "==> ad-hoc 重签"
codesign --force --sign - --options runtime \
  --entitlements "$ROOT/FinderExtension/FinderExtension.entitlements" \
  "$STAGE/$APP_NAME/Contents/PlugIns/FinderExtension.appex"
codesign --force --sign - --options runtime \
  --entitlements "$ROOT/App/SwiftRight.entitlements" \
  "$STAGE/$APP_NAME"

echo "==> 校验签名"
codesign --verify --deep --strict "$STAGE/$APP_NAME"
codesign -dvv "$STAGE/$APP_NAME" 2>&1 | grep -E "^Signature=|^TeamIdentifier=|adhoc"
# 沙盒例外丢了的话，扩展就读不到 commands.json，右键菜单会整个空掉。
codesign -d --entitlements - --xml \
  "$STAGE/$APP_NAME/Contents/PlugIns/FinderExtension.appex" 2>/dev/null \
  | grep -q "temporary-exception" \
  && echo "    扩展的沙盒例外 entitlement 保留 ✓" \
  || { echo "    ❌ 扩展 entitlement 丢失" >&2; exit 1; }

# 用 ditto 而不是 zip：zip 不保留符号链接和扩展属性，
# 解压出来的 .app 签名会失效，用户拿到手直接打不开。
echo "==> 打 zip"
ZIP="$DIST/SwiftRight-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "$STAGE/$APP_NAME" "$ZIP"

echo "==> 打 dmg"
DMG="$DIST/SwiftRight-$VERSION.dmg"
DMG_SRC="$DIST/dmg"
mkdir -p "$DMG_SRC"
# 用重签过的 stage 而不是原始构建产物，否则 dmg 里装的还是开发证书版。
cp -R "$STAGE/$APP_NAME" "$DMG_SRC/$APP_NAME"
# 放一个 /Applications 的软链，用户拖过去就装好了。
ln -s /Applications "$DMG_SRC/Applications"
hdiutil create -quiet -volname "SwiftRight $VERSION" \
  -srcfolder "$DMG_SRC" -ov -format UDZO "$DMG"
rm -rf "$DMG_SRC"

echo "==> 验证 zip 解出来的签名仍然有效"
VERIFY="$DIST/verify"
mkdir -p "$VERIFY"
ditto -x -k "$ZIP" "$VERIFY"
codesign --verify --deep --strict "$VERIFY/$APP_NAME" && echo "    签名往返无损 ✓"
rm -rf "$VERIFY" "$STAGE"

echo
echo "产物："
ls -lh "$DIST" | tail -n +2 | awk '{printf "  %-28s %s\n", $9, $5}'
echo
echo "注意：没有 Developer ID 证书，产物未经公证，Gatekeeper 会拦。"
echo "使用者需要先解除隔离标记："
echo "  xattr -dr com.apple.quarantine /Applications/SwiftRight.app"
