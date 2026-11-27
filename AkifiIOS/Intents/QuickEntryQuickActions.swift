import UIKit

// Home-screen quick actions («Расход», «Доход», «Голосом» on a long press
// of the icon). The items are static (`UIApplicationShortcutItems` in
// project.yml, titles in InfoPlist.xcstrings); this file routes a tap into
// `QuickEntryInbox`, which the signed-in UI presents.
//
// SwiftUI has no quick-action API: the app delegate hands every new scene
// a delegate class that receives `performActionFor` (warm start) and the
// shortcut in the connection options (cold start). SwiftUI keeps managing
// the window — the class implements nothing else.

extension AppDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        if connectingSceneSession.role == .windowApplication {
            configuration.delegateClass = QuickEntrySceneDelegate.self
        }
        return configuration
    }
}

final class QuickEntrySceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let item = connectionOptions.shortcutItem {
            QuickEntryInbox.shared.handleShortcutItem(type: item.type)
        }
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(QuickEntryInbox.shared.handleShortcutItem(type: shortcutItem.type))
    }
}
