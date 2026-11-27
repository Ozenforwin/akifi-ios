import Foundation

/// Word lists of the quick-entry parser (ru / en / es). Every key is stored
/// folded (`QuickEntryText.wordKey`) so lookups are case / diacritic
/// insensitive.
enum QuickEntryLexicon {

    private static func keyed<V>(_ pairs: [(String, V)]) -> [String: V] {
        var out: [String: V] = [:]
        for (k, v) in pairs { out[QuickEntryText.wordKey(k)] = v }
        return out
    }

    private static func keySet(_ words: [String]) -> Set<String> {
        Set(words.map(QuickEntryText.wordKey))
    }

    // MARK: - Currency

    /// Currency symbols (single characters or glued prefixes / suffixes).
    static let currencySymbols: [String: String] = [
        "₽": "RUB", "$": "USD", "€": "EUR", "£": "GBP", "₸": "KZT", "₴": "UAH",
        "¥": "JPY", "₺": "TRY", "₫": "VND", "฿": "THB", "₹": "INR", "₾": "GEL",
        "֏": "AMD", "₩": "KRW", "₼": "AZN", "zł": "PLN", "₪": "ILS", "₱": "PHP"
    ]

    /// Currency words — names, slang and abbreviations that are not
    /// ordinary words in any of the three languages.
    static let currencyWords: [String: String] = keyed([
        // RUB
        ("р", "RUB"), ("р.", "RUB"), ("руб", "RUB"), ("рубль", "RUB"), ("рубля", "RUB"), ("рублей", "RUB"),
        ("рублях", "RUB"), ("ruble", "RUB"), ("rubles", "RUB"), ("rouble", "RUB"), ("roubles", "RUB"),
        ("rublo", "RUB"), ("rublos", "RUB"),
        // USD
        ("доллар", "USD"), ("доллара", "USD"), ("долларов", "USD"), ("долл", "USD"), ("бакс", "USD"),
        ("бакса", "USD"), ("баксов", "USD"), ("dollar", "USD"), ("dollars", "USD"), ("bucks", "USD"),
        ("dolar", "USD"), ("dólar", "USD"), ("dolares", "USD"), ("dólares", "USD"),
        // EUR
        ("евро", "EUR"), ("euro", "EUR"), ("euros", "EUR"),
        // GBP
        ("фунт", "GBP"), ("фунта", "GBP"), ("фунтов", "GBP"), ("pound", "GBP"), ("pounds", "GBP"),
        ("libra", "GBP"), ("libras", "GBP"),
        // Others with unambiguous names
        ("тенге", "KZT"), ("tenge", "KZT"),
        ("гривна", "UAH"), ("гривны", "UAH"), ("гривен", "UAH"), ("грн", "UAH"), ("hryvnia", "UAH"),
        ("юань", "CNY"), ("юаня", "CNY"), ("юаней", "CNY"), ("yuan", "CNY"), ("rmb", "CNY"), ("yuanes", "CNY"),
        ("иена", "JPY"), ("иены", "JPY"), ("иен", "JPY"), ("йена", "JPY"), ("йены", "JPY"), ("йен", "JPY"), ("yen", "JPY"),
        ("лира", "TRY"), ("лиры", "TRY"), ("лир", "TRY"), ("lira", "TRY"), ("liras", "TRY"),
        ("донг", "VND"), ("донга", "VND"), ("донгов", "VND"), ("dong", "VND"),
        ("бат", "THB"), ("бата", "THB"), ("батов", "THB"), ("baht", "THB"),
        ("лари", "GEL"), ("lari", "GEL"),
        ("драм", "AMD"), ("драма", "AMD"), ("драмов", "AMD"), ("dram", "AMD"),
        ("сум", "UZS"), ("сумов", "UZS"),
        ("сом", "KGS"), ("сомов", "KGS"),
        ("злотый", "PLN"), ("злотых", "PLN"), ("zloty", "PLN"),
        ("дирхам", "AED"), ("дирхама", "AED"), ("дирхамов", "AED"), ("dirham", "AED"), ("dirhams", "AED"),
        ("рупия", "IDR"), ("рупии", "IDR"), ("rupiah", "IDR"),
        ("рупий", "INR"), ("rupee", "INR"), ("rupees", "INR"),
        ("франк", "CHF"), ("франка", "CHF"), ("франков", "CHF"), ("franc", "CHF"), ("francs", "CHF"),
        ("вон", "KRW"), ("won", "KRW")
    ])

