# Akifi iOS

Нативное iOS-приложение для управления личными финансами. Построено на SwiftUI с бэкендом Supabase и Firebase. Работает параллельно с Telegram Mini App версией Akifi.

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
| Локализация | 3 языка: Русский, English, Español (470+ ключей) |
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
- `AuthManager` — аутентификация (Apple, Google, Email, Telegram migration)
- `CurrencyManager` — курсы валют, форматирование, конвертация
- `PaymentManager` — проверка Premium статуса
- `DataStore` — shared хранилище с параллельной загрузкой (`async let`) и предвычисленными кэшами (balance, income/expense по счетам, category index)
- `ThemeManager` — тема оформления

Инжектируется через `.environment(appViewModel)` из `AkifiApp.swift`.

### Ключевые паттерны

- **Типизированная навигация** — `AppTab` enum вместо raw Int для tab bar и Spotlight
- **Sheet Coordinator** — единый `SheetDestination` enum для управления модальными экранами
- **Единый декодер** — `KeyedDecodingContainer.decodeKopecks(forKey:)` для числовых сумм из БД
- **Кэшированные форматтеры** — `AppDateFormatters` со static lazy свойствами
- **Структурированное логирование** — `AppLogger` через `os.Logger` с категориями (data, ai, auth, network)
- **Concurrency** — Task-based таймеры, async/await повсюду, Sendable репозитории

## Структура проекта

