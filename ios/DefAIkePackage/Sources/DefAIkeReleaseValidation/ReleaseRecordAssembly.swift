import DefAIkeDomain
import DefAIkeModelBundle

// Joining twelve kinds of evidence into one release-record payload, and generating the device
// allowlist from the coherent passing tuples inside it.
//
// This is the consumer at the top of section 14. It measures nothing. Every gate outcome it
// records is computed from a value a sibling task produced and only that task can produce:
//
//   | Record gates | Computed from | Produced by |
//   |---|---|---|
//   | the four calibration and evidence gates | ``ApprovedCalibrationRelease`` | the domain's calibration approval, which refuses a slice over budget |
//   | the two corpus gates | ``CorpusRemediation`` | task 14.7, constructible only by a run that reconciled both approved records |
//   | the four bundle gates | ``BundleActivationEvidence`` | task 14.5, whose outcomes come from runtime values only `DefAIkeModelBundle` can return |
//   | `privacy-audit`, `archive-audit`, `dependency-notices`, `corpus-exclusion` | ``ArchiveAuditReport`` | task 14.6, whose gate outcomes are derived at decode and refused when a report disagrees with its own findings |
//   | the two matrix gates | ``AccessibilityMatrixReport`` | task 14.4 |
//   | `device-allowlist` | the generated allowlist over ``CoherentDeviceEvidence`` | tasks 14.2 and 14.3 |
//   | `fixture-suite-completeness` | ``FixtureCatalog`` | task 14.1 |
//   | `capability-manifest-match` | the signed ``ReleaseCapabilityManifest`` | an approved release artifact |
//   | the three legal and governance gates | the carried ``ApprovalRecord`` values, read | release owners |
//   | the two publication gates | the cited documents' existence | release owners |
//   | the two conditional gates | the supplied applicability plus the manifest's compiled set | Requirements 6.1 through 6.3, 7.14 through 7.16 |
//
// **There is no `outcome:` parameter anywhere in this file's public surface.** A caller cannot
// hand in a ``GateOutcome`` for a record gate or for a device gate; every one is computed.
// ``ReleaseGateEvidence/outcome`` is a computed property over the fields that carry the
// findings, so "a record claiming a passing gate beside a failing input" is not a state this
// module refuses — it is a state whose two halves are one expression.
//
// **Nothing here signs, approves, or decides.** The output is the canonical bytes a release
// owner signs plus the record and allowlist those bytes encode. This module selects no key,
// mints no approval, reaches no licensing or governance conclusion, and declares no
// distribution: ``EligibleRelease`` in the domain is the arbiter of eligibility and it consumes
// this output rather than being replaced by it. The one thing this module refuses to emit at
// all is a release output while any applicable mandatory gate is missing or failing, or while
// no candidate configuration passes — Requirements 14.15, 14.16, 14.17, and 13.22.

// MARK: - Bundle gate routing

extension ReleaseGate {
    /// The recorded bundle gates this record gate is computed from.
    ///
    /// Requirement 14.13 names six recorded results and `ReleaseGate` carries four bundle
    /// entries, so the mapping is stated once, here, and is total over
    /// ``BundleReleaseGate/allCases`` — no recorded result is dropped on the way into the
    /// record. Signature, per-artifact digests, and compatibility share one entry because all
    /// three answer "these are the approved bytes and they are compatible with this build";
    /// Requirement 10.12 already treats a failure of any of them identically.
    var contributingBundleGates: [BundleReleaseGate] {
        switch self {
        case .initialModelBundleSignature:
            [.releaseSignature, .perArtifactDigests, .compatibility]
        case .initialModelBundleSelfTests:
            [.releaseSelfTests]
        case .bundleActivation:
            [.atomicActivation]
        case .bundleRollback:
            [.verifiedRollback]
        default:
            []
        }
    }
}

// MARK: - The joined evidence

/// Everything one release record is assembled from.
///
/// Each of the twelve joined kinds is `Optional` where its absence is a real state this
/// repository is in, and absence is never equivalent to a pass: an absent kind yields
/// ``GateOutcome/notExecuted`` for every gate that reads it, records the release-controlled
/// input it is owed from, and blocks the release output.
///
/// The identifiers are not optional. A record answers for one application build, one capability
/// manifest, one Model Bundle, and one allowlist, and every one of those is read from the signed
/// manifest or supplied and reconciled against it — never chosen here.
public struct ReleaseRecordEvidence: Sendable {

    /// The identity this record is published under.
    public let recordID: ArtifactID
    public let schemaVersion: ArtifactSchemaVersion

    /// The signed capability manifest this record answers for.
    ///
    /// The single authority for the application build, the approved allowlist identifier, the
    /// compiled capability set, and the approved capability implementation versions. Because it
    /// is one value for the whole assembly, there is no per-entry application build to disagree
    /// with.
    public let capabilityManifest: ReleaseCapabilityManifest

    /// The Model Bundle this release distributes. Reconciled against the manifest's catalogue.
    public let modelBundle: ModelBundleID

    public let calibration: ApprovedCalibrationRelease?
    public let corpus: CorpusRemediation?
    public let bundle: BundleActivationEvidence?
    public let archive: ArchiveAuditReport?
    public let matrix: AccessibilityMatrixReport?

    /// One coherent evidence set per candidate configuration, possibly none.
    ///
    /// Possibly none is the state today. Each element already proved Requirement 13.20's tuple
    /// clause against this manifest, which is why the assembler can join them without
    /// re-deriving version agreement per gate.
    public let deviceEvidence: [CoherentDeviceEvidence]

    public let distributionRights: DistributionRightsRecord?
    public let modelGovernance: ModelGovernanceDecisionRecord?

    /// The published active-limitations document and correction channel (Requirement 14.14).
    public let activeLimitations: EvidenceSource?
    public let correctionChannel: EvidenceSource?

    /// Claims approved for publication with this release, possibly none.
    public let benchmarkClaims: [BenchmarkClaimRecord]

