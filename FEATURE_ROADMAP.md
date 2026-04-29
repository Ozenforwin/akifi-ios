# Akifi Feature Roadmap Q2-Q3 2026

> Стратегическое позиционирование: **"Осознанный финансовый дневник"**
> Journal-first подход. Ни один конкурент не объединяет: финансовый журнал + AI-инсайты + геймификация привычек + мультивалютность + privacy-first.

---

## Текущее состояние проекта

- **Версия:** 1.2.6 (TestFlight)
- **Кодовая база:** ~30K строк Swift 6, 180+ файлов
- **Стек:** SwiftUI, Supabase (Auth + DB + Edge Functions + Storage), Firebase (Analytics + Crashlytics + Messaging + Performance)
- **Платформа:** iOS 18.0+
- **Языки:** ru, en, es (1000+ ключей локализации)

### Уже реализовано (до этого роадмапа):
- Счета (мульти, совместные с ролями)
- Транзакции (доход/расход/перевод, калькулятор, merchant)
- Бюджеты (BudgetMath: pace, risk, safe-to-spend, rollover)
- Подписки (auto-match, SubscriptionDateEngine, история платежей)
- Цели накоплений (compound interest, contributions)
- AI-ассистент (чат, голос, действия, аномалии)
- Сканирование чеков
- Геймификация (ачивки, стрики, тиры)
- Мультивалютность (6 валют + конвертация)
- Экспорт CSV, импорт выписок
- Push-уведомления (Firebase)
- Онбординг (6 шагов + spotlight)

---

## ФАЗА 1: Quick Fixes & Journal — ВЫПОЛНЕНО

### 1.1 Исправления багов и тех. долга
| Задача | Статус | Файлы |
|--------|--------|-------|
| Убрать `exit(0)` в LanguagePickerView | **DONE** | `SettingsView.swift` |
| Интегрировать OfflineQueue с DataStore | **DONE** | `DataStore.swift` |
| Подключить NetworkMonitor к UI (offline badge) | **DONE** | `ContentView.swift` |
| Очистить старые git worktrees | **DONE** | `.claude/worktrees/` удалены |
| Добавить generic `logEvent()` в AnalyticsService | **DONE** | `AnalyticsService.swift` |
| Кеширование заметок в PersistenceManager | **DONE** | `PersistenceManager.swift` |

### 1.2 Финансовый журнал (RICE 9.45)
| Задача | Статус | Файлы |
|--------|--------|-------|
| Модель `FinancialNote` (mood, tags, photos, noteType) | **DONE** | `Models/FinancialNote.swift` |
| Миграция Supabase `financial_notes` + RLS | **DONE** | `supabase/migrations/20260416090000_financial_notes.sql` |
| Репозиторий (CRUD, поиск, теги) | **DONE** | `Repositories/FinancialNoteRepository.swift` |
| ViewModel (пагинация, фильтры, группировка) | **DONE** | `ViewModels/JournalViewModel.swift` |
| JournalTabView (список, фильтры, поиск) | **DONE** | `Views/Journal/JournalTabView.swift` |
| JournalNoteCardView (карточка заметки) | **DONE** | `Views/Journal/JournalNoteCardView.swift` |
| JournalNoteDetailView (детали + FlowLayout) | **DONE** | `Views/Journal/JournalNoteDetailView.swift` |
| JournalNoteFormView (создание/редактирование + PhotosPicker) | **DONE** | `Views/Journal/JournalNoteFormView.swift` |
| JournalReflectionFormView (еженедельная рефлексия с авто-сводкой) | **DONE** | `Views/Journal/JournalReflectionFormView.swift` |
| 5-й таб в навигации (Journal между Transactions и Budgets) | **DONE** | `ContentView.swift` |
| Analytics перемещён из табов в Home (NavigationLink) | **DONE** | `HomeTabView.swift` |
| Локализация 50+ ключей (ru/en/es) | **DONE** | `Localizable.xcstrings` |

