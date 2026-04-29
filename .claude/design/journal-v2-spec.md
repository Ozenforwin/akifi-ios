# Journal Module v2 — Design Specification
**Akifi iOS — SwiftUI / iOS 17+**
Version 1.0 | April 2026 | **Revision 2 added: April 2026**

---

## Revision 2 — HIG Compliance & UX Fixes

**Status:** Active — supersedes the v1 decisions listed below where marked DEPRECATED.
**Trigger:** User feedback on shipped screens. Four screenshots reviewed: empty state, entry detail, timeline list, tag form with overlap bug.

---

### R2.1 — Accent Bar Decision

**Decision: Remove accent bar from Note cards and the detail header. Retain for Reflection only, but move it out of the leading edge.**

**Rationale:**
The 4pt leading rectangle was borrowed from productivity apps (Notion, Bear) where it signals a document status color. In Akifi's card context it reads as a visual bug — users reported it as unexplained decoration. The bar also broke the card's `cornerRadius: 12` silhouette (the bar's leading corners were square, fighting the card's rounded shape in the actual implementation).

**Type differentiation without the bar — revised approach:**

| Signal | Note | Reflection |
|--------|------|------------|
| Type pill (top of content area, inline) | `note.text` icon + "Note" label, blue tint capsule | `brain.head.profile` icon + "Рефлексия" label, violet tint capsule |
| Card background | `Color(.secondarySystemGroupedBackground)` — neutral | `Color.budget.opacity(0.05)` — very slight violet tint |
| Left bar | **Removed entirely** | **Removed entirely** |

The type pill sits inside the card's top-leading area, identical in size for both types, so differentiation is icon + color only — no asymmetric geometry.

**Type Pill Spec:**
```
HStack(spacing: 4)
├── Image(systemName: displayType.icon)   .caption2, type color
└── Text(displayType.localizedName)       .caption2.weight(.medium), type color
```
Pill background: `typeColor.opacity(0.10)`, `Capsule()`, padding h:8 v:3.

The type pill replaces the `Image(systemName: displayType.icon)` standalone icon from v1's `headerRow`.

~~DEPRECATED: v1 Section 2 "Visual Differentiation in the Timeline" — accent bar column~~
~~DEPRECATED: v1 Section 3.3 "Detail Header" — `Rectangle().fill(accentColor).frame(width: 4)` leading bar~~
~~DEPRECATED: v1 Section 6 Accessibility — "Left edge type bar (card)" accessibilityLabel row (no longer needed)~~

---

### R2.2 — Empty State Buttons

**Decision: Single primary button + secondary text link below.**

**Rationale:**
Two side-by-side buttons with mismatched styles (`.borderedProminent` + `.bordered`) and no horizontal constraint caused them to stretch to screen edges at different visual weights. HIG specifies: when there is a primary action, it should dominate; secondary actions should be clearly subordinate.

"Месячная рефлексия" / "Monthly reflection" is a secondary path — most users open the journal to write a note. Making it a full-width bordered button gives it false parity.

**Revised Empty State Layout:**
```
VStack(spacing: 24)
├── Spacer()
├── ZStack
│   ├── Circle()   80pt  Color.accent.opacity(0.08)
│   └── Image(systemName: "text.book.closed")   .font(.system(size: 32))   Color.accent
├── VStack(spacing: 8)
│   ├── Text("journal.empty.title")    .title3.weight(.semibold)   .primary
│   └── Text("journal.empty.subtitle") .body   .secondary   multilineTextAlignment(.center)
│       .padding(.horizontal, 40)
├── Button("journal.empty.writeNote")   .borderedProminent   .controlSize(.large)
│   (single full-width button, not stretched — use .frame(maxWidth: 280))
├── Button("journal.empty.reflection")
│   .buttonStyle(.plain)
│   .font(.subheadline)
│   .foregroundStyle(Color.budget)
│   (plain text link, no border, no fill — clear secondary signal)
└── Spacer()
```

The primary button uses `.controlSize(.large)` so it reaches 50pt height and reads as a confident primary CTA. The secondary plain-text button sits 8pt below with violet foreground to match the Reflection type color — visually suggests the action relates to reflection without competing for attention.

~~DEPRECATED: v1 Section 3.1 Empty State — `HStack(spacing: 12)` with two side-by-side buttons~~

---

### R2.3 — Filter Bar Overflow Fix

**Decision: Cap displayed tag chips at 5 visible + "More" button that presents a full-list sheet. Also add leading/trailing edge fade indicators.**

**Rationale:**
The current `ScrollView(.horizontal)` with no content inset clips the last chip visibly at the trailing edge, and there is no visual affordance that more chips exist. On RU-heavy tag names (e.g., `#рефлексии`, `#планирование`) even 3 chips can fill the visible width.

**Revised Filter Bar:**
```
ScrollView(.horizontal, showsIndicators: false) {
    HStack(spacing: 8) {
        // Type filters (All, Notes, Reflections)
        ForEach(NoteFilter.allCases) { filter in
            FilterChip(title: filter.localizedName, isSelected: …) { … }
        }

        Divider().frame(height: 20)  // existing pattern

        // Tag chips — show only top 5 by frequency
        ForEach(viewModel.tagsByFrequency.prefix(5), id: \.self) { tag in
            TagFilterChip(tag: tag, isSelected: …) { … }
        }

        // "More" chip — only shown when there are > 5 tags
        if viewModel.tagsByFrequency.count > 5 {
            Button {
                showTagFilterSheet = true
            } label: {
                Text("+ \(viewModel.tagsByFrequency.count - 5)")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color(.quaternarySystemFill)))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
}
.mask {
    // Trailing edge fade mask to signal scrollability
    HStack(spacing: 0) {
        Color.black  // opaque left side
        LinearGradient(
            colors: [.black, .clear],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: 32)
    }
}
```

`TagFilterSheet`: a `.sheet` with `.presentationDetents([.medium])` containing a `List` of all tags, each row tappable to select/deselect, with a swipe-to-delete affordance for tag history deletion (see R2.5). Sheet navigation title: "Теги" / "Tags". Done button top-right.

The existing `FilterChip` component in `Shared/FilterHeaderView.swift` is already correct for type filters — reuse it. Tag chips use the existing inline style from `JournalTabView.filterBar` but capped at 5.

~~DEPRECATED: v1 Section 3.1 Filter Bar — "No changes to the scroll mechanics" note~~

---

### R2.4 — Tag Picker Overlap Fix (Form)

**Decision: Hard structural separation between applied-tags FlowLayout and suggestions row. Suggestions are never placed inside the same FlowLayout as applied chips. A section label separates them.**

**Root cause of current bug:**
The `FlowLayout` containing applied chips + `inlineAddTagField` and the `ScrollView(.horizontal)` of suggestions are both rendered in the same `VStack(alignment: .leading, spacing: 8)`, but when the FlowLayout grows to 2+ rows, the absolute positions of chips in the flow collide with the suggestions ScrollView below it because SwiftUI's frame negotiation with `FlowLayout` (a custom `Layout`) doesn't always produce a correct intrinsic height in a `ScrollView` context. The result is the visual overlap seen in Screenshot 4.

