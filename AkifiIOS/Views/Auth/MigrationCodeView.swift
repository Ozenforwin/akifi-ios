import SwiftUI

struct MigrationCodeView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @ScaledMetric(relativeTo: .largeTitle) private var iconSize: CGFloat = 50

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                VStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: iconSize))
                        .foregroundStyle(Color.accent)
                        .accessibilityHidden(true)

                    Text(String(localized: "migration.title"))
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)

                    Text(String(localized: "migration.instructions"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                TextField(String(localized: "migration.codePlaceholder"), text: $code)
                    .font(.title2.monospaced())
                    .multilineTextAlignment(.center)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .padding()
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, 40)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Button {
                    Task { await migrate() }
                } label: {
                    ZStack {
                        Text(String(localized: "migration.linkAccount"))
                            .font(.headline)
                            .opacity(isLoading ? 0 : 1)
                        if isLoading {
                            ProgressView()
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.akifiPrimary)
                .controlSize(.large)
                .disabled(code.count < 6 || isLoading)
                .padding(.horizontal, 24)

                Spacer()
            }
            .padding(.top, 40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The field is a content card on the grouped background (1.6).
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.close")) { dismiss() }
                }
            }
        }
    }

    private func migrate() async {
        isLoading = true
        errorMessage = nil

        do {
            try await appViewModel.authManager.migrateWithCode(code.uppercased())
            await appViewModel.loadAfterAuth()
            dismiss()
        } catch {
            errorMessage = String(localized: "migration.invalidCode")
        }

        isLoading = false
    }
}