    /// The approved applicability decision for each conditional gate.
    ///
    /// Supplied, never constructed. Requirements 6.1 through 6.3 make the Provenance
    /// Feasibility outcome a recorded release decision and Requirements 7.15 and 7.16 do the
    /// same for fusion; this module has no way to mint either, and an absent entry is reported
    /// as an owed input rather than defaulted in one direction.
    public let conditionalApplicability: [ReleaseGate: GateApplicability]

    /// The immutable artifact each gate's result comes from (Requirement 14.1).
    ///
    /// Keyed by gate because that is the mapping the requirement asks for. Supplied, because
    /// this module cannot mint an artifact identifier, a version, or a content digest for
    /// evidence someone else produced; a gate with no entry names no evidence and cannot pass.
    public let gateCitations: [ReleaseGate: EvidenceSource]

    /// The release decision that approves the generated allowlist.
    ///
    /// An approved input. Requirement 13.18 adds a passing configuration to the allowlist and
    /// the allowlist itself is a signed artifact; which is a decision, so it arrives here.
    public let allowlistApproval: ApprovalRecord

    public init(
        recordID: ArtifactID,
        schemaVersion: ArtifactSchemaVersion,
        capabilityManifest: ReleaseCapabilityManifest,
        modelBundle: ModelBundleID,
        calibration: ApprovedCalibrationRelease?,
        corpus: CorpusRemediation?,
        bundle: BundleActivationEvidence?,
        archive: ArchiveAuditReport?,
        matrix: AccessibilityMatrixReport?,
        deviceEvidence: [CoherentDeviceEvidence],
        distributionRights: DistributionRightsRecord?,
        modelGovernance: ModelGovernanceDecisionRecord?,
        activeLimitations: EvidenceSource?,
        correctionChannel: EvidenceSource?,
        benchmarkClaims: [BenchmarkClaimRecord],
        conditionalApplicability: [ReleaseGate: GateApplicability],
        gateCitations: [ReleaseGate: EvidenceSource],
        allowlistApproval: ApprovalRecord
    ) {
        self.recordID = recordID
        self.schemaVersion = schemaVersion
        self.capabilityManifest = capabilityManifest
        self.modelBundle = modelBundle
        self.calibration = calibration
        self.corpus = corpus
        self.bundle = bundle
        self.archive = archive
        self.matrix = matrix
        self.deviceEvidence = deviceEvidence
        self.distributionRights = distributionRights
        self.modelGovernance = modelGovernance
        self.activeLimitations = activeLimitations
        self.correctionChannel = correctionChannel
        self.benchmarkClaims = benchmarkClaims
        self.conditionalApplicability = conditionalApplicability
        self.gateCitations = gateCitations
        self.allowlistApproval = allowlistApproval
    }

    /// The application build the whole assembly answers for.
    ///
    /// One value, read from the signed manifest. Every allowlist entry's tuple is compared
    /// against it, which is what makes two entries that disagree about the application build
    /// impossible to generate rather than merely detectable afterwards.
    public var appBuild: AppBuildID { capabilityManifest.appBuild }
}

// MARK: - The generated allowlist

/// The Release Approved iPhone Allowlist generated from coherent passing evidence.
///
/// One application build, read from the signed manifest and pinned here. Every admitted entry's
/// version tuple names that exact build, so two entries that disagree about it are not something
/// this type refuses — they are unreachable, because there is no per-entry build to disagree
/// with and no parameter that supplies one.
///
/// The allowlist may legitimately be empty. Emptiness is not an error and is not an approval
/// either: Requirement 13.22 blocks distribution when no configuration passes, which
/// ``permitsDistribution`` reports and which the release output refuses on.
public struct GeneratedDeviceAllowlist: Sendable {

    /// The one application build every admitted entry names.
    public let appBuild: AppBuildID

    /// The generated artifact.
    public let allowlist: ReleaseApprovedDeviceAllowlist

    /// The configurations that were admitted, in the allowlist's order.
    public let admitted: [ApprovedConfigurationID]

    /// Every candidate that was not admitted, and why (Requirements 13.19 and 13.21).
    public let excluded: [ExcludedDeviceConfiguration]

    init(
        appBuild: AppBuildID,
        allowlist: ReleaseApprovedDeviceAllowlist,
        admitted: [ApprovedConfigurationID],
        excluded: [ExcludedDeviceConfiguration]
    ) {
        self.appBuild = appBuild
        self.allowlist = allowlist
        self.admitted = admitted
        self.excluded = excluded
    }

    /// Whether any entry has every mandatory gate satisfied (Requirement 13.22).
    ///
    /// Equivalent to "the allowlist is nonempty" here, and deliberately so: the generator emits
    /// an entry only for a configuration whose 22 mandatory gates it computed as satisfied, so
    /// an admitted-but-unsatisfied entry is not representable. It reads the schema's own
    /// projection rather than restating that, so the two cannot drift.
    public var permitsDistribution: Bool { allowlist.permitsDistribution }

    /// Whether this generation admitted nothing. True today, on every configuration.
    public var isEmpty: Bool { allowlist.entries.isEmpty }
}

// MARK: - The assembler

/// Assembles one release record and its allowlist from typed evidence.
///
/// Stateless. It holds no approved value, no key designation, no default applicability, and no
/// artifact of its own, so two assemblies over the same evidence are identical and neither can
/// be influenced by something the caller did not supply.
public struct ReleaseRecordAssembler: Sendable {

    public init() {}

