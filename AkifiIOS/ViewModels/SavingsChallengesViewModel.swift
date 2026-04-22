import Foundation

@Observable @MainActor
final class SavingsChallengesViewModel {
    var challenges: [SavingsChallenge] = []
    var isLoading = false
    var error: String?

    private let repo = SavingsChallengeRepository()

    var activeChallenges: [SavingsChallenge] {
        challenges.filter { $0.status == .active }
    }

    var completedChallenges: [SavingsChallenge] {
        challenges.filter { $0.status == .completed }
    }

    var abandonedChallenges: [SavingsChallenge] {
        challenges.filter { $0.status == .abandoned }
    }

    // MARK: - Load / CRUD

    func load() async {
        isLoading = true
        error = nil
        do {
            challenges = try await repo.fetchAll()
        } catch {
            self.error = error.localizedDescription
            AppLogger.data.warning("Challenges load: \(error.localizedDescription)")
        }
        isLoading = false
    }

    func create(
        type: ChallengeType,
        title: String,
        description: String?,
        targetAmount: Int64?,
        durationDays: Int,
        categoryId: String?,
        linkedGoalId: String?
    ) async -> SavingsChallenge? {
        do {
            let userId = try await SupabaseManager.shared.currentUserId()
            let calendar = Calendar.current
            let today = Date()
            let endDate = calendar.date(byAdding: .day, value: durationDays, to: today) ?? today
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"

            let input = CreateChallengeInput(
                user_id: userId,
                type: type.rawValue,
                title: title,
                description: description,
                target_amount: targetAmount.map { Double($0) / 100.0 },
                duration_days: durationDays,
                start_date: df.string(from: today),
                end_date: df.string(from: endDate),
                status: ChallengeStatus.active.rawValue,
                progress_amount: 0,
                category_id: categoryId,
                linked_goal_id: linkedGoalId
            )
            let created = try await repo.create(input)
            challenges.insert(created, at: 0)
            AnalyticsService.logEvent("challenge_created", params: ["type": type.rawValue])
            return created
        } catch {
            self.error = error.localizedDescription
            AppLogger.data.warning("Challenge create: \(error.localizedDescription)")
            return nil
        }
    }

    func abandon(_ challenge: SavingsChallenge) async {
        do {
            try await repo.updateStatus(id: challenge.id, status: .abandoned)
            if let idx = challenges.firstIndex(where: { $0.id == challenge.id }) {
                challenges[idx].status = .abandoned
            }
            AnalyticsService.logEvent("challenge_abandoned", params: ["type": challenge.type.rawValue])
        } catch {
            self.error = error.localizedDescription
        }
    }

    func delete(_ challenge: SavingsChallenge) async {
        do {
            try await repo.delete(id: challenge.id)
            challenges.removeAll { $0.id == challenge.id }
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Progress reconciliation

    /// Recompute progress for all active challenges based on `transactions`,
    /// persist updates where progress changed, and flip status when the
    /// engine signals a transition.
    ///
    /// Idempotent & safe to call from DataStore.loadAll completion.
    func reconcileProgress(transactions: [Transaction], currencyContext: TransactionMath.CurrencyContext) async {
        var updated: [SavingsChallenge] = challenges
        for (idx, ch) in challenges.enumerated() where ch.status == .active {
            let newProgress = ChallengeProgressEngine.progress(
                for: ch, transactions: transactions, currencyContext: currencyContext
            )
            var next = ch
            if newProgress != ch.progressAmount {
                next.progressAmount = newProgress
                // Fire-and-forget persistence — progress can be recomputed
                // locally anyway, so losing one write isn't fatal.
                Task.detached { [repo] in
                    try? await repo.updateProgress(id: ch.id, amount: newProgress)
                }
            }
            if let newStatus = ChallengeProgressEngine.nextStatus(for: next) {
                next.status = newStatus
                Task.detached { [repo] in
                    try? await repo.updateStatus(id: ch.id, status: newStatus)
                }
                if newStatus == .completed {
                    AnalyticsService.logEvent(
                        "challenge_completed",
                        params: ["type": ch.type.rawValue]
                    )
                }
            }
            updated[idx] = next
        }
        challenges = updated
    }
}
