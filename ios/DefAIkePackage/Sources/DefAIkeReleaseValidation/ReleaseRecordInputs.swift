import DefAIkeDomain

// The typed evidence a release record is assembled from, and the two values that make its
// gate outcomes unfakeable.
//
// Task 14.8 is a consumer. Every one of the twelve evidence kinds it joins is already a typed
// value produced by a sibling task — ``ParityRunReport`` (14.2), ``ResourceValidationReport``
// (14.3), ``AccessibilityMatrixReport`` (14.4), ``BundleActivationEvidence`` (14.5),
// ``ArchiveAuditReport`` (14.6), ``CorpusRemediation`` (14.7), ``ApprovedCalibrationRelease``
// and the legal and governance approval records from the domain. Nothing here measures
// anything, re-derives anything, or interprets a blob: 14.6 built typed evidence specifically
// so that this task would not have to, and its note is the reason — interpreting is where a
// failing input becomes a warning.
//
// Two structural rules run through this file, and both are the reason these are types rather
// than records with an `outcome` field.
//
//   * **A gate outcome is derived, never stored.** ``ReleaseGateEvidence/outcome`` is a
//     computed property over the same stored fields that carry the findings, and there is no
//     `outcome:` parameter anywhere in this module's public surface. So a record claiming a
//     passing gate beside a failing input is not "refused at assembly time" — the expression
//     that answers "did this gate pass" *is* the expression that reads the findings, and there
//     is no second place a `passed` could be written down. ``ReleaseGateEvidence`` also has a
//     module-internal initialiser, so the only producer is the assembler, which computes every
//     finding from the typed evidence it was handed.
//   * **One record for one configuration comes from one exact version tuple.**
//     ``CoherentDeviceEvidence`` exists only when the parity, resource, and matrix reports for
//     a configuration report the *same whole* ``ValidationVersionTuple`` and that tuple
//     reconciles against the signed ``ReleaseCapabilityManifest`` field by field — including
//     the capability implementation versions, which no binding layer below checks.
//
// What this file does not do: reach a legal, data-rights, governance, trust, or fusion
// conclusion, choose a signing key, mint an applicability decision, or decide that a
// distribution may proceed. Approvals arrive inside approved inputs and are read.

// MARK: - One configuration's coherent device evidence

/// Every mandatory device gate's evidence for one candidate configuration, from one tuple.
///
/// Construction is the reconciliation gate, and it is the record-level enforcement of
/// Requirement 13.20. A value of this type means:
///
///   1. the parity, resource, and matrix reports all describe the same candidate configuration
///      at the same operating-system version;
///   2. all three ran under the same whole ``ValidationVersionTuple`` — application build,
///      Model Bundle, fixture suite, validation plan, capability manifest, capability set, and
///      capability implementation versions;
///   3. that tuple's application build, capability manifest, capability set, and *every*
///      capability implementation version are the signed manifest's, and its Model Bundle is in
///      the manifest's approved catalogue; and
///   4. all three ran in the same execution environment.
///
/// Point 3's implementation-version clause is the one no layer below enforces at the record
/// level. ``ParityRunBinding`` reconciles the fixture suite, plan, bundle, manifest, and build
/// and never touches `capabilityImplementationVersions`, so a tuple differing only in an
/// implementation version binds; below this type the clause holds only one observation at a
/// time, through whole-tuple equality inside ``QualifyingParityEvidence``. Here it is checked
/// once for the whole configuration, as a keyed mapping so entry order can neither hide a
/// disagreement nor manufacture one.
///
/// It does not mean anything passed. Gate outcomes are computed from the three runners' cells,
/// and today every one of them fails.
public struct CoherentDeviceEvidence: Sendable {

    /// The release-controlled identity this configuration is allowlisted under.
    ///
    /// An approved input. This module names no configuration: a generated identifier would be
    /// this module deciding which iPhone a release approves.
    public let configurationID: ApprovedConfigurationID

