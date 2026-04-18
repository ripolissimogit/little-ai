#!/bin/bash
# Build LittleAI come .app bundle firmato con Developer ID.
# - Se esiste icon.png (1024x1024) accanto a questo script, lo converte in AppIcon.icns
#   e lo integra nel bundle.
# - Con il flag --install copia l'.app in /Applications.
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-debug}"
INSTALL=false
if [[ "${2:-}" == "--install" || "${1:-}" == "--install" ]]; then
    INSTALL=true
    [[ "$CONFIG" == "--install" ]] && CONFIG="debug"
fi

IDENTITY="Developer ID Application: Claudio Ripoli (6T98N5PN3Y)"
BUNDLE_ID="ai.little.LittleAI"
APP_NAME="LittleAI"
VERSION="0.2"
BUILD_NUM="1"

swift build -c "$CONFIG"

BIN_DIR=".build/$([ "$CONFIG" = "release" ] && echo "release" || echo "debug")"
BIN="$BIN_DIR/$APP_NAME"
APP_DIR="$BIN_DIR/$APP_NAME.app"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN" "$APP_DIR/Contents/MacOS/$APP_NAME"

# Build icon.icns from icon.png if present.
ICON_ENTRY=""
if [[ -f "icon.png" ]]; then
    ICONSET="$BIN_DIR/AppIcon.iconset"
    rm -rf "$ICONSET"
    mkdir -p "$ICONSET"
    for SIZE in 16 32 64 128 256 512; do
        sips -z $SIZE $SIZE icon.png --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
        DOUBLE=$((SIZE * 2))
        sips -z $DOUBLE $DOUBLE icon.png --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
    done
    sips -z 1024 1024 icon.png --out "$ICONSET/icon_512x512@2x.png" >/dev/null
    iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
    rm -rf "$ICONSET"
    ICON_ENTRY="<key>CFBundleIconFile</key><string>AppIcon</string>"
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>Little AI</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUM</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Little AI legge e scrive il testo selezionato nelle altre app.</string>
    $ICON_ENTRY
</dict>
</plist>
PLIST

codesign --force --options runtime \
    --sign "$IDENTITY" \
    --identifier "$BUNDLE_ID" \
    --timestamp=none \
    "$APP_DIR"

echo ""
echo "Built and signed: $APP_DIR"
codesign -dv "$APP_DIR" 2>&1 | grep -E "Identifier|TeamIdentifier"

if $INSTALL; then
    DEST="/Applications/$APP_NAME.app"
    # Quit any running instance so rm/cp can succeed.
    pkill -x "$APP_NAME" 2>/dev/null || true
    sleep 1
    rm -rf "$DEST"
    cp -R "$APP_DIR" "$DEST"
    # Clear Gatekeeper quarantine if present.
    xattr -rd com.apple.quarantine "$DEST" 2>/dev/null || true
    echo "Installed to $DEST"
fi
