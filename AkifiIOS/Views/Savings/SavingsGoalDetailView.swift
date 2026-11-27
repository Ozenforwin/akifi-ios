import SwiftUI

struct SavingsGoalDetailView: View {
    @Environment(AppViewModel.self) private var appViewModel
    let goal: SavingsGoal
    let contributions: [SavingsContribution]
    let progress: Double
    let daysRemaining: Int?
    /// (amount kopecks, type, note, counter-account id — see
    /// `SavingsViewModel.accountLegs`). Throws (V7) — the sheet shows it.
    let onContribute: (Int64, ContributionType, String?, String?) async throws -> Void

    @State private var showContribution = false
    @ScaledMetric(relativeTo: .largeTitle) private var ringSize: CGFloat = 140

    var body: some View {
        List {
            // Progress ring + amounts
            Section {
                VStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .stroke(Color(hex: goal.color).opacity(0.2), lineWidth: 12)
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(Color(hex: goal.color), style: StrokeStyle(lineWidth: 12, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.spring(duration: 0.8), value: progress)

                        VStack(spacing: 4) {
                            Text(goal.icon)
                                .font(.largeTitle)
                            Text(verbatim: "\(Int(progress * 100))%")
                                .font(.title2.weight(.semibold))
                                .monospacedDigit()
                        }
                    }
                    .frame(width: ringSize, height: ringSize)
                    .accessibilityHidden(true)

                    Text(appViewModel.currencyManager.formatAmount(goal.currentAmount.displayAmount))
                        .font(.largeTitle.weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(String(localized: "savings.detail.ofTarget \(appViewModel.currencyManager.formatAmount(goal.targetAmount.displayAmount))"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()

                    if let days = daysRemaining, days > 0 {
                        Text(String(localized: "savings.detail.daysToDeadline \(days)"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        showContribution = true
                    } label: {
                        Label(String(localized: "savings.contribute"), systemImage: "plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.akifiPrimary)
                    .controlSize(.large)
                    .padding(.top, 8)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            }

            // Contributions history
            Section(String(localized: "savings.history")) {
                if contributions.isEmpty {
                    Text(String(localized: "savings.noHistory"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                } else {
                    ForEach(contributions) { contribution in
                        ContributionRowView(
                            contribution: contribution,
                            currencyManager: appViewModel.currencyManager
                        )
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .akifiFloatingButtonClearance()
        .navigationTitle(goal.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showContribution) {
            ContributionSheetView(goal: goal, onContribute: onContribute)
        }
    }
}

struct ContributionRowView: View {
    let contribution: SavingsContribution
    let currencyManager: CurrencyManager

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: contribution.type == .withdrawal ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                .foregroundStyle(contribution.type == .withdrawal ? Color.expense : Color.income)
                .font(.title3)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(contribution.type.historyTitle)
                if let note = contribution.note {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            let sign = contribution.type == .withdrawal ? "-" : "+"
            Text("\(sign)\(currencyManager.formatAmount(contribution.amount.displayAmount))")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(contribution.type == .withdrawal ? Color.expense : Color.income)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private extension ContributionType {
    /// Row title in the goal's history.
    var historyTitle: String {
        switch self {
        case .withdrawal: String(localized: "contribution.withdraw")
        case .interest: String(localized: "contribution.interest")
        case .contribution: String(localized: "contribution.deposit")
        }
    }
}
