# Authentication System Documentation

Complete user authentication system with JWT tokens, email verification, password reset, and rate limiting.

## Features

- Email/password authentication with PBKDF2 password hashing
- JWT access tokens (1 hour expiry) and refresh tokens (30 days expiry)
- Email verification on signup
- Password reset flow via email
- Rate limiting on all auth endpoints
- Secure token management
- Backward compatible with legacy API tokens

## Security Features

1. **Password Hashing**: PBKDF2 with 100,000 iterations (upgradeable to bcrypt/argon2)
2. **JWT Tokens**: HMAC SHA-256 signed tokens
3. **Rate Limiting**: Prevents brute force attacks
4. **Email Verification**: Ensures valid email addresses
5. **Secure Password Reset**: Time-limited reset tokens
6. **Refresh Token Rotation**: Tokens are rotated on each use
7. **Token Revocation**: All refresh tokens can be revoked

## API Endpoints

### 1. Register User

Create a new user account.

**Endpoint:** `POST /auth/register`

**Request Body:**
```json
{
  "email": "user@example.com",
  "password": "secure-password-123"
}
```

**Requirements:**
- Email must be valid format
- Password must be at least 8 characters
- Email must not already be registered

**Response (201 Created):**
```json
{
  "access_token": "eyJhbGc...",
  "refresh_token": "base64-encoded-token",
  "api_token": "uuid-token",
  "expires_in": 3600,
  "token_type": "Bearer",
  "user_id": "uuid",
  "email": "user@example.com",
  "subscription_tier": "free",
  "email_verified": false,
  "message": "Registration successful. Please check your email to verify your account."
}
```

**Rate Limit:** 5 requests per hour per IP

### 2. Login

Authenticate and receive tokens.

**Endpoint:** `POST /auth/login`

**Request Body:**
```json
{
  "email": "user@example.com",
  "password": "secure-password-123"
}
```

**Response (200 OK):**
```json
{
  "access_token": "eyJhbGc...",
  "refresh_token": "base64-encoded-token",
  "api_token": "uuid-token",
  "expires_in": 3600,
  "token_type": "Bearer",
  "user_id": "uuid",
  "email": "user@example.com",
  "subscription_tier": "free",
  "email_verified": true
}
```

**Rate Limit:** 10 requests per 15 minutes per IP

**Error Responses:**
- `401 Unauthorized`: Invalid credentials
- `429 Too Many Requests`: Rate limit exceeded

### 3. Refresh Token

Get a new access token using a refresh token.

**Endpoint:** `POST /auth/refresh`

**Request Body:**
```json
{
  "refresh_token": "base64-encoded-token"
}
```

**Response (200 OK):**
```json
{
  "access_token": "eyJhbGc...",
  "refresh_token": "new-base64-encoded-token",
  "expires_in": 3600,
  "token_type": "Bearer",
  "user_id": "uuid",
  "email": "user@example.com",
  "subscription_tier": "free"
}
```

**Note:** The old refresh token is revoked and a new one is issued (token rotation).

**Error Responses:**
- `400 Bad Request`: Missing refresh token
- `401 Unauthorized`: Invalid or expired refresh token

### 4. Forgot Password

Request a password reset email.

**Endpoint:** `POST /auth/forgot-password`

**Request Body:**
```json
{
  "email": "user@example.com"
}
```

**Response (200 OK):**
```json
{
  "message": "If an account exists with this email, you will receive password reset instructions."
}
```

**Rate Limit:** 3 requests per hour per IP

**Note:** Known and unknown emails receive the same success message when delivery succeeds. Delivery/configuration failures return 500 (and may reveal account existence); rate limits return 429.

The email contains a copyable code with iOS/macOS Enter Code instructions, not a web reset link. For Apple-only accounts use the stored email (which may be a private-relay address). See [setup and delivery/device QA](./SETUP_AUTH.md).

### 5. Reset Password

Reset password using the token from email.

**Endpoint:** `POST /auth/reset-password`

**Request Body:**
```json
{
  "token": "base64-encoded-reset-token",
  "new_password": "new-secure-password-123"
}
```

**Requirements:**
- Token must be a password-reset token for the existing account and not expired (1 hour expiry)
- Token is single-use and replaced by a subsequent reset request
- New password must be a string of at least 8 characters

`GET /auth/reset-password?token=...` is a read-only native-code instruction page for previously emailed links; it never consumes a code or changes a password.

**Response (200 OK):**
```json
{
  "message": "Password successfully reset. Please log in with your new password."
}
```

**Note:** Refresh-session revocation, password update and reset-code consumption use one guarded D1 transaction. Invalid/reused codes do not revoke sessions; storage failure rolls back the transaction, returns a generic 500 and leaves the code available for retry. Malformed bodies/invalid codes return 400. User ID, Apple link, API key, images and subscription are preserved. Existing access JWTs expire normally. Confirmation-mail failure does not change a successful reset response.

