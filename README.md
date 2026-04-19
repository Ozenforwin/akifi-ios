# Akifi iOS

Нативное iOS-приложение для управления личными финансами. Построено на SwiftUI с бэкендом Supabase и Firebase. Работает параллельно с Telegram Mini App версией Akifi.

**Актуальная версия:** 1.2.7 (TestFlight) · **Тесты:** 150/150 green

## Tech Stack

| Компонент | Технология |
|-----------|-----------|
| Язык | Swift 6 (strict concurrency) |
| UI | SwiftUI (iOS 18+) |
| Min Deployment | iOS 18.0 |
| IDE | Xcode 16+ |
| Backend | Supabase (supabase-swift v2.43+) |
| Analytics & Push | Firebase (Analytics, Crashlytics, FCM, Performance) |
| Графики | Swift Charts (нативный) |
| Auth | Sign in with Apple, Google Sign-In, Email/Password, Telegram migration |
| Локализация | 3 языка: Русский, English, Español (1100+ ключей) |
| Project Gen | XcodeGen (project.yml) |
| CI/CD | Codemagic (TestFlight) |

## Архитектура

### MVVM + Repository + DataStore

```
┌─────────────────────────────────────────────┐
│                   Views                      │
│  (SwiftUI, @Environment для зависимостей)    │
├─────────────────────────────────────────────┤
│                ViewModels                    │
│  (@Observable @MainActor, бизнес-логика)     │
├─────────────────────────────────────────────┤
│    DataStore          │    Repositories      │
│  (shared state,       │  (Supabase CRUD,     │
│   кэш balance/cat)    │   Sendable)          │
├─────────────────────────────────────────────┤
│  SupabaseManager  │  Firebase  │  Services   │
│  (Singleton)      │  (FCM,     │  (Analytics │
│                   │   Crash)   │   Haptics)  │
└─────────────────────────────────────────────┘
```

### Data Flow

`AppViewModel` (root) владеет:
- `AuthManager` — аутентификация (Apple, Google, Email, Telegram migration) + auto-refresh при foreground
- `CurrencyManager` — курсы валют, форматирование, конвертация
- `PaymentManager` — проверка Premium статуса
- `DataStore` — shared хранилище с параллельной загрузкой (`async let`), предвычисленными кэшами (balance, income/expense по счетам, category index), `displayCategories` для UI-пикеров
- `ThemeManager` — тема оформления
- `JournalViewModel` — shared state журнала (переживает tab switches, 60s TTL кэш)

Инжектируется через `.environment(appViewModel)` из `AkifiApp.swift`.

### Ключевые паттерны

- **Типизированная навигация** — `AppTab` enum вместо raw Int для tab bar и Spotlight
- **Sheet Coordinator** — единый `SheetDestination` enum для управления модальными экранами
- **Единый декодер** — `KeyedDecodingContainer.decodeKopecks(forKey:)` для числовых сумм из БД
- **Кэшированные форматтеры** — `AppDateFormatters` со static lazy свойствами
- **Структурированное логирование** — `AppLogger` через `os.Logger` с категориями (data, ai, auth, network)
- **Concurrency** — Task-based таймеры, async/await повсюду, Sendable репозитории
- **Shared account category merging** — ID-based dedup в DataStore, name-based grouping в Reports
- **SessionCoordinator** — actor в `SupabaseManager` дедуплицирует concurrent refresh'ы (single-use refresh_token protection)
- **RPC encode(to:)** — custom encoder emit'ит JSON null для optional ключей чтобы PostgREST матчил сигнатуру функции (иначе argument-name dropping ломает routing)
- **Postgres functions для атомарных multi-row операций** — `create/update/delete_expense_with_auto_transfer` (payment source → auto-transfer triplet), edge functions только для LLM/внешних API
- **Multi-currency (ADR-001)** — `transactions.amount_native` в валюте счёта как single source of truth; `foreign_amount`/`foreign_currency`/`fx_rate` для оригинального ввода; trigger `transactions_fill_amount_native` обеспечивает обратную совместимость с legacy клиентами
- **TransactionMath.amountInBase** — единая утилита FX-нормализации для cross-account aggregations (InsightEngine / CashFlowEngine / Analytics / Reports), чтобы USD и RUB суммы не складывались сырыми

## Структура проекта

