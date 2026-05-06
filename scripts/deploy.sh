#!/bin/bash
set -euo pipefail

###############################################################################
# NexifyTerm Deploy Pipeline
#
# Builds DMG, signs with Sparkle, updates appcast, syncs to site, deploys S3.
#
# Usage:
#   ./scripts/deploy.sh              # auto-bump patch (0.1.1 -> 0.1.2)
#   ./scripts/deploy.sh 0.2.0        # explicit version
#   ./scripts/deploy.sh 0.2.0 3      # explicit version + build number
###############################################################################

APP_NAME="NexifyTerm"
SITE_DIR="${SITE_DIR:-/Users/marcelo/dev/workspace/nexia/site_nexify}"
SIGN_UPDATE=$(find ~/Library/Developer/Xcode/DerivedData/NexOperator-*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update -type f 2>/dev/null | head -1)
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"

# ── Version resolution ──────────────────────────────────────────────────────

CURRENT_VERSION=$(grep '"version"' package.json | head -1 | sed 's/.*"version": *"\([^"]*\)".*/\1/')
CURRENT_BUILD=$(grep 'CURRENT_PROJECT_VERSION' project.yml | head -1 | sed 's/.*"\([^"]*\)".*/\1/')

if [ -n "${1:-}" ]; then
    VERSION="$1"
else
    IFS='.' read -r major minor patch <<< "$CURRENT_VERSION"
    patch=$((patch + 1))
    VERSION="${major}.${minor}.${patch}"
fi

BUILD="${2:-$((CURRENT_BUILD + 1))}"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  🚀 Deploy ${APP_NAME} v${VERSION} (build ${BUILD})"
echo "║  📦 Current: v${CURRENT_VERSION} (build ${CURRENT_BUILD})"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# ── Pre-flight checks ───────────────────────────────────────────────────────

echo "🔍 Pre-flight checks..."

if ! command -v xcodegen &>/dev/null; then
    echo "❌ xcodegen not found. Run: brew install xcodegen"
    exit 1
fi

if ! command -v create-dmg &>/dev/null; then
    echo "❌ create-dmg not found. Run: brew install create-dmg"
    exit 1
fi

if [ ! -d "$SITE_DIR" ]; then
    echo "❌ Site directory not found: $SITE_DIR"
    exit 1
fi

if [ -z "$SIGN_UPDATE" ] || [ ! -f "$SIGN_UPDATE" ]; then
    echo "⚠️  Sparkle sign_update not found. Build the Xcode project first."
    echo "   DMG will be created without EdDSA signature."
    SIGN_UPDATE=""
fi

aws sts get-caller-identity --query 'Account' --output text &>/dev/null || {
    echo "❌ AWS credentials not configured. Run: aws configure"
    exit 1
}

echo "✅ All checks passed"
echo ""

# ── Step 1: Update versions ─────────────────────────────────────────────────

echo "📝 Step 1/7: Updating version to ${VERSION} (build ${BUILD})..."

sed -i '' "s/\"version\": \"[^\"]*\"/\"version\": \"${VERSION}\"/" package.json
sed -i '' "s/MARKETING_VERSION: \"[^\"]*\"/MARKETING_VERSION: \"${VERSION}\"/g" project.yml
sed -i '' "s/CURRENT_PROJECT_VERSION: \"[^\"]*\"/CURRENT_PROJECT_VERSION: \"${BUILD}\"/g" project.yml

echo "✅ Versions updated"

# ── Step 2: Build Release ───────────────────────────────────────────────────

echo ""
echo "🔨 Step 2/7: Building Release..."

xcodegen generate 2>&1 | tail -1
xcodebuild -project NexOperator.xcodeproj -scheme NexOperator \
    -configuration Release SYMROOT=$(pwd)/build \
    CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
    2>&1 | tail -5

APP_PATH="build/Release/${APP_NAME}.app"
if [ ! -d "$APP_PATH" ]; then
    echo "❌ Build failed — ${APP_PATH} not found"
    exit 1
fi
echo "✅ Build succeeded"

# ── Step 2b: Clean stale copies ──────────────────────────────────────────────

echo ""
echo "🧹 Cleaning stale app copies to prevent macOS opening old versions..."

STALE_LOCATIONS=(
    "$HOME/Downloads/09_Apps/${APP_NAME}.app"
    "$HOME/Library/Developer/Xcode/DerivedData/NexOperator-*/Build/Products/Debug/${APP_NAME}.app"
    "$(pwd)/build/Debug/${APP_NAME}.app"
)

