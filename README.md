# Baymac

Your AI assistant that lives in your menu bar. Talk to it with voice, it sees your screen, responds with voice, and can even point at things.

Download it [here](https://www.baymac.so/) for free.

![Baymac AI Assistant](clicky-demo.gif)

This is the open-source version of Baymac for those who want to hack on it, build their own features, or see how it works.

## Quick Setup

### Prerequisites

- macOS 14.2+ (for ScreenCaptureKit)
- Xcode 15+
- Node.js 18+ (for the Cloudflare Worker)
- A [Cloudflare](https://cloudflare.com) account (free tier works)
- API keys: [Anthropic](https://console.anthropic.com), [AssemblyAI](https://www.assemblyai.com), [ElevenLabs](https://elevenlabs.io)

### 1. Set up the Cloudflare Worker

The Worker proxies API calls so your keys never ship in the app binary.

```bash
cd worker
npm install

# Add your secrets
npx wrangler secret put ANTHROPIC_API_KEY
npx wrangler secret put ASSEMBLYAI_API_KEY
npx wrangler secret put ELEVENLABS_API_KEY
npx wrangler secret put SUPABASE_SERVICE_KEY
npx wrangler secret put STRIPE_SECRET_KEY

# Deploy
npx wrangler deploy
```

Update `wrangler.toml` with your Supabase URL and ElevenLabs voice ID.

### 2. Configure the App

Create `.env` in the project root:

```
WORKER_URL=https://your-worker.workers.dev
SUPABASE_URL=https://your-project.supabase.co
SUPABASE_ANON_KEY=your_anon_key
LANDING_PAGE_URL=https://www.baymac.so
```

### 3. Build and Run

```bash
open Baymax.xcodeproj
```

In Xcode:
1. Select your signing team under Signing & Capabilities
2. Choose the **Baymax** scheme
3. Hit **Cmd + R** to build and run

The app appears in your menu bar (no dock icon). Click it, grant permissions, and you're ready.

### Permissions Required

- **Microphone** — voice input
- **Accessibility** — global keyboard shortcut (Ctrl + Option)
- **Screen Recording** — screenshot capture
- **Screen Content** — ScreenCaptureKit access

## Architecture

**Menu bar-only app** with two NSPanel windows:
1. Control panel dropdown (click menu bar icon)
2. Full-screen transparent cursor overlay (appears on voice interaction)

**Voice → AI → Voice pipeline:**
- Push-to-talk streams to AssemblyAI (websocket transcription)
- Transcript + screenshot → Claude (SSE streaming)
- Claude response → ElevenLabs (TTS playback)
- Claude can emit `[POINT:x,y:label:screenN]` tags to make the cursor point at UI elements

All APIs proxied through Cloudflare Worker for security.

## Project Structure

```
Baymax/                     # Swift source
  BaymaxApp.swift              # App entry point
  CompanionManager.swift       # Central state machine
  CompanionPanelView.swift     # Menu bar panel UI
  ClaudeAPI.swift              # Claude streaming client
  ElevenLabsTTSClient.swift    # Text-to-speech
  OverlayWindow.swift          # Blue cursor overlay
  AssemblyAI*.swift            # Real-time transcription
  BuddyDictation*.swift        # Voice input pipeline
worker/                     # Cloudflare Worker proxy
  src/index.ts                 # API routes: /chat, /tts, /log, /usage, etc.
landing-page/               # Web landing page
  index.html                   # Pricing, auth, download
AGENTS.md                   # Full architecture doc
```

## Distribution

To create a signed DMG for distribution:

```bash
# Build in Release mode
xcodebuild -project Baymax.xcodeproj -scheme Baymax -configuration Release build

# Sign with Developer ID (requires Apple Developer account)
codesign --force --deep --sign "Developer ID Application: Your Name (TEAMID)" \
  build/Release/Baymax.app

# Notarize (required for Gatekeeper)
# See: https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution

# Create DMG
# Use create-dmg or hdiutil
```

See `scripts/release.sh` for the full automated workflow.

## Contributing

PRs welcome. Read `AGENTS.md` for the full technical architecture.

Questions? DM [@your_twitter](https://x.com/your_twitter).
