import SwiftUI
import Supabase
import FirebaseCore
import FirebaseMessaging

@main
struct AkifiApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var appViewModel = AppViewModel()

    init() {
        // Navigation bar: transparent when at top, opaque when scrolled
        let navAppearance = UINavigationBarAppearance()
        navAppearance.configureWithTransparentBackground()
        UINavigationBar.appearance().standardAppearance = navAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navAppearance
        UINavigationBar.appearance().compactAppearance = navAppearance

        // Dismiss keyboard on scroll/tap in all scrollable views
        UIScrollView.appearance().keyboardDismissMode = .interactiveWithAccessory
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appViewModel)
                .preferredColorScheme(appViewModel.themeManager.selectedScheme)
                .onAppear { installTapToDismissKeyboard() }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                // App returned to foreground — refresh auth token proactively
                // so subsequent requests don't hit 401 with a stale access
                // token; then drain writes queued while the session was stale
                // (the queue never replays without a valid session).
                Task {
                    await appViewModel.authManager.refreshSessionIfNeeded()
                    guard appViewModel.authManager.isAuthenticated else { return }
                    await appViewModel.dataStore.syncPendingOperations()
                }
            case .background:
                // Debounced widget snapshot and background cache writes must
                // land before the process may be suspended.
                appViewModel.dataStore.flushPendingWrites()
            default:
                break
            }
        }
    }

    private func installTapToDismissKeyboard() {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first else { return }
        let tap = UITapGestureRecognizer(target: window, action: #selector(UIView.endEditing))
        tap.cancelsTouchesInView = false
        window.addGestureRecognizer(tap)
    }
}
