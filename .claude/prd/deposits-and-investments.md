---
type: prd
status: partial
date: 2026-04-19
tags: [deposits, investments, interest, accounts, savings]
---

# PRD: Вклады и инвестиции

> [!note] Статус 2026-04-29
> **Депозиты (фикс-ставка)** — отгружены, см. `Models/Deposit.swift`,
> `DepositListView`, `InterestCalculator`, BETA-флаг в Settings.
>
> **Инвестиции с рыночной переоценкой** изначально были в `Non-goals`
> этого PRD. Они отгружены отдельной аркой в 7 спринтов под BETA-флагом
> "Инвестиции". Дальнейшие задачи (TWR/IRR/dividends/tax-lots/FX-
> decomposed/shared/education/MOEX) собраны в `[[portfolio-phase-3]]`.

## Problem

Сейчас в Akifi юзер может:
- Вести **счета** (чековые, кэш) — просто баланс, без автоматики
- Создавать **цели накоплений** — с процентной ставкой, но это именно цель (есть target), не финансовый инструмент
- Добавлять **активы** в Net Worth — с ручным обновлением стоимости (для крипты, акций)

Чего нет:
1. **Вклады** (банковские, под фиксированный %) — пополняю раз, проценты капают, срок зафиксирован, к погашению получаю body+interest
2. **Инвестиции с фиксированной доходностью** — облигации, накопительные счета с известной ставкой

Юзер хочет: «чтобы я мог переводить деньги, и они сами считались — сколько я вложил, сколько процентов накопилось, какой срок».

Это не цель (нет дедлайна на накопить X) и не актив (стоимость известна детерминированно через формулу, не через рыночную переоценку).

## Goal

Добавить новый финансовый инструмент **«Вклад»** (Deposit), который:
1. Принимает переводы со счетов (как в SavingsGoal) через единый transfer-механизм
2. Автоматически считает накопленный процент по простой / сложной / капитализируемой схеме
3. Имеет срок (term) с countdown до погашения
4. Показывает в UI: body (principal) + accrued interest + term progress + projected at maturity
5. По истечении срока переводит всё обратно на source-счёт (или другой выбранный)
6. Участвует в расчёте Net Worth как реальная стоимость на сегодня

## Non-goals

- **Инвестиции с рыночной переоценкой** (акции, крипта) — уже покрыты Net Worth Assets. Пересекать не будем; если у юзера биткоин — он создаёт Asset в Net Worth с ручной переоценкой.
- **Брокерские счета** с несколькими инструментами — слишком сложно для MVP, это PortfolioTracker-level
- **Автоматическое взятие курсов** или ставок с банковских API — out of scope
- **Досрочное закрытие с частичным процентом по правилу банка** — в MVP просто записываем closed_at, проценты считаем до даты закрытия

## Концептуальная модель

```
Account (существующий)
├── checking    (обычный счёт)
├── savings     (обычный счёт, помечен как сберегательный)
├── cash        (кэш)
├── deposit     ← НОВОЕ: связан 1:1 с Deposit record, баланс = principal + accrued
└── investment  ← НОВОЕ: то же что deposit, но семантика

Deposit (новая таблица, 1:1 с Account)
├── interest_rate       (годовые %, фиксированный)
├── compound_frequency  (daily/monthly/quarterly/yearly/simple)
├── start_date
├── end_date            (nullable = open-ended)
├── principal           (сумма внесённая, кэшируется)
├── accrued_interest    (накопленный процент, пересчитывается)
├── last_interest_calc_at
└── status (active/matured/closed_early)
```

Ключевое решение: **Deposit — это специализированный Account**, а не отдельная сущность. Почему:
- Transfer-механика уже работает для Account — не надо изобретать новый flow
- `account_members` и прочая мета применима (совместный вклад)
- Net Worth автоматически подхватит Deposit balance
- Отчёты, аналитика, AI context — всё «из коробки»

Deposit ≠ Account в том что Deposit хранит **правила начисления процентов**, а Account хранит **текущий баланс** (principal + accrued).

## Архитектура

### Schema

**Миграция 1:** `accounts.account_type`
```sql
ALTER TABLE accounts
    ADD COLUMN IF NOT EXISTS account_type TEXT NOT NULL DEFAULT 'checking'
        CHECK (account_type IN (
            'checking', 'savings', 'cash', 'deposit', 'investment'
        ));

CREATE INDEX IF NOT EXISTS idx_accounts_user_type ON accounts(user_id, account_type);
```

