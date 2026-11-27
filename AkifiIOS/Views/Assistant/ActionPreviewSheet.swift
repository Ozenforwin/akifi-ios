import SwiftUI

struct ActionPreviewSheet: View {
    let action: AssistantAction
    let preview: ActionPreview
    let isProcessing: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                // Plan description
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(localized: "action.action"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(action.label)
                            .font(.headline)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(localized: "action.plan"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(preview.plan)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    riskBadge
                }

                // Changes list
                if !preview.changes.isEmpty {
                    Section(String(localized: "action.changes")) {
                        ForEach(preview.changes, id: \.self) { change in
                            Label {
                                Text(change)
                                    .font(.subheadline)
                            } icon: {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                }

                // Reversibility
                Section {
                    Label {
                        Text(preview.reversible ? String(localized: "action.reversible") : String(localized: "action.irreversible"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: preview.reversible ? "arrow.uturn.backward.circle" : "exclamationmark.triangle")
                            .foregroundStyle(preview.reversible ? .green : .orange)
                    }
                }
            }
            .akifiSafeAreaBar(edge: .bottom) {
                Button {
                    onConfirm()
                } label: {
                    HStack(spacing: 8) {
                        if isProcessing {
                            ProgressView()
                        }
                        Text(String(localized: "action.confirm"))
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.akifiPrimary)
                .controlSize(.large)
                // The risk colour carries meaning: green/blue, orange, red.
                .tint(confirmButtonColor)
                .disabled(isProcessing)
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .navigationTitle(String(localized: "action.confirmation"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.cancel"), role: .cancel) {
                        onCancel()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var riskBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(riskColor)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text("\(String(localized: "action.risk")): \(riskLabel)")
                .font(.caption.weight(.medium))
                .foregroundStyle(riskColor)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(riskColor.opacity(0.12), in: Capsule())
        .textCase(nil)
        .padding(.bottom, 4)
    }

    private var riskColor: Color {
        switch preview.risk {
        case .low: return .green
        case .medium: return .orange
        case .high: return .red
        }
    }

    private var riskLabel: String {
        switch preview.risk {
        case .low: return String(localized: "risk.low")
        case .medium: return String(localized: "risk.medium")
        case .high: return String(localized: "risk.high")
        }
    }

    private var confirmButtonColor: Color {
        switch preview.risk {
        case .low: return .accent
        case .medium: return .orange
        case .high: return .red
        }
    }
}
