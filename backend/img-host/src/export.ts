// Export service for creating ZIP archives of user images

import { zipSync, strToU8 } from 'fflate';
import { Database, Image } from './database';

export interface ExportManifest {
  export_date: string;
  image_count: number;
  total_size_bytes: number;
  images: Array<{
    id: string;
    filename: string;
    size_bytes: number;
    content_type: string;
    created_at: number;
  }>;
}

export class ExportService {
  constructor(
    private db: Database,
    private r2Bucket: R2Bucket
  ) {}

  /**
   * Process export job: fetch images, create ZIP, and store in R2
   */
  async processExportJob(jobId: string, userId: string): Promise<void> {
    try {
      // Get all images for user
      const images = await this.getAllUserImages(userId);

      if (images.length === 0) {
        await this.db.updateExportJob(
          jobId,
          'failed',
          0,
          0,
          undefined,
          undefined,
          'No images found to export'
        );
        return;
      }

      // Create ZIP archive
      const { zipBlob, totalSize } = await this.createZipArchive(images);

      // Upload ZIP to R2
      const zipKey = `exports/${jobId}.zip`;
      await this.r2Bucket.put(zipKey, zipBlob, {
        httpMetadata: {
          contentType: 'application/zip',
        },
        customMetadata: {
          jobId,
          userId,
          imageCount: images.length.toString(),
        },
      });

      // Calculate expiration (24 hours from now)
      const expiresAt = Date.now() + (24 * 60 * 60 * 1000);

      // Update job status
      await this.db.updateExportJob(
        jobId,
        'completed',
        images.length,
        totalSize,
        zipKey,
        expiresAt
      );
    } catch (error) {
      console.error('Export job failed:', error);
      await this.db.updateExportJob(
        jobId,
        'failed',
        0,
        0,
        undefined,
        undefined,
        error instanceof Error ? error.message : 'Unknown error'
      );
    }
  }

  /**
   * Get all images for a user
   */
  private async getAllUserImages(userId: string): Promise<Image[]> {
    const allImages: Image[] = [];
    let offset = 0;
    const limit = 100;

    while (true) {
      const batch = await this.db.getImagesByUserId(userId, limit, offset);
      if (batch.length === 0) break;

      allImages.push(...batch);
      offset += limit;

      if (batch.length < limit) break;
    }

    return allImages;
  }

  /**
   * Create a real ZIP archive from images using fflate.
   *
   * Each image is stored with DEFLATE compression (level 6).
   * A manifest.json is included at the root of the archive describing all exported files.
   */
  private async createZipArchive(images: Image[]): Promise<{ zipBlob: Blob; totalSize: number }> {
    const zipEntries: Record<string, [Uint8Array, { level: 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 }]> = {};
    let totalSize = 0;

    // Track seen filenames so we never write two entries with the same path
    const seenNames = new Map<string, number>();

    // Fetch all images from R2 and add to the zip entry map
    for (const image of images) {
      try {
        const object = await this.r2Bucket.get(image.r2_key);
        if (!object) continue;

        const data = new Uint8Array(await object.arrayBuffer());
        totalSize += data.byteLength;

        // Deduplicate filenames (e.g. two files both named "photo.jpg")
        let entryName = image.filename;
        const count = seenNames.get(entryName) ?? 0;
        if (count > 0) {
          const ext = entryName.includes('.') ? `.${entryName.split('.').pop()}` : '';
          const base = ext ? entryName.slice(0, -ext.length) : entryName;
          entryName = `${base}(${count})${ext}`;
        }
        seenNames.set(image.filename, count + 1);

        // Store images with compression; binary formats (JPEG/PNG/WEBP/GIF) are
        // already compressed so level 1 avoids wasting CPU for negligible gain.
        // For less-compressed formats (BMP, TIFF) use level 6.
        const alreadyCompressed = /image\/(jpeg|png|webp|gif|heic|heif|avif)|video\//.test(
          image.content_type
        );
        zipEntries[entryName] = [data, { level: alreadyCompressed ? 1 : 6 }];
      } catch (error) {
        console.error(`Failed to fetch image ${image.r2_key} for export:`, error);
      }
    }

    // Build manifest describing everything in the archive
    const manifest: ExportManifest = {
      export_date: new Date().toISOString(),
      image_count: images.length,
      total_size_bytes: totalSize,
      images: images.map(img => ({
        id: img.id,
        filename: img.filename,
        size_bytes: img.size_bytes,
        content_type: img.content_type,
        created_at: img.created_at,
      })),
    };

    zipEntries['manifest.json'] = [strToU8(JSON.stringify(manifest, null, 2)), { level: 6 }];

    // Produce the ZIP synchronously (Workers are single-threaded; zipSync is fine
    // for archives up to the Workers memory limit of ~128 MB)
    const zipped = zipSync(zipEntries);

    return { zipBlob: new Blob([zipped], { type: 'application/zip' }), totalSize };
  }

  /**
   * Get download URL for completed export
   */
  async getDownloadUrl(jobId: string, baseUrl: string): Promise<string> {
    return `${baseUrl}/api/export/${jobId}/download`;
  }

  /**
   * Cleanup expired exports from R2
   */
  async cleanupExpiredExports(): Promise<void> {
    // This would be called by a scheduled worker/cron
    await this.db.cleanupExpiredExports();
  }
}
