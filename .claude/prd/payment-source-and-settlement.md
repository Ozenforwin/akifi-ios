---
type: prd
status: shipped-mvp
date: 2026-04-19
shipped: 2026-04-19
tags: [shared-accounts, payment-flow, settlement, rls]
---

## Статус реализации (2026-04-19)

**MVP отгружен** в commits `1efe5af` … `0fdbb88`, затем серия fix-пассов на реальном устройстве:

| Коммит | Правка |
|---|---|
| `9731d4c` | 5 багов first-device: RPC 404 (null-keys), scale (200→2.63$), settlement attribution, dup label, обрезанный segmented |
| `b53cf72` | Settlement feature-scoped: игнорирует старые ручные переводы и прямые расходы, компактный UI карточки |
| `2eada24` | Closure flow: «Отметить выполненным» реально закрывает долг, секция «Закрыто в этом периоде», кнопка отмены ⟲ |
| `c9085b7` | Reports + Challenges перенесены из Home в Settings с BETA-бейджем |
| `2978474` | Swipe-delete auto-transfer: локальное состояние синкается с триплетом (не «возвращаются») |
| `79339f3` | Orphan settlement не показывается когда нет транзакций в периоде |
| `6ece83a` | Дефолт picker'а «Оплачено с» = «Этот счёт», auto-transfer только по явному выбору |

**Текущее поведение:**
- По умолчанию picker показывает «Этот счёт (обычный расход)» — авто-перевод создаётся только при явном выборе другого источника
- ⭐ рядом с сохранённым в `user_account_defaults` источником — one-tap к привычной карте, но не pre-select
- Settlement считает только транзакции с `auto_transfer_group_id != null` (новая фича). Старые ручные переводы игнорятся
- Закрытые settlements уменьшают suggestions через применение delta (from += amount, to −= amount)
- Свайп-delete auto-transfer → триплет убирается и из DB (через RPC), и из локального DataStore

Build clean, 125/125 тестов проходят.

## План v2 (deferred, в порядке приоритета)

### 🔥 Приоритет P1 — Discovery-онбординг (~30 мин)
Новые юзеры создают общий счёт и не знают про фичу «Оплачено с». Нужен баннер в TransactionFormView при первом открытии формы на общем счёте без сохранённого дефолта:
> 💡 Обычно оплачиваешь с личной карты? Выбери её ниже — создадим перевод автоматически.
Однократный показ, флаг в UserDefaults по account_id. Не должен появляться если дефолт уже настроен.

### 🔥 Приоритет P1.5 — Cross-currency auto-transfers (~1 день)
Сейчас picker «Оплачено с» фильтрует источники по совпадению валюты с целевым счётом. Реальный кейс: у юзера ByBit в USD, он пополняет Семейный (RUB) — ByBit не виден в пикере.

**Что нужно:**
1. DB: `ALTER FUNCTION create_expense_with_auto_transfer` — добавить `p_source_amount NUMERIC DEFAULT NULL` и `p_source_currency TEXT DEFAULT NULL`. Если оба = NULL → текущее поведение. Иначе transfer-out на source использует `p_source_amount` + `p_source_currency`.
2. iOS: снять same-currency фильтр в `eligibleSources`. Добавить display-hint «ByBit (USD ≈ 2,63 $)» рядом с именем счёта разной валюты.
3. Client-side: на save через `CurrencyManager.convert(...)` получить source amount, передать в RPC.
4. Risk: курсы могут скакать, source-leg сумма фиксируется в момент записи. Нужна ли «переоценка» — продуктовое решение v3.

### ⚠️ Приоритет P2 — Bank import dedup (~20 мин)
В `BankImportView`: когда импортится банковская выписка из счёта, для которого существует `auto_transfer_group_id != null` в том же дне ±1 и той же сумме — помечать импортируемую строку как «возможный дубликат авто-перевода», дефолтом снимать галочку. TODO-коммент уже в файле.

### 💤 Приоритет P3 — Custom split weights (v2 когда попросит кто-то)
Миграция: `ALTER TABLE account_members ADD COLUMN split_weight NUMERIC DEFAULT 1.0;`. UI: в `ShareAccountView` добавить поле «Доля %». В `SettlementCalculator.compute()`: `fairShare(M) = totalExpenses * (weight(M) / sum(weights))`. TODO-коммент в файле.

