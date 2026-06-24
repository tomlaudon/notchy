#!/usr/bin/env bash
# Rebuild Notchy and refresh Build/Notchy.app (the artifact tracked in git).
# Used both manually and by .git/hooks/pre-push.
set -euo pipefail

cd "$(dirname "$0")"

BUILD_DIR="/tmp/notchy-build"

echo "==> Building Notchy (Release)..."
xcodebuild \
  -project Notchy.xcodeproj \
  -scheme Notchy \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  build > /tmp/notchy-build.log 2>&1 || {
    echo "Build failed. Last 30 lines of log:"
    tail -30 /tmp/notchy-build.log
    exit 1
  }

echo "==> Refreshing Build/Notchy.app..."
rm -rf Build/Notchy.app
cp -R "$BUILD_DIR/Build/Products/Release/Notchy.app" Build/Notchy.app

# Re-sign with a stable identity so macOS TCC permissions (notably the
# microphone grant Claude Code voice needs) survive rebuilds. xcodebuild
# ad-hoc signs (CODE_SIGN_IDENTITY="-"), whose designated requirement is the
# cdhash — that changes every build and resets the grant. Signing with the
# Apple Development cert gives a cert+bundle-id designated requirement that is
# stable across rebuilds. If the identity isn't present, fall back to the
# ad-hoc build rather than fail.
SIGN_ID="3BAC109D425D0C26DF838FB4210544C572D809F5"  # Apple Development: tomlaudon@gmail.com
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
  echo "==> Re-signing with stable Apple Development identity..."
  codesign --force --deep --options runtime \
    --entitlements Notchy/Notchy.entitlements \
    --sign "$SIGN_ID" Build/Notchy.app
  codesign --verify --deep --strict Build/Notchy.app && echo "==> Signature OK."
else
  echo "==> WARNING: stable signing identity $SIGN_ID not found; leaving ad-hoc signature (mic grant will reset on rebuild)."
fi

echo "==> Done. Build/Notchy.app is fresh."
