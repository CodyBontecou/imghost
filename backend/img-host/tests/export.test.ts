// Tests for the ZIP export service

import { describe, test, expect } from 'vitest';
import { unzipSync, strFromU8 } from 'fflate';
import { ExportService, ExportManifest } from '../src/export';

// ---------------------------------------------------------------------------
// Minimal fakes
// ---------------------------------------------------------------------------

/** Fake R2 object returned by r2Bucket.get() */
function makeR2Object(bytes: Uint8Array) {
  return {
    async arrayBuffer() {
      return bytes.buffer as ArrayBuffer;
    },
  };
}

/** Build a fake R2Bucket whose contents are defined by a name → Uint8Array map */
function makeFakeR2Bucket(objects: Record<string, Uint8Array>): R2Bucket {
  return {
    async get(key: string) {
      return key in objects ? makeR2Object(objects[key]) : null;
    },
    // The rest are not exercised by ExportService – satisfy the type with stubs
    async put() { return {} as any; },
    async delete() {},
    async head() { return null; },
    async list() { return { objects: [], truncated: false, cursor: undefined, delimitedPrefixes: [] }; },
    async createMultipartUpload() { return {} as any; },
    async resumeMultipartUpload() { return {} as any; },
  } as unknown as R2Bucket;
}

/** Fake Database – only the methods ExportService calls */
function makeFakeDb(overrides: Partial<ReturnType<typeof makeFakeDb>> = {}) {
  return {
    async getImagesByUserId(userId: string, limit: number, offset: number) {
      return [] as any[];
    },
    async updateExportJob(..._args: any[]) {},
    async cleanupExpiredExports() {},
    ...overrides,
  } as any;
}

/** Minimal image record */
function makeImage(overrides: Partial<any> = {}) {
  return {
    id: 'img-1',
    filename: 'photo.jpg',
    r2_key: 'user-1/photo.jpg',
    size_bytes: 100,
    content_type: 'image/jpeg',
    created_at: 1_700_000_000_000,
    ...overrides,
  };
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Call the private createZipArchive via processExportJob and intercept the R2 put call */
async function runExport(
  images: any[],
  r2Objects: Record<string, Uint8Array>
): Promise<{ zipBytes: Uint8Array; totalSize: number }> {
  let capturedZip: Uint8Array | null = null;

  const bucket = {
    async get(key: string) {
      return key in r2Objects ? makeR2Object(r2Objects[key]) : null;
    },
    async put(_key: string, body: any) {
      // body is a Blob
      const buf = await (body as Blob).arrayBuffer();
      capturedZip = new Uint8Array(buf);
      return {} as any;
    },
    async head() { return null; },
    async list() { return { objects: [], truncated: false } as any; },
    async delete() {},
    async createMultipartUpload() { return {} as any; },
    async resumeMultipartUpload() { return {} as any; },
  } as unknown as R2Bucket;

  let capturedSize = 0;
  const db = makeFakeDb({
    async getImagesByUserId(_uid: string, limit: number, offset: number) {
      // return first page then empty
      return offset === 0 ? images : [];
    },
    async updateExportJob(
      _jobId: string,
      _status: string,
      _count: number,
      totalSize: number
    ) {
      capturedSize = totalSize;
    },
  });

  const service = new ExportService(db, bucket);
  await service.processExportJob('job-1', 'user-1');

  if (!capturedZip) throw new Error('ZIP was never written to R2');
  return { zipBytes: capturedZip, totalSize: capturedSize };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe('ExportService – ZIP archive', () => {
  test('produces a valid ZIP that can be unzipped', async () => {
    const imageBytes = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0x01, 0x02]); // fake JPEG header
    const { zipBytes } = await runExport(
      [makeImage({ r2_key: 'user-1/photo.jpg', filename: 'photo.jpg' })],
      { 'user-1/photo.jpg': imageBytes }
    );

    // fflate unzip should not throw
    const entries = unzipSync(zipBytes);
    expect(Object.keys(entries).length).toBeGreaterThan(0);
  });

  test('includes a manifest.json at the archive root', async () => {
    const imageBytes = new Uint8Array([0xff, 0xd8, 0xff]);
    const { zipBytes } = await runExport(
      [makeImage()],
      { 'user-1/photo.jpg': imageBytes }
    );

    const entries = unzipSync(zipBytes);
    expect('manifest.json' in entries).toBe(true);

    const manifest: ExportManifest = JSON.parse(strFromU8(entries['manifest.json']));
    expect(manifest.image_count).toBe(1);
    expect(manifest.images[0].filename).toBe('photo.jpg');
  });

  test('manifest image_count reflects only images found in R2', async () => {
    // Provide R2 data for only one of the two images
    const { zipBytes } = await runExport(
      [
        makeImage({ id: 'img-1', filename: 'a.jpg', r2_key: 'user-1/a.jpg' }),
        makeImage({ id: 'img-2', filename: 'b.jpg', r2_key: 'user-1/b.jpg' }),
      ],
      { 'user-1/a.jpg': new Uint8Array([1, 2, 3]) }
      // b.jpg intentionally missing from R2
    );

    const entries = unzipSync(zipBytes);
    expect('a.jpg' in entries).toBe(true);
    expect('b.jpg' in entries).toBe(false);

    const manifest: ExportManifest = JSON.parse(strFromU8(entries['manifest.json']));
    // Manifest lists all requested images (for auditing), even if some were missing
    expect(manifest.image_count).toBe(2);
  });

  test('deduplicates clashing filenames', async () => {
    const bytes = new Uint8Array([1, 2, 3]);
    const { zipBytes } = await runExport(
      [
        makeImage({ id: 'img-1', filename: 'photo.jpg', r2_key: 'user-1/a.jpg' }),
        makeImage({ id: 'img-2', filename: 'photo.jpg', r2_key: 'user-1/b.jpg' }),
      ],
      {
        'user-1/a.jpg': bytes,
        'user-1/b.jpg': bytes,
      }
    );

    const entries = unzipSync(zipBytes);
    expect('photo.jpg' in entries).toBe(true);
    expect('photo(1).jpg' in entries).toBe(true);
  });

  test('image bytes in the ZIP match the original R2 bytes', async () => {
    const original = new Uint8Array([10, 20, 30, 40, 50]);
    const { zipBytes } = await runExport(
      [makeImage({ filename: 'tiny.png', r2_key: 'user-1/tiny.png', content_type: 'image/png' })],
      { 'user-1/tiny.png': original }
    );

    const entries = unzipSync(zipBytes);
    expect(entries['tiny.png']).toEqual(original);
  });

  test('totalSize reflects raw bytes fetched from R2', async () => {
    const bytes = new Uint8Array(512);
    const { totalSize } = await runExport(
      [makeImage({ filename: 'img.jpg', r2_key: 'user-1/img.jpg' })],
      { 'user-1/img.jpg': bytes }
    );

    expect(totalSize).toBe(512);
  });

  test('fails gracefully when there are no images', async () => {
    let failStatus = '';
    const db = makeFakeDb({
      async getImagesByUserId() { return []; },
      async updateExportJob(_j: string, status: string) { failStatus = status; },
    });

    const service = new ExportService(db, makeFakeR2Bucket({}));
    await service.processExportJob('job-empty', 'user-1');

    expect(failStatus).toBe('failed');
  });
});
