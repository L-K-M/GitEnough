import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Foundation gives a launched process its own process group. Verify that
/// boundary before signalling it: cancelling git must never signal the app's
/// group, and cancelling only git leaves SSH/transport children holding pipes.
final class GitProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private let processID: Int32
    private let processGroup: Int32?
    private var active = true

    init(process: Process) {
        self.process = process
        processID = process.processIdentifier
        let group = processID > 1 ? getpgid(processID) : -1
        processGroup = group > 1 && group == processID && group != getpgrp() ? group : nil
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        guard active, processID > 1 else { return }
        active = false
        if let processGroup {
            // The verified group also covers children still holding stdout or
            // stderr after git exits. KILL is deliberate: a transport may ignore
            // TERM. Current callers cancel clones only: new targets use owned
            // staging; existing empty targets retain any partial contents.
            _ = kill(-processGroup, SIGKILL)
        } else if process.isRunning {
            // Do not send a group signal if a runtime did not isolate it.
            _ = kill(processID, SIGKILL)
        }
    }

    func finish() {
        lock.lock()
        active = false
        lock.unlock()
    }
}
