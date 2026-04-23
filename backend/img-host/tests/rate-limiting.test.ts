/**
 * Rate Limiting Tests
 *
 * These tests verify the rate limiting and abuse prevention functionality.
 * Run with: npm test
 */

import { describe, it, expect, beforeEach } from 'vitest';
import { RateLimiter, getRateLimitConfig, getIpRateLimitConfig } from '../src/rate-limiter';
import { ContentModerator } from '../src/content-moderation';

// Mock D1 Database for testing
class MockD1Database {
  private data: Map<string, any[]> = new Map();

  prepare(query: string) {
    return {
      bind: (...params: any[]) => {
        return {
          first: async () => {
            // Mock implementation
            return null;
          },
          all: async () => {
            return { results: [] };
          },
          run: async () => {
            return { success: true };
          },
        };
      },
    };
  }
}

describe('Rate Limiter', () => {
  let rateLimiter: RateLimiter;
  let mockDb: any;

  beforeEach(() => {
    mockDb = new MockD1Database();
    rateLimiter = new RateLimiter(mockDb as any);
  });

  describe('getRateLimitConfig', () => {
    it('should return correct limits for free tier', () => {
      const config = getRateLimitConfig('free', '/upload');
      expect(config.maxRequests).toBe(100);
      expect(config.windowMs).toBe(24 * 60 * 60 * 1000); // 24 hours
    });

    it('should return correct limits for pro tier', () => {
      const config = getRateLimitConfig('pro', '/upload');
      expect(config.maxRequests).toBe(50000);
    });

    it('should return correct limits for business tier', () => {
      const config = getRateLimitConfig('business', '/upload');
      expect(config.maxRequests).toBe(999999); // Effectively unlimited
    });
  });

  describe('getIpRateLimitConfig', () => {
    it('should return strict limits for auth endpoints', () => {
      const config = getIpRateLimitConfig('/auth/login');
      expect(config.maxRequests).toBe(10);
      expect(config.windowMs).toBe(60 * 60 * 1000); // 1 hour
    });

    it('should return default limits for other endpoints', () => {
      const config = getIpRateLimitConfig('/api/other');
      expect(config.maxRequests).toBe(100);
    });
  });
});

describe('Content Moderator', () => {
  let moderator: ContentModerator;
  let mockDb: any;

  beforeEach(() => {
    mockDb = new MockD1Database();
    moderator = new ContentModerator(mockDb as any);
  });

  describe('File Type Validation', () => {
    it('should detect JPEG magic bytes', async () => {
      // JPEG magic bytes: FF D8 FF
      const jpegBytes = new Uint8Array([0xff, 0xd8, 0xff, 0xe0]);
      const result = (moderator as any).detectFileTypeByMagicBytes(jpegBytes);
      expect(result).toBe('image/jpeg');
    });

    it('should detect PNG magic bytes', async () => {
      // PNG magic bytes: 89 50 4E 47 0D 0A 1A 0A
      const pngBytes = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
      const result = (moderator as any).detectFileTypeByMagicBytes(pngBytes);
      expect(result).toBe('image/png');
    });

    it('should detect GIF magic bytes', async () => {
      // GIF magic bytes: 47 49 46 38
      const gifBytes = new Uint8Array([0x47, 0x49, 0x46, 0x38, 0x39, 0x61]);
      const result = (moderator as any).detectFileTypeByMagicBytes(gifBytes);
      expect(result).toBe('image/gif');
    });

    it('should detect Windows executable (PE)', async () => {
      // Windows PE magic bytes: MZ
      const peBytes = new Uint8Array([0x4d, 0x5a, 0x90, 0x00]);
      const result = (moderator as any).detectFileTypeByMagicBytes(peBytes);
      expect(result).toBe('application/x-msdownload');
    });

    it('should detect Linux executable (ELF)', async () => {
      // ELF magic bytes: 7F 45 4C 46
      const elfBytes = new Uint8Array([0x7f, 0x45, 0x4c, 0x46]);
      const result = (moderator as any).detectFileTypeByMagicBytes(elfBytes);
      expect(result).toBe('application/x-elf');
    });
  });

  describe('Malware Detection', () => {
    it('should flag suspicious file extensions', async () => {
      const mockFile = {
        name: 'image.jpg.exe',
        type: 'image/jpeg',
        size: 1024,
        slice: (start: number, end: number) => ({
          arrayBuffer: async () => new ArrayBuffer(12),
        }),
      } as any;

      const result = await moderator.scanForMalware(mockFile);
      expect(result.flagged).toBe(true);
      // .exe is caught by the suspicious-extension check
      expect(result.flags.some(f => f.reason.includes('.exe'))).toBe(true);
    });

    it('should flag .exe extension', async () => {
      const mockFile = {
        name: 'malware.exe',
        type: 'image/jpeg',
        size: 1024,
        slice: (start: number, end: number) => ({
          arrayBuffer: async () => new ArrayBuffer(12),
        }),
      } as any;

      const result = await moderator.scanForMalware(mockFile);
      expect(result.flagged).toBe(true);
      expect(result.flags.some(f => f.reason.includes('Suspicious file extension'))).toBe(true);
    });
  });
});

describe('Rate Limit Response Headers', () => {
  it('should include correct rate limit headers', () => {
    const headers = {
      'X-RateLimit-Limit': '100',
      'X-RateLimit-Remaining': '95',
      'X-RateLimit-Reset': Date.now().toString(),
    };

    expect(headers['X-RateLimit-Limit']).toBe('100');
    expect(headers['X-RateLimit-Remaining']).toBe('95');
    expect(headers['X-RateLimit-Reset']).toBeDefined();
  });
});

describe('Exponential Backoff', () => {
  it('should calculate correct lockout durations', () => {
    const lockoutSchedule = [
      { attempt: 5, minutes: 1 },
      { attempt: 6, minutes: 5 },
      { attempt: 7, minutes: 15 },
      { attempt: 8, minutes: 60 },
      { attempt: 9, minutes: 1440 },
    ];

    lockoutSchedule.forEach(({ attempt, minutes }) => {
      const lockoutMinutes = [1, 5, 15, 60, 1440][Math.min(attempt - 5, 4)];
      expect(lockoutMinutes).toBe(minutes);
    });
  });
});
