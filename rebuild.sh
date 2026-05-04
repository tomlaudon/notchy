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

echo "==> Done. Build/Notchy.app is fresh."
