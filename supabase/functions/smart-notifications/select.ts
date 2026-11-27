// Which notification candidates actually go out for one event.
//
// Order matters: drop what was already sent FIRST, then sort by priority,
// then cap. Capping before the dedupe let two already-sent budget alerts
// occupy both slots on every expense, so new crossings, large-expense and
// savings alerts were never delivered until the period rolled over
// (review 2026-11-27, N1: no budget push from 2026-11-17 while three shared
// budgets were at 157–284 %).

export interface Selectable {
  type: string;
  key: string;
}

/// Lower number = more important.
export const NOTIFICATION_PRIORITY: Record<string, number> = {
  budget_warning: 1,
  large_expense: 2,
  weekly_pace: 3,
  savings_milestone: 4,
  inactivity: 5,
};

/// `alreadySent`: notification keys already in notification_log for this
/// user. `cap`: how many may go out now (per-event cap and what is left of
/// the daily limit, whichever is smaller). Stable: equal priorities keep
/// their input order. Duplicate keys within `candidates` count once.
export function selectCandidates<T extends Selectable>(
  candidates: T[],
  alreadySent: ReadonlySet<string>,
  cap: number,
): T[] {
  if (!(cap > 0)) return [];
  const seen = new Set<string>();
  const fresh: { c: T; i: number }[] = [];
  candidates.forEach((c, i) => {
    if (alreadySent.has(c.key) || seen.has(c.key)) return;
    seen.add(c.key);
    fresh.push({ c, i });
  });
  fresh.sort((a, b) =>
    (NOTIFICATION_PRIORITY[a.c.type] ?? 99) - (NOTIFICATION_PRIORITY[b.c.type] ?? 99) || a.i - b.i
  );
  return fresh.slice(0, Math.floor(cap)).map((x) => x.c);
}
