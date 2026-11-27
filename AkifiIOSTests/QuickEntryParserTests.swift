import XCTest
@testable import AkifiIOS

/// Phrase parser: amounts (digits, separators, words), currencies, dates,
/// type signals, accounts, description. Table-driven; the clock is Friday
/// 2026-11-27 14:30 Moscow (`QE.now`).
final class QuickEntryParserTests: XCTestCase {

    private func d(_ s: String) -> Decimal { Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))! }

    private struct Case {
        let text: String
        var amount: String?
        var currency: String?
        var description: String?
        var day: String?
        var file: StaticString = #filePath
        var line: UInt = #line
    }

    private func check(_ cases: [Case], vocabulary: QuickEntryVocabulary = .empty) {
        for c in cases {
            let p = QE.parse(c.text, vocabulary: vocabulary)
            XCTAssertEqual(p.amount, c.amount.map(d), "amount of «\(c.text)»", file: c.file, line: c.line)
            XCTAssertEqual(p.currencyCode, c.currency, "currency of «\(c.text)»", file: c.file, line: c.line)
            if let description = c.description {
                XCTAssertEqual(p.description, description, "description of «\(c.text)»", file: c.file, line: c.line)
            }
            XCTAssertEqual(QE.day(p.date), c.day, "date of «\(c.text)»", file: c.file, line: c.line)
        }
    }

    // MARK: - The brief's examples

    func testBriefExamples() {
        check([
            Case(text: "кофе 300", amount: "300", description: "кофе"),
            Case(text: "300 кофе", amount: "300", description: "кофе"),
            Case(text: "такси 500 вчера", amount: "500", description: "такси", day: "2026-11-26"),
            Case(text: "зарплата 150 000", amount: "150000", description: "зарплата"),
            Case(text: "+5000 подарок", amount: "5000", description: "подарок"),
            Case(text: "обед 12$", amount: "12", currency: "USD", description: "обед"),
            Case(text: "€20 netflix", amount: "20", currency: "EUR", description: "netflix"),
            Case(text: "вернул 2000 Сергею", amount: "2000", description: "вернул Сергею"),
        ])
        let p = QE.parse("продукты 1 234,56 с карты Тинькофф", vocabulary: QE.vocabulary)
        XCTAssertEqual(p.amount, d("1234.56"))
        XCTAssertEqual(p.account?.accountId, "acc-card")
        XCTAssertEqual(p.description, "продукты")
        XCTAssertNil(p.currencyCode)
    }

    func testTypeSignals() {
        XCTAssertEqual(QE.parse("+5000 подарок").signType, .income)
        XCTAssertEqual(QE.parse("-300 штраф").signType, .expense)
        XCTAssertEqual(QE.parse("+ 5000 подарок").signType, .income)
        XCTAssertNil(QE.parse("кофе 300").signType)
        XCTAssertEqual(QE.parse("зарплата 150 000").keywordType, .income)
        XCTAssertEqual(QE.parse("зп 80000").keywordType, .income)
        XCTAssertEqual(QE.parse("кэшбэк 150").keywordType, .income)
        XCTAssertEqual(QE.parse("refund 20 amazon").keywordType, .income)
        XCTAssertEqual(QE.parse("sueldo 1000").keywordType, .income)
        XCTAssertEqual(QE.parse("мне вернули 2000").keywordType, .income)
        // «вернул» = I paid back: no income signal, stays text (no debt yet).
        XCTAssertNil(QE.parse("вернул 2000 Сергею").keywordType)
        XCTAssertNil(QE.parse("вернул 2000 Сергею").signType)

        let command = QE.parse("добавь расход кофе 300")
        XCTAssertEqual(command.commandType, .expense)
        XCTAssertEqual(command.description, "кофе")
        let income = QE.parse("доход 5000 подарок")
        XCTAssertEqual(income.commandType, .income)
        XCTAssertEqual(income.description, "подарок")
        let spent = QE.parse("потратил 300 на кофе")
        XCTAssertEqual(spent.keywordType, .expense)
        XCTAssertEqual(spent.description, "кофе")
        XCTAssertEqual(QE.parse("spent 12 on lunch").description, "lunch")
        XCTAssertEqual(QE.parse("gasté 12 en comida").description, "comida")
        let got = QE.parse("получил зарплату 50000")
        XCTAssertEqual(got.keywordType, .income)
        XCTAssertEqual(got.description, "зарплату")
        XCTAssertEqual(QE.parse("Добавь в Акифи кофе 300").description, "кофе")
    }

    // MARK: - Digits

    func testSeparatorsAndSpacing() {
        check([
            Case(text: "обед 1,234.56", amount: "1234.56", description: "обед"),
            Case(text: "обед 1.234,56", amount: "1234.56"),
            Case(text: "кофе 12,5", amount: "12.5"),
            Case(text: "кофе 12.50", amount: "12.5"),
            Case(text: "аренда 30 000 ₽", amount: "30000", currency: "RUB", description: "аренда"),
            Case(text: "аренда 30 000₽", amount: "30000", currency: "RUB", description: "аренда"),
            Case(text: "кофе 2 500", amount: "2500"),
            Case(text: "машина 1 234 567", amount: "1234567"),
            Case(text: "зарплата 150\u{00A0}000", amount: "150000"),
            Case(text: "продукты 1\u{202F}234,56", amount: "1234.56"),
            Case(text: "кофе 1'000", amount: "1000"),
            Case(text: "кофе 300,-", amount: "300"),
            Case(text: "кофе, 300.", amount: "300", description: "кофе"),
            Case(text: "  кофе    300  ", amount: "300", description: "кофе"),
            Case(text: "ремонт 12.500", amount: "12500"),
            Case(text: "чай 0,500", amount: "0.5"),
            Case(text: "iPhone15 чехол 2000", amount: "2000", description: "iPhone15 чехол"),
        ])
    }

    func testMultipliers() {
        check([
            Case(text: "такси 5к", amount: "5000", description: "такси"),
            Case(text: "ноутбук 1.5k", amount: "1500"),
            Case(text: "ноутбук 1,5к", amount: "1500"),
            Case(text: "5 тыс аренда", amount: "5000", description: "аренда"),
            Case(text: "1.5 млн машина", amount: "1500000", description: "машина"),
            Case(text: "аренда 5к₽", amount: "5000", currency: "RUB"),
            Case(text: "alquiler 5 mil", amount: "5000", description: "alquiler"),
        ])
    }

    func testNeverInventsANumber() {
        check([
            Case(text: "кофе", description: "кофе"),
            Case(text: "", description: ""),
            Case(text: "кофе 0", description: "кофе 0"),
            Case(text: "один кофе", description: "один кофе"),
            Case(text: "a coffee", description: "a coffee"),
            Case(text: "un café", description: "un café"),
            Case(text: "кофе 12 ноября", description: "кофе", day: "2026-11-12"),
        ])
    }

    func testSeveralNumbersPickTheAmount() {
        check([
            // The other number stays in the description.
            Case(text: "обед на 2 персоны 1500", amount: "1500", description: "обед на 2 персоны"),
            Case(text: "2 кофе 300", amount: "300", description: "2 кофе"),
            Case(text: "un café 3", amount: "3", description: "un café"),
            // A number with a currency wins over a bigger plain one.
            Case(text: "обед 12$ 300", amount: "12", currency: "USD", description: "обед 300"),
        ])
    }

    // MARK: - Currencies

    func testCurrencies() {
        check([
            Case(text: "кофе 300р", amount: "300", currency: "RUB", description: "кофе"),
            Case(text: "кофе 300 руб.", amount: "300", currency: "RUB", description: "кофе"),
            Case(text: "кофе 300 рублей", amount: "300", currency: "RUB", description: "кофе"),
            Case(text: "100 usd ужин", amount: "100", currency: "USD", description: "ужин"),
            Case(text: "USD 100 ужин", amount: "100", currency: "USD", description: "ужин"),
            Case(text: "ужин USD100", amount: "100", currency: "USD", description: "ужин"),
            Case(text: "$ 12 lunch", amount: "12", currency: "USD", description: "lunch"),
            Case(text: "coffee 4.5 dollars", amount: "4.5", currency: "USD", description: "coffee"),
            Case(text: "café 3 euros", amount: "3", currency: "EUR", description: "café"),
            Case(text: "massage 500 baht", amount: "500", currency: "THB", description: "massage"),
            Case(text: "фо 50000 донгов", amount: "50000", currency: "VND", description: "фо"),
            Case(text: "pho 50000 VND", amount: "50000", currency: "VND", description: "pho"),
            Case(text: "kebab 300 TRY", amount: "300", currency: "TRY", description: "kebab"),
            Case(text: "20 баксов такси", amount: "20", currency: "USD", description: "такси"),
            Case(text: "£15 book", amount: "15", currency: "GBP", description: "book"),
            Case(text: "плов 40000 сумов", amount: "40000", currency: "UZS", description: "плов"),
        ])
        // Ordinary words that are also ISO codes need uppercase.
        let lower = QE.parse("try 300 again")
        XCTAssertEqual(lower.amount, d("300"))
        XCTAssertNil(lower.currencyCode)
    }

    // MARK: - Words as numbers (voice)

    func testRussianNumberWords() {
        check([
            Case(text: "кофе триста", amount: "300", description: "кофе"),
            Case(text: "такси полторы тысячи", amount: "1500", description: "такси"),
            Case(text: "продукты две тысячи пятьсот", amount: "2500", description: "продукты"),
            Case(text: "две тысячи пятьсот рублей продукты", amount: "2500", currency: "RUB", description: "продукты"),
            Case(text: "тысяча на продукты", amount: "1000", description: "продукты"),
            Case(text: "тысяча двести обед", amount: "1200", description: "обед"),
            Case(text: "сто пятьдесят кофе", amount: "150", description: "кофе"),
            Case(text: "кофе двадцать один", amount: "21", description: "кофе"),
            Case(text: "пять тысяч аренда", amount: "5000", description: "аренда"),
            Case(text: "2 тысячи 500 продукты", amount: "2500", description: "продукты"),
            Case(text: "полтора миллиона машина", amount: "1500000", description: "машина"),
            Case(text: "полтысячи такси", amount: "500", description: "такси"),
            Case(text: "сто двадцать рублей пятьдесят копеек кофе", amount: "120.5", currency: "RUB", description: "кофе"),
            Case(text: "три миллиона двести тысяч квартира", amount: "3200000", description: "квартира"),
        ])
    }

    func testEnglishAndSpanishNumberWords() {
        check([
            Case(text: "lunch twenty five", amount: "25", description: "lunch"),
            Case(text: "lunch twenty-five", amount: "25", description: "lunch"),
            Case(text: "two thousand five hundred rent", amount: "2500", description: "rent"),
            Case(text: "one hundred and five groceries", amount: "105", description: "groceries"),
            Case(text: "a hundred taxi", amount: "100", description: "taxi"),
            Case(text: "five dollars coffee", amount: "5", currency: "USD", description: "coffee"),
            Case(text: "dos mil quinientos supermercado", amount: "2500", description: "supermercado"),
            Case(text: "treinta y cinco taxi", amount: "35", description: "taxi"),
            Case(text: "mil quinientos alquiler", amount: "1500", description: "alquiler"),
            Case(text: "ciento cincuenta cena", amount: "150", description: "cena"),
            Case(text: "un millón coche", amount: "1000000", description: "coche"),
            Case(text: "veintidós euros comida", amount: "22", currency: "EUR", description: "comida"),
        ])
    }

    // MARK: - Dates

    func testRelativeAndWeekdayDates() {
        check([
            Case(text: "кофе 300 сегодня", amount: "300", description: "кофе", day: "2026-11-27"),
            Case(text: "такси 500 позавчера", amount: "500", description: "такси", day: "2026-11-25"),
            // Today is Friday: «в пятницу» is today, «в прошлую пятницу» a week ago.
            Case(text: "кофе 200 в пятницу", amount: "200", description: "кофе", day: "2026-11-27"),
            Case(text: "кофе 200 в прошлую пятницу", amount: "200", description: "кофе", day: "2026-11-20"),
            Case(text: "кофе 200 в понедельник", amount: "200", description: "кофе", day: "2026-11-23"),
            Case(text: "кофе 200 в ср", amount: "200", description: "кофе", day: "2026-11-25"),
            Case(text: "кофе 200 во вторник", amount: "200", description: "кофе", day: "2026-11-24"),
            Case(text: "lunch 15 last monday", amount: "15", description: "lunch", day: "2026-11-23"),
            Case(text: "lunch 15 on sunday", amount: "15", description: "lunch", day: "2026-11-22"),
            Case(text: "comida 10 el lunes pasado", amount: "10", description: "comida", day: "2026-11-23"),
            Case(text: "comida 10 ayer", amount: "10", description: "comida", day: "2026-11-26"),
            Case(text: "comida 10 anteayer", amount: "10", description: "comida", day: "2026-11-25"),
            Case(text: "taxi 20 yesterday", amount: "20", description: "taxi", day: "2026-11-26"),
            Case(text: "такси 300 3 дня назад", amount: "300", description: "такси", day: "2026-11-24"),
            Case(text: "taxi 20 2 days ago", amount: "20", description: "taxi", day: "2026-11-25"),
            Case(text: "taxi 20 hace 2 días", amount: "20", description: "taxi", day: "2026-11-25"),
        ])
    }

    func testCalendarDates() {
        check([
            Case(text: "кофе 300 12 ноября", amount: "300", description: "кофе", day: "2026-11-12"),
            Case(text: "кофе 300 12 нояб", amount: "300", description: "кофе", day: "2026-11-12"),
            // A day after today means last year.
            Case(text: "такси 12 декабря 700", amount: "700", description: "такси", day: "2025-12-12"),
            Case(text: "такси 700 1 января 2026 г", amount: "700", description: "такси", day: "2026-01-01"),
            Case(text: "Nov 12 lunch 20", amount: "20", description: "lunch", day: "2026-11-12"),
            Case(text: "November 3rd lunch 20", amount: "20", description: "lunch", day: "2026-11-03"),
            Case(text: "comida 20 12 de noviembre", amount: "20", description: "comida", day: "2026-11-12"),
            Case(text: "обед 12.11 500", amount: "500", description: "обед", day: "2026-11-12"),
            Case(text: "обед 500 12.11.2025", amount: "500", description: "обед", day: "2025-11-12"),
            Case(text: "обед 500 12/11", amount: "500", description: "обед", day: "2026-11-12"),
            // The only number: an amount, not a date.
            Case(text: "обед 12.11", amount: "12.11", description: "обед"),
            // «31.02» is not a date — stays a number.
            Case(text: "обед 31.02 500", amount: "500", description: "обед 31.02"),
            // «may» without a day is just a word.
            Case(text: "may coffee 300", amount: "300", description: "may coffee"),
        ])
    }

    func testDateKeepsTheTimeOfDay() {
        let p = QE.parse("такси 500 вчера")
        let comps = QE.calendar.dateComponents([.hour, .minute], from: p.date!)
        XCTAssertEqual(comps.hour, 14)
        XCTAssertEqual(comps.minute, 30)
        XCTAssertEqual(p.dateText, "вчера")
    }

    // MARK: - Accounts

    func testAccountHints() {
        let v = QE.vocabulary
        XCTAssertEqual(QE.parse("кофе 300 с тинькоффа", vocabulary: v).account?.accountId, "acc-card")
        // Cyrillic speech vs a Latin account name and back.
        let latin = QuickEntryVocabulary(accounts: [QE.account("acc-t", "Tinkoff Black")], categories: [])
        let spoken = QE.parse("кофе 300 с тинькофф", vocabulary: latin)
        XCTAssertEqual(spoken.account?.accountId, "acc-t")
        XCTAssertEqual(spoken.description, "кофе")
        XCTAssertEqual(QE.parse("продукты 500 со сбера", vocabulary: v).account?.accountId, "acc-sber")
        XCTAssertEqual(QE.parse("продукты 500 со сбера", vocabulary: v).description, "продукты")
        XCTAssertEqual(QE.parse("lunch 20 from bybit", vocabulary: v).account?.accountId, "acc-usd")
        // No preposition: an exact name next to another word still counts.
        XCTAssertEqual(QE.parse("кофе 300 Тинькофф", vocabulary: v).account?.accountId, "acc-card")
        // The account name alone is the description, not a hint.
        let alone = QE.parse("Сбер 500", vocabulary: v)
        XCTAssertNil(alone.account)
        XCTAssertEqual(alone.description, "Сбер")
        // «наличными» → the only cash account, whatever its name.
        let cash = QE.parse("кофе 300 наличными", vocabulary: v)
        XCTAssertEqual(cash.account?.accountId, "acc-cash")
        XCTAssertEqual(cash.description, "кофе")
        XCTAssertEqual(QE.parse("taco 5 in cash", vocabulary: v).account?.accountId, "acc-cash")
        XCTAssertEqual(QE.parse("taco 5 en efectivo", vocabulary: v).description, "taco")
        // A number that is part of the name is not the amount.
        let visa = QuickEntryVocabulary(accounts: [QE.account("acc-v", "Visa 4242")], categories: [])
        let p = QE.parse("кофе 300 с visa 4242", vocabulary: visa)
        XCTAssertEqual(p.account?.accountId, "acc-v")
        XCTAssertEqual(p.amount, d("300"))
        // Similar unrelated words don't match.
        let shop = QuickEntryVocabulary(accounts: [QE.account("acc-k", "Кофейня")], categories: [])
        XCTAssertNil(QE.parse("кофе 300", vocabulary: shop).account)
    }

    func testAmbiguousAccountsGiveNoHint() {
        let v = QuickEntryVocabulary(accounts: [QE.account("a1", "Сбер"), QE.account("a2", "Сбер")], categories: [])
        XCTAssertNil(QE.parse("кофе 300 со сбера", vocabulary: v).account)
    }

    // MARK: - Category hints

    func testCategoryHints() {
        let v = QE.vocabulary
        XCTAssertEqual(QE.parse("такси 500", vocabulary: v).categoryHints.first?.categoryId, "cat-taxi")
        XCTAssertEqual(QE.parse("продукты 1 234,56", vocabulary: v).categoryHints.first?.categoryId, "cat-food")
        let cafe = QE.parse("кафе 300", vocabulary: v).categoryHints.map(\.categoryId)
        XCTAssertEqual(cafe.first, "cat-cafe")
        XCTAssertTrue(cafe.contains("cat-rest"), "one word of «Кафе и рестораны»")
        XCTAssertEqual(QE.parse("зарплату 50000", vocabulary: v).categoryHints.first?.categoryId, "cat-salary")
        XCTAssertEqual(QE.parse("+5000 подарок", vocabulary: v).categoryHints.first?.categoryId, "cat-gifts")
        XCTAssertTrue(QE.parse("кофе 300", vocabulary: v).categoryHints.isEmpty)
    }

    // MARK: - Pieces

    func testParseDigits() {
        let table: [(String, String?)] = [
            ("150000", "150000"), ("1,234.56", "1234.56"), ("1.234,56", "1234.56"), ("12,5", "12.5"),
            ("12.50", "12.5"), ("1.234.567", "1234567"), ("1,234,567", "1234567"), ("12.500", "12500"),
            ("0.500", "0.5"), ("1'000", "1000"), ("1234,567", "1234.567"),
            ("1,2,3", nil), ("1.2.3", nil), ("1,23.45.6", nil), ("abc", nil), (".5", nil), ("5.", nil),
            ("1,234,56", nil),
        ]
        for (raw, expected) in table {
            XCTAssertEqual(QuickEntryNumbers.parseDigits(raw), expected.map(d), raw)
        }
    }

    func testAnalyzeNumeric() {
        XCTAssertEqual(QuickEntryParser.analyzeNumeric("+5000")?.sign, .income)
        XCTAssertEqual(QuickEntryParser.analyzeNumeric("€20")?.prefixCurrency, "EUR")
        XCTAssertEqual(QuickEntryParser.analyzeNumeric("12$")?.suffixCurrency, "USD")
        XCTAssertEqual(QuickEntryParser.analyzeNumeric("5к")?.multiplier, 1000)
        XCTAssertNil(QuickEntryParser.analyzeNumeric("iPhone15"))
        XCTAssertNil(QuickEntryParser.analyzeNumeric("2x"))
        XCTAssertNil(QuickEntryParser.analyzeNumeric("abc100"))
        XCTAssertNil(QuickEntryParser.analyzeNumeric("+"))
    }

    func testNumberGrammarStopsAtMalformedSequences() {
        typealias A = QuickEntryNumbers.Atom
        func w(_ s: String) -> A { .word(QuickEntryNumbers.words[QuickEntryText.wordKey(s)]!) }
        // «два три» is two numbers, not five.
        XCTAssertEqual(QuickEntryNumbers.read([w("два"), w("три")])?.length, 1)
        XCTAssertEqual(QuickEntryNumbers.read([w("два"), w("три")])?.value, 2)
        // «тысяча миллион»: scales must decrease.
        XCTAssertEqual(QuickEntryNumbers.read([w("тысяча"), w("миллион")])?.value, 1000)
        XCTAssertNil(QuickEntryNumbers.read([w("and")]))
        XCTAssertNil(QuickEntryNumbers.read([w("a")]))
        XCTAssertEqual(QuickEntryNumbers.read([.digits(2, hasGluedMultiplier: false), w("тысячи"), .digits(500, hasGluedMultiplier: false)])?.value, 2500)
        // A digit group can't exceed the scale before it.
        XCTAssertEqual(QuickEntryNumbers.read([w("тысяча"), .digits(2025, hasGluedMultiplier: false)])?.value, 1000)
    }

    func testTextKeys() {
        XCTAssertEqual(QuickEntryText.matchKey("Тинькофф"), QuickEntryText.matchKey("тинькоффа"))
        XCTAssertEqual(QuickEntryText.matchKey("Наличные"), QuickEntryText.matchKey("наличными"))
        XCTAssertEqual(QuickEntryText.matchKey("Зарплата"), QuickEntryText.matchKey("зарплату"))
        XCTAssertEqual(QuickEntryText.matchKey("тинькофф"), QuickEntryText.matchKey("Tinkoff"))
        XCTAssertEqual(QuickEntryText.identityKey("Кофе!"), QuickEntryText.identityKey("кофе"))
        XCTAssertEqual(QuickEntryText.fold("Ёлка CAFÉ"), "елка cafe")
        XCTAssertGreaterThanOrEqual(QuickEntryText.similarity(QuickEntryText.matchKey("подарок"), QuickEntryText.matchKey("Подарки")), 0.8)
        XCTAssertEqual(QuickEntryText.similarity(QuickEntryText.matchKey("кофе"), QuickEntryText.matchKey("кафе")), 0)
    }
}
