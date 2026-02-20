// Subscription endpoint handlers for Apple In-App Purchases
import { Database } from './database';
import { Auth } from './auth';
import { AppleIAP, PRODUCT_IDS, TRIAL_PERIOD_MS } from './apple-iap';

interface Env {
  DB: D1Database;
  JWT_SECRET: string;
  APPLE_BUNDLE_ID?: string;
}

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

/**
 * Get authenticated user from request
 */
async function getAuthenticatedUser(request: Request, env: Env) {
  const db = new Database(env.DB);
  const authHeader = request.headers.get('Authorization');
  const token = Auth.extractBearerToken(authHeader);

  if (!token) {
    return null;
  }

  const jwtSecret = env.JWT_SECRET || 'default-secret-change-in-production';
  const jwtPayload = await Auth.verifyJWT(token, jwtSecret);

  if (!jwtPayload || jwtPayload.type !== 'access') {
    return null;
  }

  return db.getUserById(jwtPayload.sub);
}

/**
 * Verify purchase and activate subscription
 * POST /subscription/verify-purchase
 * Body: { signedTransaction: string }
 */
export async function handleVerifyPurchase(request: Request, env: Env): Promise<Response> {
  const db = new Database(env.DB);
  const user = await getAuthenticatedUser(request, env);

  if (!user) {
    return json({ error: 'Unauthorized' }, 401);
  }

  try {
    const body = await request.json() as { signedTransaction: string };
    const { signedTransaction } = body;

    if (!signedTransaction) {
      return json({ error: 'signedTransaction is required' }, 400);
    }

    // Initialize Apple IAP verifier (accepts both Production and Sandbox)
    const bundleId = env.APPLE_BUNDLE_ID || 'com.codybontecou.imghost';
    const appleIAP = new AppleIAP(bundleId);

    // Verify the transaction
    const result = await appleIAP.verifyTransaction(signedTransaction);

    if (!result.isValid || !result.transaction) {
      console.error('Transaction verification failed:', result.error);
      return json({
        error: 'Invalid transaction',
        details: result.error,
      }, 400);
    }

    const transaction = result.transaction;
    console.log(`Verified transaction: productId=${transaction.productId}, env=${transaction.environment}, expires=${new Date(transaction.expiresDate).toISOString()}`);

    // Check if this transaction already exists
    const existingSubscription = await db.getSubscriptionByAppleTransactionId(transaction.originalTransactionId);

    if (existingSubscription && existingSubscription.user_id !== user.id) {
      // Transaction belongs to a different user
      return json({ error: 'Transaction already used by another account' }, 409);
    }

    // Determine tier and status
    const isTrialPeriod = result.isTrialPeriod;
    const tier = isTrialPeriod ? 'trial' : 'pro';
    const status = isTrialPeriod ? 'trialing' : 'active';
    const trialEndsAt = isTrialPeriod ? transaction.expiresDate : undefined;

    // Check if user already has a subscription
    const currentSubscription = await db.getSubscriptionByUserId(user.id);

    if (currentSubscription) {
      // Update existing subscription
      await db.updateSubscriptionWithApple(
        user.id,
        tier,
        status,
        transaction.originalTransactionId,
        transaction.productId,
        transaction.expiresDate,
        trialEndsAt
      );
    } else {
      // Create new subscription
      await db.createAppleSubscription(
        user.id,
        tier,
        status,
        transaction.originalTransactionId,
        transaction.productId,
        transaction.expiresDate,
        trialEndsAt
      );
    }

    // Get updated user info
    const updatedUser = await db.getUserById(user.id);
    const usage = await db.getStorageUsage(user.id);

    return json({
      success: true,
      subscription: {
        status,
        tier,
        product_id: transaction.productId,
        expires_at: new Date(transaction.expiresDate).toISOString(),
        is_trial_period: isTrialPeriod,
        trial_ends_at: trialEndsAt ? new Date(trialEndsAt).toISOString() : undefined,
      },
      user: {
        subscription_tier: updatedUser?.subscription_tier,
        storage_limit_bytes: updatedUser?.storage_limit_bytes,
        storage_used_bytes: usage.total_bytes_used,
        image_count: usage.image_count,
      },
    });
  } catch (error) {
    console.error('Verify purchase error:', error);
    return json({ error: 'Failed to verify purchase' }, 500);
  }
}

