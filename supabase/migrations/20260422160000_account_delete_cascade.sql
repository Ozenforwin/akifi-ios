-- Scenario 6: account deletion currently orphans transactions.
-- `transactions.account_id` was `ON DELETE SET NULL`, so deleting an
-- account left its rows with `account_id = NULL`. The iOS read-path
-- then interpreted `amount_native` as the user's base currency (the
-- fallback in `TransactionMath.amountInBase`) — exactly the VND-as-RUB
-- class of bug we fixed for live accounts. Plus the TMA confirmation
-- dialog promised «Все транзакции будут удалены» which was a lie.
--
-- Resolution per user decision (2026-04-22): flip the FK to CASCADE so
-- account deletion actually removes the transactions — matching what the
-- user is told. Other FKs (savings_goals, subscriptions, receipt_scans,
-- transactions.payment_source_account_id) stay on SET NULL because
-- those entities outlive the account semantically:
--   - savings goal "vacation in Bali" is meaningful even if the funding
--     account is closed
--   - subscription tracker is about the service, not the payment method
--   - receipt scan is raw evidence — survives rebucketing
--   - payment_source_account_id on a tx only disambiguates WHO paid on
--     a shared account; dropping it doesn't invalidate the expense
--
-- Note on auto-transfer triplets: 2 in prod at migration time. A delete
-- of one account CASCADEs that account's leg(s) only; the other legs of
-- the same `auto_transfer_group_id` become orphans. Out of scope here —
-- deletion of account-with-triplets is rare and the remaining legs are
-- still valid financial history on their own accounts.

BEGIN;

-- `transactions_account_id_fkey` is the one that matters.
ALTER TABLE transactions
    DROP CONSTRAINT transactions_account_id_fkey,
    ADD  CONSTRAINT transactions_account_id_fkey
        FOREIGN KEY (account_id) REFERENCES accounts(id)
        ON DELETE CASCADE;

COMMIT;
