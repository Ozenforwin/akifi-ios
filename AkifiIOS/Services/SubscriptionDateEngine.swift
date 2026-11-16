import Foundation

/// Pure domain service for subscription date math.
///
/// # Schedule contract (shared with `supabase/functions/_shared/schedule.ts`)
/// The server cron and the app must produce the SAME dates, so both follow
/// one rule (D2, 2026-11-17 review):
///
/// - The k-th charge date is `anchor + k periods`, `anchor = start_date`.
/// - monthly / quarterly / yearly add 1 / 3 / 12 calendar months **to the
///   anchor** (never to the previous charge date) and clamp the day to the
///   month length: 31 Jan → 28/29 Feb → 31 Mar → 30 Apr → 31 May; yearly
///   29 Feb → 28 Feb in a non-leap year → 29 Feb again in the next leap year.
/// - weekly adds `7k` days; custom adds `30k` days.
/// - `next_payment_date` = the first `anchor + k·period` (k ≥ 0) strictly
///   after the last charged date.
///
/// Adding to the previous date instead loses the anchor day for good
/// (31 Jan → 28 Feb → 28 Mar) and JavaScript's `setUTCMonth` overflows
/// (31 Jan → 3 Mar, February never charged). The month arithmetic here is
/// plain integer math on (year, month, day) — no `Calendar` clamping rules —
/// so the Deno port can match it line for line.
///
/// Legacy rows: some subscriptions were created with `start_date` = "the day
/// it was added", not on the billing day. `anchor(for:)` falls back to
/// `next_payment_date` when it does not lie on `start_date`'s schedule, and
/// new writes always store a `start_date` that does (`resolveAnchor`).
///
/// Storage: dates are `yyyy-MM-dd` local days (`AppDateFormatters.isoDate`);
/// `Date` values are start of that day in `calendar`'s time zone.
///
/// See ADR-004-subscription-date-engine.
enum SubscriptionDateEngine {

    // MARK: - Configuration

    /// Default custom-period length when `BillingPeriod.custom` is selected
    /// and no explicit `customDays` is supplied.
    static let defaultCustomDays: Int = 30

    /// A payment within this many days of a scheduled charge date settles
    /// that charge (the auto-matcher uses the same window).
    static let chargeWindowDays: Int = 7

    // MARK: - Schedule (anchor + k periods)

    /// The `index`-th charge date of the schedule anchored at `anchor`.
    /// Negative indexes walk back before the anchor (history matching).
    static func chargeDate(
        anchor: Date,
        period: BillingPeriod,
        index k: Int,
        customDays: Int? = nil,
        calendar: Calendar = AppDateFormatters.localCalendar
    ) -> Date {
        let cal = gregorian(calendar)
        let a = Day(cal, anchor)
        return a.adding(k, of: Step(period, customDays: customDays)).date(cal)
    }

    /// First charge date (k ≥ 0) strictly after `date`.
    static func firstChargeDate(
        after date: Date,
        anchor: Date,
        period: BillingPeriod,
        customDays: Int? = nil,
        calendar: Calendar = AppDateFormatters.localCalendar
    ) -> Date {
        let cal = gregorian(calendar)
        let a = Day(cal, anchor)
        let step = Step(period, customDays: customDays)
        let k = max(0, firstIndex(after: Day(cal, date), anchor: a, step: step))
        return a.adding(k, of: step).date(cal)
    }

    /// Last charge date (any k) strictly before `date`.
    static func previousChargeDate(
        before date: Date,
        anchor: Date,
        period: BillingPeriod,
        customDays: Int? = nil,
        calendar: Calendar = AppDateFormatters.localCalendar
    ) -> Date {
        let cal = gregorian(calendar)
        let a = Day(cal, anchor)
        let step = Step(period, customDays: customDays)
        // Smallest k with charge ≥ date, minus one.
        let k = firstIndex(after: Day(number: Day(cal, date).number - 1), anchor: a, step: step)
        return a.adding(k - 1, of: step).date(cal)
    }