```
AkifiIOS/
├── AkifiApp.swift                    # Entry point, Firebase init, scenePhase auth refresh
├── AppConstants.swift                # Config из Info.plist (Supabase URL/Key)
├── Info.plist                        # Permissions, URL schemes
├── AkifiIOS.entitlements             # Apple Sign In, APNs
├── PrivacyInfo.xcprivacy             # Privacy manifest
│
├── Models/
│   ├── Transaction.swift             # Транзакции + paymentSourceAccountId + autoTransferGroupId
│   ├── Account.swift                 # Банковские счета + AccountMember.splitWeight
│   ├── Budget.swift                  # Бюджеты (weekly/monthly/custom)
│   ├── Category.swift                # Категории расходов/доходов
│   ├── SavingsGoal.swift             # Цели накоплений + проценты
│   ├── SavingsChallenge.swift        # Челленджи (30-day, no-cafe, round-up, category-limit)
│   ├── Subscription.swift            # Трекер подписок
│   ├── SubscriptionPayment.swift     # Платежи подписок
│   ├── FinancialNote.swift           # Журнал: заметки + рефлексии (NoteType, NoteMood)
│   ├── Achievement.swift             # Достижения (9 категорий, 4 тира)
│   ├── SkillNode.swift               # Дерево навыков (15 узлов в 5 треках)
│   ├── Asset.swift                   # Активы (real_estate/vehicle/crypto/investment/...)
│   ├── Liability.swift               # Долги (mortgage/loan/credit_card/...)
│   ├── NetWorthSnapshot.swift        # Дневные snapshots чистой стоимости
│   ├── Settlement.swift              # Закрытые расчёты между участниками shared-счёта
│   ├── UserAccountDefault.swift      # Per-user дефолтный source для каждого счёта
│   ├── AssistantModels.swift         # AI request/response + AnyCodableValue + error classification
│   ├── AiConversation.swift          # AI чат-сессии
│   ├── Profile.swift                 # Профиль пользователя
│   ├── ReceiptScan.swift             # Данные OCR чека
│   ├── ExchangeRates.swift           # Курсы валют
│   ├── NotificationSettings.swift    # Настройки уведомлений
│   └── UserSubscription.swift        # Premium статус
│
├── Services/
│   ├── AuthManager.swift             # Auth: Apple/Google/Email/Telegram + refreshSessionIfNeeded()
│   ├── SupabaseManager.swift         # Singleton + SessionCoordinator actor (dedup refresh)
│   ├── DataStore.swift               # Shared state + параллельная загрузка + displayCategories
│   ├── CurrencyManager.swift         # Мультивалюта, курсы, форматирование, formatInCurrency
│   ├── TransactionMath.swift         # ADR-001 FX-нормализация в base (cross-account aggregations)
│   ├── FeatureFlags.swift            # Local feature flags (UserDefaults) + multi_currency_v2 toggle
│   ├── PaymentManager.swift          # Premium-подписка (заглушка, StoreKit отключён)
│   ├── ThemeManager.swift            # Тема (light/dark)
│   ├── BudgetMath.swift              # Вычисление метрик бюджетов
│   ├── CashFlowEngine.swift          # Прогноз денежного потока
│   ├── InsightEngine.swift           # Умные финансовые инсайты + weekly digest
│   ├── SettlementCalculator.swift    # «Кто кому должен» для shared-счетов (weighted split + FX)
│   ├── ChallengeProgressEngine.swift # Расчёт прогресса челленджей (pure, idempotent)
│   ├── NetWorthCalculator.swift      # sum(accounts) + sum(assets) − sum(liabilities) с FX
│   ├── StreakTracker.swift           # Streak + milestone-dedup в UserDefaults
│   ├── SkillTreeEngine.swift         # Multi-pass evaluator для дерева навыков
│   ├── PDFReportGenerator.swift      # A4 многосекционный PDF через UIGraphicsPDFRenderer
│   ├── CalculatorState.swift         # Калькулятор (locale-aware)
│   ├── ExchangeRateService.swift     # API курсов с retry + fallback
│   ├── AnalyticsService.swift        # Firebase Analytics (20+ типов событий)
│   ├── NotificationManager.swift     # Push-уведомления + weekly digest scheduling
│   ├── HapticManager.swift           # Тактильная обратная связь
│   ├── CSVExporter.swift             # Экспорт в CSV
│   ├── KeychainService.swift         # Secure storage (токены, FCM)
│   ├── AppLogger.swift               # os.Logger (data/ai/auth/network)
│   ├── DateFormatters.swift          # Кэш статических DateFormatter
│   ├── NetworkMonitor.swift          # Мониторинг подключения к сети
│   ├── OfflineQueue.swift            # Очередь операций при отсутствии сети
│   ├── PersistenceManager.swift      # Локальное хранение (JSON encode/decode)
│   ├── SubscriptionDateEngine.swift  # Расчёт дат подписок (billing period, next payment)
│   ├── SubscriptionMatcher.swift     # Авто-сопоставление транзакций с подписками
│   ├── JournalPhotoUploader.swift    # Загрузка фото в Supabase Storage (resize, JPEG)
│   └── AppDelegate.swift             # Firebase init, Google Sign-In, FCM
│
├── Repositories/                     # Data access (все Sendable)
│   ├── TransactionRepository.swift   # CRUD + RPC роутинг для auto-transfer триплетов
│   ├── AccountRepository.swift
│   ├── BudgetRepository.swift
│   ├── CategoryRepository.swift
│   ├── SavingsGoalRepository.swift
│   ├── SavingsChallengeRepository.swift
│   ├── SubscriptionTrackerRepository.swift
│   ├── AchievementRepository.swift
│   ├── AssetRepository.swift         # Активы
│   ├── LiabilityRepository.swift     # Долги
│   ├── NetWorthSnapshotRepository.swift # История net worth (UNIQUE по дате)
│   ├── SettlementRepository.swift    # Закрытые расчёты
│   ├── UserAccountDefaultsRepository.swift # Дефолтный source per account
│   ├── AiRepository.swift            # AI edge functions + invokeWithAuthRetry
│   ├── FinancialNoteRepository.swift # Журнал CRUD + fetchAllTags
│   ├── ProfileRepository.swift
│   ├── NotificationRepository.swift
│   └── FeatureFlagRepository.swift
│
├── ViewModels/                       # @Observable @MainActor
│   ├── AppViewModel.swift            # Root state coordinator + journalViewModel
│   ├── AssistantViewModel.swift      # AI чат + голос + rate limiting
│   ├── AnalyticsViewModel.swift      # Аналитика по периодам
│   ├── BudgetsViewModel.swift        # Управление бюджетами
│   ├── SavingsViewModel.swift        # Цели накоплений
│   ├── SavingsChallengesViewModel.swift # Челленджи
│   ├── SubscriptionsViewModel.swift  # Подписки
│   ├── AchievementsViewModel.swift   # Достижения и уровни
│   ├── ReportsViewModel.swift        # Отчёты (name-based category merge для shared accounts)
│   ├── TransactionsViewModel.swift   # Фильтры, поиск
│   ├── JournalViewModel.swift        # Журнал: CRUD, tags, caching, hiddenTags
│   ├── SettlementViewModel.swift     # Facade над SettlementCalculator
│   ├── PaymentDefaultsViewModel.swift # Per-shared-account дефолтный source
│   ├── NetWorthViewModel.swift       # Net worth + snapshot auto-capture
│   └── HomeViewModel.swift           # Home tab
│
├── Views/
│   ├── Root/
│   │   ├── ContentView.swift         # Auth router + MainTabView + AppTab enum
│   │   ├── OnboardingView.swift      # Онбординг новых пользователей
│   │   └── SplashView.swift          # Splash screen
│   ├── Home/
│   │   ├── HomeTabView.swift         # Счета, savings, инсайты, streak
│   │   ├── AccountCarouselView.swift # Карусель с frosted glass
│   │   ├── AccountFormView.swift     # Создание/редактирование счёта
│   │   ├── ShareAccountView.swift    # Общие счета
│   │   ├── SummaryCardsView.swift    # Доходы/расходы карточки
│   │   ├── InsightCardsView.swift    # Умные инсайты (swipeable)
│   │   ├── HomeSavingsSnapshotView.swift # Превью целей накоплений
│   │   ├── RecentTransactionsView.swift
│   │   └── StreakBadgeView.swift      # Streak активности
│   ├── Transactions/
│   │   ├── TransactionsTabView.swift  # Список транзакций + фильтры
│   │   ├── TransactionFormView.swift  # Форма + «Оплачено с» picker + onboarding banner + cross-currency FX hint
│   │   ├── TransactionDetailView.swift # Детали + auto-transfer бейдж + edit/delete
│   │   ├── TransactionRowView.swift   # Capsule «Из X» badge для auto-transfer
│   │   ├── TransferFormView.swift     # Переводы между счетами
│   │   ├── CategoryPickerView.swift
│   │   ├── SearchView.swift           # Глобальный поиск
│   │   ├── TransactionSearchView.swift # Поиск транзакций
│   │   └── TransactionsMiniDashboardView.swift # Мини-дашборд
│   ├── Analytics/
│   │   ├── AnalyticsTabView.swift     # Портфель, тренды, категории
│   │   ├── CashflowTrendView.swift    # Тренд доходов/расходов (6 мес)
│   │   ├── CashflowChartView.swift    # Bar chart денежного потока
│   │   ├── CashFlowForecastView.swift # Прогноз денежного потока
│   │   ├── CategoryBreakdownView.swift # Donut chart по категориям
│   │   ├── PortfolioChartView.swift   # Портфель счетов
│   │   ├── MonthlySummaryView.swift
│   │   ├── DailyLimitWidgetView.swift # Рекомендуемый расход на день
│   │   └── WidgetFilterView.swift     # Фильтр по периодам
│   ├── Reports/
│   │   └── ReportsView.swift          # Отчёты: donut chart + category list + detail sheet
│   ├── Budgets/
│   │   ├── BudgetsTabView.swift       # Бюджеты + подписки
│   │   ├── BudgetFormView.swift       # Создание/редактирование
│   │   ├── BudgetCardView.swift       # Карточка с прогрессом
│   │   └── BudgetHealthSummaryView.swift # Сводка здоровья бюджетов
│   ├── Savings/
│   │   ├── SavingsGoalListView.swift
│   │   ├── SavingsGoalDetailView.swift
│   │   ├── SavingsGoalFormView.swift
│   │   ├── SavingsGoalCardView.swift
│   │   └── ContributionSheetView.swift
│   ├── Journal/ (BETA, скрыт из UI)
│   │   ├── JournalTabView.swift       # Список заметок + фильтры + pull-to-refresh
│   │   ├── JournalNoteFormView.swift   # Unified форма (Note + Reflection)
│   │   ├── JournalNoteDetailView.swift # Детали + ReflectionPeriodCard
│   │   ├── JournalNoteCardView.swift   # 3 варианта карточек
│   │   ├── JournalReflectionFormView.swift # Wrapper для Reflection
│   │   ├── JournalPhotoViewer.swift   # Full-screen photo viewer (pinch-zoom)
│   │   ├── JournalSharedComponents.swift # TypePill, TagFilterSheet, SuggestionChip
│   │   └── TransactionPickerSheet.swift  # Выбор транзакции для привязки
│   ├── Assistant/
│   │   ├── AssistantView.swift        # Полноэкранный AI чат
│   │   ├── MessageBubbleView.swift
│   │   ├── MarkdownBlockView.swift    # Рендеринг markdown в сообщениях
│   │   ├── QuickPromptsView.swift     # Быстрые подсказки
│   │   ├── ActionPreviewSheet.swift   # Preview→confirm действий
│   │   └── EvidenceCardView.swift     # Heatmap аномалий
│   ├── Auth/
│   │   ├── LoginView.swift            # Apple/Google/Email sign in
│   │   ├── EmailAuthView.swift        # Email регистрация/вход
│   │   ├── ForgotPasswordView.swift   # Сброс пароля
│   │   ├── AuthComponents.swift       # Shared auth UI components
│   │   └── MigrationCodeView.swift    # Миграция из Telegram
│   ├── Settings/
│   │   ├── SettingsView.swift         # Все настройки + BETA-бейджи для Reports/Challenges
│   │   ├── ProfileEditView.swift      # Редактирование профиля + аватар
│   │   ├── CategoriesManagementView.swift
│   │   ├── TagManagementView.swift    # Управление тегами журнала
│   │   ├── PaymentDefaultsView.swift  # Дефолт source per shared-account
│   │   ├── AISettingsView.swift       # Настройки AI ассистента
│   │   ├── NotificationSettingsView.swift # Настройки уведомлений
│   │   ├── BankImportView.swift       # Импорт PDF + dedup vs auto-transfer
│   │   ├── ExportView.swift           # CSV экспорт
│   │   ├── CurrencyReconciliationView.swift # ADR-001 Phase 4: audit legacy cross-currency rows
│   │   └── PremiumPaywallView.swift   # Paywall
│   ├── Subscriptions/
│   │   ├── SubscriptionListView.swift # Список подписок
│   │   └── SubscriptionPaymentsHistoryView.swift # История платежей
│   ├── Shared/
│   │   ├── FAB/
│   │   │   └── CategorySheetView.swift # Grid/list выбор категорий
│   │   ├── FABView.swift              # Плавающая кнопка + arc menu + wheel
│   │   ├── FilterHeaderView.swift     # Переиспользуемые filter chips
│   │   ├── SwipeableRow.swift         # Swipe-to-action строки
│   │   ├── CachedAsyncImage.swift     # Image cache (NSCache + disk, 50 MB)
│   │   ├── CurrencyText.swift         # Форматированный текст суммы
│   │   ├── CalculatorKeyboardView.swift
│   │   ├── HorizontalSwipeGesture.swift # UIKit pan gesture для swipe
│   │   ├── SubscriptionMatchBanner.swift # Баннер авто-привязки подписки
│   │   ├── AppHeaderView.swift
│   │   ├── LoadingView.swift
│   │   ├── ReceiptScannerView.swift
│   │   ├── WelcomeOverlayView.swift
│   │   └── EmptyStateView.swift
│   ├── Spotlight/
│   │   ├── SpotlightStep.swift        # Онбординг-подсветка элементов
│   │   ├── SpotlightOverlayView.swift
│   │   ├── SpotlightModifier.swift    # .spotlight() ViewModifier
│   │   └── SpotlightManager.swift
│   ├── Achievements/
│   │   ├── AchievementsView.swift     # Уровни и достижения
│   │   ├── AchievementBadgeView.swift # Бейдж с прогресс-кольцом
│   │   ├── StreakMilestoneView.swift  # Celebration на 7/14/30/60/100/180/365 дней
│   │   ├── SkillTreeView.swift        # Дерево навыков (MVP grid)
│   │   └── LevelUpView.swift          # Celebration popup
│   ├── Account/
│   │   ├── SharedAccountDetailView.swift     # Hero + settlement + transactions
│   │   └── AccountSettlementCardView.swift   # Карточка «Кто кому должен» с weights
│   ├── NetWorth/
│   │   ├── NetWorthDashboardView.swift # Hero + breakdown + history chart
│   │   ├── AssetListView.swift         # Sectioned by category, swipe-to-delete
│   │   ├── AssetFormView.swift         # Create/edit актива
│   │   ├── LiabilityListView.swift     # Sectioned by category
│   │   └── LiabilityFormView.swift     # Create/edit долга
│   └── Challenges/ (BETA, в Settings)
│       ├── ChallengesListView.swift    # Active/completed секции
│       ├── ChallengeDetailView.swift   # Прогресс + abandon/delete
│       ├── ChallengeFormView.swift     # 4 типа + target + duration
│       └── ChallengeCardView.swift     # Компакт-карточка
│
├── Extensions/
│   ├── Color+Hex.swift               # Hex → Color
│   ├── Color+Theme.swift             # Адаптивные цвета темы
│   ├── Date+Formatting.swift         # ISO, display, fromISO
│   ├── Decimal+Currency.swift        # Kopecks → display amount
│   ├── KeyedDecodingContainer+Amount.swift # Единый decodeKopecks()
│   └── String+Nonce.swift            # Nonce для Apple Sign In
│
├── Localization/
│   └── Localizable.xcstrings         # 1000+ ключей, 3 языка (RU/EN/ES)
│
├── Assets.xcassets/
│   ├── AppIcon.appiconset
│   ├── AkifiLogo.imageset
│   └── GoogleLogo.imageset
│
└── Preview Content/
    ├── DemoData.swift                # Demo-данные для новых пользователей
    └── PreviewData.swift             # Preview fixtures
```

