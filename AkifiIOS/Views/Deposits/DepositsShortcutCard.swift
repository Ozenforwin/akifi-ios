import SwiftUI

/// Home-tab shortcut card that routes to `DepositListView`. Subtitle shows
/// the aggregate value across all active deposits (principal + live
/// accrued) in the user's display currency and, if any, the days to the
/// nearest maturity.
///
/// Visible only when the user has at least one deposit — hidden otherwise
/// to keep Home clean. The card loads its own deposits on appear (cheap
/// server round-trip; cached by DepositsViewModel in parent flows).
struct DepositsShortcutCard: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var deposits: [Deposit] = []
    @State private var contributionsByDeposit: [String: [DepositContribution]] = [:]
    @State private var hasLoaded = false

    private let depositRepo = DepositRepository()
    private let contributionRepo = DepositContributionRepository()

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: "#A78BFA"), Color(hex: "#7C3AED")],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 44, height: 44)
                Image(systemName: "percent")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "deposit.title"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitleText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .task {
            guard !hasLoaded else { return }
            hasLoaded = true
            await load()
        }
    }

    /// Computes a short subtitle summarizing the user's active deposits.
    /// - Single-currency (all deposits same ccy): "123 456 ₽ · 180 дней"
    /// - Mixed currencies: just the nearest maturity countdown.
    /// - No deposits yet: localized CTA.
    private var subtitleText: String {
        let active = deposits.filter { $0.status == .active }
        if active.isEmpty {
            return String(localized: "deposit.home.cta")
        }

        let totalPerCurrency = aggregateByCurrency(active)
        var parts: [String] = []
        if totalPerCurrency.count == 1, let (ccy, total) = totalPerCurrency.first {
            let code = CurrencyCode(rawValue: ccy.uppercased()) ?? .rub
            parts.append(formatKopecks(total, currency: code))
        } else if totalPerCurrency.count > 1 {
            // Multi-currency: show count only to avoid lying about a fake FX sum.
            parts.append(String(format: NSLocalizedString("deposit.countActive", comment: ""), active.count))
        }

        if let days = nearestDaysToMaturity(active) {
            if days >= 0 {
                parts.append(String(format: NSLocalizedString("deposit.daysLeft", comment: ""), days))
            } else {
                parts.append(String(localized: "deposit.overdue"))
            }
        }

        return parts.isEmpty ? String(localized: "deposit.home.cta") : parts.joined(separator: " · ")
    }

    private func aggregateByCurrency(_ active: [Deposit]) -> [String: Int64] {
        var result: [String: Int64] = [:]
        for deposit in active {
            let account = appViewModel.dataStore.accounts.first { $0.id == deposit.accountId }
            guard let ccy = account?.currency.uppercased() else { continue }
            let contributions = contributionsByDeposit[deposit.id] ?? []
            let total = InterestCalculator.totalPrincipal(contributions) + InterestCalculator.accrueInterest(
                contributions: contributions,
                rate: deposit.interestRate,
                frequency: deposit.compoundFrequency,
                asOf: Date()
            )
            result[ccy, default: 0] += total
        }
        return result
    }

    private func nearestDaysToMaturity(_ active: [Deposit]) -> Int? {
        let cal = InterestCalculator.defaultCalendar
        let today = cal.startOfDay(for: Date())
        var minDays: Int?
        for deposit in active {
            guard let endStr = deposit.endDate,
                  let end = DepositsViewModel.parseDate(endStr),
                  let days = cal.dateComponents([.day], from: today, to: end).day else {
                continue
            }
            if minDays == nil || days < (minDays ?? Int.max) {
                minDays = days
            }
        }
        return minDays
    }

    private func load() async {
        do {
            let fetched = try await depositRepo.fetchAll()
            await MainActor.run { self.deposits = fetched }
            // Fetch contributions for each in parallel.
            await withTaskGroup(of: (String, [DepositContribution]?).self) { group in
                for d in fetched where d.status == .active {
                    group.addTask { [contributionRepo] in
                        let list = try? await contributionRepo.fetchForDeposit(d.id)
                        return (d.id, list)
                    }
                }
                for await (depositId, list) in group {
                    if let list {
                        await MainActor.run {
                            self.contributionsByDeposit[depositId] = list
                        }
                    }
                }
            }
        } catch {
            AppLogger.data.warning("deposits shortcut load: \(error.localizedDescription)")
        }
    }

    private func formatKopecks(_ kopecks: Int64, currency: CurrencyCode) -> String {
        let decimal = Decimal(kopecks) / 100
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = currency.decimals
        f.minimumFractionDigits = 0
        f.groupingSeparator = " "
        let formatted = f.string(from: decimal as NSDecimalNumber) ?? "0"
        return "\(formatted) \(currency.symbol)"
    }
}
