import Foundation

// MARK: - Result

/// What a free-text phrase says about a transaction. Produced by
/// `QuickEntryParser.parse`; `QuickEntryEngine` turns it into a draft with
/// defaults and predictions.
///
/// Only what the text states is filled in — a missing amount stays `nil`,
/// the parser never invents a number.
struct QuickEntryParse: Equatable, Sendable {

    struct AccountHint: Equatable, Sendable {
        let accountId: String
        /// 0…1 — how closely the words matched the account name.
        let confidence: Double
        /// The words of the phrase that named the account.
        let matchedText: String
    }

    struct CategoryHint: Equatable, Sendable {
        let categoryId: String
        let type: CategoryType
        /// 0…1 — how closely a word matched the category name.
        let confidence: Double
        let matchedText: String
    }

    /// The phrase as given.
    var text: String = ""
    /// Positive amount in main units of `currencyCode` (or of the account
    /// currency when `currencyCode` is nil). Never rounded here.
    var amount: Decimal?
    /// The words / digits the amount was read from («1 234,56», «триста»).
    var amountText: String?
    /// ISO code the phrase named explicitly («12$», «€20», «20 евро»).
    var currencyCode: String?
    /// `+5000` → income, `-300` → expense.
    var signType: TransactionType?
    /// «добавь расход …», «доход 5000 …».
    var commandType: TransactionType?
    /// «зарплата», «кэшбэк», «потратил», «salary», «gasté» …
    var keywordType: TransactionType?
    /// Explicit date («вчера», «в пятницу», «12 ноября», «12.11»), with the
    /// time of day of `now`.
    var date: Date?
    var dateText: String?
    var account: AccountHint?
    /// Categories whose NAME appears in the phrase, best first (both types).
    var categoryHints: [CategoryHint] = []
    /// What remains once amount, currency, date, account and filler words
    /// are taken out — the transaction description.
    var description: String = ""
}

/// Accounts and categories the parser may recognise by name.
struct QuickEntryVocabulary: Sendable {
    struct AccountName: Sendable, Equatable {
        let id: String
        let name: String
        let accountType: AccountType
    }
    struct CategoryName: Sendable, Equatable {
        let id: String
        let name: String
        let type: CategoryType
    }

    var accounts: [AccountName] = []
    var categories: [CategoryName] = []

    static let empty = QuickEntryVocabulary()

    init(accounts: [AccountName] = [], categories: [CategoryName] = []) {
        self.accounts = accounts
        self.categories = categories
    }

    init(accounts: [Account], categories: [Category]) {
        self.accounts = accounts.map { AccountName(id: $0.id, name: $0.name, accountType: $0.accountType) }
        self.categories = categories.map { CategoryName(id: $0.id, name: $0.name, type: $0.type) }
    }
}

// MARK: - Parser

/// Pure phrase parser: «кофе 300», «такси 500 вчера», «+5000 подарок»,
/// «продукты 1 234,56 с карты Тинькофф», «€20 netflix», «две тысячи
/// пятьсот продукты». Russian, English and Spanish.
enum QuickEntryParser {

    static func parse(
        _ text: String,
        vocabulary: QuickEntryVocabulary = .empty,
        now: Date = Date(),
        calendar: Calendar = AppDateFormatters.localCalendar
    ) -> QuickEntryParse {
        var state = State(text: text)
        var result = QuickEntryParse(text: text)

        state.detectDate(into: &result, now: now, calendar: calendar)
        state.detectAccount(into: &result, vocabulary: vocabulary)
        state.detectAppName()
        state.detectAmount(into: &result)
        state.detectLeadingCommands(into: &result)
        state.detectKeywords(into: &result)
        result.description = state.description()
        result.categoryHints = state.categoryHints(vocabulary: vocabulary)
        return result
    }

    // MARK: - Tokens

    struct Token {
        /// Core text (edge punctuation stripped) as typed.
        let raw: String
        /// Folded key for lexicon lookups.
        let key: String
        var consumed = false

