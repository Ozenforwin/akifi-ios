# Akifi iOS

Нативное iOS-приложение для управления личными финансами. Построено на SwiftUI с бэкендом Supabase. Работает параллельно с Telegram Mini App версией Akifi.

## Tech Stack

| Компонент | Технология |
|-----------|-----------|
| Язык | Swift 6 (strict concurrency) |
| UI | SwiftUI (iOS 18+) |
| Min Deployment | iOS 18.0 |
| IDE | Xcode 16+ |
| Backend | Supabase (supabase-swift v2.43+) |
| Графики | Swift Charts (нативный) |
| Auth | Sign in with Apple, Email/Password, Telegram migration |
| Project Gen | XcodeGen (project.yml) |

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
│              SupabaseManager                 │
│         (Sendable singleton client)          │
└─────────────────────────────────────────────┘
```

### Data Flow

`AppViewModel` (root) владеет:
- `AuthManager` — аутентификация (Apple, Email, Telegram migration)
- `CurrencyManager` — курсы валют, форматирование сумм
- `PaymentManager` — проверка Premium статуса
- `DataStore` — shared хранилище accounts/transactions/categories с кэшированием

Инжектируется через `.environment(appViewModel)` из `AkifiApp.swift`.

### State Management

| Wrapper | Использование |
|---------|--------------|
| `@Observable` | ViewModels, Services (property-level tracking) |
| `@State` | View-local ViewModels, UI state |
| `@Environment` | AppViewModel injection |
| `@Bindable` | Two-way binding к @Observable |
| `@MainActor` | Все ViewModels и Services |

## Фичи

### Core (Фаза 1)
- Мультисчета с иконками-эмодзи и цветами
- Транзакции CRUD (доходы/расходы)
- Карусель счетов с расчётом баланса
- Категории с фильтрацией по типу
- Summary cards (доходы/расходы за период)
- Поиск по транзакциям
- Swipe-to-delete

### Бюджеты и Аналитика (Фаза 2)
- Бюджеты (месяц/квартал/год) с прогресс-барами
- Порог оповещения (зелёный → оранжевый → красный)
- Привязка к категориям и счетам
- Cashflow bar chart (Swift Charts BarMark)
- Category breakdown donut chart (SectorMark)
- Фильтрация по периодам (неделя/месяц/квартал/год)
- Реальные курсы валют (open.er-api.com, кэш 1 час)
- 6 валют: USD, RUB, EUR, GBP, CNY, JPY

### Накопления и Подписки (Фаза 3)
- Цели накоплений с прогресс-кольцом
- Вклады/снятия с историей
- Быстрые чипы (остаток, 50%, 25%)
- Дедлайн с обратным отсчётом
- Автозавершение при достижении цели
- Трекер подписок с месячным итогом
- Управление профилем
- CRUD категорий
- Настройки уведомлений

### AI-ассистент и Достижения (Фаза 4)
- Полноэкранный чат с Supabase Edge Function
- Typing indicator, follow-up подсказки
- История бесед, архивация
- Система достижений (9 категорий, 4 тира)
- Бейджи с прогрессом и очками
- Фильтрация по категориям

### Premium и Онбординг (Фаза 5)
- Premium paywall (Akifi Pro) — StoreKit 2 заглушка в v1
- Проверка статуса через Supabase
- 5-шаговый онбординг (приветствие → валюта → счёт → фичи → завершение)
- Анимированный splash screen
- Секция накоплений на Home

## Структура проекта

```
AkifiIOS/
├── AkifiApp.swift                    # @main, environment setup
├── AppConstants.swift                # Supabase URL/Key из Info.plist
├── AkifiIOS.entitlements             # Sign in with Apple
├── PrivacyInfo.xcprivacy             # App Store privacy manifest
├── Info.plist                        # Конфигурация приложения
│
├── Models/                           # Codable/Sendable structs (13 файлов)
│   ├── Account.swift                 # Account, AccountMember, AccountRole
│   ├── Transaction.swift             # Transaction, TransactionType
│   ├── Category.swift                # Category, CategoryType
│   ├── Budget.swift                  # Budget, BillingPeriod
│   ├── SavingsGoal.swift             # SavingsGoal, SavingsContribution
│   ├── Subscription.swift            # SubscriptionTracker
│   ├── Achievement.swift             # Achievement, UserAchievement
│   ├── AiConversation.swift          # AiConversation, AiMessage
│   ├── Profile.swift                 # Profile
│   ├── UserSubscription.swift        # UserSubscription, SubscriptionTier
│   ├── NotificationSettings.swift    # NotificationSettings
│   ├── ExchangeRates.swift           # ExchangeRates
│   └── ReceiptScan.swift             # ReceiptScan
│
├── Services/                         # Singletons и managers (6 файлов)
│   ├── SupabaseManager.swift         # Sendable singleton client
│   ├── AuthManager.swift             # Apple/Email/Migration auth
│   ├── DataStore.swift               # Shared state с кэшированием
│   ├── CurrencyManager.swift         # Курсы, форматирование, UserDefaults
│   ├── PaymentManager.swift          # Premium check + StoreKit protocol
│   └── ExchangeRateService.swift     # Actor, API + кэш
│
├── Repositories/                     # Data access layer (9 файлов)
│   ├── AccountRepository.swift
│   ├── TransactionRepository.swift
│   ├── CategoryRepository.swift
│   ├── BudgetRepository.swift
│   ├── SavingsGoalRepository.swift
│   ├── SubscriptionTrackerRepository.swift
│   ├── ProfileRepository.swift
│   ├── AiRepository.swift            # Edge Function calls
│   └── AchievementRepository.swift
│
├── ViewModels/                       # @Observable @MainActor (9 файлов)
│   ├── AppViewModel.swift            # Root: auth, currency, data
│   ├── HomeViewModel.swift           # Carousel index
│   ├── TransactionsViewModel.swift   # Search, filtering
│   ├── BudgetsViewModel.swift        # Periods, spending, progress
│   ├── AnalyticsViewModel.swift      # Charts data, breakdowns
│   ├── SavingsViewModel.swift        # Goals, contributions
│   ├── SubscriptionsViewModel.swift  # Monthly totals
│   ├── AssistantViewModel.swift      # Chat, conversations
│   └── AchievementsViewModel.swift   # Points, categories
│
├── Views/                            # SwiftUI views (28 файлов)
│   ├── Root/
│   │   ├── ContentView.swift         # Auth gate → TabView
│   │   ├── SplashView.swift          # Animated splash
│   │   └── OnboardingView.swift      # 5-step wizard
│   ├── Auth/
│   │   ├── LoginView.swift           # Apple + Email + Migration
│   │   └── MigrationCodeView.swift   # 6-char Telegram code
│   ├── Home/
│   │   ├── HomeTabView.swift
│   │   ├── AccountCarouselView.swift
│   │   ├── SummaryCardsView.swift
│   │   ├── RecentTransactionsView.swift
│   │   └── HomeSavingsSnapshotView.swift
│   ├── Transactions/
│   │   ├── TransactionsTabView.swift
│   │   ├── TransactionFormView.swift
│   │   └── TransactionRowView.swift
│   ├── Budgets/
│   │   ├── BudgetsTabView.swift
│   │   ├── BudgetCardView.swift
│   │   └── BudgetFormView.swift
│   ├── Analytics/
│   │   ├── AnalyticsTabView.swift
│   │   ├── CashflowChartView.swift
│   │   └── CategoryBreakdownView.swift
│   ├── Savings/
│   │   ├── SavingsGoalListView.swift
│   │   ├── SavingsGoalCardView.swift
│   │   ├── SavingsGoalDetailView.swift
│   │   ├── SavingsGoalFormView.swift
│   │   └── ContributionSheetView.swift
│   ├── Subscriptions/
│   │   └── SubscriptionListView.swift
│   ├── Assistant/
│   │   ├── AssistantView.swift       # Full-screen chat
│   │   └── MessageBubbleView.swift
│   ├── Achievements/
│   │   ├── AchievementsView.swift
│   │   └── AchievementBadgeView.swift
│   └── Settings/
│       ├── SettingsView.swift
│       ├── ProfileEditView.swift
│       ├── CategoriesManagementView.swift
│       ├── NotificationSettingsView.swift
│       └── PremiumPaywallView.swift
│
└── Extensions/                       # Утилиты (5 файлов)
    ├── Color+Hex.swift               # Color(hex:) с поддержкой 3/6/8 digit
    ├── View+Glass.swift              # .glassBackground() modifier
    ├── Date+Formatting.swift
    ├── Decimal+Currency.swift        # Int64.displayAmount → Decimal
    └── String+Nonce.swift            # randomNonce() + SHA256

