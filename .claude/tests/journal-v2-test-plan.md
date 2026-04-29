# Journal v2 — Full Test Plan
<!-- type: test-plan | status: active | date: 2026-04-16 | tags: [journal, qa, regression] -->

Scope: `JournalTabView`, `JournalNoteFormView`, `JournalNoteDetailView`, `JournalNoteCardView`, `JournalViewModel`, photo upload pipeline, tag history, RLS auth path.

---

## TC-01 — Create Note (minimum fields)
**Priority:** P0
**Preconditions:** Authenticated user, at least 0 notes in Journal.

**Steps:**
1. Open Journal tab.
2. Tap `+` menu → "New Note".
3. Leave title empty.
4. Type any non-empty content.
5. Tap Save.

**Expected:** Sheet dismisses; new note appears at top of list without reload spinner; note shows on detail screen with correct content, no title shown.

**Edge cases / notes:**
- Save button must remain disabled if content is only whitespace.

---

## TC-02 — Create Note (all fields)
**Priority:** P0
**Preconditions:** Auth user, at least 1 existing transaction.

**Steps:**
1. Open form → Note type.
2. Fill title: "Test Note Full".
3. Fill content: "Full note content."
4. Select any mood.
5. Expand "More details".
6. Add 3 tags: "food", "budget", "test".
7. Add 3 photos from Photos.
8. Link a transaction via picker.
9. Tap Save.

**Expected:**
- No error alert.
- Note appears in list with photo-strip card.
- Detail screen shows: title, content, mood emoji + label, 3 photo thumbnails (tappable), transaction badge, 3 tag chips.
- No RLS error. Photos accessible via CachedAsyncImage.

**Edge cases / notes:**
- UUID in Storage path must be lowercase (BUG-001 fix verification).

---

## TC-03 — Create Reflection with period
**Priority:** P0
**Preconditions:** Auth user.

**Steps:**
1. Open form → switch type toggle to "Reflection".
2. Verify DatePicker auto-populated with current month start/end.
3. Enter content.
4. Tap Save.

**Expected:**
- Reflection note in list; filter "Reflections" shows it, filter "Notes" hides it.
- Detail shows period badge with correct date range.

---

## TC-04 — Edit Note (all change types)
**Priority:** P0
**Preconditions:** Existing note with title, mood, 1 tag, 1 photo, 1 linked tx.

**Steps:**
1. Open detail → ellipsis menu → Edit.
2. Change title.
3. Change mood.
4. Remove existing tag.
5. Add a new tag.
6. Remove existing photo (tap X).
7. Add 1 new photo.
8. Replace linked transaction (tap filled tx row → pick different tx).
9. Tap Save.

**Expected:**
- No error.
- List card updates immediately (no network reload).
- Detail shows all new values.
- Old photo is deleted from Storage (verify via Supabase dashboard).
- New photo accessible.

---

## TC-05 — Edit Note: clear optional fields
**Priority:** P1
**Preconditions:** Note with title, mood, transaction.

**Steps:**
1. Edit → clear title, deselect mood (tap again), clear transaction (X on row).
2. Save.

**Expected:**
- Title disappears from card and detail.
- No mood shown on card header.
- Transaction badge gone from card.

---

## TC-06 — Delete Note
**Priority:** P0
**Preconditions:** Existing note with 2 photos.

**Steps:**
1. Open detail → ellipsis → Delete.
2. Confirm destructive alert.

**Expected:**
- Navigate back to list.
- Note removed from list.
- Photos deleted from Storage (best-effort; no crash).
- If this note's tags were unique, those tags disappear from filter bar (after next refresh) — see TC-22 for tag GC.

---

## TC-07 — Pull-to-refresh
**Priority:** P1
**Preconditions:** Journal loaded once.

**Steps:**
1. Pull down to trigger refresh.

**Expected:**
- Spinner appears.
- List reloads from network.
- `lastLoadedAt` resets (subsequent navigation within TTL shows no spinner).

---

## TC-08 — Cache: navigation without re-fetch
**Priority:** P1
**Preconditions:** Journal loaded; `cacheTTL` = 60 s.

**Steps:**
1. Load Journal (spinner once).
2. Navigate to Home.
3. Navigate back to Journal immediately.

**Expected:**
- No spinner on return. List appears instantly.

---

## TC-09 — Cache: force fetch after TTL
**Priority:** P1
**Preconditions:** Journal loaded.

**Steps:**
1. Wait 61 s.
2. Navigate away and back.

