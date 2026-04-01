import SwiftUI

struct CategorySheetView: View {
    @Environment(AppViewModel.self) private var appViewModel
    let categories: [Category]
    @Binding var selectedType: TransactionType
    let layout: String
    let onSelect: (Category) -> Void
    let onTransfer: () -> Void

    private var filteredCategories: [Category] {
        appViewModel.dataStore.categories.filter { $0.type.rawValue == selectedType.rawValue }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Segment control
                HStack(spacing: 0) {
                    sheetSegment(String(localized: "common.expense"), type: .expense)
                    sheetSegment(String(localized: "common.income"), type: .income)
                    sheetSegment(String(localized: "common.transfer"), type: .transfer)
                }
                .background(Color(.systemGray5))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 40)
                .padding(.vertical, 12)

                if selectedType == .transfer {
                    VStack(spacing: 16) {
                        Spacer()
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 48, weight: .light))
                            .foregroundStyle(.secondary)
                        Text(String(localized: "fab.transferBetweenAccounts"))
                            .font(.headline)
                        Button {
                            onTransfer()
                        } label: {
                            Text(String(localized: "common.continue"))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 32)
                                .padding(.vertical, 12)
                                .background(Color.accent)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        Spacer()
                    }
                } else {
                    ScrollView {
                        if layout == "list" {
                            listContent
                        } else {
                            gridContent
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "fab.selectCategory"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var gridContent: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 16) {
            ForEach(filteredCategories) { cat in
                Button {
                    HapticManager.light()
                    onSelect(cat)
                } label: {
                    VStack(spacing: 6) {
                        Circle()
                            .fill(Color(hex: cat.color).opacity(0.15))
                            .frame(width: 60, height: 60)
                            .overlay {
                                Text(cat.icon)
                                    .font(.system(size: 28))
                            }
                        Text(cat.name)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 20)
    }

    private var listContent: some View {
        VStack(spacing: 0) {
            ForEach(filteredCategories) { cat in
                Button {
                    HapticManager.light()
                    onSelect(cat)
                } label: {
                    HStack(spacing: 14) {
                        Circle()
                            .fill(Color(hex: cat.color).opacity(0.12))
                            .frame(width: 44, height: 44)
                            .overlay {
                                Text(cat.icon)
                                    .font(.system(size: 22))
                            }
                        Text(cat.name)
                            .font(.body)
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.quaternary)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.plain)

                if cat.id != filteredCategories.last?.id {
                    Divider()
                        .padding(.leading, 78)
                }
            }
        }
        .padding(.bottom, 20)
    }

    private func sheetSegment(_ label: String, type: TransactionType) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedType = type
            }
        } label: {
            Text(label)
                .font(.subheadline.weight(selectedType == type ? .semibold : .regular))
                .foregroundStyle(selectedType == type ? .white : .secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(selectedType == type ? Color.accent : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
