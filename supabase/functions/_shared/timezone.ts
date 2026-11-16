// User-local calendar for edge functions.
//
// `transactions.date` is stored as the user's LOCAL wall-clock time with a
// +00:00 suffix (the app writes "floating" time), so `date.slice(0, 10)` is
// the user's local calendar day. Windows such as "today", "this week" or
// "the last 7 days" must therefore be computed from the user's local
// "today" — taking it from the server clock (UTC) made «сколько я потратил
// сегодня» at 06:00 in UTC+7 answer about yesterday (D6).
//
// Resolution order (contract with the budgets stream):
//   1. `profiles.timezone`           (IANA id, nullable; new column)
//   2. `ai_user_settings.timezone`   (legacy)
//   3. "UTC"
// Interactive callers may put the device's live zone in front of that
// (`preferred`), because a travelling user's "today" is where the phone is.

import { chunk } from "./paging.ts";

// deno-lint-ignore no-explicit-any
type Client = any;

export const DEFAULT_TIME_ZONE = "UTC";

export function isValidTimeZone(tz: unknown): tz is string {
  if (typeof tz !== "string" || !tz.trim()) return false;
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: tz.trim() });
    return true;
  } catch {
    return false;
  }
}

function parts(now: Date, tz: string): Record<string, string> {
  const fmt = new Intl.DateTimeFormat("en-US", {
    timeZone: tz,
    calendar: "gregory",
    numberingSystem: "latn",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    hourCycle: "h23",
  });
  const out: Record<string, string> = {};
  for (const p of fmt.formatToParts(now)) out[p.type] = p.value;
  return out;
}

/** The calendar date (`yyyy-MM-dd`) at `now` in `tz`. */
export function localDate(now: Date, tz: string = DEFAULT_TIME_ZONE): string {
  const p = parts(now, isValidTimeZone(tz) ? tz : DEFAULT_TIME_ZONE);
  return `${p.year}-${p.month}-${p.day}`;
}

/** The wall-clock hour (0–23) at `now` in `tz`. */
export function localHour(now: Date, tz: string = DEFAULT_TIME_ZONE): number {
  const p = parts(now, isValidTimeZone(tz) ? tz : DEFAULT_TIME_ZONE);
  return Number(p.hour) % 24;
}

/** The UTC instant of local midnight that starts `now`'s day in `tz`. */
export function startOfLocalDayUtc(now: Date, tz: string = DEFAULT_TIME_ZONE): Date {
  const zone = isValidTimeZone(tz) ? tz : DEFAULT_TIME_ZONE;
  const date = localDate(now, zone);
  // Offset of the zone at `now` (minutes, may be fractional-hour zones).
  const fmt = new Intl.DateTimeFormat("en-US", {
    timeZone: zone, calendar: "gregory", numberingSystem: "latn", hourCycle: "h23",
    year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit",
  });
  const p: Record<string, string> = {};
  for (const part of fmt.formatToParts(now)) p[part.type] = part.value;
  const wallAsUtc = Date.UTC(Number(p.year), Number(p.month) - 1, Number(p.day), Number(p.hour) % 24, Number(p.minute), Number(p.second));
  const offsetMs = wallAsUtc - Math.floor(now.getTime() / 1000) * 1000;
  return new Date(Date.parse(`${date}T00:00:00.000Z`) - offsetMs);
}

function shiftDate(date: string, days: number): string {
  const d = new Date(`${date.slice(0, 10)}T00:00:00.000Z`);
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}

/** Monday of the ISO week containing `date` (`yyyy-MM-dd`). */
export function weekStartMonday(date: string): string {
  const dow = new Date(`${date.slice(0, 10)}T00:00:00.000Z`).getUTCDay(); // 0 = Sunday
  return shiftDate(date, -((dow + 6) % 7));
}

/** First day of the month containing `date`. */
export function monthStart(date: string): string {
  return `${date.slice(0, 7)}-01`;
}

/**
 * The `days` full local days that ended before `today`:
 * `[today - days, today)` as inclusive `start` / exclusive `endExclusive`.
 * A weekly digest sent on Monday covers Monday..Sunday of the last week —
 * exactly 7 days, never 8.
 */
export function lastFullDays(today: string, days: number): { start: string; endExclusive: string } {
  return { start: shiftDate(today, -days), endExclusive: today.slice(0, 10) };
}

function isMissingColumn(error: { code?: string; message?: string } | null | undefined): boolean {
  if (!error) return false;
  return error.code === "42703" || error.code === "PGRST204" ||
    /column .*timezone/i.test(error.message ?? "");
}

/**
 * Time zones for many users at once (cron jobs). Users without a valid
 * zone are mapped to "UTC". Tolerates `profiles.timezone` not existing yet.
 */
export async function resolveTimeZones(
  supabase: Client,
  userIds: string[],
): Promise<Map<string, string>> {
  const ids = [...new Set(userIds.filter(Boolean))];
  const fromProfiles = new Map<string, string>();
  const fromSettings = new Map<string, string>();
  let profilesColumnMissing = false;
  for (const part of chunk(ids)) {
    if (!profilesColumnMissing) {
      // bounded-fetch: one row per id in `part` (primary-key filter, ≤150 ids).
      const { data, error } = await supabase.from("profiles").select("id,timezone").in("id", part);
      if (isMissingColumn(error)) {
        profilesColumnMissing = true;
      } else if (error) {
        console.warn("[tz] profiles.timezone read failed:", error.message);
      } else {
        for (const row of data ?? []) {
          if (isValidTimeZone(row.timezone)) fromProfiles.set(row.id, row.timezone.trim());
        }
      }
    }
    // bounded-fetch: ai_user_settings is keyed by user_id (≤150 ids).
    const { data: settings, error: settingsError } = await supabase
      .from("ai_user_settings").select("user_id,timezone").in("user_id", part);
    if (settingsError) {
      console.warn("[tz] ai_user_settings.timezone read failed:", settingsError.message);
    } else {
      for (const row of settings ?? []) {
        if (isValidTimeZone(row.timezone)) fromSettings.set(row.user_id, row.timezone.trim());
      }
    }
  }
  const out = new Map<string, string>();
  for (const id of ids) out.set(id, fromProfiles.get(id) ?? fromSettings.get(id) ?? DEFAULT_TIME_ZONE);
  return out;
}

/** Time zone of one user; `preferred` (e.g. the device zone) wins when valid. */
export async function resolveTimeZone(
  supabase: Client,
  userId: string,
  preferred?: unknown,
): Promise<string> {
  if (isValidTimeZone(preferred)) return (preferred as string).trim();
  try {
    return (await resolveTimeZones(supabase, [userId])).get(userId) ?? DEFAULT_TIME_ZONE;
  } catch (err) {
    console.warn("[tz] resolution failed, using UTC:", (err as Error)?.message);
    return DEFAULT_TIME_ZONE;
  }
}
