// Privacy-safe app analytics ingestion for native onboarding, paywall, and usage funnels.
// Stores only coarse, validated product events. Do not add emails, filenames, URLs,
// request IPs, user agents, or raw device identifiers to this schema.

export interface AppAnalyticsEnv {
  DB: D1Database;
  APP_ANALYTICS_INGEST_TOKEN?: string;
  APP_ANALYTICS_MAX_BATCH_SIZE?: string;
}

type AppAnalyticsValue = string;
type AppAnalyticsProperties = Record<string, AppAnalyticsValue>;

type AppAnalyticsEventRow = {
  id: string;
  installId: string;
  eventName: string;
  properties: AppAnalyticsProperties;
};

const MAX_BODY_BYTES = 64 * 1024;
const DEFAULT_MAX_BATCH_SIZE = 50;

const EVENT_NAMES = new Set([
  'app_launched',
  'tab_selected',
  'onboarding_started',
  'onboarding_step_viewed',
  'onboarding_skipped',
  'onboarding_completed',
  'auth_screen_viewed',
  'auth_started',
  'auth_finished',
  'subscription_status_checked',
  'settings_upgrade_tapped',
  'paywall_shown',
  'paywall_tier_selected',
  'paywall_billing_selected',
  'paywall_cta_tapped',
  'paywall_continue_free_tapped',
  'purchase_started',
  'purchase_finished',
  'restore_started',
  'restore_finished',
  'upload_source_selected',
  'upload_confirmed',
  'upload_started',
  'upload_finished',
  'upload_failed',
  'upload_limit_hit',
  'export_started',
  'export_finished',
]);

const PROPERTY_KEYS = new Set([
  'appVersion',
  'buildNumber',
  'platform',
  'onboardingStep',
  'paywallContext',
  'subscriptionStatus',
  'tier',
  'trialDaysBucket',
  'productId',
  'billingPeriod',
  'purchaseOutcome',
  'authMethod',
  'authOutcome',
  'uploadSource',
  'uploadOutcome',
  'fileTypeGroup',
  'fileSizeBucket',
  'errorCategory',
  'cta',
  'tab',
]);

const PLATFORMS = new Set(['ios', 'macos']);
const ONBOARDING_STEPS = new Set(['host_images', 'share_anywhere', 'direct_links', 'organized', 'start_free']);
const PAYWALL_CONTEXTS = new Set(['onboarding', 'settings', 'post_auth', 'subscription_gate', 'upload_limit', 'export_limit', 'unknown']);
const SUBSCRIPTION_STATUSES = new Set(['loading', 'free', 'no_subscription', 'trialing', 'trial_expired', 'subscribed', 'expired', 'cancelled', 'error']);
const TIERS = new Set(['free', 'trial', 'pro', 'enterprise', 'ultimate', 'unknown']);
const TRIAL_DAY_BUCKETS = new Set(['none', '0', '1_3', '4_7', '8_14', '15_plus']);
const PRODUCT_IDS = new Set([
  'imghost.pro.monthly',
  'imghost.pro.yearly',
  'imghost.enterprise.monthly',
  'imghost.enterprise.yearly',
  'imghost.ultimate.monthly',
  'imghost.ultimate.yearly',
  'unknown',
]);
const BILLING_PERIODS = new Set(['monthly', 'yearly', 'unknown']);
const PURCHASE_OUTCOMES = new Set(['started', 'succeeded', 'failed', 'cancelled', 'pending']);
const AUTH_METHODS = new Set(['email_login', 'email_register', 'apple', 'anonymous', 'unknown']);
const AUTH_OUTCOMES = new Set(['started', 'succeeded', 'failed']);
const UPLOAD_SOURCES = new Set(['photo_library', 'file_picker', 'drag_drop', 'paste', 'share_extension', 'mac_share_extension', 'unknown']);
const UPLOAD_OUTCOMES = new Set(['started', 'succeeded', 'failed', 'cancelled', 'blocked']);
const FILE_TYPE_GROUPS = new Set(['image', 'video', 'audio', 'pdf', 'archive', 'text', 'document', 'other', 'unknown']);
const FILE_SIZE_BUCKETS = new Set(['unknown', '0_1mb', '1_5mb', '5_50mb', '50_100mb', '100_500mb', '500mb_plus']);
const ERROR_CATEGORIES = new Set([
  'network',
  'auth',
  'subscription_required',
  'free_file_size',
  'free_daily_limit',
  'free_storage_full',
  'store_unavailable',
  'payment_not_allowed',
  'verification_failed',
  'user_cancelled',
  'configuration',
  'server',
  'unknown',
]);
const CTAS = new Set(['subscribe', 'restore', 'continue_free', 'upgrade', 'retry', 'unknown']);
const TABS = new Set(['media', 'upload', 'settings']);