### 💤 Приоритет P4 — Direct-expense attribution (продуктовое решение)
Когда юзер расходует прямо с общего счёта (без auto-transfer) — totalExpenses растёт, но вклад никому не кредитуется. Варианты решения описаны в комменте `SettlementCalculator.swift`:
- (a) атрибутировать create'у транзакции как «out-of-pocket»
- (b) спросить при создании «ты бы указал source или это из общих»
- (c) считать как есть, но показывать warning в settlement

Решить когда увидим реальный паттерн в данных.

### 💤 Приоритет P5 — Orphan settlements auto-cleanup
Если юзер отметил долг закрытым, потом удалил все транзакции периода — запись в `settlements` остаётся. Сейчас UI скрывает секцию «Закрыто в этом периоде» когда `balances` пуст, но запись живая и при новых транзакциях в том же периоде применится к их расчёту (может выдать некорректную suggestion).

Решение в будущем:
- (a) Кнопка «Очистить закрытые расчёты этого периода» когда нет активности
- (b) Автоматическое удаление при `balances.isEmpty && pastSettlements.isEmpty == false` — рискованно, можно потерять историю
- (c) Предупреждающий баннер «Записи о закрытиях есть, но нет транзакций — игнорируем их при расчёте»

Вариант (c) безопаснее всего. Нужен тогда флаг в compute: `applyOrphanSettlements = balances.isEmpty ? false : true`.

### ❌ НЕ делаем (осознанно)
- **Retroactive attach** к старым ручным переводам — может сломать уже выверенную историю
- **Multi-level settlement** (A→B→C) — актуально только для 3+ участников с циклическими долгами

### 🔒 Edit-existing-expense change of source (v2)
Сейчас при редактировании расхода picker «Оплачено с» скрыт — смена источника требует перестройки всего триплета (delete + recreate). Out of MVP. Когда понадобится:
1. RPC `reassign_payment_source(p_expense_id, p_new_source)` — атомарно delete pair + insert new pair
2. Разблокировать picker в edit-mode, вызов RPC при смене

---

# PRD: Payment Source & Shared Account Settlement

## Problem

На общих счетах (shared accounts с `account_members`) участники регулярно оплачивают **общие** траты с **личных** карт. Чтобы сохранить корректный баланс общего счёта, сейчас нужно вручную создать перевод личный-счёт → общий-счёт **после** записи расхода. Это трудоёмко, о нём забывают, и общий счёт уходит в большой ложный минус.

Вторая боль: **подсчёт «кто кому должен»** между участниками. Делается на калькуляторе, ошибочно.

## Цель

Сделать оплату общих трат с личной карты **один-тап**: юзер выбирает в форме транзакции «Оплачено с: Тинькофф» — система сама создаёт пару transfer-ов (личный → общий), атомарно. Плюс инлайн-панель «кто кому должен» на детальном экране общего счёта, обобщённая для любого числа участников.

## Non-goals

- Кастомные split-проценты (60/40). MVP — equal split по числу участников.
- Ретроактивная привязка старых ручных переводов к расходам. Новое поведение начинается с момента релиза.
- Bank import reconciliation — только флаг «не задублировать» по (дата, сумма, счёт).
- Multi-level settlement (A за B, B за C → A за C).
- Custom currency conversion между счетами участников в разных валютах. MVP предполагает одну валюту.

## Actors

- **Владелец общего счёта** — создаёт счёт, приглашает участников, может настроить split.
- **Участник** (editor / viewer в `account_members`) — добавляет расходы, переводит на общий счёт, видит settlement.
- **Все участники** — видят transfer-in на общий счёт со всех сторон (но не детали чужих личных счетов).

## Core concepts

### Payment source

Новое поле на `transactions.payment_source_account_id`:
- `null` или `= account_id` → обычный расход, ничего не меняется.
- `≠ account_id` → триггер на бэкенде создаёт связанную пару transfer-ов.

### Auto-transfer group