### 1.3 Улучшение шаринга счетов
| Задача | Статус | Файлы |
|--------|--------|-------|
| HTTPS deep link (akifi.pro/invite/TOKEN) | **DONE** | `ShareAccountView.swift` |
| Чистое сообщение (ссылка + короткий код) | **DONE** | `ShareAccountView.swift`, `Localizable.xcstrings` |
| Авто-присоединение при открытии deep link | **DONE** | `ShareAccountView.swift` (AcceptInviteView) |
| Associated Domains в entitlements | **DONE** | `project.yml`, `AkifiIOS.entitlements` |
| AASA файл для Universal Links | **DONE** | `public/.well-known/apple-app-site-association` |
| NavigationTarget.journal для AI-навигации | **DONE** | `AssistantViewModel.swift` |

---

## ФАЗА 2: Подписки + Бюджеты интеграция (RICE 14.40, ~1 спринт) — ВЫПОЛНЕНО

> Самый высокий RICE-скор. BudgetMath не учитывал подписки — ни один конкурент тоже не делает этого.

### 2.1 BudgetMath + Subscriptions
| Задача | Статус | Файлы |
|--------|--------|-------|
| Добавить `subscriptions: [SubscriptionTracker]` в `BudgetMath.compute()` | **DONE** | `Services/BudgetMath.swift` |
| Метод `subscriptionCommitted(budget:subscriptions:)` | **DONE** | `Services/BudgetMath.swift` |
| `normalizedAmount()` — конвертация между периодами (weekly/monthly/quarterly/yearly) | **DONE** | `Services/BudgetMath.swift` |
| Новые поля в `BudgetMetrics`: `subscriptionCommitted`, `freeRemaining` | **DONE** | `Services/BudgetMath.swift` |
| Обновить `safeToSpendDaily` с учётом подписок | **DONE** | `Services/BudgetMath.swift` |
| Прокинуть subscriptions в BudgetsTabView → compute() | **DONE** | `Views/Budgets/BudgetsTabView.swift` |
| Показать подписки в BudgetCardView (violet-сегмент в прогресс-баре) | **DONE** | `Views/Budgets/BudgetCardView.swift` |
| Строка "Подписки: X / Свободно: Y" в карточке бюджета | **DONE** | `Views/Budgets/BudgetCardView.swift` |
| Warning если подписки > 50% бюджета | **DONE** | `Views/Budgets/BudgetHealthSummaryView.swift` |
| Unit-тесты для BudgetMath с подписками (13 тестов) | **DONE** | `AkifiIOSTests/BudgetMathTests.swift` |

### 2.2 Категория для подписок
| Задача | Статус | Файлы |
|--------|--------|-------|
| Добавить `category_id` в таблицу `subscriptions` (миграция) | **DONE** | `supabase/migrations/20260416100000_subscription_category.sql` |
| Обновить модель `SubscriptionTracker` | **DONE** | `Models/Subscription.swift` |
| Обновить `CreateSubscriptionInput` / `UpdateSubscriptionInput` | **DONE** | `Repositories/SubscriptionTrackerRepository.swift` |
| Обновить `create()` / `update()` в ViewModel | **DONE** | `ViewModels/SubscriptionsViewModel.swift` |
| Выбор категории в форме создания подписки | **DONE** | `Views/Subscriptions/SubscriptionListView.swift` |
| Выбор категории в форме редактирования подписки | **DONE** | `Views/Budgets/BudgetsTabView.swift` (EditSubscriptionFormView) |
| Локализация ключей (ru/en/es) | **DONE** | `Localizable.xcstrings` |

---

## ФАЗА 3: AI 2.0 + Cash Flow (RICE 6.40 + 5.10, ~3 спринта) — ВЫПОЛНЕНО

