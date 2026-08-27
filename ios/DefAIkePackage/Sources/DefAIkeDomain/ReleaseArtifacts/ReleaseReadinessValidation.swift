import Foundation

// Release-eligibility validation of the Release Readiness Record and the claims it
// publishes.
//
// This is the last fail-closed layer, and the layers below it cannot see what it checks:
//
//   * ``ReleaseGateRecord`` validates one entry: an unconditional gate cannot be declared
//     not applicable, and a not-applicable gate cannot carry an executed result.
//   * ``ReleaseReadinessRecord`` validates one artifact: every mandatory gate exactly
//     once, unique claim identifiers, and a fusion gate that cannot be applicable while
//     provenance is not. It reports ``unresolvedMandatoryGates`` and
//     ``failingMandatoryGates`` and deliberately decides nothing.
//   * ``BenchmarkClaimRecord`` makes each of Requirement 8.16's bindings a non-optional
//     field, so a claim missing one of them cannot be represented.
//   * ``ValidatedAccessibilityGateMatrix`` validates the two matrix gates against the
//     signed allowlist, and ``ValidatedResourcePlan`` validates the limits.
//
// What none of them can decide:
//
//   * Whether the record answers for an approved capability set, at the build, bundle,
//     and allowlist this release ships. Every identifier is a free field, so a record can
//     name a manifest nobody approved or a bundle outside the approved catalog and still
//     read as a complete record.
//   * Whether a gate's cited evidence exists. A gate carries an ``EvidenceSource``, and a
//     reference is not a record: an artifact identifier at a version and digest the
//     release does not carry names no result at all (Requirement 14.1).
//   * Whether a conditional gate's applicability is the one the signed manifest compiled.
//     Applicability is self-declared, so a provenance-enabled build can record the
//     provenance gate as waived, or a pixel-only build can record it as applicable and
//     passing — the first ships an unvalidated capability, the second is evidence for a
//     lane this build does not have (Requirement 6.2, design Property 33).
//   * Whether the legal and governance gates agree with the records that decide them. A
//     gate outcome is a separate field from the ``ApprovalRecord`` it is supposed to
//     report, so a record can mark the license gate passed while the license decision it
//     carries is a rejection.
//   * Whether a published claim's counts, coverage, and interval are measurements. Every
//     binding can be present while the sample count is zero, coverage is zero, and the
//     "interval" is a point value, which is a claim with no measured support at all
//     (Requirements 8.16 and 14.12).
//
// ``EligibleRelease`` is the only way to hold a record that passed all of it, so "release
// is eligible" is a type rather than a convention, and ``ValidatedBenchmarkClaim`` is the
// only way to hold a claim approved for publication.
//
// Deliberately absent: any way to reach a legal, data-rights, or governance conclusion.
// Those three gates are decided by externally supplied ``ApprovalRecord`` values that this
// code reads and never derives, and a missing or rejected one blocks eligibility
// (Requirements 14.2 through 14.4, 14.9, 14.10, and 14.17). There is also no applicability
// default, no synthesized approval, and no path by which a missing, unknown, or absent
// result becomes a pass or becomes "not applicable".

// MARK: - Gate classification

extension ReleaseGate {
    /// Whether this gate's result is a conclusion only an external record may reach.
    ///
    /// Requirements 14.2 through 14.4 reserve the repository code license and the dataset
    /// and benchmark distribution terms for their written approvals, and Requirements 14.9
    /// and 14.10 reserve the Lowq governance and red-team risk decision for a recorded
    /// release-owner decision. The three are listed rather than inferred, because the
    /// point is that no code path — including a future one that reads a gate's evidence —
    /// may compute them: validation compares the gate against the carried
    /// ``ApprovalRecord`` and stops.
    public var isExternallyDecided: Bool {
        switch self {
        case .repositoryCodeLicense, .dataDistributionRights, .modelGovernanceDecision: true
        default: false
        }
    }

