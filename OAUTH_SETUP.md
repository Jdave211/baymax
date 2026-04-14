# Fixing Google OAuth Redirect URLs

## The Issue

After signing in with Google, users are redirected to `localhost` instead of your production domain. This happens because Supabase OAuth only allows redirect URLs that are explicitly whitelisted in the dashboard.

## Solution: Add Production Domain to Supabase

1. **Go to Supabase Dashboard**
   - Navigate to [app.supabase.com](https://app.supabase.com/)
   - Select your project

2. **Open Authentication Settings**
   - Click **Authentication** in the left sidebar
   - Go to **URL Configuration**

3. **Add Your Production URL**
   
   Under **Redirect URLs**, add:
   ```
   https://your-netlify-domain.netlify.app
   https://www.baymac.so
   http://localhost:3000
   ```
   
   (Keep `localhost` for local development)

4. **Also Update Site URL** (if different)
   - Set **Site URL** to: `https://www.baymac.so`

5. **Save Changes**

## After Deploying to Netlify

Once you deploy and get your Netlify URL:

1. Copy your live URL (e.g., `https://baymac.netlify.app`)
2. Add it to Supabase redirect URLs (step 3 above)
3. If using a custom domain, add that too

## Test the Flow

1. Go to your production site
2. Click "Sign in with Google to download"
3. Complete Google OAuth
4. You should be redirected back to your production site
5. The download button should appear

## Common Issues

**Issue**: Still redirecting to localhost after adding domain
- **Fix**: Clear browser cache and cookies, then try again

**Issue**: "Invalid redirect URL" error from Supabase
- **Fix**: Make sure the URL in Supabase **exactly** matches your deployment URL (including https://)

**Issue**: Works on localhost but not in production
- **Fix**: You forgot to add the production domain to Supabase redirect URLs

## Quick Check

After adding the URLs, verify in Supabase dashboard:
- Authentication → URL Configuration → Redirect URLs
- Should show both localhost and production URLs

## Google OAuth Consent Screen

If you haven't published your OAuth app with Google:
1. Go to [Google Cloud Console](https://console.cloud.google.com/)
2. Navigate to **APIs & Services** → **OAuth consent screen**
3. Add your production domain to **Authorized domains**
4. Add test users (if app is in testing mode)
5. Or publish the app for public use

## Mac App Redirect

The Mac app uses `baymac://auth` as a custom URL scheme. This should already work since it's handled separately. Just make sure:
- `?client=mac` parameter is preserved in redirects
- The Mac app is registered for the `baymac://` URL scheme (already done in Info.plist)
