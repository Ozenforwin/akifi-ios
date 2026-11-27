#!/usr/bin/env python3
"""
lint_amount_usage.py — implementation behind Scripts/lint-amount-usage.sh

Guards against regressions of the ADR-001 multi-currency bug.

Rule A (legacy label). `Transaction.amount` (Swift) / `tx.amount` (edge
functions) is the legacy field that sums foreign-currency values as if they
were base currency. Any read of `.amount` that feeds an aggregation is a
violation: `reduce`, `+=` / `-=`, `x = x + …`, `abs(…)`, `sum`, and the
extraction forms `.map(\\.amount)` / `.map { $0.amount }`. Statements are
analysed as a whole, so a closure spread over several lines is caught.

Rule B (native amounts across accounts). `amountNative` / `amount_native`
is in the ACCOUNT's currency. Summing it is only correct inside one account
or after conversion to a common currency. An aggregation of it that shows
neither a conversion (`amountInBase`, `convert`, `toBase`, `rate`, `fx`,
`baseCurrency`…) nor a single-account scope (`accountId ==`, `forAccount`,
`perAccount`…) in the same statement is a violation. This is the class of
bug "sums of different currencies" from the 2026-11 review: the previous
script skipped every line that mentioned `amountNative`, which exempted
exactly these.

A line (or the comment line directly above) carrying
`// allowlisted-amount: <reason>` suppresses a hit; the reason gets reviewed.

Usage (through the wrapper):
  bash Scripts/lint-amount-usage.sh [--strict] [--root DIR]
"""
import re
import sys
from pathlib import Path

ARGS = sys.argv[1:]
STRICT = "--strict" in ARGS
if "--root" in ARGS:
    ROOT = Path(ARGS[ARGS.index("--root") + 1]).resolve()
else:
    ROOT = Path(__file__).resolve().parent.parent

SWIFT_DIRS = ["AkifiIOS", "AkifiIOSTests"]
TS_DIRS = ["supabase/functions"]

SWIFT_ALLOWLIST = {
    "AkifiIOS/Models/Transaction.swift",
    "AkifiIOS/Services/TransactionMath.swift",
    "AkifiIOS/Repositories/TransactionRepository.swift",
    "AkifiIOS/Extensions/Decimal+Currency.swift",
}
TS_ALLOWLIST = {
    "supabase/functions/assistant-query/types.ts",
    "supabase/functions/assistant-query/index.ts",
    "supabase/functions/_shared/transaction-math.ts",
}

ALLOW_TAG = "allowlisted-amount:"

AGG_RE = re.compile(
    r"\breduce\b|\+=|-=|\babs\(|\bsum\b|\.sum\(|\bMath\.abs\("
    r"|\b(\w+)\s*=\s*\1\s*[+-]"
)
# `.amount` on something transaction-like. Other models (Subscription,
# Settlement, Budget, a chart item …) also have an `amount`, and they are fine.
# Receiver is judged by name; a closure shorthand (`$0.amount`) or a bare key
# path (`\\.amount`) counts when the statement talks about transactions.
TX_NAME = r"(?:tx|txn|trx|t|tr|trans\w*|transaction\w*|expense\w*|income\w*|leg|row|\w+Tx|\w+Txn|\w+Transaction)"
TX_CONTEXT = re.compile(r"\b(?:tx|txs|txn|txns|transactions?|expenses?|incomes?|legs?)\b", re.I)
# Rule B counts only real summation (a lone abs()/% of one row is not a sum).
AGG_B_RE = re.compile(r"\breduce\b|\+=|-=|\bsum\b|\.sum\(|\b(\w+)\s*=\s*\1\s*[+-]")
LEGACY_SWIFT = re.compile(rf"(?:\b{TX_NAME}|\$\d|\\[\w.]*)\.amount\b(?!\s*\.displayAmount)")
LEGACY_TS = re.compile(rf"\b{TX_NAME}\.amount\b(?!_)")
COALESCE_TAIL = re.compile(r"amount_(?:native|in_base)\s*\?\?\s*[\w.]*\.amount\b")
EXTRACT_SWIFT = re.compile(r"\.(?:map|compactMap|flatMap)\s*\(\s*\\[\w.]*\.amount\s*\)"
                           r"|\.(?:map|compactMap)\s*\{\s*\$0\.amount\s*\}")
