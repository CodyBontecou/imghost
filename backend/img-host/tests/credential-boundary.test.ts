import { afterEach, beforeAll, beforeEach, describe, expect, it as registerTest, vi } from 'vitest';
import { AsyncLocalStorage } from 'node:async_hooks';
import { DatabaseSync } from 'node:sqlite';
import { readFileSync, readdirSync } from 'node:fs';
import { Auth } from '../src/auth';
import { AppleAuth } from '../src/apple-auth';
import { Database } from '../src/database';
import worker, { type Env } from '../src/index';

// Registered source-preparation controls, NOT RUN at authoring time. Real production
// SQL and Worker handlers; serialized SQLite transactions model, not prove, live D1.
interface Barrier {
  fixture: FixtureOwner;
  label: string;
  reached: Promise<void>;
  release: () => void;
  wait: () => Promise<void>;
}
function barrier(label: string): Barrier {
  const fixture = ownedFixture();
  if (fixture.phase !== 'active') throw new Error('Cannot create a gate during fixture teardown');
  let entered!: () => void;
  let release!: () => void;
  const reached = new Promise<void>(resolve => { entered = resolve; });
  const released = new Promise<void>(resolve => { release = resolve; });
  const gate: Barrier = { fixture, label, reached, release, wait: async () => {
    if (fixture.phase === 'closed') throw new Error('A closed fixture cannot enter a gate');
    entered(); // Only the ACTUAL wrapped operation enters; release never fakes entry.
    await released;
  } };
  fixture.gates.add(gate);
  return gate;
}
type Write = { query: string; values: any[]; changes?: number };
type RequestSettlement = PromiseSettledResult<Response>;
interface FixtureOwner {
  task: unknown;
  phase: 'active' | 'closing' | 'closed';
  gates: Set<Barrier>;
  requests: Map<Promise<Response>, Promise<RequestSettlement>>;
  auxiliary: Set<Promise<PromiseSettledResult<unknown>>>;
  sqlite?: SQLiteD1;
  env?: Env;
  db?: Database;
  access?: string;
  userId?: string;
  otherId?: string;
  mails: Array<{ to: string; subject: string; text: string }>;
  mailGate?: { subject: string; gate: Barrier };
  sensitiveCodes: Set<string>;
  baseline?: ReturnType<typeof preservedData>;
  initialized: boolean;
  setupSettlement?: Promise<PromiseSettledResult<void>>;
  teardown?: Promise<void>;
}
let fixtureOwner: FixtureOwner | undefined;
const testBodyOwner = new AsyncLocalStorage<FixtureOwner>();
function checkBodyOwner(fixture: FixtureOwner) {
  if (testBodyOwner.getStore() !== fixture || fixture.phase !== 'active' || fixtureOwner !== fixture) {
    throw new Error('Test body no longer owns an active credential-boundary fixture');
  }
}
function ownedFixture(): FixtureOwner {
  // Never fall back to the currently global hook owner. An old continuation keeps
  // its immutable async-local owner and fails rather than adopting a later case.
  const fixture = testBodyOwner.getStore();
  if (!fixture) throw new Error('Credential-boundary helper requires a test-body owner');
  checkBodyOwner(fixture);
  return fixture;
}
function trackAuxiliary<T>(fixture: FixtureOwner, operation: Promise<T>): Promise<T> {
  checkBodyOwner(fixture);
  fixture.auxiliary.add(operation.then<PromiseSettledResult<unknown>, PromiseSettledResult<unknown>>(
    value => ({ status: 'fulfilled', value }), reason => ({ status: 'rejected', reason })
  ));
  return operation; // Observe and drain, never replace the real result or rejection.
}
function ownedAuth() {
  const fixture = ownedFixture();
  return {
    verifyPassword: (...args: Parameters<typeof Auth.verifyPassword>) => {
      checkBodyOwner(fixture); // Check a captured facade again BEFORE touching shared Auth seams.
      return trackAuxiliary(fixture, Auth.verifyPassword(...args));
    },
  };
}
function guardedResource<T extends object>(fixture: FixtureOwner, target: T): T {
  return new Proxy(target, {
    get(resource, key) {
      checkBodyOwner(fixture);
      const value = Reflect.get(resource, key, resource);
      if (typeof value !== 'function') return value;
      return (...args: any[]) => {
        checkBodyOwner(fixture); // Also guard a method captured before an await.
        const result = Reflect.apply(value, resource, args);
        return result instanceof Promise ? trackAuxiliary(fixture, result) : result;
      };
    },
  });
}
function bodyFixture() {
  const fixture = ownedFixture();
  return Object.freeze({
    sqlite: guardedResource(fixture, fixture.sqlite!),
    db: guardedResource(fixture, fixture.db!),
    userId: fixture.userId!, otherId: fixture.otherId!,
    mails: fixture.mails, sensitiveCodes: fixture.sensitiveCodes, baseline: fixture.baseline!,
  });
}
type BodyFixture = ReturnType<typeof bodyFixture>;
function it(name: string, body: (fixture: BodyFixture) => Promise<void>) {
  // Same 25 individual Vitest registrations/names; only bind their async ownership.
  return registerTest(name, context => {
    const fixture = fixtureOwner;
    if (!fixture || fixture.task !== context.task || fixture.phase !== 'active' || !fixture.initialized) {
      throw new Error('Test callback does not own its completed setup fixture');
    }
    return testBodyOwner.run(fixture, () => body(bodyFixture()));
  });
}
async function waitForEntry(gate: Barrier, operation: Promise<Response>) {
  if (gate.fixture !== ownedFixture() || !gate.fixture.requests.has(operation)) {
    throw new Error('Gate and handler must belong to the same fixture');
  }
  await Promise.race([
    gate.reached,
    operation.then(response => {
      throw new Error(`Expected actual ${gate.label} gate entry; handler completed first with HTTP ${response.status}`);
    }, cause => {
      throw new Error(`Expected actual ${gate.label} gate entry; handler rejected first`, { cause });
    }),
  ]);
}
async function releaseAndSettle(fixture: FixtureOwner): Promise<PromiseSettledResult<unknown>[]> {
  for (const gate of fixture.gates) gate.release();
  // No retries, sleeps, synthetic responses or fake counts: await the owned REAL requests.
  // Closing forbids new API/test-resource/verification registrations, so these sets are fixed.
  // Setup is owned too: even a framework hook timeout must not close underneath
  // its real hash/DB work. A setup rejection still fails the original beforeEach.
  await fixture.setupSettlement;
  return Promise.all([...fixture.requests.values(), ...fixture.auxiliary]);
}

