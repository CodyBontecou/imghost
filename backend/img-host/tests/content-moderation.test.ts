/**
 * Content Moderation Tests — hash blocklist, Hive moderation, NCMEC reporting, DMCA
 *
 * Run with: npm test
 */

import { describe, it, expect, beforeEach, vi } from 'vitest';
import {
  ContentModerator,
  HiveModerationClient,
  NCMECReporter,
  type HiveModerationResult,
} from '../src/content-moderation';

// ---------------------------------------------------------------------------
// Mock D1 Database
// ---------------------------------------------------------------------------

class MockD1Database {
  private tables: Map<string, any[]> = new Map();

  seed(table: string, rows: any[]) {
    this.tables.set(table, [...rows]);
  }

  rows(table: string) {
    return this.tables.get(table) ?? [];
  }

  prepare(query: string) {
    const db = this;
    const lq = query.toLowerCase().trim();

    return {
      bind: (...params: any[]) => ({
        first: async () => {
          // blocked_hashes lookup
          if (lq.includes('from blocked_hashes')) {
            const rows = db.rows('blocked_hashes');
            return rows.find(r => r.hash === params[0]) ?? null;
          }
          // dmca_takedowns lookup
          if (lq.includes('from dmca_takedowns')) {
            const rows = db.rows('dmca_takedowns');
            return rows.find(r => r.image_id === params[0]) ?? null;
          }
          return null;
        },
        all: async () => ({ results: [] }),
        run: async () => {
          // INSERT [OR IGNORE] INTO blocked_hashes
          if (lq.includes('blocked_hashes') && (lq.includes('insert'))) {
            const existing = db.rows('blocked_hashes');
            existing.push({ hash: params[0], reason: params[1], blocked_at: params[2] });
            db.tables.set('blocked_hashes', existing);
          }
          // INSERT INTO dmca_takedowns
          if (lq.includes('dmca_takedowns') && lq.includes('insert')) {
            const existing = db.rows('dmca_takedowns');
            existing.push({
              id: params[0],
              image_id: params[1],
              reported_url: params[2],
              complainant_email: params[3],
              description: params[4],
              status: 'pending',
              created_at: params[5],
            });
            db.tables.set('dmca_takedowns', existing);
          }
          // UPDATE images SET dmca_taken_down
          if (lq.includes('update images')) {
            const existing = db.rows('images');
            const img = existing.find(r => r.id === params[0]);
            if (img) img.dmca_taken_down = 1;
          }
          return { success: true };
        },
      }),
    };
  }
}

// ---------------------------------------------------------------------------
// Hash Blocklist
// ---------------------------------------------------------------------------

describe('Hash Blocklist', () => {
  let moderator: ContentModerator;
  let mockDb: MockD1Database;

  beforeEach(() => {
    mockDb = new MockD1Database();
    moderator = new ContentModerator(mockDb as any);
  });

  it('returns false for an unknown hash', async () => {
    const blocked = await moderator.checkHashBlocklist('abc123');
    expect(blocked).toBe(false);
  });

  it('returns true for a hash that has been blocked', async () => {
    mockDb.seed('blocked_hashes', [{ hash: 'deadbeef', reason: 'csam', blocked_at: Date.now() }]);
    const blocked = await moderator.checkHashBlocklist('deadbeef');
    expect(blocked).toBe(true);
  });

  it('adds a new hash to the blocklist', async () => {
    await moderator.addToHashBlocklist('cafebabe', 'copyright');
    const rows = mockDb.rows('blocked_hashes');
    expect(rows.some(r => r.hash === 'cafebabe' && r.reason === 'copyright')).toBe(true);
  });

  it('accepts only allowed reason values', async () => {
    // Should not throw for valid reasons
    await expect(moderator.addToHashBlocklist('aaa', 'csam')).resolves.toBeUndefined();
    await expect(moderator.addToHashBlocklist('bbb', 'copyright')).resolves.toBeUndefined();
    await expect(moderator.addToHashBlocklist('ccc', 'malware')).resolves.toBeUndefined();
  });
});

// ---------------------------------------------------------------------------
// Hive Moderation Client
// ---------------------------------------------------------------------------