    /// Gates the requirements name as hard public-launch blockers.
    ///
    /// Requirement 14.16 makes a missing or failing signed Initial Model Bundle integrity,
    /// self-test, activation, or rollback gate a blocker, and Requirement 14.17 does the
    /// same for the Lowq governance decision. Requirement 14.15 already blocks on any
    /// applicable mandatory entry, so this set changes no outcome; it exists so an audit
    /// hears which hard blocker refused instead of "a gate failed".
    public static var hardPublicLaunchBlockers: Set<ReleaseGate> {
        [
            .initialModelBundleSignature,
            .initialModelBundleSelfTests,
            .bundleActivation,
            .bundleRollback,
            .modelGovernanceDecision,
        ]
    }
}

// MARK: - Claim sample counts

extension SliceOutcomeCounts {
    /// Eligible images behind a measurement, both ground-truth populations pooled.
    ///
    /// Requirement 5.18 defines coverage over eligible images without splitting them by
    /// population, so the pooled count is the denominator a claim's coverage refers to.
    var eligibleImageCount: Int {
        eligibleRealImages.value + eligibleSyntheticImages.value
    }

    /// Eligible images that received a decisive label (Requirement 5.18).
    ///
    /// The insufficient outcomes are excluded from the numerator and stay inside the
    /// denominator, which is what keeps abstention from inflating coverage.
    var decisiveLabelCount: Int {
        realPositiveLabels.value + realNonPositiveLabels.value
            + syntheticPositiveLabels.value + syntheticNonPositiveLabels.value
    }
}

// MARK: - Validated benchmark claim

/// One benchmark or evidence claim approved for publication with this release.
///
/// Holding this value means every binding Requirements 8.16 and 14.12 list resolves to
/// evidence this release carries, the model, Model Bundle, and Calibration Policy are the
/// ones this release ships, the limitations and correction channel are the ones it
/// publishes, and the counts, coverage, and uncertainty interval are measurements rather
/// than zeroes and a point value.
///
/// Nothing here computes a rate, an interval, or a coverage value. The claim's numbers
/// come from the evidence run it cites; validation refuses numbers that cannot be
/// measurements of anything.
public struct ValidatedBenchmarkClaim: Hashable, Sendable {
    /// The claim, unchanged. Validation never repairs, normalizes, or fills a field.
    public let claim: BenchmarkClaimRecord

    /// Validates `claim` against the artifacts and evidence this release binds.
    ///
    /// Fails closed with one ``ArtifactSchemaError`` naming the offending field, so an
    /// audit can point at one binding rather than reporting "unpublishable claim". A
    /// failure is never an ``AnalysisError``: a claim that does not validate stays
    /// unpublished instead of reaching a user-facing surface.
    public init(
        validating claim: BenchmarkClaimRecord,
        modelBundle: ModelBundleID,
        calibrationPolicy: ArtifactID,
        activeLimitations: EvidenceSource,
        correctionChannel: EvidenceSource,
        evidence index: ReleaseEvidenceIndex
    ) throws {
        let field = "claim[\(claim.id.rawValue)]"
        try ArtifactSchemaValidation.requireDecidedReference(claim.id, field: "\(field).id")
        try Self.validateBindings(
            claim,
            modelBundle: modelBundle,
            calibrationPolicy: calibrationPolicy,
            activeLimitations: activeLimitations,
            correctionChannel: correctionChannel,
            field: field
        )
        try Self.validateEvidence(claim, field: field, against: index)
        try Self.validateMeasurement(claim, field: field)
        self.claim = claim
    }

    // MARK: Bindings

