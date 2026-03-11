#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/release"
APP_DIR="$ROOT_DIR/dist/voice.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICON_SOURCE="$ROOT_DIR/assets/logo.png"
ICONSET_DIR="$ROOT_DIR/.build/AppIcon.iconset"
ICON_OUTPUT="$RESOURCES_DIR/AppIcon.icns"

APP_VERSION="$(cat "$ROOT_DIR/VERSION" 2>/dev/null || echo "0.0.0")"
APP_VERSION="$(echo "$APP_VERSION" | tr -d '[:space:]')"
APP_BUILD="$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || echo "1")"

echo "Building release binary..."
swift build -c release

echo "Creating app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BUILD_DIR/voice" "$MACOS_DIR/voice"
chmod +x "$MACOS_DIR/voice"

ICON_PLIST_ENTRY=""
if [ -f "$ICON_SOURCE" ]; then
    echo "Generating app icon from assets/logo.png..."
    rm -rf "$ICONSET_DIR"
    mkdir -p "$ICONSET_DIR"

    sips -z 16 16 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
    sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
    sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
    sips -z 64 64 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
    sips -z 128 128 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
    sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
    sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
    sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
    sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
    cp "$ICON_SOURCE" "$ICONSET_DIR/icon_512x512@2x.png"

    iconutil -c icns "$ICONSET_DIR" -o "$ICON_OUTPUT"
    rm -rf "$ICONSET_DIR"
    ICON_PLIST_ENTRY=$'    <key>CFBundleIconFile</key>\n    <string>AppIcon</string>'
else
    echo "Warning: assets/logo.png not found; using default app icon."
fi

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>voice</string>
    <key>CFBundleDisplayName</key>
    <string>voice</string>
    <key>CFBundleExecutable</key>
    <string>voice</string>
    <key>CFBundleIdentifier</key>
    <string>ai.gokul.voice</string>
    <key>CFBundleVersion</key>
    <string>${APP_BUILD}</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
${ICON_PLIST_ENTRY}
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSAccessibilityUsageDescription</key>
    <string>voice needs Accessibility access to paste and type dictated text into other applications.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>voice needs speech recognition to transcribe dictation.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>voice needs microphone access to capture dictation audio.</string>
</dict>
</plist>
PLIST

echo "Applying stable code signature to prevent TCC permission loop..."

# Try to find a valid Apple Development certificate
DEV_CERT=$(security find-identity -v -p codesigning | grep "Apple Development" | head -n 1 | awk -F'"' '{print $2}' || true)

if [ -n "$DEV_CERT" ]; then
    echo "Found Developer Certificate: $DEV_CERT"
    codesign --force --deep --sign "$DEV_CERT" "$APP_DIR"
else
    echo "No Developer Certificate found. Falling back to persistent ad-hoc signing..."
    # Without a cert, a plain ad-hoc signature defaults to a cdhash requirement
    # and causes TCC to treat rebuilt apps as a new identity every time.
    codesign --force --deep -s - -i "ai.gokul.voice" -r='designated => identifier "ai.gokul.voice"' "$APP_DIR"
fi

echo "Done: $APP_DIR"
