import SwiftUI

struct TransactionSearchView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @Environment(\.dismiss) private var dismiss

    let transactions: [Transaction]
    let categories: [Category]

    @State private var query = ""
    @State private var history: [String] = []
    @FocusState private var isSearchFocused: Bool

    private static let historyKey = "searchHistory"
    private static let maxHistory = 20

    // MARK: - Computed

    private var results: [Transaction] {
        guard !query.isEmpty else { return [] }
        let q = query.lowercased()
        return transactions.filter { tx in
            tx.description?.lowercased().contains(q) == true ||
            tx.merchantName?.lowercased().contains(q) == true ||
            categoryName(for: tx)?.lowercased().contains(q) == true
        }
    }

    private var merchantSuggestions: [String] {
        var freq: [String: Int] = [:]
        for tx in transactions {
            if let m = tx.merchantName, !m.isEmpty {
                freq[m, default: 0] += 1
            }
        }
        return freq.sorted { $0.value > $1.value }
            .prefix(10)
            .map(\.key)
    }

    private var descriptionKeywords: [String] {
        var freq: [String: Int] = [:]
        for tx in transactions {
            guard let desc = tx.description, !desc.isEmpty else { continue }
            let words = desc.split(separator: " ")
                .map { $0.trimmingCharacters(in: .punctuationCharacters) }
                .filter { $0.count > 2 }
            for word in words {
                let lower = word.lowercased()
                freq[lower, default: 0] += 1
            }
        }
        let merchantSet = Set(merchantSuggestions.map { $0.lowercased() })
        return freq.sorted { $0.value > $1.value }
            .map(\.key)
            .filter { !merchantSet.contains($0) }
            .prefix(5)
            .map { $0 }
    }

    private var allSuggestions: [String] {
        merchantSuggestions + descriptionKeywords
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                    .padding(.horizontal)
                    .padding(.top, 8)

                if query.isEmpty {
                    emptyStateContent
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    resultsList
                }
            }
            .navigationTitle(String(localized: "search.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.close")) { dismiss() }
                }
            }
            .onAppear {
                loadHistory()
                isSearchFocused = true
            }
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(String(localized: "search.placeholder"), text: $query)
                .focused($isSearchFocused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .onSubmit { saveToHistory(query) }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Empty State (Suggestions + History)

    private var emptyStateContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // AI Suggestions
                if !allSuggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(localized: "search.suggestions"))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(allSuggestions, id: \.self) { suggestion in
                                    chipButton(suggestion) {
                                        query = suggestion
                                        saveToHistory(suggestion)
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }

                // Search History
                if !history.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(String(localized: "search.history"))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(String(localized: "search.clearHistory")) {
                                clearHistory()
                            }
                            .font(.caption)
                            .foregroundStyle(.red)
                        }
                        .padding(.horizontal)

                        ForEach(history, id: \.self) { item in
                            HStack {
                                Button {
                                    query = item
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "clock.arrow.circlepath")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text(item)
                                            .font(.subheadline)
                                            .foregroundStyle(.primary)
                                        Spacer()
                                    }
                                }
                                .buttonStyle(.plain)

                                Button { removeFromHistory(item) } label: {
                                    Image(systemName: "xmark")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 6)
                        }
                    }
                }
            }
            .padding(.top, 16)
        }
    }

    // MARK: - Results

    private var resultsList: some View {
        List {
            ForEach(results) { transaction in
                TransactionRowView(
                    transaction: transaction,
                    category: category(for: transaction)
                )
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.interactively)
        .onAppear { saveToHistory(query) }
    }

    // MARK: - Chip

    private func chipButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(.systemGray6))
                .foregroundStyle(.primary.opacity(0.7))
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color(.systemGray4), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func categoryName(for tx: Transaction) -> String? {
        guard let cid = tx.categoryId else { return nil }
        return categories.first { $0.id == cid }?.name
    }

    private func category(for tx: Transaction) -> Category? {
        guard let cid = tx.categoryId else { return nil }
        return categories.first { $0.id == cid }
    }

    // MARK: - History Persistence

    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: Self.historyKey),
              let items = try? JSONDecoder().decode([String].self, from: data) else { return }
        history = items
    }

    private func persistHistory() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: Self.historyKey)
        }
    }

    private func saveToHistory(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        history.removeAll { $0 == trimmed }
        history.insert(trimmed, at: 0)
        if history.count > Self.maxHistory {
            history = Array(history.prefix(Self.maxHistory))
        }
        persistHistory()
    }

    private func removeFromHistory(_ item: String) {
        history.removeAll { $0 == item }
        persistHistory()
    }

    private func clearHistory() {
        history.removeAll()
        persistHistory()
    }
}
