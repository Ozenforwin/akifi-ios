import SwiftUI

enum FABAction {
    case income(categoryId: String? = nil)
    case expense(categoryId: String? = nil)
    case transfer
    case receipt
}

/// The floating «+» (1.6): one round accent-tinted glass button above the
/// tab bar, trailing.
///
/// - Tap: the quick-add menu (income, expense, transfer, receipt) grows out
///   of the button — glass capsules that morph from it on iOS 26
///   (`AkifiGlassContainer` + `akifiGlassID`), material capsules before.
/// - Long press: the category quick-add (wheel / grid / list, per Settings →
///   «Вид категорий») — the pre-1.6 tap flow, kept reachable.
///
/// Every choice leaves through `onAction(FABAction)`; `MainTabView` owns the
/// sheets.
struct FABView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @AppStorage("categoryLayout") private var categoryLayout = "wheel"
    @State private var isMenuExpanded = false
    @State private var showCategoryWheel = false
    @State private var selectedType: TransactionType = .expense
    @State private var currentPage = 0
    @State private var didLongPress = false
    @State private var showCategorySheet = false
    @Namespace private var glassNamespace

    /// Distance from the bottom edge of the screen to the bottom of the
    /// button — `MainTabView` puts it just above the tab bar.
    var bottomInset: CGFloat
    /// Distance from the trailing edge of the screen.
    var trailingInset: CGFloat
    /// `false` on the Assistant tab and while a keyboard is up.
    var isButtonVisible: Bool = true
    var onAction: (FABAction) -> Void

    static let mainButtonSize: CGFloat = 56
    private let menuItemMinHeight: CGFloat = 48

    private struct MenuItem: Identifiable {
        let id: String
        let action: FABAction
        let label: String
        let icon: String
        let color: Color
    }

    /// Top to bottom — the same order as the pre-1.6 long-press menu.
    private var menuItems: [MenuItem] {
        [
            MenuItem(id: "income", action: .income(), label: String(localized: "common.income"),
                     icon: "arrow.up.right", color: .income),
            MenuItem(id: "expense", action: .expense(), label: String(localized: "common.expense"),
                     icon: "arrow.down.left", color: .expense),
            MenuItem(id: "transfer", action: .transfer, label: String(localized: "common.transfer"),
                     icon: "arrow.left.arrow.right", color: .transfer),
            MenuItem(id: "receipt", action: .receipt, label: String(localized: "fab.receipt"),
                     icon: "doc.text.viewfinder", color: .budget),
        ]
    }

    var body: some View {
        ZStack {
            // MARK: - Menu backdrop (tap outside closes)
            if isMenuExpanded {
                Color.black.opacity(0.25)
                    .ignoresSafeArea()
                    .onTapGesture { setMenuExpanded(false) }
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }

            // MARK: - Category wheel (long press) — only the wheel layout uses the fullscreen overlay
            if showCategoryWheel && categoryLayout == "wheel" {
                Color.black.opacity(0.15)
                    .background(.ultraThinMaterial)
                    .ignoresSafeArea()

                categoryWheelContent
            }

            // MARK: - Button + menu
            if !showCategoryWheel && (isButtonVisible || isMenuExpanded) {
                buttonStack
                    .padding(.trailing, trailingInset)
                    .padding(.bottom, bottomInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .ignoresSafeArea()
                    .transition(.scale(scale: 0.5, anchor: .center).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: isButtonVisible)
        .onChange(of: isButtonVisible) { _, visible in
            if !visible { setMenuExpanded(false) }
        }
        .sheet(isPresented: $showCategorySheet) {
            CategorySheetView(
                categories: filteredCategories,
                selectedType: $selectedType,
                layout: categoryLayout,
                onSelect: { cat in
                    showCategorySheet = false
                    onAction(selectedType == .income ? .income(categoryId: cat.id) : .expense(categoryId: cat.id))
                },
                onTransfer: {
                    showCategorySheet = false
                    onAction(.transfer)
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Button stack

    private var buttonStack: some View {
        AkifiGlassContainer(spacing: 12) {
            VStack(alignment: .trailing, spacing: 12) {
                if isMenuExpanded {
                    ForEach(menuItems) { item in
                        menuItemButton(item)
                    }
                }
                mainButton
            }
        }
    }

    private func menuItemButton(_ item: MenuItem) -> some View {
        Button {
            HapticManager.light()
            setMenuExpanded(false)
            onAction(item.action)
        } label: {
            HStack(spacing: 10) {
                Text(item.label)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Image(systemName: item.icon)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(item.color)
                    .frame(width: 24)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 18)
            .frame(minHeight: menuItemMinHeight)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .akifiGlass(in: Capsule(), interactive: true)
        .akifiGlassID(item.id, in: glassNamespace)
        .transition(.scale(scale: 0.6, anchor: .bottomTrailing).combined(with: .opacity))
    }

    private var mainButton: some View {
        Button {
            // A long press already opened the category picker; its release
            // must not also toggle the menu.
            if didLongPress {
                didLongPress = false
                return
            }
            HapticManager.medium()
            setMenuExpanded(!isMenuExpanded)
        } label: {
            Image(systemName: "plus")
                .font(.title2.weight(.semibold))
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .foregroundStyle(.white)
                .rotationEffect(.degrees(isMenuExpanded ? 45 : 0))
                .frame(width: Self.mainButtonSize, height: Self.mainButtonSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .akifiGlass(in: Circle(), tint: .accent, interactive: true)
        .akifiGlassID("fab.main", in: glassNamespace)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                guard !isMenuExpanded else { return }
                didLongPress = true
                openCategoryPicker()
            }
        )
        .spotlight(.fabButton)
        .accessibilityLabel(isMenuExpanded ? String(localized: "common.close") : String(localized: "fab.addTransaction"))
        .accessibilityHint(isMenuExpanded ? "" : String(localized: "fab.addHint"))
        .accessibilityAction(named: Text(String(localized: "fab.selectCategory"))) {
            openCategoryPicker()
        }
    }

    // MARK: - Actions

    private func setMenuExpanded(_ expanded: Bool) {
        guard expanded != isMenuExpanded else { return }
        withAnimation(.spring(duration: 0.35, bounce: 0.2)) {
            isMenuExpanded = expanded
        }
    }

    /// The pre-1.6 tap flow: categories first (wheel overlay or sheet).
    private func openCategoryPicker() {
        HapticManager.medium()
        selectedType = .expense
        currentPage = 0
        if categoryLayout == "wheel" {
            withAnimation(.spring(duration: 0.35, bounce: 0.2)) {
                showCategoryWheel = true
            }
        } else {
            showCategorySheet = true
        }
    }


    // MARK: - Category wheel

    private var filteredCategories: [Category] {
        appViewModel.dataStore.displayCategories.filter { $0.type.rawValue == selectedType.rawValue }
    }

    @ViewBuilder
    private var categoryWheelContent: some View {
        VStack(spacing: 0) {
            if categoryLayout != "wheel" {
                Spacer()
            } else {
                Spacer()
                Spacer()
            }

            if selectedType == .transfer {
                // Placeholder for transfer — show message, user taps "Перевод" confirm
                VStack(spacing: 16) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(.secondary)

                    Text(String(localized: "fab.transferBetweenAccounts"))
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Button {
                        withAnimation { showCategoryWheel = false }
                        onAction(.transfer)
                    } label: {
                        Text(String(localized: "common.continue"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 12)
                            .background(Color.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
                .frame(height: 300)
            } else {
                let cats = filteredCategories

                switch categoryLayout {
                case "grid":
                    categoryGridView(categories: cats)
                case "list":
                    categoryListView(categories: cats)
                default: // "wheel"
                    categoryWheelPages(categories: cats)
                }
            }

            Spacer()

            segmentControl
                .padding(.top, 12)

            Text(String(localized: "fab.selectCategory"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
                .padding(.bottom, 30)
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Wheel layout (pages)

    private func categoryWheelPages(categories: [Category]) -> some View {
        let pageSize = 8
        let pages = max((categories.count + pageSize - 1) / pageSize, 1)

        return VStack(spacing: 0) {
            TabView(selection: $currentPage) {
                ForEach(0..<pages, id: \.self) { page in
                    let start = page * pageSize
                    let end = min(start + pageSize, categories.count)
                    let pageCats = start < categories.count ? Array(categories[start..<end]) : []
                    categoryWheelPage(categories: pageCats)
                        .tag(page)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 360)

            if pages > 1 {
                HStack(spacing: 6) {
                    ForEach(0..<pages, id: \.self) { i in
                        Capsule()
                            .fill(i == currentPage ? Color.primary : Color.primary.opacity(0.3))
                            .frame(width: i == currentPage ? 16 : 6, height: 6)
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    // MARK: - Grid layout (Telegram-style bottom sheet)

    @ViewBuilder
    private func categoryGridView(categories: [Category]) -> some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 16) {
                ForEach(categories) { cat in
                    Button {
                        HapticManager.light()
                        withAnimation(.spring(duration: 0.3)) { showCategoryWheel = false }
                        onAction(selectedType == .income ? .income(categoryId: cat.id) : .expense(categoryId: cat.id))
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
            .padding(.bottom, 20)
        }
        .frame(maxHeight: 400)
    }

    // MARK: - List layout (Telegram-style bottom sheet)

    @ViewBuilder
    private func categoryListView(categories: [Category]) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(categories) { cat in
                    Button {
                        HapticManager.light()
                        withAnimation(.spring(duration: 0.3)) { showCategoryWheel = false }
                        onAction(selectedType == .income ? .income(categoryId: cat.id) : .expense(categoryId: cat.id))
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

                    if cat.id != categories.last?.id {
                        Divider()
                            .padding(.leading, 78)
                    }
                }
            }
            .padding(.bottom, 20)
        }
        .frame(maxHeight: 400)
    }

    // MARK: - Wheel page (single page of wheel)

    private func categoryWheelPage(categories: [Category]) -> some View {
        let radius: CGFloat = 130
        let positions = wheelPositions(count: categories.count, radius: radius)

        return ZStack {
            // Close button at center
            Button {
                withAnimation(.spring(duration: 0.3)) { showCategoryWheel = false }
            } label: {
                ZStack {
                    Circle()
                        .fill(Color(.systemGray3))
                        .frame(width: 52, height: 52)
                    Image(systemName: "xmark")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)

            // Category items around the circle with staggered animation
            ForEach(Array(categories.enumerated()), id: \.element.id) { index, cat in
                let pos = index < positions.count ? positions[index] : .zero
                Button {
                    withAnimation(.spring(duration: 0.3)) { showCategoryWheel = false }
                    onAction(selectedType == .income ? .income(categoryId: cat.id) : .expense(categoryId: cat.id))
                } label: {
                    VStack(spacing: 2) {
                        ZStack {
                            Circle()
                                .fill(Color(.systemGray5))
                                .frame(width: 62, height: 62)
                            Text(cat.icon)
                                .font(.system(size: 28))
                        }
                        Text(cat.name)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .frame(width: 74)
                    }
                }
                .buttonStyle(.plain)
                .offset(x: pos.x, y: pos.y)
                .transition(.scale.combined(with: .opacity))
                .animation(
                    .spring(duration: 0.4, bounce: 0.25)
                        .delay(Double(index) * 0.04),
                    value: showCategoryWheel
                )
            }
        }
        .frame(width: 340, height: 340)
    }

    private func wheelPositions(count: Int, radius: CGFloat) -> [CGPoint] {
        guard count > 0 else { return [] }
        let start = -CGFloat.pi / 2
        return (0..<count).map { i in
            let angle = start + (2 * .pi * CGFloat(i) / CGFloat(count))
            return CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
        }
    }

    // MARK: - Segment control

    private var segmentControl: some View {
        HStack(spacing: 0) {
            segmentButton(String(localized: "common.expense"), type: .expense)
            segmentButton(String(localized: "common.income"), type: .income)
            segmentButton(String(localized: "common.transfer"), type: .transfer)
        }
        .background(Color(.systemGray5))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 40)
    }

    private func segmentButton(_ label: String, type: TransactionType) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedType = type
                currentPage = 0
            }
        } label: {
            Text(label)
                .font(.subheadline.weight(selectedType == type ? .semibold : .regular))
                .foregroundStyle(selectedType == type ? .white : .secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    selectedType == type
                        ? Color.accent
                        : Color.clear
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

