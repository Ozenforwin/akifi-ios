import SwiftUI

/// Searchable sheet for linking a transaction to a journal entry.
/// Groups transactions by date (Today / Yesterday / "5 Apr 2026"), shows
/// amount + category + account; tap selects and dismisses.
struct TransactionPickerSheet: View {
    @Environment(AppViewModel.self) private var appViewModel
    @Environment(\.dismiss) private var dismiss

    let selectedId: String?
    let onSelect: (Transaction) -> Void

    @State private var searchText = ""

    private var dataStore: DataStore { appViewModel.dataStore }

    private var filtered: [Transaction] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let all = dataStore.transactions
            .filter { $0.type != .transfer }
            .sorted { $0.rawDateTime > $1.rawDateTime }
        guard !q.isEmpty else { return all }
        return all.filter { tx in
            if tx.description?.lowercased().contains(q) == true { return true }
            if tx.merchantName?.lowercased().contains(q) == true { return true }
            if let cat = dataStore.category(for: tx), cat.name.lowercased().contains(q) { return true }
            let amountString = appViewModel.currencyManager.formatAmount(tx.amount.displayAmount).lowercased()
            if amountString.contains(q) { return true }
            return false
        }
    }

    private var grouped: [(date: String, transactions: [Transaction])] {
        let dict = Dictionary(grouping: filtered) { $0.date }
        return dict
            .map { (date: $0.key, transactions: $0.value) }
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        NavigationStack {
            Group {
                if filtered.isEmpty {
                    empty
                } else {
                    list
                }
            }
            .navigationTitle(String(localized: "journal.linker.title"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: Text(String(localized: "journal.linker.searchPlaceholder"))
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "action.cancel")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var list: some View {
        List {
            ForEach(grouped, id: \.date) { group in
                Section(header: Text(sectionTitle(for: group.date))) {
                    ForEach(group.transactions) { tx in
                        Button {
                            onSelect(tx)
                            dismiss()
                        } label: {
                            row(tx)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func row(_ tx: Transaction) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill((tx.type == .income ? Color.income : Color.expense).opacity(0.12))
                    .frame(width: 32, height: 32)
                Image(systemName: tx.type == .income ? "arrow.down" : "arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tx.type == .income ? Color.income : Color.expense)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(titleFor(tx))
                    .font(.subheadline)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(tx.date).font(.caption).foregroundStyle(.secondary)
                    if let accountName = accountName(for: tx) {
                        Text("· \(accountName)")
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer()
            Text(appViewModel.currencyManager.formatAmount(tx.amount.displayAmount))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(tx.type == .income ? Color.income : Color.expense)

            if tx.id == selectedId {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accent)
            }
        }
        .contentShape(Rectangle())
    }

    private func titleFor(_ tx: Transaction) -> String {
        if let cat = dataStore.category(for: tx) { return cat.name }
        if let desc = tx.description, !desc.isEmpty { return desc }
        if let merchant = tx.merchantName { return merchant }
        return String(localized: "journal.linker.unnamed")
    }

    private func accountName(for tx: Transaction) -> String? {
        guard let id = tx.accountId,
              let account = dataStore.accounts.first(where: { $0.id == id }) else { return nil }
        return account.name
    }

    private func sectionTitle(for dateStr: String) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        guard let date = df.date(from: dateStr) else { return dateStr }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return String(localized: "date.today") }
        if cal.isDateInYesterday(date) { return String(localized: "date.yesterday") }
        let display = DateFormatter()
        display.dateStyle = .medium
        display.timeStyle = .none
        return display.string(from: date)
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(String(localized: "journal.linker.empty"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