    /// Requirements 8.16 and 14.12: the claim describes the release that publishes it.
    ///
    /// A claim measured on another model, bundle, or Calibration Policy is a measurement
    /// of different code or different thresholds, and Requirement 8.12 exposes the bound
    /// versions next to the verdict, so a claim citing other ones contradicts what the app
    /// reports about itself. The limitations and correction channel are pinned to the ones
    /// the release-readiness record publishes (Requirement 14.14): a claim pointing at a
    /// limitations document or a channel this release does not publish sends a user
    /// somewhere the release does not go.
    private static func validateBindings(
        _ claim: BenchmarkClaimRecord,
        modelBundle: ModelBundleID,
        calibrationPolicy: ArtifactID,
        activeLimitations: EvidenceSource,
        correctionChannel: EvidenceSource,
        field: String
    ) throws {
        guard claim.modelIdentity == RequiredPixelModel.identity else {
            throw ArtifactSchemaError.inconsistentReference(
                field: "\(field).modelIdentity",
                expected: RequiredPixelModel.checkpointIdentifier,
                found: claim.modelIdentity.checkpointIdentifier.rawValue
            )
        }
        try ArtifactSchemaValidation.requireMatchingReference(
            claim.modelBundle,
            matches: modelBundle,
            field: "\(field).modelBundle"
        )
        try ArtifactSchemaValidation.requireMatchingReference(
            claim.calibrationPolicy,
            matches: calibrationPolicy,
            field: "\(field).calibrationPolicy"
        )
        guard claim.activeLimitations == activeLimitations else {
            throw ArtifactSchemaError.inconsistentReference(
                field: "\(field).activeLimitations",
                expected: activeLimitations.artifact.rawValue
                    + "@\(activeLimitations.version.description)",
                found: claim.activeLimitations.artifact.rawValue
                    + "@\(claim.activeLimitations.version.description)"
            )
        }
        guard claim.correctionChannel == correctionChannel else {
            throw ArtifactSchemaError.inconsistentReference(
                field: "\(field).correctionChannel",
                expected: correctionChannel.artifact.rawValue
                    + "@\(correctionChannel.version.description)",
                found: claim.correctionChannel.artifact.rawValue
                    + "@\(claim.correctionChannel.version.description)"
            )
        }
    }

    // MARK: Evidence

    /// Requirements 8.16 and 14.12: every cited record exists at the version and digest
    /// cited.
    ///
    /// Seven separate references, checked separately so an audit hears which binding is
    /// unresolvable. The dataset and its composition are two questions — a dataset
    /// identifier says which corpus, the composition record says what is in it — and so
    /// are the metric definition and the evidence run: the first says what was computed,
    /// the second says which run computed it.
    private static func validateEvidence(
        _ claim: BenchmarkClaimRecord,
        field: String,
        against index: ReleaseEvidenceIndex
    ) throws {
        for (name, reference) in [
            ("dataset", claim.dataset),
            ("datasetComposition", claim.datasetComposition),
            ("degradationCondition", claim.degradationCondition),
            ("metricDefinition", claim.metricDefinition),
            ("evidenceProvenance", claim.evidenceProvenance),
            ("activeLimitations", claim.activeLimitations),
            ("correctionChannel", claim.correctionChannel),
        ] {
            try index.requireResolved(reference, field: "\(field).\(name)")
        }
    }

    // MARK: Measurement

