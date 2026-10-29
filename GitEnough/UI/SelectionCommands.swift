import SwiftUI

struct ChangesActions {
    let canStage: Bool
    let canUnstage: Bool
    let canStageAll: Bool
    let canUnstageAll: Bool
    let canCommit: Bool
    let canStash: Bool
    let canGenerate: Bool
    let canDiscard: Bool
    let stage: () -> Void
    let unstage: () -> Void
    let stageAll: () -> Void
    let unstageAll: () -> Void
    let commit: () -> Void
    let stash: () -> Void
    let generate: () -> Void
    let discard: () -> Void
    let editMessage: () -> Void
}

struct BranchActions {
    let canCheckout: Bool
    let canRename: Bool
    let canMerge: Bool
    let canDelete: Bool
    let canUseStash: Bool
    let checkout: () -> Void
    let rename: () -> Void
    let merge: () -> Void
    let delete: () -> Void
    let applyStash: () -> Void
    let popStash: () -> Void
    let dropStash: () -> Void
}

private struct ChangesActionsKey: FocusedValueKey {
    typealias Value = ChangesActions
}

private struct BranchActionsKey: FocusedValueKey {
    typealias Value = BranchActions
}

extension FocusedValues {
    var changesActions: ChangesActions? {
        get { self[ChangesActionsKey.self] }
        set { self[ChangesActionsKey.self] = newValue }
    }

    var branchActions: BranchActions? {
        get { self[BranchActionsKey.self] }
        set { self[BranchActionsKey.self] = newValue }
    }
}

/// These values are supplied by the visible tab of the key repository window.
/// Text editing continues through the standard Edit menu and responder chain.
struct SelectionCommands: Commands {
    @FocusedValue(\.changesActions) private var changes
    @FocusedValue(\.branchActions) private var branch

    var body: some Commands {
        CommandMenu("Changes") {
            Button("Stage Selected File") { changes?.stage() }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(changes?.canStage != true)
            Button("Unstage Selected File") { changes?.unstage() }
                .keyboardShortcut("u", modifiers: [.command, .option])
                .disabled(changes?.canUnstage != true)
            Divider()
            Button("Stage All") { changes?.stageAll() }
                .keyboardShortcut("s", modifiers: [.command, .option, .shift])
                .disabled(changes?.canStageAll != true)
            Button("Unstage All") { changes?.unstageAll() }
                .keyboardShortcut("u", modifiers: [.command, .option, .shift])
                .disabled(changes?.canUnstageAll != true)
            Divider()
            Button("Edit Commit Message") { changes?.editMessage() }
                .keyboardShortcut("m", modifiers: [.command, .option])
                .disabled(changes == nil)
            Button("Generate Commit Message") { changes?.generate() }
                .disabled(changes?.canGenerate != true)
            Button("Commit") { changes?.commit() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(changes?.canCommit != true)
            Divider()
            Button("Stash Changes…") { changes?.stash() }
                .disabled(changes?.canStash != true)
            Button("Discard Selected File Changes…", role: .destructive) { changes?.discard() }
                .disabled(changes?.canDiscard != true)
        }
        CommandMenu("Branch") {
            Button("Check Out Selected Branch") { branch?.checkout() }
                .disabled(branch?.canCheckout != true)
            Button("Rename Selected Branch…") { branch?.rename() }
                .disabled(branch?.canRename != true)
            Button("Merge Selected Branch…") { branch?.merge() }
                .disabled(branch?.canMerge != true)
            Button("Delete Selected Branch…", role: .destructive) { branch?.delete() }
                .disabled(branch?.canDelete != true)
            Divider()
            Button("Apply Selected Stash") { branch?.applyStash() }
                .disabled(branch?.canUseStash != true)
            Button("Pop Selected Stash") { branch?.popStash() }
                .disabled(branch?.canUseStash != true)
            Button("Drop Selected Stash…", role: .destructive) { branch?.dropStash() }
                .disabled(branch?.canUseStash != true)
        }
    }
}