    public let configuration: CandidateDeviceConfiguration

    /// The one tuple every contributing report ran under.
    public let versionTuple: ValidationVersionTuple

    public let parity: ParityRunReport
    public let resources: ResourceValidationReport
    public let matrix: AccessibilityMatrixConfigurationReport

    /// The catalogued suite the parity run compared against.
    public let catalog: FixtureCatalog

    /// The immutable result artifact each runner produced.
    ///
    /// Three citations rather than 22, because three runs produced these results and a
    /// per-gate citation would let one entry name a run that never covered it. Supplied, never
    /// derived: this module cannot mint an artifact identifier, version, or content digest for
    /// evidence someone else produced.
    public let parityResult: EvidenceSource
    public let resourceResult: EvidenceSource
    public let matrixResult: EvidenceSource

    public init(
        configurationID: ApprovedConfigurationID,
        parity: ParityRunReport,
        resources: ResourceValidationReport,
        matrix: AccessibilityMatrixConfigurationReport,
        catalog: FixtureCatalog,
        capabilityManifest manifest: ReleaseCapabilityManifest,
        parityResult: EvidenceSource,
        resourceResult: EvidenceSource,
        matrixResult: EvidenceSource
    ) throws(ReleaseRecordCoherenceError) {
        let configuration = parity.configuration
        let tuple = parity.versionTuple

        for other in [resources.mainApplication.configuration,
                      resources.shareExtension.configuration,
                      matrix.configuration]
        {
            guard other.hardwareIdentifier == configuration.hardwareIdentifier else {
                throw ReleaseRecordCoherenceError.configurationMixed(
                    expected: configuration.hardwareIdentifier,
                    found: other.hardwareIdentifier
                )
            }
            guard other.osVersion == configuration.osVersion else {
                throw ReleaseRecordCoherenceError.operatingSystemVersionMixed(
                    expected: configuration.osVersion,
                    found: other.osVersion
                )
            }
            guard other.appBuild == configuration.appBuild else {
                throw ReleaseRecordCoherenceError.configurationAppBuildMismatch(
                    expected: configuration.appBuild,
                    found: other.appBuild
                )
            }
        }

        // Whole-tuple equality, so a difference in any field — including a capability
        // implementation version — is a mixed evidence set rather than a coincidence two
        // bindings both accepted.
        for (kind, other) in [
            (ReleaseRecordEvidenceKind.device, resources.mainApplication.versionTuple),
            (ReleaseRecordEvidenceKind.device, resources.shareExtension.versionTuple),
            (ReleaseRecordEvidenceKind.accessibility, matrix.versionTuple),
        ] where other != tuple {
            throw ReleaseRecordCoherenceError.versionTupleMixed(kind)
        }

        let environment = parity.runEnvironment
        for other in [resources.runEnvironment, matrix.runEnvironment] where other != environment {
            throw ReleaseRecordCoherenceError.runEnvironmentMixed(
                expected: environment,
                found: other
            )
        }

        try Self.reconcile(tuple, configuration: configuration, with: manifest)

        guard catalog.suite.id == tuple.fixtureSuite else {
            throw ReleaseRecordCoherenceError.fixtureSuiteMismatch(
                expected: tuple.fixtureSuite,
                found: catalog.suite.id
            )
        }
        guard parity.fixtureSuite == tuple.fixtureSuite else {
            throw ReleaseRecordCoherenceError.fixtureSuiteMismatch(
                expected: tuple.fixtureSuite,
                found: parity.fixtureSuite
            )
        }
        for (kind, plan) in [
            (ReleaseRecordEvidenceKind.device, parity.plan),
            (ReleaseRecordEvidenceKind.device, resources.mainApplication.plan),
            (ReleaseRecordEvidenceKind.device, resources.shareExtension.plan),
            (ReleaseRecordEvidenceKind.accessibility, matrix.plan),
        ] where plan != tuple.validationPlan {
            throw ReleaseRecordCoherenceError.validationPlanMismatch(
                kind: kind,
                expected: tuple.validationPlan,
                found: plan
            )
        }

        self.configurationID = configurationID
        self.configuration = configuration
        self.versionTuple = tuple
        self.parity = parity
        self.resources = resources
        self.matrix = matrix
        self.catalog = catalog
        self.parityResult = parityResult
        self.resourceResult = resourceResult
        self.matrixResult = matrixResult
    }