Все существующие счета → `checking` по умолчанию. Без breakage.

**Миграция 2:** `deposits`
```sql
CREATE TABLE IF NOT EXISTS deposits (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE DEFAULT auth.uid(),
    account_id UUID NOT NULL UNIQUE REFERENCES accounts(id) ON DELETE CASCADE,
    
    -- Условия
    interest_rate NUMERIC(5,3) NOT NULL CHECK (interest_rate >= 0),  -- 12.5 = 12.5%
    compound_frequency TEXT NOT NULL DEFAULT 'monthly'
        CHECK (compound_frequency IN ('daily', 'monthly', 'quarterly', 'yearly', 'simple')),
    start_date DATE NOT NULL,
    end_date DATE,  -- nullable для open-ended
    
    -- Статус
    status TEXT NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'matured', 'closed_early')),
    closed_at TIMESTAMPTZ,
    return_to_account_id UUID REFERENCES accounts(id) ON DELETE SET NULL,
    
    -- Кэшированные вычисления (обновляются в фоне)
    principal BIGINT NOT NULL DEFAULT 0,
    accrued_interest BIGINT NOT NULL DEFAULT 0,
    last_interest_calc_at DATE,
    
    notes TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_deposits_user_status ON deposits(user_id, status);
ALTER TABLE deposits ENABLE ROW LEVEL SECURITY;
-- RLS own-only как в остальных таблицах

CREATE TRIGGER trg_deposits_updated_at
    BEFORE UPDATE ON deposits FOR EACH ROW
    EXECUTE FUNCTION set_deposits_updated_at();
```

**Миграция 3 (опционально, для сервера):** pg_cron job для ежедневного пересчёта `accrued_interest`. В MVP делаем client-side, server-side — v2.

### iOS слой

**Модели:**
```swift
// Models/Deposit.swift
struct Deposit: Codable, Sendable, Identifiable {
    let id: String
    let userId: String
    let accountId: String          // FK на Account (1:1)
    let interestRate: Decimal      // 12.5 = 12.5%
    let compoundFrequency: CompoundFrequency
    let startDate: String          // yyyy-MM-dd
    let endDate: String?
    let status: DepositStatus
    let closedAt: String?
    let returnToAccountId: String?
    let principal: Int64           // kopecks
    let accruedInterest: Int64     // cached
    let lastInterestCalcAt: String?
    let notes: String?
    let createdAt: String
    let updatedAt: String
}

enum CompoundFrequency: String, Codable, Sendable, CaseIterable {
    case daily, monthly, quarterly, yearly, simple
}

enum DepositStatus: String, Codable, Sendable {
    case active, matured, closedEarly = "closed_early"
}

// Models/Account.swift — расширить
enum AccountType: String, Codable, Sendable {
    case checking, savings, cash, deposit, investment
}
// Add `account_type: AccountType` к Account
```

**Репозитории:**
```swift
// Repositories/DepositRepository.swift
final class DepositRepository: Sendable {
    func fetchAll() async throws -> [Deposit]
    func fetchActive() async throws -> [Deposit]
    func fetchForAccount(_ accountId: String) async throws -> Deposit?
    func create(_ input: CreateDepositInput) async throws -> Deposit
    func update(id: String, _ input: UpdateDepositInput) async throws
    func delete(id: String) async throws
    func closeEarly(id: String, returnToAccountId: String?) async throws
    /// Обновляет `accrued_interest` и `last_interest_calc_at` на основании
    /// `InterestCalculator.accrueInterest`. Вызывается в фоне после каждого
    /// DataStore.loadAll.
    func refreshAccruedInterest(_ deposit: Deposit) async throws -> Deposit
}
```

**Сервис:**
```swift
// Services/InterestCalculator.swift
enum InterestCalculator {
    /// Начисляет проценты на principal за период [startDate, asOf].
    /// Возвращает suma_kopecks начисленных процентов (только accrued, без principal).
    static func accrueInterest(
        principal: Int64,           // kopecks
        rate: Decimal,              // annual %, e.g. 12.5
        startDate: Date,
        asOf: Date,
        frequency: CompoundFrequency
    ) -> Int64

    /// Проецирует баланс на момент end_date (principal + interest).
    /// Для UI "к погашению вы получите X".
    static func projectedMaturityValue(
        principal: Int64,
        rate: Decimal,
        startDate: Date,
        endDate: Date,
        frequency: CompoundFrequency
    ) -> Int64
}
```

Логика — те же формулы, что уже есть в SavingsGoal (простой + compound). Extract в shared service, SavingsGoal переводим на InterestCalculator.

