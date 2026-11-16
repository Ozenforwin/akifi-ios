import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  isValidTimeZone,
  lastFullDays,
  localDate,
  localHour,
  monthStart,
  resolveTimeZone,
  resolveTimeZones,
  startOfLocalDayUtc,
  weekStartMonday,
} from "./timezone.ts";

// D6: 06:00 on 1 Dec in UTC+7 is still 30 Nov in UTC.
const SIX_AM_DEC_1_BANGKOK = new Date("2026-11-30T23:00:00Z");

Deno.test("localDate: the user's day, not the server's", () => {
  assertEquals(localDate(SIX_AM_DEC_1_BANGKOK, "Asia/Bangkok"), "2026-12-01");
  assertEquals(localDate(SIX_AM_DEC_1_BANGKOK, "UTC"), "2026-11-30");
  assertEquals(localDate(SIX_AM_DEC_1_BANGKOK, "Europe/Moscow"), "2026-12-01");
});

Deno.test("localDate: invalid zone falls back to UTC", () => {
  assertEquals(localDate(SIX_AM_DEC_1_BANGKOK, "Mars/Olympus"), "2026-11-30");
});

Deno.test("localHour is 0-23 in the zone", () => {
  assertEquals(localHour(SIX_AM_DEC_1_BANGKOK, "Asia/Bangkok"), 6);
  assertEquals(localHour(new Date("2026-11-30T17:00:00Z"), "Asia/Bangkok"), 0);
});

Deno.test("startOfLocalDayUtc: local midnight as a UTC instant", () => {
  // 06:00 Bangkok (UTC+7) on 1 Dec → midnight 1 Dec Bangkok = 30 Nov 17:00 UTC.
  assertEquals(startOfLocalDayUtc(SIX_AM_DEC_1_BANGKOK, "Asia/Bangkok").toISOString(), "2026-11-30T17:00:00.000Z");
  assertEquals(startOfLocalDayUtc(SIX_AM_DEC_1_BANGKOK, "UTC").toISOString(), "2026-11-30T00:00:00.000Z");
  assertEquals(startOfLocalDayUtc(new Date("2026-11-17T22:30:00Z"), "Europe/Moscow").toISOString(), "2026-11-17T21:00:00.000Z");
});

Deno.test("isValidTimeZone", () => {
  assertEquals(isValidTimeZone("Asia/Makassar"), true);
  assertEquals(isValidTimeZone("Nope/Nope"), false);
  assertEquals(isValidTimeZone(""), false);
  assertEquals(isValidTimeZone(null), false);
});

Deno.test("weekStartMonday: Monday-based weeks", () => {
  assertEquals(weekStartMonday("2026-11-17"), "2026-11-16"); // Tuesday
  assertEquals(weekStartMonday("2026-11-16"), "2026-11-16"); // Monday
  assertEquals(weekStartMonday("2026-11-22"), "2026-11-16"); // Sunday
  assertEquals(weekStartMonday("2026-03-01"), "2026-02-23"); // Sunday across a month
});

Deno.test("monthStart: the local month, so the 1st in UTC+7 is not last month", () => {
  const today = localDate(SIX_AM_DEC_1_BANGKOK, "Asia/Bangkok");
  assertEquals(monthStart(today), "2026-12-01");
});

Deno.test("lastFullDays: exactly 7 days ending yesterday", () => {
  assertEquals(lastFullDays("2026-11-16", 7), { start: "2026-11-09", endExclusive: "2026-11-16" });
});

/** Fake client: `.from(t).select(c).in(col, ids)` resolves to canned rows. */
function fakeClient(tables: Record<string, { data?: unknown[]; error?: { code?: string; message?: string } }>) {
  return {
    from(table: string) {
      return {
        select() {
          return {
            in() {
              const t = tables[table] ?? {};
              return Promise.resolve({ data: t.error ? null : t.data ?? [], error: t.error ?? null });
            },
          };
        },
      };
    },
  };
}

Deno.test("resolveTimeZones: profiles.timezone first, then ai_user_settings, then UTC", async () => {
  const client = fakeClient({
    profiles: { data: [{ id: "a", timezone: "Asia/Bangkok" }, { id: "b", timezone: null }] },
    ai_user_settings: { data: [{ user_id: "a", timezone: "Europe/Moscow" }, { user_id: "b", timezone: "Europe/Moscow" }] },
  });
  const map = await resolveTimeZones(client, ["a", "b", "c"]);
  assertEquals(map.get("a"), "Asia/Bangkok");
  assertEquals(map.get("b"), "Europe/Moscow");
  assertEquals(map.get("c"), "UTC");
});

Deno.test("resolveTimeZones: tolerates profiles.timezone not existing yet", async () => {
  const client = fakeClient({
    profiles: { error: { code: "42703", message: "column profiles.timezone does not exist" } },
    ai_user_settings: { data: [{ user_id: "a", timezone: "Asia/Makassar" }] },
  });
  const map = await resolveTimeZones(client, ["a"]);
  assertEquals(map.get("a"), "Asia/Makassar");
});

Deno.test("resolveTimeZone: a valid preferred (device) zone wins; garbage is ignored", async () => {
  const client = fakeClient({ profiles: { data: [{ id: "a", timezone: "Europe/Moscow" }] } });
  assertEquals(await resolveTimeZone(client, "a", "Asia/Bangkok"), "Asia/Bangkok");
  assertEquals(await resolveTimeZone(client, "a", "garbage"), "Europe/Moscow");
});
