import { assertEquals, assertRejects } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { chunk, drain, fetchAll, PagingError } from "./paging.ts";

type Row = { id: number };
const dataset = (n: number): Row[] => Array.from({ length: n }, (_, i) => ({ id: i + 1 }));

/** Simulated PostgREST: honours offset, caps each page at `maxRows`. */
function server(rows: Row[], maxRows: number) {
  return (offset: number, limit: number) =>
    Promise.resolve({ rows: rows.slice(offset, offset + Math.min(limit, maxRows)), total: rows.length });
}

Deno.test("drain: more rows than max-rows are all returned", async () => {
  const got = await drain("t", server(dataset(2500), 1000));
  assertEquals(got.length, 2500);
});

// The ADR-003 trap: max-rows smaller than our page size. A loop that stops
// on "short page" would return 500 rows here.
Deno.test("drain: server max-rows below the page size still yields the full set", async () => {
  const got = await drain("t", server(dataset(1234), 500), { pageSize: 1000 });
  assertEquals(got.length, 1234);
});

Deno.test("drain: empty table", async () => {
  assertEquals(await drain("t", server([], 1000)), []);
});

Deno.test("drain: exactly one full page", async () => {
  assertEquals((await drain("t", server(dataset(1000), 1000))).length, 1000);
});

Deno.test("drain: unknown total falls back to empty-page termination", async () => {
  const rows = dataset(1500);
  const got = await drain("t", (offset, limit) =>
    Promise.resolve({ rows: rows.slice(offset, offset + Math.min(limit, 400)), total: null }));
  assertEquals(got.length, 1500);
});

Deno.test("drain: duplicates across a shifted page boundary are dropped by key", async () => {
  const rows = dataset(10);
  let calls = 0;
  const got = await drain("t", (offset, limit) => {
    calls += 1;
    // Second page re-serves the last row of the first page (a row was
    // inserted ahead of it between requests).
    const start = calls === 2 ? offset - 1 : offset;
    return Promise.resolve({ rows: rows.slice(start, start + Math.min(limit, 5)), total: 10 });
  }, { pageSize: 5, key: (r) => r.id });
  assertEquals(got.map((r) => r.id), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
});

Deno.test("drain: a server that ignores offset is an error, not a silent result", async () => {
  await assertRejects(
    () => drain("t", () => Promise.resolve({ rows: dataset(5), total: null }), { pageSize: 5 }),
    PagingError,
  );
});

/** Minimal fake of a supabase-js query builder. */
function fakeBuilder(rows: Row[], maxRows: number, calls: string[]) {
  const b = {
    orders: [] as string[],
    order(col: string) { b.orders.push(col); return b; },
    range(from: number, to: number) {
      calls.push(`${b.orders.join(",")}:${from}-${to}`);
      const page = rows.slice(from, Math.min(to + 1, from + maxRows));
      return Promise.resolve({ data: page, error: null, count: rows.length });
    },
  };
  return b;
}

Deno.test("fetchAll: appends the primary key order and pages with range()", async () => {
  const calls: string[] = [];
  const rows = dataset(2100);
  const got = await fetchAll<Row>("t", () => fakeBuilder(rows, 1000, calls));
  assertEquals(got.length, 2100);
  assertEquals(calls, ["id:0-999", "id:1000-1999", "id:2000-2999"]);
});

Deno.test("fetchAll: a PostgREST error throws", async () => {
  const broken = {
    order() { return broken; },
    range() { return Promise.resolve({ data: null, error: { message: "boom" }, count: null }); },
  };
  await assertRejects(() => fetchAll("t", () => broken), PagingError);
});

Deno.test("chunk splits arrays", () => {
  assertEquals(chunk([1, 2, 3, 4, 5], 2), [[1, 2], [3, 4], [5]]);
  assertEquals(chunk([], 2), []);
});