    /// Joins the evidence and generates the allowlist.
    ///
    /// Never throws. A release record's failures are its content: turning the first missing
    /// artifact into a thrown error would stop the assembly at the first gap and report nothing
    /// about the rest, which is exactly the partial evidence Requirement 14.1's *auditable*
    /// record exists to prevent. Refusal happens at ``AssembledReleaseRecord/releaseOutput()``,
    /// where a record becomes a distributable artifact.
    public func assemble(_ evidence: ReleaseRecordEvidence) -> AssembledReleaseRecord {
        let allowlist = generateAllowlist(from: evidence)
        var gates: [ReleaseGateEvidence] = []
        for gate in ReleaseGate.allCases {
            gates.append(gateEvidence(for: gate, in: evidence, allowlist: allowlist))
        }
        return AssembledReleaseRecord(
            evidence: evidence,
            gateEvidence: gates.sorted { $0.gate.rawValue < $1.gate.rawValue },
            allowlist: allowlist
        )
    }

    // MARK: Allowlist generation

    /// Emits one entry per configuration whose 22 mandatory device gates are all satisfied.
    ///
    /// Four admission rules, in the order an audit needs to hear them:
    ///
    ///   1. the evidence was produced on a physical iPhone (Requirement 13.16);
    ///   2. no earlier evidence set already claimed this configuration identity or this
    ///      hardware and operating-system pair, so one entry per configuration;
    ///   3. every mandatory device gate is satisfied, computed from the three runners' cells and
    ///      never from an entry's own `isSatisfied` (Requirements 13.18 and 13.19); and
    ///   4. the entry is representable — the schema's own reconciliation of configuration,
    ///      tuple, gate coverage, and conditional applicability succeeds.
    ///
    /// Rule 3 mints ``GateApplicability/applicable`` for the 21 unconditional device gates and
    /// carries the catalogued suite's approved decision for the one conditional gate. So a
    /// generated entry cannot contain a not-applicable reference for an unconditional gate,
    /// which is the shape that makes ``GateResultReference/isSatisfied`` report an entry where
    /// nothing ran as fully satisfied.
    private func generateAllowlist(
        from evidence: ReleaseRecordEvidence
    ) -> GeneratedDeviceAllowlist {
        let appBuild = evidence.appBuild
        var entries: [ApprovedDeviceConfiguration] = []
        var admitted: [ApprovedConfigurationID] = []
        var excluded: [ExcludedDeviceConfiguration] = []
        var seenIdentifiers: Set<String> = []
        var seenTriples: Set<String> = []

        for candidate in evidence.deviceEvidence {
            let identifier = candidate.configurationID
            let hardware = candidate.configuration.hardwareIdentifier
            let osVersion = candidate.configuration.osVersion
            let triple = "\(hardware.rawValue)@\(osVersion.description)/\(appBuild.rawValue)"

            func exclude(_ reason: DeviceExclusionReason) {
                excluded.append(
                    ExcludedDeviceConfiguration(
                        configurationID: identifier,
                        hardwareIdentifier: hardware,
                        osVersion: osVersion,
                        reason: reason
                    )
                )
            }

            guard candidate.runEnvironment.isPhysicalDeviceEvidence else {
                exclude(.notPhysicalDeviceEvidence(candidate.runEnvironment))
                continue
            }
            guard seenIdentifiers.insert(identifier.rawValue).inserted else {
                exclude(.duplicateConfigurationIdentity(identifier))
                continue
            }
            guard seenTriples.insert(triple).inserted else {
                exclude(.duplicateConfigurationTriple(hardware, osVersion))
                continue
            }
            let unsatisfied = candidate.unsatisfiedGates
            guard unsatisfied.isEmpty else {
                exclude(
                    .mandatoryGatesUnsatisfied(unsatisfied.sorted { $0.rawValue < $1.rawValue })
                )
                continue
            }
            let entry: ApprovedDeviceConfiguration
            do {
                entry = try Self.entry(for: candidate)
            } catch {
                exclude(.entryNotRepresentable("\(error)"))
                continue
            }
            entries.append(entry)
            admitted.append(identifier)
        }

        let artifact: ReleaseApprovedDeviceAllowlist
        do {
            artifact = try ReleaseApprovedDeviceAllowlist(
                id: evidence.capabilityManifest.approvedConfigurationAllowlist,
                schemaVersion: evidence.schemaVersion,
                entries: entries,
                approval: evidence.allowlistApproval
            )
        } catch {
            // Unreachable: the two uniqueness rules above are exactly the schema's, and the
            // admission loop enforced both before appending. Recorded as an empty allowlist with
            // every candidate excluded rather than trapping, because an assembly that cannot
            // produce an allowlist must still report why.
            for candidate in evidence.deviceEvidence {
                excluded.append(
                    ExcludedDeviceConfiguration(
                        configurationID: candidate.configurationID,
                        hardwareIdentifier: candidate.configuration.hardwareIdentifier,
                        osVersion: candidate.configuration.osVersion,
                        reason: .entryNotRepresentable("\(error)")
                    )
                )
            }
            return GeneratedDeviceAllowlist(
                appBuild: appBuild,
                allowlist: Self.emptyAllowlist(for: evidence),
                admitted: [],
                excluded: excluded
            )
        }
        return GeneratedDeviceAllowlist(
            appBuild: appBuild,
            allowlist: artifact,
            admitted: admitted,
            excluded: excluded
        )
    }

    /// One allowlist entry for one passing configuration.
    ///
    /// Every gate reference carries the environment the run reported, so a passing reference is
    /// refused by ``GateResultReference`` unless that environment is a physical iPhone. The
    /// admission loop already required it; keeping the schema check in the path means the
    /// barrier holds even if a future admission rule is relaxed.
    private static func entry(
        for candidate: CoherentDeviceEvidence
    ) throws -> ApprovedDeviceConfiguration {
        var references: [GateResultReference] = []
        for gate in DeviceGate.allCases.sorted(by: { $0.rawValue < $1.rawValue }) {
            references.append(
                try GateResultReference(
                    gate: gate,
                    applicability: candidate.applicability(of: gate),
                    outcome: candidate.outcome(of: gate),
                    result: candidate.resultCitation(for: gate),
                    environment: candidate.runEnvironment
                )
            )
        }
        return try ApprovedDeviceConfiguration(
            id: candidate.configurationID,
            configuration: candidate.configuration,
            versionTuple: candidate.versionTuple,
            gateEvidence: references
        )
    }

