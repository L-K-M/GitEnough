import AppKit

extension NSPasteboard {
    /// The clear-then-set two-step every copy action needs; one place instead
    /// of an inline pair per call site.
    func copyString(_ text: String) {
        clearContents()
        setString(text, forType: .string)
    }
}
