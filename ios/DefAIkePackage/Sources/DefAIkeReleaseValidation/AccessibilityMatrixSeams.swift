import DefAIkeDomain

// The one thing a matrix run reaches out for: what one execution of one workflow under one
// exercise actually observed.
//
// Everything else a run needs is already an approved value it was handed. The workflow set, the
// assistive conditions, and the localization variants come from the domain's closed vocabularies;
// the candidate configurations and the missing-result rule come from the approved Device
// Validation Plan; each position's major iOS version comes from its configuration; and the version
// tuple comes from the binding. None of them arrives through this seam, and that asymmetry is the
// design: the observed side is the only side a run observes, so it is the only side that can be
// wrong in a way the module has to detect.
//
// **There is no default implementation anywhere in this module.** A runner that has not been given
// a reader cannot be constructed. A reader with no observation for a position reports that fact,
// and the run turns it into a failure — never a skip, never a smaller matrix, never an omission
// from the report.
//
// Deliberately absent from the seam:
//
//   * any member that writes, records, publishes, or caches an observation;
//   * any member that returns an outcome, a `GateOutcome`, a pass criterion, a step count, or a
//     required-cell set, so a reader cannot supply the answer alongside the observation. What a
//     reader returns is one ``ObservedWorkflowCoverage`` case — what it saw — and the run decides
//     what that means;
//   * any member that returns a set, a list, or a page of observations. The run enumerates the
//     required positions from the bound plan and asks for each one by name, so the reader cannot
//     decide which positions the run covers and a partially populated store cannot pass by
//     offering fewer positions to check;
//   * any member that reports how many observations exist, so a run cannot short-circuit on "the
//     store looks empty" and report nothing instead of reporting every position as missing;
//   * any member that returns a configuration, a major iOS version, or a supported-version list. A
//     position's device and version come from the plan, and a reader that could name them would be
//     choosing which devices the release is validated on;
//   * any member that approves a manual portion. A reader may *import* a human result and the
//     approval record that accompanies it, as part of the observation; it has no way to assert that
//     the pair authorizes anything. ``QualifyingMatrixEvidence`` decides that, and its initialiser
//     is internal to this module; and
//   * any member touching the environment gate. A reader states where an observation was produced
//     as part of the observation itself and has no way to assert that it qualifies.

/// Why an observation for one matrix position could not be read.
///
/// Structural outcomes only: no framework error, no absolute path, no partial value. Every one of
/// them is a refusal, and none is recoverable, because recovering would mean the run deciding what
/// the device would have observed.
///
/// How each maps to a cell outcome belongs to the runner. All four map to a failure.
public enum MatrixObservationFault: Error, Equatable, Sendable, CaseIterable,
    CustomStringConvertible
{
    /// The run produced no observation for that position.
    ///
    /// The case Requirements 12.14 and 12.18 turn on, and the one every position in this
    /// repository reaches today. It is a failure of the position, not an absence of the position.
    case observationAbsent

    /// An observation exists but its value could not be read.
    case observationUnreadable

    /// The assistive technology or display condition could not be established.
    ///
    /// Distinct from ``observationAbsent`` because the two are closed by different work: an absent
    /// observation arrives when a run is executed, and an unestablishable condition needs either a
    /// human runner or a test host with the technology available. This is what a harness reports
    /// for VoiceOver and Switch Control, every time, since no supported interface turns either on
    /// from a test process.
    case conditionNotActivatable

    /// The observation store itself is unavailable, so nothing was read.
    case storeUnavailable

    public var description: String {
        switch self {
        case .observationAbsent: "no observation was recorded for this position"
        case .observationUnreadable: "the recorded observation could not be read"
        case .conditionNotActivatable:
            "the assistive technology or display condition could not be established"
        case .storeUnavailable: "the observation store is unavailable"
        }
    }
}

/// Reads what one run observed for one matrix position.
///
/// One member, asked one position at a time. That shape is the point: the run owns the required
/// position set, so a reader cannot add a position, drop a position, or reorder the run's work.
public protocol MatrixObservationReading: Sendable {
    /// What the run observed for `cell`, or why there is nothing.
    func observation(
        for cell: AccessibilityMatrixCell
    ) throws(MatrixObservationFault) -> MatrixCellObservation
}
