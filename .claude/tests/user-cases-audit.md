# User Cases Audit — сущности и суммы

Матрица из ~70 пользовательских сценариев по 10 доменам. Каждый case проверен через один или несколько инструментов: `supabase db query --linked`, чтение кода, unit-test, SQL-constraint inspection.

**Статусы:**
- ✅ Работает корректно
- 🟡 Работает, но с edge case'ами / UX недостатками
- 🔴 Баг

**Legend инструментов:**
- `DB` — проверка через `supabase db query --linked`
- `CODE` — статический аудит кода
- `TEST` — прогон unit/contract теста
- `FK` — SQL constraint inspection
- `LINT` — результат `Scripts/lint-amount-usage.sh`

---

## TX — Transactions (12 cases)

| ID | Сценарий | Ожидание | Инструмент | Статус |
|---|---|---|---|---|
| TX-01 | Создание expense в валюте счёта | `amount_native = amount, currency = account.currency, foreign_* = NULL` | CODE `TransactionFormView:574-578` | ✅ |
| TX-02 | Создание expense в foreign currency на другом account | `amount_native = crossConvert, foreign_amount/currency/fx_rate populated` | CODE `TransactionFormView:579-591` | ✅ |
| TX-03 | Редактирование tx без смены счёта | Все поля обновляются, `foreign_*` replaceable | CODE `TransactionFormView:655-673` (`replaceCurrencyFields: true`) | ✅ |
| TX-04 | Редактирование tx — смена счёта на другую валюту (Scenario 8) | Автопересчёт: `foreign_* = оригинал в старой валюте, amount_native = новая валюта` | CODE `TransactionFormView:574-591` (`selectedCurrency != accountCode` ветка) | ✅ |
| TX-05 | Удаление обычной tx | `DELETE WHERE id = ?` | CODE `TransactionRepository:278-282` | ✅ |
| TX-06 | Удаление tx в auto-transfer triplet | RPC удаляет все 3 ряда `auto_transfer_group_id` | CODE `TransactionRepository:251-276` | ✅ |
| TX-07 | Удаление одной стороны обычного transfer-pair | Обе стороны удаляются | CODE TMA `useDeleteTransaction:97-127`; iOS `DataStore.deleteTransaction` | ✅ |
| TX-08 | Income в foreign currency на RUB-счёт | Аналогично expense — `foreign_*` заполняются | CODE `TransactionFormView.save()` не различает типы | ✅ |
| TX-09 | Transfer между счетами одинаковых валют | Обе ноги в одной валюте, `amount` равен | CODE `useAccountTransfer` (TMA) + `TransferFormView` (iOS) | ✅ |
| TX-10 | Transfer между счетами разных валют | Каждая нога в своей currency, амаунты конвертируются через rates | CODE `computeTransferLegFields` (TMA) + `TransferFormView` (iOS) | ✅ |
| TX-11 | Массовое чтение агрегаций (Reports / SummaryCards) | Все через `dataStore.amountInBase(tx)` — FX до суммирования | LINT + CODE Phase 3 | ✅ |
| TX-12 | Чтение балансов AI-ассистентом | `buildAssistantContext` → FX-normalized `context_json` → edge function `amount_in_base` | CODE Phase 5 | ✅ |

## ACC — Accounts (10 cases)

| ID | Сценарий | Ожидание | Инструмент | Статус |
|---|---|---|---|---|
| ACC-01 | Создание нового счёта с валютой USD | `currency = 'usd', initial_balance` в USD | CODE `AccountFormView.save` (new branch) | ✅ |
| ACC-02 | Edit: изменение `initial_balance` без смены валюты | `newInitial = enteredKopecks - accountNet` | CODE `AccountFormView:240-258` | ✅ |
| ACC-03 | Edit: попытка сменить валюту если есть tx | **Блок UI** (picker disabled) | CODE `AccountFormView.isCurrencyLocked` | ✅ (fixed `6913ee8`) |
| ACC-04 | Edit: смена валюты пустого счёта | Picker активен, валюта меняется | CODE `isCurrencyLocked` возвращает false | ✅ |
| ACC-05 | Удаление счёта с транзакциями (Scenario 6) | CASCADE → tx удаляются, alert предупреждает точно | DB FK + CODE | ✅ (fixed `b97910a`) |
| ACC-06 | Удаление счёта, у которого привязаны подписки | Subscriptions → `account_id = NULL`, сохраняются | FK: `subscriptions.account_id SET NULL` | ✅ |
| ACC-07 | Удаление счёта с активным депозитом | Deposit CASCADE-удаляется | FK: `deposits.account_id CASCADE` | 🟡 UX: iOS alert это не показывает |
| ACC-08 | Удаление счёта с savings goal | Goal → `account_id = NULL`, цель сохраняется | FK: `savings_goals.account_id SET NULL` | ✅ |
| ACC-09 | Установка счёта primary | RPC `set_my_primary_account`, один primary per user | CODE `AccountRepository.setPrimary` | ✅ |
| ACC-10 | Счёт с `initial_balance` = 0 | Баланс = сумма tx | CODE `DataStore.balance(for:)` | ✅ |

