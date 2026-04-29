#!/bin/bash
set -euo pipefail

APP_NAME="NexifyTerm"
APP_PATH="build/Debug/${APP_NAME}.app"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WATCH_DIR="$PROJECT_DIR/NexOperator"
DEBOUNCE_SEC=2
LAST_BUILD=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

cleanup() {
    echo ""
    echo -e "${YELLOW}⏹  Stopping dev mode...${RESET}"
    kill_app
    [ -n "${FSWATCH_PID:-}" ] && kill "$FSWATCH_PID" 2>/dev/null
    exit 0
}
trap cleanup SIGINT SIGTERM

kill_app() {
    pkill -f "$APP_PATH/Contents/MacOS/$APP_NAME" 2>/dev/null || true
}

launch_app() {
    echo -e "${CYAN}🚀 Launching ${APP_NAME}...${RESET}"
    open "$APP_PATH" &
}

build_app() {
    local start_time
    start_time=$(date +%s)

    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${CYAN}🔨 Building... $(date '+%H:%M:%S')${RESET}"

    xcodegen generate 2>/dev/null

    local build_output
    build_output=$(xcodebuild \
        -project NexOperator.xcodeproj \
        -scheme NexOperator \
        -configuration Debug \
        SYMROOT="$PROJECT_DIR/build" \
        CODE_SIGN_IDENTITY="" \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=NO \
        -jobs "$(sysctl -n hw.ncpu)" \
        2>&1)

    local exit_code=$?
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    if [ $exit_code -eq 0 ]; then
        echo -e "${GREEN}✅ Build OK${RESET} (${duration}s)"
        LAST_BUILD=$(date +%s)
        return 0
    else
        echo -e "${RED}❌ Build FAILED${RESET} (${duration}s)"
        echo "$build_output" | grep -E "error:|warning:" | tail -15
        echo -e "${YELLOW}⏳ Waiting for changes to retry...${RESET}"
        return 1
    fi
}

rebuild_and_relaunch() {
    local now
    now=$(date +%s)
    if (( now - LAST_BUILD < DEBOUNCE_SEC )); then
        return
    fi

    kill_app
    sleep 0.3

    if build_app; then
        launch_app
    fi
}

echo -e "${BOLD}"
echo "  ┌─────────────────────────────────────────┐"
echo "  │     NexOperator — Dev Mode (watch)       │"
echo "  │                                          │"
echo "  │  Watching: NexOperator/**/*.swift         │"
echo "  │  Auto-rebuild + relaunch on save         │"
echo "  │  Press Ctrl+C to stop                    │"
echo "  └─────────────────────────────────────────┘"
echo -e "${RESET}"

echo -e "${CYAN}📦 Initial build...${RESET}"
if build_app; then
    kill_app
    sleep 0.3
    launch_app
else
    echo -e "${YELLOW}⚠️  Initial build failed. Fix errors and save to retry.${RESET}"
fi

if command -v fswatch &>/dev/null; then
    echo -e "${GREEN}👁  Using fswatch for file watching${RESET}"
    fswatch -o \
        --event Created --event Updated --event Removed \
        -e ".*\.DS_Store" \
        -e ".*build/" \
        -e ".*\.xcodeproj/" \
        --include="\.swift$" \
        --include="\.plist$" \
        --include="\.xcassets" \
        --include="\.storyboard$" \
        --include="project\.yml$" \
        "$WATCH_DIR" "$PROJECT_DIR/project.yml" | while read -r _count; do
        echo -e "${YELLOW}📝 Change detected${RESET}"
        rebuild_and_relaunch
    done
else
    echo -e "${YELLOW}👁  Using polling (install fswatch for better perf: brew install fswatch)${RESET}"
    CHECKSUM=""
    while true; do
        NEW_CHECKSUM=$(find "$WATCH_DIR" "$PROJECT_DIR/project.yml" \
            -name "*.swift" -o -name "*.plist" -o -name "project.yml" \
            2>/dev/null | sort | xargs stat -f "%m %N" 2>/dev/null | md5)

        if [ "$NEW_CHECKSUM" != "$CHECKSUM" ] && [ -n "$CHECKSUM" ]; then
            echo -e "${YELLOW}📝 Change detected${RESET}"
            rebuild_and_relaunch
        fi
        CHECKSUM="$NEW_CHECKSUM"
        sleep 2
    done
fi
