import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// An external merge/conflict-resolution tool the user may have installed.
///
/// Detection probes executables — absolute paths and, on Linux, names on PATH —
/// plus `/Applications` bundles on macOS. Invocation always goes through
/// `git mergetool --tool=<gitName>`, which knows each tool's CLI contract, so
/// GitEnough never has to construct tool-specific argument lists itself.
struct MergeTool: Identifiable, Hashable {
    let name: String              // display name
    let gitName: String           // `git mergetool --tool=` identifier
    let executablePaths: [String] // absolute paths, probed directly
    let executableNames: [String] // command names, resolved against PATH
    let bundleIdentifiers: [String]

    init(name: String,
         gitName: String,
         executablePaths: [String] = [],
         executableNames: [String] = [],
         bundleIdentifiers: [String] = []) {
        self.name = name
        self.gitName = gitName
        self.executablePaths = executablePaths
        self.executableNames = executableNames
        self.bundleIdentifiers = bundleIdentifiers
    }

    var id: String { gitName }

    #if canImport(AppKit)
    /// All tools git ships mergetool configs for that are common on macOS.
    /// FileMerge (opendiff) ships with Xcode, so there's always at least one.
    static let known: [MergeTool] = [
        MergeTool(name: "FileMerge", gitName: "opendiff",
                  executablePaths: ["/usr/bin/opendiff"],
                  bundleIdentifiers: ["com.apple.FileMerge"]),
        MergeTool(name: "Kaleidoscope", gitName: "kaleidoscope",
                  executablePaths: ["/usr/local/bin/ksdiff", "/opt/homebrew/bin/ksdiff"],
                  bundleIdentifiers: ["com.blackpixel.kaleidoscope", "com.kaleidoscopeapp.Kaleidoscope"]),
        MergeTool(name: "Beyond Compare", gitName: "bc",
                  executablePaths: ["/usr/local/bin/bcompare", "/opt/homebrew/bin/bcompare"],
                  bundleIdentifiers: ["com.ScooterSoftware.BeyondCompare"]),
        MergeTool(name: "Araxis Merge", gitName: "araxis",
                  executablePaths: ["/usr/local/bin/araxisgitdiff", "/opt/homebrew/bin/araxisgitdiff"],
                  bundleIdentifiers: ["com.araxis.merge"]),
        MergeTool(name: "P4Merge", gitName: "p4mergetool",
                  executablePaths: ["/usr/local/bin/p4merge", "/opt/homebrew/bin/p4merge"],
                  bundleIdentifiers: ["com.perforce.p4merge"]),
        MergeTool(name: "Meld", gitName: "meld",
                  executablePaths: ["/usr/local/bin/meld", "/opt/homebrew/bin/meld"],
                  bundleIdentifiers: ["org.gnome.meld"]),
        MergeTool(name: "DeltaWalker", gitName: "deltawalker",
                  executablePaths: ["/usr/local/bin/DeltaWalker", "/opt/homebrew/bin/DeltaWalker"],
                  bundleIdentifiers: ["com.deltopia.deltawalker"]),
        MergeTool(name: "Sublime Merge", gitName: "smerge",
                  executablePaths: ["/usr/local/bin/smerge", "/opt/homebrew/bin/smerge"],
                  bundleIdentifiers: ["com.sublimemerge"]),
        MergeTool(name: "KDiff3", gitName: "kdiff3",
                  executablePaths: ["/usr/local/bin/kdiff3", "/opt/homebrew/bin/kdiff3"],
                  bundleIdentifiers: ["org.kde.kdiff3"]),
    ]
    #else
    /// The graphical tools git ships mergetool configs for that are packaged on
    /// Ubuntu and friends. Deliberately no terminal-driven tools (vimdiff,
    /// nvimdiff, xxdiff's console mode): GitEnough launches the tool without a
    /// TTY, so one would open into nothing.
    ///
    /// Unlike macOS, nothing here is guaranteed to be present — a fresh Ubuntu
    /// install has no merge tool at all, and the conflict UI has to say so
    /// rather than assume a fallback.
    static let known: [MergeTool] = [
        MergeTool(name: "Meld", gitName: "meld", executableNames: ["meld"]),
        MergeTool(name: "KDiff3", gitName: "kdiff3", executableNames: ["kdiff3"]),
        MergeTool(name: "Kompare", gitName: "kompare", executableNames: ["kompare"]),
        MergeTool(name: "Diffuse", gitName: "diffuse", executableNames: ["diffuse"]),
        MergeTool(name: "Beyond Compare", gitName: "bc", executableNames: ["bcompare"]),
        MergeTool(name: "P4Merge", gitName: "p4merge", executableNames: ["p4merge"]),
        MergeTool(name: "Sublime Merge", gitName: "smerge", executableNames: ["smerge"]),
        MergeTool(name: "DiffMerge", gitName: "diffmerge", executableNames: ["diffmerge"]),
        MergeTool(name: "DeltaWalker", gitName: "deltawalker", executableNames: ["DeltaWalker"]),
        MergeTool(name: "GVim", gitName: "gvimdiff", executableNames: ["gvim"]),
        MergeTool(name: "TkDiff", gitName: "tkdiff", executableNames: ["tkdiff"]),
    ]
    #endif

    /// The subset of `known` currently installed on this machine.
    static func detectInstalled() -> [MergeTool] {
        known.filter { $0.isInstalled }
    }

    /// Detection result, computed lazily on first access and cached: probing
    /// ~9 executables plus ~9 app bundles per conflicted-file row (on the main
    /// thread) made the conflict list stutter. `rescan()` refreshes after the
    /// user installs a tool (Settings → Merge Tools).
    ///
    /// Main-thread only: on macOS detection touches NSWorkspace, and both
    /// writers (lazy init, rescan) and readers (views) live on the main thread.
    private(set) static var installed: [MergeTool] = detectInstalled()

    /// Posted on the main thread whenever `installed` changes, so open
    /// conflict rows refresh instead of showing stale tool availability.
    static let didChangeNotification = Notification.Name("MergeToolInstalledDidChange")

    static func rescan() {
        dispatchPrecondition(condition: .onQueue(.main))
        installed = detectInstalled()
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    var isInstalled: Bool {
        let fm = FileManager.default
        if executablePaths.contains(where: { fm.isExecutableFile(atPath: $0) }) {
            return true
        }
        if executableNames.contains(where: { ProcessRunner.which($0) != nil }) {
            return true
        }
        #if canImport(AppKit)
        return bundleIdentifiers.contains {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        }
        #else
        return false
        #endif
    }
}
