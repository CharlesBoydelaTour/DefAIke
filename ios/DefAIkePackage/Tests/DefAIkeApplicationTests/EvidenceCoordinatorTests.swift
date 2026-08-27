import DefAIkeDomain
import DefAIkeProvenanceAPI
import Testing

@testable import DefAIkeApplication

/// The Evidence Coordinator: two resolved lanes in, one immutable report out.
///
/// The assertions are deliberately about what the coordinator does *not* do. Both lanes
/// reach the report byte-for-byte; `absent`, `unavailable`, and the Insufficient Evidence
/// Outcome stay three distinct values and none becomes a positive or non-positive finding;
/// an apparent contradiction is named rather than resolved; and a lane or summary
/// attributed to an artifact version the session was not bound to is refused instead of
/// recorded (Requirements 6.4, 7.1 through 7.8, and 7.13).
@Suite("Evidence Coordinator lane construction")
struct EvidenceCoordinatorTests {
    // MARK: Helpers

    /// A coordinator for a composition that matches `lane`.
    ///
    /// A session records a Provenance Policy version exactly when its composition can
    /// produce an available lane, so the binding follows the lane rather than being chosen
    /// independently.
    private func coordinator(
        for lane: ProvenanceLane,
        classifier: ApparentInconsistencyClassifier? = nil,
        fusionRuleID: ArtifactID? = nil
    ) -> EvidenceCoordinator {
        coordinator(
            binding: SessionSample.binding(
                provenancePolicyID: lane.isAvailable ? ProvenanceSample.policyID : nil,
                fusionRuleID: fusionRuleID
            ),
            classifier: classifier
        )
    }

    private func coordinator(
        binding: AnalysisSessionBinding,
        classifier: ApparentInconsistencyClassifier? = nil
    ) -> EvidenceCoordinator {
        guard let coordinator = EvidenceCoordinator(
            binding: binding,
            scope: SessionSample.scope,
            inconsistencyClassifier: classifier
        ) else {
            preconditionFailure("the coordinator fixture must accept its own inputs")
        }
        return coordinator
    }

    private func classifier(
        declaring combinations: Set<FusionLaneCombination>,
        catalog: ApprovedVerdictCopyCatalog = CopyCatalogSample.catalog()
    ) -> ApparentInconsistencyClassifier {
        guard let classifier = ApparentInconsistencyClassifier(
            catalog: catalog,
            contradictoryCombinations: combinations
        ) else {
            preconditionFailure("the classifier fixture must be constructible")
        }
        return classifier
    }

    private func report(
        _ coordinator: EvidenceCoordinator,
        pixel: PixelEvidence,
        provenance: ProvenanceLane,
        combinedSummary: CombinedSummary? = nil
    ) throws -> EvidenceReport {
        try coordinator.report(
            lanes: ResolvedEvidenceLanes(pixel: pixel, provenance: provenance),
            combinedSummary: combinedSummary,
            bytePreservationStatus: .originalBytes,
            inputQuality: SessionSample.inputQuality,
            onDeviceProcessing: true
        )
    }

    /// The declared set a classifier needs in order to answer for every enabled pair.
    private var everyEnabledCombination: Set<FusionLaneCombination> {
        Set(FusionLaneCombination.allCombinations)
    }

    // MARK: Both lanes reach the report unchanged

    @Test(
        "Both source lanes reach the report verbatim",
        arguments: PixelEvidence.allCases
    )
    func bothLanesAreCarriedVerbatim(pixel: PixelEvidence) throws {
        for lane in ProvenanceSample.allLanes {
            let report = try report(coordinator(for: lane), pixel: pixel, provenance: lane)

            #expect(report.pixel == pixel)
            #expect(report.provenance == lane)
            #expect(report.combinedSummary == nil)
            #expect(report.apparentInconsistency == nil)
            #expect(report.binding == coordinator(for: lane).binding)
            #expect(report.scope == SessionSample.scope)
        }
    }

    @Test("A joined pair of lanes is what the report carries")
    func joinedLanesAreTheReportInput() throws {
        let lanes = try #require(
            EvidenceLaneJoin.unresolved
                .resolving(pixel: .signalsConsistentWithAIGeneration)?
                .resolving(provenance: .available(ProvenanceSample.validated()))?
                .resolvedLanes
        )

