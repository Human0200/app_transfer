#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
BUILD_DIR="$ROOT/.build/release"
APP_DIR="$ROOT/dist/App Transfer.app"
ICONSET_DIR="$ROOT/.build/AppIcon.iconset"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

swift build -c release
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BUILD_DIR/AppTransfer" "$APP_DIR/Contents/MacOS/AppTransfer"

rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"
swift "$ROOT/Scripts/make-icon.swift" "$ICONSET_DIR"
iconutil -c icns "$ICONSET_DIR" -o "$APP_DIR/Contents/Resources/AppIcon.icns"

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>App Transfer</string>
    <key>CFBundleExecutable</key>
    <string>AppTransfer</string>
    <key>CFBundleIdentifier</key>
    <string>com.human0200.app-transfer</string>
    <key>CFBundleName</key>
    <string>App Transfer</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.2.0</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
</dict>
</plist>
PLIST

chmod +x "$APP_DIR/Contents/MacOS/AppTransfer"
codesign --force --deep --sign "$CODESIGN_IDENTITY" --timestamp=none "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"
echo "Built: $APP_DIR"