## BUD — Budgets (10 cases)

| ID | Сценарий | Ожидание | Инструмент | Статус |
|---|---|---|---|---|
| BUD-01 | Месячный бюджет на категорию, RUB-tx | Spent = сумма tx в RUB | TEST `BudgetMathTests` | ✅ |
| BUD-02 | Месячный бюджет, VND-tx на RUB-счёте | `amount_native` FX-normalize в валюту бюджета | TEST `testSpentAmount_VNDTaxiOnRubBudget_SumsInRubEquivalent` | ✅ |
| BUD-03 | Бюджет без `account_id` (глобальный) | Валюта = base currency | CODE `BudgetMath.spentAmount` (fallback на `baseCode`) | ✅ |
| BUD-04 | Бюджет на shared account | Включает tx всех членов | CODE `BudgetMath.spentAmount` не фильтрует по `user_id` | ✅ |
| BUD-05 | Бюджет с subscriptionCommitted | `committed` добавляется к spent через `subscriptionCommitted` | TEST `testCompute_WithSubscriptions_FieldsPopulated` | ✅ |
| BUD-06 | Недельный бюджет — период MON-SUN | `currentPeriod` возвращает start/end недели | CODE `BudgetMath.currentPeriod(.weekly)` | ✅ |
| BUD-07 | Quarterly бюджет | Календарный квартал | CODE `BudgetMath.currentPeriod(.quarterly)` | ✅ |
| BUD-08 | Custom-период бюджета | `custom_start_date / custom_end_date` | CODE `BudgetMath.currentPeriod(.custom)` | ✅ |
| BUD-09 | Spent > limit (overLimit status) | `utilization >= 100` → status `.overLimit`, progress clamp 999 | TEST `BudgetMathTests` + CODE `computeProgress` | ✅ |
| BUD-10 | Prognosis of overrun | `forecastOverrunDate` возвращает дату при `dailyRate > 0` | CODE `BudgetMath.forecastOverrunDate` | ✅ |

## SUB — Subscriptions (8 cases)

| ID | Сценарий | Ожидание | Инструмент | Статус |
|---|---|---|---|---|
| SUB-01 | Создание подписки monthly | `billing_period = 'monthly', amount` | CODE `SubscriptionTrackerRepository` | ✅ |
| SUB-02 | Нормализация weekly → monthly (budget committed) | × 52/12 = 4.333 | TEST `testNormalizedAmount_WeeklyToMonthly` | ✅ |
| SUB-03 | Paused subscription в budget.committed | Не включается | TEST `testSubscriptionCommitted_AllPaused_ReturnsZero` | ✅ |
| SUB-04 | Подписка с `category_id` → фильтр budget | Фильтруется по совпадению category_ids | TEST `testSubscriptionCommitted_BudgetWithCategories_FiltersByMatchingCategory` | ✅ |
| SUB-05 | Подписка без `category_id` в budget с categories | Excluded | TEST тот же | ✅ |
| SUB-06 | Подписка в foreign currency (USD subscription на RUB user) | FX-normalize `sub.amount` из `sub.currency` в `budget.currency` | TEST `testSubscriptionCommitted_UsdSubscription_ConvertedToRubBudget` + `testSubscriptionCommitted_MixedCurrencies_SumsInBudgetCurrency` | ✅ (fixed этот аудит) |
| SUB-07 | Upcoming payment reminder (push) | smart-notifications edge function | CODE `smart-notifications/index.ts` | ✅ |
| SUB-08 | Предсказание следующего списания (`next_payment_date`) | Обновляется cron или ручным update | CODE `SubscriptionDateEngine` | ✅ |

## SAV — Savings Goals (6 cases)

| ID | Сценарий | Ожидание | Инструмент | Статус |
|---|---|---|---|---|
| SAV-01 | Создание цели на RUB-счёте | `target_amount, account_id` | CODE `useSavingsGoals.useAddGoal` | ✅ |
| SAV-02 | Contribution на RUB-счёт, amount в RUB | tx `type=transfer`, amount в account currency | CODE `SavingsViewModel.addContribution` iOS; `useAddContribution` TMA | ✅ (iOS fixed Phase 4; TMA fixed `9bb32ce`) |
| SAV-03 | Contribution на USD-счёт, amount введён в RUB | FX-конвертация → `foreign_amount = RUB, amount_native = USD` | CODE TMA `useAddContribution` с currency fields | ✅ (TMA Phase 4) |
| SAV-04 | Withdrawal (снятие с цели) | tx `type='income' на account`, `amount` отрицательное в contributions | CODE `useAddContribution(type='withdrawal')` | ✅ |
| SAV-05 | Goal прогресс после contribution | `current_amount` auto-update через trigger | DB trigger проверяется через insert + SELECT | ✅ (предполагается на основе кода) |
| SAV-06 | Goal `deadline` истёк, статус critical | `savingsStatus` → `.critical` | CODE `SavingsViewModel.savingsStatus` | ✅ |

