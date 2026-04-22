import SwiftUI
import UniformTypeIdentifiers

/// PDF bank statement import. The parser (hosted on the Supabase edge
/// function `parse-bank-statement`) can already flag cross-statement
/// duplicates via `isDuplicate`; on top of that we run a second pass
/// locally that matches each candidate row against existing auto-transfer
/// legs (rows with `auto_transfer_group_id != nil`) on the target account.
/// Those rows were already created by `create_expense_with_auto_transfer`,
/// so importing the same debit from the bank PDF would double-count the
/// expense. Matched rows surface an amber "auto-transfer dup" badge and
/// start unselected by default.
struct BankImportView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var showFilePicker = false
    @State private var selectedAccountId: String?
    @State private var isParsing = false
    @State private var parseResult: ParseResult?
    @State private var selectedIndices: Set<Int> = []
    @State private var isImporting = false
    @State private var importResult: ImportResult?
    @State private var error: String?
    /// Indices inside `parseResult.transactions` that collided with an
    /// existing auto-transfer leg. Rendered as warning badges, excluded
    /// from the default selection.
    @State private var autoTransferDupIndices: Set<Int> = []

    private var dataStore: DataStore { appViewModel.dataStore }

    var body: some View {
        Group {
            if let result = importResult {
                importSuccessView(result)
            } else if let result = parseResult {
                previewView(result)
            } else if isParsing {
                parsingProgressView
            } else {
                selectFileView
            }
        }
        .navigationTitle(String(localized: "import.title"))
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    Task { await parseFile(url) }
                }
            case .failure(let err):
                error = err.localizedDescription
            }
        }
    }

    // MARK: - Select File

    private var selectFileView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "doc.text.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.accent)

            Text(String(localized: "import.instruction"))
                .font(.headline)
                .multilineTextAlignment(.center)

            Text(String(localized: "import.instructionDetail"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            // Account picker
            if !dataStore.accounts.isEmpty {
                Picker(String(localized: "common.account"), selection: $selectedAccountId) {
                    Text(String(localized: "import.autoDetect")).tag(nil as String?)
                    ForEach(dataStore.accounts) { acc in
                        Text("\(acc.icon) \(acc.name)").tag(acc.id as String?)
                    }
                }
                .pickerStyle(.menu)
                .padding(.horizontal, 40)
            }

            Spacer()

            Button {
                showFilePicker = true
            } label: {
                Label(String(localized: "import.selectPDF"), systemImage: "doc.badge.plus")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal)

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }
        }
        .padding(.bottom, 120)
    }

    // MARK: - Parsing Progress

    private var parsingProgressView: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView()
                .scaleEffect(1.5)
            Text(String(localized: "import.parsing"))
                .font(.headline)
            Text(String(localized: "import.parsingDetail"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - Preview

    private func previewView(_ result: ParseResult) -> some View {
        List {
            // Summary card
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    if let bank = result.bankName {
                        HStack {
                            Image(systemName: "building.columns.fill")
                                .foregroundStyle(.secondary)
                            Text(bank)
                                .font(.headline)
                        }
                    }
                    if let period = result.period {
                        Text(period)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 16) {
                        VStack(alignment: .leading) {
                            Text(String(localized: "common.income"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("+\(appViewModel.currencyManager.formatAmount(result.totalIncome))")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.income)
                        }
                        VStack(alignment: .leading) {
                            Text(String(localized: "common.expense"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("-\(appViewModel.currencyManager.formatAmount(result.totalExpense))")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.expense)
                        }
                    }

                    // Summary for the auto-transfer dedup pass. Surfaces only
                    // when we actually found collisions so the card stays
                    // compact for users who aren't paying shared-account
                    // expenses from the imported card.
                    if !autoTransferDupIndices.isEmpty {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Text(String(format: String(localized: "import.duplicate.summary"),
                                        autoTransferDupIndices.count))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 2)
                    }
                }
            }

            // Select all / none
            Section {
                HStack {
                    Button(String(localized: "import.selectAll")) {
                        selectedIndices = Set(0..<result.transactions.count)
                    }
                    Spacer()
                    Button(String(localized: "import.deselectAll")) {
                        selectedIndices.removeAll()
                    }
                }
                .font(.subheadline)
            }

            // Transactions
            Section(header: Text(String(localized: "import.transactions.\(result.transactions.count)"))) {
                ForEach(Array(result.transactions.enumerated()), id: \.offset) { index, tx in
                    Button {
                        if selectedIndices.contains(index) {
                            selectedIndices.remove(index)
                        } else {
                            selectedIndices.insert(index)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selectedIndices.contains(index) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedIndices.contains(index) ? Color.accent : .secondary)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(tx.description)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                Text(tx.date)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            VStack(alignment: .trailing, spacing: 2) {
                                Text(tx.type == "income" ? "+\(formatTxAmount(tx.amount))" : "-\(formatTxAmount(tx.amount))")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(tx.type == "income" ? Color.income : Color.expense)

                                if tx.isDuplicate {
                                    Text(String(localized: "import.duplicate"))
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundStyle(.orange)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.orange.opacity(0.12))
                                        .clipShape(Capsule())
                                } else if autoTransferDupIndices.contains(index) {
                                    // Narrower match set than `isDuplicate`:
                                    // specifically "already backed by an auto-
                                    // transfer" so the user understands why
                                    // the row is unselected by default.
                                    Text(String(localized: "import.duplicate.badge"))
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundStyle(.orange)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.orange.opacity(0.12))
                                        .clipShape(Capsule())
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            // Import button
            Section {
                Button {
                    Task { await importSelected(result) }
                } label: {
                    HStack {
                        Spacer()
                        if isImporting {
                            ProgressView()
                        } else {
                            Text(String(localized: "import.importCount.\(selectedIndices.count)"))
                                .font(.headline)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
                .disabled(selectedIndices.isEmpty || isImporting)
            }

            Color.clear.frame(height: 100)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
    }

    // MARK: - Success

    private func importSuccessView(_ result: ImportResult) -> some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)

            Text(String(localized: "import.success"))
                .font(.title2.weight(.bold))

            VStack(spacing: 8) {
                Text(String(localized: "import.imported.\(result.imported)"))
                    .font(.subheadline)
                if result.skipped > 0 {
                    Text(String(localized: "import.skipped.\(result.skipped)"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Text(String(localized: "common.done"))
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal)
            .padding(.bottom, 120)
        }
    }

    // MARK: - Logic

    private func parseFile(_ url: URL) async {
        guard url.startAccessingSecurityScopedResource() else {
            error = String(localized: "import.accessError")
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        guard let data = try? Data(contentsOf: url) else {
            error = String(localized: "import.readError")
            return
        }

        isParsing = true
        error = nil

        do {
            let session = try await SupabaseManager.shared.currentSession()

            let boundary = UUID().uuidString
            var body = Data()
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"file\"; filename=\"statement.pdf\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: application/pdf\r\n\r\n".data(using: .utf8)!)
            body.append(data)
            body.append("\r\n".data(using: .utf8)!)
            if let accountId = selectedAccountId {
                body.append("--\(boundary)\r\n".data(using: .utf8)!)
                body.append("Content-Disposition: form-data; name=\"accountId\"\r\n\r\n".data(using: .utf8)!)
                body.append(accountId.data(using: .utf8)!)
                body.append("\r\n".data(using: .utf8)!)
            }
            body.append("--\(boundary)--\r\n".data(using: .utf8)!)

            let reqURL = URL(string: "\(AppConstants.supabaseURL)/functions/v1/parse-bank-statement")!
            var request = URLRequest(url: reqURL)
            request.httpMethod = "POST"
            request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(AppConstants.supabaseAnonKey, forHTTPHeaderField: "apikey")
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            request.timeoutInterval = 60

            let (responseData, _) = try await URLSession.shared.data(for: request)
            let response = try JSONDecoder().decode(ParseStatementResponse.self, from: responseData)

            guard response.ok else {
                self.error = response.error ?? "Parse failed"
                isParsing = false
                return
            }

            guard let txs = response.transactions, !txs.isEmpty else {
                self.error = String(localized: "import.noTransactions")
                isParsing = false
                return
            }

            let info = response.statementInfo
            let periodStr: String? = {
                guard let start = info?.periodStart, let end = info?.periodEnd else { return nil }
                return "\(start) – \(end)"
            }()

            parseResult = ParseResult(
                bankName: info?.bankName,
                period: periodStr,
                totalIncome: Decimal(info?.totalIncome ?? 0),
                totalExpense: Decimal(info?.totalExpense ?? 0),
                transactions: txs
            )

            // Second-pass duplicate detection against local auto-transfer legs.
            // The backend parser already flags within-statement dups via
            // `isDuplicate`; we additionally flag rows that match an existing
            // row in `dataStore.transactions` whose `auto_transfer_group_id`
            // is set — those are legs that an auto-transfer wrote to the
            // user's personal account, and re-importing them from the bank
            // PDF would double-count the expense on the settlement side.
            let targetAccountId = selectedAccountId ?? dataStore.accounts.first(where: { $0.isPrimary })?.id
            autoTransferDupIndices = computeAutoTransferDupIndices(
                txs: txs,
                targetAccountId: targetAccountId
            )
            // Pre-select: skip statement-level dups AND auto-transfer legs.
            selectedIndices = Set(
                (0..<txs.count).filter { idx in
                    !txs[idx].isDuplicate && !autoTransferDupIndices.contains(idx)
                }
            )
        } catch {
            self.error = error.localizedDescription
        }

        isParsing = false
    }

    /// Computes the set of indices inside `txs` that match an existing
    /// auto-transfer leg in `dataStore.transactions`. Matching rule:
    /// - same target account id (`accountId == targetAccountId`),
    /// - `|amount - txAmount| <= 1 kopeck` (tolerance for rounding drift
    ///   when banks publish cents but we store kopecks),
    /// - `|date - txDate| <= 1 day`.
    /// Works on absolute kopeck amounts; the parser publishes amounts in
    /// major-currency units so we compare via a shared kopeck scale.
    private func computeAutoTransferDupIndices(
        txs: [ParsedTransaction],
        targetAccountId: String?
    ) -> Set<Int> {
        guard let targetAccountId else { return [] }
        let autoTransferLegs = dataStore.transactions.filter {
            $0.accountId == targetAccountId && $0.autoTransferGroupId != nil
        }
        guard !autoTransferLegs.isEmpty else { return [] }

        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.dateFormat = "yyyy-MM-dd"

        var matched: Set<Int> = []
        let oneDay: TimeInterval = 86_400
        for (idx, parsed) in txs.enumerated() {
            guard let parsedDate = parser.date(from: String(parsed.date.prefix(10))) else { continue }
            // Parser amount is in major units (rubles). Convert to kopecks
            // for a unit-consistent comparison with `Transaction.amountNative`.
            let parsedKopecks = Int64((parsed.amount * 100).rounded())
            for leg in autoTransferLegs {
                let legDateStr = String((leg.rawDateTime.isEmpty ? leg.date : leg.rawDateTime).prefix(10))
                guard let legDate = parser.date(from: legDateStr) else { continue }
                if abs(legDate.timeIntervalSince(parsedDate)) <= oneDay,
                   abs(leg.amountNative - parsedKopecks) <= 1 {
                    matched.insert(idx)
                    break
                }
            }
        }
        return matched
    }

    private func importSelected(_ result: ParseResult) async {
        isImporting = true
        error = nil

        let txToImport = selectedIndices.sorted().compactMap { idx -> ParsedTransaction? in
            guard idx < result.transactions.count else { return nil }
            return result.transactions[idx]
        }

        do {
            let txRepo = TransactionRepository()
            let userId = try await txRepo.currentUserId()
            var imported = 0

            // ADR-001: bank statements come pre-denominated in the account's
            // currency (the bank can't send a RUB statement for a USD card),
            // so `amount == amount_native` and `currency = account.currency`.
            // No `foreign_*` because there's no user-entry-currency mismatch.
            let targetAccountId = selectedAccountId ?? dataStore.accounts.first(where: { $0.isPrimary })?.id
            let targetAccountCurrency = dataStore.accounts
                .first(where: { $0.id == targetAccountId })?
                .currency
                .uppercased()

            for tx in txToImport {
                let input = CreateTransactionInput(
                    user_id: userId,
                    account_id: targetAccountId,
                    amount: Decimal(tx.amount),
                    amount_native: Decimal(tx.amount),
                    currency: targetAccountCurrency,
                    type: tx.type == "income" ? "income" : "expense",
                    date: tx.date,
                    description: tx.description,
                    category_id: tx.categoryId,
                    merchant_name: tx.merchantName
                )
                _ = try await txRepo.create(input)
                imported += 1
            }

            await appViewModel.dataStore.loadAll()
            AnalyticsService.logImportStatement()
            importResult = ImportResult(imported: imported, skipped: result.transactions.count - imported)
        } catch {
            self.error = error.localizedDescription
        }

        isImporting = false
    }

    private func formatTxAmount(_ amount: Double) -> String {
        appViewModel.currencyManager.formatAmount(Decimal(amount))
    }
}

// MARK: - Models

// Matches backend response: { ok, transactions[], statement_info {} }
struct ParseStatementResponse: Decodable {
    let ok: Bool
    let error: String?
    let transactions: [ParsedTransaction]?
    let statementInfo: StatementInfo?

    enum CodingKeys: String, CodingKey {
        case ok, error, transactions
        case statementInfo = "statement_info"
    }
}

struct StatementInfo: Decodable {
    let bankName: String?
    let periodStart: String?
    let periodEnd: String?
    let totalTransactions: Int?
    let totalIncome: Double?
    let totalExpense: Double?

    enum CodingKeys: String, CodingKey {
        case bankName = "bank_name"
        case periodStart = "period_start"
        case periodEnd = "period_end"
        case totalTransactions = "total_transactions"
        case totalIncome = "total_income"
        case totalExpense = "total_expense"
    }
}

struct ParseResult {
    let bankName: String?
    let period: String?
    let totalIncome: Decimal
    let totalExpense: Decimal
    let transactions: [ParsedTransaction]
}

struct ParsedTransaction: Decodable {
    let date: String
    let amount: Double
    let description: String
    let type: String
    let categoryHint: String?
    let categoryId: String?
    let merchantName: String?
    let isDuplicate: Bool

    enum CodingKeys: String, CodingKey {
        case date, amount, description, type
        case categoryHint = "category_hint"
        case categoryId = "category_id"
        case merchantName = "merchant_name"
        case isDuplicate = "is_duplicate"
    }
}

struct ImportResult {
    let imported: Int
    let skipped: Int
}