**ViewModel:**
```swift
// ViewModels/DepositsViewModel.swift
@MainActor @Observable
final class DepositsViewModel {
    var deposits: [Deposit] = []
    var isLoading = false
    var errorMessage: String?
    
    private let repo = DepositRepository()
    
    func load(dataStore: DataStore) async {
        // 1. fetch all deposits
        // 2. для каждого active — пересчитать accrued если last_calc_at ≠ today
        // 3. upsert в DB (batch)
        // 4. detect matured (endDate <= today) → auto-transition status
    }
    
    func create(...) async throws  // + transfer с source-счёта на новый deposit account
    func contribute(to:amount:fromAccount:) async throws  // обычный transfer
    func closeEarly(_ deposit: Deposit, returnTo: Account) async throws
    // closeEarly: transfer principal+accrued на returnTo, status = closed_early
}
```

**Views:**
```
Views/Deposits/
├── DepositListView.swift        # Sections: active / matured / closed
├── DepositDetailView.swift      # Hero (total = principal + accrued),
│                                  progress ring (term %), contributions list,
│                                  projected maturity value
├── DepositFormView.swift        # name, link_to_new_account, rate,
│                                  compound_freq, start_date, end_date,
│                                  initial_contribution + source_account
├── DepositCardView.swift        # компакт карточка для списков
└── DepositContributeSheet.swift # добавить в существующий вклад (transfer in)
```

**Entry points:**
- **Home:** новая gradient-карточка «Вклады» с total (principal + accrued) + next-maturity countdown
- **Settings → Финансы:** NavLink «Вклады»
- **Net Worth:** deposits включаются в `accountBalances` автоматически (через account_type)
- **TransactionFormView:** в picker «Оплачено с» и транферной форме deposits доступны как destination

## UX Flows

### 1. Создание вклада

**User journey:**
1. Home → карточка «Вклады» → «+ Новый вклад»
2. DepositFormView:
   - Название (например «Вклад Альфа 12%»)
   - Валюта
   - Сумма первого пополнения (калькулятор)
   - Откуда перевести (picker своих счетов)
   - Процентная ставка (% годовых)
   - Период капитализации (ежедневно / ежемесячно / квартально / ежегодно / простой процент)
   - Дата начала (default = today)
   - Дата окончания (optional; если нет — open-ended)
   - Куда вернуть при погашении (default = source account)
3. Save:
   - Создаётся **новый Account** с `account_type = 'deposit'` и `initial_balance = 0`
   - Создаётся **Deposit** record (linked to this account)
   - Создаётся **transfer pair**: from source → to new deposit account (via `create_expense_with_auto_transfer` или обычный transfer, смотря от реализации)
   - `principal` записывается = сумма первого пополнения
   - `last_interest_calc_at = today`, `accrued_interest = 0`

### 2. Пополнение существующего вклада

**User journey:**
1. DepositListView → тап на вклад → DepositDetailView → «Пополнить»
2. DepositContributeSheet: сумма + source account
3. Save → transfer pair, `principal += amount`

### 3. Отображение (DepositDetailView)

```
╔═══════════════════════════════════════╗
║  Вклад Альфа 12%                     ║
║                                       ║
║    135 420 ₽   ← principal + accrued ║
║                                       ║
║  ┌──────────────┬──────────────────┐ ║
║  │ Внесено       │ Начислено       │ ║
║  │ 120 000 ₽     │ 15 420 ₽ (+12%) │ ║
║  └──────────────┴──────────────────┘ ║
║                                       ║
║  ○○○○○●●●●●●●●●  365 дней — 180 осталось ║
║  ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ ║
║                                       ║
║  К погашению 15.10.2026              ║
║  Ожидаемая сумма: 148 800 ₽          ║
║                                       ║
║  Условия                              ║
║  • 12% годовых, капитализация еж.    ║
║  • Начало: 15.04.2026                 ║
║  • Срок: 365 дней                     ║
║                                       ║
║  История пополнений                  ║
║  15.04.2026 · +100 000 ₽ · с Тинькофф║
║  20.04.2026 · +20 000 ₽  · с IBT     ║
║                                       ║
║  [+ Пополнить]  [Закрыть досрочно]   ║
╚═══════════════════════════════════════╝
```

### 4. Погашение (maturity)

На `end_date` ViewModel автоматически:
1. Детектит active deposit с `end_date <= today`
2. Создаёт transfer pair: deposit account → return_to_account на `principal + accrued_interest`
3. Status → `matured`, `closed_at = now()`
4. Push-уведомление: «Вклад X погашен, 148 800 ₽ возвращены на Тинькофф»