    /// Requirement 8.16: the sample counts, coverage, and uncertainty interval are
    /// measurements.
    ///
    /// Four refusals the schema cannot make, because ``NonNegativeCount`` and
    /// ``UnitInterval`` both legitimately admit zero elsewhere:
    ///
    ///   * No eligible image. A claim measured over nothing reports nothing, and zero here
    ///     is the count that has not been taken yet rather than a measured emptiness.
    ///   * No decisive label. Coverage would be zero and the rate would have no support,
    ///     so there is no measured value for an interval to be an interval around.
    ///   * Zero coverage, which is the same absence written in the other field, and a
    ///     coverage of exactly 1 recorded while some eligible image was insufficient — or
    ///     below 1 while none was. Those two endpoints are the only places the counts pin
    ///     coverage exactly; between them the metric definition is the authority, and
    ///     recomputing the ratio here would either invent a rounding convention or reject
    ///     an honestly rounded value, because a non-terminating quotient has no exact
    ///     `Decimal` form.
    ///   * A point "interval". Requirement 8.16 requires an uncertainty interval, and a
    ///     lower bound equal to the upper bound expresses no uncertainty at all; a
    ///     confidence level of 0 or 1 is the same degeneracy in the level. The level's
    ///     value stays a claim decision: Requirement 5.19 fixes 95% for the mandatory
    ///     Release Gating Slices, and a published claim is not necessarily one of them, so
    ///     fixing a level here would be this code choosing a release value.
    private static func validateMeasurement(
        _ claim: BenchmarkClaimRecord,
        field: String
    ) throws {
        let eligible = claim.counts.eligibleImageCount
        guard eligible > 0 else {
            throw ArtifactSchemaError.nonPositiveValue(
                field: "\(field).counts.eligibleImages",
                value: "\(eligible)"
            )
        }
        let decisive = claim.counts.decisiveLabelCount
        guard decisive > 0 else {
            throw ArtifactSchemaError.nonPositiveValue(
                field: "\(field).counts.decisiveLabels",
                value: "\(decisive)"
            )
        }
        guard claim.coverage > .zero else {
            throw ArtifactSchemaError.nonPositiveValue(
                field: "\(field).coverage",
                value: claim.coverage.description
            )
        }
        guard (claim.coverage == .one) == (decisive == eligible) else {
            throw ArtifactSchemaError.inconsistentReference(
                field: "\(field).coverage",
                expected: decisive == eligible
                    ? "1, because every eligible image received a decisive label"
                    : "below 1, because \(eligible - decisive) of \(eligible) eligible images "
                        + "received an insufficient outcome",
                found: claim.coverage.description
            )
        }

        let interval = claim.uncertaintyInterval
        guard interval.lowerBound < interval.upperBound else {
            throw ArtifactSchemaError.valueOutOfRange(
                field: "\(field).uncertaintyInterval",
                value: "\(interval.lowerBound.description)...\(interval.upperBound.description)",
                allowed: "a lower bound below the upper bound, so the interval expresses "
                    + "uncertainty"
            )
        }
        guard interval.confidenceLevel > .zero, interval.confidenceLevel < .one else {
            throw ArtifactSchemaError.valueOutOfRange(
                field: "\(field).uncertaintyInterval.confidenceLevel",
                value: interval.confidenceLevel.description,
                allowed: "above 0 and below 1"
            )
        }
    }
}

// MARK: - Validated accessors

extension ValidatedBenchmarkClaim {
    /// The claim's artifact identifier, for a publication record or an audit trail.
    public var id: ArtifactID { claim.id }

    /// Eligible images behind the claim, both ground-truth populations pooled.
    public var eligibleSampleCount: Int { claim.counts.eligibleImageCount }

    /// Eligible images that received a decisive label.
    public var decisiveSampleCount: Int { claim.counts.decisiveLabelCount }

    /// The reported coverage, verified to be a measured fraction rather than an absence.
    public var coverage: UnitInterval { claim.coverage }

    /// The reported uncertainty interval, verified to be an interval.
    public var uncertaintyInterval: ConfidenceIntervalResult { claim.uncertaintyInterval }

    /// Every immutable record the claim binds, each one resolved.
    ///
    /// References rather than copies: this validator neither reads nor reproduces what the
    /// cited dataset, run, or metric definition contains.
    public var boundEvidence: Set<EvidenceSource> {
        [
            claim.dataset,
            claim.datasetComposition,
            claim.degradationCondition,
            claim.metricDefinition,
            claim.evidenceProvenance,
            claim.activeLimitations,
            claim.correctionChannel,
        ]
    }
}

// MARK: - Eligible release

/// A Release Readiness Record whose every applicable mandatory gate is satisfied.
///
/// Holding this value means Requirement 14.15 does not block: the record answers for an
/// approved capability set at this build, bundle, and allowlist; every mandatory gate has
/// immutable source and version identifiers that resolve to evidence this release carries,
/// an explicit applicability, and an executed pass; the two conditional gates' applicability
/// matches the compiled capability set; the signed Initial Model Bundle gates and the Lowq
/// governance decision pass (Requirements 14.16 and 14.17); the distribution-rights and
/// governance conclusions are externally supplied approvals rather than anything derived
/// here (Requirement 14.4); and every published claim is completely bound.
///
/// Construction refuses outright rather than reporting a status, because an ineligible
/// release has no partial form: Requirement 14.15 blocks the affected distribution. What
/// blocks it stays readable on the record itself through
/// ``ReleaseReadinessRecord/unresolvedMandatoryGates`` and
/// ``ReleaseReadinessRecord/failingMandatoryGates``.
public struct EligibleRelease: Hashable, Sendable {
    /// The record, unchanged. Validation never repairs, waives, or fills a gate.
    public let record: ReleaseReadinessRecord

