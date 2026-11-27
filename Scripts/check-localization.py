#!/usr/bin/env python3
"""
check-localization.py

Every localization key the Swift code looks up must exist in the string
catalog with a Russian, English and Spanish value.

Why: the 2026-11-27 review found six keys used in code that were missing
from the catalog on every language (users saw `import.transactions.12`
and `subscriptions.autoMatch.body Netflix`), and dozens of keys without
an English or Spanish value (Spanish alerts titled `common.error` with an
`common.ok` button). 1 334 of 1 619 catalog entries were marked `stale`,
so Xcode never warned. This script is the warning.

What counts as a lookup (string literals only — a variable can't be
checked statically):

  String(localized: "…")          NSLocalizedString("…")
  LocalizedStringKey("…")         LocalizedStringResource("…")
  Text("…")                       (not Text(verbatim:))
  SwiftUI titles that take a LocalizedStringKey when given a literal:
  Button / Label / Toggle / Section / Picker / TextField / SecureField /
  Link / Menu / Stepper / DatePicker / LabeledContent / NavigationLink /
  ContentUnavailableView ("…", and .navigationTitle / .alert /
  .confirmationDialog / .accessibilityLabel / .accessibilityHint /
  .accessibilityValue / .help ("…").

An interpolation `\\(x)` becomes a format specifier in the key (`%lld`,
`%@`, …); the script accepts any specifier in its place. Literals with no
letters ("•", "\\(a) / \\(b)") are not localizable text and are skipped.

Catalogs:
  AkifiIOS/**             -> AkifiIOS/Localization/Localizable.xcstrings
  AkifiWidget/**          -> AkifiWidget/Resources/<lang>.lproj/Localizable.strings
                             (+ Localizable.stringsdict for plurals)
  Info.plist usage texts  -> AkifiIOS/Localization/InfoPlist.xcstrings

A key passes when ru, en and es each have a non-empty value (or every
plural / device variation has one), and no value uses a format specifier
of a different kind than the code passes at that position (a `%@` where
the code passes an Int crashes).

Usage:
  python3 Scripts/check-localization.py            # report, exit 1 on violations
  python3 Scripts/check-localization.py --verbose  # also list every checked file
"""
import json
import plistlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LANGS = ("ru", "en", "es")
VERBOSE = "--verbose" in sys.argv[1:]

APP_SRC = ROOT / "AkifiIOS"
APP_CATALOG = APP_SRC / "Localization" / "Localizable.xcstrings"
INFOPLIST_CATALOG = APP_SRC / "Localization" / "InfoPlist.xcstrings"
WIDGET_SRC = ROOT / "AkifiWidget"
WIDGET_RES = WIDGET_SRC / "Resources"
# Compiled into the widget too (project.yml), so its lookups must resolve
# in both bundles.
SHARED_WITH_WIDGET = APP_SRC / "Shared" / "Widget"
PROJECT_YML = ROOT / "project.yml"

# Placeholder for an interpolation inside a scanned literal.
HOLE = "\x00"

# printf-style specifier as Foundation writes it into keys and values.
SPEC = r"%(?:\d+\$)?[-+ 0#']*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|h|ll|l|q|z|t|j|L)?[@dDiuUxXoOfFeEgGaAcCsSp]"
SPEC_RE = re.compile(SPEC)

# Text just before the opening quote that makes the literal a lookup key.
CONTEXTS = [
    ("String(localized:)", re.compile(r"\bString\(\s*localized:\s*$")),
    ("NSLocalizedString", re.compile(r"\bNSLocalizedString\(\s*$")),
    ("LocalizedStringKey", re.compile(r"\bLocalizedStringKey\(\s*$")),
    ("LocalizedStringResource", re.compile(r"\bLocalizedStringResource\(\s*$")),
    ("Text", re.compile(r"(?<![\w.])Text\(\s*$")),
    # Text(flag ? "a" : "b") — both branches are LocalizedStringKey.
    ("Text ternary", re.compile(r"(?<![\w.])Text\([^()\n]*[^?]\?\s+(?:[^()\n]*:\s*)?$")),
    ("SwiftUI title", re.compile(
        r"(?<![\w.])(?:Button|Label|Toggle|Section|Picker|TextField|SecureField|Link|Menu|"
        r"Stepper|DatePicker|LabeledContent|NavigationLink|ContentUnavailableView)\(\s*$")),
    ("view modifier", re.compile(
        r"\.(?:navigationTitle|alert|confirmationDialog|accessibilityLabel|accessibilityHint|"
        r"accessibilityValue|help)\(\s*$")),
]
# Arguments after the literal that point the lookup at another table.
OTHER_TABLE_RE = re.compile(r"^\s*,\s*(?:table|tableName|bundle)\s*:")