class SQLiteD1 {
  sql = new DatabaseSync(':memory:');
  writes: Write[] = [];
  private execute = new WeakMap<object, () => any>();
  private heldRun?: { gate: Barrier; matches: (query: string) => boolean };
  constructor() {
    try {
      this.sql.exec('PRAGMA foreign_keys = ON');
      // Preserve the established repaired-schema fixture chronology, not deployed parity.
      const repair = '0011_fix_rate_limits_schema.sql';
      for (const file of readdirSync('migrations').filter(f => f.endsWith('.sql') && f !== repair).sort()) {
        if (file === '0004_rate_limiting.sql') this.sql.exec(readFileSync(`migrations/${repair}`, 'utf8'));
        this.sql.exec(readFileSync(`migrations/${file}`, 'utf8'));
      }
    } catch (error) {
      this.sql.close(); // Failed construction cannot leak an unowned connection.
      throw error;
    }
  }
  holdIssuance(gate: Barrier) {
    this.heldRun = { gate, matches: query => query.startsWith('UPDATE users SET password_reset_token =') };
  }
  prepare(query: string) {
    const statement = this.sql.prepare(query);
    const bound = (...values: any[]) => {
      const execute = () => {
        const write: Write = { query, values };
        this.writes.push(write);
        const result = statement.run(...values);
        write.changes = Number(result.changes);
        return { success: true, results: [], meta: { changes: write.changes } };
      };
      const prepared = {
        first: async () => statement.get(...values) || null,
        all: async () => ({ success: true, results: statement.all(...values) }),
        run: async () => {
          const held = this.heldRun;
          if (held?.matches(query)) {
            this.heldRun = undefined;
            await held.gate.wait(); // BEFORE executing the snapshot-bound production write.
          }
          return execute();
        },
      };
      this.execute.set(prepared, execute);
      return prepared;
    };
    return Object.assign(bound(), { bind: bound });
  }
  async batch(statements: object[]) {
    this.sql.exec('BEGIN');
    try {
      // No awaits, barriers, nested handlers or mocked results INSIDE a transaction.
      const results = statements.map(statement => this.execute.get(statement)!());
      this.sql.exec('COMMIT');
      return results;
    } catch (error) {
      this.sql.exec('ROLLBACK');
      throw error;
    }
  }
  issuanceWrites() {
    return this.writes.filter(write => write.query.startsWith('UPDATE users SET password_reset_token ='));
  }
}

const NOW = 1800000000000;
const SOURCE = 'boundary@privaterelay.appleid.com';
const DESTINATION = 'converted@example.test';
const RESET_PASSWORD = 'ResetCredentialPassword123';
const CONVERSION_PASSWORD = 'ConvertedCredentialPassword456';
const CODE_A = `${'A'.repeat(43)}=`;
const GENERIC = { message: 'If an account exists with this email, you will receive password reset instructions.' };
let pair: CryptoKeyPair;
let publicKey: any;

