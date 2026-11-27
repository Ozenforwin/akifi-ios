#!/usr/bin/env python3
"""
lint-unbounded-fetch.py

Guard against silent PostgREST truncation (ADR-003).

PostgREST caps every response at the project's `max-rows` (1000 on
Supabase by default) and returns the truncated page WITHOUT an error.
On 2026-09-10 that turned a shared account's +36 539 ₽ into −38 997 ₽ on
one member's phone: her RLS-visible transaction set crossed 1000 rows and
the 11 oldest — two 38 880 ₽ income legs among them — never reached the
balance math.

Rule: every list read goes through `SupabasePaging.all(...)` (Swift) or
`fetchAll` / `fetchAllIn` (edge functions, supabase/functions/_shared/paging.ts).
A raw `.select(...) ... .execute()` chain in app code, or a `.from(...)
.select(...)` chain in an edge function, is a violation unless it is
provably bounded:

  - `.single()` / `.maybeSingle()` / `head: true`     (one row / no rows)
  - `.limit(N)` / `.range(a, b)` with LITERAL numbers describing a window
    of at most 1000 rows (a bigger or non-literal window is no guarantee:
    the server cap wins over `.limit(5000)`)
  - `.insert(` / `.update(` / `.upsert(` / `.delete(`  (writes returning the
                                                        rows they wrote)
  - the binding's declared type / enclosing function's return type is not an
    array (`[T]`, `Array<T>`, `Set<T>`, a typealias of those) — Swift only
  - TS: the chain sits inside a `fetchAll(` / `fetchAllIn(` / `drain(` call

The enclosing function is found by brace scope (multi-line signatures are
fine). A response stored in a variable (`let resp = try await ….execute()`
and `resp.value` later), a query builder kept in a variable (`var q =
client.from(...)` … `q.execute()`) and `Array<T>` are all covered.

Anything else needs `// bounded-fetch: <reason>` on the statement's first
line or in the comment block directly above it. The annotation is
deliberate friction: the reason gets reviewed.

Usage:
  python3 Scripts/lint-unbounded-fetch.py                 # soft: warnings only
  python3 Scripts/lint-unbounded-fetch.py --strict        # CI: exit 1 on any hit
  python3 Scripts/lint-unbounded-fetch.py --root DIR      # lint another tree (fixture tests)
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

SWIFT_SRC = ROOT / "AkifiIOS"
TS_SRC = ROOT / "supabase" / "functions"
EXEMPT_FILES = {
    SWIFT_SRC / "Services" / "SupabasePaging.swift",
    TS_SRC / "_shared" / "paging.ts",
}

MAX_ROWS = 1000  # PostgREST default on Supabase
ANNOTATION = "// bounded-fetch:"
WRITE_MARKERS = (".insert(", ".update(", ".upsert(", ".delete(")
ONE_ROW_MARKERS = (".single()", ".maybeSingle()", "head: true", "head:true")
ARRAY_PREFIXES = ("[", "Array<", "Set<", "ContiguousArray<", "Optional<[", "Optional<Array<")


# ───────────────────────── shared helpers ─────────────────────────

def mask(src, *, swift):
    """Blank out comments and string literals, preserving offsets/newlines,
    so brace/paren matching and keyword searches see code only."""
    out = list(src)
    n = len(src)
    i = 0

    def blank(a, b):
        for k in range(a, b):
            if out[k] != "\n":
                out[k] = " "

    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ""
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
        elif swift and src.startswith('"""', i):
            j = src.find('"""', i + 3)
            j = n if j < 0 else j + 3
            blank(i + 3, j - 3 if j - 3 > i + 3 else j)
            i = j
        elif c in "\"'`" and (c != "'" or not swift):
            j = i + 1
            while j < n and src[j] != c:
                if src[j] == "\\":
                    j += 1
                if src[j] == "\n" and c != "`":
                    break
                j += 1
            blank(i + 1, min(j, n))
            i = j + 1
        else:
            i += 1
    return "".join(out)


def match_pairs(code, opener, closer):
    """Map each opener offset -> matching closer offset."""
    stack, pairs = [], {}
    for i, c in enumerate(code):
        if c == opener:
            stack.append(i)
        elif c == closer and stack:
            pairs[stack.pop()] = i
    return pairs


def line_starts(text):
    starts = [0]
    for m in re.finditer("\n", text):
        starts.append(m.end())
    return starts


