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
// out of the package: that is the part a Linux front end has to replace.
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
    ]
)
