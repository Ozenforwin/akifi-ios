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
            // A sheet: an inset-grouped list, no card stack (design doc §3).
            List {
                Section {
                    header
                        .listRowBackground(Color.clear)
                }
                Section {
                    successCard
                }
                Section {
                    timeCard
                }
                if let desc = challenge.challengeDescription, !desc.isEmpty {
                    Section {
                        descriptionCard(desc)
                    }
                }
                Section {
                    actionButtons
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(challenge.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCloseButton { dismiss() }
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
        .presentationDetents([.medium, .large])
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            Text(challenge.type.icon)
                .font(.largeTitle)
                .padding(16)
                .background(statusColor.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            Text(challenge.type.localizedTitle)
                .font(.headline)
            Text(statusText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(statusColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(statusColor.opacity(0.12), in: Capsule())
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
            ProgressView(value: min(max(fraction, 0), 1))
                .tint(statusColor)
            progressDetail
        }
        .padding(.vertical, 4)
    }

    private var progressDetail: some View {
        HStack {
            Text(progressText)
                .font(.footnote)
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
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: min(max(timeProgress, 0), 1))
                .tint(Color.accent)
            HStack {
                // First and LAST day — `endDate` itself is exclusive.
                Text(displayDay(AppDateFormatters.day(challenge.startDate), fallback: challenge.startDate))
                    .font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Text(displayDay(challenge.lastDay, fallback: challenge.endDate))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func displayDay(_ date: Date?, fallback: String) -> String {
        date.map { AppDateFormatters.displayDate.string(from: $0) } ?? fallback
    }

    private func descriptionCard(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Actions

    /// A destructive row button, the way system sheets end (e.g. "Delete
    /// Event").
    @ViewBuilder
    private var actionButtons: some View {
        if challenge.status == .active {
            Button(String(localized: "challenge.abandon"), role: .destructive) {
                confirmAbandon = true
            }
            .frame(maxWidth: .infinity)
        } else {
            Button(String(localized: "common.delete"), role: .destructive) {
                confirmDelete = true
            }
            .frame(maxWidth: .infinity)
        }
    }
}
