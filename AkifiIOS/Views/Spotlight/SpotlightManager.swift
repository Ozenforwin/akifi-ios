import SwiftUI

@Observable @MainActor
final class SpotlightManager {
    var isActive = false
    var currentStepIndex = 0
    var frames: [SpotlightTarget: CGRect] = [:]

    @ObservationIgnored
    private var completed: Bool {
        get { UserDefaults.standard.bool(forKey: "spotlight_completed") }
        set { UserDefaults.standard.set(newValue, forKey: "spotlight_completed") }
    }

    var currentStep: SpotlightStep? {
        guard isActive, currentStepIndex < SpotlightStep.allSteps.count else { return nil }
        return SpotlightStep.allSteps[currentStepIndex]
    }

    var currentFrame: CGRect? {
        guard let step = currentStep else { return nil }
        return frames[step.target]
    }

    var requiredTab: AppTab? {
        currentStep?.tab
    }

    var totalSteps: Int { SpotlightStep.allSteps.count }

    func start() {
        guard !completed else { return }
        currentStepIndex = 0
        isActive = true
    }

    func next() {
        if currentStepIndex + 1 < SpotlightStep.allSteps.count {
            currentStepIndex += 1
        } else {
            finish()
        }
    }

    func skip() {
        finish()
    }

    func finish() {
        isActive = false
        completed = true
        currentStepIndex = 0
    }

    func reset() {
        completed = false
        currentStepIndex = 0
    }
}
