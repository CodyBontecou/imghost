import { Auth } from './auth';
import { Database, type User } from './database';

export interface RequestAuthEnv {
  DB: D1Database;
  JWT_SECRET: string;
}

/**
 * Extracts authentication credential from request headers.
 * Supports either:
 * - X-API-Key: <api_token>
 * - Authorization: Bearer <access_jwt_or_api_token>
 */
export function extractAuthCredential(request: Request): string | null {
  const apiKey = request.headers.get('X-API-Key')?.trim();
  if (apiKey) {
    return apiKey;
  }

  const bearerToken = Auth.extractBearerToken(request.headers.get('Authorization'))?.trim();
  return bearerToken || null;
}

/**
 * Resolves an authenticated user from either JWT access token or legacy API token.
 */
export async function resolveAuthenticatedUser(
  request: Request,
  env: RequestAuthEnv,
  db?: Database
): Promise<User | null> {
  const credential = extractAuthCredential(request);
  if (!credential) {
    return null;
  }

  const database = db ?? new Database(env.DB);
  const jwtSecret = env.JWT_SECRET || 'default-secret-change-in-production';

  // First, try as JWT access token (only if token has JWT shape)
  if (credential.split('.').length === 3) {
    const jwtPayload = await Auth.verifyJWT(credential, jwtSecret);
    if (jwtPayload?.type === 'access') {
      return database.getUserById(jwtPayload.sub);
    }
  }

  // Fallback to API token for CLI/agent integrations
  return database.getUserByApiToken(credential);
}