### 3.1 Natural Language запросы
| Задача | Статус | Файлы |
|--------|--------|-------|
| Расширить system prompt Edge Function для NL-запросов | **DONE** | `supabase/functions/assistant-query/*.ts` — деплой сделан 2026-04-18/19 |
| Добавить в контекст AI помесячную разбивку по категориям | **DONE** | `DataStore.swift` → `buildAssistantContext()` |
| Добавить в контекст AI список активных подписок (нормализовано по месяцам) | **DONE** | `DataStore.swift`, `AssistantModels.swift` |
| Добавить в контекст AI список бюджетов с метриками | **DONE** | `DataStore.swift`, `AssistantModels.swift` |
| AI всегда указывает период в ответе (нет "тратишь 23k" без контекста) | **DONE** | `nlg.ts` + `coaching-builders.ts` — правило #7 в промпте |

### 3.2 Проактивные инсайты (Nudges)
| Задача | Статус | Файлы |
|--------|--------|-------|
| Создать `InsightEngine` (анализ паттернов расходов) | **DONE** | `Services/InsightEngine.swift` |
| Типы: budget_warning, spending_spike, subscription_approaching, topCategoryHeavy, etc. (10 типов) | **DONE** | `InsightEngine.Kind` |
| Карточки инсайтов на Home (через InsightEngine) | **DONE** | `Views/Home/InsightCardsView.swift` |

### 3.3 Еженедельный дайджест
| Задача | Статус | Файлы |
|--------|--------|-------|
| `InsightEngine.weeklyDigest()` — генератор текста сводки | **DONE** | `Services/InsightEngine.swift` |
| `NotificationManager.scheduleWeeklyDigest()` — local notification в вс 10:00 | **DONE** | `Services/NotificationManager.swift` |
| Ссылка на таб «Журнал» через userInfo (deep link) | **DONE** | `ContentView.swift` |
| Связь с рефлексией в журнале | **DONE** | клик → открывает JournalTabView |

### 3.4 Cash Flow прогнозирование
| Задача | Статус | Файлы |
|--------|--------|-------|
| `CashFlowEngine` (паттерны + подписки + variance) | **DONE** | `Services/CashFlowEngine.swift` |
| Нормализация периодов (weekly/monthly/quarterly/yearly → monthly) | **DONE** | `CashFlowEngine.normalizeToMonthly` |
| Прогноз на 1/3/6 месяцев с confidence band (±σ) | **DONE** | `CashFlowEngine.forecast` |
| Confidence levels: low (<2 мес) / medium (2-3) / high (4+) | **DONE** | `CashFlowEngine.Confidence` |
| `CashFlowForecastView` — график + summary grid | **DONE** | `Views/Analytics/CashFlowForecastView.swift` |
| Интеграция в AnalyticsTabView | **DONE** | `Views/Analytics/AnalyticsTabView.swift` |
| Исправлены 4 бага (confidence, today-anchor, stdDev fallback, subs dedup) | **DONE** | 2026-04-18, +7 юнит-тестов |
| Интерактивный тултип, "when money runs out" alert, "how it works" sheet | **DONE** | commit `738273e` |
| Временно перемещено в низ дашборда (ждёт доработки визуала) | **PARKED** | `AnalyticsTabView.swift:127` |

### 3.5 Тесты
| Задача | Статус | Файлы |
|--------|--------|-------|
| Unit-тесты CashFlowEngine (14 тестов) | **DONE** | `AkifiIOSTests/CashFlowEngineTests.swift` |
| Покрытие: normalizeToMonthly, forecast (empty/history/subs), variance, confidence | **DONE** | — |

---

## ФАЗА 4: Отчёты + Геймификация (RICE 4.50 + 3.73, ~2 спринта) — ВЫПОЛНЕНО

### 4.1 PDF-отчёты (commit `f604556`)
| Задача | Статус | Файлы |
|--------|--------|-------|
| `PDFReportGenerator` (UIGraphicsPDFRenderer, A4 многосекционный) | **DONE** | `Services/PDFReportGenerator.swift` |
| Шаблоны: месячный, квартальный, годовой (через фильтр ReportsView) | **DONE** | |
| Содержание: сводка с MoM/QoQ/YoY дельтами, категории, топ-10 расходов, бюджеты, подписки | **DONE** | |
| Подключить ReportsView к навигации (NavLink из Home) | **DONE** | `Views/Home/HomeTabView.swift` → `ReportsShortcutCard` |
| ShareLink для PDF через `UIActivityViewController` | **DONE** | `Views/Reports/ReportsView.swift` |
| Локализация RU/EN/ES (`pdf.*`, `reports.*`) | **DONE** | `Localizable.xcstrings` |
| 3 smoke-теста | **DONE** | `AkifiIOSTests/PDFReportGeneratorTests.swift` |

