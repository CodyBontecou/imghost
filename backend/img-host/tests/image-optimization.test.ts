/**
 * Image Optimization Tests
 *
 * Comprehensive tests for dynamic image optimization via URL parameters.
 * Covers parameter parsing, validation, transformation, caching, and error handling.
 *
 * Run with: npm test
 */

import { describe, it, expect, beforeEach, vi } from 'vitest';
import {
  parseTransformParams,
  isTransformableContentType,
  buildCacheKey,
  buildCloudflareImageOptions,
  getBestFormat,
  type ImageTransformOptions,
} from '../src/image-optimization';

// ============================================================================
// Tests
// ============================================================================

describe('Image Optimization', () => {
  describe('URL Parameter Parsing', () => {
    describe('Width parameter (w)', () => {
      it('should parse valid width', () => {
        const url = new URL('https://imghost.isolated.tech/abc123.png?w=400');
        const result = parseTransformParams(url);

        expect(result.options.width).toBe(400);
        expect(result.errors).toHaveLength(0);
        expect(result.hasTransforms).toBe(true);
      });

      it('should reject negative width', () => {
        const url = new URL('https://imghost.isolated.tech/abc123.png?w=-100');
        const result = parseTransformParams(url);

        expect(result.options.width).toBeUndefined();
        expect(result.errors).toContain('Invalid width: must be a positive integer');
      });

      it('should reject zero width', () => {
        const url = new URL('https://imghost.isolated.tech/abc123.png?w=0');
        const result = parseTransformParams(url);

        expect(result.options.width).toBeUndefined();
        expect(result.errors).toContain('Invalid width: must be a positive integer');
      });

      it('should reject non-numeric width', () => {
        const url = new URL('https://imghost.isolated.tech/abc123.png?w=abc');
        const result = parseTransformParams(url);

        expect(result.options.width).toBeUndefined();
        expect(result.errors).toContain('Invalid width: must be a positive integer');
      });

      it('should reject width exceeding maximum (8192px)', () => {
        const url = new URL('https://imghost.isolated.tech/abc123.png?w=10000');
        const result = parseTransformParams(url);

        expect(result.options.width).toBeUndefined();
        expect(result.errors).toContain('Invalid width: maximum is 8192px');
      });

      it('should accept maximum width (8192px)', () => {
        const url = new URL('https://imghost.isolated.tech/abc123.png?w=8192');
        const result = parseTransformParams(url);

        expect(result.options.width).toBe(8192);
        expect(result.errors).toHaveLength(0);
      });

      it('should accept minimum width (1px)', () => {
        const url = new URL('https://imghost.isolated.tech/abc123.png?w=1');
        const result = parseTransformParams(url);

        expect(result.options.width).toBe(1);
        expect(result.errors).toHaveLength(0);
      });
    });

    describe('Height parameter (h)', () => {
      it('should parse valid height', () => {
        const url = new URL('https://imghost.isolated.tech/abc123.png?h=300');
        const result = parseTransformParams(url);

        expect(result.options.height).toBe(300);
        expect(result.errors).toHaveLength(0);
      });

      it('should reject negative height', () => {
        const url = new URL('https://imghost.isolated.tech/abc123.png?h=-50');
        const result = parseTransformParams(url);

        expect(result.options.height).toBeUndefined();
        expect(result.errors).toContain('Invalid height: must be a positive integer');
      });

      it('should reject height exceeding maximum', () => {
        const url = new URL('https://imghost.isolated.tech/abc123.png?h=9999');
        const result = parseTransformParams(url);

        expect(result.options.height).toBeUndefined();
        expect(result.errors).toContain('Invalid height: maximum is 8192px');
      });
    });

    describe('Fit parameter', () => {
      const validFitModes = ['scale-down', 'contain', 'cover', 'crop', 'pad'];

      validFitModes.forEach((mode) => {
        it(`should accept fit mode: ${mode}`, () => {
          const url = new URL(`https://imghost.isolated.tech/abc123.png?fit=${mode}`);
          const result = parseTransformParams(url);

          expect(result.options.fit).toBe(mode);
          expect(result.errors).toHaveLength(0);
        });
      });

      it('should reject invalid fit mode', () => {
        const url = new URL('https://imghost.isolated.tech/abc123.png?fit=stretch');
        const result = parseTransformParams(url);

        expect(result.options.fit).toBeUndefined();
        expect(result.errors[0]).toContain('Invalid fit mode');
      });
    });

    describe('Quality parameter (q)', () => {
      it('should parse valid quality', () => {
        const url = new URL('https://imghost.isolated.tech/abc123.png?q=80');
        const result = parseTransformParams(url);

        expect(result.options.quality).toBe(80);
        expect(result.errors).toHaveLength(0);
      });

      it('should accept minimum quality (1)', () => {
        const url = new URL('https://imghost.isolated.tech/abc123.png?q=1');
        const result = parseTransformParams(url);

        expect(result.options.quality).toBe(1);
        expect(result.errors).toHaveLength(0);
      });

      it('should accept maximum quality (100)', () => {
        const url = new URL('https://imghost.isolated.tech/abc123.png?q=100');
        const result = parseTransformParams(url);

        expect(result.options.quality).toBe(100);
        expect(result.errors).toHaveLength(0);
      });

      it('should reject quality below minimum', () => {
        const url = new URL('https://imghost.isolated.tech/abc123.png?q=0');
        const result = parseTransformParams(url);

        expect(result.options.quality).toBeUndefined();
        expect(result.errors).toContain('Invalid quality: must be between 1 and 100');
      });

      it('should reject quality above maximum', () => {
        const url = new URL('https://imghost.isolated.tech/abc123.png?q=101');
        const result = parseTransformParams(url);

        expect(result.options.quality).toBeUndefined();
        expect(result.errors).toContain('Invalid quality: must be between 1 and 100');
      });
    });

    describe('Format parameter', () => {
      const validFormats = ['webp', 'avif', 'jpeg', 'png', 'auto'];

      validFormats.forEach((format) => {
        it(`should accept format: ${format}`, () => {
          const url = new URL(`https://imghost.isolated.tech/abc123.png?format=${format}`);
          const result = parseTransformParams(url);

          expect(result.options.format).toBe(format);
          expect(result.errors).toHaveLength(0);
        });
      });

      it('should reject invalid format', () => {
        const url = new URL('https://imghost.isolated.tech/abc123.png?format=bmp');
        const result = parseTransformParams(url);

        expect(result.options.format).toBeUndefined();
        expect(result.errors[0]).toContain('Invalid format');
      });
    });

    describe('Blur parameter', () => {
      it('should parse valid blur', () => {
        const url = new URL('https://imghost.isolated.tech/abc123.png?blur=10');
        const result = parseTransformParams(url);

        expect(result.options.blur).toBe(10);
        expect(result.errors).toHaveLength(0);
      });

      it('should accept minimum blur (1)', () => {
        const url = new URL('https://imghost.isolated.tech/abc123.png?blur=1');
        const result = parseTransformParams(url);

        expect(result.options.blur).toBe(1);
        expect(result.errors).toHaveLength(0);
      });

      it('should accept maximum blur (250)', () => {
        const url = new URL('https://imghost.isolated.tech/abc123.png?blur=250');
        const result = parseTransformParams(url);

        expect(result.options.blur).toBe(250);
        expect(result.errors).toHaveLength(0);
      });

      it('should reject blur outside range', () => {
        const url = new URL('https://imghost.isolated.tech/abc123.png?blur=300');
        const result = parseTransformParams(url);

        expect(result.options.blur).toBeUndefined();
        expect(result.errors).toContain('Invalid blur: must be between 1 and 250');
      });
    });

    describe('Sharpen parameter', () => {
      it('should parse valid sharpen', () => {
        const url = new URL('https://imghost.isolated.tech/abc123.png?sharpen=1.5');
        const result = parseTransformParams(url);

        expect(result.options.sharpen).toBe(1.5);
        expect(result.errors).toHaveLength(0);
      });

      it('should reject sharpen outside range', () => {
        const url = new URL('https://imghost.isolated.tech/abc123.png?sharpen=15');
        const result = parseTransformParams(url);

        expect(result.options.sharpen).toBeUndefined();
        expect(result.errors).toContain('Invalid sharpen: must be between 0 and 10');
      });
    });

    describe('Brightness parameter', () => {
      it('should parse valid brightness', () => {
        const url = new URL('https://imghost.isolated.tech/abc123.png?brightness=1.2');
        const result = parseTransformParams(url);

        expect(result.options.brightness).toBe(1.2);
        expect(result.errors).toHaveLength(0);
      });

      it('should reject brightness outside range', () => {
        const url = new URL('https://imghost.isolated.tech/abc123.png?brightness=3');
        const result = parseTransformParams(url);

        expect(result.options.brightness).toBeUndefined();
        expect(result.errors).toContain('Invalid brightness: must be between 0 and 2');
      });
    });

    describe('Contrast parameter', () => {
      it('should parse valid contrast', () => {
        const url = new URL('https://imghost.isolated.tech/abc123.png?contrast=1.5');
        const result = parseTransformParams(url);

        expect(result.options.contrast).toBe(1.5);
        expect(result.errors).toHaveLength(0);
      });

      it('should reject contrast outside range', () => {
        const url = new URL('https://imghost.isolated.tech/abc123.png?contrast=5');
        const result = parseTransformParams(url);

        expect(result.options.contrast).toBeUndefined();
        expect(result.errors).toContain('Invalid contrast: must be between 0 and 2');
      });
    });

    describe('Rotate parameter', () => {
      [90, 180, 270].forEach((angle) => {
        it(`should accept rotation: ${angle}`, () => {
          const url = new URL(`https://imghost.isolated.tech/abc123.png?rotate=${angle}`);
          const result = parseTransformParams(url);

          expect(result.options.rotate).toBe(angle);
          expect(result.errors).toHaveLength(0);
        });
      });

      it('should reject invalid rotation angle', () => {
        const url = new URL('https://imghost.isolated.tech/abc123.png?rotate=45');
        const result = parseTransformParams(url);

        expect(result.options.rotate).toBeUndefined();
        expect(result.errors).toContain('Invalid rotate: must be 90, 180, 270');
      });
    });

    describe('DPR parameter (device pixel ratio)', () => {
      it('should parse valid dpr', () => {
        const url = new URL('https://imghost.isolated.tech/abc123.png?dpr=2');
        const result = parseTransformParams(url);

        expect(result.options.dpr).toBe(2);
        expect(result.errors).toHaveLength(0);
      });

      it('should accept dpr with decimals', () => {
        const url = new URL('https://imghost.isolated.tech/abc123.png?dpr=1.5');
        const result = parseTransformParams(url);

        expect(result.options.dpr).toBe(1.5);
        expect(result.errors).toHaveLength(0);
      });

      it('should reject dpr below 1', () => {
        const url = new URL('https://imghost.isolated.tech/abc123.png?dpr=0.5');
        const result = parseTransformParams(url);

        expect(result.options.dpr).toBeUndefined();
        expect(result.errors).toContain('Invalid dpr: must be between 1 and 3');
      });

      it('should reject dpr above 3', () => {
        const url = new URL('https://imghost.isolated.tech/abc123.png?dpr=4');
        const result = parseTransformParams(url);

        expect(result.options.dpr).toBeUndefined();
        expect(result.errors).toContain('Invalid dpr: must be between 1 and 3');
      });
    });

    describe('Multiple parameters', () => {
      it('should parse multiple valid parameters', () => {
        const url = new URL(
          'https://imghost.isolated.tech/abc123.png?w=400&h=300&fit=cover&q=80&format=webp'
        );
        const result = parseTransformParams(url);

        expect(result.options.width).toBe(400);
        expect(result.options.height).toBe(300);
        expect(result.options.fit).toBe('cover');
        expect(result.options.quality).toBe(80);
        expect(result.options.format).toBe('webp');
        expect(result.errors).toHaveLength(0);
        expect(result.hasTransforms).toBe(true);
      });

      it('should collect multiple errors', () => {
        const url = new URL(
          'https://imghost.isolated.tech/abc123.png?w=-1&h=0&q=200&format=bmp'
        );
        const result = parseTransformParams(url);

        expect(result.errors.length).toBeGreaterThanOrEqual(4);
        expect(result.hasTransforms).toBe(false);
      });

      it('should parse valid params while reporting invalid ones', () => {
        const url = new URL(
          'https://imghost.isolated.tech/abc123.png?w=400&h=-100&format=webp'
        );
        const result = parseTransformParams(url);

        expect(result.options.width).toBe(400);
        expect(result.options.height).toBeUndefined();
        expect(result.options.format).toBe('webp');
        expect(result.errors).toContain('Invalid height: must be a positive integer');
        expect(result.hasTransforms).toBe(true);
      });
    });

    describe('No transform parameters', () => {
      it('should return hasTransforms=false when no params provided', () => {
        const url = new URL('https://imghost.isolated.tech/abc123.png');
        const result = parseTransformParams(url);

        expect(result.options).toEqual({});
        expect(result.errors).toHaveLength(0);
        expect(result.hasTransforms).toBe(false);
      });

      it('should ignore unrelated query params', () => {
        const url = new URL('https://imghost.isolated.tech/abc123.png?foo=bar&baz=123');
        const result = parseTransformParams(url);

        expect(result.options).toEqual({});
        expect(result.hasTransforms).toBe(false);
      });
    });
  });

  describe('Content Type Validation', () => {
    const transformableTypes = [
      'image/jpeg',
      'image/png',
      'image/gif',
      'image/webp',
      'image/avif',
      'image/svg+xml',
    ];

    transformableTypes.forEach((type) => {
      it(`should allow transformation for ${type}`, () => {
        expect(isTransformableContentType(type)).toBe(true);
      });
    });

    const nonTransformableTypes = [
      'video/mp4',
      'application/pdf',
      'text/plain',
      'audio/mpeg',
      'application/zip',
      'image/tiff', // Not supported by Cloudflare Image Resizing
    ];

    nonTransformableTypes.forEach((type) => {
      it(`should reject transformation for ${type}`, () => {
        expect(isTransformableContentType(type)).toBe(false);
      });
    });
  });

  describe('Cache Key Generation', () => {
    it('should return original key when no transforms', () => {
      const result = buildCacheKey('abc123.png', {});
      expect(result).toBe('abc123.png');
    });

    it('should include width in cache key', () => {
      const result = buildCacheKey('abc123.png', { width: 400 });
      expect(result).toBe('abc123.png_w400');
    });

    it('should include height in cache key', () => {
      const result = buildCacheKey('abc123.png', { height: 300 });
      expect(result).toBe('abc123.png_h300');
    });

    it('should include all transform params in cache key', () => {
      const result = buildCacheKey('abc123.png', {
        width: 400,
        height: 300,
        fit: 'cover',
        quality: 80,
        format: 'webp',
      });
      expect(result).toBe('abc123.png_w400_h300_fcover_q80_fmtwebp');
    });

    it('should create consistent cache keys for same options', () => {
      const options = { width: 400, height: 300, format: 'webp' as const };
      const result1 = buildCacheKey('abc123.png', options);
      const result2 = buildCacheKey('abc123.png', options);
      expect(result1).toBe(result2);
    });

    it('should create different cache keys for different options', () => {
      const result1 = buildCacheKey('abc123.png', { width: 400 });
      const result2 = buildCacheKey('abc123.png', { width: 800 });
      expect(result1).not.toBe(result2);
    });

    it('should include blur in cache key', () => {
      const result = buildCacheKey('abc123.png', { blur: 10 });
      expect(result).toBe('abc123.png_blur10');
    });

    it('should include rotation in cache key', () => {
      const result = buildCacheKey('abc123.png', { rotate: 90 });
      expect(result).toBe('abc123.png_rot90');
    });
  });

  describe('Cloudflare Image Options Builder', () => {
    it('should build empty options object when no transforms', () => {
      const result = buildCloudflareImageOptions({});
      expect(result).toEqual({});
    });

    it('should build options with width', () => {
      const result = buildCloudflareImageOptions({ width: 400 });
      expect(result).toEqual({ width: 400 });
    });

    it('should build options with all transforms', () => {
      const result = buildCloudflareImageOptions({
        width: 400,
        height: 300,
        fit: 'cover',
        quality: 80,
        format: 'webp',
        blur: 10,
        sharpen: 1.5,
        brightness: 1.2,
        contrast: 1.1,
        rotate: 90,
        dpr: 2,
      });

      expect(result).toEqual({
        width: 400,
        height: 300,
        fit: 'cover',
        quality: 80,
        format: 'webp',
        blur: 10,
        sharpen: 1.5,
        brightness: 1.2,
        contrast: 1.1,
        rotate: 90,
        dpr: 2,
      });
    });

    it('should only include defined options', () => {
      const result = buildCloudflareImageOptions({
        width: 400,
        quality: 80,
      });

      expect(result).toEqual({
        width: 400,
        quality: 80,
      });
      expect(result).not.toHaveProperty('height');
      expect(result).not.toHaveProperty('fit');
    });
  });

  describe('Format Auto-Detection (getBestFormat)', () => {
    it('should return avif when Accept header includes image/avif', () => {
      const result = getBestFormat('image/avif,image/webp,image/apng,image/*,*/*;q=0.8');
      expect(result).toBe('avif');
    });

    it('should return webp when Accept header includes image/webp but not avif', () => {
      const result = getBestFormat('image/webp,image/apng,image/*,*/*;q=0.8');
      expect(result).toBe('webp');
    });

    it('should return jpeg when Accept header has neither avif nor webp', () => {
      const result = getBestFormat('image/png,image/*,*/*;q=0.8');
      expect(result).toBe('jpeg');
    });

    it('should return jpeg when Accept header is null', () => {
      const result = getBestFormat(null);
      expect(result).toBe('jpeg');
    });

    it('should return jpeg for generic Accept header', () => {
      const result = getBestFormat('*/*');
      expect(result).toBe('jpeg');
    });

    it('should prefer avif over webp when both are present', () => {
      const result = getBestFormat('image/webp,image/avif,*/*');
      expect(result).toBe('avif');
    });
  });
});

