import Foundation
import UIKit
import SwiftUI

/// Generates a multi-page financial PDF report from DataStore snapshots.
///
/// Design goals:
/// - Clean, bank-statement grade layout with SF Pro system fonts.
/// - All text is selectable (rendered via `NSAttributedString.draw`, not as image).
/// - Supports arbitrary period (month / quarter / year / custom).
/// - Respects user locale (RU / EN / ES) via `String(localized:)`.
/// - Fully deterministic & client-side — no network.
///
/// Input expects already-filtered `transactions` for the selected period
/// so the caller (ReportsView) can apply account filter / period filter once.
/// `previousTransactions` is the same filter shifted back by one period, used
/// for MoM/QoQ/YoY delta calculations.
enum PDFReportGenerator {

    // MARK: - Input

    struct Input: Sendable {
        let title: String
        let periodLabel: String
        let generatedAt: Date
        let userName: String?
        let currencyCode: String
        let transactions: [Transaction]
        let previousTransactions: [Transaction]   // same period, one step back
        let categories: [Category]
        let accounts: [Account]
        let accountFilter: Account?               // nil = all accounts
        let budgets: [Budget]
        let subscriptions: [SubscriptionTracker]
    }

    // MARK: - Page geometry (A4 @ 72dpi)

    private static let pageSize = CGSize(width: 595.2, height: 841.8)   // A4 portrait
    private static let margin: CGFloat = 40
    private static var contentWidth: CGFloat { pageSize.width - margin * 2 }

    // MARK: - Colors

    private static let accent = UIColor(red: 0.28, green: 0.56, blue: 0.95, alpha: 1)    // blue
    private static let incomeColor = UIColor(red: 0.22, green: 0.70, blue: 0.44, alpha: 1)
    private static let expenseColor = UIColor(red: 0.93, green: 0.33, blue: 0.33, alpha: 1)
    private static let divider = UIColor(white: 0.85, alpha: 1)
    private static let secondary = UIColor(white: 0.45, alpha: 1)
    /// Primary text color on PDF paper. Intentionally NOT `primaryText`
    /// — that's a dynamic color which resolves to white in dark-mode trait
    /// collections and disappears against the always-white PDF background.
    /// Incident: 2026-04-19, all category names + amounts blanked out in
    /// a dark-mode user's exported PDF.
    private static let primaryText = UIColor(white: 0.0, alpha: 1)

    // MARK: - Public

    /// Render the report into a PDF file on disk. Returns the URL.
    /// Throws on I/O or rendering failure.
    static func generate(_ input: Input) throws -> URL {
        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(origin: .zero, size: pageSize),
            format: pdfFormat(for: input)
        )

        let filename = makeFilename(for: input)
        let url = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(filename)