def line_of(starts, off):
    lo, hi = 0, len(starts) - 1
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if starts[mid] <= off:
            lo = mid
        else:
            hi = mid - 1
    return lo


def comment_block_above(raw_lines, idx):
    """The contiguous run of `//` comment lines directly above `idx`."""
    block, j = [], idx - 1
    while j >= 0 and raw_lines[j].strip().startswith("//"):
        block.append(raw_lines[j])
        j -= 1
    return "\n".join(block)


def window_ok(text):
    """True when every `.limit(N)` / `.range(a, b)` in `text` is a literal
    window of at most MAX_ROWS rows. Returns None when neither is present,
    False when one is present but not provably small."""
    found = False
    for m in re.finditer(r"\.limit\(\s*([^)]*?)\s*\)", text):
        found = True
        arg = m.group(1).replace("_", "")
        if not re.fullmatch(r"\d+", arg) or int(arg) > MAX_ROWS:
            return False
    for m in re.finditer(r"\.range\(\s*([^,)]*?)\s*,\s*([^)]*?)\s*\)", text):
        found = True
        a, b = (g.replace("_", "") for g in m.groups())
        if not (re.fullmatch(r"\d+", a) and re.fullmatch(r"\d+", b)):
            return False
        if int(b) - int(a) + 1 > MAX_ROWS:
            return False
    return True if found else None


def common_verdict(text):
    """Bound checks shared by Swift and TS. Returns 'bounded', or
    'unbounded' with a reason, or None to continue with language rules."""
    if any(m in text for m in ONE_ROW_MARKERS):
        return ("bounded", "")
    if any(m in text for m in WRITE_MARKERS):
        return ("bounded", "")
    w = window_ok(text)
    if w is True:
        return ("bounded", "")
    if w is False:
        return ("unbounded", "window is not a literal <= 1000 rows (server max-rows wins over a bigger .limit/.range)")
    return None


# ───────────────────────── Swift ─────────────────────────

FUNC_RE = re.compile(r"\bfunc\s+[\w`]+")
BINDING_RE = re.compile(r"^\s*(?:let|var)\s+(\w+)\s*(?::\s*([^=]+?))?\s*=(?!=)")
ASSIGN_RE = re.compile(r"^\s*(\w+)\s*=(?!=)")


def is_array_type(t, alias_arrays):
    t = t.strip().rstrip("?!").strip()
    return t.startswith(ARRAY_PREFIXES) or t in alias_arrays


def swift_functions(code):
    """List of (body_open, body_close, return_type_or_None)."""
    braces = match_pairs(code, "{", "}")
    funcs = []
    for m in FUNC_RE.finditer(code):
        i = m.end()
        n = len(code)
        # generic clause, then the parameter list
        depth_paren = 0
        sig_start = i
        seen_params = False
        while i < n:
            c = code[i]
            if c == "(":
                depth_paren += 1
                seen_params = True
            elif c == ")":
                depth_paren -= 1
            elif c == "{" and depth_paren == 0 and seen_params:
                break
            elif c == "}" and depth_paren == 0:
                i = -1
                break
            i += 1
        if i < 0 or i >= n or i not in braces:
            continue  # protocol requirement, no body
        sig = code[sig_start:i]
        # strip the parameter list (balanced) to find `->`
        depth, tail_at = 0, None
        for k, c in enumerate(sig):
            if c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
                if depth == 0:
                    tail_at = k + 1
                    break
        tail = sig[tail_at:] if tail_at is not None else ""
        rm = re.search(r"->\s*(.+?)\s*(?:\bwhere\b.*)?$", tail, re.S)
        ret = re.sub(r"\s+", " ", rm.group(1)).strip() if rm else None
        funcs.append((i, braces[i], ret))
    return funcs


def innermost_func(funcs, off):
    best = None
    for o, c, ret in funcs:
        if o < off < c and (best is None or o > best[0]):
            best = (o, c, ret)
    return best


def swift_alias_arrays(root_src):
    names = set()
    for p in root_src.rglob("*.swift"):
        for m in re.finditer(r"\btypealias\s+(\w+)\s*=\s*([^\n]+)", p.read_text()):
            if m.group(2).strip().startswith(ARRAY_PREFIXES):
                names.add(m.group(1))
    return names


