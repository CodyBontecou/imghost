/**
 * Integration tests for DMCA endpoint and upload-time content checks
 * (hash blocklist + Hive moderation integration).
 *
 * Run with: npm test
 */

import { describe, it, expect, beforeEach, vi } from 'vitest';
import { ContentModerator, HiveModerationClient, computeFileSha256 } from '../src/content-moderation';

// ---------------------------------------------------------------------------
// Helpers
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
          if (lq.includes('from blocked_hashes')) {
            const rows = db.rows('blocked_hashes');
            return rows.find(r => r.hash === params[0]) ?? null;
          }
          return null;
        },
        all: async () => ({ results: [] }),
        run: async () => {
          if (lq.includes('blocked_hashes') && lq.includes('insert')) {
            const existing = db.rows('blocked_hashes');
            existing.push({ hash: params[0], reason: params[1], blocked_at: params[2] });
            db.tables.set('blocked_hashes', existing);
          }
          if (lq.includes('dmca_takedowns') && lq.includes('insert')) {
            const existing = db.rows('dmca_takedowns');
            existing.push({ id: params[0], image_id: params[1], status: 'pending' });
            db.tables.set('dmca_takedowns', existing);
          }
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
// Upload-time hash blocklist enforcement
// ---------------------------------------------------------------------------

describe('Upload hash blocklist enforcement', () => {
  let moderator: ContentModerator;
  let mockDb: MockD1Database;

  beforeEach(() => {
    mockDb = new MockD1Database();
    moderator = new ContentModerator(mockDb as any);
  });

  it('allows upload when hash is not blocked', async () => {
    const buf = new TextEncoder().encode('safe content').buffer as ArrayBuffer;
    const hash = await computeFileSha256(buf);
    const blocked = await moderator.checkHashBlocklist(hash);
    expect(blocked).toBe(false);
  });

  it('rejects upload when hash matches a blocklist entry', async () => {
    const buf = new TextEncoder().encode('bad content').buffer as ArrayBuffer;
    const hash = await computeFileSha256(buf);
    mockDb.seed('blocked_hashes', [{ hash, reason: 'csam', blocked_at: Date.now() }]);

    const blocked = await moderator.checkHashBlocklist(hash);
    expect(blocked).toBe(true);
  });

  it('hash changes when file content changes', async () => {
    const { computeFileSha256 } = await import('../src/content-moderation');
    const a = await computeFileSha256(new TextEncoder().encode('version1').buffer as ArrayBuffer);
    const b = await computeFileSha256(new TextEncoder().encode('version2').buffer as ArrayBuffer);
    expect(a).not.toBe(b);
  });
});

// ---------------------------------------------------------------------------
// Hive moderation CSAM → immediate block + blocklist
// ---------------------------------------------------------------------------

describe('Hive moderation CSAM flow', () => {
  it('adds hash to blocklist when CSAM is detected', async () => {
    const mockFetch = vi.fn().mockResolvedValue({
      ok: true,
      json: async () => ({
        status: { code: 200 },
        output: [{ classes: [{ class: 'yes_csam', score: 0.97 }] }],
      }),
    });

    const mockDb = new MockD1Database();
    const moderator = new ContentModerator(mockDb as any);
    const client = new HiveModerationClient('test-key', mockFetch as any);

    const buf = new TextEncoder().encode('csam-content').buffer as ArrayBuffer;
    const hash = await computeFileSha256(buf);

    const result = await client.classify(buf);

    if (result.csam) {
      await moderator.addToHashBlocklist(hash, 'csam');
    }

    const rows = mockDb.rows('blocked_hashes');
    expect(result.csam).toBe(true);
    expect(rows.some(r => r.hash === hash && r.reason === 'csam')).toBe(true);
  });

  it('does not add hash to blocklist when content is safe', async () => {
    const mockFetch = vi.fn().mockResolvedValue({
      ok: true,
      json: async () => ({
        status: { code: 200 },
        output: [{ classes: [{ class: 'general', score: 0.99 }] }],
      }),
    });

    const mockDb = new MockD1Database();
    const moderator = new ContentModerator(mockDb as any);
    const client = new HiveModerationClient('test-key', mockFetch as any);

    const buf = new TextEncoder().encode('safe-content').buffer as ArrayBuffer;
    const result = await client.classify(buf);

    if (result.csam) {
      await moderator.addToHashBlocklist(await computeFileSha256(buf), 'csam');
    }

    const rows = mockDb.rows('blocked_hashes');
    expect(result.csam).toBe(false);
    expect(rows).toHaveLength(0);
  });
});

// ---------------------------------------------------------------------------
// DMCA endpoint logic
// ---------------------------------------------------------------------------

describe('DMCA takedown flow', () => {
  let moderator: ContentModerator;
  let mockDb: MockD1Database;

  beforeEach(() => {
    mockDb = new MockD1Database();
    mockDb.seed('images', [{ id: 'img-xyz', r2_key: 'img-xyz.png', dmca_taken_down: 0 }]);
    moderator = new ContentModerator(mockDb as any);
  });

  it('creates a takedown record and marks image as removed', async () => {
    const takedown = await moderator.createDmcaTakedown({
      imageId: 'img-xyz',
      reportedUrl: 'https://imghost.isolated.tech/img-xyz.png',
      complainantEmail: 'rights@studio.com',
      description: 'Unauthorized use of copyrighted material',
    });

    expect(takedown.status).toBe('pending');
    expect(takedown.image_id).toBe('img-xyz');

    const dmcaRows = mockDb.rows('dmca_takedowns');
    expect(dmcaRows).toHaveLength(1);

    const images = mockDb.rows('images');
    expect(images[0].dmca_taken_down).toBe(1);
  });

  it('prevents future uploads of the same file after takedown with hash', async () => {
    const fileContent = new TextEncoder().encode('copyrighted-image-bytes');
    const hash = await computeFileSha256(fileContent.buffer as ArrayBuffer);

    await moderator.createDmcaTakedown({
      imageId: 'img-xyz',
      reportedUrl: 'https://imghost.isolated.tech/img-xyz.png',
      complainantEmail: 'rights@studio.com',
      description: 'Copyright',
      fileHash: hash,
    });

    const isBlocked = await moderator.checkHashBlocklist(hash);
    expect(isBlocked).toBe(true);
  });
});