    /// The signed capability manifest the record was validated against.
    public let capabilityManifest: ArtifactID

    /// The validated accessibility and Localization Readiness matrix this release's two
    /// matrix gates cite.
    ///
    /// An identifier rather than the matrix: reaching this value required a
    /// ``ValidatedAccessibilityGateMatrix``, so the caller already holds the matrix and
    /// the record only needs the audit trail back to it.
    public let accessibilityMatrix: ArtifactID

    /// Claims approved for publication with this release, each completely bound. Possibly
    /// none: a release may publish no benchmark claim at all.
    public let publishableClaims: [ValidatedBenchmarkClaim]

    /// Validates `record` for distribution eligibility.
    ///
    /// Fails closed with one ``ArtifactSchemaError`` naming the offending gate or field, so
    /// an audit can point at one position rather than reporting "release blocked". A
    /// failure is never an ``AnalysisError``: a record that does not validate blocks the
    /// affected public distribution instead of producing a user-facing verdict.
    ///
    /// The accessibility and Localization Readiness matrix is a required input rather than
    /// something re-derived here. Requirements 12.13 through 12.18 are what
    /// ``ValidatedAccessibilityGateMatrix`` decides, and a record's `accessibility-matrix`
    /// gate is one pass-or-fail entry: without the validated matrix, "passed" in that
    /// entry is an unbacked assertion, and re-validating the matrices here would put the
    /// same decision in two places.
    public init(
        validating record: ReleaseReadinessRecord,
        capabilityManifest manifest: ReleaseCapabilityManifest,
        accessibilityMatrix matrix: ValidatedAccessibilityGateMatrix,
        evidence index: ReleaseEvidenceIndex
    ) throws {
        try Self.validateApprovedManifest(manifest, against: index)
        try Self.validateReferences(record, manifest: manifest, matrix: matrix)
        try Self.validateExternalConclusions(record, against: index)
        try Self.validateConditionalApplicability(record, manifest: manifest)
        try Self.validateGates(record, against: index)
        let claims = try Self.validatedClaims(record, manifest: manifest, against: index)

        self.record = record
        self.capabilityManifest = manifest.id
        self.accessibilityMatrix = matrix.id
        self.publishableClaims = claims
    }

    // MARK: Approved manifest

    /// Requirement 14.1: the record answers for a capability set someone approved.
    ///
    /// ``ValidatedAccessibilityGateMatrix`` deliberately leaves this question open, and
    /// startup preflight answers a different one — whether the running module graph matches
    /// the manifest. Neither covers whether the manifest is an approved release decision,
    /// and a record mapping every gate to a manifest nobody approved describes a
    /// distribution that was never authorized.
    private static func validateApprovedManifest(
        _ manifest: ReleaseCapabilityManifest,
        against index: ReleaseEvidenceIndex
    ) throws {
        guard manifest.approval.isApproved else {
            throw ArtifactSchemaError.forbiddenValue(
                field: "release.capabilityManifest.approval.decision",
                value: manifest.approval.decision.rawValue,
                reason: "an unapproved capability set authorizes no distribution to gate"
            )
        }
        try index.requireResolved(
            manifest.approval.source,
            field: "release.capabilityManifest.approval.source"
        )
    }

    // MARK: References