    /// Lowercase ISO codes accepted without uppercase («usd», «eur»).
    /// Codes that are ordinary words («try», «gel», «all», «cup», «top»,
    /// «mad», «pen», «bob») only count when typed in uppercase.
    static let lowercaseISOCodes: Set<String> = [
        "usd", "eur", "rub", "gbp", "vnd", "thb", "idr", "kzt", "uah", "byn", "cny", "jpy",
        "aed", "amd", "uzs", "kgs", "chf", "pln", "czk", "inr", "krw", "azn", "rsd", "huf",
        "sek", "nok", "dkk", "cad", "aud", "nzd", "sgd", "hkd", "myr", "php", "ils", "brl",
        "mxn", "ars", "clp", "cop"
    ]

    /// ISO code for a folded / raw token, if it names a currency.
    static func currency(forToken raw: String) -> String? {
        if let symbol = currencySymbols[raw] { return symbol }
        let key = QuickEntryText.wordKey(raw)
        if let word = currencyWords[key] { return word }
        if raw.count == 3, raw.allSatisfy({ $0.isASCII && $0.isLetter }) {
            if raw == raw.uppercased(), CurrencyCatalog.isKnown(raw) { return raw }
            if lowercaseISOCodes.contains(raw.lowercased()) { return raw.uppercased() }
        }
        return nil
    }

    // MARK: - Type signals

    /// Words that mark an entry as income.
    static let incomeKeywords: Set<String> = keySet([
        "зарплата", "зарплату", "зарплаты", "зп", "аванс", "премия", "премию", "бонус", "доход", "доходы",
        "получил", "получила", "получили", "пришла", "пришло", "пришли", "заработал", "заработала",
        "кэшбэк", "кешбэк", "кэшбек", "кешбек", "вернули", "возврат", "дивиденды", "проценты",
        "salary", "paycheck", "payday", "income", "bonus", "refund", "refunded", "cashback", "received",
        "earned", "dividends", "salario", "sueldo", "nomina", "nómina", "ingreso", "ingresos", "bono",
        "reembolso", "recibi", "recibí", "cobre", "cobré", "gane", "gané", "devolucion", "devolución"
    ])

    /// Words that explicitly mark an expense.
    static let expenseKeywords: Set<String> = keySet([
        "расход", "расходы", "трата", "трату", "траты", "потратил", "потратила", "заплатил", "заплатила",
        "оплатил", "оплатила", "купил", "купила",
        "expense", "spent", "paid", "bought", "gasto", "gaste", "gasté", "pague", "pagué", "compre", "compré"
    ])

    // MARK: - Filler

    /// Command words a voice / Siri phrase may start with.
    static let commandWords: Set<String> = keySet([
        "добавь", "добавить", "добавьте", "запиши", "записать", "запишите", "внеси", "внести", "новый", "новая",
        "add", "log", "record", "new", "anade", "añade", "anadir", "añadir", "agrega", "agregar",
        "apunta", "apuntar", "registra", "registrar", "nuevo", "nueva"
    ])

    /// Type words that are pure commands after a command verb or at the
    /// start («добавь расход …», «доход 5000 подарок») — removed from the
    /// description.
    static let typeCommandWords: [String: TransactionType] = keyed([
        ("расход", .expense), ("трату", .expense), ("трата", .expense), ("expense", .expense), ("gasto", .expense),
        ("доход", .income), ("income", .income), ("ingreso", .income)
    ])

    /// Verbs at the start of a phrase that only say "I paid / I got".
    static let leadingVerbs: Set<String> = keySet([
        "потратил", "потратила", "заплатил", "заплатила", "оплатил", "оплатила", "купил", "купила",
        "получил", "получила", "заработал", "заработала",
        "spent", "paid", "bought", "received", "earned", "got",
        "gaste", "gasté", "pague", "pagué", "compre", "compré", "recibi", "recibí", "cobre", "cobré", "gane", "gané"
    ])

    /// Prepositions trimmed off the edges of the description once the
    /// amount / date / account around them are gone («300 на кофе» →
    /// «кофе», «обед за 500» → «обед»).
    static let danglingPrepositions: Set<String> = keySet([
        "на", "за", "в", "во", "по", "для",
        "on", "for", "at", "in",
        "en", "para", "por"
    ])

    // MARK: - Account context

    /// Words right before an account name («с карты Тинькофф», «from
    /// Revolut», «con Santander»).
    static let accountPrepositions: Set<String> = keySet([
        "с", "со", "из", "через", "from", "with", "via", "using", "con", "desde", "de"
    ])

    /// Generic account nouns, ignored in account names and consumed
    /// together with the name in a phrase.
    static let accountNouns: Set<String> = keySet([
        "карта", "карты", "карте", "карту", "картой", "счет", "счета", "счете", "счетом", "кошелек", "кошелька",
        "card", "account", "wallet", "tarjeta", "cuenta", "cartera", "мой", "моя", "моего", "моей", "my", "mi"
    ])

