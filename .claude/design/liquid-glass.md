# Akifi 1.6 — Liquid Glass design rules

Source of truth for the 1.6.0 redesign. Every screen follows this file; if a
case is not covered, follow Apple's Human Interface Guidelines (iOS 26,
"Adopting Liquid Glass") and add the decision here.

Deployment target stays **iOS 18.0**. Liquid Glass exists only on **iOS 26+**,
so every glass-only API sits behind `if #available(iOS 26.0, *)` with a
classic system fallback (materials / bordered styles). Prefer the shared
helpers in `AkifiIOS/DesignSystem/Glass.swift` over sprinkling availability
checks in screens.

## 1. Principles (HIG)

1. **Two layers.** Liquid Glass is the *navigation and controls* layer that
   floats above content: tab bar, navigation/tool bars, floating buttons,
   menus, sheets, popovers, segmented controls. **Content is not glass**:
   lists, cards, charts, rows stay on standard system backgrounds.
   Never put glass on glass (no glass card inside a glass sheet).
2. **Let the system do it.** Standard `TabView`, `NavigationStack`,
   `.toolbar`, `.sheet`, `Menu`, `Picker`, `.searchable` adopt Liquid Glass
   automatically when built with the iOS 26 SDK. Remove anything that fights
   it: custom bar backgrounds, `UINavigationBarAppearance` overrides,
   `.toolbarBackground(...)`, `.presentationBackground(...)`, opaque custom tab
   bars, hand-made blur/shadow chrome.
3. **Content first.** Content scrolls *under* the glass bars (no opaque
   spacers, no fake headers). Use `.scrollEdgeEffectStyle(.soft, for: .top)`
   only where legibility needs it.
4. **Clarity over decoration.** Fewer gradients, shadows and borders. One
   accent colour. Colour carries meaning (income/expense/warning), not
   decoration.
5. **Accessibility.** Dynamic Type everywhere (text styles, not fixed point
   sizes), 44×44 pt hit targets, VoiceOver labels on icon-only buttons,
   respect Reduce Transparency / Increase Contrast / Reduce Motion (system
   glass already does; custom effects must too).

## 2. API cheat-sheet (iOS 26)

| Need | API |
|---|---|
| Glass on a custom control | `.glassEffect(.regular, in: .capsule)` · shapes: `.circle`, `.capsule`, `.rect(cornerRadius:)` |
| Tinted / tappable glass | `.glassEffect(.regular.tint(.accent).interactive(), in: .circle)` |
| Several glass elements that blend/morph | `GlassEffectContainer(spacing: 16) { … }` + `.glassEffectID(id, in: ns)` |
| Glass buttons | `.buttonStyle(.glass)` (secondary) · `.buttonStyle(.glassProminent)` (primary) |
| Tab bar minimises on scroll | `.tabBarMinimizeBehavior(.onScrollDown)` on `TabView` |
| Separate trailing tab (like Search) | `Tab(value:role: .search) { … } label: { … }` |
| Toolbar grouping | `ToolbarSpacer(.fixed)` / `ToolbarSpacer(.flexible)` between items |
| Item without shared glass capsule | `.sharedBackgroundVisibility(.hidden)` on `ToolbarItem` |
| Search in bottom toolbar | `.searchable(...)` (+ `.searchToolbarBehavior(.minimize)`) |
| Edge fade under bars | `.scrollEdgeEffectStyle(.soft, for: .top)` |
| Shapes concentric with the container | `ConcentricRectangle()` / `.containerShape(...)` |

Fallback mapping (iOS 18–25), provided by `Glass.swift`:
- `.glassEffect` → `.background(.regularMaterial, in: shape)`
- `.glassProminent` → `.borderedProminent`, `.glass` → `.bordered`
- `GlassEffectContainer` → plain `HStack/VStack`

## 3. Components

### Tab bar (decided with Vladimir)
- System `TabView` with the `Tab` API: **Главная · Операции · Аналитика ·
  Бюджеты**; **Ассистент** is a separate trailing round glass button via
  `Tab(value: .assistant, role: .search)` with `sparkles`.
