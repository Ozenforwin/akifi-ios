# Budget Module Redesign Specification
**Akifi iOS — SwiftUI / iOS 17+**
Version 1.0 | April 2026

---

## Table of Contents

1. Current State Analysis
2. Competitor Reference Patterns
3. BudgetCardView Redesign
4. BudgetFormView Redesign
5. BudgetsTabView Redesign
6. New Components
7. Accessibility Checklist (WCAG 2.1 AA)
8. SwiftUI Implementation Guide

---

## 1. Current State Analysis

### What Works Well

- **Rich metrics**: BudgetMath produces exactly the right signals (pace, safe-to-spend, forecast overrun, risk level). This is the strongest part of the module and should be fully surfaced in the UI rather than hidden.
- **Color semantics**: The green → amber → orange → red hex ramp in `progressColorHex` is correct and already maps to `Color+Theme`.
- **Status pill**: The capsule badge in BudgetCardView is legible and consistent with iOS patterns.
- **Category picker**: The collapsible grid in BudgetFormView is a good interaction; the chip size (80 pt adaptive) is acceptable.
- **Swipe actions**: Archive/edit on swipe is the correct iOS pattern.
- **Material backgrounds**: `.ultraThinMaterial` + `cornerRadius(16)` is consistent with SavingsGoalCardView.

### Problems to Fix

#### BudgetCardView
- **Information overload**: Five distinct rows of data (header, progress bar, spent/pace, safe-to-spend row, forecast row) create cognitive fatigue. The forecast row and safe-to-spend row are shown simultaneously with no visual hierarchy separating primary from secondary data.
- **Progress bar height (10 pt) is too thin** for the amount of semantic meaning it carries (threshold markers at 80% and 100%). Apple HIG recommends at least 8 pt for trackable progress; 12 pt would make the threshold markers readable and meet minimum touch guidance.
- **Icon cluster (`categoryIcons`) is emoji-only**: On small devices or when a budget has 3 categories the emoji string becomes illegible clutter. There is no fallback icon for the "all categories" state besides "📊".
- **Pace indicator label alone is ambiguous**: "+23%" with no axis label is unclear — 23% over budget or over expected pace? Label must be contextualised.
- **`budget.daysRemaining.\(metrics.remainingDays)`**: Pluralisation via string interpolation in key names is fragile; this is a localisation risk.
- **Risk border is a subtle 1.5 pt stroke** that will fail WCAG 3:1 non-text contrast requirement at `.opacity(0.3)` and `.opacity(0.4)`. Risk must be communicated through an additional visual channel.
- **No empty-progress state**: When `utilization == 0` the bar is invisible — just the grey track. New users need a starting-point affordance.
- **No edit affordance on the card itself**: Users must discover swipe-to-edit; there is no visual hint.

#### BudgetFormView
- **Single long form**: All 7 sections are presented as a continuous scroll. On iPhone SE this requires scrolling past the fold to reach the most decision-critical field (amount), which appears third. Amount should be step one.
- **Budget Type selector uses full-height rows** without a visual "selected" background, relying solely on the checkmark. The distinction between Hard and Soft is conceptually important (strict limit vs. tracking) and needs stronger visual treatment.
- **CalculatorKeyboardView in a Form Section** creates a jarring modal-within-form feel. The calculator should be the opening screen, not buried in a section.
- **Alert threshold sliders** are an advanced feature presented inline. They add length without helping most users. Move to an expandable "Advanced" section collapsed by default.
- **Category picker font size 9 pt** (`font(.system(size: 9))`) is below the HIG minimum of 11 pt for readable text and will fail WCAG 1.4.4 (resize text).

#### BudgetsTabView
- **No summary header**: Users see a list of individual budgets with no aggregate health signal. A user with 5 budgets has no quick answer to "how am I doing overall this month?"
- **Budgets and Subscriptions mixed in one List** with only a section header — two conceptually different things competing for the same visual space. Subscriptions belong in their own tab or a clearly separated card-style section with a visual divider.
- **No sort/filter control**: As budgets grow (> 3) there is no way to surface the most critical ones first.
- **Empty state icon `wallet.bifold.fill`** (SF Symbols) is appropriate but the description text lacks a concrete value proposition hint.

---

## 2. Competitor Reference Patterns

