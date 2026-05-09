# img-host

Multi-user image hosting backend using Cloudflare Workers, R2 storage, and D1 database.

## Features

- Multi-user authentication with API tokens
- Tiered subscriptions (free, pro, enterprise)
- Storage quotas and limits per tier
- Per-user image management
- Stripe integration ready
- API usage tracking and analytics

## Quick Start

### 1. Install Dependencies

```bash
npm install
```

### 2. Login to Cloudflare

```bash
wrangler login
```

### 3. Create R2 Bucket

```bash
wrangler r2 bucket create images
```

### 4. Initialize Database

Run the interactive setup script:

```bash
npm run db:init
```

Or manually:

```bash
# Create D1 database
wrangler d1 create imghost

# Update wrangler.toml with the database_id from above

# Run migrations
npm run db:migrate:local  # For local development
npm run db:migrate        # For production
```

### 5. Run Locally

```bash
npm run dev
```

For local development, create a `.dev.vars` file:

```
UPLOAD_TOKEN=legacy-test-token
```

### 6. Test the API

```bash
./examples/api-examples.sh
```

### 7. Deploy

```bash
npm run deploy
```

## Database Setup

See [DATABASE.md](./DATABASE.md) for detailed database schema, migration instructions, and API documentation.

### Quick Database Commands

```bash
# Initialize database
npm run db:init

# Run migrations
npm run db:migrate:local      # Local
npm run db:migrate            # Production

# List tables
npm run db:tables:local       # Local
npm run db:tables             # Production

# Execute custom query
npm run db:query:local "SELECT * FROM users LIMIT 5;"
npm run db:query "SELECT * FROM users LIMIT 5;"
```

## API Endpoints

### Authentication

#### Register User
```bash
POST /auth/register
Content-Type: application/json

{
  "email": "user@example.com",
  "password": "secure-password"
}
```

#### Login
```bash
POST /auth/login
Content-Type: application/json

{
  "email": "user@example.com",
  "password": "secure-password"
}
```

### User Management

#### Get User Info
```bash
GET /user
Authorization: Bearer <access_token_or_api_key>
# or: X-API-Key: <api_key>
```

#### List User Images
```bash
GET /images?limit=100&offset=0
Authorization: Bearer <access_token_or_api_key>
# or: X-API-Key: <api_key>
```

### Image Operations

#### Upload Image
```bash
POST /upload
Authorization: Bearer <access_token_or_api_key>
# or: X-API-Key: <api_key>
Content-Type: multipart/form-data

image=<file>
```

#### Get Image
```bash
GET /<id>.<ext>
```

#### Delete Image
```bash
DELETE /delete/<id>?token=<delete_token>
```

### Health Check
```bash
GET /health
```

## Subscription Tiers

### Free Tier
- 100MB storage
- 10MB max file size
- 100 images maximum
- API access

### Pro Tier
- 10GB storage
- 50MB max file size
- Unlimited images
- Custom domains
- Analytics
- API access

### Enterprise Tier
- 100GB storage
- 100MB max file size
- Unlimited images
- Custom domains
- Analytics
- API access
- Priority support

## Project Structure

```
img-host/
├── src/
│   ├── index.ts        # Main worker entry point
│   ├── database.ts     # D1 database utilities
│   ├── auth.ts         # Authentication utilities
│   └── types.ts        # TypeScript type definitions
├── migrations/
│   └── 0001_initial_schema.sql
├── scripts/
│   └── init-db.sh      # Database initialization script
├── examples/
│   └── api-examples.sh # API usage examples
├── schema.sql          # Complete database schema
├── DATABASE.md         # Database documentation
├── wrangler.toml       # Cloudflare configuration
└── package.json
```

## Development

### Local Development with Database

```bash
# Start local dev server
npm run dev

# In another terminal, run migrations
npm run db:migrate:local

# Create test user and get API token
./examples/api-examples.sh
```

### Testing

```bash
# Test API endpoints
./examples/api-examples.sh

# Query database
npm run db:query:local "SELECT * FROM storage_usage;"

# Check user storage
npm run db:query:local "
SELECT
  u.email,
  COUNT(i.id) as image_count,
  SUM(i.size_bytes) as total_bytes
FROM users u
LEFT JOIN images i ON u.id = i.user_id
GROUP BY u.id;
"
```

## Security

- **Passwords:** PBKDF2 with 100,000 iterations (upgradeable to bcrypt/Argon2)
- **JWT Tokens:** HMAC SHA-256 signed with configurable secret
- **Refresh Tokens:** 30-day expiry with automatic rotation
- **Rate Limiting:** Protects all authentication endpoints
- **Email Verification:** Required for account activation
- **Secure Password Reset:** Time-limited reset tokens
- **API Tokens:** Backward compatible UUID tokens
- **Parameterized Queries:** All database queries use prepared statements
- **Delete Tokens:** Per-image tokens prevent unauthorized deletion
- **Storage Quotas:** Enforce tier limits

See [AUTHENTICATION.md](./AUTHENTICATION.md) for complete authentication documentation.

## Migration from Single-User

The legacy `UPLOAD_TOKEN` environment variable is still supported for backward compatibility, but new users should register via `/auth/register` and use API tokens.

## Next Steps

- [x] Add rate limiting on auth endpoints
- [x] Add email verification
- [x] Implement password reset
- [x] JWT token authentication
- [ ] Implement Stripe webhook handlers
- [ ] Set up automated cleanup of orphaned R2 objects
- [ ] Add OAuth providers (Google, GitHub)
- [ ] Two-factor authentication (TOTP)
- [ ] Integrate email service (SendGrid/Postmark)

## Troubleshooting

### Database Not Found
Verify `database_id` in `wrangler.toml` matches the output from `wrangler d1 create imghost`

### Migration Failed
Check SQL syntax and ensure you're using SQLite-compatible SQL

### Permission Denied
Ensure you're authenticated: `wrangler login`

See [DATABASE.md](./DATABASE.md) for more troubleshooting tips.

## License

This project is licensed under the [GNU Affero General Public License v3.0](../../LICENSE).
