import DefAIkeDomain
import Foundation

// Step 5 of the fixed verification order, as a value.
//
// Requirement 10.9 makes the bundle responsible for identifying its self-test
// specification, its fixtures, and its expected results; Requirement 10.10 rejects a
// candidate when any one of the three is missing. So "the self-tests are complete" is
// carried by a type: a ``VerifiedSelfTestPlan`` exists only for a candidate whose
// specification decoded, whose every case resolves to a catalogued fixture that is
// actually present in the verified tree with the catalogued digest, and whose every case
// declares a coherent set of expected results.
//
// What the plan does not claim: that any case has run. Execution is a separate step with
// a separate value, because a complete specification and a passing run are different
// facts (Requirement 10.11).

/// Which kind of result one ``SelfTestExpectation`` declares.
///
/// Exists so a case can be checked for a repeated or contradictory declaration, and so a
/// finding can name which expectation was missing without spelling a value.
public enum SelfTestExpectationKind: String, Hashable, Sendable, CaseIterable,
    CustomStringConvertible
{
    case rawLogit = "raw-logit"
    case pixelLabel = "pixel-label"
    case preprocessingOutputDigest = "preprocessing-output-digest"
    case analysisError = "analysis-error"

    /// Whether this kind describes a result the candidate produced successfully.
    ///
    /// A case that expects an Analysis Error expects the run to terminate without one of
    /// these, so declaring both is contradictory.
    public var describesSuccessfulResult: Bool { self != .analysisError }

    public var description: String { rawValue }
}

extension SelfTestExpectation {
    /// The kind of result this expectation declares.
    public var kind: SelfTestExpectationKind {
        switch self {
        case .rawLogit: .rawLogit
        case .pixelLabel: .pixelLabel
        case .preprocessingOutputDigest: .preprocessingOutputDigest
        case .analysisError: .analysisError
        }
    }

    /// Whether `observation` satisfies this expectation.
    ///
    /// `false` covers both a mismatch and a missing observation, and neither is ever a
    /// pass. The caller distinguishes them so the finding can say which one happened.
    func isSatisfied(by observation: SelfTestObservation) -> Bool {
        switch self {
        case let .rawLogit(value, tolerance):
            guard let observed = observation.rawLogit else { return false }
            return Self.isWithin(tolerance, of: value, observed: observed.value)
        case let .pixelLabel(expected):
            return observation.pixelLabel == expected
        case let .preprocessingOutputDigest(expected):
            return observation.preprocessingOutputDigest == expected
        case let .analysisError(expected):
            return observation.analysisError == expected
        }
    }

    /// Whether `observed` is within `tolerance` of `expected`.
    ///
    /// The tolerance is the one the bundle's own signed expectation declares; nothing
    /// here widens it, and a zero tolerance means exact equality. A difference that is
    /// not finite fails, so an implausible pair of values cannot pass by arithmetic
    /// accident.
    private static func isWithin(
        _ tolerance: NonNegativeDecimal,
        of expected: Double,
        observed: Double
    ) -> Bool {
        let difference = abs(observed - expected)
        guard difference.isFinite else { return false }
        let bound = NSDecimalNumber(decimal: tolerance.value).doubleValue
        guard bound.isFinite else { return false }
        return difference <= bound
    }
}

/// One self-test case whose fixture is present in the candidate and whose expectations
/// are coherent.
public struct VerifiedSelfTestCase: Hashable, Sendable {
    public let id: SelfTestCaseID
    public let fixture: FixtureID

    /// Bundle-relative path of the fixture asset, resolved through the approved layout.
    public let assetPath: CanonicalRelativePath

    /// Byte count and digest the fixture catalogue declares, both confirmed against the
    /// bytes actually in the verified tree.
    public let byteCount: UInt64
    public let contentDigest: SHA256Digest

    /// The declared expected results. Never empty, at most one per kind.
    public let expectations: [SelfTestExpectation]

    init(
        id: SelfTestCaseID,
        fixture: FixtureID,
        assetPath: CanonicalRelativePath,
        byteCount: UInt64,
        contentDigest: SHA256Digest,
        expectations: [SelfTestExpectation]
    ) {
        self.id = id
        self.fixture = fixture
        self.assetPath = assetPath
        self.byteCount = byteCount
        self.contentDigest = contentDigest
        self.expectations = expectations
    }

    /// The kinds of result this case declares an expectation for.
    public var declaredKinds: Set<SelfTestExpectationKind> {
        Set(expectations.map(\.kind))
    }
}

/// The candidate's complete, resolvable release self-test specification.
///
/// Constructible only inside this module, and only by a verification run that resolved
/// every case, so an incomplete specification is not representable.
public struct VerifiedSelfTestPlan: Hashable, Sendable {
    /// The specification as decoded from the candidate's own declared artifact.
    public let specification: ReleaseSelfTestSpecification

    /// The fixture catalogue the specification names, as decoded from the candidate.
    public let fixtureCatalog: ReleaseFixtureSuite

    /// Every case, ordered by the UTF-8 bytes of its identifier.
    ///
    /// Deterministic ordering so two runs over the same candidate execute the same cases
    /// in the same sequence, and a receipt can record that sequence reproducibly.
    public let cases: [VerifiedSelfTestCase]

    init(
        specification: ReleaseSelfTestSpecification,
        fixtureCatalog: ReleaseFixtureSuite,
        cases: [VerifiedSelfTestCase]
    ) {
        self.specification = specification
        self.fixtureCatalog = fixtureCatalog
        self.cases = cases.sorted {
            $0.id.rawValue.utf8.lexicographicallyPrecedes($1.id.rawValue.utf8)
        }
    }

    /// The specification version this plan came from.
    public var specificationID: ArtifactID { specification.id }

    /// Total number of expected results the plan declares, across every case.
    public var declaredExpectationCount: Int {
        cases.reduce(0) { $0 + $1.expectations.count }
    }
}
