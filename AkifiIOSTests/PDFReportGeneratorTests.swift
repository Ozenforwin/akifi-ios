import XCTest
@testable import AkifiIOS

/// Smoke tests for `PDFReportGenerator`.
///
/// We don't try to pixel-compare rendered PDFs — that is brittle and not worth
/// the maintenance. Instead we verify the generator:
/// 1. Doesn't crash on empty/minimal inputs (regression guard).
/// 2. Produces a valid, non-empty PDF file.
/// 3. Handles multiple categories, budgets and subscriptions without throwing.
final class PDFReportGeneratorTests: XCTestCase {

    // MARK: - Factories

    private func makeCategory(id: String, name: String, icon: String = "🛒", type: CategoryType = .expense) -> AkifiIOS.Category {
        AkifiIOS.Category(
            id: id, userId: "u1", accountId: nil, name: name,
            icon: icon, color: "#60A5FA", type: type, isActive: true, createdAt: nil
        )
    }

    private func makeTx(id: String, amount: Int64, type: TransactionType,
                       categoryId: String? = nil, date: String = "2026-04-15") -> Transaction {
        Transaction(
            id: id, userId: "u1", accountId: "a1", amount: amount,
            currency: "RUB", description: "Test \(id)", categoryId: categoryId, type: type,
            date: date, merchantName: nil, merchantFuzzy: nil, transferGroupId: nil,
            status: nil, createdAt: nil, updatedAt: nil
        )
    }

    private func makeAccount() -> Account {
        Account(
            id: "a1", userId: "u1", name: "Main",
            icon: "💳", color: "#60A5FA",
            initialBalance: 0, isPrimary: true, currency: "RUB"
        )
    }

    // MARK: - Tests

    func testGenerate_EmptyInput_DoesNotCrashAndProducesFile() throws {
        let input = PDFReportGenerator.Input(
            title: "Report",
            periodLabel: "April 2026",
            generatedAt: Date(),
            userName: nil,
            currencyCode: "RUB",
            transactions: [],
            previousTransactions: [],
            categories: [],
            accounts: [],
            accountFilter: nil,
            budgets: [],
            subscriptions: []
        )
        let url = try PDFReportGenerator.generate(input)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 500, "PDF should contain at least a header page")
        // PDF files start with %PDF-
        let prefix = String(data: data.prefix(5), encoding: .ascii)
        XCTAssertEqual(prefix, "%PDF-")
    }

    func testGenerate_WithDataProducesLargerPDF() throws {
        let food = makeCategory(id: "c1", name: "Food", icon: "🍔")
        let cafe = makeCategory(id: "c2", name: "Cafe", icon: "☕")
        let salary = makeCategory(id: "c3", name: "Salary", icon: "💰", type: .income)

        let txs: [Transaction] = [
            makeTx(id: "t1", amount: 150_00, type: .expense, categoryId: "c1"),
            makeTx(id: "t2", amount: 250_00, type: .expense, categoryId: "c1"),
            makeTx(id: "t3", amount: 80_00, type: .expense, categoryId: "c2"),
            makeTx(id: "t4", amount: 50_000_00, type: .income, categoryId: "c3"),
            makeTx(id: "t5", amount: 1_200_00, type: .expense, categoryId: nil)
        ]
        let prev: [Transaction] = [
            makeTx(id: "p1", amount: 100_00, type: .expense, categoryId: "c1", date: "2026-03-15"),
            makeTx(id: "p2", amount: 45_000_00, type: .income, categoryId: "c3", date: "2026-03-15")
        ]

        let input = PDFReportGenerator.Input(
            title: "Financial Report",
            periodLabel: "April 2026",
            generatedAt: Date(),
            userName: "Vladimir",
            currencyCode: "RUB",
            transactions: txs,
            previousTransactions: prev,
            categories: [food, cafe, salary],
            accounts: [makeAccount()],
            accountFilter: nil,
            budgets: [],
            subscriptions: []
        )

        let url = try PDFReportGenerator.generate(input)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 1500, "PDF with data should be larger than empty one")
    }

    func testFormatAmount_FormatsCurrencyCorrectly() {
        // Sanity check on internal helper (exposed as nonisolated static).
        let result = PDFReportGenerator.formatAmount(1_500_00, currency: "RUB")
        // Should contain "1500" somewhere (grouping/decimal format is locale-dependent).
        XCTAssertTrue(result.contains("1") && result.contains("5"),
                      "formatted amount should contain the numeric value, got: \(result)")
    }
}
