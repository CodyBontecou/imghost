// Authentication utilities

// JWT payload interface
export interface JWTPayload {
  sub: string; // user_id
  email: string;
  tier: string;
  iat: number; // issued at
  exp: number; // expiration
  type: 'access' | 'refresh';
}

export class Auth {
  private static readonly PBKDF2_ITERATIONS = 100000;
  private static readonly PBKDF2_KEY_LENGTH = 32;
  private static readonly SALT_LENGTH = 16;

  // JWT secret should be set as environment variable
  // For now, we'll use a derived key from env or generate one

  /**
   * Hash a password using PBKDF2 (more secure than SHA-256)
   * Format: salt:hash (both base64 encoded)
   */
  static async hashPassword(password: string): Promise<string> {
    const encoder = new TextEncoder();

    // Generate random salt
    const salt = new Uint8Array(this.SALT_LENGTH);
    crypto.getRandomValues(salt);

    // Import password as key
    const keyMaterial = await crypto.subtle.importKey(
      'raw',
      encoder.encode(password),
      'PBKDF2',
      false,
      ['deriveBits']
    );

    // Derive key using PBKDF2
    const hashBuffer = await crypto.subtle.deriveBits(
      {
        name: 'PBKDF2',
        salt: salt,
        iterations: this.PBKDF2_ITERATIONS,
        hash: 'SHA-256'
      },
      keyMaterial,
      this.PBKDF2_KEY_LENGTH * 8
    );

    // Convert to base64 and combine salt:hash
    const saltB64 = this.arrayBufferToBase64(salt);
    const hashB64 = this.arrayBufferToBase64(hashBuffer);

    return `${saltB64}:${hashB64}`;
  }

  /**
   * Verify a password against a PBKDF2 hash
   */
  static async verifyPassword(password: string, storedHash: string): Promise<boolean> {
    try {
      const [saltB64, hashB64] = storedHash.split(':');
      if (!saltB64 || !hashB64) {
        // Fallback for old SHA-256 hashes (backward compatibility)
        return this.verifyLegacySHA256(password, storedHash);
      }

      const encoder = new TextEncoder();
      const salt = this.base64ToArrayBuffer(saltB64);
      const expectedHash = this.base64ToArrayBuffer(hashB64);

      // Import password as key
      const keyMaterial = await crypto.subtle.importKey(
        'raw',
        encoder.encode(password),
        'PBKDF2',
        false,
        ['deriveBits']
      );

      // Derive key using same parameters
      const hashBuffer = await crypto.subtle.deriveBits(
        {
          name: 'PBKDF2',
          salt: new Uint8Array(salt),
          iterations: this.PBKDF2_ITERATIONS,
          hash: 'SHA-256'
        },
        keyMaterial,
        this.PBKDF2_KEY_LENGTH * 8
      );

      // Constant-time comparison
      return this.constantTimeEqual(new Uint8Array(hashBuffer), new Uint8Array(expectedHash));
    } catch (error) {
      console.error('Password verification error:', error);
      return false;
    }
  }

  /**
   * Legacy SHA-256 verification for backward compatibility
   */
  private static async verifyLegacySHA256(password: string, hash: string): Promise<boolean> {
    const encoder = new TextEncoder();
    const data = encoder.encode(password);
    const hashBuffer = await crypto.subtle.digest('SHA-256', data);
    const hashArray = Array.from(new Uint8Array(hashBuffer));
    const passwordHash = hashArray.map(b => b.toString(16).padStart(2, '0')).join('');
    return passwordHash === hash;
  }

  /**
   * Generate a secure API token (for backward compatibility)
   */
  static generateApiToken(): string {
    return crypto.randomUUID();
  }

  /**
   * Generate a secure random token for email verification or password reset
   */
  static generateSecureToken(): string {
    const array = new Uint8Array(32);
    crypto.getRandomValues(array);
    return this.arrayBufferToBase64(array);
  }

