#!/bin/bash
set -e

echo "🤖 Setting up Baymax..."

# Check for Xcode
if ! command -v xcodebuild &> /dev/null; then
    echo "❌ Xcode is required. Install it from the App Store."
    exit 1
fi

# Install XcodeGen if needed
if ! command -v xcodegen &> /dev/null; then
    echo "📦 Installing XcodeGen..."
    brew install xcodegen
fi

# Generate Xcode project
echo "🔧 Generating Xcode project..."
xcodegen generate

echo ""
echo "✅ Setup complete!"
echo ""
echo "Next steps:"
echo "  1. Open Baymax.xcodeproj in Xcode"
echo "  2. Build & Run (⌘R)"
echo "  3. Click the ✨ icon in the menu bar"
echo "  4. Enter your OpenAI API key in Settings"
echo "  5. Press ⌘⇧B to activate Baymax"
echo ""
echo "System permissions needed:"
echo "  • Screen Recording (System Settings → Privacy & Security → Screen Recording)"
echo "  • Accessibility (System Settings → Privacy & Security → Accessibility)"
echo ""
