import Foundation
@preconcurrency import UserNotifications

@Observable @MainActor
final class NotificationManager {
    var isAuthorized = false

    func requestAuthorization() async {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])
            isAuthorized = granted
        } catch {
            isAuthorized = false
        }
    }

    func checkAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        isAuthorized = settings.authorizationStatus == .authorized
    }

    func scheduleBudgetWarning(budgetName: String, percentage: Int) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "notification.budget.title \(budgetName)")
        content.body = String(localized: "notification.budget.body \(percentage)")
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(
            identifier: "budget-\(budgetName)-\(percentage)",
            content: content,
            trigger: trigger
        )

        UNUserNotificationCenter.current().add(request)
    }

    func scheduleLargeExpenseAlert(amount: String) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "notification.largeExpense.title")
        content.body = String(localized: "notification.largeExpense.body \(amount)")
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(
            identifier: "large-expense-\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )

        UNUserNotificationCenter.current().add(request)
    }

    func scheduleInactivityReminder(days: Int = 3) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "notification.inactivity.title")
        content.body = String(localized: "notification.inactivity.body")
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: TimeInterval(days * 86400),
            repeats: false
        )
        let request = UNNotificationRequest(
            identifier: "inactivity-reminder",
            content: content,
            trigger: trigger
        )

        UNUserNotificationCenter.current().add(request)
    }

    func scheduleSavingsMilestone(goalName: String, milestone: Int) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "notification.savings.title \(goalName)")
        content.body = String(localized: "notification.savings.body \(milestone)")
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(
            identifier: "savings-\(goalName)-\(milestone)",
            content: content,
            trigger: trigger
        )

        UNUserNotificationCenter.current().add(request)
    }

    func removeAllPending() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }
}