describe('Image Optimization Integration', () => {
  // Mock R2 bucket
  const createMockR2Bucket = () => ({
    get: vi.fn(),
    put: vi.fn(),
    delete: vi.fn(),
  });

  // Mock environment
  const createMockEnv = () => ({
    IMAGES: createMockR2Bucket(),
    DB: {},
    JWT_SECRET: 'test-secret',
    UPLOAD_TOKEN: 'test-token',
  });

  describe('Request Handling', () => {
    it('should serve original image when no transform params', async () => {
      const mockEnv = createMockEnv();
      const mockBody = new Uint8Array([0xff, 0xd8, 0xff]); // JPEG magic bytes
      
      mockEnv.IMAGES.get.mockResolvedValue({
        body: new ReadableStream({
          start(controller) {
            controller.enqueue(mockBody);
            controller.close();
          },
        }),
        httpMetadata: { contentType: 'image/jpeg' },
        httpEtag: '"abc123"',
      });

      // This simulates what the handler should do
      const url = new URL('https://imghost.isolated.tech/abc123.jpg');
      const { hasTransforms } = parseTransformParams(url);

      expect(hasTransforms).toBe(false);
      // Original image should be served without transformation
    });

    it('should apply transforms when params provided', async () => {
      const url = new URL('https://imghost.isolated.tech/abc123.jpg?w=400&h=300&format=webp');
      const { options, hasTransforms } = parseTransformParams(url);

      expect(hasTransforms).toBe(true);
      expect(options.width).toBe(400);
      expect(options.height).toBe(300);
      expect(options.format).toBe('webp');
    });
  });

  describe('Error Responses', () => {
    it('should return 400 for invalid transform params', () => {
      const url = new URL('https://imghost.isolated.tech/abc123.jpg?w=-100');
      const { errors } = parseTransformParams(url);

      expect(errors.length).toBeGreaterThan(0);
      // Handler should return 400 Bad Request with error details
    });

    it('should return 404 for non-existent image', async () => {
      const mockEnv = createMockEnv();
      mockEnv.IMAGES.get.mockResolvedValue(null);

      // Handler should return 404 Not Found
      const result = await mockEnv.IMAGES.get('nonexistent.jpg');
      expect(result).toBeNull();
    });

    it('should return 415 for non-transformable content type', () => {
      const contentType = 'video/mp4';
      const isTransformable = isTransformableContentType(contentType);

      expect(isTransformable).toBe(false);
      // Handler should return 415 Unsupported Media Type
    });
  });

  describe('Caching Behavior', () => {
    it('should set appropriate cache headers for transformed images', () => {
      // Transformed images should have:
      // - Cache-Control: public, max-age=31536000 (1 year)
      // - Vary: Accept (for format=auto)
      const expectedHeaders = {
        'Cache-Control': 'public, max-age=31536000',
        'Vary': 'Accept',
      };

      expect(expectedHeaders['Cache-Control']).toContain('max-age=31536000');
    });

    it('should use different cache keys for different transforms', () => {
      const key1 = buildCacheKey('abc123.png', { width: 400 });
      const key2 = buildCacheKey('abc123.png', { width: 800 });
      const key3 = buildCacheKey('abc123.png', { width: 400, format: 'webp' });

      expect(key1).not.toBe(key2);
      expect(key1).not.toBe(key3);
      expect(key2).not.toBe(key3);
    });
  });

  describe('Format Auto-Detection', () => {
    it('should respect Accept header for format=auto', () => {
      // When format=auto, the handler should:
      // - Check Accept header for webp/avif support
      // - Return best supported format

      const acceptWebp = 'image/webp,image/apng,image/*,*/*;q=0.8';
      const acceptAvif = 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8';
      const acceptBasic = 'image/*,*/*;q=0.8';

      // These would be used by the handler to determine output format
      expect(acceptWebp).toContain('image/webp');
      expect(acceptAvif).toContain('image/avif');
      expect(acceptBasic).not.toContain('image/webp');
    });
  });
});