    /// An allowlist with no entries, for the unreachable generation failure above.
    private static func emptyAllowlist(
        for evidence: ReleaseRecordEvidence
    ) -> ReleaseApprovedDeviceAllowlist {
        // Safe: the schema's only refusals are the two uniqueness rules, and an empty entry list
        // satisfies both.
        try! ReleaseApprovedDeviceAllowlist(
            id: evidence.capabilityManifest.approvedConfigurationAllowlist,
            schemaVersion: evidence.schemaVersion,
            entries: [],
            approval: evidence.allowlistApproval
        )
    }

    // MARK: One gate

    private func gateEvidence(
        for gate: ReleaseGate,
        in evidence: ReleaseRecordEvidence,
        allowlist: GeneratedDeviceAllowlist
    ) -> ReleaseGateEvidence {
        var findings: [ReleaseRecordFinding] = []
        var owed: [UnprovisionedReleaseRecordInput] = []
        var produced = true
        var applicability = GateApplicability.applicable

        switch gate {
        case .calibrationSliceBudgets, .contemporaryPhoneCameraSlice, .populationSeparation:
            (produced, findings, owed) = Self.calibrationGate(gate, in: evidence)
        case .corpusIdentifierCorrection, .duplicateHashDisposition:
            (produced, findings, owed) = Self.corpusGate(gate, in: evidence)
        case .benchmarkClaimBindings:
            (produced, findings, owed) = Self.claimGate(in: evidence)
        case .initialModelBundleSignature, .initialModelBundleSelfTests, .bundleActivation,
             .bundleRollback:
            (produced, findings, owed) = Self.bundleGate(gate, in: evidence)
        case .privacyAudit, .archiveAudit, .dependencyNotices, .corpusExclusion:
            (produced, findings, owed) = Self.archiveGate(gate, in: evidence)
        case .accessibilityMatrix, .localizationReadinessMatrix:
            (produced, findings, owed) = Self.matrixGate(gate, in: evidence)
        case .deviceAllowlist:
            (produced, findings, owed) = Self.allowlistGate(in: evidence, allowlist: allowlist)
        case .fixtureSuiteCompleteness:
            (produced, findings, owed) = Self.fixtureGate(in: evidence)
        case .capabilityManifestMatch:
            (produced, findings, owed) = Self.capabilityGate(in: evidence)
        case .repositoryCodeLicense, .dataDistributionRights, .modelGovernanceDecision:
            (produced, findings, owed) = Self.externalGate(gate, in: evidence)
        case .activeLimitationsPublication, .correctionChannel:
            (produced, findings, owed) = Self.publicationGate(gate, in: evidence)
        case .provenanceFeasibility, .fusionRuleApproval:
            let conditional = Self.conditionalGate(gate, in: evidence)
            produced = conditional.produced
            findings = conditional.findings
            owed = conditional.owed
            applicability = conditional.applicability
        }

        let citation = evidence.gateCitations[gate]
        if citation == nil, !owed.contains(.releaseGateEvidenceCitation) {
            owed.append(.releaseGateEvidenceCitation)
        }
        return ReleaseGateEvidence(
            gate: gate,
            applicability: applicability,
            citation: citation,
            contributingKinds: gate.contributingEvidenceKinds,
            findings: findings,
            unprovisionedInputs: UnprovisionedReleaseRecordInput.allCases
                .filter { owed.contains($0) },
            evidenceWasProduced: produced
        )
    }

    // MARK: Calibration and corpus

    private static func calibrationGate(
        _ gate: ReleaseGate,
        in evidence: ReleaseRecordEvidence
    ) -> (Bool, [ReleaseRecordFinding], [UnprovisionedReleaseRecordInput]) {
        guard let calibration = evidence.calibration else {
            return (false, [.evidenceAbsent(.calibration)], [gate.owedReleaseRecordInput])
        }
        var findings: [ReleaseRecordFinding] = []
        // Holding an `ApprovedCalibrationRelease` already means every mandatory slice is inside
        // the False Accusation Budget under the predeclared confidence-interval rule and that
        // population separation was verified: the approval refuses rather than reporting a
        // status. So the only thing left to check per gate is the one clause its type cannot
        // carry — Requirement 5.20's dedicated contemporary phone-camera slice, which is a
        // property of the slice *set* rather than of any one measurement.
        if gate == .contemporaryPhoneCameraSlice, calibration.contemporaryPhoneCameraSlices.isEmpty
        {
            findings.append(.mandatoryGatingSliceAbsent("contemporary-phone-camera"))
        }
        if calibration.modelBundle != evidence.modelBundle {
            findings.append(
                .bundleEvidenceNamesAnotherBundle(
                    expected: evidence.modelBundle,
                    found: calibration.modelBundle
                )
            )
        }
        return (true, findings, [])
    }

    private static func corpusGate(
        _ gate: ReleaseGate,
        in evidence: ReleaseRecordEvidence
    ) -> (Bool, [ReleaseRecordFinding], [UnprovisionedReleaseRecordInput]) {
        guard evidence.corpus != nil else {
            return (false, [.evidenceAbsent(.calibration)], [gate.owedReleaseRecordInput])
        }
        // A `CorpusRemediation` exists only for a run that reconciled the 13 collisions against
        // the approved correction, proved the corrected identifiers unique, and reconciled the
        // four duplicate hashes against the approved disposition. Both gates are that run.
        return (true, [], [])
    }