const APP_VERSION_RE = /^\d+(?:\.\d+){0,3}$/;
const BUILD_NUMBER_RE = /^\d{1,12}$/;
const INSTALL_ID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function appAnalyticsCorsHeaders(): Headers {
  return new Headers({
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Authorization, Content-Type',
    'Cache-Control': 'no-store',
    'Content-Type': 'application/json; charset=utf-8',
  });
}

export async function handleAppAnalyticsIngest(request: Request, env: AppAnalyticsEnv): Promise<Response> {
  const authError = authorize(request, env);
  if (authError) return authError;

  const contentLength = Number(request.headers.get('content-length') ?? '0');
  if (Number.isFinite(contentLength) && contentLength > MAX_BODY_BYTES) {
    return appAnalyticsJson({ ok: false, error: 'body_too_large' }, 413);
  }

  const rawBody = await request.text();
  if (new TextEncoder().encode(rawBody).byteLength > MAX_BODY_BYTES) {
    return appAnalyticsJson({ ok: false, error: 'body_too_large' }, 413);
  }

  let body: unknown;
  try {
    body = JSON.parse(rawBody);
  } catch {
    return appAnalyticsJson({ ok: false, error: 'invalid_json' }, 400);
  }

  let rows: AppAnalyticsEventRow[];
  try {
    rows = normalizeIngestBody(body, maxBatchSize(env));
  } catch (error) {
    return appAnalyticsJson({
      ok: false,
      error: error instanceof Error ? error.message : 'invalid_payload',
    }, 400);
  }

  if (rows.length === 0) {
    return appAnalyticsJson({ ok: false, error: 'empty_batch' }, 400);
  }

  const insert = env.DB.prepare(`
    INSERT OR IGNORE INTO app_analytics_events (
      id,
      install_id,
      event_name,
      app_version,
      build_number,
      platform,
      onboarding_step,
      paywall_context,
      subscription_status,
      tier,
      trial_days_bucket,
      product_id,
      billing_period,
      purchase_outcome,
      auth_method,
      auth_outcome,
      upload_source,
      upload_outcome,
      file_type_group,
      file_size_bucket,
      error_category,
      cta,
      tab,
      payload_json
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `);

  await env.DB.batch(rows.map((row) => insert.bind(
    row.id,
    row.installId,
    row.eventName,
    property(row.properties, 'appVersion'),
    property(row.properties, 'buildNumber'),
    property(row.properties, 'platform'),
    property(row.properties, 'onboardingStep'),
    property(row.properties, 'paywallContext'),
    property(row.properties, 'subscriptionStatus'),
    property(row.properties, 'tier'),
    property(row.properties, 'trialDaysBucket'),
    property(row.properties, 'productId'),
    property(row.properties, 'billingPeriod'),
    property(row.properties, 'purchaseOutcome'),
    property(row.properties, 'authMethod'),
    property(row.properties, 'authOutcome'),
    property(row.properties, 'uploadSource'),
    property(row.properties, 'uploadOutcome'),
    property(row.properties, 'fileTypeGroup'),
    property(row.properties, 'fileSizeBucket'),
    property(row.properties, 'errorCategory'),
    property(row.properties, 'cta'),
    property(row.properties, 'tab'),
    JSON.stringify({ eventName: row.eventName, properties: row.properties }),
  )));

  return appAnalyticsJson({ ok: true, accepted: rows.length });
}

function normalizeIngestBody(body: unknown, maxBatch: number): AppAnalyticsEventRow[] {
  if (!isObject(body)) throw new Error('payload_must_be_object');

  const batchInstallId = optionalString(body.installId);
  const incomingEvents = Array.isArray(body.events) ? body.events : [body];

  if (incomingEvents.length > maxBatch) throw new Error('batch_too_large');

  return incomingEvents.map((event) => normalizeEvent(event, batchInstallId));
}

function normalizeEvent(event: unknown, batchInstallId: string | undefined): AppAnalyticsEventRow {
  if (!isObject(event)) throw new Error('event_must_be_object');

  const eventName = requiredString(event.eventName, 'eventName');
  if (!EVENT_NAMES.has(eventName)) throw new Error('unknown_event_name');

  const eventId = validateUuid(optionalString(event.eventId) ?? optionalString(event.id), 'event_id');
  const installId = validateUuid(optionalString(event.installId) ?? batchInstallId, 'install_id');
  const properties = normalizeProperties(isObject(event.properties) ? event.properties : {});

  return {
    id: eventId,
    installId,
    eventName,
    properties,
  };
}

