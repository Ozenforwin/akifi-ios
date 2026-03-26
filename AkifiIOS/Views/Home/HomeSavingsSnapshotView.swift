import SwiftUI

struct HomeSavingsSnapshotView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var goals: [SavingsGoal] = []

    private let repo = SavingsGoalRepository()

    var body: some View {
        Group {
            if !goals.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Накопления")
                            .font(.headline)
                        Spacer()
                        NavigationLink {
                            SavingsGoalListView()
                        } label: {
                            Text("Все")
                                .font(.subheadline)
                                .foregroundStyle(.green)
                        }
                    }

                    ForEach(goals.prefix(3)) { goal in
                        HStack(spacing: 12) {
                            Text(goal.icon)
                                .font(.title3)
                                .frame(width: 32, height: 32)
                                .background(Color(hex: goal.color).opacity(0.15))
                                .clipShape(Circle())

                            VStack(alignment: .leading, spacing: 4) {
                                Text(goal.name)
                                    .font(.subheadline.weight(.medium))

                                GeometryReader { geo in
                                    let progress = goal.targetAmount > 0
                                        ? min(Double(goal.currentAmount) / Double(goal.targetAmount), 1.0)
                                        : 0
                                    ZStack(alignment: .leading) {
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(.quaternary)
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(Color(hex: goal.color).gradient)
                                            .frame(width: geo.size.width * progress)
                                    }
                                    .accessibilityLabel("Прогресс \(Int(progress * 100)) процентов")
                                }
                                .frame(height: 5)
                            }

                            Text(appViewModel.currencyManager.formatAmount(goal.currentAmount.displayAmount))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding()
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 20))
            }
        }
        .task {
            await loadGoals()
        }
    }

    private func loadGoals() async {
        goals = (try? await repo.fetchAll().filter { $0.status == .active }) ?? []
    }
}