### 4.2 Savings Challenges (commit `dae1065`)
| Задача | Статус | Файлы |
|--------|--------|-------|
| Модель `SavingsChallenge` + 4 типа (noCafe, roundUp, weeklyAmount, categoryLimit) | **DONE** | `Models/SavingsChallenge.swift` |
| Миграция Supabase с RLS | **DONE** | `supabase/migrations/20260419120000_savings_challenges.sql` (применена 2026-04-19) |
| Repository Sendable CRUD | **DONE** | `Repositories/SavingsChallengeRepository.swift` |
| ChallengeProgressEngine (pure, идемпотентная) | **DONE** | `Services/ChallengeProgressEngine.swift` + 10 тестов |
| ViewModel `@Observable @MainActor` | **DONE** | `ViewModels/SavingsChallengesViewModel.swift` |
| UI: list + detail + form + card | **DONE** | `Views/Challenges/` |
| Привязка challenges к целям накоплений (linkedGoalId) | **PARTIAL** | модель + engine поддерживают; goal-picker в форме — TODO |
| Точка входа (`ChallengesShortcutCard` в HomeTabView) | **DONE** | |
| Push-напоминания для челленджей | TODO | `NotificationManager` — для Phase 5 |

### 4.3 Streak Milestones (commit `ba41902`)
| Задача | Статус | Файлы |
|--------|--------|-------|
| `StreakTracker` + milestones [7,14,30,60,100,180,365] + dedup в UserDefaults | **DONE** | `Services/StreakTracker.swift` + 12 тестов |
| `StreakMilestoneView` celebration popup (tier-градиент, confetti, haptic) | **DONE** | `Views/Achievements/StreakMilestoneView.swift` |
| Триггер после создания транзакции | **DONE** | `Views/Root/ContentView.swift` |
| Защита от multi-level jumps (5→35 = один попап на 30) | **DONE** | |
| Бонусные ачивки за стрики (bronze/silver/gold/diamond badges) | TODO | требует seed-миграции или client-side синтеза |

### 4.4 Skill Tree (commit `ba41902`)
| Задача | Статус | Файлы |
|--------|--------|-------|
| Модель `SkillNode` — 15 узлов в 5 треках с prerequisites | **DONE** | `Models/SkillNode.swift` |
| `SkillTreeEngine` (pure, multi-pass evaluator) | **DONE** | `Services/SkillTreeEngine.swift` + 5 тестов |
| `SkillTreeView` — flat grid по трекам + detail sheet (MVP) | **DONE** | `Views/Achievements/SkillTreeView.swift` |
| Точка входа из `AchievementsView` | **DONE** | |
| v2: canvas-визуализация с рёбрами + zoom/pan + анимация веток | TODO | Phase 5 |

### 4.5 Уровни «Новичок → Финансовый мастер»
| Задача | Статус | Файлы |
|--------|--------|-------|
| 10 уровней уже реализованы до этого роадмапа | **DONE** | `AchievementRepository.swift` |

---

## ФАЗА 5: iOS Виджеты + Net Worth (RICE 3.60 + 1.88, ~3 спринта)

### 5.1 iOS Виджеты
| Задача | Статус | Файлы |
|--------|--------|-------|
| Новый target `AkifiWidget` (WidgetKit) | TODO | Xcode target |
| App Groups для shared data | TODO | `project.yml`, entitlements |
| Small widget: баланс | TODO | |
| Small widget: дневной лимит (из BudgetMath) | TODO | |
| Circular widget: стрик | TODO | |
| Medium widget: сводка дня (доход/расход/баланс) | TODO | |

