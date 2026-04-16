-- Add preferred_language to profiles for localized backend notifications
ALTER TABLE profiles
ADD COLUMN IF NOT EXISTS preferred_language TEXT DEFAULT 'ru'
  CHECK (preferred_language IN ('ru', 'en', 'es'));

COMMENT ON COLUMN profiles.preferred_language IS
  'User UI language (ru/en/es). Used by backend functions (weekly digest, smart notifications) to localize push content. Synced from iOS app on language change.';