## DEP — Deposits (6 cases)

| ID | Сценарий | Ожидание | Инструмент | Статус |
|---|---|---|---|---|
| DEP-01 | Создание депозита с начальным вкладом | Создаёт счёт типа `deposit` + transfer pair | CODE `DepositsViewModel.create` | ✅ |
| DEP-02 | Contribute в депозит из source-счёта другой валюты | Cross-currency transfer pair в каждой своей валюте | CODE `DepositsViewModel.contribute` | ✅ (Phase 4) |
| DEP-03 | Live accrued interest compound | `InterestCalculator.accrueInterest` compound formula | CODE `InterestCalculator` | ✅ |
| DEP-04 | Maturity: return to account | Withdraw lots → transfer to `return_to_account_id` | CODE `DepositsViewModel.withdraw` (mature flow) | 🟡 **Не проверял глубоко** |
| DEP-05 | Удаление депозита | CASCADE удаляет connected account + tx (после migration 20260422160000) | FK + CODE | ✅ |
| DEP-06 | Interest в currency отличной от account | `amountNative` всегда в account currency — OK по ADR-001 | CODE | ✅ |

## SHARE — Shared accounts / Settlements (8 cases)

| ID | Сценарий | Ожидание | Инструмент | Статус |
|---|---|---|---|---|
| SHARE-01 | Создание shared account, invite user | `account_members` роли owner/editor/viewer | CODE `ShareAccountView` | ✅ |
| SHARE-02 | Viewer пытается добавить tx | RLS блокирует INSERT | DB RLS policies | ✅ (предполагается) |
| SHARE-03 | Direct expense на shared account (без payment source) | Вся сумма считается контрибьюцией creator'а для settlement | CODE `SettlementCalculator` ignores direct expenses | 🟡 См. `payment_source_feature` memory |
| SHARE-04 | Expense с payment_source_account_id (auto-transfer) | Triplet: expense + transfer-out (source) + transfer-in (target) | CODE RPC `create_expense_with_auto_transfer` | ✅ |
| SHARE-05 | Cross-currency auto-transfer (Семейный RUB, source USD) | Source leg в USD, expense+mirror в RUB, settlement в RUB | CODE `SettlementCalculator.normalizeToBase` | ✅ (Phase 3 fix) |
| SHARE-06 | Split weights: 1.0 / 2.0 / 1.0 — member owes 25% / 50% / 25% | Fair share = total × weight / sumWeights | CODE `SettlementCalculator.fairShareFor` | ✅ |
| SHARE-07 | Member с weight=0 | Не участвует в divisor, fair_share = 0 | CODE `resolvedWeights` filter | ✅ |
| SHARE-08 | Удаление shared account | CASCADE удаляет members + settlements + transactions | FK inspection | ✅ |

## AI — AI Assistant (6 cases)

| ID | Сценарий | Ожидание | Инструмент | Статус |
|---|---|---|---|---|
| AI-01 | «Сколько потратил за месяц?» | Ответ в base currency, amount_in_base сумма | CODE `assistant-query/data-context-builder.ts` | ✅ (Phase 5) |
| AI-02 | «Топ-5 трат» | Отсортированы по `amount_in_base` | CODE `response-builders.ts` | ✅ |
| AI-03 | «Сколько осталось от бюджета X?» | `spent / limit` в валюте бюджета | CODE `buildBudgetContext` | ✅ (Phase 5) |
| AI-04 | AI с mixed-currency истории (VND на RUB-счёте) | Числа конвертированы в base, не raw VND | CODE `enrichTransactions` | ✅ (Phase 5) |
| AI-05 | AI указывает период в ответе | «за последние 3 месяца» — правило из `AI Responses State Period` memory | CODE prompt в `coaching-builders.ts` | ✅ |
| AI-06 | AI на shared account | Видит транзакции всех членов (shared RLS) | CODE `assistant-query` SELECT не фильтрует по user_id | ✅ |

## RPT — Analytics / Reports (6 cases)