        var isWord: Bool { raw.contains(where: \.isLetter) }
    }

    /// A number read from the tokens.
    struct NumberSpan {
        let start: Int
        /// Exclusive.
        var end: Int
        var value: Decimal
        var currency: String?
        var currencyTokens: [Int] = []
        var sign: TransactionType?
        var signToken: Int?
        let usedWords: Bool
    }

    /// One digit token taken apart: «+5000», «$12», «12$», «5к», «1.5k»,
    /// «300руб», «USD100», «5к₽».
    struct NumericToken: Equatable {
        var sign: TransactionType?
        var prefixCurrency: String?
        var digits: String
        var multiplier: Decimal?
        var suffixCurrency: String?

        var isPlain: Bool { sign == nil && prefixCurrency == nil && multiplier == nil && suffixCurrency == nil }
        var currency: String? { prefixCurrency ?? suffixCurrency }
    }

    static func isCurrencySymbol(_ c: Character) -> Bool {
        c.unicodeScalars.first?.properties.generalCategory == .currencySymbol
    }

    static func analyzeNumeric(_ raw: String) -> NumericToken? {
        var rest = Substring(raw)
        var token = NumericToken(digits: "")
        if let first = rest.first, "+-−–".contains(first) {
            token.sign = first == "+" ? .income : .expense
            rest = rest.dropFirst()
        }
        if let first = rest.first, isCurrencySymbol(first) {
            token.prefixCurrency = QuickEntryLexicon.currencySymbols[String(first)]
            guard token.prefixCurrency != nil else { return nil }
            rest = rest.dropFirst()
        } else if rest.count > 3,
                  rest.prefix(3).allSatisfy({ $0.isASCII && $0.isLetter }),
                  rest.dropFirst(3).first?.isNumber == true {
            guard let code = QuickEntryLexicon.currency(forToken: String(rest.prefix(3))) else { return nil }
            token.prefixCurrency = code
            rest = rest.dropFirst(3)
        }
        guard let first = rest.first, first.isASCII, first.isNumber else { return nil }
        let digits = rest.prefix { ($0.isASCII && $0.isNumber) || ".,'’".contains($0) }
        var digitString = String(digits)
        while let last = digitString.last, !last.isNumber { digitString.removeLast() }
        token.digits = digitString
        var suffix = String(rest.dropFirst(digitString.count))
        // «300,-» / «300.-»: a dash after the separator means "no kopecks".
        if suffix.hasPrefix(",-") || suffix.hasPrefix(".-") { suffix.removeFirst(2) }
        if suffix.isEmpty { return token }
        if let code = QuickEntryLexicon.currency(forToken: suffix) {
            token.suffixCurrency = code
            return token
        }
        // Folded but not filtered: «к₽» must not read as a bare «к».
        let suffixKey = QuickEntryText.fold(suffix)
        if let factor = QuickEntryNumbers.multipliers[suffixKey] {
            token.multiplier = factor
            return token
        }
        // Multiplier + currency glued together: «5к₽», «2kusd».
        for (word, factor) in QuickEntryNumbers.multipliers.sorted(by: { $0.key.count > $1.key.count })
        where suffixKey.hasPrefix(word) && suffixKey.count > word.count {
            let remainder = String(suffix.dropFirst(word.count))
            if let code = QuickEntryLexicon.currency(forToken: remainder) {
                token.multiplier = factor
                token.suffixCurrency = code
                return token
            }
        }
        return nil
    }