## Основные функции

### Финансы
- **Мультисчета** — карусель с круговой прокруткой, frosted glass эффект, стек-подложки
- **Транзакции** — CRUD с категориями, описанием, датой+временем, мультивалютой
- **Переводы** между счетами с group tracking
- **Общие счета** — бейдж "Общая", аватары участников, роли (owner/editor/viewer), корректный merge категорий в отчётах
- **Мультивалюта (ADR-001)** — `amount_native` в валюте счёта как канон, `foreign_amount`/`foreign_currency`/`fx_rate` для оригинального ввода; FX-нормализация только на финальной агрегации

### Multi-currency архитектура (ADR-001)

Core invariant: для каждой транзакции `amount_native` хранится **в валюте её счёта**. Аккумулирование по нескольким счетам с разными валютами (ByBit USD + Семейный RUB) проходит через `TransactionMath.amountInBase(tx, accountsById, fxRates, baseCode)`. Это единственный способ сравнивать USD-транзакции с рублёвыми в едином виде.

Ввод в чужой валюте:
- Юзер выбирает счёт Семейный (RUB), вводит 500 000 и переключает currency picker на VND
- `amount_native = 500 000 × FX(VND→RUB) = 1 900₽` (в валюте счёта)
- `foreign_amount = 500 000`, `foreign_currency = VND`, `fx_rate = 0.0038`
- Баланс счёта считается через `amount_native`; UI показывает оригинальный ввод через `foreign_*`