  /**
   * Create a JWT token
   */
  static async createJWT(
    payload: Omit<JWTPayload, 'iat' | 'exp'>,
    expiresInSeconds: number,
    secret: string
  ): Promise<string> {
    const header = {
      alg: 'HS256',
      typ: 'JWT'
    };

    const now = Math.floor(Date.now() / 1000);
    const fullPayload: JWTPayload = {
      ...payload,
      iat: now,
      exp: now + expiresInSeconds
    };

    const encodedHeader = this.base64UrlEncode(JSON.stringify(header));
    const encodedPayload = this.base64UrlEncode(JSON.stringify(fullPayload));
    const signatureInput = `${encodedHeader}.${encodedPayload}`;

    const signature = await this.signHS256(signatureInput, secret);
    const encodedSignature = this.base64UrlEncode(signature);

    return `${signatureInput}.${encodedSignature}`;
  }

  /**
   * Verify and decode a JWT token
   */
  static async verifyJWT(token: string, secret: string): Promise<JWTPayload | null> {
    try {
      const parts = token.split('.');
      if (parts.length !== 3) return null;

      const [encodedHeader, encodedPayload, encodedSignature] = parts;
      const signatureInput = `${encodedHeader}.${encodedPayload}`;

      // Verify signature
      const expectedSignature = await this.signHS256(signatureInput, secret);
      const expectedEncodedSignature = this.base64UrlEncode(expectedSignature);

      if (encodedSignature !== expectedEncodedSignature) {
        return null;
      }

      // Decode and validate payload
      const payload = JSON.parse(this.base64UrlDecode(encodedPayload)) as JWTPayload;

      // Check expiration
      const now = Math.floor(Date.now() / 1000);
      if (payload.exp < now) {
        return null;
      }

      return payload;
    } catch (error) {
      console.error('JWT verification error:', error);
      return null;
    }
  }

  /**
   * Sign data using HMAC SHA-256
   */
  private static async signHS256(data: string, secret: string): Promise<ArrayBuffer> {
    const encoder = new TextEncoder();
    const key = await crypto.subtle.importKey(
      'raw',
      encoder.encode(secret),
      { name: 'HMAC', hash: 'SHA-256' },
      false,
      ['sign']
    );

    return await crypto.subtle.sign('HMAC', key, encoder.encode(data));
  }

  /**
   * Extract bearer token from Authorization header
   */
  static extractBearerToken(authHeader: string | null): string | null {
    if (!authHeader) return null;
    const match = authHeader.match(/^Bearer\s+(.+)$/i);
    return match ? match[1] : null;
  }

  // Utility functions for encoding/decoding

  private static arrayBufferToBase64(buffer: ArrayBuffer | Uint8Array): string {
    const bytes = buffer instanceof Uint8Array ? buffer : new Uint8Array(buffer);
    let binary = '';
    for (let i = 0; i < bytes.byteLength; i++) {
      binary += String.fromCharCode(bytes[i]);
    }
    return btoa(binary);
  }

  private static base64ToArrayBuffer(base64: string): ArrayBuffer {
    const binary = atob(base64);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) {
      bytes[i] = binary.charCodeAt(i);
    }
    return bytes.buffer;
  }

  private static base64UrlEncode(data: string | ArrayBuffer): string {
    let base64: string;
    if (typeof data === 'string') {
      base64 = btoa(data);
    } else {
      base64 = this.arrayBufferToBase64(data);
    }
    return base64.replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, '');
  }

  private static base64UrlDecode(base64Url: string): string {
    let base64 = base64Url.replace(/-/g, '+').replace(/_/g, '/');
    while (base64.length % 4) {
      base64 += '=';
    }
    return atob(base64);
  }

  /**
   * Constant-time comparison to prevent timing attacks
   */
  private static constantTimeEqual(a: Uint8Array, b: Uint8Array): boolean {
    if (a.length !== b.length) return false;

    let result = 0;
    for (let i = 0; i < a.length; i++) {
      result |= a[i] ^ b[i];
    }
    return result === 0;
  }
}