**Revised Tags Block:**
```
VStack(alignment: .leading, spacing: 0) {

    // ── Section 1: Applied Tags ──────────────────────────────
    VStack(alignment: .leading, spacing: 6) {
        Text("journal.tags")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)

        // Applied chips + inline add field
        // Wrapped in a GeometryReader to force explicit height on FlowLayout
        FlowLayout(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                RemovableTagChip(tag: tag) { removeTag(tag) }
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
            AddTagInlineField(text: $tagInput, isFocused: $tagFieldFocused) {
                commitTagInput()
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        // Force layout engine to measure correctly:
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.top, 8)

    Divider().padding(.horizontal, 16)  // visual separator between sections

    // ── Section 2: Suggestions ──────────────────────────────
    VStack(alignment: .leading, spacing: 6) {
        Text(tagInput.isEmpty ? "journal.tags.suggested" : "journal.tags.matching")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 16)
            .padding(.top, 8)

        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tagSuggestions, id: \.self) { tag in
                    SuggestionChip(tag: tag) { addTag(tag) }
                        .contextMenu {
                            Button(role: .destructive) {
                                confirmDeleteTagFromHistory(tag)
                            } label: {
                                Label("journal.tag.deleteFromHistory", systemImage: "trash")
                            }
                        }
                }
                if !tagInput.isEmpty && tagSuggestions.isEmpty {
                    CreateTagChip(tag: tagInput) { commitTagInput() }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
    }
    // Hide entire Section 2 when there are no suggestions and input is empty
    .opacity((tagSuggestions.isEmpty && tagInput.isEmpty) ? 0 : 1)
    .frame(height: (tagSuggestions.isEmpty && tagInput.isEmpty) ? 0 : nil)
    .clipped()
}
```

Key fix: `FlowLayout` must be given `.fixedSize(horizontal: false, vertical: true)` so that the custom Layout correctly reports its intrinsic height to the parent `VStack`. Without this, the VStack does not reserve the correct vertical space and the next sibling (suggestions) overlaps. This is the minimal code change — the rest of the block structure already exists in the form.

The Divider between Section 1 and Section 2 ensures visual separation even when FlowLayout wraps to 3+ rows.

~~DEPRECATED: v1 Section 4.1 Tag Input Area Layout — single VStack with both FlowLayout and suggestions (replace with the two-section structure above)~~

---

### R2.5 — Tag Deletion from History

**Decision: Two surfaces. Primary: long-press context menu on suggestion chips. Secondary: dedicated screen in Settings.**

**Surface 1 — Context Menu on SuggestionChip (in form and in TagFilterSheet):**

Every `SuggestionChip` rendered in the form's suggestions row and in the `TagFilterSheet` list gets a `.contextMenu`:

```
SuggestionChip(tag: tag)
    .contextMenu {
        Button(role: .destructive) {
            pendingDeleteTag = tag
            showDeleteTagConfirm = true
        } label: {
            Label("journal.tag.deleteFromHistory", systemImage: "trash")
        }
    }
```

`showDeleteTagConfirm` triggers a `.confirmationDialog` (not Alert — HIG prefers `confirmationDialog` for destructive actions with body text explaining scope):

```
.confirmationDialog(
    "journal.tag.deleteTitle",    // "Удалить тег?"
    isPresented: $showDeleteTagConfirm,
    titleVisibility: .visible
) {
    Button("journal.tag.deleteConfirm", role: .destructive) {
        Task { await viewModel.deleteTagFromHistory(pendingDeleteTag) }
    }
    Button("action.cancel", role: .cancel) {}
} message: {
    Text("journal.tag.deleteMessage")
    // "Тег #\(pendingDeleteTag) будет удалён из всех заметок. Это действие нельзя отменить."
}
```

`viewModel.deleteTagFromHistory(_ tag: String)` — new method to add to `JournalViewModel`. Removes the tag string from `tags` array of every `FinancialNote` record in Supabase. Local cache updated by filtering.

**Surface 2 — Settings → Manage Tags screen:**

Add a row to `SettingsView`: "Управление тегами" / "Manage Tags", navigates to `TagManagementView`.

`TagManagementView`:
```
NavigationStack
└── List(viewModel.allTags, id: \.self) { tag in
        HStack {
            Text("#\(tag)")   .font(.body)
            Spacer()
            Text("\(viewModel.tagUsageCount(tag)) заметок")
                .font(.caption)   .foregroundStyle(.secondary)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                pendingDeleteTag = tag
                showDeleteTagConfirm = true
            } label: {
                Label("action.delete", systemImage: "trash")
            }
        }
    }
    .navigationTitle("journal.manageTagsTitle")
    .confirmationDialog(…)   // same dialog as Surface 1
```

Tag usage count is derived from `dataStore.notes.flatMap(\.tags ?? []).filter { $0 == tag }.count` — no extra API call.

---

### R2.6 — Entry Detail Header Rework

**Decision: Remove leading accent bar, strengthen date contrast, fix mood inline alignment.**

**Revised `detailHeader`:**
```
VStack(alignment: .leading, spacing: 8)   padding: h:16, top:12
├── // Row 1: Type pill (left) + Date (right)
│   HStack(alignment: .center) {
│       TypePill(displayType: displayType)   // per R2.1 spec
│       Spacer()
│       Text(formattedDate)
│           .font(.footnote)              // was .caption — still small but 13pt not 12pt
│           .foregroundStyle(.secondary)  // was .tertiary — WCAG AA pass at this size
│   }
│
├── // Row 2: Title (if present)
│   Text(note.title)   .font(.title2.weight(.bold))
│
└── // Row 3: Mood (if present) — inline HStack with fixed leading alignment
    HStack(alignment: .center, spacing: 6) {
        Text(mood.emoji)
            .font(.body)        // was .title3 (22pt) — reduce to 17pt to match text baseline
        Text(mood.localizedName)
            .font(.subheadline)  // was .caption — increase to 15pt to match emoji visual weight
            .foregroundStyle(.secondary)
    }
```

Changes from v1:
- No `HStack(alignment: .top, spacing: 0)` outer container with leading `Rectangle()`.
- Date foregroundStyle changed from `.tertiary` to `.secondary` — eliminates low-contrast complaint while keeping hierarchy (title is still bolder, date is medium weight).
- Mood emoji reduced from `.title3` (22pt) to `.body` (17pt) so it baseline-aligns naturally with the `.subheadline` (15pt) mood name without manual offset. The mismatch that caused poor alignment in Screenshot 2 was the 22pt emoji sitting on a different baseline grid than the 12pt caption text.
- `.footnote` for date (13pt) is still clearly smaller than `.title2` for title — hierarchy preserved.

~~DEPRECATED: v1 Section 3.3 Detail Header — full `HStack(alignment: .top, spacing: 0)` with leading Rectangle, `.caption` date, `.title3` mood emoji~~

---

### R2.7 — Card Redesign Without Accent Bar

**Decision: Type pill replaces the bar as the sole type differentiator. Card structure cleaned up.**

**Revised Standard Card (Variant A) — `JournalNoteCardView.standardCard`:**
```
VStack(alignment: .leading, spacing: 6)
    .padding(.horizontal, 12)
    .padding(.vertical, 12)
    .background(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(cardBackground)
    )
    // No HStack wrapper, no leading Rectangle

Content of VStack:
├── HStack(alignment: .center, spacing: 8)
│   ├── TypePill(displayType: displayType)     // per R2.1
│   ├── (if mood) Text(mood.emoji)   .caption  // already compact — no change
│   └── Spacer()
│   └── Text(formattedTime)   .caption2   .tertiary
├── Text(title ?? content)   .subheadline.weight(.semibold)   lineLimit: 1
├── (if title) Text(content)   .caption   .secondary   lineLimit: 2
├── (if tx) linkedTransactionBadge(tx)
└── (if tags) tagChipRow(tags)
```

The outer `HStack(alignment: .top, spacing: 0)` wrapping the bar + content VStack is replaced by a plain `VStack`. The `padding(.leading, 0)` and `padding(.trailing, 16)` asymmetry is replaced by symmetric `padding(.horizontal, 12)`.

