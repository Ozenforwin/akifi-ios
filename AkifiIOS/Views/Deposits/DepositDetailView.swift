import SwiftUI

/// Deposit detail — hero total, breakdown (principal / accrued), term
/// progress ring, conditions, contributions history, projected maturity,
/// and action buttons (contribute, early close).
struct DepositDetailView: View {
    let deposit: Deposit
    let viewModel: DepositsViewModel

    @Environment(AppViewModel.self) private var appViewModel
    @State private var showContributeSheet = false
    @State private var showCloseConfirmation = false

    private var dataStore: DataStore { appViewModel.dataStore }
    private var depositAccount: Account? {
        dataStore.accounts.first { $0.id == deposit.accountId }
    }
    private var currency: CurrencyCode {
        depositAccount.map { CurrencyCode(rawValue: $0.currency.uppercased()) ?? .rub } ?? .rub
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
            .padding(.bottom, 120)
        }
        .navigationTitle(depositAccount?.name ?? String(localized: "deposit.item.title"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showContributeSheet) {
            if let acc = depositAccount {
                DepositContributeSheet(
                    deposit: deposit,
                    depositAccount: acc,
                    viewModel: viewModel
                )
                .presentationBackground(.ultraThinMaterial)
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
    }

    // MARK: - Hero

    @ViewBuilder
    private var heroCard: some View {
        let total = viewModel.liveTotalValue(for: deposit)
        let tint = Color(hex: "#7C3AED")

        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "deposit.detail.totalTitle"))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            Text(formatAmount(total))
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .minimumScaleFactor(0.55)
                .lineLimit(1)

            HStack(spacing: 8) {
                Text(deposit.status.localizedTitle)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(tint.opacity(0.16))
                    .foregroundStyle(tint)
                    .clipShape(Capsule())
                Text(formatRate(deposit.interestRate))
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color(hex: "#16A34A").opacity(0.16))
                    .foregroundStyle(Color(hex: "#16A34A"))
                    .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.08), tint.opacity(0.18)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(tint.opacity(0.18), lineWidth: 0.5)
        )
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
                color: Color(hex: "#16A34A")
            )
        }
    }

    @ViewBuilder
    private func breakdownBox(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(color)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
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
                            .foregroundStyle(.orange)
                    }
                } else {
                    Text(String(localized: "deposit.openEnded"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            ZStack {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.08))
                            .frame(height: 8)
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [Color(hex: "#7C3AED"), Color(hex: "#A78BFA")],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(0, geo.size.width * progress), height: 8)
                    }
                }
                .frame(height: 8)
            }

            if let maturity = projectedMaturity() {
                HStack {
                    Text(String(localized: "deposit.detail.maturityValue"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(formatAmount(maturity))
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
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
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func conditionRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.weight(.medium))
                .monospacedDigit()
        }
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
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
        }
    }

    @ViewBuilder
    private func contributionRow(_ contrib: DepositContribution) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(formatDateDisplay(contrib.contributedAt))
                    .font(.caption.weight(.semibold))
                if let srcId = contrib.sourceAccountId,
                   let src = dataStore.accounts.first(where: { $0.id == srcId }) {
                    Text(src.name)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("+\(formatAmount(contrib.amount))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(hex: "#16A34A"))
                    .monospacedDigit()
                if let srcCurr = contrib.sourceCurrency, let srcAmt = contrib.sourceAmount {
                    let srcCode = CurrencyCode(rawValue: srcCurr.uppercased()) ?? .rub
                    Text("~ \(formatAmountInCurrency(srcAmt, currency: srcCode))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    // MARK: - Action buttons

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 10) {
            Button {
                showContributeSheet = true
            } label: {
                Label(String(localized: "deposit.contribute"), systemImage: "plus.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.accent.opacity(0.16))
                    .foregroundStyle(Color.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            Button {
                showCloseConfirmation = true
            } label: {
                Label(String(localized: "deposit.closeEarly"), systemImage: "xmark.seal.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.orange.opacity(0.16))
                    .foregroundStyle(.orange)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
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
            viewModel.errorMessage = error.localizedDescription
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
        let f = DateFormatter()
        f.dateStyle = .medium
        f.locale = Locale.current
        return f.string(from: date)
    }
}
