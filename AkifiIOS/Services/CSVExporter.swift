import Foundation

enum CSVExporter {
    static func export(transactions: [Transaction], categories: [Category], accounts: [Account]) -> String {
        var csv = "\(String(localized: "csv.date")),\(String(localized: "csv.type")),\(String(localized: "csv.amount")),\(String(localized: "csv.category")),\(String(localized: "csv.description")),\(String(localized: "csv.account"))\n"

        let categoryMap = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
        let accountMap = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })

        for tx in transactions.sorted(by: { $0.date > $1.date }) {
            let type = tx.isTransfer ? String(localized: "transaction.transfer") : (tx.type == .income ? String(localized: "common.income") : String(localized: "common.expense"))
            let amount = String(format: "%.2f", Double(truncating: tx.amount.displayAmount as NSDecimalNumber))
            let category = tx.categoryId.flatMap { categoryMap[$0]?.name } ?? ""
            let description = (tx.description ?? "").replacingOccurrences(of: ",", with: ";")
            let account = tx.accountId.flatMap { accountMap[$0]?.name } ?? ""

            csv += "\(tx.date),\(type),\(amount),\(category),\(description),\(account)\n"
        }

        return csv
    }
}
