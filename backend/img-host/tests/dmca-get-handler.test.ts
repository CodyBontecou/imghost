/**
 * DMCA GET Handler Tests
 *
 * Verifies that images marked as DMCA taken down are served as 451.
 */

import { describe, it, expect, vi } from 'vitest';
import worker from '../src/index';

class MockD1Database {
  constructor(private imageRow: Record<string, unknown> | null) {}

  prepare(query: string) {
    const lq = query.toLowerCase().trim();

    return {
      bind: (..._params: unknown[]) => ({
        first: async () => {
          if (lq.includes('from images where r2_key')) {
            return this.imageRow;
          }
          return null;
        },
        all: async () => ({ results: [] }),
        run: async () => ({ success: true }),
      }),
    };
  }
}

function createMockR2Object(contentType = 'image/png') {
  const bytes = new TextEncoder().encode('mock-image-data');
  return {
    body: new ReadableStream({
      start(controller) {
        controller.enqueue(bytes);
        controller.close();
      },
    }),
    httpMetadata: { contentType },
    httpEtag: '"test-etag"',
    size: bytes.length,
    key: 'abc123.png',
  };
}

function createEnv(dmcaTakenDown: 0 | 1) {
  const dbRow = {
    id: 'abc123',
    r2_key: 'abc123.png',
    dmca_taken_down: dmcaTakenDown,
  };

  return {
    IMAGES: {
      get: vi.fn().mockResolvedValue(createMockR2Object()),
      put: vi.fn(),
      delete: vi.fn(),
    },
    DB: new MockD1Database(dbRow) as unknown as D1Database,
    JWT_SECRET: 'test-secret',
    UPLOAD_TOKEN: 'test-upload-token',
  } as any;
}

describe('DMCA enforcement on image GET', () => {
  it('returns 451 for images marked dmca_taken_down', async () => {
    const env = createEnv(1);
    const request = new Request('https://imghost.isolated.tech/abc123.png');

    const response = await worker.fetch(request, env, {
      waitUntil: vi.fn(),
      passThroughOnException: vi.fn(),
    } as any);

    expect(response.status).toBe(451);
    expect(response.headers.get('Content-Type')).toContain('application/json');

    const body = await response.json() as { error: string };
    expect(body.error).toBe('Unavailable for legal reasons');
  });

  it('serves image normally when dmca_taken_down is 0', async () => {
    const env = createEnv(0);
    const request = new Request('https://imghost.isolated.tech/abc123.png');

    const response = await worker.fetch(request, env, {
      waitUntil: vi.fn(),
      passThroughOnException: vi.fn(),
    } as any);

    expect(response.status).toBe(200);
    expect(response.headers.get('Content-Type')).toBe('image/png');
    expect(response.headers.get('Access-Control-Allow-Origin')).toBe('*');
  });
});
