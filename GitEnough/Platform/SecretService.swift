import Foundation

/// The Linux half of `KeychainStore`: the freedesktop Secret Service, reached
/// through libsecret's `secret-tool` command line.
///
/// Driving the CLI instead of linking libsecret keeps the "no third-party
/// dependencies" rule intact — the same trade GitEnough already makes by
/// shelling out to `git` instead of linking libgit2. Whatever the session runs
/// (GNOME Keyring, KWallet's Secret Service bridge, KeePassXC) answers on the
/// same D-Bus interface, so one backend covers every desktop.
///
/// There is deliberately **no plain-file fallback**: when `secret-tool` is
/// missing the save fails loudly with an install hint, because a config file
/// with an API key in the clear is exactly what the Keychain rule exists to
/// prevent.
enum SecretService {

    enum SecretServiceError: Error, LocalizedError {
        case toolMissing
        case storeFailed(String)

        var errorDescription: String? {
            switch self {
            case .toolMissing:
                return """
                    Storing the API key needs libsecret's secret-tool, which \
                    isn't installed. On Ubuntu: sudo apt install libsecret-tools
                    """
            case .storeFailed(let message):
                return message.isEmpty
                    ? "Could not save the API key to the system keyring."
                    : "Could not save the API key to the system keyring: \(message)"
            }
        }
    }

    /// Attribute pairs identifying one secret. `secret-tool` matches on the full
    /// set, so these are effectively the primary key.
    static func attributes(service: String, account: String) -> [String] {
        ["service", service, "account", account]
    }

    /// Stores `secret`, replacing any previous value for the same attributes.
    /// Blocking; call it off the main thread.
    ///
    /// The secret goes in over stdin — never as an argument, which would put it
    /// in every process listing on the machine.
    static func save(secret: String, service: String, account: String) throws {
        guard let tool = secretTool else { throw SecretServiceError.toolMissing }
        let label = "GitEnough (\(account))"
        let result = try ProcessRunner.run(
            tool, ["store", "--label=" + label] + attributes(service: service, account: account),
            input: Data(secret.utf8))
        guard result.succeeded else {
            throw SecretServiceError.storeFailed(result.stderr)
        }
    }

    /// The stored secret, or nil when there is none (or no keyring at all).
    /// Blocking; call it off the main thread.
    static func read(service: String, account: String) -> String? {
        guard let tool = secretTool,
              let result = try? ProcessRunner.run(
                  tool, ["lookup"] + attributes(service: service, account: account)),
              result.succeeded
        else { return nil }
        // `secret-tool lookup` prints the secret raw, with no trailing newline;
        // trim anyway so a keyring that adds one can't corrupt the key.
        let secret = result.standardOutput.trimmingCharacters(in: .newlines)
        return secret.isEmpty ? nil : secret
    }

    /// Removes the stored secret. Best effort: a missing tool or a missing item
    /// both mean "there is nothing stored", which is the caller's goal anyway.
    static func delete(service: String, account: String) {
        guard let tool = secretTool else { return }
        _ = try? ProcessRunner.run(
            tool, ["clear"] + attributes(service: service, account: account))
    }

    /// True when this machine can store secrets at all — Settings uses it to
    /// explain why the API key field is refusing to stick.
    static var isAvailable: Bool { secretTool != nil }

    /// Resolved per call rather than cached: `toolMissing` tells the user to
    /// install libsecret-tools, and they must not then have to relaunch the app
    /// for it to be noticed. A PATH probe is a handful of `stat`s, and these
    /// operations are all user-initiated.
    private static var secretTool: URL? { ProcessRunner.which("secret-tool") }
}
