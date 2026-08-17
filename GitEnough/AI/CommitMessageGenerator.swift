import Foundation

/// Generates commit messages from the staged diff using an OpenAI-compatible
/// chat-completions API (Z.AI GLM by default; see LLMConfiguration).
final class CommitMessageGenerator {

    enum GenerationError: Error, LocalizedError {
        case noAPIKey
        case invalidEndpoint
        case httpError(status: Int, body: String)
        case malformedResponse
        case emptyMessage

        var errorDescription: String? {
            switch self {
            case .noAPIKey:
                return "No API key configured. Add one in Settings → AI."
            case .invalidEndpoint:
                return "The API base URL is invalid. Check Settings → AI."
            case .httpError(let status, let body):
                let snippet = body.prefix(300)
                return "The model endpoint returned HTTP \(status): \(snippet)"
            case .malformedResponse:
                return "The model endpoint returned an unexpected response shape."
            case .emptyMessage:
                return "The model returned an empty commit message."
            }
        }
    }

    private let configuration: LLMConfiguration
    private let apiKeyProvider: () -> String?
    private let session: URLSession

    init(configuration: LLMConfiguration,
         apiKeyProvider: @escaping () -> String? = { LLMConfiguration.apiKey },
         session: URLSession = .shared) {
        self.configuration = configuration
        self.apiKeyProvider = apiKeyProvider
        self.session = session
    }

    // MARK: - Prompt

    /// The diff is capped so a huge refactor can't blow the context window or the
    /// request size; the stat summary always goes in full so the model sees every
    /// touched file even when the patch body is truncated.
    static let maxDiffCharacters = 12_000

    static func prompt(diffStat: String, diff: String, branch: String?) -> String {
        var text = "Write a commit message for the following staged changes"
        if let branch, !branch.isEmpty {
            text += " (on branch \(branch))"
        }
        text += ".\n\n## Diff summary (git diff --staged --stat)\n\n\(diffStat)\n\n## Staged diff (may be truncated)\n\n```diff\n"
        if diff.count > maxDiffCharacters {
            text += String(diff.prefix(maxDiffCharacters))
            text += "\n… [diff truncated]\n"
        } else {
            text += diff
        }
        text += "\n```"
        return text
    }

    static let systemPrompt = """
        You write excellent git commit messages. Rules:
        - First line: a concise subject in the imperative mood, at most 72 characters, \
        no trailing period. Use a Conventional-Commits prefix (feat:, fix:, refactor:, \
        docs:, test:, chore:, perf:, build:, ci:) only when it clearly fits.
        - If the change needs explanation, add one blank line, then a short body of \
        bullet points (lines starting with "- ") saying what and why, not how.
        - Output ONLY the commit message. No quotes, no code fences, no commentary.
        """

    // MARK: - Generation

    func generateCommitMessage(diffStat: String, diff: String, branch: String?) async throws -> String {
        guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
            throw GenerationError.noAPIKey
        }
        guard let url = configuration.chatCompletionsURL else {
            throw GenerationError.invalidEndpoint
        }

        let payload: [String: Any] = [
            "model": configuration.model,
            "temperature": 0.3,
            "max_tokens": 400,
            "messages": [
                ["role": "system", "content": Self.systemPrompt],
                ["role": "user", "content": Self.prompt(diffStat: diffStat, diff: diff, branch: branch)],
            ],
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 45
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GenerationError.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GenerationError.httpError(status: http.statusCode, body: body)
        }

        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw GenerationError.malformedResponse
        }

        let cleaned = Self.cleanGeneratedMessage(content)
        guard !cleaned.isEmpty else { throw GenerationError.emptyMessage }
        return cleaned
    }

    /// Strips the decorations models love to add despite instructions: surrounding
    /// quotes, code fences, leading "Commit message:" labels.
    static func cleanGeneratedMessage(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            // Drop the opening fence line and a trailing fence.
            var lines = text.components(separatedBy: "\n")
            if !lines.isEmpty { lines.removeFirst() }
            if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                lines.removeLast()
            }
            text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for prefix in ["Commit message:", "commit message:", "Message:"] {
            if text.hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // Strip one layer of surrounding quotes.
        if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") {
            text = String(text.dropFirst().dropLast())
        }
        return text
    }
}
