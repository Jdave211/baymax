#!/bin/bash
# Build Baymax and launch from ~/Applications so macOS TCC permissions persist.

set -e

DERIVED_APP="$HOME/Library/Developer/Xcode/DerivedData/Baymax-cvzqngrjfhdfoobmfaggapgputgp/Build/Products/Debug/Baymax.app"
STABLE_APP="$HOME/Applications/Baymax.app"

echo "Building Baymax..."
cd "$(dirname "$0")"
xcodebuild -project Baymax.xcodeproj -scheme Baymax -configuration Debug build 2>&1 \
  | grep -E "(error:|warning:|BUILD |Copying|Install)" \
  | grep -v "warning: Run script" \
  || true

# Stage env vars into Application Support so the app never needs to read from the Desktop workspace.
APP_SUPPORT_ENV="$HOME/Library/Application Support/Baymax/.env"
if [ -f ".env" ]; then
  mkdir -p "$(dirname "$APP_SUPPORT_ENV")"
  cp ".env" "$APP_SUPPORT_ENV"
fi

# Post-build script copies to ~/Applications automatically.
# Keep a fallback here and self-heal unsigned installs.
if [ -d "$DERIVED_APP" ]; then
  NEED_REINSTALL=0
  if [ ! -d "$STABLE_APP" ]; then
    NEED_REINSTALL=1
  elif ! codesign --verify --deep --strict "$STABLE_APP" >/dev/null 2>&1; then
    echo "Installed app signature invalid or missing — reinstalling..."
    NEED_REINSTALL=1
  fi

  if [ "$NEED_REINSTALL" -eq 1 ]; then
    echo "Copying to ~/Applications..."
    mkdir -p "$HOME/Applications"
    rm -rf "$STABLE_APP"
    ditto "$DERIVED_APP" "$STABLE_APP"
    DEV_ID="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*\"\\(Apple Development:.*\\)\"/\\1/p' | head -n 1)"
    if [ -n "$DEV_ID" ]; then
      codesign --force --deep --sign "$DEV_ID" "$STABLE_APP"
    else
      codesign --force --deep --sign - "$STABLE_APP"
    fi
    codesign --verify --deep --strict "$STABLE_APP"
  fi
fi

echo "Killing any running Baymax..."
pkill -f "Baymax.app/Contents/MacOS/Baymax" 2>/dev/null || true
sleep 0.5

echo "Launching from $STABLE_APP"
open "$STABLE_APP"
echo "Done."
