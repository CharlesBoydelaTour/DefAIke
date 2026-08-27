import DefAIkeDomain

// The closed set of parity comparisons a device run owes, and where each one's two sides
// come from.
//
// Requirements 13.6 through 13.11 name eight comparisons: preprocessing output, raw logit,
// rank agreement, categorical Pixel Evidence outcome, screenshot behaviour, retained bytes,
// byte-preservation status, and the conditional provenance state. `ComparisonMetric` in the
// domain is already exactly those eight, so nothing here invents a ninth or renames one.
//
// What this file adds is the layout: for a given catalogue, *which* comparisons are owed, on
// *which* subjects, from *which* approved expected value, and against *which* observed value
// kind. Every one of those four questions is answered by a total function over the closed
// vocabulary, written without a `default`, so adding a comparison metric to the domain is a
// compile error here rather than a comparison that quietly stops being required.
//
// Three rules run through the whole file, and each is structural rather than documentary:
//
//   * **A comparison's expected value is approved or it does not exist.** There is no
//     member anywhere here that computes, defaults, rounds, or infers an expected value.
//     ``ApprovedExpectationSource`` is the total statement of where each one comes from, and
//     one comparison's answer is that the expected-result schema cannot carry it at all.
//   * **An observation records where it was produced.** ``ParityObservation`` requires an
//     ``ExecutionEnvironment`` and the configuration and version tuple the run ran under, so
//     a host result is recordable and honest. Turning one into evidence that satisfies a
//     device gate needs ``QualifyingParityEvidence``, whose only initialiser is internal to
//     this module and refuses anything but a physical iPhone on a configuration the bound
//     plan enumerates.
//   * **The observed vocabulary mirrors the approved one.** ``ObservedParityValue`` has one
//     case per ``FixtureExpectationKind`` that maps to a comparison, so an observation cannot
//     be supplied in a shape the approved expectation could not have been written in, and a
//     preprocessing digest cannot be handed in where a retained-bytes digest was owed.

// MARK: - Where this process is running

/// The execution environment the running process may honestly claim.
///
/// Decided by the platform this module was compiled for, not supplied by a caller and not
/// read from a plan. That is the point: a host test process cannot be configured into
/// claiming it is a physical iPhone, so a run whose report says ``ExecutionEnvironment/
/// developmentMac`` is telling the truth about itself for structural reasons.
///
/// It is a ceiling rather than an identification. A non-simulator iOS process is running on
/// physical Apple hardware, but *which* hardware — and whether that hardware is a
/// configuration the approved Device Validation Plan enumerates — is
/// ``QualifyingParityEvidence``'s reconciliation against
/// ``DeviceValidationPlan/candidateConfigurations``, not this constant's claim.
public enum ObservedParityEnvironment: Sendable {

    /// Where this process is running.
    public static let current: ExecutionEnvironment = {
        #if targetEnvironment(simulator)
            return .iOSSimulator
        #elseif os(iOS)
            return .physicalIPhone
        #else
            return .developmentMac
        #endif
    }()

    /// Whether a measurement taken *by this process* could satisfy a physical-device gate.
    ///
    /// False on a development Mac and in a simulator. A host-run test suite reads `false`
    /// here, which is why no host-run test in this repository can produce a passing
    /// physical-iPhone gate (Requirement 13.16).
    public static var canProducePhysicalDeviceEvidence: Bool {
        current.isPhysicalDeviceEvidence
    }
}

// MARK: - Subjects and cells

/// What one parity comparison is made about.
///
/// Two shapes, because two of the eight comparisons are not per fixture. Rank agreement is
/// an ordering over a whole family — a single fixture has no rank — so its subject is the
/// family itself.
public enum ParitySubject: Hashable, Sendable, CustomStringConvertible {
    /// One catalogued fixture, carrying the family the catalogue assigned it.
    ///
    /// The family travels with the identifier so a cell is self-describing: gate membership
    /// and ordering never need a second lookup into the suite, and a cell built with the
    /// wrong family simply does not match a required one.
    case fixture(FixtureID, family: FixtureFamily)

