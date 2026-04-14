# Netlify Deployment Instructions

## Quick Deploy

1. Go to [app.netlify.com](https://app.netlify.com/)
2. Click **"Add new site"** → **"Deploy manually"**
3. Drag and drop the entire `dist` folder
4. Done! Your site is live.

## Configure Custom Domain (Optional)

After deployment:
1. Go to **Site settings** → **Domain management**
2. Click **Add a domain**
3. Enter your domain (e.g., `www.baymac.so`)
4. Follow DNS instructions to point your domain to Netlify

## Environment Variables

No environment variables needed! All API keys are in the Cloudflare Worker.

## Redirect Rules

Create a `_redirects` file in `dist/` if you need custom redirects:

```
# Redirect root to landing page
/  /index.html  200

# Redirect old URLs (if migrating from another domain)
# /old-path  /new-path  301
```

## Update Download URL

After hosting the DMG on Cloudflare R2 or another CDN:

1. Get your DMG URL (e.g., `https://pub-xxxx.r2.dev/Baymac.dmg`)
2. Open `dist/index.html`
3. Find line ~752: `const DOWNLOAD_URL = '/download/Baymac.dmg';`
4. Replace with your R2 URL
5. Re-deploy by dragging the updated `dist` folder to Netlify

## Continuous Deployment (Optional)

To auto-deploy on git push:

1. Go to **Site settings** → **Build & deploy**
2. Click **Link to repository**
3. Connect your GitHub repo
4. Set build settings:
   - **Base directory**: `landing-page`
   - **Build command**: (leave empty - static site)
   - **Publish directory**: `.` (or `landing-page`)

## Testing Before Deploy

Test locally:
```bash
# Install a simple HTTP server
npm install -g http-server

# Serve the dist folder
cd dist
http-server -p 8080

# Open http://localhost:8080 in your browser
```

## Post-Deploy Checklist

- [ ] Test Google Sign-In
- [ ] Test pricing checkout (all tiers)
- [ ] Test PAYG enrollment flow
- [ ] Verify download button works
- [ ] Test on mobile
- [ ] Check SSL certificate is active (Netlify does this automatically)
