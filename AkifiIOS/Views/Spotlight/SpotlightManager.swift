import SwiftUI

@Observable @MainActor
final class SpotlightManager {
    var isActive = false
    var currentStepIndex = 0
    /// Frames of the targets currently on screen, in global coordinates.
    /// Written by `.spotlight(_:)` anchors through `report` / `withdraw`.
    private(set) var frames: [SpotlightTarget: CGRect] = [:]

    /// How long a step may wait for its target to appear (tab switch, first
    /// layout of a tab) before it is skipped as having nothing to point at.
    static let anchorGracePeriod: Duration = .seconds(1.2)

    let steps: [SpotlightStep]
    @ObservationIgnored private let defaults: UserDefaults
    /// Which anchor instance reported each frame (see `SpotlightAnchor`).
    @ObservationIgnored private var frameOwners: [SpotlightTarget: UUID] = [:]

    static let completedKey = "spotlight_completed"

    init(steps: [SpotlightStep] = SpotlightStep.allSteps, defaults: UserDefaults = .standard) {
        self.steps = steps
        self.defaults = defaults
    }

    @ObservationIgnored
    private var completed: Bool {
        get { defaults.bool(forKey: Self.completedKey) }
        set { defaults.set(newValue, forKey: Self.completedKey) }
    }

    var currentStep: SpotlightStep? {
        guard isActive, currentStepIndex < steps.count else { return nil }
        return steps[currentStepIndex]
    }

    /// The frame to cut out for the current step — `nil` while its target
    /// isn't on screen (or has no size yet).
    var currentFrame: CGRect? {
        guard let step = currentStep,
              let frame = frames[step.target],
              frame.width > 0, frame.height > 0
        else { return nil }
        return frame
    }

    var requiredTab: AppTab? {
        currentStep?.tab
    }

    var totalSteps: Int { steps.count }

    func start() {
        guard !completed else { return }
        currentStepIndex = 0
        isActive = true
    }

    func next() {
        if currentStepIndex + 1 < steps.count {
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

    // MARK: - Anchors

    func report(_ target: SpotlightTarget, frame: CGRect, owner: UUID) {
        frameOwners[target] = owner
        if frames[target] != frame {
            frames[target] = frame
        }
    }

    func withdraw(_ target: SpotlightTarget, owner: UUID) {
        guard frameOwners[target] == owner else { return }
        frameOwners[target] = nil
        frames[target] = nil
    }

    /// No step may point at nothing: called once the grace period after a
    /// step change has passed; if the step's target still isn't on screen
    /// (no budgets yet → no budget card, …) the tour moves on.
    func skipStepIfUnanchored() {
        guard isActive, currentStep != nil, currentFrame == nil else { return }
        next()
    }
}
