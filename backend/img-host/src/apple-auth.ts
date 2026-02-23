// Apple Sign-In verification utilities

interface ApplePublicKey {
  kty: string;
  kid: string;
  use: string;
  alg: string;
  n: string;
  e: string;
}

interface AppleKeysResponse {
  keys: ApplePublicKey[];
}

export interface AppleTokenPayload {
  iss: string;              // "https://appleid.apple.com"
  aud: string;              // Your app's Bundle ID
  exp: number;              // Expiration timestamp
  iat: number;              // Issued at timestamp
  sub: string;              // Apple user ID (stable identifier)
  c_hash?: string;          // Authorization code hash
  email?: string;           // User's email (may be private relay)
  email_verified?: string;  // "true" or "false"
  is_private_email?: string; // "true" if using Hide My Email
  auth_time: number;        // Authentication timestamp
  nonce_supported: boolean;
}

export class AppleAuth {
  private static cachedKeys: ApplePublicKey[] | null = null;
  private static cacheExpiry: number = 0;

  /**
   * Fetch Apple's public keys (cached for 24 hours)
   */
  static async getApplePublicKeys(): Promise<ApplePublicKey[]> {
    const now = Date.now();
    if (this.cachedKeys && now < this.cacheExpiry) {
      return this.cachedKeys;
    }

    const response = await fetch('https://appleid.apple.com/auth/keys');
    if (!response.ok) {
      throw new Error('Failed to fetch Apple public keys');
    }

    const data = await response.json() as AppleKeysResponse;
    this.cachedKeys = data.keys;
    this.cacheExpiry = now + (24 * 60 * 60 * 1000); // 24 hours
    return data.keys;
  }

  /**
   * Verify Apple identity token and extract payload
   * Accepts a single audience string or an array of valid audiences (e.g. iOS + macOS bundle IDs)
   */
  static async verifyIdentityToken(
    identityToken: string,
    expectedAudience: string | string[]
  ): Promise<AppleTokenPayload | null> {
    try {
      // Decode JWT header to get key ID
      const [headerB64, payloadB64, signatureB64] = identityToken.split('.');
      if (!headerB64 || !payloadB64 || !signatureB64) {
        console.error('Invalid token format');
        return null;
      }

      const header = JSON.parse(this.base64UrlDecode(headerB64));

      // Get Apple's public keys
      const keys = await this.getApplePublicKeys();
      const key = keys.find(k => k.kid === header.kid);

      if (!key) {
        console.error('Apple public key not found for kid:', header.kid);
        return null;
      }

      // Import the public key
      const publicKey = await crypto.subtle.importKey(
        'jwk',
        {
          kty: key.kty,
          n: key.n,
          e: key.e,
          alg: key.alg,
          use: key.use,
        },
        { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
        false,
        ['verify']
      );

      // Verify signature
      const signatureInput = `${headerB64}.${payloadB64}`;
      const signature = this.base64UrlDecodeToBuffer(signatureB64);

      const isValid = await crypto.subtle.verify(
        'RSASSA-PKCS1-v1_5',
        publicKey,
        signature,
        new TextEncoder().encode(signatureInput)
      );

      if (!isValid) {
        console.error('Apple identity token signature invalid');
        return null;
      }

      // Decode and validate payload
      const payload = JSON.parse(this.base64UrlDecode(payloadB64)) as AppleTokenPayload;

      // Validate issuer
      if (payload.iss !== 'https://appleid.apple.com') {
        console.error('Invalid issuer:', payload.iss);
        return null;
      }

      // Validate audience (your app's Bundle ID — may be iOS or macOS)
      const audiences = Array.isArray(expectedAudience) ? expectedAudience : [expectedAudience];
      if (!audiences.includes(payload.aud)) {
        console.error('Invalid audience:', payload.aud, 'expected one of:', audiences);
        return null;
      }

      // Check expiration
      const now = Math.floor(Date.now() / 1000);
      if (payload.exp < now) {
        console.error('Token expired');
        return null;
      }

      return payload;
    } catch (error) {
      console.error('Apple token verification error:', error);
      return null;
    }
  }

  private static base64UrlDecode(str: string): string {
    let base64 = str.replace(/-/g, '+').replace(/_/g, '/');
    while (base64.length % 4) {
      base64 += '=';
    }
    return atob(base64);
  }

  private static base64UrlDecodeToBuffer(str: string): ArrayBuffer {
    const binary = this.base64UrlDecode(str);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) {
      bytes[i] = binary.charCodeAt(i);
    }
    return bytes.buffer;
  }
}
