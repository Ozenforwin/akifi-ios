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

    // MARK: - Subscription reminders

    private static func subscriptionReminderIdentifier(id: String) -> String {
        "sub-reminder-\(id)"
    }

    /// Requests notification authorization if needed, then schedules
    /// a local reminder for the given subscription.
    ///
    /// - Notes: Skips scheduling silently if the user has denied permission.
    ///   Always cancels any prior reminder with the same identifier first.
    static func scheduleSubscriptionReminder(
        id: String,
        serviceName: String,
        amount: Int64,
        currency: String,
        nextPaymentDate: Date,
        daysBefore: Int
    ) async {
        let center = UNUserNotificationCenter.current()

        // Ensure authorization (best-effort; request on first use).
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            _ = try? await center.requestAuthorization(options: [.alert, .badge, .sound])
        case .denied:
            return
        default:
            break
        }

        let identifier = subscriptionReminderIdentifier(id: id)
        center.removePendingNotificationRequests(withIdentifiers: [identifier])

        guard let fire = SubscriptionDateEngine.reminderFireDate(
            nextPaymentDate: nextPaymentDate,
            daysBefore: daysBefore
        ) else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = String(localized: "notification.subscription.title")
        content.body = daysBefore == 0
            ? String(localized: "notification.subscription.bodyToday \(serviceName)")
            : String(localized: "notification.subscription.body \(serviceName) \(daysBefore)")
        content.sound = .default
        content.userInfo = ["subscription_id": id, "amount": amount, "currency": currency]

        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        try? await center.add(request)
    }

    /// Cancels the pending reminder for a subscription (if any).
    static func cancelSubscriptionReminder(id: String) async {
        let identifier = subscriptionReminderIdentifier(id: id)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
    }
}