**Photo-first card (Variant B):** Remove the inner `HStack(alignment: .top, spacing: 0)` with `Rectangle()` from the body section below the photo strip. Replace with a plain `VStack(alignment: .leading, spacing: 6).padding(12)`.

The card shadow `shadow(color: .primary.opacity(0.06), radius: 6, x: 0, y: 2)` already used by `TransactionRowView` should be applied here for consistency — it is currently missing from `JournalNoteCardView`.

~~DEPRECATED: v1 Section 3.1 Card Variants — `HStack(alignment: .top, spacing: 0)` with leading `Rectangle()` accent bar~~

---

### R2.8 — Accessibility & Long Russian Labels

**Additions to Section 6 (Accessibility):**

**Dynamic Type & Russian text:**
- `TypePill` text ("Заметка" = 6 chars, "Рефлексия" = 9 chars) must be tested at `.accessibilityExtraExtraExtraLarge`. At that size, the pill text will wrap or truncate. Solution: set `.lineLimit(1)` and `.minimumScaleFactor(0.75)` on the pill text, and set a `.fixedSize(horizontal: true, vertical: false)` on the pill `HStack` so it does not stretch the card header row.
- Filter chips in the filter bar with Russian tag names (e.g., `#планирование` = 13 chars) will overflow at default large-text sizes. The filter bar's `ScrollView(.horizontal)` naturally handles this — no additional fix needed since users can scroll.
- Empty state subtitle at xL+ Dynamic Type: the subtitle text uses `padding(.horizontal, 40)` — at the largest DT sizes this may leave only ~30pt of readable width on SE-sized devices. Change to `padding(.horizontal, 24)` minimum, and allow unlimited lines (no `lineLimit`).
- `TagManagementView` tag rows: set `.minimumScaleFactor(0.85)` on tag text so long tags like `#финансовоепланирование` don't truncate on SE.

