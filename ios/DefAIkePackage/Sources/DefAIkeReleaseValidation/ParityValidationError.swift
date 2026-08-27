import DefAIkeDomain

// Why a parity run cannot start, what it is still owed, and what agreement would not
// establish even if every artifact arrived.
//
// Three vocabularies live here and they record three different kinds of blocker. Keeping
// them apart matters, because the actions that close them are different and a release audit
// that conflates them will wait for the wrong thing:
//
//   * ``ParityBindingError`` — *this run's inputs disagree with each other*. The plan does
//     not declare a comparison the catalogue owes, the configuration is not a plan
//     candidate, the version tuple names a different fixture suite. A reconciliation
//     finding: nothing was measured and nothing should be.
//   * ``UnprovisionedParityInput`` — *a release-controlled input this repository does not
//     carry*. An approved plan, a signed fixture suite, the 96 model-parity references and
//     their assets, the approved reference outputs, a physical iPhone to run on. Closing one
//     is a release-artifact, packaging, or hardware change. It is not a change to this file.
//   * ``UnobservableParityEvidence`` — *something the implementation does not expose*, so a
//     comparison either cannot be made at all or does not establish what its name suggests.
//     Closing one is a schema or implementation change, and no amount of provisioning helps.
//
// The third vocabulary is the one that keeps this module honest. Six of its eight cases are
// findings other tasks made and this module must not paper over: the input route is absent
// from the Evidence Report, nothing records screenshot origin, byte-preservation status is
// not integrity-bound, no shipping type conforms to `ProvenanceAnalyzing`, there is no
// offline trust store, and the compiled model carries no checkpoint identifier. A run
// records them beside every affected cell whatever the cell's outcome, because they are
// properties of the implementation rather than of one measurement.
//
// No vocabulary here has a case meaning "proceed anyway", "assume", "skip", or "warn". A
// parity run either compares an approved expected value against a qualifying observation, or
// it produces one of these.

// MARK: - Reconciliation findings

/// Why a plan, a catalogue, a configuration, and a version tuple cannot be bound into one
/// parity run.
///
/// Equatable rather than Hashable because ``FixtureCatalogError`` is Equatable, and wrapping
/// it whole is better than restating its cases.
public enum ParityBindingError: Error, Equatable, Sendable, CustomStringConvertible {

    /// The catalogue does not reconcile against the plan or the release's capability set.
    case catalogNotReconcilable(FixtureCatalogError)

    /// The catalogue owes a comparison the approved plan does not declare, so the comparison
    /// would run against no approved tolerance or agreement ratio (Requirements 13.3, 4.13).
    ///
    /// Stricter than ``FixtureCatalog/reconcile(with:)``, deliberately. That check covers the
    /// comparisons the catalogued *expectations* supply values for; this one covers every
    /// comparison the *requirements* ask for, which additionally includes rank agreement
    /// (Requirement 13.7) and screenshot geometry (Requirement 13.9).
    case planComparisonMissing(ComparisonMetric)

    /// The configuration under test is not one the approved plan enumerates.
    case configurationNotInPlan(DeviceHardwareID, PlatformVersion)

    /// The version tuple names a different fixture suite than the catalogue.
    case versionTupleFixtureSuiteMismatch(expected: ArtifactID, found: ArtifactID)

    /// The version tuple names a different validation plan.
    case versionTuplePlanMismatch(expected: ArtifactID, found: ArtifactID)

    /// The version tuple names a different Model Bundle than the plan.
    case versionTupleModelBundleMismatch(expected: ModelBundleID, found: ModelBundleID)

    /// The version tuple names a different capability manifest than the plan.
    case versionTupleCapabilityManifestMismatch(expected: ArtifactID, found: ArtifactID)

    /// The configuration's application build disagrees with the version tuple's.
    case versionTupleAppBuildMismatch(expected: AppBuildID, found: AppBuildID)

    /// The catalogue does not account for all 96 existing model-parity references, so a run
    /// over it would report parity for a subset and call it the parity result.
    case modelParityCoverageIncomplete(expected: Int, found: Int)

    /// The plan's missing-result rule is not "treat as failure".
    ///
    /// The plan schema already refuses this, so it is unreachable through a decoded plan.
    /// It is checked again here because a runner that trusted the rule to be right without
    /// reading it would be relying on another type's invariant for the one behaviour this
    /// task turns on (Requirement 13.19).
    case missingResultRuleNotFailure(MissingResultRule)

