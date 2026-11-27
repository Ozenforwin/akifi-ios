#!/usr/bin/env python3
"""
test-lints.py — fixture tests for the ADR-001 / ADR-003 lints.

Each case is a tiny source file with a known verdict. The lints are run with
`--root <temp tree>` and must report exactly the expected number of hits, so a
regression of the lint itself (a bypass that used to be caught, or noise on
good code) fails CI.

Run: python3 Scripts/test-lints.py
"""
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
PAGING = SCRIPTS / "lint-unbounded-fetch.py"
AMOUNT = SCRIPTS / "lint_amount_usage.py"

# (name, relative path, source, expected hits)
PAGING_CASES = [
    # ── Swift: must be caught ──
    ("swift multi-line signature returning array", "AkifiIOS/Repositories/A.swift", """
final class A {
    func fetch(
        userId: String,
        since: String
    ) async throws -> [Row] {
        try await supabase
            .from("rows")
            .select()
            .eq("user_id", value: userId)
            .execute()
            .value
    }
}
""", 1),
    ("swift response stored in a variable", "AkifiIOS/Repositories/B.swift", """
final class B {
    func fetch() async throws {
        let response = try await supabase
            .from("rows")
            .select()
            .execute()
        let rows = try JSONDecoder().decode([Row].self, from: response.data)
        print(rows)
    }
}
""", 1),
    ("swift Array<T> declared type", "AkifiIOS/Repositories/C.swift", """
final class C {
    func fetch() async throws {
        let rows: Array<Row> = try await supabase
            .from("rows")
            .select()
            .execute()
            .value
        print(rows)
    }
}
""", 1),
    ("swift limit(5000) is not a bound", "AkifiIOS/Repositories/D.swift", """
final class D {
    func fetch() async throws -> [Row] {
        try await supabase
            .from("rows")
            .select()
            .limit(5000)
            .execute()
            .value
    }
}
""", 1),
    ("swift builder kept in a variable", "AkifiIOS/Repositories/E.swift", """
final class E {
    func fetch(flag: Bool) async throws -> [Row] {
        var q = supabase.from("rows").select()
        if flag { q = q.eq("a", value: 1) }
        let rows: [Row] = try await q.execute().value
        return rows
    }
}
""", 1),
    ("swift typealias of an array", "AkifiIOS/Repositories/F.swift", """
typealias Rows = [Row]
final class F {
    func fetch() async throws {
        let rows: Rows = try await supabase.from("rows").select().execute().value
        print(rows)
    }
}
""", 1),
    # ── Swift: must pass ──
    ("swift single row", "AkifiIOS/Repositories/G.swift", """
final class G {
    func fetch() async throws -> Row {
        try await supabase.from("rows").select().eq("id", value: 1).single().execute().value
    }
}
""", 0),
    ("swift small literal limit", "AkifiIOS/Repositories/H.swift", """
final class H {
    func fetch() async throws -> [Row] {
        try await supabase.from("rows").select().limit(10).execute().value
    }
}
""", 0),
    ("swift non-array return type", "AkifiIOS/Repositories/I.swift", """
final class I {
    func fetch(
        a: Int
    ) async throws -> Summary {
        try await supabase.rpc("summary").execute().value
    }
}
""", 0),
    ("swift annotated", "AkifiIOS/Repositories/J.swift", """
final class J {
    func fetch() async throws -> [Row] {
        // bounded-fetch: one row per currency code
        try await supabase.from("rows").select().execute().value
    }
}
""", 0),
    ("swift write without rows", "AkifiIOS/Repositories/K.swift", """
final class K {
    func save() async throws {
        try await supabase.from("rows").insert(x).execute()
    }
}
""", 0),
    # ── TypeScript ──
    ("ts bare select", "supabase/functions/f/index.ts", """
export async function f(supabase: any) {
  const { data } = await supabase
    .from("profiles")
    .select("id")
    .eq("a", 1);
  return data;
}
""", 1),
    ("ts limit(5000)", "supabase/functions/f/index.ts", """
export async function f(supabase: any) {
  const { data } = await supabase.from("profiles").select("id").limit(5000);
  return data;
}
""", 1),
    ("ts bare rpc", "supabase/functions/f/index.ts", """
export async function f(supabase: any) {
  const { data } = await supabase.rpc("things", { a: 1 });
  return data;
}
""", 1),
    ("ts inside fetchAll", "supabase/functions/f/index.ts", """
import { fetchAll } from "../_shared/paging.ts";
export async function f(supabase: any) {
  return await fetchAll("profiles", () =>
    supabase.from("profiles").select("id", { count: "exact" }).eq("a", 1));
}
""", 0),
    ("ts maybeSingle", "supabase/functions/f/index.ts", """
export async function f(supabase: any) {
  return await supabase.from("profiles").select("id").eq("id", 1).maybeSingle();
}
""", 0),
    ("ts annotated", "supabase/functions/f/index.ts", """
export async function f(supabase: any) {
  // bounded-fetch: one row per currency
  const { data } = await supabase.from("fx_rates").select("code");
  return data;
}
""", 0),
    ("ts builder var consumed by fetchAll", "supabase/functions/f/index.ts", """
import { fetchAll } from "../_shared/paging.ts";
export async function f(supabase: any) {
  const q = supabase.from("profiles").select("id", { count: "exact" });
  return await fetchAll("profiles", () => q);
}
""", 0),
]