# ── Swift literal scanner ───────────────────────────────────────────────

class Literal:
    __slots__ = ("start", "end", "parts", "line")

    def __init__(self, start, end, parts, line):
        self.start, self.end, self.parts, self.line = start, end, parts, line

    @property
    def template(self):
        return "".join(HOLE if p is None else p for p in self.parts)


ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "0": "\0", "\\": "\\", '"': '"', "'": "'"}


def scan_swift(src):
    """Return (code_without_comments_and_strings, [Literal]) for single-line
    string literals. Comments and literal bodies are blanked out in the
    returned code (same length, newlines kept) so context regexes never
    match inside them."""
    out = list(src)
    literals = []
    i, n = 0, len(src)

    def blank(a, b):
        for k in range(a, b):
            if out[k] != "\n":
                out[k] = " "

    def read_string(pos):
        """pos at the opening quote of a "…" literal. Returns (end, parts)
        where end is the index after the closing quote."""
        parts, buf = [], []
        k = pos + 1
        while k < n:
            c = src[k]
            if c == '"':
                if buf:
                    parts.append("".join(buf))
                return k + 1, parts
            if c == "\n":  # unterminated — give up on this literal
                return k, None
            if c == "\\":
                nxt = src[k + 1] if k + 1 < n else ""
                if nxt == "(":
                    if buf:
                        parts.append("".join(buf))
                        buf = []
                    k = skip_interpolation(k + 2)
                    parts.append(None)
                    continue
                if nxt == "u" and k + 2 < n and src[k + 2] == "{":
                    close = src.find("}", k + 3)
                    try:
                        buf.append(chr(int(src[k + 3:close], 16)))
                    except ValueError:
                        pass
                    k = close + 1
                    continue
                buf.append(ESCAPES.get(nxt, nxt))
                k += 2
                continue
            buf.append(c)
            k += 1
        return k, None

    def skip_interpolation(k):
        """k just after `\\(`. Returns index after the matching `)`."""
        depth = 1
        while k < n and depth:
            c = src[k]
            if c == '"':
                end, _ = read_string(k)
                k = end
                continue
            if c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
            k += 1
        return k

    line = 1
    while i < n:
        c = src[i]
        if c == "\n":
            line += 1
            i += 1
            continue
        if src.startswith("//", i):
            j = src.find("\n", i)
            j = n if j == -1 else j
            blank(i, j)
            i = j
            continue
        if src.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if src.startswith("/*", j):
                    depth, j = depth + 1, j + 2
                elif src.startswith("*/", j):
                    depth, j = depth - 1, j + 2
                else:
                    j += 1
            line += src.count("\n", i, j)
            blank(i, j)
            i = j
            continue
        if src.startswith('"""', i):
            j = src.find('"""', i + 3)
            j = n if j == -1 else j + 3
            line += src.count("\n", i, j)
            blank(i, j)
            i = j
            continue
        if c == "#" and re.match(r'#+"', src[i:i + 8]):
            hashes = len(re.match(r"#+", src[i:]).group(0))
            close = '"' + "#" * hashes
            j = src.find(close, i + hashes + 1)
            j = n if j == -1 else j + len(close)
            line += src.count("\n", i, j)
            blank(i, j)
            i = j
            continue
        if c == '"':
            end, parts = read_string(i)
            if parts is not None:
                literals.append(Literal(i, end, parts, line))
            line += src.count("\n", i, end)
            blank(i, end)
            i = end
            continue
        i += 1
    return "".join(out), literals


# ── Catalogs ────────────────────────────────────────────────────────────

def xcstrings_values(entry):
    """{lang: [values]} for one xcstrings entry; [] when the language has
    no usable value."""
    result = {}
    locs = entry.get("localizations", {})
    for lang in LANGS:
        loc = locs.get(lang)
        values = []
        if loc is not None:
            ok = collect_unit_values(loc, values)
            if not ok:
                values = []
        result[lang] = values
    return result


