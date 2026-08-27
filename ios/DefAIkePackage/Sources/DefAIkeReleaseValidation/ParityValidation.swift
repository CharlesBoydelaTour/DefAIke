import DefAIkeDomain
import Foundation

// Running the eight parity comparisons Requirements 13.6 through 13.11 name, against the
// bound Device Validation Plan and fixture catalogue.
//
// The runner does one thing: for every comparison the bound plan and catalogue *owe*, it puts
// the approved expected value beside what the run observed and records one outcome. It has no
// other job, and in particular:
//
//   | Decision | Where it comes from |
//   |---|---|
//   | the expected value | the signed fixture catalogue's ``FixtureExpectation`` |
//   | the numeric tolerance | ``DeviceValidationPlan/comparisons`` |
//   | the required agreement ratio | ``DeviceValidationPlan/comparisons`` |
//   | which configurations are candidates | ``DeviceValidationPlan/candidateConfigurations`` |
//   | what a missing result means | ``MissingResultRule``, and only `treat-as-failure` binds |
//   | whether the result may approve a configuration | nowhere in this module |
//
// There is no `outcome:` parameter anywhere in this file's public surface. A caller cannot
// hand in a ``GateOutcome`` or a ``ParityCellOutcome``; every one is computed from an approved
// expected value and an observation that came back.
//
// ## Two rules this file exists to make structural
//
// **A missing result is a failure.** ``ParityRunReport`` holds a total mapping over a closed
// required-cell set. Every required cell has exactly one ``ParityCellOutcome``, only
// ``ParityCellOutcome/agreed`` satisfies a cell, and ``ParityCellOutcome/outcome`` can return
// ``GateOutcome/passed`` or ``GateOutcome/failed`` and never ``GateOutcome/notExecuted``.
// ``ParityRunReport/outcome(of:)`` is non-optional and total over every `ParityCell`,
// including ones outside the required set, and its answer for anything it has no result for is
// a failure. So there is no `nil` for a caller to read as satisfied, no cell that can be
// absent from the report, and no way to raise the agreement ratio by comparing fewer
// fixtures: ``ParityRunReport/comparisonRecord(for:)`` sets `comparedFixtureCount` to the
// *required* cell count, so a missing cell lowers the measured agreement instead of
// disappearing from the denominator (Requirement 13.19).
//
// **A physical-iPhone gate is not satisfiable by host or simulator evidence.** Two
// independent barriers, and both have to be crossed:
//
//   1. ``ParityCellOutcome/agreed`` carries a ``ParityAgreement``, which can only be built
//      from a ``QualifyingParityEvidence``, whose only initialiser is internal to this module
//      and refuses any observation not produced on a physical iPhone, on the bound
//      configuration, on a configuration the approved plan enumerates, under the bound
//      version tuple (Requirements 13.16 and 13.20).
//   2. ``ParityRunReport/gateResult(for:)`` additionally consults
//      ``ObservedParityEnvironment/current``, which is decided by the platform this module was
//      compiled for and cannot be supplied, overridden, or configured. A run in a host test
//      process or a simulator therefore fails every applicable parity gate no matter what its
//      observations claim.
//
// Barrier 1 bounds what an observation can become; barrier 2 bounds what a *process* can
// conclude. Today this repository has no physical iPhone and only a simulator runtime, so
// barrier 2 is failing for every gate and the report says so by name. That is the correct
// result and not a limitation of the runner: a host-satisfiable device gate would be a false
// pass.

// MARK: - Comparison results

/// One comparison that was made, on evidence that may back a physical-device gate.
///
/// The only satisfying outcome, and the only type in this module that means "this comparison
/// agreed". It cannot be constructed outside the module and cannot be constructed inside it
/// without a ``QualifyingParityEvidence``.
public struct ParityAgreement: Hashable, Sendable {
    public let comparison: ComparisonMetric

    /// Proof that every observation behind this agreement may back a device gate.
    public let evidence: QualifyingParityEvidence

    /// The observed numeric deviation, for a numeric comparison; `nil` for a categorical one.
    ///
    /// Retained rather than replaced by "within tolerance", so a release record carries the
    /// measured value beside the pass and a later tolerance change is auditable against it.
    public let deviation: NonNegativeDecimal?

    init(
        comparison: ComparisonMetric,
        evidence: QualifyingParityEvidence,
        deviation: NonNegativeDecimal?
    ) {
        self.comparison = comparison
        self.evidence = evidence
        self.deviation = deviation
    }
}

/// Why one comparison did not agree.
public enum ParityDisagreementDetail: Hashable, Sendable, CustomStringConvertible {
    /// The observed digest is not the approved digest.
    case digestMismatch

    /// A categorical observation is not the approved value.
    case categoricalMismatch(expected: String, observed: String)

    /// The observed numeric deviation exceeds the approved tolerance.
    case deviationExceedsTolerance(deviation: NonNegativeDecimal, tolerance: NumericTolerance)

    /// The observed deviation exceeds the fixture's own approved tolerance.
    ///
    /// Both the plan's tolerance and the fixture's declared tolerance are approved values and
    /// neither is this module's to relax, so a comparison has to satisfy both. This case
    /// names the fixture's when the plan's was met and the fixture's was not.
    case deviationExceedsFixtureTolerance(
        deviation: NonNegativeDecimal,
        tolerance: NonNegativeDecimal
    )

    /// The observed raw logit is missing or non-finite (Requirement 4.16).
    ///
    /// Not a tolerance question. A non-finite logit is never within any tolerance, and the
    /// session that produced it should have returned `invalid-output-error` instead of a
    /// value to compare.
    case nonFiniteObservedLogit

    /// The deviation is finite but outside the range a decimal comparison can represent.
    ///
    /// Recorded rather than clamped: clamping would decide the comparison, and a deviation
    /// this large is a disagreement under every tolerance the plan can declare.
    case deviationNotRepresentable(expected: Double, observed: Double)

    /// The observed ordering disagrees with the reference ordering on this many pairs.
    case orderingDiscordance(discordantPairCount: Int, tolerance: NumericTolerance)

