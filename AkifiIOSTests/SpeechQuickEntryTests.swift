import XCTest
@testable import AkifiIOS

/// Voice entry state machine with a scripted recognizer, scripted
/// permissions and a manual clock (no audio, no timing flakiness).
@MainActor
final class SpeechQuickEntryTests: XCTestCase {

    // MARK: - Fakes

    final class FakeRecognizer: QuickEntrySpeechRecognizing {
        var available = true
        var startError: Error?
        /// Final text delivered when the audio stops; nil = never delivers.
        var finalOnFinish: String? = ""
        private(set) var continuation: AsyncThrowingStream<QuickEntrySpeechChunk, Error>.Continuation?
        private(set) var startCount = 0
        private(set) var finishCount = 0
        private(set) var cancelCount = 0
        private(set) var lastLocale: Locale?
        private(set) var lastContextualStrings: [String] = []
        private var lastPartial = ""

        func isAvailable(locale: Locale) -> Bool { available }

        func start(locale: Locale, contextualStrings: [String]) throws -> AsyncThrowingStream<QuickEntrySpeechChunk, Error> {
            if let startError { throw startError }
            startCount += 1
            lastLocale = locale
            lastContextualStrings = contextualStrings
            let (stream, continuation) = AsyncThrowingStream<QuickEntrySpeechChunk, Error>.makeStream()
            self.continuation = continuation
            return stream
        }

        func finishAudio() {
            finishCount += 1
            guard let finalOnFinish else { return }
            continuation?.yield(QuickEntrySpeechChunk(text: finalOnFinish.isEmpty ? lastPartial : finalOnFinish, isFinal: true))
            continuation?.finish()
        }

        func cancel() {
            cancelCount += 1
            continuation?.finish()
        }

        func say(_ text: String) {
            lastPartial = text
            continuation?.yield(QuickEntrySpeechChunk(text: text, isFinal: false))
        }

        func fail(_ error: Error) {
            continuation?.finish(throwing: error)
        }
    }

    final class FakePermissions: QuickEntrySpeechPermissions {
        var speech: QuickEntrySpeechAuthorization = .authorized
        var speechAfterRequest: QuickEntrySpeechAuthorization = .authorized
        var mic: Bool? = true
        var micAfterRequest = true
        private(set) var speechRequests = 0
        private(set) var micRequests = 0

        func speechAuthorization() -> QuickEntrySpeechAuthorization { speech }
        func requestSpeechAuthorization() async -> QuickEntrySpeechAuthorization {
            speechRequests += 1
            speech = speechAfterRequest
            return speech
        }
        func microphoneGranted() -> Bool? { mic }
        func requestMicrophone() async -> Bool {
            micRequests += 1
            mic = micAfterRequest
            return micAfterRequest
        }
    }

    /// Sleeps until the test fires the duration.
    final class ManualClock: @unchecked Sendable {
        private var waiters: [UUID: (Duration, CheckedContinuation<Void, Error>)] = [:]
        private let lock = NSLock()

        var pending: [Duration] {
            lock.withLock { waiters.values.map(\.0) }
        }