Отображение в формах:
- **Edit Account** — поле баланса всегда в валюте счёта, справа preview «≈ X base»
- **Transaction Form** — currency picker рядом с amount; при валюте ≠ account.currency создаётся foreign_* triplet
- **Reconciliation UI** (Settings → Проверка валют) — для легaсy TMA-rows где стояла кривая `currency` label; три действия: keep as account ccy / reinterpret as label / delete

DB layer:
- `transactions.amount_native` NUMERIC NOT NULL (CHECK)
- `transactions.foreign_amount` / `foreign_currency` / `fx_rate` NULLABLE
- Trigger `transactions_fill_amount_native` BEFORE INSERT/UPDATE — legacy клиенты без поля пишут amount_native = amount
- RPC overloads: `create_expense_with_auto_transfer` (8/10/13-arg), `update_expense_with_auto_transfer` (6/9-arg)
- Feature flag `multi_currency_v2` в UserDefaults + DEBUG toggle в Settings → Developer

### Общие счета — Payment Source + Settlement (Phase 4.6)
- **«Оплачено с»** в форме транзакции — выбрать личную карту-источник при расходе на общем счёте. Система автоматически создаёт триплет (expense + transfer-out + transfer-in) через атомарную Postgres RPC
- **Cross-currency** — ByBit (USD) может быть источником для Семейный (RUB). Picker показывает FX-preview «(≈ 2,63 $)», transfer-out записывается в валюте source, expense + transfer-in в target
- **Per-user дефолты** — запоминаем выбранный source для каждого shared-счёта (`user_account_defaults`), ⭐ в picker'е для one-tap
- **Custom split weights** — `account_members.split_weight` задаёт долю каждого участника (60/40 вместо 50/50). Редактируется в экране редактирования счёта → «Участники и доли»
- **Settlement card** на детальной странице shared-счёта — «кто кому должен» с greedy min-cash-flow, period picker (этот месяц/прошлый/квартал/YTD), кнопка «Отметить выполненным» реально закрывает долг через `settlements` таблицу, история с undo
- **Direct-expense attribution** — прямой расход с общего счёта (без auto-transfer) кредитует создателя
- **Orphan cleanup** — кнопка «Очистить историю» когда balances пусты + есть закрытые settlements
- **Onboarding банн­ер** — gradient-подсказка при первом открытии формы с shared-счётом
- **Edit source reassignment** — при редактировании expense можно сменить source, триплет пересоздаётся client-side
- **Bank import dedup** — импорт выписки автоматически помечает коллизии с auto-transfer легами