### 5. Досрочное закрытие

DepositDetailView → «Закрыть досрочно» → confirmation → transfer as-of текущий `principal + accrued`, status → `closed_early`.

## Interest Calculation

### MVP: client-side

```swift
static func accrueInterest(
    principal: Int64,
    rate: Decimal,
    startDate: Date,
    asOf: Date,
    frequency: CompoundFrequency
) -> Int64 {
    let days = Decimal(asOf.timeIntervalSince(startDate) / 86400)
    let yearly = rate / 100  // 12.5 → 0.125
    
    switch frequency {
    case .simple:
        // I = P * r * t (where t in years)
        let years = days / 365
        return Int64(truncating: (Decimal(principal) * yearly * years) as NSDecimalNumber)
        
    case .daily:
        // A = P * (1 + r/365)^days
        let factor = pow(1 + yearly / 365, days)
        let amount = Decimal(principal) * factor
        return Int64(truncating: (amount - Decimal(principal)) as NSDecimalNumber)
        
    case .monthly:
        let months = days / 30
        let factor = pow(1 + yearly / 12, months)
        return Int64(truncating: (Decimal(principal) * (factor - 1)) as NSDecimalNumber)
    // ... quarterly, yearly analogously
    }
}
```

### Edge cases

1. **Пополнения в середине срока:** каждое пополнение — отдельный lot с собственной start_date. Accrual считается по сумме lots. Упрощение MVP: игнорируем time-weighting, считаем на текущий principal с last_calc_at.
    - **Правильное решение v2:** хранить contribution history в `deposit_contributions` (mirror на savings_contributions) и считать interest как sum per lot.
    - **MVP compromise:** при каждом пополнении — recalc accrued до today, add to principal, reset last_calc_at = today. Это занижает interest на ~0.5% в год для ежемесячных пополнений, приемлемо.
2. **Валюта не matches source:** позволить, использовать FX на момент контрибуции (как в payment-source cross-currency).
3. **Отрицательный principal (снятие):** разрешаем только через close_early.

### Server-side (v2)

pg_cron job ежедневно в 02:00 UTC:
```sql
UPDATE deposits
SET 
  accrued_interest = <computed>,
  last_interest_calc_at = CURRENT_DATE
WHERE status = 'active'
  AND last_interest_calc_at < CURRENT_DATE;
```

Плюс cron для auto-maturity:
```sql
UPDATE deposits SET status = 'matured', closed_at = now()
WHERE status = 'active' AND end_date <= CURRENT_DATE;
```

И edge function для выдачи push-уведомления о maturity.

## Integration

### Transfer system
При `TransferFormView` + `TransactionFormView` → в picker «Счёт получатель» / «Оплачено с» deposits отображаются как обычные accounts с иконкой 💰 и бейджем «вклад».

### Net Worth
Deposits имеют баланс на Account — включаются в `accountBalances` автоматически. Никаких спец-правил.

### AI Assistant
Контекст ассистента (DataStore.buildAssistantContext) обогатить списком активных вкладов с их параметрами — чтобы юзер мог спросить «сколько я заработаю к лету по всем вкладам».

### Reports (PDF)
Новая секция в PDF: «Вклады» — таблица активных + совокупный expected income за период.

### Челленджи
`categoryLimit` challenge можно привязать к deposit для челленджа «положить 50k до конца месяца».

### Savings Goals
Сохраняем SavingsGoal как отдельную сущность (у них ДРУГОЕ — целевая сумма, накапливаем шаг за шагом). Deposit — это финансовый продукт, Goal — намерение. Разные UI, но InterestCalculator шарится.

## Phased rollout

### Phase 1 (MVP, 1-2 сессии)

- [ ] Migration: `accounts.account_type` + `deposits` table + RLS
- [ ] Models: `Deposit`, `CompoundFrequency`, `DepositStatus`, `AccountType`
- [ ] `InterestCalculator` + unit tests (5 кейсов: simple, daily, monthly, quarterly, yearly)
- [ ] `DepositRepository` + `DepositsViewModel`
- [ ] `DepositFormView` — создание + первое пополнение через transfer
- [ ] `DepositListView` — sections active/matured/closed
- [ ] `DepositDetailView` — hero + breakdown + contributions history + term progress ring
- [ ] `DepositContributeSheet` — пополнение
- [ ] Auto-maturity detection в `load()` (client-side)
- [ ] Home shortcut card
- [ ] Settings → Finance NavLink
- [ ] Локализация ru/en/es

