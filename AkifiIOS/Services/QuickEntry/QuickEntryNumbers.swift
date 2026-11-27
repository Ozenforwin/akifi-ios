import Foundation

/// Numbers as people type and dictate them — digits with any thousands /
/// decimal convention, «5к», «1.5k», and words in Russian, English and
/// Spanish («триста», «полторы тысячи», «two thousand five hundred»,
/// «dos mil quinientos»).
///
/// The contract is the parser's: a value comes out only when the text
/// states it. Ambiguous or malformed input gives `nil`, never a guess.
enum QuickEntryNumbers {

    // MARK: - Digits

    /// Value of a digit string with optional grouping / decimal separators:
    /// «150000», «1,234.56», «1.234,56», «1 234,56» (after grouping is
    /// joined), «12,5», «12.50», «1'000». Returns nil for anything else.
    ///
    /// One separator kind: repeated → thousands («1.234.567»); once and
    /// followed by exactly three digits with a non-zero integer part →
    /// thousands («12.500», «1,234»); otherwise decimal («12,5», «0.500»).
    /// Both kinds: the last one is the decimal separator.
    static func parseDigits(_ raw: String) -> Decimal? {
        let s = raw.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "")
        guard let first = s.first, first.isNumber, let last = s.last, last.isNumber else { return nil }
        guard s.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "." || $0 == ",") }) else { return nil }

        let dots = s.filter { $0 == "." }.count
        let commas = s.filter { $0 == "," }.count
        var integerPart = s
        var fractionPart = ""

        func split(at separator: Character, thousands: Character?) -> Bool {
            guard let idx = s.lastIndex(of: separator) else { return false }
            var intRaw = String(s[..<idx])
            let frac = String(s[s.index(after: idx)...])
            if let thousands {
                guard validGrouping(intRaw, separator: thousands) else { return false }
                intRaw.removeAll { $0 == thousands }
            }
            guard !intRaw.isEmpty, intRaw.allSatisfy(\.isNumber), !frac.isEmpty, frac.allSatisfy(\.isNumber) else { return false }
            integerPart = intRaw
            fractionPart = frac
            return true
        }

        switch (dots, commas) {
        case (0, 0):
            break
        case (_, 0), (0, _):
            let sep: Character = dots > 0 ? "." : ","
            let count = max(dots, commas)
            let groups = s.split(separator: sep, omittingEmptySubsequences: false).map(String.init)
            if count > 1 {
                guard validGrouping(s, separator: sep) else { return nil }
                integerPart = groups.joined()
            } else {
                let intRaw = groups[0], frac = groups[1]
                if frac.count == 3, intRaw != "0", intRaw.count <= 3 {
                    integerPart = intRaw + frac
                } else {
                    guard !intRaw.isEmpty, !frac.isEmpty else { return nil }
                    integerPart = intRaw
                    fractionPart = frac
                }
            }
        default:
            // Both present: the later one is the decimal separator.
            let lastDot = s.lastIndex(of: ".")!, lastComma = s.lastIndex(of: ",")!
            let decimal: Character = lastDot > lastComma ? "." : ","
            let thousands: Character = decimal == "." ? "," : "."
            if (decimal == "." ? dots : commas) != 1 { return nil }
            guard split(at: decimal, thousands: thousands) else { return nil }
        }
        let literal = fractionPart.isEmpty ? integerPart : "\(integerPart).\(fractionPart)"
        return Decimal(string: literal, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// «1.234.567» / «12,500»: first group 1–3 digits, every later group
    /// exactly 3.
    private static func validGrouping(_ s: String, separator: Character) -> Bool {
        let groups = s.split(separator: separator, omittingEmptySubsequences: false)
        guard let head = groups.first, (1...3).contains(head.count), head.allSatisfy(\.isNumber) else { return false }
        return groups.dropFirst().allSatisfy { $0.count == 3 && $0.allSatisfy(\.isNumber) }
    }

    // MARK: - Multipliers («5к», «2 тыс», «1.5 млн», «5 mil»)

    /// Folded word → factor.
    static let multipliers: [String: Decimal] = {
        var m: [String: Decimal] = [:]
        for w in ["к", "k", "тыс", "тысяча", "тысячи", "тысяч", "тыща", "тыщи", "тыщ", "thousand", "thousands", "mil"] {
            m[QuickEntryText.wordKey(w)] = 1_000
        }
        for w in ["млн", "миллион", "миллиона", "миллионов", "million", "millions", "millon", "millón", "millones", "mln", "m"] {
            m[QuickEntryText.wordKey(w)] = 1_000_000
        }
        return m
    }()

    /// Multipliers that may only be glued to the digits («5к», «1.5m») —
    /// standing alone they are ordinary letters.
    static let attachedOnlyMultipliers: Set<String> = ["к", "k", "m"]

    // MARK: - Words

    enum WordClass: Equatable, Sendable {
        /// 1–9
        case unit
        /// 10–19
        case teen
        /// 20–90
        case ten
        /// 100–900 as one word («триста», «doscientos», «cien»)
        case hundreds
        /// English «hundred» — multiplies what precedes it
        case hundredMultiplier
        /// 1 000, 1 000 000
        case scale
        /// «полтора» / «полторы» — 1.5, usually before a scale
        case oneAndHalf
        /// «полтысячи» — 500 as one word
        case halfThousand
        /// «and», «y» inside a number
        case connector
        /// English «a» / Spanish «un» before hundred / thousand
        case article
    }

    struct Word: Equatable, Sendable {
        let value: Decimal
        let cls: WordClass
    }

    /// Folded word → meaning. Russian, English, Spanish.
    static let words: [String: Word] = {
        var w: [String: Word] = [:]
        func add(_ keys: [String], _ value: Decimal, _ cls: WordClass) {
            for k in keys { w[QuickEntryText.wordKey(k)] = Word(value: value, cls: cls) }
        }
        // Russian
        add(["ноль", "нуль"], 0, .unit)
        add(["один", "одна", "одно", "одну"], 1, .unit)
        add(["два", "две"], 2, .unit)
        add(["три"], 3, .unit)
        add(["четыре"], 4, .unit)
        add(["пять"], 5, .unit)
        add(["шесть"], 6, .unit)
        add(["семь"], 7, .unit)
        add(["восемь"], 8, .unit)
        add(["девять"], 9, .unit)
        add(["десять"], 10, .teen)
        add(["одиннадцать"], 11, .teen)
        add(["двенадцать"], 12, .teen)
        add(["тринадцать"], 13, .teen)
        add(["четырнадцать"], 14, .teen)
        add(["пятнадцать"], 15, .teen)
        add(["шестнадцать"], 16, .teen)
        add(["семнадцать"], 17, .teen)
        add(["восемнадцать"], 18, .teen)
        add(["девятнадцать"], 19, .teen)
        add(["двадцать"], 20, .ten)
        add(["тридцать"], 30, .ten)
        add(["сорок"], 40, .ten)
        add(["пятьдесят"], 50, .ten)
        add(["шестьдесят"], 60, .ten)
        add(["семьдесят"], 70, .ten)
        add(["восемьдесят"], 80, .ten)
        add(["девяносто"], 90, .ten)
        add(["сто"], 100, .hundreds)
        add(["двести"], 200, .hundreds)
        add(["триста"], 300, .hundreds)
        add(["четыреста"], 400, .hundreds)
        add(["пятьсот"], 500, .hundreds)
        add(["шестьсот"], 600, .hundreds)
        add(["семьсот"], 700, .hundreds)
        add(["восемьсот"], 800, .hundreds)
        add(["девятьсот"], 900, .hundreds)
        add(["тысяча", "тысячи", "тысяч", "тысячу", "тыща", "тыщи", "тыщ", "тыс"], 1_000, .scale)
        add(["миллион", "миллиона", "миллионов", "млн"], 1_000_000, .scale)
        add(["полтора", "полторы"], 1.5, .oneAndHalf)
        add(["полтысячи", "полтыщи"], 500, .halfThousand)
        // English
        add(["zero"], 0, .unit)
        add(["one"], 1, .unit)
        add(["two"], 2, .unit)
        add(["three"], 3, .unit)
        add(["four"], 4, .unit)
        add(["five"], 5, .unit)
        add(["six"], 6, .unit)
        add(["seven"], 7, .unit)
        add(["eight"], 8, .unit)
        add(["nine"], 9, .unit)
        add(["ten"], 10, .teen)
        add(["eleven"], 11, .teen)
        add(["twelve"], 12, .teen)
        add(["thirteen"], 13, .teen)
        add(["fourteen"], 14, .teen)
        add(["fifteen"], 15, .teen)
        add(["sixteen"], 16, .teen)
        add(["seventeen"], 17, .teen)
        add(["eighteen"], 18, .teen)
        add(["nineteen"], 19, .teen)
        add(["twenty"], 20, .ten)
        add(["thirty"], 30, .ten)
        add(["forty"], 40, .ten)
        add(["fifty"], 50, .ten)
        add(["sixty"], 60, .ten)
        add(["seventy"], 70, .ten)
        add(["eighty"], 80, .ten)
        add(["ninety"], 90, .ten)
        add(["hundred"], 100, .hundredMultiplier)
        add(["thousand"], 1_000, .scale)
        add(["million"], 1_000_000, .scale)
        add(["and"], 0, .connector)
        add(["a"], 1, .article)
        // Spanish
        add(["cero"], 0, .unit)
        add(["uno"], 1, .unit)
        add(["un", "una"], 1, .article)
        add(["dos"], 2, .unit)
        add(["tres"], 3, .unit)
        add(["cuatro"], 4, .unit)
        add(["cinco"], 5, .unit)
        add(["seis"], 6, .unit)
        add(["siete"], 7, .unit)
        add(["ocho"], 8, .unit)
        add(["nueve"], 9, .unit)
        add(["diez"], 10, .teen)
        add(["once"], 11, .teen)
        add(["doce"], 12, .teen)
        add(["trece"], 13, .teen)
        add(["catorce"], 14, .teen)
        add(["quince"], 15, .teen)
        add(["dieciseis", "dieciséis"], 16, .teen)
        add(["diecisiete"], 17, .teen)
        add(["dieciocho"], 18, .teen)
        add(["diecinueve"], 19, .teen)
        add(["veinte"], 20, .ten)
        add(["veintiuno", "veintiun", "veintiún", "veintiuna"], 21, .teen)
        add(["veintidos", "veintidós"], 22, .teen)
        add(["veintitres", "veintitrés"], 23, .teen)
        add(["veinticuatro"], 24, .teen)
        add(["veinticinco"], 25, .teen)
        add(["veintiseis", "veintiséis"], 26, .teen)
        add(["veintisiete"], 27, .teen)
        add(["veintiocho"], 28, .teen)
        add(["veintinueve"], 29, .teen)
        add(["treinta"], 30, .ten)
        add(["cuarenta"], 40, .ten)
        add(["cincuenta"], 50, .ten)
        add(["sesenta"], 60, .ten)
        add(["setenta"], 70, .ten)
        add(["ochenta"], 80, .ten)
        add(["noventa"], 90, .ten)
        add(["cien", "ciento"], 100, .hundreds)
        add(["doscientos", "doscientas"], 200, .hundreds)
        add(["trescientos", "trescientas"], 300, .hundreds)
        add(["cuatrocientos", "cuatrocientas"], 400, .hundreds)
        add(["quinientos", "quinientas"], 500, .hundreds)
        add(["seiscientos", "seiscientas"], 600, .hundreds)
        add(["setecientos", "setecientas"], 700, .hundreds)
        add(["ochocientos", "ochocientas"], 800, .hundreds)
        add(["novecientos", "novecientas"], 900, .hundreds)
        add(["mil"], 1_000, .scale)
        add(["millon", "millón", "millones"], 1_000_000, .scale)
        add(["y"], 0, .connector)
        return w
    }()

    /// One element of a spoken / typed number.
    enum Atom: Equatable, Sendable {
        /// A digit value, already multiplied by a glued suffix («5к» → 5000).
        case digits(Decimal, hasGluedMultiplier: Bool)
        case word(Word)
    }

    /// Result of reading a number from a run of atoms.
    struct Reading: Equatable, Sendable {
        let value: Decimal
        /// Atoms consumed from the start of the run.
        let length: Int
        /// True when at least one atom was a number word (not digits).
        let usedWords: Bool
    }

    /// Reads the longest well-formed number at the start of `atoms`.
    ///
    /// Grammar per group (< 1000): hundreds → tens → units / teens, in that
    /// order; a scale word closes the group and multiplies it; scales must
    /// decrease («две тысячи пятьсот» ✓, «тысяча миллион» ✗ — stops). A
    /// digit value may lead a group and take a scale («2 тысячи 500»).
    /// Connectors and articles only count inside a number («one hundred
    /// and five», «treinta y cinco», «a thousand»).
    static func read(_ atoms: [Atom]) -> Reading? {
        var total: Decimal = 0
        var group: Decimal = 0
        var groupHasValue = false
        var lastClass: WordClass?
        var lastWasDigits = false
        var previousScale: Decimal?
        var consumed = 0
        var committedLength = 0
        var committedValue: Decimal?
        var usedWords = false
        var committedUsedWords = false

        func commit() {
            committedLength = consumed
            committedValue = total + group
            committedUsedWords = usedWords
        }

        var i = 0
        loop: while i < atoms.count {
            let atom = atoms[i]
            switch atom {
            case .digits(let v, let glued):
                // Digits lead a group; nothing numeric may precede them
                // inside the same group.
                if groupHasValue { break loop }
                if let previousScale, v >= previousScale { break loop }
                group = v
                groupHasValue = true
                lastClass = nil
                lastWasDigits = true
                consumed = i + 1
                commit()
                if glued {
                    // «5к» is complete in itself.
                    break loop
                }
            case .word(let word):
                switch word.cls {
                case .connector:
                    // Only between two numeric words of one number.
                    guard groupHasValue || total > 0,
                          i + 1 < atoms.count,
                          case .word(let next) = atoms[i + 1],
                          [.unit, .teen, .ten, .hundreds].contains(next.cls) else { break loop }
                    i += 1
                    continue loop
                case .article:
                    // «a hundred», «a thousand», «un millón»; alone it is
                    // an article, not a number.
                    guard !groupHasValue,
                          i + 1 < atoms.count,
                          case .word(let next) = atoms[i + 1],
                          next.cls == .hundredMultiplier || next.cls == .scale else {
                        // Spanish «un» / «una» before a non-number word.
                        break loop
                    }
                    group = 1
                    groupHasValue = true
                    lastClass = .unit
                    lastWasDigits = false
                    usedWords = true
                case .unit:
                    if lastWasDigits || [.unit, .teen].contains(lastClass) { break loop }
                    group += word.value
                    groupHasValue = true
                    lastClass = .unit
                    usedWords = true
                case .teen:
                    if lastWasDigits || [.unit, .teen, .ten].contains(lastClass) { break loop }
                    group += word.value
                    groupHasValue = true
                    lastClass = .teen
                    usedWords = true
                case .ten:
                    if lastWasDigits || [.unit, .teen, .ten].contains(lastClass) { break loop }
                    group += word.value
                    groupHasValue = true
                    lastClass = .ten
                    usedWords = true
                case .hundreds:
                    if lastWasDigits || lastClass != nil { break loop }
                    group += word.value
                    groupHasValue = true
                    lastClass = .hundreds
                    usedWords = true
                case .hundredMultiplier:
                    guard groupHasValue, !lastWasDigits || group < 10, group < 10 else { break loop }
                    group = max(group, 1) * 100
                    lastClass = .hundreds
                    lastWasDigits = false
                    usedWords = true
                case .oneAndHalf:
                    if groupHasValue { break loop }
                    group = 1.5
                    groupHasValue = true
                    lastClass = .unit
                    usedWords = true
                case .halfThousand:
                    if groupHasValue || previousScale != nil { break loop }
                    group = 500
                    groupHasValue = true
                    lastClass = .hundreds
                    usedWords = true
                case .scale:
                    if let previousScale, word.value >= previousScale { break loop }
                    let multiplier = groupHasValue ? group : 1
                    total += multiplier * word.value
                    group = 0
                    groupHasValue = false
                    lastClass = nil
                    lastWasDigits = false
                    previousScale = word.value
                    usedWords = true
                }
                // An article only counts once the scale after it lands.
                if word.cls != .article {
                    consumed = i + 1
                    commit()
                }
            }
            i += 1
        }
        guard let value = committedValue, committedLength > 0 else { return nil }
        return Reading(value: value, length: committedLength, usedWords: committedUsedWords)
    }
}
