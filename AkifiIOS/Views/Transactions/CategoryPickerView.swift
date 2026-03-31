import SwiftUI

struct CategoryPickerView: View {
    let categories: [Category]
    let transactionType: TransactionType
    @Binding var selectedCategoryId: String?
    @Environment(\.dismiss) private var dismiss

    private var filteredCategories: [Category] {
        categories.filter { $0.type.rawValue == transactionType.rawValue }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 16) {
                    ForEach(filteredCategories) { category in
                        Button {
                            selectedCategoryId = category.id
                            dismiss()
                        } label: {
                            VStack(spacing: 6) {
                                Text(category.icon)
                                    .font(.title)
                                    .frame(width: 56, height: 56)
                                    .background(
                                        selectedCategoryId == category.id
                                            ? Color(hex: category.color).opacity(0.25)
                                            : Color(hex: category.color).opacity(0.1)
                                    )
                                    .clipShape(Circle())
                                    .overlay {
                                        if selectedCategoryId == category.id {
                                            Circle().stroke(Color(hex: category.color), lineWidth: 2)
                                        }
                                    }

                                Text(category.name)
                                    .font(.caption2)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(category.name), \(selectedCategoryId == category.id ? String(localized: "common.selected") : "")")
                    }
                }
                .padding()
            }
            .navigationTitle(String(localized: "category.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.close")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "transaction.noCategory")) {
                        selectedCategoryId = nil
                        dismiss()
                    }
                    .font(.caption)
                }
            }
        }
    }
}