- `.tabBarMinimizeBehavior(.onScrollDown)` on iOS 26.
- No custom tab bar, no centre bump button, no gradients in the bar.
- Tab icons: SF Symbols, outline in the label (`house`, `arrow.left.arrow.right`,
  `chart.bar`, `wallet.bifold`); the system fills the selected one.

### Add button («+»)
- One floating round glass button above the tab bar, trailing side
  (`.glassEffect(.regular.tint(.accent).interactive(), in: .circle)`, white
  `plus` symbol, 56 pt), opening the existing quick-add menu (expense, income,
  transfer, receipt; later debt actions). Hidden while the keyboard is up and
  on the Assistant tab.
- Morph into the menu with `GlassEffectContainer` + `glassEffectID` where it
  stays simple; otherwise a standard `Menu`.

### Navigation and toolbars
- `NavigationStack` per tab, large titles on tab roots, inline on pushed
  screens. Title = screen name (no custom header views pretending to be bars).
- Top-trailing actions as `ToolbarItem`s with SF Symbols (profile/settings,
  filter, share). Group related actions; separate unrelated ones with
  `ToolbarSpacer(.fixed)`.
- Delete the global `UINavigationBarAppearance` in `AkifiApp`.

### Sheets and forms
- `.sheet` with `.presentationDetents` where content is short
  (`.medium`, `.large`); no `.presentationBackground`, no custom drag
  indicators. Toolbar `Cancel`/`Done` (`.confirmationAction` /
  `.cancellationAction`, the confirm one may use `.glassProminent` look via the
  system default).
- Forms: `Form`/`List` with `.insetGrouped` look; no custom card stacks inside
  sheets.

### Content: cards, lists, charts
- Cards stay **content**: `Color(.secondarySystemGroupedBackground)` on
  `Color(.systemGroupedBackground)`, continuous corners **20 pt** (small rows
  12 pt), **no shadows**, no borders. Use `CardStyle` from the design system.
- Prefer `List` for row collections (swipe actions, accessibility) over
  hand-made stacks.
- Amount typography: `.title`/`.largeTitle` with `.monospacedDigit()` and
  `.fontWeight(.semibold)`; secondary info `.secondary` foreground.
- Charts: Swift Charts with semantic colours; no glass.

### Buttons
- Primary call to action: `AkifiButtonStyle.primary` (= `.glassProminent` on
  26, `.borderedProminent` before), full width only in forms/empty states.
- Secondary: `.glass` / `.bordered`. Destructive: `role: .destructive`.
- Icon buttons: SF Symbol, `.buttonBorderShape(.circle)`, accessibility label.

### Menus, pickers, segmented controls
- System `Menu`, `Picker(.segmented)`, `Picker(.menu)` — they are glass on 26.
  Replace hand-made segmented controls and pop-ups with them.

### Banners, toasts, overlays
- Floating transient UI (offline/data banners, toasts) = small glass capsule
  near the top (`.glassEffect(.regular, in: .capsule)`), not full-width
  opaque bars.
- Full-screen celebration overlays stay content (no glass), dimmed backdrop.

