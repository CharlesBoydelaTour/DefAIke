import DefAIkeTestSupport
import Foundation
import Testing

@testable import DefAIkeDomain

// Example tests for the release-eligibility layer.
//
// Every test builds the coherent baseline, breaks exactly one thing, and requires the
// validator to refuse. What each one is really asserting is that a specific way of
// distributing a release with an unrun gate, an unresolvable citation, a silently enabled
// capability, a conclusion nobody approved, or a claim with no measured support is not
// available.
//
// The exhaustive generated coverage belongs to Property 33 (release readiness is auditable
// and fail-closed) and Property 24 (benchmark claims are completely bound) in their own
// tasks. These examples pin the individual refusals so a regression names one field.

@Suite("Eligible release")
struct EligibleReleaseTests {

    @Test("A complete passing record is eligible and reports what it was validated against")
    func coherentRecordIsEligible() throws {
        let eligible = try ReleaseReadinessSample.validated()

        #expect(eligible.id == Sample.artifact(ReleaseReadinessSample.recordIdentifier))
        #expect(eligible.appBuild == Sample.appBuild(ReleaseReadinessSample.appBuildIdentifier))
        #expect(eligible.modelBundle == Sample.bundle(ReleaseReadinessSample.bundleIdentifier))
        #expect(
            eligible.deviceAllowlist
                == Sample.artifact(ReleaseReadinessSample.allowlistIdentifier)
        )
        #expect(
            eligible.capabilityManifest
                == Sample.artifact(ReleaseReadinessSample.manifestIdentifier)
        )
        #expect(
            eligible.accessibilityMatrix
                == Sample.artifact(ReleaseReadinessSample.matrixIdentifier)
        )
        #expect(!eligible.enablesProvenance)
        #expect(!eligible.enablesFusion)
        #expect(eligible.publishableClaims.isEmpty)

        // Requirement 14.14: the published limitations and channel are the record's own.
        #expect(
            eligible.publishedActiveLimitations
                == Sample.evidence(ReleaseReadinessSample.limitationsIdentifier)
        )
        #expect(
            eligible.publishedCorrectionChannel
                == Sample.evidence(ReleaseReadinessSample.correctionChannelIdentifier)
        )
        #expect(
            eligible.evidence(for: .privacyAudit)
                == Sample.evidence(
                    ReleaseReadinessSample.gateEvidenceIdentifier(.privacyAudit)
                )
        )
        // The governance conclusion is exposed as the record that decided it, never as a
        // value this module computed.
        #expect(eligible.governanceDecision.isApproved)
        #expect(
            eligible.governanceDecision.source
                == Sample.evidence(ReleaseReadinessSample.governanceApprovalIdentifier)
        )
    }

    // MARK: Missing and failing gates

    @Test("A gate with no result blocks rather than passing")
    func missingResultBlocks() throws {
        let record = try ReleaseReadinessSample.record(
            gateRecords: try ReleaseReadinessSample.gateRecords(
                outcomes: [.privacyAudit: .notExecuted]
            )
        )
        // The record itself reports the gate as unresolved; eligibility refuses it.
        #expect(record.unresolvedMandatoryGates == [.privacyAudit])
        #expect(throws: ArtifactSchemaError.self) {
            try ReleaseReadinessSample.validated(record: record)
        }
    }

    @Test("Any failing mandatory gate blocks distribution")
    func everyFailingGateBlocks() throws {
        for gate in ReleaseGate.unconditionalGates.sorted(by: { $0.rawValue < $1.rawValue }) {
            #expect(
                throws: ArtifactSchemaError.self,
                "a release with a failed \(gate.rawValue) result was eligible"
            ) {
                try ReleaseReadinessSample.validated(
                    record: try ReleaseReadinessSample.record(
                        gateRecords: try ReleaseReadinessSample.gateRecords(
                            outcomes: [gate: .failed]
                        )
                    )
                )
            }
        }
    }

    @Test("A hard public-launch blocker names itself when it refuses")
    func hardBlockersNameThemselves() throws {
        // Requirements 14.16 and 14.17: the bundle gates and the governance decision are
        // the blockers the requirements call out by name, and every one of them is
        // unconditional so none can be waived.
        #expect(
            ReleaseGate.hardPublicLaunchBlockers
                == [
                    .initialModelBundleSignature,
                    .initialModelBundleSelfTests,
                    .bundleActivation,
                    .bundleRollback,
                    .modelGovernanceDecision,
                ]
        )
        #expect(ReleaseGate.hardPublicLaunchBlockers.isSubset(of: ReleaseGate.unconditionalGates))

        for gate in ReleaseGate.hardPublicLaunchBlockers
            .sorted(by: { $0.rawValue < $1.rawValue })
        {
            // The four bundle gates fail through their recorded outcome. The governance
            // gate cannot: its outcome is required to report the decision it carries, so a
            // failed outcome beside an approved decision is refused earlier as that
            // disagreement, and the gate blocks through the decision instead.
            let record = try gate.isExternallyDecided
                ? ReleaseReadinessSample.record(
                    modelGovernance: try ReleaseReadinessSample.governance(decision: .rejected)
                )
                : ReleaseReadinessSample.record(
                    gateRecords: try ReleaseReadinessSample.gateRecords(
                        outcomes: [gate: .failed]
                    )
                )
            let error = try #require(
                Self.refusal { try ReleaseReadinessSample.validated(record: record) },
                "a failing \(gate.rawValue) result was eligible"
            )
            #expect(
                error.description.contains("hard public-launch blocker"),
                "\(gate.rawValue) refused with \(error) rather than as a hard blocker"
            )
        }
    }

    // MARK: Gate evidence

    @Test("A gate citing evidence the release does not carry is refused")
    func unresolvableGateEvidenceRefused() throws {
        // The reference is well formed and names nothing, so the mapping Requirement 14.1
        // requires would point at no record at all.
        #expect(throws: ArtifactSchemaError.self) {
            try ReleaseReadinessSample.validated(
                record: try ReleaseReadinessSample.record(
                    gateRecords: try ReleaseReadinessSample.gateRecords(
                        evidenceIdentifiers: [.archiveAudit: "evidence.elsewhere"]
                    )
                )
            )
        }
        // Removing the record from the release, rather than repointing the gate, is the
        // other direction of the same fault.
        #expect(throws: ArtifactSchemaError.self) {
            try ReleaseReadinessSample.validated(
                evidence: try ReleaseReadinessSample.evidenceIndex(
                    omitting: [ReleaseReadinessSample.gateEvidenceIdentifier(.archiveAudit)]
                )
            )
        }
    }

    @Test("A waiver whose approval the release cannot resolve is refused")
    func unresolvableWaiverApprovalRefused() throws {
        #expect(throws: ArtifactSchemaError.self) {
            try ReleaseReadinessSample.validated(
                record: try ReleaseReadinessSample.record(
                    gateRecords: try ReleaseReadinessSample.gateRecords(
                        waiverEvidence: "approval.elsewhere"
                    )
                )
            )
        }
    }

    @Test("A rejected inapplicability decision waives nothing")
    func rejectedWaiverRefused() throws {
        #expect(throws: ArtifactSchemaError.self) {
            try ReleaseReadinessSample.validated(
                record: try ReleaseReadinessSample.record(
                    gateRecords: try ReleaseReadinessSample.gateRecords(
                        waiverDecisions: [.provenanceFeasibility: .rejected]
                    )
                )
            )
        }
    }

    // MARK: Conditional capabilities

    @Test("A conditional gate's applicability is the compiled capability set")
    func conditionalApplicabilityFollowsTheManifest() throws {
        // A pixel-only build recording the provenance gate as applicable and passing is
        // carrying evidence for a lane it does not have.
        #expect(throws: ArtifactSchemaError.self) {
            try ReleaseReadinessSample.validated(
                record: try ReleaseReadinessSample.record(
                    gateRecords: try ReleaseReadinessSample.gateRecords(
                        provenanceApplicable: true
                    )
                )
            )
        }

        // A provenance build recording the gate as waived ships the capability with no
        // gate behind it, which is the silent enabling Property 33 excludes.
        let provenanceManifest = try ReleaseReadinessSample.capabilityManifest(
            provenanceEnabled: true
        )
        #expect(throws: ArtifactSchemaError.self) {
            try ReleaseReadinessSample.validated(manifest: provenanceManifest)
        }

        let eligible = try ReleaseReadinessSample.validated(
            record: try ReleaseReadinessSample.record(
                gateRecords: try ReleaseReadinessSample.gateRecords(provenanceApplicable: true)
            ),
            manifest: provenanceManifest
        )
        #expect(eligible.enablesProvenance)
        #expect(!eligible.enablesFusion)
    }

    @Test("A provenance-plus-fusion release records both conditional gates as applicable")
    func fusionApplicabilityFollowsTheManifest() throws {
        let manifest = try ReleaseReadinessSample.capabilityManifest(
            provenanceEnabled: true,
            fusionEnabled: true
        )
        let eligible = try ReleaseReadinessSample.validated(
            record: try ReleaseReadinessSample.record(
                gateRecords: try ReleaseReadinessSample.gateRecords(
                    provenanceApplicable: true,
                    fusionApplicable: true
                )
            ),
            manifest: manifest
        )
        #expect(eligible.enablesProvenance && eligible.enablesFusion)

        // Provenance enabled and fusion waived, against a manifest that compiled fusion.
        #expect(throws: ArtifactSchemaError.self) {
            try ReleaseReadinessSample.validated(
                record: try ReleaseReadinessSample.record(
                    gateRecords: try ReleaseReadinessSample.gateRecords(
                        provenanceApplicable: true,
                        fusionApplicable: false
                    )
                ),
                manifest: manifest
            )
        }
    }

    // MARK: The approved capability set

    @Test("An unapproved capability manifest authorizes no distribution")
    func unapprovedManifestRefused() throws {
        #expect(throws: ArtifactSchemaError.self) {
            try ReleaseReadinessSample.validated(
                manifest: try ReleaseReadinessSample.capabilityManifest(approval: .rejected)
            )
        }
        #expect(throws: ArtifactSchemaError.self) {
            try ReleaseReadinessSample.validated(
                manifest: try ReleaseReadinessSample.capabilityManifest(
                    approvalEvidence: "approval.elsewhere"
                )
            )
        }
    }

    // MARK: References

    @Test("A record bound to another build, manifest, bundle, or allowlist is refused")
    func referencesMustResolveToThisRelease() throws {
        for record in try [
            ReleaseReadinessSample.record(capabilityManifest: "manifest.other"),
            ReleaseReadinessSample.record(appBuild: "build.other"),
            ReleaseReadinessSample.record(modelBundle: "bundle.other"),
            ReleaseReadinessSample.record(deviceAllowlist: "allowlist.other"),
        ] {
            #expect(throws: ArtifactSchemaError.self) {
                try ReleaseReadinessSample.validated(record: record)
            }
        }
    }

    @Test("A matrix gate citing a document other than the validated matrix is refused")
    func matrixGatesCiteTheValidatedMatrix() throws {
        for gate in [ReleaseGate.accessibilityMatrix, .localizationReadinessMatrix] {
            #expect(
                throws: ArtifactSchemaError.self,
                "\(gate.rawValue) accepted a citation outside the validated matrix"
            ) {
                try ReleaseReadinessSample.validated(
                    record: try ReleaseReadinessSample.record(
                        gateRecords: try ReleaseReadinessSample.gateRecords(
                            evidenceIdentifiers: [gate: "evidence.release.\(gate.rawValue)"]
                        )
                    ),
                    evidence: try ReleaseReadinessSample.evidenceIndex(
                        adding: [Sample.evidence("evidence.release.\(gate.rawValue)")]
                    )
                )
            }
        }
    }

    @Test("A matrix validated for another application version is refused")
    func matrixMustAnswerForThisBuild() throws {
        // The matrix is internally valid and answers for a different build, which is the
        // pooling across application versions Requirement 13.20 excludes.
        let otherBuildManifest = try ReleaseCapabilityManifest(
            id: Sample.artifact(ReleaseReadinessSample.manifestIdentifier),
            schemaVersion: .v1,
            appBuild: Sample.appBuild("build.other"),
            compositionIdentifier: Sample.text("pixel-only"),
            compiledCapabilities: [.pixelAnalysis],
            implementationVersions: [
                CapabilityImplementationEntry(capability: .pixelAnalysis, version: Sample.version())
            ],
            approvedConfigurationAllowlist: Sample.artifact(
                ReleaseReadinessSample.allowlistIdentifier
            ),
            approvedBundleCatalog: [Sample.bundle(ReleaseReadinessSample.bundleIdentifier)],
            policyCompatibility: try Sample.policyCompatibility(),
            approval: Sample.approval(
                identifier: ReleaseReadinessSample.sharedApprovalIdentifier
            )
        )
        let otherBuildMatrix = try AccessibilityMatrixSample.validated(
            allowlist: try AccessibilityMatrixSample.allowlist(
                entries: [try AccessibilityMatrixSample.entry(appBuild: "build.other")]
            ),
            manifest: otherBuildManifest,
            evidence: try ReleaseReadinessSample.evidenceIndex()
        )
        #expect(otherBuildMatrix.appBuild == Sample.appBuild("build.other"))

        #expect(throws: ArtifactSchemaError.self) {
            try ReleaseReadinessSample.validated(accessibilityMatrix: otherBuildMatrix)
        }
    }

    // MARK: Legal and governance conclusions

    @Test("An unresolved code or data right blocks the affected distribution")
    func unresolvedRightsBlock() throws {
        for rights in [
            ReleaseReadinessSample.distributionRights(code: .rejected),
            ReleaseReadinessSample.distributionRights(data: .rejected),
        ] {
            #expect(!rights.isResolved)
            #expect(throws: ArtifactSchemaError.self) {
                try ReleaseReadinessSample.validated(
                    record: try ReleaseReadinessSample.record(distributionRights: rights)
                )
            }
        }
    }

    @Test("A rights approval the release cannot resolve is not evidence")
    func unresolvableRightsApprovalRefused() throws {
        for omitted in [
            ReleaseReadinessSample.codeLicenseApprovalIdentifier,
            ReleaseReadinessSample.datasetTermsApprovalIdentifier,
            ReleaseReadinessSample.governanceApprovalIdentifier,
        ] {
            #expect(
                throws: ArtifactSchemaError.self,
                "an approval citing missing \(omitted) was accepted"
            ) {
                try ReleaseReadinessSample.validated(
                    evidence: try ReleaseReadinessSample.evidenceIndex(omitting: [omitted])
                )
            }
        }
    }

    @Test("A gate outcome cannot disagree with the record that decides it")
    func gateOutcomeFollowsTheExternalRecord() throws {
        // The two fields are stored separately, which is what keeps a conclusion from
        // being asserted next to its own evidence. When they disagree, this module has no
        // way to settle which is right, so it refuses and names the pair.
        let record = try ReleaseReadinessSample.record(
            gateRecords: try ReleaseReadinessSample.gateRecords(
                outcomes: [.repositoryCodeLicense: .failed]
            )
        )
        let error = try #require(Self.refusal { try ReleaseReadinessSample.validated(record: record) })
        #expect(
            error
                == .inconsistentReference(
                    field: "release.gateRecords[repository-code-license].outcome",
                    expected: "passed, the approved decision at "
                        + "release.distributionRights.repositoryCodeLicense",
                    found: "failed"
                ),
            "the license disagreement was reported as \(error)"
        )
    }

    @Test("Only the external decision decides governance; the disclosures do not")
    func governanceConclusionIsNeverDerived() throws {
        // The disclosures are identical in both records and only the decision differs, so
        // the outcome cannot be coming from anything this module computed about the
        // checkpoint (Requirements 14.9, 14.10, and 14.17).
        let approved = try ReleaseReadinessSample.record(
            modelGovernance: try ReleaseReadinessSample.governance(decision: .approved)
        )
        let rejected = try ReleaseReadinessSample.record(
            modelGovernance: try ReleaseReadinessSample.governance(decision: .rejected)
        )
        #expect(approved.modelGovernance.redTeamValidationValid == false)
        #expect(
            approved.modelGovernance.isIndependentNonPeerReviewed
                == rejected.modelGovernance.isIndependentNonPeerReviewed
        )

        _ = try ReleaseReadinessSample.validated(record: approved)
        let error = try #require(
            Self.refusal { try ReleaseReadinessSample.validated(record: rejected) }
        )
        #expect(
            error
                == .forbiddenValue(
                    field: "release.modelGovernance.decision.decision",
                    value: ApprovalDecision.rejected.rawValue,
                    reason: """
                        a missing or failing model-governance-decision result is a hard \
                        public-launch blocker and cannot be waived
                        """
                ),
            "the rejected governance decision was reported as \(error)"
        )
    }

    @Test("A false red-team or peer-review disclosure is refused")
    func disclosuresAreFixed() throws {
        // Requirement 14.9 fixes what this checkpoint's disclosure says. A record claiming
        // a valid inherited red-team report, or a peer-reviewed status, is a false
        // disclosure regardless of how the risk decision came out.
        #expect(throws: ArtifactSchemaError.self) {
            try ReleaseReadinessSample.validated(
                record: try ReleaseReadinessSample.record(
                    modelGovernance: try ReleaseReadinessSample.governance(
                        redTeamValidationValid: true
                    )
                )
            )
        }
        #expect(throws: ArtifactSchemaError.self) {
            try ReleaseReadinessSample.validated(
                record: try ReleaseReadinessSample.record(
                    modelGovernance: try ReleaseReadinessSample.governance(
                        isIndependentNonPeerReviewed: false
                    )
                )
            )
        }
    }

    @Test("A governance decision about another checkpoint is refused")
    func governanceMustDescribeTheBoundModel() throws {
        #expect(throws: ArtifactSchemaError.self) {
            try ReleaseReadinessSample.validated(
                record: try ReleaseReadinessSample.record(
                    modelGovernance: try ReleaseReadinessSample.governance(
                        modelIdentity: ModelIdentity(
                            checkpointIdentifier: try #require(
                                ModelCheckpointIdentifier("Vendor/other-checkpoint")
                            ),
                            requiredWeightDigest: Sample.digest("9")
                        )
                    )
                )
            )
        }
    }

    /// The schema fault a validation raised, or `nil` when it was accepted.
    ///
    /// Returning the fault instead of asserting on `throws:` is what lets a test require
    /// one exact field and reason, so a refusal that moves to a different cause is a
    /// failure rather than a silent pass.
    static func refusal(_ build: () throws -> EligibleRelease) -> ArtifactSchemaError? {
        do {
            _ = try build()
            return nil
        } catch let error as ArtifactSchemaError {
            return error
        } catch {
            Issue.record("unexpected fault: \(error)")
            return nil
        }
    }
}

