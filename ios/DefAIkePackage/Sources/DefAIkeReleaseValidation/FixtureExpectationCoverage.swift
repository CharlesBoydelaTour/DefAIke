import DefAIkeDomain

// Which expected results each fixture family has to declare.
//
// `FixtureExpectation` in the domain says what an expected result *can* be. It does
// not say which ones a family *must* carry, because that is a catalog-completeness
// rule for nonshipping tooling rather than something a shipping session path reads.
// It lives here for that reason.
//
// The rules below are structural, and every one of them is a requirement rather than
// a choice made here:
//
//   * a model-parity fixture is compared on raw logit and on categorical outcome
//     (Requirements 4.13, 13.7, and 13.8);
//   * an orientation, color-space, alpha, aspect-ratio, or container fixture is
//     compared on preprocessing output (Requirement 13.6);
//   * a physical-screenshot fixture is compared on both preprocessing output and raw
//     logit (Requirement 13.9);
//   * a malformed-input fixture asserts a terminal Analysis Error rather than a
//     reference comparison (Requirements 3.3 and 13.4);
//   * a route fixture is compared on retained bytes and preservation status
//     (Requirement 13.10);
//   * a provenance fixture is compared on its single exclusive state (Requirements
//     6.18 and 13.11).
//
// No rule here supplies a tolerance, a limit, or an expected value. Those are the
// approved Device Validation Plan's and the fixture's own, respectively.

/// Which kind of expected result one ``FixtureExpectation`` supplies.
///
/// A separate closed vocabulary from the expectation itself, so completeness can be
/// checked per kind without inspecting associated values, and so a fixture cannot
/// satisfy a required kind twice with two disagreeing values.
public enum FixtureExpectationKind: String, Sendable, Hashable, CaseIterable,
    CustomStringConvertible
{
    case pixelLabel = "pixel-label"
    case rawLogit = "raw-logit"
    case preprocessingOutputDigest = "preprocessing-output-digest"
    case retainedBytesDigest = "retained-bytes-digest"
    case bytePreservationStatus = "byte-preservation-status"
    case provenanceState = "provenance-state"
    case analysisError = "analysis-error"

    public var description: String { rawValue }
}

extension FixtureExpectation {
    /// The kind of expected result this expectation supplies.
    public var kind: FixtureExpectationKind {
        switch self {
        case .pixelLabel: .pixelLabel
        case .rawLogit: .rawLogit
        case .preprocessingOutputDigest: .preprocessingOutputDigest
        case .retainedBytesDigest: .retainedBytesDigest
        case .bytePreservationStatus: .bytePreservationStatus
        case .provenanceState: .provenanceState
        case .analysisError: .analysisError
        }
    }

    /// The plan comparison this expectation supplies the approved value for, or `nil`
    /// when the expectation is a terminal outcome rather than a reference comparison.
    ///
    /// Used to check that the bound Device Validation Plan actually declares a
    /// comparison, with a tolerance or a required agreement ratio, for every
    /// comparison the catalog's fixtures expect (Requirements 4.13 and 13.3). A
    /// malformed-input fixture has no reference artifact to compare against: it
    /// asserts that the session ends in one exact Analysis Error, so it maps to `nil`
    /// rather than to a comparison the plan would then have to bound numerically.
    public var referenceComparison: ComparisonMetric? {
        switch self {
        case .pixelLabel: .categoricalOutcome
        case .rawLogit: .rawLogit
        case .preprocessingOutputDigest: .preprocessingOutput
        case .retainedBytesDigest: .retainedBytes
        case .bytePreservationStatus: .bytePreservationStatus
        case .provenanceState: .provenanceState
        case .analysisError: nil
        }
    }
}

extension FixtureFamily {
    /// Expected-result kinds a fixture in this family must declare.
    ///
    /// Total over every family: adding a family to the domain enumeration without
    /// stating what it must expect is a compile error here, not a family that
    /// silently requires nothing.
    public var requiredExpectationKinds: Set<FixtureExpectationKind> {
        switch self {
        case .modelParity:
            [.rawLogit, .pixelLabel]
        case .orientation, .colorSpace, .alpha, .aspectRatio, .jpegContainer, .pngContainer,
             .heifContainer:
            [.preprocessingOutputDigest]
        case .physicalScreenshot:
            [.preprocessingOutputDigest, .rawLogit]
        case .malformedInput:
            [.analysisError]
        case .photosPickerRoute, .shareExtensionRoute:
            [.retainedBytesDigest, .bytePreservationStatus]
        case .provenanceValidSigned, .provenanceTampered, .provenanceInvalid, .provenanceAbsent,
             .provenanceUnsupported, .provenanceIndeterminate:
            [.provenanceState]
        }
    }
}

extension ProvenanceStateKey {
    /// Fixture families that demonstrate this provenance state.
    ///
    /// Six families exist for five states because Requirement 6.18 names tampered and
    /// invalid fixtures separately while Requirement 6.12 gives both the one `invalid`
    /// state: a broken byte binding and a broken signature are different inputs with
    /// the same exclusive result. Nothing here decides what a validator returns; it
    /// records which family a fixture demonstrating an approved state belongs to.
    public var demonstratingFamilies: Set<FixtureFamily> {
        switch self {
        case .validated: [.provenanceValidSigned]
        case .invalid: [.provenanceTampered, .provenanceInvalid]
        case .absent: [.provenanceAbsent]
        case .unsupported: [.provenanceUnsupported]
        case .indeterminate: [.provenanceIndeterminate]
        }
    }
}
