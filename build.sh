#!/bin/bash
set -e

cd "$(dirname "$0")"

MODE="${1:-debug}"
APP_NAME="CampusVPN"
BUNDLE_ID="com.campusvpn.CampusVPN"

echo "=== 构建 $APP_NAME ($MODE) ==="

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"

if [ "$MODE" = "release" ]; then
    swift build -c release 2>&1
    BUILD_DIR=".build/release"
else
    swift build 2>&1
    BUILD_DIR=".build/debug"
fi

APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES"

cp "$BUILD_DIR/$APP_NAME" "$MACOS/$APP_NAME"

if [ -d "$BUILD_DIR/CampusVPN_CampusVPN.bundle" ]; then
    cp -R "$BUILD_DIR/CampusVPN_CampusVPN.bundle" "$RESOURCES/"
fi

cat > "$CONTENTS/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>CampusVPN</string>
    <key>CFBundleIdentifier</key>
    <string>com.campusvpn.CampusVPN</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>CampusVPN</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.2</string>
    <key>CFBundleVersion</key>
    <string>3</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSLocationUsageDescription</key>
    <string>CampusVPN 需要位置权限来读取当前 Wi-Fi 名称，以判断是否在校园网环境。</string>
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>CampusVPN 需要位置权限来读取当前 Wi-Fi 名称，以判断是否在校园网环境。</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

echo "PkgInfo: APPL????" > "$CONTENTS/PkgInfo"

echo ""
echo "=== 构建完成 ==="
echo "应用路径: $APP_DIR"
echo ""
echo "运行方式:"
echo "  open \"$APP_DIR\""
echo ""
echo "安装到 /Applications:"
echo "  cp -R \"$APP_DIR\" /Applications/"
