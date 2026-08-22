import AppKit

extension NSPasteboard {
    /// The clear-then-set two-step every copy action needs; one place instead
    /// of an inline pair per call site. Returns whether the write succeeded —
    /// UI call sites ignore it, tests and future diagnostics don't have to —
    /// and logs a failure rather than swallowing it.
    ///
    /// Deliberately not `@MainActor`: it touches no view state, and isolating
    /// it would bar the non-isolated test suite from driving it against a
    /// private pasteboard.
    @discardableResult
    func copyString(_ text: String) -> Bool {
        clearContents()
        // A string write to a private pasteboard can't meaningfully fail —
        // but if it ever does, the failure is logged, not swallowed.
        let wrote = setString(text, forType: .string)
        if !wrote {
            NSLog("[GitEnough] NSPasteboard.setString failed for %ld characters on %@",
                  text.count, name.rawValue)
        }
        return wrote
    }
}
