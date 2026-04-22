#!/usr/bin/env bash
# lint-amount-usage.sh
#
# Guard against regressions of the ADR-001 multi-currency bug.
# `Transaction.amount` (Swift) and `tx.amount` (edge function TS) are the
# legacy fields that sum foreign-currency values as if they were base
# currency. All aggregation must go through `amountInBase` / `amount_native`.
#
# The script greps the codebase for direct reads of these fields and
# fails (exit 1) if any hit appears outside the allowlist of model /
# repository files where the legacy column legitimately still lives.
#
# Usage:
#   ./Scripts/lint-amount-usage.sh           # soft mode: warnings only
#   ./Scripts/lint-amount-usage.sh --strict  # hard mode: exit 1 on any hit
#
# Allowlist philosophy:
#   - Transaction.swift  — model definition, encode/decode round-trip
#   - TransactionMath.swift — declares the correct helpers
#   - TransactionRepository.swift — serializes legacy column over the wire
#   - Decimal+Currency.swift — pure Decimal math (not tx-scoped)
#   - Edge function types.ts + index.ts SELECT strings (schema contract)
#
# Anything else hitting `.amount` / `tx.amount` is a candidate bug.

set -uo pipefail

STRICT=0
if [[ "${1:-}" == "--strict" ]]; then
    STRICT=1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SWIFT_ALLOWLIST=(
    "AkifiIOS/Models/Transaction.swift"
    "AkifiIOS/Services/TransactionMath.swift"
    "AkifiIOS/Repositories/TransactionRepository.swift"
    "AkifiIOS/Extensions/Decimal+Currency.swift"
)

TS_ALLOWLIST=(
    "supabase/functions/assistant-query/types.ts"
    "supabase/functions/assistant-query/index.ts"
)

strip_allowlisted() {
    # Reads from stdin, strips lines whose path matches any allowlisted file.
    local files=("$@")
    local pattern
    pattern=$(printf '%s|' "${files[@]}")
    pattern="${pattern%|}"
    grep -v -E "^($pattern):" || true
}

# ── Swift: aggregation-shaped reads of `.amount` on a transaction.
# Focus on `reduce ... .amount`, `abs(... .amount)`, and `+= ... .amount`
# patterns — these are the aggregation boundaries where ADR-001 breaks.
# Sorting/comparing `.amount` (e.g. `{ $0.amount > $1.amount }`) is safe
# because `amountNative == amount` on post-migration rows.
echo "── Swift aggregations via legacy .amount ──"
SWIFT_HITS=$(
    grep -rn --include='*.swift' \
        -E '\b(reduce|\+=|abs\()[^;]*\.amount\b' \
        AkifiIOS AkifiIOSTests 2>/dev/null \
    | grep -v -E 'amountNative|amount_native|amountInBase|\.amount\.displayAmount|// allowlisted-amount:' \
    | grep -v -E '^[^:]+:[0-9]+:[[:space:]]*///' \
    | strip_allowlisted "${SWIFT_ALLOWLIST[@]}" \
    || true
)

SWIFT_COUNT=0
if [[ -n "$SWIFT_HITS" ]]; then
    SWIFT_COUNT=$(echo "$SWIFT_HITS" | wc -l | tr -d ' ')
    echo "$SWIFT_HITS"
fi

# ── TypeScript edge functions: `tx.amount` without `amount_native` nearby
echo ""
echo "── Edge function aggregations via legacy tx.amount ──"
TS_HITS=$(
    grep -rn --include='*.ts' \
        -E '\btx\.amount\b' \
        supabase/functions 2>/dev/null \
    | grep -v -E 'amount_native|amount_in_base|// allowlisted-amount:' \
    | strip_allowlisted "${TS_ALLOWLIST[@]}" \
    || true
)

TS_COUNT=0
if [[ -n "$TS_HITS" ]]; then
    TS_COUNT=$(echo "$TS_HITS" | wc -l | tr -d ' ')
    echo "$TS_HITS"
fi

TOTAL=$((SWIFT_COUNT + TS_COUNT))

echo ""
if [[ $TOTAL -eq 0 ]]; then
    echo "✅ No legacy .amount usage detected (ADR-001 compliant)"
    exit 0
fi

echo "⚠️  Found $TOTAL legacy .amount usage(s) outside allowlist"
echo "   See ADR-001 and /.claude/plans/cosmic-purring-wand.md"
echo "   To suppress a legitimate case: append '// allowlisted-amount: reason'"

if [[ $STRICT -eq 1 ]]; then
    echo ""
    echo "❌ Strict mode: failing CI"
    exit 1
fi

exit 0
