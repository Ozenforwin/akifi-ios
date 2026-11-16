import Foundation

enum CSVExporter {
    /// One row per transaction. `amount` is `amount_native` — in the
    /// ACCOUNT's currency — so the `currency` column (M7) carries that
    /// account's ISO code; without it a "50.00" on a USD account and a
    /// "3000.00" on a RUB account were indistinguishable in a spreadsheet.
    static func export(transactions: [Transaction], categories: [Category], accounts: [Account]) -> String {
        let header = [
            String(localized: "csv.date"),
            String(localized: "csv.type"),
            String(localized: "csv.amount"),
            String(localized: "csv.currency"),
            String(localized: "csv.category"),
            String(localized: "csv.description"),
            String(localized: "csv.account")
        ]
        var csv = header.map(field).joined(separator: ",") + "\n"

        let categoryMap = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let accountMap = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for tx in transactions.sorted(by: { $0.date > $1.date }) {
            let type = tx.isTransfer ? String(localized: "transaction.transfer") : (tx.type == .income ? String(localized: "common.income") : String(localized: "common.expense"))
            let amount = amountString(tx.amountNative)
            let account = tx.accountId.flatMap { accountMap[$0] }
            let currency = account?.currency.uppercased() ?? ""
            let category = tx.categoryId.flatMap { categoryMap[$0]?.name } ?? ""

            let row = [tx.date, type, amount, currency, category, tx.description ?? "", account?.name ?? ""]
            csv += row.map(field).joined(separator: ",") + "\n"
        }

        return csv
    }

    /// Kopecks → "1234.56" / "-0.05", exact (no Double round-trip).
    static func amountString(_ kopecks: Int64) -> String {
        let sign = kopecks < 0 ? "-" : ""
        let magnitude = kopecks.magnitude
        return "\(sign)\(magnitude / 100).\(String(format: "%02d", Int(magnitude % 100)))"
    }

    /// RFC 4180 quoting: a field with a comma, quote or line break is
    /// wrapped in quotes with inner quotes doubled. (Descriptions used to
    /// have commas replaced by ";", and a comma in a category or account
    /// name shifted every following column.)
    static func field(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
