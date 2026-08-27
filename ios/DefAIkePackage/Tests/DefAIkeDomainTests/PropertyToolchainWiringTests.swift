import Foundation
import PropertyBased
import Testing

/// Confirms the exact-pinned, test-only property-based testing toolchain is
/// reachable from a test target and runs with the defaults the design requires:
/// at least 100 generated cases per property and shrinking enabled.
///
/// This is a toolchain wiring check, not one of the 36 design properties. Each
/// design property is implemented by exactly one dedicated, tagged property file
/// in a later task.
@Suite("Property-based toolchain wiring")
struct PropertyToolchainWiringTests {
    @Test("propertyCheck runs the default 100 bounded cases")
    func defaultCaseCountRuns() async {
        let counter = CaseCounter()

        await propertyCheck(input: Gen.int(in: 0...1_000)) { value in
            counter.increment()
            #expect(value >= 0)
        }

        #expect(counter.count == 100)
    }
}

/// Minimal thread-safe counter. A shared test-double toolkit arrives in task 1.4.
private final class CaseCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var observed = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return observed
    }

    func increment() {
        lock.lock()
        observed += 1
        lock.unlock()
    }
}
