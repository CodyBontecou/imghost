// Content moderation utilities for abuse prevention

export type FlagType = 'nsfw' | 'copyright' | 'malware' | 'suspicious';
export type AbuseReason = 'nsfw' | 'copyright' | 'malware' | 'spam' | 'other';
export type BlocklistReason = 'csam' | 'copyright' | 'malware';

// ---------------------------------------------------------------------------
// SHA-256 hashing helper (Web Crypto API — available in Cloudflare Workers)
// ---------------------------------------------------------------------------

export async function computeFileSha256(buffer: ArrayBuffer): Promise<string> {
  const hashBuffer = await crypto.subtle.digest('SHA-256', buffer);
  return Array.from(new Uint8Array(hashBuffer))
    .map(b => b.toString(16).padStart(2, '0'))
    .join('');
}

// ---------------------------------------------------------------------------
// Hive Moderation Client
// ---------------------------------------------------------------------------

export interface HiveModerationResult {
  /** True when the content should be blocked (CSAM or high-confidence NSFW) */
  blocked: boolean;
  csam: boolean;
  nsfw: boolean;
  confidence: number;
  /** Set when the API returned an error; content is not blocked on errors */
  error?: string;
  /** Set when no API key is configured — call was skipped */
  skipped?: boolean;
}

const HIVE_CSAM_THRESHOLD = 0.9;
const HIVE_NSFW_THRESHOLD = 0.9;

export class HiveModerationClient {
  private readonly apiKey: string;
  private readonly fetch: typeof globalThis.fetch;

  constructor(apiKey: string, fetchFn: typeof globalThis.fetch = globalThis.fetch) {
    this.apiKey = apiKey;
    this.fetch = fetchFn;
  }

  async classify(buffer: ArrayBuffer): Promise<HiveModerationResult> {
    if (!this.apiKey) {
      return { blocked: false, csam: false, nsfw: false, confidence: 0, skipped: true };
    }

    try {
      const form = new FormData();
      form.append('media', new Blob([buffer]));

      const response = await this.fetch('https://api.hivemoderation.com/api/v2/task/sync', {
        method: 'POST',
        headers: { Authorization: `Token ${this.apiKey}` },
        body: form,
      });

      const data = await response.json() as {
        status: { code: number };
        output: Array<{ classes: Array<{ class: string; score: number }> }>;
      };

      const classes: Record<string, number> = {};
      for (const output of data.output ?? []) {
        for (const cls of output.classes ?? []) {
          classes[cls.class] = Math.max(classes[cls.class] ?? 0, cls.score);
        }
      }

      const csamScore = classes['yes_csam'] ?? 0;
      const nsfwScore = classes['yes_sexual_activity'] ?? 0;

      const csam = csamScore >= HIVE_CSAM_THRESHOLD;
      const nsfw = nsfwScore >= HIVE_NSFW_THRESHOLD;
      const confidence = Math.max(csamScore, nsfwScore);

      return { blocked: csam || nsfw, csam, nsfw, confidence };
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      console.error('[HiveModeration] API error (failing open):', message);
      return { blocked: false, csam: false, nsfw: false, confidence: 0, error: message };
    }
  }
}

// ---------------------------------------------------------------------------
// NCMEC CyberTipline Reporter
// ---------------------------------------------------------------------------

export interface NCMECReportParams {
  imageId: string;
  imageHash: string;
  uploadedAt: Date;
  uploaderIp: string;
}

export class NCMECReporter {
  private readonly apiKey: string;
  private readonly fetch: typeof globalThis.fetch;

  constructor(apiKey: string, fetchFn: typeof globalThis.fetch = globalThis.fetch) {
    this.apiKey = apiKey;
    this.fetch = fetchFn;
  }

