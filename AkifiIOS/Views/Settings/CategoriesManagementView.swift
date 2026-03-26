import SwiftUI

struct CategoriesManagementView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var categories: [Category] = []
    @State private var isLoading = true
    @State private var showAddCategory = false
    @State private var error: String?

    private let categoryRepo = CategoryRepository()
    private var dataStore: DataStore { appViewModel.dataStore }

    private var incomeCategories: [Category] {
        categories.filter { $0.type == .income }
    }

    private var expenseCategories: [Category] {
        categories.filter { $0.type == .expense }
    }

    var body: some View {
        List {
            if !expenseCategories.isEmpty {
                Section("Расходы") {
                    ForEach(expenseCategories) { cat in
                        CategoryManagementRow(category: cat)
                    }
                }
            }

            if !incomeCategories.isEmpty {
                Section("Доходы") {
                    ForEach(incomeCategories) { cat in
                        CategoryManagementRow(category: cat)
                    }
                }
            }
        }
        .navigationTitle("Категории")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddCategory = true
                } label: {
                    Image(systemName: "plus")
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
    }
}

struct CategoryManagementRow: View {
    let category: Category

    var body: some View {
        HStack(spacing: 12) {
            Text(category.icon)
                .font(.title2)
                .frame(width: 36, height: 36)
                .background(Color(hex: category.color).opacity(0.15))
                .clipShape(Circle())

            Text(category.name)
                .font(.subheadline)
        }
    }
}

struct AddCategoryView: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (String, String, String, CategoryType) async throws -> Void

    @State private var name = ""
    @State private var selectedIcon = "🛒"
    @State private var selectedColor = "#60A5FA"
    @State private var type: CategoryType = .expense
    @State private var isSaving = false

    private let icons = ["🛒", "🍽️", "🏠", "🚗", "💊", "🎮", "👕", "📚", "✈️", "💰", "💻", "🎁", "📱", "🏋️", "🎵", "☕"]
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