**Expected:**
- Fetch triggers (spinner or background update). `lastLoadedAt` updates.

---

## TC-10 — Create note appears in list immediately
**Priority:** P1
**Preconditions:** Journal loaded.

**Steps:**
1. Create a new note.
2. Observe list without dismissing and re-opening.

**Expected:**
- New note at top of today group without pull-to-refresh.

---

## TC-11 — Search by content
**Priority:** P1
**Preconditions:** Notes with distinct content strings.

**Steps:**
1. Tap search bar.
2. Type substring present in exactly one note.

**Expected:**
- List filters to matching notes.
- Clear search → full list restored.

**Edge cases / notes:**
- Unicode search ("кофе"), emoji in content.
- Empty-string search falls through to `applyFilters()`, not network call.

---

## TC-12 — Filter: All / Notes / Reflections
**Priority:** P1
**Preconditions:** Mix of freeform notes and reflections.

**Steps:**
1. Tap "Notes" chip → verify only freeform/transaction notes.
2. Tap "Reflections" chip → verify only reflections.
3. Tap "All" → all items visible.

**Expected:**
- Client-side filtering, no network call.

---

## TC-13 — Filter by tag chip
**Priority:** P1
**Preconditions:** Notes with at least 2 distinct tags.

**Steps:**
1. Tap a tag chip in filter bar.
2. Verify list shows only notes with that tag.
3. Tap same chip again → deselect.

**Expected:**
- Correct filter applied/cleared. Chip shows selected style when active.

---

## TC-14 — Filter bar: overflow with 3+ tags
**Priority:** P1  ← BUG-004 regression
**Preconditions:** At least 3 notes with distinct long tags (e.g. "рефлексии", "инвестиции", "расходы").

**Steps:**
1. Open Journal.
2. Observe horizontal filter bar.

**Expected:**
- All tag chips visible via horizontal scroll.
- No chip clipped/hidden. "#рефлексии" (Cyrillic) fully readable.
- ScrollView scrollable; doesn't wrap to second line.

---

## TC-15 — Photo upload: 1 / 3 / 5 photos
**Priority:** P0  ← BUG-001 regression
**Preconditions:** Auth user; logged in with valid session.

**Steps (repeat for counts 1, 3, 5):**
1. Open form.
2. Expand details → add N photos.
3. Observe upload progress indicator per photo.
4. Tap Save.

**Expected:**
- No RLS error.
- All photos uploaded. `photo_urls` array in DB has N lowercase-path URLs.
- Detail screen renders all photos.
- Photo-strip card variant shown on list for N >= 1.

---

## TC-16 — Photo upload: attempt 6th photo
**Priority:** P1
**Preconditions:** Form open with 5 photos.

**Steps:**
1. Observe "Add" cell state.

**Expected:**
- "Add" cell disappears when total == 5 (`if totalPhotoCount < 5` guard).
- PhotosPicker not accessible. No 6th photo can be added.

---

## TC-17 — Photo upload: >5 MB file
**Priority:** P1
**Preconditions:** Photo library contains image >5 MB.

**Steps:**
1. Select oversized photo.
2. Tap Save.

**Expected:**
- Error alert with readable message (not a crash).
- Form stays open. User can remove photo and retry.

---

## TC-18 — Photo upload: HEIC format
**Priority:** P1
**Preconditions:** iPhone camera-default HEIC image.

**Steps:**
1. Select HEIC photo from library.
2. Save note.

**Expected:**
- Photo ingested (`loadTransferable(type: Data.self)` decodes HEIC).
- Thumbnail visible before save.
- Upload succeeds; photo renders on detail.

---

## TC-19 — Photo upload: cancel during upload
**Priority:** P2
**Preconditions:** Slow network / large photo.

**Steps:**
1. Select 3 large photos.
2. Tap Save; observe upload in progress (progress bars).
3. Remove one pending photo by tapping X mid-upload.

**Expected:**
- Removed photo cell disappears from form.
- Remaining uploads proceed or only that photo is cancelled (no crash).
- Note saved with surviving photos only.

---

## TC-20 — Photo viewer: swipe, pinch-zoom, dismiss
**Priority:** P1
**Preconditions:** Note with 3+ photos.

**Steps:**
1. Open detail → tap any photo.
2. Swipe left/right between photos.
3. Pinch-zoom on a photo.
4. Swipe down (or tap X) to dismiss.

**Expected:**
- Viewer opens at tapped index.
- All 3 photos navigable.
- Pinch-zoom works without crash.
- Dismissal returns to detail without navigation side-effects.

