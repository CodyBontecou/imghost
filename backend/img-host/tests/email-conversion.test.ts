import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { DatabaseSync } from 'node:sqlite';
import { readFileSync, readdirSync } from 'node:fs';
import { Auth } from '../src/auth';
import { AppleAuth } from '../src/apple-auth';
import { Database } from '../src/database';
import worker, { type Env } from '../src/index';

// Real production migration/SQL execution, not SQL matching or mocked invariants.
class SQLiteD1 {
  sql = new DatabaseSync(':memory:');
  failBatchAt = -1;
  constructor() {
    this.sql.exec('PRAGMA foreign_keys = ON');
    for (const file of readdirSync('migrations').filter(f => f.endsWith('.sql')).sort()) {
      this.sql.exec(readFileSync(`migrations/${file}`, 'utf8'));
    }
  }
  prepare(query: string) {
    const stmt = this.sql.prepare(query);
    let args: any[] = [];
    const prepared = {
      bind: (...values: any[]) => { args = values; return prepared; },
      first: async () => stmt.get(...args) || null,
      all: async () => ({ success: true, results: stmt.all(...args) }),
      run: async () => {
        const result = stmt.run(...args);
        return { success: true, results: [], meta: { changes: Number(result.changes) } };
      },
    };
    return prepared;
  }
  async batch(statements: any[]) {
    this.sql.exec('BEGIN');
    try {
      const results = [];
      for (let i = 0; i < statements.length; i++) {
        if (this.failBatchAt === i) throw new Error('Synthetic transaction failure');
        results.push(await statements[i].run());
      }
      this.sql.exec('COMMIT');
      return results;
    } catch (error) { this.sql.exec('ROLLBACK'); throw error; }
  }
}

const NOW = 1800000000000;
const SOURCE = 'original@privaterelay.appleid.com';
const DESTINATION = 'new@example.test';
const PASSWORD = 'my private password 123';
let pair: CryptoKeyPair;
let publicKey: any;
function b64url(value: string | Uint8Array): string {
  return (typeof value === 'string' ? btoa(value) : btoa(String.fromCharCode(...value)))
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, '');
}
async function appleToken(nonce: string, overrides: Record<string, unknown> = {}, header: Record<string, unknown> = {}) {
  const input = `${b64url(JSON.stringify({ alg: 'RS256', kid: 'test-key', ...header }))}.${b64url(JSON.stringify({
    iss: 'https://appleid.apple.com', aud: 'com.codybontecou.imghost', sub: 'apple-owner',
    iat: Math.floor(Date.now() / 1000), exp: Math.floor(Date.now() / 1000) + 600,
    nonce, email: SOURCE, ...overrides,
  }))}`;
  const signature = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', pair.privateKey, new TextEncoder().encode(input));
  return `${input}.${b64url(new Uint8Array(signature))}`;
}

let sqlite: SQLiteD1;
let env: Env;
let db: Database;
let userId: string;
let access: string;
let emails: any[];
let rejectMailSubject: string | undefined;
let rejectMailTo: string | undefined;
let log: ReturnType<typeof vi.spyOn>;
let errorLog: ReturnType<typeof vi.spyOn>;