/**
 * Get current subscription status
 * GET /subscription/status
 */
export async function handleSubscriptionStatus(request: Request, env: Env): Promise<Response> {
  const db = new Database(env.DB);
  const user = await getAuthenticatedUser(request, env);

  if (!user) {
    return json({ error: 'Unauthorized' }, 401);
  }

  try {
    const subscription = await db.getSubscriptionByUserId(user.id);
    const usage = await db.getStorageUsage(user.id);

    if (!subscription) {
      return json({
        status: 'none',
        tier: 'trial',
        has_access: false,
        will_renew: false,
        user: {
          subscription_tier: user.subscription_tier,
          storage_limit_bytes: user.storage_limit_bytes,
          storage_used_bytes: usage.total_bytes_used,
          image_count: usage.image_count,
        },
      });
    }

    // Check if subscription is still valid
    const now = Date.now();
    let effectiveStatus = subscription.status;

    // Check trial expiration
    if (subscription.status === 'trialing' && subscription.trial_ends_at && subscription.trial_ends_at < now) {
      effectiveStatus = 'expired';
      // Update the subscription status in the database
      await db.updateSubscriptionStatus(user.id, 'expired');
    }

    // Check subscription expiration
    if (subscription.current_period_end && subscription.current_period_end < now) {
      if (subscription.status === 'active' || subscription.status === 'trialing') {
        effectiveStatus = 'expired';
        await db.updateSubscriptionStatus(user.id, 'expired');
      }
    }

    const hasAccess = effectiveStatus === 'active' || effectiveStatus === 'trialing';

    // Calculate trial days remaining
    let trialDaysRemaining: number | undefined;
    if (subscription.trial_ends_at && subscription.status === 'trialing') {
      const msRemaining = subscription.trial_ends_at - now;
      trialDaysRemaining = Math.max(0, Math.ceil(msRemaining / (24 * 60 * 60 * 1000)));
    }

    return json({
      status: effectiveStatus,
      tier: subscription.tier,
      has_access: hasAccess,
      product_id: subscription.apple_product_id,
      expires_at: subscription.current_period_end
        ? new Date(subscription.current_period_end).toISOString()
        : undefined,
      trial_ends_at: subscription.trial_ends_at
        ? new Date(subscription.trial_ends_at).toISOString()
        : undefined,
      trial_days_remaining: trialDaysRemaining,
      will_renew: hasAccess && !subscription.cancel_at_period_end,
      user: {
        subscription_tier: user.subscription_tier,
        storage_limit_bytes: user.storage_limit_bytes,
        storage_used_bytes: usage.total_bytes_used,
        image_count: usage.image_count,
      },
    });
  } catch (error) {
    console.error('Subscription status error:', error);
    return json({ error: 'Failed to get subscription status' }, 500);
  }
}

/**
 * Restore purchases from App Store
 * POST /subscription/restore
 * Body: { signedTransactions: string[] }
 */
