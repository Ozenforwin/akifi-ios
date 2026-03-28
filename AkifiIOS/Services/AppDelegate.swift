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

// Separate delegate class to avoid Sendable issues with Swift 6
final class NotificationDelegate: NSObject, MessagingDelegate, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationDelegate()

    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let token = fcmToken else { return }
        UserDefaults.standard.set(token, forKey: "fcmToken")
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .badge, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}