    /// The charge date (any k, history included) closest to `date`; ties go
    /// to the earlier one.
    static func nearestChargeDate(
        to date: Date,
        anchor: Date,
        period: BillingPeriod,
        customDays: Int? = nil,
        calendar: Calendar = AppDateFormatters.localCalendar
    ) -> Date {
        let cal = gregorian(calendar)
        let a = Day(cal, anchor)
        let d = Day(cal, date)
        let step = Step(period, customDays: customDays)
        let k = firstIndex(after: d, anchor: a, step: step)
        let before = a.adding(k - 1, of: step)
        let after = a.adding(k, of: step)
        let nearest = (d.number - before.number) <= (after.number - d.number) ? before : after
        return nearest.date(cal)
    }

    /// True when `date` is one of the schedule's charge dates.
    static func isOnSchedule(
        _ date: Date,
        anchor: Date,
        period: BillingPeriod,
        customDays: Int? = nil,
        calendar: Calendar = AppDateFormatters.localCalendar
    ) -> Bool {
        let cal = gregorian(calendar)
        let nearest = nearestChargeDate(to: date, anchor: anchor, period: period, customDays: customDays, calendar: cal)
        return Day(cal, nearest) == Day(cal, date)
    }

    /// Whole calendar days from `from` to `to` (negative when `to` is earlier).
    static func daysBetween(_ from: Date, _ to: Date, calendar: Calendar = AppDateFormatters.localCalendar) -> Int {
        let cal = gregorian(calendar)
        return Day(cal, to).number - Day(cal, from).number
    }

    // MARK: - Schedule of a stored subscription

    /// The schedule anchor of a stored subscription: `start_date` when
    /// `next_payment_date` lies on its schedule (or is missing), otherwise
    /// `next_payment_date` — legacy rows stored "created on" as `start_date`.
    static func anchor(
        for sub: SubscriptionTracker,
        calendar: Calendar = AppDateFormatters.localCalendar
    ) -> Date? {
        let start = parseDay(sub.startDate, calendar: calendar)
        let next = parseDay(sub.nextPaymentDate, calendar: calendar)
        guard let start else { return next }
        guard let next else { return start }
        return isOnSchedule(next, anchor: start, period: sub.billingPeriod, calendar: calendar) ? start : next
    }

    /// The `start_date` to store when the user saves a subscription with an
    /// explicit next payment date: the first candidate (in order) that is not
    /// after `nextPayment` and has it on its schedule, else `nextPayment`
    /// itself. Keeping an old anchor preserves a 31st billing day through
    /// short months; falling back to `nextPayment` keeps the user's choice.
    static func resolveAnchor(
        candidates: [Date?],
        nextPayment: Date,
        period: BillingPeriod,
        calendar: Calendar = AppDateFormatters.localCalendar
    ) -> Date {
        let cal = gregorian(calendar)
        let next = cal.startOfDay(for: nextPayment)
        for case let candidate? in candidates {
            let c = cal.startOfDay(for: candidate)
            if c <= next, isOnSchedule(next, anchor: c, period: period, calendar: cal) {
                return c
            }
        }
        return next
    }

    /// The charge date a payment made on `date` settles: the nearest
    /// scheduled date within `chargeWindowDays`, or nil when the payment is
    /// off-schedule.
    static func chargedCycle(
        forPaymentOn date: Date,
        subscription sub: SubscriptionTracker,
        calendar: Calendar = AppDateFormatters.localCalendar
    ) -> Date? {
        guard let anchor = anchor(for: sub, calendar: calendar) else { return nil }
        let nearest = nearestChargeDate(to: date, anchor: anchor, period: sub.billingPeriod, calendar: calendar)
        return abs(daysBetween(date, nearest, calendar: calendar)) <= chargeWindowDays ? nearest : nil
    }

    /// `yyyy-MM-dd` key of the charge a stored payment date settles (the
    /// date itself when off-schedule). Two payments with the same key pay
    /// the same cycle — use it to dedupe instead of the raw payment date.
    static func cycleKey(forPaymentOn raw: String, subscription sub: SubscriptionTracker) -> String {
        let day = String(raw.prefix(10))
        guard let date = parseDbDate(day),
              let cycle = chargedCycle(forPaymentOn: date, subscription: sub) else { return day }
        return formatDbDate(cycle)
    }

