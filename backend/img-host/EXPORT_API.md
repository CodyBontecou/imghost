# Export API Documentation

This document describes the bulk export API endpoints for downloading user images as a ZIP archive.

## Overview

The export feature allows users to create and download a ZIP archive containing all of their uploaded images. The process is asynchronous and includes rate limiting to prevent abuse.

## Endpoints

### 1. Initiate Export Job

**POST** `/api/export`

Initiates a new export job for the authenticated user.

**Headers:**
- `Authorization: Bearer <access_token_or_api_key>`
- `X-API-Key: <api_key>` (alternative)

**Response (202 Accepted):**
```json
{
  "jobId": "export_abc12345",
  "status": "processing",
  "imageCount": 0
}
```

**Rate Limit:** 1 export per hour per user

**Error Responses:**
- `401 Unauthorized` - Missing or invalid API token
- `429 Too Many Requests` - Rate limit exceeded (must wait 1 hour between exports)

---

### 2. Check Export Status

**GET** `/api/export/{job_id}/status`

Checks the status of an export job.

**Headers:**
- `Authorization: Bearer <access_token_or_api_key>`
- `X-API-Key: <api_key>` (alternative)

**Response (200 OK):**

When processing:
```json
{
  "jobId": "export_abc12345",
  "status": "processing",
  "imageCount": 0
}
```

When completed:
```json
{
  "jobId": "export_abc12345",
  "status": "completed",
  "imageCount": 42,
  "archiveSize": 52428800,
  "downloadUrl": "https://backend.com/api/export/export_abc12345/download",
  "expiresAt": "2026-01-27T12:00:00Z"
}
```

When failed:
```json
{
  "jobId": "export_abc12345",
  "status": "failed",
  "imageCount": 0,
  "errorMessage": "No images found to export"
}
```

**Error Responses:**
- `401 Unauthorized` - Missing or invalid API token
- `403 Forbidden` - User does not own this export job
- `404 Not Found` - Export job not found

---

### 3. Download Export Archive

**GET** `/api/export/{job_id}/download`

Downloads the completed export archive.

**Headers:**
- `Authorization: Bearer <access_token_or_api_key>`
- `X-API-Key: <api_key>` (alternative)

**Response (200 OK):**
- Content-Type: `application/zip`
- Content-Disposition: `attachment; filename="export_{job_id}.zip"`
- Body: ZIP archive containing all user images and a manifest.json file

**Archive Contents:**
- `MANIFEST.JSON` - Metadata about the export including image list, sizes, and timestamps
- Individual image files with their original filenames

**Error Responses:**
- `400 Bad Request` - Export is not ready yet (still processing)
- `401 Unauthorized` - Missing or invalid API token
- `403 Forbidden` - User does not own this export job
- `404 Not Found` - Export job or archive not found
- `410 Gone` - Export has expired (archives expire after 24 hours)

---

## Workflow Example

```bash
# 1. Initiate export
curl -X POST https://your-domain.com/api/export \
  -H "Authorization: Bearer YOUR_API_TOKEN"

# Response: {"jobId":"export_abc12345","status":"processing","imageCount":0}

# 2. Check status (poll until status is "completed")
curl https://your-domain.com/api/export/export_abc12345/status \
  -H "Authorization: Bearer YOUR_API_TOKEN"

# Response: {"jobId":"export_abc12345","status":"completed",...}

# 3. Download archive
curl https://your-domain.com/api/export/export_abc12345/download \
  -H "Authorization: Bearer YOUR_API_TOKEN" \
  -o my_images.zip
```

---

## Implementation Details

### Rate Limiting
- Each user can only initiate 1 export per hour
- Rate limits are tracked in the `export_rate_limits` table

### Archive Expiration
- Export archives expire 24 hours after creation
- Expired archives are automatically cleaned up
- Attempting to download an expired archive returns a 410 Gone response

### Background Processing
- Export jobs are processed asynchronously using Cloudflare Workers `ctx.waitUntil()`
- For production at scale, consider using Cloudflare Queues or Durable Objects

### Archive Format
The current implementation uses a simplified archive format. For production, it's recommended to implement a proper ZIP format using a library like `fflate` or `jszip`.

The archive includes:
- `MANIFEST.JSON` - Contains metadata about all exported images
- All user images with their original filenames

---

## Database Schema

### export_jobs Table
```sql
CREATE TABLE export_jobs (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'processing',
  image_count INTEGER NOT NULL DEFAULT 0,
  archive_size INTEGER NOT NULL DEFAULT 0,
  download_url TEXT,
  expires_at INTEGER,
  error_message TEXT,
  created_at INTEGER NOT NULL,
  completed_at INTEGER,
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);
```

### export_rate_limits Table
```sql
CREATE TABLE export_rate_limits (
  user_id TEXT PRIMARY KEY,
  last_export_at INTEGER NOT NULL,
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);
```

---

## Future Enhancements

1. **Proper ZIP Format**: Implement a true ZIP archive using `fflate` library
2. **Selective Export**: Allow users to select specific images to export
3. **Export Filters**: Support filtering by date range, size, or content type
4. **Email Notifications**: Notify users when export is complete
5. **Progress Tracking**: Real-time progress updates during export processing
6. **Compression Options**: Allow users to choose compression levels
7. **Cloud Storage Integration**: Support exporting directly to user's cloud storage (Google Drive, Dropbox, etc.)