    /// A whole fixture family, for a comparison that has no per-fixture meaning.
    case family(FixtureFamily)

    /// The family this subject belongs to.
    public var family: FixtureFamily {
        switch self {
        case let .fixture(_, family): family
        case let .family(family): family
        }
    }

    /// The fixture, or `nil` for a family-scoped subject.
    public var fixture: FixtureID? {
        switch self {
        case let .fixture(id, _): id
        case .family: nil
        }
    }

    public var description: String {
        switch self {
        case let .fixture(id, family): "\(family.rawValue)/\(id.rawValue)"
        case let .family(family): "\(family.rawValue)/*"
        }
    }
}

/// One comparison a device run owes: a subject and the metric it is compared on.
///
/// The unit of the closed required set. A run's report holds one outcome per cell and no
/// optional that could be read as "satisfied", which is what makes a missing result a
/// failure structurally rather than by convention.
public struct ParityCell: Hashable, Sendable, CustomStringConvertible {
    public let subject: ParitySubject
    public let comparison: ComparisonMetric

    public init(subject: ParitySubject, comparison: ComparisonMetric) {
        self.subject = subject
        self.comparison = comparison
    }

    /// A stable ordering key, so two runs over the same catalogue enumerate identically.
    public var orderingKey: String {
        "\(comparison.rawValue)\u{1F}\(subject.description)"
    }

    public var description: String {
        "\(subject.description) [\(comparison.rawValue)]"
    }
}

// MARK: - How a comparison is laid out

/// How one comparison's cells are laid out over a catalogued suite.
public enum ParityComparisonScope: Hashable, Sendable {
    /// One cell for every catalogued fixture that declares an approved expected value for
    /// this comparison.
    case perDeclaringFixture

    /// One cell for every catalogued fixture in these families, whether or not the fixture
    /// declares an approved expected value.
    ///
    /// Used where a requirement names the comparison directly rather than leaving it to the
    /// fixture's declarations. Requirement 13.9 requires screenshot geometry, orientation,
    /// colour handling, encoding, and crop output to be compared for every physical-iPhone
    /// screenshot fixture, so the cell exists even though no expectation kind can carry its
    /// approved value — and it then fails closed instead of vanishing.
    case perFixtureInFamilies(Set<FixtureFamily>)

    /// One cell for the whole family, when the family has at least one fixture.
    case perFamily(FixtureFamily)
}

/// Where a comparison's approved expected value comes from.
///
/// Total over ``ComparisonMetric``. The third case is not a placeholder: it is the finding
/// that the expected-result schema has no way to carry an approved value for that
/// comparison, which is a different blocker from a release artifact this repository has not
/// been given.
public enum ApprovedExpectationSource: Hashable, Sendable {
    /// One catalogued ``FixtureExpectation`` supplies the approved value directly.
    case expectationKind(FixtureExpectationKind)

    /// Derived from the approved expectations of every fixture in a family.
    ///
    /// Deriving is not inventing: the reference ordering for rank agreement is the order the
    /// approved raw logits already put the fixtures in. Reading an ordering as its own input
    /// would let a run satisfy rank agreement with an ordering that disagrees with the
    /// logits the same run recorded.
    case derivedFromFamilyExpectations(FixtureExpectationKind)

    /// The expected-result schema carries no approved value for this comparison.
    case unrepresentable(UnobservableParityEvidence)
}

/// The kind of value one observation carries.
///
/// One case per ``FixtureExpectationKind`` that maps to a comparison. The mirror is
/// deliberate: an observation cannot arrive in a shape the approved expectation could not
/// have been written in.
public enum ParityValueKind: String, Hashable, Sendable, CaseIterable, CustomStringConvertible {
    case preprocessingOutputDigest = "preprocessing-output-digest"
    case rawLogit = "raw-logit"
    case pixelLabel = "pixel-label"
    case retainedBytesDigest = "retained-bytes-digest"
    case bytePreservationStatus = "byte-preservation-status"
    case provenanceState = "provenance-state"

