# Pre-Launch Checklist

## Code Quality
- [x] Remove debug logs from production code
- [x] Update .gitignore to exclude sensitive files (.env, *.dmg)
- [x] Update README with current branding and setup
- [x] Clean up unused files
- [x] Verify error messages are user-friendly

## Distribution Setup
- [ ] Enroll in Apple Developer Program ($99/year)
- [ ] Generate Developer ID certificate in Xcode
- [ ] Set up notarization credentials (`xcrun notarytool store-credentials`)
- [ ] Install `brew install create-dmg`
- [ ] Run `./scripts/release.sh 1.0.0` to build first DMG
- [ ] Test DMG on clean Mac (no Xcode installed)

## Hosting Setup
- [ ] Create Cloudflare R2 bucket: `baymac-releases`
- [ ] Upload Baymac.dmg to R2
- [ ] Enable public access on bucket
- [ ] Copy R2 public URL (or set up custom domain: download.baymac.so)
- [ ] Update `DOWNLOAD_URL` in landing-page/index.html

## Database
- [ ] Run migration: `migrations/004_add_payg_cap.sql` in Supabase Dashboard
- [ ] Verify `profiles` table has all PAYG columns
- [ ] Test user sign-up flow on landing page
- [ ] Verify logs are being written to `baymax_logs`

## Stripe
- [ ] Verify all price IDs are correct in landing-page/index.html:
  - `PRO_PRICE_ID`
  - `MAX_PRICE_ID`
  - `LIFETIME_PRICE_ID`
  - `PAYG_PRICE_ID` in worker/src/index.ts
- [ ] Test checkout flow for each tier
- [ ] Test PAYG enrollment and cap selection
- [ ] Verify webhooks are working (check Stripe Dashboard → Developers → Webhooks)

## Worker
- [ ] Verify all secrets are set:
  - `ANTHROPIC_API_KEY`
  - `ASSEMBLYAI_API_KEY`
  - `ELEVENLABS_API_KEY`
  - `SUPABASE_SERVICE_KEY`
  - `STRIPE_SECRET_KEY`
- [ ] Deploy latest version: `cd worker && npx wrangler deploy`
- [ ] Test all routes:
  - `/chat` (Claude streaming)
  - `/tts` (ElevenLabs)
  - `/transcribe-token` (AssemblyAI)
  - `/log` (Supabase logging)
  - `/usage` (monthly usage check)
  - `/stripe/payg-subscribe` (PAYG enrollment)
  - `/stripe/report-usage` (PAYG metering)
  - `/stripe/payg-status` (PAYG status)

## Mac App
- [ ] Update `.env` with production values:
  - `WORKER_URL=https://your-worker.workers.dev`
  - `SUPABASE_URL=https://your-project.supabase.co`
  - `SUPABASE_ANON_KEY=your_key`
  - `LANDING_PAGE_URL=https://www.baymac.so`
- [ ] Build and test locally first (Cmd+R in Xcode)
- [ ] Test all permissions flow (Microphone, Screen Recording, Accessibility)
- [ ] Test voice interaction (Ctrl+Option hotkey)
- [ ] Test Google sign-in from app
- [ ] Test usage limits and PAYG
- [ ] Verify conversation history persists across restarts

## Landing Page
- [ ] Deploy to production (Cloudflare Pages or your hosting)
- [ ] Update download URL with R2/hosting URL
- [ ] Test Google OAuth login
- [ ] Test pricing modal and checkout
- [ ] Test PAYG enrollment flow
- [ ] Verify all buttons work
- [ ] Test on mobile (responsive)
- [ ] Check analytics (PostHog) is tracking

## Final Testing
- [ ] Full end-to-end test as new user:
  1. Download DMG from landing page
  2. Install app
  3. Sign in with Google
  4. Grant permissions
  5. Test voice interaction
  6. Verify usage is tracked
  7. Test upgrade flow (if on free tier)
- [ ] Test on fresh Mac without Xcode installed
- [ ] Verify no Gatekeeper warnings
- [ ] Test in low bandwidth environment
- [ ] Check all error states have friendly messages

## Marketing
- [ ] Screenshot/GIF demo for landing page
- [ ] Update social media links
- [ ] Prepare launch announcement
- [ ] Set up support channel (email/Discord/Twitter)

## Post-Launch
- [ ] Monitor Stripe Dashboard for payments
- [ ] Monitor Worker logs for errors
- [ ] Monitor Supabase usage
- [ ] Monitor PostHog analytics
- [ ] Monitor user feedback channels
- [ ] Set up error alerting (optional: Sentry integration)

## Known Non-Blocking Issues
These warnings are safe to ignore:
- Swift 6 concurrency warnings in Xcode
- Deprecated `onChange` warning in OverlayWindow.swift
- "leanring" typo in project name (intentional/legacy)