export async function handleRestorePurchases(request: Request, env: Env): Promise<Response> {
  const db = new Database(env.DB);
  const user = await getAuthenticatedUser(request, env);

  if (!user) {
    return json({ error: 'Unauthorized' }, 401);
  }

  try {
    const body = await request.json() as { signedTransactions: string[] };
    const { signedTransactions } = body;

    if (!signedTransactions || !Array.isArray(signedTransactions) || signedTransactions.length === 0) {
      return json({ error: 'signedTransactions array is required' }, 400);
    }

    // Initialize Apple IAP verifier (accepts both Production and Sandbox)
    const bundleId = env.APPLE_BUNDLE_ID || 'com.codybontecou.imghost';
    const appleIAP = new AppleIAP(bundleId);

    // Find the most recent valid subscription
    let latestTransaction: {
      transaction: any;
      isTrialPeriod: boolean;
    } | null = null;

    for (const signedTransaction of signedTransactions) {
      const result = await appleIAP.verifyTransaction(signedTransaction);

      if (result.isValid && result.transaction) {
        // Check if this is more recent than current latest
        if (!latestTransaction || result.transaction.expiresDate > latestTransaction.transaction.expiresDate) {
          latestTransaction = {
            transaction: result.transaction,
            isTrialPeriod: result.isTrialPeriod,
          };
        }
      }
    }

    if (!latestTransaction) {
      return json({
        success: false,
        message: 'No valid subscriptions found to restore',
      });
    }

    const { transaction, isTrialPeriod } = latestTransaction;

    // Check if subscription is expired
    const now = Date.now();
    if (transaction.expiresDate < now) {
      return json({
        success: false,
        message: 'All subscriptions have expired',
        expired_at: new Date(transaction.expiresDate).toISOString(),
      });
    }

    // Determine tier and status
    const tier = isTrialPeriod ? 'trial' : 'pro';
    const status = isTrialPeriod ? 'trialing' : 'active';
    const trialEndsAt = isTrialPeriod ? transaction.expiresDate : undefined;

    // Check if user already has a subscription
    const currentSubscription = await db.getSubscriptionByUserId(user.id);

    if (currentSubscription) {
      // Update existing subscription
      await db.updateSubscriptionWithApple(
        user.id,
        tier,
        status,
        transaction.originalTransactionId,
        transaction.productId,
        transaction.expiresDate,
        trialEndsAt
      );
    } else {
      // Create new subscription
      await db.createAppleSubscription(
        user.id,
        tier,
        status,
        transaction.originalTransactionId,
        transaction.productId,
        transaction.expiresDate,
        trialEndsAt
      );
    }

    // Get updated user info
    const updatedUser = await db.getUserById(user.id);
    const usage = await db.getStorageUsage(user.id);

    return json({
      success: true,
      message: 'Subscription restored successfully',
      subscription: {
        status,
        tier,
        product_id: transaction.productId,
        expires_at: new Date(transaction.expiresDate).toISOString(),
        is_trial_period: isTrialPeriod,
        trial_ends_at: trialEndsAt ? new Date(trialEndsAt).toISOString() : undefined,
      },
      user: {
        subscription_tier: updatedUser?.subscription_tier,
        storage_limit_bytes: updatedUser?.storage_limit_bytes,
        storage_used_bytes: usage.total_bytes_used,
        image_count: usage.image_count,
      },
    });
  } catch (error) {
    console.error('Restore purchases error:', error);
    return json({ error: 'Failed to restore purchases' }, 500);
  }
}

/**
 * Check if user has subscription access (helper for other handlers)
 */
export async function checkSubscriptionAccess(userId: string, db: Database): Promise<{
  hasAccess: boolean;
  tier: string;
  status: string;
  reason?: string;
}> {
  const user = await db.getUserById(userId);
  if (!user) {
    return { hasAccess: false, tier: 'trial', status: 'none', reason: 'User not found' };
  }

  const subscription = await db.getSubscriptionByUserId(userId);

  // No subscription record means trial tier with no access
  if (!subscription) {
    return { hasAccess: false, tier: 'trial', status: 'none', reason: 'No subscription' };
  }

  const now = Date.now();

  // Check trial expiration
  if (subscription.status === 'trialing' && subscription.trial_ends_at && subscription.trial_ends_at < now) {
    await db.updateSubscriptionTierAndStatus(userId, 'trial', 'expired');
    return { hasAccess: false, tier: 'trial', status: 'expired', reason: 'Trial expired' };
  }

  // Check subscription period expiration
  if (subscription.current_period_end && subscription.current_period_end < now) {
    if (subscription.status === 'active' || subscription.status === 'trialing') {
      await db.updateSubscriptionTierAndStatus(userId, 'trial', 'expired');
      return { hasAccess: false, tier: 'trial', status: 'expired', reason: 'Subscription expired' };
    }
  }

  // Active subscription or trial
  if (subscription.status === 'active' || subscription.status === 'trialing') {
    return { hasAccess: true, tier: subscription.tier, status: subscription.status };
  }

  // Cancelled, past due, or other status
  return { hasAccess: false, tier: subscription.tier, status: subscription.status, reason: `Subscription ${subscription.status}` };
}
