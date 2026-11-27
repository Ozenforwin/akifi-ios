import SwiftUI

/// Deposit detail — hero total, breakdown (principal / accrued), term
/// progress ring, conditions, contributions history, projected maturity,
/// and action buttons (contribute, early close).
struct DepositDetailView: View {
    private let initialDeposit: Deposit
    let viewModel: DepositsViewModel

    @Environment(AppViewModel.self) private var appViewModel
    @State private var showContributeSheet = false
    @State private var showCloseConfirmation = false
    /// A failed close shows here (V1) — it used to go to a view-model
    /// field no screen displayed.
    @State private var closeError: String?

    init(deposit: Deposit, viewModel: DepositsViewModel) {
        self.initialDeposit = deposit
        self.viewModel = viewModel
    }

    /// The live row. The copy the list pushed stays "active" after a close;
    /// reading it kept the close button on screen for a second payout.
    private var deposit: Deposit {
        viewModel.deposits.first { $0.id == initialDeposit.id } ?? initialDeposit
    }

    private var dataStore: DataStore { appViewModel.dataStore }
    private var depositAccount: Account? {
        dataStore.accounts.first { $0.id == deposit.accountId }
    }
    private var currency: CurrencyCode {
        depositAccount.map { Currency(code: $0.currency.uppercased()) ?? .rub } ?? .rub
    }
    private var contributions: [DepositContribution] {
        viewModel.contributionsByDeposit[deposit.id] ?? []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                heroCard
                breakdownCard
                termProgressCard
                conditionsCard
                contributionsSection
                if deposit.status == .active {
                    actionButtons
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .akifiFloatingButtonClearance()
        .navigationTitle(depositAccount?.name ?? String(localized: "deposit.item.title"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showContributeSheet) {
            if let acc = depositAccount {
                DepositContributeSheet(
                    deposit: deposit,
                    depositAccount: acc,
                    viewModel: viewModel
                )
            }
        }
        .alert(
            String(localized: "deposit.closeEarly.confirmTitle"),
            isPresented: $showCloseConfirmation
        ) {
            Button(String(localized: "common.cancel"), role: .cancel) {}
            Button(String(localized: "deposit.closeEarly"), role: .destructive) {
                Task { await closeEarly() }
            }
        } message: {
            Text(String(localized: "deposit.closeEarly.confirmMessage"))
        }
        .errorAlert($closeError)
    }

    // MARK: - Hero

    @ViewBuilder
    private var heroCard: some View {
        let total = viewModel.liveTotalValue(for: deposit)
        let tint = Color.budget

        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "deposit.detail.totalTitle"))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            Text(formatAmount(total))
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .minimumScaleFactor(0.55)
                .lineLimit(1)

            HStack(spacing: 8) {
                Text(deposit.status.localizedTitle)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(tint.opacity(0.16), in: Capsule())
                    .foregroundStyle(tint)
                Text(formatRate(deposit.interestRate))
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.income.opacity(0.16), in: Capsule())
                    .foregroundStyle(Color.income)
            }
        }
        .akifiCard()
    }

    // MARK: - Breakdown

    @ViewBuilder
    private var breakdownCard: some View {
        let principal = InterestCalculator.totalPrincipal(contributions)
        let accrued = viewModel.liveAccruedInterest(for: deposit)

        HStack(spacing: 12) {
            breakdownBox(
                title: String(localized: "deposit.detail.principal"),
                value: formatAmount(principal),
                color: Color.accent
            )
            breakdownBox(
                title: String(localized: "deposit.detail.accrued"),
                value: "+\(formatAmount(accrued))",
                color: Color.income
            )
        }
    }

    @ViewBuilder
    private func breakdownBox(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .foregroundStyle(color)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .akifiCard()
        .accessibilityElement(children: .combine)
    }

    // MARK: - Term progress

    @ViewBuilder
    private var termProgressCard: some View {
        let progress = termProgress()
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(String(localized: "deposit.detail.term"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let days = daysLeft() {
                    if days >= 0 {
                        Text(String(format: NSLocalizedString("deposit.daysLeft", comment: ""), days))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(String(localized: "deposit.overdue"))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.warning)
                    }
                } else {
                    Text(String(localized: "deposit.openEnded"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            ProgressView(value: progress)
                .tint(Color.budget)
                .accessibilityLabel(String(localized: "deposit.detail.term"))

            if let maturity = projectedMaturity() {
                HStack {
                    Text(String(localized: "deposit.detail.maturityValue"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(formatAmount(maturity))
                        .font(.footnote.weight(.semibold))
                        .monospacedDigit()
                }
            }
        }
        .akifiCard()
    }

    // MARK: - Conditions

    @ViewBuilder
    private var conditionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "deposit.detail.conditions"))
                .font(.subheadline.weight(.semibold))

            conditionRow(
                label: String(localized: "deposit.detail.rate"),
                value: formatRate(deposit.interestRate)
            )
            conditionRow(
                label: String(localized: "deposit.detail.compound"),
                value: deposit.compoundFrequency.localizedTitle
            )
            conditionRow(
                label: String(localized: "deposit.detail.startDate"),
                value: formatDateDisplay(deposit.startDate)
            )
            if let end = deposit.endDate {
                conditionRow(
                    label: String(localized: "deposit.detail.endDate"),
                    value: formatDateDisplay(end)
                )
            }
            if let returnId = deposit.returnToAccountId,
               let returnAcc = dataStore.accounts.first(where: { $0.id == returnId }) {
                conditionRow(
                    label: String(localized: "deposit.detail.returnTo"),
                    value: returnAcc.name
                )
            }

            Text(String(localized: "deposit.detail.rateImmutable"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .akifiCard()
    }

    @ViewBuilder
    private func conditionRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Contributions section

    @ViewBuilder
    private var contributionsSection: some View {
        if !contributions.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(String(localized: "deposit.detail.history"))
                    .font(.subheadline.weight(.semibold))

                ForEach(contributions) { contrib in
                    contributionRow(contrib)
                    if contrib.id != contributions.last?.id {
                        Divider()
                    }
                }
            }
            .akifiCard()
        }
    }

    @ViewBuilder
    private func contributionRow(_ contrib: DepositContribution) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(formatDateDisplay(contrib.contributedAt))
                    .font(.subheadline.weight(.medium))
                if let srcId = contrib.sourceAccountId,
                   let src = dataStore.accounts.first(where: { $0.id == srcId }) {
                    Text(src.name)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("+\(formatAmount(contrib.amount))")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.income)
                    .monospacedDigit()
                if let srcCurr = contrib.sourceCurrency, let srcAmt = contrib.sourceAmount {
                    let srcCode = Currency(code: srcCurr.uppercased()) ?? .rub
                    Text("~ \(formatAmountInCurrency(srcAmt, currency: srcCode))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Action buttons

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 10) {
            Button {
                showContributeSheet = true
            } label: {
                Label(String(localized: "deposit.contribute"), systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.akifiPrimary)

            Button(role: .destructive) {
                showCloseConfirmation = true
            } label: {
                Group {
                    if viewModel.isClosing(deposit) {
                        ProgressView()
                    } else {
                        Label(String(localized: "deposit.closeEarly"), systemImage: "xmark.seal")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.akifiSecondary)
        }
        .controlSize(.large)
        // No second close (or top-up) while a payout is being written.
        .disabled(viewModel.isClosing(deposit))
    }

    // MARK: - Helpers

    private func termProgress() -> CGFloat {
        guard let endStr = deposit.endDate,
              let end = DepositsViewModel.parseDate(endStr),
              let start = DepositsViewModel.parseDate(deposit.startDate) else {
            return 0
        }
        let cal = InterestCalculator.defaultCalendar
        let today = cal.startOfDay(for: Date())
        let total = end.timeIntervalSince(start)
        let elapsed = today.timeIntervalSince(start)
        guard total > 0 else { return 1 }
        return CGFloat(max(0, min(1, elapsed / total)))
    }

    private func daysLeft() -> Int? {
        guard let endStr = deposit.endDate,
              let end = DepositsViewModel.parseDate(endStr) else { return nil }
        let cal = InterestCalculator.defaultCalendar
        let today = cal.startOfDay(for: Date())
        return cal.dateComponents([.day], from: today, to: end).day
    }

    private func projectedMaturity() -> Int64? {
        viewModel.projectedMaturityValue(for: deposit)
    }

    private func closeEarly() async {
        guard let depositAcc = depositAccount else { return }
        let returnTo = dataStore.accounts.first { $0.id == deposit.returnToAccountId }
            ?? dataStore.accounts.first { $0.id != deposit.accountId }
        guard let returnTo else { return }
        do {
            try await viewModel.closeEarly(
                deposit,
                depositAccount: depositAcc,
                returnTo: returnTo,
                dataStore: dataStore
            )
        } catch {
            closeError = error.localizedDescription
        }
    }

    // MARK: - Formatting

    private func formatAmount(_ kopecks: Int64) -> String {
        formatAmountInCurrency(kopecks, currency: currency)
    }

    private func formatAmountInCurrency(_ kopecks: Int64, currency: CurrencyCode) -> String {
        let decimal = Decimal(kopecks) / 100
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = currency.decimals
        f.minimumFractionDigits = 0
        f.groupingSeparator = " "
        let formatted = f.string(from: decimal as NSDecimalNumber) ?? "0"
        return "\(formatted) \(currency.symbol)"
    }

    private func formatRate(_ rate: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = 0
        f.decimalSeparator = "."
        let s = f.string(from: rate as NSDecimalNumber) ?? "0"
        return "\(s)%"
    }

    private func formatDateDisplay(_ isoDate: String) -> String {
        guard let date = DepositsViewModel.parseDate(isoDate) else { return isoDate }
        return AppDateFormatters.displayDate.string(from: date)
    }
}