    public var description: String {
        switch self {
        case .digestMismatch:
            return "the observed digest is not the approved digest"
        case let .categoricalMismatch(expected, observed):
            return "observed \(observed); the approved value is \(expected)"
        case let .deviationExceedsTolerance(deviation, tolerance):
            return "deviation \(deviation.value) exceeds the plan's "
                + "\(tolerance.kind.rawValue) tolerance \(tolerance.value.value)"
        case let .deviationExceedsFixtureTolerance(deviation, tolerance):
            return "deviation \(deviation.value) exceeds the fixture's tolerance "
                + "\(tolerance.value)"
        case .nonFiniteObservedLogit:
            return "the observed raw logit is not finite"
        case let .deviationNotRepresentable(expected, observed):
            return "the deviation between \(expected) and \(observed) is not representable"
        case let .orderingDiscordance(count, tolerance):
            return "\(count) discordant ordering pairs exceed the plan's "
                + "\(tolerance.kind.rawValue) tolerance \(tolerance.value.value)"
        }
    }
}

/// One comparison that was made and did not agree.
public struct ParityDisagreement: Hashable, Sendable {
    public let comparison: ComparisonMetric
    public let detail: ParityDisagreementDetail

    /// The observed numeric deviation, when the comparison produced one.
    public let deviation: NonNegativeDecimal?

    init(
        comparison: ComparisonMetric,
        detail: ParityDisagreementDetail,
        deviation: NonNegativeDecimal? = nil
    ) {
        self.comparison = comparison
        self.detail = detail
        self.deviation = deviation
    }
}

/// A required comparison with no result, and what is owed for it.
///
/// Carries three things because a release audit needs all three: why nothing came back, which
/// release-controlled input would supply it, and which standing implementation limits apply
/// to that comparison whether or not the input ever arrives.
public struct ParityResultGap: Hashable, Sendable {
    public let fault: ParityObservationFault
    public let owed: UnprovisionedParityInput
    public let standingLimits: Set<UnobservableParityEvidence>

    init(
        fault: ParityObservationFault,
        owed: UnprovisionedParityInput,
        standingLimits: Set<UnobservableParityEvidence>
    ) {
        self.fault = fault
        self.owed = owed
        self.standingLimits = standingLimits
    }
}

/// The outcome of one required parity comparison.
///
/// Seven cases, exactly one of which satisfies the cell. There is no case meaning "skipped",
/// "pending", "not applicable", or "assumed", and no case that a missing result maps to other
/// than a failure.
public enum ParityCellOutcome: Hashable, Sendable, CustomStringConvertible {
    /// Compared against the approved expected value on qualifying evidence, and agreed.
    case agreed(ParityAgreement)

    /// Compared and did not agree.
    case disagreed(ParityDisagreement)

    /// No observation came back for a required comparison (Requirement 13.19).
    case resultMissing(ParityResultGap)

    /// An observation came back but cannot satisfy a physical-device gate (Requirement 13.16).
    case nonQualifyingEvidence(NonQualifyingParityEvidence)

    /// The expected-result schema cannot carry an approved value for this comparison.
    case approvedExpectationUnrepresentable(UnobservableParityEvidence)

    /// The catalogued fixture declares no approved expected value of the required kind.
    case approvedExpectationAbsent(kind: FixtureExpectationKind)

    /// The observation is a different kind of value than the comparison needs.
    case observationKindMismatch(observed: ParityValueKind, required: ParityValueKind)

    /// Whether this cell is satisfied. True for ``agreed`` alone.
    public var isSatisfied: Bool {
        if case .agreed = self { true } else { false }
    }

    /// Whether a comparison was actually performed, agreeing or not.
    ///
    /// Distinct from ``isSatisfied``: a gate tolerates a disagreeing cell only as far as its
    /// approved agreement ratio allows, and tolerates a cell that was never compared not at
    /// all.
    public var wasCompared: Bool {
        switch self {
        case .agreed, .disagreed: true
        case .resultMissing, .nonQualifyingEvidence, .approvedExpectationUnrepresentable,
             .approvedExpectationAbsent, .observationKindMismatch:
            false
        }
    }

    /// The recorded gate outcome for this cell.
    ///
    /// ``GateOutcome/notExecuted`` is deliberately unreachable. Every required cell is asked
    /// for, so a cell with no observation is a failing cell rather than one that quietly did
    /// not participate — the same rule ``FixtureAssetVerification/outcome`` applies to a
    /// missing fixture asset.
    public var outcome: GateOutcome { isSatisfied ? .passed : .failed }

    /// The numeric deviation this cell measured, when it measured one.
    public var deviation: NonNegativeDecimal? {
        switch self {
        case let .agreed(agreement): agreement.deviation
        case let .disagreed(disagreement): disagreement.deviation
        default: nil
        }
    }

    public var description: String {
        switch self {
        case let .agreed(agreement):
            return "agreed on \(agreement.evidence.configuration.hardwareIdentifier.rawValue)"
        case let .disagreed(disagreement):
            return "disagreed: \(disagreement.detail.description)"
        case let .resultMissing(gap):
            return "\(gap.fault.description); owed: \(gap.owed.rawValue)"
        case let .nonQualifyingEvidence(reason):
            return "non-qualifying evidence: \(reason.description)"
        case let .approvedExpectationUnrepresentable(limit):
            return "no approved expected value is representable: \(limit.rawValue)"
        case let .approvedExpectationAbsent(kind):
            return "the fixture declares no approved \(kind.rawValue)"
        case let .observationKindMismatch(observed, required):
            return "observed a \(observed.rawValue) where a \(required.rawValue) was required"
        }
    }
}

// MARK: - The binding

/// One plan, one catalogue, one configuration, and one version tuple, reconciled.
///
/// Construction is the reconciliation gate. A value of this type means the plan declares an
/// approved comparison for every comparison the catalogue owes, the configuration is a plan
/// candidate, the catalogue accounts for all 96 existing model-parity references, the version
/// tuple names this exact plan, suite, bundle, manifest, and build, and the plan's
/// missing-result rule is `treat-as-failure`.
///
/// It does not mean anything was measured. That is ``ParityRunner``'s job, and it needs
/// observations.
public struct ParityRunBinding: Hashable, Sendable {
    public let plan: DeviceValidationPlan
    public let catalog: FixtureCatalog
    public let configuration: CandidateDeviceConfiguration
    public let versionTuple: ValidationVersionTuple

