# Journal v2 — Bug Reports
<!-- type: bug | status: open | date: 2026-04-16 | tags: [journal, regression] -->

---

# BUG-001: RLS violation on photo save — UUID case mismatch
- **Priority:** P0
- **Severity:** Critical
- **Affects:** `JournalNoteFormView.save()`, `JournalPhotoUploader.upload()`, `SupabaseManager.currentUserId()`

**Steps to reproduce:**
1. Authenticate as any user.
2. Open Journal → New Note.
3. Expand "More details" → add at least 1 photo.
4. Tap Save.

**Expected:**
- Note and photo saved successfully. No error alert.

**Actual:**
- Error alert: "new row violates row-level security policy".
- Photo not uploaded. Note may or may not save depending on whether photo upload or DB insert fires first.

**Root cause:**
`SupabaseManager.currentUserId()` at line 35 returns `user.id.uuidString` which Swift formats as uppercase (e.g. `"A1B2C3D4-..."`). Supabase Storage policy evaluates `(storage.foldername(name))[1] = auth.uid()::text` where `auth.uid()::text` is lowercase (e.g. `"a1b2c3d4-..."`). The string comparison fails, blocking the upload.

**Fix hint:**
Change line 35 to `user.id.uuidString.lowercased()`. Alternatively, lower in `JournalPhotoUploader` at path construction.

---

# BUG-002: Deleted tag persists in suggestions indefinitely
- **Priority:** P1
- **Severity:** Major
- **Affects:** `JournalViewModel.allTags`, `JournalNoteFormView.tagSuggestions`, `FinancialNoteRepository.fetchAllTags()`

**Steps to reproduce:**
1. Create a note with unique tag "bugtag999".
2. Verify "bugtag999" appears in suggestions and filter bar.
3. Delete the note (ellipsis → Delete → confirm).
4. Pull-to-refresh.
5. Open New Note form → expand details.

**Expected:**
- "bugtag999" absent from suggestions (no notes reference it).

**Actual:**
- "bugtag999" still shown in suggestions.

**Additional symptom:**
- No UI affordance to delete a tag from history at all (long-press does nothing currently).

**Root cause:**
`loadInitial` calls `repo.fetchAllTags()` which likely queries a `tags` table or cached list that is not pruned on note deletion. `deleteNote` only removes the note row and photo files — it does not update the tag index.

**Fix hint:**
Option A: `fetchAllTags()` should derive tags from live `financial_notes` rows (`SELECT DISTINCT unnest(tags) FROM financial_notes WHERE user_id = auth.uid()`), not a separate tags table. Option B: add long-press gesture on suggestion chip calling a `deleteTagFromHistory(tag)` VM method that removes from `allTags` and optionally strips from existing notes.

---

# BUG-003: Empty state action buttons flush to screen edges
- **Priority:** P1
- **Severity:** Minor (visual)
- **Affects:** `JournalTabView.emptyState`

**Steps to reproduce:**
1. Sign in with a fresh account (0 notes) OR delete all notes.
2. Open Journal tab.

**Expected:**
- "Write Note" and "Reflection" buttons centered with comfortable horizontal padding.

**Actual:**
- HStack buttons in `emptyState` have no explicit width constraint; with `borderedProminent` and `bordered` styles they may expand edge-to-edge or hug the safe area boundary on smaller devices (SE 3rd gen).

**Root cause:**
`HStack(spacing: 12)` with two `Button`s using `.buttonStyle(.borderedProminent)` / `.buttonStyle(.bordered)` expands to fill available width. No `padding(.horizontal)` or `frame(maxWidth:)` limiter wraps the HStack.

**Fix hint:**
Wrap the HStack in `.padding(.horizontal, 32)` or add `.frame(maxWidth: 360)` to cap width on larger screens.

---

# BUG-004: Filter chip "#рефлексии" clipped in filter bar
- **Priority:** P1
- **Severity:** Minor (visual/usability)
- **Affects:** `JournalTabView.filterBar`