### 5.2 Net Worth трекер — DONE (BETA)
| Задача | Статус | Файлы |
|--------|--------|-------|
| Модель `Asset` (недвижимость, авто, крипто, инвестиции) | **DONE** | `Models/Asset.swift` |
| Модель `Liability` (кредиты, ипотека, долги) | **DONE** | `Models/Liability.swift` |
| Миграция Supabase (`assets`, `liabilities`, `net_worth_snapshots`) | **DONE** | `supabase/migrations/` |
| Net Worth = Assets - Liabilities + Account balances | **DONE** | `Services/NetWorthCalculator.swift` |
| Дашборд net worth (hero / breakdown / chart 30/90/180/365 дней) | **DONE** | `Views/NetWorth/NetWorthDashboardView.swift` |
| Ручной ввод / редактирование / удаление активов и долгов | **DONE** | `AssetFormView.swift` + `LiabilityFormView.swift` |
| Snapshots ежедневные | **DONE** | `Repositories/NetWorthSnapshotRepository.swift` |

### 5.3 Инвест-инструмент (BETA, Settings → Инвестиции) — Phase 1-2 DONE
Расширение `Asset` категорий `investment`/`crypto` до полноценного инвест-портфеля. Скрыто за beta-флагом.

| Спринт | Задача | Статус | Коммит |
|--------|--------|--------|--------|
| 1 | `investment_holdings` table + AFTER STATEMENT триггер `recompute_asset_value_on_holding_change` | **DONE** | `c1212ba` |
| 1 | `InvestmentHolding` model + `HoldingKind` enum + `InvestmentHoldingRepository` | **DONE** | `c1212ba` |
| 1 | `PortfolioCalculator.aggregate` (totalValue, ROI, byKind, byCurrency) + 11 тестов | **DONE** | `c1212ba` |
| 2 | `PortfolioViewModel` + `InvestmentHoldingFormView` + `InvestmentHoldingsListView` (встроен в `AssetFormView`) | **DONE** | `b663e86` |
| 2 | `PortfolioDashboardView` — hero / 2 donut chart'а / cross-asset list | **DONE** | `b663e86` |
| 3 | `fetch-price` edge function + `price_cache` table (CoinGecko + Twelve Data, 30-мин кеш) | **DONE** | `75176b3` |
| 3 | "Pull current price" button + stale badge | **DONE** | `75176b3` |
| 4 | `SavingsRateCalculator` (поверх `CashFlowEngine`) + `FIREProjector` (4% rule, scenarios) + `CompoundProjector` | **DONE** | `cec840b` |
| 4 | `FIREProjectionView` + `CompoundCalculatorView` + FIRE-тизер на NetWorthDashboard | **DONE** | `cec840b` |
| 5 | Tooltips через `InfoTooltipButton` (4% rule / savings rate / investable / expected return) | **DONE** | `8d6320a` |
| 6 | `PortfolioCalculator.rebalance` (no-sell) + `TargetAllocationView` + `RebalanceHintView` | **DONE** | `fb2dad1` |
| 7 | Manual override для FIRE (расход + взнос) — обходит проблему общих счетов | **DONE** | `b1b1afb` |
| 7 | `FIREImpactCalculator` + секция в `TransactionDetailView` для крупных трат | **DONE** | `b1b1afb` |
| 7 | CAGR per holding (annualized return из `acquired_date`) + UI рядом с ROI | **DONE** | `b1b1afb` |
| 7 | `refresh-portfolio-prices` edge function + pg_cron migration (06:00 UTC) | **DONE** (deploy manual) | `b1b1afb` |
| 7 | PRD по deferred Phase 3 фичам (TWR/IRR/dividends/tax-lots/etc.) | **DONE** | `.claude/prd/portfolio-phase-3.md` |

> [!note] Deploy artefacts
> Edge function `refresh-portfolio-prices` лежит в `supabase/functions/`, миграция `20260501100000_refresh_prices_cron.sql` — в репо. Из-за временного сбоя Supabase MCP при последнем коммите автодеплой не прошёл; ручной деплой — через `supabase functions deploy refresh-portfolio-prices --project-ref fnvwfrkixjqdifitlifr --no-verify-jwt`, затем `ALTER DATABASE postgres SET app.settings.*` и применение миграции. Подробности — в `b1b1afb`.