    /// The closed set of comparisons this binding owes, in a stable order.
    ///
    /// Derived once at construction so a run cannot enumerate a different set than the one
    /// the binding was validated against.
    public let requiredCells: [ParityCell]

    public init(
        plan: DeviceValidationPlan,
        catalog: FixtureCatalog,
        configuration: CandidateDeviceConfiguration,
        versionTuple: ValidationVersionTuple
    ) throws(ParityBindingError) {
        do {
            try catalog.reconcile(with: plan)
            try catalog.reconcile(withCapabilities: versionTuple.capabilities)
        } catch {
            throw ParityBindingError.catalogNotReconcilable(error)
        }
        guard plan.missingResultRule == .treatAsFailure else {
            throw ParityBindingError.missingResultRuleNotFailure(plan.missingResultRule)
        }
        guard plan.candidateConfigurations.contains(configuration) else {
            throw ParityBindingError.configurationNotInPlan(
                configuration.hardwareIdentifier,
                configuration.osVersion
            )
        }
        guard versionTuple.fixtureSuite == catalog.suite.id else {
            throw ParityBindingError.versionTupleFixtureSuiteMismatch(
                expected: catalog.suite.id,
                found: versionTuple.fixtureSuite
            )
        }
        guard versionTuple.validationPlan == plan.id else {
            throw ParityBindingError.versionTuplePlanMismatch(
                expected: plan.id,
                found: versionTuple.validationPlan
            )
        }
        guard versionTuple.modelBundle == plan.modelBundle else {
            throw ParityBindingError.versionTupleModelBundleMismatch(
                expected: plan.modelBundle,
                found: versionTuple.modelBundle
            )
        }
        guard versionTuple.capabilityManifest == plan.capabilityManifest else {
            throw ParityBindingError.versionTupleCapabilityManifestMismatch(
                expected: plan.capabilityManifest,
                found: versionTuple.capabilityManifest
            )
        }
        guard configuration.appBuild == versionTuple.appBuild else {
            throw ParityBindingError.versionTupleAppBuildMismatch(
                expected: versionTuple.appBuild,
                found: configuration.appBuild
            )
        }
        guard catalog.suite.hasCompleteModelParityCoverage else {
            throw ParityBindingError.modelParityCoverageIncomplete(
                expected: ReleaseFixtureSuite.requiredModelParityFixtureCount,
                found: catalog.suite.fixtures(in: .modelParity).count
            )
        }

        let cells = Self.deriveRequiredCells(catalog: catalog)
        guard !cells.isEmpty else { throw ParityBindingError.requiredCellSetEmpty }
        let derived = Self.requiredComparisons(of: cells)
        // Reconciled against the domain's own statement of what Requirements 13.6 through
        // 13.11 require, so the derivation cannot quietly drop a comparison the plan
        // validator would still demand a specification for.
        let owed = ComparisonMetric.requiredComparisons(
            provenanceEnabled: versionTuple.enablesProvenance
        )
        let uncovered = owed.subtracting(derived)
        guard uncovered.isEmpty else {
            throw ParityBindingError.requiredComparisonsIncomplete(
                uncovered.sorted { $0.rawValue < $1.rawValue }
            )
        }
        for metric in derived where plan.comparison(for: metric) == nil {
            throw ParityBindingError.planComparisonMissing(metric)
        }

        self.plan = plan
        self.catalog = catalog
        self.configuration = configuration
        self.versionTuple = versionTuple
        self.requiredCells = cells
    }

    /// Whether the conditional provenance comparison applies to this release.
    ///
    /// Read from the catalogued suite, which ``FixtureCatalog/reconcile(withCapabilities:)``
    /// already proved agrees with the version tuple's capability set.
    public var provenanceApplicability: GateApplicability {
        catalog.suite.provenanceApplicability
    }

    /// Comparison metrics the required cells cover, in declaration order.
    public var requiredComparisons: [ComparisonMetric] {
        Self.requiredComparisons(of: requiredCells)
    }

    /// The required cells for one comparison metric.
    public func requiredCells(for metric: ComparisonMetric) -> [ParityCell] {
        requiredCells.filter { $0.comparison == metric }
    }

    // MARK: Deriving the closed required set

    /// Every comparison the catalogue owes.
    ///
    /// Three sources, and each is a requirement rather than a choice made here:
    ///
    ///   * every approved expectation a catalogued fixture declares that maps to a
    ///     comparison, so the required set is driven by approved declarations rather than by
    ///     a guess about which fixtures matter (Requirements 13.6, 13.7, 13.8, 13.10, 13.11);
    ///   * one rank-agreement cell over the model-parity family, because rank agreement has
    ///     no per-fixture meaning (Requirement 13.7); and
    ///   * one screenshot-geometry cell per physical-screenshot fixture, because
    ///     Requirement 13.9 asks for the comparison directly. No expectation kind can carry
    ///     its approved value, so the cell fails closed rather than not existing — the
    ///     alternative is a requirement that silently stops being checked.
    ///
    /// A malformed-input fixture contributes nothing: its only expected result is a terminal
    /// Analysis Error, which is not a comparison against a reference artifact and which
    /// Requirements 13.6 through 13.11 do not cover.
    private static func deriveRequiredCells(catalog: FixtureCatalog) -> [ParityCell] {
        var cells: Set<ParityCell> = []
        for fixture in catalog.suite.fixtures {
            let subject = ParitySubject.fixture(fixture.id, family: fixture.family)
            for expectation in fixture.expectations {
                guard let metric = expectation.referenceComparison else { continue }
                guard case .perDeclaringFixture = metric.parityScope else { continue }
                cells.insert(ParityCell(subject: subject, comparison: metric))
            }
        }
        for metric in ComparisonMetric.allCases {
            switch metric.parityScope {
            case .perDeclaringFixture:
                continue
            case let .perFamily(family):
                guard !catalog.suite.fixtures(in: family).isEmpty else { continue }
                cells.insert(ParityCell(subject: .family(family), comparison: metric))
            case let .perFixtureInFamilies(families):
                for fixture in catalog.suite.fixtures where families.contains(fixture.family) {
                    cells.insert(
                        ParityCell(
                            subject: .fixture(fixture.id, family: fixture.family),
                            comparison: metric
                        )
                    )
                }
            }
        }
        return cells.sorted { $0.orderingKey < $1.orderingKey }
    }