EXTRACT_TS = re.compile(r"\.map\(\s*\(?\s*\w+\s*\)?\s*=>\s*\w+\.amount\s*\)")
NATIVE_SWIFT = re.compile(r"\.amountNative\b|\.amount_native\b")
NATIVE_TS = re.compile(r"\.amount_native\b|\.amountNative\b")
CONVERSION_RE = re.compile(
    r"amountInBase|amount_in_base|convert|toBase|inBase|\brates?\b|\bfx\b|fxRate|"
    r"baseCurrency|base_currency|exchange|\bnormalized|inCurrency"
)
SCOPE_RE = re.compile(
    r"\[\s*\.?account\w*|accountId\s*==|account_id\s*===?|account\.id|forAccount|perAccount|byAccount|"
    r"singleAccount|\.accountId\s*==|currency\s*==|\.currency\s*===?|sameCurrency"
)

CONTROL_START = re.compile(
    r"^\s*(?:@\w+\s+)*(?:(?:public|private|fileprivate|internal|final|static|override|mutating|nonisolated)\s+)*"
    r"(?:for|if|else|while|guard|switch|do|func|class|struct|enum|extension|protocol|init|catch|defer|case|repeat"
    r"|function|async\s+function|try\s*\{|import)\b"
)
OPERATOR_END = re.compile(r"[+\-*/%&|,=(\[{]\s*$")


def mask(src):
    out = list(src)
    n, i = len(src), 0

    def blank(a, b):
        for k in range(a, b):
            if out[k] != "\n":
                out[k] = " "

    while i < n:
        c, nxt = src[i], src[i + 1] if i + 1 < n else ""
        if c == "/" and nxt == "/":
            j = src.find("\n", i)
            j = n if j < 0 else j
            blank(i, j)
            i = j
        elif c == "/" and nxt == "*":
            j = src.find("*/", i + 2)
            j = n if j < 0 else j + 2
            blank(i, j)
            i = j
        elif c in "\"`":
            j = i + 1
            while j < n and src[j] != c:
                if src[j] == "\\":
                    j += 1
                if j < n and src[j] == "\n" and c == '"':
                    break
                j += 1
            blank(i + 1, min(j, n))
            i = j + 1
        else:
            i += 1
    return "".join(out)


def split_statements(code, lo, hi):
    """Statements inside code[lo:hi]: (start, end, header_end) where header_end
    is the offset where the first top-level `{` of the statement opens (or
    `end` when none). Splits at depth-0 newlines unless the statement
    continues (leading `.`/operator on the next line, trailing operator)."""
    stmts = []
    i, depth, start = lo, 0, None
    first_block = None
    while i < hi:
        c = code[i]
        if start is None:
            if not c.isspace() and c not in ";}":
                start, depth, first_block = i, 0, None
            else:
                i += 1
                continue
        if c in "([{":
            if c == "{" and depth == 0 and first_block is None:
                first_block = i
            depth += 1
        elif c in ")]}":
            depth -= 1
            if depth < 0:  # stray closer of an outer scope
                stmts.append((start, i, first_block if first_block is not None else i))
                start = None
                depth = 0
                i += 1
                continue
        elif c == ";" and depth == 0:
            stmts.append((start, i, first_block if first_block is not None else i))
            start = None
        elif c == "\n" and depth == 0:
            # does the statement continue on the next non-blank line?
            k = i + 1
            while k < hi and code[k] in " \t\n":
                k += 1
            nxt = code[k:k + 2]
            cur = code[start:i]
            continues = (
                k < hi and (nxt.startswith((".", "?.", "&&", "||", "??", "+", "*", "/", ")", "]"))
                            or (nxt[:1] == "-" and nxt[:2] != "->")
                            or nxt.startswith(("else", "catch")))
            ) or OPERATOR_END.search(cur) is not None
            # `}` closing a block that was opened in this statement then a new
            # line: statement is complete (handled by depth == 0)
            if not continues:
                stmts.append((start, i, first_block if first_block is not None else i))
                start = None
        i += 1
    if start is not None:
        stmts.append((start, hi, first_block if first_block is not None else hi))
    return stmts


def analyse(code, lo, hi, visit):
    for s, e, head_end in split_statements(code, lo, hi):
        text = code[s:e]
        if CONTROL_START.match(text):
            visit(s, head_end if head_end < e else e)
            # recurse into every top-level block of the control statement
            depth, i = 0, head_end
            block_start = None
            while i < e:
                ch = code[i]
                if ch == "{":
                    if depth == 0:
                        block_start = i + 1
                    depth += 1
                elif ch == "}":
                    depth -= 1
                    if depth == 0 and block_start is not None:
                        analyse(code, block_start, i, visit)
                        block_start = None
                i += 1
        else:
            visit(s, e)
            # also look inside closures/blocks for nested statements
            depth, i, block_start = 0, s, None
            while i < e:
                ch = code[i]
                if ch == "{":
                    if depth == 0:
                        block_start = i + 1
                    depth += 1
                elif ch == "}":
                    depth -= 1
                    if depth == 0 and block_start is not None:
                        analyse(code, block_start, i, visit)
                        block_start = None
                i += 1