    private static func claimGate(
        in evidence: ReleaseRecordEvidence
    ) -> (Bool, [ReleaseRecordFinding], [UnprovisionedReleaseRecordInput]) {
        var owed: [UnprovisionedReleaseRecordInput] = []
        var findings: [ReleaseRecordFinding] = []
        var produced = true
        if evidence.calibration == nil {
            produced = false
            findings.append(.evidenceAbsent(.calibration))
            owed.append(.approvedCalibrationRelease)
        }
        guard let limitations = evidence.activeLimitations,
              let channel = evidence.correctionChannel
        else {
            findings.append(.evidenceAbsent(.limitationAndCorrectionChannel))
            owed.append(.publishedLimitationsAndCorrectionChannel)
            return (false, findings, owed)
        }
        // The bindings come from the release, not from the claim, so a claim cannot nominate its
        // own bundle, policy, limitations document, or correction channel (Requirements 8.16 and
        // 14.12). An empty claim list is valid and means this release publishes no claim.
        let policy = evidence.capabilityManifest.policyCompatibility.calibrationPolicy
        for claim in evidence.benchmarkClaims {
            if claim.modelBundle != evidence.modelBundle {
                findings.append(.claimBindingMismatch(claim.id, field: "modelBundle"))
            }
            if claim.calibrationPolicy != policy {
                findings.append(.claimBindingMismatch(claim.id, field: "calibrationPolicy"))
            }
            if claim.activeLimitations != limitations {
                findings.append(.claimBindingMismatch(claim.id, field: "activeLimitations"))
            }
            if claim.correctionChannel != channel {
                findings.append(.claimBindingMismatch(claim.id, field: "correctionChannel"))
            }
        }
        // Requirement 14.7 forbids using a regenerated comparison in a release claim before
        // every affected artifact is regenerated, and task 14.7 reports which regenerated
        // comparisons name an entry the approved dispositions excluded. A release that publishes
        // a claim while any of those stand is publishing over an unresolved corpus.
        if !evidence.benchmarkClaims.isEmpty, let corpus = evidence.corpus {
            let standing = corpus.comparisonsNamingExcludedEntries.count
            if standing > 0 {
                findings.append(.claimRestsOnExcludedCorpusEntry(count: standing))
            }
        }
        return (produced, findings, owed)
    }

    // MARK: Bundle

    private static func bundleGate(
        _ gate: ReleaseGate,
        in evidence: ReleaseRecordEvidence
    ) -> (Bool, [ReleaseRecordFinding], [UnprovisionedReleaseRecordInput]) {
        guard let bundle = evidence.bundle else {
            return (false, [.evidenceAbsent(.bundle)], [gate.owedReleaseRecordInput])
        }
        var findings: [ReleaseRecordFinding] = []
        if bundle.bundleID != evidence.modelBundle {
            findings.append(
                .bundleEvidenceNamesAnotherBundle(
                    expected: evidence.modelBundle,
                    found: bundle.bundleID
                )
            )
        }
        for recorded in gate.contributingBundleGates {
            let outcome = bundle.outcome(of: recorded)
            guard outcome.isPassing else {
                findings.append(
                    .contributingResultFailed(
                        .bundle,
                        detail: "\(recorded.rawValue) recorded \(outcome.rawValue)"
                    )
                )
                continue
            }
        }
        return (true, findings, [])
    }

    // MARK: Archive and privacy

    private static func archiveGate(
        _ gate: ReleaseGate,
        in evidence: ReleaseRecordEvidence
    ) -> (Bool, [ReleaseRecordFinding], [UnprovisionedReleaseRecordInput]) {
        guard let archive = evidence.archive else {
            return (false, [.evidenceAbsent(.archive)], [gate.owedReleaseRecordInput])
        }
        guard let recorded = archive.gates.first(where: { $0.gate == gate }) else {
            // Unreachable through `ArchiveAuditReport.decode`, which refuses a report omitting
            // any gate this audit produces evidence for. Recorded as a failing input rather than
            // ignored, because a gate this module cannot find evidence for is not a gate that
            // passed.
            return (true, [.evidenceAbsent(.archive)], [])
        }
        var findings: [ReleaseRecordFinding] = []
        let kind: ReleaseRecordEvidenceKind = gate == .privacyAudit ? .privacy : .archive
        // The audit's own identifiers, verbatim. A translation table from its two vocabularies
        // into this one would be a second place the classes are written down, and a class that
        // existed in one and not the other would be a finding nobody could route.
        for finding in recorded.findings {
            findings.append(
                .contributingResultFailed(
                    kind,
                    detail: "\(finding.failingInputClass.rawValue): \(finding.detail)"
                )
            )
        }
        for input in recorded.unprovisionedInputs {
            findings.append(.contributingResultFailed(kind, detail: input.rawValue))
        }
        return (archive.archivesInspected, findings, [])
    }

    // MARK: Accessibility and localization

    private static func matrixGate(
        _ gate: ReleaseGate,
        in evidence: ReleaseRecordEvidence
    ) -> (Bool, [ReleaseRecordFinding], [UnprovisionedReleaseRecordInput]) {
        guard let matrix = evidence.matrix else {
            return (false, [.evidenceAbsent(.accessibility)], [gate.owedReleaseRecordInput])
        }
        let deviceGate: DeviceGate = gate == .accessibilityMatrix
            ? .accessibilityMatrix
            : .localizationReadinessMatrix
        let kind: ReleaseRecordEvidenceKind = gate == .accessibilityMatrix
            ? .accessibility
            : .localization
        var findings: [ReleaseRecordFinding] = []
        let outcome = matrix.outcome(of: deviceGate)
        if !outcome.isPassing {
            let unsatisfied = matrix.configurationReports
                .flatMap { $0.gateResult(for: deviceGate).cells }
                .filter { cell in
                    matrix.configurationReports.contains {
                        $0.requiredCells.contains(cell) && !$0.outcome(of: cell).isSatisfied
                    }
                }
            findings.append(
                .contributingResultFailed(
                    kind,
                    detail: "\(unsatisfied.count) unsatisfied matrix positions across "
                        + "\(matrix.coveredConfigurations.count) configurations"
                )
            )
        }
        for input in matrix.owedInputs {
            findings.append(.contributingResultFailed(kind, detail: input.rawValue))
        }
        return (!matrix.configurationReports.isEmpty, findings, [])
    }

    // MARK: Devices, fixtures, capabilities

