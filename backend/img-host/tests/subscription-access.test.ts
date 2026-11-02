import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { Database, type Subscription, type User } from '../src/database';
import { checkSubscriptionAccess, handleSubscriptionStatus } from '../src/subscription-handlers';
import worker from '../src/index';

const now = Date.now();
const user: User = {
  id: 'user', email: 'user@example.com', password_hash: '', created_at: now,
  subscription_tier: 'pro', api_token: 'test-key', storage_limit_bytes: 10_000_000_000,
  email_verified: 1, is_anonymous: 0,
};
const subscription: Subscription = {
  id: 'subscription', user_id: user.id, tier: 'pro', status: 'active',
  current_period_end: now + 86_400_000, cancel_at_period_end: false,
  created_at: now, updated_at: now,
};
const db = new Database({} as D1Database);
const env = {
  DB: {} as D1Database, JWT_SECRET: 'test-secret', UPLOAD_TOKEN: 'legacy-token',
  IMAGES: { put: vi.fn(), get: vi.fn(), delete: vi.fn() },
};
beforeEach(() => {
  vi.spyOn(Database.prototype, 'getUserById').mockResolvedValue(user);
  vi.spyOn(Database.prototype, 'getUserByApiToken').mockResolvedValue(user);
  vi.spyOn(Database.prototype, 'getSubscriptionByUserId').mockResolvedValue(subscription);
  vi.spyOn(Database.prototype, 'getStorageUsage').mockResolvedValue({
    user_id: user.id, image_count: 0, total_bytes_used: 0,
  });
  vi.spyOn(Database.prototype, 'updateSubscriptionTierAndStatus').mockResolvedValue();
});
afterEach(() => vi.restoreAllMocks());

describe('hard paywall', () => {
  it.each([0, 1])('denies active legacy free subscriptions (anonymous=%s)', async (is_anonymous) => {
    vi.mocked(db.getUserById).mockResolvedValue({ ...user, subscription_tier: 'free', is_anonymous });
    vi.mocked(db.getSubscriptionByUserId).mockResolvedValue({ ...subscription, tier: 'free' });
    expect((await checkSubscriptionAccess(user.id, db)).hasAccess).toBe(false);
  });
  it('denies accounts without a subscription record', async () => {
    vi.mocked(db.getSubscriptionByUserId).mockResolvedValue(null);
    expect((await checkSubscriptionAccess(user.id, db)).hasAccess).toBe(false);
  });
  it.each(['pro', 'enterprise', 'ultimate'] as const)('allows current %s subscriptions', async (tier) => {
    vi.mocked(db.getSubscriptionByUserId).mockResolvedValue({ ...subscription, tier });
    expect((await checkSubscriptionAccess(user.id, db)).hasAccess).toBe(true);
  });
  it.each([
    { status: 'trialing', trial_ends_at: now + 86_400_000 },
    { cancel_at_period_end: true },
  ] as const)('allows current trials and cancelled renewal: %j', async (overrides) => {
    vi.mocked(db.getSubscriptionByUserId).mockResolvedValue({ ...subscription, ...overrides });
    expect((await checkSubscriptionAccess(user.id, db)).hasAccess).toBe(true);
  });
  it.each([
    { current_period_end: now - 1 },
    { current_period_end: undefined },
    { status: 'trialing', current_period_end: undefined, trial_ends_at: undefined },
    { status: 'trialing', trial_ends_at: now - 1 },
    { status: 'expired' }, { status: 'past_due' },
    { status: 'cancelled', current_period_end: now - 1 },
  ] as const)('denies invalid subscriptions: %j', async (overrides) => {
    vi.mocked(db.getSubscriptionByUserId).mockResolvedValue({ ...subscription, ...overrides });
    expect((await checkSubscriptionAccess(user.id, db)).hasAccess).toBe(false);
  });
  it('reports no access for legacy free subscriptions', async () => {
    vi.mocked(db.getSubscriptionByUserId).mockResolvedValue({ ...subscription, tier: 'free' });
    const response = await handleSubscriptionStatus(new Request('https://example.com/subscription/status', {
      headers: { 'X-API-Key': 'test-key' },
    }), env);
    expect(await response.json()).toMatchObject({ has_access: false, will_renew: false });
  });
  it.each(['/upload', '/api/export'])('blocks unpaid requests to %s before processing files', async (path) => {
    vi.mocked(db.getSubscriptionByUserId).mockResolvedValue({ ...subscription, tier: 'free' });
    const response = await worker.fetch(new Request(`https://example.com${path}`, {
      method: 'POST', headers: { 'X-API-Key': 'test-key' },
    }), env as any, {} as ExecutionContext);
    expect(response.status).toBe(403);
    expect(await response.json()).toMatchObject({ subscription_required: true });
    expect(env.IMAGES.put).not.toHaveBeenCalled();
  });
});
