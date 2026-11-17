#!/usr/bin/env bash
# lint-date-formatters.sh
#
# Guard against bare `DateFormatter()` / `ISO8601DateFormatter()` in app code.
#
# A bare formatter inherits the device's calendar, locale and 12/24-hour
# setting. With the region set to Thailand the calendar is Buddhist, so
# "yyyy" writes 2569 and the transaction falls out of every month; with a
# 12-hour override a fixed "HH:mm" can come back as "1:05 PM". Any string that
# is stored in or parsed from the database must not depend on that (D1,
# 2026-11-17 review). Every parsing/writing formatter comes from the factory in
# AkifiIOS/Services/DateFormatters.swift (en_US_POSIX + gregorian + explicit
# time zone).
#
# Display formatters that must follow the user's locale are allowed when the
# construction line (or the line right above it) carries
#     // date-formatter-ok: <reason>
# Display is not parsing: never use such a formatter for a stored string.
#
# There is no baseline: every construction outside the factory must be
# annotated (the last 65 were converted or annotated on 2026-11-17).
#
# Usage:
#   bash Scripts/lint-date-formatters.sh           # report, exit 0
#   bash Scripts/lint-date-formatters.sh --strict  # exit 1 on violations (CI)

set -uo pipefail

STRICT=0
if [[ "${1:-}" == "--strict" ]]; then
    STRICT=1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

FACTORY="AkifiIOS/Services/DateFormatters.swift"

SCAN_DIRS=()
for d in AkifiIOS AkifiWidget; do
    [[ -d "$d" ]] && SCAN_DIRS+=("$d")
done

# path:line: code   — one line per unannotated construction outside the factory.
# Matches `DateFormatter()`, `ISO8601DateFormatter()`, `DateFormatter.init()`
# and `let f: DateFormatter = .init()`.
HITS="$(find "${SCAN_DIRS[@]}" -name '*.swift' -type f -print0 | sort -z | xargs -0 awk -v factory="$FACTORY" '
    FNR == 1 { prev = "" }
    {
        line = $0
        code = line
        sub(/^[ \t]+/, "", code)
        bare = (line ~ /DateFormatter[ \t]*(\.init)?[ \t]*\([ \t]*\)/) ||
               (line ~ /DateFormatter[ \t]*=[ \t]*\.init[ \t]*\([ \t]*\)/)
        if (FILENAME != factory && code !~ /^\/\// && bare) {
            ok = (line ~ /date-formatter-ok:[ \t]*[^ \t]/) || (prev ~ /^[ \t]*\/\/.*date-formatter-ok:[ \t]*[^ \t]/)
            if (!ok) print FILENAME ":" FNR ": " code
        }
        prev = line
    }
')"

violations="$(printf '%s\n' "$HITS" | grep -c . || true)"

if (( violations > 0 )); then
    printf '%s\n' "$HITS" | sed 's/^/✗ /'
    echo ""
    echo "Bare date formatters: $violations"
    echo "Use AppDateFormatters (AkifiIOS/Services/DateFormatters.swift) for anything stored or parsed;"
    echo "for a locale-following display formatter add '// date-formatter-ok: <reason>'."
    if (( STRICT == 1 )); then
        exit 1
    fi
    exit 0
fi

echo "Bare date formatters: 0"
exit 0