    /// The bound catalogue and plan produce no required comparison at all.
    ///
    /// A run with nothing to compare is not a passing run. It has no evidence.
    case requiredCellSetEmpty

    /// The derived required set does not cover every comparison the domain declares
    /// Requirements 13.6 through 13.11 need for this capability set.
    ///
    /// Checked against ``ComparisonMetric/requiredComparisons(provenanceEnabled:)`` rather
    /// than against a list restated here, so the runner and the plan validator cannot drift
    /// about which comparisons a release owes. A catalogue that produces fewer would run a
    /// subset and present it as the parity result.
    case requiredComparisonsIncomplete([ComparisonMetric])

    public var description: String {
        switch self {
        case let .catalogNotReconcilable(finding):
            return "the fixture catalogue does not reconcile: \(finding.description)"
        case let .planComparisonMissing(metric):
            return "the plan declares no comparison for \(metric.rawValue)"
        case let .configurationNotInPlan(hardware, osVersion):
            return "\(hardware.rawValue)@\(osVersion.description) is not a plan candidate"
        case let .versionTupleFixtureSuiteMismatch(expected, found):
            return "the version tuple names fixture suite \(found.rawValue), not "
                + expected.rawValue
        case let .versionTuplePlanMismatch(expected, found):
            return "the version tuple names plan \(found.rawValue), not \(expected.rawValue)"
        case let .versionTupleModelBundleMismatch(expected, found):
            return "the version tuple names Model Bundle \(found.rawValue), not "
                + expected.rawValue
        case let .versionTupleCapabilityManifestMismatch(expected, found):
            return "the version tuple names capability manifest \(found.rawValue), not "
                + expected.rawValue
        case let .versionTupleAppBuildMismatch(expected, found):
            return "the configuration names application build \(found.rawValue), not "
                + expected.rawValue
        case let .modelParityCoverageIncomplete(expected, found):
            return "the catalogue accounts for \(found) model-parity fixtures, not \(expected)"
        case let .missingResultRuleNotFailure(rule):
            return "the plan's missing-result rule is \(rule.rawValue)"
        case .requiredCellSetEmpty:
            return "the bound plan and catalogue require no comparison at all"
        case let .requiredComparisonsIncomplete(missing):
            return "the catalogue owes no cell for "
                + missing.map(\.rawValue).sorted().joined(separator: ", ")
        }
    }
}

// MARK: - Release-controlled inputs this repository does not carry