async function post(step: string, body: unknown = {}, token = access, method = 'POST') {
  return worker.fetch(new Request(`https://worker.test/auth/email-conversion/${step}`, {
    method, headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    ...(method === 'GET' ? {} : { body: JSON.stringify(body) }),
  }), env, {} as ExecutionContext);
}
async function challenge() {
  const response = await post('challenge');
  expect(response.status).toBe(200);
  expect(response.headers.get('Cache-Control')).toBe('no-store');
  return response.json() as Promise<{ challenge_id: string; nonce: string; expires_at: number }>;
}
async function start(c: Awaited<ReturnType<typeof challenge>>, destination = DESTINATION, proof?: string) {
  return post('start', { challenge_id: c.challenge_id, destination_email: destination,
    identity_token: proof ?? await appleToken(c.nonce) });
}
async function prepared() {
  const c = await challenge();
  const response = await start(c);
  expect(response.status).toBe(200);
  const email = emails.findLast(e => e.Content.Simple.Subject.Data === 'imghost login email verification code');
  const code = email.Content.Simple.Body.Text.Data.split('\n\n')[1];
  expect(code.length).toBeGreaterThan(40);
  expect(await response.text()).not.toContain(code);
  return { ...c, code };
}
async function complete(c: { challenge_id: string; code: string }, code = c.code) {
  return post('complete', { challenge_id: c.challenge_id, code, new_password: PASSWORD });
}
function snapshot() {
  return {
    users: sqlite.sql.prepare('SELECT * FROM users ORDER BY id').all(),
    images: sqlite.sql.prepare('SELECT * FROM images ORDER BY id').all(),
    subscriptions: sqlite.sql.prepare('SELECT * FROM subscriptions ORDER BY id').all(),
    storage: sqlite.sql.prepare('SELECT * FROM storage_usage ORDER BY user_id').all(),
    refresh: sqlite.sql.prepare('SELECT * FROM refresh_tokens ORDER BY id').all(),
  };
}
async function assertUntouched(before: ReturnType<typeof snapshot>) {
  expect(snapshot()).toEqual(before);
  expect(sqlite.sql.prepare('SELECT * FROM email_conversion_events').all()).toEqual([]);
}

