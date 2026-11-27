import AVFoundation
import Foundation
import Speech

/// `SFSpeechRecognizer` + `AVAudioEngine` behind `QuickEntrySpeechRecognizing`.
///
/// Swift 6 note: the audio tap and the recognition callback run on
/// background queues. Their closures are built in `nonisolated` static
/// functions so they don't inherit main-actor isolation (which would trap
/// at runtime when the audio thread calls them).
@MainActor
final class LiveQuickEntrySpeechRecognizer: QuickEntrySpeechRecognizing {

    enum RecognizerError: LocalizedError {
        case unavailable
        case noMicrophoneInput

        var errorDescription: String? {
            switch self {
            case .unavailable: String(localized: "quickEntry.voice.unavailable")
            case .noMicrophoneInput: String(localized: "quickEntry.voice.noMicrophone")
            }
        }
    }

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var tapInstalled = false

    nonisolated static func supportedLocaleIdentifiers() -> Set<String> {
        Set(SFSpeechRecognizer.supportedLocales().map(\.identifier))
    }

    func isAvailable(locale: Locale) -> Bool {
        SFSpeechRecognizer(locale: locale)?.isAvailable ?? false
    }

    func start(locale: Locale, contextualStrings: [String]) throws -> AsyncThrowingStream<QuickEntrySpeechChunk, Error> {
        cancel()
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw RecognizerError.unavailable
        }

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Private by default: audio stays on the device whenever the
        // language model is there.
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        request.contextualStrings = contextualStrings
        request.taskHint = .dictation
        request.addsPunctuation = false

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            throw RecognizerError.noMicrophoneInput
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tapBlock(for: request))
        tapInstalled = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            tapInstalled = false
            try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }

        let (stream, continuation) = AsyncThrowingStream<QuickEntrySpeechChunk, Error>.makeStream()
        task = recognizer.recognitionTask(with: request, resultHandler: Self.resultHandler(continuation))
        self.request = request
        self.recognizer = recognizer
        return stream
    }

    func finishAudio() {
        stopAudio()
        request?.endAudio()
    }

    func cancel() {
        task?.cancel()
        task = nil
        stopAudio()
        request = nil
        recognizer = nil
    }

    private func stopAudio() {
        if engine.isRunning { engine.stop() }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated private static func tapBlock(
        for request: SFSpeechAudioBufferRecognitionRequest
    ) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        nonisolated(unsafe) let request = request
        return { buffer, _ in request.append(buffer) }
    }

    nonisolated private static func resultHandler(
        _ continuation: AsyncThrowingStream<QuickEntrySpeechChunk, Error>.Continuation
    ) -> @Sendable (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            if let result {
                continuation.yield(QuickEntrySpeechChunk(
                    text: result.bestTranscription.formattedString,
                    isFinal: result.isFinal
                ))
                if result.isFinal {
                    continuation.finish()
                    return
                }
            }
            if let error {
                continuation.finish(throwing: error)
            }
        }
    }
}

/// Speech-recognition and microphone permissions of the system.
@MainActor
final class LiveQuickEntrySpeechPermissions: QuickEntrySpeechPermissions {

    func speechAuthorization() -> QuickEntrySpeechAuthorization {
        Self.map(SFSpeechRecognizer.authorizationStatus())
    }

    func requestSpeechAuthorization() async -> QuickEntrySpeechAuthorization {
        Self.map(await Self.requestSpeech())
    }

    func microphoneGranted() -> Bool? {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        case .undetermined: return nil
        @unknown default: return nil
        }
    }

    func requestMicrophone() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    nonisolated private static func requestSpeech() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    nonisolated private static func map(_ status: SFSpeechRecognizerAuthorizationStatus) -> QuickEntrySpeechAuthorization {
        switch status {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }
}
