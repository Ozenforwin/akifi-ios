import SwiftUI

struct ChallengeDetailView: View {
    let challenge: SavingsChallenge
    let onAbandon: () -> Void
    let onDelete: () -> Void

    @Environment(AppViewModel.self) private var appViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmAbandon = false
    @State private var confirmDelete = false

    private var cm: CurrencyManager { appViewModel.currencyManager }

    private var fraction: Double { challenge.successFraction }
    private var timeProgress: Double { challenge.timeProgress }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    header
                    successCard
                    timeCard
                    if let desc = challenge.challengeDescription, !desc.isEmpty {
                        descriptionCard(desc)
                    }
                    actionButtons
                    Color.clear.frame(height: 40)
                }
                .padding(.horizontal)
                .padding(.top, 20)
            }
            .navigationTitle(challenge.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.close")) { dismiss() }
                }
            }
            .confirmationDialog(String(localized: "challenge.confirmAbandon"),
                                isPresented: $confirmAbandon,
                                titleVisibility: .visible) {
                Button(String(localized: "challenge.abandon"), role: .destructive) {
                    onAbandon()
                }
                Button(String(localized: "common.cancel"), role: .cancel) {}
            }
            .confirmationDialog(String(localized: "challenge.confirmDelete"),
                                isPresented: $confirmDelete,
                                titleVisibility: .visible) {
                Button(String(localized: "common.delete"), role: .destructive) {
                    onDelete()
                }
                Button(String(localized: "common.cancel"), role: .cancel) {}
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            Text(challenge.type.icon)
                .font(.system(size: 52))
                .padding(12)
                .background(Color.accent.opacity(0.12))
                .clipShape(Circle())
            Text(challenge.type.localizedTitle)
                .font(.headline)
            Text(statusText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(statusColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(statusColor.opacity(0.12))
                .clipShape(Capsule())
        }
        .frame(maxWidth: .infinity)
    }

    private var statusText: String {
        switch challenge.status {
        case .active: return String(localized: "challenges.active")
        case .completed: return String(localized: "challenges.completed")
        case .abandoned: return String(localized: "challenges.abandoned")
        }
    }

    private var statusColor: Color {
        switch challenge.status {
        case .active: Color.accent
        case .completed: Color.income
        case .abandoned: Color.secondary
        }
    }

    // MARK: - Success card

    private var successCard: some View {
        VStack(spacing: 12) {
            HStack {
                Text(String(localized: "challenge.progressTitle"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(Int(fraction * 100)) %")
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(statusColor)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(.systemGray5))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(statusColor)
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 8)
            progressDetail
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var progressDetail: some View {
        HStack {
            Text(progressText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
        }
    }

    private var progressText: String {
        switch challenge.type {
        case .noCafe:
            return challenge.progressAmount == 0
                ? String(localized: "challenge.progress.clean")
                : String(format: String(localized: "challenge.progress.spent"),
                         cm.formatAmount(challenge.progressAmount.displayAmount))
        case .categoryLimit:
            let spent = cm.formatAmount(challenge.progressAmount.displayAmount)
            let target = cm.formatAmount((challenge.targetAmount ?? 0).displayAmount)
            return "\(spent) / \(target)"
        case .weeklyAmount, .roundUp:
            let saved = cm.formatAmount(challenge.progressAmount.displayAmount)
            if let t = challenge.targetAmount {
                return "\(saved) / \(cm.formatAmount(t.displayAmount))"
            }
            return saved
        }
    }

    // MARK: - Time card

    private var timeCard: some View {
        VStack(spacing: 12) {
            HStack {
                Text(String(localized: "challenge.timeTitle"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(challenge.daysRemaining)")
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(.primary)
                Text(String(localized: "challenge.daysLeft"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(.systemGray5))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.accent.opacity(0.6))
                        .frame(width: geo.size.width * timeProgress)
                }
            }
            .frame(height: 8)
            HStack {
                Text(challenge.startDate).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(challenge.endDate).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func descriptionCard(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionButtons: some View {
        VStack(spacing: 10) {
            if challenge.status == .active {
                Button(role: .destructive) {
                    confirmAbandon = true
                } label: {
                    Text(String(localized: "challenge.abandon"))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.expense.opacity(0.12))
                        .foregroundStyle(Color.expense)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            } else {
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Text(String(localized: "common.delete"))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.expense.opacity(0.12))
                        .foregroundStyle(Color.expense)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
        }
    }
}