    /// Requirement 13.20's tuple clause, field by field, against the signed manifest.
    ///
    /// The application-build identity is checked here rather than left to the entry schema.
    /// ``ApprovedDeviceConfiguration`` requires an entry's configuration and tuple to agree
    /// with *each other*, which two sibling entries can satisfy while naming two different
    /// builds; requiring both to be the manifest's build is what makes a disagreeing pair
    /// impossible to assemble.
    private static func reconcile(
        _ tuple: ValidationVersionTuple,
        configuration: CandidateDeviceConfiguration,
        with manifest: ReleaseCapabilityManifest
    ) throws(ReleaseRecordCoherenceError) {
        guard tuple.appBuild == manifest.appBuild else {
            throw ReleaseRecordCoherenceError.appBuildNotTheManifestBuild(
                expected: manifest.appBuild,
                found: tuple.appBuild
            )
        }
        guard configuration.appBuild == tuple.appBuild else {
            throw ReleaseRecordCoherenceError.configurationAppBuildMismatch(
                expected: tuple.appBuild,
                found: configuration.appBuild
            )
        }
        guard tuple.capabilityManifest == manifest.id else {
            throw ReleaseRecordCoherenceError.capabilityManifestMismatch(
                expected: manifest.id,
                found: tuple.capabilityManifest
            )
        }
        guard tuple.capabilities == manifest.compiledCapabilities else {
            throw ReleaseRecordCoherenceError.capabilitySetMismatch(
                expected: manifest.compiledCapabilities.map(\.rawValue).sorted(),
                found: tuple.capabilities.map(\.rawValue).sorted()
            )
        }
        // Compared as a keyed mapping in both directions. The exact-coverage rule inside both
        // schemas already ties each list to its own capability set, and the sets are equal by
        // the check above, so a missing key here is unreachable; the version disagreement is
        // the reachable one and it is the clause no binding layer checks.
        var declared: [CapabilityID: CapabilityImplementationVersion] = [:]
        for entry in manifest.implementationVersions {
            declared[entry.capability] = entry.version
        }
        for entry in tuple.capabilityImplementationVersions {
            guard let approved = declared[entry.capability] else {
                throw ReleaseRecordCoherenceError.capabilitySetMismatch(
                    expected: declared.keys.map(\.rawValue).sorted(),
                    found: tuple.capabilityImplementationVersions
                        .map(\.capability.rawValue)
                        .sorted()
                )
            }
            guard approved == entry.version else {
                throw ReleaseRecordCoherenceError.capabilityImplementationVersionMismatch(
                    capability: entry.capability,
                    expected: approved,
                    found: entry.version
                )
            }
        }
        guard manifest.approvedBundleCatalog.contains(tuple.modelBundle) else {
            throw ReleaseRecordCoherenceError.modelBundleOutsideApprovedCatalog(tuple.modelBundle)
        }
    }

    // MARK: Device gate outcomes

