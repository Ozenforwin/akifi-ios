import UIKit
import FirebaseCore
import FirebaseMessaging
import FirebaseCrashlytics

class AppDelegate: NSObject, UIApplicationDelegate, @unchecked Sendable {

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        FirebaseApp.configure()

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
}

// MARK: - Notification Delegate

final class NotificationDelegate: NSObject, MessagingDelegate, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationDelegate()
    private let notifRepo = NotificationRepository()

    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let token = fcmToken else { return }
        UserDefaults.standard.set(token, forKey: "fcmToken")
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