Новое поле `transactions.auto_transfer_group_id UUID` связывает расход со сгенерированной парой `transfer_group_id`. Пара транзакций (transfer-out + transfer-in) хранится как обычные transfer-леги, плюс ссылается обратно на expense через тот же `auto_transfer_group_id`.

### User account defaults

Новая таблица `user_account_defaults`:
- Хранит per-user дефолтный source account для каждого целевого account.
- Используется при открытии TransactionFormView: выбран счёт → подставляется дефолт.

### Settlement

Вычисляемая сущность, не хранится в БД до момента «отметить выполненным». В БД живёт `settlements`:
- Запись о том, что участник A признал долг перед B на сумму X за период P.
- Может быть привязана к реальному transfer-у между личными счетами (если юзер знает счёт другого), но это опционально.

## Data model

### Миграция 1 — transactions extension

```sql
ALTER TABLE transactions
    ADD COLUMN payment_source_account_id UUID REFERENCES accounts(id) ON DELETE SET NULL,
    ADD COLUMN auto_transfer_group_id UUID;

CREATE INDEX idx_transactions_auto_transfer_group ON transactions(auto_transfer_group_id)
    WHERE auto_transfer_group_id IS NOT NULL;
```

Инварианты:
- Если `auto_transfer_group_id IS NOT NULL` — в `transactions` всегда **3 строки** с этим id:
  1. expense на target account (payment_source_account_id = source)
  2. transfer-leg «out» на source (type='expense', transfer_group_id = auto_transfer_group_id)
  3. transfer-leg «in» на target (type='income', transfer_group_id = auto_transfer_group_id)
- Все три имеют одинаковую сумму, валюту, дату.

### Миграция 2 — user_account_defaults

```sql
CREATE TABLE user_account_defaults (
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE DEFAULT auth.uid(),
    account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    default_source_id UUID REFERENCES accounts(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, account_id)
);

ALTER TABLE user_account_defaults ENABLE ROW LEVEL SECURITY;

CREATE POLICY "user_account_defaults: own only" ON user_account_defaults
    FOR ALL USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());
```

### Миграция 3 — settlements

```sql
CREATE TABLE settlements (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    shared_account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    from_user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    to_user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    amount BIGINT NOT NULL, -- minor units
    currency TEXT NOT NULL,
    period_start DATE NOT NULL,
    period_end DATE NOT NULL,
    settled_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    settled_by UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
    linked_transfer_group_id UUID,      -- если связали с реальным transfer-ом
    note TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_settlements_account_period ON settlements(shared_account_id, period_end);

ALTER TABLE settlements ENABLE ROW LEVEL SECURITY;

-- Все участники общего счёта видят settlements по нему
CREATE POLICY "settlements: members can read" ON settlements FOR SELECT USING (
    EXISTS (
        SELECT 1 FROM account_members m
        WHERE m.account_id = shared_account_id AND m.user_id = auth.uid()
    )
);
CREATE POLICY "settlements: members can write" ON settlements FOR INSERT WITH CHECK (
    EXISTS (
        SELECT 1 FROM account_members m
        WHERE m.account_id = shared_account_id AND m.user_id = auth.uid()
    )
);
CREATE POLICY "settlements: creator can delete" ON settlements FOR DELETE USING (settled_by = auth.uid());
```

### RPC функции (атомарность)

