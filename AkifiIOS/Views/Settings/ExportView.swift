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

    private var filteredTransactions: [Transaction] {
        Self.filter(dataStore.transactions, from: startDate, to: endDate, accountId: selectedAccountId)
    }

    /// Transactions whose local day lies in the picked days, both ends
    /// included. Compared as `yyyy-MM-dd` strings: the pickers return the
    /// current time of day, so `txMidnight < startDate` used to drop the
    /// whole "From" day.
    static func filter(
        _ transactions: [Transaction],
        from start: Date,
        to end: Date,
        accountId: String?
    ) -> [Transaction] {
        let fromDay = AppDateFormatters.isoDate.string(from: min(start, end))
        let toDay = AppDateFormatters.isoDate.string(from: max(start, end))
        return transactions.filter { tx in
            let day = String(tx.date.prefix(10))
            guard day >= fromDay, day <= toDay else { return false }
            if let accountId, tx.accountId != accountId { return false }
            return true
        }
    }

    var body: some View {
        Form {
            Section(String(localized: "export.period")) {
                DatePicker(String(localized: "export.from"), selection: $startDate, displayedComponents: .date)
                DatePicker(String(localized: "export.to"), selection: $endDate, displayedComponents: .date)
            }

            Section(String(localized: "export.account")) {
                Picker(String(localized: "export.account"), selection: $selectedAccountId) {
                    Text(String(localized: "export.allAccounts")).tag(nil as String?)
                    ForEach(dataStore.accounts) { account in
                        Text("\(account.icon) \(account.name)").tag(account.id as String?)
                    }
                }
            }

            Section {
                LabeledContent(String(localized: "export.transactionsToExport")) {
                    Text("\(filteredTransactions.count)")
                        .monospacedDigit()
                }
            }

            Section {
                Button {
                    exportCSV()
                } label: {
                    Group {
                        if isExporting {
                            ProgressView()
                        } else {
                            Label(String(localized: "export.exportCSV"), systemImage: "square.and.arrow.up")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(filteredTransactions.isEmpty || isExporting)
            }
        }
        .akifiFloatingButtonClearance()
        .navigationTitle(String(localized: "settings.export"))
        .navigationBarTitleDisplayMode(.inline)
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

        let fileName = "akifi_export_\(AppDateFormatters.isoDate.string(from: Date())).csv"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        do {
            try csv.write(to: tempURL, atomically: true, encoding: .utf8)
            exportURL = tempURL
            showShareSheet = true
            AnalyticsService.logExportCSV()
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