/// One release-controlled input a parity run needs and this repository does not have.
///
/// A closed, enumerable vocabulary, in the established style: recording a gap as a value is
/// what lets a release audit enumerate what is still owed instead of discovering it when a
/// gate is due.
///
/// Closing a gap is a release-artifact, packaging, or hardware change. It is not a change to
/// this file, and no case here is closable by writing code.
public enum UnprovisionedParityInput: String, Hashable, Sendable, CaseIterable,
    CustomStringConvertible
{
    /// No approved Device Validation Plan exists.
    ///
    /// Requirement 13.3 requires the reference artifacts, comparison metrics, numeric
    /// tolerances, expected categorical outcomes, measurement conditions, and missing-result
    /// rules to be declared *before* validation begins. `DeviceValidationPlan` is a schema
    /// with no instance anywhere outside test samples, so there is no approved tolerance for
    /// any of the eight comparisons and no candidate configuration list.
    case deviceValidationPlan = "device-validation-plan"

    /// No signed Release Fixture Suite exists.
    ///
    /// `ReleaseFixtureSuite` is likewise a schema with no approved instance. Without it there
    /// is no catalogue to derive required cells from.
    case releaseFixtureSuite = "release-fixture-suite"

    /// The approved inventory of the 96 existing model-parity references is absent.
    ///
    /// Requirement 13.4 fixes the count at 96 and ``ModelParityFixtureInventory`` reconciles
    /// against the identities and digests rather than trusting a count. Neither the identities
    /// nor the digests exist in this repository.
    case modelParityFixtureInventory = "model-parity-fixture-inventory"

    /// The 96 model-parity fixture assets are absent.
    ///
    /// Distinct from the inventory: an approved list of references with no bytes behind it
    /// fails ``FixtureCatalogVerifier`` rather than the catalogue, and the two are owed
    /// separately.
    case modelParityFixtureAssets = "model-parity-fixture-assets"

    /// No approved preprocessing reference outputs exist (Requirement 13.6).
    case preprocessingReferenceOutputs = "preprocessing-reference-outputs"

    /// No approved Core ML raw-logit reference values exist (Requirement 13.7).
    ///
    /// Also what rank agreement is owed from: its reference ordering is derived from these,
    /// so an absent logit reference is an absent ordering.
    case rawLogitReferences = "raw-logit-references"

    /// No approved categorical Pixel Evidence outcomes exist (Requirement 13.8).
    case categoricalOutcomeReferences = "categorical-outcome-references"

    /// No approved physical-iPhone screenshot fixtures or their references exist
    /// (Requirement 13.9).
    case screenshotFixtureReferences = "screenshot-fixture-references"

    /// No approved retained-byte sequences or expected preservation statuses exist for the
    /// Photos Picker and Share Extension route fixtures (Requirement 13.10).
    case routeByteReferences = "route-byte-references"

    /// No approved provenance fixture expectations exist (Requirements 13.5 and 13.11).
    ///
    /// Owed only when Provenance Capability is enabled. A pixel-only release records the
    /// provenance gate as not applicable against an approved decision instead.
    case provenanceFixtureExpectations = "provenance-fixture-expectations"

    /// No release-controlled validation version tuple is bound.
    ///
    /// The application build identity is `0`/`0.0.0` in both shipping targets, so no
    /// `AppBuildID` a run could legitimately name exists, and Requirement 13.20 forbids
    /// assembling gate evidence across tuples.
    case boundValidationVersionTuple = "bound-validation-version-tuple"

    /// No physical iPhone is available to run on.
    ///
    /// The blocking one, and the reason every parity gate in this repository is failing
    /// rather than pending. Requirement 13.16 admits only physical-iPhone results, this
    /// repository has no device, and the only installed runtime is a simulator runtime. So
    /// every observation any run here can produce is a development-Mac or simulator
    /// observation, and ``QualifyingParityEvidence`` refuses all of them.
    ///
    /// Nothing in this module reduces the gate to what a host can do. That is the point: a
    /// host-satisfiable device gate would be a false pass, and a failing gate is the honest
    /// answer.
    case physicalIPhoneRunEnvironment = "physical-iphone-run-environment"

    public var description: String { rawValue }
}

/// The complete set of release-controlled inputs one parity run does not have.
///
/// A named type rather than a bare array, so the reason travels as one value and an audit
/// sees the whole list rather than whichever gap was checked first.
public struct UnprovisionedParityRun: Error, Hashable, Sendable {
    public let inputs: [UnprovisionedParityInput]

    public init(inputs: [UnprovisionedParityInput]) {
        self.inputs = inputs
    }
}

// MARK: - Evidence the implementation cannot produce

