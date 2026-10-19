export interface PublicSupabaseConfig {
  url: string;
  publishableKey: string;
}

type PublicSupabaseConfigInput = {
  url?: string;
  publishableKey?: string;
};

const HTTP_URL_PATTERN = /^https?:\/\/(?:[a-z\d.-]+|\[[\da-f:]+\])(?::\d{1,5})?(?:\/[^\s]*)?$/i;

export function validatePublicSupabaseConfig({
  url,
  publishableKey,
}: PublicSupabaseConfigInput): PublicSupabaseConfig {
  const normalizedUrl = url?.trim();
  const normalizedKey = publishableKey?.trim();

  if (!normalizedUrl || !HTTP_URL_PATTERN.test(normalizedUrl)) {
    throw new Error('Set EXPO_PUBLIC_SUPABASE_URL to a valid HTTP or HTTPS project URL.');
  }

  if (!normalizedKey?.startsWith('sb_publishable_')) {
    throw new Error(
      'Set EXPO_PUBLIC_SUPABASE_PUBLISHABLE_KEY to a Supabase publishable key. Privileged and legacy keys are not supported in the app.',
    );
  }

  return { url: normalizedUrl, publishableKey: normalizedKey };
}

export function getPublicSupabaseConfig(): PublicSupabaseConfig {
  return validatePublicSupabaseConfig({
    url: process.env.EXPO_PUBLIC_SUPABASE_URL,
    publishableKey: process.env.EXPO_PUBLIC_SUPABASE_PUBLISHABLE_KEY,
  });
}