def builder_text(code_lines, start_idx, name, scope_lines):
    """Join every statement in `scope_lines` (inclusive range) that builds
    the query-builder variable `name`."""
    lo, hi = scope_lines
    parts = []
    k = lo
    while k <= min(hi, start_idx):
        line = code_lines[k]
        if re.match(rf"^\s*(?:let|var)\s+{name}\b", line) or re.match(rf"^\s*{name}\s*=(?!=)", line):
            parts.append(line)
            while k + 1 <= hi and code_lines[k + 1].lstrip().startswith("."):
                k += 1
                parts.append(code_lines[k])
        k += 1
    return "\n".join(parts)


def lint_swift(path, alias_arrays):
    raw = path.read_text()
    code = mask(raw, swift=True)
    raw_lines = raw.splitlines()
    code_lines = code.splitlines()
    starts = line_starts(code)
    funcs = swift_functions(code)
    results = []

    for m in re.finditer(r"\.execute\(\)", code):
        li = line_of(starts, m.start())
        s = li
        while s > 0 and code_lines[s].lstrip().startswith((".", "?.")):
            s -= 1
        e = li
        while e + 1 < len(code_lines) and code_lines[e + 1].lstrip().startswith((".", "?.")):
            e += 1
        text = "\n".join(code_lines[s:e + 1])
        first = code_lines[s]
        fn = innermost_func(funcs, m.start())
        scope = (line_of(starts, fn[0]), line_of(starts, fn[1])) if fn else (0, len(code_lines) - 1)

        # Query builder kept in a variable: `q.execute().value`
        if not re.search(r"\.(from|rpc)\(", text):
            rm = re.search(r"(?:try\s+)?(?:await\s+)?(\w+)\s*(?:\n\s*)?\.execute\(\)", text)
            if rm:
                built = builder_text(code_lines, s, rm.group(1), scope)
                if re.search(r"\.(from|rpc)\(", built):
                    text = built + "\n" + text
        if not re.search(r"\.(select|rpc)\(", text):
            continue  # not a read
        if not re.search(r"\.(from|rpc)\(", text):
            continue

        binding = BINDING_RE.match(first)
        assign = None if binding else ASSIGN_RE.match(first)
        var = binding.group(1) if binding else (assign.group(1) if assign else None)

        # Is the response consumed as rows?
        reads_value = ".value" in text or ".data" in text
        if not reads_value and var:
            after = "\n".join(code_lines[e + 1:scope[1] + 1])
            reads_value = bool(re.search(rf"\b{var}\s*\.\s*(value|data)\b", after))
        if not reads_value:
            continue  # fire-and-forget / Void execute

        verdict = common_verdict(text)
        if verdict and verdict[0] == "bounded":
            continue
        reason = verdict[1] if verdict else "unbounded list read"

        if verdict is None:
            # type-based exemptions: declared type / return type not an array
            declared = binding.group(2) if binding and binding.group(2) else None
            if declared is None and var and not binding:
                # `x = try await …` — look up the declaration of x
                decl = re.search(rf"\b(?:let|var)\s+{var}\s*:\s*([^=\n]+?)\s*(?:=|$)",
                                 "\n".join(code_lines[scope[0]:s + 1]))
                declared = decl.group(1) if decl else None
            if declared is not None:
                if not is_array_type(declared, alias_arrays):
                    continue
            else:
                stripped = first.strip()
                if stripped.startswith(("try await", "return try await", "try? await",
                                        "return try? await", "return await", "await")):
                    if fn and fn[2] is not None and not is_array_type(fn[2], alias_arrays):
                        continue

        if ANNOTATION in raw_lines[s] or ANNOTATION in comment_block_above(raw_lines, s):
            results.append(("allowlisted", s, raw_lines[s].strip()))
        else:
            results.append(("hit", s, raw_lines[s].strip(), reason))
    return results


# ───────────────────────── TypeScript (edge functions) ─────────────────────────

PAGED_CALLEES = {"fetchAll", "fetchAllIn", "drain"}


def ts_paren_spans(code):
    """Spans (open, close, callee) for every `(`."""
    pairs = match_pairs(code, "(", ")")
    spans = []
    for o, c in pairs.items():
        before = code[:o].rstrip()
        # skip a generic clause: fetchAll<Row>(
        if before.endswith(">"):
            depth, k = 0, len(before) - 1
            while k >= 0:
                if before[k] == ">":
                    depth += 1
                elif before[k] == "<":
                    depth -= 1
                    if depth == 0:
                        break
                k -= 1
            before = before[:k].rstrip()
        nm = re.search(r"(\w+)$", before)
        spans.append((o, c, nm.group(1) if nm else ""))
    return spans


