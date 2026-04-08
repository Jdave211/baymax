# Baymax

**Your on-screen learning companion for macOS.** A little buddy that lives next to your cursor, sees your screen, talks to you, and guides you through anything — step by step, with its own cursor.

Ask "how do I crop a video?" while in DaVinci Resolve and Baymax captures your screen, figures out what you're looking at, then walks you through it — pointing at exactly where to click with labels like *"over here!"* and *"this one!"* while explaining each step conversationally through voice.

---

## How it works

1. **⌘⇧B** → Baymax appears, starts listening
2. Talk naturally — "How do I add a LUT in DaVinci?"
3. Baymax captures your screen → GPT-4o Vision analyzes it
4. For each step:
   - **Speaks** the instruction conversationally (ElevenLabs TTS)
   - Moves its **virtual cursor** to the exact UI element
   - Pops up a short **context label** ("over here!", "click this!")
   - **Spotlights** the target area, dimming everything else
   - **Waits** for you to do the action
5. When you click the right spot → "nice!" → next step
6. Done → "Boom, done! See, easy right?" → listens for next question

## Tech stack

| Layer | Technology |
|-------|-----------|
| **App** | Swift + SwiftUI (native macOS, no Electron) |
| **Overlay** | NSPanel (borderless, transparent, click-through) |
| **Screen capture** | ScreenCaptureKit (macOS 14+, excludes own windows) |
| **AI vision** | GPT-5 mini with base64 screenshot |
| **Voice output** | ElevenLabs TTS (primary) → OpenAI TTS → AVSpeech fallback |
| **Voice input** | Apple Speech framework (real-time transcription, silence detection) |
| **Hotkeys** | NSEvent global/local key monitors |
| **Animations** | SwiftUI spring animations |

## Prerequisites

- **macOS 14.0+** (Sonoma or later)
- **Xcode 15+**
- **XcodeGen** — `brew install xcodegen`
- **OpenAI API key** (required — GPT-5 mini screen analysis)
- **ElevenLabs API key** (recommended — natural conversational voice)

## Setup

```bash
cd baymax
chmod +x setup.sh
./setup.sh
open Baymax.xcodeproj
```

Create a local `.env` in the repo root with your keys. Baymax reads from it on launch, and it is ignored by git.

Then in Xcode:
1. **Build & Run** (⌘R)
2. Grant **Screen Recording** + **Accessibility** + **Microphone** permissions
3. Hold **Control + Option** to talk

## Usage

| Action | How |
|--------|-----|
| Activate | **⌘⇧B** |
| Ask a question | Talk (voice is default) or click ⌨ to type |
| Dismiss | **Escape** or **⌘⇧B** again |

### Example questions
- "How do I crop a video in DaVinci Resolve?"
- "Show me how to create a mask in Photoshop"
- "How do I split a clip here?"
- "Walk me through color grading this shot"

## Architecture

```
Sources/
├── App/                  # Entry point, AppDelegate, global state
├── Overlay/              # All overlay UI
│   ├── OverlayWindow     # Transparent click-through NSPanel
│   ├── CharacterView     # Animated companion (eyes, waveform, thinking dots)
│   ├── VirtualCursorView # AI's cursor with glow + ripple
│   ├── ContextLabel      # Short labels: "over here!", "found it!"
│   ├── AnnotationView    # Spotlight + highlight overlay
│   └── InputBarView      # Voice-first input (mic, waveform, keyboard fallback)
├── AI/                   # OpenAI client, screen analysis, teaching session
├── Screen/               # ScreenCaptureKit, cursor tracking @ 60fps
├── Voice/                # ElevenLabs TTS, Apple Speech recognizer
├── Input/                # Global hotkey management
├── Settings/             # API keys, voice selection
└── Utilities/            # Extensions (hex colors, reverse mask, etc.)
```

## Permissions

- **Screen Recording** — capture screen for AI analysis
- **Accessibility** — global hotkeys and click detection
- **Microphone** — voice input

All prompted automatically. Manage in **System Settings → Privacy & Security**.

## License

MIT
