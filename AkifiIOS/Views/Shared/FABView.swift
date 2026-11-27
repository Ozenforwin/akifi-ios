import SwiftUI

enum FABAction: Equatable {
    case income(categoryId: String? = nil)
    case expense(categoryId: String? = nil)
    case transfer
    case receipt
    case debt(FABDebtAction)
}

/// Debt actions of the «+» menu (1.6.0 debts).
enum FABDebtAction: Equatable, Sendable {
    /// «Дал в долг».
    case lent
    /// «Взял в долг».
    case borrowed
}

/// The long-press menu of the «+», top to bottom.
enum FABMenu {
    struct Item: Identifiable, Equatable {
        let id: String
        let action: FABAction
        let label: String
        let icon: String
        let color: Color
    }

    // INTEGRATION POINT — debts stream (1.6.0).
    // The debts UI isn't on this branch yet. When it lands: set this to
    // true and open its «Дал в долг» / «Взял в долг» flow from
    // `MainTabView.openDebtAction(_:)` (the `.debt` route). The menu items,
    // their strings (`fab.debt.lent` / `fab.debt.borrowed`) and the routing
    // are already in place.
    static let showsDebtActions = false

    static func items(includeDebtActions: Bool = showsDebtActions) -> [Item] {
        var items: [Item] = [
            Item(id: "income", action: .income(), label: String(localized: "common.income"),
                 icon: "arrow.up.right", color: .income),
            Item(id: "expense", action: .expense(), label: String(localized: "common.expense"),
                 icon: "arrow.down.left", color: .expense),
            Item(id: "transfer", action: .transfer, label: String(localized: "common.transfer"),
                 icon: "arrow.left.arrow.right", color: .transfer),
            Item(id: "receipt", action: .receipt, label: String(localized: "fab.receipt"),
                 icon: "doc.text.viewfinder", color: .budget),
        ]
        if includeDebtActions {
            items += [
                Item(id: "debt.lent", action: .debt(.lent), label: String(localized: "fab.debt.lent"),
                     icon: "arrow.up.forward.circle", color: .accent),
                Item(id: "debt.borrowed", action: .debt(.borrowed), label: String(localized: "fab.debt.borrowed"),
                     icon: "arrow.down.backward.circle", color: .accent),
            ]
        }
        return items
    }

    /// What a plain tap on the «+» does: quick entry, expense.
    static let tapAction: FABAction = .expense()
}

/// The floating «+» (1.6): one round accent-tinted glass button above the
/// tab bar, trailing.
///
/// - Tap: quick entry (`FABMenu.tapAction` → the quick-entry sheet, expense).
/// - Long press: the menu (income, expense, transfer, receipt; debts later)
///   grows out of the button — glass capsules that morph from it on iOS 26
///   (`AkifiGlassContainer` + `akifiGlassID`), material capsules before.
///   VoiceOver: the «Другие операции» action.
///
/// The pre-1.6 category wheel is retired: quick entry starts with predicted
/// category chips (and «Все» for the full list), and the full form is one
/// tap away there («Подробнее»).
///
/// Every choice leaves through `onAction(FABAction)`; `MainTabView` owns the
/// sheets.
struct FABView: View {
    @State private var isMenuExpanded = false
    @State private var didLongPress = false
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

            // MARK: - Button + menu
            if isButtonVisible || isMenuExpanded {
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
    }

    // MARK: - Button stack

    private var buttonStack: some View {
        AkifiGlassContainer(spacing: 12) {
            VStack(alignment: .trailing, spacing: 12) {
                if isMenuExpanded {
                    ForEach(FABMenu.items()) { item in
                        menuItemButton(item)
                    }
                }
                mainButton
            }
        }
    }

    private func menuItemButton(_ item: FABMenu.Item) -> some View {
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
            // A long press already opened the menu; its release must not
            // also count as a tap.
            if didLongPress {
                didLongPress = false
                return
            }
            if isMenuExpanded {
                setMenuExpanded(false)
                return
            }
            HapticManager.medium()
            onAction(FABMenu.tapAction)
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
                HapticManager.medium()
                setMenuExpanded(true)
            }
        )
        .spotlight(.fabButton)
        .accessibilityLabel(isMenuExpanded ? String(localized: "common.close") : String(localized: "fab.addTransaction"))
        .accessibilityHint(isMenuExpanded ? "" : String(localized: "fab.addHint"))
        .accessibilityAction(named: Text(String(localized: "fab.moreActions"))) {
            setMenuExpanded(true)
        }
    }

    // MARK: - Actions

    private func setMenuExpanded(_ expanded: Bool) {
        guard expanded != isMenuExpanded else { return }
        withAnimation(.spring(duration: 0.35, bounce: 0.2)) {
            isMenuExpanded = expanded
        }
    }
}
