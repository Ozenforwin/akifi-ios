import SwiftUI
import UniformTypeIdentifiers

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
        .padding(.bottom, 40)
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

            Color.clear.frame(height: 80)
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
            .padding(.bottom, 40)
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
            let supabase = SupabaseManager.shared.client
            let session = try await supabase.auth.session

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
            let result = try JSONDecoder().decode(ParseStatementResponse.self, from: responseData)

            guard result.ok else {
                self.error = result.error ?? "Parse failed"
                isParsing = false
                return
            }

            parseResult = result.result
            selectedIndices = Set((0..<(result.result?.transactions.count ?? 0)).filter {
                !(result.result?.transactions[$0].isDuplicate ?? false)
            })
        } catch {
            self.error = error.localizedDescription
        }

        isParsing = false
    }

    private func importSelected(_ result: ParseResult) async {
        isImporting = true
        error = nil

        let txToImport = selectedIndices.sorted().compactMap { idx -> ParsedTransaction? in
            guard idx < result.transactions.count else { return nil }
            return result.transactions[idx]
        }

        do {
            var imported = 0

            for tx in txToImport {
                let input = CreateTransactionInput(
                    account_id: selectedAccountId ?? dataStore.accounts.first(where: { $0.isPrimary })?.id,
                    amount: Decimal(tx.amount),
                    type: tx.type == "income" ? "income" : "expense",
                    date: tx.date,
                    description: tx.description,
                    category_id: tx.categoryId,
                    merchant_name: tx.merchantName
                )
                _ = try await TransactionRepository().create(input)
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

struct ParseStatementResponse: Decodable {
    let ok: Bool
    let error: String?
    let result: ParseResult?
}

struct ParseResult: Decodable {
    let bankName: String?
    let period: String?
    let totalIncome: Decimal
    let totalExpense: Decimal
    let transactions: [ParsedTransaction]

    enum CodingKeys: String, CodingKey {
        case bankName = "bank_name"
        case period
        case totalIncome = "total_income"
        case totalExpense = "total_expense"
        case transactions
    }
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
