#!/usr/bin/env bash
# Build Setlist and assemble a double-clickable .app bundle.
#   ./build.sh            release, universal (Apple Silicon + Intel)
#   ./build.sh debug      debug, this Mac's architecture only (fast)
#   ./build.sh zip        release + dist/Setlist.zip for a GitHub release
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-release}"
APP="dist/Setlist.app"

if [ "$MODE" = "debug" ]; then
  echo "==> swift build -c debug"
  swift build -c debug
  BIN=".build/debug/Setlist"
else
  echo "==> swift build -c release (arm64 + x86_64)"
  swift build -c release --arch arm64 --arch x86_64
  BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Setlist"
fi

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Setlist"
cp Info.plist "$APP/Contents/Info.plist"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc sign so Gatekeeper is happy locally.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

if [ "$MODE" = "zip" ]; then
  rm -f dist/Setlist.zip
  ditto -c -k --sequesterRsrc --keepParent "$APP" dist/Setlist.zip
  echo "==> zipped: dist/Setlist.zip"
fi

echo "==> built: $APP"
echo "    run with:  open \"$APP\""
