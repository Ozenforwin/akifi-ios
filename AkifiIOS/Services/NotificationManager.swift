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

    // MARK: - Subscription reminders: one source per device (D9)
    //
    // A subscription reminder comes from exactly ONE place:
    //
    // - The server (`check-subscriptions`, daily cron) whenever it can push to
    //   this device. It owns the schedule — it charges and moves
    //   `next_payment_date` — dedupes per (subscription, payment date) in
    //   `subscription_reminder_events`, and also covers Telegram. A local copy
    //   went stale as soon as the cron moved the date, and doubled every
    //   reminder (09:00 local + the server's push).
    // - The device (local notification at 09:00) only while the server has
    //   no push channel to it, i.e. until this device's FCM token has been
    //   stored on the server (`recordServerPushRegistration`). On prod some
    //   iOS users have no stored token and get nothing from the server; for
    //   them the local reminder is the only one, so it stays as a fallback.

    private static let subscriptionReminderPrefix = "sub-reminder-"

    private static func subscriptionReminderIdentifier(id: String) -> String {
        subscriptionReminderPrefix + id
    }

    /// UserDefaults key: id of the user whose FCM token this device last
    /// stored on the server successfully.
    nonisolated static let serverPushUserIdKey = "notifications.subscriptionReminders.serverPushUserId"

    /// Call after `profiles.fcm_token` was written for this device (`userId`)
    /// or failed / the user signed out (`nil`).
    nonisolated static func recordServerPushRegistration(
        userId: String?,
        defaults: UserDefaults = .standard
    ) {
        if let userId {
            defaults.set(userId, forKey: serverPushUserIdKey)
        } else {
            defaults.removeObject(forKey: serverPushUserIdKey)
        }
    }

    /// True when the server pushes subscription reminders to this device for
    /// `userId` (any user when nil) — the device must then stay silent.
    nonisolated static func serverDeliversSubscriptionReminders(
        userId: String? = nil,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let registered = defaults.string(forKey: serverPushUserIdKey) else { return false }
        return userId == nil || registered == userId
    }

    /// What `rescheduleAllReminders` does with the device's pending
    /// subscription reminders.
    struct SubscriptionReminderPlan: Equatable, Sendable {
        /// Subscription ids to (re)schedule locally.
        var schedule: [String]
        /// Subscription ids whose pending local reminder must go.
        var cancel: [String]
    }

    /// Pure planning step of `rescheduleAllReminders`.
    ///
    /// Server delivers → every pending local reminder goes (including ones
    /// scheduled by builds before 1.5.7). Otherwise every active subscription
    /// with a future fire date is (re)scheduled — re-adding replaces a
    /// reminder whose date moved on another device or by the cron — and
    /// pending reminders of paused, cancelled, deleted or past-due ones go.
    nonisolated static func planSubscriptionReminders(
        subscriptions: [SubscriptionTracker],
        pendingIds: Set<String>,
        serverDelivers: Bool,
        now: Date = Date(),
        calendar: Calendar = AppDateFormatters.localCalendar
    ) -> SubscriptionReminderPlan {
        guard !serverDelivers else {
            return SubscriptionReminderPlan(schedule: [], cancel: pendingIds.sorted())
        }
        let schedule = subscriptions.compactMap { sub -> String? in
            guard sub.status == .active,
                  let next = SubscriptionDateEngine.parseDay(sub.nextPaymentDate, calendar: calendar),
                  SubscriptionDateEngine.reminderFireDate(
                      nextPaymentDate: next, daysBefore: sub.reminderDays, calendar: calendar, now: now
                  ) != nil else { return nil }
            return sub.id
        }
        let keep = Set(schedule)
        return SubscriptionReminderPlan(
            schedule: schedule,
            cancel: pendingIds.subtracting(keep).sorted()
        )
    }

    /// Schedules the device's local reminder for a subscription — unless the
    /// server delivers reminders to this device, in which case any local one
    /// is removed instead (see the section comment).
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
        guard !serverDeliversSubscriptionReminders() else {
            await cancelSubscriptionReminder(id: id)
            return
        }
        await scheduleLocalSubscriptionReminder(
            id: id, serviceName: serviceName, amount: amount, currency: currency,
            nextPaymentDate: nextPaymentDate, daysBefore: daysBefore
        )
    }

    private static func scheduleLocalSubscriptionReminder(
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

        let components = AppDateFormatters.localCalendar.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
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
    ///   - devices the server pushes to drop every local reminder (one source),
    ///   - newly installed devices / reinstalls re-register reminders that existed
    ///     purely in the OS notification center,
    ///   - subscriptions whose date or `status` changed outside the app (another
    ///     device, the server cron) get their reminders reconciled.
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
        let pendingIds: Set<String> = Set(
            pending
                .map(\.identifier)
                .filter { $0.hasPrefix(subscriptionReminderPrefix) }
                .map { String($0.dropFirst(subscriptionReminderPrefix.count)) }
        )

        let plan = planSubscriptionReminders(
            subscriptions: subscriptions,
            pendingIds: pendingIds,
            serverDelivers: serverDeliversSubscriptionReminders(userId: subscriptions.first?.userId)
        )
        center.removePendingNotificationRequests(
            withIdentifiers: plan.cancel.map(subscriptionReminderIdentifier(id:))
        )
        let byId = Dictionary(subscriptions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in plan.schedule {
            guard let sub = byId[id],
                  let nextDate = SubscriptionDateEngine.parseDbDate(sub.nextPaymentDate) else { continue }
            await scheduleLocalSubscriptionReminder(
                id: sub.id,
                serviceName: sub.serviceName,
                amount: sub.amount,
                currency: sub.currency ?? "RUB",
                nextPaymentDate: nextDate,
                daysBefore: sub.reminderDays
            )
        }
        let scheduledCount = plan.schedule.count
        let cancelledCount = plan.cancel.count

        if scheduledCount > 0 || cancelledCount > 0 {
            AnalyticsService.logRemindersRescheduled(scheduled: scheduledCount, cancelled: cancelledCount)
        }
        return (scheduledCount, cancelledCount)
    }

    // MARK: - Weekly Digest

    static let weeklyDigestId = "weekly-digest"

    /// Whether this device schedules its own weekly digest (N2) — one
    /// source per device, the same rule as subscription reminders (D9):
    /// - never unless the user opted in (`ai_user_settings.digest_opt_in`):
    ///   the toggle OFF means no digest at all (product decision
    ///   2026-11-27);
    /// - never while the user switched notifications off (`enabled`) — the
    ///   server skips those users too;
    /// - never while the server sends it here: it does every Monday to
    ///   opted-in users with a push channel to this device. The local copy
    ///   was built from the numbers of the last app launch and arrived on
    ///   top of the server's. The local one remains only for an opted-in
    ///   user the server cannot reach on this device yet.
    nonisolated static func shouldScheduleLocalWeeklyDigest(
        notificationsEnabled: Bool,
        digestOptIn: Bool,
        serverPushRegistered: Bool
    ) -> Bool {
        notificationsEnabled && digestOptIn && !serverPushRegistered
    }

    /// Schedules (or cancels) the local weekly digest for `userId` per
    /// `shouldScheduleLocalWeeklyDigest`, from the freshest settings it can
    /// get — the server rows when reachable, this user's cached ones else.
    static func syncWeeklyDigest(body: String, userId: String?) async {
        guard let userId else {
            cancelWeeklyDigest()
            return
        }
        let settings = await freshNotificationSettings(userId: userId)
        let optIn = await freshDigestOptIn(userId: userId)
        let schedule = shouldScheduleLocalWeeklyDigest(
            notificationsEnabled: settings?.enabled ?? NotificationSettings.defaults.enabled,
            digestOptIn: optIn,
            serverPushRegistered: serverDeliversSubscriptionReminders(userId: userId)
        )
        if schedule {
            await scheduleWeeklyDigest(body: body)
        } else {
            cancelWeeklyDigest()
        }
    }

    private static func freshNotificationSettings(userId: String) async -> NotificationSettings? {
        do {
            let row = try await withTimeout(seconds: 5) { try await NotificationRepository().fetchSettings() }
            if let row { NotificationPreferencesCache.store(row, userId: userId) }
            return row ?? NotificationPreferencesCache.settings(userId: userId)
        } catch {
            return NotificationPreferencesCache.settings(userId: userId)
        }
    }

    private static func freshDigestOptIn(userId: String) async -> Bool {
        do {
            let fetched = try await withTimeout(seconds: 5) { try await AiRepository().fetchSettings() }
            // No row = not opted in (the server's rule too).
            let optIn = fetched?.digestOptIn ?? false
            NotificationPreferencesCache.storeDigestOptIn(optIn, userId: userId)
            return optIn
        } catch {
            return NotificationPreferencesCache.digestOptIn(userId: userId)
        }
    }

    /// Schedule a repeating weekly digest notification for Sunday at 10:00 local time.
    /// The body is provided eagerly — the system shows a static message each week.
    /// For a dynamic body you would need a silent background refresh, which is out
    /// of scope here; this notification simply prompts the user to open the app.
    static func scheduleWeeklyDigest(body: String) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }

        center.removePendingNotificationRequests(withIdentifiers: [weeklyDigestId])

        let content = UNMutableNotificationContent()
        content.title = String(localized: "notification.weeklyDigest.title")
        content.body = body
        content.sound = .default
        content.userInfo = ["tab": "journal"]

        var components = DateComponents()
        components.weekday = 1  // Sunday (1 = Sunday in UNCalendarNotificationTrigger)
        components.hour = 10
        components.minute = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)

        let request = UNNotificationRequest(identifier: weeklyDigestId, content: content, trigger: trigger)
        try? await center.add(request)
    }

    static func cancelWeeklyDigest() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [weeklyDigestId])
    }
}
