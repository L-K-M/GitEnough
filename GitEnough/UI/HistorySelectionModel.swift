import Foundation
import Combine

/// Read results belong to a history view, while the repository keeps owning the
/// serial queue and mutation state. Two windows can inspect different commits
/// in the same repository without replacing each other's detail or diff.
final class HistorySelectionModel: ObservableObject {
    @Published private(set) var detail: CommitDetail?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading = false
    @Published private(set) var fileDiff = ""
    @Published private(set) var isLoadingFileDiff = false
    @Published private(set) var fileDiffError: String?

    private var detailGeneration: UInt64 = 0
    private var fileGeneration: UInt64 = 0
    private var pendingDetailRead: DispatchWorkItem?
    private var pendingFileRead: DispatchWorkItem?

    deinit {
        pendingDetailRead?.cancel()
        pendingFileRead?.cancel()
    }

    func selectCommit(_ hash: String?, in viewModel: RepoViewModel) {
        dispatchPrecondition(condition: .onQueue(.main))
        pendingDetailRead?.cancel()
        pendingDetailRead = nil
        detailGeneration &+= 1
        let generation = detailGeneration
        detail = nil
        errorMessage = nil
        selectFile(nil, hash: nil, in: viewModel)
        isLoading = hash != nil
        guard let hash else { return }

        let read = DispatchWorkItem { [weak self] in
            let result = Result { try viewModel.client.commitDetail(hash) }
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.detailGeneration else { return }
                self.pendingDetailRead = nil
                self.isLoading = false
                switch result {
                case .success(let detail?):
                    self.detail = detail
                case .success(nil):
                    self.errorMessage = "Git returned details that couldn't be read. Refresh and select the commit again."
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                }
            }
        }
        pendingDetailRead = read
        viewModel.queue.async(execute: read)
    }

    func selectFile(_ path: String?, hash: String?, in viewModel: RepoViewModel) {
        dispatchPrecondition(condition: .onQueue(.main))
        pendingFileRead?.cancel()
        pendingFileRead = nil
        fileGeneration &+= 1
        let generation = fileGeneration
        fileDiff = ""
        fileDiffError = nil
        isLoadingFileDiff = path != nil && hash != nil
        guard let path, let hash else { return }

        let read = DispatchWorkItem { [weak self] in
            let result = Result { try viewModel.client.commitFileDiff(hash: hash, path: path) }
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.fileGeneration else { return }
                self.pendingFileRead = nil
                self.isLoadingFileDiff = false
                switch result {
                case .success(let diff): self.fileDiff = diff
                case .failure(let error): self.fileDiffError = error.localizedDescription
                }
            }
        }
        pendingFileRead = read
        viewModel.queue.async(execute: read)
    }
}
