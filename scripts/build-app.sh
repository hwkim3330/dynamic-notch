#!/bin/zsh
# DynamicNotch.app 빌드 → ~/Applications 설치 → 실행
#   ./scripts/build-app.sh          빌드 + 설치 + 실행
#   ./scripts/build-app.sh --demo   실행하면서 데모 재생
set -euo pipefail
cd "$(dirname "$0")/.."

# Apple Silicon + Intel 유니버설
swift build -c release --arch arm64 --arch x86_64
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/DynamicNotch
APP=build/DynamicNotch.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DynamicNotch"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# 고정 서명. 임시 서명(-)은 빌드마다 서명이 바뀌어 macOS 가 다른 앱으로 보고
# 손쉬운 사용 권한이 매번 풀렸다. 키체인에 'DynamicNotch Local Signing' 이 있으면 그걸 쓴다.
SIGN_ID="DynamicNotch Local Signing"
if security find-identity -p codesigning | grep -q "$SIGN_ID"; then
  codesign --force --sign "$SIGN_ID" --timestamp=none "$APP"
else
  codesign --force --sign - --timestamp=none "$APP"
fi

DEST="$HOME/Applications/DynamicNotch.app"
mkdir -p "$HOME/Applications"
pkill -x DynamicNotch 2>/dev/null && sleep 0.8 || true
rm -rf "$DEST"
cp -R "$APP" "$DEST"
echo "설치됨: $DEST"
open "$DEST" --args "$@"