    /// `next_payment_date` after a payment on `paymentDate` (manual record,
    /// auto-match, history backfill): the first charge date strictly after
    /// the charge that payment settles — a payment two days early or late
    /// keeps the billing day instead of moving it. Never earlier than the
    /// stored `next_payment_date`, so recording an old payment cannot
    /// re-open a cycle the server already charged.
    static func nextPaymentDate(
        for sub: SubscriptionTracker,
        afterPaymentOn paymentDate: Date,
        calendar: Calendar = AppDateFormatters.localCalendar
    ) -> Date {
        let cal = gregorian(calendar)
        let paid = cal.startOfDay(for: paymentDate)
        guard let anchor = anchor(for: sub, calendar: cal) else {
            return nextPaymentDate(from: paid, period: sub.billingPeriod, calendar: cal)
        }
        let settled = chargedCycle(forPaymentOn: paid, subscription: sub, calendar: cal) ?? paid
        let computed = firstChargeDate(after: settled, anchor: anchor, period: sub.billingPeriod, calendar: cal)
        if let current = parseDay(sub.nextPaymentDate, calendar: cal), current > computed {
            return current
        }
        return computed
    }

    // MARK: - One period from a date (form previews)

    /// One billing period after `lastPaymentDate` — i.e. charge #1 of the
    /// schedule anchored at it.
    static func nextPaymentDate(
        from lastPaymentDate: Date,
        period: BillingPeriod,
        customDays: Int? = nil,
        calendar: Calendar = AppDateFormatters.localCalendar
    ) -> Date {
        chargeDate(anchor: lastPaymentDate, period: period, index: 1, customDays: customDays, calendar: calendar)
    }

    /// One billing period before `nextPaymentDate` — used when the user
    /// enters "next payment" but we need to infer "last payment".
    static func previousPaymentDate(
        from nextPaymentDate: Date,
        period: BillingPeriod,
        customDays: Int? = nil,
        calendar: Calendar = AppDateFormatters.localCalendar
    ) -> Date {
        chargeDate(anchor: nextPaymentDate, period: period, index: -1, customDays: customDays, calendar: calendar)
    }

    // MARK: - Reminders

    /// Reminder fire date: `nextPaymentDate - daysBefore` at the given hour of day.
    ///
    /// - Returns: `Date` at `hour:00` local time on the reminder day, or `nil` if in the past.
    static func reminderFireDate(
        nextPaymentDate: Date,
        daysBefore: Int,
        hour: Int = 9,
        calendar: Calendar = AppDateFormatters.localCalendar,
        now: Date = Date()
    ) -> Date? {
        let cal = gregorian(calendar)
        let days = max(0, daysBefore)
        let day = cal.date(byAdding: .day, value: -days, to: cal.startOfDay(for: nextPaymentDate)) ?? nextPaymentDate
        var components = cal.dateComponents([.year, .month, .day], from: day)
        components.hour = hour
        components.minute = 0
        guard let fire = cal.date(from: components) else { return nil }
        return fire > now ? fire : nil
    }

    // MARK: - String helpers (date-only persistence)

    /// Canonical date-only formatter for `start_date`, `last_payment_date`,
    /// `next_payment_date`: local day, POSIX, gregorian.
    static var dbDateFormatter: DateFormatter { AppDateFormatters.isoDate }

    /// Parse a `yyyy-MM-dd` (or longer ISO) string into a start-of-day `Date`.
    /// Returns `nil` if unparsable.
    static func parseDbDate(_ string: String?) -> Date? {
        guard let s = string, !s.isEmpty else { return nil }
        // Accept both pure date and full ISO timestamps ("2026-04-15T09:00:00Z").
        return AppDateFormatters.isoDate.date(from: String(s.prefix(10)))
    }