```sql
-- Create expense with optional auto-transfer. Returns expense row id.
CREATE OR REPLACE FUNCTION create_expense_with_auto_transfer(
    p_account_id UUID,
    p_category_id UUID,
    p_amount NUMERIC,
    p_currency TEXT,
    p_date TIMESTAMPTZ,
    p_description TEXT,
    p_merchant_name TEXT,
    p_payment_source_account_id UUID
) RETURNS UUID AS $$
DECLARE
    v_expense_id UUID;
    v_group_id UUID;
BEGIN
    IF p_payment_source_account_id IS NULL OR p_payment_source_account_id = p_account_id THEN
        -- Simple expense, no auto-transfer
        INSERT INTO transactions(account_id, category_id, amount, currency, date, description, merchant_name, type, user_id)
        VALUES (p_account_id, p_category_id, p_amount, p_currency, p_date, p_description, p_merchant_name, 'expense', auth.uid())
        RETURNING id INTO v_expense_id;
        RETURN v_expense_id;
    END IF;

    v_group_id := gen_random_uuid();

    -- 1. The main expense on target account, with payment_source pointer and auto_transfer_group_id
    INSERT INTO transactions(account_id, category_id, amount, currency, date, description, merchant_name, type,
                             payment_source_account_id, auto_transfer_group_id, user_id)
    VALUES (p_account_id, p_category_id, p_amount, p_currency, p_date, p_description, p_merchant_name, 'expense',
            p_payment_source_account_id, v_group_id, auth.uid())
    RETURNING id INTO v_expense_id;

    -- 2. Transfer-out on source account
    INSERT INTO transactions(account_id, amount, currency, date, description, type, transfer_group_id, auto_transfer_group_id, user_id)
    VALUES (p_payment_source_account_id, p_amount, p_currency, p_date, 'Авто-перевод: ' || COALESCE(p_description, 'расход'), 'expense', v_group_id, v_group_id, auth.uid());

    -- 3. Transfer-in on target account
    INSERT INTO transactions(account_id, amount, currency, date, description, type, transfer_group_id, auto_transfer_group_id, user_id)
    VALUES (p_account_id, p_amount, p_currency, p_date, 'Авто-перевод: ' || COALESCE(p_description, 'расход'), 'income', v_group_id, v_group_id, auth.uid());

    RETURN v_expense_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Delete expense and its auto-transfer pair atomically.
CREATE OR REPLACE FUNCTION delete_expense_with_auto_transfer(p_expense_id UUID)
RETURNS VOID AS $$
DECLARE
    v_group_id UUID;
BEGIN
    SELECT auto_transfer_group_id INTO v_group_id FROM transactions WHERE id = p_expense_id;

    IF v_group_id IS NOT NULL THEN
        DELETE FROM transactions WHERE auto_transfer_group_id = v_group_id;
    ELSE
        DELETE FROM transactions WHERE id = p_expense_id;
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Update expense amount + sync auto-transfer pair if exists.
CREATE OR REPLACE FUNCTION update_expense_with_auto_transfer(
    p_expense_id UUID,
    p_amount NUMERIC,
    p_category_id UUID,
    p_date TIMESTAMPTZ,
    p_description TEXT,
    p_merchant_name TEXT
) RETURNS VOID AS $$
DECLARE
    v_group_id UUID;
BEGIN
    UPDATE transactions
    SET amount = p_amount, category_id = p_category_id, date = p_date,
        description = p_description, merchant_name = p_merchant_name
    WHERE id = p_expense_id
    RETURNING auto_transfer_group_id INTO v_group_id;

    IF v_group_id IS NOT NULL THEN
        -- Sync the transfer pair amounts and date
        UPDATE transactions
        SET amount = p_amount, date = p_date,
            description = 'Авто-перевод: ' || COALESCE(p_description, 'расход')
        WHERE transfer_group_id = v_group_id AND id <> p_expense_id;
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

### RLS для transactions с авто-переводами

Существующая RLS transactions — проверить, что:
- SELECT: юзер видит свою строку (`user_id = auth.uid()`) OR является членом `account_members` для `account_id`
- INSERT/UPDATE/DELETE: через RPC функции (SECURITY DEFINER обходит RLS внутри, но функция сама проверяет что вызывающий имеет право)

**Видимость пары для другого участника общего счёта:**
- Transfer-in на Семейный — видят все участники (через account_members)
- Transfer-out на личный счёт создателя — видит только создатель (not a member → RLS deny)
- Expense на Семейный — видят все участники

Эффект: Оля видит в истории Семейного строку «Владимир вложил 1500 ₽ · Авто-перевод» + соответствующий расход. Не видит что именно у Владимира Тинькофф.

Для user-display отсутствующего personal-счёта на чужой стороне: denormalize в `description` или через join `profiles` по `user_id`.

## Client-side changes (iOS)

### Модели

```swift
struct Transaction: Codable, Sendable, Identifiable {
    // existing...
    var paymentSourceAccountId: String?
    var autoTransferGroupId: String?
}

