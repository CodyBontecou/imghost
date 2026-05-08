# imghost Development Guidelines

## Production-First Development

**CRITICAL**: This project uses a production-first development workflow. All development and testing should be done against the production backend.

### Backend (Cloudflare Worker)

- **Always deploy changes to production** after making backend modifications
- Run `wrangler deploy` from `backend/img-host/` after any backend code changes
- Never assume changes are live until deployed
- Use `wrangler tail` to debug production issues

```bash
cd backend/img-host
wrangler deploy
```

### iOS App Configuration

- **Debug builds use production URLs** - this is intentional
- `frontend/imghost/Config/Debug.xcconfig` should always point to:
  ```
  BACKEND_URL = https:/$()/imghost.isolated.tech
  ```
- Do NOT use local IP addresses (192.168.x.x) or localhost for development
- If you see network errors about "local network prohibited", check that Debug.xcconfig has the production URL

### Common Issues

1. **404 on new endpoints**: Backend changes haven't been deployed. Run `wrangler deploy`.
2. **"Local network prohibited" errors**: App is configured to hit local IP. Update Debug.xcconfig to production URL.
3. **Stale app config**: Clear Xcode derived data and rebuild:
   ```bash
   rm -rf ~/Library/Developer/Xcode/DerivedData/*imghost*
   ```

### Verification Commands

```bash
# Check if endpoint exists in production
curl -s https://imghost.isolated.tech/health

# Test a POST endpoint
curl -s -X POST https://imghost.isolated.tech/auth/apple -H "Content-Type: application/json" -d '{}'

# View production logs
wrangler tail --format=pretty
```

## API Response Format

**CRITICAL**: All backend JSON responses must use **snake_case** for field names.

The iOS Swift models use `CodingKeys` to map snake_case JSON to camelCase properties:
```swift
enum CodingKeys: String, CodingKey {
    case subscriptionTier = "subscription_tier"  // JSON uses snake_case
}
```

When adding new fields to API responses:
- Backend: `subscription_tier`, `storage_limit_bytes`, `has_access`
- NOT: `subscriptionTier`, `storageLimitBytes`, `hasAccess`

If you see `keyNotFound` decoding errors in the iOS app, check that the backend response uses snake_case.

### Landing Page

The landing page (`landing/index.html`) is served by the Worker from R2 storage.

**To update the landing page:**
```bash
wrangler r2 object put images/landing.html --file landing/index.html --remote
```

No Worker redeploy needed - changes are immediate.

## Project Structure

- `backend/img-host/` - Cloudflare Worker backend
- `frontend/imghost/` - iOS app and share extension
- `frontend/imghost/Config/` - Build configuration (xcconfig files)
- `landing/` - Landing page (served from R2 at root path)

## Bundle IDs and Product IDs

- **Main App Bundle ID**: `com.codybontecou.imghost`
- **Share Extension Bundle ID**: `com.codybontecou.imghost.ShareExtension`
- **App Group**: `group.com.imghost.shared`
- **IAP Products**: `imghost.pro.monthly`, `imghost.pro.yearly` (approved Starter subscriptions in App Store Connect)
- **D1 Database**: `imghost`
