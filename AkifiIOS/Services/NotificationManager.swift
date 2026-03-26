import Foundation
import UserNotifications

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
        content.title = "Бюджет: \(budgetName)"
        content.body = "Использовано \(percentage)% бюджета. Следите за расходами!"
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
        content.title = "Крупный расход"
        content.body = "Зафиксирован расход на \(amount). Проверьте операцию."
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
        content.title = "Давно не заходили"
        content.body = "Не забывайте записывать расходы. Так легче контролировать бюджет!"
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
        content.title = "Цель: \(goalName)"
        content.body = "Поздравляем! Вы достигли \(milestone)% цели!"
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
