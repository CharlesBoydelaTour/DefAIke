// Honest progress: determinate only from measured work, otherwise indeterminate.

/// A unit of measured analysis work.
///
/// Only units the application actually measures while streaming or transforming
/// exist here. There is deliberately no "stage", "step", or "percent" unit: a
/// weighted stage count is an estimate, not a measurement, and Requirement 15.2
/// admits determinate progress only from reliable completed-work and total-work
/// measurements of the same unit.
public enum ProgressUnit: String, Codable, Sendable, CaseIterable {
    /// Encoded bytes copied and hashed while streaming a retained representation.
    case encodedBytes
    /// Image rows or tiles transformed, where the operation reports them.
    case imageRows
}

/// The user-visible work-progress state of an active Analysis Session.
///
/// Determinate progress requires a defined unit, a positive total, a completed
/// value within `0...total`, and completed and total describing the same reliable
/// measured work. When any prerequisite is missing, the state is explicitly
/// indeterminate and reports that analysis is continuing rather than stalled
/// (Requirements 15.2, 15.3, and 15.4). Deriving the state from raw measurements is
/// the coordinator's responsibility; this type carries the outcome and refuses to
/// project a fraction from a total it cannot divide by.
///
/// A fraction here is analysis work progress. It is never a result probability,
/// confidence, or likelihood, and it is never derived from a logit or a label.
public enum AnalysisProgressState: Hashable, Sendable {
    case determinate(
        completed: UInt64,
        total: UInt64,
        unit: ProgressUnit,
        stage: AnalysisStage
    )
    case indeterminate(stage: AnalysisStage)

    /// The stage this progress describes.
    public var stage: AnalysisStage {
        switch self {
        case .determinate(_, _, _, let stage): return stage
        case .indeterminate(let stage): return stage
        }
    }

    /// Whether a completion fraction is available.
    public var isDeterminate: Bool {
        switch self {
        case .determinate: return true
        case .indeterminate: return false
        }
    }

    /// The measured fraction of analysis work completed, in `0...1`.
    ///
    /// `nil` for indeterminate progress, and `nil` for a determinate value whose
    /// total is zero or whose completed value is out of range: an unusable
    /// measurement yields no fraction rather than a fabricated one.
    public var fractionOfWorkCompleted: Double? {
        guard case .determinate(let completed, let total, _, _) = self else { return nil }
        guard total > 0, completed <= total else { return nil }
        return Double(completed) / Double(total)
    }
}
