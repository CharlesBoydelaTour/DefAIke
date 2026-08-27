import Foundation

// The clock port.
//
// Two clocks, for two different jobs, because using one for both would be wrong in
// opposite directions:
//
//   * Cleanup deadlines are compared against a ticket's recorded `createdAt` and
//     survive process restarts, so they need wall-clock time.
//   * Elapsed-work measurement feeds resource limits and must not jump when the
//     user changes the time zone or the system corrects the clock, so it needs a
//     monotonic reading.
//
// The port exposes only readings. It has no `sleep`, no `timeout`, no `deadline`, and
// no scheduling member, because Requirement 15.5 and design decision "does not invent
// a time limit" forbid a requirement-level timeout that no approved artifact
// measured. A future approved analysis-time limit arrives as a Resource Budget value
// enforced through ``ResourceGoverning``, not as a clock API (Property 36).

/// Time readings for lifecycle deadlines and elapsed-work measurement.
///
/// Injected everywhere rather than read from the environment, so every deadline and
/// duration property runs against a deterministic virtual clock.
public protocol SessionClock: Sendable {
    /// Wall-clock instant, for evaluating Data Lifecycle Policy deadlines and for
    /// stamping deletion receipts and transfer tickets.
    ///
    /// Never used to measure how long work took: a wall clock can move backwards.
    var wallClockNow: Date { get }

    /// Monotonic instant, for measuring how long work took.
    ///
    /// Never used for a deadline that must survive a process restart: continuous
    /// instants are not comparable across launches.
    var monotonicNow: ContinuousClock.Instant { get }
}

extension SessionClock {
    /// Monotonic time elapsed since `instant`.
    public func elapsed(since instant: ContinuousClock.Instant) -> Duration {
        instant.duration(to: monotonicNow)
    }

    /// Whether `deadline` has passed for material created at `createdAt`.
    ///
    /// The comparison is inclusive: material exactly at its deadline is due for cleanup
    /// rather than granted one more interval. `Date` differences are seconds as
    /// `Double`, so the elapsed side carries `TimeInterval` precision; the policy side
    /// is the exact millisecond integer the artifact declared. At the millisecond scale
    /// of a cleanup deadline that difference is far below one millisecond, and the
    /// inclusive comparison means any residual error can only make cleanup due a hair
    /// early rather than late.
    public func isDue(createdAt: Date, deadline: ValidatedDuration) -> Bool {
        let elapsedMilliseconds = wallClockNow.timeIntervalSince(createdAt) * 1000
        guard elapsedMilliseconds >= 0 else {
            // The recorded creation instant is in the future, which means the wall
            // clock moved. Fail closed toward retention rather than deleting material
            // whose age cannot be established.
            return false
        }
        return elapsedMilliseconds >= Double(deadline.milliseconds)
    }
}
