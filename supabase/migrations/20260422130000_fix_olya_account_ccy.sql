-- Reconciliation: `Оля зарубежный` account was labelled USD but 71
-- historical transactions on it were actually written in RUB. All
-- description/amount pairs make sense only in roubles ("Психолог 2500",
-- "Симка Вьетнам 1349.91", "iPad 42578"); reading `amount_native`
-- through USD inflated monthly totals ~80×.
--
-- User (owner) confirmed the account is fact-in-rubles. Simplest
-- correct fix: flip `accounts.currency` to RUB. `amount_native` stays
-- untouched — it's already the right number in the right unit, only
-- the label lied. This also aligns with `initial_balance = 57 399`
-- which only makes sense as roubles for this user's history.
--
-- Scope: only the single account. Does NOT retroactively touch rows
-- that already have a non-RUB `foreign_currency` on this account (none
-- currently exist, but the guard makes the migration idempotent and
-- safe to re-run).

BEGIN;

CREATE SCHEMA IF NOT EXISTS backup_20260422;

-- Snapshot the account row and all its transactions before mutation.
CREATE TABLE IF NOT EXISTS backup_20260422.accounts_olya_ccy_fix AS
SELECT * FROM accounts
WHERE id = 'd5083910-57bd-40af-8163-c74bc3b49b29';

CREATE TABLE IF NOT EXISTS backup_20260422.transactions_olya_ccy_fix AS
SELECT * FROM transactions
WHERE account_id = 'd5083910-57bd-40af-8163-c74bc3b49b29';

-- Flip the account currency. initial_balance is already a rouble number
-- (57 399) so no rescale is needed.
UPDATE accounts
SET currency = 'rub'
WHERE id = 'd5083910-57bd-40af-8163-c74bc3b49b29'
  AND currency = 'usd';

-- Normalize transaction labels on this account to RUB where they
-- carried the stale USD / RUB / NULL tag but the number itself is
-- already in roubles. Skip rows that legitimately have `foreign_*`
-- populated (user genuinely entered in another currency).
UPDATE transactions
SET currency = 'RUB'
WHERE account_id = 'd5083910-57bd-40af-8163-c74bc3b49b29'
  AND foreign_amount IS NULL
  AND (currency IS NULL OR UPPER(currency) <> 'RUB');

COMMIT;