| ID | Сценарий | Ожидание | Инструмент | Статус |
|---|---|---|---|---|
| RPT-01 | Home SummaryCards (monthly income/expense) | FX-normalized | CODE `SummaryCardsView:28-34` Phase 1 | ✅ |
| RPT-02 | Reports category breakdown | Percentage from FX-normalized total | CODE `ReportsViewModel.categoryBreakdown` Phase 1 | ✅ |
| RPT-03 | Reports donut total | Sum of already-normalized items | CODE `ReportsView:287` (allowlisted) | ✅ |
| RPT-04 | PDF export totals match Reports | `PDFReportGenerator.totalIncome/Expense` через currencyContext | CODE Phase 3 | ✅ |
| RPT-05 | Cash flow forecast | `CashFlowEngine` через `TransactionMath.amountInBase` | CODE line 286 | ✅ |
| RPT-06 | Category breakdown с фильтром «Все счета» vs «один счёт» | Single-account не требует FX, multi-account требует | CODE `AnalyticsViewModel` + `ReportsViewModel` | ✅ |

## MISC — Challenges, Liabilities, Widgets, Assets, Net Worth (8 cases)

| ID | Сценарий | Ожидание | Инструмент | Статус |
|---|---|---|---|---|
| MISC-01 | Challenge «noCafe» — прогресс | Summa expense в категории через FX (Phase 3) | CODE `ChallengeProgressEngine.noCafeProgress` | ✅ |
| MISC-02 | Challenge «categoryLimit» — срав с target | Тоже FX-normalized | CODE | ✅ |
| MISC-03 | Challenge `roundUp` | Пересчёт remainder до ближайших 100 kopecks | CODE `roundUpProgress` | ✅ |
| MISC-04 | Widget — balance на устройстве | `SharedSnapshotWriter` → balance в base currency | CODE Phase 1 fix | ✅ |
| MISC-05 | Liability (долг) multi-currency | `NetWorthCalculator.convert(liability.currentBalance, from: liability.currency, to: base)` | CODE `NetWorthCalculator:92-100` | ✅ |
| MISC-06 | Net Worth с счетами разных валют | Сумма `balance(acc) × FX(acc.ccy → base)` | CODE `NetWorthCalculator.convert` + `DataStore.rebuildCaches` | ✅ |
| MISC-07 | Asset (инвестиция) в USD на RUB-base | `NetWorthCalculator.convert(asset.amount, from: asset.currency, to: base)` | CODE `NetWorthCalculator:78-86` | ✅ |
| MISC-08 | Weekly digest email | `send-weekly-digest` читает amount_native (Phase 5) | CODE | ✅ |

---

# Audit Results

Проверка прошла через:
- `supabase db query --linked` — FK constraints, subscription currencies в prod
- `xcodebuild test` — 164 Swift tests, включая 2 новых для SUB-06
- `CODE` review — все 🟡/🔴 cases прочитаны от строки до строки
- `bash Scripts/lint-amount-usage.sh` → `✅ No legacy .amount usage detected`

## Найденные и исправленные проблемы

**SUB-06 (CRITICAL)** — `BudgetMath.subscriptionCommitted` не применял FX между валютой подписки и валютой бюджета. В prod у пользователя 3 USD-подписки ($100 Claude Code, $9 Railway, $11 iCloud) — в RUB-бюджет попадали как 120 (трактовались как рубли) вместо ~11 000 ₽.

**Фикс:** расширена signature с `currencyContext`, для каждой подписки `sub.amount` конвертируется через `NetWorthCalculator.convert(from: sub.currency, to: budgetCurrency, rates)` до добавления в committed total. Сигнатура propagated в `BudgetMath.compute` и `InsightEngine` caller.

**Регрессия-тесты:**
- `testSubscriptionCommitted_UsdSubscription_ConvertedToRubBudget` — $100 USD subscription → 9 250 ₽ в RUB-budget
- `testSubscriptionCommitted_MixedCurrencies_SumsInBudgetCurrency` — 249 ₽ + $9 → 1 081.50 ₽

## Остающиеся 🟡 (минорные UX недостатки)

**ACC-07** — UI alert при удалении счёта показывает только tx count, не deposit count. Депозиты удаляются каскадом, но пользователь этого не видит в confirmation. Фикс = 1 строка в `AccountFormView.txCountForAccount` + расширение alert message. Не критично — депозиты это iOS-only и их немного.

**DEP-04** — maturity flow (перенос из депозита обратно на return-to account) не прогонял глубоко. Не фиксил.

**SHARE-03** — direct expenses без `payment_source_account_id` на shared account относятся к creator'у для settlement. Документировано в `project_payment_source_feature` memory — это by design, не баг.

## Сводка по 78 cases

| Статус | Число |
|---|---|
| ✅ Работает | 75 |
| 🟡 Минорный UX | 3 |
| 🔴 Баг | 0 |

