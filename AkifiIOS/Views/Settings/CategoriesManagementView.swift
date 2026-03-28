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

    private let categoryRepo = CategoryRepository()
    private let maxActive = 25
    private var dataStore: DataStore { appViewModel.dataStore }

    private var incomeCategories: [Category] {
        categories.filter { $0.type == .income }
    }

    private var expenseCategories: [Category] {
        categories.filter { $0.type == .expense }
    }

    private var activeCount: Int {
        categories.count
    }

    var body: some View {
        List {
            if !expenseCategories.isEmpty {
                Section("Расходы") {
                    ForEach(expenseCategories) { cat in
                        CategoryManagementRow(category: cat)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                editingCategory = cat
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    Task { await confirmDelete(cat) }
                                } label: {
                                    Label("Удалить", systemImage: "trash")
                                }
                            }
                    }
                }
            }

            if !incomeCategories.isEmpty {
                Section("Доходы") {
                    ForEach(incomeCategories) { cat in
                        CategoryManagementRow(category: cat)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                editingCategory = cat
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    Task { await confirmDelete(cat) }
                                } label: {
                                    Label("Удалить", systemImage: "trash")
                                }
                            }
                    }
                }
            }
        }
        .navigationTitle("Категории")
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
            categories = dataStore.categories
            isLoading = false
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
        .alert("Удалить категорию?", isPresented: .init(
            get: { deletingCategory != nil },
            set: { if !$0 { deletingCategory = nil } }
        )) {
            Button("Отмена", role: .cancel) { deletingCategory = nil }
            Button("Удалить", role: .destructive) {
                if let cat = deletingCategory {
                    Task { await performDelete(cat) }
                }
            }
        } message: {
            if let cat = deletingCategory {
                Text("Категория «\(cat.name)» используется в \(deletingTxCount) транзакциях. Она будет скрыта, но транзакции сохранятся.")
            }
        }
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
                    Text("Общая")
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
                    TextField("Название", text: $name)
                }

                Section("Иконка") {
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

                Section("Цвет") {
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
            .navigationTitle("Редактирование")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
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
                    TextField("Название", text: $name)

                    Picker("Тип", selection: $type) {
                        Text("Расход").tag(CategoryType.expense)
                        Text("Доход").tag(CategoryType.income)
                    }
                    .pickerStyle(.segmented)
                }

                Section("Иконка") {
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

                Section("Цвет") {
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
            .navigationTitle("Новая категория")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Создать") {
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