function normalizeProperties(properties: Record<string, unknown>): AppAnalyticsProperties {
  const normalized: AppAnalyticsProperties = {};

  for (const [key, value] of Object.entries(properties)) {
    if (!PROPERTY_KEYS.has(key)) throw new Error(`unknown_property:${key}`);
    normalized[key] = validateProperty(key, value);
  }

  return normalized;
}

function validateProperty(key: string, value: unknown): string {
  if (typeof value !== 'string') throw new Error(`invalid_property_type:${key}`);

  switch (key) {
    case 'appVersion':
      if (!APP_VERSION_RE.test(value)) throw new Error(`invalid_property:${key}`);
      return value;
    case 'buildNumber':
      if (!BUILD_NUMBER_RE.test(value)) throw new Error(`invalid_property:${key}`);
      return value;
    case 'platform':
      return validateSetValue(key, value, PLATFORMS);
    case 'onboardingStep':
      return validateSetValue(key, value, ONBOARDING_STEPS);
    case 'paywallContext':
      return validateSetValue(key, value, PAYWALL_CONTEXTS);
    case 'subscriptionStatus':
      return validateSetValue(key, value, SUBSCRIPTION_STATUSES);
    case 'tier':
      return validateSetValue(key, value, TIERS);
    case 'trialDaysBucket':
      return validateSetValue(key, value, TRIAL_DAY_BUCKETS);
    case 'productId':
      return validateSetValue(key, value, PRODUCT_IDS);
    case 'billingPeriod':
      return validateSetValue(key, value, BILLING_PERIODS);
    case 'purchaseOutcome':
      return validateSetValue(key, value, PURCHASE_OUTCOMES);
    case 'authMethod':
      return validateSetValue(key, value, AUTH_METHODS);
    case 'authOutcome':
      return validateSetValue(key, value, AUTH_OUTCOMES);
    case 'uploadSource':
      return validateSetValue(key, value, UPLOAD_SOURCES);
    case 'uploadOutcome':
      return validateSetValue(key, value, UPLOAD_OUTCOMES);
    case 'fileTypeGroup':
      return validateSetValue(key, value, FILE_TYPE_GROUPS);
    case 'fileSizeBucket':
      return validateSetValue(key, value, FILE_SIZE_BUCKETS);
    case 'errorCategory':
      return validateSetValue(key, value, ERROR_CATEGORIES);
    case 'cta':
      return validateSetValue(key, value, CTAS);
    case 'tab':
      return validateSetValue(key, value, TABS);
    default:
      throw new Error(`unknown_property:${key}`);
  }
}

function validateSetValue(key: string, value: string, allowedValues: Set<string>): string {
  if (!allowedValues.has(value)) throw new Error(`unknown_property_value:${key}`);
  return value;
}

function validateUuid(value: string | undefined, name: string): string {
  if (!value || !INSTALL_ID_RE.test(value)) throw new Error(`invalid_${name}`);
  return value.toLowerCase();
}

function authorize(request: Request, env: AppAnalyticsEnv): Response | undefined {
  if (!env.APP_ANALYTICS_INGEST_TOKEN) return undefined;

  const expected = `Bearer ${env.APP_ANALYTICS_INGEST_TOKEN}`;
  if (request.headers.get('authorization') === expected) return undefined;

  return appAnalyticsJson({ ok: false, error: 'unauthorized' }, 401);
}

function maxBatchSize(env: AppAnalyticsEnv): number {
  const parsed = Number(env.APP_ANALYTICS_MAX_BATCH_SIZE ?? DEFAULT_MAX_BATCH_SIZE);
  return Number.isInteger(parsed) && parsed > 0
    ? Math.min(parsed, DEFAULT_MAX_BATCH_SIZE)
    : DEFAULT_MAX_BATCH_SIZE;
}

function property(properties: AppAnalyticsProperties, key: string): string | null {
  return properties[key] ?? null;
}

function requiredString(value: unknown, key: string): string {
  if (typeof value !== 'string' || value.length === 0) throw new Error(`missing_${key}`);
  return value;
}

function optionalString(value: unknown): string | undefined {
  return typeof value === 'string' && value.length > 0 ? value : undefined;
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function appAnalyticsJson(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: appAnalyticsCorsHeaders(),
  });
}