  /** Reports suspected CSAM to NCMEC. Returns the NCMEC report ID, or null on failure. */
  async report(params: NCMECReportParams): Promise<string | null> {
    if (!this.apiKey) return null;

    try {
      const body = JSON.stringify({
        imageId: params.imageId,
        imageHash: params.imageHash,
        uploadedAt: params.uploadedAt.toISOString(),
        uploaderIp: params.uploaderIp,
      });

      const response = await this.fetch('https://api.ncmec.org/cybertipline/v1/report', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${this.apiKey}`,
        },
        body,
      });

      const data = await response.json() as { reportId?: string };
      return data.reportId ?? null;
    } catch (err) {
      console.error('[NCMEC] Reporting failed:', err);
      return null;
    }
  }
}

// ---------------------------------------------------------------------------
// DMCA Takedown
// ---------------------------------------------------------------------------

export interface DmcaTakedownParams {
  imageId: string;
  reportedUrl: string;
  complainantEmail: string;
  description: string;
  fileHash?: string;
}

export interface DmcaTakedown {
  id: string;
  image_id: string;
  reported_url: string;
  complainant_email: string;
  description: string;
  status: 'pending' | 'actioned' | 'counter_noticed' | 'dismissed';
  created_at: number;
}

export interface ContentFlagResult {
  flagged: boolean;
  flags: {
    type: FlagType;
    confidence: number;
    reason: string;
  }[];
}

export interface AbuseReport {
  id: string;
  reported_image_id: string;
  reported_user_id: string;
  reporter_user_id: string | null;
  reporter_ip: string | null;
  reason: AbuseReason;
  description: string | null;
  status: 'pending' | 'reviewing' | 'resolved' | 'dismissed';
  created_at: number;
}

export class ContentModerator {
  constructor(private db: D1Database) {}

  /**
   * Validate file type beyond just MIME type
   * Checks magic bytes to detect actual file type
   */
  async validateFileType(
    file: File,
    allowedTypes: string[] = [
      'image/jpeg', 'image/png', 'image/gif', 'image/webp', 'image/heic', 'image/heif',
      'video/mp4', 'video/quicktime', 'video/x-msvideo', 'video/webm',
      'audio/mpeg', 'audio/wav', 'audio/mp4', 'audio/ogg',
      'application/pdf', 'application/zip', 'application/gzip', 'application/json',
      'application/octet-stream', 'text/plain', 'text/html', 'text/css'
    ]
  ): Promise<{ valid: boolean; detectedType: string | null; reason?: string }> {
    // For non-image types, skip magic byte validation (just check MIME)
    if (!file.type.startsWith('image/')) {
      const allowedPrefixes = ['video/', 'audio/', 'application/', 'text/'];
      const isAllowed = allowedTypes.includes(file.type) || 
                       allowedPrefixes.some(prefix => file.type.startsWith(prefix));
      return {
        valid: isAllowed,
        detectedType: file.type,
        reason: isAllowed ? undefined : `MIME type ${file.type} not allowed`,
      };
    }
    
    // Check MIME type first for images
    if (!allowedTypes.includes(file.type)) {
      return {
        valid: false,
        detectedType: file.type,
        reason: `MIME type ${file.type} not allowed`,
      };
    }

    try {
      // Read first few bytes to check magic bytes
      const buffer = await file.slice(0, 12).arrayBuffer();
      const bytes = new Uint8Array(buffer);

      // Check magic bytes for common image formats
      const magicBytes = this.detectFileTypeByMagicBytes(bytes);

      if (!magicBytes) {
        // If we can't detect magic bytes but the MIME type is allowed, 
        // log it but allow the upload (don't reject legitimate unknown formats)
        console.warn('Unknown magic bytes for file type:', {
          mimeType: file.type,
          firstBytes: Array.from(bytes.slice(0, 12)).map(b => b.toString(16).padStart(2, '0')).join(' '),
        });
        
        // Only fail if the file claims to be an image type we should recognize
        const recognizedImageTypes = ['image/jpeg', 'image/png', 'image/gif', 'image/webp'];
        if (recognizedImageTypes.includes(file.type)) {
          return {
            valid: false,
            detectedType: null,
            reason: `Could not verify ${file.type} - magic bytes don't match expected format`,
          };
        }
        
        // For HEIC/HEIF and other types, be more lenient
        return {
          valid: true,
          detectedType: file.type,
        };
      }