### 5.3.1 Phase 3 (deferred → `.claude/prd/portfolio-phase-3.md`)
- TWR / IRR / XIRR — нужна таблица `holding_transactions`
- Dividends — нужна таблица `holding_dividends`
- Tax-lots FIFO/LIFO — нужна та же `holding_transactions`
- FX-decomposed return — нужны поля `cost_basis_base` + `cost_basis_date`
- Shared portfolio для пар — RLS rewrite + UI per-holding ownership
- Education-уроки — нужен контент-pass на ru/en/es
- Risk / volatility — нужен 5+ лет истории цен (Twelve Data paid)
- MOEX / KASE feed — research API (MOEX публичный, KASE неясно)
- Broker CSV import — N парсеров, никогда "done"

---

## ФАЗА 4.6: Payment Source + Shared Account Settlement (2026-04-19) — MVP ВЫПОЛНЕНО + stability pass

Закрывает боль с общим счётом Вова/Оля: оплаты общих трат с личных карт теперь 1 тап, без ручного балансирования.

### Отгружено

| Задача | Статус | Коммит |
|--------|--------|-------|
| 3 миграции + 3 RPC функции (create/update/delete_expense_with_auto_transfer) | **DONE** | `1efe5af` |
| iOS data layer: модели, репозитории, PaymentDefaultsVM | **DONE** | `7448300` |
| Picker «Оплачено с», валютная блокировка, ⭐ для сохранённого дефолта | **DONE** | `7a53d47` |
| Бейдж «Из X» в TransactionRowView/DetailView, guard на удаление transfer-leg | **DONE** | `7a53d47` |
| Settings → «Способы оплаты» per-account | **DONE** | `6aeb850` |
| SettlementCalculator (equal split + greedy min-cash-flow) + 7 тестов | **DONE** | `58991a9` |
| SharedAccountDetailView + settlement card | **DONE** | `0fdbb88` |
| **Stability pass** — 5 багов с first-device test (RPC 404, scale, attribution, dup label, segmented) | **DONE** | `9731d4c` |
| **Feature-scoped settlement** — игнорим legacy-transfer'ы и прямые расходы | **DONE** | `b53cf72` |
| **Closure flow** — «Отметить выполненным» реально закрывает долг, история + отмена ⟲ | **DONE** | `2eada24` |
| Reports + Challenges перенесены в Settings с BETA-бейджем | **DONE** | `c9085b7` |
| Swipe-delete auto-transfer синкает локальное состояние с триплетом | **DONE** | `2978474` |
| Orphan settlement скрывается когда нет транзакций в периоде | **DONE** | `79339f3` |
| Дефолт picker'а = «Этот счёт», auto-transfer только по явному выбору | **DONE** | `6ece83a` |

### v2 (2026-04-19, commits `550a57f`…`33e2201`)

| Пункт | Статус | Коммит |
|---|---|---|
| Discovery-онбординг (баннер для новых юзеров) | **DONE** | `33e2201` |
| Cross-currency auto-transfers (ByBit USD → Семейный RUB) | **DONE** | `1b548ec` |
| Custom split weights (60/40 и т.п.) | **DONE** | `21ff449` |
| Design pass (settlement card, hero, участники, бейджи) | **DONE** | `33e2201` |

### v3 (2026-04-19, commits `0161bdb`…`77bf4c5`) — ЗАКРЫТО

| Пункт | Статус | Коммит |
|---|---|---|
| Bank import dedup против auto-transfer | **DONE** | `0161bdb` |
| Direct-expense attribution (credits creator) | **DONE** | `d12f41e` |
| FX-normalize cross-currency contributions + 4 теста | **DONE** | `d12f41e` + `615f064` |
| Orphan settlements auto-cleanup | **DONE** | `1e75432` |
| Edit-existing-expense source reassignment | **DONE** | `77bf4c5` (client-side) |
| Bump 1.2.7 (ASC train closed) | **DONE** | `9c67264` |

