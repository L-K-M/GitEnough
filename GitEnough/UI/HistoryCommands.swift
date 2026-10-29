import SwiftUI

struct HistoryCommandContext {
    var find: () -> Void
    var selectedCommitCommands: AnyView?
}

private struct HistoryCommandKey: FocusedValueKey {
    typealias Value = HistoryCommandContext
}

extension FocusedValues {
    var historyCommands: HistoryCommandContext? {
        get { self[HistoryCommandKey.self] }
        set { self[HistoryCommandKey.self] = newValue }
    }
}

/// The scene supplies selection actions, so neither another repository window
/// nor Settings can accidentally act on a commit in a background window.
struct HistoryCommands: Commands {
    @FocusedValue(\.historyCommands) private var context

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Find in History…") { context?.find() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(context == nil)
        }
        CommandMenu("Commit") {
            if let commands = context?.selectedCommitCommands {
                commands
            } else {
                Button("No Commit Selected") {}
                    .disabled(true)
            }
        }
    }
}