    /// Requirements 13.20 and 14.1: one record, one build, one bundle, one allowlist.
    ///
    /// Every identifier the record carries is a free field, so each is required to be the
    /// artifact this release actually binds. Without that, a record can pass every gate
    /// against a different build's manifest, a bundle outside the approved catalog, or an
    /// allowlist for other devices — which is also the mechanism Requirement 14.11 relies
    /// on: a model refresh changes the bundle, so its evidence cannot be recorded against
    /// this build's record and a fresh record has to repeat every gate.
    ///
    /// The matrix is pinned in both directions. Its own validation already tied it to one
    /// allowlist and one application version; what is added here is that those are *this*
    /// record's, and that the two matrix gates cite the matrix that was validated rather
    /// than some other document.
    private static func validateReferences(
        _ record: ReleaseReadinessRecord,
        manifest: ReleaseCapabilityManifest,
        matrix: ValidatedAccessibilityGateMatrix
    ) throws {
        try ArtifactSchemaValidation.requireMatchingReference(
            record.capabilityManifest,
            matches: manifest.id,
            field: "release.capabilityManifest"
        )
        try ArtifactSchemaValidation.requireMatchingReference(
            record.appBuild,
            matches: manifest.appBuild,
            field: "release.appBuild"
        )
        guard manifest.approvedBundleCatalog.contains(record.modelBundle) else {
            throw ArtifactSchemaError.inconsistentReference(
                field: "release.modelBundle",
                expected: "one of "
                    + "\(manifest.approvedBundleCatalog.map(\.rawValue).sorted())",
                found: record.modelBundle.rawValue
            )
        }
        try ArtifactSchemaValidation.requireMatchingReference(
            record.deviceAllowlist,
            matches: manifest.approvedConfigurationAllowlist,
            field: "release.deviceAllowlist"
        )
        try ArtifactSchemaValidation.requireMatchingReference(
            matrix.allowlist,
            matches: record.deviceAllowlist,
            field: "release.accessibilityMatrix.allowlist"
        )
        try ArtifactSchemaValidation.requireMatchingReference(
            matrix.appBuild,
            matches: record.appBuild,
            field: "release.accessibilityMatrix.appBuild"
        )
        for gate in [ReleaseGate.accessibilityMatrix, .localizationReadinessMatrix] {
            try ArtifactSchemaValidation.requireMatchingReference(
                record.record(for: gate).evidence.artifact,
                matches: matrix.id,
                field: "release.gateRecords[\(gate.rawValue)].evidence"
            )
        }
    }

    // MARK: External conclusions

    /// Requirements 14.2 through 14.4, 14.9, 14.10, and 14.17: the legal and governance
    /// gates report externally supplied records.
    ///
    /// Each of the three is checked the same way and never computed: the carried
    /// ``ApprovalRecord`` has to approve, its source has to resolve to evidence this
    /// release carries, and the gate's own outcome has to agree with that decision. The
    /// third check is what keeps the two fields from drifting — a record that marks the
    /// license gate passed while carrying a rejection is asserting a conclusion its own
    /// evidence contradicts, and this module has no way to settle which is right.
    ///
    /// The governance record's disclosures are required data rather than a decision.
    /// Requirement 14.9 fixes what the Lowq checkpoint's disclosure says, so a record
    /// claiming the checkpoint is peer reviewed or that its upstream red-team validation
    /// is valid is a false disclosure. Whether that disclosed risk is acceptable stays
    /// entirely in ``ModelGovernanceDecisionRecord/decision``.
    private static func validateExternalConclusions(
        _ record: ReleaseReadinessRecord,
        against index: ReleaseEvidenceIndex
    ) throws {
        try Self.validateDisclosures(record.modelGovernance)
        for (gate, approval, field) in [
            (
                ReleaseGate.repositoryCodeLicense,
                record.distributionRights.repositoryCodeLicense,
                "release.distributionRights.repositoryCodeLicense"
            ),
            (
                ReleaseGate.dataDistributionRights,
                record.distributionRights.datasetDistributionTerms,
                "release.distributionRights.datasetDistributionTerms"
            ),
            (
                ReleaseGate.modelGovernanceDecision,
                record.modelGovernance.decision,
                "release.modelGovernance.decision"
            ),
        ] {
            guard approval.isApproved else {
                throw ArtifactSchemaError.forbiddenValue(
                    field: "\(field).decision",
                    value: approval.decision.rawValue,
                    reason: Self.blockingReason(gate)
                )
            }
            try index.requireResolved(approval.source, field: "\(field).source")

            let outcome = record.record(for: gate).outcome
            guard outcome.isPassing else {
                throw ArtifactSchemaError.inconsistentReference(
                    field: "release.gateRecords[\(gate.rawValue)].outcome",
                    expected: "\(GateOutcome.passed.rawValue), the approved decision at \(field)",
                    found: outcome.rawValue
                )
            }
        }
    }

