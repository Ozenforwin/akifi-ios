import UIKit
import FirebaseCore
import FirebaseMessaging
import FirebaseCrashlytics
import GoogleSignIn

class AppDelegate: NSObject, UIApplicationDelegate, @unchecked Sendable {

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        FirebaseApp.configure()

        // Configure Google Sign In with client ID from Firebase
        if let clientID = FirebaseApp.app()?.options.clientID {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        }

        // Push notifications
        let delegate = NotificationDelegate.shared
        Messaging.messaging().delegate = delegate
        UNUserNotificationCenter.current().delegate = delegate

        application.registerForRemoteNotifications()

        return true
    }

    // MARK: - APNs Token

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Messaging.messaging().apnsToken = deviceToken
    }

    // MARK: - Google Sign In URL handling

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        return GIDSignIn.sharedInstance.handle(url)
    }
}

// MARK: - Notification Delegate

final class NotificationDelegate: NSObject, MessagingDelegate, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationDelegate()
    private let notifRepo = NotificationRepository()

    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let token = fcmToken else { return }
        _ = KeychainService.save(key: "fcmToken", string: token)
        // Send to Supabase for server-side push delivery
        Task { await notifRepo.registerFCMToken(token) }
    }

    // Show push when app is in foreground
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .badge, .sound])
    }

    // Handle push tap — deep link to relevant screen
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        if let tab = userInfo["tab"] as? String {
            NotificationCenter.default.post(name: .pushNotificationTapped, object: nil, userInfo: ["tab": tab])
        }
        completionHandler()
    }
}

extension Notification.Name {
    static let pushNotificationTapped = Notification.Name("pushNotificationTapped")
}