// MARK: - Benchmark claims

@Suite("Validated benchmark claim")
struct ValidatedBenchmarkClaimTests {

    @Test("A completely bound claim is publishable and reports its measured support")
    func coherentClaimValidates() throws {
        let eligible = try ReleaseReadinessSample.validated(
            record: try ReleaseReadinessSample.record(
                benchmarkClaims: [try ReleaseReadinessSample.claim()]
            )
        )
        let claim = try #require(
            eligible.claim(Sample.artifact(ReleaseReadinessSample.claimIdentifier))
        )
        #expect(eligible.publishableClaims.count == 1)
        #expect(claim.eligibleSampleCount == 100)
        #expect(claim.decisiveSampleCount == 80)
        #expect(claim.coverage == Sample.ratio(Decimal(sign: .plus, exponent: -1, significand: 8)))
        #expect(claim.uncertaintyInterval.lowerBound < claim.uncertaintyInterval.upperBound)
        #expect(claim.boundEvidence.count == 7)
        #expect(claim.boundEvidence.contains(eligible.publishedActiveLimitations))
        #expect(claim.boundEvidence.contains(eligible.publishedCorrectionChannel))
    }

    @Test("A claim citing a record the release does not carry is refused")
    func everyCitationMustResolve() throws {
        for omitted in [
            ReleaseReadinessSample.datasetIdentifier,
            ReleaseReadinessSample.compositionIdentifier,
            ReleaseReadinessSample.degradationIdentifier,
            ReleaseReadinessSample.metricIdentifier,
            ReleaseReadinessSample.runIdentifier,
        ] {
            #expect(
                throws: ArtifactSchemaError.self,
                "a claim citing missing \(omitted) was publishable"
            ) {
                try ReleaseReadinessSample.validated(
                    record: try ReleaseReadinessSample.record(
                        benchmarkClaims: [try ReleaseReadinessSample.claim()]
                    ),
                    evidence: try ReleaseReadinessSample.evidenceIndex(omitting: [omitted])
                )
            }
        }
    }

    @Test("A claim measured on another model, bundle, or policy is refused")
    func claimDescribesThisRelease() throws {
        for claim in try [
            ReleaseReadinessSample.claim(modelBundle: "bundle.other"),
            ReleaseReadinessSample.claim(calibrationPolicy: "policy.other"),
            ReleaseReadinessSample.claim(
                modelIdentity: ModelIdentity(
                    checkpointIdentifier: try #require(
                        ModelCheckpointIdentifier("Vendor/other-checkpoint")
                    ),
                    requiredWeightDigest: Sample.digest("9")
                )
            ),
        ] {
            #expect(throws: ArtifactSchemaError.self) {
                try ReleaseReadinessSample.validated(
                    record: try ReleaseReadinessSample.record(benchmarkClaims: [claim])
                )
            }
        }
    }

    @Test("A claim must cite the limitations and correction channel this release publishes")
    func claimPointsAtThePublishedRecords() throws {
        for claim in try [
            ReleaseReadinessSample.claim(activeLimitations: "evidence.dataset"),
            ReleaseReadinessSample.claim(correctionChannel: "evidence.dataset"),
        ] {
            #expect(throws: ArtifactSchemaError.self) {
                try ReleaseReadinessSample.validated(
                    record: try ReleaseReadinessSample.record(benchmarkClaims: [claim])
                )
            }
        }
    }

    // MARK: Sample counts and coverage

    @Test("A claim measured over no eligible image or no decisive label is refused")
    func zeroCountsRefused() throws {
        // Zero here is the count nobody took, not a measured emptiness, so it is the
        // categorical form of "unknown" and cannot support a published rate.
        for counts in try [
            ReleaseReadinessSample.outcomeCounts(
                eligibleReal: 0,
                eligibleSynthetic: 0,
                realDecisive: 0,
                syntheticDecisive: 0
            ),
            ReleaseReadinessSample.outcomeCounts(realDecisive: 0, syntheticDecisive: 0),
        ] {
            #expect(throws: ArtifactSchemaError.self) {
                try ReleaseReadinessSample.validated(
                    record: try ReleaseReadinessSample.record(
                        benchmarkClaims: [try ReleaseReadinessSample.claim(counts: counts)]
                    )
                )
            }
        }
    }

    @Test("A claim reporting zero coverage is refused")
    func zeroCoverageRefused() throws {
        #expect(throws: ArtifactSchemaError.self) {
            try ReleaseReadinessSample.validated(
                record: try ReleaseReadinessSample.record(
                    benchmarkClaims: [try ReleaseReadinessSample.claim(coverage: 0)]
                )
            )
        }
    }

    @Test("Coverage agrees with the counts at both endpoints")
    func coverageEndpointsFollowTheCounts() throws {
        // Full coverage claimed while a fifth of the eligible images abstained.
        #expect(throws: ArtifactSchemaError.self) {
            try ReleaseReadinessSample.validated(
                record: try ReleaseReadinessSample.record(
                    benchmarkClaims: [try ReleaseReadinessSample.claim(coverage: 1)]
                )
            )
        }

        // Every eligible image decisive, so coverage below 1 contradicts the counts.
        let complete = try ReleaseReadinessSample.outcomeCounts(
            realDecisive: 60,
            syntheticDecisive: 40
        )
        #expect(throws: ArtifactSchemaError.self) {
            try ReleaseReadinessSample.validated(
                record: try ReleaseReadinessSample.record(
                    benchmarkClaims: [
                        try ReleaseReadinessSample.claim(
                            counts: complete,
                            coverage: Decimal(sign: .plus, exponent: -1, significand: 8)
                        )
                    ]
                )
            )
        }

        // The same counts with coverage of exactly 1 are consistent, so the refusals above
        // are about the disagreement rather than about full coverage being unrepresentable.
        let eligible = try ReleaseReadinessSample.validated(
            record: try ReleaseReadinessSample.record(
                benchmarkClaims: [
                    try ReleaseReadinessSample.claim(counts: complete, coverage: 1)
                ]
            )
        )
        #expect(eligible.publishableClaims.first?.coverage == .one)
    }

    // MARK: Uncertainty interval

    @Test("A point value is not an uncertainty interval")
    func pointIntervalRefused() throws {
        let point = try ReleaseReadinessSample.uncertaintyInterval(
            lowerBound: Decimal(sign: .plus, exponent: -2, significand: 1),
            upperBound: Decimal(sign: .plus, exponent: -2, significand: 1)
        )
        // The schema accepts it, because a lower bound equal to the upper bound is a valid
        // ordering. Requirement 8.16 asks for uncertainty, and this expresses none.
        #expect(point.lowerBound == point.upperBound)
        #expect(throws: ArtifactSchemaError.self) {
            try ReleaseReadinessSample.validated(
                record: try ReleaseReadinessSample.record(
                    benchmarkClaims: [try ReleaseReadinessSample.claim(interval: point)]
                )
            )
        }
    }

    @Test("A degenerate confidence level is refused, and the level itself stays a decision")
    func confidenceLevelMustBeALevel() throws {
        for level in [Decimal(0), Decimal(1)] {
            #expect(
                throws: ArtifactSchemaError.self,
                "a claim at confidence level \(level) was publishable"
            ) {
                try ReleaseReadinessSample.validated(
                    record: try ReleaseReadinessSample.record(
                        benchmarkClaims: [
                            try ReleaseReadinessSample.claim(
                                interval: try ReleaseReadinessSample.uncertaintyInterval(
                                    level: level
                                )
                            )
                        ]
                    )
                )
            }
        }

        // A level other than the 95% Requirement 5.19 fixes for the mandatory gating
        // slices is accepted: a published claim is not necessarily one of those slices, so
        // fixing the level here would be this module choosing a release value.
        let ninety = try ReleaseReadinessSample.uncertaintyInterval(
            level: Decimal(sign: .plus, exponent: -2, significand: 90)
        )
        let eligible = try ReleaseReadinessSample.validated(
            record: try ReleaseReadinessSample.record(
                benchmarkClaims: [try ReleaseReadinessSample.claim(interval: ninety)]
            )
        )
        #expect(eligible.publishableClaims.first?.uncertaintyInterval == ninety)
    }

    // MARK: Required bindings

    @Test("Dropping any binding from a claim payload fails closed")
    func everyBindingIsRequired() throws {
        let claim = try ReleaseReadinessSample.claim()
        let payload = try CanonicalArtifactPayload.text(claim)

        // The positive control: the untouched payload decodes back to the same claim, so
        // every refusal below is about the removed member rather than about the encoding.
        #expect(
            try JSONDecoder().decode(BenchmarkClaimRecord.self, from: Data(payload.utf8)) == claim
        )

        let keys = try CanonicalArtifactPayload.topLevelKeys(claim)
        #expect(keys.count == 14, "a claim binding was added or removed: \(keys)")
        for key in keys {
            let mutated = try #require(
                JSONMemberSplice.removingTopLevelMember(key, from: payload),
                "\(key) was not a top-level member of the encoded claim"
            )
            #expect(
                throws: DecodingError.self,
                "a claim decoded without \(key), so something supplied a default"
            ) {
                try JSONDecoder().decode(BenchmarkClaimRecord.self, from: Data(mutated.utf8))
            }
        }
    }
}