## 4. Colour and type tokens
- Accent: `Color.accent` (#3B82F6) — also the app `AccentColor`.
- Semantic: `income` #10B981, `expense` #F43F5E, `transfer` = accent,
  `warning` #F59E0B, `budget` #8B5CF6. Keep; use only for meaning.
- Backgrounds: system grouped colours only (dark mode correct by default).
- Remove decorative gradients (AI gradient stays only on the Assistant's
  own screen header/avatar, not on navigation chrome).
- Type: text styles (`.largeTitle … .caption2`). No `.system(size:)` except
  for numbers that must not wrap — then still `relativeTo:` a text style.

## 5. Don'ts
- No glass on content cards, list rows, charts or backgrounds.
- No `.ultraThinMaterial` chrome imitating bars.
- No nested glass, no stacked shadows, no custom blur views.
- No availability-unchecked iOS 26 API (deployment target is 18).
- Don't change behaviour, data flow or analytics events while restyling.

## 6. Verification
- Build for iOS 18 deployment target (compiler enforces availability).
- Screenshot every touched screen on the **iOS 26.5** simulator in light and
  dark mode (`xcrun simctl io <id> screenshot`), plus Dynamic Type XL for the
  main tabs.
- Full XCTest suite and all lints stay green.
- Signed-in screens without signing in: the DEBUG-only harness
  (`AkifiIOS/Debug/UIHarness.swift`, compiled out of Release). Launch with
  `xcrun simctl launch <id> ru.akifi.app -AkifiUIHarness -spotlight_completed YES`
  (+ `-AkifiUIHarnessTab budgets`, `-AkifiUIHarnessBanners`,
  `-AkifiUIHarnessGallery` for every `Glass.swift` component). Drive taps and
  swipes with `idb ui tap|swipe --udid <id>`; the tab bar minimises only on a
  real drag, not on a programmatic scroll.

## 7. Decisions made while building the foundation (phase A)
- **Shell:** `MainTabView` = system `TabView` with `Tab(value:)` bound to
  `AppTab`; the system keeps every visited tab alive (state, scroll, nav
  stack). Tab bar tint = `Color.accent`. Journal is not in the bar (it had no
  entry point before 1.6 either); a stray `.journal` selection falls back to
  Home.
- **«+»:** tap opens the quick-add menu (income, expense, transfer, receipt —
  glass capsules morphing out of the button on 26); long press opens the
  category quick-add (wheel / grid / list per Settings), the pre-1.6 tap flow.
  It floats 12 pt above the measured top of the tab bar, trailing edge aligned
  with the bar (21 pt on 26, 16 pt before).
- **Banners** (offline, data issue, auto-match undo) float 50 pt below the top
  safe-area edge — over the title, never over toolbar buttons.
- **Home toolbar:** large title «Главная»; top-trailing currency switcher
  (`Menu`), fixed spacer, profile avatar without the shared glass plate
  (`sharedBackgroundVisibility(.hidden)`). Other tab roots keep their own
  toolbar items.
- **Spotlight:** anchors report frames through the environment (preferences
  don't cross `TabView` / toolbar hosting). The Assistant step is gone (no
  public API for a tab item's frame); any step whose target isn't on screen
  after 1.2 s is skipped. The tour never starts over the Assistant tab.

## 8. Decisions from the screen sweep — Transactions / Assistant / Auth
- **Search inside a tab:** `.searchable` + `.akifiSearchToolbarMinimize()`
  — on iOS 26 a search button in the top toolbar that expands into the glass
  field. A bottom-bar field (`DefaultToolbarItem(kind: .search,
  placement: .bottomBar)`) is not shown inside a `TabView` tab, and the tab
  bar's search role belongs to the Assistant. Suggestions/history go in
  `.searchSuggestions`; the query narrows the list on top of the filters.
- **Bottom controls over scrolling content** (chat composer, confirm
  buttons of consent/invite/action sheets): `.akifiBottomBar { … }` —
  `safeAreaBar` on 26 (scroll-edge effect, no opaque bar), the classic
  `.bar` inset before.
- **Chat:** the composer is one glass capsule (22 pt corners = capsule at
  one line) with the send/voice button inside; follow-ups and message
  actions are `.akifiSecondary` capsules; answers are `.akifiCard()`; user
  bubbles solid accent. Tab root → large title.
- **Auth fields:** no coloured borders — error = red icon + message,
  valid = green check; buttons `.akifiPrimary`/`.akifiSecondary`,
  `.controlSize(.large)`. Sign in with Apple stays Apple's control (black in
  light, white in dark), clipped to a capsule like the others.
- **Signed-out screens** have no tab view setting the tint (and the app has
  no AccentColor asset), so their roots set `.tint(Color.accent)`.
