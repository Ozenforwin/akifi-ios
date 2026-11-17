import SwiftUI

struct SummaryCardsView: View {
    @Environment(AppViewModel.self) private var appViewModel
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
        HStack(spacing: 8) {
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
    }
}

struct SummaryCard: View {
    let title: String
    let formattedAmount: String
    let systemIcon: String
    let iconColor: Color
    let amountColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                // Icon in colored square (matches HTML design)
                Image(systemName: systemIcon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 24, height: 24)
                    .background(iconColor.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Text(formattedAmount)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(amountColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.2), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 2)
    }
}