    /// The recorded outcome of one mandatory device gate, computed from the runners' cells.
    ///
    /// Routed to the runner that measured it, and computed from that runner's cells rather than
    /// read from any entry's `isSatisfied`. That distinction matters:
    /// ``GateResultReference/isSatisfied`` answers `decision.isApproved` for a not-applicable
    /// gate, so an entry whose every gate is declared inapplicable reports every gate satisfied
    /// while nothing ran anywhere. All four runners compute their outcomes from cells, and so
    /// does this.
    ///
    /// A gate no runner measures cannot occur: the 22 mandatory gates are exactly
    /// `DeviceGate.parityGates ∪ resourceGates ∪ matrixGates`, and the `default` arm is
    /// therefore unreachable and reports a failure rather than a pass.
    public func outcome(of gate: DeviceGate) -> GateOutcome {
        if DeviceGate.parityGates.contains(gate) {
            return parity.gateResult(for: gate).outcome
        }
        if DeviceGate.resourceGates.contains(gate) {
            return resources.outcome(of: gate)
        }
        if DeviceGate.matrixGates.contains(gate) {
            return matrix.gateResult(for: gate).outcome
        }
        return .failed
    }

    /// The applicability of one mandatory device gate.
    ///
    /// Only the conditional provenance gate can be anything but applicable, and its value is
    /// read from the catalogued suite's approved decision rather than decided here — which is
    /// what "preserved rather than collapsed" means: the decision travels from the signed suite
    /// through the parity binding into the allowlist entry unchanged.
    public func applicability(of gate: DeviceGate) -> GateApplicability {
        gate.isProvenanceConditional ? parity.provenanceApplicability : .applicable
    }

    /// Whether one mandatory device gate is satisfied for this configuration.
    ///
    /// Applicable gates need a computed pass. The one conditional gate needs an approved
    /// inapplicability decision, read through ``GateApplicability/inapplicabilityDecision`` so
    /// an unapproved waiver waives nothing.
    public func isSatisfied(_ gate: DeviceGate) -> Bool {
        let applicability = self.applicability(of: gate)
        guard applicability.isApplicable else {
            return applicability.inapplicabilityDecision?.isApproved ?? false
        }
        return outcome(of: gate).isPassing
    }

    /// Mandatory device gates this configuration does not satisfy.
    ///
    /// Nonempty means Requirement 13.19 excludes the configuration from the allowlist.
    public var unsatisfiedGates: Set<DeviceGate> {
        Set(DeviceGate.mandatoryGates.filter { !isSatisfied($0) })
    }

    /// Whether every mandatory device gate is satisfied on a physical iPhone.
    ///
    /// False today for every configuration, and for reasons the three runners name one cell at
    /// a time. Two barriers stand behind it and neither is bypassable from here: the qualifying
    /// evidence initialisers are internal to this module, and each runner's environment comes
    /// from ``ObservedParityEnvironment/current``, compiled from the platform with no setter.
    public var isPassing: Bool { unsatisfiedGates.isEmpty }

    /// Where the three runs executed. The same for all three, by construction.
    public var runEnvironment: ExecutionEnvironment { parity.runEnvironment }

    /// Whether this release's evidence enables the conditional provenance lane.
    public var enablesProvenance: Bool { versionTuple.enablesProvenance }

    /// The immutable citation for one mandatory device gate's result.
    public func resultCitation(for gate: DeviceGate) -> EvidenceSource {
        if DeviceGate.parityGates.contains(gate) { return parityResult }
        if DeviceGate.resourceGates.contains(gate) { return resourceResult }
        return matrixResult
    }
}

// MARK: - Why a configuration was excluded

/// Why one candidate configuration is not in the generated allowlist.
///
/// A closed vocabulary with no case meaning "admitted with reservations". Requirement 13.19
/// excludes a configuration whose mandatory result is missing or failing and Requirement 13.21
/// excludes one whose parity fails a plan limit, so exclusion is the only alternative to
/// admission.
public enum DeviceExclusionReason: Hashable, Sendable, CustomStringConvertible {

    /// One or more mandatory device gates are not satisfied (Requirements 13.19 and 13.21).
    case mandatoryGatesUnsatisfied([DeviceGate])

    /// The evidence was produced somewhere that cannot satisfy a device gate
    /// (Requirement 13.16).
    case notPhysicalDeviceEvidence(ExecutionEnvironment)