AMOUNT_CASES = [
    ("multi-line reduce over tx.amount", "AkifiIOS/ViewModels/A.swift", """
func total(_ txs: [Transaction]) -> Int64 {
    txs.reduce(0) { acc, tx in
        acc + tx.amount
    }
}
""", 1),
    ("map keypath then reduce", "AkifiIOS/ViewModels/B.swift", """
func total(_ transactions: [Transaction]) -> Int64 {
    transactions.map(\\.amount).reduce(0, +)
}
""", 1),
    ("x = x + tx.amount", "AkifiIOS/ViewModels/C.swift", """
func total(_ txs: [Transaction]) -> Int64 {
    var sum: Int64 = 0
    for tx in txs {
        sum = sum + tx.amount
    }
    return sum
}
""", 1),
    ("+= tx.amount", "AkifiIOS/ViewModels/D.swift", """
func total(_ txs: [Transaction]) -> Int64 {
    var sum: Int64 = 0
    for tx in txs { sum += tx.amount }
    return sum
}
""", 1),
    ("amountNative summed across accounts without conversion", "AkifiIOS/ViewModels/E.swift", """
func total(_ txs: [Transaction]) -> Int64 {
    txs.reduce(0) { $0 + $1.amountNative }
}
""", 1),
    ("amountInBase is fine", "AkifiIOS/ViewModels/F.swift", """
func total(_ txs: [Transaction]) -> Int64 {
    txs.reduce(0) { $0 + TransactionMath.amountInBase($1, ctx) }
}
""", 0),
    ("amountNative inside one account is fine", "AkifiIOS/ViewModels/G.swift", """
func total(_ txs: [Transaction], accountId: String) -> Int64 {
    txs.filter { $0.accountId == accountId }.reduce(0) { $0 + $1.amountNative }
}
""", 0),
    ("non-transaction amount is fine", "AkifiIOS/ViewModels/H.swift", """
func monthly(_ subs: [Subscription]) -> Int64 {
    subs.reduce(0) { total, sub in total + sub.amount }
}
""", 0),
    ("sorting by amount is fine", "AkifiIOS/ViewModels/I.swift", """
func sorted(_ txs: [Transaction]) -> [Transaction] {
    txs.sorted { $0.amount > $1.amount }
}
""", 0),
    ("allowlisted with a reason", "AkifiIOS/ViewModels/J.swift", """
func total(_ txs: [Transaction]) -> Int64 {
    // allowlisted-amount: single-currency legacy report
    txs.reduce(0) { $0 + $1.amount }
}
""", 0),
    ("ts reduce over tx.amount", "supabase/functions/f/index.ts", """
export const total = (rows: Tx[]) =>
  rows.reduce((s, tx) => s + tx.amount, 0);
""", 1),
    ("ts coalesce tail is fine", "supabase/functions/f/index.ts", """
export const total = (rows: Tx[]) =>
  rows.reduce((s, tx) => s + (tx.amount_in_base ?? tx.amount_native ?? tx.amount), 0);
""", 0),
]


def run(script, root):
    p = subprocess.run([sys.executable, str(script), "--root", str(root), "--strict"],
                       capture_output=True, text=True)
    out = p.stdout
    hits = [l for l in out.splitlines()
            if ("." in l.split(":")[0] and l.split(":")[0].endswith((".swift", ".ts")) and "[" in l)]
    return len(hits), out


def main():
    failures = 0
    for script, cases in ((PAGING, PAGING_CASES), (AMOUNT, AMOUNT_CASES)):
        for name, rel, src, expected in cases:
            with tempfile.TemporaryDirectory() as d:
                root = Path(d)
                f = root / rel
                f.parent.mkdir(parents=True, exist_ok=True)
                f.write_text(src.lstrip("\n"))
                got, out = run(script, root)
                ok = got == expected
                print(f"{'ok  ' if ok else 'FAIL'} [{script.stem}] {name}: expected {expected}, got {got}")
                if not ok:
                    failures += 1
                    print(out)
    if failures:
        print(f"\n{failures} lint fixture(s) failed")
        sys.exit(1)
    print("\nAll lint fixtures pass")


main()