function b64url(value: string | Uint8Array) {
  return (typeof value === 'string' ? btoa(value) : btoa(String.fromCharCode(...value)))
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, '');
}
async function appleToken(nonce: string) {
  const input = `${b64url(JSON.stringify({ alg: 'RS256', kid: 'boundary-key' }))}.${b64url(JSON.stringify({
    iss: 'https://appleid.apple.com', aud: 'com.codybontecou.imghost', sub: 'boundary-apple-owner',
    iat: NOW / 1000, exp: NOW / 1000 + 600, nonce, email: SOURCE,
  }))}`;
  const signature = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', pair.privateKey, new TextEncoder().encode(input));
  return `${input}.${b64url(new Uint8Array(signature))}`;
}
function api(path: string, body: unknown, authenticated = false): Promise<Response> {
  const fixture = ownedFixture();
  if (fixture.phase !== 'active' || !fixture.env) throw new Error('Cannot start a handler during fixture teardown');
  // Capture this fixture's DB/env before dispatch; never rebind a pending request to a later case.
  const operation = worker.fetch(new Request(`https://worker.test${path}`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', 'CF-Connecting-IP': '192.0.2.25',
      ...(authenticated ? { Authorization: `Bearer ${fixture.access}` } : {}) },
    body: JSON.stringify(body),
  }), fixture.env, {} as ExecutionContext);
  // Observe rejection immediately (including before gate entry), without changing the returned promise.
  fixture.requests.set(operation, operation.then<RequestSettlement, RequestSettlement>(
    value => ({ status: 'fulfilled', value }), reason => ({ status: 'rejected', reason })
  ));
  return operation;
}
function forgot(email = SOURCE) { return api('/auth/forgot-password', { email }); }
function reset(code = CODE_A) { return api('/auth/reset-password', { token: code, new_password: RESET_PASSWORD }); }
function refresh() { return api('/auth/refresh', { refresh_token: 'source-refresh' }); }
type Proof = { challenge_id: string; code: string };
function complete(proof: Proof) {
  return api('/auth/email-conversion/complete', { ...proof, new_password: CONVERSION_PASSWORD }, true);
}
async function prepareConversion(): Promise<Proof> {
  const { mails, sensitiveCodes } = bodyFixture();
  const challenge = await api('/auth/email-conversion/challenge', {}, true);
  expect(challenge.status).toBe(200);
  const c = await challenge.json() as { challenge_id: string; nonce: string };
  const start = await api('/auth/email-conversion/start', { challenge_id: c.challenge_id,
    destination_email: DESTINATION, identity_token: await appleToken(c.nonce) }, true);
  expect(start.status).toBe(200);
  ownedFixture();
  const text = mails.findLast(mail => mail.subject === 'imghost login email verification code')!.text;
  const code = text.split('\n\n')[1];
  sensitiveCodes.add(code);
  expect(code.length).toBeGreaterThan(40);
  expect(await start.text()).not.toContain(code);
  const proof = { challenge_id: c.challenge_id, code };
  const before = state();
  expect((await reset(code)).status).toBe(400);
  expect((await api('/auth/email-conversion/complete', { challenge_id: c.challenge_id,
    code: CODE_A, new_password: CONVERSION_PASSWORD }, true)).status).toBe(400);
  expect(state()).toEqual(before); // Independent reset/conversion purposes cannot authorize each other.
  return proof;
}
function checkReadableFixture(fixture: FixtureOwner) {
  const caller = testBodyOwner.getStore();
  if (caller) {
    if (caller !== fixture) throw new Error('Test body cannot read another fixture');
    checkBodyOwner(fixture);
  } else if (fixtureOwner !== fixture || fixture.phase === 'closed') {
    throw new Error('Hook cannot read an unowned or closed fixture');
  }
}
function currentUser(fixture = ownedFixture()) {
  checkReadableFixture(fixture);
  return fixture.sqlite!.sql.prepare('SELECT * FROM users WHERE id = ?').get(fixture.userId!)!;
}
function refreshRows(fixture = ownedFixture()) {
  checkReadableFixture(fixture);
  return fixture.sqlite!.sql.prepare('SELECT * FROM refresh_tokens ORDER BY id').all();
}
function preservedData(fixture = ownedFixture()) {
  checkReadableFixture(fixture);
  const sql = fixture.sqlite!.sql;
  const { email, password_hash, email_verified, email_verification_token, email_verification_token_expires,
    password_reset_token, password_reset_token_expires, ...account } = currentUser(fixture);
  return {
    account,
    other: sql.prepare('SELECT * FROM users WHERE id = ?').get(fixture.otherId!),
    otherRefresh: sql.prepare('SELECT * FROM refresh_tokens WHERE user_id = ? ORDER BY id').all(fixture.otherId!),
    images: sql.prepare('SELECT * FROM images ORDER BY id').all(),
    storage: sql.prepare('SELECT * FROM storage_usage ORDER BY user_id').all(),
    subscriptions: sql.prepare('SELECT * FROM subscriptions ORDER BY id').all(),
  };
}
function state(fixture = ownedFixture()) {
  checkReadableFixture(fixture);
  return { user: currentUser(fixture), refresh: refreshRows(fixture), data: preservedData(fixture),
    challenges: fixture.sqlite!.sql.prepare('SELECT * FROM email_conversion_challenges ORDER BY id').all(),
    events: fixture.sqlite!.sql.prepare('SELECT * FROM email_conversion_events ORDER BY id').all() };
}
function assertPreserved(fixture = ownedFixture()) { expect(preservedData(fixture)).toEqual(fixture.baseline); }
function mailCode() {
  const { mails, sensitiveCodes } = bodyFixture();
  const code = mails.findLast(mail => mail.subject === 'Your imghost password reset code')!.text.split('\n\n')[1];
  expect(code).toMatch(/^[A-Za-z0-9+/]{43}=$/);
  sensitiveCodes.add(code);
  return code;
}
async function requestCode(email = SOURCE) {
  const { mails } = bodyFixture();
  const response = await forgot(email);
  expect(response.status).toBe(200);
  expect(await response.json()).toEqual(GENERIC);
  ownedFixture();
  expect(mails.findLast(mail => mail.subject === 'Your imghost password reset code')!.to).toBe(email);
  return mailCode();
}
async function login(email: string, password: string) {
  const { db, userId, baseline } = bodyFixture();
  const response = await api('/auth/login', { email, password });
  expect(response.status).toBe(200);
  const receipt = await response.json() as { user_id: string; refresh_token: string; api_token: string };
  expect(receipt).toMatchObject({ user_id: userId, email, api_token: baseline.account.api_token });
  expect(await db.getRefreshToken(receipt.refresh_token)).not.toBeNull();
  return receipt.refresh_token;
}
function holdHash(password: string) {
  const gate = barrier('post-authority-read password hashing');
  const original = Auth.hashPassword.bind(Auth);
  let armed = true;
  vi.spyOn(Auth, 'hashPassword').mockImplementation(async input => {
    if (armed && input === password) {
      armed = false;
      await gate.wait(); // Handler has read authority; production hashing/guarded SQL still follow.
    }
    return original(input);
  });
  return gate;
}
function holdRefreshAfterRead() {
  const gate = barrier('post-refresh-authority-read JWT creation');
  const original = Auth.createJWT.bind(Auth);
  let armed = true;
  vi.spyOn(Auth, 'createJWT').mockImplementation(async (...args) => {
    if (armed) { armed = false; await gate.wait(); }
    return original(...args);
  });
  return gate;
}
function holdForgotWrite() {
  const { sqlite } = bodyFixture();
  const gate = barrier('snapshot-bound forgot SQL write');
  sqlite.holdIssuance(gate);
  return gate;
}
function holdForgotMail() {
  const gate = barrier('post-issuance forgot mail transport');
  gate.fixture.mailGate = { subject: 'Your imghost password reset code', gate };
  return gate;
}
function installAbort(event: string, table: string, condition: string) {
  const { sqlite } = bodyFixture();
  sqlite.sql.exec(`CREATE TEMP TRIGGER boundary_abort BEFORE ${event} ON ${table}
    WHEN ${condition} BEGIN SELECT RAISE(ABORT, 'boundary storage abort'); END;`);
}
function dropAbort() { bodyFixture().sqlite.sql.exec('DROP TRIGGER boundary_abort'); }
function assertMissFromOriginal(email: string, hash: string, count: number) {
  const { sqlite, userId } = bodyFixture();
  const writes = sqlite.issuanceWrites();
  expect(writes).toHaveLength(count);
  expect(writes.at(-1)).toMatchObject({ changes: 0 });
  expect(writes.at(-1)!.values.slice(2)).toEqual([userId, email, hash]);
}
async function assertResetWinner(code = CODE_A) {
  const { db, sqlite, userId } = bodyFixture();
  const response = await reset(code);
  expect(response.status).toBe(200);
  expect(await response.json()).toEqual({ message: 'Password successfully reset. Please log in with your new password.' });
  expect(currentUser()).toMatchObject({ email: SOURCE, password_reset_token: null, password_reset_token_expires: null });
  expect(await ownedAuth().verifyPassword(RESET_PASSWORD, String(currentUser().password_hash))).toBe(true);
  expect(await db.getRefreshToken('source-refresh')).toBeNull();
  expect(sqlite.sql.prepare('SELECT * FROM refresh_tokens WHERE user_id = ? AND revoked = 0').all(userId)).toEqual([]);
  assertPreserved();
}
async function assertConversionWinner(proof: Proof) {
  const { db, sqlite, userId } = bodyFixture();
  const response = await complete(proof);
  expect(response.status).toBe(200);
  expect(await response.json()).toMatchObject({ user_id: userId, email: DESTINATION,
    apple_access_retained: true, email_verified: true, notification_pending: false });
  expect(currentUser()).toMatchObject({ email: DESTINATION, password_reset_token: null, password_reset_token_expires: null });
  expect(await ownedAuth().verifyPassword(CONVERSION_PASSWORD, String(currentUser().password_hash))).toBe(true);
  expect(await db.getRefreshToken('source-refresh')).toBeNull();
  expect(sqlite.sql.prepare('SELECT * FROM refresh_tokens WHERE user_id = ? AND revoked = 0').all(userId)).toEqual([]);
  expect(sqlite.sql.prepare('SELECT phase FROM email_conversion_challenges WHERE user_id = ?').get(userId))
    .toMatchObject({ phase: 'complete' });
  expect(sqlite.sql.prepare('SELECT * FROM email_conversion_events WHERE user_id = ?').all(userId)).toHaveLength(1);
  assertPreserved();
}
async function currentEmailReset() {
  const { db, sqlite, userId } = bodyFixture();
  const code = await requestCode(DESTINATION);
  expect(currentUser()).toMatchObject({ email: DESTINATION, password_reset_token: code });
  expect((await reset(code)).status).toBe(200);
  expect(currentUser()).toMatchObject({ email: DESTINATION, password_reset_token: null, password_reset_token_expires: null });
  expect(await ownedAuth().verifyPassword(RESET_PASSWORD, String(currentUser().password_hash))).toBe(true);
  expect(sqlite.sql.prepare('SELECT * FROM refresh_tokens WHERE user_id = ? AND revoked = 0').all(userId)).toEqual([]);
  const session = await login(DESTINATION, RESET_PASSWORD);
  const beforeReplay = state();
  expect((await reset(code)).status).toBe(400);
  expect(state()).toEqual(beforeReplay);
  expect(await db.getRefreshToken(session)).not.toBeNull();
  assertPreserved();
}