    private static func requiredComparisons(of cells: [ParityCell]) -> [ComparisonMetric] {
        let present = Set(cells.map(\.comparison))
        return ComparisonMetric.allCases.filter { present.contains($0) }
    }
}

// MARK: - The report

/// The recorded result of one parity gate, and the cells it was computed from.
public struct ParityGateResult: Hashable, Sendable {
    public let gate: DeviceGate
    public let applicability: GateApplicability

    /// The required cells this gate is computed from, in stable order.
    public let cells: [ParityCell]

    /// The recorded outcome.
    ///
    /// ``GateOutcome/notExecuted`` is reachable for exactly one reason: the gate carries an
    /// approved decision that it does not apply to this release, which Requirement 13.5
    /// permits for the conditional provenance gate. Every other path yields
    /// ``GateOutcome/passed`` or ``GateOutcome/failed``, so a gate whose cells were never
    /// measured fails rather than being absent.
    public let outcome: GateOutcome

    /// Why an applicable gate cannot pass in this process, when that is the reason.
    ///
    /// Non-`nil` whenever ``ObservedParityEnvironment/canProducePhysicalDeviceEvidence`` is
    /// false, which is every host and simulator run.
    public let processRefusal: NonQualifyingParityEvidence?

    init(
        gate: DeviceGate,
        applicability: GateApplicability,
        cells: [ParityCell],
        outcome: GateOutcome,
        processRefusal: NonQualifyingParityEvidence?
    ) {
        self.gate = gate
        self.applicability = applicability
        self.cells = cells
        self.outcome = outcome
        self.processRefusal = processRefusal
    }
}

/// Everything one parity run recorded.
///
/// A total mapping over the binding's closed required-cell set plus the projections a release
/// record needs. Constructible only inside this module, and only by a run: there is no
/// initialiser that takes outcomes, so a caller cannot assemble a report that declares a
/// comparison agreed.
public struct ParityRunReport: Hashable, Sendable {
    public let plan: ArtifactID
    public let fixtureSuite: ArtifactID
    public let configuration: CandidateDeviceConfiguration
    public let versionTuple: ValidationVersionTuple
    public let provenanceApplicability: GateApplicability

    /// Where this run's *process* was executing.
    ///
    /// Observed from the platform, never supplied. A caller cannot set it, so a host test run
    /// cannot report itself as a physical iPhone.
    public let runEnvironment: ExecutionEnvironment

    /// The closed required-cell set, in stable order.
    public let requiredCells: [ParityCell]

    private let outcomes: [ParityCell: ParityCellOutcome]

    /// Approved agreement ratios, copied from the bound plan at construction.
    ///
    /// Copied rather than referenced so the report never reads a plan: a projection that
    /// re-read one could be handed a different plan than the run was bound to.
    private let requiredAgreements: [ComparisonMetric: UnitInterval]

    init(
        binding: ParityRunBinding,
        runEnvironment: ExecutionEnvironment,
        outcomes: [ParityCell: ParityCellOutcome],
        requiredAgreements: [ComparisonMetric: UnitInterval]
    ) {
        self.plan = binding.plan.id
        self.fixtureSuite = binding.catalog.suite.id
        self.configuration = binding.configuration
        self.versionTuple = binding.versionTuple
        self.provenanceApplicability = binding.provenanceApplicability
        self.runEnvironment = runEnvironment
        self.requiredCells = binding.requiredCells
        self.outcomes = outcomes
        self.requiredAgreements = requiredAgreements
    }

    // MARK: The total mapping

    /// The outcome of one comparison. Total, and never satisfied without a comparison.
    ///
    /// Non-optional by design. The run recorded exactly one outcome per required cell, so
    /// every cell in ``requiredCells`` has a real answer here; and a cell *outside* the
    /// required set gets the same failure a missing result gets, because "this comparison was
    /// never required" is not a reason to treat it as done. There is deliberately no `nil`,
    /// no `Optional`, and no default that a caller could read as a pass.
    public func outcome(of cell: ParityCell) -> ParityCellOutcome {
        outcomes[cell]
            ?? .resultMissing(
                ParityResultGap(
                    fault: .observationAbsent,
                    owed: cell.comparison.owedReleaseInput,
                    standingLimits: cell.comparison.standingObservationLimits
                )
            )
    }

    // MARK: Projections

    /// Required cells that agreed.
    public var satisfiedCells: [ParityCell] {
        requiredCells.filter { outcome(of: $0).isSatisfied }
    }

    /// Required cells that did not agree, for any reason.
    public var unsatisfiedCells: [ParityCell] {
        requiredCells.filter { !outcome(of: $0).isSatisfied }
    }

    /// Required cells with no observation at all.
    public var missingResultCells: [ParityCell] {
        requiredCells.filter {
            if case .resultMissing = outcome(of: $0) { true } else { false }
        }
    }

    /// Required cells whose observation cannot back a device gate.
    public var nonQualifyingCells: [ParityCell] {
        requiredCells.filter {
            if case .nonQualifyingEvidence = outcome(of: $0) { true } else { false }
        }
    }

    /// Required cells whose approved expected value does not exist or cannot be expressed.
    public var expectationGapCells: [ParityCell] {
        requiredCells.filter {
            switch outcome(of: $0) {
            case .approvedExpectationUnrepresentable, .approvedExpectationAbsent: true
            default: false
            }
        }
    }

