import SwiftUI

struct ExportView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var startDate = Calendar.current.date(byAdding: .month, value: -1, to: Date())!
    @State private var endDate = Date()
    @State private var selectedAccountId: String?
    @State private var exportURL: URL?
    @State private var showShareSheet = false
    @State private var isExporting = false

    private var dataStore: DataStore { appViewModel.dataStore }

    private static let df: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()

    private var filteredTransactions: [Transaction] {
        return dataStore.transactions.filter { tx in
            guard let date = Self.df.date(from: tx.date) else { return false }
            if date < startDate || date > endDate { return false }
            if let accountId = selectedAccountId, tx.accountId != accountId { return false }
            return true
        }
    }

    var body: some View {
        Form {
            Section("Период") {
                DatePicker("С", selection: $startDate, displayedComponents: .date)
                DatePicker("По", selection: $endDate, displayedComponents: .date)
            }

            Section("Счёт") {
                Picker("Счёт", selection: $selectedAccountId) {
                    Text("Все счета").tag(nil as String?)
                    ForEach(dataStore.accounts) { account in
                        Text("\(account.icon) \(account.name)").tag(account.id as String?)
                    }
                }
            }

            Section {
                HStack {
                    Text("Транзакций к экспорту")
                    Spacer()
                    Text("\(filteredTransactions.count)")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button {
                    exportCSV()
                } label: {
                    HStack {
                        Spacer()
                        if isExporting {
                            ProgressView()
                        } else {
                            Label("Экспортировать CSV", systemImage: "square.and.arrow.up")
                        }
                        Spacer()
                    }
                }
                .disabled(filteredTransactions.isEmpty || isExporting)
            }
        }
        .navigationTitle("Экспорт")
        .sheet(isPresented: $showShareSheet) {
            if let url = exportURL {
                ShareSheet(activityItems: [url])
            }
        }
    }

    private func exportCSV() {
        isExporting = true

        let csv = CSVExporter.export(
            transactions: filteredTransactions,
            categories: dataStore.categories,
            accounts: dataStore.accounts
        )

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let fileName = "akifi_export_\(df.string(from: Date())).csv"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        do {
            try csv.write(to: tempURL, atomically: true, encoding: .utf8)
            exportURL = tempURL
            showShareSheet = true
        } catch {
            // Handle error
        }

        isExporting = false
    }
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
