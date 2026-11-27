#if DEBUG
import SwiftUI
import UIKit

/// DEBUG-only screenshot harness: the signed-in UI with fixture data, no
/// sign-in and no network. Compiled out of Release builds entirely.
/// Interactions (open the «+» menu, switch tabs, swipe to minimise the tab
/// bar) are driven from outside with `idb ui tap/swipe`.
///
/// Launch arguments (`xcrun simctl launch <device> ru.akifi.app <args>`):
///
/// | Argument | Effect |
/// |---|---|
/// | `-AkifiUIHarness` | enable the harness (required) |
/// | `-AkifiUIHarnessTab <name>` | start on a tab: home, transactions, analytics, budgets, assistant |
/// | `-AkifiUIHarnessScroll <points>` | scroll the visible list down after launch (collapses the large title; the iOS 26 tab bar minimises only on a real drag — `idb ui swipe`) |
/// | `-AkifiUIHarnessBanners` | show the data-issue and auto-match banners |
/// | `-AkifiUIHarnessGallery` | design-system gallery instead of the tabs |
/// | `-AkifiUIHarnessScreen <name>` | open one screen directly (`UIHarnessScreen` in `UIHarnessScreens.swift`) |
/// | `-AkifiUIHarnessSweep <name>` | Transactions / Assistant / Auth / onboarding screens and sheets (`UIHarnessSweepScreen` in `UIHarnessSweepScreens.swift`) |
/// | `-AkifiUIHarnessCapture <dir> -AkifiUIHarnessPlan name@look,…` | the app snapshots each planned `UIHarnessSweepScreen` into `<dir>` itself |
/// | `-AkifiUIHarnessQuickEntry <state>` | quick-entry sheet with a Russian fixture: empty, typed, voice (`UIHarnessQuickEntry`) |
/// | `-AkifiUIHarnessWidgets` | UUID-id accounts + «Повторить» history written into the App Group snapshot, for the real widgets (`UIHarnessWidgets`); `-AkifiUIHarnessWidgetsMany` adds five more accounts |
/// | `-AkifiUIHarnessCover <screen>` | account covers: homeBright, homeDark, crop, ownerSection, memberSection, shared (`UIHarnessCovers.swift`) |
/// | `-spotlight_completed YES` / `NO` | hide / start the onboarding tour (UserDefaults argument domain) |
enum UIHarness {
    private static var arguments: [String] { ProcessInfo.processInfo.arguments }

    static var isEnabled: Bool { arguments.contains("-AkifiUIHarness") }
    static var showsBanners: Bool { arguments.contains("-AkifiUIHarnessBanners") }
    static var showsGallery: Bool { arguments.contains("-AkifiUIHarnessGallery") }

    static var initialTab: AppTab? {
        guard let name = value(after: "-AkifiUIHarnessTab")?.lowercased() else { return nil }
        return AppTab.allCases.first { $0.screenName.lowercased() == name }
    }

    static var scrollOffset: CGFloat? {
        value(after: "-AkifiUIHarnessScroll").flatMap(Double.init).map { CGFloat($0) }
    }

    private static func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    // MARK: - Fixture

    @MainActor
    static func makeAppViewModel() -> AppViewModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AkifiUIHarness", isDirectory: true)
        let store = DataStore(cache: PersistenceManager(directory: directory))
        let app = AppViewModel(dataStore: store)
        // Supabase answered from fixtures, journal seams (UIHarnessScreens.swift).
        UIHarnessScreens.prepare(app)
        // No session here: nothing may sign the fixture out.
        store.onSessionMissing = {}
        app.authManager.onSessionEnded = nil
        app.currencyManager.rates = ["USD": 1, "RUB": 92.5, "EUR": 0.92]

        store.profile = Profile(
            id: "demo", email: "anna@example.com", fullName: "Анна",
            avatarUrl: nil, defaultCurrency: "RUB",
            telegramUserId: nil, telegramChatId: nil, telegramLinkedAt: nil,
            updatedAt: nil
        )
        store.allAccounts = DemoData.accounts
        store.categories = DemoData.categories
        store.transactions = (DemoData.transactions + extraTransactions())
            .sorted { $0.date > $1.date }
        store.budgets = [DemoData.budget]
        store.subscriptions = DemoData.subscriptions
        store.rebuildCaches()
        store.currencyContextDidChange()
        // Account covers (UIHarnessCovers.swift): cover accounts first.
        if let covered = UIHarnessCovers.accounts {
            store.allAccounts = covered
            store.rebuildCaches()
        }