def line_starts(text):
    return [0] + [m.end() for m in re.finditer("\n", text)]


def line_of(starts, off):
    lo, hi = 0, len(starts) - 1
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if starts[mid] <= off:
            lo = mid
        else:
            hi = mid - 1
    return lo


def lint_file(path, rel, *, swift, is_test):
    raw = path.read_text()
    code = mask(raw)
    raw_lines = raw.splitlines()
    starts = line_starts(code)
    legacy = LEGACY_SWIFT if swift else LEGACY_TS
    extract = EXTRACT_SWIFT if swift else EXTRACT_TS
    native = NATIVE_SWIFT if swift else NATIVE_TS
    found = {}

    def allowed(first_line, last_line):
        for ln in range(first_line, last_line + 1):
            if ALLOW_TAG in raw_lines[ln]:
                return True
        above = first_line - 1
        while above >= 0 and raw_lines[above].strip().startswith("//"):
            if ALLOW_TAG in raw_lines[above]:
                return True
            above -= 1
        return False

    def legacy_hits(text):
        """Offsets of legacy `.amount` reads that look like transactions."""
        scrubbed = COALESCE_TAIL.sub(lambda m: " " * len(m.group(0)), text)
        out = []
        for m in legacy.finditer(scrubbed):
            tok = m.group(0)
            # `$0.amount` / `\\.amount` carry no type: need transaction context
            if (tok.startswith("$") or tok.startswith("\\")) and not TX_CONTEXT.search(scrubbed):
                continue
            out.append(m.start())
        return out

    def visit(s, e):
        text = code[s:e]
        fl, ll = line_of(starts, s), line_of(starts, max(s, e - 1))
        # Rule A: legacy label in an aggregation
        offs = legacy_hits(text)
        if offs and (AGG_RE.search(text) or extract.search(text)) and not allowed(fl, ll):
            for o in offs:
                ln = line_of(starts, s + o)
                found.setdefault(ln, ("A", raw_lines[ln].strip()))
        # Rule B: native amounts summed with no conversion / account scope
        if not is_test and native.search(text) and AGG_B_RE.search(text):
            if not CONVERSION_RE.search(text) and not SCOPE_RE.search(text) and not allowed(fl, ll):
                ln = line_of(starts, s + native.search(text).start())
                found.setdefault(ln, ("B", raw_lines[ln].strip()))

    analyse(code, 0, len(code), visit)
    return [(rel, ln + 1, kind, txt) for ln, (kind, txt) in sorted(found.items())]


def collect(dirs, suffix, allowlist, *, swift):
    hits = []
    for d in dirs:
        base = ROOT / d
        if not base.exists():
            continue
        for p in sorted(base.rglob(f"*{suffix}")):
            rel = str(p.relative_to(ROOT))
            if rel in allowlist or p.name.endswith(".test.ts") and not swift and False:
                continue
            if "node_modules" in p.parts:
                continue
            is_test = swift and rel.startswith("AkifiIOSTests") or (not swift and p.name.endswith(".test.ts"))
            hits += lint_file(p, rel, swift=swift, is_test=is_test)
    return hits


swift_hits = collect(SWIFT_DIRS, ".swift", SWIFT_ALLOWLIST, swift=True)
ts_hits = collect(TS_DIRS, ".ts", TS_ALLOWLIST, swift=False)

KIND = {"A": "legacy .amount in an aggregation", "B": "amountNative summed without conversion or single-account scope"}
print("── Swift aggregations via legacy .amount / unconverted amountNative ──")
for rel, ln, kind, txt in swift_hits:
    print(f"{rel}:{ln}: {txt}    [{KIND[kind]}]")
print("")
print("── Edge function aggregations via legacy .amount / unconverted amount_native ──")
for rel, ln, kind, txt in ts_hits:
    print(f"{rel}:{ln}: {txt}    [{KIND[kind]}]")

total = len(swift_hits) + len(ts_hits)
print("")
if total == 0:
    print("✅ No legacy .amount usage detected (ADR-001 compliant)")
    sys.exit(0)

print(f"⚠️  Found {total} amount usage(s) violating ADR-001")
print("   See ADR-001 (.claude/adr/ADR-001-multi-currency.md)")
print("   To suppress a legitimate case: append '// allowlisted-amount: reason'")
if STRICT:
    print("")
    print("❌ Strict mode: failing CI")
    sys.exit(1)
sys.exit(0)