def collect_unit_values(node, values):
    """Walk stringUnit / variations / substitutions. False when any leaf
    is empty."""
    ok = True
    found = False
    unit = node.get("stringUnit")
    if unit is not None:
        found = True
        value = unit.get("value", "")
        if not value.strip():
            return False
        values.append(value)
    variations = node.get("variations")
    if variations:
        for kind in variations.values():
            for variant in kind.values():
                found = True
                ok = collect_unit_values(variant, values) and ok
    for sub in node.get("substitutions", {}).values():
        ok = collect_unit_values(sub, values) and ok
    return ok and found


def load_xcstrings(path):
    data = json.loads(path.read_text(encoding="utf-8"))
    return {key: xcstrings_values(entry) for key, entry in data.get("strings", {}).items()}


STRINGS_LINE_RE = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', re.M)


def unescape_strings(s):
    return re.sub(r"\\(.)", lambda m: ESCAPES.get(m.group(1), m.group(1)), s)


def load_lproj_catalog(res_dir):
    """Widget-style catalog: {key: {lang: [values]}} merged from
    <lang>.lproj/Localizable.strings and Localizable.stringsdict."""
    catalog = {}
    for lang in LANGS:
        lproj = res_dir / f"{lang}.lproj"
        strings = lproj / "Localizable.strings"
        if strings.exists():
            text = strings.read_text(encoding="utf-8")
            text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
            for m in STRINGS_LINE_RE.finditer(text):
                key, value = unescape_strings(m.group(1)), unescape_strings(m.group(2))
                catalog.setdefault(key, {l: [] for l in LANGS})[lang] = [value] if value.strip() else []
        sdict = lproj / "Localizable.stringsdict"
        if sdict.exists():
            with sdict.open("rb") as fh:
                plist = plistlib.load(fh)
            for key, spec in plist.items():
                values = []
                ok = True
                fmt = spec.get("NSStringLocalizedFormatKey", "")
                for name, rule in spec.items():
                    if name == "NSStringLocalizedFormatKey" or not isinstance(rule, dict):
                        continue
                    if "other" not in rule or not str(rule["other"]).strip():
                        ok = False
                    for cat, value in rule.items():
                        if cat.startswith("NSString"):
                            continue
                        if not str(value).strip():
                            ok = False
                        values.append(fmt.replace(f"%#@{name}@", str(value)))
                catalog.setdefault(key, {l: [] for l in LANGS})[lang] = values if ok else []
    return catalog


# ── Matching ────────────────────────────────────────────────────────────

def key_pattern(template):
    """Regex for catalog keys a literal can produce: each interpolation is
    some format specifier; a literal `%` may have been doubled."""
    out = []
    for ch in template:
        if ch == HOLE:
            out.append("(" + SPEC + ")")
        elif ch == "%":
            out.append("%%?")
        else:
            out.append(re.escape(ch))
    return re.compile("^" + "".join(out) + "$")


def spec_kind(spec):
    conv = spec[-1]
    if conv in "@":
        return "object"
    if conv in "fFeEgGaA":
        return "float"
    if conv in "sS":
        return "cstring"
    if conv == "p":
        return "pointer"
    return "int"


def spec_slots(text):
    """{argument index: kind} for the specifiers in a format string."""
    slots = {}
    seq = 0
    for m in SPEC_RE.finditer(text.replace("%%", "")):
        spec = m.group(0)
        pos = re.match(r"%(\d+)\$", spec)
        if pos:
            index = int(pos.group(1))
        else:
            seq += 1
            index = seq
        slots[index] = spec_kind(spec)
    return slots


def check_catalog_entry(key, values):
    """Problems for one resolved key: missing languages and specifier
    kinds that disagree with what the key (= the code) passes."""
    problems = []
    missing = [lang for lang in LANGS if not values.get(lang)]
    if missing:
        problems.append("no " + "/".join(missing) + " value")
    key_slots = spec_slots(key)
    if key_slots:
        for lang in LANGS:
            for value in values.get(lang, []):
                for index, kind in spec_slots(value).items():
                    expected = key_slots.get(index)
                    if expected is None:
                        problems.append(f"{lang} value uses argument {index}, the code passes {len(key_slots)}")
                    elif expected != kind:
                        problems.append(f"{lang} value formats argument {index} as {kind}, the code passes {expected}")
    return sorted(set(problems))