    /// Two evidence sets claim the same configuration identity.
    case duplicateConfigurationIdentity(ApprovedConfigurationID)

    /// Two evidence sets claim the same hardware, operating-system, and build triple.
    case duplicateConfigurationTriple(DeviceHardwareID, PlatformVersion)

    /// The entry could not be constructed from the evidence.
    ///
    /// Carries the schema's own refusal text so an audit reads the field that refused rather
    /// than a restatement of it.
    case entryNotRepresentable(String)

    public var description: String {
        switch self {
        case let .mandatoryGatesUnsatisfied(gates):
            return "unsatisfied mandatory gates: \(gates.map(\.rawValue).sorted())"
        case let .notPhysicalDeviceEvidence(environment):
            return "produced in \(environment.rawValue), which cannot satisfy a device gate"
        case let .duplicateConfigurationIdentity(identifier):
            return "\(identifier.rawValue) is claimed by more than one evidence set"
        case let .duplicateConfigurationTriple(hardware, osVersion):
            return "\(hardware.rawValue)@\(osVersion.description) is claimed twice"
        case let .entryNotRepresentable(detail):
            return "the allowlist entry is not representable: \(detail)"
        }
    }
}

/// One candidate configuration the generator did not admit, and why.
public struct ExcludedDeviceConfiguration: Hashable, Sendable {
    public let configurationID: ApprovedConfigurationID
    public let hardwareIdentifier: DeviceHardwareID
    public let osVersion: PlatformVersion
    public let reason: DeviceExclusionReason

    init(
        configurationID: ApprovedConfigurationID,
        hardwareIdentifier: DeviceHardwareID,
        osVersion: PlatformVersion,
        reason: DeviceExclusionReason
    ) {
        self.configurationID = configurationID
        self.hardwareIdentifier = hardwareIdentifier
        self.osVersion = osVersion
        self.reason = reason
    }
}

// MARK: - One record gate's finding

/// One failing release-record input, tagged with the gate it fails.
///
/// A closed vocabulary. Requirement 14.15 blocks the affected public distribution on a missing
/// or failing applicable mandatory entry, so there is no case here meaning "noted", "waived",
/// or "acceptable" — every value makes its gate fail, and the assembler is the only producer.
public enum ReleaseRecordFinding: Hashable, Sendable, CustomStringConvertible {

    /// The evidence a gate reads does not exist.
    case evidenceAbsent(ReleaseRecordEvidenceKind)

    /// A contributing runner or audit recorded a failure.
    ///
    /// Carries the contributing report's own account rather than a reworded one, for the same
    /// reason ``ArchiveAuditFinding/detail`` is verbatim: a release record that rephrased a
    /// measurement would be a second account of it.
    case contributingResultFailed(ReleaseRecordEvidenceKind, detail: String)

    /// An externally supplied decision this gate reports is a rejection.
    ///
    /// Read, never derived. Requirements 14.2 through 14.4, 14.9, and 14.10 reserve the
    /// licence, dataset-terms, and governance conclusions for their written records, and this
    /// case is the record's rejection being carried into the gate rather than resolved.
    case externalDecisionRejected(ReleaseRecordEvidenceKind)

    /// No candidate iPhone configuration passes every mandatory device gate
    /// (Requirement 13.22).
    case noPassingDeviceConfiguration

    /// One candidate configuration was excluded from the allowlist (Requirement 13.19).
    case deviceConfigurationExcluded(ApprovedConfigurationID, DeviceExclusionReason)

    /// A required fixture family is absent from the catalogued suite (Requirement 13.4).
    case fixtureFamilyAbsent(FixtureFamily)

    /// The suite does not account for all 96 model-parity references (Requirement 13.4).
    case modelParityCoverageIncomplete(observed: Int, required: Int)

    /// The record names a Model Bundle the manifest's approved catalogue does not.
    case modelBundleOutsideApprovedCatalog(ModelBundleID)

