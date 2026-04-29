---
type: prd
status: proposed
date: 2026-04-16
tags: [prd, journal, v2, ios]
owner: team-lead
---

# PRD — Journal v2 ("journal-first finance")

## 1. Context & Problem

Journal v1 shipped as BETA in Q1 2026. Real-user feedback (Vladimir) surfaces
5 issues that together break the feature's promise:

1. **Tag input** uses a text-field-plus-button; suggestions exist but are
   visually buried. Users believe tags aren't remembered.
2. **Photos** are collected via PhotosPicker but silently dropped in `save()`
   (`photoUrls` never passed). No Supabase Storage upload.
3. **Linked Transaction** field is **not tappable** — `Text("journal.selectTransaction")`
   has no button / navigation. Feature is dead.
4. **Mood picker** emojis truncate in Russian ("Беспокойство", "Стресс") —
   label wraps and visually breaks the row.
5. **Conceptual confusion** — three `NoteType`s (transaction / reflection /
   freeform) with no clear value proposition per type.

See competitor analysis in `.claude/research/journal-market-analysis.md`.

## 2. Positioning

> Akifi is the only iOS app where you can say
> **"I was stressed this week and here's what I spent"** in one flow.

**Note vs Transaction (user-facing definition)**

| | Transaction | Journal Entry |
|-|-|-|
| Captures | What money moved | How you felt / why / what you learned |
| Required fields | amount, date, category | content (text) |
| Optional link | journal entry | transaction, photo, mood, tags |
| Time frame | instant | free (day, week) |

**Simplified taxonomy — 2 types instead of 3:**

- `entry` (was `freeform` + `transaction`) — anything the user wants to
  write. If linked to a transaction, it behaves as "transaction note".
- `reflection` — period-bound (week/month), prompted, summary attached.

`NoteType.transaction` is dropped from the picker. If a user opens an entry
via "Add note to transaction" on the transaction detail screen, the link is
set automatically and the type collapses to `entry`. DB column stays for
backward compat; migration back-fills `transaction` → `entry`.

## 3. User Stories

### Epic A — Capture without friction
- **A1** As a user, I can pick my mood with one tap on a coloured emoji,
  and the emoji alone is enough (no label breaking layout).
- **A2** As a user, I see my existing tags as chips and tap to add; new
  tag creation is one secondary action.
- **A3** As a user, I can attach up to 3 photos and they are actually
  saved and visible on the detail screen.
- **A4** As a user, I can pick a transaction from a searchable sheet and
  the entry is linked to it.

### Epic B — Reflection cadence
- **B1** As a user, on Sunday evening I get a notification to reflect on
  the week with 4 prompts and auto-filled week summary (already built —
  keep).
- **B2** As a user, I can browse past reflections in their own filter.

### Epic C — Discoverability
- **C1** As a user on the transaction detail screen, I see linked journal
  entries and can jump to them.
- **C2** As a user on a journal entry, I see the linked transaction card
  (amount, category, date) and can jump to it.

### Epic D — Integrity
- **D1** As a user, my photos don't disappear between save and reload.
- **D2** As a user, my tags are shared across all entries (not per-entry
  islands).

## 4. Acceptance Criteria (critical path)

- [ ] `save()` passes `photoUrls` (uploaded to Supabase Storage bucket
      `journal-photos`, signed URLs stored).
- [ ] Transaction picker is a full sheet with search; tap sets
      `selectedTransactionId`; clear button works.
- [ ] Mood picker = 5 coloured faces, NO label under emoji; label shown
      only in accessibility hint (VoiceOver) and on selected-state tooltip.
- [ ] Tag chips: existing tags shown as filled chips, tap toggles add;
      "+ New tag" at the end opens a small alert/sheet.
- [ ] Removing `NoteType.transaction` from the picker; linked-transaction
      UI surfaces independent of type.
- [ ] Transaction detail screen shows count + list of linked entries.
- [ ] All existing v1 entries render without migration work for the user.

## 5. Success Metrics (post-launch, 2 sprints)

| Metric | Baseline (v1) | Target (v2) |
|-|-|-|
| Journal DAU / App DAU | — (BETA, unknown) | **≥ 12 %** |
| Entries/week per active journal user | — | **≥ 3** |
| % entries with mood set | — | **≥ 60 %** |
| % entries with photo (of users who try) | 0 (bug) | **≥ 30 %** |
| % entries linked to transaction | ~0 (dead button) | **≥ 25 %** |
| Weekly reflection completion (of notified users) | — | **≥ 20 %** |
| Crash-free rate on Journal tab | — | **≥ 99.8 %** |

Tracked via `AnalyticsService.logEvent` — events: `journal_note_created`
(exists), add `journal_photo_attached`, `journal_transaction_linked`,
`journal_mood_set`, `journal_reflection_completed`.

## 6. Out of Scope (v2)

- AI-suggested mood/tag auto-fill (v3).
- Cross-device sync of drafts (already via Supabase, no extra work).
- Shared/household journals.
- Export to PDF.
- Rich text / markdown in content.

## 7. Risk & Dependencies

- **Supabase Storage bucket `journal-photos`** must exist with RLS
  (`user_id = auth.uid()`). Blocker if not created — devops/backend task.
- **Photo upload latency** on slow networks — plan for background upload
  with optimistic UI.
- **Migration** of existing `note_type=transaction` rows — one-time SQL
  update, no user data loss.

## 8. Links
- Research: `.claude/research/journal-market-analysis.md`
- Current code: `AkifiIOS/Views/Journal/*`
- Session: `Sessions/2026-04-16-journal-v2-planning.md`