        if UIHarnessQuickEntry.isEnabled {
            store.allAccounts = UIHarnessQuickEntry.accounts
            UIHarnessQuickEntry.install(in: store)
            if let request = UIHarnessQuickEntry.request() {
                QuickEntryInbox.shared.submit(request)
            }
        }
        if UIHarnessWidgets.isEnabled {
            UIHarnessWidgets.install(in: store, currencyManager: app.currencyManager)
        }
        if showsBanners {
            store.reportIssue(.load, message: String(localized: "sync.error.partialLoad"))
            store.pendingAutoMatch = DataStore.PendingAutoMatch(
                subscriptionId: "demo-sub-1",
                subscriptionName: "Netflix",
                paymentId: "harness-payment",
                previousLastPaymentDate: nil,
                previousNextPaymentDate: nil
            )
        }
        if let tab = initialTab {
            app.pendingDeepLink = .tab(tab)
        }
        return app
    }

    /// Enough rows for the lists to scroll.
    private static func extraTransactions() -> [Transaction] {
        let categories = ["demo-cat-1", "demo-cat-2", "demo-cat-3", "demo-cat-4", "demo-cat-5"]
        return (0..<30).map { i in
            let day = AppDateFormatters.isoDate.string(
                from: Calendar.current.date(byAdding: .day, value: -(12 + i), to: Date()) ?? Date()
            )
            return Transaction(
                id: "harness-tx-\(i)", userId: "demo", accountId: "demo-acc-1",
                amount: Int64(300_00 + i * 137_00), currency: "RUB", description: "Покупка \(i + 1)",
                categoryId: categories[i % categories.count], type: .expense, date: day,
                merchantName: nil, merchantFuzzy: nil, transferGroupId: nil,
                status: nil, createdAt: day, updatedAt: nil
            )
        }
    }

    // MARK: - Scrolling

    /// Scrolls the largest visible scroll view down by `offset` points.
    @MainActor
    static func scrollVisibleList(by offset: CGFloat) {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        else { return }
        var candidates: [UIScrollView] = []
        func collect(_ view: UIView) {
            if let scroll = view as? UIScrollView,
               scroll.isScrollEnabled,
               scroll.contentSize.height > scroll.bounds.height,
               scroll.window != nil,
               !scroll.isHidden, scroll.alpha > 0.01,
               scroll.convert(scroll.bounds, to: nil).intersects(window.bounds) {
                candidates.append(scroll)
            }
            view.subviews.forEach(collect)
        }
        collect(window)
        guard let target = candidates.max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height })
        else { return }
        let y = min(target.contentOffset.y + offset,
                    target.contentSize.height - target.bounds.height + target.adjustedContentInset.bottom)
        target.setContentOffset(CGPoint(x: target.contentOffset.x, y: y), animated: true)
    }
}

/// Root of the harness: the fixture app view model around the tabs (or the
/// gallery).
struct UIHarnessRoot: View {
    @State private var app = UIHarness.makeAppViewModel()

    var body: some View {
        Group {
            if let directory = UIHarnessCapture.directory {
                // In-app capture of a plan of screens (UIHarnessSweepScreens.swift).
                UIHarnessCaptureRoot(steps: UIHarnessCapture.plan, directory: directory)
            } else if let screen = UIHarnessCoverScreen.requested {
                // Account covers (UIHarnessCovers.swift).
                UIHarnessCoverScreenView(screen: screen)
            } else if let screen = UIHarnessSweepScreen.requested {
                // Transactions / Assistant / Auth sweep screens (UIHarnessSweepScreens.swift).
                UIHarnessSweepScreenView(screen: screen)
            } else if let screen = UIHarnessScreen.current {
                UIHarnessScreenHost(screen: screen)
            } else if UIHarness.showsGallery {
                DesignSystemGallery()
            } else {
                MainTabView()
            }
        }
        .environment(app)
        // Same routing as `ContentView`: widget / quick-add links can be
        // tried on the fixture (`xcrun simctl openurl <id> akifi://…`).
        .onOpenURL { url in
            app.open(url)
        }
        .task {
            guard let offset = UIHarness.scrollOffset else { return }
            try? await Task.sleep(for: .seconds(2))
            UIHarness.scrollVisibleList(by: offset)
        }
    }
}

// MARK: - Design-system gallery

/// Every `Glass.swift` component on one screen, over colourful content so
/// the glass has something to refract.
private struct DesignSystemGallery: View {
    @Namespace private var namespace

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    section("Banners (.akifiGlassBanner)") {
                        VStack(spacing: 8) {
                            OfflineBanner(pendingCount: 3)
                            DataIssueBanner(
                                issue: DataStore.Issue(kind: .load, message: String(localized: "sync.error.partialLoad")),
                                onRetry: {},
                                onDismiss: {}
                            )
                        }
                        .padding(.horizontal, -16)
                    }

                    section("Buttons (.akifiPrimary / .akifiSecondary)") {
                        HStack {
                            Button(String(localized: "common.continue")) {}
                                .buttonStyle(.akifiPrimary)
                            Button(String(localized: "common.close")) {}
                                .buttonStyle(.akifiSecondary)
                            Button(String(localized: "common.delete"), role: .destructive) {}
                                .buttonStyle(.akifiSecondary)
                        }
                    }

                    section("Glass controls (.akifiGlass, AkifiGlassContainer)") {
                        ZStack {
                            LinearGradient(colors: [.income, .accent, .budget],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                                .frame(height: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                            AkifiGlassContainer(spacing: 12) {
                                HStack(spacing: 12) {
                                    Image(systemName: "plus")
                                        .font(.title2.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .frame(width: 56, height: 56)
                                        .akifiGlass(in: Circle(), tint: .accent, interactive: true)
                                        .akifiGlassID("plus", in: namespace)
                                    Label(String(localized: "common.expense"), systemImage: "arrow.down.left")
                                        .font(.body.weight(.semibold))
                                        .padding(.horizontal, 18)
                                        .frame(minHeight: 48)
                                        .akifiGlass(interactive: true)
                                        .akifiGlassID("expense", in: namespace)
                                }
                            }
                        }
                    }

                    section("Content cards (.akifiCard) — not glass") {
                        VStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: "128 450 ₽")
                                    .font(.title.weight(.semibold))
                                    .monospacedDigit()
                                Text(verbatim: "Chase Checking")
                                    .foregroundStyle(.secondary)
                            }
                            .akifiCard()
                            Text(verbatim: "Compact card — 12 pt corners")
                                .akifiCard(.compact)
                        }
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(Text(verbatim: "Glass.swift"))
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}
#endif