    private static func allowlistGate(
        in evidence: ReleaseRecordEvidence,
        allowlist: GeneratedDeviceAllowlist
    ) -> (Bool, [ReleaseRecordFinding], [UnprovisionedReleaseRecordInput]) {
        guard !evidence.deviceEvidence.isEmpty else {
            return (
                false,
                [.evidenceAbsent(.device), .noPassingDeviceConfiguration],
                [.coherentPhysicalDeviceEvidenceSet]
            )
        }
        var findings: [ReleaseRecordFinding] = []
        for exclusion in allowlist.excluded {
            findings.append(
                .deviceConfigurationExcluded(exclusion.configurationID, exclusion.reason)
            )
        }
        if !allowlist.permitsDistribution {
            findings.append(.noPassingDeviceConfiguration)
        }
        return (true, findings, [])
    }

    private static func fixtureGate(
        in evidence: ReleaseRecordEvidence
    ) -> (Bool, [ReleaseRecordFinding], [UnprovisionedReleaseRecordInput]) {
        let catalogs = evidence.deviceEvidence.map(\.catalog)
        guard let first = catalogs.first else {
            return (
                false,
                [.evidenceAbsent(.fixture)],
                [ReleaseGate.fixtureSuiteCompleteness.owedReleaseRecordInput]
            )
        }
        var findings: [ReleaseRecordFinding] = []
        var seenFamilies: Set<FixtureFamily> = []
        for catalog in catalogs {
            for family in catalog.suite.missingFamilies where seenFamilies.insert(family).inserted {
                findings.append(.fixtureFamilyAbsent(family))
            }
        }
        if !first.suite.hasCompleteModelParityCoverage {
            findings.append(
                .modelParityCoverageIncomplete(
                    observed: first.suite.fixtures(in: .modelParity).count,
                    required: ReleaseFixtureSuite.requiredModelParityFixtureCount
                )
            )
        }
        return (true, findings, [])
    }

    private static func capabilityGate(
        in evidence: ReleaseRecordEvidence
    ) -> (Bool, [ReleaseRecordFinding], [UnprovisionedReleaseRecordInput]) {
        var findings: [ReleaseRecordFinding] = []
        let manifest = evidence.capabilityManifest
        // Read, never derived. An unapproved capability set authorizes no distribution to gate.
        if !manifest.approval.isApproved {
            findings.append(.externalDecisionRejected(.capability))
        }
        if !manifest.approvedBundleCatalog.contains(evidence.modelBundle) {
            findings.append(.modelBundleOutsideApprovedCatalog(evidence.modelBundle))
        }
        // Every supplied device evidence set already reconciled its whole version tuple against
        // this manifest, including the capability implementation versions, so this gate has
        // nothing left to compare there: `CoherentDeviceEvidence` cannot exist otherwise.
        return (true, findings, [])
    }

    // MARK: External conclusions and publications

    private static func externalGate(
        _ gate: ReleaseGate,
        in evidence: ReleaseRecordEvidence
    ) -> (Bool, [ReleaseRecordFinding], [UnprovisionedReleaseRecordInput]) {
        let kind: ReleaseRecordEvidenceKind = gate == .modelGovernanceDecision
            ? .governance
            : .legal
        let approval: ApprovalRecord?
        switch gate {
        case .repositoryCodeLicense:
            approval = evidence.distributionRights?.repositoryCodeLicense
        case .dataDistributionRights:
            approval = evidence.distributionRights?.datasetDistributionTerms
        default:
            approval = evidence.modelGovernance?.decision
        }
        guard let approval else {
            return (false, [.evidenceAbsent(kind)], [gate.owedReleaseRecordInput])
        }
        // The only thing this module does with a legal, data-rights, or governance record is
        // read its decision. Nothing derives one, and a present record is never a favorable one.
        guard approval.isApproved else {
            return (true, [.externalDecisionRejected(kind)], [])
        }
        return (true, [], [])
    }

    private static func publicationGate(
        _ gate: ReleaseGate,
        in evidence: ReleaseRecordEvidence
    ) -> (Bool, [ReleaseRecordFinding], [UnprovisionedReleaseRecordInput]) {
        let published = gate == .activeLimitationsPublication
            ? evidence.activeLimitations
            : evidence.correctionChannel
        guard published != nil else {
            return (
                false,
                [.evidenceAbsent(.limitationAndCorrectionChannel)],
                [gate.owedReleaseRecordInput]
            )
        }
        return (true, [], [])
    }

    // MARK: Conditional capabilities

    private static func conditionalGate(
        _ gate: ReleaseGate,
        in evidence: ReleaseRecordEvidence
    ) -> (
        applicability: GateApplicability,
        produced: Bool,
        findings: [ReleaseRecordFinding],
        owed: [UnprovisionedReleaseRecordInput]
    ) {
        let manifest = evidence.capabilityManifest
        let compiled = gate == .provenanceFeasibility
            ? manifest.enablesProvenance
            : manifest.enablesFusion
        guard let declared = evidence.conditionalApplicability[gate] else {
            // Absent is not "disabled". Requirement 6.1 evaluates the gate before the capability
            // set is chosen and Requirement 6.3 permits a pixel-only release *by decision*, so
            // an absent decision is an owed input rather than a default in either direction —
            // and this module cannot supply one.
            return (
                .applicable,
                false,
                [.evidenceAbsent(.capability)],
                [.conditionalCapabilityApplicabilityDecision]
            )
        }
        var findings: [ReleaseRecordFinding] = []
        // Both directions are faults. A provenance-enabled build recording the gate as waived
        // ships a capability with no gate behind it; a pixel-only build recording it as
        // applicable carries evidence for a lane it does not have.
        if declared.isApplicable != compiled {
            findings.append(
                .conditionalApplicabilityDisagreesWithManifest(
                    gate,
                    compiled: compiled,
                    declared: declared.isApplicable
                )
            )
        }
        guard declared.isApplicable else {
            // The one legitimate `notExecuted` path: the derived outcome is not executed and
            // satisfaction is the carried decision's approval, read rather than assumed.
            return (declared, true, findings, [])
        }
        let backed: Bool
        if gate == .provenanceFeasibility {
            backed = manifest.policyCompatibility.provenancePolicy.isBound
                && evidence.deviceEvidence.contains { $0.isSatisfied(.provenanceFixtures) }
        } else {
            backed = manifest.policyCompatibility.fusionRule.isBound
                && evidence.deviceEvidence.contains { candidate in
                    guard let coverage = candidate.catalog.fusionCoverage.boundReference else {
                        return false
                    }
                    return coverage.approval.isApproved
                }
        }
        if !backed {
            findings.append(.conditionalCapabilityUnbacked(gate))
        }
        return (declared, true, findings, [])
    }
}

