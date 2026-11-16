// Complete-set reads from PostgREST for edge functions (ADR-003).
//
// PostgREST caps every response at the project's `max-rows` (1000) and
// returns the truncated page WITHOUT an error. `.limit(5000)` does not
// help — the server cap still wins — so every list read in server code
// goes through `fetchAll`, the TypeScript twin of the iOS
// `SupabasePaging.all`:
//
// 1. The server's limit is never assumed. `pageSize` is a round-trip hint;
//    the loop advances by rows received and stops only when the server's
//    own `count=exact` is satisfied or a page comes back empty.
// 2. A total order is enforced: the primary key is appended as the last
//    `order` term, so offset paging over ties (same date) is sound.
// 3. The assembled set is cross-checked against the server count and the
//    read retried once on mismatch (rows inserted/deleted mid-read).

export const PAGE_SIZE = 1000;
const MAX_PAGES = 1000;

export interface Page<Row> {
  rows: Row[];
  /** Server-reported total (Content-Range). `null` when unknown. */
  total: number | null;
}

export class PagingError extends Error {}

/**
 * Pure driver: assembles the full result by calling `fetchPage(offset,
 * limit)`. Network-free so it can be tested against a simulated
 * PostgREST with any max-rows value.
 */
export async function drain<Row>(
  label: string,
  fetchPage: (offset: number, limit: number) => Promise<Page<Row>>,
  opts: { pageSize?: number; key?: (row: Row) => unknown } = {},
): Promise<Row[]> {
  const pageSize = opts.pageSize ?? PAGE_SIZE;
  let rows: Row[] = [];
  for (let attempt = 1; attempt <= 2; attempt++) {
    rows = [];
    let offset = 0;
    let expected: number | null = null;
    let pages = 0;
    while (true) {
      const page = await fetchPage(offset, pageSize);
      pages += 1;
      if (offset === 0) expected = page.total;
      rows.push(...page.rows);
      if (page.rows.length === 0) break;
      offset += page.rows.length;
      // A short page is ambiguous (end of data OR a smaller max-rows):
      // only the server count can say we are done.
      if (expected !== null && rows.length >= expected) break;
      if ((expected !== null && offset > expected + pageSize) || pages >= MAX_PAGES) {
        throw new PagingError(`${label}: server is not honouring offset (${pages} pages)`);
      }
    }
    if (opts.key) {
      const seen = new Set<unknown>();
      rows = rows.filter((r) => {
        const k = opts.key!(r);
        if (seen.has(k)) return false;
        seen.add(k);
        return true;
      });
    }
    if (expected === null || rows.length === expected) return rows;
    if (attempt === 2) {
      console.error(`[paging] ${label}: assembled ${rows.length} rows, server said ${expected}`);
    }
  }
  return rows;
}

// deno-lint-ignore no-explicit-any
type AnyQuery = any;

/**
 * Reads every row of a PostgREST query.
 *
 * `build` must return a FRESH query builder on every call (builders are
 * single-use) whose `.select(...)` was called with `{ count: "exact" }`.
 * `pk` is appended as the final order term (default `id`).
 *
 *   const rows = await fetchAll("profiles", () =>
 *     supabase.from("profiles").select("id,fcm_token", { count: "exact" })
 *       .not("fcm_token", "is", null));
 *
 * Throws on a PostgREST error — a failed read must never look like an
 * empty one.
 */
export async function fetchAll<Row = Record<string, unknown>>(
  label: string,
  build: () => AnyQuery,
  opts: { pk?: string; pageSize?: number } = {},
): Promise<Row[]> {
  const pk = opts.pk ?? "id";
  return await drain<Row>(
    label,
    async (offset, limit) => {
      const { data, error, count } = await build()
        .order(pk, { ascending: true })
        .range(offset, offset + limit - 1);
      if (error) {
        throw new PagingError(`${label}: ${error.message ?? "query failed"}`);
      }
      return { rows: (data ?? []) as Row[], total: typeof count === "number" ? count : null };
    },
    {
      pageSize: opts.pageSize,
      key: (row) => (row as Record<string, unknown>)[pk],
    },
  );
}

/** Splits `values` into chunks (keeps `.in()` filters well under URL limits). */
export function chunk<T>(values: T[], size = 150): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < values.length; i += size) out.push(values.slice(i, i + size));
  return out;
}

/** `fetchAll` over `.in(column, ids)` in URL-safe chunks. */
export async function fetchAllIn<Row = Record<string, unknown>>(
  label: string,
  ids: string[],
  build: (idsChunk: string[]) => AnyQuery,
  opts: { pk?: string; pageSize?: number } = {},
): Promise<Row[]> {
  const unique = [...new Set(ids.filter(Boolean))];
  const out: Row[] = [];
  for (const part of chunk(unique)) {
    out.push(...await fetchAll<Row>(label, () => build(part), opts));
  }
  return out;
}
