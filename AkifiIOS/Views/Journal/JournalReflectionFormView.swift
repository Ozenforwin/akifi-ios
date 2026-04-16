import SwiftUI

struct JournalReflectionFormView: View {
    @Environment(AppViewModel.self) private var appViewModel
    let viewModel: JournalViewModel
    let dataStore: DataStore

    @Environment(\.dismiss) private var dismiss
    @State private var content = ""
    @State private var selectedMood: NoteMood?
    @State private var tags: [String] = ["reflection"]
    @State private var isSaving = false

    private var weekSummary: WeekSummary {
        computeWeekSummary()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    weekSummaryCard
                    promptsSection
                    moodSection
                    contentSection
                }
                .padding(16)
            }
            .navigationTitle(String(localized: "journal.weeklyReflection"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "action.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "action.save")) {
                        Task { await save() }
                    }
                    .disabled(content.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                    .fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: - Week Summary

    private var weekSummaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "journal.reflection.yourWeek"))
                .font(.headline)

            HStack(spacing: 20) {
                VStack(spacing: 4) {
                    Text(appViewModel.currencyManager.formatAmount(weekSummary.income.displayAmount))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.income)
                    Text(String(localized: "journal.reflection.income"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(spacing: 4) {
                    Text(appViewModel.currencyManager.formatAmount(weekSummary.expense.displayAmount))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.expense)
                    Text(String(localized: "journal.reflection.expense"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(spacing: 4) {
                    Text("\(weekSummary.transactionCount)")
                        .font(.subheadline.weight(.semibold))
                    Text(String(localized: "journal.reflection.transactions"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !weekSummary.topCategories.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "journal.reflection.topCategories"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(weekSummary.topCategories.prefix(3), id: \.name) { cat in
                        HStack {
                            Text(cat.name)
                                .font(.caption)
                            Spacer()
                            Text(appViewModel.currencyManager.formatAmount(cat.amount.displayAmount))
                                .font(.caption.weight(.medium))
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Prompts

    private var promptsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "journal.reflection.prompts"))
                .font(.headline)

            ForEach(prompts, id: \.self) { prompt in
                Button {
                    if !content.isEmpty { content += "\n\n" }
                    content += prompt + "\n"
                } label: {
                    HStack {
                        Image(systemName: "lightbulb")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Text(prompt)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                        Spacer()
                    }
                    .padding(10)
                    .background(Color(.tertiarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var prompts: [String] {
        [
            String(localized: "journal.reflection.prompt1"),
            String(localized: "journal.reflection.prompt2"),
            String(localized: "journal.reflection.prompt3"),
            String(localized: "journal.reflection.prompt4"),
        ]
    }

    // MARK: - Mood

    private var moodSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "journal.reflection.weekMood"))
                .font(.headline)
            HStack(spacing: 12) {
                ForEach(NoteMood.allCases, id: \.self) { mood in
                    Button {
                        selectedMood = selectedMood == mood ? nil : mood
                    } label: {
                        VStack(spacing: 4) {
                            Text(mood.emoji)
                                .font(.title2)
                            Text(mood.localizedName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(selectedMood == mood ? Color.accentColor.opacity(0.15) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Content

    private var contentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "journal.reflection.yourThoughts"))
                .font(.headline)
            TextEditor(text: $content)
                .frame(minHeight: 150)
                .padding(8)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if content.isEmpty {
                        Text(String(localized: "journal.reflection.placeholder"))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 16)
                            .padding(.leading, 12)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    // MARK: - Save

    private func save() async {
        isSaving = true
        let cal = Calendar.current
        let now = Date()
        let weekday = cal.component(.weekday, from: now)
        let daysToMonday = (weekday + 5) % 7
        let monday = cal.date(byAdding: .day, value: -daysToMonday, to: cal.startOfDay(for: now))!
        let sunday = cal.date(byAdding: .day, value: 6, to: monday)!
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"

        do {
            _ = try await viewModel.createNote(
                title: String(localized: "journal.reflection.weekTitle"),
                content: content,
                tags: tags,
                mood: selectedMood,
                noteType: .reflection,
                periodStart: df.string(from: monday),
                periodEnd: df.string(from: sunday)
            )
            dismiss()
        } catch {
            // handled by viewModel
        }
        isSaving = false
    }

    // MARK: - Week Summary

    struct WeekSummary {
        var income: Int64 = 0
        var expense: Int64 = 0
        var transactionCount: Int = 0
        var topCategories: [(name: String, amount: Int64)] = []
    }

    private func computeWeekSummary() -> WeekSummary {
        let cal = Calendar.current
        let now = Date()
        let weekday = cal.component(.weekday, from: now)
        let daysToMonday = (weekday + 5) % 7
        let monday = cal.date(byAdding: .day, value: -daysToMonday, to: cal.startOfDay(for: now))!
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let mondayStr = df.string(from: monday)

        var summary = WeekSummary()
        var categoryExpense: [String: Int64] = [:]

        for tx in dataStore.transactions {
            guard tx.date >= mondayStr else { continue }
            summary.transactionCount += 1
            switch tx.type {
            case .income: summary.income += tx.amount
            case .expense:
                summary.expense += tx.amount
                if tx.categoryId != nil, let cat = dataStore.category(for: tx) {
                    categoryExpense[cat.name, default: 0] += tx.amount
                }
            case .transfer: break
            }
        }

        summary.topCategories = categoryExpense
            .sorted { $0.value > $1.value }
            .map { (name: $0.key, amount: $0.value) }

        return summary
    }
}
