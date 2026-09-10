#!/usr/bin/env python3
"""
lint-unbounded-fetch.py

Guard against silent PostgREST truncation.

PostgREST caps every response at the project's `max-rows` (1000 on
Supabase by default) and returns the truncated page WITHOUT an error.
On 2026-09-10 that turned a shared account's +36 539 ₽ into −38 997 ₽ on
one member's phone: her RLS-visible transaction set crossed 1000 rows and
the 11 oldest — two 38 880 ₽ income legs among them — never reached the
balance math.

Rule: every list read goes through `SupabasePaging.all(...)`, which pages
until the server's own count is satisfied. A raw
`.select(...) ... .execute()` chain in app code is a violation unless it
is provably bounded:

  - `.single()` / `.maybeSingle()` / `head: true`   (one row / no rows)
  - `.range(` / `.limit(`                            (an explicit window)
  - `.insert(` / `.update(` / `.upsert(` / `.delete(` (writes returning
                                                     the rows they wrote)
  - the binding's declared type is not an array     (`let x: Foo = ...`)
  - the chain is the returned expression of a func whose return type is
    not an array

Anything else needs `// bounded-fetch: <reason>` on the statement's first
line or in the comment block directly above it. The annotation is deliberate friction: the
reason gets reviewed.

Usage:
  python3 Scripts/lint-unbounded-fetch.py           # soft: warnings only
  python3 Scripts/lint-unbounded-fetch.py --strict  # CI: exit 1 on any hit
"""
import re
import sys
from pathlib import Path

STRICT = "--strict" in sys.argv[1:]

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "AkifiIOS"
EXEMPT_FILES = {SRC / "Services" / "SupabasePaging.swift"}

ANNOTATION = "// bounded-fetch:"
BOUNDED_MARKERS = (
    ".single()", ".maybeSingle()", "head: true",
    ".range(", ".limit(",
    ".insert(", ".update(", ".upsert(", ".delete(",
)
FUNC_RE = re.compile(r"\bfunc\s+\w+\s*\([^)]*\)[^{]*?->\s*([^\s{]+)")
BINDING_TYPE_RE = re.compile(r"^\s*(?:let|var)\s+\w+\s*:\s*([^=]+?)\s*=")


def statements(lines):
    """Yield (start, end) line-index ranges of method chains that call
    `.execute()`. A chain is the statement's first line plus every following
    line that starts with `.`."""
    i, n = 0, len(lines)
    while i < n:
        if ".execute()" in lines[i]:
            s = i
            while s > 0 and lines[s].lstrip().startswith("."):
                s -= 1
            e = i
            while e + 1 < n and lines[e + 1].lstrip().startswith("."):
                e += 1
            yield s, e
            i = e + 1
        else:
            i += 1


def enclosing_return_type(lines, idx):
    for j in range(idx, -1, -1):
        m = FUNC_RE.search(lines[j])
        if m:
            return m.group(1)
    return None


def comment_block_above(lines, idx):
    """The contiguous run of `//` comment lines directly above `idx`."""
    block = []
    j = idx - 1
    while j >= 0 and lines[j].strip().startswith("//"):
        block.append(lines[j])
        j -= 1
    return "\n".join(block)


def classify(lines, s, e):
    """Return None if fine, 'allowlisted' if annotated, else the reason."""
    text = "\n".join(lines[s:e + 1])
    first = lines[s]

    if not (".select(" in text or ".rpc(" in text or ".from(" in text):
        return None
    if any(marker in text for marker in BOUNDED_MARKERS):
        return None
    if ".value" not in text and ".data" not in text:
        return None  # fire-and-forget / Void execute

    m = BINDING_TYPE_RE.match(first)
    if m:
        declared = m.group(1).strip()
        if not declared.startswith("["):
            return None
    else:
        stripped = first.strip()
        if stripped.startswith(("try await", "return try await", "try? await", "return try? await")):
            ret = enclosing_return_type(lines, s)
            if ret is not None and not ret.startswith("["):
                return None

    if ANNOTATION in first or ANNOTATION in comment_block_above(lines, s):
        return "allowlisted"
    return "unbounded list read"


hits, allowlisted = [], []
for path in sorted(SRC.rglob("*.swift")):
    if path in EXEMPT_FILES:
        continue
    lines = path.read_text().splitlines()
    for s, e in statements(lines):
        verdict = classify(lines, s, e)
        if verdict is None:
            continue
        rel = path.relative_to(ROOT)
        entry = f"{rel}:{s + 1}: {lines[s].strip()}"
        (allowlisted if verdict == "allowlisted" else hits).append(entry)

print("── Supabase list reads outside SupabasePaging ──")
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
print("   Route through SupabasePaging.all(...) — see AkifiIOS/Services/SupabasePaging.swift")
print("   For a genuinely bounded read, annotate: // bounded-fetch: <reason>")
if STRICT:
    print("\n❌ Strict mode: failing CI")
    sys.exit(1)
sys.exit(0)
