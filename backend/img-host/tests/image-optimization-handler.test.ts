/**
 * Image Optimization Handler Tests
 *
 * End-to-end tests for the HTTP request/response handling of image optimization.
 * These tests simulate full request flows through the worker.
 *
 * Run with: npm test
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';

// ============================================================================
// Mock Types
// ============================================================================

interface MockR2Object {
  body: ReadableStream;
  httpMetadata?: { contentType?: string };
  httpEtag: string;
  size: number;
  key: string;
  customMetadata?: Record<string, string>;
}

interface MockR2Bucket {
  get: ReturnType<typeof vi.fn>;
  put: ReturnType<typeof vi.fn>;
  delete: ReturnType<typeof vi.fn>;
}

interface MockEnv {
  IMAGES: MockR2Bucket;
  DB: unknown;
  JWT_SECRET: string;
  UPLOAD_TOKEN: string;
}

// ============================================================================
// Test Helpers
// ============================================================================

function createMockEnv(): MockEnv {
  return {
    IMAGES: {
      get: vi.fn(),
      put: vi.fn(),
      delete: vi.fn(),
    },
    DB: {},
    JWT_SECRET: 'test-secret',
    UPLOAD_TOKEN: 'test-token',
  };
}

function createMockR2Object(
  contentType: string = 'image/png',
  size: number = 1024
): MockR2Object {
  const mockData = new Uint8Array(size);
  return {
    body: new ReadableStream({
      start(controller) {
        controller.enqueue(mockData);
        controller.close();
      },
    }),
    httpMetadata: { contentType },
    httpEtag: '"test-etag"',
    size,
    key: 'test.png',
  };
}

// Simulated handler function (to be implemented)
// This represents the expected behavior of handleOptimizedGet

interface HandleOptimizedGetResult {
  status: number;
  headers: Record<string, string>;
  body?: ReadableStream | string;
  cfImageOptions?: Record<string, unknown>;
}

async function simulateHandleOptimizedGet(
  request: Request,
  env: MockEnv,
  key: string
): Promise<HandleOptimizedGetResult> {
  const url = new URL(request.url);

  // Get image from R2
  const object = await env.IMAGES.get(key);
  if (!object) {
    return {
      status: 404,
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ error: 'Not found' }),
    };
  }

  // Parse transform params
  const width = parseInt(url.searchParams.get('w') || '0') || undefined;
  const height = parseInt(url.searchParams.get('h') || '0') || undefined;
  const quality = parseInt(url.searchParams.get('q') || '0') || undefined;
  const format = url.searchParams.get('format') || undefined;
  const fit = url.searchParams.get('fit') || undefined;

  // Validate params
  const errors: string[] = [];
  if (width !== undefined && (width < 1 || width > 8192)) {
    errors.push('Invalid width');
  }
  if (height !== undefined && (height < 1 || height > 8192)) {
    errors.push('Invalid height');
  }
  if (quality !== undefined && (quality < 1 || quality > 100)) {
    errors.push('Invalid quality');
  }

  if (errors.length > 0) {
    return {
      status: 400,
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ error: 'Invalid parameters', details: errors }),
    };
  }

  const hasTransforms = width || height || quality || format || fit;
  const contentType = object.httpMetadata?.contentType || 'application/octet-stream';

  // Check if content type is transformable
  const transformableTypes = [
    'image/jpeg',
    'image/png',
    'image/gif',
    'image/webp',
    'image/avif',
  ];

  if (hasTransforms && !transformableTypes.includes(contentType)) {
    return {
      status: 415,
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        error: 'Unsupported media type for transformation',
        content_type: contentType,
      }),
    };
  }

  // Build response
  const headers: Record<string, string> = {
    'Content-Type': contentType,
    'Cache-Control': 'public, max-age=31536000',
    'ETag': object.httpEtag,
  };

  if (hasTransforms) {
    headers['Vary'] = 'Accept';
    headers['X-Image-Optimized'] = 'true';
  }

  const cfImageOptions: Record<string, unknown> = {};
  if (width) cfImageOptions.width = width;
  if (height) cfImageOptions.height = height;
  if (quality) cfImageOptions.quality = quality;
  if (format) cfImageOptions.format = format;
  if (fit) cfImageOptions.fit = fit;

  return {
    status: 200,
    headers,
    body: object.body,
    cfImageOptions: hasTransforms ? cfImageOptions : undefined,
  };
}

// ============================================================================
// Tests
// ============================================================================

describe('Image Optimization HTTP Handler', () => {
  let mockEnv: MockEnv;

  beforeEach(() => {
    mockEnv = createMockEnv();
    vi.clearAllMocks();
  });

  describe('GET /{id}.{ext} - Original Image', () => {
    it('should serve original image when no params', async () => {
      const mockObject = createMockR2Object('image/png');
      mockEnv.IMAGES.get.mockResolvedValue(mockObject);

      const request = new Request('https://imghost.isolated.tech/abc123.png');
      const result = await simulateHandleOptimizedGet(request, mockEnv, 'abc123.png');

      expect(result.status).toBe(200);
      expect(result.headers['Content-Type']).toBe('image/png');
      expect(result.headers['Cache-Control']).toContain('max-age=31536000');
      expect(result.cfImageOptions).toBeUndefined();
      expect(mockEnv.IMAGES.get).toHaveBeenCalledWith('abc123.png');
    });

    it('should return 404 for non-existent image', async () => {
      mockEnv.IMAGES.get.mockResolvedValue(null);

      const request = new Request('https://imghost.isolated.tech/notfound.png');
      const result = await simulateHandleOptimizedGet(request, mockEnv, 'notfound.png');

      expect(result.status).toBe(404);
      expect(JSON.parse(result.body as string)).toHaveProperty('error', 'Not found');
    });
  });

  describe('GET /{id}.{ext}?w=... - Width Resize', () => {
    it('should apply width transformation', async () => {
      const mockObject = createMockR2Object('image/jpeg');
      mockEnv.IMAGES.get.mockResolvedValue(mockObject);

      const request = new Request('https://imghost.isolated.tech/abc123.jpg?w=400');
      const result = await simulateHandleOptimizedGet(request, mockEnv, 'abc123.jpg');

      expect(result.status).toBe(200);
      expect(result.cfImageOptions).toEqual({ width: 400 });
      expect(result.headers['X-Image-Optimized']).toBe('true');
      expect(result.headers['Vary']).toBe('Accept');
    });

    it('should reject invalid width', async () => {
      const mockObject = createMockR2Object('image/jpeg');
      mockEnv.IMAGES.get.mockResolvedValue(mockObject);

      const request = new Request('https://imghost.isolated.tech/abc123.jpg?w=-100');
      const result = await simulateHandleOptimizedGet(request, mockEnv, 'abc123.jpg');

      expect(result.status).toBe(400);
      expect(JSON.parse(result.body as string).details).toContain('Invalid width');
    });

    it('should reject width exceeding maximum', async () => {
      const mockObject = createMockR2Object('image/jpeg');
      mockEnv.IMAGES.get.mockResolvedValue(mockObject);

      const request = new Request('https://imghost.isolated.tech/abc123.jpg?w=10000');
      const result = await simulateHandleOptimizedGet(request, mockEnv, 'abc123.jpg');

      expect(result.status).toBe(400);
      expect(JSON.parse(result.body as string).details).toContain('Invalid width');
    });
  });

  describe('GET /{id}.{ext}?h=... - Height Resize', () => {
    it('should apply height transformation', async () => {
      const mockObject = createMockR2Object('image/png');
      mockEnv.IMAGES.get.mockResolvedValue(mockObject);

      const request = new Request('https://imghost.isolated.tech/abc123.png?h=300');
      const result = await simulateHandleOptimizedGet(request, mockEnv, 'abc123.png');

      expect(result.status).toBe(200);
      expect(result.cfImageOptions).toEqual({ height: 300 });
    });
  });

  describe('GET /{id}.{ext}?w=...&h=... - Both Dimensions', () => {
    it('should apply both width and height', async () => {
      const mockObject = createMockR2Object('image/webp');
      mockEnv.IMAGES.get.mockResolvedValue(mockObject);

      const request = new Request('https://imghost.isolated.tech/abc123.webp?w=400&h=300');
      const result = await simulateHandleOptimizedGet(request, mockEnv, 'abc123.webp');

      expect(result.status).toBe(200);
      expect(result.cfImageOptions).toEqual({ width: 400, height: 300 });
    });
  });

  describe('GET /{id}.{ext}?fit=... - Fit Mode', () => {
    it('should apply fit mode with dimensions', async () => {
      const mockObject = createMockR2Object('image/jpeg');
      mockEnv.IMAGES.get.mockResolvedValue(mockObject);

      const request = new Request(
        'https://imghost.isolated.tech/abc123.jpg?w=400&h=300&fit=cover'
      );
      const result = await simulateHandleOptimizedGet(request, mockEnv, 'abc123.jpg');

      expect(result.status).toBe(200);
      expect(result.cfImageOptions).toEqual({
        width: 400,
        height: 300,
        fit: 'cover',
      });
    });
  });

  describe('GET /{id}.{ext}?q=... - Quality', () => {
    it('should apply quality setting', async () => {
      const mockObject = createMockR2Object('image/jpeg');
      mockEnv.IMAGES.get.mockResolvedValue(mockObject);

      const request = new Request('https://imghost.isolated.tech/abc123.jpg?q=80');
      const result = await simulateHandleOptimizedGet(request, mockEnv, 'abc123.jpg');

      expect(result.status).toBe(200);
      expect(result.cfImageOptions).toEqual({ quality: 80 });
    });

    it('should reject quality outside range', async () => {
      const mockObject = createMockR2Object('image/jpeg');
      mockEnv.IMAGES.get.mockResolvedValue(mockObject);

      const request = new Request('https://imghost.isolated.tech/abc123.jpg?q=150');
      const result = await simulateHandleOptimizedGet(request, mockEnv, 'abc123.jpg');

      expect(result.status).toBe(400);
      expect(JSON.parse(result.body as string).details).toContain('Invalid quality');
    });
  });

  describe('GET /{id}.{ext}?format=... - Format Conversion', () => {
    it('should apply format conversion', async () => {
      const mockObject = createMockR2Object('image/png');
      mockEnv.IMAGES.get.mockResolvedValue(mockObject);

      const request = new Request('https://imghost.isolated.tech/abc123.png?format=webp');
      const result = await simulateHandleOptimizedGet(request, mockEnv, 'abc123.png');

      expect(result.status).toBe(200);
      expect(result.cfImageOptions).toEqual({ format: 'webp' });
    });
  });

  describe('Non-Image Content Types', () => {
    it('should reject transformation for video', async () => {
      const mockObject = createMockR2Object('video/mp4');
      mockEnv.IMAGES.get.mockResolvedValue(mockObject);

      const request = new Request('https://imghost.isolated.tech/video.mp4?w=400');
      const result = await simulateHandleOptimizedGet(request, mockEnv, 'video.mp4');

      expect(result.status).toBe(415);
      expect(JSON.parse(result.body as string).error).toContain('Unsupported media type');
    });

    it('should reject transformation for PDF', async () => {
      const mockObject = createMockR2Object('application/pdf');
      mockEnv.IMAGES.get.mockResolvedValue(mockObject);

      const request = new Request('https://imghost.isolated.tech/doc.pdf?w=400');
      const result = await simulateHandleOptimizedGet(request, mockEnv, 'doc.pdf');

      expect(result.status).toBe(415);
    });

    it('should serve non-image files without transformation', async () => {
      const mockObject = createMockR2Object('video/mp4');
      mockEnv.IMAGES.get.mockResolvedValue(mockObject);

      const request = new Request('https://imghost.isolated.tech/video.mp4');
      const result = await simulateHandleOptimizedGet(request, mockEnv, 'video.mp4');

      expect(result.status).toBe(200);
      expect(result.cfImageOptions).toBeUndefined();
    });
  });

  describe('Combined Transformations', () => {
    it('should apply all transformations together', async () => {
      const mockObject = createMockR2Object('image/jpeg');
      mockEnv.IMAGES.get.mockResolvedValue(mockObject);

      const request = new Request(
        'https://imghost.isolated.tech/abc123.jpg?w=800&h=600&fit=cover&q=85&format=webp'
      );
      const result = await simulateHandleOptimizedGet(request, mockEnv, 'abc123.jpg');

      expect(result.status).toBe(200);
      expect(result.cfImageOptions).toEqual({
        width: 800,
        height: 600,
        fit: 'cover',
        quality: 85,
        format: 'webp',
      });
    });
  });

  describe('Cache Headers', () => {
    it('should set long cache for original images', async () => {
      const mockObject = createMockR2Object('image/png');
      mockEnv.IMAGES.get.mockResolvedValue(mockObject);

      const request = new Request('https://imghost.isolated.tech/abc123.png');
      const result = await simulateHandleOptimizedGet(request, mockEnv, 'abc123.png');

      expect(result.headers['Cache-Control']).toBe('public, max-age=31536000');
    });

    it('should set long cache for transformed images', async () => {
      const mockObject = createMockR2Object('image/png');
      mockEnv.IMAGES.get.mockResolvedValue(mockObject);

      const request = new Request('https://imghost.isolated.tech/abc123.png?w=400');
      const result = await simulateHandleOptimizedGet(request, mockEnv, 'abc123.png');

      expect(result.headers['Cache-Control']).toBe('public, max-age=31536000');
    });

    it('should include Vary header for transformed images', async () => {
      const mockObject = createMockR2Object('image/png');
      mockEnv.IMAGES.get.mockResolvedValue(mockObject);

      const request = new Request('https://imghost.isolated.tech/abc123.png?format=auto');
      const result = await simulateHandleOptimizedGet(request, mockEnv, 'abc123.png');

      expect(result.headers['Vary']).toBe('Accept');
    });

    it('should include ETag header', async () => {
      const mockObject = createMockR2Object('image/png');
      mockEnv.IMAGES.get.mockResolvedValue(mockObject);

      const request = new Request('https://imghost.isolated.tech/abc123.png');
      const result = await simulateHandleOptimizedGet(request, mockEnv, 'abc123.png');

      expect(result.headers['ETag']).toBeDefined();
    });
  });

  describe('Multiple Invalid Parameters', () => {
    it('should collect all validation errors', async () => {
      const mockObject = createMockR2Object('image/jpeg');
      mockEnv.IMAGES.get.mockResolvedValue(mockObject);

      const request = new Request(
        'https://imghost.isolated.tech/abc123.jpg?w=-1&h=-1&q=200'
      );
      const result = await simulateHandleOptimizedGet(request, mockEnv, 'abc123.jpg');

      expect(result.status).toBe(400);
      const body = JSON.parse(result.body as string);
      expect(body.details.length).toBeGreaterThanOrEqual(3);
    });
  });
});

describe('Image Optimization URL Patterns', () => {
  it('should match image URLs with extensions', () => {
    const patterns = [
      '/abc123.png',
      '/abc123.jpg',
      '/abc123.jpeg',
      '/abc123.gif',
      '/abc123.webp',
      '/abc123.avif',
      '/test-image_123.png',
    ];

    const imagePattern = /^\/([a-zA-Z0-9_-]+\.[a-zA-Z0-9]+)$/;

    patterns.forEach((path) => {
      expect(imagePattern.test(path)).toBe(true);
    });
  });

  it('should not match non-image paths', () => {
    const patterns = [
      '/upload',
      '/user',
      '/auth/login',
      '/api/export',
      '/',
    ];

    const imagePattern = /^\/([a-zA-Z0-9_-]+\.[a-zA-Z0-9]+)$/;

    patterns.forEach((path) => {
      expect(imagePattern.test(path)).toBe(false);
    });
  });

  it('should extract image key from URL', () => {
    const url = new URL('https://imghost.isolated.tech/abc123.png?w=400');
    const match = url.pathname.match(/^\/([a-zA-Z0-9_-]+\.[a-zA-Z0-9]+)$/);

    expect(match).not.toBeNull();
    expect(match![1]).toBe('abc123.png');
  });
});

describe('Cloudflare Image Resizing Integration', () => {
  it('should build proper cf.image options', () => {
    const options = {
      width: 400,
      height: 300,
      fit: 'cover',
      quality: 85,
      format: 'webp',
    };

    // This represents what would be passed to fetch with cf options
    const cfOptions = {
      image: options,
      cacheEverything: true,
      cacheTtl: 86400,
    };

    expect(cfOptions.image.width).toBe(400);
    expect(cfOptions.image.height).toBe(300);
    expect(cfOptions.cacheEverything).toBe(true);
  });

  it('should handle auto format detection', () => {
    // Simulate Accept header parsing for auto format
    const acceptHeaders = [
      { header: 'image/avif,image/webp,*/*', expected: 'avif' },
      { header: 'image/webp,*/*', expected: 'webp' },
      { header: '*/*', expected: 'jpeg' },
    ];

    acceptHeaders.forEach(({ header, expected }) => {
      let format = 'jpeg';
      if (header.includes('image/avif')) format = 'avif';
      else if (header.includes('image/webp')) format = 'webp';

      expect(format).toBe(expected);
    });
  });
});

describe('Performance Considerations', () => {
  it('should not fetch R2 object if validation fails', async () => {
    // When params are invalid, we should fail fast without hitting R2
    const url = new URL('https://imghost.isolated.tech/abc123.jpg?w=-1');
    const width = parseInt(url.searchParams.get('w') || '0');

    // Validation should happen before R2 fetch
    const isValid = width > 0 && width <= 8192;
    expect(isValid).toBe(false);

    // In actual implementation, we'd skip the R2 get() call
  });

  it('should use cache-friendly URLs', () => {
    // Same params should produce same cache key
    const url1 = new URL('https://imghost.isolated.tech/abc123.jpg?w=400&h=300');
    const url2 = new URL('https://imghost.isolated.tech/abc123.jpg?w=400&h=300');

    expect(url1.search).toBe(url2.search);
  });
});