### Net Worth трекер (Phase 5.2)
- **Активы** — real_estate / vehicle / crypto / investment / collectible / cash / other с иконкой, цветом, notes, acquired_date
- **Долги** — mortgage / loan / credit_card / personal_debt / other с interest_rate, monthly_payment, end_date
- **Dashboard** — hero 32pt (net worth цвет зелёный/красный), breakdown (счета / активы / долги), Swift Charts история за 30/90/180/365 дней
- **Multi-currency** — `NetWorthCalculator` нормализует активы/долги в валюту через FX rates
- **Snapshots** — ежедневный авто-capture net worth в `net_worth_snapshots`, UNIQUE по (user, date)
- **Shortcut на Home** — gradient-карточка с текущим net worth

### Бюджеты
- **Гибкие периоды** — недельные, месячные, квартальные, годовые, произвольные
- **Прогресс-бар** с цветовой индикацией (зелёный → оранжевый → красный)
- **Статусы** — В норме → Внимание → Близко к лимиту → Превышен
- **Rollover** — перенос остатка на следующий период
- **Alert thresholds** — настраиваемые пороги 80%/100%
- **По категориям или счетам**
- **Health summary** — общая сводка здоровья бюджетов

### Цели накоплений
- **Прогресс-кольцо** с визуальным индикатором
- **Процентная ставка** — простой/сложный процент
- **Пополнения/снятия** как внутренние транзакции
- **Дедлайн и напоминания**
- **Pace tracking** — on_track / falling_behind / completed
- **Home snapshot** — компактное превью на главном экране

