import SwiftUI

struct ActionPreviewSheet: View {
    let action: AssistantAction
    let preview: ActionPreview
    let isProcessing: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Risk badge
                riskBadge

                // Plan description
                VStack(alignment: .leading, spacing: 12) {
                    Text("Действие")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(action.label)
                        .font(.headline)

                    Text("План")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    Text(preview.plan)
                        .font(.subheadline)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                // Changes list
                if !preview.changes.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Изменения")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        ForEach(preview.changes, id: \.self) { change in
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.caption)
                                Text(change)
                                    .font(.subheadline)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                // Reversibility
                HStack(spacing: 8) {
                    Image(systemName: preview.reversible ? "arrow.uturn.backward.circle" : "exclamationmark.triangle")
                        .foregroundStyle(preview.reversible ? .green : .orange)
                    Text(preview.reversible ? "Можно отменить" : "Нельзя отменить")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer()

                // Action buttons
                VStack(spacing: 12) {
                    Button {
                        onConfirm()
                    } label: {
                        HStack {
                            if isProcessing {
                                ProgressView()
                                    .tint(.white)
                            }
                            Text("Подтвердить")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(confirmButtonColor)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(isProcessing)

                    Button("Отмена", role: .cancel) {
                        onCancel()
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .padding()
            .navigationTitle("Подтверждение")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        onCancel()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
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
            Text("Риск: \(riskLabel)")
                .font(.caption.weight(.medium))
                .foregroundStyle(riskColor)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(riskColor.opacity(0.12))
        .clipShape(Capsule())
        .frame(maxWidth: .infinity, alignment: .leading)
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
        case .low: return "Низкий"
        case .medium: return "Средний"
        case .high: return "Высокий"
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
