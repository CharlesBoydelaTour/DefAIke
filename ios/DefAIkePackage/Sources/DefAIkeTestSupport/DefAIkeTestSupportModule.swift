/// Boundary marker for the test-only port doubles.
///
/// Responsibility: bounded in-memory fakes and call spies for every application port
/// in `DefAIkeDomain`, so domain and application behavior can be exercised without
/// PhotosUI, Image I/O, Core Graphics, Core ML, C2PA, the file system, or a physical
/// device. Nothing here decides a policy, budget, deadline, boundary, trust rule,
/// mapping, or gate outcome: a double returns what a test programmed it to return.
///
/// Dependency rule: `DefAIkeDomain` only, and **nonshipping**. This module belongs to
/// no product, so it cannot be linked into the main app, the Share Extension, or either
/// capability composition. `ios/Scripts/check-module-boundaries.py` enforces that:
/// it fails if any product closure reaches this module, if any shipping module depends
/// on it, or if no test target uses it.
///
/// A double is never release evidence. Host results are development checks, and a fake
/// proves nothing about Foundation, Image I/O, Core ML, or `c2pa-swift`; integration
/// and physical-device tests close that gap.
///
/// Populated by task 1.4.
public enum DefAIkeTestSupportModule: Sendable {
    /// Stable module identifier used by module-boundary and release-audit checks.
    public static let name = "DefAIkeTestSupport"

    /// Always false. Asserted by the boundary check and by the wiring test, so a future
    /// edit that adds this module to a shipping product is caught by name.
    public static let isShippingModule = false
}
