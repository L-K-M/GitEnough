import XCTest
@testable import GitEnough

/// Tests for the settings the ✨ Generate button runs on.
///
/// The contract both Settings panes depend on is that what one of them saves is
/// what the next open reads back — a front end that writes a provider and finds
/// another provider's endpoint beside it has configured nothing.
final class LLMConfigurationTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        let suite = "GitEnoughTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        addTeardownBlock { [defaults] in
            defaults?.removePersistentDomain(forName: suite)
        }
    }

    func testSavedSettingsComeBack() {
        let saved = LLMConfiguration(provider: .openai,
                                     baseURL: "https://example.test/v1",
                                     model: "gpt-probe")
        saved.save(defaults: defaults)

        XCTAssertEqual(LLMConfiguration.load(defaults: defaults), saved)
    }

    /// A fresh install has nothing stored, and must still have a working
    /// endpoint and model rather than two empty fields.
    func testUnsetSettingsFallBackToTheProviderDefaults() {
        let loaded = LLMConfiguration.load(defaults: defaults)

        XCTAssertEqual(loaded.provider, .zai)
        XCTAssertEqual(loaded.baseURL, LLMConfiguration.Provider.zai.defaultBaseURL)
        XCTAssertEqual(loaded.model, LLMConfiguration.Provider.zai.defaultModel)
    }

    /// Switching providers in Settings replaces the endpoint, but the stored
    /// provider is read before the stored URL — so a half-written pair resolves
    /// to the stored provider's defaults rather than the first provider's.
    func testAStoredProviderDecidesTheFallbacks() {
        defaults.set(LLMConfiguration.Provider.openai.rawValue, forKey: "llm.provider")

        let loaded = LLMConfiguration.load(defaults: defaults)

        XCTAssertEqual(loaded.provider, .openai)
        XCTAssertEqual(loaded.baseURL, LLMConfiguration.Provider.openai.defaultBaseURL)
        XCTAssertEqual(loaded.model, LLMConfiguration.Provider.openai.defaultModel)
    }

    /// Settings is a plist key away from anything on the machine, so an
    /// unreadable provider name must not leave the app with no provider at all.
    func testAnUnknownStoredProviderFallsBack() {
        defaults.set("Provider From The Future", forKey: "llm.provider")

        XCTAssertEqual(LLMConfiguration.load(defaults: defaults).provider, .zai)
    }

    // MARK: - Endpoints

    func testEndpointsJoinWithoutDoubleSlashes() {
        let configuration = LLMConfiguration(provider: .custom,
                                             baseURL: "  https://example.test/v1/  ",
                                             model: "local")

        XCTAssertEqual(configuration.chatCompletionsURL?.absoluteString,
                       "https://example.test/v1/chat/completions")
        XCTAssertEqual(configuration.modelsURL?.absoluteString,
                       "https://example.test/v1/models")
    }

    /// `Custom` starts with an empty base URL, which is not an endpoint. The
    /// generator reports that as `invalidEndpoint` rather than building a
    /// request against a relative URL.
    func testAnEmptyBaseURLHasNoEndpoint() {
        let configuration = LLMConfiguration(provider: .custom, baseURL: "   ", model: "local")

        XCTAssertNil(configuration.chatCompletionsURL)
        XCTAssertNil(configuration.modelsURL)
    }
}