**Итого по Phase 4.6:** MVP → v2 → v3 закрыто. 132/132 тестов. TestFlight 1.2.7.

### TODO v4 (если понадобится)
- **Atomic `reassign_expense_source` RPC** — сейчас client-side delete+recreate, окно неатомарности ~300ms. Повысить до RPC если частые reassignments в телеметрии.
- **Per-row `fx_rate_to_base` column** — сейчас FX snapshot current. Мигрируем если нужна историческая точность при скачках курсов.
- **Push-напоминания для челленджей** (унаследовано из Phase 4.2)
- **Bonus streak achievements** (унаследовано из Phase 4.3)
- **Skill tree v2 canvas** (унаследовано из Phase 4.4)

### Осознанно НЕ делаем
- Retroactive attach к старым ручным переводам
- Multi-level settlement (A→B→C)

---

## ФАЗА 4.5: Стабильность (внеплановая, 2026-04-17 … 19) — ВЫПОЛНЕНО

Баги обнаружены в TestFlight, починены с глубоким копанием в root cause:

| Задача | Статус | Файлы / коммит |
|--------|--------|-------|
| Race condition двух рефрешей сессии (→ ложная "Сессия истекла") | **DONE** | `SupabaseManager.sessionCoordinator` actor, `c889d48` |
| `verify_jwt = true` по умолчанию в деплое assistant-query (→ 401 за 50мс) | **DONE** | `supabase/config.toml` с verify_jwt=false, `f03d8a4` |
| Платформенный JWT rejection блокировал grace-period токены | **DONE** | Редеплой с `--no-verify-jwt` |
| AuthManager слишком агрессивный signOut на любую ошибку рефреша | **DONE** | `isDefinitivelyExpired()` — только на `refresh_token_not_found`, `invalid_grant` и пр. |
| `AssistantErrorType.classify` false-positive на substring "auth" | **DONE** | Явные сигналы: `code: 401/403`, `unauthorized`, `jwt expired` |
| Universal Links не работали (AASA не отдавался) | **DONE** | `Site Akifi` nginx + `public/.well-known/apple-app-site-association` |
| `/invite/:token` на сайте не существовал — шаринг счёта вёл на лендинг | **DONE** | `Site Akifi/src/pages/Invite.tsx` с smart deeplink логикой |
| Сайт рекламировал только Telegram — нет иконки App Store | **DONE** | Hero, FinalCTA, Navbar, Footer + meta-теги |

---

## Роадмап по спринтам

| Спринт | Фаза | Фичи | Статус |
|--------|-------|-------|--------|
| **S1** (нед 1) | Fixes + Journal | Исправления + Финансовый журнал + Шаринг | **DONE** |
| **S2** (нед 2) | Subscriptions | Подписки ↔ Бюджеты интеграция | **DONE** |
| **S3-S5** (нед 3-5) | AI 2.0 + Cash Flow | Nudges + InsightEngine + CashFlowEngine + ForecastView + дайджест | **DONE** |
| **S5.5** (внеплан, 2 дня) | Stability | Session refresh coordinator + verify_jwt + Universal Links + Landing update | **DONE** |
| **S6-S8** (нед 6-8) | Reports + Gamification | PDF-отчёты + Savings Challenges + Streak milestones + Skill tree MVP | **DONE** |
| **S9-S10** (нед 9-10) | Widgets | WidgetKit (4 виджета) | TODO |
| **S11-S12** (нед 11-12) | Net Worth | Активы, долги, дашборд | TODO |
| **S13** (нед 13, опционально) | Phase 4 polish | Skill tree v2 (canvas + zoom/pan) + bonus streak badges + push-напоминания челленджей | TODO |

---

## Конкурентные преимущества (по результатам анализа рынка)

