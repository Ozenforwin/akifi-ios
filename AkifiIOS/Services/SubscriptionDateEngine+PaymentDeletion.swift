import Foundation

extension SubscriptionDateEngine {

    /// `last_payment_date` / `next_payment_date` after payment rows are
    /// deleted from the history (V8).
    ///
    /// Recording a payment moves `next` past the charge it settles;
    /// deleting it left `next` there, so a mistaken 17 Nov payment pushed
    /// the next charge to 17 Dec for good, and the real November charge and
    /// its reminder were skipped. The undo banner restores the dates it
    /// captured (`undoPayment`); history has no captured dates, so they are
    /// recomputed:
    ///
    /// - `next` goes back to the charge a deleted payment settled — but not
    ///   before the charge after the latest REMAINING payment (deleting one
    ///   of two payments for the same cycle keeps it paid), and never later
    ///   than it is now (a deletion doesn't pay anything). It never
    ///   re-opens cycles the deleted payment didn't settle.
    /// - `last` becomes the latest remaining payment when it was set by a
    ///   deleted one (nil when none remain); a date no deleted payment
    ///   explains (entered in the form) is left alone.
    ///
    /// Dates are `yyyy-MM-dd`; payment dates may be timestamps (the server
    /// writes `…T00:00:00+00:00`), only their day is used.
    static func datesAfterDeleting(
        paymentDates deleted: [String],
        remainingPaymentDates remaining: [String],
        subscription sub: SubscriptionTracker,
        calendar: Calendar = AppDateFormatters.localCalendar
    ) -> (last: String?, next: String?) {
        let deletedDays = Set(deleted.map { String($0.prefix(10)) })
        let remainingDays = remaining.map { String($0.prefix(10)) }
        let latestRemaining = remainingDays.max()
        let currentLast = sub.lastPaymentDate.map { String($0.prefix(10)) }
        let currentNext = sub.nextPaymentDate.map { String($0.prefix(10)) }

        var newLast = currentLast
        if let last = currentLast, deletedDays.contains(last), !remainingDays.contains(last) {
            newLast = latestRemaining
        } else if currentLast == nil {
            newLast = latestRemaining
        }

        guard let anchor = anchor(for: sub, calendar: calendar) else { return (newLast, currentNext) }
        let period = sub.billingPeriod

        /// The charge a payment on `day` settles; off-schedule, the first
        /// charge after it (what `nextPaymentDate(for:afterPaymentOn:)`
        /// moved `next` to).
        func settled(_ day: String) -> Date? {
            guard let date = parseDay(day, calendar: calendar) else { return nil }
            return chargedCycle(forPaymentOn: date, subscription: sub, calendar: calendar)
                ?? firstChargeDate(after: date, anchor: anchor, period: period, calendar: calendar)
        }

        guard let reopened = deletedDays.compactMap(settled).min() else { return (newLast, currentNext) }
        var candidate = reopened
        if let latestRemaining, let latestDate = parseDay(latestRemaining, calendar: calendar) {
            let cycle = chargedCycle(forPaymentOn: latestDate, subscription: sub, calendar: calendar) ?? latestDate
            candidate = max(candidate, firstChargeDate(after: cycle, anchor: anchor, period: period, calendar: calendar))
        }
        if let current = parseDay(currentNext, calendar: calendar) {
            candidate = min(candidate, current)
        }
        return (newLast, formatDbDate(candidate, calendar: calendar))
    }

    /// `formatDbDate` in `calendar`'s zone (tests pin UTC).
    static func formatDbDate(_ date: Date, calendar: Calendar) -> String {
        AppDateFormatters.localDate(in: calendar.timeZone).string(from: date)
    }
}
