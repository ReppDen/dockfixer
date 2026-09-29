import Foundation

/// Minimal test harness.
///
/// Exists because XCTest is unavailable outside Xcode and this project targets
/// bare Command Line Tools. It only needs to compare values and report the
/// first useful thing about a mismatch, which is all the geometry tests do.
final class TestRun {
    private var currentSuite = ""
    private var checks = 0
    private var failures: [String] = []

    func suite(_ name: String, _ body: (TestRun) -> Void) {
        currentSuite = name
        let before = failures.count
        body(self)
        let failed = failures.count - before
        let mark = failed == 0 ? "ok  " : "FAIL"
        print("\(mark) \(name)\(failed == 0 ? "" : "  (\(failed) failed)")")
    }

    func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
        checks += 1
        if !condition { failures.append("\(currentSuite): \(message())") }
    }

    func expect(_ a: CGFloat, near b: CGFloat, _ message: @autoclosure () -> String) {
        expect(abs(a - b) < 0.01, "\(message()) — expected \(b), got \(a)")
    }

    func fail(_ message: String) {
        checks += 1
        failures.append("\(currentSuite): \(message)")
    }

    /// Prints a summary and exits non-zero if anything failed.
    func finish() -> Never {
        print("")
        if failures.isEmpty {
            print("\(checks) checks passed")
            exit(0)
        }
        print("\(failures.count) of \(checks) checks failed:")
        for f in failures { print("  - \(f)") }
        exit(1)
    }
}