struct UserAccountDefault: Codable, Sendable {
    let userId: String
    let accountId: String
    let defaultSourceId: String?
}

struct Settlement: Codable, Sendable, Identifiable {
    let id: String
    let sharedAccountId: String
    let fromUserId: String
    let toUserId: String
    let amount: Int64
    let currency: String
    let periodStart: Date
    let periodEnd: Date
    let settledAt: Date
    let settledBy: String
    let linkedTransferGroupId: String?
    let note: String?
}
```

### Репозитории

- `TransactionRepository`:
  - `create(input:)` — вызывает RPC `create_expense_with_auto_transfer`
  - `update(id:input:)` — вызывает `update_expense_with_auto_transfer`
  - `delete(id:)` — вызывает `delete_expense_with_auto_transfer`
- Новый `UserAccountDefaultsRepository` (CRUD)
- Новый `SettlementRepository` (CRUD, fetchForAccount, create, markSettled)

### ViewModels

- `TransactionsViewModel` — обновить create/update/delete через RPC
- Новый `SettlementViewModel` — загружает участников, вычисляет балансы через `SettlementCalculator`, создаёт settlement-запись

### Сервис SettlementCalculator

```swift
enum SettlementCalculator {
    struct MemberBalance: Sendable {
        let userId: String
        let contributed: Int64   // сумма всех transfer-in со своих счетов минус transfer-out
        let fairShare: Int64     // equal split = totalExpenses / memberCount
        let delta: Int64         // contributed - fairShare (+ = вложил больше, - = должен)
    }

    struct SettlementSuggestion: Sendable {
        let fromUserId: String
        let toUserId: String
        let amount: Int64
    }

    static func compute(
        sharedAccountId: String,
        transactions: [Transaction],
        memberIds: [String],
        personalAccountsByUser: [String: [String]],  // user_id → [personal_account_id]
        period: DateInterval
    ) -> [MemberBalance]