      // Verify magic bytes match MIME type
      if (!this.mimeMatchesMagicBytes(file.type, magicBytes)) {
        return {
          valid: false,
          detectedType: magicBytes,
          reason: `MIME type ${file.type} does not match detected type ${magicBytes}`,
        };
      }

      return {
        valid: true,
        detectedType: magicBytes,
      };
    } catch (error) {
      console.error('Error validating file type:', error);
      return {
        valid: false,
        detectedType: null,
        reason: 'Error reading file bytes',
      };
    }
  }

  /**
   * Detect file type by magic bytes
   */
  private detectFileTypeByMagicBytes(bytes: Uint8Array): string | null {
    // JPEG: FF D8 FF
    if (bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) {
      return 'image/jpeg';
    }

    // PNG: 89 50 4E 47 0D 0A 1A 0A
    if (
      bytes[0] === 0x89 &&
      bytes[1] === 0x50 &&
      bytes[2] === 0x4e &&
      bytes[3] === 0x47 &&
      bytes[4] === 0x0d &&
      bytes[5] === 0x0a &&
      bytes[6] === 0x1a &&
      bytes[7] === 0x0a
    ) {
      return 'image/png';
    }

    // GIF: 47 49 46 38 (GIF8)
    if (
      bytes[0] === 0x47 &&
      bytes[1] === 0x49 &&
      bytes[2] === 0x46 &&
      bytes[3] === 0x38
    ) {
      return 'image/gif';
    }

    // WebP: RIFF ... WEBP
    if (
      bytes[0] === 0x52 &&
      bytes[1] === 0x49 &&
      bytes[2] === 0x46 &&
      bytes[3] === 0x46 &&
      bytes[8] === 0x57 &&
      bytes[9] === 0x45 &&
      bytes[10] === 0x42 &&
      bytes[11] === 0x50
    ) {
      return 'image/webp';
    }

    // HEIC/HEIF/AVIF: ftyp box with various brand codes
    // ISOBMFF container format: [size(4)][ftyp(4)][brand(4+)]
    if (
      bytes[4] === 0x66 && // 'f'
      bytes[5] === 0x74 && // 't'
      bytes[6] === 0x79 && // 'y'
      bytes[7] === 0x70    // 'p'
    ) {
      // Check for HEIC/HEIF/AVIF brands starting at byte 8
      const brandBytes = String.fromCharCode(bytes[8], bytes[9], bytes[10], bytes[11]);
      
      // HEIC brands (common in iOS)
      const heicBrands = ['heic', 'heix', 'mif1', 'msf1', 'miaf', 'MiHE', 'MiPr'];
      if (heicBrands.includes(brandBytes)) {
        return 'image/heic';
      }
      
      // HEIF brands
      const heifBrands = ['heif', 'heim', 'heis', 'hevs', 'hev1'];
      if (heifBrands.includes(brandBytes)) {
        return 'image/heif';
      }
      
      // AVIF brands
      const avifBrands = ['avif', 'avis', 'avio', 'MA1A', 'MA1B'];
      if (avifBrands.includes(brandBytes)) {
        return 'image/avif';
      }
      
      // MP4/MOV video (also uses ftyp)
      const videoBrands = ['isom', 'iso2', 'mp41', 'mp42', 'M4V ', 'M4A ', 'qt  ', 'avc1'];
      if (videoBrands.includes(brandBytes)) {
        return 'video/mp4';
      }
    }

    // Executable detection (simple check for common malware)
    // Windows PE: MZ
    if (bytes[0] === 0x4d && bytes[1] === 0x5a) {
      return 'application/x-msdownload';
    }

    // ELF: 7F 45 4C 46
    if (
      bytes[0] === 0x7f &&
      bytes[1] === 0x45 &&
      bytes[2] === 0x4c &&
      bytes[3] === 0x46
    ) {
      return 'application/x-elf';
    }

    return null;
  }

  /**
   * Check if MIME type matches detected magic bytes
   */
  private mimeMatchesMagicBytes(mimeType: string, detectedType: string): boolean {
    // Exact match
    if (mimeType === detectedType) {
      return true;
    }

    // Handle variants (e.g., image/jpg vs image/jpeg)
    if (mimeType === 'image/jpg' && detectedType === 'image/jpeg') {
      return true;
    }

    // Be lenient with common image formats - iOS sometimes sends wrong MIME type
    // If both are valid image formats, allow it (the actual data is what matters)
    const commonImageTypes = ['image/jpeg', 'image/jpg', 'image/png', 'image/gif', 'image/webp', 'image/bmp', 'image/tiff'];
    if (commonImageTypes.includes(mimeType) && commonImageTypes.includes(detectedType)) {
      // Log for monitoring but allow
      console.warn('MIME type mismatch (allowing):', { claimed: mimeType, detected: detectedType });
      return true;
    }

    // Handle HEIC/HEIF/AVIF variants (iOS may send any of these)
    const heicTypes = ['image/heic', 'image/heif', 'image/avif'];
    if (heicTypes.includes(mimeType) && heicTypes.includes(detectedType)) {
      return true;
    }
    
    // Also allow HEIC types to match common image types (iOS conversion edge cases)
    if ((heicTypes.includes(mimeType) && commonImageTypes.includes(detectedType)) ||
        (commonImageTypes.includes(mimeType) && heicTypes.includes(detectedType))) {
      console.warn('HEIC/image MIME type mismatch (allowing):', { claimed: mimeType, detected: detectedType });
      return true;
    }

    // Handle video formats (MP4/MOV/M4V often detected as generic video/mp4)
    const videoTypes = ['video/mp4', 'video/quicktime', 'video/x-m4v', 'video/mpeg4'];
    if (videoTypes.includes(mimeType) && videoTypes.includes(detectedType)) {
      return true;
    }

    return false;
  }

  /**
   * Scan image for suspicious patterns (basic malware detection)
   */
  async scanForMalware(file: File): Promise<ContentFlagResult> {
    const flags: { type: FlagType; confidence: number; reason: string }[] = [];

    try {
      // Check file extension
      const filename = file.name.toLowerCase();
      const suspiciousExtensions = ['.exe', '.bat', '.cmd', '.com', '.scr', '.vbs', '.js'];

      for (const ext of suspiciousExtensions) {
        if (filename.endsWith(ext)) {
          flags.push({
            type: 'malware',
            confidence: 1.0,
            reason: `Suspicious file extension: ${ext}`,
          });
        }
      }

      // Check for double extensions (e.g., image.jpg.exe)
      const parts = filename.split('.');
      if (parts.length > 2) {
        const secondLastExt = `.${parts[parts.length - 2]}`;
        if (suspiciousExtensions.includes(secondLastExt)) {
          flags.push({
            type: 'malware',
            confidence: 0.9,
            reason: 'Double extension detected',
          });
        }
      }

      // Validate file type
      const typeValidation = await this.validateFileType(file);
      if (!typeValidation.valid) {
        flags.push({
          type: 'malware',
          confidence: 0.8,
          reason: typeValidation.reason || 'Invalid file type',
        });
      }

      // Check for executable magic bytes in what claims to be an image
      if (
        typeValidation.detectedType === 'application/x-msdownload' ||
        typeValidation.detectedType === 'application/x-elf'
      ) {
        flags.push({
          type: 'malware',
          confidence: 1.0,
          reason: 'Executable file disguised as image',
        });
      }

      return {
        flagged: flags.length > 0,
        flags,
      };
    } catch (error) {
      console.error('Error scanning for malware:', error);
      return {
        flagged: false,
        flags: [],
      };
    }
  }

  /**
   * Flag content for review
   */
  async flagContent(
    imageId: string,
    flagType: FlagType,
    confidence: number,
    flaggedBy: string = 'system',
    metadata?: Record<string, any>
  ): Promise<void> {
    const id = crypto.randomUUID();
    const now = Date.now();

    await this.db
      .prepare(
        `INSERT INTO content_flags (id, image_id, flag_type, confidence_score, flagged_by, metadata, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)`
      )
      .bind(
        id,
        imageId,
        flagType,
        confidence,
        flaggedBy,
        metadata ? JSON.stringify(metadata) : null,
        now
      )
      .run();
  }

  /**
   * Get content flags for an image
   */
  async getContentFlags(imageId: string): Promise<
    {
      id: string;
      flag_type: FlagType;
      confidence_score: number;
      flagged_by: string;
      metadata: string | null;
      created_at: number;
    }[]
  > {
    const result = await this.db
      .prepare('SELECT * FROM content_flags WHERE image_id = ? ORDER BY created_at DESC')
      .bind(imageId)
      .all<{
        id: string;
        flag_type: FlagType;
        confidence_score: number;
        flagged_by: string;
        metadata: string | null;
        created_at: number;
      }>();

    return result.results || [];
  }

  /**
   * Submit an abuse report
   */
  async submitAbuseReport(
    imageId: string,
    reportedUserId: string,
    reporterUserId: string | null,
    reporterIp: string | null,
    reason: AbuseReason,
    description: string | null
  ): Promise<AbuseReport> {
    const id = crypto.randomUUID();
    const now = Date.now();

    await this.db
      .prepare(
        `INSERT INTO abuse_reports (id, reported_image_id, reported_user_id, reporter_user_id, reporter_ip, reason, description, status, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', ?)`
      )
      .bind(
        id,
        imageId,
        reportedUserId,
        reporterUserId,
        reporterIp,
        reason,
        description,
        now
      )
      .run();

    return {
      id,
      reported_image_id: imageId,
      reported_user_id: reportedUserId,
      reporter_user_id: reporterUserId,
      reporter_ip: reporterIp,
      reason,
      description,
      status: 'pending',
      created_at: now,
    };
  }

  /**
   * Get abuse reports for an image
   */
  async getAbuseReports(
    imageId: string
  ): Promise<AbuseReport[]> {
    const result = await this.db
      .prepare(
        'SELECT * FROM abuse_reports WHERE reported_image_id = ? ORDER BY created_at DESC'
      )
      .bind(imageId)
      .all<AbuseReport>();

    return result.results || [];
  }

  /**
   * Get pending abuse reports (for admin review)
   */
  async getPendingAbuseReports(limit = 50): Promise<AbuseReport[]> {
    const result = await this.db
      .prepare(
        'SELECT * FROM abuse_reports WHERE status = ? ORDER BY created_at DESC LIMIT ?'
      )
      .bind('pending', limit)
      .all<AbuseReport>();

    return result.results || [];
  }

  /**
   * Update abuse report status
   */
  async updateAbuseReportStatus(
    reportId: string,
    status: 'reviewing' | 'resolved' | 'dismissed',
    reviewedBy: string,
    resolutionNotes?: string
  ): Promise<void> {
    const now = Date.now();

    await this.db
      .prepare(
        'UPDATE abuse_reports SET status = ?, reviewed_at = ?, reviewed_by = ?, resolution_notes = ? WHERE id = ?'
      )
      .bind(status, now, reviewedBy, resolutionNotes || null, reportId)
      .run();
  }

  /**
   * Check for unusual upload patterns (potential abuse detection)
   */
  async detectUnusualUploadPattern(userId: string): Promise<{
    suspicious: boolean;
    reasons: string[];
  }> {
    const reasons: string[] = [];
    const now = Date.now();
    const oneHourAgo = now - 60 * 60 * 1000;
    const oneDayAgo = now - 24 * 60 * 60 * 1000;

    // Check upload rate in last hour
    const recentUploads = await this.db
      .prepare(
        'SELECT COUNT(*) as count FROM images WHERE user_id = ? AND created_at > ?'
      )
      .bind(userId, oneHourAgo)
      .first<{ count: number }>();

    if (recentUploads && recentUploads.count > 50) {
      reasons.push(`High upload rate: ${recentUploads.count} uploads in last hour`);
    }

    // Check for identical file sizes (potential spam)
    const identicalSizes = await this.db
      .prepare(
        `SELECT size_bytes, COUNT(*) as count
         FROM images
         WHERE user_id = ? AND created_at > ?
         GROUP BY size_bytes
         HAVING count > 10`
      )
      .bind(userId, oneDayAgo)
      .first<{ count: number }>();

    if (identicalSizes) {
      reasons.push(`Identical file sizes: ${identicalSizes.count} files with same size`);
    }

    // Check for rapid sequential uploads (bot-like behavior)
    const sequentialUploads = await this.db
      .prepare(
        `SELECT created_at FROM images
         WHERE user_id = ?
         ORDER BY created_at DESC
         LIMIT 10`
      )
      .bind(userId)
      .all<{ created_at: number }>();

    if (sequentialUploads.results && sequentialUploads.results.length >= 10) {
      const timestamps = sequentialUploads.results.map(r => r.created_at);
      const intervals = [];
      for (let i = 0; i < timestamps.length - 1; i++) {
        intervals.push(timestamps[i] - timestamps[i + 1]);
      }

      // If all intervals are very similar (within 1 second), it's suspicious
      const avgInterval = intervals.reduce((a, b) => a + b, 0) / intervals.length;
      const allSimilar = intervals.every(
        interval => Math.abs(interval - avgInterval) < 1000
      );

      if (allSimilar && avgInterval < 5000) {
        reasons.push('Bot-like upload pattern detected (too consistent)');
      }
    }

    return {
      suspicious: reasons.length > 0,
      reasons,
    };
  }

  // -------------------------------------------------------------------------
  // Hash Blocklist
  // -------------------------------------------------------------------------

  /**
   * Returns true if the given SHA-256 hash is on the blocklist.
   * Call this before storing any uploaded file.
   */
  async checkHashBlocklist(hash: string): Promise<boolean> {
    const row = await this.db
      .prepare('SELECT hash FROM blocked_hashes WHERE hash = ?')
      .bind(hash)
      .first<{ hash: string }>();
    return row !== null;
  }

  /**
   * Permanently blocks a file hash (e.g. after CSAM detection or DMCA takedown).
   */
  async addToHashBlocklist(hash: string, reason: BlocklistReason): Promise<void> {
    await this.db
      .prepare(
        'INSERT OR IGNORE INTO blocked_hashes (hash, reason, blocked_at) VALUES (?, ?, ?)'
      )
      .bind(hash, reason, Date.now())
      .run();
  }

  // -------------------------------------------------------------------------
  // DMCA Takedowns
  // -------------------------------------------------------------------------

  /**
   * Records a DMCA takedown request, marks the image as taken down, and
   * optionally adds the file hash to the blocklist.
   */
  async createDmcaTakedown(params: DmcaTakedownParams): Promise<DmcaTakedown> {
    const id = crypto.randomUUID();
    const now = Date.now();

    await this.db
      .prepare(
        `INSERT INTO dmca_takedowns
           (id, image_id, reported_url, complainant_email, description, status, created_at)
         VALUES (?, ?, ?, ?, ?, 'pending', ?)`
      )
      .bind(id, params.imageId, params.reportedUrl, params.complainantEmail, params.description, now)
      .run();

    // Mark the image so it's served as 451 Unavailable For Legal Reasons
    await this.db
      .prepare('UPDATE images SET dmca_taken_down = 1 WHERE id = ?')
      .bind(params.imageId)
      .run();

    // Blocklist the hash so the same content can never be re-uploaded
    if (params.fileHash) {
      await this.addToHashBlocklist(params.fileHash, 'copyright');
    }

    return {
      id,
      image_id: params.imageId,
      reported_url: params.reportedUrl,
      complainant_email: params.complainantEmail,
      description: params.description,
      status: 'pending',
      created_at: now,
    };
  }
}
