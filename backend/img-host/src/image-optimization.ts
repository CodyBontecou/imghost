/**
 * Image Optimization Module
 *
 * Provides dynamic image optimization via URL parameters using Cloudflare Image Resizing.
 *
 * Supported parameters:
 * - w: width (1-8192px)
 * - h: height (1-8192px)
 * - fit: scale-down | contain | cover | crop | pad
 * - q: quality (1-100)
 * - format: webp | avif | jpeg | png | auto
 * - blur: blur radius (1-250)
 * - sharpen: sharpen amount (0-10)
 * - brightness: brightness multiplier (0-2)
 * - contrast: contrast multiplier (0-2)
 * - rotate: rotation degrees (90 | 180 | 270)
 * - dpr: device pixel ratio (1-3)
 */

// ============================================================================
// Types
// ============================================================================

export interface ImageTransformOptions {
  width?: number;
  height?: number;
  fit?: 'scale-down' | 'contain' | 'cover' | 'crop' | 'pad';
  quality?: number;
  format?: 'webp' | 'avif' | 'jpeg' | 'png' | 'auto';
  blur?: number;
  sharpen?: number;
  brightness?: number;
  contrast?: number;
  rotate?: 90 | 180 | 270;
  dpr?: number;
}

export interface ParsedTransformParams {
  options: ImageTransformOptions;
  errors: string[];
  hasTransforms: boolean;
}

// ============================================================================
// Constants
// ============================================================================

const MAX_DIMENSION = 8192;
const MIN_DIMENSION = 1;
const MAX_QUALITY = 100;
const MIN_QUALITY = 1;
const MAX_BLUR = 250;
const MIN_BLUR = 1;
const MAX_SHARPEN = 10;
const MIN_SHARPEN = 0;
const MAX_BRIGHTNESS = 2;
const MIN_BRIGHTNESS = 0;
const MAX_CONTRAST = 2;
const MIN_CONTRAST = 0;
const MAX_DPR = 3;
const MIN_DPR = 1;

const VALID_FIT_MODES = ['scale-down', 'contain', 'cover', 'crop', 'pad'] as const;
const VALID_FORMATS = ['webp', 'avif', 'jpeg', 'png', 'auto'] as const;
const VALID_ROTATIONS = [90, 180, 270] as const;

const TRANSFORMABLE_CONTENT_TYPES = [
  'image/jpeg',
  'image/png',
  'image/gif',
  'image/webp',
  'image/avif',
  'image/svg+xml',
];

// ============================================================================
// Parameter Parsing
// ============================================================================

/**
 * Parse transform parameters from URL search params
 */
export function parseTransformParams(url: URL): ParsedTransformParams {
  const options: ImageTransformOptions = {};
  const errors: string[] = [];

  // Parse width
  const w = url.searchParams.get('w');
  if (w !== null) {
    const width = parseInt(w, 10);
    if (isNaN(width) || width < MIN_DIMENSION) {
      errors.push('Invalid width: must be a positive integer');
    } else if (width > MAX_DIMENSION) {
      errors.push(`Invalid width: maximum is ${MAX_DIMENSION}px`);
    } else {
      options.width = width;
    }
  }

  // Parse height
  const h = url.searchParams.get('h');
  if (h !== null) {
    const height = parseInt(h, 10);
    if (isNaN(height) || height < MIN_DIMENSION) {
      errors.push('Invalid height: must be a positive integer');
    } else if (height > MAX_DIMENSION) {
      errors.push(`Invalid height: maximum is ${MAX_DIMENSION}px`);
    } else {
      options.height = height;
    }
  }

  // Parse fit mode
  const fit = url.searchParams.get('fit');
  if (fit !== null) {
    if (!VALID_FIT_MODES.includes(fit as typeof VALID_FIT_MODES[number])) {
      errors.push(`Invalid fit mode: must be one of ${VALID_FIT_MODES.join(', ')}`);
    } else {
      options.fit = fit as ImageTransformOptions['fit'];
    }
  }

  // Parse quality
  const q = url.searchParams.get('q');
  if (q !== null) {
    const quality = parseInt(q, 10);
    if (isNaN(quality) || quality < MIN_QUALITY || quality > MAX_QUALITY) {
      errors.push(`Invalid quality: must be between ${MIN_QUALITY} and ${MAX_QUALITY}`);
    } else {
      options.quality = quality;
    }
  }

  // Parse format
  const format = url.searchParams.get('format');
  if (format !== null) {
    if (!VALID_FORMATS.includes(format as typeof VALID_FORMATS[number])) {
      errors.push(`Invalid format: must be one of ${VALID_FORMATS.join(', ')}`);
    } else {
      options.format = format as ImageTransformOptions['format'];
    }
  }

  // Parse blur
  const blur = url.searchParams.get('blur');
  if (blur !== null) {
    const blurValue = parseInt(blur, 10);
    if (isNaN(blurValue) || blurValue < MIN_BLUR || blurValue > MAX_BLUR) {
      errors.push(`Invalid blur: must be between ${MIN_BLUR} and ${MAX_BLUR}`);
    } else {
      options.blur = blurValue;
    }
  }

  // Parse sharpen
  const sharpen = url.searchParams.get('sharpen');
  if (sharpen !== null) {
    const sharpenValue = parseFloat(sharpen);
    if (isNaN(sharpenValue) || sharpenValue < MIN_SHARPEN || sharpenValue > MAX_SHARPEN) {
      errors.push(`Invalid sharpen: must be between ${MIN_SHARPEN} and ${MAX_SHARPEN}`);
    } else {
      options.sharpen = sharpenValue;
    }
  }

  // Parse brightness
  const brightness = url.searchParams.get('brightness');
  if (brightness !== null) {
    const brightnessValue = parseFloat(brightness);
    if (isNaN(brightnessValue) || brightnessValue < MIN_BRIGHTNESS || brightnessValue > MAX_BRIGHTNESS) {
      errors.push(`Invalid brightness: must be between ${MIN_BRIGHTNESS} and ${MAX_BRIGHTNESS}`);
    } else {
      options.brightness = brightnessValue;
    }
  }

  // Parse contrast
  const contrast = url.searchParams.get('contrast');
  if (contrast !== null) {
    const contrastValue = parseFloat(contrast);
    if (isNaN(contrastValue) || contrastValue < MIN_CONTRAST || contrastValue > MAX_CONTRAST) {
      errors.push(`Invalid contrast: must be between ${MIN_CONTRAST} and ${MAX_CONTRAST}`);
    } else {
      options.contrast = contrastValue;
    }
  }

  // Parse rotate
  const rotate = url.searchParams.get('rotate');
  if (rotate !== null) {
    const rotateValue = parseInt(rotate, 10);
    if (!VALID_ROTATIONS.includes(rotateValue as typeof VALID_ROTATIONS[number])) {
      errors.push(`Invalid rotate: must be ${VALID_ROTATIONS.join(', ')}`);
    } else {
      options.rotate = rotateValue as 90 | 180 | 270;
    }
  }

  // Parse DPR (device pixel ratio)
  const dpr = url.searchParams.get('dpr');
  if (dpr !== null) {
    const dprValue = parseFloat(dpr);
    if (isNaN(dprValue) || dprValue < MIN_DPR || dprValue > MAX_DPR) {
      errors.push(`Invalid dpr: must be between ${MIN_DPR} and ${MAX_DPR}`);
    } else {
      options.dpr = dprValue;
    }
  }

  const hasTransforms = Object.keys(options).length > 0;

  return { options, errors, hasTransforms };
}