/// Something a parity comparison would need that the implementation does not expose.
///
/// A separate vocabulary from ``UnprovisionedParityInput`` because the two are closed by
/// different work. A missing fixture suite arrives when a release signs one; the absence of
/// a decoded-metadata comparison metric does not, because there is no artifact to sign — the
/// closed `ComparisonMetric` enumeration would have to gain a case first.
///
/// Six of the eight are findings this repository already made and recorded. They are carried
/// here so a parity report states them beside the cells they qualify, rather than reporting a
/// bare pass whose meaning is narrower than its name.
///
/// Nothing here is a defect this module fixes. Each is reported.
public enum UnobservableParityEvidence: String, Hashable, Sendable, CaseIterable,
    CustomStringConvertible
{
    /// No ``FixtureExpectationKind`` maps to ``ComparisonMetric/screenshotGeometry``.
    ///
    /// Requirement 13.9 requires screenshot geometry, orientation, colour handling, encoding,
    /// crop output, and raw logit to be compared against the approved reference. The
    /// expected-result schema can carry the crop output (as a preprocessing-output digest)
    /// and the raw logit, and it has no shape at all for the other four: every
    /// ``FixtureExpectation`` case maps to one of the other seven comparisons or to a
    /// terminal Analysis Error.
    ///
    /// The only case whose ``blocksComparison`` is true. A screenshot-geometry cell therefore
    /// exists — the requirement asks for it — and reports that its approved expected value is
    /// unrepresentable, rather than being dropped from the required set.
    case screenshotGeometryHasNoExpectationKind = "screenshot-geometry-has-no-expectation-kind"

    /// ``ComparisonMetric`` has no decoded-metadata case.
    ///
    /// The design's preprocessing comparison list is "decoded metadata, pre-orientation
    /// dimensions, converted RGB samples, 440 resize, 384 crop, and input bytes". A
    /// preprocessing-output digest covers the pixels that reach the model; it says nothing
    /// about which orientation, colour-profile, or alpha metadata state the Preprocessor
    /// observed, and two different metadata readings that happen to produce the same crop
    /// are indistinguishable to it. A schema gap, recorded rather than approximated.
    case decodedMetadataHasNoComparisonMetric = "decoded-metadata-has-no-comparison-metric"

    /// The input route is absent from the Evidence Report.
    ///
    /// Neither `EvidenceReport` nor `AnalysisSessionBinding` carries a route field, so two
    /// byte-identical inputs taken through the Photos Picker and a completed Share Extension
    /// handoff produce reports that compare equal. Requirement 13.10's comparison is
    /// therefore made on what is actually observable — the retained encoded bytes and the
    /// recorded preservation status — and route parity cannot be established from the report.
    case inputRouteAbsentFromEvidenceReport = "input-route-absent-from-evidence-report"

    /// Nothing records screenshot origin.
    ///
    /// Requirement 6.16 asks for the screenshot explanation when *a screenshot* contains no
    /// Content Credential. With no recorded origin, the approved explanation is attached to
    /// every enabled `absent` provenance result — a superset of the requirement's cases. A
    /// provenance-state comparison bounds the state, not which of those cases produced it.
    case screenshotOriginNotRecorded = "screenshot-origin-not-recorded"

    /// Byte-preservation status is not integrity-bound.
    ///
    /// Changing the recorded status and its basis together to another supported pair yields a
    /// record that decodes, resolves, and verifies, and the changed status reaches the
    /// Evidence Report. So a preservation-status comparison establishes that the recorded
    /// pair matches the approved expected status; it does not establish that the recorded
    /// pair describes what the platform actually handed over.
    case preservationStatusNotIntegrityBound = "preservation-status-not-integrity-bound"

    /// No shipping type conforms to `ProvenanceAnalyzing`.
    ///
    /// `DefAIkeProvenanceC2PA.C2PAProvenanceValidator` deliberately does not conform, so
    /// there is no shipping provenance analyzer at all; and `c2pa-swift` 0.0.12 refuses
    /// configuration with synthetic trust anchors, so every real read returns
    /// `validatorNotConfigurable`. Requirement 6.18's per-fixture state comparison is
    /// therefore unrunnable against a real validator. A run records that; it does not stand
    /// a fake result in for one.
    case noShippingProvenanceAnalyzer = "no-shipping-provenance-analyzer"

    /// No offline Content Credential trust store exists.
    ///
    /// Requirements 6.7 and 6.8 require validation entirely on device with connectivity
    /// disabled, which needs an approved offline trust store. There is none, so even a
    /// conforming analyzer would have no anchors to validate against.
    case noOfflineContentCredentialTrustStore = "no-offline-content-credential-trust-store"

    /// The compiled Core ML model carries no checkpoint identifier.
    ///
    /// Its metadata records a version string and an author string and nothing that names the
    /// Lowq checkpoint Requirement 10.2 binds the bundle to. Model identity must therefore
    /// come from the signed manifest, and a raw-logit or rank agreement establishes that
    /// *this compiled model* reproduced the reference — not that the compiled model is the
    /// approved checkpoint.
    case modelIdentityAbsentFromCompiledModel = "model-identity-absent-from-compiled-model"

    /// Whether this limit prevents the comparison from being made at all.
    ///
    /// True only for ``screenshotGeometryHasNoExpectationKind``, because that one removes the
    /// expected side of the comparison. The other seven narrow what agreement establishes
    /// without preventing the comparison, so they are recorded beside a cell whose outcome is
    /// reached normally.
    ///
    /// Written without a `default`, so a new limit forces a decision about whether it blocks.
    public var blocksComparison: Bool {
        switch self {
        case .screenshotGeometryHasNoExpectationKind:
            true
        case .decodedMetadataHasNoComparisonMetric, .inputRouteAbsentFromEvidenceReport,
             .screenshotOriginNotRecorded, .preservationStatusNotIntegrityBound,
             .noShippingProvenanceAnalyzer, .noOfflineContentCredentialTrustStore,
             .modelIdentityAbsentFromCompiledModel:
            false
        }
    }

    public var description: String { rawValue }
}