// MARK: - The assembled record

/// One release record, assembled and reporting honestly.
///
/// Holding this value means the twelve evidence kinds were joined and every gate outcome was
/// computed from them. It does **not** mean the release is distributable: that is
/// ``releaseOutput()``, which refuses while any applicable mandatory gate is missing or failing
/// or while no candidate configuration passes.
///
/// Nothing here can be repaired, waived, or filled in. There is no mutating member, no
/// `override`, and no initialiser that accepts a gate outcome.
public struct AssembledReleaseRecord: Sendable {

    /// The evidence this record was assembled from, unchanged.
    public let evidence: ReleaseRecordEvidence

    /// One entry per mandatory release gate, each gate exactly once, ordered by identifier.
    public let gateEvidence: [ReleaseGateEvidence]

    /// The allowlist generated from the coherent passing tuples.
    public let allowlist: GeneratedDeviceAllowlist

    init(
        evidence: ReleaseRecordEvidence,
        gateEvidence: [ReleaseGateEvidence],
        allowlist: GeneratedDeviceAllowlist
    ) {
        self.evidence = evidence
        self.gateEvidence = gateEvidence
        self.allowlist = allowlist
    }

    /// The application build this record answers for. One, read from the signed manifest.
    public var appBuild: AppBuildID { evidence.appBuild }

    /// The evidence for one gate. Total by construction: the assembler enumerates
    /// ``ReleaseGate/allCases``.
    public func gate(_ gate: ReleaseGate) -> ReleaseGateEvidence {
        // Safe: one entry per case, produced by the only assembler there is.
        gateEvidence.first { $0.gate == gate }!
    }

    /// Applicable mandatory gates whose result is missing (Requirement 14.15).
    public var unresolvedMandatoryGates: Set<ReleaseGate> {
        Set(
            gateEvidence
                .filter { $0.applicability.isApplicable && $0.outcome == .notExecuted }
                .map(\.gate)
        )
    }

    /// Mandatory gates that are not satisfied and did produce a result, plus conditional gates
    /// whose inapplicability decision is a rejection.
    public var failingMandatoryGates: Set<ReleaseGate> {
        Set(
            gateEvidence
                .filter { !$0.isSatisfied && $0.outcome != .notExecuted }
                .map(\.gate)
        )
            .union(
                gateEvidence
                    .filter { !$0.applicability.isApplicable && !$0.isSatisfied }
                    .map(\.gate)
            )
    }

    /// Gates naming no evidence artifact at all, so Requirement 14.1's mapping is unwritable.
    public var gatesNamingNoEvidence: Set<ReleaseGate> {
        Set(gateEvidence.filter { $0.citation == nil }.map(\.gate))
    }

    /// The hard public-launch blockers among the unresolved and failing gates
    /// (Requirements 14.16 and 14.17).
    ///
    /// Changes no outcome — Requirement 14.15 already blocks on any applicable mandatory entry —
    /// and exists so an audit hears which hard blocker refused instead of "a gate failed".
    public var blockingHardPublicLaunchBlockers: Set<ReleaseGate> {
        ReleaseGate.hardPublicLaunchBlockers
            .intersection(unresolvedMandatoryGates.union(failingMandatoryGates))
    }

    /// Every release-controlled input this record is still owed, in declaration order.
    public var unprovisionedInputs: [UnprovisionedReleaseRecordInput] {
        var owed = Set<UnprovisionedReleaseRecordInput>()
        for entry in gateEvidence { owed.formUnion(entry.unprovisionedInputs) }
        return UnprovisionedReleaseRecordInput.allCases.filter { owed.contains($0) }
    }

    /// Every standing limit this record's claims are qualified by, in declaration order.
    ///
    /// Reported whatever the gate outcomes, because each is a property of the available
    /// artifacts rather than of one assembly. Three apply to every record; the two measured ones
    /// apply when the record carries the evidence they qualify.
    public var standingLimits: [UnobservableReleaseRecordEvidence] {
        var applicable: Set<UnobservableReleaseRecordEvidence> = [
            .signatureStandInVerifiesUnderEveryDeclaredAlgorithm,
            .noJointlySatisfiableMandatoryDeviceGateSetExists,
            .dataLifecycleDeadlinesAreNotBoundToAnyRecordGate,
        ]
        if !evidence.benchmarkClaims.isEmpty {
            applicable.insert(.publishedClaimCoverageIsNotReconciledAgainstSliceMeasurements)
        }
        if !evidence.deviceEvidence.isEmpty {
            applicable.insert(
                .recordCompletenessStatisticsCountReturnedRatherThanQualifyingSamples
            )
        }
        return UnobservableReleaseRecordEvidence.allCases.filter { applicable.contains($0) }
    }

    /// Whether every applicable mandatory gate is satisfied and some configuration passes.
    ///
    /// The direct reading of Requirements 14.15 and 13.22, and the only member here that answers
    /// a distribution question. It answers `false` today, for reasons the gate entries name one
    /// at a time.
    public var permitsDistribution: Bool {
        unresolvedMandatoryGates.isEmpty
            && failingMandatoryGates.isEmpty
            && gatesNamingNoEvidence.isEmpty
            && allowlist.permitsDistribution
    }

