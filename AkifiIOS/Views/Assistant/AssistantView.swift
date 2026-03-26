import SwiftUI

struct AssistantView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack {
                ContentUnavailableView(
                    "AI Ассистент",
                    systemImage: "sparkles",
                    description: Text("Финансовый ассистент появится в следующем обновлении")
                )
            }
            .navigationTitle("Ассистент")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