**Contrast additions:**
- `TypePill` text: `typeColor` at 100% opacity on `typeColor.opacity(0.10)` background. Check: `Color.accent` (#3B82F6) on white at 10% opacity ≈ 4.5:1 — passes AA for normal text at 12pt bold. `Color.budget` (#8B5CF6) same calc ≈ 4.6:1 — passes.
- Suggestions section label (`.tertiary` foreground): only used as a non-interactive label at 11pt `.caption2`. Acceptable per HIG for de-emphasized supplementary text — but increase to `.caption` (12pt) to match the project's own rule in v1 Section 5 Typography: "No `.caption2` for content or labels."

---

### R2.9 — Consistency with Existing Components

Observations from reading `TransactionRowView.swift`, `FilterHeaderView.swift`, `EmptyStateView.swift`:

| Pattern | Existing usage | Journal v2 alignment |
|---------|---------------|---------------------|
| Card background | `Color(.secondarySystemGroupedBackground)` + `cornerRadius: 16` + shadow `opacity 0.06, radius 6` | Adopt same shadow. Use `cornerRadius: 12` (already in spec, acceptable — 12 vs 16 is a deliberate Journaling softness choice) |
| Icon background | 44×44 `RoundedRectangle(cornerRadius: 12)` with category color at 0.08 opacity | TypePill uses capsule shape — intentionally different from icon circles, consistent with tag chip pattern |
| Filter chips | `FilterChip` in `FilterHeaderView.swift` uses outlined capsule (stroke, no fill for unselected) | `JournalTabView.filterBar` currently uses solid fill for selected, no-stroke for unselected — this is inconsistent with `FilterChip`. **Fix:** For type filters (All/Notes/Reflections), reuse `FilterChip` from `Shared/FilterHeaderView.swift` directly. For tag chips, keep the violet tint fill style (separate semantic purpose). |
| Empty state | `EmptyStateView` uses single-action capsule button | Journal empty state uses the same icon+title+subtitle pattern but with a custom two-action layout (R2.2). Do not use `EmptyStateView` directly — it only supports one action. |
| Section labels | `.footnote.weight(.semibold)` `.secondary` — already consistent across Journal and Transactions | No change. |

---

### R2 — Summary of All Changed Sections

| Original Section | Status | What Changed |
|-----------------|--------|-------------|
| 2 — Visual Differentiation | REVISED | Accent bar removed for both types. TypePill introduced. |
| 3.1 — Empty State | REVISED | Two side-by-side buttons → primary button + plain text link |
| 3.1 — Filter Bar | REVISED | Cap at 5 tags + More button + trailing fade mask |
| 3.1 — Card Variants A & B | REVISED | Remove leading Rectangle bar, add TypePill, add shadow |
| 3.3 — Detail Header | REVISED | Remove bar, `.secondary` date, body+subheadline mood row |
| 4.1 — Tag Input Area | REVISED | Two-section VStack with `.fixedSize` fix, Divider separator |
| 4.1 — SuggestionChip | REVISED | Add `.contextMenu` with destructive delete-from-history |
| 6 — Accessibility | ADDENDUM | Long RU labels, Dynamic Type, contrast for TypePill |
| NEW — Settings | ADDED | TagManagementView for bulk tag history management |

---

## Table of Contents

1. Design Principles
2. Entry Types Model
3. Screen Specs
   - 3.1 Journal List (Timeline)
   - 3.2 New / Edit Entry Form
   - 3.3 Entry Detail
4. Component Specs
   - 4.1 Tag Chip + Picker
   - 4.2 Mood Selector
   - 4.3 Transaction Linker
   - 4.4 Photo Attachments
5. Design Tokens
6. Accessibility
7. Motion & Micro-interactions

---

## 1. Design Principles

### P1 — Reflection-First
The Journal is a tool for meaning-making, not just logging. Every screen prioritises the emotional/contextual layer (mood, reflection prompt) over the mechanical layer (transaction ID, tags). The question "how do I feel about this?" comes before "what is the metadata?"

### P2 — Context-Rich Cards
A card in the timeline should tell a micro-story: who (mood), what (title/content excerpt), connected to what (linked transaction amount badge), and when (time). Cards with photos lead with a photo. Cards with a linked transaction show an amount badge. No card is just a title + timestamp.

### P3 — Low-Friction Capture
The most common action — write a quick thought — must require the fewest taps. A single FAB opens directly to the text field with the keyboard raised. Type-ahead and suggestion features (tags, moods, transaction links) fill in metadata after content is written, never before.

### P4 — Earned Depth
Advanced fields (linked transaction, tags, period for reflection) are discoverable but not forced. They appear in a "More details" expandable section below the primary content area. Power users find them; new users are not overwhelmed.

### P5 — Language-Neutral UI
All labels that appear alongside emoji or icons must either fit within a fixed width (using a compact format) or be hidden behind a tooltip/long-press. No full-length emotion names ("Беспокойство") appear as visible card labels. Emoji are self-sufficient for instant recognition; text is available as an accessibility label only.

---

## 2. Entry Types Model

### Decision: Collapse Three Types into Two with a Subtype

The current three-way split (freeform / transaction / reflection) causes confusion because the distinction between freeform and reflection is invisible to the user at the point of creation. The redesign collapses to two surface-level types with a single structural difference:

| Type | Display Name (EN) | Display Name (RU) | SF Symbol | Accent Color |
|------|-------------------|-------------------|-----------|--------------|
| **Note** | Note | Заметка | `note.text` | `Color.accent` (#3B82F6 blue) |
| **Reflection** | Reflection | Рефлексия | `brain.head.profile` | `Color.budget` (#8B5CF6 violet) |

Both types support: title, content, mood, tags, photos.
Only **Note** supports: linked transaction.
Only **Reflection** supports: period (start / end date range for monthly/weekly review).

### Why Not Three Types

- `freeform` and `reflection` are identical structurally except for `periodStart/periodEnd`. The user never benefits from seeing these as separate creation flows.
- The type distinction is now a toggle inside a single form, not a separate entry point. The toggle only exposes the period picker (for Reflection) or transaction linker (for Note).
- The `NoteType.freeform` and `NoteType.reflection` enum cases are preserved in the model for backward compatibility. The form writes `freeform` for quick notes and `reflection` when the period picker has been used.

### Quick-Action Menu (replaces Menu "+Note / +Reflection")

A single FAB button with a long-press or swipe-up reveals three **contextual actions** that pre-fill the form:

| Action | Icon | Pre-fills |
|--------|------|-----------|
| Quick note | `pencil` | Opens form with cursor in content field, type = freeform |
| About a purchase | `cart` | Opens form with transaction linker sheet immediately presented, type = transaction |
| Monthly reflection | `calendar.badge.checkmark` | Opens form with period picker pre-set to current month, type = reflection |

The FAB itself (single tap) performs "Quick note" directly.

### Visual Differentiation in the Timeline

| Signal | Note | Reflection |
|--------|------|------------|
| Left edge accent bar (4 pt wide, full card height) | `Color.accent` | `Color.budget` |
| Type icon (top-left, 14pt) | `note.text` in blue | `brain.head.profile` in violet |
| Card background | `Color.cardBackground` (neutral) | `Color.budget.opacity(0.04)` subtle tint |

Transaction-linked Notes additionally display an amount badge (see Section 4.3).

---

## 3. Screen Specs

---

### 3.1 Journal List (Timeline)

#### Layout Structure

```
NavigationStack
└── VStack(spacing: 0)
    ├── FilterBar          (fixed, does not scroll with content)
    └── ScrollView
        └── LazyVStack(spacing: 0)
            ├── Section header "Today"
            │   ├── JournalCardView (photo-first, large)    ← if note has photos
            │   ├── JournalCardView (standard)
            │   └── JournalCardView (transaction-linked)
            ├── Section header "Yesterday"
            │   └── ...
            └── Pagination trigger (ProgressView)
```

#### Filter Bar

Same horizontal ScrollView pattern as today. Chip order:
1. "All" (default selected)
2. "Notes" (filters to freeform + transaction type)
3. "Reflections" (filters to reflection type)
4. Divider (1px, systemGray4)
5. User tags — each as a tappable `#tag` chip (de-selected state: `Color(.quaternarySystemFill)` bg; selected: `Color.budget.opacity(0.15)` bg + violet text)

No changes to the scroll mechanics. Tags in the filter bar are populated from `viewModel.allTags` sorted by usage frequency (most used first).

#### Section Headers

```
HStack
├── Text("Today")          .footnote.weight(.semibold)  .secondary
└── Spacer()
```

Padding: horizontal 16, top 20, bottom 6. No background (transparent, not sticky).

#### Card Variants

Three card variants. The view model/card component selects the variant based on note properties.

**Variant A — Standard Card** (no photos, no linked transaction)

```
HStack(alignment: .top, spacing: 0)
├── Rectangle()  // left edge accent bar: width 3, full height, cornerRadius on left only
└── VStack(alignment: .leading, spacing: 6)
    ├── HStack
    │   ├── Image(systemName: type.icon)   .caption, iconColor
    │   ├── Text(mood.emoji)               .caption  (if mood exists)
    │   ├── Spacer()
    │   └── Text("14:32")                 .caption2, .tertiary
    ├── Text(title ?? content)            .subheadline.weight(.semibold)  lineLimit: 1
    ├── Text(content)                     .caption, .secondary  lineLimit: 2
    │   (only shown if title is non-nil)
    ├── TagChipRow(tags.prefix(3))        (if tags exist)
    └── ("+N more tags" text if > 3)      .caption2, .tertiary
```

Full card padding: top/bottom 12, leading 0 (bar flush), trailing 16.
Card background: `Color.cardBackground`, cornerRadius 12.
Outer horizontal padding: 16. Vertical gap between cards: 6.

**Variant B — Photo-First Card** (note has >= 1 photo URL)

```
VStack(alignment: .leading, spacing: 0)
├── PhotoThumbnailStrip(urls: note.photoUrls)   height: 140, cornerRadius top 12
└── VStack(alignment: .leading, spacing: 6)      padding: 10
    ├── HStack
    │   ├── Image(systemName: type.icon) + Text(mood.emoji)
    │   └── Text("14:32")  .caption2, .tertiary
    ├── Text(title ?? content)    .subheadline.weight(.semibold)  lineLimit: 1
    └── TagChipRow  (if tags exist)
```

`PhotoThumbnailStrip`: if 1 photo — full width single image. If 2 photos — side by side (equal width). If 3+ photos — left image 60% width, right column shows 2 images stacked (top = 2nd photo, bottom = "+" count badge if > 2 remaining).

**Variant C — Transaction-Linked Card** (note has transactionId resolved to a tx object)

Identical to Variant A, with an additional row inserted after the content excerpt:

```
HStack(spacing: 6)
├── Image(systemName: tx.type == .income ? "arrow.down" : "arrow.up")
│   .font(.caption2)  foregroundStyle: income/expense color
├── Text(formattedAmount)     .caption.weight(.semibold)  monospaced
├── Text("·")                 .caption2, .tertiary
└── Text(categoryName)        .caption2, .secondary
```

Background: `(incomeColor or expenseColor).opacity(0.08)` capsule, padding h:10 v:4.

#### Empty State

```
VStack(spacing: 20)
├── Spacer()
├── ZStack
│   ├── Circle()  80pt, accent.opacity(0.08)
│   └── Image(systemName: "text.book.closed")  .font(.system(size: 32))  .accent
├── Text("Your financial story starts here")   .title3.weight(.semibold)
├── Text("Notes help you remember why you spend, \nhow you felt, and what changed.")
│   .body, .secondary, multilineTextAlignment: .center, padding h: 32
├── HStack(spacing: 12)
│   ├── Button("Write a note")     .borderedProminent  → FAB quick-note action
│   └── Button("Monthly reflection")  .bordered  → FAB reflection action
└── Spacer()
```

#### Navigation Bar

- Principal: `Text("Journal")` `.headline` + `Text("BETA")` capsule (keep existing pattern)
- Trailing: Single `Image(systemName: "plus.circle.fill")` `.title3` — single tap = quick note (no menu). Long-press = quick-actions sheet (see FAB spec in Section 3.2).

---

### 3.2 New / Edit Entry Form

#### Form Architecture

The form is a full-screen sheet (`presentationDetents: [.large]`) with `presentationBackground(.regularMaterial)`.

Structure:

```
NavigationStack
└── ScrollView
    └── VStack(spacing: 0)
        ├── TypeToggleBar          (sticky at top, below nav bar)
        ├── ContentArea            (title + body text, always visible)
        ├── MoodRow                (always visible, horizontal)
        ├── Divider
        └── DetailsSection         (collapsed by default for new entries; auto-expanded when editing)
            ├── TagPicker
            ├── PhotoPicker (inline thumbnails)
            ├── TransactionLinker   (Note type only)
            └── PeriodPicker        (Reflection type only)
```

Nav bar: Cancel (left), inline title "New Note" / "New Reflection" / "Edit", Save (right, `.semibold`, disabled when content empty).

#### Type Toggle Bar

```
HStack(spacing: 0)
├── TypeToggleButton("Note",       icon: "note.text",          isSelected: type == .freeform)
└── TypeToggleButton("Reflection", icon: "brain.head.profile",  isSelected: type == .reflection)
```

Each button: full-width equal columns, height 36, background when selected: `systemBackground` with shadow depth 1, background when unselected: `tertiarySystemFill`. The entire bar has `tertiarySystemFill` background, padding h:16 v:8. Animation: `.easeInOut(duration: 0.15)`.

When type changes to Reflection, the TransactionLinker row disappears and the PeriodPicker row appears (both with slide + fade transition, duration 0.2).

#### Content Area

```
VStack(alignment: .leading, spacing: 0)
├── TextField("Title (optional)", text: $title)
│   .font(.title3.weight(.semibold))
│   .padding(EdgeInsets(top: 16, leading: 16, bottom: 0, trailing: 16))
│   ReturnKeyType: .next  (focuses TextEditor)
└── TextEditor(text: $content)
    .font(.body)
    .frame(minHeight: 160)
    .padding(EdgeInsets(top: 4, leading: 12, bottom: 16, trailing: 16))
    placeholder: "What's on your mind?" / "Что у тебя на уме?"
```

No Section wrapper (no Form). The content area uses plain VStack for a note-like feel, without the grouped list aesthetic.

#### Mood Row

Always visible, directly below content area.

```
HStack(spacing: 8)
├── Text("Mood")   .caption, .secondary  (or localized "journal.mood")
└── Spacer()
    ForEach(NoteMood.allCases) { mood in
        MoodButton(mood: mood, isSelected: selectedMood == mood)
    }
```

`MoodButton`: emoji only (`.title3`), inside a circle of diameter 40. Selected state: `Color.accent.opacity(0.15)` fill + 1.5pt `Color.accent` stroke. Unselected: `Color(.quaternarySystemFill)` fill. Deselect by tapping the selected mood again. See Section 4.2 for full MoodButton spec.

#### Details Section (Expandable)

Default state for a new entry: collapsed, shown as a single tappable row.

```
Button {
    withAnimation(.easeInOut(duration: 0.2)) { showDetails.toggle() }
} label: {
    HStack {
        Label("More details", systemImage: "chevron.right.circle")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        Spacer()
        Image(systemName: showDetails ? "chevron.up" : "chevron.down")
            .font(.caption)
            .foregroundStyle(.tertiary)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
}
```

When expanded, reveals:
1. TagPicker (Section 4.1)
2. PhotoPicker (Section 4.4)
3. TransactionLinker (Section 4.3) — Note type only
4. PeriodPicker — Reflection type only

PeriodPicker: two `DatePicker` controls (Start / End) inline, `displayedComponents: .date`. Label: "Period". Only shown when `noteType == .reflection`.

When `editingNote != nil`, the details section opens automatically if the note has tags, photos, a linked transaction, or a period.

---

### 3.3 Entry Detail

#### Layout

```
ScrollView
└── VStack(alignment: .leading, spacing: 0)
    ├── DetailHeaderView        (type bar + mood + date)
    ├── Divider                 padding h: 16
    ├── ContentView             (title + body)
    ├── LinkedTransactionCard   (if transactionId, with padding h:16)
    ├── PhotoGrid               (if photoUrls, full-bleed with h:16 padding)
    ├── TagsFlowView            (if tags, padding h:16)
    └── PeriodBadge             (if periodStart, padding h:16)
```

All sections separated by Spacer of 20pt, not Dividers (cleaner reading flow).

#### Detail Header

```
HStack(alignment: .top, spacing: 0)
├── Rectangle()   // accent bar, width 4, full height, type color
└── VStack(alignment: .leading, spacing: 4)   padding: 16
    ├── HStack
    │   ├── Label(type.localizedName, systemImage: type.icon)
    │   │   .font(.caption.weight(.semibold))
    │   │   .foregroundStyle(type == .reflection ? Color.budget : Color.accent)
    │   └── Spacer()
    │   └── Text(formattedDate)   .caption, .tertiary
    ├── (if title) Text(title)    .title2.weight(.bold)
    └── (if mood)  HStack
                   ├── Text(mood.emoji)  .title3
                   └── Text(mood.localizedName)  .caption, .secondary
```

Navigation title: empty string (the header carries the context). `navigationBarTitleDisplayMode(.inline)`.

Toolbar trailing: `Menu` with Edit + Delete (keep existing pattern).

#### Content

`Text(note.content)` with `.body` font, `.textSelection(.enabled)`, padding h:16. No container/card — plain text on the screen background.

#### Linked Transaction Card (Detail)

```
VStack(alignment: .leading, spacing: 8)  padding: 16, background: cardBackground, cornerRadius 12
├── Label("Linked Transaction", systemImage: "link")
│   .caption.weight(.semibold), .secondary
└── HStack(spacing: 12)
    ├── ZStack
    │   ├── Circle()  40pt  income/expense color at 0.1 opacity
    │   └── Image(systemName: tx.type == .income ? "arrow.down" : "arrow.up")
    │       foregroundStyle: income/expense color
    ├── VStack(alignment: .leading, spacing: 2)
    │   ├── Text(formattedAmount)   .headline
    │   └── Text(categoryName)     .caption, .secondary
    └── Spacer()
    └── Text(tx.date)              .caption2, .tertiary
```

Tappable: NavigationLink to transaction detail (if available in navigation stack) or present a simple transaction info sheet.

#### Photo Grid (Detail)

Full-bleed image grid, padding only on sides.

Single photo: full width, height 240, `resizable().scaledToFill()`, `clipped()`, `cornerRadius 12`.
Two photos: LazyVGrid 2 columns, equal width, height 160 each, `cornerRadius 12`.
Three+ photos: first photo full width height 200, then `LazyVGrid 3 columns` for remaining photos, height 100 each. `cornerRadius 8` for small thumbnails.

Each photo: tappable → presents `PhotoFullScreenViewer` (see Section 4.4).

#### Tags Flow

Horizontal `FlowLayout` of read-only tag chips. Chip: `#tag` in `.caption.weight(.medium)`, foreground `.budget` (violet), background `Color.budget.opacity(0.10)`, capsule, padding h:10 v:4.

#### Period Badge (Reflection only)

```
HStack(spacing: 6)
├── Image(systemName: "calendar")  .caption, Color.budget
└── Text("1 Apr – 30 Apr 2026")    .caption.weight(.medium), Color.budget
```

Shown inside a `RoundedRectangle(cornerRadius: 8)` with `Color.budget.opacity(0.08)` fill, padding h:12 v:6.

---

## 4. Component Specs

---

### 4.1 Tag Chip + Picker

#### Design Goals

- User must be able to add an existing tag in one tap (no keyboard required).
- User must see their history of tags clearly, sorted by frequency.
- Autocomplete must trigger on first keystroke and filter in real-time.
- Adding a brand-new tag (keyboard) must feel equivalent in cost to selecting an existing one.

#### Tag Input Area Layout

Replaces the current `TextField + "+" Button` row.

```
VStack(alignment: .leading, spacing: 8)
├── // Currently-applied tags (FlowLayout, wraps to multiple lines)
│   FlowLayout(spacing: 6)
│   └── ForEach(tags) {
│         TagChip(tag, removable: true)    // see TagChip spec below
│       }
│       AddTagField()                      // inline text input chip at the end of flow
│
└── // Suggestions header + row (shown when input is empty OR filtered when typing)
    VStack(alignment: .leading, spacing: 4)
    ├── Text("Suggested")   .caption2, .tertiary   (hidden when filtering)
    └── ScrollView(.horizontal, showsIndicators: false)
        └── HStack(spacing: 6)
            └── ForEach(suggestions) {
                  SuggestionChip(tag)
                }
```

#### AddTagField (inline chip)

Appears at the end of the applied-tags FlowLayout as a transparent input that looks like a chip outline:

```
HStack(spacing: 4)
├── Image(systemName: "plus")   .caption2, .secondary
└── TextField("Add tag", text: $tagInput)
    .font(.caption.weight(.medium))
    .textInputAutocapitalization(.never)
    .frame(minWidth: 60, maxWidth: 120)
    .onSubmit { commitTag() }
```

Outline: `Capsule().stroke(Color(.systemGray4), lineWidth: 1)`, padding h:8 v:4.
When `tagInput` is non-empty, the outline becomes `Color.accent` with 1.5pt stroke.

#### TagChip (applied, removable)

```
HStack(spacing: 4)
├── Text("#\(tag)")       .caption.weight(.medium), Color.budget
└── Button(action: remove) {
      Image(systemName: "xmark.circle.fill")
      .font(.caption2)
      .foregroundStyle(Color.budget.opacity(0.6))
    }
```

Background: `Color.budget.opacity(0.10)`, capsule. Padding h:8 v:4.

#### SuggestionChip (not yet applied)

Same visual as TagChip but without the remove button. Background: `Color(.quaternarySystemFill)`. Text: `.secondary`. Tap adds to applied tags with a spring scale animation (0.8 → 1.0, duration 0.2).

#### Suggestion Ordering Logic

1. When `tagInput` is empty: show all `viewModel.allTags` sorted by frequency of use, limited to 8 chips.
2. When `tagInput.count >= 1`: filter `viewModel.allTags` where tag `.hasPrefix(tagInput.lowercased())`, then show results. If none match, show a single chip "Create #\(tagInput)" styled with `Color.accent` border.

#### Removing a Tag

Tapping the `xmark.circle.fill` on a TagChip removes the tag and the chip flies out to the right with `.transition(.asymmetric(insertion: .scale(scale: 0.8).combined(with: .opacity), removal: .scale(scale: 0.8).combined(with: .opacity)))`.

---

### 4.2 Mood Selector

#### Decision: Emoji-Only Circles, No Visible Text Labels

**Rationale:** The five mood names in Russian ("Отлично", "Хорошо", "Нейтрально", "Беспокойство", "Стресс") are of unequal length and do not fit horizontally in a single row without clipping or wrapping on standard iPhone widths. The English equivalents are shorter but still inconsistent. Emoji alone are internationally understood for valence (positive → negative). Text labels are preserved as accessibility labels only.

**Rejected alternatives:**
- Vertical stack: takes too much vertical space in a compact form.
- Bottom sheet: breaks the "low friction" principle — too many taps for an optional field.
- Slider scale: loses the distinct mood identities; users think in states not continua.
- Tooltip on long-press: discoverability too low for first-time use.

#### MoodButton Spec

```
Button(action: { toggleMood(mood) }) {
    Text(mood.emoji)
        .font(.title3)   // ~22pt; large enough for tap recognition, not so large it dominates
        .frame(width: 44, height: 44)
        .background(
            Circle().fill(isSelected ? Color.accent.opacity(0.15) : Color(.quaternarySystemFill))
        )
        .overlay(
            Circle().stroke(isSelected ? Color.accent : Color.clear, lineWidth: 1.5)
        )
        .scaleEffect(isSelected ? 1.08 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isSelected)
}
.buttonStyle(.plain)
.accessibilityLabel(mood.localizedName)
.accessibilityAddTraits(isSelected ? [.isSelected] : [])
```

Touch target: 44×44pt (iOS HIG minimum). The `frame(width:44, height:44)` ensures this even though the visible circle may be smaller.

#### Mood Row Container

```
HStack(spacing: 4)      // 5 buttons × 44pt + 4 gaps × 4pt = 236pt — fits 320pt+ screens
    ForEach(NoteMood.allCases) { mood in
        MoodButton(mood: mood, isSelected: selectedMood == mood)
    }
Spacer()
```

Place inside `HStack(spacing: 0)` alongside `Text("journal.mood").caption.foregroundStyle(.secondary)` on the left, separated by `Spacer()`.

#### Selected Mood Display in Card and Detail

In `JournalNoteCardView`: show `Text(mood.emoji)` `.caption` next to the type icon (keep existing pattern). No text label.

In `JournalNoteDetailView` header: show `Text(mood.emoji)` `.title3` with `Text(mood.localizedName)` `.caption .secondary` to the right. This is the only place the full text name appears, because in detail view there is no width constraint.

---

### 4.3 Transaction Linker

#### Design Goal

Tapping the transaction row must open a searchable, scrollable list of recent transactions. The row must clearly communicate tappability and give immediate confirmation after selection. The "dead text" state must be eliminated.

#### Form Row (before selection)

```
Button(action: { showTransactionSheet = true }) {
    HStack(spacing: 12)
    ├── ZStack
    │   ├── Circle()  36pt  Color.accent.opacity(0.10)
    │   └── Image(systemName: "link")  .body  Color.accent
    ├── VStack(alignment: .leading, spacing: 2)
    │   ├── Text("Link a transaction")   .subheadline
    │   └── Text("Connect this note to a purchase or income")
    │       .caption, .secondary
    └── Spacer()
    └── Image(systemName: "chevron.right")  .caption2, .tertiary
}
.buttonStyle(.plain)
```

#### Form Row (after selection)

```
HStack(spacing: 12)
├── ZStack
│   ├── Circle()  36pt  income/expense color at 0.1
│   └── Image(systemName: directionIcon)  income/expense color
├── VStack(alignment: .leading, spacing: 2)
│   ├── Text(formattedAmount)   .subheadline.weight(.semibold)
│   └── Text(categoryName + " · " + date)  .caption, .secondary
└── Spacer()
└── Button(action: { clearTransaction() }) {
      Image(systemName: "xmark.circle.fill")
      .foregroundStyle(.secondary)
    }
```

Background: `(income/expense color).opacity(0.06)`, `cornerRadius 10`.

Tapping anywhere except the xmark re-opens the picker sheet.

#### TransactionPickerSheet

Presented as `.sheet` with `presentationDetents([.medium, .large])` and `presentationDragIndicator(.visible)`.

```
NavigationStack
├── .searchable(text: $searchText, placement: .navigationBarDrawer, prompt: "Search transactions")
└── List
    └── ForEach(groupedTransactions, id: \.date) { group in
          Section(header: Text(group.displayDate)) {
              ForEach(group.transactions) { tx in
                  TransactionPickerRow(tx: tx, isSelected: tx.id == selectedId)
                      .contentShape(Rectangle())
                      .onTapGesture { selectTransaction(tx); dismiss() }
              }
          }
        }
```

`TransactionPickerRow`:
```
HStack(spacing: 12)
├── ZStack
│   ├── Circle()  32pt  income/expense at 0.1
│   └── Image(systemName: directionIcon)  14pt  income/expense
├── VStack(alignment: .leading, spacing: 2)
│   ├── Text(categoryName ?? "Transfer")  .subheadline
│   └── Text(tx.date + " · " + accountName)  .caption, .secondary
└── Spacer()
└── Text(formattedAmount)  .subheadline.weight(.semibold)  income/expense color
    (if isSelected) Image(systemName: "checkmark")  .caption, Color.accent
```

Data sourced from `appViewModel.dataStore.transactions`, sorted by `date` descending. Filter: when `searchText` non-empty, filter where `categoryName.localizedCaseInsensitiveContains(searchText) || formattedAmount.contains(searchText)`. Show max 60 days of history (pagination not required for this component).

---

### 4.4 Photo Attachments

#### Design Goals

- After selecting photos, the user sees inline thumbnails — not a count badge.
- Each thumbnail has a visible delete affordance.
- Upload progress is visible per-image (Supabase upload).
- Tapping a photo in detail view opens a full-screen viewer.

#### Form: Photo Thumbnail Grid

Replaces the current `PhotosPicker + "Selected: N" text` pattern.

```
VStack(alignment: .leading, spacing: 10)
├── // Thumbnail row (existing selected photos)
│   ScrollView(.horizontal, showsIndicators: false)
│   └── HStack(spacing: 8)
│       ├── ForEach(selectedPhotoItems) { item in
│       │     PhotoThumbnailCell(item: item, onDelete: { remove(item) })
│       │   }
│       └── (if count < 5) AddPhotoButton()   // PhotosPicker trigger
│
└── // Upload state row (if any uploads in progress)
    ForEach(uploadingItems) { item in
        UploadProgressRow(item: item)
    }
```

`PhotoThumbnailCell`:
```
ZStack(alignment: .topTrailing)
├── Image(uiImage: thumbnail)
│   .resizable().scaledToFill()
│   .frame(width: 80, height: 80)
│   .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
└── Button(action: { removePending(item) }) {
      Image(systemName: "xmark.circle.fill")
      .font(.body)
      .foregroundStyle(.white)
      .shadow(radius: 2)
    }
    .offset(x: 6, y: -6)
```

`AddPhotoButton` (shown at the end of the row):
```
PhotosPicker(selection: $newPhotos, maxSelectionCount: max(0, 5 - selectedPhotoItems.count), matching: .images) {
    VStack(spacing: 4)
    ├── Image(systemName: "plus")   .title3, Color.accent
    └── Text("Add")                 .caption2, .secondary
}
.frame(width: 80, height: 80)
.background(Color(.quaternarySystemFill))
.clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
.overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(.systemGray4), style: StrokeStyle(lineWidth: 1, dash: [4])))
```

`UploadProgressRow` (per uploading photo):
```
HStack(spacing: 10)
├── Image(uiImage: thumbnail)   32×32, cornerRadius 4
├── ProgressView(value: progress)   .progressViewStyle(.linear)   Spacer fill
└── Text("\(Int(progress * 100))%")  .caption2, .tertiary   monospacedDigit
```

Maximum 5 photos. The `AddPhotoButton` disappears when count reaches 5.

Already-saved photos (from `note.photoUrls` when editing): displayed as `CachedAsyncImage` thumbnails with the same delete affordance, marked with a trash icon rather than xmark (deletes from remote on save).

#### Detail View: Full-Screen Photo Viewer

Presented when any photo thumbnail in the detail is tapped. Uses SwiftUI sheet with `.presentationDetents([.large])` and zero background (true full-screen).

```
PhotoFullScreenViewer(urls: note.photoUrls, initialIndex: tappedIndex)
```

Internal layout:
```
ZStack
├── Color.black.ignoresSafeArea()
├── TabView(selection: $currentIndex) {
│     ForEach(urls.indices) { i in
│         CachedAsyncImage(url: urls[i])
│             .resizable().scaledToFit()
│             .tag(i)
│             .pinchToZoom()   // apply .gesture(MagnificationGesture)
│     }
│   }
│   .tabViewStyle(.page(indexDisplayMode: .always))
├── // Top bar
│   HStack  padding 20
│   ├── Spacer()
│   └── Button(action: dismiss) {
│         Image(systemName: "xmark.circle.fill")
│         .font(.title2)
│         .foregroundStyle(.white.opacity(0.8))
│       }
└── // Bottom counter
    Text("\(currentIndex + 1) / \(urls.count)")
    .font(.caption)
    .foregroundStyle(.white.opacity(0.6))
    .padding(.bottom, 20)
```

Page dots from `tabViewStyle(.page)` serve as the primary navigation affordance.

---

## 5. Design Tokens

### Color

All colors must be declared in `Color+Theme.swift`. New tokens to add:

| Token | Hex | Semantic Use |
|-------|-----|--------------|
| `Color.journal` | `#8B5CF6` | Alias for `Color.budget` — violet. Used for reflection type accent, tag chips in journal context. Declare as `static let journal = Color.budget` to avoid duplication. |
| `Color.journalNote` | `#3B82F6` | Alias for `Color.accent` — blue. Used for note type accent. Declare as `static let journalNote = Color.accent`. |

Existing tokens used in Journal v2:

| Purpose | Token |
|---------|-------|
| Note type accent (left bar, icon) | `Color.accent` (#3B82F6) |
| Reflection type accent (left bar, icon, tag chips) | `Color.budget` (#8B5CF6) |
| Income-linked transaction badge | `Color.income` (#10B981) |
| Expense-linked transaction badge | `Color.expense` (#F43F5E) |
| Warning state | `Color.warning` (#F59E0B) |
| Card backgrounds | `Color.cardBackground` = `Color(.secondarySystemGroupedBackground)` |
| Form sheet background | `.regularMaterial` |
| Selected mood button fill | `Color.accent.opacity(0.15)` |
| Selected tag chip (filter bar) | `Color.budget.opacity(0.15)` |
| Suggestion chip (unselected) | `Color(.quaternarySystemFill)` |

### Typography

| Element | Modifier | Size | Notes |
|---------|----------|------|-------|
| Entry title (card, form) | `.subheadline.weight(.semibold)` | 15pt | |
| Entry title (detail) | `.title2.weight(.bold)` | 22pt | |
| Content excerpt (card) | `.caption` | 12pt | Max 2 lines |
| Body text (detail) | `.body` | 17pt | `.textSelection(.enabled)` |
| Tag chip text | `.caption.weight(.medium)` | 12pt | |
| Timestamp (card) | `.caption2` | 11pt | `.tertiary` — de-emphasised |
| Section header | `.footnote.weight(.semibold)` | 13pt | `.secondary` |
| Mood emoji | `.title3` | ~22pt | No text label in compact views |
| Amount badge | `.caption.weight(.semibold).monospacedDigit()` | 12pt | Always monospaced |
| Upload progress % | `.caption2.monospacedDigit()` | 11pt | `.tertiary` |

No `.caption2` for content or labels. Minimum 12pt (`.caption`) for any user-readable string.

### Spacing

Using the 4px grid:

| Use | Value | Grid unit |
|-----|-------|-----------|
| Card outer padding h | 16pt | 4× |
| Card inner padding h | 12pt | 3× |
| Card inner padding v | 12pt | 3× |
| Gap between cards | 6pt | 1.5× |
| Tag chip padding h | 8–10pt | 2–2.5× |
| Tag chip padding v | 4pt | 1× |
| Tag chip gap | 6pt | 1.5× |
| Section header top padding | 20pt | 5× |
| Section header bottom padding | 6pt | 1.5× |
| Form section padding h | 16pt | 4× |
| Photo thumbnail size | 80×80pt | 20× |
| Photo thumbnail gap | 8pt | 2× |
| Mood button size | 44×44pt | 11× (HIG minimum touch target) |

### Corner Radius

| Element | Radius | SwiftUI |
|---------|--------|---------|
| Card | 12pt | `RoundedRectangle(cornerRadius: 12, style: .continuous)` |
| Tag chip | fully rounded | `Capsule()` |
| Photo thumbnail (form) | 8pt | `RoundedRectangle(cornerRadius: 8, style: .continuous)` |
| Photo thumbnail (detail, small) | 8pt | same |
| Photo (detail, large) | 12pt | same as card |
| Transaction linker row (filled) | 10pt | `RoundedRectangle(cornerRadius: 10, style: .continuous)` |
| Linked transaction card (detail) | 12pt | same as card |
| Mood button | fully rounded | `Circle()` |

---

## 6. Accessibility

### VoiceOver Labels

| Element | `accessibilityLabel` | `accessibilityHint` |
|---------|---------------------|---------------------|
| MoodButton (unselected) | `mood.localizedName` | "Double tap to select" |
| MoodButton (selected) | `mood.localizedName + ", selected"` | "Double tap to deselect" |
| TagChip remove button | "Remove tag \(tag)" | — |
| SuggestionChip | "Add tag \(tag)" | — |
| AddPhotoButton | "Add photo" | "Up to \(remaining) more photos" |
| PhotoThumbnailCell delete | "Remove photo" | — |
| Transaction linker (empty) | "Link a transaction" | "Double tap to open transaction picker" |
| Transaction linker (filled) | "\(amount) from \(category), linked transaction" | "Double tap to change" |
| Left edge type bar (card) | "Note type: \(type.localizedName)" | — (decorative if type also shown as icon) |
| Photo count badge ("+N more") | "\(n) more photos" | — |

### Dynamic Type

All font references must use named styles (`.subheadline`, `.caption`, etc.) rather than fixed sizes. Exceptions permitted only for the mood emoji (`.title3` is acceptable) and the "BETA" badge (`.system(size: 10, weight: .bold)` — already existing, acceptable for a badge).

Photo thumbnail grid at `accessibilityLargeContentSize` (accessibility text size xL+): hide the photo grid in cards and replace with an `Image(systemName: "photo") + Text("\(count) photos")` row using `.caption`. The full grid remains in the detail view. Use `@Environment(\.dynamicTypeSize)` to detect xL+ sizes.

### Color Contrast

| Element | Foreground | Background | Estimated ratio | Requirement |
|---------|-----------|-----------|-----------------|-------------|
| Content text in card | `.primary` (label) | `.secondarySystemGroupedBackground` | ≥ 7:1 | Pass |
| Tag chip text (`Color.budget`) | #8B5CF6 | #8B5CF6 at 0.10 white bg | ≈ 4.6:1 | Pass (AA normal) |
| Amount badge text (income) | #10B981 | white | ≈ 3.5:1 | Pass (AA large, 12pt bold) |
| Amount badge text (expense) | #F43F5E | white | ≈ 4.1:1 | Pass (AA normal) |
| Section header (`.secondary`) | systemGray | white | ≈ 4.5:1 | Pass (AA) |
| Timestamp (`.tertiary`) | systemGray2 | white | ≈ 3.1:1 | Borderline — only used at caption2 size, ensure weight is `.regular` not `.ultraLight` |

The left edge type bar encodes type visually. It is supplemented by the type icon and `accessibilityLabel` on the card container — not relied upon as the sole indicator.

### Focus and Keyboard Navigation

- All interactive elements (MoodButton, TagChip remove, SuggestionChip, TransactionLinker row) must be reachable via `.focusable()` where SwiftUI does not apply it automatically (custom `Button` with `.plain` style).
- `TagPicker` AddTagField: `.onSubmit` commits the tag and returns focus to the field for rapid multi-tag entry without lifting hands from keyboard.
- `TransactionPickerSheet` `.searchable` field receives focus automatically on sheet appear via `.onAppear { focusSearch = true }` using `@FocusState`.

---

## 7. Motion & Micro-interactions

### Tag Addition

When a tag is committed (from AddTagField submit or SuggestionChip tap):
- New `TagChip` appears at the end of the FlowLayout with `.transition(.asymmetric(insertion: .scale(scale: 0.5, anchor: .leading).combined(with: .opacity), removal: .scale(scale: 0.5).combined(with: .opacity)))`.
- Animation: `.spring(response: 0.3, dampingFraction: 0.7)`.
- The `SuggestionChip` that was tapped disappears from the suggestions row with the same removal transition.
- The `AddTagField` clears and re-focuses.
- Wrap the `FlowLayout` in `withAnimation` at the call site.

### Tag Removal

Tapping the xmark on a `TagChip`: the chip scales down and fades out (`.scale(0.7).combined(with: .opacity)`, duration 0.15s, `.easeOut`). The FlowLayout re-flows the remaining chips smoothly via `withAnimation(.easeInOut(duration: 0.2))`.

### Mood Selection

Tapping a `MoodButton`:
- Selected button: scale from 1.0 → 1.15 → 1.08 (spring overshoot). Fill and stroke appear simultaneously.
- Previously selected button (if any): scale 1.08 → 1.0, fill/stroke fade out. Duration 0.15s, `.easeOut`.
- Use `.animation(.spring(response: 0.3, dampingFraction: 0.6), value: isSelected)` on the button's scale modifier.

### Card → Detail Transition

Use SwiftUI's default `NavigationLink` push transition (slide from right). Do not override with custom transitions — the native push animation is appropriate and expected by users.

On the card itself, apply `.buttonStyle(.plain)` with a custom press effect: `scaleEffect(isPressed ? 0.97 : 1.0, anchor: .center)` animated with `.easeInOut(duration: 0.12)`. Use `_onButtonGesture` or a custom `ButtonStyle` implementation.

### Entry Detail Appearance

When `JournalNoteDetailView` appears in the navigation stack, the photo grid enters with a staggered delay: each photo cell appears with `.transition(.opacity.combined(with: .move(edge: .bottom)))`, each delayed by `index * 0.05` seconds (max delay cap at 0.15s for the fourth+ item). Apply via `.task` / `onAppear` + `@State private var appeared = false`.

### Transaction Picker Sheet Presentation

The `TransactionPickerSheet` appears with `.sheet` and `.presentationDetents([.medium, .large])`. No custom entry animation needed — the system sheet spring is appropriate.

When a transaction is selected: the sheet dismisses, and the form's transaction linker row animates from the empty state to the filled state using `withAnimation(.easeInOut(duration: 0.25))`. The row background color fades in.

### Type Toggle (Note / Reflection)

When the user switches between Note and Reflection in the form:
- The TransactionLinker row slides out to the left and fades (`.transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))`).
- The PeriodPicker row slides in from the right.
- Duration: 0.2s `.easeInOut`. Wrap in `withAnimation(.easeInOut(duration: 0.2))`.

### Photo Thumbnail Addition

When a photo is selected from `PhotosPicker`:
- New thumbnail cell appears at the end of the scroll row with `.transition(.scale(scale: 0.7, anchor: .leading).combined(with: .opacity))`, spring animation.
- Scroll row automatically scrolls to reveal the new cell (use `ScrollViewReader` with `.scrollTo(item.id, anchor: .trailing)`).
- If upload starts immediately, the `UploadProgressRow` fades in below the thumbnail row.

### Empty State → First Entry

When the first note is saved and the list transitions from empty state to a populated state, use `withAnimation(.spring(response: 0.4, dampingFraction: 0.8))` on the condition that switches between `emptyState` and `notesList`. The first card slides in from the bottom.

---

## Reference Patterns

- **Daylio**: The inspiration for emoji-only mood circles with no text in the selection UI. Their mono-row of circles with selection feedback is the closest reference.
- **Apple Notes**: Title + body textarea without Form sections — the basis for the content area architecture in the form.
- **Linear app**: Tag suggestion chips appearing below an input field and dismissing after selection — the exact pattern for the tag picker.
- **iOS Photos app**: The full-screen viewer with paged `TabView` and pinch-to-zoom is the system reference for `PhotoFullScreenViewer`.
- **Apple HIG — Menus and Actions**: FAB with long-press for contextual actions is documented in HIG under "Pop-Up Buttons"; single-tap default + long-press alternative is the correct pattern.
