import SwiftUI

struct ChallengeFormView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @Environment(\.dismiss) private var dismiss

    let onCreate: (SavingsChallenge) -> Void

    @State private var selectedType: ChallengeType = .noCafe
    @State private var title: String = ""
    @State private var durationDays: Int = 30
    @State private var targetAmountText: String = ""
    @State private var selectedCategoryId: String?
    @State private var isSaving = false
    @State private var error: String?

    @State private var vm = SavingsChallengesViewModel()

    private var dataStore: DataStore { appViewModel.dataStore }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
            && (!selectedType.requiresCategory || selectedCategoryId != nil)
            && (!selectedType.requiresTarget || parsedTarget != nil)
    }

    private var parsedTarget: Int64? {
        let cleaned = targetAmountText
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ",", with: ".")
        guard let v = Double(cleaned), v > 0 else { return nil }
        return Int64((v * 100).rounded())
    }

    var body: some View {
        NavigationStack {
            Form {
                typeSection
                detailsSection
                if selectedType.requiresTarget { targetSection }
                if selectedType.requiresCategory { categorySection }
                durationSection
            }
            .navigationTitle(String(localized: "challenges.form.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "common.save")) {
                        Task { await save() }
                    }
                    .disabled(!canSave || isSaving)
                }
            }
            .alert(String(localized: "common.error"),
                   isPresented: .init(get: { error != nil }, set: { _ in error = nil })) {
                Button(String(localized: "common.close"), role: .cancel) {}
            } message: {
                Text(error ?? "")
            }
            .onChange(of: selectedType) { _, newType in
                // Autofill title from preset when user picks a type with an empty title.
                if title.isEmpty {
                    title = newType.localizedTitle
                }
            }
            .onAppear {
                if title.isEmpty { title = selectedType.localizedTitle }
            }
        }
    }

    // MARK: - Sections

    private var typeSection: some View {
        Section(String(localized: "challenges.form.type")) {
            ForEach(ChallengeType.allCases, id: \.self) { type in
                Button {
                    selectedType = type
                } label: {
                    HStack(spacing: 12) {
                        Text(type.icon).font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(type.localizedTitle)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(type.localizedDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer()
                        if selectedType == type {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.accent)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var detailsSection: some View {
        Section(String(localized: "challenges.form.details")) {
            TextField(String(localized: "challenges.form.title.placeholder"), text: $title)
        }
    }

    private var targetSection: some View {
        Section(String(localized: "challenges.form.target")) {
            TextField(
                String(localized: "challenges.form.target.placeholder"),
                text: $targetAmountText
            )
            .keyboardType(.decimalPad)
        }
    }

    private var categorySection: some View {
        Section(String(localized: "challenges.form.category")) {
            Menu {
                ForEach(dataStore.displayCategories.filter { $0.type == .expense }) { cat in
                    Button {
                        selectedCategoryId = cat.id
                    } label: {
                        Label("\(cat.icon) \(cat.name)", systemImage: selectedCategoryId == cat.id ? "checkmark" : "")
                    }
                }
            } label: {
                HStack {
                    Text(selectedCategoryName)
                        .foregroundStyle(selectedCategoryId == nil ? .secondary : .primary)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var selectedCategoryName: String {
        if let id = selectedCategoryId,
           let cat = dataStore.categories.first(where: { $0.id == id }) {
            return "\(cat.icon) \(cat.name)"
        }
        return String(localized: "challenges.form.category.placeholder")
    }

    private var durationSection: some View {
        Section(String(localized: "challenges.form.duration")) {
            Picker(String(localized: "challenges.form.duration"), selection: $durationDays) {
                Text(String(localized: "challenges.duration.7")).tag(7)
                Text(String(localized: "challenges.duration.14")).tag(14)
                Text(String(localized: "challenges.duration.30")).tag(30)
                Text(String(localized: "challenges.duration.60")).tag(60)
                Text(String(localized: "challenges.duration.90")).tag(90)
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - Save

    private func save() async {
        isSaving = true
        defer { isSaving = false }

        let description = selectedType.localizedDescription
        let created = await vm.create(
            type: selectedType,
            title: title.trimmingCharacters(in: .whitespaces),
            description: description,
            targetAmount: parsedTarget,
            durationDays: durationDays,
            categoryId: selectedCategoryId,
            linkedGoalId: nil
        )
        if let created {
            onCreate(created)
            dismiss()
        } else if let err = vm.error {
            error = err
        }
    }
}
