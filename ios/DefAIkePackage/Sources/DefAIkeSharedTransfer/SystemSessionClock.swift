import DefAIkeDomain
import Foundation

/// The platform clock, for the two readings the lifecycle needs.
///
/// A separate type rather than a default argument somewhere, so that every component
/// receives its clock explicitly and a deterministic clock can replace it without a
/// production code path silently reading the system time.
public struct SystemSessionClock: SessionClock {
    public init() {}

    public var wallClockNow: Date { Date() }

    public var monotonicNow: ContinuousClock.Instant { ContinuousClock.now }
}
