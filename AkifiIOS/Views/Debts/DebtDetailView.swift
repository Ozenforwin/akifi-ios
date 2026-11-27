import SwiftUI

/// One person: balance, the four actions, history of movements (the legs on
/// the debt account), close / reopen / delete.
struct DebtDetailView: View {
    let accountId: String

    @Environment(AppViewModel.self) private var appViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var activeAction: DebtAction?
    @State private var editingLeg: Transaction?
    @State private var showEditDetails = false
    @State private var showDeleteConfirm = false
    @State private var errorMessage: String?

    private var dataStore: DataStore { appViewModel.dataStore }
    private var debts: DebtsStore { appViewModel.debts }
    private var cm: CurrencyManager { appViewModel.currencyManager }

    var body: some View {
        Group {
            if let entry = debts.entry(accountId: accountId, dataStore: dataStore) {
                content(entry)
            } else {
                ContentUnavailableView(String(localized: "debts.notFound"), systemImage: "person.crop.circle.badge.questionmark")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func content(_ entry: DebtEntry) -> some View {
        let movements = DebtMath.movements(accountId: accountId, transactions: dataStore.transactions)
        List {
            Section {
                header(entry)
            }

            if entry.isOpen {
                Section {
                    actionGrid(entry)
                }
                if entry.balance == 0 && entry.hasDetails {
                    Section {
                        Button {
                            Task { await setClosed(true) }
                        } label: {
                            Label(String(localized: "debts.close"), systemImage: "checkmark.circle")
                        }
                    } footer: {
                        Text(String(localized: "debts.close.hint"))
                    }
                }
            }

            if !entry.hasDetails {
                Section {
                    Button {
                        showEditDetails = true
                    } label: {
                        Label(String(localized: "debts.details.missing"), systemImage: "square.and.pencil")
                    }
                }
            }

            Section(String(localized: "debts.history")) {
                if movements.isEmpty {
                    Text(String(localized: "debts.history.empty"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(movements) { leg in
                        Button {
                            editingLeg = leg
                        } label: {
                            DebtMovementRow(leg: leg, currency: entry.currency)
                        }
                        .foregroundStyle(.primary)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                Task { _ = await dataStore.deleteTransaction(leg) }
                            } label: {
                                Label(String(localized: "common.delete"), systemImage: "trash")
                            }
                        }
                    }
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(Color.expense)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(entry.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        showEditDetails = true
                    } label: {
                        Label(String(localized: "debts.editDetails"), systemImage: "pencil")
                    }
                    if entry.hasDetails {
                        Button {
                            Task { await setClosed(!entry.isClosed) }
                        } label: {
                            if entry.isClosed {
                                Label(String(localized: "debts.reopen"), systemImage: "arrow.uturn.backward")
                            } else {
                                Label(String(localized: "debts.close"), systemImage: "checkmark.circle")
                            }
                        }
                    }
                    Divider()
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label(String(localized: "debts.delete"), systemImage: "trash")
                    }
                } label: {
                    Label(String(localized: "common.more"), systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(item: $activeAction) { action in
            DebtMovementSheet(debtAccountId: accountId, action: action)
        }
        .sheet(item: $editingLeg) { leg in
            DebtMovementSheet(debtAccountId: accountId, editing: leg)
        }
        .sheet(isPresented: $showEditDetails) {
            DebtFormSheet(mode: .edit(entry))
        }
        .confirmationDialog(
            String(localized: "debts.delete.title"),
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(String(localized: "debts.delete"), role: .destructive) {
                Task { await deletePerson() }
            }
            if entry.isOpen && entry.hasDetails {
                Button(String(localized: "debts.close")) {
                    Task { await setClosed(true) }
                }
            }
        } message: {
            Text(String(localized: "debts.delete.message"))
        }
    }

    // MARK: - Header

    private func header(_ entry: DebtEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                DebtAvatar(name: entry.name, color: entry.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(DebtFormat.directionCaption(entry.direction))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(DebtFormat.amount(entry.balance, currency: entry.currency, cm: cm))
                        .font(.largeTitle)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .foregroundStyle(DebtFormat.color(entry.direction))
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                }
            }
            if entry.isOverdue {
                Label(String(localized: "debts.overdue"), systemImage: "exclamationmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.warning)
            }
            if let due = DebtFormat.dueDate(entry.dueDate) {
                Label(String(localized: "debts.dueDate.short \(due)"), systemImage: entry.remind ? "bell" : "calendar")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let contact = entry.contact {
                Label(contact, systemImage: "phone")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let note = entry.note {
                Text(note)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if entry.isClosed {
                Label(String(localized: "debts.closed"), systemImage: "archivebox")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Actions

    private func actionGrid(_ entry: DebtEntry) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(DebtAction.allCases) { action in
                Button {
                    activeAction = action
                } label: {
                    Label(action.title, systemImage: action.systemImage)
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .tint(action.movesIntoDebt ? Color.accent : Color.income)
            }
        }
        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
    }

    private func setClosed(_ closed: Bool) async {
        do {
            try await debts.setClosed(accountId: accountId, closed: closed, dataStore: dataStore)
            errorMessage = nil
        } catch {
            errorMessage = FormErrorMessage.text(for: error)
        }
    }

    private func deletePerson() async {
        do {
            try await debts.delete(accountId: accountId, dataStore: dataStore)
            dismiss()
        } catch {
            errorMessage = FormErrorMessage.text(for: error)
        }
    }
}

/// One movement of a debt: what happened, through which real account.
struct DebtMovementRow: View {
    let leg: Transaction
    let currency: String
    @Environment(AppViewModel.self) private var appViewModel

    var body: some View {
        let dataStore = appViewModel.dataStore
        let partner = dataStore.derivedCache.transactionIndex(for: dataStore).transferPartner(of: leg)
        let realAccount = dataStore.account(withId: partner?.accountId)
        let effect = DebtMath.signedEffect(leg)
        HStack(spacing: 12) {
            Image(systemName: effect >= 0 ? "arrow.up.right" : "arrow.down.left")
                .font(.body.weight(.semibold))
                .foregroundStyle(effect >= 0 ? Color.accent : Color.income)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(effect >= 0 ? String(localized: "debts.movement.toThem") : String(localized: "debts.movement.fromThem"))
                    .font(.body)
                HStack(spacing: 4) {
                    Text(leg.formattedDateTime)
                    if let realAccount {
                        Text("· \(realAccount.name)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text((effect >= 0 ? "+" : "−") + DebtFormat.amount(effect, currency: currency, cm: appViewModel.currencyManager))
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                if leg.status == "pending" {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .accessibilityLabel(String(localized: "tx.pendingSync"))
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