    /// Why no applicable gate can pass in this process, when that is so.
    ///
    /// Non-`nil` on a development Mac and in a simulator. This is the value that makes
    /// Requirement 13.16 structural rather than advisory: it is computed from
    /// ``ObservedParityEnvironment/current`` and there is no parameter, artifact, or approval
    /// that changes it.
    public var processRefusal: NonQualifyingParityEvidence? {
        runEnvironment.isPhysicalDeviceEvidence ? nil : .notPhysicalIPhone(runEnvironment)
    }

    /// The release-controlled inputs this run is still owed, in declaration order.
    public var owedInputs: [UnprovisionedParityInput] {
        var owed = Set<UnprovisionedParityInput>()
        for cell in requiredCells {
            switch outcome(of: cell) {
            case let .resultMissing(gap):
                owed.insert(gap.owed)
            case .approvedExpectationAbsent:
                owed.insert(cell.comparison.owedReleaseInput)
            case .agreed, .disagreed, .nonQualifyingEvidence,
                 .approvedExpectationUnrepresentable, .observationKindMismatch:
                continue
            }
        }
        if processRefusal != nil || !nonQualifyingCells.isEmpty {
            owed.insert(.physicalIPhoneRunEnvironment)
        }
        return UnprovisionedParityInput.allCases.filter { owed.contains($0) }
    }

    /// Standing implementation limits that qualify what this run's comparisons establish.
    ///
    /// Reported whatever each cell's outcome, because they are properties of the
    /// implementation rather than of a measurement.
    public var standingLimits: [UnobservableParityEvidence] {
        let applicable = Set(requiredCells.flatMap { $0.comparison.standingObservationLimits })
        return UnobservableParityEvidence.allCases.filter { applicable.contains($0) }
    }

    /// The overall parity outcome.
    ///
    /// Passing requires every applicable parity gate to pass, which in turn requires a
    /// physical-iPhone process. An empty required set cannot occur: the binding refuses one.
    public var outcome: GateOutcome {
        let results = DeviceGate.parityGates.map { gateResult(for: $0) }
        let blocking = results.filter { $0.applicability.isApplicable && !$0.outcome.isPassing }
        return blocking.isEmpty ? .passed : .failed
    }

    // MARK: Gates

    /// The recorded result of one parity gate.
    ///
    /// A gate not in ``DeviceGate/parityGates`` has no cells and no comparison to make, so it
    /// records ``GateOutcome/failed`` rather than a pass: this module measures parity, and it
    /// has nothing to say about a resource, thermal, accessibility, or localization gate.
    public func gateResult(for gate: DeviceGate) -> ParityGateResult {
        let cells = requiredCells.filter { Self.gates(for: $0).contains(gate) }
        let applicability = gate.isProvenanceConditional ? provenanceApplicability : .applicable

        guard applicability.isApplicable else {
            // The one legitimate `notExecuted`: an approved decision says the conditional
            // provenance gate does not apply to this release (Requirements 6.3 and 13.5).
            return ParityGateResult(
                gate: gate,
                applicability: applicability,
                cells: cells,
                outcome: .notExecuted,
                processRefusal: processRefusal
            )
        }
        guard let refusal = processRefusal else {
            return ParityGateResult(
                gate: gate,
                applicability: applicability,
                cells: cells,
                outcome: measuredOutcome(of: cells),
                processRefusal: nil
            )
        }
        // Barrier 2. No amount of agreement in a host or simulator process satisfies a
        // physical-device gate, and the refusal travels with the result so the reason is
        // recorded rather than inferred from a bare failure.
        return ParityGateResult(
            gate: gate,
            applicability: applicability,
            cells: cells,
            outcome: .failed,
            processRefusal: refusal
        )
    }

    /// The domain comparison record for one metric, for a device result set.
    ///
    /// `comparedFixtureCount` is the *required* cell count, not the number of cells that
    /// produced a comparison. That is deliberate and it is the whole of Requirement 13.19 in
    /// one line: a run that observed 90 of 96 fixtures reports 90 agreeing out of 96, not 90
    /// out of 90, so a missing result lowers the measured agreement instead of leaving the
    /// denominator to be whatever came back.
    ///
    /// Returns `nil` for a metric the binding does not require.
    public func comparisonRecord(
        for metric: ComparisonMetric,
        specification: EvidenceSource
    ) throws -> ComparisonRecord? {
        let cells = requiredCells.filter { $0.comparison == metric }
        guard !cells.isEmpty else { return nil }
        let agreeing = cells.filter { outcome(of: $0).isSatisfied }.count
        let deviations = cells.compactMap { outcome(of: $0).deviation?.value }
        let maximum = metric.isCategorical ? nil : deviations.max() ?? 0
        return try ComparisonRecord(
            metric: metric,
            specification: specification,
            comparedFixtureCount: try NonNegativeCount(validating: cells.count),
            agreeingFixtureCount: try NonNegativeCount(validating: agreeing),
            maximumDeviation: try maximum.map { try NonNegativeDecimal(validating: $0) },
            outcome: metricOutcome(metric, cells: cells)
        )
    }

    // MARK: Aggregation

    /// The outcome for one set of cells, evaluated per metric.
    ///
    /// Evaluated per metric rather than in bulk because two metrics in one gate can carry
    /// different approved acceptance rules: Requirement 13.10's gate covers a retained-byte
    /// comparison and a preservation-status comparison, and each has its own declared
    /// agreement ratio.
    private func measuredOutcome(of cells: [ParityCell]) -> GateOutcome {
        guard !cells.isEmpty else { return .failed }
        var metrics: [ComparisonMetric] = []
        for cell in cells where !metrics.contains(cell.comparison) {
            metrics.append(cell.comparison)
        }
        for metric in metrics {
            let scoped = cells.filter { $0.comparison == metric }
            guard metricOutcome(metric, cells: scoped).isPassing else { return .failed }
        }
        return .passed
    }

