import SwiftUI

/// SwiftUI owns the Edit menu's labels and key equivalents. Bridge the focused
/// native composer into that menu, leaving other controls on standard commands.
struct CommitMessageUndoCommands: Commands {
    @FocusedObject private var controller: CommitMessageUndoController?

    var body: some Commands {
        if let controller, controller.state.isFocused {
            CommandGroup(replacing: .undoRedo) {
                Button(controller.state.undoTitle, action: controller.undo)
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!controller.state.canUndo)
                Button(controller.state.redoTitle, action: controller.redo)
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!controller.state.canRedo)
            }
        }
    }
}
