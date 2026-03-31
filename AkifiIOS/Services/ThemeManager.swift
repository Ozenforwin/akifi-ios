import SwiftUI

@Observable @MainActor
final class ThemeManager {
    var selectedScheme: ColorScheme?

    private static let key = "appThemePreference"

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.key)
        switch saved {
        case "light": selectedScheme = .light
        case "dark": selectedScheme = .dark
        default: selectedScheme = nil // system
        }
    }

    func setTheme(_ scheme: ColorScheme?) {
        selectedScheme = scheme
        switch scheme {
        case .light: UserDefaults.standard.set("light", forKey: Self.key)
        case .dark: UserDefaults.standard.set("dark", forKey: Self.key)
        case nil: UserDefaults.standard.removeObject(forKey: Self.key)
        @unknown default: UserDefaults.standard.removeObject(forKey: Self.key)
        }
    }

    var themeName: String {
        switch selectedScheme {
        case .light: return String(localized: "theme.light")
        case .dark: return String(localized: "theme.dark")
        case nil: return String(localized: "theme.system")
        @unknown default: return String(localized: "theme.system")
        }
    }
}