def ts_chain_end(code, open_paren, pairs):
    """End offset of a method chain whose first call's `(` is `open_paren`."""
    end = pairs.get(open_paren, open_paren) + 1
    while True:
        m = re.match(r"\s*\??\.\s*(\w+)\s*(<[^()]*>)?\s*\(", code[end:])
        if not m:
            return end
        o = end + m.end() - 1
        if o not in pairs:
            return end
        end = pairs[o] + 1


def lint_ts(path):
    raw = path.read_text()
    code = mask(raw, swift=False)
    raw_lines = raw.splitlines()
    starts = line_starts(code)
    pairs = match_pairs(code, "(", ")")
    spans = ts_paren_spans(code)
    paged = [(o, c) for o, c, name in spans if name in PAGED_CALLEES]
    results = []

    for m in re.finditer(r"\.(?:from|rpc)\(", code):
        o = m.end() - 1
        is_rpc = m.group(0).startswith(".rpc")
        end = ts_chain_end(code, o, pairs)
        text = code[m.start():end]
        if not is_rpc and ".select(" not in text:
            continue  # storage / write-only / builder started elsewhere
        li = line_of(starts, m.start())

        # statement start line (for annotation + display)
        s = li
        while s > 0:
            prev = code.splitlines()[s - 1].rstrip() if s - 1 < len(code.splitlines()) else ""
            if not prev or prev.endswith((";", "{", "}")):
                break
            if s < li - 8:
                break
            s -= 1
        stmt = code[starts[s]:end]
        full = stmt if len(stmt) >= len(text) else text

        if any(o2 < m.start() < c2 for o2, c2 in paged):
            continue
        verdict = common_verdict(full)
        if verdict and verdict[0] == "bounded":
            continue
        reason = verdict[1] if verdict else "unbounded list read"

        # builder kept in a variable and later consumed by fetchAll(...)
        bm = re.match(r"\s*(?:const|let|var)\s+(\w+)\s*=", code[starts[s]:])
        if bm and end >= m.end():
            name = bm.group(1)
            used_in_paged = False
            for mm in re.finditer(rf"\b{name}\b", code[end:]):
                pos = end + mm.start()
                if any(o2 < pos < c2 for o2, c2 in paged):
                    used_in_paged = True
                    break
            if used_in_paged:
                continue

        window = raw_lines[s:li + 1]
        if any(ANNOTATION in l for l in window) or ANNOTATION in comment_block_above(raw_lines, s):
            results.append(("allowlisted", li, raw_lines[li].strip()))
        else:
            results.append(("hit", li, raw_lines[li].strip(), reason))
    return results


# ───────────────────────── driver ─────────────────────────

hits, allowlisted = [], []


def record(path, res):
    rel = path.relative_to(ROOT)
    for r in res:
        entry = f"{rel}:{r[1] + 1}: {r[2]}"
        if r[0] == "allowlisted":
            allowlisted.append(entry)
        else:
            hits.append(f"{entry}    [{r[3]}]")


alias = swift_alias_arrays(SWIFT_SRC) if SWIFT_SRC.exists() else set()
if SWIFT_SRC.exists():
    for p in sorted(SWIFT_SRC.rglob("*.swift")):
        if p not in EXEMPT_FILES:
            record(p, lint_swift(p, alias))
if TS_SRC.exists():
    for p in sorted(TS_SRC.rglob("*.ts")):
        if p in EXEMPT_FILES or p.name.endswith(".test.ts") or "node_modules" in p.parts:
            continue
        record(p, lint_ts(p))

print("── Supabase list reads outside SupabasePaging / fetchAll ──")
for h in hits:
    print(h)
if allowlisted:
    print("\n── Allowlisted (annotated with a reason) ──")
    for a in allowlisted:
        print(a)

print()
if not hits:
    print("✅ Every list read is paginated (no silent max-rows truncation possible)")
    sys.exit(0)

print(f"⚠️  Found {len(hits)} unbounded list read(s)")
print("   Route through SupabasePaging.all(...) (Swift) or fetchAll(...) (edge functions)")
print("   For a genuinely bounded read, annotate: // bounded-fetch: <reason>")
if STRICT:
    print("\n❌ Strict mode: failing CI")
    sys.exit(1)
sys.exit(0)
