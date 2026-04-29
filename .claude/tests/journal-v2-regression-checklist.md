# Journal v2 — Regression Checklist (Quick Pass)
<!-- type: checklist | status: active | date: 2026-04-16 -->

Run after every fix. Check each item manually on device. ~20 min.

---

## Auth / Storage (BUG-001)
- [ ] **R01** Create note with 1 photo → Save → NO "row-level security" error alert
- [ ] **R02** Photo accessible on detail screen (not broken image placeholder)
- [ ] **R03** Storage path in Supabase dashboard uses lowercase UUID

## Tag History (BUG-002)
- [ ] **R04** Create note with unique tag "regrtest001" → delete note → pull-to-refresh → "regrtest001" absent from form suggestions
- [ ] **R05** Long-press on suggestion chip → tag removed from suggestions

## Empty State (BUG-003)
- [ ] **R06** With 0 notes: two buttons visible with proper horizontal padding (not flush to screen edge)
- [ ] **R07** "Write Note" button opens Note form; "Reflection" button opens Reflection form

## Filter Bar Overflow (BUG-004)
- [ ] **R08** With 3+ long Cyrillic tags in history: filter bar horizontally scrollable; "#рефлексии" fully visible (not clipped)

## Accent Bar Visual (BUG-005)
- [ ] **R09** Note card and Reflection card: accent bar presence/absence matches design spec
- [ ] **R10** Detail header: accent bar matches expectation (purposeful or removed)

## Tag Suggestion Overlap (BUG-006)
- [ ] **R11** With 5 tags in history: add 3 tags in form → suggestions row and applied chips do not overlap

## Core Happy Paths
- [ ] **R12** Create Note (content only) → appears top of list immediately
- [ ] **R13** Create Note with title + mood + 3 tags + 3 photos + linked tx → all visible on detail
- [ ] **R14** Create Reflection with period → period badge on detail; filtered correctly by "Reflections" chip
- [ ] **R15** Edit note: change title, swap photo, remove tag → detail reflects all changes; no reload needed
- [ ] **R16** Delete note → removed from list; navigation pops back

## Guards
- [ ] **R17** Save button disabled when content is empty / whitespace-only
- [ ] **R18** Add cell disappears when 5 photos already in form (no 6th slot)
- [ ] **R19** Offline save → error alert shown, no crash, form stays open

## Navigation / Cache
- [ ] **R20** Navigate Home → Journal within 60 s: no spinner, instant list