class Catalog:
    def __init__(self, name, entries):
        self.name = name
        self.entries = entries
        self._by_prefix = {}
        for key in entries:
            self._by_prefix.setdefault(key[:4], []).append(key)

    def resolve(self, template):
        """Keys matching the literal (exact first, then with specifiers)."""
        if HOLE not in template and "%" not in template:
            return [template] if template in self.entries else []
        pattern = key_pattern(template)
        prefix = template.split(HOLE, 1)[0].split("%", 1)[0]
        candidates = self._by_prefix.get(prefix[:4], []) if len(prefix) >= 4 else self.entries
        return [key for key in candidates if pattern.match(key)]


def has_letters(template):
    text = re.sub(SPEC, "", template.replace(HOLE, ""))
    return any(ch.isalpha() for ch in text)


def describe(template):
    return template.replace(HOLE, "\\(…)").replace("\n", "\\n")


def preview_ranges(code):
    """(start, end) of every `#Preview { … }` block — previews don't ship."""
    ranges = []
    for m in re.finditer(r"#Preview\b", code):
        open_brace = code.find("{", m.end())
        if open_brace == -1:
            continue
        depth, k = 0, open_brace
        while k < len(code):
            if code[k] == "{":
                depth += 1
            elif code[k] == "}":
                depth -= 1
                if depth == 0:
                    break
            k += 1
        ranges.append((m.start(), k))
    return ranges


def lookups(path):
    src = path.read_text(encoding="utf-8")
    code, literals = scan_swift(src)
    previews = preview_ranges(code)
    for lit in literals:
        if any(a <= lit.start <= b for a, b in previews):
            continue
        before = code[max(0, lit.start - 80):lit.start]
        context = next((name for name, rx in CONTEXTS if rx.search(before)), None)
        if context is None:
            continue
        after = code[lit.end:lit.end + 60]
        if OTHER_TABLE_RE.match(after):
            continue
        template = lit.template
        if not has_letters(template):
            continue
        yield lit.line, context, template


def main():
    violations = []
    app = Catalog("Localizable.xcstrings", load_xcstrings(APP_CATALOG))
    widget = Catalog("widget Localizable.strings", load_lproj_catalog(WIDGET_RES))

    targets = []
    for path in sorted(APP_SRC.rglob("*.swift")):
        cats = [app]
        if SHARED_WITH_WIDGET in path.parents:
            cats.append(widget)
        targets.append((path, cats))
    for path in sorted(WIDGET_SRC.rglob("*.swift")):
        targets.append((path, [widget]))

    checked = 0
    reported = set()
    for path, cats in targets:
        rel = path.relative_to(ROOT)
        if VERBOSE:
            print(f"checking {rel}")
        for line, context, template in lookups(path):
            checked += 1
            for cat in cats:
                keys = cat.resolve(template)
                if not keys:
                    violations.append(f"{rel}:{line}: {context} key \"{describe(template)}\" is not in {cat.name}")
                    continue
                problem_sets = [(key, check_catalog_entry(key, cat.entries[key])) for key in keys]
                if any(not problems for _, problems in problem_sets):
                    continue  # at least one matching key is complete
                for key, problems in problem_sets:
                    tag = (cat.name, key)
                    if tag in reported:
                        continue
                    reported.add(tag)
                    violations.append(f"{rel}:{line}: \"{key}\" in {cat.name}: " + "; ".join(problems))

    # Permission prompts: every *UsageDescription in project.yml needs a
    # translated InfoPlist.xcstrings entry.
    usage_keys = sorted(set(re.findall(r"^\s+(NS\w+UsageDescription):", PROJECT_YML.read_text(encoding="utf-8"), re.M)))
    if usage_keys:
        if not INFOPLIST_CATALOG.exists():
            violations.append(f"{INFOPLIST_CATALOG.relative_to(ROOT)} is missing (needed for {', '.join(usage_keys)})")
        else:
            info = load_xcstrings(INFOPLIST_CATALOG)
            for key in usage_keys:
                if key not in info:
                    violations.append(f"InfoPlist.xcstrings: \"{key}\" is missing")
                    continue
                missing = [lang for lang in LANGS if not info[key].get(lang)]
                if missing:
                    violations.append(f"InfoPlist.xcstrings: \"{key}\" has no {'/'.join(missing)} value")

    if violations:
        print("check-localization: keys used in code are missing or untranslated\n")
        for v in violations:
            print("  " + v)
        print(f"\n{len(violations)} violation(s) in {checked} lookups. Add the key to the catalog "
              "with ru, en and es values (ru is the source language).")
        return 1
    print(f"check-localization: OK ({checked} lookups, all keys present in ru/en/es)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
