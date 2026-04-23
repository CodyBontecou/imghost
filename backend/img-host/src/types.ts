// Type definitions for the imghost API

export type SubscriptionTier = 'free' | 'trial' | 'pro' | 'enterprise' | 'ultimate';

export type SubscriptionStatus = 'active' | 'cancelled' | 'past_due' | 'trialing';

export interface RegisterRequest {
  email: string;
  password: string;
}

export interface LoginRequest {
  email: string;
  password: string;
}

export interface AuthResponse {
  user_id: string;
  email: string;
  api_token: string;
  subscription_tier: SubscriptionTier;
}

export interface UserInfoResponse {
  user_id: string;
  email: string;
  subscription_tier: SubscriptionTier;
  storage_limit_bytes: number;
  storage_used_bytes: number;
  image_count: number;
}

export interface ImageInfo {
  id: string;
  filename: string;
  url: string;
  size_bytes: number;
  content_type: string;
  created_at: number;
}

export interface ImagesListResponse {
  images: ImageInfo[];
  count: number;
}

export interface UploadResponse {
  url: string;
  id: string;
  deleteUrl: string;
}

export interface DeleteResponse {
  deleted: boolean;
}

export interface ErrorResponse {
  error: string;
  [key: string]: any; // Allow additional error details
}

export interface TierFeatures {
  custom_domains: boolean;
  analytics: boolean;
  api_access: boolean;
  priority_support?: boolean;
}

export type ExportJobStatus = 'processing' | 'completed' | 'failed';

export interface ExportJobResponse {
  jobId: string;
  status: ExportJobStatus;
  imageCount: number;
  archiveSize?: number;
  downloadUrl?: string;
  expiresAt?: string;
  errorMessage?: string;
}

export interface ForgotPasswordRequest {
  email: string;
}

export interface ResetPasswordRequest {
  token: string;
  new_password: string;
}

export interface VerifyEmailRequest {
  token: string;
}

export interface RefreshTokenRequest {
  refresh_token: string;
}

export interface TokenResponse {
  access_token: string;
  refresh_token: string;
  expires_in: number;
  token_type: string;
  user_id: string;
  email: string;
  subscription_tier: SubscriptionTier;
}
