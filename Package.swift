// swift-tools-version: 5.9
import PackageDescription

// No XCTest / swift-testing target here on purpose: `swift test` on macOS wraps
// tests in an XCTest bundle, and XCTest ships with Xcode, not with the Command
// Line Tools. To keep the project buildable and testable without Xcode, the
// tests are a plain executable with a tiny hand-rolled harness — run it with
// `make test`.
let package = Package(
    name: "DockFix",
    platforms: [.macOS(.v14)],
    targets: [
        // Everything except the @main entry point lives here so the test
        // runner can import it.
        .target(
            name: "DockFixCore",
            path: "Sources/DockFixCore"
        ),
        .executableTarget(
            name: "DockFix",
            dependencies: ["DockFixCore"],
            path: "Sources/DockFix"
        ),
        .executableTarget(
            name: "DockFixTests",
            dependencies: ["DockFixCore"],
            path: "Tests/DockFixTests"
        ),
    ]
)