    public var description: String { rawValue }
}

extension ComparisonMetric {

    /// How this comparison's cells are laid out over a catalogue.
    ///
    /// Written without a `default`, so a new comparison metric forces a decision about what
    /// it is compared on rather than defaulting to nothing.
    public var parityScope: ParityComparisonScope {
        switch self {
        case .preprocessingOutput, .rawLogit, .categoricalOutcome, .retainedBytes,
             .bytePreservationStatus, .provenanceState:
            .perDeclaringFixture
        case .rankAgreement:
            .perFamily(.modelParity)
        case .screenshotGeometry:
            .perFixtureInFamilies([.physicalScreenshot])
        }
    }

    /// Where this comparison's approved expected value comes from.
    public var approvedExpectationSource: ApprovedExpectationSource {
        switch self {
        case .preprocessingOutput: .expectationKind(.preprocessingOutputDigest)
        case .rawLogit: .expectationKind(.rawLogit)
        case .categoricalOutcome: .expectationKind(.pixelLabel)
        case .retainedBytes: .expectationKind(.retainedBytesDigest)
        case .bytePreservationStatus: .expectationKind(.bytePreservationStatus)
        case .provenanceState: .expectationKind(.provenanceState)
        case .rankAgreement: .derivedFromFamilyExpectations(.rawLogit)
        case .screenshotGeometry: .unrepresentable(.screenshotGeometryHasNoExpectationKind)
        }
    }

    /// The observed value kind a run supplies for this comparison, or `nil` when the
    /// comparison is not read through the observation seam at all.
    ///
    /// `nil` for rank agreement, whose observed ordering is derived from the raw-logit
    /// observations of the same run, and for screenshot geometry, which has no approved
    /// expected value to compare an observation against.
    public var requiredObservationKind: ParityValueKind? {
        switch self {
        case .preprocessingOutput: .preprocessingOutputDigest
        case .rawLogit: .rawLogit
        case .categoricalOutcome: .pixelLabel
        case .retainedBytes: .retainedBytesDigest
        case .bytePreservationStatus: .bytePreservationStatus
        case .provenanceState: .provenanceState
        case .rankAgreement, .screenshotGeometry: nil
        }
    }

    /// The mandatory device gate this comparison belongs to.
    ///
    /// Eight comparisons map onto the seven parity gates Requirements 13.6 through 13.11
    /// define; retained bytes and byte-preservation status share
    /// ``DeviceGate/routeByteParity`` because Requirement 13.10 states them as one
    /// comparison over both route families.
    public var parityGate: DeviceGate {
        switch self {
        case .preprocessingOutput: .preprocessingParity
        case .rawLogit: .rawLogitParity
        case .rankAgreement: .rankAgreement
        case .categoricalOutcome: .categoricalAgreement
        case .screenshotGeometry: .screenshotFidelity
        case .retainedBytes, .bytePreservationStatus: .routeByteParity
        case .provenanceState: .provenanceFixtures
        }
    }

    /// The release-controlled input a missing observation for this comparison is owed from.
    ///
    /// Total, so a gap is always attributable to something a release has to supply rather
    /// than to "no result".
    public var owedReleaseInput: UnprovisionedParityInput {
        switch self {
        case .preprocessingOutput: .preprocessingReferenceOutputs
        case .rawLogit, .rankAgreement: .rawLogitReferences
        case .categoricalOutcome: .categoricalOutcomeReferences
        case .screenshotGeometry: .screenshotFixtureReferences
        case .retainedBytes, .bytePreservationStatus: .routeByteReferences
        case .provenanceState: .provenanceFixtureExpectations
        }
    }