        try renderer.writePDF(to: url) { ctx in
            var cursor = Cursor(y: margin)
            ctx.beginPage()
            cursor = drawHeader(input: input, cursor: cursor, ctx: ctx)
            cursor = drawSummary(input: input, cursor: cursor, ctx: ctx)
            cursor = drawCategoryBreakdown(input: input, cursor: cursor, ctx: ctx)
            cursor = drawTopTransactions(input: input, cursor: cursor, ctx: ctx)
            cursor = drawBudgets(input: input, cursor: cursor, ctx: ctx)
            cursor = drawSubscriptions(input: input, cursor: cursor, ctx: ctx)
            drawFooter(input: input, pageNumber: ctx.pdfContextBounds == .zero ? 1 : 1)
        }
        return url
    }

    // MARK: - Cursor helper (tracks y across potential page breaks)

    private struct Cursor {
        var y: CGFloat
    }

    // MARK: - PDF metadata

    private static func pdfFormat(for input: Input) -> UIGraphicsPDFRendererFormat {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: input.title,
            kCGPDFContextAuthor as String: "Akifi",
            kCGPDFContextCreator as String: "Akifi iOS"
        ]
        return format
    }

    private static func makeFilename(for input: Input) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let ds = df.string(from: input.generatedAt)
        let safePeriod = input.periodLabel
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        return "Akifi-Report-\(safePeriod)-\(ds).pdf"
    }

    // MARK: - Page-break safeguard

    /// Check if `needed` vertical space is available; if not, start a new page.
    @discardableResult
    private static func ensureSpace(
        _ needed: CGFloat,
        cursor: Cursor,
        ctx: UIGraphicsPDFRendererContext
    ) -> Cursor {
        if cursor.y + needed > pageSize.height - margin - 20 {
            ctx.beginPage()
            return Cursor(y: margin)
        }
        return cursor
    }

    // MARK: - Header

    private static func drawHeader(
        input: Input,
        cursor: Cursor,
        ctx: UIGraphicsPDFRendererContext
    ) -> Cursor {
        var c = cursor

        // Brand
        let brand = "Akifi"
        brand.draw(at: CGPoint(x: margin, y: c.y),
                   withAttributes: [
                    .font: UIFont.systemFont(ofSize: 24, weight: .heavy),
                    .foregroundColor: accent
                   ])

        // Generated date (right-aligned)
        let dateStr = generatedDateString(input.generatedAt)
        let dateSize = attributedSize(dateStr, font: .systemFont(ofSize: 10, weight: .regular))
        dateStr.draw(at: CGPoint(x: pageSize.width - margin - dateSize.width, y: c.y + 8),
                     withAttributes: [
                        .font: UIFont.systemFont(ofSize: 10, weight: .regular),
                        .foregroundColor: secondary
                     ])

        c.y += 36

        // Title
        input.title.draw(at: CGPoint(x: margin, y: c.y),
                         withAttributes: [
                            .font: UIFont.systemFont(ofSize: 20, weight: .bold),
                            .foregroundColor: primaryText
                         ])
        c.y += 26

        // Period & account
        var subtitle = input.periodLabel
        if let acc = input.accountFilter {
            subtitle += " · \(acc.name)"
        } else {
            subtitle += " · " + String(localized: "pdf.allAccounts")
        }
        if let name = input.userName, !name.isEmpty {
            subtitle += " · \(name)"
        }
        subtitle.draw(at: CGPoint(x: margin, y: c.y),
                      withAttributes: [
                        .font: UIFont.systemFont(ofSize: 12, weight: .regular),
                        .foregroundColor: secondary
                      ])
        c.y += 22

        drawHorizontalLine(at: c.y, ctx: ctx)
        c.y += 16
        return c
    }

    // MARK: - Summary

    private static func drawSummary(
        input: Input,
        cursor: Cursor,
        ctx: UIGraphicsPDFRendererContext
    ) -> Cursor {
        var c = ensureSpace(120, cursor: cursor, ctx: ctx)

        let income = totalIncome(input.transactions)
        let expense = totalExpense(input.transactions)
        let net = income - expense

        let prevIncome = totalIncome(input.previousTransactions)
        let prevExpense = totalExpense(input.previousTransactions)
        let prevNet = prevIncome - prevExpense

        drawSectionTitle(String(localized: "pdf.summary"), at: &c.y)

        // 3 tiles
        let tileWidth = (contentWidth - 24) / 3
        let tileHeight: CGFloat = 72
        drawStatTile(
            frame: CGRect(x: margin, y: c.y, width: tileWidth, height: tileHeight),
            label: String(localized: "pdf.income"),
            value: formatAmount(income, currency: input.currencyCode),
            delta: percentDelta(now: income, prev: prevIncome),
            color: incomeColor
        )
        drawStatTile(
            frame: CGRect(x: margin + tileWidth + 12, y: c.y, width: tileWidth, height: tileHeight),
            label: String(localized: "pdf.expense"),
            value: formatAmount(expense, currency: input.currencyCode),
            delta: percentDelta(now: expense, prev: prevExpense),
            color: expenseColor,
            invertDelta: true
        )
        drawStatTile(
            frame: CGRect(x: margin + (tileWidth + 12) * 2, y: c.y, width: tileWidth, height: tileHeight),
            label: String(localized: "pdf.net"),
            value: formatAmount(net, currency: input.currencyCode),
            delta: percentDelta(now: net, prev: prevNet),
            color: net >= 0 ? incomeColor : expenseColor
        )
        c.y += tileHeight + 8

        // Footnote under the three tiles clarifying what "Net" actually is.
        // Users saw "Остаток = -552k" and read it as "account balance" when
        // it's really the cash-flow delta for the period (excludes transfers
        // between own accounts).
        let footnote = String(localized: "pdf.summary.footnote")
        footnote.draw(
            at: CGPoint(x: margin, y: c.y),
            withAttributes: [
                .font: UIFont.systemFont(ofSize: 9, weight: .regular),
                .foregroundColor: secondary
            ]
        )
        c.y += 20
        return c
    }

    // MARK: - Category breakdown table

    private static func drawCategoryBreakdown(
        input: Input,
        cursor: Cursor,
        ctx: UIGraphicsPDFRendererContext
    ) -> Cursor {
        var c = ensureSpace(120, cursor: cursor, ctx: ctx)

        let expenses = input.transactions.filter { $0.type == .expense && !$0.isTransfer }
        guard !expenses.isEmpty else {
            return c
        }

        drawSectionTitle(String(localized: "pdf.expensesByCategory"), at: &c.y)

        let categoryById = Dictionary(uniqueKeysWithValues: input.categories.map { ($0.id, $0) })
        var totals: [(name: String, icon: String, amount: Int64, count: Int)] = []
        var byName: [String: (icon: String, amount: Int64, count: Int)] = [:]
        for tx in expenses {
            let cat = tx.categoryId.flatMap { categoryById[$0] }
            let name = cat?.name ?? String(localized: "transaction.noCategory")
            let icon = cat?.icon ?? "💰"
            var entry = byName[name] ?? (icon: icon, amount: 0, count: 0)
            entry.amount += tx.amountNative
            entry.count += 1
            byName[name] = entry
        }
        let grand = Int64(byName.values.reduce(Int64(0)) { $0 + $1.amount })
        totals = byName.map { (name: $0.key, icon: $0.value.icon, amount: $0.value.amount, count: $0.value.count) }
            .sorted { $0.amount > $1.amount }

        // Column widths
        let iconColW: CGFloat = 24
        let nameColW: CGFloat = contentWidth * 0.48
        let amountColW: CGFloat = contentWidth * 0.26
        // percent column is the remainder; right-edge aligned so explicit width not needed

        // Header row
        let headerAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: secondary
        ]
        String(localized: "pdf.col.category")
            .draw(at: CGPoint(x: margin + iconColW, y: c.y), withAttributes: headerAttrs)
        let amountHeader = String(localized: "pdf.col.amount")
        let amountHeaderW = attributedSize(amountHeader, font: .systemFont(ofSize: 10, weight: .semibold)).width
        amountHeader.draw(
            at: CGPoint(x: margin + iconColW + nameColW + amountColW - amountHeaderW, y: c.y),
            withAttributes: headerAttrs
        )
        let pctHeader = String(localized: "pdf.col.percent")
        let pctHeaderW = attributedSize(pctHeader, font: .systemFont(ofSize: 10, weight: .semibold)).width
        pctHeader.draw(
            at: CGPoint(x: margin + contentWidth - pctHeaderW, y: c.y),
            withAttributes: headerAttrs
        )
        c.y += 14
        drawHorizontalLine(at: c.y, ctx: ctx)
        c.y += 6

        let rowFont = UIFont.systemFont(ofSize: 11, weight: .regular)
        let rowBoldFont = UIFont.systemFont(ofSize: 11, weight: .semibold)

        for row in totals {
            c = ensureSpace(20, cursor: c, ctx: ctx)

            row.icon.draw(at: CGPoint(x: margin, y: c.y),
                          withAttributes: [.font: UIFont.systemFont(ofSize: 12)])
            row.name.draw(at: CGPoint(x: margin + iconColW, y: c.y + 1),
                          withAttributes: [.font: rowFont, .foregroundColor: primaryText])

            let amtStr = formatAmount(row.amount, currency: input.currencyCode)
            let amtW = attributedSize(amtStr, font: rowBoldFont).width
            amtStr.draw(
                at: CGPoint(x: margin + iconColW + nameColW + amountColW - amtW, y: c.y + 1),
                withAttributes: [.font: rowBoldFont, .foregroundColor: primaryText]
            )

            let pct = grand > 0 ? Double(row.amount) / Double(grand) * 100.0 : 0.0
            let pctStr = String(format: "%.1f%%", pct)
            let pctW = attributedSize(pctStr, font: rowFont).width
            pctStr.draw(
                at: CGPoint(x: margin + contentWidth - pctW, y: c.y + 1),
                withAttributes: [.font: rowFont, .foregroundColor: secondary]
            )

            c.y += 18
        }

        // Total row
        drawHorizontalLine(at: c.y, ctx: ctx)
        c.y += 6
        String(localized: "pdf.total").draw(
            at: CGPoint(x: margin + iconColW, y: c.y + 1),
            withAttributes: [.font: rowBoldFont, .foregroundColor: primaryText]
        )
        let totalStr = formatAmount(grand, currency: input.currencyCode)
        let totalW = attributedSize(totalStr, font: rowBoldFont).width
        totalStr.draw(
            at: CGPoint(x: margin + iconColW + nameColW + amountColW - totalW, y: c.y + 1),
            withAttributes: [.font: rowBoldFont, .foregroundColor: primaryText]
        )
        c.y += 26
        return c
    }

    // MARK: - Top transactions

    private static func drawTopTransactions(
        input: Input,
        cursor: Cursor,
        ctx: UIGraphicsPDFRendererContext
    ) -> Cursor {
        var c = ensureSpace(120, cursor: cursor, ctx: ctx)

        let top = input.transactions
            .filter { $0.type == .expense && !$0.isTransfer }
            .sorted { $0.amount > $1.amount }
            .prefix(10)
        guard !top.isEmpty else { return c }

        drawSectionTitle(String(localized: "pdf.topTransactions"), at: &c.y)

        let categoryById = Dictionary(uniqueKeysWithValues: input.categories.map { ($0.id, $0) })
        let accountById = Dictionary(uniqueKeysWithValues: input.accounts.map { ($0.id, $0) })
        let rowFont = UIFont.systemFont(ofSize: 10.5, weight: .regular)
        let boldFont = UIFont.systemFont(ofSize: 11, weight: .semibold)
        let secondaryFont = UIFont.systemFont(ofSize: 9, weight: .regular)

        for tx in top {
            c = ensureSpace(30, cursor: c, ctx: ctx)
            let cat = tx.categoryId.flatMap { categoryById[$0] }
            let rawDescr = (tx.description?.isEmpty == false ? tx.description : cat?.name) ?? "—"
            let descr: String = rawDescr
            let icon = cat?.icon ?? "💳"
            let account = tx.accountId.flatMap { accountById[$0]?.name } ?? ""
            let meta = [tx.date, account].filter { !$0.isEmpty }.joined(separator: " · ")

            "\(icon) \(descr)".draw(
                at: CGPoint(x: margin, y: c.y),
                withAttributes: [.font: rowFont, .foregroundColor: primaryText]
            )
            let amtStr = formatAmount(tx.amountNative, currency: input.currencyCode)
            let amtW = attributedSize(amtStr, font: boldFont).width
            amtStr.draw(
                at: CGPoint(x: margin + contentWidth - amtW, y: c.y),
                withAttributes: [.font: boldFont, .foregroundColor: expenseColor]
            )
            meta.draw(
                at: CGPoint(x: margin, y: c.y + 14),
                withAttributes: [.font: secondaryFont, .foregroundColor: secondary]
            )
            c.y += 30
        }

        c.y += 8
        return c
    }

    // MARK: - Budgets

    private static func drawBudgets(
        input: Input,
        cursor: Cursor,
        ctx: UIGraphicsPDFRendererContext
    ) -> Cursor {
        var c = cursor
        let active = input.budgets.filter { $0.isActive }
        guard !active.isEmpty else { return c }

        c = ensureSpace(90, cursor: c, ctx: ctx)
        drawSectionTitle(String(localized: "pdf.budgets"), at: &c.y)

        let rowFont = UIFont.systemFont(ofSize: 11, weight: .regular)
        let boldFont = UIFont.systemFont(ofSize: 11, weight: .semibold)

        for budget in active {
            c = ensureSpace(42, cursor: c, ctx: ctx)
            let metrics = BudgetMath.compute(
                budget: budget,
                transactions: input.transactions,
                subscriptions: input.subscriptions
            )

            let name = budget.name
            name.draw(at: CGPoint(x: margin, y: c.y),
                      withAttributes: [.font: boldFont, .foregroundColor: primaryText])

            let spent = formatAmount(metrics.spent, currency: input.currencyCode)
            let limit = formatAmount(metrics.effectiveLimit, currency: input.currencyCode)
            let spentStr = "\(spent) / \(limit)"
            let spentW = attributedSize(spentStr, font: rowFont).width
            spentStr.draw(
                at: CGPoint(x: margin + contentWidth - spentW, y: c.y),
                withAttributes: [.font: rowFont, .foregroundColor: secondary]
            )
            c.y += 18

            // Progress bar (utilization is Int percent, e.g. 75 = 75%)
            let barRect = CGRect(x: margin, y: c.y, width: contentWidth, height: 6)
            let bg = UIBezierPath(roundedRect: barRect, cornerRadius: 3)
            divider.setFill()
            bg.fill()

            let pctDouble = min(max(Double(metrics.utilization) / 100.0, 0), 1.0)
            let fillRect = CGRect(x: margin, y: c.y, width: contentWidth * CGFloat(pctDouble), height: 6)
            let fill = UIBezierPath(roundedRect: fillRect, cornerRadius: 3)
            let barColor: UIColor = metrics.utilization >= 100 ? expenseColor
                : (metrics.utilization >= 80 ? .systemOrange : incomeColor)
            barColor.setFill()
            fill.fill()
            c.y += 18
        }
        c.y += 10
        return c
    }

    // MARK: - Subscriptions

    private static func drawSubscriptions(
        input: Input,
        cursor: Cursor,
        ctx: UIGraphicsPDFRendererContext
    ) -> Cursor {
        var c = cursor
        let active = input.subscriptions.filter { $0.status == .active }
        guard !active.isEmpty else { return c }

        c = ensureSpace(80, cursor: c, ctx: ctx)
        drawSectionTitle(String(localized: "pdf.subscriptions"), at: &c.y)

        let rowFont = UIFont.systemFont(ofSize: 11, weight: .regular)
        let boldFont = UIFont.systemFont(ofSize: 11, weight: .semibold)

        var monthlyTotal: Int64 = 0
        for sub in active {
            c = ensureSpace(22, cursor: c, ctx: ctx)
            let monthly = BudgetMath.normalizedAmount(sub.amount, from: sub.billingPeriod, to: .monthly)
            monthlyTotal += monthly

            sub.serviceName.draw(
                at: CGPoint(x: margin, y: c.y),
                withAttributes: [.font: rowFont, .foregroundColor: primaryText]
            )
            let amt = formatAmount(monthly, currency: input.currencyCode) + "/" +
                String(localized: "pdf.month")
            let amtW = attributedSize(amt, font: boldFont).width
            amt.draw(
                at: CGPoint(x: margin + contentWidth - amtW, y: c.y),
                withAttributes: [.font: boldFont, .foregroundColor: primaryText]
            )
            c.y += 18
        }

        // Total row
        drawHorizontalLine(at: c.y, ctx: ctx)
        c.y += 6
        String(localized: "pdf.subscriptions.total")
            .draw(at: CGPoint(x: margin, y: c.y),
                  withAttributes: [.font: boldFont, .foregroundColor: primaryText])
        let total = formatAmount(monthlyTotal, currency: input.currencyCode) + "/" +
            String(localized: "pdf.month")
        let totalW = attributedSize(total, font: boldFont).width
        total.draw(
            at: CGPoint(x: margin + contentWidth - totalW, y: c.y),
            withAttributes: [.font: boldFont, .foregroundColor: primaryText]
        )
        c.y += 24
        return c
    }

    // MARK: - Footer (single-page variant for now)

    private static func drawFooter(input: Input, pageNumber: Int) {
        let footer = String(localized: "pdf.footer")
        let w = attributedSize(footer, font: .systemFont(ofSize: 8, weight: .regular)).width
        footer.draw(
            at: CGPoint(x: (pageSize.width - w) / 2, y: pageSize.height - margin + 4),
            withAttributes: [
                .font: UIFont.systemFont(ofSize: 8, weight: .regular),
                .foregroundColor: secondary
            ]
        )
    }

    // MARK: - Primitives

    private static func drawHorizontalLine(at y: CGFloat, ctx: UIGraphicsPDFRendererContext) {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: margin, y: y))
        path.addLine(to: CGPoint(x: pageSize.width - margin, y: y))
        divider.setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }

    private static func drawSectionTitle(_ title: String, at y: inout CGFloat) {
        title.draw(at: CGPoint(x: margin, y: y),
                   withAttributes: [
                    .font: UIFont.systemFont(ofSize: 14, weight: .bold),
                    .foregroundColor: primaryText
                   ])
        y += 22
    }

    private static func drawStatTile(
        frame: CGRect,
        label: String,
        value: String,
        delta: String?,
        color: UIColor,
        invertDelta: Bool = false
    ) {
        let path = UIBezierPath(roundedRect: frame, cornerRadius: 10)
        UIColor(white: 0.97, alpha: 1).setFill()
        path.fill()

        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: secondary
        ]
        label.draw(at: CGPoint(x: frame.minX + 12, y: frame.minY + 10), withAttributes: labelAttrs)

        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 17, weight: .bold),
            .foregroundColor: color
        ]
        value.draw(at: CGPoint(x: frame.minX + 12, y: frame.minY + 26), withAttributes: valueAttrs)

        if let delta {
            let positive = delta.hasPrefix("+")
            let good = invertDelta ? !positive : positive
            let deltaColor: UIColor = good ? incomeColor : expenseColor
            let deltaAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 9, weight: .semibold),
                .foregroundColor: deltaColor
            ]
            delta.draw(at: CGPoint(x: frame.minX + 12, y: frame.minY + 50), withAttributes: deltaAttrs)
        }
    }

    private static func attributedSize(_ string: String, font: UIFont) -> CGSize {
        (string as NSString).size(withAttributes: [.font: font])
    }

    // MARK: - Formatting helpers

    private static func totalIncome(_ txs: [Transaction]) -> Int64 {
        txs.filter { $0.type == .income && !$0.isTransfer }
            .reduce(Int64(0)) { $0 + $1.amount }
    }

    private static func totalExpense(_ txs: [Transaction]) -> Int64 {
        txs.filter { $0.type == .expense && !$0.isTransfer }
            .reduce(Int64(0)) { $0 + $1.amount }
    }

    private static func percentDelta(now: Int64, prev: Int64) -> String? {
        guard prev != 0 else {
            if now == 0 { return nil }
            return "+100%"
        }
        let delta = Double(now - prev) / Double(abs(prev)) * 100.0
        let rounded = Int(delta.rounded())
        if rounded == 0 { return "±0%" }
        let sign = rounded > 0 ? "+" : ""
        return "\(sign)\(rounded)%"
    }

    /// Format minor-unit (Int64 kopecks) to human-readable amount.
    /// Simpler than CurrencyManager (no rate conversion): assumes amount is
    /// already in target currency.
    nonisolated static func formatAmount(_ kopecks: Int64, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency.uppercased()
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 0
        formatter.groupingSeparator = " "
        let value = Double(kopecks) / 100.0
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f %@", value, currency)
    }

    private static func generatedDateString(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        df.locale = Locale.current
        return String(localized: "pdf.generatedAt") + " " + df.string(from: date)
    }
}
