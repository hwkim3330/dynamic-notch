#!/bin/zsh
# DynamicNotch.app 빌드 → ~/Applications 설치 → 실행
#   ./scripts/build-app.sh          빌드 + 설치 + 실행
#   ./scripts/build-app.sh --demo   실행하면서 데모 재생
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64
BIN=.build/arm64-apple-macosx/release/DynamicNotch
APP=build/DynamicNotch.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DynamicNotch"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - --timestamp=none "$APP"

DEST="$HOME/Applications/DynamicNotch.app"
mkdir -p "$HOME/Applications"
pkill -x DynamicNotch 2>/dev/null && sleep 0.8 || true
rm -rf "$DEST"
cp -R "$APP" "$DEST"
echo "설치됨: $DEST"
open "$DEST" --args "$@"
