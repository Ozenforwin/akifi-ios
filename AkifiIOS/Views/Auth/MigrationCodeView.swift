import SwiftUI

struct MigrationCodeView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                VStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 50))
                        .foregroundStyle(Color.accent)

                    Text(String(localized: "migration.title"))
                        .font(.title2.bold())

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
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 40)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button {
                    Task { await migrate() }
                } label: {
                    if isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding()
                    } else {
                        Text(String(localized: "migration.linkAccount"))
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                }
                .background(Color.accent)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .disabled(code.count < 6 || isLoading)
                .padding(.horizontal, 24)

                Spacer()
            }
            .padding(.top, 40)
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
