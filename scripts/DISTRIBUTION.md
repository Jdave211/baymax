# Baymac Distribution Guide

## Building a Release

### Prerequisites

1. **Apple Developer Account** ($99/year)
   - Enroll at [developer.apple.com](https://developer.apple.com/programs/)
   - You need this for code signing and notarization

2. **Developer ID Certificate**
   - In Xcode: Preferences → Accounts → Your Apple ID → Manage Certificates
   - Click + → "Developer ID Application"
   - This certificate is used to sign the app for distribution outside the App Store

3. **Notarization Credentials**
   - Generate an app-specific password at [appleid.apple.com](https://appleid.apple.com/)
   - Store it in your keychain:
     ```bash
     xcrun notarytool store-credentials "BAYMAC_NOTARY"
     ```
   - You'll be prompted for your Apple ID, app-specific password, and team ID

4. **Install create-dmg**
   ```bash
   brew install create-dmg
   ```

### Build Process

Run the release script:

```bash
./scripts/release.sh 1.0.0
```

This will:
1. Build the app in Release configuration
2. Code sign with your Developer ID
3. Notarize with Apple (takes 1-3 minutes)
4. Create a DMG with drag-to-Applications UI
5. Notarize and staple the DMG

Output: `releases/Baymac.dmg`

### Test the DMG

Before distributing, test on a **clean Mac** (or a Mac that doesn't have Xcode/dev tools):

1. Double-click `Baymac.dmg`
2. Drag Baymac to Applications
3. Open Baymac from Applications
4. macOS should NOT show any Gatekeeper warnings
5. Grant permissions when prompted
6. Test voice interaction

If you see "cannot be opened because the developer cannot be verified," the notarization failed.

---

## Hosting the DMG

You have three options for hosting. **Cloudflare R2 is recommended** since you're already using Cloudflare.

### Option 1: Cloudflare R2 (Recommended)

R2 is Cloudflare's S3-compatible storage. 10GB free, no egress fees.

#### Setup

1. Go to [Cloudflare Dashboard](https://dash.cloudflare.com/) → R2
2. Create a bucket: `baymac-releases`
3. Upload `releases/Baymac.dmg`
4. Make it public:
   - Go to Settings → Public Access → Allow Access
   - Copy the public bucket URL (e.g., `https://pub-xxxx.r2.dev`)

Your download URL will be:
```
https://pub-xxxx.r2.dev/Baymac.dmg
```

#### Update Landing Page

In `landing-page/index.html`, replace `/download/Baymac.dmg` with your R2 URL:

```javascript
// Find these lines and update:
window.location.href = 'https://pub-xxxx.r2.dev/Baymac.dmg';
```

Or use a custom domain:
- Add a CNAME record: `download.baymac.so` → `pub-xxxx.r2.dev`
- Then use: `https://download.baymac.so/Baymac.dmg`

---

### Option 2: GitHub Releases

Free and simple, but tied to your GitHub repo.

1. Create a new release on GitHub
2. Upload `Baymac.dmg` as an asset
3. Use this URL format in your landing page:
   ```
   https://github.com/yourusername/baymax/releases/latest/download/Baymac.dmg
   ```

**Pros**: Free, automatic versioning
**Cons**: Users see GitHub in the URL

---

### Option 3: Cloudflare Pages (If Landing Page is on Pages)

If your landing page is hosted on Cloudflare Pages, you can serve the DMG directly:

1. Create a `public/download/` directory in your Pages project
2. Add `Baymac.dmg` there
3. Deploy
4. Access at: `https://www.baymac.so/download/Baymac.dmg`

**Cons**: DMG goes through git (bad for large files), no CDN caching

---

## Updating the Landing Page

After hosting, update these references in `landing-page/index.html`:

```javascript
// Line ~816, ~1088, ~1123
window.location.href = 'YOUR_DOWNLOAD_URL_HERE';
```

Deploy the updated landing page.

---

## Release Checklist

Before each public release:

- [ ] Update version number in the release script call
- [ ] Test on a clean Mac
- [ ] Upload DMG to hosting
- [ ] Update landing page download URL if needed
- [ ] Test download link on landing page
- [ ] Verify Gatekeeper doesn't block the app
- [ ] Test sign-in flow (Google OAuth)
- [ ] Test voice interaction
- [ ] Test PAYG enrollment (if applicable)

---

## Troubleshooting

### "Baymac.app cannot be opened because the developer cannot be verified"

- Notarization failed or wasn't stapled. Re-run the release script.
- Check: `spctl -a -vv -t install releases/Baymac.app`
  - Should say: "source=Notarized Developer ID"

### "No Developer ID certificate found"

- Go to Xcode → Preferences → Accounts → Manage Certificates
- Click + → "Developer ID Application"
- If you don't see this option, you need to enroll in the Apple Developer Program ($99/year)

### Notarization times out

- Check your notarization history:
  ```bash
  xcrun notarytool history --keychain-profile "BAYMAC_NOTARY"
  ```
- Get logs for a specific submission:
  ```bash
  xcrun notarytool log <submission-id> --keychain-profile "BAYMAC_NOTARY"
  ```

### "xcbeautify: command not found"

The release script tries to use `xcbeautify` for prettier output but falls back if it's not installed. To install:
```bash
brew install xcbeautify
```

---

## Cost Breakdown

**Apple Developer Program**: $99/year (required for distribution)
**Cloudflare R2**: Free up to 10GB storage + 10GB egress/month
**Cloudflare Pages**: Free (unlimited sites)

Total minimum cost: $99/year
