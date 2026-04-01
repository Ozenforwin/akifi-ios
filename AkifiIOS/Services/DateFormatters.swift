import Foundation

/// Shared DateFormatter cache.
/// All callers are @MainActor, so static lets are safe (no thread-safety concern).
enum AppDateFormatters {

    /// "yyyy-MM-dd" with POSIX locale (for DB dates)
    static let isoDate: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        return df
    }()

    /// Medium date style with device locale
    static let displayDate: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.locale = Locale.current
        return df
    }()

    /// "d MMM yyyy" with device locale
    static let shortDate: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "d MMM yyyy"
        df.locale = Locale.current
        return df
    }()

    /// "LLLL yyyy" — full month + year, device locale
    static let monthYear: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "LLLL yyyy"
        df.locale = Locale.current
        return df
    }()

    /// "LLL" — short month name
    static let shortMonth: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "LLL"
        df.locale = Locale.current
        return df
    }()

    /// "HH:mm" with device locale
    static let shortTime: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm"
        df.locale = Locale.current
        return df
    }()
}
