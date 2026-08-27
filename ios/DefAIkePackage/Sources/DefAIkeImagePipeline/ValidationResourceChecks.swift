import DefAIkeDomain
import Foundation

// Comparing a measurement against the bound Resource Budget.
//
// Every number this file uses comes from the budget passed into the port. There is no
// default, no fallback, and no clamp: a metric the bound budget does not define is a
// check that cannot be performed, and a check that cannot be performed fails closed
// with `resource-limit` rather than passing silently (Requirement 3.4 and the design's
// "it does not invent a time limit").
//
// Comparisons are exact. Measurements are whole counts of pixels or bytes and budget
// limits are `Decimal`, so both sides are compared as `Decimal`: `UInt64` has twenty
// digits and `Decimal` carries thirty-eight significant digits, which makes the
// widened comparison lossless in a way that converting the limit down to an integer
// would not be.

/// Applies the bound Resource Budget's hard limits to validation measurements.
struct ValidationResourceChecks: Sendable {
    /// Why a measurement did not pass.
    enum Breach: Hashable, Sendable {
        /// The measurement exceeded a defined hard limit.
        case exceeded(ResourceMetric)
        /// The bound budget defines no limit for a metric this check needs.
        case limitNotDefined(ResourceMetric)
        /// The bound budget's limit for the metric is not a numeric limit in the
        /// unit the measurement is expressed in.
        case limitUnitMismatch(ResourceMetric, expected: ResourceLimitUnit)
        /// The measurement could not be computed without integer overflow, so it
        /// cannot be bounded by any limit.
        case measurementOverflow(ResourceMetric)
    }

    let budget: ResourceBudget

    /// Whether the bound budget defines a limit for `metric` at all.
    ///
    /// Used only where a metric is legitimately absent for the bound target: the
    /// encoded-input-size ceiling belongs to the Share Extension budget
    /// (Requirement 11.3) and a main-application budget correctly has none, so
    /// treating its absence as a failure would reject every main-app analysis.
    func definesLimit(for metric: ResourceMetric) -> Bool {
        budget.limit(for: metric) != nil
    }

    /// Checks `measured` bytes against the budget's limit for `metric`.
    func checkBytes(_ measured: UInt64, against metric: ResourceMetric) -> Breach? {
        check(measured, against: metric, unit: .bytes)
    }

    /// Checks `measured` pixels against the budget's limit for `metric`.
    func checkPixels(_ measured: UInt64, against metric: ResourceMetric) -> Breach? {
        check(measured, against: metric, unit: .pixels)
    }

    private func check(
        _ measured: UInt64,
        against metric: ResourceMetric,
        unit expectedUnit: ResourceLimitUnit
    ) -> Breach? {
        guard let limit = budget.limit(for: metric) else {
            return .limitNotDefined(metric)
        }
        guard case .numeric(let value, let unit) = limit, unit == expectedUnit else {
            // A thermal limit, or a numeric limit measured in milliseconds, cannot
            // bound a byte or pixel count. Fail closed rather than compare magnitudes
            // across units.
            return .limitUnitMismatch(metric, expected: expectedUnit)
        }
        return Decimal(measured) > value.value ? .exceeded(metric) : nil
    }

    /// The decoded byte cost of `pixelCount` pixels at `bitsPerComponent`, or `nil`
    /// on overflow.
    ///
    /// An over-estimate on purpose: it assumes the widest decode Core Graphics can
    /// hand back for the declared component depth. Under-estimating here would let a
    /// declaration slip past the memory check and allocate before the breach was
    /// detectable, which is the ordering Requirement 3.4 exists to prevent.
    ///
    /// `nil` means the product does not fit in `UInt64`. That is not "unbounded and
    /// therefore fine": a cost that cannot be represented cannot be compared to a
    /// limit, so the caller reports ``Breach/measurementOverflow(_:)``.
    static func estimatedDecodedByteCount(
        pixelCount: UInt64,
        bitsPerComponent: Int?
    ) -> UInt64? {
        let bytesPerComponent = UInt64(((bitsPerComponent ?? 8) + 7) / 8)
        let (perPixel, perPixelOverflow) = bytesPerComponent.multipliedReportingOverflow(
            by: EncodedImageSource.maximumDecodedChannelCount
        )
        guard !perPixelOverflow else { return nil }
        let (total, totalOverflow) = pixelCount.multipliedReportingOverflow(by: perPixel)
        guard !totalOverflow else { return nil }
        return total
    }
}

extension ValidationResourceChecks.Breach {
    /// The fault a breach raises at `stage`.
    ///
    /// Always `resource-limit`. A missing limit, a mismatched unit, and an
    /// unrepresentable measurement are all "this work cannot be shown to fit the
    /// approved budget", which is the same fail-closed outcome as exceeding it; none
    /// of them is a decoding problem and none may become a downgraded warning.
    func fault(at stage: AnalysisStage) -> AnalysisFault {
        .analysis(.resourceLimit, stage: stage)
    }
}