### Подписки
- **Трекер** с прогресс-баром обратного отсчёта до списания
- **Reminder days** — уведомления за N дней
- **Авто-транзакции** при списании
- **Мультивалюта**
- **Авто-сопоставление** — банковские транзакции привязываются к подпискам (SubscriptionMatcher)
- **История платежей** — отдельный экран с хронологией

### Аналитика
- **Портфель счетов** — цветная полоса-прогресс, список с процентами
- **Тренд доходов/расходов** — 6 месяцев, две кривые, тап-для-тултипа
- **Денежный поток** — bar chart по периодам
- **Прогноз** — CashFlowEngine предсказывает будущие расходы
- **По категориям** — donut chart, сворачиваемый список, тап→sheet с транзакциями
- **Дневной лимит** — рекомендуемый расход на сегодня
- **Summary карточки** — доходы/расходы за текущий месяц

### Отчёты
- **Donut chart** по категориям с иконками на линиях
- **Фильтры** — по счёту, периоду (месяц/квартал/год)
- **Детализация** — тап на категорию → sheet со всеми транзакциями
- **Shared accounts** — категории с одинаковыми именами объединяются для корректных итогов

### Журнал (BETA, скрыт из UI)
- **Два типа записей** — Note (быстрая заметка) и Reflection (структурированная рефлексия с промптами)
- **Mood picker** — emoji-only 44pt circles, accessible
- **Tag system** — inline chip picker, autocomplete, удаление из истории
- **Фото** — upload в Supabase Storage, inline thumbnails, full-screen viewer с pinch-zoom
- **Transaction linking** — привязка заметки к транзакции через searchable picker
- **Reflection** — PeriodCard с income/expense/net/top categories + 4 guided prompts
- **Кэширование** — shared JournalViewModel с 60s TTL

