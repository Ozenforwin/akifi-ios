import SwiftUI

struct HomeSavingsSnapshotView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var goals: [SavingsGoal] = []
    @ScaledMetric(relativeTo: .title3) private var iconSize: CGFloat = 32

    /// Static: a class instance stored on the view makes every value of the
    /// view compare unequal, so each Home pass re-rendered this card.
    private static let repo = SavingsGoalRepository()

    var body: some View {
        Group {
            if !goals.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(String(localized: "savings.title"))
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                        Spacer()
                        NavigationLink {
                            SavingsGoalListView()
                        } label: {
                            Text(String(localized: "common.all"))
                                .font(.subheadline)
                                .foregroundStyle(Color.accent)
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                        }
                    }

                    ForEach(goals.prefix(3)) { goal in
                        let progress = goal.targetAmount > 0
                            ? min(Double(goal.currentAmount) / Double(goal.targetAmount), 1.0)
                            : 0
                        HStack(spacing: 12) {
                            Text(goal.icon)
                                .font(.title3)
                                .frame(width: iconSize, height: iconSize)
                                .background(Color(hex: goal.color).opacity(0.15), in: Circle())

                            VStack(alignment: .leading, spacing: 6) {
                                Text(goal.name)
                                    .font(.subheadline.weight(.medium))

                                // System progress bar in the goal's colour
                                // (no gradient fill).
                                ProgressView(value: max(0, progress))
                                    .tint(Color(hex: goal.color))
                                    .accessibilityLabel(String(localized: "savings.progress.\(Int(progress * 100))"))
                            }

                            Text(appViewModel.currencyManager.formatAmount(goal.currentAmount.displayAmount))
                                .font(.caption.weight(.medium))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .akifiCard()
            }
        }
        .task {
            await loadGoals()
        }
    }

    private func loadGoals() async {
        goals = (try? await Self.repo.fetchAll().filter { $0.status == .active }) ?? []
    }
}