    /// Requirement 14.9: the disclosed model, review status, and red-team status are the
    /// ones this release has to disclose.
    private static func validateDisclosures(_ governance: ModelGovernanceDecisionRecord) throws {
        guard governance.modelIdentity == RequiredPixelModel.identity else {
            throw ArtifactSchemaError.inconsistentReference(
                field: "release.modelGovernance.modelIdentity",
                expected: RequiredPixelModel.checkpointIdentifier,
                found: governance.modelIdentity.checkpointIdentifier.rawValue
            )
        }
        guard governance.isIndependentNonPeerReviewed else {
            throw ArtifactSchemaError.fixedValueMismatch(
                field: "release.modelGovernance.isIndependentNonPeerReviewed",
                expected: "true, the disclosed status of this checkpoint",
                found: "false"
            )
        }
        // The schema already refuses an inherited-report claim alongside this value, so
        // requiring it here fixes both disclosures at once.
        guard !governance.redTeamValidationValid else {
            throw ArtifactSchemaError.fixedValueMismatch(
                field: "release.modelGovernance.redTeamValidationValid",
                expected: "false, the upstream value this release discloses",
                found: "true"
            )
        }
    }

    // MARK: Conditional applicability

    /// Requirements 6.2, 6.3, and 14.1: a conditional gate's applicability is the compiled
    /// capability set, not a claim.
    ///
    /// Both directions are faults. A provenance-enabled build that records the feasibility
    /// gate as waived ships a capability with no gate behind it; a pixel-only build that
    /// records it as applicable and passing carries evidence for a lane it does not have,
    /// and the same holds for fusion. The record schema couples fusion to provenance
    /// internally; what it cannot see is which of the two the signed manifest compiled.
    private static func validateConditionalApplicability(
        _ record: ReleaseReadinessRecord,
        manifest: ReleaseCapabilityManifest
    ) throws {
        for (gate, compiled) in [
            (ReleaseGate.provenanceFeasibility, manifest.enablesProvenance),
            (ReleaseGate.fusionRuleApproval, manifest.enablesFusion),
        ] {
            let declared = record.record(for: gate).applicability.isApplicable
            guard declared == compiled else {
                throw ArtifactSchemaError.inconsistentReference(
                    field: "release.gateRecords[\(gate.rawValue)].applicability",
                    expected: compiled ? "applicable" : "not applicable",
                    found: declared ? "applicable" : "not applicable"
                )
            }
        }
    }

    // MARK: Gates

    /// Requirements 14.1, 14.15, 14.16, and 14.17: every mandatory gate names evidence
    /// that exists and records an explicit pass.
    ///
    /// Three refusals per gate, in the order an audit needs to hear them:
    ///
    ///   * The cited result does not resolve. The gate names an artifact, a version, and a
    ///     content digest, and a reference the release cannot resolve is not a source
    ///     identifier for anything — the mapping Requirement 14.1 requires would point at
    ///     nothing.
    ///   * The result is missing. A `not-executed` entry is the unrun gate written down
    ///     rather than omitted, and it is reported as missing evidence instead of as a
    ///     failure so the two stay distinguishable.
    ///   * The gate is not satisfied: it failed, or its inapplicability decision is a
    ///     rejection. A waiver nobody approved waives nothing.
    ///
    /// A not-applicable gate keeps both references checked. Its decision has to resolve,
    /// because an approval nobody can find at the cited version and digest is a
    /// synthesized approval, and its result reference has to resolve too — the field is
    /// required by the schema, and leaving it unchecked would make the one gate a release
    /// is allowed to skip the one gate whose citation nobody verifies.
    private static func validateGates(
        _ record: ReleaseReadinessRecord,
        against index: ReleaseEvidenceIndex
    ) throws {
        for entry in record.gateRecords.sorted(by: { $0.gate.rawValue < $1.gate.rawValue }) {
            let field = "release.gateRecords[\(entry.gate.rawValue)]"
            try index.requireResolved(entry.evidence, field: "\(field).evidence")
            if let decision = entry.applicability.inapplicabilityDecision {
                try index.requireResolved(
                    decision.source,
                    field: "\(field).applicability.decision.source"
                )
            }
            if entry.applicability.isApplicable, entry.outcome == .notExecuted {
                throw ArtifactSchemaError.missingRequiredEntries(
                    field: field,
                    keys: ["an executed result"]
                )
            }
            guard entry.isSatisfied else {
                throw ArtifactSchemaError.forbiddenValue(
                    field: "\(field).outcome",
                    value: entry.applicability.isApplicable
                        ? entry.outcome.rawValue
                        : ApprovalDecision.rejected.rawValue,
                    reason: Self.blockingReason(entry.gate)
                )
            }
        }
    }

