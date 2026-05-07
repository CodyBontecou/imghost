import { describe, expect, it, vi } from 'vitest';
import worker, { ANONYMOUS_UPLOAD_ERROR, isAnonymousFreeTierUser } from '../src/index';

function createMockD1(user: Record<string, unknown> | null) {
  return {
    prepare(query: string) {
      const normalized = query.toLowerCase();
      return {
        bind: (..._params: unknown[]) => ({
          first: async () => {
            if (normalized.includes('from users') && normalized.includes('api_token')) {
              return user;
            }
            return null;
          },
          all: async () => ({ results: [] }),
          run: async () => ({ success: true }),
        }),
      };
    },
  };
}

function createMockEnv(user: Record<string, unknown> | null) {
  return {
    DB: createMockD1(user),
    IMAGES: {
      get: vi.fn(),
      put: vi.fn(),
      delete: vi.fn(),
    },
    UPLOAD_TOKEN: 'legacy-token',
    JWT_SECRET: 'test-secret',
  };
}

describe('anonymous upload gating', () => {
  it('identifies only anonymous free-tier users for the anonymous upload block', () => {
    expect(isAnonymousFreeTierUser({ is_anonymous: 1, subscription_tier: 'free' })).toBe(true);
    expect(isAnonymousFreeTierUser({ is_anonymous: 0, subscription_tier: 'free' })).toBe(false);
    expect(isAnonymousFreeTierUser({ is_anonymous: 1, subscription_tier: 'trial' })).toBe(false);
    expect(isAnonymousFreeTierUser({ is_anonymous: 1, subscription_tier: 'pro' })).toBe(false);
  });

  it('rejects anonymous free-tier uploads before storing files', async () => {
    const anonymousFreeUser = {
      id: 'anon-user',
      email: 'anonymous+anon-user@imghost.local',
      password_hash: 'ANONYMOUS_DEVICE_ACCOUNT',
      created_at: Date.now(),
      subscription_tier: 'free',
      api_token: 'anon-token',
      storage_limit_bytes: 1_000_000_000,
      email_verified: 1,
      is_anonymous: 1,
    };
    const env = createMockEnv(anonymousFreeUser);
    const request = new Request('https://imghost.isolated.tech/upload', {
      method: 'POST',
      headers: { 'X-API-Key': 'anon-token' },
    });

    const response = await worker.fetch(request, env as any, {} as ExecutionContext);
    const body = await response.json() as Record<string, unknown>;

    expect(response.status).toBe(403);
    expect(body).toEqual({
      error: ANONYMOUS_UPLOAD_ERROR,
      account_required: true,
      upgrade_required: true,
    });
    expect(env.IMAGES.put).not.toHaveBeenCalled();
  });
});