    /// Whether provenance is part of this release, by explicit applicability.
    public var enablesProvenance: Bool {
        gate(.provenanceFeasibility).applicability.isApplicable
    }

    /// Whether a Combined Summary is part of this release, by explicit applicability.
    ///
    /// Preserved from the supplied decision and the manifest's compiled set rather than
    /// collapsed into the provenance answer. Requirement 7.10 forbids fusion without an
    /// available provenance lane and ``ReleaseReadinessRecord`` enforces that coupling; what is
    /// kept here is that the two remain two separate recorded decisions.
    public var enablesFusion: Bool {
        gate(.fusionRuleApproval).applicability.isApplicable
    }

    // MARK: Release output

    /// The signed-record payload, or a refusal naming what blocks it.
    ///
    /// Six refusals, in the order an audit needs to hear them: a gate naming no evidence, an
    /// unresolved mandatory gate, a failing mandatory gate, a hard public-launch blocker, no
    /// passing device configuration, and the release-controlled inputs still owed. The first one
    /// that applies is thrown, so an audit reads one position rather than "release blocked".
    ///
    /// A release output is therefore not something this module produces and then labels
    /// unusable. It is a value that does not exist while anything blocks — which is what
    /// "block release output" means in Requirements 14.15 and 13.22.
    public func releaseOutput() throws -> ReleaseRecordOutput {
        let unwritable = gatesNamingNoEvidence
        guard unwritable.isEmpty else {
            throw ReleaseRecordOutputRefusal.gateNamesNoEvidence(
                unwritable.sorted { $0.rawValue < $1.rawValue }
            )
        }
        let unresolved = unresolvedMandatoryGates
        guard unresolved.isEmpty else {
            throw ReleaseRecordOutputRefusal.mandatoryGatesUnresolved(
                unresolved.sorted { $0.rawValue < $1.rawValue }
            )
        }
        let failing = failingMandatoryGates
        guard failing.isEmpty else {
            throw ReleaseRecordOutputRefusal.mandatoryGatesFailing(
                failing.sorted { $0.rawValue < $1.rawValue }
            )
        }
        let blockers = blockingHardPublicLaunchBlockers
        guard blockers.isEmpty else {
            throw ReleaseRecordOutputRefusal.hardPublicLaunchBlocker(
                blockers.sorted { $0.rawValue < $1.rawValue }
            )
        }
        guard allowlist.permitsDistribution else {
            throw ReleaseRecordOutputRefusal.noPassingDeviceConfiguration
        }
        let owed = unprovisionedInputs
        guard owed.isEmpty else {
            throw ReleaseRecordOutputRefusal.unprovisionedInputs(owed)
        }
        guard let rights = evidence.distributionRights,
              let governance = evidence.modelGovernance
        else {
            // Unreachable: the three externally decided gates are unresolved without these two
            // records, and an unresolved mandatory gate already refused above.
            throw ReleaseRecordOutputRefusal.unprovisionedInputs(
                [.approvedDistributionRightsRecords, .recordedModelGovernanceDecision]
            )
        }
        let record = try ReleaseReadinessRecord(
            id: evidence.recordID,
            schemaVersion: evidence.schemaVersion,
            appBuild: appBuild,
            capabilityManifest: evidence.capabilityManifest.id,
            modelBundle: evidence.modelBundle,
            deviceAllowlist: evidence.capabilityManifest.approvedConfigurationAllowlist,
            gateRecords: try gateEvidence.map { try $0.releaseGateRecord() },
            distributionRights: rights,
            modelGovernance: governance,
            benchmarkClaims: evidence.benchmarkClaims
        )
        return ReleaseRecordOutput(
            record: record,
            allowlist: allowlist.allowlist,
            canonicalRecordBytes: try CanonicalArtifactEncoding.canonicalBytes(of: record),
            canonicalAllowlistBytes: try CanonicalArtifactEncoding.canonicalBytes(
                of: allowlist.allowlist
            ),
            standingLimits: standingLimits
        )
    }
}

// MARK: - The payload

/// The release-record payload a release owner signs.
///
/// Two artifacts and their canonical bytes. The bytes are what a signature would cover, and
/// they are produced by the module's one writer so two assemblies over the same evidence are
/// byte-identical and a published record is comparable as bytes rather than by inspection.
///
/// **Nothing here is signed and nothing here selects a key.** The signature construction
/// available in this repository digests the key bytes concatenated with the message, so one
/// value verifies under every algorithm the schema can name; treating a verification pass over
/// it as cryptographic evidence would be wrong, and
/// ``UnobservableReleaseRecordEvidence/signatureStandInVerifiesUnderEveryDeclaredAlgorithm`` is
/// carried in ``standingLimits`` so a record states that rather than implying otherwise.
///
/// Constructible only inside this module, and only by an assembly that nothing blocked.
public struct ReleaseRecordOutput: Sendable {
    public let record: ReleaseReadinessRecord
    public let allowlist: ReleaseApprovedDeviceAllowlist
    public let canonicalRecordBytes: [UInt8]
    public let canonicalAllowlistBytes: [UInt8]

    /// What this payload would not establish even though nothing blocked its emission.
    public let standingLimits: [UnobservableReleaseRecordEvidence]

    init(
        record: ReleaseReadinessRecord,
        allowlist: ReleaseApprovedDeviceAllowlist,
        canonicalRecordBytes: [UInt8],
        canonicalAllowlistBytes: [UInt8],
        standingLimits: [UnobservableReleaseRecordEvidence]
    ) {
        self.record = record
        self.allowlist = allowlist
        self.canonicalRecordBytes = canonicalRecordBytes
        self.canonicalAllowlistBytes = canonicalAllowlistBytes
        self.standingLimits = standingLimits
    }

    /// The allowlisted configuration identifiers, in the allowlist's order.
    public var allowlistedConfigurations: [ApprovedConfigurationID] {
        allowlist.entries.map(\.id)
    }
}
