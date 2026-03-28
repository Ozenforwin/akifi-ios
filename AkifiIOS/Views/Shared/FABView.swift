import SwiftUI

enum FABAction {
    case income, expense, transfer, receipt
}

struct FABView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var isMenuExpanded = false
    @State private var showCategoryWheel = false
    @State private var selectedType: TransactionType = .expense
    @State private var currentPage = 0
    @State private var didLongPress = false
    var onAction: (FABAction) -> Void

    private let mainButtonSize: CGFloat = 56
    private let subButtonSize: CGFloat = 48

    // Angles match Telegram: arc from bottom-right going up-left
    private var menuItems: [(action: FABAction, label: String, icon: String, color: Color, angle: Double)] {
        [
            (.income, "Доход", "arrow.up.right", Color.income.opacity(0.85), -100),
            (.expense, "Расход", "arrow.down.left", Color.expense.opacity(0.85), -125),
            (.transfer, "Перевод", "arrow.left.arrow.right", Color.transfer.opacity(0.85), -150),
            (.receipt, "Чек", "doc.text.viewfinder", Color.budget.opacity(0.85), -175),
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
                    HStack {
                        Spacer()
                        ZStack(alignment: .bottomTrailing) {
                            ForEach(Array(menuItems.enumerated()), id: \.offset) { index, item in
                                arcButton(item: item, index: index)
                            }

                            // Close/× button at FAB position
                            Button {
                                withAnimation(.spring(duration: 0.3)) { isMenuExpanded = false }
                            } label: {
                                fabCircle(icon: "xmark")
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.trailing, 20)
                        .padding(.bottom, 90)
                    }
                }
            }

            // MARK: - Category wheel (tap mode)
            if showCategoryWheel {
                Color.black.opacity(0.15)
                    .background(.ultraThinMaterial)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.spring(duration: 0.3)) { showCategoryWheel = false }
                    }

                categoryWheelContent
            }

            // MARK: - FAB button
            if !isMenuExpanded && !showCategoryWheel {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        fabCircle(icon: "plus")
                            .accessibilityLabel("Добавить операцию")
                            .accessibilityHint("Нажмите для быстрого добавления, удерживайте для меню")
                            .onLongPressGesture(minimumDuration: 0.4, perform: {
                                // Long press → arc menu
                                didLongPress = true
                                showCategoryWheel = false
                                withAnimation(.spring(duration: 0.35, bounce: 0.2)) {
                                    isMenuExpanded = true
                                }
                            }, onPressingChanged: { pressing in
                                if !pressing && !didLongPress {
                                    // Released before long press threshold → tap
                                    selectedType = .expense
                                    currentPage = 0
                                    withAnimation(.spring(duration: 0.35, bounce: 0.2)) {
                                        showCategoryWheel = true
                                    }
                                }
                                if !pressing {
                                    didLongPress = false
                                }
                            })
                        .padding(.trailing, 20)
                        .padding(.bottom, 90)
                    }
                }
            }
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

    // MARK: - Arc button (long-press)

    private func arcButton(item: (action: FABAction, label: String, icon: String, color: Color, angle: Double), index: Int) -> some View {
        let rad = item.angle * .pi / 180
        let radius: CGFloat = 140
        // x goes left (negative), y goes up (negative) — offset relative to bottom-trailing anchor
        let dx = cos(rad) * radius
        let dy = sin(rad) * radius

        return Button {
            withAnimation(.spring(duration: 0.3)) { isMenuExpanded = false }
            onAction(item.action)
        } label: {
            HStack(spacing: 8) {
                Text(item.label)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .shadow(color: .white.opacity(0.8), radius: 2)

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
        .offset(x: dx, y: dy)
        .transition(.scale.combined(with: .opacity))
        .animation(.spring(duration: 0.35, bounce: 0.2).delay(Double(index) * 0.05), value: isMenuExpanded)
    }

    // MARK: - Category wheel

    private var filteredCategories: [Category] {
        appViewModel.dataStore.categories.filter { $0.type.rawValue == selectedType.rawValue }
    }

    @ViewBuilder
    private var categoryWheelContent: some View {
        VStack(spacing: 0) {
            Spacer()

            if selectedType == .transfer {
                // Placeholder for transfer — show message, user taps "Перевод" confirm
                VStack(spacing: 16) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(.secondary)

                    Text("Перевод между счетами")
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Button {
                        withAnimation { showCategoryWheel = false }
                        onAction(.transfer)
                    } label: {
                        Text("Продолжить")
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
                let pageSize = 8
                let pages = max((cats.count + pageSize - 1) / pageSize, 1)

                TabView(selection: $currentPage) {
                    ForEach(0..<pages, id: \.self) { page in
                        let start = page * pageSize
                        let end = min(start + pageSize, cats.count)
                        let pageCats = start < cats.count ? Array(cats[start..<end]) : []
                        categoryPage(categories: pageCats)
                            .tag(page)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: 300)

                // Custom page dots below wheel with spacing
                if pages > 1 {
                    HStack(spacing: 6) {
                        ForEach(0..<pages, id: \.self) { i in
                            Capsule()
                                .fill(i == currentPage ? Color.white : Color.white.opacity(0.4))
                                .frame(width: i == currentPage ? 16 : 6, height: 6)
                        }
                    }
                    .padding(.top, 8)
                }
            }

            Text("Выберите категорию")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 12)

            segmentControl
                .padding(.top, 12)

            Spacer()
        }
        .padding(.horizontal, 20)
    }

    private func categoryPage(categories: [Category]) -> some View {
        let radius: CGFloat = 105
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

            // Category items around the circle
            ForEach(Array(categories.enumerated()), id: \.element.id) { index, cat in
                let pos = index < positions.count ? positions[index] : .zero
                Button {
                    withAnimation(.spring(duration: 0.3)) { showCategoryWheel = false }
                    onAction(selectedType == .income ? .income : .expense)
                } label: {
                    VStack(spacing: 2) {
                        ZStack {
                            Circle()
                                .fill(Color(.systemGray4))
                                .frame(width: 58, height: 58)
                            Text(cat.icon)
                                .font(.system(size: 26))
                        }
                        Text(cat.name)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .frame(width: 70)
                    }
                }
                .buttonStyle(.plain)
                .offset(x: pos.x, y: pos.y)
            }
        }
        .frame(width: 300, height: 300)
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
            segmentButton("Расход", type: .expense)
            segmentButton("Доход", type: .income)
            segmentButton("Перевод", type: .transfer)
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
