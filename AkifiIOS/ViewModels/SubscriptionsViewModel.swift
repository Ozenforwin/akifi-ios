import Foundation

@Observable @MainActor
final class SubscriptionsViewModel {
    var subscriptions: [SubscriptionTracker] = []
    var isLoading = false
    var error: String?
    var showForm = false

    private let repo = SubscriptionTrackerRepository()

    var monthlyTotal: Int64 {
        subscriptions.reduce(Int64(0)) { total, sub in
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
            nextPaymentDate: nextPayment
        )
    }

    /// New API: explicit dates from the form.
    func create(name: String, amount: Int64, period: BillingPeriod, color: String?,
                currency: String, reminderDays: Int,
                lastPaymentDate: Date?, nextPaymentDate: Date) async {
        do {
            let resolvedUserId = try await SupabaseManager.shared.currentUserId()
            let amountDecimal = Decimal(amount) / 100
            let nextStr = SubscriptionDateEngine.formatDbDate(nextPaymentDate)
            let lastStr = lastPaymentDate.map(SubscriptionDateEngine.formatDbDate)
            let input = CreateSubscriptionInput(
                user_id: resolvedUserId,
                service_name: name,
                amount: amountDecimal,
                billing_period: period.rawValue,
                start_date: lastStr ?? SubscriptionDateEngine.formatDbDate(Date()),
                last_payment_date: lastStr,
                next_payment_date: nextStr,
                icon_color: color,
                reminder_days: reminderDays,
                currency: currency
            )
            let sub = try await repo.create(input)
            subscriptions.append(sub)
            await scheduleReminder(for: sub)
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Update

    func update(id: String, name: String, amount: Int64, period: BillingPeriod,
                color: String?, currency: String, reminderDays: Int,
                lastPaymentDate: Date?, nextPaymentDate: Date) async {
        do {
            let amountDecimal = Decimal(amount) / 100
            let input = UpdateSubscriptionInput(
                service_name: name,
                amount: amountDecimal,
                billing_period: period.rawValue,
                start_date: nil,
                last_payment_date: lastPaymentDate.map(SubscriptionDateEngine.formatDbDate),
                next_payment_date: SubscriptionDateEngine.formatDbDate(nextPaymentDate),
                icon_color: color,
                reminder_days: reminderDays,
                currency: currency
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
                sub.lastPaymentDate = lastPaymentDate.map(SubscriptionDateEngine.formatDbDate)
                sub.nextPaymentDate = SubscriptionDateEngine.formatDbDate(nextPaymentDate)
                subscriptions[idx] = sub
                await scheduleReminder(for: sub)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Delete

    func delete(_ sub: SubscriptionTracker) async {
        do {
            try await repo.delete(id: sub.id)
            subscriptions.removeAll { $0.id == sub.id }
            await NotificationManager.cancelSubscriptionReminder(id: sub.id)
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Record payment (atomic-ish)

    /// Records a payment, advances the subscription's `lastPaymentDate`,
    /// recalculates `nextPaymentDate`, and reschedules the reminder.
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

            let nextPayment = SubscriptionDateEngine.nextPaymentDate(from: date, period: sub.billingPeriod)
            let nextStr = SubscriptionDateEngine.formatDbDate(nextPayment)
            try await repo.updateDates(id: subscriptionId, lastPaymentDate: paymentDateStr, nextPaymentDate: nextStr)

            if let idx = subscriptions.firstIndex(where: { $0.id == subscriptionId }) {
                var updated = subscriptions[idx]
                updated.lastPaymentDate = paymentDateStr
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

    // MARK: - Notifications

    private func scheduleReminder(for sub: SubscriptionTracker) async {
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
}
