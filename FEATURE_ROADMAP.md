# Akifi Feature Roadmap Q2-Q3 2026

> Стратегическое позиционирование: **"Осознанный финансовый дневник"**
> Journal-first подход. Ни один конкурент не объединяет: финансовый журнал + AI-инсайты + геймификация привычек + мультивалютность + privacy-first.

---

## Текущее состояние проекта

- **Версия:** 1.2.3
- **Кодовая база:** ~25K строк Swift 6, 155+ файлов
- **Стек:** SwiftUI, Supabase (Auth + DB + Edge Functions), Firebase (Analytics + Crashlytics + Messaging)
- **Платформа:** iOS 18.0+
- **Языки:** ru, en, es

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
| Расширить system prompt Edge Function для NL-запросов | DEFERRED | требует деплоя Edge Function |
| Добавить в контекст AI помесячную разбивку по категориям | **DONE** | `DataStore.swift` → `buildAssistantContext()` |
| Добавить в контекст AI список активных подписок (нормализовано по месяцам) | **DONE** | `DataStore.swift`, `AssistantModels.swift` |
| Добавить в контекст AI список бюджетов с метриками | **DONE** | `DataStore.swift`, `AssistantModels.swift` |

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

### 3.5 Тесты
| Задача | Статус | Файлы |
|--------|--------|-------|
| Unit-тесты CashFlowEngine (14 тестов) | **DONE** | `AkifiIOSTests/CashFlowEngineTests.swift` |
| Покрытие: normalizeToMonthly, forecast (empty/history/subs), variance, confidence | **DONE** | — |

---

## ФАЗА 4: Отчёты + Геймификация (RICE 4.50 + 3.73, ~2 спринта)

### 4.1 PDF-отчёты
| Задача | Статус | Файлы |
|--------|--------|-------|
| `PDFReportGenerator` (UIGraphicsPDFRenderer) | TODO | `Services/PDFReportGenerator.swift` (новый) |
| Шаблоны: месячный, квартальный, годовой | TODO | |
| Содержание: сводка, категории, бюджеты, подписки | TODO | |
| Подключить ReportsView к навигации (сейчас не подключён) | TODO | `Views/Reports/ReportsView.swift` |
| ShareLink для PDF | TODO | |

### 4.2 Глубокая геймификация
| Задача | Статус | Файлы |
|--------|--------|-------|
| Модель `SavingsChallenge` (30-дневный, без кафе, округляй и копи) | TODO | `Models/SavingsChallenge.swift` (новый) |
| UI challenges (создание, прогресс, результат) | TODO | `Views/Challenges/` (новая папка) |
| Привязка challenges к целям накоплений | TODO | |
| Streak milestone анимации (7, 14, 30, 60, 100 дней) | TODO | `Views/Achievements/LevelUpView.swift` |
| Бонусные ачивки за длинные стрики | TODO | Supabase `achievements` таблица |
| Финансовое дерево навыков (визуализация прогресса) | TODO | `Views/Achievements/SkillTreeView.swift` (новый) |
| Уровни: Новичок → Финансовый мастер | TODO | |

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

### 5.2 Net Worth трекер
| Задача | Статус | Файлы |
|--------|--------|-------|
| Модель `Asset` (недвижимость, авто, крипто, инвестиции) | TODO | `Models/Asset.swift` (новый) |
| Модель `Liability` (кредиты, ипотека, долги) | TODO | `Models/Liability.swift` (новый) |
| Миграция Supabase (`assets`, `liabilities`) | TODO | `supabase/migrations/` |
| Net Worth = Assets - Liabilities + Account balances | TODO | `Services/NetWorthCalculator.swift` (новый) |
| Дашборд net worth на Home | TODO | `Views/Home/NetWorthCardView.swift` (новый) |
| Ручной ввод и обновление стоимости | TODO | |
| График изменений за год | TODO | |

---

## Роадмап по спринтам

| Спринт | Фаза | Фичи | Статус |
|--------|-------|-------|--------|
| **S1** (нед 1) | Fixes + Journal | Исправления + Финансовый журнал + Шаринг | **DONE** |
| **S2** (нед 2) | Subscriptions | Подписки ↔ Бюджеты интеграция | **DONE** |
| **S3-S5** (нед 3-5) | AI 2.0 + Cash Flow | Nudges + InsightEngine + CashFlowEngine + ForecastView + дайджест | **DONE** |
| **S6** (нед 6) | Reports | PDF-отчёты + подключение ReportsView | TODO |
| **S7-S8** (нед 7-8) | Gamification | Challenges + streak rewards + skill tree | TODO |
| **S9-S10** (нед 9-10) | Widgets | WidgetKit (4 виджета) | TODO |
| **S11-S12** (нед 11-12) | Net Worth | Активы, долги, дашборд | TODO |

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
| PDF-отчёты | TODO | Есть у Monarch/Rocket |
| Savings challenges | TODO | Базовые у Cleo |
| iOS Виджеты | TODO | Есть у многих |
| Net worth | TODO | Есть у Monarch/YNAB |

---

## Технический долг (не блокирует, но стоит исправить)

| Задача | Приоритет | Описание |
|--------|-----------|----------|
| Dependency Injection | Medium | Все Repository создаются напрямую, нет протоколов, нет DI-контейнера |
| Unit-тесты BudgetMath | High | 176 строк domain-логики без тестов |
| Unit-тесты DataStore/ViewModels | Medium | Покрыты только SubscriptionDateEngine и SubscriptionMatcher |
| Декомпозиция ContentView | Low | 400+ строк, можно разбить |
| Декомпозиция SettingsView | Low | 587 строк, 5 под-View внутри |
| PaymentManager (StoreKit) | High | Заглушка, нет In-App Purchases |
| OfflineQueue для всех сущностей | Medium | Сейчас только транзакции |
| NetworkMonitor → DataStore интеграция | Medium | Автосинхронизация при восстановлении сети |

---

*Последнее обновление: 2026-04-16*
*Анализ рынка: топ-10 конкурентов (Monarch, YNAB, Copilot, Rocket Money, PocketGuard, Cleo, EveryDollar, MoneyWiz, Goodbudget, Fina)*
