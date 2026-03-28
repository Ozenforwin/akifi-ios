import Foundation

enum RiskLevel: String { case low, medium, high, critical }
enum BudgetStatus: String { case onTrack, warning, nearLimit, overLimit }

struct BudgetMetrics {
    let spent: Int64
    let effectiveLimit: Int64
    let remaining: Int64
    let utilization: Int          // 0–999 %
    let totalDays: Int
    let elapsedDays: Int
    let remainingDays: Int
    let safeToSpendDaily: Int64
    let paceRatio: Double         // 1.0 = on track
    let riskLevel: RiskLevel
    let status: BudgetStatus
    let progressColor: String     // hex
}

enum BudgetMath {

    static func compute(budget: Budget, transactions: [Transaction]) -> BudgetMetrics {
        let period = currentPeriod(for: budget)
        let spent = spentAmount(budget: budget, transactions: transactions, period: period)
        let limit = budget.amount
        let remaining = max(0, limit - spent)

        let utilization = computeProgress(spent: spent, limit: limit)
        let days = daysMeta(start: period.start, end: period.end)
        let safe = computeSafeToSpend(limit: limit, spent: spent, remainingDays: days.remaining)
        let pace = computePace(limit: limit, spent: spent, elapsed: days.elapsed, total: days.total)
        let risk = computeRiskLevel(utilization: utilization, pace: pace, remainingDays: days.remaining)
        let status = computeStatus(utilization: utilization, pace: pace)
        let color = progressColorHex(utilization: utilization)

        return BudgetMetrics(
            spent: spent, effectiveLimit: limit, remaining: remaining,
            utilization: utilization,
            totalDays: days.total, elapsedDays: days.elapsed, remainingDays: days.remaining,
            safeToSpendDaily: safe, paceRatio: pace,
            riskLevel: risk, status: status, progressColor: color
        )
    }

    // MARK: - Period

    static func currentPeriod(for budget: Budget) -> (start: Date, end: Date) {
        let cal = Calendar.current
        let now = Date()
        switch budget.billingPeriod {
        case .weekly:
            let weekday = cal.component(.weekday, from: now)
            let daysToMonday = (weekday + 5) % 7
            let start = cal.date(byAdding: .day, value: -daysToMonday, to: cal.startOfDay(for: now))!
            let end = cal.date(byAdding: .day, value: 6, to: start)!
            return (start, end)
        case .monthly:
            let start = cal.date(from: cal.dateComponents([.year, .month], from: now))!
            let end = cal.date(byAdding: DateComponents(month: 1, day: -1), to: start)!
            return (start, end)
        case .quarterly:
            let month = cal.component(.month, from: now)
            let qStart = ((month - 1) / 3) * 3 + 1
            var comps = cal.dateComponents([.year], from: now)
            comps.month = qStart; comps.day = 1
            let start = cal.date(from: comps)!
            let end = cal.date(byAdding: DateComponents(month: 3, day: -1), to: start)!
            return (start, end)
        case .yearly:
            let start = cal.date(from: cal.dateComponents([.year], from: now))!
            let end = cal.date(byAdding: DateComponents(year: 1, day: -1), to: start)!
            return (start, end)
        case .custom:
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            if let startStr = budget.customStartDate,
               let endStr = budget.customEndDate,
               let start = df.date(from: startStr),
               let end = df.date(from: endStr) {
                return (start, end)
            }
            let start = cal.date(from: cal.dateComponents([.year, .month], from: now))!
            let end = cal.date(byAdding: DateComponents(month: 1, day: -1), to: start)!
            return (start, end)
        }
    }

    // MARK: - Forecast Overrun Date

    static func forecastOverrunDate(metrics: BudgetMetrics) -> Date? {
        guard metrics.spent > 0, metrics.elapsedDays > 0, metrics.spent < metrics.effectiveLimit else { return nil }
        let dailyRate = Double(metrics.spent) / Double(metrics.elapsedDays)
        guard dailyRate > 0 else { return nil }
        let daysToOverrun = Double(metrics.effectiveLimit - metrics.spent) / dailyRate
        guard daysToOverrun < Double(metrics.remainingDays) else { return nil }
        return Calendar.current.date(byAdding: .day, value: Int(daysToOverrun), to: Date())
    }

    // MARK: - Spent

    static func spentAmount(budget: Budget, transactions: [Transaction], period: (start: Date, end: Date)) -> Int64 {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return transactions.filter { tx in
            guard tx.type == .expense && !tx.isTransfer else { return false }
            if let cats = budget.categoryIds, !cats.isEmpty {
                guard let catId = tx.categoryId, cats.contains(catId) else { return false }
            }
            if let accId = budget.accountId {
                guard tx.accountId == accId else { return false }
            }
            guard let d = df.date(from: tx.date) else { return false }
            return d >= period.start && d <= period.end
        }.reduce(Int64(0)) { $0 + $1.amount }
    }

    // MARK: - Progress (0–999 %)

    static func computeProgress(spent: Int64, limit: Int64) -> Int {
        guard limit > 0 else { return spent > 0 ? 999 : 0 }
        return min(999, max(0, Int(Double(spent) / Double(limit) * 100)))
    }

    // MARK: - Days

    static func daysMeta(start: Date, end: Date) -> (total: Int, elapsed: Int, remaining: Int) {
        let day: TimeInterval = 86_400
        let total = max(1, Int(round((end.timeIntervalSince(start)) / day)) + 1)
        let elapsed = max(0, min(total, Int(round((Date().timeIntervalSince(start)) / day)) + 1))
        return (total, elapsed, total - elapsed)
    }

    // MARK: - Safe to spend daily

    static func computeSafeToSpend(limit: Int64, spent: Int64, remainingDays: Int) -> Int64 {
        let leftover = max(0, limit - spent)
        guard remainingDays > 0 else { return leftover }
        return max(0, leftover / Int64(remainingDays))
    }

    // MARK: - Pace ratio

    static func computePace(limit: Int64, spent: Int64, elapsed: Int, total: Int) -> Double {
        guard elapsed > 0, total > 0 else { return 0 }
        let expected = Double(limit) * (Double(elapsed) / Double(total))
        guard expected > 0 else { return spent > 0 ? 9.99 : 0 }
        return (Double(spent) / expected * 100).rounded() / 100
    }

    // MARK: - Risk level

    static func computeRiskLevel(utilization: Int, pace: Double, remainingDays: Int) -> RiskLevel {
        if utilization >= 100 || (pace >= 1.5 && remainingDays <= 3) { return .critical }
        if utilization >= 90 || (pace >= 1.3 && remainingDays <= 7) { return .high }
        if utilization >= 70 || pace >= 1.1 { return .medium }
        return .low
    }

    // MARK: - Status

    static func computeStatus(utilization: Int, pace: Double) -> BudgetStatus {
        if utilization >= 100 { return .overLimit }
        if utilization >= 90 { return .nearLimit }
        if utilization >= 75 || pace >= 1.15 { return .warning }
        return .onTrack
    }

    // MARK: - Color

    static func progressColorHex(utilization: Int) -> String {
        if utilization > 100 { return "#EF4444" }
        if utilization >= 90 { return "#F97316" }
        if utilization >= 75 { return "#F59E0B" }
        return "#22C55E"
    }
}