```
AkifiIOS/
├── AkifiApp.swift                    # Entry point, Firebase init
├── AppConstants.swift                # Config из Info.plist (Supabase URL/Key)
├── Info.plist                        # Permissions, URL schemes
├── AkifiIOS.entitlements             # Apple Sign In, APNs
├── PrivacyInfo.xcprivacy             # Privacy manifest
│
├── Models/
│   ├── Transaction.swift             # Транзакции (income/expense/transfer)
│   ├── Account.swift                 # Банковские счета
│   ├── Budget.swift                  # Бюджеты (weekly/monthly/custom)
│   ├── Category.swift                # Категории расходов/доходов
│   ├── SavingsGoal.swift             # Цели накоплений + проценты
│   ├── Subscription.swift            # Трекер подписок
│   ├── Achievement.swift             # Достижения (9 категорий, 4 тира)
│   ├── AssistantModels.swift         # AI request/response + AnyCodableValue
│   ├── AiConversation.swift          # AI чат-сессии
│   ├── Profile.swift                 # Профиль пользователя
│   ├── ReceiptScan.swift             # Данные OCR чека
│   ├── ExchangeRates.swift           # Курсы валют
│   ├── NotificationSettings.swift    # Настройки уведомлений
│   └── UserSubscription.swift        # Premium статус
│
├── Services/
│   ├── AuthManager.swift             # Auth: Apple/Google/Email/Telegram
│   ├── SupabaseManager.swift         # Singleton Supabase client
│   ├── DataStore.swift               # Shared state + параллельная загрузка
│   ├── CurrencyManager.swift         # Мультивалюта, курсы, форматирование
│   ├── PaymentManager.swift          # Premium-подписка
│   ├── ThemeManager.swift            # Тема (light/dark)
│   ├── BudgetMath.swift              # Вычисление метрик бюджетов
│   ├── CalculatorState.swift         # Калькулятор (locale-aware)
│   ├── ExchangeRateService.swift     # API курсов с retry + fallback
│   ├── AnalyticsService.swift        # Firebase Analytics (18 типов событий)
│   ├── NotificationManager.swift     # Push-уведомления
│   ├── HapticManager.swift           # Тактильная обратная связь
│   ├── CSVExporter.swift             # Экспорт в CSV
│   ├── KeychainService.swift         # Secure storage (токены, FCM)
│   ├── AppLogger.swift               # os.Logger (data/ai/auth/network)
│   ├── DateFormatters.swift          # Кэш статических DateFormatter
│   └── AppDelegate.swift             # Firebase init, Google Sign-In, FCM
│
├── Repositories/                     # Data access (все Sendable)
│   ├── TransactionRepository.swift
│   ├── AccountRepository.swift
│   ├── BudgetRepository.swift
│   ├── CategoryRepository.swift
│   ├── SavingsGoalRepository.swift
│   ├── SubscriptionTrackerRepository.swift
│   ├── AchievementRepository.swift
│   ├── AiRepository.swift            # AI edge functions
│   ├── ProfileRepository.swift
│   ├── NotificationRepository.swift
│   └── FeatureFlagRepository.swift
│
├── ViewModels/                       # @Observable @MainActor
│   ├── AppViewModel.swift            # Root state coordinator
│   ├── AssistantViewModel.swift      # AI чат + голос + rate limiting
│   ├── AnalyticsViewModel.swift      # Аналитика по периодам
│   ├── BudgetsViewModel.swift        # Управление бюджетами
│   ├── SavingsViewModel.swift        # Цели накоплений
│   ├── SubscriptionsViewModel.swift  # Подписки
│   ├── AchievementsViewModel.swift   # Достижения и уровни
│   ├── ReportsViewModel.swift        # Отчёты
│   ├── TransactionsViewModel.swift   # Фильтры, поиск
│   └── HomeViewModel.swift           # Home tab
│
├── Views/
│   ├── Root/
│   │   └── ContentView.swift         # Auth router + MainTabView + AppTab enum
│   ├── Home/
│   │   ├── HomeTabView.swift         # Счета, саммари, инсайты
│   │   ├── AccountCarouselView.swift # Карусель с frosted glass
│   │   ├── AccountFormView.swift     # Создание/редактирование счёта
│   │   ├── ShareAccountView.swift    # Общие счета
│   │   ├── SummaryCardsView.swift    # Доходы/расходы карточки
│   │   ├── InsightCardsView.swift    # Умные инсайты
│   │   ├── RecentTransactionsView.swift
│   │   └── StreakBadgeView.swift     # Streak активности
│   ├── Transactions/
│   │   ├── TransactionsTabView.swift # Список транзакций + фильтры
│   │   ├── TransactionFormView.swift # Создание с калькулятором
│   │   ├── TransactionRowView.swift
│   │   ├── TransferFormView.swift    # Переводы между счетами
│   │   └── CategoryPickerView.swift
│   ├── Analytics/
│   │   ├── AnalyticsTabView.swift    # Портфель, тренды, категории
│   │   ├── CashflowTrendView.swift   # Денежный поток
│   │   ├── CategoryBreakdownView.swift # Donut chart по категориям
│   │   ├── MonthlySummaryView.swift
│   │   └── WidgetFilterView.swift    # Фильтр по периодам
│   ├── Budgets/
│   │   ├── BudgetsTabView.swift      # Бюджеты + подписки
│   │   ├── BudgetFormView.swift      # Создание/редактирование
│   │   └── BudgetCardView.swift      # Карточка с прогрессом
│   ├── Savings/
│   │   ├── SavingsGoalListView.swift
│   │   ├── SavingsGoalDetailView.swift
│   │   ├── SavingsGoalFormView.swift
│   │   └── ContributionSheetView.swift
│   ├── Assistant/
│   │   ├── AssistantView.swift       # Полноэкранный AI чат
│   │   ├── MessageBubbleView.swift
│   │   ├── ActionPreviewSheet.swift  # Preview→confirm действий
│   │   └── EvidenceCardView.swift    # Heatmap аномалий
│   ├── Auth/
│   │   ├── LoginView.swift           # Apple/Google/Email sign in
│   │   ├── EmailAuthView.swift       # Email регистрация/вход
│   │   ├── MigrationCodeView.swift   # Миграция из Telegram
│   │   ├── OnboardingView.swift      # Онбординг новых пользователей
│   │   └── SplashView.swift
│   ├── Settings/
│   │   ├── SettingsView.swift        # Все настройки
│   │   ├── ProfileEditView.swift     # Редактирование профиля
│   │   ├── CategoriesManagementView.swift
│   │   ├── BankImportView.swift      # Импорт PDF выписок
│   │   ├── ExportView.swift          # CSV экспорт
│   │   └── PremiumPaywallView.swift  # Paywall
│   ├── Shared/
│   │   ├── FAB/
│   │   │   └── CategorySheetView.swift # Grid/list выбор категорий
│   │   ├── FABView.swift             # Плавающая кнопка + arc menu + wheel
│   │   ├── SwipeableRow.swift        # Swipe-to-action строки
│   │   ├── CachedAsyncImage.swift    # Image cache (50 MB limit)
│   │   ├── CalculatorKeyboardView.swift
│   │   ├── WelcomeOverlayView.swift
│   │   └── EmptyStateView.swift
│   ├── Spotlight/
│   │   ├── SpotlightStep.swift       # Онбординг-подсветка элементов
│   │   ├── SpotlightOverlayView.swift
│   │   └── SpotlightManager.swift
│   └── Achievements/
│       └── AchievementsView.swift    # Уровни и достижения
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
│   └── Localizable.xcstrings         # 470+ ключей, 3 языка
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
- **Общие счета** — бейдж "Общая", аватары участников, роли (owner/editor/viewer)
- **Мультивалюта** — курсы в реальном времени, конвертация отображения

### Бюджеты
- **Гибкие периоды** — недельные, месячные, квартальные, годовые, произвольные
- **Прогресс-бар** с цветовой индикацией (зелёный → оранжевый → красный)
- **Статусы** — В норме → Внимание → Близко к лимиту → Превышен
- **Rollover** — перенос остатка на следующий период
- **Alert thresholds** — настраиваемые пороги 80%/100%
- **По категориям или счетам**

### Цели накоплений
- **Прогресс-кольцо** с визуальным индикатором
- **Процентная ставка** — простой/сложный процент
- **Пополнения/снятия** как внутренние транзакции
- **Дедлайн и напоминания**
- **Pace tracking** — on_track / falling_behind / completed

### Подписки
- **Трекер** с прогресс-баром обратного отсчёта до списания
- **Reminder days** — уведомления за N дней
- **Авто-транзакции** при списании
- **Мультивалюта**

### Аналитика
- **Портфель счетов** — цветная полоса-прогресс, список с процентами
- **Тренд доходов/расходов** — 6 месяцев, две кривые, тап-для-тултипа
- **Денежный поток** — bar chart по периодам
- **По категориям** — donut chart, сворачиваемый список, тап→sheet с транзакциями
- **Дневной лимит** — рекомендуемый расход на сегодня
- **Summary карточки** — доходы/расходы за текущий месяц

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
- **Настройки** синхронизируются с сервером

### Другое
- **Аватар** — PhotosPicker, сжатие, Supabase Storage
- **Spotlight онбординг** — пошаговая подсветка UI-элементов для новых пользователей
- **Удаление аккаунта** — двухшаговое подтверждение, edge function (App Store compliance)
- **Тактильный отклик** — haptic на таббар, FAB, достижения (отключаемый)
- **Тёмная тема** — адаптивные цвета на всех экранах
- **Portrait** на iPhone, все ориентации на iPad

## Локализация

470+ ключей на 3 языка:
- Русский (основной)
- English
- Español

Выбор языка: Настройки → Язык (системный / ручной)

## Зависимости

Все пакеты через Swift Package Manager:

| Пакет | Версия | Назначение |
|-------|--------|-----------|
| supabase-swift | 2.43+ | REST/realtime клиент, auth |
| firebase-ios-sdk | 11.0.0+ | Analytics, Crashlytics, FCM, Performance |
| GoogleSignIn-iOS | 8.0.0+ | OAuth для Google Sign-In |

Встроенные фреймворки: SwiftUI, Swift Charts, AVFoundation, PhotosUI, AuthenticationServices, CoreHaptics.

## Firebase

| Сервис | Назначение |
|--------|-----------|
| Analytics | 18 типов событий (auth, transactions, budgets, savings, AI, scanner, import/export, settings, screens) |
| Crashlytics | Автоматический сбор крашей |
| Cloud Messaging | Push-уведомления через FCM + APNs |
| Performance | Мониторинг скорости |

## Supabase

### Таблицы
`profiles`, `accounts`, `account_members`, `transactions`, `categories`, `budgets`, `budget_rollovers`, `budget_alerts`, `savings_goals`, `savings_contributions`, `subscriptions`, `subscription_reminder_events`, `subscription_charge_events`, `achievements`, `user_achievements`, `ai_conversations`, `ai_messages`, `ai_feedback`, `ai_action_runs`, `ai_user_settings`, `notification_settings`, `notification_log`, `receipt_scans`, `migration_codes`

### Edge Functions

| Функция | Назначение |
|---------|-----------|
| `assistant-query` | AI-ассистент (intent classification + coaching LLM) |
| `assistant-action` | Действия ассистента (preview/confirm) |
| `transcribe-voice` | Голосовая транскрипция (Whisper) |
| `analyze-receipt` | OCR чеков (OpenAI Vision) |
| `finalize-receipt` | Создание транзакции из чека |
| `parse-bank-statement` | Парсинг PDF выписок |
| `import-bank-statement` | Импорт транзакций из выписки |
| `smart-notifications` | Серверные push (FCM + Telegram) |
| `check-subscriptions` | Напоминания о подписках + авто-транзакции |
| `ios-migrate-auth` | Миграция из Telegram |
| `delete-account` | Удаление аккаунта (Apple compliance) |

### RLS
Все таблицы защищены Row Level Security. Данные фильтруются по `user_id`.

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

## Дизайн

- **Frosted glass** — `.ultraThinMaterial` на карточках счетов
- **SF Symbols** — нативные иконки повсюду
- **Tier градиенты** — bronze/silver/gold/diamond для достижений
- **Адаптивные цвета** — `secondarySystemGroupedBackground` для dark mode
- **Стек-карточки** — peek-эффект за активной карточкой
- **Emoji конфетти** — particle system для celebration popup
- **Скруглённый таббар** — 24pt radius, тень, 44pt touch targets
- **FAB** — floating action button с arc menu (long press) и wheel/grid/list (tap)

## Лицензия

Proprietary. All rights reserved.