### YNAB (You Need A Budget)
- **Key pattern**: The "Available" number is the single primary data point — green when positive, red when negative. Everything else is secondary. Lesson: make the "remaining" amount the hero number, not the utilization percentage.
- **Borrow**: Category-level colour strips on the left edge of each row to encode status at a glance without reading text.
- **Borrow**: "Overspent" rolls up to a summary banner above the list.

### Monzo
- **Key pattern**: Animated circular arc progress per budget category. The arc fills left-to-right; at 100% it turns red and pulses once. Lesson: motion communicates urgency without a banner.
- **Borrow**: "You've spent X, you have Y left" sentence format at the bottom of the card — natural language beats percentages for non-finance users.
- **Borrow**: A horizontal "spending over time" bar chart per period (sparkline style) showing daily burn — immediately shows whether spending is front-loaded.

### Revolut
- **Key pattern**: Summary donut at the top of the budget list shows total spent vs total budgeted for all budgets combined. Lesson: aggregate view before detail.
- **Borrow**: Segmented control (All / At Risk / Over) as a filter above the card list.
- **Borrow**: "Safe to spend today" is the primary call-to-action number, shown in a coloured pill on the card face.

### Тинькофф / T-Bank
- **Key pattern**: Budget cards use a full-width colour fill at low opacity as the card background, directly tied to status colour. At-risk budgets have a warm tint, healthy ones are neutral. No border is needed — the fill conveys state.
- **Borrow**: Compact 2-line card format with the progress bar as the most prominent visual element.
- **Borrow**: "Will run out on [date]" forecast in natural language, not a chart.

### Mint (archived, reference only)
- **Anti-pattern**: Showing 12+ categories per scroll makes the list unusable. Enforce a visual limit (max 6 budgets on screen; collapse rest under "Show more").
- **Anti-pattern**: Colour-only status encoding with no text fallback. Always pair colour with an icon or text label.

---

## 3. BudgetCardView Redesign

### Design Principles for the Card

1. One primary number per card: the **remaining** amount (or overrun amount if exceeded).
2. One primary visual: the **progress bar**, taller and more expressive.
3. Secondary data lives in a collapsed "details" row, visible on tap or always visible for at-risk budgets.
4. Status is communicated via three independent channels: colour, icon, and text (accessibility).

### New Card Layout (ASCII)

```
┌──────────────────────────────────────────────┐
│  [Icon]  Budget Name           [Status Pill] │  ← 44pt row
│          📁 Categories · Period               │  ← caption
├──────────────────────────────────────────────┤
│  ████████████████░░░░░░  [80%|]       72%   │  ← 12pt bar
├──────────────────────────────────────────────┤
│  Spent: 14 500 ₽        Remaining: 5 500 ₽  │  ← subheadline
│  ──────────────────────────────────────────  │
│  🛡 Safe/day: 1 833 ₽    📅 3 days left     │  ← caption row
│  [Only shown when at risk:]                  │
│  ⚠ At current pace, budget ends Apr 18      │  ← orange caption
└──────────────────────────────────────────────┘
```

### Colour System for Progress

| Utilization | Hex | Semantic name | Background tint |
|------------|-----|--------------|-----------------|
| 0–74% | `#22C55E` | `Color.income` | none (neutral card) |
| 75–89% | `#F59E0B` | `Color.warning` | amber at 4% opacity |
| 90–99% | `#F97316` | orange | orange at 6% opacity |
| 100%+ | `#EF4444` | `Color.expense` | red at 8% opacity |

The background tint replaces the risk border stroke, which failed contrast requirements. The tint is applied to the entire card material, not just the border.

### Typography Hierarchy

| Element | SwiftUI modifier | Size | Weight |
|---------|-----------------|------|--------|
| Budget name | `.subheadline.weight(.semibold)` | 15 pt | Semibold |
| Status pill text | `.system(size: 11, weight: .semibold)` | 11 pt | Semibold |
| Category + period subtitle | `.caption` (not `.caption2`) | 12 pt | Regular |
| Progress % label | `.caption.weight(.bold).monospacedDigit()` | 12 pt | Bold |
| Spent amount | `.subheadline.weight(.semibold)` | 15 pt | Semibold |
| Remaining amount | `.subheadline.weight(.semibold)` | 15 pt | Semibold |
| Safe/day label | `.caption` | 12 pt | Regular |
| Forecast warning | `.caption.weight(.medium)` | 12 pt | Medium |