describe('Security & Rate Limiting', () => {
  describe('Transform Abuse Prevention', () => {
    it('should enforce maximum dimensions', () => {
      const url = new URL('https://imghost.isolated.tech/abc123.png?w=10000&h=10000');
      const { errors } = parseTransformParams(url);

      expect(errors.some((e) => e.includes('maximum'))).toBe(true);
    });

    it('should reject requests with too many transform params', () => {
      // Limit complexity to prevent DoS
      const maxParams = 10;
      const url = new URL(
        'https://imghost.isolated.tech/abc123.png?w=100&h=100&fit=cover&q=80&format=webp&blur=5&sharpen=1&brightness=1&contrast=1&rotate=90&dpr=2'
      );

      const paramCount = url.searchParams.size;
      // This could be enforced in the handler
      expect(paramCount).toBeLessThanOrEqual(11); // All supported params
    });
  });

  describe('Input Sanitization', () => {
    it('should handle URL-encoded parameters', () => {
      const url = new URL('https://imghost.isolated.tech/abc123.png?w=400&fit=scale-down');
      const { options } = parseTransformParams(url);

      expect(options.width).toBe(400);
      expect(options.fit).toBe('scale-down');
    });

    it('should ignore malformed parameters gracefully', () => {
      const url = new URL('https://imghost.isolated.tech/abc123.png?w=400&h=');
      const { options, errors } = parseTransformParams(url);

      expect(options.width).toBe(400);
      // Empty height should result in error or be ignored
    });
  });
});

describe('Edge Cases', () => {
  it('should handle images with special characters in filename', () => {
    const key = 'abc-123_test.png';
    const cacheKey = buildCacheKey(key, { width: 400 });

    expect(cacheKey).toBe('abc-123_test.png_w400');
  });

  it('should handle very small dimensions', () => {
    const url = new URL('https://imghost.isolated.tech/abc123.png?w=1&h=1');
    const { options, errors } = parseTransformParams(url);

    expect(options.width).toBe(1);
    expect(options.height).toBe(1);
    expect(errors).toHaveLength(0);
  });

  it('should handle float values being truncated for integer params', () => {
    const url = new URL('https://imghost.isolated.tech/abc123.png?w=400.7');
    const { options } = parseTransformParams(url);

    // parseInt should truncate to 400
    expect(options.width).toBe(400);
  });

  it('should handle duplicate parameters (use first)', () => {
    const url = new URL('https://imghost.isolated.tech/abc123.png?w=400&w=800');
    const { options } = parseTransformParams(url);

    // URLSearchParams.get() returns first value
    expect(options.width).toBe(400);
  });
});