for pattern in "${STALE_LOCATIONS[@]}"; do
    for stale in $pattern; do
        if [ -d "$stale" ]; then
            stale_ver=$(defaults read "$stale/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "?")
            if [ "$stale_ver" != "$VERSION" ]; then
                rm -rf "$stale"
                echo "   Removed $stale (v${stale_ver})"
            fi
        fi
    done
done

if [ -d "/Applications/${APP_NAME}.app" ]; then
    installed_ver=$(defaults read "/Applications/${APP_NAME}.app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "?")
    if [ "$installed_ver" != "$VERSION" ]; then
        echo "   /Applications/${APP_NAME}.app is v${installed_ver} — will be replaced by DMG install"
    fi
fi

if [ -f "$LSREGISTER" ]; then
    "$LSREGISTER" -f -R -trusted "$APP_PATH" 2>/dev/null
    echo "✅ Launch Services updated to prefer build/Release"
fi

# ── Step 3: Sign app and create DMG + ZIP ────────────────────────────────────

echo ""
echo "📦 Step 3/7: Creating DMG and ZIP..."

DMG_NAME="${APP_NAME}-v${VERSION}-macos.dmg"
ZIP_NAME="${APP_NAME}-v${VERSION}-macos.zip"
DMG_DIR="build/dmg"

xattr -cr "$APP_PATH"

# IMPORTANTE: assinatura é feita UMA ÚNICA VEZ aqui, com entitlements + hardened
# runtime. O app instalado em /Applications no passo 8 será apenas COPIADO,
# sem re-codesign — assim o cdhash em /Applications é idêntico ao do DMG e o
# TCC mantém as permissões (Microfone / Screen Recording / etc.) válidas
# entre releases. Re-assinar em /Applications muda o cdhash e invalida tudo.
ENTITLEMENTS_FILE="NexOperator/Resources/NexOperator.entitlements"

if [ ! -f "$ENTITLEMENTS_FILE" ]; then
    echo "❌ Entitlements file não encontrado: $ENTITLEMENTS_FILE"
    exit 1
fi

# Assina do MAIS INTERNO para o MAIS EXTERNO, sem --deep (deprecated e bugado
# no macOS 14+). Cada bundle aninhado precisa de codesign individual.
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

# Demais frameworks (caso existam no futuro).
find "$APP_PATH/Contents/Frameworks" -maxdepth 1 -type d -name "*.framework" 2>/dev/null | while read -r FW; do
    [ "$FW" = "$SPARKLE_FW" ] && continue
    codesign --force --options runtime --sign - --timestamp=none "$FW" >/dev/null 2>&1 || true
done

# App extensions (.appex) — cada uma precisa de assinatura individual.
find "$APP_PATH/Contents/PlugIns" -maxdepth 1 -type d -name "*.appex" 2>/dev/null | while read -r APPEX; do
    codesign --force --options runtime --sign - --timestamp=none "$APPEX" >/dev/null 2>&1 || true
done

# Por último, app principal COM entitlements (sem --deep). Os entitlements
# disable-library-validation + allow-dyld-environment-variables são
# obrigatórios em ad-hoc para que dyld carregue frameworks externos no macOS
# 14+ (Library Validation rejeita Team IDs ausentes/incompatíveis sem isso).
codesign --force \
    --options runtime \
    --entitlements "$ENTITLEMENTS_FILE" \
    --sign - --timestamp=none \
    "$APP_PATH"

if ! codesign --verify --strict --verbose=2 "$APP_PATH" >/dev/null 2>&1; then
    echo "❌ Falha ao verificar assinatura do app"
    codesign --verify --strict --verbose=2 "$APP_PATH" 2>&1 | tail -10
    exit 1
fi

# Confirma que entitlements críticos foram realmente embedded.
EMBEDDED=$(codesign -d --entitlements - "$APP_PATH" 2>&1)
for KEY in "audio-input" "disable-library-validation"; do
    if ! echo "$EMBEDDED" | grep -q "$KEY"; then
        echo "❌ Entitlement '$KEY' não foi embedded no binário"
        exit 1
    fi
done

# Smoke test: app realmente abre? (detecta crashes de dyld antes do release sair).
# IMPORTANTE: usamos `open -a` em vez de executar o binário direto porque rodar
# `Contents/MacOS/<App>` fora do LaunchServices não inicializa NSApplication
# corretamente — o app sai imediatamente sem janela mesmo estando saudável,
# o que dava falso positivo de "crash" no script.
# Cuidado: `set -e` global derrubaria o script em qualquer pkill/pgrep que
# retornasse 1 (no processes matched), por isso encapsulamos TUDO em set +e.
set +e
pkill -x "$APP_NAME" >/dev/null 2>&1
sleep 0.5
open -a "$(cd "$(dirname "$APP_PATH")" && pwd)/$(basename "$APP_PATH")" >/tmp/${APP_NAME}-smoke.log 2>&1
OPEN_EC=$?
sleep 3
if [ "$OPEN_EC" = "0" ] && pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    SMOKE_OK=1
else
    SMOKE_OK=0
fi
pkill -x "$APP_NAME" >/dev/null 2>&1
sleep 0.5
set -e

if [ "$SMOKE_OK" = "1" ]; then
    echo "✅ Assinado, entitlements OK, smoke test passou"
else
    echo "❌ App crashou no smoke test:"
    tail -10 /tmp/${APP_NAME}-smoke.log
    exit 1
fi

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

cd build/Release && zip -r -y "../${ZIP_NAME}" "${APP_NAME}.app" > /dev/null && cd ../..

DMG_PATH="build/${DMG_NAME}"
ZIP_PATH="build/${ZIP_NAME}"

if [ ! -f "$DMG_PATH" ]; then
    echo "❌ DMG creation failed"
    exit 1
fi

DMG_SIZE=$(stat -f "%z" "$DMG_PATH")
DMG_SIZE_MB=$(echo "scale=1; ${DMG_SIZE}/1048576" | bc)
echo "✅ DMG: ${DMG_NAME} (${DMG_SIZE_MB} MB)"
echo "✅ ZIP: ${ZIP_NAME}"

# ── Step 4: Sparkle EdDSA signature ─────────────────────────────────────────

echo ""
echo "🔐 Step 4/7: Signing with Sparkle EdDSA..."

ED_SIGNATURE=""
if [ -n "$SIGN_UPDATE" ]; then
    SIGN_OUTPUT=$("$SIGN_UPDATE" "$DMG_PATH" 2>&1) || true
    ED_SIGNATURE=$(echo "$SIGN_OUTPUT" | grep 'sparkle:edSignature=' | sed 's/.*sparkle:edSignature="\([^"]*\)".*/\1/')

    if [ -n "$ED_SIGNATURE" ]; then
        echo "✅ EdDSA signature generated"
    else
        echo "⚠️  Could not extract signature. Output: ${SIGN_OUTPUT}"
        echo "   Continuing without signature..."
    fi
else
    echo "⚠️  Skipping signature (sign_update not available)"
fi

# ── Step 5: Copy to site and update appcast.xml ─────────────────────────────

echo ""
echo "📋 Step 5/7: Updating site..."

mkdir -p "${SITE_DIR}/downloads"
cp "$DMG_PATH" "${SITE_DIR}/downloads/"
cp "$ZIP_PATH" "${SITE_DIR}/downloads/"

PUB_DATE=$(date -R)

if [ -n "$ED_SIGNATURE" ]; then
    ENCLOSURE_ATTRS="url=\"https://nexify.ink/downloads/${DMG_NAME}\"
                length=\"${DMG_SIZE}\"
                type=\"application/octet-stream\"
                sparkle:edSignature=\"${ED_SIGNATURE}\"
                sparkle:os=\"macos\""
else
    ENCLOSURE_ATTRS="url=\"https://nexify.ink/downloads/${DMG_NAME}\"
                length=\"${DMG_SIZE}\"
                type=\"application/octet-stream\"
                sparkle:os=\"macos\""
fi

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
                ${ENCLOSURE_ATTRS}
            />
        </item>
    </channel>
</rss>
APPCAST

echo "✅ appcast.xml updated"
echo "✅ DMG + ZIP copied to site/downloads"

# ── Step 6: Commit and push site repo ────────────────────────────────────────

echo ""
echo "📤 Step 6/7: Committing site changes..."

cd "$SITE_DIR"
git add -A
git commit -m "release: ${APP_NAME} v${VERSION} (build ${BUILD})" 2>/dev/null || echo "   (no changes to commit)"
git push 2>/dev/null || echo "⚠️  git push failed — push manually"
cd -

echo "✅ Site repo updated"

# ── Step 7: Deploy to S3 ────────────────────────────────────────────────────

echo ""
echo "☁️  Step 7/7: Deploying to S3..."

cd "$SITE_DIR"
npm run deploy
cd -

# ── Step 8: Install locally ──────────────────────────────────────────────────

echo ""
echo "💻 Step 8: Installing locally..."

# Em zsh com `set -e`, a forma `cmd && sleep || true` ainda pode abortar o
# script porque o `&&` bloqueia o efeito do `||`. Encapsulamos tudo em set +e
# pra garantir que pkill (que retorna 1 quando não há processo) nunca derrube
# o deploy.
set +e
pkill -x "${APP_NAME}" >/dev/null 2>&1
sleep 1
pkill -f "${APP_NAME}.app/Contents/Frameworks/Sparkle" >/dev/null 2>&1
set -e

# CRÍTICO: copiamos o app já assinado, SEM re-rodar codesign. Re-assinar aqui
# mudaria o cdhash e o macOS trataria como "outro app" → as permissões
# concedidas (Microfone, Screen Recording) seriam descartadas a cada deploy.
rm -rf "/Applications/${APP_NAME}.app"
cp -R "$APP_PATH" "/Applications/${APP_NAME}.app"

# NÃO rodar `xattr -cr` aqui também — isso pode invalidar a assinatura.
# O app copiado mantém o cdhash idêntico ao do DMG.

# Limpeza do LaunchServices: remove TODOS os registros stale do bundle
# (DMGs antigos em /Volumes, builds Debug em /private/tmp, .Trash, etc.).
# Sem isso, o macOS acumula dezenas de paths para o mesmo bundle id e o
# Finder/Dock/Launchpad mostram a versão errada ou não atualizam após install.
BUNDLE_ID="com.nexia.nexifyterm"
if [ -f "$LSREGISTER" ]; then
    # Desmonta DMGs antigos do app que ainda estejam montados.
    mount | awk '/\/Volumes\/(NexifyTerm|dmg\.)/ {print $3}' | while read -r MNT; do
        hdiutil detach "$MNT" -force >/dev/null 2>&1 || true
    done

    # Unregister cada path que NÃO seja /Applications/${APP_NAME}.app.
    # IMPORTANTE: `set -euo pipefail` faz o script abortar se `grep` não
    # encontrar matches (exit 1) — desativamos pipefail só pra esse pipeline.
    set +o pipefail
    "$LSREGISTER" -dump 2>/dev/null \
      | awk '/^----/{block=""} {block=block"\n"$0} /'"$BUNDLE_ID"'/ {print block; block=""}' \
      | grep -E "^path:" | awk '{print $2}' | sort -u | while IFS= read -r STALE; do
        [ -z "$STALE" ] && continue
        [ "$STALE" = "/Applications/${APP_NAME}.app" ] && continue
        "$LSREGISTER" -u "$STALE" >/dev/null 2>&1 || true
    done
    set -o pipefail

    # Limpa caches do Sparkle (Updater.app extraído de versões anteriores).
    rm -rf "$HOME/Library/Caches/${BUNDLE_ID}/org.sparkle-project.Sparkle/Launcher" 2>/dev/null
    rm -rf "$HOME/Library/Caches/${BUNDLE_ID}/org.sparkle-project.Sparkle/PersistentDownloads" 2>/dev/null

    # Remove cópias na Lixeira e diretório dmg local sobrando.
    rm -rf "$HOME/.Trash/${APP_NAME}.app" 2>/dev/null || true
    rm -rf "$(pwd)/build/dmg" 2>/dev/null || true

    # Re-registra o app instalado como autoritativo.
    "$LSREGISTER" -f -R -trusted "/Applications/${APP_NAME}.app" >/dev/null 2>&1

    # Força refresh da UI para Finder/Dock/Launchpad pegarem o novo registro.
    killall Dock 2>/dev/null || true
    killall Finder 2>/dev/null || true
fi

INSTALLED_CDHASH=$(codesign -dv "/Applications/${APP_NAME}.app" 2>&1 | grep CDHash | head -1 | awk '{print $2}')
SOURCE_CDHASH=$(codesign -dv "$APP_PATH" 2>&1 | grep CDHash | head -1 | awk '{print $2}')

if [ "$INSTALLED_CDHASH" = "$SOURCE_CDHASH" ] && [ -n "$INSTALLED_CDHASH" ]; then
    echo "✅ /Applications/${APP_NAME}.app updated to v${VERSION} (cdhash preservado: ${INSTALLED_CDHASH:0:12}…)"
    echo "✅ Permissões TCC (Microfone, Screen Recording) preservadas entre releases"
else
    echo "⚠️  cdhash divergente entre source e /Applications — TCC pode pedir permissão novamente"
    echo "   source:    $SOURCE_CDHASH"
    echo "   installed: $INSTALLED_CDHASH"
fi

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  🎉 Deploy complete: ${APP_NAME} v${VERSION}            "
echo "║                                                          "
echo "║  📦 DMG: https://nexify.ink/downloads/${DMG_NAME}       "
echo "║  📡 Appcast: https://nexify.ink/downloads/appcast.xml   "
echo "║  💻 Local: /Applications/${APP_NAME}.app (v${VERSION})  "
echo "║                                                          "
echo "║  ✅ Existing users: will receive update via Sparkle      "
echo "║  ✅ New users: can download latest DMG from site         "
echo "║  ✅ Local install: updated automatically                 "
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
