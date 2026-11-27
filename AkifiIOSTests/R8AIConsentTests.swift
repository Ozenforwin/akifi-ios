import XCTest
@testable import AkifiIOS

/// R8: nothing goes to the AI providers before the user agreed; consent
/// is remembered per user.
final class R8AIConsentTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "R8AIConsentTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    @MainActor private func viewModel(userId: String?) -> AssistantViewModel {
        let vm = AssistantViewModel()
        vm.consentStore = AIConsentStore(defaults: defaults)
        vm.currentUserId = { userId }
        return vm
    }

    func test_R8_store_isPerUserAndCaseInsensitive() {
        let store = AIConsentStore(defaults: defaults)
        XCTAssertFalse(store.hasConsented(userId: "user-a"))
        store.recordConsent(userId: "USER-A")
        XCTAssertTrue(store.hasConsented(userId: "user-a"))
        XCTAssertFalse(store.hasConsented(userId: "user-b"))
        XCTAssertFalse(store.hasConsented(userId: nil))
        XCTAssertFalse(store.hasConsented(userId: ""))
        store.revokeConsent(userId: "user-a")
        XCTAssertFalse(store.hasConsented(userId: "user-a"))
    }

    func test_R8_store_keyCarriesVersion() {
        XCTAssertEqual(AIConsentStore.key(userId: "ABC"), "ai_consent_v\(AIConsentStore.version)_abc")
        XCTAssertEqual(AIConsentStore.providers, ["OpenAI", "Anthropic"])
    }

    @MainActor func test_R8_firstSend_asksAndSendsNothing() async {
        let vm = viewModel(userId: "user-a")
        vm.inputText = "Сколько я потратил на еду?"
        await vm.send()
        XCTAssertTrue(vm.showAIConsent)
        XCTAssertTrue(vm.chatMessages.isEmpty, "the question must not be sent or shown as sent")
        XCTAssertFalse(vm.isProcessing)
        XCTAssertEqual(vm.inputText, "Сколько я потратил на еду?", "the text stays in the input")
    }

    @MainActor func test_R8_decline_keepsAskingNextTime() async {
        let vm = viewModel(userId: "user-a")
        vm.inputText = "Бюджет?"
        await vm.send()
        vm.declineAIConsent()
        XCTAssertFalse(vm.showAIConsent)
        XCTAssertFalse(vm.hasAIConsent)
        await vm.send()
        XCTAssertTrue(vm.showAIConsent)
        XCTAssertTrue(vm.chatMessages.isEmpty)
    }

    @MainActor func test_R8_voice_asksBeforeRecording() {
        let vm = viewModel(userId: "user-a")
        vm.startRecording()
        XCTAssertTrue(vm.showAIConsent)
        XCTAssertFalse(vm.isRecording)
    }

    @MainActor func test_R8_accept_recordsConsentForThisUserOnly() async {
        let vm = viewModel(userId: "user-a")
        vm.startRecording()   // asks; accepting does not start recording on its own
        await vm.acceptAIConsent()
        XCTAssertFalse(vm.showAIConsent)
        XCTAssertFalse(vm.isRecording)
        XCTAssertTrue(vm.hasAIConsent)
        XCTAssertTrue(AIConsentStore(defaults: defaults).hasConsented(userId: "user-a"))

        let other = viewModel(userId: "user-b")
        XCTAssertFalse(other.hasAIConsent, "another account on the same device is asked again")
    }

    func test_R8_consentStrings_nameTheProviders() throws {
        let app = Bundle(for: AppViewModel.self)
        for lang in ["ru", "en", "es"] {
            let path = try XCTUnwrap(app.path(forResource: lang, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            let intro = String(localized: "assistant.consent.intro \("OpenAI, Anthropic")", bundle: bundle)
            XCTAssertTrue(intro.contains("OpenAI, Anthropic"), "\(lang): \(intro)")
            XCTAssertFalse(intro.hasPrefix("assistant."), "\(lang): \(intro)")
        }
    }
}