    /// «12.11», «12.11.2026», «12/11», «12/11/26» → (day, month, year?).
    /// The dot form needs a two-digit month («1.5» is a number).
    static func dateLike(_ raw: String) -> (day: Int, month: Int, year: Int?)? {
        let separator: Character
        if raw.contains(".") { separator = "." } else if raw.contains("/") { separator = "/" } else { return nil }
        let parts = raw.split(separator: separator, omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              (1...2).contains(parts[0].count), (1...2).contains(parts[1].count),
              let day = Int(parts[0]), let month = Int(parts[1]),
              (1...31).contains(day), (1...12).contains(month) else { return nil }
        if separator == ".", parts[1].count != 2 { return nil }
        var year: Int?
        if parts.count == 3 {
            guard parts[2].count == 2 || parts[2].count == 4, let y = Int(parts[2]) else { return nil }
            year = parts[2].count == 2 ? 2000 + y : y
        }
        return (day, month, year)
    }

    // MARK: - State

    struct State {
        var tokens: [Token]

        init(text: String) {
            var tokens: [Token] = []
            var current = ""
            func flush() {
                guard !current.isEmpty else { return }
                var core = Substring(current)
                // Strip edge punctuation, keeping a leading sign and
                // currency symbols.
                while let first = core.first, QuickEntryText.edgePunctuation.contains(first) { core = core.dropFirst() }
                while let last = core.last, QuickEntryText.edgePunctuation.contains(last) { core = core.dropLast() }
                if !core.isEmpty {
                    tokens.append(Token(raw: String(core), key: QuickEntryText.wordKey(String(core))))
                }
                current = ""
            }
            for ch in text {
                if QuickEntryText.spaceLike.contains(ch) { flush() } else { current.append(ch) }
            }
            flush()
            self.tokens = tokens
        }

        private func isFree(_ i: Int) -> Bool {
            i >= 0 && i < tokens.count && !tokens[i].consumed
        }

        private mutating func consume(_ indices: [Int]) {
            for i in indices where i >= 0 && i < tokens.count { tokens[i].consumed = true }
        }

        private mutating func consume(_ range: Range<Int>) {
            consume(Array(range))
        }

        private func key(_ i: Int) -> String? {
            i >= 0 && i < tokens.count ? tokens[i].key : nil
        }

        // MARK: Dates

        /// Plain positive integer token («12», not «12$» or «+12»).
        private func plainInt(_ i: Int) -> Int? {
            guard isFree(i), let n = QuickEntryParser.analyzeNumeric(tokens[i].raw), n.isPlain,
                  n.digits.allSatisfy(\.isNumber) else { return nil }
            return Int(n.digits)
        }

        /// Day number, also with an ordinal suffix («12th», «1st»).
        private func dayNumber(_ i: Int) -> Int? {
            if let n = plainInt(i), (1...31).contains(n) { return n }
            guard isFree(i) else { return nil }
            let raw = tokens[i].key
            for suffix in ["st", "nd", "rd", "th", "го", "е"] where raw.hasSuffix(suffix) {
                let digits = raw.dropLast(suffix.count).filter { $0 != "-" }
                if let n = Int(digits), (1...31).contains(n) { return n }
            }
            return nil
        }

        /// Count of number-looking tokens other than `except`.
        private func numberTokenCount(except: Int) -> Int {
            tokens.indices.filter { i in
                guard i != except, isFree(i) else { return false }
                if QuickEntryParser.analyzeNumeric(tokens[i].raw) != nil { return true }
                if let w = QuickEntryNumbers.words[tokens[i].key] {
                    return w.cls != .connector && w.cls != .article
                }
                return false
            }.count
        }

        mutating func detectDate(into result: inout QuickEntryParse, now: Date, calendar: Calendar) {
            let time = calendar.dateComponents([.hour, .minute, .second], from: now)

            func shifted(days: Int) -> Date? {
                calendar.date(byAdding: .day, value: -days, to: now)
            }
            func make(day: Int, month: Int, year: Int?) -> Date? {
                let nowYear = calendar.component(.year, from: now)
                var comps = DateComponents(year: year ?? nowYear, month: month, day: day,
                                           hour: time.hour, minute: time.minute, second: time.second)
                guard comps.isValidDate(in: calendar), var date = calendar.date(from: comps) else { return nil }
                // A bare «12 декабря» in November means last December.
                if year == nil, calendar.startOfDay(for: date) > calendar.startOfDay(for: now) {
                    comps.year = nowYear - 1
                    guard comps.isValidDate(in: calendar), let previous = calendar.date(from: comps) else { return nil }
                    date = previous
                }
                return date
            }
            func finish(_ date: Date, _ indices: [Int]) {
                result.date = date
                result.dateText = indices.sorted().map { tokens[$0].raw }.joined(separator: " ")
                consume(indices)
            }

            for i in tokens.indices where isFree(i) {
                let k = tokens[i].key

                // сегодня / вчера / позавчера
                if let back = QuickEntryLexicon.relativeDays[k], let date = shifted(days: back) {
                    finish(date, [i]); return
                }

                // «3 дня назад», «2 days ago»
                if let n = plainInt(i) ?? wordInt(i), n <= 366,
                   let unit = key(i + 1), QuickEntryLexicon.dayUnits.contains(unit),
                   let ago = key(i + 2), QuickEntryLexicon.agoWords.contains(ago),
                   let date = shifted(days: n) {
                    finish(date, [i, i + 1, i + 2]); return
                }
                // «hace 2 días»
                if QuickEntryLexicon.haceWords.contains(k), let n = plainInt(i + 1) ?? wordInt(i + 1), n <= 366,
                   let unit = key(i + 2), QuickEntryLexicon.dayUnits.contains(unit),
                   let date = shifted(days: n) {
                    finish(date, [i, i + 1, i + 2]); return
                }

                // Weekdays
                if let weekday = QuickEntryLexicon.weekdays[k] {
                    var indices = [i]
                    var isLast = false
                    var j = i - 1
                    if let prev = key(j), isFree(j), QuickEntryLexicon.lastWords.contains(prev) {
                        isLast = true; indices.append(j); j -= 1
                    }
                    var hasPreposition = false
                    if let prev = key(j), isFree(j), QuickEntryLexicon.weekdayPrepositions.contains(prev) {
                        hasPreposition = true; indices.append(j); j -= 1
                    }
                    if !isLast, let prev = key(j), isFree(j), QuickEntryLexicon.lastWords.contains(prev) {
                        // «el pasado viernes»
                        isLast = true; indices.append(j)
                    }
                    if let next = key(i + 1), isFree(i + 1), QuickEntryLexicon.lastWords.contains(next) {
                        // «el viernes pasado»
                        isLast = true; indices.append(i + 1)
                    }
                    if weekday.standalone || hasPreposition || isLast {
                        let today = calendar.component(.weekday, from: now)
                        var back = (today - weekday.weekday + 7) % 7
                        if isLast, back == 0 { back = 7 }
                        if let date = shifted(days: back) { finish(date, indices); return }
                    }
                }

                // «12 ноября», «12 de noviembre», «12 ноября 2025 г.»
                if let day = dayNumber(i) {
                    var monthIndex = i + 1
                    if let connector = key(monthIndex), QuickEntryLexicon.monthConnectors.contains(connector) { monthIndex += 1 }
                    if isFree(monthIndex), let m = key(monthIndex), let month = QuickEntryLexicon.months[m] {
                        var indices = Array(i...monthIndex)
                        var year: Int?
                        if let y = plainInt(monthIndex + 1), (2000...2100).contains(y) {
                            year = y
                            indices.append(monthIndex + 1)
                            if let g = key(monthIndex + 2), ["г", "года", "год"].contains(g) { indices.append(monthIndex + 2) }
                        }
                        if let date = make(day: day, month: month, year: year) { finish(date, indices); return }
                    }
                }
                // «Nov 12», «November 12th»
                if let month = QuickEntryLexicon.months[k], let day = dayNumber(i + 1),
                   let date = make(day: day, month: month, year: nil) {
                    finish(date, [i, i + 1]); return
                }

                // «12.11», «12.11.2026», «12/11» — a bare «12.11» is a date
                // only when another number can be the amount.
                if let parts = QuickEntryParser.dateLike(tokens[i].raw) {
                    let hasYear = parts.year != nil
                    let slash = tokens[i].raw.contains("/")
                    if hasYear || slash || numberTokenCount(except: i) > 0,
                       let date = make(day: parts.day, month: parts.month, year: parts.year) {
                        finish(date, [i]); return
                    }
                }
            }
        }

        /// A single number word («три», «two») as an Int.
        private func wordInt(_ i: Int) -> Int? {
            guard isFree(i), let w = QuickEntryNumbers.words[tokens[i].key],
                  [.unit, .teen, .ten].contains(w.cls) else { return nil }
            return NSDecimalNumber(decimal: w.value).intValue
        }

        // MARK: Accounts

        mutating func detectAccount(into result: inout QuickEntryParse, vocabulary: QuickEntryVocabulary) {
            struct Candidate {
                let id: String
                let keys: [String]
                let rawKeys: [String]
            }
            let candidates: [Candidate] = vocabulary.accounts.compactMap { account in
                let words = QuickEntryText.words(account.name)
                let significant = words.filter {
                    !QuickEntryLexicon.accountNouns.contains($0) && !QuickEntryText.stopWords.contains($0)
                }
                let chosen = significant.isEmpty ? words : significant
                let keys = chosen.map { QuickEntryText.transliterate(QuickEntryText.stem($0)) }
                guard !keys.isEmpty else { return nil }
                return Candidate(id: account.id, keys: keys, rawKeys: chosen)
            }

            struct Match {
                let id: String
                let score: Double
                let range: Range<Int>
                let context: [Int]
            }
            var best: Match?
            var tie = false

            for i in tokens.indices where isFree(i) && tokens[i].isWord {
                for candidate in candidates {
                    // Align name keys with consecutive phrase tokens from i.
                    var scores: [Double] = []
                    var j = i
                    for nameKey in candidate.keys {
                        guard isFree(j) else { break }
                        let s = QuickEntryText.similarity(QuickEntryText.matchKey(tokens[j].raw), nameKey)
                        guard s >= 0.75 else { break }
                        scores.append(s)
                        j += 1
                    }
                    guard let firstScore = scores.first else { continue }
                    var score = scores.reduce(0, +) / Double(candidate.keys.count)
                    if scores.count < candidate.keys.count {
                        // Part of a multi-word name: only a distinctive word.
                        guard candidate.keys[0].count >= 4 else { continue }
                        score = firstScore * 0.85
                    }
                    if candidate.keys.allSatisfy({ $0.count < 3 }) && score < 1 { continue }

                    // «с карты X», «from X», «картой X».
                    var context: [Int] = []
                    var k = i - 1
                    if let prev = key(k), isFree(k), QuickEntryLexicon.accountNouns.contains(prev) {
                        context.append(k); k -= 1
                    }
                    if let prev = key(k), isFree(k), QuickEntryLexicon.accountPrepositions.contains(prev) {
                        context.append(k)
                    }
                    let range = i..<j
                    let otherWords = tokens.indices.filter { t in
                        !range.contains(t) && !context.contains(t) && isFree(t) && tokens[t].isWord
                            && !QuickEntryText.stopWords.contains(tokens[t].key)
                            && !QuickEntryLexicon.accountNouns.contains(tokens[t].key)
                    }.count
                    let accepted = (!context.isEmpty && score >= 0.75) || (score >= 0.9 && otherWords >= 1)
                    guard accepted else { continue }
                    let ranked = score + (context.isEmpty ? 0 : 0.05)
                    if let current = best {
                        let currentRanked = current.score + (current.context.isEmpty ? 0 : 0.05)
                        if abs(ranked - currentRanked) < 0.0001, current.id != candidate.id {
                            tie = true
                        } else if ranked > currentRanked {
                            best = Match(id: candidate.id, score: score, range: range, context: context)
                            tie = false
                        }
                    } else {
                        best = Match(id: candidate.id, score: score, range: range, context: context)
                    }
                }
            }

            if let match = best, !tie {
                var indices = Array(match.range) + match.context
                // A number that is part of the name («Visa 1234»).
                if let candidate = candidates.first(where: { $0.id == match.id }) {
                    var next = match.range.upperBound
                    while isFree(next), candidate.rawKeys.contains(tokens[next].key) {
                        indices.append(next); next += 1
                    }
                }
                result.account = QuickEntryParse.AccountHint(
                    accountId: match.id,
                    confidence: min(1, match.score),
                    matchedText: match.range.map { tokens[$0].raw }.joined(separator: " ")
                )
                consume(indices)
                return
            }

            // «наличными», «cash», «en efectivo» → the only cash account.
            let cashAccounts = vocabulary.accounts.filter { $0.accountType == .cash }
            guard cashAccounts.count == 1 else { return }
            for i in tokens.indices where isFree(i) && QuickEntryLexicon.cashWords.contains(tokens[i].key) {
                var indices = [i]
                if let prev = key(i - 1), isFree(i - 1), ["in", "en", "за"].contains(prev) { indices.append(i - 1) }
                result.account = QuickEntryParse.AccountHint(
                    accountId: cashAccounts[0].id, confidence: 0.8, matchedText: tokens[i].raw
                )
                consume(indices)
                return
            }
        }

        /// «в Акифи», «in Akifi» — the app's own name in a dictated phrase.
        mutating func detectAppName() {
            for i in tokens.indices where isFree(i) && ["акифи", "akifi"].contains(tokens[i].key) {
                var indices = [i]
                if let prev = key(i - 1), isFree(i - 1), ["в", "in", "en"].contains(prev) { indices.append(i - 1) }
                consume(indices)
            }
        }

        // MARK: Amount

        mutating func detectAmount(into result: inout QuickEntryParse) {
            var spans: [NumberSpan] = []
            var i = 0
            while i < tokens.count {
                guard isFree(i) else { i += 1; continue }
                if let span = readNumber(at: i) {
                    spans.append(span)
                    i = span.end
                } else {
                    i += 1
                }
            }

            let candidates = spans.filter { span in
                guard span.value > 0 else { return false }
                // «один кофе», «un café», «a coffee» — not a price.
                if span.usedWords, span.value == 1, span.currency == nil { return false }
                return true
            }
            guard let chosen = candidates.max(by: { a, b in
                func rank(_ s: NumberSpan) -> (Int, Int, Decimal, Int) {
                    (s.currency != nil ? 1 : 0, s.sign != nil ? 1 : 0, s.value, s.start)
                }
                return rank(a) < rank(b)
            }) else { return }

            var span = chosen
            // «сто двадцать рублей пятьдесят копеек»
            if let minor = readMinorUnits(after: span) {
                span.value += minor.value
                span.end = minor.end
            }
            result.amount = span.value
            result.amountText = (span.start..<span.end).map { tokens[$0].raw }.joined(separator: " ")
            result.currencyCode = span.currency
            result.signType = span.sign
            consume(span.start..<span.end)
            consume(span.currencyTokens)
            if let s = span.signToken { consume([s]) }
        }

        /// The number starting at token `i`, with its currency and sign.
        private func readNumber(at start: Int) -> NumberSpan? {
            var atoms: [QuickEntryNumbers.Atom] = []
            /// Token range of each atom (joined digit groups span several).
            var atomEnds: [Int] = []
            var firstNumeric: NumericToken?
            var j = start
            while j < tokens.count, isFree(j) {
                if let numeric = QuickEntryParser.analyzeNumeric(tokens[j].raw) {
                    if !atoms.isEmpty, numeric.sign != nil || numeric.prefixCurrency != nil { break }
                    var merged = numeric
                    var end = j + 1
                    // «150 000», «1 234,56», «1 000₽»
                    if merged.suffixCurrency == nil, merged.multiplier == nil,
                       (1...3).contains(merged.digits.count), merged.digits.allSatisfy(\.isNumber) {
                        while end < tokens.count, isFree(end),
                              let group = QuickEntryParser.analyzeNumeric(tokens[end].raw),
                              group.sign == nil, group.prefixCurrency == nil,
                              isThousandsGroup(group.digits) {
                            merged.digits += group.digits
                            merged.multiplier = group.multiplier
                            merged.suffixCurrency = group.suffixCurrency
                            end += 1
                            if group.digits.count > 3 || group.multiplier != nil || group.suffixCurrency != nil { break }
                        }
                    }
                    guard let base = QuickEntryNumbers.parseDigits(merged.digits) else { break }
                    let value = base * (merged.multiplier ?? 1)
                    let glued = merged.multiplier != nil || merged.suffixCurrency != nil
                    if atoms.isEmpty { firstNumeric = merged }
                    atoms.append(.digits(value, hasGluedMultiplier: glued))
                    atomEnds.append(end)
                    j = end
                    if glued { break }
                    continue
                }
                if let word = QuickEntryNumbers.words[tokens[j].key] {
                    atoms.append(.word(word))
                    atomEnds.append(j + 1)
                    j += 1
                    continue
                }
                // «twenty-five», «treinta-y-cinco»
                let parts = tokens[j].key.split(separator: "-").map(String.init)
                if parts.count > 1, parts.allSatisfy({ QuickEntryNumbers.words[$0] != nil }) {
                    for part in parts { atoms.append(.word(QuickEntryNumbers.words[part]!)); atomEnds.append(j + 1) }
                    j += 1
                    continue
                }
                break
            }
            guard let reading = QuickEntryNumbers.read(atoms) else { return nil }
            let end = atomEnds[reading.length - 1]
            var span = NumberSpan(start: start, end: end, value: reading.value, usedWords: reading.usedWords)

            if let first = firstNumeric, case .digits = atoms[0] {
                span.sign = first.sign
                if let currency = first.currency, reading.length == 1 || first.prefixCurrency != nil {
                    span.currency = currency
                }
            }
            // The last atom's glued currency («1 000₽»).
            if span.currency == nil, let last = QuickEntryParser.analyzeNumeric(tokens[end - 1].raw), let c = last.suffixCurrency {
                span.currency = c
            }
            // A separate currency word / symbol after the number, or a
            // symbol / ISO code before it.
            if span.currency == nil, isFree(end), let code = currencyWord(end) {
                span.currency = code
                span.currencyTokens = [end]
            } else if span.currency == nil, isFree(start - 1), let code = currencyPrefix(start - 1) {
                span.currency = code
                span.currencyTokens = [start - 1]
            }
            // A standalone «+» / «-» before the number.
            let signIndex = span.currencyTokens.first == start - 1 ? start - 2 : start - 1
            if span.sign == nil, isFree(signIndex), ["+", "-", "−", "–"].contains(tokens[signIndex].raw) {
                span.sign = tokens[signIndex].raw == "+" ? .income : .expense
                span.signToken = signIndex
            }
            return span
        }

        private func isThousandsGroup(_ digits: String) -> Bool {
            let chars = Array(digits)
            guard chars.count >= 3, chars[0..<3].allSatisfy(\.isNumber) else { return false }
            if chars.count == 3 { return true }
            // «234,56»
            guard chars.count >= 5, chars.count <= 6, chars[3] == "," || chars[3] == "." else { return false }
            return chars[4...].allSatisfy(\.isNumber)
        }

        private func currencyWord(_ i: Int) -> String? {
            QuickEntryLexicon.currency(forToken: tokens[i].raw)
        }

        /// Only symbols and ISO codes may stand before the number («$ 12»,
        /// «USD 100»); words go after it («12 долларов»).
        private func currencyPrefix(_ i: Int) -> String? {
            let raw = tokens[i].raw
            if raw.count == 1, let c = raw.first, QuickEntryParser.isCurrencySymbol(c) {
                return QuickEntryLexicon.currencySymbols[raw]
            }
            if raw.count == 3, raw.allSatisfy({ $0.isASCII && $0.isLetter }) {
                return QuickEntryLexicon.currency(forToken: raw)
            }
            return nil
        }

        private static let minorUnitWords: Set<String> = Set([
            "копейка", "копейки", "копеек", "коп", "цент", "цента", "центов", "cent", "cents",
            "centavo", "centavos", "centimo", "centimos", "céntimo", "céntimos"
        ].map(QuickEntryText.wordKey))

        /// «… рублей пятьдесят копеек» right after the chosen amount.
        private func readMinorUnits(after span: NumberSpan) -> (value: Decimal, end: Int)? {
            let start = (span.currencyTokens.max() ?? span.end - 1) + 1
            guard isFree(start), let number = readNumber(at: start), number.currency == nil,
                  number.value > 0, number.value < 100, number.end < tokens.count,
                  Self.minorUnitWords.contains(tokens[number.end].key) else { return nil }
            return (number.value / 100, number.end + 1)
        }

        // MARK: Filler and type words

        mutating func detectLeadingCommands(into result: inout QuickEntryParse) {
            func firstFree() -> Int? { tokens.indices.first(where: isFree) }
            while let i = firstFree(), QuickEntryLexicon.commandWords.contains(tokens[i].key) {
                consume([i])
            }
            if let i = firstFree(), let type = QuickEntryLexicon.typeCommandWords[tokens[i].key] {
                result.commandType = type
                consume([i])
            }
            if let i = firstFree(), QuickEntryLexicon.leadingVerbs.contains(tokens[i].key) {
                if QuickEntryLexicon.incomeKeywords.contains(tokens[i].key) {
                    result.keywordType = .income
                } else if QuickEntryLexicon.expenseKeywords.contains(tokens[i].key) {
                    result.keywordType = .expense
                }
                consume([i])
            }
        }

        mutating func detectKeywords(into result: inout QuickEntryParse) {
            guard result.keywordType == nil else { return }
            for token in tokens where !token.consumed {
                if QuickEntryLexicon.incomeKeywords.contains(token.key) { result.keywordType = .income; return }
                if QuickEntryLexicon.expenseKeywords.contains(token.key) { result.keywordType = .expense; return }
            }
        }

        // MARK: Description

        private var freeIndices: [Int] {
            tokens.indices.filter(isFree)
        }

        /// The free tokens, prepositions trimmed off both edges.
        private func descriptionIndices() -> [Int] {
            var indices = freeIndices
            while let first = indices.first, QuickEntryLexicon.danglingPrepositions.contains(tokens[first].key) {
                indices.removeFirst()
            }
            while let last = indices.last, QuickEntryLexicon.danglingPrepositions.contains(tokens[last].key) {
                indices.removeLast()
            }
            // A lone sign left behind («- кофе»).
            return indices.filter { !["+", "-", "−", "–"].contains(tokens[$0].raw) }
        }

        func description() -> String {
            descriptionIndices().map { tokens[$0].raw }.joined(separator: " ")
        }

        /// Categories named by a description word.
        func categoryHints(vocabulary: QuickEntryVocabulary) -> [QuickEntryParse.CategoryHint] {
            let words = descriptionIndices().filter { tokens[$0].isWord }
            guard !words.isEmpty else { return [] }
            let phraseKeys = words.map { (index: $0, key: QuickEntryText.matchKey(tokens[$0].raw)) }
            var hints: [QuickEntryParse.CategoryHint] = []
            for category in vocabulary.categories {
                let nameKeys = QuickEntryText.matchKeys(category.name)
                guard !nameKeys.isEmpty else { continue }
                var best = 0.0
                var bestIndex: Int?
                for nameKey in nameKeys where nameKey.count >= 3 {
                    for word in phraseKeys {
                        let s = QuickEntryText.similarity(word.key, nameKey)
                        if s > best { best = s; bestIndex = word.index }
                    }
                }
                // One word of a multi-word name («Кафе и рестораны»).
                if nameKeys.count > 1 { best *= 0.95 }
                if best >= 0.8, let bestIndex {
                    hints.append(QuickEntryParse.CategoryHint(
                        categoryId: category.id, type: category.type,
                        confidence: best, matchedText: tokens[bestIndex].raw
                    ))
                }
            }
            return hints.sorted { $0.confidence > $1.confidence }
        }
    }
}
