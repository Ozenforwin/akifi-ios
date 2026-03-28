import SwiftUI
import Supabase

@main
struct AkifiApp: App {
    @State private var appViewModel = AppViewModel()

    init() {
        // Navigation bar: transparent when at top, opaque when scrolled
        let navAppearance = UINavigationBarAppearance()
        navAppearance.configureWithTransparentBackground()
        UINavigationBar.appearance().standardAppearance = navAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navAppearance
        UINavigationBar.appearance().compactAppearance = navAppearance
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appViewModel)
                .preferredColorScheme(appViewModel.themeManager.selectedScheme)
        }
    }
}
