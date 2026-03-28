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
| Auth | Sign in with Apple, Email/Password, Telegram migration |
| Локализация | 3 языка: Русский, English, Español (470+ ключей) |
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
│  SupabaseManager  │  Firebase  │  Services   │
│  (Singleton)      │  (FCM,     │  (Analytics │
│                   │   Crash)   │   Haptics)  │
└─────────────────────────────────────────────┘
```

### Data Flow

`AppViewModel` (root) владеет:
- `AuthManager` — аутентификация (Apple, Email, Telegram migration)
- `CurrencyManager` — курсы валют, форматирование, конвертация
- `PaymentManager` — проверка Premium статуса
- `DataStore` — shared хранилище с предвычисленными кэшами (balance, income/expense по счетам, category index)
- `ThemeManager` — тема оформления

Инжектируется через `.environment(appViewModel)` из `AkifiApp.swift`.

## Основные функции

### Финансы
- **Мультисчета** — карусель с круговой прокруткой, frosted glass эффект, стек-подложки
- **Транзакции** — CRUD с категориями, описанием, датой+временем, валютой
- **Переводы** между счетами
- **Бюджеты** — недельные/месячные/произвольные, прогресс-бар, статусы (В норме → Внимание → Превышен)
- **Цели накоплений** — прогресс-кольцо, пополнения/снятия как переводы, процентная ставка, статусы pace
- **Подписки** — трекер с прогресс-баром обратного отсчёта до списания, reminder days

### Аналитика
- **Портфель счетов** — цветная полоса-прогресс, список с процентами
- **Тренд доходов/расходов** — 6 месяцев, две кривые, тап-для-тултипа
- **Денежный поток** — bar chart по периодам (dd.MM формат)
- **По категориям** — donut chart, сворачиваемый список, тап→sheet с транзакциями
- **Дневной лимит** — рекомендуемый расход на сегодня
- **Summary карточки** — доходы/расходы за текущий месяц

### AI Ассистент
- **Полноэкранный чат** с Supabase Edge Function (assistant-query)
- **Голосовой ввод** — запись через AVAudioRecorder, транскрипция через Whisper (transcribe-voice)
- **Умный fallback** — нераспознанные вопросы направляются в LLM coaching с финансовым контекстом пользователя
- **Действия** — создание транзакций, бюджетов, навигация с preview→confirm
- **Smart budget creation** — чекбоксы для выбора предложенных бюджетов
- **Evidence карточки** — аномалии с heatmap и delta bars
- **Обратная связь** — thumbs up/down с причинами
- **История бесед** — до 30 сохранённых, автоархивация
- **Сохранение контекста** — диалог сохраняется при переходе между экранами

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
- **Прогресс-кольца** на бейджах, points badge

### Push-уведомления (серверные через FCM)
- **Budget warning** — при достижении 80%/100% лимита (event-driven)
- **Large expense** — крупный расход выше порога (event-driven)
- **Savings milestone** — 25/50/75/100% цели (event-driven)
- **Inactivity reminder** — нет транзакций >3 дня (cron ежедневно)
- **Weekly pace** — темп расходов >120% бюджета (cron среда)
- **Subscription reminder** — N дней до списания (cron ежедневно)
- **Настройки** синхронизируются с сервером

### Другое
- **Аватар** — PhotosPicker, сжатие, Supabase Storage
- **Общие счета** — бейдж "Общая", аватары участников
- **Удаление аккаунта** — двухшаговое подтверждение, edge function
- **Тактильный отклик** — haptic на таббар, FAB, достижения (отключаемый)
- **Тёмная тема** — адаптивные цвета на всех экранах
- **Только portrait** на iPhone, все ориентации на iPad

## Локализация

470+ ключей на 3 языка:
- 🇷🇺 Русский (основной)
- 🇺🇸 English
- 🇪🇸 Español

Выбор языка: Настройки → Язык (системный / ручной)

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
# Xcode подтянет SPM зависимости (Supabase + Firebase)
# Cmd+R для запуска
```

## App Store Compliance

- ✅ Sign in with Apple
- ✅ Account deletion (двухшаговое подтверждение)
- ✅ Privacy Manifest (PrivacyInfo.xcprivacy)
- ✅ NSCameraUsageDescription, NSMicrophoneUsageDescription, NSPhotoLibraryUsageDescription
- ✅ Portrait-only iPhone + all orientations iPad
- ✅ Privacy Policy & Terms of Service ссылки
- ✅ Push Notifications (aps-environment, remote-notification background mode)

## Дизайн

- **Frosted glass** — `.ultraThinMaterial` на карточках счетов
- **SF Symbols** — нативные иконки
- **Tier градиенты** — bronze/silver/gold/diamond для достижений
- **Адаптивные цвета** — `secondarySystemGroupedBackground` для контраста в dark mode
- **Стек-карточки** — peek-эффект за активной карточкой
- **Emoji конфетти** — particle system для celebration popup
- **Скруглённый таббар** — 24pt radius, тень, 44pt touch targets

## Лицензия

Proprietary. All rights reserved.