    /// «Paid in cash» words → the user's only `.cash` account.
    static let cashWords: Set<String> = keySet([
        "наличными", "наличкой", "налом", "кэшем", "кешем", "наличные", "cash", "efectivo"
    ])

    // MARK: - Dates

    /// Relative day words → days back from today.
    static let relativeDays: [String: Int] = keyed([
        ("сегодня", 0), ("today", 0), ("hoy", 0),
        ("вчера", 1), ("yesterday", 1), ("ayer", 1),
        ("позавчера", 2), ("anteayer", 2), ("antier", 2)
    ])

    /// Weekday words → Gregorian weekday (1 = Sunday … 7 = Saturday) and
    /// whether the word may stand alone (short forms need «в» / «on» / «el»).
    struct Weekday: Equatable, Sendable {
        let weekday: Int
        let standalone: Bool
    }

    static let weekdays: [String: Weekday] = {
        var w: [String: Weekday] = [:]
        func add(_ names: [String], _ day: Int, standalone: Bool = true) {
            for n in names { w[QuickEntryText.wordKey(n)] = Weekday(weekday: day, standalone: standalone) }
        }
        add(["понедельник"], 2); add(["вторник"], 3); add(["среда", "среду"], 4); add(["четверг"], 5)
        add(["пятница", "пятницу"], 6); add(["суббота", "субботу"], 7); add(["воскресенье"], 1)
        add(["пн"], 2, standalone: false); add(["вт"], 3, standalone: false); add(["ср"], 4, standalone: false)
        add(["чт"], 5, standalone: false); add(["пт"], 6, standalone: false); add(["сб"], 7, standalone: false)
        add(["вс"], 1, standalone: false)
        add(["monday"], 2); add(["tuesday"], 3); add(["wednesday"], 4); add(["thursday"], 5)
        add(["friday"], 6); add(["saturday"], 7); add(["sunday"], 1)
        add(["mon"], 2, standalone: false); add(["tue", "tues"], 3, standalone: false); add(["wed"], 4, standalone: false)
        add(["thu", "thur", "thurs"], 5, standalone: false); add(["fri"], 6, standalone: false)
        add(["sat"], 7, standalone: false); add(["sun"], 1, standalone: false)
        add(["lunes"], 2); add(["martes"], 3); add(["miercoles", "miércoles"], 4); add(["jueves"], 5)
        add(["viernes"], 6); add(["sabado", "sábado"], 7); add(["domingo"], 1)
        return w
    }()

    /// Words before a weekday: «в пятницу», «on friday», «el viernes».
    static let weekdayPrepositions: Set<String> = keySet(["в", "во", "on", "el"])

    /// «прошлую пятницу», «last friday», «el viernes pasado».
    static let lastWords: Set<String> = keySet([
        "прошлый", "прошлую", "прошлое", "прошлой", "прошлом", "last", "pasado", "pasada"
    ])

    /// Month words → month number. Every form needs a day number next to it.
    static let months: [String: Int] = {
        var m: [String: Int] = [:]
        func add(_ names: [String], _ month: Int) {
            for n in names { m[QuickEntryText.wordKey(n)] = month }
        }
        add(["января", "январь", "янв", "january", "jan", "enero", "ene"], 1)
        add(["февраля", "февраль", "фев", "february", "feb", "febrero"], 2)
        add(["марта", "март", "мар", "march", "mar", "marzo"], 3)
        add(["апреля", "апрель", "апр", "april", "apr", "abril", "abr"], 4)
        add(["мая", "май", "may", "mayo"], 5)
        add(["июня", "июнь", "июн", "june", "jun", "junio"], 6)
        add(["июля", "июль", "июл", "july", "jul", "julio"], 7)
        add(["августа", "август", "авг", "august", "aug", "agosto", "ago"], 8)
        add(["сентября", "сентябрь", "сен", "сент", "september", "sep", "sept", "septiembre", "setiembre"], 9)
        add(["октября", "октябрь", "окт", "october", "oct", "octubre"], 10)
        add(["ноября", "ноябрь", "ноя", "нояб", "november", "nov", "noviembre"], 11)
        add(["декабря", "декабрь", "дек", "december", "dec", "diciembre", "dic"], 12)
        return m
    }()

    /// «3 дня назад», «2 days ago», «hace 2 días».
    static let dayUnits: Set<String> = keySet(["день", "дня", "дней", "day", "days", "dia", "día", "dias", "días"])
    static let agoWords: Set<String> = keySet(["назад", "ago"])
    static let haceWords: Set<String> = keySet(["hace"])
    /// Spanish «12 de noviembre».
    static let monthConnectors: Set<String> = keySet(["de"])
}
