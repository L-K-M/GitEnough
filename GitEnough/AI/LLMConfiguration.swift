import Foundation

/// Settings for the smart-commit LLM. Non-secret fields live in UserDefaults; the
/// API key lives in the Keychain (see KeychainStore).
///
/// Any OpenAI-compatible chat-completions endpoint works. The default provider is
/// Z.AI's GLM coding endpoint — the same service that powers this repository's
/// automated PR reviews — but OpenAI and any custom-compatible server (local
/// llama.cpp, LiteLLM, …) can be selected in Settings.
struct LLMConfiguration: Equatable {

    enum Provider: String, CaseIterable, Identifiable {
        case zai = "Z.AI (GLM)"
        case openai = "OpenAI"
        case custom = "Custom (OpenAI-compatible)"

        var id: String { rawValue }

        var defaultBaseURL: String {
            switch self {
            case .zai: return "https://api.z.ai/api/coding/paas/v4"
            case .openai: return "https://api.openai.com/v1"
            case .custom: return ""
            }
        }

        var defaultModel: String {
            switch self {
            case .zai: return "glm-4.6"
            case .openai: return "gpt-4o-mini"
            case .custom: return ""
            }
        }
    }

    var provider: Provider
    var baseURL: String
    var model: String

    static let `default` = LLMConfiguration(provider: .zai,
                                            baseURL: Provider.zai.defaultBaseURL,
                                            model: Provider.zai.defaultModel)

    var chatCompletionsURL: URL? {
        endpoint("chat/completions")
    }

    var modelsURL: URL? {
        endpoint("models")
    }

    private func endpoint(_ path: String) -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed + "/" + path)
    }

    // MARK: - Persistence

    private enum Keys {
        static let provider = "llm.provider"
        static let baseURL = "llm.baseURL"
        static let model = "llm.model"
        static let keychainAccount = "llm.apiKey"
    }

    static func load(defaults: UserDefaults = .standard) -> LLMConfiguration {
        let providerRaw = defaults.string(forKey: Keys.provider)
        let provider = providerRaw.flatMap(Provider.init(rawValue:)) ?? .zai
        return LLMConfiguration(
            provider: provider,
            baseURL: defaults.string(forKey: Keys.baseURL) ?? provider.defaultBaseURL,
            model: defaults.string(forKey: Keys.model) ?? provider.defaultModel
        )
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set(provider.rawValue, forKey: Keys.provider)
        defaults.set(baseURL, forKey: Keys.baseURL)
        defaults.set(model, forKey: Keys.model)
    }

    // MARK: - API key (Keychain)

    static var apiKey: String? {
        get { KeychainStore.read(account: Keys.keychainAccount) }
    }

    static func saveAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainStore.delete(account: Keys.keychainAccount)
        } else {
            try KeychainStore.save(secret: trimmed, account: Keys.keychainAccount)
        }
    }
}