    /// The outcome for one metric over its cells.
    private func metricOutcome(_ metric: ComparisonMetric, cells: [ParityCell]) -> GateOutcome {
        guard !cells.isEmpty else { return .failed }
        // A cell that was never compared is never tolerable, whatever ratio the plan
        // declares. A ratio bounds disagreement among comparisons that happened; it does not
        // license a comparison that did not.
        guard cells.allSatisfy({ outcome(of: $0).wasCompared }) else { return .failed }
        let agreeing = cells.filter { outcome(of: $0).isSatisfied }.count
        guard let specification = requiredAgreement(for: metric) else {
            // A numeric comparison: every cell is already bounded by the plan's tolerance, so
            // every one has to be within it.
            return agreeing == cells.count ? .passed : .failed
        }
        // Compared as whole counts rather than as a decimal quotient, so the ratio check does
        // not depend on decimal division: `agreeing / total >= required` becomes
        // `agreeing >= required * total`.
        let threshold = specification.value * Decimal(cells.count)
        return Decimal(agreeing) >= threshold ? .passed : .failed
    }

    /// The plan's declared agreement ratio for a categorical metric.
    private func requiredAgreement(for metric: ComparisonMetric) -> UnitInterval? {
        requiredAgreements[metric]
    }

    /// Which gates one cell contributes to.
    ///
    /// Usually one, from ``ComparisonMetric/parityGate``. A physical-screenshot fixture's
    /// preprocessing-output and raw-logit cells contribute to
    /// ``DeviceGate/screenshotFidelity`` as well, because Requirement 13.9 asks for crop
    /// output and raw logit as part of the screenshot comparison and the same measurement
    /// answers both gates.
    static func gates(for cell: ParityCell) -> Set<DeviceGate> {
        var gates: Set<DeviceGate> = [cell.comparison.parityGate]
        if cell.subject.family == .physicalScreenshot,
            cell.comparison == .preprocessingOutput || cell.comparison == .rawLogit
        {
            gates.insert(.screenshotFidelity)
        }
        return gates
    }
}

// MARK: - The runner

/// Runs the eight parity comparisons for one bound plan and catalogue.
///
/// Holds nothing but the injected observation reader, so it carries no approved value of its
/// own and no state two runs could share. It cannot be constructed without a reader, which is
/// the structural form of "a run without observations does not happen" — and a reader with
/// nothing in it produces a report in which every cell is a failure, not an empty report.
public struct ParityRunner: Sendable {
    private let observations: any ParityObservationReading

    /// Creates a runner over the observation reader.
    ///
    /// Required, with no default. There is no convenience initialiser and no in-module reader:
    /// a runner without observations cannot exist rather than comparing against something this
    /// module chose.
    public init(observations: any ParityObservationReading) {
        self.observations = observations
    }

    /// Compares every cell the binding requires and records one outcome for each.
    ///
    /// Never throws. A parity run's failures are its result, and turning the first missing
    /// observation into a thrown error would stop the run at the first gap and report nothing
    /// about the rest — which is exactly the partial evidence Requirement 13.19 refuses.
    public func run(_ binding: ParityRunBinding) -> ParityRunReport {
        var outcomes: [ParityCell: ParityCellOutcome] = [:]
        for cell in binding.requiredCells {
            outcomes[cell] = evaluate(cell, in: binding)
        }
        var ratios: [ComparisonMetric: UnitInterval] = [:]
        for metric in binding.requiredComparisons {
            if let ratio = binding.plan.comparison(for: metric)?.requiredAgreement {
                ratios[metric] = ratio
            }
        }
        return ParityRunReport(
            binding: binding,
            runEnvironment: ObservedParityEnvironment.current,
            outcomes: outcomes,
            requiredAgreements: ratios
        )
    }

    // MARK: One cell

    private func evaluate(_ cell: ParityCell, in binding: ParityRunBinding) -> ParityCellOutcome {
        // A comparison whose expected side the schema cannot express is refused before any
        // observation is read, so a run cannot appear to have compared it.
        if case let .unrepresentable(limit) = cell.comparison.approvedExpectationSource {
            return .approvedExpectationUnrepresentable(limit)
        }
        if let blocking = cell.comparison.standingObservationLimits
            .sorted(by: { $0.rawValue < $1.rawValue })
            .first(where: \.blocksComparison)
        {
            return .approvedExpectationUnrepresentable(blocking)
        }
        if cell.comparison == .rankAgreement {
            return rankAgreement(cell, in: binding)
        }
        return perFixture(cell, in: binding)
    }

    /// One per-fixture comparison.
    private func perFixture(
        _ cell: ParityCell,
        in binding: ParityRunBinding
    ) -> ParityCellOutcome {
        guard let fixtureID = cell.subject.fixture,
            let fixture = binding.catalog.suite.fixtures.first(where: { $0.id == fixtureID })
        else {
            // Unreachable through a binding: every per-fixture cell was derived from a
            // catalogued fixture. Recorded as a missing result rather than ignored, because
            // a cell this module cannot resolve is not a cell that passed.
            return .resultMissing(gap(for: cell, fault: .observationAbsent))
        }
        let kind: FixtureExpectationKind
        switch cell.comparison.approvedExpectationSource {
        case let .expectationKind(declared):
            kind = declared
        case let .derivedFromFamilyExpectations(declared):
            // Unreachable: the only derived comparison is rank agreement, which is handled
            // before this point. Recorded as an absent approved expectation rather than
            // compared against a value this module would have to derive here.
            return .approvedExpectationAbsent(kind: declared)
        case let .unrepresentable(limit):
            return .approvedExpectationUnrepresentable(limit)
        }
        guard let expectation = fixture.expectations.first(where: { $0.kind == kind }) else {
            return .approvedExpectationAbsent(kind: kind)
        }

        let observation: ParityObservation
        do {
            observation = try observations.observation(for: cell)
        } catch {
            return .resultMissing(gap(for: cell, fault: error))
        }
        guard
            let evidence = QualifyingParityEvidence(
                observations: [observation],
                plan: binding.plan,
                configuration: binding.configuration,
                versionTuple: binding.versionTuple
            )
        else {
            return .nonQualifyingEvidence(
                Self.refusal(for: [observation], in: binding)
            )
        }
        guard let required = cell.comparison.requiredObservationKind else {
            // Unreachable: only rank agreement and screenshot geometry have no observed kind,
            // and both are handled before this point.
            return .approvedExpectationUnrepresentable(.screenshotGeometryHasNoExpectationKind)
        }
        guard observation.value.kind == required else {
            return .observationKindMismatch(observed: observation.value.kind, required: required)
        }
        return Self.compare(
            expectation: expectation,
            observed: observation.value,
            comparison: cell.comparison,
            plan: binding.plan,
            evidence: evidence
        )
    }

