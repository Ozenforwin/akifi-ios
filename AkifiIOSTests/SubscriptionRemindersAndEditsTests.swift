import XCTest
@testable import AkifiIOS

/// D9 (one reminder source per device) and the anchor an edit writes.
final class SubscriptionRemindersAndEditsTests: XCTestCase {

    private func sub(
        _ id: String,
        status: SubscriptionTrackerStatus = .active,
        next: String?,
        start: String = "2026-01-17",
        period: BillingPeriod = .monthly,
        reminderDays: Int = 1
    ) -> SubscriptionTracker {
        SubscriptionTracker(
            id: id, userId: "u1", serviceName: id, amount: 100_00, currency: "RUB",
            billingPeriod: period, startDate: start, nextPaymentDate: next,
            reminderDays: reminderDays, status: status
        )
    }

    private var now: Date { AppDateFormatters.localDateTime.date(from: "2026-11-17T12:00:00")! }

    // MARK: - Reminder plan

    func test_serverDelivers_everyLocalReminderGoes() {
        let plan = NotificationManager.planSubscriptionReminders(
            subscriptions: [sub("a", next: "2026-12-17")],
            pendingIds: ["a", "orphan"],
            serverDelivers: true,
            now: now
        )
        XCTAssertEqual(plan.schedule, [])
        XCTAssertEqual(plan.cancel, ["a", "orphan"])
    }

    func test_deviceFallback_schedulesActiveFutureOnes_andCleansTheRest() {
        let subs = [
            sub("active", next: "2026-12-17"),
            sub("paused", status: .paused, next: "2026-12-17"),
            sub("cancelled", status: .cancelled, next: "2026-12-17"),
            sub("pastReminder", next: "2026-11-17"),          // 1 day before = yesterday
            sub("todayLater", next: "2026-11-18"),             // reminder 17 Nov 09:00 — already past at noon
            sub("sameDay", next: "2026-11-18", reminderDays: 0),
            sub("noDate", next: nil),
        ]
        let plan = NotificationManager.planSubscriptionReminders(
            subscriptions: subs,
            pendingIds: ["active", "paused", "pastReminder", "deleted"],
            serverDelivers: false,
            now: now
        )
        XCTAssertEqual(plan.schedule, ["active", "sameDay"])
        XCTAssertEqual(plan.cancel, ["deleted", "pastReminder", "paused"])
    }

    func test_serverPushRegistration_isPerUser() {
        let defaults = UserDefaults(suiteName: "SubscriptionRemindersTests-\(UUID().uuidString)")!
        XCTAssertFalse(NotificationManager.serverDeliversSubscriptionReminders(defaults: defaults))

        NotificationManager.recordServerPushRegistration(userId: "u1", defaults: defaults)
        XCTAssertTrue(NotificationManager.serverDeliversSubscriptionReminders(defaults: defaults))
        XCTAssertTrue(NotificationManager.serverDeliversSubscriptionReminders(userId: "u1", defaults: defaults))
        XCTAssertFalse(NotificationManager.serverDeliversSubscriptionReminders(userId: "u2", defaults: defaults))

        NotificationManager.recordServerPushRegistration(userId: nil, defaults: defaults)
        XCTAssertFalse(NotificationManager.serverDeliversSubscriptionReminders(defaults: defaults))
    }

    // MARK: - start_date written by an edit

    private func day(_ s: String) -> Date { AppDateFormatters.isoDate.date(from: s)! }

    func test_edit_withoutScheduleChange_leavesStartDateAlone() {
        // Legacy row (start off-schedule) renamed only: nothing to write, so
        // the DB trigger that recomputes next_payment_date stays quiet.
        let stored = sub("s", next: "2026-12-21", start: "2026-11-01")
        XCTAssertNil(SubscriptionsViewModel.startDateToWrite(
            stored: stored, period: .monthly, lastPaymentDate: nil, nextPaymentDate: day("2026-12-21")
        ))
    }

    func test_edit_nextStillOnTheOldSchedule_keepsTheAnchor() {
        let stored = sub("s", next: "2026-01-31", start: "2025-12-31")
        XCTAssertNil(SubscriptionsViewModel.startDateToWrite(
            stored: stored, period: .monthly, lastPaymentDate: nil, nextPaymentDate: day("2026-02-28")
        ))
    }

    func test_edit_movingTheBillingDay_reanchorsOnTheNewNextDate() {
        let stored = sub("s", next: "2026-12-17", start: "2026-01-17")
        XCTAssertEqual(SubscriptionsViewModel.startDateToWrite(
            stored: stored, period: .monthly, lastPaymentDate: nil, nextPaymentDate: day("2026-12-20")
        ), "2026-12-20")
    }

    func test_edit_lastPaymentOnTheNewSchedule_becomesTheAnchor() {
        let stored = sub("s", next: "2026-12-17", start: "2026-01-17")
        XCTAssertEqual(SubscriptionsViewModel.startDateToWrite(
            stored: stored, period: .monthly, lastPaymentDate: day("2026-11-20"), nextPaymentDate: day("2026-12-20")
        ), "2026-11-20")
    }
}
