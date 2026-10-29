import Foundation

/// One accepted generated edit. A UI can put this edit on its own text undo
/// stack without making the shared repository model own a window's UndoManager.
public struct CommitMessageReplacement: Equatable {
    public let previousMessage: String
    public let message: String

    public init(previousMessage: String, message: String) {
        self.previousMessage = previousMessage
        self.message = message
    }

    public var inverse: Self {
        Self(previousMessage: message, message: previousMessage)
    }

    public func replacing(_ currentMessage: String) -> String? {
        currentMessage == previousMessage ? message : nil
    }
}
