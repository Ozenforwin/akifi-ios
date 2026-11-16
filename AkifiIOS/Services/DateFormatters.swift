import Foundation

/// The one place the app builds date formatters and calendars.
///
/// # Why (D1, 2026-11-17 review)
/// A bare `DateFormatter()` inherits the device's calendar, locale and
/// 12/24-hour setting. With the region set to Thailand the calendar is
/// Buddhist, so `"yyyy"` writes 2569 and a transaction falls out of every
/// month; with a 12-hour override a fixed `"HH:mm"` can come back with an
/// AM/PM marker. A string that is stored in, or parsed from, the database must
/// never depend on that.
///
/// # Storage contract
/// - **Day strings** (`yyyy-MM-dd`: `start_date`, `deadline`, `contributed_at`,
///   subscription dates, the first 10 characters of `transactions.date`) are
///   the user's **local** calendar date. The app writes local wall-clock time
///   without an offset (`2026-11-17T00:30:00`); Postgres stores it as
///   `…00:30+00`, so `prefix(10)` of a stored `date` IS the local date.
///   Use `isoDate` / `localDateTime` — or, when a day string must be turned
///   into a `Date` that other code formats in UTC, `utcDate`.
/// - **Instants** (`created_at`, `updated_at`, `closed_at`, `*_updated_at`) are
///   real moments: write with `utcTimestamp`, read with `parseTimestamp(_:)`.
///
/// # Rules
/// - Parsing/writing formatters are `en_US_POSIX` + `.gregorian` + an explicit
///   time zone. Build a one-off with `posix(_:timeZone:)`.
/// - The `display…` formatters follow the user's locale on purpose (display ≠
///   parsing). A view that needs another display format may build its own
///   with `// date-formatter-ok: <reason>` on the line — never for a string
///   that is stored or parsed.
/// - `Scripts/lint-date-formatters.sh` fails CI on any other `DateFormatter()`.
enum AppDateFormatters {

    // MARK: - Building blocks

    static let posixLocale = Locale(identifier: "en_US_POSIX")
    static let utcTimeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!

