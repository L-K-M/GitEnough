import AppKit

extension NSPasteboard {
    /// The clear-then-set two-step every copy action needs; one place instead
    /// of an inline pair per call site. Returns whether the write succeeded —
    /// UI call sites ignore it, tests and future diagnostics don't have to.
    @discardableResult
    func copyString(_ text: String) -> Bool {
        clearContents()
        return setString(text, forType: .string)
    }
}