describe('HiveModerationClient', () => {
  it('returns a safe result when the API signals no issues', async () => {
    const mockFetch = vi.fn().mockResolvedValue({
      ok: true,
      json: async () => ({
        status: { code: 200 },
        output: [
          {
            time: 0.1,
            classes: [
              { class: 'yes_sexual_activity', score: 0.01 },
              { class: 'general', score: 0.99 },
            ],
          },
        ],
      }),
    });

    const client = new HiveModerationClient('test-api-key', mockFetch as any);
    const result = await client.classify(new ArrayBuffer(8));

    expect(result.blocked).toBe(false);
    expect(result.csam).toBe(false);
  });

  it('blocks and flags csam when confidence exceeds threshold', async () => {
    const mockFetch = vi.fn().mockResolvedValue({
      ok: true,
      json: async () => ({
        status: { code: 200 },
        output: [
          {
            time: 0.1,
            classes: [
              { class: 'yes_csam', score: 0.97 },
              { class: 'general', score: 0.03 },
            ],
          },
        ],
      }),
    });

    const client = new HiveModerationClient('test-api-key', mockFetch as any);
    const result = await client.classify(new ArrayBuffer(8));

    expect(result.blocked).toBe(true);
    expect(result.csam).toBe(true);
    expect(result.confidence).toBeGreaterThan(0.9);
  });

  it('blocks nsfw content above threshold', async () => {
    const mockFetch = vi.fn().mockResolvedValue({
      ok: true,
      json: async () => ({
        status: { code: 200 },
        output: [
          {
            time: 0.1,
            classes: [
              { class: 'yes_sexual_activity', score: 0.91 },
            ],
          },
        ],
      }),
    });

    const client = new HiveModerationClient('test-api-key', mockFetch as any);
    const result = await client.classify(new ArrayBuffer(8));

    expect(result.blocked).toBe(true);
    expect(result.nsfw).toBe(true);
  });

  it('returns safe result and logs on API error (fail open)', async () => {
    const mockFetch = vi.fn().mockRejectedValue(new Error('network timeout'));

    const client = new HiveModerationClient('test-api-key', mockFetch as any);
    const result = await client.classify(new ArrayBuffer(8));

    // Fail open — do not block on transient API errors
    expect(result.blocked).toBe(false);
    expect(result.error).toBeDefined();
  });

  it('returns safe result when API key is not configured', async () => {
    const client = new HiveModerationClient('', fetch);
    const result = await client.classify(new ArrayBuffer(8));

    expect(result.blocked).toBe(false);
    expect(result.skipped).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// NCMEC Reporter
// ---------------------------------------------------------------------------

describe('NCMECReporter', () => {
  it('calls the NCMEC report endpoint with the correct payload', async () => {
    const mockFetch = vi.fn().mockResolvedValue({ ok: true, json: async () => ({ reportId: 'XYZ' }) });

    const reporter = new NCMECReporter('ncmec-key', mockFetch as any);
    const reportId = await reporter.report({
      imageId: 'img-001',
      imageHash: 'deadbeef',
      uploadedAt: new Date('2024-01-01T00:00:00Z'),
      uploaderIp: '1.2.3.4',
    });

    expect(mockFetch).toHaveBeenCalledOnce();
    const [url, opts] = mockFetch.mock.calls[0];
    expect(url).toContain('ncmec');
    const body = JSON.parse(opts.body);
    expect(body.imageId).toBe('img-001');
    expect(reportId).toBe('XYZ');
  });

  it('does not throw when NCMEC API is unavailable', async () => {
    const mockFetch = vi.fn().mockRejectedValue(new Error('connection refused'));

    const reporter = new NCMECReporter('ncmec-key', mockFetch as any);
    await expect(
      reporter.report({ imageId: 'img-001', imageHash: 'abc', uploadedAt: new Date(), uploaderIp: '1.2.3.4' })
    ).resolves.toBeNull();
  });

  it('is a no-op when no API key is configured', async () => {
    const mockFetch = vi.fn();
    const reporter = new NCMECReporter('', mockFetch as any);
    await reporter.report({ imageId: 'x', imageHash: 'y', uploadedAt: new Date(), uploaderIp: 'z' });
    expect(mockFetch).not.toHaveBeenCalled();
  });
});

// ---------------------------------------------------------------------------
// DMCA Takedown
// ---------------------------------------------------------------------------

describe('DMCA Takedown', () => {
  let moderator: ContentModerator;
  let mockDb: MockD1Database;

  beforeEach(() => {
    mockDb = new MockD1Database();
    mockDb.seed('images', [{ id: 'img-abc', r2_key: 'img-abc.jpg', size_bytes: 1024 }]);
    moderator = new ContentModerator(mockDb as any);
  });

  it('creates a DMCA takedown record', async () => {
    const result = await moderator.createDmcaTakedown({
      imageId: 'img-abc',
      reportedUrl: 'https://imghost.isolated.tech/img-abc.jpg',
      complainantEmail: 'legal@example.com',
      description: 'Infringes my copyright',
    });

    const rows = mockDb.rows('dmca_takedowns');
    expect(rows).toHaveLength(1);
    expect(rows[0].image_id).toBe('img-abc');
    expect(result.status).toBe('pending');
  });

  it('marks the image as DMCA taken down', async () => {
    await moderator.createDmcaTakedown({
      imageId: 'img-abc',
      reportedUrl: 'https://imghost.isolated.tech/img-abc.jpg',
      complainantEmail: 'legal@example.com',
      description: 'Copyright claim',
    });

    const images = mockDb.rows('images');
    const img = images.find(r => r.id === 'img-abc');
    expect(img?.dmca_taken_down).toBe(1);
  });

  it('adds the file hash to the blocklist after a takedown', async () => {
    await moderator.createDmcaTakedown({
      imageId: 'img-abc',
      reportedUrl: 'https://imghost.isolated.tech/img-abc.jpg',
      complainantEmail: 'legal@example.com',
      description: 'Copyright',
      fileHash: 'sha256-of-file',
    });

    const blocked = await moderator.checkHashBlocklist('sha256-of-file');
    expect(blocked).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// SHA-256 File Hashing Helper
// ---------------------------------------------------------------------------

describe('computeFileSha256', () => {
  it('returns a 64-char lowercase hex string', async () => {
    const { computeFileSha256 } = await import('../src/content-moderation');
    const buf = new TextEncoder().encode('hello world').buffer as ArrayBuffer;
    const hash = await computeFileSha256(buf);
    expect(hash).toMatch(/^[0-9a-f]{64}$/);
  });

  it('returns the same hash for identical input', async () => {
    const { computeFileSha256 } = await import('../src/content-moderation');
    const buf = new TextEncoder().encode('deterministic').buffer as ArrayBuffer;
    const a = await computeFileSha256(buf);
    const b = await computeFileSha256(buf);
    expect(a).toBe(b);
  });
});