---

## TC-21 — Delete photo from existing note
**Priority:** P1
**Preconditions:** Note with 2 photos saved.

**Steps:**
1. Edit note.
2. Tap X on one existing photo.
3. Save.

**Expected:**
- `photo_urls` in DB updated to 1 URL.
- Removed URL no longer in Storage (async delete via `JournalPhotoUploader.delete`).
- Detail shows 1 photo.

---

## TC-22 — Tags: add new (not in history)
**Priority:** P0
**Preconditions:** Tag "unicorntag2026" does not exist.

**Steps:**
1. Open form → Expand details → type "unicorntag2026" in tag field → Return.
2. Save note.

**Expected:**
- Tag chip appears in form.
- After save, "unicorntag2026" appears in filter bar and in suggestions for next note.

---

## TC-23 — Tags: select from suggestions
**Priority:** P1
**Preconditions:** At least 1 tag in history.

**Steps:**
1. Open form → details.
2. Tap existing tag suggestion without typing.

**Expected:**
- Tag immediately added to form (single tap). Not duplicated.

---

## TC-24 — Tags: remove applied tag from form
**Priority:** P1
**Steps:**
1. Form with 2 tags applied.
2. Tap X on one RemovableTagChip.

**Expected:**
- Chip disappears with spring animation. Tag re-appears in suggestions.

---

## TC-25 — Tags: delete from history (long-press)
**Priority:** P0  ← BUG-002 regression
**Preconditions:** Tag "deleteme" exists in history (used in a note that was then deleted, OR still in at least one note).

**Steps:**
1. Open form → Expand details.
2. Long-press suggestion chip "#deleteme".

**Expected (after fix):**
- Confirmation appears OR chip removed immediately.
- Tag disappears from `viewModel.allTags` / suggestions.
- Does NOT survive after all notes using it are deleted.

**Notes:**
- Current behavior (bug): tag persists in suggestions even after all notes with it are deleted.
- Clarify with ios-developer: on delete-tag-from-history, should existing notes lose that tag or retain it?

---

## TC-26 — Tags: persistence after note deletion (regression)
**Priority:** P0  ← BUG-002 regression
**Preconditions:** Create note with unique tag "temptag999". No other notes use it.

**Steps:**
1. Create note with tag "temptag999". Verify it appears in filter bar.
2. Delete the note (TC-06 flow).
3. Pull-to-refresh.
4. Open form → expand details → observe suggestions.

**Expected (after fix):**
- "temptag999" absent from suggestions and filter bar.

**Actual (current):**
- "temptag999" still in suggestions despite having 0 associated notes.

---

## TC-27 — Tags: suggestion overlap in form
**Priority:** P1  ← BUG-006 regression
**Preconditions:** 5+ tags in history.

**Steps:**
1. Open form → Expand details → tag section visible.
2. Add 3 tags one by one.
3. Observe suggestions row and FlowLayout chips simultaneously.

**Expected (after fix):**
- Suggestions in horizontal `ScrollView` below FlowLayout — no visual overlap.
- Each element occupies distinct vertical space.

---

## TC-28 — Transaction linking: link, view, clear, replace
**Priority:** P1
**Preconditions:** At least 2 transactions in account.

**Steps:**
1. Open form → Expand details → tap "Link transaction" row.
2. Pick tx A.
3. Verify filled row shows amount, category, date.
4. Tap X → row resets to empty.
5. Open picker again → pick tx B.
6. Save.

**Expected:**
- Detail shows tx B badge.
- Card shows tx badge.
- Clearing sets `transaction_id` = null in DB.

---

## TC-29 — Transaction picker: search
**Priority:** P1

**Steps:**
1. Open picker.
2. Type partial category name or partial amount.

**Expected:**
- Filtered results shown.

---

## TC-30 — Transaction picker: empty state
**Priority:** P1
**Preconditions:** Account has 0 transactions.

**Steps:**
1. Open form → Expand details → tap link row.

**Expected:**
- Picker shows empty state (not crash, not blank white screen).

---

## TC-31 — Empty state UI
**Priority:** P1  ← BUG-003 regression
**Preconditions:** 0 notes in Journal (fresh account or delete all).

**Steps:**
1. Open Journal.

**Expected (after fix):**
- Centered illustration + title + subtitle.
- Two buttons ("Write Note", "Reflection") with correct horizontal padding (16pt on each side, no edge-hugging).
- Buttons tappable and open correct sheets.

