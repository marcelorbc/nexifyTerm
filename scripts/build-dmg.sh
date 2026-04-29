#!/bin/bash
set -euo pipefail

APP_NAME="NexifyTerm"
APP_PATH="build/Release/${APP_NAME}.app"
VERSION=$(grep '"version"' package.json | head -1 | sed 's/.*"version": *"\([^"]*\)".*/\1/')
DMG_NAME="${APP_NAME}-v${VERSION}-macos.dmg"
DMG_DIR="build/dmg"
DMG_OUTPUT="build/${DMG_NAME}"

if [ ! -d "$APP_PATH" ]; then
    echo "❌ $APP_PATH not found. Run 'npm run build:release' first."
    exit 1
fi

echo "📦 Building DMG for ${APP_NAME} v${VERSION}..."

rm -rf "$DMG_DIR"
mkdir -p "$DMG_DIR"

xattr -cr "$APP_PATH"
codesign --force --deep --sign - "$APP_PATH"

cp -R "$APP_PATH" "$DMG_DIR/"

rm -f "$DMG_OUTPUT"

create-dmg \
    --volname "${APP_NAME}" \
    --volicon "${APP_PATH}/Contents/Resources/AppIcon.svg" \
    --window-pos 200 120 \
    --window-size 660 400 \
    --icon-size 80 \
    --icon "${APP_NAME}.app" 180 190 \
    --hide-extension "${APP_NAME}.app" \
    --app-drop-link 480 190 \
    --no-internet-enable \
    "$DMG_OUTPUT" \
    "$DMG_DIR/" \
    2>&1 || true

if [ -f "$DMG_OUTPUT" ]; then
    SIZE=$(du -sh "$DMG_OUTPUT" | cut -f1)
    echo ""
    echo "✅ DMG created: $DMG_OUTPUT ($SIZE)"
    echo "   Version: $VERSION"
    echo "   Ready to distribute."
else
    echo "❌ DMG creation failed."
    exit 1
fi

rm -rf "$DMG_DIR"