Note: remove all `.caption2` (11 pt) usage. Minimum body text size in HIG for legibility is 11 pt; for data labels pair it with `.monospacedDigit()` to prevent layout jumps.

### Progress Bar Redesign

```swift
// Target height: 12 pt (up from 10 pt)
// Threshold marker at 80%: 2 pt wide, full bar height, systemGray3
// Threshold text "80%" as tiny label above the marker, only when utilization < 80
// Animated fill with .animation(.spring(response: 0.5), value: metrics.utilization)

ZStack(alignment: .leading) {
    Capsule()
        .fill(Color(.systemGray5))
        .frame(height: 12)

    Capsule()
        .fill(progressGradient)     // two-stop gradient: lighter at left, solid at right
        .frame(width: barWidth, height: 12)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: metrics.utilization)

    // 80% threshold tick
    Rectangle()
        .fill(Color(.systemGray3))
        .frame(width: 2, height: 16)   // slightly taller than bar to bleed above/below
        .offset(x: geo.size.width * 0.8 - 1)
}
// Do NOT show a separate 100% tick — the end of the bar is the natural boundary.
```

### Card States

**Healthy (0–74%)**: Neutral `.ultraThinMaterial` background. No tint. Green progress bar.

**Warning (75–89%)**: `Color.warning.opacity(0.05)` overlay on the material. Amber bar. Status pill is amber. Safe-to-spend row is always visible.

**Near Limit (90–99%)**: `Color.orange.opacity(0.07)` overlay. Orange bar. Forecast row appears automatically if overrun date exists.

**Over Limit (100%+)**: `Color.expense.opacity(0.08)` overlay. Red bar fills past 100% and shows a small overflow indicator (a red dot or exclamation mark at the right edge). The "remaining" amount slot shows "Over by X" in red `.subheadline.weight(.semibold)`.

### Pace Indicator — Revised Label

Replace the opaque "+23%" with a contextual label:

```swift
// paceText rewrite:
var paceDescription: String {
    switch metrics.paceRatio {
    case ..<0.9:  return String(localized: "budget.pace.underPace")   // "Under pace"
    case 0.9..<1.1: return String(localized: "budget.pace.onTrack")  // "On track"
    case 1.1..<1.3: return String(localized: "budget.pace.slightlyOver") // "Slightly over pace"
    default:      return String(localized: "budget.pace.overPace")    // "Over pace"
    }
}
```

Show the percentage only as a `.caption2` secondary label below the description string, not as the primary label.

### Category Icon Area — Revised

Replace the raw emoji cluster with a structured icon:

```swift
// Fallback: single SF Symbol in a coloured circle
// If 1 category selected: show category icon in accent-coloured circle
// If 2-3 categories: show first icon + count badge "+2"
// If all categories: show "grid.2x2.fill" SF Symbol in violet (Color.budget)

ZStack {
    Circle()
        .fill(iconBackground)
        .frame(width: 36, height: 36)
    if let singleIcon = singleCategoryIcon {
        Text(singleIcon).font(.body)
    } else {
        Image(systemName: allCategories ? "grid.2x2.fill" : "square.grid.2x2.fill")
            .font(.body)
            .foregroundStyle(.white)
    }
}
```

### Edit Hint

Add a subtle `.contextMenu` on the card that provides Edit and Archive actions, in addition to the swipe actions. This discoverability hint satisfies HIG section on "context menus as secondary actions."

### VoiceOver Labels

```swift
.accessibilityElement(children: .combine)
.accessibilityLabel(accessibilityDescription)
.accessibilityHint(String(localized: "budget.accessibility.swipeToEdit"))

private var accessibilityDescription: String {
    let status = statusLabel.text
    let spent = fmt.formatAmount(metrics.spent.displayAmount)
    let limit = fmt.formatAmount(metrics.effectiveLimit.displayAmount)
    let remaining = fmt.formatAmount(max(0, metrics.remaining).displayAmount)
    let pct = metrics.utilization
    return "\(budget.name). \(status). Spent \(spent) of \(limit), \(pct) percent. \(remaining) remaining."
}
```

### Light / Dark Mode

- Use `.ultraThinMaterial` — it adapts automatically.
- Status tint overlays use `.opacity(0.05–0.08)` which remains visible in both modes.
- Progress bar track: `Color(.systemGray5)` adapts correctly.
- Threshold marker: `Color(.systemGray3)` — verify contrast in dark mode; may need `Color(.systemGray2)` in dark.
- Never hard-code white or black for text over the card body.