**Error Responses:**
- `400 Bad Request`: Invalid, expired, replaced or reused token; invalid body or weak password

### 6. Verify Email

Verify email address using the token from email.

**Endpoint:** `POST /auth/verify-email` or `GET /auth/verify-email?token=...`

**POST Request Body:**
```json
{
  "token": "base64-encoded-verification-token"
}
```

**GET Query Parameter:**
```
?token=base64-encoded-verification-token
```

**Response (200 OK):**
```json
{
  "message": "Email successfully verified!",
  "email_verified": true
}
```

**Error Responses:**
- `400 Bad Request`: Invalid or expired token (24 hour expiry)

### 7. Resend Verification Email

Request a new verification email.

**Endpoint:** `POST /auth/resend-verification`

**Request Body:**
```json
{
  "email": "user@example.com"
}
```

**Response (200 OK):**
```json
{
  "message": "If your email is registered, you will receive a verification email."
}
```

**Rate Limit:** 3 requests per hour per IP

## Using JWT Tokens or API Keys

### Making Authenticated Requests

You can authenticate with either:

1. **JWT access token** (recommended for web/mobile sessions)
2. **API key** (recommended for CLI tools and coding agents)

```bash
# JWT
curl -H "Authorization: Bearer eyJhbGc..." https://api.example.com/user

# API key in Authorization header
curl -H "Authorization: Bearer your-api-token" https://api.example.com/user

# API key in X-API-Key header
curl -H "X-API-Key: your-api-token" https://api.example.com/user
```

### Token Expiry

- **Access Token:** 1 hour
- **Refresh Token:** 30 days
- **Email Verification Token:** 24 hours
- **Password Reset Token:** 1 hour

### Token Refresh Flow

When your access token expires (401 response), use the refresh token to get a new one:

```javascript
// Access token expired, refresh it
const response = await fetch('/auth/refresh', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ refresh_token: storedRefreshToken })
});

const { access_token, refresh_token } = await response.json();

// Store new tokens
localStorage.setItem('access_token', access_token);
localStorage.setItem('refresh_token', refresh_token);

// Retry original request
const retryResponse = await fetch('/user', {
  headers: { 'Authorization': `Bearer ${access_token}` }
});
```

## Database Schema

### Users Table (Enhanced)

```sql
CREATE TABLE users (
  id TEXT PRIMARY KEY,
  email TEXT UNIQUE NOT NULL,
  password_hash TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  subscription_tier TEXT NOT NULL DEFAULT 'free',
  api_token TEXT UNIQUE NOT NULL,
  storage_limit_bytes INTEGER NOT NULL DEFAULT 104857600,
  email_verified INTEGER NOT NULL DEFAULT 0,
  email_verification_token TEXT,
  email_verification_token_expires INTEGER,
  password_reset_token TEXT,
  password_reset_token_expires INTEGER
);
```

### Refresh Tokens Table

```sql
CREATE TABLE refresh_tokens (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  token TEXT UNIQUE NOT NULL,
  expires_at INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  revoked INTEGER NOT NULL DEFAULT 0,
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);
```

### Rate Limits Table

```sql
CREATE TABLE rate_limits (
  id TEXT PRIMARY KEY,
  identifier TEXT NOT NULL,
  endpoint TEXT NOT NULL,
  request_count INTEGER NOT NULL DEFAULT 1,
  window_start INTEGER NOT NULL,
  UNIQUE(identifier, endpoint, window_start)
);
```

## Rate Limiting

All authentication endpoints are rate limited to prevent abuse:

| Endpoint | Limit | Window |
|----------|-------|--------|
| `/auth/register` | 5 requests | 1 hour |
| `/auth/login` | 10 requests | 15 minutes |
| `/auth/forgot-password` | 3 requests | 1 hour |
| `/auth/resend-verification` | 3 requests | 1 hour |

Rate limits are tracked by IP address.

## Email Integration

### Email Templates

The system sends the following emails:

1. **Email Verification** - Sent on registration
2. **Password Reset** - Sent on forgot password request
3. **Password Changed** - Confirmation after reset
4. **Welcome Email** - Sent after email verification

### Email Service Configuration

The implemented provider is Amazon SES v2. Configure `EMAIL_FROM` and `AWS_REGION`, and store `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` as secrets. There is no console-email fallback or SendGrid/Postmark integration. Missing credentials fail delivery without logging email bodies/codes.

See [SETUP_AUTH.md](./SETUP_AUTH.md) for verified SES API, sandbox, Apple private-relay authentication requirements and delivery testing limits.

