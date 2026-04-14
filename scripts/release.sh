#!/bin/bash
set -euo pipefail

# Simplified release script - builds DMG without auto-notarization
# Notarization happens separately after DMG creation

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

SCHEME="Baymax"
APP_NAME="Baymac"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/build"
ARCHIVE_PATH="${BUILD_DIR}/${APP_NAME}.xcarchive"
EXPORT_DIR="${BUILD_DIR}/export"
DMG_OUTPUT_DIR="${PROJECT_DIR}/releases"
DMG_BACKGROUND="${PROJECT_DIR}/dmg-background.png"
DMG_FILENAME="${APP_NAME}.dmg"

VERSION="${1:-1.0.0}"

echo ""
echo "🚀 Building Baymac v${VERSION}"
echo ""

# Check for create-dmg
if ! command -v create-dmg &> /dev/null; then
    echo "❌ create-dmg not found. Install it with: brew install create-dmg"
    exit 1
fi

# Clean
echo "🧹 Cleaning build directory..."
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}" "${EXPORT_DIR}" "${DMG_OUTPUT_DIR}"

# Step 1: Archive
echo "📦 Archiving Baymac..."
xcodebuild archive \
    -project "${PROJECT_DIR}/Baymax.xcodeproj" \
    -scheme "${SCHEME}" \
    -configuration Release \
    -archivePath "${ARCHIVE_PATH}" \
    MARKETING_VERSION="${VERSION}" \
    CODE_SIGN_STYLE=Automatic \
    2>&1 | grep -E "Archive|Signing|error|warning|failed|succeeded" || true

if [ ! -d "${ARCHIVE_PATH}" ]; then
    echo "❌ Archive failed."
    exit 1
fi

echo "✅ Archive created"

# Step 2: Export WITHOUT notarization (faster)
echo "📤 Exporting signed app (without notarization)..."

EXPORT_OPTIONS="${BUILD_DIR}/ExportOptions.plist"
cat > "${EXPORT_OPTIONS}" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>destination</key>
    <string>export</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>teamID</key>
    <string>U8FPZXV6X6</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
    -archivePath "${ARCHIVE_PATH}" \
    -exportPath "${EXPORT_DIR}" \
    -exportOptionsPlist "${EXPORT_OPTIONS}" \
    -allowProvisioningUpdates \
    2>&1 | grep -E "Export|Signing|error|warning|failed|succeeded" || true

if [ ! -d "${EXPORT_DIR}/${APP_NAME}.app" ]; then
    echo "❌ Export failed."
    ls -la "${EXPORT_DIR}"
    exit 1
fi

echo "✅ App exported and signed"

# Step 3: Create DMG
echo "💿 Creating DMG..."

DMG_PATH="${DMG_OUTPUT_DIR}/${DMG_FILENAME}"
rm -f "${DMG_PATH}"

create-dmg \
    --volname "${APP_NAME}" \
    --window-pos 200 120 \
    --window-size 660 400 \
    --icon-size 160 \
    --icon "${APP_NAME}.app" 180 170 \
    --hide-extension "${APP_NAME}.app" \
    --app-drop-link 480 170 \
    --no-internet-enable \
    "${DMG_PATH}" \
    "${EXPORT_DIR}/${APP_NAME}.app" \
    2>&1 | grep -v "^hdiutil:" || true

if [ ! -f "${DMG_PATH}" ]; then
    echo "❌ DMG creation failed."
    exit 1
fi

echo "✅ DMG created: ${DMG_PATH}"

# Step 4: Notarize the DMG
echo "🔏 Notarizing DMG with Apple (this takes 1-3 minutes)..."

xcrun notarytool submit "${DMG_PATH}" \
    --keychain-profile "BAYMAC_NOTARY" \
    --wait \
    2>&1

echo "📎 Stapling notarization ticket..."
xcrun stapler staple "${DMG_PATH}"

echo "✅ DMG notarized and stapled"

# Done
echo ""
echo "═══════════════════════════════════════════════════════"
echo "✅ Baymac v${VERSION} release complete!"
echo ""
echo "   DMG location:"
echo "   ${DMG_PATH}"
echo ""
echo "Next steps:"
echo "  1. Test the DMG on a clean Mac"
echo "  2. Upload to hosting (Cloudflare R2, S3, etc.)"
echo "  3. Update landing page download link"
echo "═══════════════════════════════════════════════════════"
echo ""
