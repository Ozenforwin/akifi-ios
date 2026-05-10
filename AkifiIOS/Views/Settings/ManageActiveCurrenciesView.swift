import SwiftUI

/// Settings screen — lets the user pick which currencies appear in the
/// inline picker (`ActiveCurrencyPicker`) used by transaction, account,
/// budget and net-worth forms.
///
/// ## UX
/// Two sections plus a search bar:
///   1. **Active** — currencies the user has marked active. Tap to remove.
///      Drag-to-reorder via `.onMove`. The last remaining row is
///      protected (delete is disabled) so the inline picker is never
///      empty.
///   2. **All currencies** — every code in `CurrencyCatalog.all` that
///      isn't already active. Tap to add.
///
/// The search bar filters both sections via `CurrencyCatalog.search`
/// (matches code OR localized name). When the query is non-empty the
/// section headers stay so the user understands which list they're
/// modifying.
///
/// ## Source of truth
/// Reads + writes through `UserCurrencyPreferences.shared`. SwiftUI
/// re-renders automatically because `prefs.activeCodes` is `@Observable`.
struct ManageActiveCurrenciesView: View {
    /// The shared preferences instance. Re-read on every body evaluation
    /// thanks to `@Observable`'s tracking — no `@Bindable` needed.
    private let prefs = UserCurrencyPreferences.shared

    @State private var searchText: String = ""
    @State private var editMode: EditMode = .inactive
    @State private var showMinWarning: Bool = false

    // MARK: - Derived lists

    /// Active currencies in their current user-defined order, filtered by
    /// the search query.
    private var filteredActive: [Currency] {
        let active = prefs.activeCurrencies
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return active }
        let needle = q.lowercased()
        return active.filter {
            $0.code.lowercased().contains(needle)
                || $0.localizedName.lowercased().contains(needle)
        }
    }

    /// Inactive currencies — full catalog minus active codes — filtered
    /// by the search query. Sorted by code (catalog already is).
    private var filteredInactive: [Currency] {
        let activeSet = Set(prefs.activeCodes)
        let pool = searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? CurrencyCatalog.all
            : CurrencyCatalog.search(searchText)
        return pool.filter { !activeSet.contains($0.code) }
    }

    // MARK: - Body

    var body: some View {
        List {
            Section {
                Text(String(localized: "settings.activeCurrencies.subtitle"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !filteredActive.isEmpty {
                Section(String(localized: "settings.activeCurrencies.section.active")) {
                    ForEach(filteredActive) { currency in
                        activeRow(for: currency)
                    }
                    .onMove(perform: moveActive)
                    .onDelete(perform: deleteActive)
                }
            }

            if !filteredInactive.isEmpty {
                Section(String(localized: "settings.activeCurrencies.section.all")) {
                    ForEach(filteredInactive) { currency in
                        inactiveRow(for: currency)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: Text(String(localized: "currencyPicker.searchPlaceholder"))
        )
        .navigationTitle(String(localized: "settings.activeCurrencies.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Standard system EditButton enables drag-to-reorder + the
            // red minus on rows. Better than rolling our own toggle and
            // it picks up Dynamic Type / accessibility for free.
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
        .environment(\.editMode, $editMode)
        .alert(
            String(localized: "settings.activeCurrencies.minWarning"),
            isPresented: $showMinWarning
        ) {
            Button(String(localized: "common.ok"), role: .cancel) {}
        }
    }

    // MARK: - Rows

    /// Active row — single interpolated `Text` to stay consistent with
    /// the menu-row rule, plus a checkmark trailing icon. Tap removes
    /// from active (or shows the min-1 warning when there's only one).
    @ViewBuilder
    private func activeRow(for currency: Currency) -> some View {
        Button {
            attemptRemove(currency)
        } label: {
            HStack(spacing: 12) {
                Text("\(currency.symbol)  \(currency.code) — \(currency.localizedName)")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accent)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(currency.code), \(currency.localizedName)")
        .accessibilityHint(String(localized: "settings.activeCurrencies.section.active"))
    }

    /// Inactive row — tap adds to active. No checkmark; uses a `+`
    /// indicator so the affordance is clear.
    @ViewBuilder
    private func inactiveRow(for currency: Currency) -> some View {
        Button {
            prefs.add(currency.code)
        } label: {
            HStack(spacing: 12) {
                Text("\(currency.symbol)  \(currency.code) — \(currency.localizedName)")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Image(systemName: "plus.circle")
                    .foregroundStyle(.tertiary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(currency.code), \(currency.localizedName)")
    }

    // MARK: - Mutations

    /// Removes `currency` from active iff it's not the only one left.
    /// Otherwise surfaces the min-1 warning alert — silently ignoring
    /// the tap would feel like a broken UI.
    private func attemptRemove(_ currency: Currency) {
        if prefs.activeCodes.count <= 1 {
            showMinWarning = true
            return
        }
        prefs.remove(currency.code)
    }

    /// Bridge between `.onDelete(perform:)` and the prefs API.
    /// Indices are into `filteredActive`, which equals `activeCurrencies`
    /// when `searchText` is empty. We resolve the code by index against
    /// the filtered list so deletions remain correct under search.
    private func deleteActive(at offsets: IndexSet) {
        for idx in offsets {
            guard idx < filteredActive.count else { continue }
            attemptRemove(filteredActive[idx])
        }
    }

    /// Reorder via drag handles. Only reorders the FULL active list when
    /// the search field is empty — re-ordering a filtered subset would
    /// be ambiguous (where does the dragged row land in the unfiltered
    /// list?), so we no-op when `searchText` is non-empty.
    private func moveActive(from source: IndexSet, to destination: Int) {
        guard searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        var codes = prefs.activeCodes
        codes.move(fromOffsets: source, toOffset: destination)
        prefs.reorder(codes)
    }
}

#Preview {
    NavigationStack {
        ManageActiveCurrenciesView()
    }
}