    /// Greedy min-cash-flow. For 2 members — один settlement. Для N — до N-1.
    static func settlements(from balances: [MemberBalance]) -> [SettlementSuggestion]
}
```

Покрыть юнит-тестами:
- 2 участника, базовый случай
- 3+ участника, неравные вклады
- Все равны (delta = 0)
- Один не внёс ничего
- Один переплатил в 2x

### Views

**1. `TransactionFormView` — новая секция «Оплачено с»:**

```
┌─ Детали расхода ──────────────────────┐
│ Счёт:          [Семейный ▾]           │
│ Сумма:         1 500 ₽                │
│ Категория:     Еда                    │
│ Дата:          Сегодня                │
│ Оплачено с:    [Тинькофф (моё) ▾] ⭐   │
│                                        │
│ ℹ️ Создадим перевод 1 500 ₽ с         │
│    Тинькофф на Семейный.              │
└───────────────────────────────────────┘
```

Picker показывает:
- Целевой счёт сам (🔹 дефолт для личных счетов)
- Все личные счета юзера (включая cash)
- ⭐ рядом с дефолтом из `user_account_defaults`

При первом выборе source ≠ target — автоматически обновляется `user_account_defaults` (чтобы в следующий раз подставилось то же).

**2. Новая `SharedAccountDetailView`:**

Открывается при тапе на shared-счёт в `AccountCarouselView` или через отдельный NavLink.

Структура:
```
[Шапка с балансом]
[Participant settlement card] ← новое
[Recent transactions list]
[Account settings / invite members]
```

Settlement card (см. UX пример в обсуждении): баланс по участникам + suggested settlements + кнопка «Отметить выполненным» (создаёт запись в `settlements`).

Period picker: `This month` (default) / `Last month` / `Quarter` / `YTD` / `Custom`.

**3. `TransactionDetailView` — индикатор авто-перевода:**

Если у расхода есть `autoTransferGroupId` — показать бейдж «💳 Из Тинькофф (Тинькофф)» со ссылкой на связанную transfer-пару (readonly). Кнопка «Удалить» удаляет всю тройку через RPC.

**4. `SettingsView` → новая секция «Способы оплаты»:**

Список всех общих счетов юзера + per-account выбор дефолтной источник-карты. Для личных — не показывается.

**5. `Views/Account/AccountSettlementCardView.swift` — компонент для переиспользования.**

### Локализация (RU/EN/ES)

Ключи:
- `tx.paymentSource` — «Оплачено с»
- `tx.paymentSource.hint.autoTransfer` — «Создадим перевод %@ с %@ на %@»
- `tx.paymentSource.default` — «дефолт»
- `tx.autoTransfer.badge` — «Из %@»
- `tx.autoTransfer.deleteWarning` — «Этот перевод связан с расходом «%@». Чтобы удалить, удалите расход.»
- `settlement.title` — «Расчёт между участниками»
- `settlement.period.thisMonth` — «Этот месяц»
- `settlement.balance.positive` — «Вложил больше доли»
- `settlement.balance.negative` — «Должен доплатить»
- `settlement.suggestion` — «%@ → %@: %@»
- `settlement.markSettled` — «Отметить выполненным»
- `settlement.empty` — «Пока нет транзакций за период»

## Тесты

### Unit
- `SettlementCalculatorTests`: 2/3/5 участников, edge cases (0 transactions, single contributor, equal split, over-contribution)
- `TransactionRepositoryTests`: RPC wrapping (нужен mock SupabaseClient или integration tests на test project)

### Integration (через Supabase MCP / staging project)
- Create expense with payment_source → проверить 3 строки в DB с одинаковым `auto_transfer_group_id`
- Delete expense → 3 строки удалены
- Update amount → все 3 строки синхронизированы
- RLS: Оля видит transfer-in на Семейный, не видит transfer-out на Тинькофф Владимира

### UI smoke
- TransactionFormView: дефолт из user_account_defaults подставился
- SharedAccountDetailView: settlement отрисовался, suggestions корректны

## Риски и open issues

1. **Валютная несоответствие источник ≠ целевой счёт** — что если Семейный в RUB, а оплатили с ByBit в USD? MVP: блокируем auto-transfer если валюты разные (disabled picker + подсказка), расход создаётся в валюте целевого счёта без авто-перевода.
2. **Редактирование расхода в старой транзакции** (без auto_transfer_group_id) — пропустить заполнение поля, обычный флоу.
3. **Производительность SettlementCalculator** для счёта с 1000+ транзакций — вычисление за O(N), ok. Кэшируем в `@Observable` через computed property.
4. **Уведомление участников о новых auto-transfer** — out of scope, не нужны push каждый раз.
5. **Concurrent edits** — если Оля в это же время редактирует расход, RPC может конфликтнуть. Использовать Postgres advisory locks или просто optimistic update с переcorrection при конфликте.

## Rollout

1. Миграции применяются через Supabase MCP `apply_migration`
2. iOS выпускается с feature flag `enable_payment_source` (включить через Supabase edge function `feature-flags`)
3. Включаем фичу для beta-группы на 1 неделю
4. Полный релиз в 1.3.0

## Декомпозиция для team-lead (1-2 спринта)

### Спринт 1 — Core flow
- DB: 3 миграции + 3 RPC функции + RLS
- iOS: модели + репозитории + TransactionRepository через RPC
- iOS: TransactionFormView payment source picker
- iOS: TransactionDetailView badge + deletion with warning
- iOS: SettingsView payment defaults
- Тесты: unit + integration for RPC

### Спринт 2 — Settlement
- iOS: SettlementCalculator + юнит-тесты
- iOS: SharedAccountDetailView + SettlementCardView
- iOS: Settlement sheet (mark settled, period picker)
- iOS: локализация
- Тесты: SettlementCalculator edge cases
- Integration: RLS visibility end-to-end

### Зависимости
- Сначала миграции → потом RPC → потом iOS
- SettlementCalculator не зависит от payment source (работает и на старых ручных переводах)

## References

- Roadmap Phase 2: Subscriptions + Budgets integration (precedent for cross-account logic)
- `Repositories/TransactionRepository.swift` (current CRUD)
- `Views/Transactions/TransactionFormView.swift` (where pickers live)
- `Views/Home/AccountCarouselView.swift` (entry point to SharedAccountDetailView)
- Memory `project_shared_accounts_categories.md` (existing shared-account reporting logic)