### AI Ассистент
- **Полноэкранный чат** с Supabase Edge Function (assistant-query)
- **Голосовой ввод** — запись через AVAudioRecorder, транскрипция через Whisper
- **Умный fallback** — нераспознанные вопросы направляются в LLM coaching с финансовым контекстом
- **Действия** — создание транзакций, бюджетов, навигация с preview→confirm
- **Smart budget creation** — чекбоксы для выбора предложенных бюджетов
- **Evidence карточки** — аномалии с heatmap и delta bars
- **Обратная связь** — thumbs up/down с причинами
- **История бесед** — до 30 сохранённых, автоархивация
- **Rate limiting** — клиентская защита от спама (2 сек между сообщениями)
- **Сохранение контекста** при переходе между экранами
- **Auth retry** — автоматический refresh + retry при 401, JWT grace period на сервере
- **Quick prompts** — быстрые подсказки для начала диалога

### Умные инсайты
- **InsightEngine** — анализирует транзакции и генерирует персональные советы
- **Swipeable карточки** с UIKit pan gesture
- **Weekly digest** — еженедельная сводка через push-уведомление

### Сканер чеков
- **Камера или галерея** → сжатие до 1800px JPEG
- **AI OCR** через analyze-receipt edge function (OpenAI Vision)
- **Извлечение**: магазин, сумма, валюта, дата, товары
- **Умные подсказки**: история мерчанта, автоопределение категории
- **Подтверждение** → finalize-receipt создаёт транзакцию

### Импорт/Экспорт
- **Импорт банковских выписок** (PDF) — AI парсинг, превью транзакций с чекбоксами, дубликаты
- **Экспорт CSV** — фильтр по датам и счетам

### Геймификация
- **10 уровней**: Новичок → Ученик → Финансист → ... → Магнат
- **Достижения** — 9 категорий, 4 тира (bronze/silver/gold/diamond)
- **Celebration popup** — emoji-конфетти, tier-градиенты, count-up очков, haptic feedback
- **Прогресс-кольца** на бейджах

### Push-уведомления (серверные через FCM)
- **Budget warning** — при достижении 80%/100% лимита
- **Large expense** — крупный расход выше порога
- **Savings milestone** — 25/50/75/100% цели
- **Inactivity reminder** — нет транзакций >3 дня
- **Weekly pace** — темп расходов >120% бюджета
- **Subscription reminder** — N дней до списания
- **Weekly digest** — еженедельная сводка
- **Настройки** синхронизируются с сервером

### Другое
- **Аватар** — PhotosPicker, сжатие, Supabase Storage
- **Spotlight онбординг** — пошаговая подсветка UI-элементов для новых пользователей
- **Удаление аккаунта** — двухшаговое подтверждение, edge function (App Store compliance)
- **Тактильный отклик** — haptic на таббар, FAB, достижения (отключаемый)
- **Тёмная тема** — адаптивные цвета на всех экранах
- **Portrait** на iPhone, все ориентации на iPad
- **Offline indicator** — баннер при потере сети
- **Network monitor** — NWPathMonitor для отслеживания состояния сети

## Локализация

1000+ ключей на 3 языка:
- Русский (основной)
- English
- Español

Выбор языка: Настройки → Язык (системный / ручной)

## Зависимости

Все пакеты через Swift Package Manager:

| Пакет | Версия | Назначение |
|-------|--------|-----------|
| supabase-swift | 2.43+ | REST/realtime клиент, auth, storage, functions |
| firebase-ios-sdk | 11.0.0+ | Analytics, Crashlytics, FCM, Performance |
| GoogleSignIn-iOS | 8.0.0+ | OAuth для Google Sign-In |

Встроенные фреймворки: SwiftUI, Swift Charts, AVFoundation, PhotosUI, AuthenticationServices, CoreHaptics, Network.

## Firebase

| Сервис | Назначение |
|--------|-----------|
| Analytics | 18 типов событий (auth, transactions, budgets, savings, AI, scanner, import/export, settings, screens) |
| Crashlytics | Автоматический сбор крашей |
| Cloud Messaging | Push-уведомления через FCM + APNs |
| Performance | Мониторинг скорости |

## Supabase

### Таблицы
`profiles`, `accounts`, `account_members`, `transactions` (+ ADR-001: `amount_native`/`foreign_amount`/`foreign_currency`/`fx_rate`), `categories`, `budgets`, `budget_rollovers`, `budget_alerts`, `savings_goals`, `savings_contributions`, `savings_challenges`, `subscriptions`, `subscription_reminder_events`, `subscription_charge_events`, `achievements`, `user_achievements`, `ai_conversations`, `ai_messages`, `ai_feedback`, `ai_action_runs`, `ai_user_settings`, `notification_settings`, `notification_log`, `receipt_scans`, `migration_codes`, `financial_notes`, `assets`, `liabilities`, `net_worth_snapshots`, `deposits`, `deposit_contributions`, `settlements`, `user_account_defaults`