### Spacing Spec

```
Card padding:          16 pt (all sides)  → .padding(16)
Section spacing:       12 pt              → VStack spacing: 12
Header row spacing:    8 pt               → HStack spacing: 8
Icon to name gap:      10 pt
Progress bar height:   12 pt
Stats row top margin:  4 pt
Safe/day row top margin: 8 pt
Forecast row top margin: 4 pt
Corner radius:         16 pt              → existing, keep
```

---

## 4. BudgetFormView Redesign

### Problem: Single Flat Form

The current form is a 7-section scrolling list. Research (Typeform, conversational UX) shows that completion rate improves when complex forms are split into steps with one decision per screen. For a budget creation flow with 5–7 distinct inputs, a step-by-step sheet is recommended.

### Proposed Step Flow

```
Step 1: AMOUNT
  ← Full-screen CalculatorView (existing component)
  Header: "How much is this budget?"
  Subtext: period selector as segmented control below the amount display
  CTA: "Next"

Step 2: CATEGORIES (optional)
  Header: "What does this budget cover?"
  Category grid — full width chips, 56 pt touch target height
  "All spending" toggle at the top (shortcuts the grid)
  CTA: "Next" / "Skip"

Step 3: NAME & TYPE (optional)
  Header: "Give it a name"
  TextField for name (pre-filled with period + primary category, e.g. "Monthly · Food")
  Budget type selector: two large radio-card options side by side
  CTA: "Create" (or "Save" when editing)

Settings (Advanced — collapsed): rollover, alert thresholds, account filter, custom dates
```

For the **editing** flow, all steps are shown as a single expanded form (the user already knows the context) — this matches HIG's guidance that edit flows can show all fields at once.

### Step Indicator

```swift
// At the top of the sheet during creation:
HStack(spacing: 4) {
    ForEach(0..<3) { step in
        Capsule()
            .fill(step <= currentStep ? Color.accent : Color(.systemGray4))
            .frame(width: step == currentStep ? 20 : 8, height: 4)
            .animation(.spring(response: 0.3), value: currentStep)
    }
}
.padding(.top, 12)
```

### Budget Type Selector — Redesign

Replace the list rows with two card-style options in an HStack:

```
┌─────────────────┐  ┌─────────────────┐
│  🔒             │  │  💬             │
│  Hard           │  │  Flexible       │
│  Strict limit.  │  │  Track spending │
│  Alerts + block │  │  Alerts only    │
│  ✓ selected     │  │                 │
└─────────────────┘  └─────────────────┘
```

Each card: `minHeight: 100`, `cornerRadius: 12`, selected state uses `Color.accent.opacity(0.10)` fill + `Color.accent` stroke `lineWidth: 2`.

### Category Chip — Fix

Increase minimum tap target and font size:

```swift
// Before: font(.system(size: 9)), .padding(.vertical, 8)
// After:
VStack(spacing: 6) {
    Text(category.icon).font(.title3)           // 20 pt emoji
    Text(category.name)
        .font(.system(size: 11, weight: .medium))  // minimum 11 pt
        .lineLimit(2)
        .multilineTextAlignment(.center)
}
.frame(maxWidth: .infinity, minHeight: 56)       // 56 pt touch target
.padding(.vertical, 10)
```

### Amount Entry — Visual Feedback

When the user types an amount, show a real-time "safe to spend per day" preview below the number pad:

```swift
// Below CalculatorKeyboardView, update as amount changes:
if let amount = calculatorState.getResult(), amount > 0 {
    let dailyAmount = amount / Decimal(period.estimatedDays)
    Text("≈ \(fmt.formatAmount(dailyAmount)) per day")
        .font(.caption)
        .foregroundStyle(.secondary)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
}
```

This gives the user an immediate gut-check on whether the budget is realistic.

### Period Selector in the Form

The current `Picker` inside a Form Section is correct for the editing context. In the new step-based creation flow, move it to Step 1 as a segmented-style row of chips below the amount display:

```swift
// Period chips (not a Picker — no disclosure chevron needed here)
ScrollView(.horizontal, showsIndicators: false) {
    HStack(spacing: 8) {
        ForEach(BillingPeriod.allCases, id: \.self) { p in
            Text(p.shortLabel)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(period == p ? Color.accent : Color(.systemGray5))
                .foregroundStyle(period == p ? .white : .primary)
                .clipShape(Capsule())
                .onTapGesture { period = p }
        }
    }
    .padding(.horizontal, 16)
}
```

