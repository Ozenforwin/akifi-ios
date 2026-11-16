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
# Files written before this lint existed are listed with their current hit
# count in Scripts/lint-date-formatters.baseline. A file may not exceed its
# baseline; new files get 0. When you fix a file, lower (or delete) its line.
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
BASELINE="Scripts/lint-date-formatters.baseline"

SCAN_DIRS=()
for d in AkifiIOS AkifiWidget; do
    [[ -d "$d" ]] && SCAN_DIRS+=("$d")
done

# path:line: code   — one line per unannotated construction outside the factory.
HITS="$(find "${SCAN_DIRS[@]}" -name '*.swift' -type f -print0 | sort -z | xargs -0 awk -v factory="$FACTORY" '
    FNR == 1 { prev = "" }
    {
        line = $0
        code = line
        sub(/^[ \t]+/, "", code)
        if (FILENAME != factory && code !~ /^\/\// && line ~ /DateFormatter[ \t]*(\.init)?[ \t]*\([ \t]*\)/) {
            ok = (line ~ /date-formatter-ok:[ \t]*[^ \t]/) || (prev ~ /^[ \t]*\/\/.*date-formatter-ok:[ \t]*[^ \t]/)
            if (!ok) print FILENAME ":" FNR ": " code
        }
        prev = line
    }
')"

# Per-file counts of the current hits.
COUNTS="$(printf '%s\n' "$HITS" | awk -F: 'NF > 1 { n[$1]++ } END { for (f in n) print f ":" n[f] }' | sort)"

baseline_for() {
    local file="$1"
    [[ -f "$BASELINE" ]] || { echo 0; return; }
    awk -F: -v f="$file" '$0 !~ /^#/ && $1 == f { print $2; found = 1 } END { if (!found) print 0 }' "$BASELINE"
}

violations=0
stale=0

while IFS=: read -r file count; do
    [[ -z "$file" ]] && continue
    allowed="$(baseline_for "$file")"
    if (( count > allowed )); then
        violations=$((violations + count - allowed))
        echo "✗ $file: $count bare date formatter(s), baseline allows $allowed"
        printf '%s\n' "$HITS" | grep -F "$file:" | sed 's/^/    /'
    fi
done <<< "$COUNTS"

# Baseline entries that can be lowered — the file got better.
if [[ -f "$BASELINE" ]]; then
    while IFS=: read -r file allowed; do
        [[ -z "$file" || "$file" == \#* ]] && continue
        current="$(printf '%s\n' "$COUNTS" | awk -F: -v f="$file" '$1 == f { print $2 }')"
        current="${current:-0}"
        if (( current < allowed )); then
            stale=$((stale + 1))
            if (( current == 0 )); then
                echo "↓ $file is clean now — delete its line from $BASELINE"
            else
                echo "↓ $file: $current hit(s) left — lower its baseline from $allowed to $current"
            fi
        fi
    done < "$BASELINE"
fi

total="$(printf '%s\n' "$HITS" | grep -c . || true)"
echo ""
echo "Bare date formatters: $total (baseline-covered: $((total - violations))), new violations: $violations, baseline lines to lower: $stale"

if (( violations > 0 )); then
    echo "Use AppDateFormatters (AkifiIOS/Services/DateFormatters.swift) for anything stored or parsed;"
    echo "for a locale-following display formatter add '// date-formatter-ok: <reason>'."
    if (( STRICT == 1 )); then
        exit 1
    fi
fi
exit 0
