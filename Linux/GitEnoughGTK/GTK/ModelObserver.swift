import GitEnough

/// Redraws a piece of UI whenever a model object changes.
///
/// The core's view models announce `objectWillChange` *before* the value moves,
/// so the refresh is deferred to the next main-loop turn: by then the new state
/// is in place, and a burst of writes — a repo refresh publishes status,
/// branches, commits and layout back to back — collapses into one rebuild
/// instead of four.
final class ModelObserver {

    private var token: AnyCancellable?
    private var refreshPending = false

    init(_ object: some ObservableObject, onChange: @escaping () -> Void) {
        token = object.objectWillChange.sink { [weak self] in
            guard let self, !refreshPending else { return }
            refreshPending = true
            onNextMainLoopTurn { [weak self] in
                self?.refreshPending = false
                onChange()
            }
        }
    }

    deinit { token?.cancel() }
}
