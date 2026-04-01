import Foundation

// MARK: - Transaction formatted date+time (mirrors Mini App logic)

extension Transaction {
    /// Formatted date+time like Mini App: "25 мар 2026, 14:30"
    var formattedDateTime: String {
        let datePart: String
        if let d = Self.isoDF.date(from: date) {
            datePart = Self.outDateDF.string(from: d)
        } else {
            datePart = date
        }

        if let createdAt,
           let d = Self.createdAtDF.date(from: String(createdAt.prefix(19))) {
            return "\(datePart), \(Self.outTimeDF.string(from: d))"
        }

        return datePart
    }

    private static let isoDF: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        return df
    }()

    private static let outDateDF: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale.current
        df.dateFormat = "d MMM yyyy"
        return df
    }()

    private static let createdAtDF: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        return df
    }()

    private static let outTimeDF: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale.current
        df.dateFormat = "HH:mm"
        return df
    }()
}

extension Date {
    var isoDateString: String {
        AppDateFormatters.isoDate.string(from: self)
    }

    var displayString: String {
        AppDateFormatters.displayDate.string(from: self)
    }

    static func fromISO(_ string: String) -> Date? {
        AppDateFormatters.isoDate.date(from: string)
    }
}