    /// The bundle evidence answers for a different Model Bundle than the record distributes.
    case bundleEvidenceNamesAnotherBundle(expected: ModelBundleID, found: ModelBundleID)

    /// A published claim is not bound to this release's artifacts (Requirements 8.16, 14.12).
    case claimBindingMismatch(ArtifactID, field: String)

    /// A published claim rests on a regenerated comparison naming an excluded corpus entry
    /// (Requirement 14.7).
    case claimRestsOnExcludedCorpusEntry(count: Int)

    /// A mandatory Release Gating Slice the requirements name is absent (Requirement 5.20).
    case mandatoryGatingSliceAbsent(String)

    /// A conditional gate's declared applicability is not the compiled capability set
    /// (Requirements 6.2, 6.3, 7.15, 7.16).
    case conditionalApplicabilityDisagreesWithManifest(
        ReleaseGate,
        compiled: Bool,
        declared: Bool
    )

    /// An applicable conditional gate has no approved artifact behind it.
    case conditionalCapabilityUnbacked(ReleaseGate)

    public var description: String {
        switch self {
        case let .evidenceAbsent(kind):
            return "no \(kind.rawValue) exists"
        case let .contributingResultFailed(kind, detail):
            return "\(kind.rawValue) failed: \(detail)"
        case let .externalDecisionRejected(kind):
            return "the \(kind.rawValue) decision is a rejection"
        case .noPassingDeviceConfiguration:
            return "no candidate iPhone configuration passes every mandatory device gate"
        case let .deviceConfigurationExcluded(identifier, reason):
            return "\(identifier.rawValue) excluded: \(reason.description)"
        case let .fixtureFamilyAbsent(family):
            return "the \(family.rawValue) fixture family is absent"
        case let .modelParityCoverageIncomplete(observed, required):
            return "\(observed) of \(required) model-parity references are accounted for"
        case let .modelBundleOutsideApprovedCatalog(bundle):
            return "\(bundle.rawValue) is not in the approved bundle catalogue"
        case let .bundleEvidenceNamesAnotherBundle(expected, found):
            return "the bundle evidence answers for \(found.rawValue), not \(expected.rawValue)"
        case let .claimBindingMismatch(claim, field):
            return "claim \(claim.rawValue) is not bound at \(field)"
        case let .claimRestsOnExcludedCorpusEntry(count):
            return "\(count) regenerated comparisons name a corpus entry the dispositions "
                + "excluded"
        case let .mandatoryGatingSliceAbsent(name):
            return "no \(name) release gating slice is present"
        case let .conditionalApplicabilityDisagreesWithManifest(gate, compiled, declared):
            return "\(gate.rawValue) is declared "
                + (declared ? "applicable" : "not applicable")
                + " while the manifest compiles it as "
                + (compiled ? "applicable" : "not applicable")
        case let .conditionalCapabilityUnbacked(gate):
            return "\(gate.rawValue) is applicable with no approved artifact behind it"
        }
    }
}

// MARK: - One record gate's evidence

/// One release-readiness gate's joined evidence.
///
/// The `outcome` is not stored. It is computed from `findings`, `unprovisionedInputs`, and
/// whether a citation exists, so a gate with any of the three cannot be passing and a gate with
/// none of them cannot be failing. Requirement 14.15 blocks distribution on a missing or
/// failing mandatory entry, and this is where "missing is not pass" stops being a convention.
///
/// The initialiser is module-internal. The only producer is ``ReleaseRecordAssembler``, which
/// derives every field from the typed evidence it was handed, so no caller can hand in a
/// finding-free gate for evidence that carries findings — and no caller can hand in an outcome
/// at all, because no initialiser anywhere accepts one.
public struct ReleaseGateEvidence: Hashable, Sendable {
    public let gate: ReleaseGate

