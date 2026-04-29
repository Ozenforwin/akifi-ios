---
type: knowledge
status: active
date: 2026-04-16
tags: [research, journal, competitors, ux]
---

# Journal — Market Analysis 2026

> [!warning] Source note
> WebSearch tool was **not available** in this session. The analysis below is
> based on model knowledge (cutoff May 2025) and Akifi's prior competitor
> research (`project_market_analysis.md`). Numbers and exact UI details should
> be re-verified with live WebSearch before high-stakes decisions. Items that
> need verification are marked `[verify]`.

## Research Questions
1. How do finance apps handle **notes attached to transactions**?
2. How do standalone journaling apps handle **mood + tags + prompts**?
3. Where is the gap Akifi's "journal-first finance" can fill?

---

## A. Finance Apps — transaction notes

### YNAB (You Need A Budget)
- Every transaction has a **single free-text `memo` field** (inline, ≤255 chars).
- No tags, no mood, no photos.
- Memos are searchable. No concept of a standalone "entry".
- Takeaway: memo = operational annotation ("who did I pay / why"), not reflection.

### Copilot Money (iOS, premium)
- Transactions have a **notes field + one attachment** (receipt photo).
- **Categories act as tags**; no free-form tags.
- "Review" screen is a weekly/monthly swipe feed — not a journal, more like an inbox.
- Takeaway: receipt-capture + category-review flow is the closest thing to "journaling" in finance apps, but framed as housekeeping, not reflection.

### Monarch Money
- Transaction-level `notes` (free text) + file attachments.
- No mood, no standalone journal.
- Strong emphasis on shared household goals and monthly reports. [verify]
- Takeaway: reflection happens in reports, not per-transaction.

### Rocket Money
- Barely any note-taking. Focus is bill-negotiation, subscription cancellation.
- Takeaway: non-journal app.

### Emma, Toshl, Spendee
- Emma: tags on transactions, no notes UI of note.
- Toshl: tags + optional free-text description per transaction.
- Spendee: notes + one photo per transaction.
- Takeaway: tags are universally attached to **transactions**, not to entries.

### Gap in finance apps
> [!tip] Opportunity
> No major finance app treats a note as a **first-class object** with its own
> list, search, and mood. They are all "appendages to a transaction". A
> journal tab that elevates reflections to a feed is a white-space.

---

## B. Journaling Apps — mood & prompts

### Daylio
- Core UX: one-tap **mood picker** (5 faces, colour-coded), then optional
  activity "chips" (tags). No free-text required.
- Mood is the **primary entity**; text is optional. Statistics show mood trend
  over time.
- Chips are **predefined** (work, family, sport…) with custom additions.
- Takeaway: friction is measured in seconds. Emoji + chip = one session.

### Stoic
- Morning and evening **prompts** ("What am I grateful for?").
- Mood slider 1-10 + tags.
- Weekly reports tie mood to themes.
- Takeaway: prompt-led UX converts non-writers into writers.

### Reflectly
- AI-generated daily prompt, mood selector, single photo attachment.
- Heavy use of gradients / "journal-as-premium" visual style.
- Takeaway: daily cadence + push notification = retention hook.

### Day One (Automattic)
- Free-form entries with rich photo galleries, weather, location autotagged.
- Multiple **journals** (buckets), not types.
- Markdown support. Search across all entries.
- Takeaway: polish of gallery + auto-context (date/place/weather) is what
  makes "notes" feel valuable long-term.

### How journal apps handle mood
- **Always emoji-only in the picker.** Labels appear on tap / in stats, never
  inline with the emoji (solves Akifi's truncation bug).
- Colour is used as semantic cue (green=great, red=stressed).
- 5 options is the consensus. 3 is too coarse, 7 is analysis paralysis.

### How journal apps handle tags
- **Chips**, not text fields with plus buttons. Recently-used chips surface
  first. "Create new" is a secondary affordance inside a sheet.
- Tags are **preloaded** with common suggestions for new users (onboarding
  seeds 8-12 default chips).

---

## C. Where Akifi Wins — Journal-First Finance

Synthesis for positioning:

| Axis | Finance apps | Journal apps | Akifi opportunity |
|------|--------------|--------------|-------------------|
| Entry as first-class | No | Yes | **Yes** — dedicated tab |
| Mood linked to money | No | No | **Yes** — correlate mood × spend |
| Transaction-bound note | Memo only | N/A | **Yes** — rich link w/ two-way nav |
| Weekly reflection prompts | No | Yes | **Yes** — already prototyped |
| Photo attached to entry | 0-1 photo | Unlimited | 1-3 photos sweet spot |
| Private-by-default | Yes | Yes | Yes (preserve) |

> [!tip] Positioning hypothesis
> Akifi is the **only** iOS app that lets a user say "I was stressed this
> week and here's what I spent" in one place. This is the "journal-first
> finance app" identified in `project_market_analysis.md`.

---

## D. Concrete UX patterns to steal

1. **Daylio**: mood picker = 5 coloured faces, label in tooltip only.
2. **Copilot**: "Review" inbox for recent transactions needing a note
   (could be Akifi's "Unjournaled spending").
3. **Stoic**: prompt-of-the-day on journal tab header.
4. **Day One**: EXIF-style meta strip (date · mood · amount linked) under
   title of each entry.
5. **Reflectly**: gradient card only on the hero/new-entry CTA, not on every
   item — keeps list scannable.

---

## E. Anti-patterns to avoid

- Text-field-with-plus-button for tags (Akifi current). Replace with chips.
- Three note types in a segmented picker. Users don't understand taxonomy
  they didn't ask for. Daylio/Day One use **one** entry type + metadata.
- Mood label under emoji breaking on long locales. Emoji-only in picker.
- Photo picker that silently drops data. If you can't store it, don't show
  the picker.

---

## Links
- [[project_market_analysis]] — Akifi's broader competitive landscape
- [[feature-roadmap]]
- [[journal-v2]] — PRD produced from this research