        func sleep(_ duration: Duration) async throws {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    // Cancelled before it got here: onCancel already ran.
                    if Task.isCancelled {
                        c.resume(throwing: CancellationError())
                        return
                    }
                    lock.withLock { waiters[id] = (duration, c) }
                }
            } onCancel: {
                let waiter = lock.withLock { waiters.removeValue(forKey: id) }
                waiter?.1.resume(throwing: CancellationError())
            }
        }

        /// Wakes every sleeper of exactly `duration`.
        func fire(_ duration: Duration) {
            let fired = lock.withLock {
                let matching = waiters.filter { $0.value.0 == duration }
                matching.keys.forEach { waiters.removeValue(forKey: $0) }
                return matching.values.map(\.1)
            }
            fired.forEach { $0.resume() }
        }
    }

    private var recognizer: FakeRecognizer!
    private var permissions: FakePermissions!
    private var clock: ManualClock!
    private var speech: SpeechQuickEntry!
    private var finished: [String] = []

    override func setUp() async throws {
        recognizer = FakeRecognizer()
        permissions = FakePermissions()
        clock = ManualClock()
        let clock = clock!
        speech = SpeechQuickEntry(
            recognizer: recognizer,
            permissions: permissions,
            locale: Locale(identifier: "ru-RU"),
            sleep: { try await clock.sleep($0) }
        )
        speech.silenceTimeout = .milliseconds(1600)
        speech.initialSilenceTimeout = .seconds(6)
        speech.maxDuration = .seconds(30)
        speech.finalResultTimeout = .seconds(3)
        finished = []
        speech.onFinish = { [weak self] in self?.finished.append($0) }
    }

    /// Lets the main-actor tasks run.
    private func settle() async {
        for _ in 0..<30 { await Task.yield() }
    }

    // MARK: - Flow

    func testDictationEndsBySilenceAndKeepsTheWords() async {
        await speech.start(contextualStrings: ["Тинькофф", "Кафе"])
        XCTAssertEqual(speech.state, .listening)
        XCTAssertEqual(recognizer.lastContextualStrings, ["Тинькофф", "Кафе"])
        XCTAssertEqual(recognizer.lastLocale?.identifier.replacingOccurrences(of: "_", with: "-"), "ru-RU")

        recognizer.say("кофе")
        await settle()
        recognizer.say("кофе триста")
        await settle()
        XCTAssertEqual(speech.transcript, "кофе триста")
        XCTAssertEqual(speech.parse?.amount, 300, "live parse for the preview")

        clock.fire(.milliseconds(1600))
        await settle()
        XCTAssertEqual(recognizer.finishCount, 1)
        XCTAssertEqual(speech.state, .finished("кофе триста"))
        XCTAssertEqual(finished, ["кофе триста"])
    }

    func testEveryNewWordRestartsTheSilenceTimer() async {
        await speech.start()
        recognizer.say("такси")
        await settle()
        recognizer.say("такси пятьсот")
        await settle()
        // Only one silence timer is alive (the first one was cancelled).
        XCTAssertEqual(clock.pending.filter { $0 == .milliseconds(1600) }.count, 1)
        XCTAssertEqual(recognizer.finishCount, 0)
    }

    func testNothingHeardEndsQuietly() async {
        await speech.start()
        await settle()
        clock.fire(.seconds(6))
        await settle()
        XCTAssertEqual(recognizer.finishCount, 1)
        XCTAssertEqual(speech.state, .idle)
        XCTAssertTrue(finished.isEmpty)
    }

    func testStopKeepsWhatWasHeard() async {
        recognizer.finalOnFinish = "кофе 300 рублей"
        await speech.start()
        recognizer.say("кофе 300")
        await settle()
        speech.stop()
        await settle()
        XCTAssertEqual(speech.state, .finished("кофе 300 рублей"))
        XCTAssertEqual(speech.parse?.currencyCode, "RUB")
        XCTAssertEqual(finished, ["кофе 300 рублей"])
    }

    func testMaxDurationStopsTheDictation() async {
        await speech.start()
        recognizer.say("очень длинная фраза")
        await settle()
        clock.fire(.seconds(30))
        await settle()
        XCTAssertEqual(recognizer.finishCount, 1)
        XCTAssertEqual(speech.state, .finished("очень длинная фраза"))
    }

    func testAMissingFinalResultDoesNotHang() async {
        recognizer.finalOnFinish = nil
        await speech.start()
        recognizer.say("кофе 300")
        await settle()
        speech.stop()
        await settle()
        XCTAssertEqual(speech.state, .finishing)
        clock.fire(.seconds(3))
        await settle()
        XCTAssertEqual(speech.state, .finished("кофе 300"))
        XCTAssertEqual(finished, ["кофе 300"], "once")
        XCTAssertGreaterThanOrEqual(recognizer.cancelCount, 1)
    }

    func testAnErrorAfterWordsKeepsThem() async {
        await speech.start()
        recognizer.say("такси 500")
        await settle()
        recognizer.fail(NSError(domain: "kAFAssistantErrorDomain", code: 1110))
        await settle()
        XCTAssertEqual(speech.state, .finished("такси 500"))
    }

    func testAnErrorBeforeWordsFails() async {
        await speech.start()
        recognizer.fail(NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"]))
        await settle()
        XCTAssertEqual(speech.state, .failed("boom"))
        XCTAssertTrue(finished.isEmpty)
    }

    func testCancelDropsEverything() async {
        await speech.start()
        recognizer.say("кофе")
        await settle()
        speech.cancel()
        await settle()
        clock.fire(.milliseconds(1600))
        await settle()
        XCTAssertEqual(speech.state, .idle)
        XCTAssertTrue(finished.isEmpty)
        XCTAssertEqual(recognizer.cancelCount, 1)
        XCTAssertEqual(recognizer.finishCount, 0)
    }

    func testCanDictateAgain() async {
        await speech.start()
        recognizer.say("кофе 300")
        await settle()
        speech.stop()
        await settle()
        await speech.start()
        XCTAssertEqual(speech.state, .listening)
        XCTAssertEqual(speech.transcript, "")
        XCTAssertEqual(recognizer.startCount, 2)
    }

    // MARK: - Permissions and availability

    func testAsksForPermissionsOnce() async {
        permissions.speech = .notDetermined
        permissions.mic = nil
        await speech.start()
        XCTAssertEqual(permissions.speechRequests, 1)
        XCTAssertEqual(permissions.micRequests, 1)
        XCTAssertEqual(speech.state, .listening)
    }

    func testSpeechDenied() async {
        permissions.speech = .notDetermined
        permissions.speechAfterRequest = .denied
        await speech.start()
        XCTAssertEqual(speech.state, .denied(.speech))
        XCTAssertEqual(recognizer.startCount, 0)
        XCTAssertEqual(permissions.micRequests, 0, "no mic prompt after a refusal")
    }

    func testRestricted() async {
        permissions.speech = .restricted
        await speech.start()
        XCTAssertEqual(speech.state, .denied(.restricted))
    }

    func testMicrophoneDenied() async {
        permissions.mic = false
        await speech.start()
        XCTAssertEqual(speech.state, .denied(.microphone))
        XCTAssertEqual(recognizer.startCount, 0)
    }

    func testUnavailableRecognizer() async {
        recognizer.available = false
        await speech.start()
        XCTAssertEqual(speech.state, .unavailable)
    }

    func testRecognizerThatFailsToStart() async {
        recognizer.startError = NSError(domain: "audio", code: 2, userInfo: [NSLocalizedDescriptionKey: "no input"])
        await speech.start()
        XCTAssertEqual(speech.state, .failed("no input"))
    }

    // MARK: - Locale

    func testRecognitionLocaleFollowsTheAppLanguage() {
        let supported: Set<String> = ["ru-RU", "en-US", "en-GB", "es-ES", "es-MX"]
        func locale(_ app: String?, _ current: String) -> String {
            SpeechQuickEntry.recognitionLocale(appLanguage: app, current: Locale(identifier: current), supported: supported)
                .identifier.replacingOccurrences(of: "_", with: "-")
        }
        XCTAssertEqual(locale("ru", "en_US"), "ru-RU")
        XCTAssertEqual(locale("es", "es_MX"), "es-MX", "keeps a supported region")
        XCTAssertEqual(locale("es", "ru_RU"), "es-ES")
        XCTAssertEqual(locale("en", "en_GB"), "en-GB")
        XCTAssertEqual(locale("system", "en_GB"), "en-GB")
        XCTAssertEqual(locale(nil, "ru_KZ"), "ru-RU")
        XCTAssertEqual(locale("system", "de_DE"), "ru-RU", "unsupported language → app default")
    }
}
