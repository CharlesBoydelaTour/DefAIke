import DefAIkeDomain

// The one thing a resource run reaches out for: what a device actually measured for one
// sample of one measurement.
//
// Everything else a run needs is already an approved value it was handed. Sample counts,
// summary statistics, workloads, cold or warm state, concurrency, starting thermal and power
// conditions, and pass limits come from the approved Device Validation Plan; hard limits come
// from the two signed Resource Budgets; candidate configurations come from the same plan; and
// the version tuple comes from the binding. None of them arrives through this seam, and that
// asymmetry is the design: the measured side is the only side a run measures, so it is the
// only side that can be wrong in a way the module has to detect.
//
// **There is no default implementation anywhere in this module.** A runner that has not been
// given a reader cannot be constructed. A reader with no sample at a position reports that
// fact, and the run turns it into a failure — never a skip, never a shorter series, never an
// omission from the report.
//
// Deliberately absent from the seam:
//
//   * any member that writes, records, publishes, or caches a sample;
//   * any member that returns a limit, a sample count, a summary statistic, a summary value,
//     or an outcome, so a reader cannot supply the answer alongside the measurement;
//   * any member that returns a set, a list, or a page of samples. The run enumerates
//     `0..<sampleCount` from the approved specification and asks for each position by name, so
//     the reader cannot decide how many samples the run took and a partially populated store
//     cannot pass by offering a shorter series. ``ResourceSampleIndex`` is not constructible
//     outside this module, which is what makes that structural rather than conventional;
//   * any member that reports how many samples exist, so a run cannot short-circuit on "the
//     store looks empty" and report nothing instead of reporting every position as missing;
//   * any member taking or returning a `Duration`, a deadline, a timeout, or an elapsed time.
//     Requirements 15.8 and 15.9 make the plan the authoritative source of numeric
//     analysis-time limits, and Property 36 forbids synthesizing one; a seam that could hand a
//     harness a duration would be an injection point for exactly that. The two latency metrics
//     and the energy metric are *measured values* the plan compares against its own approved
//     limits, and they arrive here as ``ObservedResourceValue/quantity(_:unit:)`` like every
//     other magnitude; and
//   * any member touching the environment or target gate. A reader states where and in which
//     process a sample was taken as part of the sample itself and has no way to assert that it
//     qualifies.

/// Why a sample at one position could not be read.
///
/// Structural outcomes only: no framework error, no absolute path, no partial value. Every one
/// of them is a refusal, and none is recoverable, because recovering would mean the run
/// deciding what the device would have measured.
///
/// How each maps to a cell outcome belongs to the runner. All four map to a failure.
public enum ResourceSampleFault: Error, Equatable, Sendable, CaseIterable,
    CustomStringConvertible
{
    /// The run took no sample at that position.
    ///
    /// The case Requirement 13.19 turns on, and the one every position in this repository
    /// reaches today. It is a failure of the measurement, not a shorter series.
    case sampleAbsent

    /// A sample exists at that position but its value could not be read.
    case sampleUnreadable

    /// The metric cannot be measured in the environment the run executed in.
    ///
    /// Distinct from ``sampleAbsent`` because the two are closed by different work: an absent
    /// sample arrives when a run is executed, and an unmeasurable metric needs a measurement
    /// path first. This is what a reader backed by `PlatformResourceGovernor` reports for
    /// temporary storage, all three latencies, and energy impact, every time — the governor
    /// answers `ResourceObservation.notMeasurable` for each of them and never
    /// `withinHardLimit`.
    case metricNotMeasurableInEnvironment

    /// The sample store itself is unavailable, so nothing was read.
    case storeUnavailable

    public var description: String {
        switch self {
        case .sampleAbsent: "no sample was taken at this position"
        case .sampleUnreadable: "the recorded sample could not be read"
        case .metricNotMeasurableInEnvironment:
            "this metric cannot be measured in the environment the run executed in"
        case .storeUnavailable: "the sample store is unavailable"
        }
    }
}

/// Reads what one device run measured for one sample of one measurement.
///
/// One member, asked one position at a time. That shape is the point: the run owns the
/// required cell set and the plan owns the sample count, so a reader cannot add a measurement,
/// drop a measurement, shorten a series, or reorder the run's work.
public protocol ResourceSampleReading: Sendable {
    /// What the run measured for `cell` at `index`, or why there is nothing.
    func sample(
        for cell: ResourceCell,
        at index: ResourceSampleIndex
    ) throws(ResourceSampleFault) -> ResourceSample
}
