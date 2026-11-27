import Foundation

/// Text helpers shared by the quick-entry parser and the category predictor.
///
/// Everything here is pure and locale-independent: the same input gives the
/// same output on every device, whatever the region or language settings.
/// Matching works on *keys* — lowercased, diacritics folded (ё → е,
/// café → cafe), light-stemmed so Russian / Spanish / English inflections
/// meet («тинькоффа» ≈ «Тинькофф», «наличными» ≈ «Наличные»,
/// «зарплату» ≈ «Зарплата») and transliterated to Latin so a Cyrillic word
/// meets a Latin account name («сбер» ≈ «Sber»).
enum QuickEntryText {

    // MARK: - Normalization

    /// Lowercased, diacritics folded, `ё` → `е`. Keeps every other
    /// character (digits, punctuation, symbols) as is.
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: posix)
            .replacingOccurrences(of: "ё", with: "е")
            .lowercased()
    }

    private static let posix = Locale(identifier: "en_US_POSIX")

    /// Whitespace characters people (and dictation) put between digit
    /// groups or words: regular / no-break / narrow no-break / thin space.
    static let spaceLike: Set<Character> = [" ", "\u{00A0}", "\u{202F}", "\u{2009}", "\u{2007}", "\t", "\n", "\r"]

    /// Punctuation stripped from token edges (never from the middle — a
    /// decimal separator lives there).
    static let edgePunctuation: Set<Character> = [
        ",", ".", "!", "?", ":", ";", "(", ")", "[", "]", "{", "}", "\"", "'", "«", "»", "“", "”", "„", "…", "/"
    ]

    /// Folded letters only — the key of one word for lexicon lookups.
    static func wordKey(_ s: String) -> String {
        String(fold(s).filter { $0.isLetter || $0.isNumber || $0 == "-" })
    }

    // MARK: - Words

    /// Splits `s` into words (letters / digits runs), folded. Used for
    /// similarity — not for the parser, which keeps original ranges.
    static func words(_ s: String) -> [String] {
        fold(s)
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .map(String.init)
    }

    /// Words that carry no meaning for matching («и», «the», «de», …).
    static let stopWords: Set<String> = [
        "и", "в", "во", "на", "за", "с", "со", "по", "для", "от", "из", "к", "у", "а", "о", "об",
        "the", "a", "an", "and", "of", "for", "on", "in", "at", "to", "from", "with", "my",
        "el", "la", "los", "las", "de", "del", "y", "en", "con", "para", "por", "un", "una", "mi"
    ]

    // MARK: - Stemming

    /// Russian inflection endings, longest first, in FOLDED form (`fold`
    /// turns «й» into «и»). Stripping one of them leaves a stem that the
    /// prefix rule in `similarity` matches across cases («подарок» /
    /// «подарки», «карта» / «картой»).
    private static let russianEndings: [String] = [
        "иями", "ями", "ами", "ыми", "ими", "иеи", "иях", "ого", "его", "ому", "ему",
        "ях", "ах", "ов", "ев", "еи", "ои", "ии", "ыи", "ая", "яя", "ое", "ее", "ые", "ие",
        "ую", "юю", "ом", "ем", "ам", "ям", "ью",
        "а", "я", "о", "е", "ы", "и", "у", "ю", "ь"
    ]

    /// Light stem of one folded word. Never shorter than three letters.
    static func stem(_ word: String) -> String {
        guard word.count > 3 else { return word }
        if word.unicodeScalars.contains(where: { (0x0400...0x04FF).contains($0.value) }) {
            for ending in russianEndings where word.hasSuffix(ending) && word.count - ending.count >= 3 {
                return String(word.dropLast(ending.count))
            }
            return word
        }
        // Latin (en / es): plural endings only.
        if word.hasSuffix("es"), word.count - 2 >= 3 { return String(word.dropLast(2)) }
        if word.hasSuffix("s"), !word.hasSuffix("ss"), word.count - 1 >= 3 { return String(word.dropLast()) }
        return word
    }

    // MARK: - Transliteration

    private static let translitTable: [Character: String] = [
        "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ж": "zh", "з": "z",
        "и": "i", "й": "i", "к": "k", "л": "l", "м": "m", "н": "n", "о": "o", "п": "p",
        "р": "r", "с": "s", "т": "t", "у": "u", "ф": "f", "х": "h", "ц": "c", "ч": "ch",
        "ш": "sh", "щ": "sch", "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "yu", "я": "ya"
    ]

    /// Cyrillic → Latin skeleton («тинькофф» → «tinkoff»). Latin input is
    /// returned unchanged. Lossy on purpose: only for comparing.
    static func transliterate(_ word: String) -> String {
        var out = ""
        out.reserveCapacity(word.count)
        for ch in word {
            if let latin = translitTable[ch] { out += latin } else { out.append(ch) }
        }
        return out
    }

    /// The matching key of one word: folded, stemmed, transliterated.
    static func matchKey(_ word: String) -> String {
        transliterate(stem(fold(word)))
    }

    /// Matching keys of the meaningful words in `s`.
    static func matchKeys(_ s: String) -> [String] {
        words(s).filter { !stopWords.contains($0) }.map { transliterate(stem($0)) }
    }

    // MARK: - Similarity

    /// 0…1 similarity of two match keys.
    /// - equal → 1
    /// - one is a prefix of the other and the shorter has ≥ 4 letters → 0.9
    /// - common prefix ≥ 5 letters covering ≥ 70 % of the shorter → 0.8
    /// - edit distance close (≥ 0.8 normalized, both ≥ 5 letters) → 0.75
    /// - otherwise 0
    static func similarity(_ a: String, _ b: String) -> Double {
        if a.isEmpty || b.isEmpty { return 0 }
        if a == b { return 1 }
        let shorter = min(a.count, b.count)
        if shorter >= 4, a.hasPrefix(b) || b.hasPrefix(a) { return 0.9 }
        let common = commonPrefixLength(a, b)
        if common >= 5, Double(common) >= 0.7 * Double(shorter) { return 0.8 }
        if shorter >= 5 {
            let distance = levenshtein(a, b)
            let normalized = 1 - Double(distance) / Double(max(a.count, b.count))
            if normalized >= 0.8 { return 0.75 }
        }
        return 0
    }

    static func commonPrefixLength(_ a: String, _ b: String) -> Int {
        var n = 0
        for (x, y) in zip(a, b) {
            guard x == y else { break }
            n += 1
        }
        return n
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[y.count]
    }

    /// Fuzzy overlap of two key sets: matched pairs / union size. A key on
    /// one side matches at most one key on the other (best similarity
    /// ≥ 0.75).
    static func overlap(_ a: [String], _ b: [String]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var remaining = b
        var matched = 0.0
        for key in a {
            var best = 0.0
            var bestIndex: Int?
            for (i, other) in remaining.enumerated() {
                let s = similarity(key, other)
                if s > best { best = s; bestIndex = i }
            }
            if let bestIndex, best >= 0.75 {
                matched += best
                remaining.remove(at: bestIndex)
            }
        }
        let union = Double(a.count + b.count) - matched
        return union > 0 ? matched / union : 0
    }

    /// The identity of a description for "same text" checks: meaningful
    /// words, stemmed, in order. «Кофе!» and «кофе» share it, so do
    /// «Зарплата» and «зарплату».
    static func identityKey(_ s: String) -> String {
        matchKeys(s).joined(separator: " ")
    }
}
