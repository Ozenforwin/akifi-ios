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

    /// Walks the entire subscription list and brings pending local notifications
    /// back into alignment with each subscription's desired state.
    ///
    /// Runs at app startup (and after `loadAll`) so that:
    ///   - newly installed devices / reinstalls re-register reminders that existed
    ///     purely in the OS notification center,
    ///   - legacy subscriptions created before v1.2.2 get reminders on first run,
    ///   - subscriptions whose `status` was changed outside the app (e.g. via
    ///     another device) get their reminders reconciled.
    ///
    /// Side effects: schedules/cancels via `UNUserNotificationCenter`. Returns a
    /// tuple `(scheduled, cancelled)` with the number of operations performed,
    /// suitable for analytics / logging.
    @discardableResult
    static func rescheduleAllReminders(subscriptions: [SubscriptionTracker]) async -> (scheduled: Int, cancelled: Int) {
        let center = UNUserNotificationCenter.current()

        // Skip if user has denied notifications.
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus != .denied else { return (0, 0) }

        let pending = await center.pendingNotificationRequests()
        let scheduledIds: Set<String> = Set(
            pending
                .map(\.identifier)
                .filter { $0.hasPrefix("sub-reminder-") }
                .map { String($0.dropFirst("sub-reminder-".count)) }
        )

        var scheduledCount = 0
        var cancelledCount = 0

        for sub in subscriptions {
            let isScheduled = scheduledIds.contains(sub.id)

            switch sub.status {
            case .active:
                // Need a reminder — only schedule if missing and date is in the future.
                guard !isScheduled else { continue }
                guard let nextStr = sub.nextPaymentDate,
                      let nextDate = SubscriptionDateEngine.parseDbDate(nextStr),
                      nextDate > Date() else { continue }
                await scheduleSubscriptionReminder(
                    id: sub.id,
                    serviceName: sub.serviceName,
                    amount: sub.amount,
                    currency: sub.currency ?? "RUB",
                    nextPaymentDate: nextDate,
                    daysBefore: sub.reminderDays
                )
                scheduledCount += 1

            case .paused, .cancelled:
                // Must NOT have a reminder.
                guard isScheduled else { continue }
                await cancelSubscriptionReminder(id: sub.id)
                cancelledCount += 1
            }
        }

        if scheduledCount > 0 || cancelledCount > 0 {
            AnalyticsService.logRemindersRescheduled(scheduled: scheduledCount, cancelled: cancelledCount)
        }
        return (scheduledCount, cancelledCount)
    }
}