Config/
├── Config.xcconfig.template          # Шаблон (в git)
├── Debug.xcconfig                    # Credentials (gitignored)
└── Release.xcconfig                  # Credentials (gitignored)

project.yml                           # XcodeGen конфигурация
```

## Установка и запуск

### Требования
- macOS 15+ с Xcode 16+
- iOS 18.0+ симулятор или устройство
- XcodeGen (`brew install xcodegen`)
- Supabase проект с настроенными таблицами

### Шаги

1. Клонировать репозиторий:
```bash
git clone https://github.com/Ozenforwin/akifi-ios.git
cd akifi-ios
```

2. Создать конфигурационные файлы из шаблона:
```bash
cp Config/Config.xcconfig.template Config/Debug.xcconfig
cp Config/Config.xcconfig.template Config/Release.xcconfig
```

3. Заполнить Supabase credentials в обоих xcconfig файлах:
```
SUPABASE_URL = https://YOUR_PROJECT.supabase.co
SUPABASE_ANON_KEY = YOUR_ANON_KEY_HERE
```

4. Сгенерировать Xcode project:
```bash
xcodegen generate
```

5. Открыть проект и собрать:
```bash
open AkifiIOS.xcodeproj
```
Xcode автоматически подтянет supabase-swift через SPM.

6. Выбрать симулятор iOS 18+ и запустить (Cmd+R).

## Supabase

### Необходимые таблицы
`profiles`, `accounts`, `account_members`, `transactions`, `categories`, `budgets`, `savings_goals`, `savings_contributions`, `subscriptions`, `user_subscriptions`, `achievements`, `user_achievements`, `ai_conversations`, `ai_messages`, `migration_codes`

### Edge Functions
- `assistant-query` — AI-ассистент (обработка запросов, intent classification)
- `assistant-action` — Выполнение действий по запросу ассистента
- `ios-migrate-auth` — Миграция пользователей из Telegram бота

### RLS
Все таблицы защищены Row Level Security. Данные фильтруются по `user_id` автоматически.

## App Store

### Entitlements
- Sign in with Apple (`com.apple.developer.applesignin`)

### Privacy Manifest (PrivacyInfo.xcprivacy)
- Tracking: отключён
- Collected data: email, name, user ID (для функциональности)
- Accessed APIs: UserDefaults (кэш валют и настроек)

### Permissions (добавить при реализации)
- `NSCameraUsageDescription` — при реализации сканера чеков
- `NSUserNotificationsUsageDescription` — при реализации push-уведомлений

## Дизайн

- **Glass morphism**: `.ultraThinMaterial` / `.regularMaterial` фон карточек
- **SF Symbols**: вместо кастомных иконок
- **Dynamic Type**: семантические шрифты (`.headline`, `.body`, `.caption`)
- **Dark/Light mode**: автоматическая адаптация через material и semantic colors
- **Accent color**: зелёный (`.green`)

## Лицензия

Proprietary. All rights reserved.
