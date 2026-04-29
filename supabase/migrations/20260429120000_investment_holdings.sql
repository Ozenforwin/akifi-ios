-- Investment holdings: позиции внутри Asset (брокерский счёт / wallet / stash).
-- Один Asset (категории investment / crypto) может содержать N позиций
-- (тикер × количество × цена). Asset.current_value становится derived —
-- AFTER STATEMENT триггер пересчитывает его одним UPDATE на затронутые asset_id.
--
-- Для прочих категорий (real_estate / vehicle / collectible / cash / other)
-- holdings отсутствуют и assets.current_value по-прежнему вводится руками.

CREATE TABLE IF NOT EXISTS investment_holdings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE DEFAULT auth.uid(),
    asset_id UUID NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
    ticker TEXT NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN (
        'stock', 'etf', 'bond', 'crypto', 'metal', 'fund', 'other'
    )),
    -- 8 знаков после запятой — достаточно для крипты (1 satoshi = 0.00000001 BTC).
    quantity NUMERIC(28,8) NOT NULL CHECK (quantity >= 0),
    -- Средняя цена покупки × quantity, в minor units (kopecks) валюты родительского Asset.
    cost_basis BIGINT NOT NULL CHECK (cost_basis >= 0),
    -- Текущая цена за единицу, в той же валюте, что и Asset.
    last_price NUMERIC(20,8) NOT NULL CHECK (last_price >= 0),
    last_price_date DATE NOT NULL,
    notes TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_holdings_asset ON investment_holdings(asset_id);
CREATE INDEX IF NOT EXISTS idx_holdings_user  ON investment_holdings(user_id);

ALTER TABLE investment_holdings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "holdings_own_select" ON investment_holdings;
DROP POLICY IF EXISTS "holdings_own_insert" ON investment_holdings;
DROP POLICY IF EXISTS "holdings_own_update" ON investment_holdings;
DROP POLICY IF EXISTS "holdings_own_delete" ON investment_holdings;

CREATE POLICY "holdings_own_select" ON investment_holdings FOR SELECT USING (user_id = auth.uid());
CREATE POLICY "holdings_own_insert" ON investment_holdings FOR INSERT WITH CHECK (user_id = auth.uid());
CREATE POLICY "holdings_own_update" ON investment_holdings FOR UPDATE USING (user_id = auth.uid());
CREATE POLICY "holdings_own_delete" ON investment_holdings FOR DELETE USING (user_id = auth.uid());

-- updated_at триггер: тот же шаблон, что и в других таблицах (assets / liabilities).
CREATE OR REPLACE FUNCTION set_investment_holdings_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_holdings_updated_at ON investment_holdings;
CREATE TRIGGER trg_holdings_updated_at
    BEFORE UPDATE ON investment_holdings FOR EACH ROW
    EXECUTE FUNCTION set_investment_holdings_updated_at();

-- Пересчёт assets.current_value по затронутым asset_id одним UPDATE.
--
-- AFTER STATEMENT (а не FOR EACH ROW) — чтобы bulk-импорт N позиций не
-- превращался в O(N²). Объединяем NEW и OLD таблицы (для UPDATE и DELETE
-- они обе непустые), берём DISTINCT asset_id, считаем сумму позиций.
--
-- Важно:
-- * `current_value` хранится в kopecks: `ROUND(SUM(quantity * last_price) * 100)`.
-- * Защита от переполнения BIGINT: `LEAST(..., 9223372036854775807)`.
-- * Применяется только для категорий investment / crypto. Остальные
--   категории трогать нельзя — там пользователь сам вводит currentValue.
-- * NULLIF для случая, когда все позиции удалены: SUM возвращает NULL,
--   COALESCE ставит 0 (asset остаётся существующим, но обнулённым).
CREATE OR REPLACE FUNCTION recompute_asset_value_on_holding_change()
RETURNS TRIGGER AS $$
DECLARE
    affected_ids UUID[];
BEGIN
    IF TG_OP = 'DELETE' THEN
        SELECT ARRAY(SELECT DISTINCT asset_id FROM old_table) INTO affected_ids;
    ELSIF TG_OP = 'INSERT' THEN
        SELECT ARRAY(SELECT DISTINCT asset_id FROM new_table) INTO affected_ids;
    ELSE -- UPDATE
        SELECT ARRAY(
            SELECT DISTINCT asset_id FROM (
                SELECT asset_id FROM old_table
                UNION
                SELECT asset_id FROM new_table
            ) ids
        ) INTO affected_ids;
    END IF;

    UPDATE assets a
    SET current_value = LEAST(
        COALESCE(
            (SELECT ROUND(SUM(h.quantity * h.last_price) * 100)::BIGINT
               FROM investment_holdings h
              WHERE h.asset_id = a.id),
            0
        ),
        9223372036854775807
    )
    WHERE a.id = ANY(affected_ids)
      AND a.category IN ('investment', 'crypto');

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_holdings_recompute_insert ON investment_holdings;
DROP TRIGGER IF EXISTS trg_holdings_recompute_update ON investment_holdings;
DROP TRIGGER IF EXISTS trg_holdings_recompute_delete ON investment_holdings;

CREATE TRIGGER trg_holdings_recompute_insert
    AFTER INSERT ON investment_holdings
    REFERENCING NEW TABLE AS new_table
    FOR EACH STATEMENT
    EXECUTE FUNCTION recompute_asset_value_on_holding_change();

CREATE TRIGGER trg_holdings_recompute_update
    AFTER UPDATE ON investment_holdings
    REFERENCING OLD TABLE AS old_table NEW TABLE AS new_table
    FOR EACH STATEMENT
    EXECUTE FUNCTION recompute_asset_value_on_holding_change();

CREATE TRIGGER trg_holdings_recompute_delete
    AFTER DELETE ON investment_holdings
    REFERENCING OLD TABLE AS old_table
    FOR EACH STATEMENT
    EXECUTE FUNCTION recompute_asset_value_on_holding_change();