    /// Rank agreement over the model-parity family.
    ///
    /// The observed ordering is derived from the raw-logit observations of this same run and
    /// is never supplied as an input. An ordering handed in on its own could disagree with the
    /// logits the run recorded and still pass, which would make the comparison meaningless.
    /// The reference ordering is likewise derived, from the approved expected logits.
    private func rankAgreement(
        _ cell: ParityCell,
        in binding: ParityRunBinding
    ) -> ParityCellOutcome {
        let fixtures = binding.catalog.suite
            .fixtures(in: cell.subject.family)
            .sorted { $0.id.rawValue < $1.id.rawValue }
        guard !fixtures.isEmpty else {
            return .resultMissing(gap(for: cell, fault: .observationAbsent))
        }

        var expected: [Double] = []
        var observed: [Double] = []
        var contributing: [ParityObservation] = []
        for fixture in fixtures {
            guard
                let expectation = fixture.expectations.first(where: { $0.kind == .rawLogit }),
                case let .rawLogit(value, _) = expectation
            else {
                return .approvedExpectationAbsent(kind: .rawLogit)
            }
            let logitCell = ParityCell(
                subject: .fixture(fixture.id, family: fixture.family),
                comparison: .rawLogit
            )
            let observation: ParityObservation
            do {
                observation = try observations.observation(for: logitCell)
            } catch {
                return .resultMissing(gap(for: cell, fault: error))
            }
            guard case let .rawLogit(measured) = observation.value else {
                return .observationKindMismatch(
                    observed: observation.value.kind,
                    required: .rawLogit
                )
            }
            guard measured.isFinite else {
                return .disagreed(
                    ParityDisagreement(comparison: .rankAgreement, detail: .nonFiniteObservedLogit)
                )
            }
            expected.append(value)
            observed.append(measured)
            contributing.append(observation)
        }
        guard
            let evidence = QualifyingParityEvidence(
                observations: contributing,
                plan: binding.plan,
                configuration: binding.configuration,
                versionTuple: binding.versionTuple
            )
        else {
            return .nonQualifyingEvidence(Self.refusal(for: contributing, in: binding))
        }
        guard let tolerance = binding.plan.comparison(for: .rankAgreement)?.tolerance else {
            // Unreachable through a binding, which refuses a plan that omits a required
            // comparison. Recorded as a missing result rather than compared without a bound.
            return .resultMissing(gap(for: cell, fault: .observationAbsent))
        }

        var discordant = 0
        for i in expected.indices {
            for j in expected.indices where j > i {
                let referenceOrder = Self.order(expected[i], expected[j])
                // Equal approved logits impose no order, so a pair the reference does not
                // separate cannot be discordant.
                guard referenceOrder != 0 else { continue }
                if Self.order(observed[i], observed[j]) != referenceOrder { discordant += 1 }
            }
        }
        guard let deviation = try? NonNegativeDecimal(validating: Decimal(discordant)) else {
            // Unreachable: a pair count is a non-negative integer.
            return .resultMissing(gap(for: cell, fault: .observationUnreadable))
        }
        // The reference ordering has zero discordant pairs with itself, so a relative
        // tolerance over a zero reference requires exact agreement. That is stated here
        // rather than special-cased: `withinTolerance` refuses a nonzero deviation against a
        // zero magnitude for every tolerance kind.
        guard Self.withinTolerance(
            deviation: deviation.value,
            expectedMagnitude: 0,
            tolerance: tolerance
        ) else {
            return .disagreed(
                ParityDisagreement(
                    comparison: .rankAgreement,
                    detail: .orderingDiscordance(
                        discordantPairCount: discordant,
                        tolerance: tolerance
                    ),
                    deviation: deviation
                )
            )
        }
        return .agreed(
            ParityAgreement(comparison: .rankAgreement, evidence: evidence, deviation: deviation)
        )
    }

    // MARK: Comparing

    private static func compare(
        expectation: FixtureExpectation,
        observed: ObservedParityValue,
        comparison: ComparisonMetric,
        plan: DeviceValidationPlan,
        evidence: QualifyingParityEvidence
    ) -> ParityCellOutcome {
        switch (expectation, observed) {
        case let (.preprocessingOutputDigest(approved), .preprocessingOutputDigest(measured)):
            return categorical(approved == measured, comparison: comparison, evidence: evidence) {
                .digestMismatch
            }
        case let (.retainedBytesDigest(approved), .retainedBytesDigest(measured)):
            return categorical(approved == measured, comparison: comparison, evidence: evidence) {
                .digestMismatch
            }
        case let (.pixelLabel(approved), .pixelLabel(measured)):
            return categorical(approved == measured, comparison: comparison, evidence: evidence) {
                .categoricalMismatch(expected: approved.rawValue, observed: measured.rawValue)
            }
        case let (.bytePreservationStatus(approved), .bytePreservationStatus(measured)):
            return categorical(approved == measured, comparison: comparison, evidence: evidence) {
                .categoricalMismatch(expected: approved.rawValue, observed: measured.rawValue)
            }
        case let (.provenanceState(approved), .provenanceState(measured)):
            return categorical(approved == measured, comparison: comparison, evidence: evidence) {
                .categoricalMismatch(expected: approved.rawValue, observed: measured.rawValue)
            }
        case let (.rawLogit(approved, fixtureTolerance), .rawLogit(measured)):
            return rawLogit(
                approved: approved,
                fixtureTolerance: fixtureTolerance,
                measured: measured,
                plan: plan,
                evidence: evidence
            )
        default:
            // The kinds were already reconciled against the comparison, so the two sides
            // cannot disagree here. Recorded as a kind mismatch rather than as a pass.
            return .observationKindMismatch(
                observed: observed.kind,
                required: comparison.requiredObservationKind ?? observed.kind
            )
        }
    }

