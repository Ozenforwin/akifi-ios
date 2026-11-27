import SwiftUI

/// «Долги» — every person who owes me or whom I owe, one debt account each
/// (contract §A). System list, insetGrouped; content stays content.
struct DebtsListView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var showAddPerson = false
    @State private var showClosed = false

    private var dataStore: DataStore { appViewModel.dataStore }
    private var debts: DebtsStore { appViewModel.debts }
    private var cm: CurrencyManager { appViewModel.currencyManager }

    var body: some View {
        let entries = debts.entries(dataStore: dataStore)
        let open = entries.filter(\.isOpen)
        let closed = entries.filter(\.isClosed)
        let totals = DebtMath.totals(entries)

        List {
            if !totals.isEmpty {
                Section {
                    ForEach(totals, id: \.currency) { total in
                        DebtTotalsRow(total: total, showsCurrency: totals.count > 1)
                    }
                } footer: {
                    if debts.isOffline {
                        Label(String(localized: "debts.offline"), systemImage: "wifi.slash")
                    }
                }
            }

            if !open.isEmpty {
                Section(String(localized: "debts.section.open")) {
                    ForEach(open) { entry in
                        NavigationLink {
                            DebtDetailView(accountId: entry.accountId)
                        } label: {
                            DebtRow(entry: entry)
                        }
                    }
                }
            }

            if !closed.isEmpty {
                Section {
                    DisclosureGroup(isExpanded: $showClosed) {
                        ForEach(closed) { entry in
                            NavigationLink {
                                DebtDetailView(accountId: entry.accountId)
                            } label: {
                                DebtRow(entry: entry)
                            }
                        }
                    } label: {
                        Text(String(localized: "debts.section.closed \(closed.count)"))
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if entries.isEmpty && !debts.isLoading {
                ContentUnavailableView {
                    Label(String(localized: "debts.empty.title"), systemImage: "person.2")
                } description: {
                    Text(String(localized: "debts.empty.body"))
                } actions: {
                    Button(String(localized: "debts.addPerson")) { showAddPerson = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle(String(localized: "debts.title"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAddPerson = true
                } label: {
                    Label(String(localized: "debts.addPerson"), systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddPerson) {
            DebtFormSheet(mode: .create(initial: nil))
        }
        .task { await debts.refresh(dataStore: dataStore) }
        .refreshable {
            await dataStore.loadAll()
            await debts.refresh(dataStore: dataStore)
        }
    }
}

/// «Мне должны» / «Я должен» for one currency.
struct DebtTotalsRow: View {
    let total: DebtsSummary.Total
    let showsCurrency: Bool
    @Environment(AppViewModel.self) private var appViewModel

    var body: some View {
        let cm = appViewModel.currencyManager
        HStack(alignment: .top) {
            column(
                title: String(localized: "debts.totals.owedToMe"),
                value: DebtFormat.amount(total.owedToMe, currency: total.currency, cm: cm),
                color: total.owedToMe > 0 ? .income : .secondary
            )
            Spacer(minLength: 12)
            column(
                title: String(localized: "debts.totals.iOwe"),
                value: DebtFormat.amount(total.iOwe, currency: total.currency, cm: cm),
                color: total.iOwe > 0 ? .expense : .secondary
            )
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func column(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(showsCurrency ? "\(title) · \(total.currency)" : title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2)
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundStyle(color)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
    }
}

/// The «Долги» content card for Home (below the accounts) and Net Worth:
/// one line «мне должны / я должен» in the display currency. Plain grouped
/// content background, 20 pt continuous corners, no shadow (liquid-glass.md).
struct DebtsSummaryCard: View {
    @Environment(AppViewModel.self) private var appViewModel

    var body: some View {
        let dataStore = appViewModel.dataStore
        let cm = appViewModel.currencyManager
        let entries = appViewModel.debts.entries(dataStore: dataStore)
        let open = entries.filter(\.isOpen)
        let converted = DebtMath.convertedTotals(DebtMath.totals(entries), to: cm.selectedCurrency.code, rates: cm.rates)
        let overdue = open.filter(\.isOverdue).count

        HStack(spacing: 14) {
            Image(systemName: "person.2.fill")
                .font(.title3)
                .foregroundStyle(Color.warning)
                .frame(width: 44, height: 44)
                .background(Color.warning.opacity(0.14), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(String(localized: "debts.title"))
                        .font(.headline)
                        .foregroundStyle(.primary)
                    if overdue > 0 {
                        Text(String(localized: "debts.overdue.count \(overdue)"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.warning)
                    }
                }
                if open.isEmpty {
                    Text(String(localized: "debts.card.empty"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { owedText(converted.owedToMe, cm); oweText(converted.iOwe, cm) }
                        VStack(alignment: .leading, spacing: 2) { owedText(converted.owedToMe, cm); oweText(converted.iOwe, cm) }
                    }
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private func owedText(_ value: Int64, _ cm: CurrencyManager) -> some View {
        Text(String(localized: "debts.card.owedToMe \(cm.formatInCurrency(Decimal(value) / 100, currency: cm.selectedCurrency))"))
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(value > 0 ? Color.income : .secondary)
    }

    private func oweText(_ value: Int64, _ cm: CurrencyManager) -> some View {
        Text(String(localized: "debts.card.iOwe \(cm.formatInCurrency(Decimal(value) / 100, currency: cm.selectedCurrency))"))
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(value > 0 ? Color.expense : .secondary)
    }
}

/// Home entry point: the card, linking to the «Долги» screen. Refreshes the
/// summary whenever the store finishes a full load.
struct DebtsHomeEntry: View {
    @Environment(AppViewModel.self) private var appViewModel

    var body: some View {
        NavigationLink {
            DebtsListView()
        } label: {
            DebtsSummaryCard()
        }
        .buttonStyle(.plain)
        // Re-asks the server when a debt appears or disappears (the store's
        // load timestamps are not observable).
        .task(id: appViewModel.dataStore.debtAccounts.map(\.id)) {
            await appViewModel.debts.refresh(dataStore: appViewModel.dataStore)
        }
    }
}
