#!/usr/bin/env bash
# lint-amount-usage.sh
#
# Guard against regressions of the ADR-001 multi-currency bug (see
# .claude/adr/ADR-001-multi-currency.md). Thin wrapper: the analysis lives in
# Scripts/lint_amount_usage.py, which understands multi-line statements and
# closures, `x = x + tx.amount`, `.map(\.amount)`, and flags amountNative sums
# that show neither a conversion nor a single-account scope.
#
# Usage:
#   bash Scripts/lint-amount-usage.sh             # soft mode: warnings only
#   bash Scripts/lint-amount-usage.sh --strict    # CI: exit 1 on any hit
#   bash Scripts/lint-amount-usage.sh --root DIR  # lint another tree (fixture tests)
#
# Suppress a deliberate case with `// allowlisted-amount: <reason>` on the
# statement or on the comment line directly above it.
set -uo pipefail
exec python3 "$(cd "$(dirname "$0")" && pwd)/lint_amount_usage.py" "$@"
