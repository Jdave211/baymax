#!/bin/bash

set -euo pipefail

DEST="$HOME/Applications/Baymax.app"
SRC="$BUILT_PRODUCTS_DIR/$PRODUCT_NAME.app"
RES="$DEST/Contents/Resources"

echo "Installing $SRC -> $DEST"
rm -rf "$DEST"
ditto "$SRC" "$DEST"
mkdir -p "$RES"

# Copy raw resources so the runtime can load the cursor asset directly.
if [ -d "$SRCROOT/Resources" ]; then
  ditto "$SRCROOT/Resources" "$RES"
fi
if [ -d "$SRCROOT/resources" ]; then
  ditto "$SRCROOT/resources" "$RES"
fi

rm -f "$RES/BaymaxCursor.png"

# This script phase runs before Xcode's final signing step, so sign the installed copy explicitly.
DEV_ID="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -n 1)"
if [ -n "$DEV_ID" ]; then
  codesign --force --deep --sign "$DEV_ID" "$DEST"
else
  codesign --force --deep --sign - "$DEST"
fi

codesign --verify --deep --strict "$DEST"
touch "$DERIVED_FILE_DIR/Baymax.install.stamp"
echo "Install done. Launch from $DEST to keep permissions."