    /// Standing limits that qualify what agreement on this comparison establishes.
    ///
    /// Recorded whatever the outcome, because they are properties of the implementation
    /// rather than of one run: they do not become true when a cell fails and false when it
    /// passes. A limit whose ``UnobservableParityEvidence/blocksComparison`` is true
    /// additionally prevents the comparison from being made at all.
    public var standingObservationLimits: Set<UnobservableParityEvidence> {
        switch self {
        case .preprocessingOutput:
            [.decodedMetadataHasNoComparisonMetric]
        case .rawLogit, .rankAgreement:
            [.modelIdentityAbsentFromCompiledModel]
        case .categoricalOutcome:
            []
        case .screenshotGeometry:
            [.screenshotGeometryHasNoExpectationKind]
        case .retainedBytes:
            [.inputRouteAbsentFromEvidenceReport]
        case .bytePreservationStatus:
            [.inputRouteAbsentFromEvidenceReport, .preservationStatusNotIntegrityBound]
        case .provenanceState:
            [
                .noShippingProvenanceAnalyzer,
                .noOfflineContentCredentialTrustStore,
                .screenshotOriginNotRecorded,
            ]
        }
    }
}

extension DeviceGate {
    /// The parity gates Requirements 13.6 through 13.11 define, in declaration order.
    ///
    /// Derived from ``ComparisonMetric`` rather than restated, so the two cannot drift.
    public static var parityGates: [DeviceGate] {
        var seen: [DeviceGate] = []
        for metric in ComparisonMetric.allCases where !seen.contains(metric.parityGate) {
            seen.append(metric.parityGate)
        }
        return seen
    }
}

// MARK: - Observations

/// One observed parity value.
///
/// Carries no expected value, no tolerance, and no outcome. A run supplies what it saw; what
/// that means is the comparison's answer, and the comparison reads its expected value from
/// the approved catalogue.
public enum ObservedParityValue: Hashable, Sendable {
    /// Digest of the bytes the Preprocessor produced for the model input.
    case preprocessingOutputDigest(SHA256Digest)

    /// The raw positive-going logit Core ML emitted.
    ///
    /// A `Double` because Requirement 4.9's output is one, including the non-finite values
    /// Requirement 4.16 refuses. A non-finite observation is recorded and then compared to
    /// nothing: it is a disagreement, never a value within a tolerance.
    case rawLogit(Double)

    /// The calibrated Pixel Evidence label the session presented.
    case pixelLabel(PixelLabelKey)

    /// Digest of the encoded bytes the ingest route retained.
    case retainedBytesDigest(SHA256Digest)

    /// The preservation status the ingest route recorded.
    case bytePreservationStatus(BytePreservationStatusKey)

    /// The single exclusive provenance state an enabled validator reported.
    case provenanceState(ProvenanceStateKey)

    /// The kind of value this observation carries.
    public var kind: ParityValueKind {
        switch self {
        case .preprocessingOutputDigest: .preprocessingOutputDigest
        case .rawLogit: .rawLogit
        case .pixelLabel: .pixelLabel
        case .retainedBytesDigest: .retainedBytesDigest
        case .bytePreservationStatus: .bytePreservationStatus
        case .provenanceState: .provenanceState
        }
    }
}

/// One observation, and the exact conditions it was produced under.
///
/// Public and permissive on purpose. A development-Mac or simulator observation is a real
/// thing a run produces and recording it honestly is better than refusing to represent it —
/// Requirement 13.16 asks for M3 Pro timing to be *classified* as development evidence, not
/// discarded. What no caller can do is turn one into a satisfied gate: that needs
/// ``QualifyingParityEvidence``, and its initialiser is internal to this module.
public struct ParityObservation: Hashable, Sendable {
    /// The cell this observation answers.
    public let cell: ParityCell

    /// What was observed.
    public let value: ObservedParityValue

    /// Where the observation was produced.
    public let environment: ExecutionEnvironment

    /// The configuration it was produced on.
    public let configuration: CandidateDeviceConfiguration

    /// The exact version tuple the run used (Requirements 13.17 and 13.20).
    public let versionTuple: ValidationVersionTuple

    public init(
        cell: ParityCell,
        value: ObservedParityValue,
        environment: ExecutionEnvironment,
        configuration: CandidateDeviceConfiguration,
        versionTuple: ValidationVersionTuple
    ) {
        self.cell = cell
        self.value = value
        self.environment = environment
        self.configuration = configuration
        self.versionTuple = versionTuple
    }
}

