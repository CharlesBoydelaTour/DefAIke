import DefAIkeDomain

// The one thing a parity run reaches out for: what a device actually observed for one cell.
//
// Everything else a run needs is already an approved value it was handed. Expected results
// come from the signed fixture catalogue, tolerances and required agreement ratios from the
// approved Device Validation Plan, candidate configurations from the same plan, and the
// version tuple from the binding. None of them arrives through this seam, and that asymmetry
// is the design: the observed side is the only side a run measures, so it is the only side
// that can be wrong in a way the module has to detect.
//
// **There is no default implementation anywhere in this module.** A runner that has not been
// given a reader cannot be constructed. A reader with no result for a cell reports that fact,
// and the run turns it into a failure — never a skip, never an omission from the report.
//
// Deliberately absent from the seam:
//
//   * any member that writes, records, publishes, or caches an observation;
//   * any member that returns an expected value, a tolerance, an agreement ratio, or an
//     outcome, so a reader cannot supply the answer alongside the measurement;
//   * any member that returns a set, a list, or a page of observations. A run enumerates the
//     required cells and asks for each one by name, so the reader cannot decide which cells
//     the run covers and a partially populated store cannot pass by offering fewer cells to
//     check;
//   * any member that reports how many observations exist, so a run cannot short-circuit on
//     "the store looks empty" and report nothing instead of reporting every cell as missing;
//   * any member that returns an ordering, a rank, or a summary. Rank agreement is derived
//     from the raw-logit observations of the same run, because an ordering supplied as its
//     own input could disagree with the logits the run recorded and still pass; and
//   * any member touching the environment gate. A reader states where an observation was
//     produced as part of the observation itself and has no way to assert that it qualifies.

/// Why an observation for one cell could not be read.
///
/// Structural outcomes only: no framework error, no absolute path, no partial value. Every
/// one of them is a refusal, and none is recoverable, because recovering would mean the run
/// deciding what the device would have observed.
///
/// How each maps to a cell outcome belongs to the runner. All three map to a failure.
public enum ParityObservationFault: Error, Equatable, Sendable, CaseIterable,
    CustomStringConvertible
{
    /// The run produced no observation for that cell.
    ///
    /// The case Requirement 13.19 turns on, and the one every cell in this repository reaches
    /// today. It is a failure of the cell, not an absence of the cell.
    case observationAbsent

    /// An observation exists but its value could not be read.
    case observationUnreadable

    /// The observation store itself is unavailable, so nothing was read.
    case storeUnavailable

    public var description: String {
        switch self {
        case .observationAbsent: "no observation was recorded for this comparison"
        case .observationUnreadable: "the recorded observation could not be read"
        case .storeUnavailable: "the observation store is unavailable"
        }
    }
}

/// Reads what one device run observed for one parity cell.
///
/// One member, asked one cell at a time. That shape is the point: the run owns the required
/// cell set, so a reader cannot add a cell, drop a cell, or reorder the run's work.
public protocol ParityObservationReading: Sendable {
    /// What the run observed for `cell`, or why there is nothing.
    func observation(
        for cell: ParityCell
    ) throws(ParityObservationFault) -> ParityObservation
}
