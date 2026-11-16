-- S9 (2026-11-17 review): storage policies.
--
-- 1) journal-photos: "Public can read journal photos" (SELECT, role public,
--    bucket_id only) lets anyone with the anon key LIST every user's journal
--    photos. The bucket stays PUBLIC so existing public URLs
--    (…/object/public/journal-photos/<uid>/<note>/<uuid>.jpg, unguessable
--    paths) keep working — public-bucket downloads do not consult RLS. The
--    owner keeps SELECT on their own folder, which Storage needs for
--    remove() (JournalPhotoUploader.delete) and any future upsert.
--    Paths are `<auth.uid()>/<noteId>/<uuid>.jpg`, matching the existing
--    INSERT / UPDATE / DELETE policies of this bucket.
--
-- 2) avatars: "Users can update own avatar" checked only bucket_id, so any
--    signed-in user could overwrite anyone's avatar (and the INSERT policy
--    only required the `avatars/` folder). The app writes
--    `avatars/<userId>.jpg` with upsert (ProfileEditView.uploadAvatar);
--    SupabaseManager.currentUserId() is lower-case today, but older builds
--    wrote an upper-case UUID (one such object exists), hence lower().
--    The public SELECT policy on avatars is unchanged (upsert needs SELECT).

drop policy if exists "Public can read journal photos" on storage.objects;
drop policy if exists "User can list own journal photos" on storage.objects;
create policy "User can list own journal photos" on storage.objects
    for select
    to authenticated
    using (
        bucket_id = 'journal-photos'
        and (storage.foldername(name))[1] = (auth.uid())::text
    );

drop policy if exists "Users can update own avatar" on storage.objects;
create policy "Users can update own avatar" on storage.objects
    for update
    to authenticated
    using (
        bucket_id = 'avatars'
        and (storage.foldername(name))[1] = 'avatars'
        and lower(split_part(storage.filename(name), '.', 1)) = (auth.uid())::text
    )
    with check (
        bucket_id = 'avatars'
        and (storage.foldername(name))[1] = 'avatars'
        and lower(split_part(storage.filename(name), '.', 1)) = (auth.uid())::text
    );

drop policy if exists "Users can upload own avatar" on storage.objects;
create policy "Users can upload own avatar" on storage.objects
    for insert
    to authenticated
    with check (
        bucket_id = 'avatars'
        and (storage.foldername(name))[1] = 'avatars'
        and lower(split_part(storage.filename(name), '.', 1)) = (auth.uid())::text
    );
