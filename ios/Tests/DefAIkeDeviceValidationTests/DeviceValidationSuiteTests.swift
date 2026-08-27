import Testing

@testable import DefAIkeReleaseValidation

/// Physical-device validation target.
///
/// Runs the approved Device Validation Plan on candidate iPhones and records the
/// device model and hardware identifier, iOS version, app build, Model Bundle
/// version, fixture-suite version, plan version, enabled capability set,
/// capability implementation versions, measured values, categorical comparisons,
/// and pass or fail result for every mandatory gate (Requirement 13.17).
///
/// It measures main-app and Share Extension resource behavior as separate sets
/// with separate gate results (Requirement 11.19). No threshold is chosen after
/// observing a result, missing data is failure, and results from different
/// version tuples are never pooled.
///
/// Simulator and Mac runs of this target are development checks only; they cannot
/// satisfy a physical-device release gate.
@Suite("Device validation target wiring")
struct DeviceValidationSuiteTests {
    @Test("Release validation tooling is reachable from the device target")
    func releaseValidationLinked() {
        #expect(DefAIkeReleaseValidationModule.name == "DefAIkeReleaseValidation")
    }
}