**Steps to reproduce:**
1. Create notes with 3+ distinct multi-character tags (especially Cyrillic: "рефлексии", "инвестиции", "расходы").
2. Open Journal.
3. Observe horizontal filter bar.

**Expected:**
- All tag chips visible; bar is horizontally scrollable; no chip right-edge clipped.

**Actual:**
- Last tag chip(s) partially or fully hidden off right edge; ScrollView appears non-scrollable or clip boundary wrong.

**Root cause:**
The `ScrollView(.horizontal)` in `filterBar` wraps an `HStack` with `.padding(.horizontal, 16)` on the HStack itself. On device, if the HStack intrinsic width exceeds the scroll view's frame the trailing padding may be swallowed, causing the last chip to appear clipped. Additionally `.showsIndicators: false` hides any scroll affordance cue.

**Fix hint:**
Move horizontal padding to the ScrollView's content insets: `.contentMargins(.horizontal, 16, for: .scrollContent)` (iOS 17+) or wrap in `HStack` without side padding and add trailing `Spacer(minLength: 16)` at end of HStack to preserve trailing gap.

---

# BUG-005: Accent bar on cards / detail header confuses users
- **Priority:** P2
- **Severity:** Minor (UX/design)
- **Affects:** `JournalNoteCardView.standardCard`, `JournalNoteCardView.photoFirstCard`, `JournalNoteDetailView.detailHeader`

**Steps to reproduce:**
1. Open Journal with at least one Note and one Reflection.
2. Observe left edge of each list card.
3. Open detail of any note.

**Expected (per design spec):**
- Visual separator that clearly communicates note type (color-coded) OR no bar if redesign removes it.

**Actual:**
- 4pt `Rectangle().fill(accentColor)` present in all card variants and detail header. Users report it looks like a UI artifact or selection indicator rather than intentional type differentiation.

**Root cause:**
Design decision not communicated to users. The bar serves as type color-code but lacks a legend or tooltip. The designer is updating the spec; this bug tracks the need for alignment between design and implementation.

**Fix hint:**
Coordinate with designer output. If bar stays: ensure `accentColor` semantics are clear (icon + color together). If bar removed: delete the leading `Rectangle()` from `standardCard`, `photoFirstCard`, and `detailHeader` and replace with another type indicator (e.g. colored icon background pill).

---

# BUG-006: Tag suggestion chips overlap applied tag chips in form
- **Priority:** P1
- **Severity:** Major (usability)
- **Affects:** `JournalNoteFormView.tagsBlock`

**Steps to reproduce:**
1. Open New Note form.
2. Expand "More details".
3. Add 3+ tags so FlowLayout grows.
4. Ensure suggestions are visible (type nothing or partial query).

**Expected:**
- Applied tags (FlowLayout with RemovableTagChip + inlineAddTagField) occupies its own vertical space.
- Suggestions ScrollView appears below the FlowLayout, not on top of it.

**Actual:**
- With multiple applied tags the FlowLayout grows in height, but the suggestions `ScrollView` is positioned at a fixed offset and visually overlaps the FlowLayout chips.

**Root cause:**
`tagsBlock` uses `VStack(alignment: .leading, spacing: 8)` which should stack correctly, but `FlowLayout` is a custom `Layout` and its `sizeThatFits` may not return a correct height when the `inlineAddTagField` is included as a subview alongside the `ForEach`-generated chips. If `FlowLayout` underestimates its height the VStack positions the suggestions ScrollView too high.

**Fix hint:**
Audit `FlowLayout.sizeThatFits` — confirm it accounts for all subviews including `inlineAddTagField`. Add a `.fixedSize(horizontal: false, vertical: true)` modifier on the `FlowLayout` call or wrap it in a `GeometryReader`-backed approach to force correct height measurement. Write a unit test for `FlowLayout` with 5 subviews of known width to verify height output.
