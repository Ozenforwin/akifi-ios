import Foundation
import Observation

/// One recognition update.
struct QuickEntrySpeechChunk: Equatable, Sendable {
    let text: String
    let isFinal: Bool
}

enum QuickEntrySpeechAuthorization: Equatable, Sendable {
    case notDetermined, denied, restricted, authorized
}

/// Recognizer seam. Production: `LiveQuickEntrySpeechRecognizer`
/// (`SFSpeechRecognizer` + `AVAudioEngine`). Tests: a scripted fake.
@MainActor
protocol QuickEntrySpeechRecognizing: AnyObject {
    /// Whether recognition for `locale` exists on this device right now.
    func isAvailable(locale: Locale) -> Bool
    /// Starts listening. Partial results stream in; the stream finishes
    /// after `finishAudio()` delivered the final result, or throws.
    func start(locale: Locale, contextualStrings: [String]) throws -> AsyncThrowingStream<QuickEntrySpeechChunk, Error>
    /// Stop capturing; the final result still arrives on the stream.
    func finishAudio()
    /// Stop everything, no final result.
    func cancel()
}

/// Permission seam (speech recognition + microphone).
@MainActor
protocol QuickEntrySpeechPermissions: AnyObject {
    func speechAuthorization() -> QuickEntrySpeechAuthorization
    func requestSpeechAuthorization() async -> QuickEntrySpeechAuthorization
    /// nil = not asked yet.
    func microphoneGranted() -> Bool?
    func requestMicrophone() async -> Bool
}

/// On-device voice entry for the quick-entry sheet.
///
/// Flow: `start()` → permissions (asked once, the system remembers) →
/// listening with partial results in `transcript` (and their parse in
/// `parse`, for the live preview) → stops by itself after
/// `silenceTimeout` without new words, after `maxDuration`, or on
/// `stop()` → `state == .finished(text)`; the text goes through
/// `QuickEntryParser` like typed input.
///
/// Recognition runs on the device when the locale supports it
/// (`requiresOnDeviceRecognition`); the language follows the app's
/// language setting.
@Observable @MainActor
final class SpeechQuickEntry {

    enum State: Equatable, Sendable {
        case idle
        case requestingPermission
        case listening
        /// Audio stopped; waiting for the final result.
        case finishing
        case finished(String)
        /// The user refused (or a profile forbids) speech or microphone.
        case denied(DeniedReason)
        /// No recognizer for the language on this device / offline.
        case unavailable
        case failed(String)
    }

    enum DeniedReason: Equatable, Sendable {
        case speech, microphone, restricted
    }

    private(set) var state: State = .idle
    /// Best transcription so far.
    private(set) var transcript = ""
    /// `transcript` parsed — for a live preview of amount / category.
    private(set) var parse: QuickEntryParse?

    /// Silence that ends the dictation once something was heard.
    var silenceTimeout: Duration = .seconds(1.6)
    /// Give up when nothing at all is heard for this long.
    var initialSilenceTimeout: Duration = .seconds(6)
    /// Hard cap of one dictation.
    var maxDuration: Duration = .seconds(30)

    /// Called once with the final text (not for empty results).
    @ObservationIgnored var onFinish: (@MainActor (String) -> Void)?
    /// Turns a transcript into a parse; set by the sheet with the user's
    /// vocabulary. Default: no vocabulary.
    @ObservationIgnored var parser: @MainActor (String) -> QuickEntryParse = { QuickEntryParser.parse($0) }

    private let recognizer: QuickEntrySpeechRecognizing
    private let permissions: QuickEntrySpeechPermissions
    private let sleep: @Sendable (Duration) async throws -> Void
    private let locale: Locale

    @ObservationIgnored private var listenTask: Task<Void, Never>?
    @ObservationIgnored private var silenceTask: Task<Void, Never>?
    @ObservationIgnored private var capTask: Task<Void, Never>?
    @ObservationIgnored private var session = 0

    init(
        recognizer: QuickEntrySpeechRecognizing? = nil,
        permissions: QuickEntrySpeechPermissions? = nil,
        locale: Locale? = nil,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.recognizer = recognizer ?? LiveQuickEntrySpeechRecognizer()
        self.permissions = permissions ?? LiveQuickEntrySpeechPermissions()
        self.locale = locale ?? Self.recognitionLocale(
            appLanguage: UserDefaults.standard.string(forKey: "appLanguage"),
            current: .current,
            supported: LiveQuickEntrySpeechRecognizer.supportedLocaleIdentifiers()
        )
        self.sleep = sleep
    }

    var isListening: Bool { state == .listening || state == .finishing }

    // MARK: - Control