        let report = try report(
            coordinator(for: lanes.provenance),
            pixel: lanes.pixel,
            provenance: lanes.provenance
        )

        #expect(report.pixel == lanes.pixel)
        #expect(report.provenance == lanes.provenance)
    }

    // MARK: Absent and insufficient add nothing

    @Test(
        "Absent provenance preserves the pixel lane and adds nothing",
        arguments: PixelEvidence.allCases
    )
    func absentProvenanceAddsNothing(pixel: PixelEvidence) throws {
        let lane = ProvenanceLane.available(.absent)
        // A classifier that declares every enabled pair is the hostile case: even then,
        // absence may only attach an explanatory notice, never a lane change.
        let report = try report(
            coordinator(for: lane, classifier: classifier(declaring: everyEnabledCombination)),
            pixel: pixel,
            provenance: lane
        )

        #expect(report.pixel == pixel)
        #expect(report.provenance == .available(.absent))
        #expect(report.provenance.category == .absent)
        #expect(report.combinedSummary == nil)
        #expect(report.apparentInconsistency == CopyCatalogSample.noticeKey)
    }

    @Test("Absent provenance without a classifier leaves the report with no notice")
    func absentProvenanceWithoutClassifier() throws {
        let lane = ProvenanceLane.available(.absent)

        for pixel in PixelEvidence.allCases {
            let report = try report(coordinator(for: lane), pixel: pixel, provenance: lane)

            #expect(report.pixel == pixel)
            #expect(report.provenance == lane)
            #expect(report.apparentInconsistency == nil)
            #expect(report.combinedSummary == nil)
        }
    }

    @Test("Insufficient pixel evidence preserves every enabled provenance state")
    func insufficientPixelEvidencePreservesProvenance() throws {
        for evidence in ProvenanceSample.allEnabledStates {
            let lane = ProvenanceLane.available(evidence)
            let report = try report(
                coordinator(for: lane),
                pixel: .notEnoughSignal,
                provenance: lane
            )

            #expect(report.pixel == .notEnoughSignal)
            #expect(report.provenance == lane)
            #expect(report.provenance.evidence == evidence)
            #expect(report.combinedSummary == nil)
        }
    }

    @Test("Absent, unavailable, and indeterminate stay three distinct lane states")
    func noEvidenceStatesAreNotCollapsed() throws {
        let absent = ProvenanceLane.available(.absent)
        let indeterminate = ProvenanceLane.available(ProvenanceSample.indeterminate())
        let unavailable = ProvenanceLane.unavailable(.validatorNotCompiledIntoRelease)

        let reports = try [absent, indeterminate, unavailable].map { lane in
            try report(coordinator(for: lane), pixel: .notEnoughSignal, provenance: lane)
        }

        #expect(reports[0].provenance == absent)
        #expect(reports[1].provenance == indeterminate)
        #expect(reports[2].provenance == unavailable)

        // Distinguishable through every discriminator the presenter reads, not merely
        // unequal as values.
        #expect(reports[0].provenance.category == .absent)
        #expect(reports[1].provenance.category == .indeterminate)
        #expect(reports[2].provenance.category == nil)
        #expect(reports[0].provenance.isAvailable)
        #expect(reports[1].provenance.isAvailable)
        #expect(reports[2].provenance.isAvailable == false)
        #expect(reports[0].provenance.unavailableReason == nil)
        #expect(reports[2].provenance.unavailableReason == .validatorNotCompiledIntoRelease)

        // No lane became a pixel finding, and the abstaining pixel lane stayed abstaining.
        #expect(Set(reports.map(\.pixel)) == [.notEnoughSignal])
    }

    // MARK: Apparent contradictions are retained, not resolved

    @Test("An undeclared combination attaches no notice")
    func undeclaredCombinationHasNoNotice() throws {
        let declared: Set<FusionLaneCombination> = [
            FusionLaneCombination(
                pixel: .signalsConsistentWithAIGeneration,
                provenance: .validated
            )
        ]
        let lane = ProvenanceLane.available(ProvenanceSample.validated())
        let report = try report(
            coordinator(for: lane, classifier: classifier(declaring: declared)),
            pixel: .noStrongSignalDetected,
            provenance: lane
        )

        #expect(report.apparentInconsistency == nil)
        #expect(report.pixel == .noStrongSignalDetected)
        #expect(report.provenance == lane)
    }

    @Test("A declared combination keeps both lanes and adds the approved notice")
    func declaredCombinationRetainsBothLanes() throws {
        let combination = FusionLaneCombination(
            pixel: .signalsConsistentWithAIGeneration,
            provenance: .validated
        )
        let lane = ProvenanceLane.available(ProvenanceSample.validated())
        let report = try report(
            coordinator(for: lane, classifier: classifier(declaring: [combination])),
            pixel: .signalsConsistentWithAIGeneration,
            provenance: lane
        )

        // Retained, not resolved: the notice is an approved key beside two unchanged lanes.
        #expect(report.apparentInconsistency == CopyCatalogSample.noticeKey)
        #expect(report.pixel == .signalsConsistentWithAIGeneration)
        #expect(report.provenance == lane)
        #expect(report.combinedSummary == nil)
    }

    @Test("The notice is the same whether or not a classifier changes the lanes")
    func noticeDoesNotChangeTheLanes() throws {
        let combination = FusionLaneCombination(
            pixel: .signalsConsistentWithAIGeneration,
            provenance: .validated
        )
        let lane = ProvenanceLane.available(ProvenanceSample.validated())
        let pixel = PixelEvidence.signalsConsistentWithAIGeneration

        let withoutNotice = try report(coordinator(for: lane), pixel: pixel, provenance: lane)
        let withNotice = try report(
            coordinator(for: lane, classifier: classifier(declaring: [combination])),
            pixel: pixel,
            provenance: lane
        )

        #expect(withoutNotice.apparentInconsistency == nil)
        #expect(withNotice.apparentInconsistency != nil)
        #expect(withNotice.pixel == withoutNotice.pixel)
        #expect(withNotice.provenance == withoutNotice.provenance)
    }

    @Test("A classifier never annotates an unavailable provenance lane")
    func unavailableLaneIsNeverInconsistent() throws {
        let declaring = classifier(declaring: everyEnabledCombination)

        for reason in UnavailableReason.allCases {
            let lane = ProvenanceLane.unavailable(reason)

            for pixel in PixelEvidence.allCases {
                #expect(declaring.notice(pixel: pixel, provenance: lane) == nil)

                let report = try report(
                    coordinator(for: lane, classifier: declaring),
                    pixel: pixel,
                    provenance: lane
                )
                #expect(report.apparentInconsistency == nil)
                #expect(report.provenance == lane)
            }
        }
    }

    @Test("A classifier answers for every enabled combination it declared")
    func declaredSetIsAnsweredExactly() {
        let declaring = classifier(declaring: everyEnabledCombination)

        for pixel in PixelEvidence.allCases {
            for evidence in ProvenanceSample.allEnabledStates {
                let notice = declaring.notice(pixel: pixel, provenance: .available(evidence))
                #expect(notice == CopyCatalogSample.noticeKey)
            }
        }
    }

    // MARK: A classifier needs approved copy

    @Test("A classifier cannot be built without the approved notice copy")
    func classifierNeedsApprovedNoticeCopy() {
        #expect(
            ApparentInconsistencyClassifier(
                catalog: CopyCatalogSample.catalog(omittingInconsistencyNotice: true),
                contradictoryCombinations: everyEnabledCombination
            ) == nil
        )
    }

    @Test("A classifier cannot be built from an unapproved catalogue")
    func classifierNeedsAnApprovedCatalogue() {
        #expect(
            ApparentInconsistencyClassifier(
                catalog: CopyCatalogSample.catalog(approval: .rejected),
                contradictoryCombinations: everyEnabledCombination
            ) == nil
        )
    }

    @Test("An empty declared set is not a classifier")
    func emptyDeclaredSetIsNotAClassifier() {
        #expect(
            ApparentInconsistencyClassifier(
                catalog: CopyCatalogSample.catalog(),
                contradictoryCombinations: []
            ) == nil
        )
    }

    @Test("A coordinator refuses a classifier bound to incompatible copy")
    func coordinatorRefusesIncompatibleCopy() {
        let incompatible = classifier(
            declaring: everyEnabledCombination,
            catalog: CopyCatalogSample.catalog(
                id: Fixture.artifactID("copy-catalog-0002"),
                compatibilityID: SessionSample.otherCopyCompatibilityID
            )
        )

        #expect(
            EvidenceCoordinator(
                binding: SessionSample.binding(provenancePolicyID: ProvenanceSample.policyID),
                scope: SessionSample.scope,
                inconsistencyClassifier: incompatible
            ) == nil
        )
    }

    // MARK: A Combined Summary sits beside both lanes

    @Test("Both source lanes are retained alongside a Combined Summary")
    func bothLanesSurviveACombinedSummary() throws {
        let lane = ProvenanceLane.available(ProvenanceSample.validated())
        let summary = CombinedSummary(
            copyKey: EvidenceSample.copyKey("copy.combined-summary.sample"),
            fusionRuleID: SessionSample.fusionRuleID
        )
        let report = try report(
            coordinator(for: lane, fusionRuleID: SessionSample.fusionRuleID),
            pixel: .signalsConsistentWithAIGeneration,
            provenance: lane,
            combinedSummary: summary
        )

        #expect(report.combinedSummary == summary)
        #expect(report.pixel == .signalsConsistentWithAIGeneration)
        #expect(report.provenance == lane)
    }

    @Test("A summary from a rule the session was not bound to is refused")
    func summaryFromAnUnboundRuleIsRefused() {
        let lane = ProvenanceLane.available(ProvenanceSample.validated())
        let summary = CombinedSummary(
            copyKey: EvidenceSample.copyKey("copy.combined-summary.sample"),
            fusionRuleID: SessionSample.otherFusionRuleID
        )

        #expect(
            throws: EvidenceJoinFault.combinedSummaryNotBoundToSession(
                expected: SessionSample.fusionRuleID,
                found: SessionSample.otherFusionRuleID
            )
        ) {
            try report(
                coordinator(for: lane, fusionRuleID: SessionSample.fusionRuleID),
                pixel: .noStrongSignalDetected,
                provenance: lane,
                combinedSummary: summary
            )
        }
    }

    @Test("A summary in a session with no bound rule is refused")
    func summaryWithoutABoundRuleIsRefused() {
        let lane = ProvenanceLane.available(ProvenanceSample.validated())
        let summary = CombinedSummary(
            copyKey: EvidenceSample.copyKey("copy.combined-summary.sample"),
            fusionRuleID: SessionSample.fusionRuleID
        )

        #expect(
            throws: EvidenceJoinFault.combinedSummaryNotBoundToSession(
                expected: nil,
                found: SessionSample.fusionRuleID
            )
        ) {
            try report(
                coordinator(for: lane),
                pixel: .noStrongSignalDetected,
                provenance: lane,
                combinedSummary: summary
            )
        }
    }

    @Test("A summary beside an unavailable lane is not representable")
    func summaryBesideUnavailableLaneIsRefused() {
        let lane = ProvenanceLane.unavailable(.validatorNotCompiledIntoRelease)
        let summary = CombinedSummary(
            copyKey: EvidenceSample.copyKey("copy.combined-summary.sample"),
            fusionRuleID: SessionSample.fusionRuleID
        )

        #expect(throws: EvidenceJoinFault.reportNotRepresentable) {
            try report(
                coordinator(for: lane, fusionRuleID: SessionSample.fusionRuleID),
                pixel: .noStrongSignalDetected,
                provenance: lane,
                combinedSummary: summary
            )
        }
    }

    // MARK: A lane must belong to the composition the session was bound to

    @Test("An available lane in a session bound to no policy is refused")
    func availableLaneNeedsABoundPolicy() {
        let lane = ProvenanceLane.available(ProvenanceSample.validated())

        #expect(
            throws: EvidenceJoinFault.provenanceLaneNotBoundToSession(
                expected: nil,
                found: ProvenanceSample.policyID
            )
        ) {
            try report(
                coordinator(binding: SessionSample.binding(provenancePolicyID: nil)),
                pixel: .noStrongSignalDetected,
                provenance: lane
            )
        }
    }

    @Test("An unavailable lane in a session bound to a policy is refused")
    func unavailableLaneRefusesABoundPolicy() {
        #expect(
            throws: EvidenceJoinFault.provenanceLaneNotBoundToSession(
                expected: ProvenanceSample.policyID,
                found: nil
            )
        ) {
            try report(
                coordinator(
                    binding: SessionSample.binding(
                        provenancePolicyID: ProvenanceSample.policyID
                    )
                ),
                pixel: .noStrongSignalDetected,
                provenance: .unavailable(.capabilityNotEnabledByReleaseCapabilityManifest)
            )
        }
    }

    @Test("A state attributed to another policy version is refused")
    func laneFromAnotherPolicyVersionIsRefused() {
        let lane = ProvenanceLane.available(
            ProvenanceSample.invalid(policyID: ProvenanceSample.otherPolicyID)
        )

        #expect(
            throws: EvidenceJoinFault.provenanceLaneNotBoundToSession(
                expected: ProvenanceSample.policyID,
                found: ProvenanceSample.otherPolicyID
            )
        ) {
            try report(
                coordinator(
                    binding: SessionSample.binding(
                        provenancePolicyID: ProvenanceSample.policyID
                    )
                ),
                pixel: .noStrongSignalDetected,
                provenance: lane
            )
        }
    }

    @Test("Absent names no policy and is accepted by any enabled composition")
    func absentIsAttributedToNoPolicy() throws {
        let lane = ProvenanceLane.available(.absent)
        let report = try report(
            coordinator(
                binding: SessionSample.binding(provenancePolicyID: ProvenanceSample.policyID)
            ),
            pixel: .noStrongSignalDetected,
            provenance: lane
        )

        #expect(report.provenance == lane)
    }

    // MARK: Neither analyzer reaches the other lane

    @Test("A provenance analyzer produces its lane without access to the pixel lane")
    func analyzerCannotReachThePixelLane() async throws {
        // The pixel lane is fixed before the analyzer runs, and the join keeps it as a
        // value. The analyzer receives an accepted ingest and a policy; there is no
        // parameter, return value, or member through which it could reach Pixel Evidence.
        let pixel = PixelEvidence.signalsConsistentWithAIGeneration
        let pixelResolved = try #require(EvidenceLaneJoin.unresolved.resolving(pixel: pixel))

        let asset = ProvenanceSample.asset()
        let policy = ProvenanceSample.policy()
        let analyzer = RecordingProvenanceAnalyzer(returning: ProvenanceSample.validated())
        let evidence = await analyzer.analyze(asset, policy: policy)

        #expect(analyzer.inspectedSessions == [asset.sessionID])
        #expect(analyzer.inspectedDigests == [asset.sha256])
        #expect(analyzer.appliedPolicies == [policy.id])

        let lanes = try #require(
            pixelResolved.resolving(provenance: .available(evidence))?.resolvedLanes
        )
        let report = try report(
            coordinator(for: lanes.provenance),
            pixel: lanes.pixel,
            provenance: lanes.provenance
        )

        // The pixel-only join is still exactly what the pixel branch produced.
        #expect(pixelResolved.pixel == pixel)
        #expect(pixelResolved.provenance == nil)
        #expect(report.pixel == pixel)
        #expect(report.provenance == .available(evidence))
    }

    @Test("A pixel-only composition joins the unavailable lane its provider resolved")
    func pixelOnlyCompositionJoinsTheUnavailableLane() async throws {
        let lane = await ProvenanceLaneProvider.pixelOnly.lane(for: ProvenanceSample.asset())
        let lanes = try #require(
            EvidenceLaneJoin.unresolved
                .resolving(pixel: .noStrongSignalDetected)?
                .resolving(provenance: lane)?
                .resolvedLanes
        )

        let report = try report(
            coordinator(for: lane, classifier: classifier(declaring: everyEnabledCombination)),
            pixel: lanes.pixel,
            provenance: lanes.provenance
        )

        #expect(report.provenance == .unavailable(.validatorNotCompiledIntoRelease))
        #expect(report.pixel == .noStrongSignalDetected)
        #expect(report.combinedSummary == nil)
        #expect(report.apparentInconsistency == nil)
        #expect(report.binding.provenancePolicyID == nil)
    }
}
