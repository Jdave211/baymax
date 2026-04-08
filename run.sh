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

# Post-build script copies to ~/Applications automatically.
# If for any reason it didn't, do it manually here.
if [ -d "$DERIVED_APP" ] && [ ! -d "$STABLE_APP" ]; then
  echo "Copying to ~/Applications..."
  mkdir -p "$HOME/Applications"
  cp -R "$DERIVED_APP" "$STABLE_APP"
  codesign --force --deep --sign - "$STABLE_APP" 2>/dev/null || true
fi

echo "Killing any running Baymax..."
pkill -f "Baymax.app/Contents/MacOS/Baymax" 2>/dev/null || true
sleep 0.5

echo "Launching from $STABLE_APP"
open "$STABLE_APP"
echo "Done."