### Alert Thresholds — Advanced Collapse

```swift
DisclosureGroup(String(localized: "budget.advanced")) {
    // Rollover toggle
    // Alert threshold sliders
    // Account picker
}
// Default: isExpanded = false
// On edit: isExpanded = true if non-default values exist
```

---

## 5. BudgetsTabView Redesign

### Tab Structure — Separate Subscriptions

The most impactful structural change: move subscriptions to a dedicated section that is visually separated from budgets. Options:

**Option A (Recommended)**: Keep both in the Budgets tab but use a `ScrollView + LazyVStack` instead of `List`. Budgets section and Subscriptions section are separated by a full-width section header with a distinct background (`Color(.systemGroupedBackground)`), mimicking a UITableView grouped style with custom control.

**Option B**: Give Subscriptions its own tab. This requires a tab bar change — out of scope for this spec. Flag for product discussion.

This spec recommends Option A.

### Overall Summary Header

Insert a `BudgetHealthSummaryView` at the top of the scroll view, above the budget list. See Section 6 for full spec.

### Revised Layout

```
NavigationStack
  ScrollView
    ├── BudgetHealthSummaryView        ← new component
    ├── Section header: "Budgets" + sort/filter control
    ├── BudgetCardView × N
    ├── Section divider (full-width, 8pt spacing)
    ├── Section header: "Subscriptions" + add button
    └── SubscriptionRowView × N
  FAB-style + button (keep existing toolbar)
```

### Sort and Filter Control

```swift
// Inline, below section header, above first card
HStack(spacing: 8) {
    Menu {
        Button("By status") { sortOrder = .status }
        Button("By utilization") { sortOrder = .utilization }
        Button("By remaining") { sortOrder = .remaining }
        Button("By name") { sortOrder = .name }
    } label: {
        Label(currentSortLabel, systemImage: "arrow.up.arrow.down")
            .font(.caption.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(.systemGray6))
            .clipShape(Capsule())
    }

    // Quick filter: "At Risk" shows only warning/nearLimit/overLimit
    Toggle(isOn: $showAtRiskOnly) {
        Text("At Risk")
            .font(.caption.weight(.medium))
    }
    .toggleStyle(.button)
    .tint(.orange)
}
.padding(.horizontal, 16)
```

### Default Sort Order

Sort budgets by: overLimit first, then nearLimit, then warning, then onTrack. Within each group, sort by utilization descending. This ensures the most critical budget is always at the top without user action.

### Empty State — Improved

```swift
EmptyStateView(
    title: String(localized: "budget.noBudgets"),
    systemImage: "chart.bar.doc.horizontal",   // more relevant than wallet
    description: String(localized: "budget.noBudgets.description"),
    actionTitle: String(localized: "common.create")
)
// description should read: "Set spending limits by category. We'll track your progress automatically."
```

### Navigation Title

Change from `"budget.title"` to a contextual title showing current period:

```swift
// "Budgets · April" or "Budgets · This Week"
var navigationSubtitle: String {
    let df = DateFormatter()
    df.dateFormat = "LLLL"
    return df.string(from: Date()).capitalized
}
// Use .navigationTitle with a VStack of title + subtitle, or inline subtitle
```

---

## 6. New Components

### 6.1 BudgetHealthSummaryView

A horizontal summary bar at the top of the tab showing aggregate health across all active budgets.

**Layout:**

```
┌────────────────────────────────────────────────┐
│  Total Budgets          Overall Health          │
│  ₽ 45 000 / ₽ 80 000        56% used           │
│                                                 │
│  ████████████████████░░░░░░░░░░░░░░░░          │
│                                                 │
│  ✅ 3 on track   ⚠ 1 warning   🔴 1 over      │
└────────────────────────────────────────────────┘
```

**Implementation notes:**
- Aggregate `spent` and `effectiveLimit` by summing across all BudgetMetrics.
- Use a segmented progress bar — each budget's contribution rendered as its own segment in the appropriate status colour, proportional to its limit relative to total limit.
- The three status counters below use SF Symbol icons with colour: `checkmark.circle.fill` (green), `exclamationmark.triangle.fill` (amber), `xmark.octagon.fill` (red).
- Height: approximately 100 pt total including padding.
- Touch the summary bar → scrolls to the first at-risk card (`.scrollTo` via ScrollViewProxy).

