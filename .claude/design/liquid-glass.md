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
  with the bar (21 pt on 26, 16 pt before). *Superseded in phase B — see
  §8.*
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

## 8. Decisions made while building quick entry (phase B)
- **«+»:** tap opens the quick-entry sheet (expense). Long press (and the
  VoiceOver action «Другие операции») opens the glass capsule menu: Доход,
  Расход (both quick entry), Перевод, Чек, Дал в долг, Взял в долг. The
  category wheel and its Settings row («Вид категорий») are retired: the
  sheet's category chips + «Все» cover category-first entry, and the full
  form is one tap away («Подробнее»).
- **Quick-entry sheet:** system `.sheet`, detents `[.medium, .large]`; with
  the keyboard up the system lifts it to the large height, which keeps
  «Сохранить» right above the keyboard. Toolbar: close (`xmark`, leading),
  `Picker(.segmented)` Расход/Доход as the principal item, «Подробнее»
  trailing — all system toolbar glass. The save button is `.akifiPrimary`
  in a bottom `safeAreaInset`, no background (the sheet is the glass).
- **Chips are content, not glass** (category, account, date, «Повторить»):
  `tertiarySystemFill` capsules, selected = accent fill with white text,
  44 pt tall. A row of glass buttons inside the glass sheet would be glass
  on glass. Account and date chips are `Menu`s (their popups are system
  glass). The mic is an icon button with `.akifiSecondary` + circle shape.
- **Toast** «Записано: … · Отменить» = `.akifiGlassBanner` in the top banner
  stack (same place as the other banners), 5 s (12 s with VoiceOver).

## 9. Decisions from device testing (Vladimir, 2026-11-28)
- **Account cards keep their colour.** The plain white card lost which
  account is which. Home's account cards use `.akifiCard(tint: accountColor)`:
  a light diagonal wash (10 % → 22 %) and a 0.5 pt hairline in the account's
  colour, no shadow, still content (not glass). Other cards stay neutral.
- **Quick entry keeps the keyboard up.** The window-wide tap-to-hide-keyboard
  gesture skips UIKit controls, never delays touch-ups, and is suspended
  while quick entry is on screen (`KeyboardTapDismiss`). The type control
  (Расход · Доход · Перевод) is full-width content, not a toolbar item.
- **No wrapping chip rows above a bottom bar.** Chip rows scroll sideways;
  bottom call-to-action bars use `akifiSafeAreaBar` so content never shows
  through them.
- **Currency is chosen next to the amount** (quick entry chip, debt forms).

## 10. Decisions from the screen sweep — Transactions / Assistant / Auth
- **Search inside a tab:** `.searchable` + `.akifiSearchToolbarMinimize()`
  — on iOS 26 a search button in the top toolbar that expands into the glass
  field. A bottom-bar field (`DefaultToolbarItem(kind: .search,
  placement: .bottomBar)`) is not shown inside a `TabView` tab, and the tab
  bar's search role belongs to the Assistant. Suggestions/history go in
  `.searchSuggestions`; the query narrows the list on top of the filters.
- **Bottom controls over scrolling content** (chat composer, confirm
  buttons of the consent/action sheets): `.akifiSafeAreaBar(edge: .bottom)`
  (`hardEdge: true` for the two-button consent bar).
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

## 11. Widgets — «Счёт» and «Быстрая запись» (1.6.0)
- **Widgets are content, not glass.** No `glassEffect` inside a widget: on
  iOS 26 the system draws its own glass around a tinted / clear widget.
  Background via `containerBackground(for: .widget)` only.
- **Full colour:** the «Счёт» widget is washed in the account's colour like
  its Home card (`secondarySystemGroupedBackground` + 10 % → 22 % diagonal
  wash); «Быстрая запись» stays neutral with meaning-coloured buttons
  (expense red, income green, mic accent, 14 % fills). Buttons and
  «Повторить» rows are chips (`tertiarySystemFill`, ≥ 44 pt tall where the
  family allows).
- **Tinted / clear (`widgetRenderingMode != .fullColor`):** no wash, no
  colour; semantics carried by symbols and signs (↗ +, ↙ −, «+», «−»).
  `.widgetAccentable()` on the balance, the button symbols and amounts.
- **Lock Screen:** `.accessoryRectangular` / `.accessoryInline` («Счёт»),
  `.accessoryCircular` «+» («Быстрая запись»); money texts are
  `.privacySensitive()` (redacted while the iPhone is locked).
- **Taps are deep links** (`Link` / `widgetURL` → `akifi://quick-add?…`
  built by `QuickEntryLaunchLink`): a widget only opens the quick-entry
  sheet, never saves. A small widget also carries a `widgetURL` fallback
  («Расход») for systems that don't route a `Link` there.
- **Dynamic Type:** text styles, capped at `.xxLarge` (small) / `.xLarge`
  (medium, buttons) so layouts never clip; numbers scale down
  (`minimumScaleFactor`) instead of wrapping.

## 12. Account covers (Vladimir, 2026-11-28)
- **Who:** the account's OWNER (`accounts.user_id`) sets, re-crops or removes
  the cover; every member of a shared account sees the same cover and no
  edit controls (footer says who can change it). Debt accounts have none.
  Server: `20261128100000_account_covers.sql` (private bucket
  `account-covers`, `<account_id>/<uuid>.jpg`, owner-only writes, members
  read; `guard_account_cover`).
- **Card:** with a cover the Home card's background is the photo
  (`scaledToFill`, clipped, 20 pt continuous corners — same frame as
  `.akifiCard`), still content: no glass, no shadow, no hairline. Without
  one (or until it has loaded / offline with nothing cached) the tinted card
  of §9. The account colour keeps marking the page dot.
- **Legibility is computed, not eyeballed:** the photo's brightest spot is
  measured in the header band and the balance band (`AccountCoverTone`), and
  the dark scrim gets just enough opacity there for WCAG AA 4.5 : 1 (7 : 1
  with Increase Contrast) for every colour drawn on it (`AccountCoverScrim`,
  unit-tested for any brightness). Text and symbols turn white; income /
  expense use lighter tints of the same hues (#10B981 → #6EE7B7,
  #F43F5E → #FDA4AF) — the semantic ones fail on a dark scrim. Accessibility text sizes and
  layouts other than the Home card (shared account header) use one even
  scrim strong enough for the brightest spot anywhere.
- **Picker and crop:** «Обложка» section in «Настройки счёта»
  (`AccountFormView`, existing accounts only): preview, «Выбрать фото»
  (`PhotosPicker`, images, out of process — no library permission),
  «Изменить область», «Убрать обложку» (destructive, confirmed). Each applies
  at once (like «Участники» next to it). The crop screen is a dark
  full-screen cover with system toolbar Cancel / Done; the photo moves under
  a card-shaped window (card aspect 1.9 : 1), outside dimmed, the card's text
  live in the window; pinch + drag, clamped so the window is always filled;
  VoiceOver: adjustable zoom and four move actions.
- **Upload:** ≈1200 px wide JPEG (quality 0.8), a new bitmap encoded with no
  metadata (no EXIF / GPS / camera). Downloads go through the authenticated
  Storage API — no public or signed URLs anywhere.
