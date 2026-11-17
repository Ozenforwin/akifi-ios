import Foundation

@Observable @MainActor
final class SubscriptionsViewModel {
    var subscriptions: [SubscriptionTracker] = []
    var isLoading = false
    var error: String?
    var showForm = false

    private let repo = SubscriptionTrackerRepository()

    // MARK: - Derived collections

    var activeSubscriptions: [SubscriptionTracker] {
        subscriptions.filter { $0.status == .active }
    }

    var pausedSubscriptions: [SubscriptionTracker] {
        subscriptions.filter { $0.status == .paused }
    }

    var archivedSubscriptions: [SubscriptionTracker] {
        subscriptions.filter { $0.status == .cancelled }
    }

    /// Monthly total is computed over **active** subscriptions only — paused ones
    /// are not currently billing and cancelled ones are archived.
    var monthlyTotal: Int64 {
        activeSubscriptions.reduce(Int64(0)) { total, sub in
            switch sub.billingPeriod {
            case .weekly: total + sub.amount * 4
            case .monthly: total + sub.amount
            case .quarterly: total + sub.amount / 3
            case .yearly: total + sub.amount / 12
            case .custom: total + sub.amount
            }
        }
    }

    func load() async {
        isLoading = true
        error = nil
        do {
            subscriptions = try await repo.fetchAll()
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Create

    /// Legacy call site used by `SubscriptionListView` and `BudgetsTabView` without explicit dates.
    /// Delegates to the new API with `lastPaymentDate: nil` and `nextPaymentDate` = today + period.
    // `userId` parameter kept for API compatibility with existing call sites.
    // We ignore it and always source user_id from the Supabase session to
    // prevent "wrong/stale user_id" → RLS violations.
    func create(name: String, amount: Int64, period: BillingPeriod, color: String?,
                currency: String = "RUB", reminderDays: Int = 1, userId: String = "") async {
        let today = Calendar.current.startOfDay(for: Date())
        let nextPayment = SubscriptionDateEngine.nextPaymentDate(from: today, period: period)
        await create(
            name: name,
            amount: amount,
            period: period,
            color: color,
            currency: currency,
            reminderDays: reminderDays,
            lastPaymentDate: nil,
            nextPaymentDate: nextPayment,
            categoryId: nil,
            accountId: nil
        )
    }

    /// New API: explicit dates from the form.
    /// Returns `false` on failure with the message in `self.error` — callers
    /// that drive a form MUST surface it; a swallowed create error looks
    /// like "the subscription silently didn't save" to the user.
    @discardableResult
    func create(name: String, amount: Int64, period: BillingPeriod, color: String?,
                currency: String, reminderDays: Int,
                lastPaymentDate: Date?, nextPaymentDate: Date,
                categoryId: String? = nil,
                accountId: String? = nil) async -> Bool {
        error = nil
        do {
            let resolvedUserId = try await SupabaseManager.shared.currentUserId()
            let amountDecimal = Decimal(amount) / 100
            let nextStr = SubscriptionDateEngine.formatDbDate(nextPaymentDate)
            let lastStr = lastPaymentDate.map(SubscriptionDateEngine.formatDbDate)
            // start_date is the schedule anchor the server bills from
            // (SubscriptionDateEngine contract): the last payment — or today
            // when none was given — if the chosen next date is on its
            // schedule, otherwise the next date itself.
            let anchor = SubscriptionDateEngine.resolveAnchor(
                candidates: [lastPaymentDate ?? Date()],
                nextPayment: nextPaymentDate,
                period: period
            )
            let input = CreateSubscriptionInput(
                user_id: resolvedUserId,
                service_name: name,
                amount: amountDecimal,
                billing_period: period.rawValue,
                start_date: SubscriptionDateEngine.formatDbDate(anchor),
                last_payment_date: lastStr,
                next_payment_date: nextStr,
                icon_color: color,
                reminder_days: reminderDays,
                currency: currency,
                status: SubscriptionTrackerStatus.active.rawValue,
                category_id: categoryId,
                account_id: accountId
            )
            let sub = try await repo.create(input)
            subscriptions.append(sub)
            await scheduleReminder(for: sub)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    // MARK: - Update

    /// Returns `false` on failure with the message in `self.error` — see `create`.
    @discardableResult
    func update(id: String, name: String, amount: Int64, period: BillingPeriod,
                color: String?, currency: String, reminderDays: Int,
                lastPaymentDate: Date?, nextPaymentDate: Date,
                status: SubscriptionTrackerStatus? = nil,
                categoryId: String? = nil,
                accountId: String? = nil) async -> Bool {
        error = nil
        do {
            let amountDecimal = Decimal(amount) / 100
            let startDate = Self.startDateToWrite(
                stored: subscriptions.first(where: { $0.id == id }),
                period: period,
                lastPaymentDate: lastPaymentDate,
                nextPaymentDate: nextPaymentDate
            )
            let input = UpdateSubscriptionInput(
                service_name: name,
                amount: amountDecimal,
                billing_period: period.rawValue,
                start_date: startDate,
                last_payment_date: lastPaymentDate.map(SubscriptionDateEngine.formatDbDate),
                next_payment_date: SubscriptionDateEngine.formatDbDate(nextPaymentDate),
                icon_color: color,
                reminder_days: reminderDays,
                currency: currency,
                status: status?.rawValue,
                category_id: categoryId,
                account_id: accountId
            )
            try await repo.update(id: id, input)
            if let idx = subscriptions.firstIndex(where: { $0.id == id }) {
                var sub = subscriptions[idx]
                sub.serviceName = name
                sub.amount = amount
                sub.billingPeriod = period
                sub.currency = currency
                sub.reminderDays = reminderDays
                sub.iconColor = color
                sub.categoryId = categoryId
                sub.accountId = accountId
                if let startDate { sub.startDate = startDate }
                sub.lastPaymentDate = lastPaymentDate.map(SubscriptionDateEngine.formatDbDate)
                sub.nextPaymentDate = SubscriptionDateEngine.formatDbDate(nextPaymentDate)
                if let status {
                    sub.status = status
                    sub.isActive = (status == .active)
                }
                subscriptions[idx] = sub
                await applyReminderPolicy(for: sub)
            }
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// The `start_date` (schedule anchor) an edit must write, or nil to leave
    /// it alone.
    ///
    /// Only when the schedule itself changed — the next date or the period.
    /// Then the stored anchor is kept if the new next date is still on its
    /// schedule (a 31st billing day survives February), else the last
    /// payment, else the next date.
    ///
    /// Leaving it alone otherwise also keeps the DB trigger
    /// `subscription_set_default_next_payment` quiet: it recomputes
    /// next_payment_date whenever start_date changes while next_payment_date
    /// does not.
    nonisolated static func startDateToWrite(
        stored: SubscriptionTracker?,
        period: BillingPeriod,
        lastPaymentDate: Date?,
        nextPaymentDate: Date
    ) -> String? {
        let nextStr = SubscriptionDateEngine.formatDbDate(nextPaymentDate)
        if let stored,
           stored.billingPeriod == period,
           stored.nextPaymentDate.map({ String($0.prefix(10)) }) == nextStr {
            return nil
        }
        let anchor = SubscriptionDateEngine.resolveAnchor(
            candidates: [SubscriptionDateEngine.parseDbDate(stored?.startDate), lastPaymentDate],
            nextPayment: nextPaymentDate,
            period: period
        )
        let anchorStr = SubscriptionDateEngine.formatDbDate(anchor)
        return anchorStr == stored.map({ String($0.startDate.prefix(10)) }) ? nil : anchorStr
    }

    // MARK: - Status transitions

    /// Change subscription status. Cancels reminders on pause/cancel, schedules on resume.
    func setStatus(_ newStatus: SubscriptionTrackerStatus, for subscriptionId: String) async {
        do {
            try await repo.updateStatus(id: subscriptionId, newStatus)
            if let idx = subscriptions.firstIndex(where: { $0.id == subscriptionId }) {
                var sub = subscriptions[idx]
                sub.status = newStatus
                sub.isActive = (newStatus == .active)
                subscriptions[idx] = sub
                await applyReminderPolicy(for: sub)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Delete

    func delete(_ sub: SubscriptionTracker) async {
        do {
            try await repo.delete(id: sub.id)
            // Keep archived row in memory as cancelled so it can reappear in archive view.
            if let idx = subscriptions.firstIndex(where: { $0.id == sub.id }) {
                var updated = subscriptions[idx]
                updated.status = .cancelled
                updated.isActive = false
                subscriptions[idx] = updated
            }
            await NotificationManager.cancelSubscriptionReminder(id: sub.id)
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Record payment (atomic-ish)

    /// Records a payment, advances the subscription's `lastPaymentDate`,
    /// recalculates `nextPaymentDate`, and reschedules the reminder.
    ///
    /// The next date follows the schedule (anchor + k periods), not the
    /// payment day: paying on the 20th for a subscription billed on the 17th
    /// keeps the 17th. Recording an older payment never moves
    /// `nextPaymentDate` or `lastPaymentDate` backwards.
    ///
    /// Not a DB transaction — payment row is created first (source of truth),
    /// then subscription dates are patched. See ADR-004.
    @discardableResult
    func recordPayment(subscriptionId: String, amount: Int64, date: Date) async -> SubscriptionPayment? {
        guard let sub = subscriptions.first(where: { $0.id == subscriptionId }) else { return nil }
        let currency = sub.currency ?? "RUB"
        let amountDecimal = Decimal(amount) / 100
        let paymentDateStr = SubscriptionDateEngine.formatDbDate(date)

        let insertInput = CreateSubscriptionPaymentInput(
            subscription_id: subscriptionId,
            amount: amountDecimal,
            currency: currency,
            payment_date: paymentDateStr
        )

        do {
            let payment = try await repo.addPayment(insertInput)

            let nextPayment = SubscriptionDateEngine.nextPaymentDate(for: sub, afterPaymentOn: date)
            let nextStr = SubscriptionDateEngine.formatDbDate(nextPayment)
            let lastStr = max(paymentDateStr, sub.lastPaymentDate.map { String($0.prefix(10)) } ?? "")
            try await repo.updateDates(id: subscriptionId, lastPaymentDate: lastStr, nextPaymentDate: nextStr)

            if let idx = subscriptions.firstIndex(where: { $0.id == subscriptionId }) {
                var updated = subscriptions[idx]
                updated.lastPaymentDate = lastStr
                updated.nextPaymentDate = nextStr
                subscriptions[idx] = updated
                await scheduleReminder(for: updated)
            }

            return payment
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    /// Undo a previously recorded payment: delete the payment row, restore the
    /// subscription's `lastPaymentDate` / `nextPaymentDate` to the supplied
    /// previous values. Used by the auto-match undo banner.
    func undoPayment(
        paymentId: String,
        subscriptionId: String,
        previousLastPaymentDate: String?,
        previousNextPaymentDate: String?
    ) async {
        do {
            try await repo.deletePayment(id: paymentId)
            try await repo.updateDates(
                id: subscriptionId,
                lastPaymentDate: previousLastPaymentDate,
                nextPaymentDate: previousNextPaymentDate
            )
            if let idx = subscriptions.firstIndex(where: { $0.id == subscriptionId }) {
                var updated = subscriptions[idx]
                updated.lastPaymentDate = previousLastPaymentDate
                updated.nextPaymentDate = previousNextPaymentDate
                subscriptions[idx] = updated
                await scheduleReminder(for: updated)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Notifications

    private func scheduleReminder(for sub: SubscriptionTracker) async {
        guard sub.status == .active else { return }
        guard let nextStr = sub.nextPaymentDate,
              let nextDate = SubscriptionDateEngine.parseDbDate(nextStr) else { return }
        await NotificationManager.scheduleSubscriptionReminder(
            id: sub.id,
            serviceName: sub.serviceName,
            amount: sub.amount,
            currency: sub.currency ?? "RUB",
            nextPaymentDate: nextDate,
            daysBefore: sub.reminderDays
        )
    }

    /// Ensures the notification state matches subscription status:
    /// schedules on active, cancels on paused/cancelled.
    private func applyReminderPolicy(for sub: SubscriptionTracker) async {
        if sub.status == .active {
            await scheduleReminder(for: sub)
        } else {
            await NotificationManager.cancelSubscriptionReminder(id: sub.id)
        }
    }
}