// ============================================================================
// Content Type Validation
// ============================================================================

/**
 * Check if a content type supports image transformation
 */
export function isTransformableContentType(contentType: string): boolean {
  return TRANSFORMABLE_CONTENT_TYPES.includes(contentType);
}

// ============================================================================
// Cache Key Generation
// ============================================================================

/**
 * Build a cache key that includes transform parameters
 */
export function buildCacheKey(originalKey: string, options: ImageTransformOptions): string {
  if (Object.keys(options).length === 0) {
    return originalKey;
  }

  const parts = [originalKey];
  if (options.width) parts.push(`w${options.width}`);
  if (options.height) parts.push(`h${options.height}`);
  if (options.fit) parts.push(`f${options.fit}`);
  if (options.quality) parts.push(`q${options.quality}`);
  if (options.format) parts.push(`fmt${options.format}`);
  if (options.blur) parts.push(`blur${options.blur}`);
  if (options.sharpen) parts.push(`sharp${options.sharpen}`);
  if (options.brightness) parts.push(`bri${options.brightness}`);
  if (options.contrast) parts.push(`con${options.contrast}`);
  if (options.rotate) parts.push(`rot${options.rotate}`);
  if (options.dpr) parts.push(`dpr${options.dpr}`);

  return parts.join('_');
}

// ============================================================================
// Cloudflare Image Options Builder
// ============================================================================

/**
 * Build Cloudflare Image Resizing options object
 */
export function buildCloudflareImageOptions(options: ImageTransformOptions): Record<string, unknown> {
  const cfOptions: Record<string, unknown> = {};

  if (options.width) cfOptions.width = options.width;
  if (options.height) cfOptions.height = options.height;
  if (options.fit) cfOptions.fit = options.fit;
  if (options.quality) cfOptions.quality = options.quality;
  if (options.format) cfOptions.format = options.format;
  if (options.blur) cfOptions.blur = options.blur;
  if (options.sharpen) cfOptions.sharpen = options.sharpen;
  if (options.brightness) cfOptions.brightness = options.brightness;
  if (options.contrast) cfOptions.contrast = options.contrast;
  if (options.rotate) cfOptions.rotate = options.rotate;
  if (options.dpr) cfOptions.dpr = options.dpr;

  return cfOptions;
}

// ============================================================================
// Accept Header Parsing (for format=auto)
// ============================================================================

/**
 * Determine the best output format based on Accept header
 */
export function getBestFormat(acceptHeader: string | null): 'avif' | 'webp' | 'jpeg' {
  if (!acceptHeader) return 'jpeg';

  // Prefer AVIF if supported (best compression)
  if (acceptHeader.includes('image/avif')) {
    return 'avif';
  }

  // Fall back to WebP if supported
  if (acceptHeader.includes('image/webp')) {
    return 'webp';
  }

  // Default to JPEG for maximum compatibility
  return 'jpeg';
}
