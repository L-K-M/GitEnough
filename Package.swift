// swift-tools-version: 6.0
import PackageDescription

// The `GitEnough` library is the platform-independent half of the app: the git
// plumbing, the graph layout, the forge lookups, the LLM client and the view
// models — everything except the SwiftUI front end.
//
// It is declared over the *existing* directories rather than a Sources/ tree, so
// the Xcode project's file-system-synchronized groups keep working unchanged and
// macOS still builds one flat app module out of GitEnough/. The module keeps the
// app target's name too, so `@testable import GitEnough` means the same thing in
// both builds and the test suite is shared verbatim.
//
// Everything under GitEnough/UI/ (SwiftUI) and the two app-lifecycle files stay
// out of the package: that is the part the Linux front end replaces.
//
// That front end lives in Linux/ rather than under GitEnough/, so the Xcode
// project's file-system-synchronized groups never see GTK sources. Its two
// targets exist only when the manifest is evaluated on Linux — a macOS
// `swift build` gets the library and its tests, and nothing that needs gtk4.
#if os(Linux)
let linuxTargets: [Target] = [
    .systemLibrary(
        name: "CGtk",
        path: "Linux/CGtk",
        pkgConfig: "gtk4",
        providers: [.apt(["libgtk-4-dev"]), .yum(["gtk4-devel"])]),
    .executableTarget(
        name: "gitenough-gtk",
        dependencies: ["GitEnough", "CGtk"],
        path: "Linux/GitEnoughGTK",
        swiftSettings: [.swiftLanguageMode(.v5)]),
]
#else
let linuxTargets: [Target] = []
#endif

let package = Package(
    name: "GitEnough",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GitEnough", targets: ["GitEnough"]),
    ],
    targets: [
        .target(
            name: "GitEnough",
            path: "GitEnough",
            exclude: ["Resources", "UI", "AppDelegate.swift", "GitEnoughApp.swift",
                      "GitEnough.entitlements"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "GitEnoughTests",
            dependencies: ["GitEnough"],
            path: "GitEnoughTests",
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ] + linuxTargets
)