    /// Why a missing or failing result at one gate blocks the affected distribution.
    private static func blockingReason(_ gate: ReleaseGate) -> String {
        ReleaseGate.hardPublicLaunchBlockers.contains(gate)
            ? """
                a missing or failing \(gate.rawValue) result is a hard public-launch \
                blocker and cannot be waived
                """
            : """
                a missing or failing applicable mandatory entry blocks the affected \
                public distribution
                """
    }

    // MARK: Claims

    /// Requirements 8.16 and 14.12: every claim this release publishes is completely bound.
    ///
    /// The bindings come from the release rather than from the claim, so a claim cannot
    /// nominate its own bundle, Calibration Policy, limitations document, or correction
    /// channel. An empty list is valid and means this release publishes no benchmark claim;
    /// it never means the claim gate was skipped, which the gate sweep above already
    /// required to pass.
    private static func validatedClaims(
        _ record: ReleaseReadinessRecord,
        manifest: ReleaseCapabilityManifest,
        against index: ReleaseEvidenceIndex
    ) throws -> [ValidatedBenchmarkClaim] {
        try record.benchmarkClaims.map {
            try ValidatedBenchmarkClaim(
                validating: $0,
                modelBundle: record.modelBundle,
                calibrationPolicy: manifest.policyCompatibility.calibrationPolicy,
                activeLimitations: record.record(for: .activeLimitationsPublication).evidence,
                correctionChannel: record.record(for: .correctionChannel).evidence,
                evidence: index
            )
        }
    }
}

// MARK: - Eligible accessors

extension EligibleRelease {
    /// The record's artifact identifier, for a distribution audit trail.
    public var id: ArtifactID { record.id }

    /// The application build this eligibility answers for.
    public var appBuild: AppBuildID { record.appBuild }

    /// The Model Bundle this release distributes.
    public var modelBundle: ModelBundleID { record.modelBundle }

    /// The device allowlist this release is distributed against.
    public var deviceAllowlist: ArtifactID { record.deviceAllowlist }

    /// Whether provenance is part of this release, by explicit applicability that matches
    /// the signed manifest.
    public var enablesProvenance: Bool { record.enablesProvenance }

    /// Whether a Combined Summary is part of this release.
    public var enablesFusion: Bool { record.enablesFusion }

    /// The versioned active known limitations this release publishes (Requirement 14.14).
    public var publishedActiveLimitations: EvidenceSource {
        record.record(for: .activeLimitationsPublication).evidence
    }

    /// The user-accessible correction channel this release publishes (Requirement 14.14).
    public var publishedCorrectionChannel: EvidenceSource {
        record.record(for: .correctionChannel).evidence
    }

    /// The externally supplied governance and red-team decision this release recorded.
    ///
    /// Exposed as the record it is, not as a boolean: a reader sees who decided, when, and
    /// from which immutable source, and nothing here can be mistaken for a conclusion this
    /// module reached.
    public var governanceDecision: ApprovalRecord { record.modelGovernance.decision }

    /// The immutable result reference behind one satisfied gate.
    ///
    /// Total by construction: the record carries every gate exactly once, and reaching
    /// this value required each reference to resolve.
    public func evidence(for gate: ReleaseGate) -> EvidenceSource {
        record.record(for: gate).evidence
    }

    /// The validated claim with one identifier, or `nil` when this release publishes none
    /// under it.
    ///
    /// `nil` is never "the claim exists but was not checked": an unvalidated claim keeps
    /// the whole record from validating.
    public func claim(_ id: ArtifactID) -> ValidatedBenchmarkClaim? {
        publishableClaims.first { $0.id == id }
    }
}