    private static func categorical(
        _ agreed: Bool,
        comparison: ComparisonMetric,
        evidence: QualifyingParityEvidence,
        otherwise detail: () -> ParityDisagreementDetail
    ) -> ParityCellOutcome {
        agreed
            ? .agreed(
                ParityAgreement(comparison: comparison, evidence: evidence, deviation: nil)
            )
            : .disagreed(ParityDisagreement(comparison: comparison, detail: detail()))
    }

    /// One raw-logit comparison, bounded by both approved tolerances.
    ///
    /// The plan's tolerance and the fixture's own declared tolerance are both approved values
    /// and neither is this module's to relax, so the comparison has to satisfy both. Their
    /// kinds differ — the plan's carries a ``ToleranceKind`` and the fixture's is an absolute
    /// bound — so they are evaluated independently rather than reduced to one number.
    private static func rawLogit(
        approved: Double,
        fixtureTolerance: NonNegativeDecimal,
        measured: Double,
        plan: DeviceValidationPlan,
        evidence: QualifyingParityEvidence
    ) -> ParityCellOutcome {
        guard measured.isFinite else {
            return .disagreed(
                ParityDisagreement(comparison: .rawLogit, detail: .nonFiniteObservedLogit)
            )
        }
        let delta = abs(measured - approved)
        guard delta.isFinite, delta <= Self.maximumRepresentableDeviation else {
            return .disagreed(
                ParityDisagreement(
                    comparison: .rawLogit,
                    detail: .deviationNotRepresentable(expected: approved, observed: measured)
                )
            )
        }
        guard let deviation = try? NonNegativeDecimal(validating: Decimal(delta)) else {
            return .disagreed(
                ParityDisagreement(
                    comparison: .rawLogit,
                    detail: .deviationNotRepresentable(expected: approved, observed: measured)
                )
            )
        }
        guard let tolerance = plan.comparison(for: .rawLogit)?.tolerance else {
            // Unreachable through a binding, which refuses a plan that omits a required
            // comparison.
            return .resultMissing(
                ParityResultGap(
                    fault: .observationAbsent,
                    owed: .rawLogitReferences,
                    standingLimits: ComparisonMetric.rawLogit.standingObservationLimits
                )
            )
        }
        guard Self.withinTolerance(
            deviation: deviation.value,
            expectedMagnitude: Decimal(abs(approved)),
            tolerance: tolerance
        ) else {
            return .disagreed(
                ParityDisagreement(
                    comparison: .rawLogit,
                    detail: .deviationExceedsTolerance(
                        deviation: deviation,
                        tolerance: tolerance
                    ),
                    deviation: deviation
                )
            )
        }
        guard deviation.value <= fixtureTolerance.value else {
            return .disagreed(
                ParityDisagreement(
                    comparison: .rawLogit,
                    detail: .deviationExceedsFixtureTolerance(
                        deviation: deviation,
                        tolerance: fixtureTolerance
                    ),
                    deviation: deviation
                )
            )
        }
        return .agreed(
            ParityAgreement(comparison: .rawLogit, evidence: evidence, deviation: deviation)
        )
    }

    /// The largest deviation a decimal comparison represents.
    ///
    /// Beyond this a `Decimal` conversion produces a value no tolerance can be compared
    /// against, so the deviation is recorded as unrepresentable rather than clamped into
    /// range. A deviation this large is a disagreement under every tolerance a plan can
    /// declare.
    static let maximumRepresentableDeviation: Double = 1e30

    static func withinTolerance(
        deviation: Decimal,
        expectedMagnitude: Decimal,
        tolerance: NumericTolerance
    ) -> Bool {
        switch tolerance.kind {
        case .exact:
            return deviation == 0
        case .absolute:
            return deviation <= tolerance.value.value
        case .relative:
            guard expectedMagnitude != 0 else { return deviation == 0 }
            return deviation <= tolerance.value.value * expectedMagnitude
        }
    }

    /// -1, 0, or 1 for the order of two finite logits.
    static func order(_ lhs: Double, _ rhs: Double) -> Int {
        if lhs < rhs { return -1 }
        if lhs > rhs { return 1 }
        return 0
    }

    // MARK: Refusals

    /// Why a set of observations cannot back a device gate.
    ///
    /// Reports the first reason found, in the order the requirements impose it: the
    /// environment first (Requirement 13.16), then the configuration, then the version tuple
    /// (Requirement 13.20).
    private static func refusal(
        for observations: [ParityObservation],
        in binding: ParityRunBinding
    ) -> NonQualifyingParityEvidence {
        for observation in observations where !observation.environment.isPhysicalDeviceEvidence {
            return .notPhysicalIPhone(observation.environment)
        }
        for observation in observations
        where observation.configuration != binding.configuration {
            return .configurationMismatch(
                expected: binding.configuration.hardwareIdentifier,
                observed: observation.configuration.hardwareIdentifier
            )
        }
        for observation in observations
        where !binding.plan.candidateConfigurations.contains(observation.configuration) {
            return .configurationNotInPlan(
                observation.configuration.hardwareIdentifier,
                observation.configuration.osVersion
            )
        }
        if observations.contains(where: { $0.versionTuple != binding.versionTuple }) {
            return .versionTupleMismatch
        }
        if !binding.plan.candidateConfigurations.contains(binding.configuration) {
            return .configurationNotInPlan(
                binding.configuration.hardwareIdentifier,
                binding.configuration.osVersion
            )
        }
        // An empty observation set also fails qualification. It is a version-tuple refusal
        // only in the sense that nothing established one; either way it is not a pass.
        return .versionTupleMismatch
    }

    private func gap(for cell: ParityCell, fault: ParityObservationFault) -> ParityResultGap {
        ParityResultGap(
            fault: fault,
            owed: cell.comparison.owedReleaseInput,
            standingLimits: cell.comparison.standingObservationLimits
        )
    }
}