    /// Starts a dictation. `contextualStrings`: names that help the
    /// recognizer (see `QuickEntryEngine.contextualStrings`).
    func start(contextualStrings: [String] = []) async {
        guard !isListening, state != .requestingPermission else { return }
        session += 1
        let current = session
        transcript = ""
        parse = nil

        state = .requestingPermission
        if let denied = await ensurePermissions() {
            guard current == session else { return }
            state = .denied(denied)
            return
        }
        guard current == session else { return }
        guard recognizer.isAvailable(locale: locale) else {
            state = .unavailable
            return
        }

        let stream: AsyncThrowingStream<QuickEntrySpeechChunk, Error>
        do {
            stream = try recognizer.start(locale: locale, contextualStrings: contextualStrings)
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        state = .listening
        armSilenceTimer(timeout: initialSilenceTimeout, session: current)
        capTask = Task { [weak self, sleep, maxDuration] in
            do { try await sleep(maxDuration) } catch { return }
            self?.finishListening(session: current)
        }
        listenTask = Task { [weak self] in
            do {
                for try await chunk in stream {
                    guard let self, self.session == current else { return }
                    self.receive(chunk, session: current)
                    if chunk.isFinal { break }
                }
                self?.complete(session: current)
            } catch is CancellationError {
                return
            } catch {
                self?.fail(error, session: current)
            }
        }
    }

    /// The user tapped stop: keep what was heard.
    func stop() {
        finishListening(session: session)
    }

    /// The user dismissed: drop everything.
    func cancel() {
        session += 1
        recognizer.cancel()
        tearDownTimers()
        listenTask?.cancel()
        listenTask = nil
        state = .idle
    }

    // MARK: - Internals

    private func ensurePermissions() async -> DeniedReason? {
        var speech = permissions.speechAuthorization()
        if speech == .notDetermined { speech = await permissions.requestSpeechAuthorization() }
        switch speech {
        case .denied: return .speech
        case .restricted: return .restricted
        case .notDetermined: return .speech
        case .authorized: break
        }
        var mic = permissions.microphoneGranted()
        if mic == nil { mic = await permissions.requestMicrophone() }
        return mic == true ? nil : .microphone
    }

    private func receive(_ chunk: QuickEntrySpeechChunk, session current: Int) {
        let text = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text != transcript {
            transcript = text
            parse = text.isEmpty ? nil : parser(text)
            if !chunk.isFinal, !text.isEmpty {
                armSilenceTimer(timeout: silenceTimeout, session: current)
            }
        }
    }

    private func armSilenceTimer(timeout: Duration, session current: Int) {
        silenceTask?.cancel()
        silenceTask = Task { [weak self, sleep] in
            do { try await sleep(timeout) } catch { return }
            self?.finishListening(session: current)
        }
    }

    /// How long to wait for the final result after the audio stopped.
    var finalResultTimeout: Duration = .seconds(3)

    private func finishListening(session current: Int) {
        guard current == session, state == .listening else { return }
        state = .finishing
        tearDownTimers()
        recognizer.finishAudio()
        // A recognizer that never delivers its final result must not
        // leave the sheet hanging: keep the last partial.
        capTask = Task { [weak self, sleep, finalResultTimeout] in
            do { try await sleep(finalResultTimeout) } catch { return }
            guard let self, self.session == current, self.state == .finishing else { return }
            self.recognizer.cancel()
            self.listenTask?.cancel()
            self.complete(session: current)
        }
    }

    private func complete(session current: Int) {
        guard current == session, isListening else { return }
        tearDownTimers()
        listenTask = nil
        let text = transcript
        if text.isEmpty {
            state = .idle
        } else {
            state = .finished(text)
            onFinish?(text)
        }
    }

    private func fail(_ error: Error, session current: Int) {
        guard current == session, isListening else { return }
        tearDownTimers()
        listenTask = nil
        recognizer.cancel()
        // A recognizer that ends with an error after real words (e.g.
        // «no speech detected» right after the last one) still delivered
        // them — keep them.
        if !transcript.isEmpty {
            state = .finished(transcript)
            onFinish?(transcript)
        } else {
            state = .failed(error.localizedDescription)
        }
    }

    private func tearDownTimers() {
        silenceTask?.cancel()
        silenceTask = nil
        capTask?.cancel()
        capTask = nil
    }

    // MARK: - Locale

    /// Recognition locale for the app language («ru» / «en» / «es» /
    /// «system»), keeping the device region when the recognizer supports
    /// that combination (es-MX, en-GB), else a default region.
    nonisolated static func recognitionLocale(appLanguage: String?, current: Locale, supported: Set<String>) -> Locale {
        let defaults = ["ru": "ru-RU", "en": "en-US", "es": "es-ES"]
        let language: String = {
            if let appLanguage, appLanguage != "system", !appLanguage.isEmpty { return appLanguage }
            return current.language.languageCode?.identifier ?? "ru"
        }()
        let normalizedSupported = Set(supported.map { $0.replacingOccurrences(of: "_", with: "-") })
        if let region = current.region?.identifier {
            let candidate = "\(language)-\(region)"
            if normalizedSupported.contains(candidate) { return Locale(identifier: candidate) }
        }
        if let fallback = defaults[language] { return Locale(identifier: fallback) }
        if let any = normalizedSupported.sorted().first(where: { $0.hasPrefix(language + "-") }) {
            return Locale(identifier: any)
        }
        return Locale(identifier: "ru-RU")
    }
}
