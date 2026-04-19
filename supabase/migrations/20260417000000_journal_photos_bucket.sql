-- Journal v2: photo attachments bucket
--
-- Bucket: journal-photos (public for read — signed URLs are not used)
-- Path layout: {userId}/{noteId}/{photoUuid}.jpg
-- RLS on storage.objects restricts writes to the authenticated user's own
-- first-level folder (matching the `user_id` in financial_notes).

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
    'journal-photos',
    'journal-photos',
    TRUE,
    5 * 1024 * 1024, -- 5 MB per photo
    ARRAY['image/jpeg', 'image/png', 'image/heic', 'image/webp']
)
ON CONFLICT (id) DO UPDATE
    SET public = EXCLUDED.public,
        file_size_limit = EXCLUDED.file_size_limit,
        allowed_mime_types = EXCLUDED.allowed_mime_types;

-- Public read for all objects in the bucket.
CREATE POLICY "Public can read journal photos"
    ON storage.objects FOR SELECT
    USING (bucket_id = 'journal-photos');

-- Owner may insert objects only under their own user-id prefix.
-- path: storage.objects.name is the object path relative to the bucket root.
CREATE POLICY "User can upload own journal photos"
    ON storage.objects FOR INSERT
    WITH CHECK (
        bucket_id = 'journal-photos'
        AND auth.uid()::text = (storage.foldername(name))[1]
    );

CREATE POLICY "User can update own journal photos"
    ON storage.objects FOR UPDATE
    USING (
        bucket_id = 'journal-photos'
        AND auth.uid()::text = (storage.foldername(name))[1]
    );

CREATE POLICY "User can delete own journal photos"
    ON storage.objects FOR DELETE
    USING (
        bucket_id = 'journal-photos'
        AND auth.uid()::text = (storage.foldername(name))[1]
    );
