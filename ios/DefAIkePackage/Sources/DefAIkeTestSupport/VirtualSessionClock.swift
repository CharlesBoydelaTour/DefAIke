import DefAIkeDomain
import Foundation

/// A deterministic ``SessionClock`` a test advances by hand.
///
/// Time never passes on its own, so a deadline test states exactly how much time it
/// wants to have elapsed and gets a repeatable answer. Nothing here sleeps, and the
/// clock exposes no timeout, matching the port: an approved analysis-time limit would
/// arrive as a Resource Budget value, never as a clock behavior (Property 36).
///
/// The wall clock and the monotonic clock advance together by default, and
/// ``setWallClock(_:)`` moves only the wall clock. That is how "the wall clock jumped
/// backwards" is reproduced without touching the elapsed-work measurement, which is the
/// case ``SessionClock/isDue(createdAt:deadline:)`` fails closed on.
public final class VirtualSessionClock: SessionClock, Sendable {
    private struct State {
        var wallClock: Date
        var monotonic: ContinuousClock.Instant
    }

    private let state: LockedBox<State>

    /// Creates a clock at `start`, with an arbitrary monotonic origin.
    ///
    /// The default `start` is a fixed instant rather than `Date()`, so two runs of the
    /// same test see identical wall-clock values.
    public init(start: Date = VirtualSessionClock.defaultStart) {
        self.state = LockedBox(State(wallClock: start, monotonic: ContinuousClock.now))
    }

    /// 2026-01-01T00:00:00Z, a fixed reference instant with no product meaning.
    public static let defaultStart = Date(timeIntervalSince1970: 1_767_225_600)

    public var wallClockNow: Date { state.value.wallClock }

    public var monotonicNow: ContinuousClock.Instant { state.value.monotonic }

    /// Advances both clocks by `duration`.
    public func advance(by duration: Duration) {
        let seconds =
            Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        state.withValue { current in
            current.wallClock = current.wallClock.addingTimeInterval(seconds)
            current.monotonic = current.monotonic.advanced(by: duration)
        }
    }

    /// Advances both clocks past `deadline`, by exactly one millisecond more.
    ///
    /// The deliberate off-by-one-millisecond step keeps a "just due" test honest:
    /// deadline evaluation is inclusive, so a test that means "overdue" should not be
    /// landing exactly on the boundary by accident.
    public func advancePast(_ deadline: ValidatedDuration) {
        advance(by: .milliseconds(Int64(deadline.milliseconds) + 1))
    }

    /// Advances both clocks to exactly `deadline`.
    public func advanceTo(_ deadline: ValidatedDuration) {
        advance(by: deadline.duration)
    }

    /// Moves the wall clock only, leaving monotonic time untouched.
    ///
    /// Reproduces a system time change, including one that moves backwards.
    public func setWallClock(_ instant: Date) {
        state.withValue { $0.wallClock = instant }
    }
}
