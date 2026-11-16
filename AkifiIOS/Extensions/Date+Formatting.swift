import Foundation

// MARK: - Transaction formatted date+time (mirrors Mini App logic)

extension Transaction {
    /// Formatted date+time like Mini App: "25 мар 2026, 14:30".
    ///
    /// The day comes from `date` (the user's local day — see
    /// `AppDateFormatters`), the time from `created_at`, an instant that
    /// PostgREST returns as `2026-03-25T07:30:00.123+00:00` and is shown in
    /// the device's time zone.
    var formattedDateTime: String {
        let datePart: String
        if let d = AppDateFormatters.isoDate.date(from: date) {
            datePart = AppDateFormatters.shortDate.string(from: d)
        } else {
            datePart = date
        }

        if let createdAt, let d = AppDateFormatters.parseTimestamp(createdAt) {
            return "\(datePart), \(AppDateFormatters.shortTime.string(from: d))"
        }

        return datePart
    }
}

extension Date {
    /// The local calendar day, `yyyy-MM-dd`.
    var isoDateString: String {
        AppDateFormatters.isoDate.string(from: self)
    }

    var displayString: String {
        AppDateFormatters.displayDate.string(from: self)
    }

    /// Parses a local `yyyy-MM-dd` day (start of that day, device time zone).
    static func fromISO(_ string: String) -> Date? {
        AppDateFormatters.isoDate.date(from: string)
    }
}
