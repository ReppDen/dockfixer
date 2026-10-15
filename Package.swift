// swift-tools-version: 5.9
import PackageDescription

// No XCTest / swift-testing target here on purpose: `swift test` on macOS wraps
// tests in an XCTest bundle, and XCTest ships with Xcode, not with the Command
// Line Tools. To keep the project buildable and testable without Xcode, the
// tests are a plain executable with a tiny hand-rolled harness — run it with
// `make test`.
let package = Package(
    name: "DockFixer",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Updates. Pinned exactly: the framework is copied into the bundle by
        // the Makefile, and a new Sparkle is something to read the changelog of
        // first, not something to pick up by accident.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        // Everything except the @main entry point lives here so the test
        // runner can import it.
        .target(
            name: "DockFixerCore",
            path: "Sources/DockFixerCore"
        ),
        .executableTarget(
            name: "DockFixer",
            dependencies: [
                "DockFixerCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/DockFixer"
        ),
        .executableTarget(
            name: "DockFixerTests",
            dependencies: ["DockFixerCore"],
            path: "Tests/DockFixerTests"
        ),
    ]
)
