import SwiftUI

enum FABAction {
    case income(categoryId: String? = nil)
    case expense(categoryId: String? = nil)
    case transfer
    case receipt
}

struct FABView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @AppStorage("categoryLayout") private var categoryLayout = "wheel"
    @State private var isMenuExpanded = false
    @State private var showCategoryWheel = false
    @State private var selectedType: TransactionType = .expense
    @State private var currentPage = 0
    @State private var didLongPress = false
    @State private var showCategorySheet = false
    var onAction: (FABAction) -> Void

    private let mainButtonSize: CGFloat = 56
    private let subButtonSize: CGFloat = 48

    // Angles match Telegram: arc from bottom-right going up-left
    private var menuItems: [(action: FABAction, label: String, icon: String, color: Color, angle: Double)] {
        [
            (.income(), String(localized: "common.income"), "arrow.up.right", Color.income.opacity(0.85), -100),
            (.expense(), String(localized: "common.expense"), "arrow.down.left", Color.expense.opacity(0.85), -125),
            (.transfer, String(localized: "common.transfer"), "arrow.left.arrow.right", Color.transfer.opacity(0.85), -150),
            (.receipt, String(localized: "fab.receipt"), "doc.text.viewfinder", Color.budget.opacity(0.85), -175),
        ]
    }

    var body: some View {
        ZStack {
            // MARK: - Long-press arc menu
            if isMenuExpanded {
                Color.black.opacity(0.3)
                    .background(.ultraThinMaterial)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.spring(duration: 0.3)) { isMenuExpanded = false }
                    }

                VStack {
                    Spacer()

                    // Menu items stacked vertically
                    VStack(spacing: 14) {
                        ForEach(Array(menuItems.enumerated()), id: \.offset) { index, item in
                            Button {
                                HapticManager.light()
                                withAnimation(.spring(duration: 0.3)) { isMenuExpanded = false }
                                onAction(item.action)
                            } label: {
                                HStack(spacing: 12) {
                                    Spacer()
                                    Text(item.label)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(.primary)
                                    ZStack {
                                        Circle()
                                            .fill(item.color)
                                            .frame(width: subButtonSize, height: subButtonSize)
                                        Image(systemName: item.icon)
                                            .font(.system(size: 18, weight: .semibold))
                                            .foregroundStyle(.white)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .transition(.asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .opacity
                            ))
                            .animation(
                                .spring(duration: 0.35, bounce: 0.2).delay(Double(index) * 0.06),
                                value: isMenuExpanded
                            )
                        }
                    }
                    .padding(.trailing, 24)

                    // Close button
                    HStack {
                        Spacer()
                        Button {
                            withAnimation(.spring(duration: 0.3)) { isMenuExpanded = false }
                        } label: {
                            fabCircle(icon: "xmark")
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.trailing, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 110)
                }
                .onAppear { HapticManager.medium() }
            }

            // MARK: - Category wheel (tap mode) — only wheel layout uses fullscreen overlay
            if showCategoryWheel && categoryLayout == "wheel" {
                Color.black.opacity(0.15)
                    .background(.ultraThinMaterial)
                    .ignoresSafeArea()

                categoryWheelContent
            }

            // MARK: - FAB button
            if !isMenuExpanded && !showCategoryWheel {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        fabCircle(icon: "plus")
                            .spotlight(.fabButton)
                            .accessibilityLabel(String(localized: "fab.addTransaction"))
                            .accessibilityHint(String(localized: "fab.addHint"))
                            .onLongPressGesture(minimumDuration: 0.4, perform: {
                                // Long press → arc menu
                                didLongPress = true
                                showCategoryWheel = false
                                withAnimation(.spring(duration: 0.35, bounce: 0.2)) {
                                    isMenuExpanded = true
                                }
                            }, onPressingChanged: { pressing in
                                if !pressing && !didLongPress {
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
                                if !pressing {
                                    didLongPress = false
                                }
                            })
                        .padding(.trailing, 20)
                        .padding(.bottom, 110)
                    }
                }
            }
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

    // MARK: - FAB circle

    private func fabCircle(icon: String) -> some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: Color.fabStart.opacity(0.8), location: 0),
                            .init(color: Color.fabEnd.opacity(0.8), location: 1),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: mainButtonSize, height: mainButtonSize)
                .shadow(color: Color.accent.opacity(0.2), radius: 12.5, x: 0, y: 10)
                .overlay(
                    Circle()
                        .inset(by: 0.5)
                        .stroke(.white.opacity(0.25), lineWidth: 1)
                )

            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    // MARK: - Category wheel

    private var filteredCategories: [Category] {
        appViewModel.dataStore.categories.filter { $0.type.rawValue == selectedType.rawValue }
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