## Environment Variables

Required:
- `JWT_SECRET` - Secret key for signing JWT tokens (generate with `openssl rand -base64 32`)

Required for email delivery:
- `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` - SES credentials (secrets)

Optional:
- `EMAIL_FROM` - Verified SES sender (default `noreply@isolated.tech`)
- `AWS_REGION` - SES region (default `us-east-1`)

`BASE_URL` is retained in the environment interface for compatibility but is not used to generate reset links.

### Setting up locally

Create `.dev.vars` file:

```env
JWT_SECRET=your-secret-key-here
EMAIL_FROM=noreply@your-verified-domain.com
AWS_REGION=us-east-1
AWS_ACCESS_KEY_ID=your-test-access-key
AWS_SECRET_ACCESS_KEY=your-test-secret-key
```

### Setting up in production

```bash
wrangler secret put JWT_SECRET
wrangler secret put AWS_ACCESS_KEY_ID
wrangler secret put AWS_SECRET_ACCESS_KEY
```

Update `wrangler.toml`:
```toml
[vars]
EMAIL_FROM = "noreply@your-verified-domain.com"
AWS_REGION = "us-east-1"
```

## Migration Guide

### Running Migrations

```bash
# Local development
wrangler d1 execute imghost --local --file=./migrations/0002_auth_enhancements.sql

# Production
wrangler d1 execute imghost --file=./migrations/0002_auth_enhancements.sql
```

### Backward Compatibility

The new authentication system maintains backward compatibility:

- Legacy API tokens continue to work
- Old SHA-256 password hashes are automatically upgraded to PBKDF2 on next login
- All authenticated endpoints accept JWTs plus API keys via either `Authorization: Bearer <token>` or `X-API-Key: <token>`

## Security Best Practices

1. **Use HTTPS Only** - Never send tokens over plain HTTP
2. **Store Tokens Securely** - Use iOS Keychain for mobile apps
3. **Set Strong JWT_SECRET** - Generate with `openssl rand -base64 32`
4. **Monitor Rate Limits** - Track failed login attempts
5. **Require Email Verification** - Enforce for sensitive operations
6. **Rotate Refresh Tokens** - Tokens are automatically rotated
7. **Revoke on Password Reset** - Refresh tokens are revoked; access JWTs expire normally

## Testing

### Test Registration Flow

```bash
# Register
curl -X POST http://localhost:8787/auth/register \
  -H "Content-Type: application/json" \
  -d '{"email":"test@example.com","password":"password123"}'

# Verify email (copy code from the received test email)
curl -X POST http://localhost:8787/auth/verify-email \
  -H "Content-Type: application/json" \
  -d '{"token":"VERIFICATION_TOKEN_HERE"}'

# Login
curl -X POST http://localhost:8787/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"test@example.com","password":"password123"}'
```

### Test Password Reset Flow

```bash
# Request reset
curl -X POST http://localhost:8787/auth/forgot-password \
  -H "Content-Type: application/json" \
  -d '{"email":"test@example.com"}'

# Reset password (copy full code from the received test email, never logs)
curl -X POST http://localhost:8787/auth/reset-password \
  -H "Content-Type: application/json" \
  -d '{"token":"RESET_TOKEN_HERE","new_password":"newpassword123"}'
```

### Test Token Refresh

```bash
# Get refresh token from login response
REFRESH_TOKEN="your-refresh-token"

# Refresh access token
curl -X POST http://localhost:8787/auth/refresh \
  -H "Content-Type: application/json" \
  -d "{\"refresh_token\":\"$REFRESH_TOKEN\"}"
```

## Troubleshooting

### "Invalid JWT signature"
- Check that `JWT_SECRET` is set correctly
- Ensure the same secret is used across all instances

### "Email not sent"
- Verify SES credentials, region and verified `EMAIL_FROM` identity
- Check sandbox recipient restrictions and bounce/suppression metadata
- For Apple private relay check registered sources and aligned SPF/DKIM
- See [SETUP_AUTH.md](./SETUP_AUTH.md); never log/reset secrets

### "Rate limit exceeded"
- Wait for the rate limit window to reset
- Check `rate_limits` table for current limits
- Run cleanup: `await db.cleanupOldRateLimits(3600000)`

### "Token expired"
- Access tokens expire after 1 hour - use refresh token
- Refresh tokens expire after 30 days - user must log in again
- Verification tokens expire after 24 hours - resend verification

## Future Enhancements

- [ ] OAuth providers (Google, GitHub)
- [ ] Two-factor authentication (TOTP)
- [ ] Session management dashboard
- [ ] Account deletion workflow
- [ ] IP-based suspicious activity detection
- [ ] Passwordless authentication (magic links)