    /// Gregorian calendar in `timeZone` (default: the device's, tracking
    /// changes). Use it for day arithmetic on stored dates: `Calendar.current`
    /// may be Buddhist or Japanese.
    static func gregorian(timeZone: TimeZone = .autoupdatingCurrent) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = posixLocale
        cal.timeZone = timeZone
        return cal
    }

    /// The device-time-zone gregorian calendar.
    static var localCalendar: Calendar { gregorian() }

    /// Fixed-format formatter that ignores every user preference.
    static func posix(_ format: String, timeZone: TimeZone) -> DateFormatter {
        applyPOSIX(DateFormatter(), format: format, timeZone: timeZone)
    }

    /// Pins `formatter` to POSIX / gregorian / `timeZone`. Order matters:
    /// assigning `locale` resets `calendar` to the locale's own calendar, so
    /// the calendar is set after it.
    @discardableResult
    static func applyPOSIX(_ formatter: DateFormatter, format: String, timeZone: TimeZone) -> DateFormatter {
        formatter.locale = posixLocale
        formatter.calendar = gregorian(timeZone: timeZone)
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }

    // MARK: - Parsing / writing: local dates

    /// `yyyy-MM-dd` in the device's time zone — the user's calendar day.
    static let isoDate: DateFormatter = posix("yyyy-MM-dd", timeZone: .autoupdatingCurrent)

    /// Same as `isoDate`; the name says what it is.
    static var localDate: DateFormatter { isoDate }

    /// `yyyy-MM-dd'T'HH:mm:ss` local wall-clock time, no offset — the shape the
    /// app writes to `transactions.date`.
    static let localDateTime: DateFormatter = posix("yyyy-MM-dd'T'HH:mm:ss", timeZone: .autoupdatingCurrent)

    /// `yyyy-MM-dd` in `timeZone` — for tests and code that must render a
    /// moment as somebody else's calendar day.
    static func localDate(in timeZone: TimeZone) -> DateFormatter {
        posix("yyyy-MM-dd", timeZone: timeZone)
    }

    /// Start of the day `yyyy-MM-dd` (first 10 characters of `raw`) in
    /// `calendar`'s time zone — no formatter involved, so it is cheap inside
    /// loops over every transaction and immune to locale settings.
    static func day(_ raw: String?, calendar: Calendar = localCalendar) -> Date? {
        guard let raw, raw.count >= 10 else { return nil }
        let parts = raw.prefix(10).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        let cal = calendar.identifier == .gregorian ? calendar : gregorian(timeZone: calendar.timeZone)
        let comps = DateComponents(year: y, month: m, day: d)
        guard comps.isValidDate(in: cal), let date = cal.date(from: comps) else { return nil }
        return cal.startOfDay(for: date)
    }

    // MARK: - Parsing / writing: UTC

    /// `yyyy-MM-dd` at UTC midnight. Use when a day string has to become a
    /// `Date` that downstream code formats in UTC (e.g. `ISO8601DateFormatter`
    /// with `.withFullDate`).
    static let utcDate: DateFormatter = posix("yyyy-MM-dd", timeZone: utcTimeZone)

    /// `yyyy-MM-dd'T'HH:mm:ss` read as UTC.
    static let utcDateTime: DateFormatter = posix("yyyy-MM-dd'T'HH:mm:ss", timeZone: utcTimeZone)

    /// `yyyy-MM` in UTC — month keys of code that anchors its month window
    /// in UTC.
    static let utcMonth: DateFormatter = posix("yyyy-MM", timeZone: utcTimeZone)

    /// `yyyy-MM` in the device zone — the month of `transactions.date`'s
    /// local wall-clock prefix (`prefix(7)`).
    static let localMonth: DateFormatter = posix("yyyy-MM", timeZone: .autoupdatingCurrent)

    /// `yyyy-MM-dd'T'HH:mm:ssZZZZZ` in UTC (`2026-11-17T00:30:00Z`) — for
    /// timestamptz columns. Same string `ISO8601DateFormatter()` writes.
    static let utcTimestamp: DateFormatter = posix("yyyy-MM-dd'T'HH:mm:ssZZZZZ", timeZone: utcTimeZone)

    /// The current instant as a timestamptz string (`2026-11-17T00:30:00Z`).
    static func nowTimestamp(_ now: Date = Date()) -> String {
        utcTimestamp.string(from: now)
    }

    /// An `ISO8601DateFormatter` with an explicit UTC zone. ISO 8601 is
    /// always gregorian and ignores the locale; the zone is the only setting
    /// it would otherwise take from outside. Prefer `parseTimestamp(_:)` for
    /// reading — this exists for APIs that need the formatter object.
    static func iso8601(_ options: ISO8601DateFormatter.Options) -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.timeZone = utcTimeZone
        f.formatOptions = options
        return f
    }

    /// Parses a timestamptz as PostgREST returns it — `2026-11-17T00:30:00+00:00`,
    /// `…00.123456+00:00`, `…Z`, `2026-11-17 00:30:00+07`, or without any
    /// offset (read as UTC). Returns the instant.
    static func parseTimestamp(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard s.count >= 19 else { return nil }
        var head = Array(s.prefix(19))
        if head[10] == " " { head[10] = "T" }
        guard let base = utcDateTime.date(from: String(head)) else { return nil }

        var rest = Substring(s.dropFirst(19))
        var fraction: TimeInterval = 0
        if rest.first == "." {
            let digits = rest.dropFirst().prefix(while: \.isNumber)
            fraction = Double("0." + digits) ?? 0
            rest = rest.dropFirst(1 + digits.count)
        }
        rest = rest.drop(while: { $0 == " " })

        let offsetSeconds: Int
        if rest.isEmpty || rest == "Z" || rest == "z" {
            offsetSeconds = 0
        } else if let sign = rest.first, sign == "+" || sign == "-" {
            let digits = rest.dropFirst().filter(\.isNumber)
            guard digits.count == 2 || digits.count == 4,
                  rest.dropFirst().allSatisfy({ $0.isNumber || $0 == ":" }),
                  let hh = Int(digits.prefix(2)) else { return nil }
            let mm = digits.count == 4 ? (Int(digits.suffix(2)) ?? 0) : 0
            offsetSeconds = (sign == "-" ? -1 : 1) * (hh * 3600 + mm * 60)
        } else {
            return nil
        }
        return base.addingTimeInterval(fraction - TimeInterval(offsetSeconds))
    }

    // MARK: - Display (user locale, on purpose)

    /// Medium date style with device locale.
    static let displayDate: DateFormatter = display { $0.dateStyle = .medium }

    /// Medium date + short time with device locale («17 нояб. 2026 г., 13:05»).
    static let displayDateTime: DateFormatter = display {
        $0.dateStyle = .medium
        $0.timeStyle = .short
    }

    /// "d MMM yyyy" with device locale.
    static let shortDate: DateFormatter = display { $0.dateFormat = "d MMM yyyy" }

    /// "LLLL yyyy" — full month + year, device locale.
    static let monthYear: DateFormatter = display { $0.dateFormat = "LLLL yyyy" }

    /// "LLL yyyy" — short month + year, device locale.
    static let shortMonthYear: DateFormatter = display { $0.dateFormat = "LLL yyyy" }

    /// "LLL" — short month name.
    static let shortMonth: DateFormatter = display { $0.dateFormat = "LLL" }

    /// "HH:mm" with device locale.
    static let shortTime: DateFormatter = display { $0.dateFormat = "HH:mm" }

    /// "d MMM" localized from a template.
    static let dayMonth: DateFormatter = display { $0.setLocalizedDateFormatFromTemplate("d MMM") }

    /// "d MMM yyyy" localized from a template.
    static let dayMonthYear: DateFormatter = display { $0.setLocalizedDateFormatFromTemplate("d MMM yyyy") }

    /// A locale-following display formatter. Never use it for stored strings.
    static func display(_ configure: (DateFormatter) -> Void) -> DateFormatter {
        let df = DateFormatter()
        df.locale = .autoupdatingCurrent
        df.timeZone = .autoupdatingCurrent
        configure(df)
        return df
    }
}