// MARK: - Payload text splicing

/// Removes one member from a JSON object's *text*.
///
/// Text splicing rather than a `JSONSerialization` round trip. Re-serializing a value
/// perturbs its exact decimals, and a benchmark claim carries three of them — coverage and
/// both interval bounds — so a decode failure could come from the perturbed decimal instead
/// of from the removed member, and a "this field is required" assertion would pass
/// vacuously. Splicing leaves every other byte of the payload untouched.
enum JSONMemberSplice {

    /// `payload` without its top-level `key` member, or `nil` when there is no such member.
    ///
    /// Returning `nil` rather than the unchanged text keeps a test from asserting against
    /// a payload it did not actually mutate.
    static func removingTopLevelMember(_ key: String, from payload: String) -> String? {
        guard let range = topLevelMemberRanges(in: payload)[key] else { return nil }
        var start = range.lowerBound
        var end = range.upperBound
        // Take one adjacent separator with the member so the result stays well-formed
        // JSON: an absent field has to be refused on its own merits, not because the
        // payload became unparseable.
        if end < payload.endIndex, payload[end] == "," {
            end = payload.index(after: end)
        } else if start > payload.startIndex, payload[payload.index(before: start)] == "," {
            start = payload.index(before: start)
        }
        return payload.replacingCharacters(in: start..<end, with: "")
    }