---

## TC-32 — Accent bar: cards
**Priority:** P2  ← BUG-005 regression
**Preconditions:** Notes and Reflections exist.

**Steps:**
1. View list with standard (no photo) Note card.
2. View list with Reflection card.
3. View a note Detail.

**Expected (after redesign):**
- If accent bar is intentional: visible, purposeful, 4pt width, color-coded (accent for Note, budget-purple for Reflection).
- If redesign removes it: no bar appears in either card or detail.
- No "mysterious" bar with no apparent meaning.

---

## TC-33 — Save disabled on empty content
**Priority:** P0
**Steps:**
1. Open form. Leave content field empty or whitespace only.

**Expected:**
- Save button disabled (`content.trimmingCharacters(in: .whitespaces).isEmpty`).
- Typing space does not enable it.
- Typing one non-space character enables it.

---

## TC-34 — Offline save
**Priority:** P1
**Preconditions:** Disable network.

**Steps:**
1. Open form. Fill content. Tap Save.

**Expected:**
- Error alert shown with intelligible message.
- No crash. Form stays open. User can retry after re-enabling network.

---

## TC-35 — RLS / auth expired
**Priority:** P0
**Preconditions:** Force-expire session (or simulate auth error).

**Steps:**
1. Attempt save.

**Expected:**
- Error surfaced via `errorText` alert.
- App does not crash.
- Session auto-refresh (Supabase `autoRefreshToken: true`) handles token rotation transparently before user sees error.

---

## TC-36 — Large content (>10k chars)
**Priority:** P2
**Steps:**
1. Paste 10 000+ character text into content field.
2. Save.

**Expected:**
- No crash. TextEditor scrolls. Content saved and rendered on detail.

---

## TC-37 — VoiceOver labels
**Priority:** P1
**Steps:**
1. Enable VoiceOver.
2. Navigate form: mood buttons, tag remove X buttons, photo remove X, transaction clear X, link row.

**Expected:**
- Each interactive element announces a human-readable label (not "button" or system image name).
- Mood buttons announce mood name (e.g. "Спокойный" / "Calm").
- Tag remove announces "Remove tag food".

---

## TC-38 — Dynamic Type XL+
**Priority:** P1
**Steps:**
1. Set system font to Accessibility XL or XXL.
2. Open Journal list, open a detail, open form.

**Expected:**
- Cards do not clip content. Text wraps rather than truncates beyond `lineLimit`.
- Filter bar chips readable.
- Mood emoji row does not overflow horizontally.

---

## TC-39 — Long Russian labels in UI
**Priority:** P1
**Steps:**
1. Set device language to Russian.
2. Create note with mood "Беспокойство" / "Стресс".
3. View card header and detail mood row.

**Expected:**
- Mood name not clipped in card header (caption font, HStack with Spacer).
- VoiceOver reads Russian accessibilityLabel for mood button (`.accessibilityLabel(Text(mood.localizedName))`).

---

## TC-40 — Localization: RU → EN → ES
**Priority:** P1
**Preconditions:** App supports EN, RU, ES.

**Steps:**
1. Each language: open Journal list, open form (Note + Reflection), open detail.

**Expected:**
- All strings translated (title, filter labels, mood labels, empty state, form placeholders, toolbar buttons).
- No truncated keys (e.g. "journal.title" displayed raw).
- Layout holds for all languages.

---

## TC-41 — Unicode / emoji in content and tags
**Priority:** P2
**Steps:**
1. Create note with content containing: CJK chars, emoji (🎯💰), RTL Arabic, Cyrillic.
2. Add tag with emoji: "🏠home".
3. Save.

**Expected:**
- Content saved and rendered correctly.
- Emoji tag saved; appears in suggestions and filter.
- No crash.

---

## TC-42 — Pagination boundary: exact 50 notes
**Priority:** P2
**Preconditions:** Exactly 50 notes in DB.

**Steps:**
1. Load Journal.
2. Observe bottom of list.

**Expected:**
- `ProgressView` at bottom triggers `loadMore()`.
- `loadMore()` returns 0 items → `hasMorePages = false` → spinner disappears.

---

## TC-43 — Malformed photo URL
**Priority:** P2
**Preconditions:** Inject a note with `photo_urls = ["not-a-url"]`.

**Steps:**
1. Open list → tap note.

**Expected:**
- Detail shows placeholder (`Color(.systemGray5)`) without crash.
- No nil force-unwrap (guard in `photoImage` / `singlePhotoView`).

---
