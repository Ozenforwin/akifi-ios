import SwiftUI

struct CategoriesManagementView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var categories: [Category] = []
    @State private var isLoading = true
    @State private var showAddCategory = false
    @State private var editingCategory: Category?
    @State private var error: String?
    @State private var deletingCategory: Category?
    @State private var deletingTxCount = 0
    @State private var selectedTab: CategoryType = .expense

    private let categoryRepo = CategoryRepository()
    private let maxActive = 40
    private var dataStore: DataStore { appViewModel.dataStore }

    /// Deduplicated categories — shared account categories with same name are merged
    private var uniqueCategories: [Category] {
        var seen: Set<String> = []
        return categories.filter { cat in
            let key = "\(cat.name.lowercased())_\(cat.type.rawValue)"
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }
    }

    /// Only user's own categories (not from shared accounts)
    private var ownCategories: [Category] {
        let currentUserId = dataStore.profile?.id ?? ""
        return uniqueCategories.filter { $0.userId == currentUserId || $0.accountId == nil }
    }

    private var activeExpense: [Category] {
        uniqueCategories.filter { $0.type == .expense && $0.isActive }
    }

    private var activeIncome: [Category] {
        uniqueCategories.filter { $0.type == .income && $0.isActive }
    }

    private var hiddenCategories: [Category] {
        uniqueCategories.filter { !$0.isActive && $0.type == selectedTab }
    }

    private var visibleCategories: [Category] {
        selectedTab == .expense ? activeExpense : activeIncome
    }

    /// Count transactions per category for subtitle
    private var txCountByCategory: [String: Int] {
        var counts: [String: Int] = [:]
        for tx in dataStore.transactions {
            if let catId = tx.categoryId {
                counts[catId, default: 0] += 1
            }
        }
        return counts
    }

    private var activeCount: Int {
        ownCategories.count
    }

    var body: some View {
        VStack(spacing: 0) {
            // Segment control
            Picker("", selection: $selectedTab) {
                Text(String(localized: "common.expenses")).tag(CategoryType.expense)
                Text(String(localized: "common.incomes")).tag(CategoryType.income)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            List {
                ForEach(visibleCategories) { cat in
                    categoryRow(cat)
                }

                if !hiddenCategories.isEmpty {
                    Section(String(localized: "categories.hidden")) {
                        ForEach(hiddenCategories) { cat in
                            categoryRow(cat)
                        }
                    }
                }

                Color.clear.frame(height: 100)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .navigationTitle(String(localized: "budgets.categories"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 8) {
                    Text("\(activeCount)/\(maxActive)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button {
                        showAddCategory = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(activeCount >= maxActive)
                }
            }
        }
        .task {
            await reloadCategories()
        }
        .sheet(isPresented: $showAddCategory) {
            AddCategoryView { name, icon, color, type in
                do {
                    let cat = try await categoryRepo.create(
                        name: name, icon: icon, color: color, type: type
                    )
                    categories.append(cat)
                    await dataStore.loadAll()
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
        .sheet(item: $editingCategory) { cat in
            EditCategoryView(category: cat) { name, icon, color in
                do {
                    let updated = try await categoryRepo.update(
                        id: cat.id, name: name, icon: icon, color: color
                    )
                    if let idx = categories.firstIndex(where: { $0.id == cat.id }) {
                        categories[idx] = updated
                    }
                    await dataStore.loadAll()
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
        .alert(String(localized: "categories.deleteConfirm"), isPresented: .init(
            get: { deletingCategory != nil },
            set: { if !$0 { deletingCategory = nil } }
        )) {
            Button(String(localized: "common.cancel"), role: .cancel) { deletingCategory = nil }
            Button(String(localized: "common.delete"), role: .destructive) {
                if let cat = deletingCategory {
                    Task { await performDelete(cat) }
                }
            }
        } message: {
            if let cat = deletingCategory {
                Text(String(localized: "categories.deleteWarning \(cat.name) \(deletingTxCount)"))
            }
        }
    }

    @ViewBuilder
    private func categoryRow(_ cat: Category) -> some View {
        HStack(spacing: 12) {
            Text(cat.icon)
                .font(.title2)
                .frame(width: 40, height: 40)
                .background(Color(hex: cat.color).opacity(0.15))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(cat.name)
                    .font(.subheadline.weight(.medium))
                let count = txCountByCategory[cat.id] ?? 0
                Text("\(count) \(String(localized: "categories.transactions"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { cat.isActive },
                set: { newVal in
                    Task {
                        try? await categoryRepo.toggleActive(id: cat.id, isActive: newVal)
                        await reloadCategories()
                    }
                }
            ))
            .labelsHidden()
        }
        .contentShape(Rectangle())
        .onTapGesture { editingCategory = cat }
    }

    private func reloadCategories() async {
        do {
            categories = try await categoryRepo.fetchAllIncludingHidden()
        } catch {
            categories = dataStore.categories
        }
        isLoading = false
    }

    private func confirmDelete(_ category: Category) async {
        do {
            let count = try await categoryRepo.transactionCount(categoryId: category.id)
            deletingTxCount = count
            deletingCategory = category
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func performDelete(_ category: Category) async {
        do {
            try await categoryRepo.delete(id: category.id)
            categories.removeAll { $0.id == category.id }
            await dataStore.loadAll()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Row

struct CategoryManagementRow: View {
    let category: Category

    var body: some View {
        HStack(spacing: 12) {
            Text(category.icon)
                .font(.title2)
                .frame(width: 36, height: 36)
                .background(Color(hex: category.color).opacity(0.15))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(category.name)
                    .font(.subheadline)
                if category.accountId != nil {
                    Text(String(localized: "categories.shared"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(.tertiarySystemBackground))
                        .clipShape(Capsule())
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Edit Category View

struct EditCategoryView: View {
    @Environment(\.dismiss) private var dismiss
    let category: Category
    let onSave: (String, String, String) async throws -> Void

    @State private var name: String
    @State private var selectedIcon: String
    @State private var selectedColor: String
    @State private var isSaving = false

    private let icons = ["🛒", "🍽️", "🏠", "🚗", "💊", "🎮", "👕", "📚", "✈️", "💰", "💻", "🎁", "📱", "🏋️", "🎵", "☕",
                         "🍕", "🎬", "🏥", "🚌", "💼", "🎓", "🐕", "👶", "💇", "🔧", "📦", "🎨", "🏖️", "🎯", "🛠️", "🏦",
                         "🌿", "🔌", "🎶", "🏡"]
    private let colors = ["#60A5FA", "#4ADE80", "#F472B6", "#FBBF24", "#A78BFA", "#FB923C", "#F87171", "#34D399", "#38BDF8", "#C084FC"]

    init(category: Category, onSave: @escaping (String, String, String) async throws -> Void) {
        self.category = category
        self.onSave = onSave
        _name = State(initialValue: category.name)
        _selectedIcon = State(initialValue: category.icon)
        _selectedColor = State(initialValue: category.color)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "common.name"), text: $name)
                }

                Section(String(localized: "categories.icon")) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 12) {
                        ForEach(icons, id: \.self) { icon in
                            Text(icon)
                                .font(.title2)
                                .frame(width: 36, height: 36)
                                .background(selectedIcon == icon ? Color(hex: selectedColor).opacity(0.3) : .clear)
                                .clipShape(Circle())
                                .onTapGesture { selectedIcon = icon }
                        }
                    }
                }

                Section(String(localized: "categories.color")) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
                        ForEach(colors, id: \.self) { color in
                            Circle()
                                .fill(Color(hex: color))
                                .frame(width: 36, height: 36)
                                .overlay {
                                    if selectedColor == color {
                                        Image(systemName: "checkmark")
                                            .font(.caption.bold())
                                            .foregroundStyle(.white)
                                    }
                                }
                                .onTapGesture { selectedColor = color }
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "categories.edit"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "common.save")) {
                        Task {
                            isSaving = true
                            try? await onSave(name, selectedIcon, selectedColor)
                            dismiss()
                        }
                    }
                    .disabled(name.isEmpty || isSaving)
                }
            }
        }
    }
}

// MARK: - Add Category (updated with expanded emojis)

struct AddCategoryView: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (String, String, String, CategoryType) async throws -> Void

    @State private var name = ""
    @State private var selectedIcon = "🛒"
    @State private var selectedColor = "#60A5FA"
    @State private var type: CategoryType = .expense
    @State private var isSaving = false

    private let icons = ["🛒", "🍽️", "🏠", "🚗", "💊", "🎮", "👕", "📚", "✈️", "💰", "💻", "🎁", "📱", "🏋️", "🎵", "☕",
                         "🍕", "🎬", "🏥", "🚌", "💼", "🎓", "🐕", "👶", "💇", "🔧", "📦", "🎨", "🏖️", "🎯", "🛠️", "🏦",
                         "🌿", "🔌", "🎶", "🏡"]
    private let colors = ["#60A5FA", "#4ADE80", "#F472B6", "#FBBF24", "#A78BFA", "#FB923C", "#F87171", "#34D399", "#38BDF8", "#C084FC"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "common.name"), text: $name)

                    Picker(String(localized: "common.type"), selection: $type) {
                        Text(String(localized: "common.expense")).tag(CategoryType.expense)
                        Text(String(localized: "common.income")).tag(CategoryType.income)
                    }
                    .pickerStyle(.segmented)
                }

                Section(String(localized: "categories.icon")) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 12) {
                        ForEach(icons, id: \.self) { icon in
                            Text(icon)
                                .font(.title2)
                                .frame(width: 36, height: 36)
                                .background(selectedIcon == icon ? Color(hex: selectedColor).opacity(0.3) : .clear)
                                .clipShape(Circle())
                                .onTapGesture { selectedIcon = icon }
                        }
                    }
                }

                Section(String(localized: "categories.color")) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
                        ForEach(colors, id: \.self) { color in
                            Circle()
                                .fill(Color(hex: color))
                                .frame(width: 36, height: 36)
                                .overlay {
                                    if selectedColor == color {
                                        Image(systemName: "checkmark")
                                            .font(.caption.bold())
                                            .foregroundStyle(.white)
                                    }
                                }
                                .onTapGesture { selectedColor = color }
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "categories.new"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "common.create")) {
                        Task {
                            isSaving = true
                            try? await onSave(name, selectedIcon, selectedColor, type)
                            dismiss()
                        }
                    }
                    .disabled(name.isEmpty || isSaving)
                }
            }
        }
    }
}
