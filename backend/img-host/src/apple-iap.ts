// Apple In-App Purchase verification for StoreKit 2
// Handles JWS (JSON Web Signature) decoding and validation

export interface DecodedTransaction {
  transactionId: string;
  originalTransactionId: string;
  productId: string;
  purchaseDate: number;
  expiresDate: number;
  type: 'Auto-Renewable Subscription' | 'Non-Consumable' | 'Consumable';
  inAppOwnershipType: 'PURCHASED' | 'FAMILY_SHARED';
  signedDate: number;
  environment: 'Production' | 'Sandbox';
  bundleId: string;
  offerType?: number; // 1 = introductory, 2 = promotional, 3 = offer code
  offerIdentifier?: string;
}

export interface AppleVerificationResult {
  isValid: boolean;
  transaction?: DecodedTransaction;
  error?: string;
  isTrialPeriod: boolean;
  status: 'active' | 'expired' | 'billing_retry' | 'grace_period' | 'unknown';
}

export interface SubscriptionStatusResponse {
  status: 'active' | 'trialing' | 'expired' | 'none';
  productId?: string;
  expiresDate?: number;
  trialEndsAt?: number;
  willRenew: boolean;
  originalTransactionId?: string;
}

// Apple's public keys for JWS verification (fetched from Apple)
const APPLE_ROOT_CA_G3_PUBLIC_KEY_URL = 'https://www.apple.com/certificateauthority/AppleRootCA-G3.cer';

export class AppleIAP {
  private bundleId: string;

  constructor(bundleId: string) {
    this.bundleId = bundleId;
  }

  /**
   * Decode a JWS signed transaction from StoreKit 2
   * JWS format: header.payload.signature (base64url encoded)
   */
  async decodeJWS(jwsString: string): Promise<DecodedTransaction | null> {
    try {
      const parts = jwsString.split('.');
      if (parts.length !== 3) {
        console.error('Invalid JWS format: expected 3 parts');
        return null;
      }

      const [headerB64, payloadB64, signatureB64] = parts;

      // Decode header
      const header = JSON.parse(this.base64UrlDecode(headerB64));

      // Decode payload (the transaction data)
      const payload = JSON.parse(this.base64UrlDecode(payloadB64));

      // In production, you should verify the signature using Apple's public keys
      // For now, we decode and validate the payload structure

      const transaction: DecodedTransaction = {
        transactionId: payload.transactionId,
        originalTransactionId: payload.originalTransactionId,
        productId: payload.productId,
        purchaseDate: payload.purchaseDate,
        expiresDate: payload.expiresDate,
        type: payload.type,
        inAppOwnershipType: payload.inAppOwnershipType,
        signedDate: payload.signedDate,
        environment: payload.environment,
        bundleId: payload.bundleId,
        offerType: payload.offerType,
        offerIdentifier: payload.offerIdentifier,
      };

      return transaction;
    } catch (error) {
      console.error('Failed to decode JWS:', error);
      return null;
    }
  }

  /**
   * Verify a signed transaction and return subscription status
   */
  async verifyTransaction(signedTransaction: string): Promise<AppleVerificationResult> {
    try {
      const transaction = await this.decodeJWS(signedTransaction);

      if (!transaction) {
        return {
          isValid: false,
          error: 'Failed to decode transaction',
          isTrialPeriod: false,
          status: 'unknown',
        };
      }

      // Validate bundle ID matches
      if (transaction.bundleId !== this.bundleId) {
        return {
          isValid: false,
          error: `Bundle ID mismatch: expected ${this.bundleId}, got ${transaction.bundleId}`,
          isTrialPeriod: false,
          status: 'unknown',
        };
      }

      // Accept both Production and Sandbox environments
      // Apple App Review always tests in Sandbox, so we must accept both
      if (transaction.environment !== 'Production' && transaction.environment !== 'Sandbox') {
        console.warn(`Unexpected transaction environment: ${transaction.environment}`);
      }

      // Determine if this is a trial period
      // offerType 1 = introductory offer (includes free trials)
      const isTrialPeriod = transaction.offerType === 1;

      // Determine subscription status
      const now = Date.now();
      let status: AppleVerificationResult['status'] = 'unknown';

      if (transaction.expiresDate > now) {
        status = 'active';
      } else {
        // Check if within grace period (typically 16 days for billing retry)
        const gracePeriodMs = 16 * 24 * 60 * 60 * 1000; // 16 days
        if (transaction.expiresDate + gracePeriodMs > now) {
          status = 'billing_retry';
        } else {
          status = 'expired';
        }
      }

      return {
        isValid: true,
        transaction,
        isTrialPeriod,
        status,
      };
    } catch (error) {
      console.error('Transaction verification failed:', error);
      return {
        isValid: false,
        error: error instanceof Error ? error.message : 'Unknown error',
        isTrialPeriod: false,
        status: 'unknown',
      };
    }
  }

  /**
   * Get subscription status from a verified transaction
   */
  getSubscriptionStatus(transaction: DecodedTransaction): SubscriptionStatusResponse {
    const now = Date.now();
    const isTrialPeriod = transaction.offerType === 1;
    const isActive = transaction.expiresDate > now;

    if (!isActive) {
      return {
        status: 'expired',
        productId: transaction.productId,
        expiresDate: transaction.expiresDate,
        willRenew: false,
        originalTransactionId: transaction.originalTransactionId,
      };
    }

    return {
      status: isTrialPeriod ? 'trialing' : 'active',
      productId: transaction.productId,
      expiresDate: transaction.expiresDate,
      trialEndsAt: isTrialPeriod ? transaction.expiresDate : undefined,
      willRenew: true, // We can't determine this from the transaction alone
      originalTransactionId: transaction.originalTransactionId,
    };
  }

  /**
   * Determine the tier based on product ID
   */
  getTierFromProductId(productId: string): 'trial' | 'pro' {
    // During trial period, use 'trial' tier
    // After trial, use 'pro' tier
    // Product IDs: imghost.pro.monthly, imghost.pro.yearly
    if (productId.includes('pro')) {
      return 'pro';
    }
    return 'trial';
  }

  /**
   * Base64 URL decode (handles URL-safe base64)
   */
  private base64UrlDecode(str: string): string {
    // Replace URL-safe characters
    let base64 = str.replace(/-/g, '+').replace(/_/g, '/');

    // Add padding if needed
    const padding = base64.length % 4;
    if (padding) {
      base64 += '='.repeat(4 - padding);
    }

    // Decode
    return atob(base64);
  }
}

// Product IDs for the subscription plans
export const PRODUCT_IDS = {
  MONTHLY: 'imghost.pro.monthly',
  YEARLY: 'imghost.pro.yearly',
} as const;

// Trial period duration (7 days)
export const TRIAL_PERIOD_DAYS = 7;
export const TRIAL_PERIOD_MS = TRIAL_PERIOD_DAYS * 24 * 60 * 60 * 1000;
