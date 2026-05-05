#!/bin/bash
set -euo pipefail

# Usage: ./scripts/release.sh 0.2.0 2
# Args: VERSION BUILD_NUMBER

VERSION="${1:?Uso: ./scripts/release.sh <version> <build_number>}"
BUILD="${2:?Uso: ./scripts/release.sh <version> <build_number>}"
SITE_DIR="${SITE_DIR:-/Users/marcelo/dev/workspace/nexia/site_nexify}"
APP_NAME="NexifyTerm"

echo "🚀 Release ${APP_NAME} v${VERSION} (build ${BUILD})"

# 1. Update version in package.json
sed -i '' "s/\"version\": \"[^\"]*\"/\"version\": \"${VERSION}\"/" package.json

# 2. Update version in project.yml
sed -i '' "s/MARKETING_VERSION: \"[^\"]*\"/MARKETING_VERSION: \"${VERSION}\"/g" project.yml
sed -i '' "s/CURRENT_PROJECT_VERSION: \"[^\"]*\"/CURRENT_PROJECT_VERSION: \"${BUILD}\"/g" project.yml

echo "✅ Versão atualizada para ${VERSION} (${BUILD})"

# 3. Build Release
echo "🔨 Building Release..."
xcodegen generate
xcodebuild -project NexOperator.xcodeproj -scheme NexOperator \
    -configuration Release SYMROOT=$(pwd)/build \
    CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
    2>&1 | tail -5

if [ ! -d "build/Release/${APP_NAME}.app" ]; then
    echo "❌ Build failed"
    exit 1
fi
echo "✅ Build succeeded"

# 4. Sign and create DMG
echo "📦 Creating DMG..."
APP_PATH="build/Release/${APP_NAME}.app"
DMG_NAME="${APP_NAME}-v${VERSION}-macos.dmg"
ZIP_NAME="${APP_NAME}-v${VERSION}-macos.zip"
DMG_DIR="build/dmg"

xattr -cr "$APP_PATH"

# Assinatura: entitlements + hardened runtime + ordem correta (interno → externo).
# Ver scripts/deploy.sh para explicação detalhada de por que cada passo importa.
ENTITLEMENTS_FILE="NexOperator/Resources/NexOperator.entitlements"

SPARKLE_FW="$APP_PATH/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE_FW" ]; then
    for XPC in "$SPARKLE_FW/Versions/B/XPCServices/"*.xpc; do
        [ -d "$XPC" ] && codesign --force --options runtime --sign - --timestamp=none "$XPC" >/dev/null 2>&1
    done
    [ -d "$SPARKLE_FW/Versions/B/Updater.app" ] && \
        codesign --force --options runtime --sign - --timestamp=none "$SPARKLE_FW/Versions/B/Updater.app" >/dev/null 2>&1
    [ -f "$SPARKLE_FW/Versions/B/Autoupdate" ] && \
        codesign --force --options runtime --sign - --timestamp=none "$SPARKLE_FW/Versions/B/Autoupdate" >/dev/null 2>&1
    codesign --force --options runtime --sign - --timestamp=none "$SPARKLE_FW" >/dev/null 2>&1
fi

find "$APP_PATH/Contents/Frameworks" -maxdepth 1 -type d -name "*.framework" 2>/dev/null | while read -r FW; do
    [ "$FW" = "$SPARKLE_FW" ] && continue
    codesign --force --options runtime --sign - --timestamp=none "$FW" >/dev/null 2>&1 || true
done

find "$APP_PATH/Contents/PlugIns" -maxdepth 1 -type d -name "*.appex" 2>/dev/null | while read -r APPEX; do
    codesign --force --options runtime --sign - --timestamp=none "$APPEX" >/dev/null 2>&1 || true
done

codesign --force \
    --options runtime \
    --entitlements "$ENTITLEMENTS_FILE" \
    --sign - --timestamp=none \
    "$APP_PATH"

codesign --verify --strict --verbose=2 "$APP_PATH" 2>&1 | tail -3

rm -rf "$DMG_DIR" && mkdir -p "$DMG_DIR"
cp -R "$APP_PATH" "$DMG_DIR/"
rm -f "build/${DMG_NAME}"

create-dmg \
    --volname "${APP_NAME}" \
    --window-pos 200 120 --window-size 660 400 \
    --icon-size 80 --icon "${APP_NAME}.app" 180 190 \
    --hide-extension "${APP_NAME}.app" \
    --app-drop-link 480 190 --no-internet-enable \
    "build/${DMG_NAME}" "$DMG_DIR/" 2>&1 || true

rm -rf "$DMG_DIR"

# 5. Create ZIP
echo "📦 Creating ZIP..."
cd build/Release && zip -r -y "../${ZIP_NAME}" "${APP_NAME}.app" > /dev/null && cd ../..

DMG_SIZE=$(stat -f "%z" "build/${DMG_NAME}")
DMG_SIZE_MB=$(echo "scale=1; ${DMG_SIZE}/1048576" | bc)

echo "✅ DMG: build/${DMG_NAME} (${DMG_SIZE_MB} MB)"
echo "✅ ZIP: build/${ZIP_NAME}"

# 6. Copy to site
if [ -d "$SITE_DIR" ]; then
    echo "📋 Copying to site..."
    cp "build/${DMG_NAME}" "${SITE_DIR}/downloads/"
    cp "build/${ZIP_NAME}" "${SITE_DIR}/downloads/"

    # 7. Update appcast.xml
    PUB_DATE=$(date -R)
    cat > "${SITE_DIR}/downloads/appcast.xml" << APPCAST
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title>${APP_NAME} Updates</title>
        <link>https://nexify.ink/downloads/appcast.xml</link>
        <description>Atualizações do ${APP_NAME}</description>
        <language>pt-BR</language>

        <item>
            <title>${APP_NAME} v${VERSION}</title>
            <pubDate>${PUB_DATE}</pubDate>
            <sparkle:version>${BUILD}</sparkle:version>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <description><![CDATA[
                <h2>${APP_NAME} v${VERSION}</h2>
                <p>Nova versão disponível.</p>
            ]]></description>
            <enclosure
                url="https://nexify.ink/downloads/${DMG_NAME}"
                length="${DMG_SIZE}"
                type="application/octet-stream"
                sparkle:os="macos"
            />
        </item>
    </channel>
</rss>
APPCAST

    echo "✅ Appcast atualizado"
    echo ""
    echo "📌 Próximo passo: cd ${SITE_DIR} && git add -A && git commit -m 'release: v${VERSION}' && git push"
else
    echo "⚠️  Site dir não encontrado: ${SITE_DIR}"
    echo "   Copie manualmente: build/${DMG_NAME} e build/${ZIP_NAME}"
fi

echo ""
echo "🎉 Release v${VERSION} pronta!"