### RPC функции
- `create_expense_with_auto_transfer` (8/10/13-arg overloads) — атомарное создание expense + transfer triplet, с cross-currency source и foreign-entry поддержкой
- `update_expense_with_auto_transfer` (6/9-arg overloads) — синхронизированный update триплета + foreign_* fields
- `delete_expense_with_auto_transfer` — atomic delete всех трёх row'ов триплета

### Triggers
- `transactions_fill_amount_native` BEFORE INSERT/UPDATE — ADR-001 compat для legacy клиентов

### Storage Buckets
- `avatars` — аватары пользователей (public)
- `journal-photos` — фото журнала (public, 5MB limit, JPEG/PNG/HEIC/WebP, RLS по user_id)

### Edge Functions

| Функция | Назначение |
|---------|-----------|
| `assistant-query` | AI-ассистент (intent classification + coaching LLM), --no-verify-jwt + JWT grace period |
| `assistant-action` | Действия ассистента (preview/confirm) |
| `transcribe-voice` | Голосовая транскрипция (Whisper) |
| `analyze-receipt` | OCR чеков (OpenAI Vision) |
| `finalize-receipt` | Создание транзакции из чека |
| `parse-bank-statement` | Парсинг PDF выписок |
| `import-bank-statement` | Импорт транзакций из выписки |
| `smart-notifications` | Серверные push (FCM + Telegram) |
| `coaching-reminders` | Коучинговые напоминания |
| `check-subscriptions` | Напоминания о подписках + авто-транзакции |
| `send-weekly-digest` | Еженедельная сводка |
| `ios-migrate-auth` | Миграция из Telegram |
| `delete-account` | Удаление аккаунта (Apple compliance) |

### RLS
Все таблицы защищены Row Level Security. Данные фильтруются по `user_id`. Shared accounts имеют отдельные policies для чтения данных участников.

## Установка и запуск

### Требования
- macOS 15+ с Xcode 16+
- iOS 18.0+ симулятор или устройство
- XcodeGen (`brew install xcodegen`)
- Supabase проект
- Firebase проект с GoogleService-Info.plist

### Шаги

```bash
# 1. Клонировать
git clone https://github.com/Ozenforwin/akifi-ios.git
cd akifi-ios

# 2. Конфиг
cp Config/Config.xcconfig.template Config/Debug.xcconfig
cp Config/Config.xcconfig.template Config/Release.xcconfig
# Заполнить SUPABASE_URL и SUPABASE_ANON_KEY

# 3. Firebase
# Положить GoogleService-Info.plist в AkifiIOS/

# 4. Генерация проекта
xcodegen generate

# 5. Открыть и собрать
open AkifiIOS.xcodeproj
# Xcode подтянет SPM зависимости
# Cmd+R для запуска
```

## App Store Compliance

- Sign in with Apple
- Account deletion (двухшаговое подтверждение)
- Privacy Manifest (PrivacyInfo.xcprivacy)
- NSCameraUsageDescription, NSMicrophoneUsageDescription, NSPhotoLibraryUsageDescription
- Portrait-only iPhone + all orientations iPad
- Privacy Policy & Terms of Service ссылки
- Push Notifications (aps-environment, remote-notification background mode)
- ITSAppUsesNonExemptEncryption: false

## Безопасность

- TLS 1.2+ для всех сетевых запросов
- Keychain для токенов аутентификации и FCM
- API ключи через .xcconfig (не в коде)
- SHA256 nonce для Sign in with Apple
- RLS на всех таблицах Supabase
- Клиентский rate limiting для AI-чата
- Retry с exponential backoff для внешних API
- JWT grace period (2h) на edge functions для expired tokens
- Proactive session refresh при возврате из background

## Дизайн

- **Frosted glass** — `.ultraThinMaterial` на карточках счетов
- **SF Symbols** — нативные иконки повсюду
- **Tier градиенты** — bronze/silver/gold/diamond для достижений
- **Адаптивные цвета** — `secondarySystemGroupedBackground` для dark mode
- **Стек-карточки** — peek-эффект за активной карточкой
- **Emoji конфетти** — particle system для celebration popup
- **Скруглённый таббар** — 24pt radius, тень, 44pt touch targets
- **FAB** — floating action button с arc menu (long press) и wheel/grid/list (tap)
- **TypePill** — inline capsule для типов записей (Note/Reflection)
- **CachedAsyncImage** — двухуровневый кэш (NSCache + disk SHA256)

## Лицензия

Proprietary. All rights reserved.