    /// Format a `Date` as `yyyy-MM-dd` for persistence.
    static func formatDbDate(_ date: Date) -> String {
        AppDateFormatters.isoDate.string(from: date)
    }

    /// The first 10 characters (`yyyy-MM-dd`) as start of that day in
    /// `calendar`'s time zone — `parseDbDate` with an explicit zone (tests pin UTC).
    static func parseDay(_ string: String?, calendar: Calendar) -> Date? {
        AppDateFormatters.day(string, calendar: calendar)
    }

    // MARK: - Integer day math

    private static func gregorian(_ calendar: Calendar) -> Calendar {
        guard calendar.identifier != .gregorian else { return calendar }
        return AppDateFormatters.gregorian(timeZone: calendar.timeZone)
    }

    /// Smallest k (any sign) whose charge date is strictly after `date`.
    private static func firstIndex(after date: Day, anchor: Day, step: Step) -> Int {
        switch step {
        case .months(let m):
            let diff = (date.year * 12 + date.month) - (anchor.year * 12 + anchor.month)
            var k = floorDiv(diff, m) - 1        // ≥ one month before `date`
            while anchor.adding(k, of: step).number <= date.number { k += 1 }
            return k
        case .days(let p):
            return floorDiv(date.number - anchor.number, p) + 1
        }
    }

    private static func floorDiv(_ a: Int, _ b: Int) -> Int {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    private enum Step {
        case months(Int)
        case days(Int)

        init(_ period: BillingPeriod, customDays: Int?) {
            switch period {
            case .weekly: self = .days(7)
            case .monthly: self = .months(1)
            case .quarterly: self = .months(3)
            case .yearly: self = .months(12)
            case .custom: self = .days(max(1, customDays ?? SubscriptionDateEngine.defaultCustomDays))
            }
        }
    }

    /// A proleptic-gregorian calendar day.
    private struct Day: Equatable {
        let year: Int
        let month: Int
        let day: Int

        init(year: Int, month: Int, day: Int) {
            self.year = year; self.month = month; self.day = day
        }

        init(_ cal: Calendar, _ date: Date) {
            let c = cal.dateComponents([.year, .month, .day], from: date)
            self.init(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
        }

        init(number: Int) {
            // Inverse of `number` (H. Hinnant, civil_from_days).
            let z = number + 719_468
            let era = (z >= 0 ? z : z - 146_096) / 146_097
            let doe = z - era * 146_097
            let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
            let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
            let mp = (5 * doy + 2) / 153
            let d = doy - (153 * mp + 2) / 5 + 1
            let m = mp < 10 ? mp + 3 : mp - 9
            self.init(year: yoe + era * 400 + (m <= 2 ? 1 : 0), month: m, day: d)
        }

        /// Days since 1970-01-01 (H. Hinnant, days_from_civil).
        var number: Int {
            let y = month <= 2 ? year - 1 : year
            let era = (y >= 0 ? y : y - 399) / 400
            let yoe = y - era * 400
            let mp = (month + 9) % 12
            let doy = (153 * mp + 2) / 5 + day - 1
            let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
            return era * 146_097 + doe - 719_468
        }

        func adding(_ k: Int, of step: Step) -> Day {
            switch step {
            case .months(let m):
                let total = year * 12 + (month - 1) + k * m
                let y = SubscriptionDateEngine.floorDiv(total, 12)
                let mo = total - y * 12 + 1
                return Day(year: y, month: mo, day: min(day, Day.daysInMonth(year: y, month: mo)))
            case .days(let p):
                return Day(number: number + k * p)
            }
        }

        func date(_ cal: Calendar) -> Date {
            let comps = DateComponents(year: year, month: month, day: day)
            return cal.date(from: comps).map { cal.startOfDay(for: $0) } ?? Date(timeIntervalSince1970: 0)
        }

        static func daysInMonth(year: Int, month: Int) -> Int {
            switch month {
            case 2:
                let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
                return leap ? 29 : 28
            case 4, 6, 9, 11: return 30
            default: return 31
            }
        }
    }
}
