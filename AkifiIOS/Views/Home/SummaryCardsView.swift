import SwiftUI

struct SummaryCardsView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let transactions: [Transaction]
    let selectedAccount: Account?

    private struct TotalsKey: Equatable {
        let transactions: ArrayIdentity<Transaction>
        let token: UInt64
        let accountId: String?
        let monthStart: String
    }

    /// Month totals, recomputed only when the rows, FX context, account or
    /// month change — they were re-derived with 2 N date parses per render.
    @State private var memo = Memo<TotalsKey, (income: Int64, expense: Int64)>()

    /// Current-calendar-month income / expense, restricted to the account
    /// selected in the carousel when `accountId` is non-nil (the hero card
    /// shows that account, the cards beneath must agree with it).
    ///
    /// "In the current month" is a string comparison against the month's
    /// first day — exactly the old "parsed local midnight ≥ local month
    /// start" test, without a date parse per row.
    ///
    /// ADR-001: aggregate via `amountInBase` so VND/EUR/USD rows on
    /// differently-denominated accounts are FX-normalized into the base
    /// currency (summing raw amounts showed 76 000 ₫ as 76 000 ₽).
    static func monthTotals(
        _ transactions: [Transaction],
        accountId: String?,
        monthStart: String,
        amountInBase: (Transaction) -> Int64
    ) -> (income: Int64, expense: Int64) {
        var income: Int64 = 0
        var expense: Int64 = 0
        for tx in transactions {
            if let accountId, tx.accountId != accountId { continue }
            guard DayKey.isDay(tx.date), tx.date >= monthStart, !tx.isTransfer else { continue }
            switch tx.type {
            case .income: income += amountInBase(tx)
            case .expense: expense += amountInBase(tx)
            case .transfer: break
            }
        }
        return (income, expense)
    }

    var body: some View {
        let store = appViewModel.dataStore
        let key = TotalsKey(
            transactions: ArrayIdentity(transactions),
            token: store.txGenerationToken,
            accountId: selectedAccount?.id,
            monthStart: DayKey.month(Date()) + "-01"
        )
        let totals = memo.value(for: key) {
            Self.monthTotals(transactions, accountId: key.accountId, monthStart: key.monthStart) {
                store.amountInBase($0)
            }
        }
        let monthlyIncome = totals.income
        let monthlyExpense = totals.expense
        // Side by side; stacked from XXXL up, where two titles and amounts
        // no longer fit across the screen.
        let layout = dynamicTypeSize >= .xxxLarge
            ? AnyLayout(VStackLayout(spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        layout {
            SummaryCard(
                title: String(localized: "summary.monthlyIncome"),
                formattedAmount: "+\(appViewModel.currencyManager.formatAmount(monthlyIncome.displayAmount))",
                systemIcon: "arrow.up.right",
                iconColor: Color.income,
                amountColor: Color.income
            )

            SummaryCard(
                title: String(localized: "summary.monthlyExpense"),
                formattedAmount: "-\(appViewModel.currencyManager.formatAmount(monthlyExpense.displayAmount))",
                systemIcon: "arrow.down.left",
                iconColor: Color.expense,
                amountColor: Color.expense
            )
        }
        // Both cards as tall as the taller one.
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct SummaryCard: View {
    let title: String
    let formattedAmount: String
    let systemIcon: String
    let iconColor: Color
    let amountColor: Color

    @ScaledMetric(relativeTo: .caption) private var iconTileSize: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: systemIcon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: iconTileSize, height: iconTileSize)
                    .background(iconColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .accessibilityHidden(true)

                Text(title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    // Wrap instead of truncating inside the equal-height row.
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(verbatim: formattedAmount)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(amountColor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .akifiCard()
        .accessibilityElement(children: .combine)
    }
}