    /// Whether this gate applies, as an approved decision. Supplied for the two conditional
    /// gates and ``GateApplicability/applicable`` for the other 24.
    public let applicability: GateApplicability

    /// The immutable artifact this gate's result came from, or `nil` when it names none.
    ///
    /// `nil` is a real state and it is not a pass: Requirement 14.1 requires the source
    /// artifact identifier and version, and a result with no citation is not a mapping.
    public let citation: EvidenceSource?

    /// The joined evidence kinds this outcome was computed from.
    public let contributingKinds: [ReleaseRecordEvidenceKind]

    /// Every failing input routed to this gate.
    public let findings: [ReleaseRecordFinding]

    /// Every release-controlled input this gate depends on and does not have.
    public let unprovisionedInputs: [UnprovisionedReleaseRecordInput]

    /// Whether the evidence this gate reads was produced at all.
    ///
    /// A run that produced nothing yields ``GateOutcome/notExecuted`` rather than a pass over
    /// nothing, which is the same shape ``ArchiveAuditGateEvidence`` uses for an audit that
    /// inspected no archive.
    public let evidenceWasProduced: Bool

    init(
        gate: ReleaseGate,
        applicability: GateApplicability,
        citation: EvidenceSource?,
        contributingKinds: [ReleaseRecordEvidenceKind],
        findings: [ReleaseRecordFinding],
        unprovisionedInputs: [UnprovisionedReleaseRecordInput],
        evidenceWasProduced: Bool
    ) {
        self.gate = gate
        self.applicability = applicability
        self.citation = citation
        self.contributingKinds = contributingKinds
        self.findings = findings
        self.unprovisionedInputs = unprovisionedInputs
        self.evidenceWasProduced = evidenceWasProduced
    }

    /// The gate outcome, derived.
    ///
    /// Three values and no fourth, matching ``GateOutcome`` exactly. There is no "passed with
    /// findings", because Requirement 14.15 makes a failing entry a block and a fourth value is
    /// how one would stop being one.
    ///
    /// ``GateOutcome/notExecuted`` is reachable for exactly two reasons: an approved decision
    /// says the conditional gate does not apply to this release, which Requirements 6.3, 7.16,
    /// and 14.1 permit; or the evidence was never produced and the gate names no citation.
    /// Every other path yields ``GateOutcome/passed`` or ``GateOutcome/failed``.
    public var outcome: GateOutcome {
        guard applicability.isApplicable else { return .notExecuted }
        guard evidenceWasProduced, citation != nil else { return .notExecuted }
        return findings.isEmpty && unprovisionedInputs.isEmpty ? .passed : .failed
    }

    /// Whether this gate is satisfied: it passed, or an approved decision declared it
    /// inapplicable.
    ///
    /// Read through ``GateApplicability/inapplicabilityDecision`` rather than through
    /// ``ReleaseGateRecord/isSatisfied``, and only ever for a gate ``ReleaseGate/isConditional``
    /// admits — so an unapproved waiver waives nothing, and an unconditional gate cannot be
    /// satisfied by a waiver at all.
    public var isSatisfied: Bool {
        guard applicability.isApplicable else {
            guard gate.isConditional else { return false }
            return applicability.inapplicabilityDecision?.isApproved ?? false
        }
        return outcome.isPassing
    }

    /// This gate's entry in the release-readiness record.
    ///
    /// Throws when the gate names no evidence artifact, because ``ReleaseGateRecord`` requires
    /// one and this module will not mint an identifier, version, or digest for a result it did
    /// not produce. The outcome written into the entry is ``outcome`` — the derived value — so
    /// the entry cannot disagree with the findings beside it.
    func releaseGateRecord() throws -> ReleaseGateRecord {
        guard let citation else {
            throw ReleaseRecordOutputRefusal.gateNamesNoEvidence([gate])
        }
        return try ReleaseGateRecord(
            gate: gate,
            applicability: applicability,
            outcome: outcome,
            evidence: citation
        )
    }
}