    /// The text range of each top-level member, from its opening quote to the end of its
    /// value.
    ///
    /// Depth tracking is what makes this different from a substring search: a nested object
    /// can repeat a top-level key name, and a string value can contain a brace.
    static func topLevelMemberRanges(in payload: String) -> [String: Range<String.Index>] {
        guard let opening = payload.firstIndex(where: { !$0.isWhitespace }),
              payload[opening] == "{"
        else {
            return [:]
        }
        var ranges: [String: Range<String.Index>] = [:]
        var index = payload.index(after: opening)
        while index < payload.endIndex {
            while index < payload.endIndex,
                  payload[index] == "," || payload[index].isWhitespace
            {
                index = payload.index(after: index)
            }
            guard index < payload.endIndex, payload[index] == "\"" else { break }
            let memberStart = index
            guard let keyEnd = endOfString(in: payload, from: memberStart) else { break }
            let key = String(
                payload[payload.index(after: memberStart)..<payload.index(before: keyEnd)]
            )
            var cursor = keyEnd
            while cursor < payload.endIndex, payload[cursor] != ":" {
                cursor = payload.index(after: cursor)
            }
            guard cursor < payload.endIndex else { break }
            guard let valueEnd = endOfValue(in: payload, from: payload.index(after: cursor))
            else {
                break
            }
            ranges[key] = memberStart..<valueEnd
            index = valueEnd
        }
        return ranges
    }

    /// The index just past the closing quote of the string starting at `start`.
    private static func endOfString(
        in payload: String,
        from start: String.Index
    ) -> String.Index? {
        var index = payload.index(after: start)
        while index < payload.endIndex {
            switch payload[index] {
            case "\\":
                index = payload.index(after: index)
                guard index < payload.endIndex else { return nil }
            case "\"":
                return payload.index(after: index)
            default:
                break
            }
            index = payload.index(after: index)
        }
        return nil
    }

    /// The index just past the value starting at `start`.
    private static func endOfValue(
        in payload: String,
        from start: String.Index
    ) -> String.Index? {
        var index = start
        var depth = 0
        while index < payload.endIndex {
            switch payload[index] {
            case "\"":
                guard let next = endOfString(in: payload, from: index) else { return nil }
                index = next
                if depth == 0 { return index }
                continue
            case "{", "[":
                depth += 1
            case "}", "]":
                guard depth > 0 else { return index }
                depth -= 1
                if depth == 0 { return payload.index(after: index) }
            case ",":
                if depth == 0 { return index }
            default:
                break
            }
            index = payload.index(after: index)
        }
        return depth == 0 ? index : nil
    }
}
