import Foundation

/// One in-flight Settings operation's identity: which showing of the editor
/// asked for it, and what the fields held at the time.
///
/// Carries a revision rather than the key itself. The comparison only needs to
/// know *whether* the key changed, and a revision answers that without a copy
/// of the secret living in a capture for the length of a network call.
public struct SettingsRequest: Equatable {
    /// Public because a completion records it as what reached storage; the
    /// other two are only ever compared, which `SettingsEditState` does.
    public let configuration: LLMConfiguration
    let presentation: Int
    let keyRevision: Int
}

/// The decisions a Settings editor has to make about its own asynchronous
/// lifecycle, with no window attached.
///
/// Both front ends ask the same three questions, and all three have been got
/// wrong at least once: may this save write the key, does this result still
/// describe what is on screen, and did the fields move while a write was out.
/// Keeping them here makes the transitions testable, which a GTK dialog is
/// not.
public struct SettingsEditState: Equatable {

    /// Which showing of the editor this is. Bumped on every presentation so a
    /// result started by a previous one can be recognised and dropped.
    public private(set) var presentation = 0
    /// Bumped every time the user edits the key field. Programmatic fills do
    /// not count: they are the editor showing what is already stored.
    public private(set) var keyRevision = 0
    /// Whether the user has touched the key field this showing.
    public private(set) var userEditedKey = false
    public private(set) var isBusy = false

    public init() {}

    // MARK: - Transitions

    /// Opens the editor afresh.
    ///
    /// Clears `isBusy` as well as the key state: an operation still running
    /// from the previous showing will have its result discarded, so its
    /// completion will never clear the flag, and leaving it set disables the
    /// buttons of the new showing for good.
    public mutating func present() {
        presentation += 1
        keyRevision = 0
        userEditedKey = false
        isBusy = false
    }

    public mutating func editKey() {
        userEditedKey = true
        keyRevision += 1
    }

    public mutating func beginOperation() { isBusy = true }

    public mutating func endOperation() { isBusy = false }

    // MARK: - Questions

    public func request(for configuration: LLMConfiguration) -> SettingsRequest {
        SettingsRequest(configuration: configuration,
                        presentation: presentation,
                        keyRevision: keyRevision)
    }

    /// Whether a result for `request` still describes what the user is looking
    /// at. A models list or a connection verdict belongs to the provider,
    /// endpoint and credentials it was fetched with; apply it to any other and
    /// it becomes a claim about settings nobody tested.
    public func accepts(_ request: SettingsRequest,
                        configuration: LLMConfiguration) -> Bool {
        request.presentation == presentation
            && request.configuration == configuration
            && request.keyRevision == keyRevision
    }

    /// Whether `request` belongs to the showing now on screen, regardless of
    /// what the fields have since become. Asked where only the dialog's
    /// identity matters — an opening read has no configuration to validate,
    /// and a discarded result is worth explaining only if the user is still
    /// looking at the dialog that asked for it.
    public func isFromCurrentPresentation(_ request: SettingsRequest) -> Bool {
        request.presentation == presentation
    }

    /// What a save should write to the secret store: the displayed key, or nil
    /// to leave the stored one alone.
    ///
    /// nil whenever the user has not touched the field, which is what stops a
    /// save aimed at the model name from deleting a key the editor could not
    /// read. Clearing the field is an edit, so removing a key still works.
    public func keyPayload(displayed: String) -> String? {
        userEditedKey ? displayed : nil
    }

    /// Whether the fields have moved since `request` was made.
    ///
    /// Asked after a write lands, because the fields stay editable while one
    /// is out. The key side is checked even when the save carried no key: the
    /// user may have typed one *during* the write, and reporting a plain
    /// "Saved" would claim a key reached the store that never did.
    public func moved(since request: SettingsRequest,
                      configuration: LLMConfiguration) -> Bool {
        request.configuration != configuration || request.keyRevision != keyRevision
    }
}