```swift
struct BudgetHealthSummaryView: View {
    let budgets: [Budget]
    let allMetrics: [BudgetMetrics]

    private var totalLimit: Int64 { allMetrics.reduce(0) { $0 + $1.effectiveLimit } }
    private var totalSpent: Int64 { allMetrics.reduce(0) { $0 + $1.spent } }
    private var overallUtilization: Int {
        guard totalLimit > 0 else { return 0 }
        return Int(Double(totalSpent) / Double(totalLimit) * 100)
    }
    private var onTrackCount: Int { allMetrics.filter { $0.status == .onTrack }.count }
    private var warningCount: Int { allMetrics.filter { $0.status == .warning || $0.status == .nearLimit }.count }
    private var overCount: Int { allMetrics.filter { $0.status == .overLimit }.count }
    // ... view body
}
```

### 6.2 BudgetSparklineView

A compact 7-day daily spending bar chart rendered using Swift Charts. Shows actual daily spend vs expected daily spend (limit / totalDays) for the current period.

**Spec:**
- Width: fill card width. Height: 40 pt.
- Bars: daily actual spend in `progressColor` (status-derived).
- Baseline: a dashed horizontal line at `budget.amount / totalDays` (the "ideal" daily rate).
- Show only when `metrics.elapsedDays >= 3` (not enough data otherwise).
- No axis labels, no grid lines — sparkline style only.
- Accessibility: `.accessibilityHidden(true)` with a separate `.accessibilityLabel` on the container describing the trend in text ("Spending trending above daily target").

```swift
import Charts

struct BudgetSparklineView: View {
    let dailyAmounts: [(date: Date, amount: Decimal)]  // last 7 days
    let dailyTarget: Decimal
    let color: Color

    var body: some View {
        Chart {
            ForEach(dailyAmounts, id: \.date) { point in
                BarMark(
                    x: .value("Day", point.date, unit: .day),
                    y: .value("Amount", point.amount)
                )
                .foregroundStyle(color.gradient)
                .cornerRadius(3)
            }
            RuleMark(y: .value("Target", dailyTarget))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(Color(.systemGray3))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 40)
        .accessibilityHidden(true)
    }
}
```

**Data prep**: compute daily aggregates from `BudgetMath.spentAmount` filtered per day. This requires a new helper in `BudgetMath`:

```swift
static func dailyAmounts(
    budget: Budget,
    transactions: [Transaction],
    days: Int = 7
) -> [(date: Date, amount: Decimal)] {
    // Returns array of (date, amount) for last `days` calendar days within period
}
```

### 6.3 PeriodComparisonBadge

A small inline badge below the spent/remaining row showing the delta vs the previous period:

```
▲ 12% vs last month
```

- Green downward arrow for decreased spending, red upward for increased.
- Only show when previous period data is available (requires storing previous-period spent — see model note below).
- Font: `.caption2.monospacedDigit()`. Keep width narrow; use `HStack(spacing: 4)`.
- Positioned between the progress bar and the stats row — visible but not primary.

**Model note**: The current `Budget` model does not store historical period data. To implement this component, `BudgetMath` needs a new function:

```swift
static func previousPeriodSpent(
    budget: Budget,
    transactions: [Transaction]
) -> Int64 {
    let (currentStart, _) = currentPeriod(for: budget)
    let previousEnd = Calendar.current.date(byAdding: .day, value: -1, to: currentStart)!
    // Compute the previous period's start by shifting back by one period interval
    // Then call spentAmount with the previous period dates
}
```

---

## 7. Accessibility Checklist (WCAG 2.1 AA)

### Colour Contrast

| Element | Foreground | Background | Required Ratio | Notes |
|---------|-----------|-----------|----------------|-------|
| Budget name (semibold, 15pt) | `.primary` | `.ultraThinMaterial` | 4.5:1 | Pass — system colors handled by OS |
| Status pill text (11pt, bold) | Status colour | Status colour at 0.12 opacity | 4.5:1 | Verify each: `#22C55E` on white bg at 12% = ~1.2:1 FAIL. Use darker text on light bg: set foreground to a 60%-darkened version of the status colour, not the full-saturation colour. |
| Progress bar fill | N/A (non-text) | Grey track | 3:1 | Verify `#F59E0B` on `systemGray5`: ratio ≈ 2.8:1 on light. Increase track to `systemGray4` for warning/orange states. |
| Forecast warning text (12pt) | `#F97316` | card background | 4.5:1 | On white: ratio ≈ 2.9:1 FAIL. Use `.primary` coloured text with an orange icon instead. |
| Safe/day label (12pt) | `.secondary` | card background | 4.5:1 | System secondary on white = ~3.5:1 borderline. Use `.primary` for the amount value itself. |