| Преимущество | Статус | vs Конкуренты |
|-------------|--------|---------------|
| BudgetMath (pace, risk, forecast) | **Есть** | Продвинутее Monarch/YNAB |
| Мультивалютность (6 валют) | **Есть** | Критично вне US-рынка |
| Геймификация (ачивки, стрики) | **Есть** | Есть только у Cleo (базовая) |
| AI-ассистент с голосом и действиями | **Есть** | На уровне Copilot/Monarch |
| Сканирование чеков | **Есть** | Есть у немногих |
| Цели с compound interest | **Есть** | Уникальная фича |
| Privacy-first (без банковского подключения) | **Есть** | Дифференциатор |
| **Финансовый журнал** | **Есть** | **НИ У КОГО нет** (Gap #1 рынка) |
| **Подписки ↔ Бюджеты связь** | **Есть** | **НИ У КОГО нет** (Gap #7 рынка) |
| Cash flow прогноз | **Есть** | На уровне Monarch/Quicken |
| PDF-отчёты | **Есть** | На уровне Monarch/Rocket |
| Savings challenges | **Есть** | Лучше Cleo (4 типа, привязка к целям) |
| Skill tree навыков | **Есть (MVP)** | **НИ У КОГО нет** (Gap #11 рынка) |
| Streak milestones с celebration | **Есть** | Сильнее чем у большинства |
| iOS Виджеты | TODO | Есть у многих |
| Net worth | TODO | Есть у Monarch/YNAB |

---

## Технический долг (не блокирует, но стоит исправить)

| Задача | Приоритет | Описание |
|--------|-----------|----------|
| Dependency Injection | Medium | Все Repository создаются напрямую, нет протоколов, нет DI-контейнера |
| Unit-тесты BudgetMath | **DONE** | 13 тестов, покрывают подписки + edge cases |
| Unit-тесты CashFlowEngine | **DONE** | 14 тестов (confidence, averages, stdDev fallback, subscription dedup) |
| Unit-тесты ChallengeProgressEngine | **DONE** | 10 тестов (noCafe, categoryLimit, transitions, range clipping) |
| Unit-тесты StreakTracker + SkillTreeEngine | **DONE** | 12 + 5 тестов |
| Unit-тесты DataStore/ViewModels | Medium | Покрыты: CashFlow, BudgetMath, Challenge, Streak, SkillTree, SubscriptionDate, SubscriptionMatcher. Не покрыты: DataStore.balance, displayCategories merging, JournalViewModel |
| Декомпозиция ContentView | Low | 400+ строк, можно разбить |
| Декомпозиция SettingsView | Low | 587 строк, 5 под-View внутри |
| PaymentManager (StoreKit) | **High** | Заглушка, нет In-App Purchases — блокирует монетизацию |
| OfflineQueue для всех сущностей | Medium | Сейчас только транзакции |
| NetworkMonitor → DataStore интеграция | Medium | Автосинхронизация при восстановлении сети |
| Goal-picker в ChallengeFormView | Medium | Модель + engine поддерживают linkedGoalId, форма — нет |
| Миграция iOS repo edge-функций на TMA config | **DONE** | `supabase/config.toml` зеркало TMA репо |
| Синхронизация `types.ts` из TMA repo | **DONE** | Скопирован в iOS repo, закоммичен |

---

*Последнее обновление: 2026-04-19*
*Анализ рынка: топ-10 конкурентов (Monarch, YNAB, Copilot, Rocket Money, PocketGuard, Cleo, EveryDollar, MoneyWiz, Goodbudget, Fina)*

## Следующий шаг (рекомендация)

1. **Phase 5.1 — iOS Widgets** (WidgetKit + App Groups): высокая видимость на home screen iPhone, retention-booster. ~2 спринта, требует нового Xcode target.
2. **Phase 5.2 — Net Worth трекер**: активы/долги/дашборд, ~2 спринта, новая БД-схема.
3. **Параллельно — Phase 4 polish** (1 неделя дополнительно): goal-picker в челленджах, push-напоминания, bonus streak badges, skill tree v2.
4. **Блокер для релиза v1.3** — реализовать StoreKit в `PaymentManager` (сейчас заглушка).