beforeAll(async () => {
  pair = await crypto.subtle.generateKey({ name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048,
    publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' }, true, ['sign', 'verify']);
  publicKey = { ...await crypto.subtle.exportKey('jwk', pair.publicKey), kid: 'test-key', alg: 'RS256', use: 'sig' };
});
beforeEach(async () => {
  vi.spyOn(Date, 'now').mockReturnValue(NOW);
  vi.spyOn(AppleAuth, 'getApplePublicKeys').mockResolvedValue([publicKey]);
  log = vi.spyOn(console, 'log').mockImplementation(() => {});
  errorLog = vi.spyOn(console, 'error').mockImplementation(() => {});
  sqlite = new SQLiteD1();
  env = { DB: sqlite as unknown as D1Database, JWT_SECRET: 'test-secret-not-production',
    EMAIL_CONVERSION_ENABLED: 'true', EMAIL_FROM: 'sender@example.test',
    AWS_ACCESS_KEY_ID: 'test-access', AWS_SECRET_ACCESS_KEY: 'test-secret',
  } as Env;
  db = new Database(env.DB);
  const user = await db.createAppleUser(SOURCE, 'apple-owner', 'enterprise');
  userId = user.id;
  await db.createAppleSubscription(userId, 'enterprise', 'active', 'original-transaction', 'product-id', NOW + 999999);
  sqlite.sql.prepare(`UPDATE subscriptions SET stripe_customer_id = 'stripe-customer',
    stripe_subscription_id = 'stripe-sub', cancel_at_period_end = 1, trial_ends_at = ? WHERE user_id = ?`)
    .run(NOW + 200000, userId);
  await db.createImage(userId, 'library/photo.png', 'photo.png', 300, 'image/png', 'unchanged-delete-token');
  await db.createImage(userId, 'library/video.mov', 'video.mov', 700, 'video/quicktime', 'second-delete-token', NOW + 500000);
  await db.createRefreshToken(userId, 'old-refresh', 999999);
  await db.setPasswordResetToken(userId, 'old-reset', 999999);
  await db.setEmailVerificationToken(userId, 'old-verification', 999999);
  access = await Auth.createJWT({ sub: userId, email: SOURCE, tier: 'enterprise', type: 'access' }, 3600, env.JWT_SECRET);
  emails = [];
  rejectMailSubject = undefined;
  rejectMailTo = undefined;
  vi.stubGlobal('fetch', vi.fn(async (_url, init) => {
    const email = JSON.parse(init.body);
    emails.push(email);
    if (email.Content.Simple.Subject.Data === rejectMailSubject || email.Destination.ToAddresses[0] === rejectMailTo) {
      return new Response(`sensitive provider response ${SOURCE} code secret`, { status: 500 });
    }
    return new Response('{}', { status: 200 });
  }));
});
afterEach(() => {
  sqlite?.sql.close();
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

describe('gated same-account email conversion through real Worker routes', () => {
  it('is off by default, POST-only and requires a configured secret and access JWT, not API/refresh tokens', async () => {
    env.EMAIL_CONVERSION_ENABLED = undefined;
    expect((await post('challenge')).status).toBe(404);
    env.EMAIL_CONVERSION_ENABLED = 'true';
    expect((await post('challenge', {}, access, 'GET')).status).toBe(404);
    expect((await post('unknown')).status).toBe(404);
    expect((await post('challenge', {}, (await db.getUserById(userId))!.api_token)).status).toBe(401);
    const refreshJwt = await Auth.createJWT({ sub: userId, email: SOURCE, tier: 'enterprise', type: 'refresh' }, 3600, env.JWT_SECRET);
    expect((await post('challenge', {}, refreshJwt)).status).toBe(401);
    env.JWT_SECRET = '';
    expect((await post('challenge')).status).toBe(503);
    expect(emails).toHaveLength(0);
  });

  it('rejects email-only and anonymous source accounts', async () => {
    sqlite.sql.prepare('UPDATE users SET apple_user_id = NULL WHERE id = ?').run(userId);
    expect((await post('challenge')).status).toBe(403);
    sqlite.sql.prepare('UPDATE users SET apple_user_id = ?, is_anonymous = 1 WHERE id = ?').run('apple-owner', userId);
    expect((await post('challenge')).status).toBe(403);
  });

  it('requires an independent email code and preserves the entire library, quota and renewal relationship', async () => {
    const before = snapshot();
    const c = await prepared();
    await assertUntouched(before);
    expect(sqlite.sql.prepare('SELECT email_token_hash FROM email_conversion_challenges').get()!.email_token_hash).not.toBe(c.code);
    expect((await complete(c, 'email-or-payment-claim-is-not-proof')).status).toBe(400);
    await assertUntouched(before);
    const response = await complete(c, `  \n${c.code}\n `);
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ user_id: userId, email: DESTINATION, apple_access_retained: true,
      email_verified: true, notification_pending: false });
    const after = snapshot();
    expect(after.images).toEqual(before.images);
    expect(after.subscriptions).toEqual(before.subscriptions);
    expect(after.storage).toEqual(before.storage);
    const original = before.users[0] as any;
    const updated = await db.getUserById(userId);
    expect(updated).toEqual({ ...original, email: DESTINATION, password_hash: updated!.password_hash, email_verified: 1,
      password_reset_token: null, password_reset_token_expires: null, email_verification_token: null, email_verification_token_expires: null });
    expect(await Auth.verifyPassword(PASSWORD, updated!.password_hash)).toBe(true);
    expect(await db.getRefreshToken('old-refresh')).toBeNull();
    expect(await db.getUserByApiToken(original.api_token)).toMatchObject({ id: userId });
    // Existing access JWT stays valid by documented policy; /user resolves current database email.
    const getUser = await worker.fetch(new Request('https://worker.test/user', { headers: { Authorization: `Bearer ${access}` } }), env, {} as ExecutionContext);
    expect(getUser.status).toBe(200);
    expect(await getUser.json()).toMatchObject({ user_id: userId, email: DESTINATION });
    const login = await worker.fetch(new Request('https://worker.test/auth/login', { method: 'POST',
      headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ email: DESTINATION, password: PASSWORD }) }), env, {} as ExecutionContext);
    expect(login.status).toBe(200);
    expect(await login.json()).toMatchObject({ user_id: userId, email: DESTINATION, api_token: original.api_token });
    const apple = await worker.fetch(new Request('https://worker.test/auth/apple', { method: 'POST',
      headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ identity_token: await appleToken('normal-login'), user_identifier: 'apple-owner' }) }), env, {} as ExecutionContext);
    expect(apple.status).toBe(200);
    expect(await apple.json()).toMatchObject({ user_id: userId, email: DESTINATION });
    expect(emails.map(e => e.Destination.ToAddresses[0])).toEqual([SOURCE, DESTINATION, SOURCE, DESTINATION]);
    expect(sqlite.sql.prepare('SELECT * FROM email_conversion_events').get()).toMatchObject({ user_id: userId, notification_pending: 0 });
    expect(JSON.stringify([...log.mock.calls, ...errorLog.mock.calls])).not.toContain(c.code);
  });

  it.each([
    ['wrong nonce', { nonce: 'saved-nonce' }],
    ['wrong source subject', { sub: 'different-apple-owner' }],
    ['wrong issuer', { iss: 'https://attacker.test' }],
    ['wrong audience', { aud: 'unrelated.app' }],
    ['expired at boundary', { exp: NOW / 1000 }],
    ['old saved token', { iat: NOW / 1000 - 301 }],
    ['future issued token', { iat: NOW / 1000 + 31 }],
    ['missing expiry', { exp: undefined }],
    ['missing issued time', { iat: undefined }],
  ])('rejects signed Apple proof: %s', async (_name, overrides) => {
    const c = await challenge();
    const before = snapshot();
    expect((await start(c, DESTINATION, await appleToken(c.nonce, overrides))).status).toBe(401);
    await assertUntouched(before);
    expect(emails).toHaveLength(0);
  });

  it('verifies signatures, declared algorithm, token structure and both supported audiences', async () => {
    const c = await challenge();
    const signed = await appleToken(c.nonce);
    expect((await start(c, DESTINATION, `${signed}extra`)).status).toBe(401);
    expect((await start(c, DESTINATION, `${signed}.extra`)).status).toBe(401);
    expect((await start(c, DESTINATION, await appleToken(c.nonce, {}, { alg: 'none' }))).status).toBe(401);
    expect((await start(c, DESTINATION, await appleToken(c.nonce, { aud: 'com.codybontecou.imghost.mac' }))).status).toBe(200);
  });

  it('binds challenge and code to the authenticated account, not email input', async () => {
    const c = await prepared();
    const other = await db.createAppleUser('other@example.test', 'other-apple-owner');
    const otherAccess = await Auth.createJWT({ sub: other.id, email: other.email, tier: 'free', type: 'access' }, 3600, env.JWT_SECRET);
    const before = snapshot();
    expect((await post('complete', { ...c, new_password: PASSWORD }, otherAccess)).status).toBe(400);
    await assertUntouched(before);
  });

  it('rejects conflicting destination accounts case-insensitively without merging', async () => {
    await db.createUser('NEW@EXAMPLE.TEST', 'unrelated-password', 'unrelated-api');
    const before = snapshot();
    expect((await start(await challenge())).status).toBe(409);
    expect(emails).toHaveLength(0);
    await assertUntouched(before);
  });

  it('rechecks a conflicting account created after email verification', async () => {
    const c = await prepared();
    await db.createUser('NEW@EXAMPLE.TEST', 'unrelated-password', 'unrelated-api');
    const before = snapshot();
    expect((await complete(c)).status).toBe(409);
    await assertUntouched(before);
  });

  it.each(['source', 'email'])('rejects expiry exactly at the %s challenge boundary', async phase => {
    const c = phase === 'source' ? await challenge() : await prepared();
    const before = snapshot();
    vi.mocked(Date.now).mockReturnValue(NOW + (phase === 'source' ? 5 : 10) * 60000);
    expect((await (phase === 'source' ? start(c) : complete(c as any))).status).toBe(400);
    await assertUntouched(before);
  });

  it('rechecks expiry after password hashing', async () => {
    const c = await prepared();
    const before = snapshot();
    const realHash = Auth.hashPassword.bind(Auth);
    vi.spyOn(Auth, 'hashPassword').mockImplementation(async password => {
      const hash = await realHash(password);
      vi.mocked(Date.now).mockReturnValue(NOW + 10 * 60000);
      return hash;
    });
    expect((await complete(c)).status).toBe(409);
    await assertUntouched(before);
  });

  it('rechecks proof replacement during hashing and makes an old emailed code unusable', async () => {
    const c = await prepared();
    const before = snapshot();
    const realHash = Auth.hashPassword.bind(Auth);
    vi.spyOn(Auth, 'hashPassword').mockImplementation(async password => {
      const hash = await realHash(password);
      await challenge();
      return hash;
    });
    expect((await complete(c)).status).toBe(409);
    await assertUntouched(before);
  });

  it.each(['email', 'password_hash', 'apple_user_id'])('rejects source credential drift (%s)', async column => {
    const c = await prepared();
    sqlite.sql.prepare(`UPDATE users SET ${column} = ? WHERE id = ?`).run('changed', userId);
    const before = snapshot();
    expect((await complete(c)).status).toBe(400);
    await assertUntouched(before);
  });

  it('does not accept reset/verification codes for this purpose or conversion codes for reset', async () => {
    const c = await prepared();
    const before = snapshot();
    expect((await complete(c, 'old-reset')).status).toBe(400);
    expect((await complete(c, 'old-verification')).status).toBe(400);
    expect(await db.getUserByPasswordResetToken(c.code)).toBeNull();
    expect(await db.getUserByVerificationToken(c.code)).toBeNull();
    await assertUntouched(before);
  });

  it('consumes a fresh source proof once and rejects replaced source challenges', async () => {
    const old = await challenge();
    const c = await challenge();
    expect((await start(old)).status).toBe(400);
    expect((await start(c)).status).toBe(200);
    expect((await start(c)).status).toBe(400);
  });

  it('allows only one concurrent completion and rejects replay without further revocation', async () => {
    const c = await prepared();
    // SQLite batch adapter transactions cannot overlap on one connection; serialize batch calls
    // as D1 does while retaining concurrent reads and PBKDF2 computations in the handlers.
    const batch = sqlite.batch.bind(sqlite);
    let tail = Promise.resolve();
    sqlite.batch = statements => {
      const result = tail.then(() => batch(statements));
      tail = result.then(() => undefined, () => undefined);
      return result;
    };
    const responses = await Promise.all([complete(c), complete(c)]);
    expect(responses.map(r => r.status).sort()).toEqual([200, 409]);
    expect(sqlite.sql.prepare('SELECT * FROM email_conversion_events').all()).toHaveLength(1);
    await db.createRefreshToken(userId, 'new-login-refresh', 999999);
    expect((await complete(c)).status).toBe(400);
    expect(await db.getRefreshToken('new-login-refresh')).not.toBeNull();
  });

  it('rolls back credential changes, challenge consumption and revocation if any batch step fails; retry succeeds', async () => {
    const c = await prepared();
    const before = snapshot();
    sqlite.failBatchAt = 3;
    expect((await complete(c)).status).toBe(503);
    await assertUntouched(before);
    expect(sqlite.sql.prepare('SELECT phase FROM email_conversion_challenges').get()!.phase).toBe('email');
    sqlite.failBatchAt = -1;
    expect((await complete(c)).status).toBe(200);
  });

  it.each([SOURCE, DESTINATION])('fails closed on mail rejection to %s, without secret logs or changes', async address => {
    const c = await challenge();
    rejectMailTo = address;
    const before = snapshot();
    expect((await start(c)).status).toBe(503);
    await assertUntouched(before);
    expect(sqlite.sql.prepare('SELECT phase FROM email_conversion_challenges').get()!.phase).toBe('source');
    const logs = JSON.stringify([...log.mock.calls, ...errorLog.mock.calls]);
    expect(logs).not.toContain(SOURCE);
    expect(logs).not.toContain('sensitive provider');
  });

  it('never treats missing SES credentials as delivery', async () => {
    const c = await challenge();
    const before = snapshot();
    env.AWS_ACCESS_KEY_ID = undefined;
    expect((await start(c)).status).toBe(503);
    expect(emails).toHaveLength(0);
    await assertUntouched(before);
  });

  it('reports committed success if confirmation delivery fails and records notification retry need', async () => {
    const c = await prepared();
    rejectMailSubject = 'imghost login email changed';
    const response = await complete(c);
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ notification_pending: true, email: DESTINATION });
    expect(await db.getUserById(userId)).toMatchObject({ email: DESTINATION, apple_user_id: 'apple-owner' });
    expect(sqlite.sql.prepare('SELECT notification_pending FROM email_conversion_events').get()!.notification_pending).toBe(1);
    const logs = JSON.stringify([...log.mock.calls, ...errorLog.mock.calls]);
    expect(logs).not.toContain(c.code);
    expect(logs).not.toContain(PASSWORD);
    expect(logs).not.toContain(SOURCE);
  });

  it('validates input without consuming a usable challenge', async () => {
    const c = await prepared();
    const before = snapshot();
    for (const new_password of ['', 'short', 123, 'x'.repeat(1025)]) {
      expect((await post('complete', { challenge_id: c.challenge_id, code: c.code, new_password })).status).toBe(400);
    }
    for (const body of [null, [], 'string', {}]) expect((await post('complete', body)).status).toBe(400);
    await assertUntouched(before);
    expect((await complete(c)).status).toBe(200);
  });

  it('a refresh read before conversion cannot mint a session after conversion revocation', async () => {
    const c = await prepared();
    const createJWT = Auth.createJWT.bind(Auth);
    vi.spyOn(Auth, 'createJWT').mockImplementation(async (...args) => {
      const token = await createJWT(...args);
      expect((await complete(c)).status).toBe(200);
      return token;
    });
    const refresh = await worker.fetch(new Request('https://worker.test/auth/refresh', { method: 'POST',
      headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ refresh_token: 'old-refresh' }) }), env, {} as ExecutionContext);
    expect(refresh.status).toBe(401);
    expect(sqlite.sql.prepare('SELECT * FROM refresh_tokens WHERE revoked = 0').all()).toEqual([]);
  });

  it('normal refresh retains response compatibility but consumes once and rolls back on failure', async () => {
    const request = () => new Request('https://worker.test/auth/refresh', { method: 'POST',
      headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ refresh_token: 'old-refresh' }) });
    sqlite.failBatchAt = 1;
    expect((await worker.fetch(request(), env, {} as ExecutionContext)).status).toBe(400);
    expect(await db.getRefreshToken('old-refresh')).not.toBeNull();
    sqlite.failBatchAt = -1;
    const response = await worker.fetch(request(), env, {} as ExecutionContext);
    expect(response.status).toBe(200);
    const body = await response.json() as any;
    expect(body).toMatchObject({ user_id: userId, email: SOURCE, token_type: 'Bearer', expires_in: 3600 });
    expect(await db.getRefreshToken(body.refresh_token)).not.toBeNull();
    expect((await worker.fetch(request(), env, {} as ExecutionContext)).status).toBe(401);
    expect(await db.rotateRefreshToken('old-refresh', userId, 'forbidden-replay', 1000)).toBe(false);
    expect(await db.getRefreshToken('forbidden-replay')).toBeNull();
  });

  it('limits repeated account challenge creation', async () => {
    for (let i = 0; i < 10; i++) expect((await post('challenge')).status).toBe(200);
    expect((await post('challenge')).status).toBe(429);
  });
});
