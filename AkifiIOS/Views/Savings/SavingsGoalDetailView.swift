import SwiftUI

struct SavingsGoalDetailView: View {
    @Environment(AppViewModel.self) private var appViewModel
    let goal: SavingsGoal
    let contributions: [SavingsContribution]
    let progress: Double
    let daysRemaining: Int?
    let onContribute: (Int64, ContributionType, String?) async -> Void

    @State private var showContribution = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Progress Circle
                VStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .stroke(.quaternary, lineWidth: 12)
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(Color(hex: goal.color).gradient, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.spring(duration: 0.8), value: progress)

                        VStack(spacing: 4) {
                            Text(goal.icon)
                                .font(.system(size: 36))
                            Text("\(Int(progress * 100))%")
                                .font(.title2.weight(.bold))
                        }
                    }
                    .frame(width: 140, height: 140)

                    Text(appViewModel.currencyManager.formatAmount(goal.currentAmount.displayAmount))
                        .font(.title.weight(.bold))
                    Text("из \(appViewModel.currencyManager.formatAmount(goal.targetAmount.displayAmount))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if let days = daysRemaining, days > 0 {
                        Text("\(days) дн. до дедлайна")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                    }
                }
                .padding(.top)

                // Action button
                Button {
                    showContribution = true
                } label: {
                    Label("Пополнить", systemImage: "plus.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.green.gradient)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .padding(.horizontal)

                // Contributions history
                VStack(alignment: .leading, spacing: 12) {
                    Text("История операций")
                        .font(.headline)
                        .padding(.horizontal)

                    if contributions.isEmpty {
                        Text("Пока нет операций")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    } else {
                        ForEach(contributions) { contribution in
                            ContributionRowView(
                                contribution: contribution,
                                currencyManager: appViewModel.currencyManager
                            )
                        }
                    }
                }
                .padding()
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .padding(.horizontal)
            }
        }
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
                .foregroundStyle(contribution.type == .withdrawal ? .red : .green)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(contribution.type == .withdrawal ? "Снятие" : contribution.type == .interest ? "Проценты" : "Пополнение")
                    .font(.subheadline.weight(.medium))
                if let note = contribution.note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            let sign = contribution.type == .withdrawal ? "-" : "+"
            Text("\(sign)\(currencyManager.formatAmount(contribution.amount.displayAmount))")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(contribution.type == .withdrawal ? .red : .green)
        }
        .padding(.vertical, 4)
    }
}
