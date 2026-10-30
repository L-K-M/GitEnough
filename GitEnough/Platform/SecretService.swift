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
public enum SecretService {

    public enum SecretServiceError: Error, LocalizedError {
        case toolMissing
        case storeFailed(String)
        case timedOut

        public var errorDescription: String? {
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
            case .timedOut:
                return """
                    The system keyring didn't answer. If your login keyring is \
                    locked, unlock it and try again.
                    """
            }
        }
    }

    /// How long any one `secret-tool` call may take.
    ///
    /// A keyring that is running and unlocked answers in milliseconds. The case
    /// this bounds is the one that otherwise never ends: when the item lives in
    /// a **locked** keyring, libsecret asks the session to unlock it, and on a
    /// session with no prompter — a minimal window manager, a headless login,
    /// a keyring installed but never set up — nothing ever answers and the call
    /// blocks for the life of the process. Before this bound existed that hung
    /// ✨ Generate with no error and no way back.
    ///
    /// Sixty seconds, because where there *is* a prompter the unlock is a human
    /// typing a password, and cutting that off would break the case that works.
    static let operationTimeout: TimeInterval = 60

    /// Attribute pairs identifying one secret. `secret-tool` matches on the full
    /// set, so these are effectively the primary key.
    public static func attributes(service: String, account: String) -> [String] {
        ["service", service, "account", account]
    }

    /// Stores `secret`, replacing any previous value for the same attributes.
    /// Blocking; call it off the main thread.
    ///
    /// The secret goes in over stdin — never as an argument, which would put it
    /// in every process listing on the machine.
    public static func save(secret: String, service: String, account: String) throws {
        guard let tool = secretTool else { throw SecretServiceError.toolMissing }
        let label = "GitEnough (\(account))"
        let result: ProcessRunner.Result
        do {
            result = try ProcessRunner.run(
                tool, ["store", "--label=" + label] + attributes(service: service, account: account),
                input: Data(secret.utf8),
                timeout: operationTimeout)
        // Two different causes, one remedy for the person at the keyboard: the
        // keyring never confirmed the write, either because it did not answer
        // in time or because its output never closed.
        } catch ProcessRunner.RunError.timedOut, ProcessRunner.RunError.outputNeverEnded {
            throw SecretServiceError.timedOut
        } catch {
            // Everything save() throws is a SecretServiceError, so a launch
            // failure arrives described as what it stopped rather than as a
            // bare process error.
            throw SecretServiceError.storeFailed(error.localizedDescription)
        }
        guard result.succeeded else {
            throw SecretServiceError.storeFailed(result.stderr)
        }
    }

    /// The stored secret, or nil when there is none — which also covers no
    /// keyring at all, and a keyring that did not answer within
    /// `operationTimeout`. Blocking; call it off the main thread.
    ///
    /// Reading is a convenience (the caller can always be given a fresh key),
    /// so every one of those is the same answer here: nothing to hand back.
    /// Writing cannot be so relaxed, and `save` reports each case separately.
    public static func read(service: String, account: String) -> String? {
        guard case .found(let secret) = lookup(service: service, account: account) else {
            return nil
        }
        return secret
    }

    /// The stored secret, distinguishing "nothing is stored" from "the keyring
    /// could not be asked". Blocking; call it off the main thread.
    ///
    /// `secret-tool lookup` leaves exactly one usable signal for the
    /// difference, measured on libsecret 0.21 / gtk4 4.14.5:
    ///
    ///     key exists                exit 0, the value on stdout, stderr empty
    ///     nothing stored            exit 1, stdout empty, **stderr empty**
    ///     keyring not reachable     exit 1, stdout empty, **stderr non-empty**
    ///
    /// So a silent non-zero exit is absence and a talkative one is a failure.
    /// A missing tool or a timeout are failures too — in neither case did
    /// anything confirm that the store is empty.
    public static func lookup(service: String, account: String) -> SecretLookup {
        guard let tool = secretTool else { return .unavailable }
        guard let result = try? ProcessRunner.run(
            tool, ["lookup"] + attributes(service: service, account: account),
            timeout: operationTimeout)
        else { return .unavailable }

        guard result.succeeded else {
            return result.stderr.isEmpty ? .absent : .unavailable
        }
        // `secret-tool lookup` prints the secret raw, with no trailing newline;
        // trim anyway so a keyring that adds one can't corrupt the key.
        let secret = result.standardOutput.trimmingCharacters(in: .newlines)
        return secret.isEmpty ? .absent : .found(secret)
    }

    /// Removes the stored secret. Best effort: a missing tool or a missing item
    /// both mean "there is nothing stored", which is the caller's goal anyway.
    public static func delete(service: String, account: String) {
        guard let tool = secretTool else { return }
        _ = try? ProcessRunner.run(
            tool, ["clear"] + attributes(service: service, account: account),
            timeout: operationTimeout)
    }

    /// The Linux half of `KeychainStore.isAvailable`, which is what callers
    /// outside the platform layer ask: a front end should not have to know
    /// which secret store it is on to find out whether there is one.
    public static var isAvailable: Bool { secretTool != nil }

    /// Resolved per call rather than cached: `toolMissing` tells the user to
    /// install libsecret-tools, and they must not then have to relaunch the app
    /// for it to be noticed. A PATH probe is a handful of `stat`s, and these
    /// operations are all user-initiated.
    private static var secretTool: URL? { ProcessRunner.which("secret-tool") }
}
