import DefAIkeDomain

/// A programmed sequence of port outcomes.
///
/// Every stub is driven by one of these rather than by ad-hoc closures, so a test reads
/// the same way regardless of which port it is programming, and a retry-after-each-error
/// test can queue "fail, then succeed" without writing stateful glue.
///
/// The final outcome repeats once the queue is drained. That is deliberate: a port called
/// once more than the test expected should keep the behavior the test declared instead of
/// trapping on an empty queue and turning a behavioral bug into an unrelated crash.
public struct StubOutcome<Success: Sendable>: Sendable {
    /// One programmed result.
    public enum Step: Sendable {
        case success(Success)
        case fault(AnalysisFault)
    }

    private let steps: LockedBox<[Step]>
    private let last: LockedBox<Step>

    /// Creates a sequence that always produces `value`.
    public init(always value: Success) {
        self.steps = LockedBox([])
        self.last = LockedBox(.success(value))
    }

    /// Creates a sequence that always throws `fault`.
    public init(alwaysFailing fault: AnalysisFault) {
        self.steps = LockedBox([])
        self.last = LockedBox(.fault(fault))
    }

    /// Creates a sequence of steps. The last step repeats after the queue drains.
    ///
    /// A precondition rather than a failable initializer: an empty queue is a test
    /// authoring mistake with no sensible interpretation.
    public init(_ steps: [Step]) {
        precondition(!steps.isEmpty, "a stub outcome sequence needs at least one step")
        self.steps = LockedBox(Array(steps.dropLast()))
        self.last = LockedBox(steps[steps.count - 1])
    }

    /// Takes the next step, or repeats the final one.
    public func next() -> Step {
        steps.withValue { remaining in
            guard !remaining.isEmpty else { return last.value }
            return remaining.removeFirst()
        }
    }

    /// Takes the next step and either returns its value or throws its fault.
    public func resolve() throws(AnalysisFault) -> Success {
        switch next() {
        case .success(let value): return value
        case .fault(let fault): throw fault
        }
    }
}