### Phase 2 (v2, 1 сессия)

- [ ] Deposit contributions table (lot-based interest calc)
- [ ] Server-side pg_cron для accrual + maturity
- [ ] Push-уведомления о приближении maturity (за 7 дней, за 1 день)
- [ ] PDF reports секция «Вклады»
- [ ] AI context extension
- [ ] Close-early с правилом частичного процента (опционально, если юзер попросит)
- [ ] Chart истории баланса deposit (principal + accrued по дням)

### Phase 3 (nice-to-have)

- [ ] Импорт реальных ставок ЦБ для suggested rate
- [ ] Compound frequency picker с подсказкой «при этой капитализации вы получите X»
- [ ] Сравнение двух вкладов по yield
- [ ] Deposit laddering (раскладка денег по нескольким вкладам с разными сроками)

## Open Questions

1. **Account создаётся автоматически или пользователь выбирает существующий?**
   - Рекомендую: автоматически при создании Deposit, чтобы юзер не путался. Можно назвать по имени вклада.
2. **Можно ли пополнять matured или closed deposit?**
   - Нет. Только `active`.
3. **Как отображать в Net Worth — вместе с активами или как отдельный блок?**
   - Baseline: уже `accountBalances` (принципал+accrued). Отдельно — нет.
4. **Cross-currency deposits?**
   - MVP: deposit в одной валюте (= account currency). Пополнение из разного-валютного счёта — конвертация как в payment-source flow.
5. **Что делать если юзер удалит Account, на котором deposit?**
   - `ON DELETE CASCADE` на deposits.account_id — deposit тоже удалится. История transfer'ов останется. ОК для MVP.
6. **Инвестиции (с неизвестной ставкой) — отдельная сущность или extension?**
   - Отдельная. Pass 1: использовать Net Worth Assets. Pass 2 (если нужно) — добавить `account_type = 'investment'` и отдельную модель InvestmentPosition с ручной переоценкой.

## Technical risks

1. **Concurrent pополнения и recalc** — если юзер пополняет вклад в момент, когда в фоне идёт accrual-обновление, можно записать устаревший `principal`. Решение: делать accrual атомарно через RPC `accrue_deposit_interest(p_deposit_id)`.
2. **Precision в interest calc** — Decimal vs Double. Используем `Decimal` + `pow(base:Decimal, exp:Decimal)` из Foundation (осторожно с overflow при daily compound за 10 лет). Есть unit tests.
3. **Time zones** — вся логика дат в UTC, как в SavingsGoal. Проверить на юзера в другом часовом поясе.
4. **Backward compat** — существующие juices Account без `account_type` получат default 'checking'. Проверить что UI корректно их рендерит.

## Success metrics

- Кол-во созданных deposits per user (цель: 30% premium-юзеров создают ≥ 1 в первый месяц)
- Точность accrued: отклонение < 0.1% от банковской формулы на 1-летнем вкладе
- NPS feature: ≥ 8/10 на вопрос «насколько точно app показал проценты»
- Retention: юзеры с вкладами возвращаются в app на 20% чаще (через notifications о приближении maturity)

## Зависимости

- **SavingsGoal** → переиспользуем InterestCalculator
- **AccountRepository** → расширяется account_type
- **NetWorthCalculator** → автоматически подхватывает через accountBalances
- **CurrencyManager** → для cross-currency пополнений
- **Supabase MCP** → для применения миграций
- **Нет** зависимости от StoreKit (фича free-tier).

## Скоуп MVP для одной сессии (реалистично)

Что можно отгрузить за 1 сессию делегирования:

1. ✅ Миграции (через MCP)
2. ✅ Модели + enums
3. ✅ `InterestCalculator` + 5 тестов
4. ✅ Repository + ViewModel
5. ✅ 4 Views (List, Detail, Form, ContributeSheet)
6. ✅ Home shortcut + Settings entry
7. ✅ Auto-maturity detection
8. ✅ Локализация
9. ✅ Build + test clean, push

Что оставляем на Phase 2:
- pg_cron для серверного accrual
- Push-уведомления о maturity
- PDF reports integration
- Chart истории deposit balance
- Lot-based precise accrual

## Next Steps

1. Подтвердить с пользователем открытые вопросы (особенно #1, #4, #6)
2. Задать RICE score и поставить в Phase 5.3 роадмапа
3. Делегировать team-lead'у для реализации Phase 1 MVP
