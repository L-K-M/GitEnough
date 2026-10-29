import SwiftUI

/// Read-only selection results belong to a window. Mutations and these reads
/// still share the repository's queue, preserving ordering around index changes.
final class ChangesSelectionModel: ObservableObject {
    @Published private(set) var diff = ""
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    private var generation: UInt64 = 0
    private var pendingRead: DispatchWorkItem?

    deinit { pendingRead?.cancel() }

    func select(_ selection: ChangeSelection?, in viewModel: RepoViewModel) {
        dispatchPrecondition(condition: .onQueue(.main))
        pendingRead?.cancel()
        pendingRead = nil
        generation &+= 1
        let request = generation
        errorMessage = nil
        guard let selection else {
            diff = ""
            isLoading = false
            return
        }
        isLoading = true
        diff = ""
        let read = DispatchWorkItem { [weak self] in
            let result = Result {
                selection.file.isUntracked
                    ? try viewModel.client.diffForUntracked(path: selection.file.path)
                    : try viewModel.client.diff(path: selection.file.path, staged: selection.isStaged)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == request else { return }
                self.pendingRead = nil
                self.isLoading = false
                switch result {
                case .success(let diff): self.diff = diff
                case .failure(let error): self.errorMessage = error.localizedDescription
                }
            }
        }
        pendingRead = read
        viewModel.queue.async(execute: read)
    }
}