**Action**: Audit all status-coloured text labels. Never use a status colour (green, amber, orange, red) as the foreground text colour on a light/translucent background without sufficient contrast. Use the colour for icons and decorative elements only; pair with `.primary` or a verified-contrast text colour.

### Touch Targets

| Component | Current size | Required | Fix |
|-----------|------------|----------|-----|
| Category chips in form | ~56pt adaptive | 44pt iOS min | Already correct if `minHeight: 56` is applied per Section 4 |
| Alert threshold add button (`plus.circle.fill`) | Icon only, ~20pt | 44pt | Wrap in `.frame(width: 44, height: 44)` |
| Alert threshold remove button (`minus.circle`) | Icon only, ~16pt | 44pt | Same fix |
| Sort/filter menu | Capsule pill | 44pt | Ensure `.frame(minHeight: 44)` |
| Subscription row | 12pt padding each side | 44pt row height | Current layout is ~64pt, OK |
| Budget card swipe actions | System swipe | 44pt system default | Pass |

All interactive elements must meet the 44×44 pt minimum. The threshold slider controls are system `Slider` components — they meet HIG by default.

### Screen Reader (VoiceOver)

- Each `BudgetCardView` must be a single accessibility element: `.accessibilityElement(children: .combine)`. The combined label should read the budget in a single sentence (see Section 3, VoiceOver Labels).
- The progress bar's visual representation is decorative — suppress it: `.accessibilityHidden(true)` on the `GeometryReader` bar, and provide the percentage in the card's combined label.
- The `BudgetSparklineView` is always `.accessibilityHidden(true)` with the trend described in the card's combined label.
- The status pill is `.accessibilityHidden(true)` — its content is included in the combined card label.
- The `BudgetHealthSummaryView` needs its own `.accessibilityLabel`: e.g. "Budget overview: 3 budgets on track, 1 warning, 1 over limit. Overall 56% spent."
- Form step indicators (dots) are `.accessibilityLabel("Step \(currentStep + 1) of 3")`.
- Category chips in form: `.accessibilityLabel(category.name)` + `.accessibilityAddTraits(isSelected ? .isSelected : [])`.

### Dynamic Type

- All font modifiers must use system-relative styles (`.subheadline`, `.caption`, `.body`, etc.) or `scaledFont`. Avoid `font(.system(size: N))` except for icons.
- The one exception: the status pill at `.system(size: 11, weight: .semibold)` — replace with `.caption.weight(.semibold)` which scales with Dynamic Type.
- Card layout must reflow gracefully at xxxLarge accessibility text size. Use `@ScaledMetric` for icon circle sizes:

```swift
@ScaledMetric private var iconSize: CGFloat = 36
@ScaledMetric private var cardPadding: CGFloat = 16
```

- Test layouts at "Accessibility Large" (AX3 size) in Simulator.

### Reduce Motion

Respect `.isReduceMotionEnabled`:

```swift
@Environment(\.accessibilityReduceMotion) var reduceMotion

// Progress bar animation:
.animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.8), value: metrics.utilization)
```

### Focus Management (iOS 17 `.focusSection`)

When the `BudgetFormView` sheet is presented, set initial focus on the amount input (Step 1 calculator). Use `.focused($focusField, equals: .amount)`.

---

## 8. SwiftUI Implementation Guide

### File Organisation

```
Views/Budgets/
  BudgetsTabView.swift          — existing, restructure
  BudgetCardView.swift          — existing, full redesign
  BudgetFormView.swift          — existing, add step flow for create
  BudgetHealthSummaryView.swift — new
  BudgetSparklineView.swift     — new
  PeriodComparisonBadge.swift   — new
  BudgetSortFilterBar.swift     — new
```

### Swift Charts — Required Import

```swift
import Charts
// Requires iOS 16+. Project targets iOS 17+, so no availability guard needed.
```

### Gradient Definition

