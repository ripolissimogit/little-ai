#!/bin/bash
# Build LittleAI come .app bundle firmato con Developer ID.
# - Se esiste icon.png accanto a questo script, lo converte in AppIcon.icns e lo integra.
# Flags:
#   --install   Copia l'.app in /Applications dopo il build.
#   --dmg       Crea un DMG notarizzato e stapled pronto per la distribuzione.
# Notarization keychain profile: "littleai-notary" (creato una tantum con notarytool
# store-credentials).
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="debug"
INSTALL=false
MAKE_DMG=false
for arg in "$@"; do
    case "$arg" in
        release|debug) CONFIG="$arg" ;;
        --install)     INSTALL=true ;;
        --dmg)         MAKE_DMG=true; CONFIG="release" ;;
        *) echo "Unknown arg: $arg"; exit 2 ;;
    esac
done

IDENTITY="Developer ID Application: Claudio Ripoli (6T98N5PN3Y)"
BUNDLE_ID="ai.little.LittleAI"
APP_NAME="LittleAI"
DISPLAY_NAME="Little AI"
VERSION="0.6"
BUILD_NUM="1"
NOTARY_PROFILE="littleai-notary"

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
    # Also copy a smaller PNG used as the menu bar icon (40pt @2x).
    sips -z 40 40 icon.png --out "$APP_DIR/Contents/Resources/MenuIcon.png" >/dev/null
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
    <string>$DISPLAY_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUM</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Little AI legge e scrive il testo selezionato nelle altre app.</string>
    $ICON_ENTRY
</dict>
</plist>
PLIST

# Codesign with hardened runtime + timestamp (required for notarization when --dmg).
CODESIGN_FLAGS=(--force --options runtime --sign "$IDENTITY" --identifier "$BUNDLE_ID")
if $MAKE_DMG; then
    CODESIGN_FLAGS+=(--timestamp)
else
    CODESIGN_FLAGS+=(--timestamp=none)
fi
codesign "${CODESIGN_FLAGS[@]}" "$APP_DIR"

echo ""
echo "Built and signed: $APP_DIR"
codesign -dv "$APP_DIR" 2>&1 | grep -E "Identifier|TeamIdentifier"

if $INSTALL; then
    DEST="/Applications/$APP_NAME.app"
    pkill -x "$APP_NAME" 2>/dev/null || true
    sleep 1
    rm -rf "$DEST"
    cp -R "$APP_DIR" "$DEST"
    xattr -rd com.apple.quarantine "$DEST" 2>/dev/null || true
    echo "Installed to $DEST"
fi

if $MAKE_DMG; then
    DIST_DIR="dist"
    rm -rf "$DIST_DIR"
    mkdir -p "$DIST_DIR"
    DMG_STAGING="$DIST_DIR/staging"
    mkdir -p "$DMG_STAGING"
    cp -R "$APP_DIR" "$DMG_STAGING/"
    ln -s /Applications "$DMG_STAGING/Applications"

    DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"
    echo ""
    echo "Creating DMG: $DMG_PATH"
    hdiutil create -volname "$DISPLAY_NAME" \
        -srcfolder "$DMG_STAGING" \
        -ov -format UDZO \
        "$DMG_PATH" >/dev/null
    rm -rf "$DMG_STAGING"

    echo "Signing DMG..."
    codesign --force --sign "$IDENTITY" --timestamp "$DMG_PATH"

    echo "Submitting to Apple for notarization (this takes ~2-5 min)..."
    xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait

    echo "Stapling ticket..."
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"

    echo ""
    echo "✓ Ready to distribute: $DMG_PATH"
    ls -lh "$DMG_PATH"
fi