/// Proof that the observations behind one comparison may back a physical-device gate.
///
/// The whole of Requirement 13.16 in one type. There is exactly one way to obtain a value:
/// ``init(observations:plan:configuration:versionTuple:)``, which is internal to this
/// module and returns `nil` unless every contributing observation was produced
///
///   1. in ``ExecutionEnvironment/physicalIPhone``,
///   2. on the configuration the run is bound to,
///   3. on a configuration the approved plan enumerates as a candidate, and
///   4. under the exact version tuple the run is bound to (Requirement 13.20).
///
/// ``ParityAgreement`` can only be built from one of these, and ``ParityCellOutcome/agreed``
/// can only be built from a ``ParityAgreement``. So a satisfied parity cell is not "a cell
/// that passed and happened to be on a phone": it is a value the type system will not let a
/// host or simulator observation produce. A caller outside this module has no initialiser at
/// all, which is why no test in this repository can manufacture one.
public struct QualifyingParityEvidence: Hashable, Sendable {
    /// The configuration every contributing observation was produced on.
    public let configuration: CandidateDeviceConfiguration

    /// The version tuple every contributing observation ran under.
    public let versionTuple: ValidationVersionTuple

    /// Always ``ExecutionEnvironment/physicalIPhone``. Retained so a recorded agreement
    /// states its environment rather than leaving it implied.
    public var environment: ExecutionEnvironment { .physicalIPhone }

    /// The number of observations this proof covers. Never zero.
    public let observationCount: Int

    init?(
        observations: [ParityObservation],
        plan: DeviceValidationPlan,
        configuration: CandidateDeviceConfiguration,
        versionTuple: ValidationVersionTuple
    ) {
        guard !observations.isEmpty else { return nil }
        guard plan.candidateConfigurations.contains(configuration) else { return nil }
        for observation in observations {
            guard observation.environment.isPhysicalDeviceEvidence,
                observation.configuration == configuration,
                observation.versionTuple == versionTuple
            else {
                return nil
            }
        }
        self.configuration = configuration
        self.versionTuple = versionTuple
        self.observationCount = observations.count
    }
}

/// Why an observation exists but cannot satisfy a physical-device gate.
///
/// Every case is a refusal. None of them is a warning attached to a pass: a cell in any of
/// these states is failing, and Requirement 13.16 is the reason.
public enum NonQualifyingParityEvidence: Hashable, Sendable, CustomStringConvertible {
    /// Produced somewhere that cannot supply release evidence at all.
    ///
    /// The case a host test run reaches. `ObservedParityEnvironment.current` is
    /// ``ExecutionEnvironment/developmentMac`` under `swift test` on a Mac and
    /// ``ExecutionEnvironment/iOSSimulator`` in a simulator, so this is not a hypothetical
    /// branch: it is what every parity gate in this repository reports today.
    case notPhysicalIPhone(ExecutionEnvironment)

    /// Produced on a configuration the approved plan does not enumerate as a candidate.
    case configurationNotInPlan(DeviceHardwareID, PlatformVersion)

    /// Produced on a different configuration than the run is bound to.
    case configurationMismatch(expected: DeviceHardwareID, observed: DeviceHardwareID)

    /// Produced under a different version tuple than the run is bound to.
    ///
    /// Requirement 13.20 excludes a configuration whose gate evidence mixes builds,
    /// bundles, fixture suites, plans, capability sets, or implementation versions.
    case versionTupleMismatch

    public var description: String {
        switch self {
        case let .notPhysicalIPhone(environment):
            return "produced in \(environment.rawValue), which cannot satisfy a device gate"
        case let .configurationNotInPlan(hardware, osVersion):
            return "\(hardware.rawValue)@\(osVersion.description) is not a plan candidate"
        case let .configurationMismatch(expected, observed):
            return "produced on \(observed.rawValue); the run is bound to \(expected.rawValue)"
        case .versionTupleMismatch:
            return "produced under a different version tuple than the run is bound to"
        }
    }
}
