import SwiftUI

/// Multi-select filter for the report: everything is on by default and the
/// user switches individual rows OFF ("all accounts except that card").
///
/// A row can stand for several ids at once — the report groups categories
/// by display name, and the same name legitimately exists under different
/// ids (shared accounts, income/expense twins). Toggling the row moves all
/// of its `memberIds` in or out of `excluded` together.
struct ReportFilterSheet: View {
    struct Row: Identifiable {
        let id: String
        let title: String
        var subtitle: String?
        /// Ids this row represents in the exclusion set.
        let memberIds: [String]
    }

    @Environment(\.dismiss) private var dismiss

    let title: String
    let rows: [Row]
    @Binding var excluded: Set<String>

    private func isOn(_ row: Row) -> Bool {
        !row.memberIds.allSatisfy { excluded.contains($0) }
    }

    private func toggle(_ row: Row) {
        if isOn(row) {
            row.memberIds.forEach { excluded.insert($0) }
        } else {
            row.memberIds.forEach { excluded.remove($0) }
        }
    }

    private var allOn: Bool { rows.allSatisfy { isOn($0) } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    // Only ever "turn everything back on" — a "deselect all"
                    // would leave the report with nothing to draw.
                    Button {
                        excluded.removeAll()
                    } label: {
                        HStack {
                            Text(String(localized: "report.filter.selectAll"))
                            Spacer()
                            if allOn {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accent)
                            }
                        }
                    }
                    .disabled(allOn)
                    .foregroundStyle(allOn ? .secondary : Color.accent)
                }

                Section {
                    ForEach(rows) { row in
                        Button {
                            toggle(row)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: isOn(row) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(isOn(row) ? Color.accent : Color(.systemGray3))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.title)
                                        .foregroundStyle(.primary)
                                    if let subtitle = row.subtitle {
                                        Text(subtitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "common.done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