Replace the direct `.gradient` convenience (which uses the colour's own tonal gradient) with an explicit two-stop gradient for the progress bar:

```swift
private var progressGradient: LinearGradient {
    LinearGradient(
        colors: [progressColor.opacity(0.7), progressColor],
        startPoint: .leading,
        endPoint: .trailing
    )
}
```

This produces a left-fade that gives the bar visual depth without using `.gradient` (which can look too light on amber/green at low fill percentages).

### Segmented Progress Bar for Summary View

```swift
// BudgetHealthSummaryView — segmented bar
GeometryReader { geo in
    HStack(spacing: 2) {
        ForEach(Array(zip(budgets, allMetrics)), id: \.0.id) { budget, metrics in
            let proportion = totalLimit > 0
                ? CGFloat(metrics.effectiveLimit) / CGFloat(totalLimit)
                : 1.0 / CGFloat(allMetrics.count)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(hex: metrics.progressColor))
                .frame(width: (geo.size.width - CGFloat(allMetrics.count - 1) * 2) * proportion)
        }
    }
}
.frame(height: 8)
.clipShape(Capsule())
```

### BudgetFormView — Step State Machine

```swift
enum BudgetCreationStep: Int, CaseIterable {
    case amount = 0
    case categories = 1
    case nameAndType = 2
}

@State private var creationStep: BudgetCreationStep = .amount

// Navigation buttons:
Button("Next") {
    withAnimation(.easeInOut(duration: 0.25)) {
        creationStep = BudgetCreationStep(rawValue: creationStep.rawValue + 1) ?? .nameAndType
    }
}
```

Use `.transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))` for step transitions.

### Sorting BudgetCards

Add a computed property to `BudgetsTabView`:

```swift
private var sortedBudgets: [Budget] {
    let metricsMap = Dictionary(
        uniqueKeysWithValues: dataStore.budgets.map {
            ($0.id, BudgetMath.compute(budget: $0, transactions: dataStore.transactions))
        }
    )
    return dataStore.budgets.sorted { a, b in
        let ma = metricsMap[a.id]!
        let mb = metricsMap[b.id]!
        let priority: (BudgetStatus) -> Int = {
            switch $0 {
            case .overLimit: return 0
            case .nearLimit: return 1
            case .warning:   return 2
            case .onTrack:   return 3
            }
        }
        let pa = priority(ma.status)
        let pb = priority(mb.status)
        if pa != pb { return pa < pb }
        return ma.utilization > mb.utilization
    }
}
```

### `.refreshable` Placement

The existing `.refreshable` is on `List`. After migrating to `ScrollView + LazyVStack`, move it:

```swift
ScrollView {
    LazyVStack(spacing: 12) { ... }
}
.refreshable { await dataStore.loadAll() }
```

### Sheet Presentation Height

For `BudgetFormView` during creation (step flow), use a taller detent to accommodate the calculator:

```swift
.sheet(isPresented: $viewModel.showForm) {
    BudgetFormView(...)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.ultraThinMaterial)
}
```

For editing (single form), allow `.medium` and `.large`:

```swift
.presentationDetents([.medium, .large])
```

### Key `@Observable` Note

`BudgetsViewModel` uses `@State private var viewModel = BudgetsViewModel()`. Ensure `BudgetsViewModel` is annotated `@Observable` (iOS 17 macro, not `ObservableObject`). The new `BudgetSortOrder` enum and `showAtRiskOnly: Bool` filter state should live in this ViewModel, not in the View itself.

---

## Implementation Priority Order

1. **High priority — immediate user value**
   - Increase progress bar height to 12 pt
   - Fix `.caption2` → `.caption` font sizes throughout the card
   - Fix status pill text contrast (replace status colour foreground with semantic `.primary`)
   - Apply default sort by status criticality in BudgetsTabView
   - Add `.accessibilityElement(children: .combine)` with proper label to BudgetCardView

2. **Medium priority — structural improvements**
   - Add `BudgetHealthSummaryView` to the top of the tab
   - Migrate BudgetFormView to step-based creation flow
   - Redesign budget type selector to card-based layout
   - Increase category chip touch targets and font sizes
   - Add `.contextMenu` to BudgetCardView

3. **Lower priority — enrichment features**
   - `BudgetSparklineView` with Swift Charts (requires `dailyAmounts` helper in BudgetMath)
   - `PeriodComparisonBadge` (requires previous-period data — model change)
   - Sort/filter control bar
   - Segmented progress bar in summary view
   - Step transition animations

---

*Spec authored by @designer | April 2026*
