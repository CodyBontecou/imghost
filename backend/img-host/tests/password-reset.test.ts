import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';
import worker from '../src/index';
import { Auth } from '../src/auth';
import { Database } from '../src/database';

// Execute production SQL, not a query-string mock. This small D1 adapter models
// first/run/meta.changes and transactional batch; not a Workers runtime test.
function d1(sqlite: DatabaseSync): D1Database {
  const execute = new WeakMap<object, () => any>();
  return {
    prepare(sql: string) {
      const statement = sqlite.prepare(sql);
      const bound = (...values: any[]) => {
        const run = () => {
          const result = statement.run(...values);
          return { success: true, meta: { changes: Number(result.changes) } };
        };
        const prepared = {
          first: async () => statement.get(...values) || null,
          all: async () => ({ results: statement.all(...values), success: true }),
          run: async () => run(),
        };
        execute.set(prepared, run);
        return prepared;
      };
      const prepared = bound();
      return Object.assign(prepared, { bind: bound });
    },
    async batch(statements: object[]) {
      sqlite.exec('BEGIN');
      try {
        // Execute synchronously inside one SQLite transaction; no interleaving
        // or nested transactions while modeling D1's serialized batch guarantee.
        const results = statements.map(statement => execute.get(statement)!());
        sqlite.exec('COMMIT');
        return results;
      } catch (error) {
        sqlite.exec('ROLLBACK');
        throw error;
      }
    },
  } as unknown as D1Database;
}

let sqlite: DatabaseSync;
let db: Database;
let env: any;
let mail: Array<{ to: string; subject: string; text: string }>;
let transport: ReturnType<typeof vi.fn>;
const oldPassword = 'OriginalPassword123';
const newPassword = 'ReplacementPassword456';

async function api(path: string, body?: unknown) {
  return worker.fetch(new Request(`https://imghost.example${path}`, body === undefined ? {} : {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'CF-Connecting-IP': '192.0.2.1' },
    body: JSON.stringify(body),
  }), env, {} as ExecutionContext);
}

async function requestCode(email = 'ordinary@example.com') {
  const response = await api('/auth/forgot-password', { email });
  expect(response.status).toBe(200);
  const message = mail.at(-1)!;
  // Follow the actual copyable email instructions; no logs or URL parsing.
  const code = message.text.split('\n\n')[1];
  expect(code).toMatch(/^[A-Za-z0-9+/]{43}=$/);
  return code;
}

function reset(token: unknown, new_password: unknown = newPassword) {
  return api('/auth/reset-password', { token, new_password });
}

function unchangedAccount(id: string) {
  const { password_hash, password_reset_token, password_reset_token_expires, ...account } =
    sqlite.prepare('SELECT * FROM users WHERE id = ?').get(id)!;
  return account;
}

beforeEach(async () => {
  sqlite = new DatabaseSync(':memory:');
  sqlite.exec(readFileSync(new URL('../schema.sql', import.meta.url), 'utf8'));
  db = new Database(d1(sqlite));
  const ordinary = await db.createUser('ordinary@example.com', await Auth.hashPassword(oldPassword), 'ordinary-api', 'pro');
  const apple = await db.createAppleUser('relay@privaterelay.appleid.com', 'apple-sub', 'pro');
  const other = await db.createUser('other@example.com', await Auth.hashPassword(oldPassword), 'other-api', 'free');
  for (const user of [ordinary, apple, other]) {
    await db.createSubscription(user.id, user.subscription_tier, 'active');
    await db.createRefreshToken(user.id, `refresh-${user.id}`, 3600000);
    sqlite.prepare('INSERT INTO images (id, user_id, r2_key, filename, size_bytes, content_type, created_at, delete_token) VALUES (?, ?, ?, ?, ?, ?, ?, ?)')
      .run(`image-${user.id}`, user.id, `${user.id}.png`, 'photo.png', 100, 'image/png', Date.now(), `delete-${user.id}`);
  }
  env = {
    DB: d1(sqlite), IMAGES: {}, JWT_SECRET: 'test-only-secret',
    AWS_ACCESS_KEY_ID: 'test-access-key', AWS_SECRET_ACCESS_KEY: 'test-secret-key',
    AWS_REGION: 'us-east-1', EMAIL_FROM: 'sender@example.com',
  };
  mail = [];
  transport = vi.fn(async (url: string, options: RequestInit) => {
    expect(url).toBe('https://email.us-east-1.amazonaws.com/v2/email/outbound-emails');
    expect(options.method).toBe('POST');
    const payload = JSON.parse(options.body as string);
    expect(payload.FromEmailAddress).toBe('sender@example.com');
    expect((options.headers as Record<string, string>).Authorization).toContain('AWS4-HMAC-SHA256');
    mail.push({ to: payload.Destination.ToAddresses[0], subject: payload.Content.Simple.Subject.Data, text: payload.Content.Simple.Body.Text.Data });
    return new Response(JSON.stringify({ MessageId: 'test-message' }));
  });
  vi.stubGlobal('fetch', transport);
  vi.spyOn(console, 'log').mockImplementation(() => {});
  vi.spyOn(console, 'error').mockImplementation(() => {});
});

afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
  sqlite.close();
});

describe('emailed password reset through worker routes', () => {
  it.each(['ordinary@example.com', 'relay@privaterelay.appleid.com'])('resets %s with a copyable email code and preserves the account/data', async email => {
    const user = (await db.getUserByEmail(email))!;
    const accountBefore = unchangedAccount(user.id);
    const imagesBefore = sqlite.prepare('SELECT * FROM images').all();
    const subscriptionsBefore = sqlite.prepare('SELECT * FROM subscriptions').all();
    const otherBefore = await db.getUserByEmail('other@example.com');
    const code = await requestCode(email);
    expect(mail[0].to).toBe(email);
    expect(mail[0].subject).toBe('Your imghost password reset code');
    for (const instruction of ['iOS or macOS', 'Enter Code', 'Reset Code', '1 hour', 'only once', 'same email', 'Sign in with Apple']) {
      expect(mail[0].text).toContain(instruction);
    }
    expect(mail[0].text).not.toMatch(/https?:\/\//);
    expect(await (await reset(code)).json()).toEqual({ message: 'Password successfully reset. Please log in with your new password.' });
    expect(unchangedAccount(user.id)).toEqual(accountBefore);
    expect(sqlite.prepare('SELECT * FROM images').all()).toEqual(imagesBefore);
    expect(sqlite.prepare('SELECT * FROM subscriptions').all()).toEqual(subscriptionsBefore);
    expect(await db.getUserByEmail('other@example.com')).toEqual(otherBefore);
    const updated = (await db.getUserById(user.id))!;
    expect(updated.password_reset_token).toBeNull();
    expect(updated.password_reset_token_expires).toBeNull();
    expect(await Auth.verifyPassword(newPassword, updated.password_hash)).toBe(true);
    expect(await db.getUserByApiToken(user.api_token)).toMatchObject({ id: user.id });
    expect(await db.getRefreshToken(`refresh-${user.id}`)).toBeNull();
    expect(await db.getRefreshToken(`refresh-${otherBefore!.id}`)).not.toBeNull();
    if (user.apple_user_id) expect(await db.getUserByAppleId(user.apple_user_id)).toMatchObject({ id: user.id });
    const login = await api('/auth/login', { email, password: newPassword });
    expect(login.status).toBe(200);
    const loginReceipt = await login.json() as { refresh_token: string };
    expect(loginReceipt).toMatchObject({ user_id: user.id, api_token: user.api_token, subscription_tier: 'pro' });
    expect((await api('/auth/login', { email, password: oldPassword })).status).toBe(401);
    expect((await reset(code)).status).toBe(400);
    expect(await db.getRefreshToken(loginReceipt.refresh_token)).not.toBeNull();
    expect(console.log).not.toHaveBeenCalled();
    expect(console.error).not.toHaveBeenCalled();
  });

  it('serves legacy emailed links without consuming or leaking the code to page resources', async () => {
    const code = await requestCode();
    const before = await db.getUserByEmail('ordinary@example.com');
    const response = await api(`/auth/reset-password?token=${encodeURIComponent(code)}`);
    expect(response.status).toBe(200);
    expect(response.headers.get('Cache-Control')).toBe('no-store');
    expect(response.headers.get('Referrer-Policy')).toBe('no-referrer');
    expect(response.headers.get('Content-Security-Policy')).toContain("default-src 'none'");
    const page = await response.text();
    expect(page).toContain(`<pre>${code}</pre>`);
    expect(page).toContain('Enter Code');
    expect(page).not.toMatch(/<script|<img|<form|href=/i);
    expect(await db.getUserByEmail('ordinary@example.com')).toEqual(before);
    expect((await reset(code)).status).toBe(200);
    expect((await api('/auth/reset-password')).status).toBe(200);
    const attack = await api('/auth/reset-password?token=%3Cscript%3Ealert(1)%3C%2Fscript%3E');
    expect(await attack.text()).toContain('&lt;script&gt;alert(1)&lt;/script&gt;');
  });

  it('rejects unknown, wrong-purpose, expired and replaced tokens without changing a password', async () => {
    const code = await requestCode();
    const user = (await db.getUserByEmail('ordinary@example.com'))!;
    await db.setEmailVerificationToken(user.id, 'verification-only', 3600000);
    for (const token of ['unknown-code', 'verification-only', `refresh-${user.id}`]) {
      expect((await reset(token)).status).toBe(400);
    }
    vi.spyOn(Date, 'now').mockReturnValue(user.password_reset_token_expires!);
    expect((await reset(code)).status).toBe(400); // expiry is exclusive
    vi.mocked(Date.now).mockRestore();
    const replacement = await requestCode();
    expect(replacement).not.toBe(code);
    expect((await reset(code)).status).toBe(400);
    expect((await db.getUserById(user.id))!.password_hash).toBe(user.password_hash);
    expect((await reset(replacement)).status).toBe(200);
  });

  it.each(['', 'short', 12345678, null, {}, []])('rejects invalid password %j without consuming a code', async password => {
    const code = await requestCode();
    const user = (await db.getUserByEmail('ordinary@example.com'))!;
    expect((await reset(code, password)).status).toBe(400);
    expect(await db.getUserById(user.id)).toEqual(user);
    expect((await reset(code, '12345678')).status).toBe(200);
  });

  it.each([null, {}, [], 123])('rejects invalid token type %j', async token => {
    expect((await reset(token)).status).toBe(400);
  });

  it('accepts surrounding Mail copy/paste whitespace without altering base64 characters', async () => {
    const code = await requestCode();
    expect((await reset(` \t${code}\r\n`)).status).toBe(200);
    expect((await reset(code)).status).toBe(400);
  });

  it('binds consumption to the original account', async () => {
    const code = await requestCode();
    const other = (await db.getUserByEmail('other@example.com'))!;
    const tokensBefore = sqlite.prepare('SELECT * FROM refresh_tokens').all();
    expect(await db.consumePasswordResetToken(other.id, code, 'not-a-valid-hash')).toBe(false);
    expect(await db.getUserById(other.id)).toEqual(other);
    expect(sqlite.prepare('SELECT * FROM refresh_tokens').all()).toEqual(tokensBefore);
    expect((await reset(code)).status).toBe(200);
  });

  it('allows exactly one of two overlapping resets', async () => {
    const code = await requestCode();
    const hashPassword = Auth.hashPassword.bind(Auth);
    let release!: () => void;
    const barrier = new Promise<void>(resolve => { release = resolve; });
    let hashing = 0;
    vi.spyOn(Auth, 'hashPassword').mockImplementation(async password => {
      if (++hashing === 2) release();
      await barrier; // both handlers have read the same valid challenge
      return hashPassword(password);
    });
    const responses = await Promise.all([reset(code), reset(code, 'AnotherPassword789')]);
    expect(responses.map(response => response.status).sort()).toEqual([200, 400]);
    expect(mail.filter(message => message.subject === 'Password Changed')).toHaveLength(1);
  });

  it.each(['expires', 'is replaced'])('rechecks a challenge that %s while hashing', async change => {
    const code = await requestCode();
    const user = (await db.getUserByEmail('ordinary@example.com'))!;
    const tokensBefore = sqlite.prepare('SELECT * FROM refresh_tokens').all();
    const hashPassword = Auth.hashPassword.bind(Auth);
    vi.spyOn(Auth, 'hashPassword').mockImplementation(async password => {
      if (change === 'expires') vi.spyOn(Date, 'now').mockReturnValue(user.password_reset_token_expires!);
      else await db.setPasswordResetToken(user.id, user.email, user.password_hash, 'replacement-code', 3600000);
      return hashPassword(password);
    });
    expect((await reset(code)).status).toBe(400);
    expect((await db.getUserById(user.id))!.password_hash).toBe(user.password_hash);
    expect(sqlite.prepare('SELECT * FROM refresh_tokens').all()).toEqual(tokensBefore);
  });

  it('uses the same success response for unknown email and enforces request rate limits', async () => {
    const unknown = await api('/auth/forgot-password', { email: 'unknown@example.com' });
    expect(unknown.status).toBe(200);
    expect(mail).toHaveLength(0);
    const known = await api('/auth/forgot-password', { email: 'ordinary@example.com' });
    expect(await unknown.json()).toEqual(await known.json());
    await requestCode();
    expect((await api('/auth/forgot-password', { email: 'ordinary@example.com' })).status).toBe(429);
  });

  it.each(['missing credentials', 'provider rejection', 'transport failure'])('fails delivery safely for %s without secret logs', async failure => {
    if (failure === 'missing credentials') delete env.AWS_SECRET_ACCESS_KEY;
    if (failure === 'provider rejection') transport.mockResolvedValue(new Response('echoed-secret-body', { status: 400 }));
    if (failure === 'transport failure') transport.mockRejectedValue(new Error('secret-request-body'));
    const response = await api('/auth/forgot-password', { email: 'ordinary@example.com' });
    expect(response.status).toBe(500);
    expect(await response.json()).toEqual({ error: 'Failed to send password reset email. Please try again.' });
    expect(console.log).not.toHaveBeenCalled();
    expect(vi.mocked(console.error).mock.calls).toEqual([['Forgot password: failed to send reset email']]);
    if (failure === 'missing credentials') expect(transport).not.toHaveBeenCalled();
  });

  it.each([
    ['session revocation', 'refresh_tokens', 'revoked'],
    ['password update', 'users', 'password_hash'],
  ])('rolls back reset state when %s fails and permits explicit retry', async (_failure, table, column) => {
    const code = await requestCode();
    const user = (await db.getUserByEmail('ordinary@example.com'))!;
    const tokensBefore = sqlite.prepare('SELECT * FROM refresh_tokens').all();
    sqlite.exec(`CREATE TEMP TRIGGER fail_reset_write BEFORE UPDATE OF ${column} ON ${table}
      BEGIN SELECT RAISE(ABORT, 'simulated storage failure'); END;`);
    const failed = await reset(code);
    expect(failed.status).toBe(500);
    expect(await failed.json()).toEqual({ error: 'Failed to reset password. Please try again.' });
    expect(await db.getUserById(user.id)).toEqual(user);
    expect(sqlite.prepare('SELECT * FROM refresh_tokens').all()).toEqual(tokensBefore);
    expect(mail.filter(message => message.subject === 'Password Changed')).toHaveLength(0);
    expect(vi.mocked(console.error).mock.calls).toEqual([['Reset password failed']]);
    sqlite.exec('DROP TRIGGER fail_reset_write');
    expect((await reset(code)).status).toBe(200);
    expect(await Auth.verifyPassword(newPassword, (await db.getUserById(user.id))!.password_hash)).toBe(true);
    expect(await db.getRefreshToken(`refresh-${user.id}`)).toBeNull();
    expect((await reset(code)).status).toBe(400);
  });

  it.each(['{bad json', 'null', '[]', 'true'])('rejects malformed body %s without consuming a code', async body => {
    const code = await requestCode();
    const before = await db.getUserByEmail('ordinary@example.com');
    const response = await worker.fetch(new Request('https://imghost.example/auth/reset-password', {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body,
    }), env, {} as ExecutionContext);
    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: 'Invalid request body' });
    expect(await db.getUserByEmail('ordinary@example.com')).toEqual(before);
    expect((await reset(code)).status).toBe(200);
  });

  it('reports a committed reset as successful even if the confirmation email fails', async () => {
    const code = await requestCode();
    transport.mockRejectedValue(new Error('secret-confirmation-data'));
    expect((await reset(code)).status).toBe(200);
    expect((await reset(code)).status).toBe(400);
    expect(await Auth.verifyPassword(newPassword, (await db.getUserByEmail('ordinary@example.com'))!.password_hash)).toBe(true);
    expect(vi.mocked(console.error).mock.calls).toEqual([['Reset password: failed to send confirmation email']]);
  });
});