beforeAll(async () => {
  pair = await crypto.subtle.generateKey({ name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048,
    publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' }, true, ['sign', 'verify']);
  publicKey = { ...await crypto.subtle.exportKey('jwk', pair.publicKey), kid: 'boundary-key', alg: 'RS256', use: 'sig' };
});
beforeEach(async context => {
  if (fixtureOwner && fixtureOwner.phase !== 'closed') {
    throw new Error('Previous fixture still owns pending work; refusing cross-case reuse');
  }
  const fixture: FixtureOwner = { task: context.task, phase: 'active', gates: new Set(), requests: new Map(),
    auxiliary: new Set(), mails: [], sensitiveCodes: new Set([CODE_A, 'verification-only']), initialized: false };
  fixtureOwner = fixture;
  const setup = initializeFixture(fixture);
  fixture.setupSettlement = setup.then<PromiseSettledResult<void>, PromiseSettledResult<void>>(
    value => ({ status: 'fulfilled', value }), reason => ({ status: 'rejected', reason })
  );
  await setup;
});
async function initializeFixture(fixture: FixtureOwner) {
  vi.spyOn(Date, 'now').mockReturnValue(NOW);
  vi.spyOn(AppleAuth, 'getApplePublicKeys').mockResolvedValue([publicKey]);
  vi.spyOn(console, 'log').mockImplementation(() => {});
  vi.spyOn(console, 'error').mockImplementation(() => {});
  const sqlite = new SQLiteD1();
  fixture.sqlite = sqlite;
  const env = { DB: sqlite as unknown as D1Database, JWT_SECRET: 'boundary-test-only-secret',
    // Enabled only in this synthetic fixture; no product configuration/rollout changes.
    EMAIL_CONVERSION_ENABLED: 'true', EMAIL_FROM: 'sender@example.test', AWS_REGION: 'us-east-1',
    AWS_ACCESS_KEY_ID: 'test-access', AWS_SECRET_ACCESS_KEY: 'test-secret' } as Env;
  fixture.env = env;
  const db = new Database(env.DB);
  fixture.db = db;
  const user = await db.createAppleUser(SOURCE, 'boundary-apple-owner', 'enterprise');
  const userId = user.id;
  fixture.userId = userId;
  const other = await db.createUser('unrelated@example.test', await Auth.hashPassword('UnrelatedPassword789'), 'unrelated-api');
  const otherId = other.id;
  fixture.otherId = otherId;
  await db.createAppleSubscription(userId, 'enterprise', 'active', 'original-transaction', 'product-id', NOW + 999999);
  await db.createSubscription(otherId, 'free', 'active');
  sqlite.sql.prepare(`UPDATE subscriptions SET stripe_customer_id = 'stripe-customer',
    stripe_subscription_id = 'stripe-sub', cancel_at_period_end = 1, trial_ends_at = ? WHERE user_id = ?`)
    .run(NOW + 200000, userId);
  await db.createImage(userId, 'library/photo.png', 'photo.png', 300, 'image/png', 'preserved-delete-token');
  await db.createImage(otherId, 'other/photo.png', 'other.png', 100, 'image/png', 'other-delete-token');
  await db.createRefreshToken(userId, 'source-refresh', 999999);
  await db.createRefreshToken(otherId, 'other-refresh', 999999);
  expect(await db.setPasswordResetToken(userId, user.email, user.password_hash, CODE_A, 3600000)).toBe(true);
  await db.setEmailVerificationToken(userId, 'verification-only', 999999);
  fixture.access = await Auth.createJWT({ sub: userId, email: SOURCE, tier: 'enterprise', type: 'access' }, 3600, env.JWT_SECRET);
  vi.stubGlobal('fetch', vi.fn(async (url: string, options: RequestInit) => {
    expect(url).toBe('https://email.us-east-1.amazonaws.com/v2/email/outbound-emails');
    expect(options.method).toBe('POST');
    expect((options.headers as Record<string, string>).Authorization).toContain('AWS4-HMAC-SHA256');
    const payload = JSON.parse(options.body as string);
    const mail = { to: payload.Destination.ToAddresses[0], subject: payload.Content.Simple.Subject.Data,
      text: payload.Content.Simple.Body.Text.Data };
    if (fixture.phase === 'closed') throw new Error('Mail cannot outlive its owning fixture');
    fixture.mails.push(mail);
    if (mail.subject === 'Your imghost password reset code') fixture.sensitiveCodes.add(mail.text.split('\n\n')[1]);
    if (fixture.mailGate?.subject === mail.subject) {
      const held = fixture.mailGate;
      fixture.mailGate = undefined;
      await held.gate.wait(); // Only outbound transport; the issuance SQL has already committed.
    }
    return new Response('{}', { status: 200 });
  }));
  fixture.baseline = preservedData(fixture);
  fixture.initialized = true;
}
afterEach(async context => {
  const fixture = fixtureOwner;
  // A later setup refused because an earlier owner was still draining must not
  // restore that owner's mocks or close its DB. Its existing teardown retains ownership.
  if (!fixture || fixture.task !== context.task) return;
  if (!fixture.teardown) {
    fixture.phase = 'closing';
    fixture.teardown = (async () => {
      try {
        const settlements = await releaseAndSettle(fixture);
        expect(settlements.filter(result => result.status === 'rejected')).toEqual([]);
        if (fixture.initialized) {
          expect(console.log).not.toHaveBeenCalled();
          const logs = JSON.stringify(vi.mocked(console.error).mock.calls);
          for (const secret of [SOURCE, DESTINATION, RESET_PASSWORD, CONVERSION_PASSWORD, ...fixture.sensitiveCodes]) {
            expect(logs).not.toContain(secret);
          }
          assertPreserved(fixture);
        }
      } finally {
        // Also release/settle on any assertion/error path BEFORE restoring global
        // seams or closing SQLite. No subsequent case can borrow this live owner.
        try {
          await releaseAndSettle(fixture);
        } finally {
          try {
            vi.restoreAllMocks();
          } finally {
            try {
              vi.unstubAllGlobals();
            } finally {
              try {
                fixture.sqlite?.sql.close();
              } finally {
                fixture.phase = 'closed';
                if (fixtureOwner === fixture) fixtureOwner = undefined;
              }
            }
          }
        }
      }
    })();
  }
  await fixture.teardown;
});

describe('credential boundary through actual Worker routes and production SQL (not live D1)', () => {
  it('ResetReadThenConversionRejectsStaleReset', async ({ db, mails }) => {
    const proof = await prepareConversion();
    const gate = holdHash(RESET_PASSWORD);
    const pending = reset();
    await waitForEntry(gate, pending);
    await assertConversionWinner(proof);
    const session = await login(DESTINATION, CONVERSION_PASSWORD);
    const committed = state();
    const mailCount = mails.length;
    gate.release();
    expect((await pending).status).toBe(400);
    expect(state()).toEqual(committed);
    expect(mails).toHaveLength(mailCount);
    expect(await db.getRefreshToken(session)).not.toBeNull();
    await currentEmailReset();
  });

  it('ConversionReadThenResetRejectsStaleConversion', async ({ db, mails }) => {
    const proof = await prepareConversion();
    const gate = holdHash(CONVERSION_PASSWORD);
    const pending = complete(proof);
    await waitForEntry(gate, pending);
    await assertResetWinner();
    const session = await login(SOURCE, RESET_PASSWORD);
    const committed = state();
    const mailCount = mails.length;
    gate.release();
    expect((await pending).status).toBe(409);
    expect(state()).toEqual(committed);
    expect(mails).toHaveLength(mailCount);
    expect(await db.getRefreshToken(session)).not.toBeNull();
    expect((await reset()).status).toBe(400);
    expect(await db.getRefreshToken(session)).not.toBeNull();
  });

  it('ForgotLookupThenConversionRejectsLateIssuance', async ({ sqlite, db, mails }) => {
    const proof = await prepareConversion();
    const hash = String(currentUser().password_hash);
    const count = sqlite.issuanceWrites().length;
    const gate = holdForgotWrite();
    const pending = forgot();
    await waitForEntry(gate, pending);
    await assertConversionWinner(proof);
    const session = await login(DESTINATION, CONVERSION_PASSWORD);
    const committed = state();
    const mailCount = mails.length;
    gate.release();
    const response = await pending;
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual(GENERIC);
    assertMissFromOriginal(SOURCE, hash, count + 1);
    expect(state()).toEqual(committed);
    expect(mails).toHaveLength(mailCount);
    expect(await db.getRefreshToken(session)).not.toBeNull();
    await currentEmailReset();
  });

  it('ForgotIssuanceThenConversionInvalidatesOldMailCode', async ({ db }) => {
    const proof = await prepareConversion();
    const gate = holdForgotMail();
    const pending = forgot();
    await waitForEntry(gate, pending);
    const codeB = mailCode();
    expect(currentUser().password_reset_token).toBe(codeB);
    expect(codeB).not.toBe(CODE_A);
    await assertConversionWinner(proof);
    const session = await login(DESTINATION, CONVERSION_PASSWORD);
    gate.release();
    const response = await pending;
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual(GENERIC);
    const committed = state();
    expect((await reset(codeB)).status).toBe(400);
    expect((await reset()).status).toBe(400);
    expect(state()).toEqual(committed);
    expect(await db.getRefreshToken(session)).not.toBeNull();
    await currentEmailReset();
  });

  it('ForgotLookupThenPasswordResetRejectsLateIssuance', async ({ sqlite, db, mails }) => {
    const hash = String(currentUser().password_hash);
    const count = sqlite.issuanceWrites().length;
    const gate = holdForgotWrite();
    const pending = forgot();
    await waitForEntry(gate, pending);
    await assertResetWinner();
    const session = await login(SOURCE, RESET_PASSWORD);
    const committed = state();
    const mailCount = mails.length;
    gate.release();
    const response = await pending;
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual(GENERIC);
    assertMissFromOriginal(SOURCE, hash, count + 1);
    expect(state()).toEqual(committed);
    expect(mails).toHaveLength(mailCount);
    expect(await db.getRefreshToken(session)).not.toBeNull();
    await assertResetWinner(await requestCode());
  });

  it('ForgotIssuanceThenPasswordResetInvalidatesIssuedCode', async ({ db }) => {
    const gate = holdForgotMail();
    const pending = forgot();
    await waitForEntry(gate, pending);
    const codeB = mailCode();
    const issued = state();
    expect(currentUser().password_reset_token).toBe(codeB);
    // A is obsolete now: it must NOT clear B or revoke any sessions.
    expect((await reset()).status).toBe(400);
    expect(state()).toEqual(issued);
    await assertResetWinner(codeB); // The currently issued B, not obsolete A, wins.
    const session = await login(SOURCE, RESET_PASSWORD);
    gate.release();
    const response = await pending;
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual(GENERIC);
    const committed = state();
    expect((await reset(codeB)).status).toBe(400);
    expect(state()).toEqual(committed);
    expect(await db.getRefreshToken(session)).not.toBeNull();
  });

  it('ForgotWrongAccountSnapshotCannotIssue', async ({ db, otherId, mails }) => {
    const before = state();
    const user = currentUser();
    expect(await db.setPasswordResetToken(otherId, String(user.email), String(user.password_hash), 'cross-account', 3600000)).toBe(false);
    expect(state()).toEqual(before);
    expect(mails).toHaveLength(0);
    await assertResetWinner(await requestCode()); // Real current-account Worker issuance/consumption still works.
  });

  it('ForgotChangedEmailSnapshotCannotIssue', async ({ db, userId }) => {
    const proof = await prepareConversion();
    await assertConversionWinner(proof);
    const before = state();
    // Correct ID and CURRENT password isolate the email predicate from password drift.
    expect(await db.setPasswordResetToken(userId, SOURCE, String(currentUser().password_hash), 'stale-email', 3600000)).toBe(false);
    expect(state()).toEqual(before);
    await currentEmailReset();
  });

  it('ForgotCurrentCredentialIssuesAndResetsSameAccount', async ({ db, mails }) => {
    await assertConversionWinner(await prepareConversion());
    const session = await login(DESTINATION, CONVERSION_PASSWORD);
    await currentEmailReset();
    expect(await db.getRefreshToken(session)).toBeNull();
    expect((await forgot()).status).toBe(200);
    expect(mails.filter(mail => mail.subject === 'Your imghost password reset code')).toHaveLength(1);
  });

  it('ForgotGuardMissPreservesNewerCurrentEmailCode', async ({ db, sqlite, mails }) => {
    const proof = await prepareConversion();
    const hash = String(currentUser().password_hash);
    const gate = holdForgotWrite();
    const pending = forgot();
    await waitForEntry(gate, pending);
    await assertConversionWinner(proof);
    const session = await login(DESTINATION, CONVERSION_PASSWORD);
    const codeB = await requestCode(DESTINATION);
    const issued = state();
    const mailCount = mails.length;
    const count = sqlite.issuanceWrites().length;
    gate.release();
    const response = await pending;
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual(GENERIC);
    assertMissFromOriginal(SOURCE, hash, count + 1);
    expect(state()).toEqual(issued);
    expect(mails).toHaveLength(mailCount);
    expect(await db.getRefreshToken(session)).not.toBeNull();
    expect((await reset(codeB)).status).toBe(200);
    expect(await db.getRefreshToken(session)).toBeNull();
    expect(await ownedAuth().verifyPassword(RESET_PASSWORD, String(currentUser().password_hash))).toBe(true);
    expect(currentUser().password_reset_token).toBeNull();
  });

  it('ForgotStorageAbortSendsNoMail', async ({ userId, mails }) => {
    const before = state();
    installAbort('UPDATE OF password_reset_token', 'users', `OLD.id = '${userId}'`);
    const failed = await forgot();
    expect(failed.status).toBe(500);
    expect(await failed.json()).toEqual({ error: 'Internal server error' });
    expect(state()).toEqual(before);
    expect(mails).toHaveLength(0);
    dropAbort();
    await assertResetWinner(await requestCode());
  });

  it('ResetThenRefreshCannotMintReplacement', async ({ db }) => {
    const proof = await prepareConversion();
    const gate = holdRefreshAfterRead();
    const pending = refresh();
    await waitForEntry(gate, pending);
    await assertResetWinner();
    const session = await login(SOURCE, RESET_PASSWORD);
    const committed = state();
    gate.release();
    const loser = await pending;
    expect(loser.status).toBe(401);
    expect(await loser.json()).toEqual({ error: 'Invalid or expired refresh token' });
    expect(state()).toEqual(committed);
    expect(await db.getRefreshToken(session)).not.toBeNull();
    expect((await complete(proof)).status).toBe(400);
    expect(state()).toEqual(committed);
  });

  it('RefreshThenResetRevokesReplacement', async ({ db, userId }) => {
    const proof = await prepareConversion();
    const gate = holdHash(RESET_PASSWORD);
    const pending = reset();
    await waitForEntry(gate, pending);
    const rotated = await refresh();
    expect(rotated.status).toBe(200);
    const receipt = await rotated.json() as { refresh_token: string };
    expect(receipt).toMatchObject({ user_id: userId, email: SOURCE, token_type: 'Bearer', expires_in: 3600 });
    expect(await db.getRefreshToken(receipt.refresh_token)).not.toBeNull();
    expect(await db.getRefreshToken('source-refresh')).toBeNull();
    gate.release();
    expect((await pending).status).toBe(200);
    expect(await db.getRefreshToken(receipt.refresh_token)).toBeNull();
    expect(currentUser().password_reset_token).toBeNull();
    expect(await ownedAuth().verifyPassword(RESET_PASSWORD, String(currentUser().password_hash))).toBe(true);
    expect((await complete(proof)).status).toBe(400);
    const session = await login(SOURCE, RESET_PASSWORD);
    const committed = state();
    expect((await reset()).status).toBe(400);
    expect((await refresh()).status).toBe(401);
    expect(state()).toEqual(committed);
    expect(await db.getRefreshToken(session)).not.toBeNull();
  });

  it('ResetRevocationAbortRollsBackCombinedState', async ({ userId }) => {
    await resetAbortRetry('UPDATE OF revoked', 'refresh_tokens', `OLD.user_id = '${userId}'`);
  });
  it('ResetPasswordAbortRollsBackCombinedState', async ({ userId }) => {
    await resetAbortRetry('UPDATE OF password_hash', 'users', `OLD.id = '${userId}'`);
  });
  it('RefreshRevocationAbortPreservesResetAuthority', async ({ userId }) => {
    await refreshAbortRetry('UPDATE OF revoked', 'refresh_tokens', `OLD.user_id = '${userId}'`);
  });
  it('RefreshReplacementAbortRollsBackConsumedRefresh', async ({ userId }) => {
    await refreshAbortRetry('INSERT', 'refresh_tokens', `NEW.user_id = '${userId}'`);
  });
  it('ConversionUserUpdateAbortPreservesResetAuthority', async ({ userId }) => {
    await conversionAbortRetry('UPDATE OF email', 'users', `OLD.id = '${userId}'`);
  });
  it('ConversionChallengeAbortPreservesResetAuthority', async ({ userId }) => {
    await conversionAbortRetry('UPDATE OF phase', 'email_conversion_challenges', `OLD.user_id = '${userId}' AND NEW.phase = 'complete'`);
  });
  it('ConversionRevocationAbortPreservesResetAuthority', async ({ userId }) => {
    await conversionAbortRetry('UPDATE OF revoked', 'refresh_tokens', `OLD.user_id = '${userId}'`);
  });
  it('ConversionAuditAbortPreservesResetAuthority', async ({ userId }) => {
    await conversionAbortRetry('INSERT', 'email_conversion_events', `NEW.user_id = '${userId}'`);
  });

  it('AppleOnlyCredentialBoundaryPreservesAccount', async () => {
    expect(currentUser().password_hash).toBe('APPLE_SIGN_IN_ONLY');
    await assertConversionWinner(await prepareConversion());
    await currentEmailReset();
  });

  it('PasswordBearingAppleLinkedCredentialBoundaryPreservesAccount', async ({ db }) => {
    await assertResetWinner(); // Establish a real password WITHOUT dropping the Apple link.
    await requestCode();
    expect(currentUser().password_hash).not.toBe('APPLE_SIGN_IN_ONLY');
    expect(currentUser().apple_user_id).toBe('boundary-apple-owner');
    const proof = await prepareConversion();
    const obsolete = String(currentUser().password_reset_token);
    const gate = holdHash(RESET_PASSWORD);
    const pending = reset(obsolete);
    await waitForEntry(gate, pending);
    await assertConversionWinner(proof);
    const session = await login(DESTINATION, CONVERSION_PASSWORD);
    const committed = state();
    gate.release();
    expect((await pending).status).toBe(400);
    expect(state()).toEqual(committed);
    expect(await db.getRefreshToken(session)).not.toBeNull();
    await currentEmailReset();
  });

  it('ResetWithoutRefreshRowsStillCommits', async ({ sqlite, userId, db }) => {
    // Account setup removes only this fixture's session rows; no product cleanup.
    sqlite.sql.prepare('DELETE FROM refresh_tokens WHERE user_id = ?').run(userId);
    const proof = await prepareConversion();
    const response = await reset();
    expect(response.status).toBe(200);
    expect(currentUser().password_reset_token).toBeNull();
    expect(currentUser().password_reset_token_expires).toBeNull();
    expect(await ownedAuth().verifyPassword(RESET_PASSWORD, String(currentUser().password_hash))).toBe(true);
    expect(sqlite.sql.prepare('SELECT * FROM refresh_tokens WHERE user_id = ?').all(userId)).toEqual([]);
    expect((await complete(proof)).status).toBe(400);
    const session = await login(SOURCE, RESET_PASSWORD);
    const committed = state();
    expect((await reset()).status).toBe(400);
    expect(state()).toEqual(committed);
    expect(await db.getRefreshToken(session)).not.toBeNull();
  });

  it('ResetReadThenForgotReplacementRejectsObsoleteResetAndPreservesNewCode', async ({ db, mails }) => {
    const gate = holdHash(RESET_PASSWORD);
    const pendingA = reset();
    await waitForEntry(gate, pendingA);
    const codeB = await requestCode();
    expect(codeB).not.toBe(CODE_A);
    expect(currentUser().password_reset_token).toBe(codeB);
    const issuedB = state();
    const mailCount = mails.length;
    gate.release();
    expect((await pendingA).status).toBe(400);
    expect(state()).toEqual(issuedB); // Obsolete A cannot clear B or revoke any session.
    expect(mails).toHaveLength(mailCount);
    expect(await db.getRefreshToken('source-refresh')).not.toBeNull();
    await assertResetWinner(codeB);
    const session = await login(SOURCE, RESET_PASSWORD);
    const committed = state();
    expect((await reset()).status).toBe(400);
    expect((await reset(codeB)).status).toBe(400);
    expect(state()).toEqual(committed);
    expect(await db.getRefreshToken(session)).not.toBeNull();
  });
});

async function resetAbortRetry(event: string, table: string, condition: string) {
  const { db, mails } = bodyFixture();
  const proof = await prepareConversion();
  const before = state();
  const mailCount = mails.length;
  installAbort(event, table, condition);
  const failed = await reset();
  expect(failed.status).toBe(500);
  expect(await failed.json()).toEqual({ error: 'Failed to reset password. Please try again.' });
  expect(state()).toEqual(before); // Includes code/password, ALL sessions, conversion proof and account data.
  expect(mails).toHaveLength(mailCount);
  dropAbort();
  await assertResetWinner();
  expect((await complete(proof)).status).toBe(400);
  const session = await login(SOURCE, RESET_PASSWORD);
  const committed = state();
  expect((await reset()).status).toBe(400);
  expect(state()).toEqual(committed);
  expect(await db.getRefreshToken(session)).not.toBeNull();
}
async function refreshAbortRetry(event: string, table: string, condition: string) {
  const { db, userId, mails } = bodyFixture();
  const proof = await prepareConversion();
  const before = state();
  const mailCount = mails.length;
  installAbort(event, table, condition);
  const failed = await refresh();
  expect(failed.status).toBe(400); // Preserve C6's existing refresh failure contract.
  expect(await failed.json()).toEqual({ error: 'Invalid request body' });
  expect(state()).toEqual(before);
  expect(mails).toHaveLength(mailCount);
  dropAbort();
  const retried = await refresh();
  expect(retried.status).toBe(200);
  const receipt = await retried.json() as { refresh_token: string };
  expect(receipt).toMatchObject({ user_id: userId, email: SOURCE, token_type: 'Bearer', expires_in: 3600 });
  expect(await db.getRefreshToken(receipt.refresh_token)).not.toBeNull();
  expect(await db.getRefreshToken('source-refresh')).toBeNull();
  expect(currentUser().password_reset_token).toBe(CODE_A);
  await assertResetWinner();
  expect(await db.getRefreshToken(receipt.refresh_token)).toBeNull();
  expect((await complete(proof)).status).toBe(400);
  const session = await login(SOURCE, RESET_PASSWORD);
  const committed = state();
  expect((await refresh()).status).toBe(401);
  expect(state()).toEqual(committed);
  expect(await db.getRefreshToken(session)).not.toBeNull();
}
async function conversionAbortRetry(event: string, table: string, condition: string) {
  const { db, mails } = bodyFixture();
  const proof = await prepareConversion();
  const before = state();
  const mailCount = mails.length;
  installAbort(event, table, condition);
  const failed = await complete(proof);
  expect(failed.status).toBe(503);
  expect(await failed.json()).toMatchObject({ error: 'Conversion unavailable; credentials were not intentionally removed. Apple sign-in remains available.' });
  expect(state()).toEqual(before);
  expect(mails).toHaveLength(mailCount);
  dropAbort();
  await assertConversionWinner(proof);
  const session = await login(DESTINATION, CONVERSION_PASSWORD);
  const committed = state();
  expect((await reset()).status).toBe(400);
  expect((await complete(proof)).status).toBe(400);
  expect(state()).toEqual(committed);
  expect(await db.getRefreshToken(session)).not.toBeNull();
  await currentEmailReset();
}
