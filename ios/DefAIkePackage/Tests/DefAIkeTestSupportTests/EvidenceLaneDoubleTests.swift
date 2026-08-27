import DefAIkeDomain
import Testing

@testable import DefAIkeTestSupport

/// Covers the evidence-lane doubles and the key mapping they depend on.
///
/// The mapping between runtime evidence values and encoded artifact keys is the seam
/// where a fusion table could quietly look up the wrong row, so it is checked
/// exhaustively in both directions. The fusion double's own logic is the two
/// session-compatibility checks; the exhaustiveness and determinism of the table itself
/// belong to ``EvidenceFusionRule``, which proves them at construction.
@Suite("Evidence lane doubles and key mapping")
struct EvidenceLaneDoubleTests {

    // MARK: - Key mapping

    @Test("Pixel labels round trip through their artifact keys", arguments: PixelEvidence.allCases)
    func pixelLabelsRoundTrip(evidence: PixelEvidence) {
        #expect(evidence.labelKey.pixelEvidence == evidence)
        #expect(evidence.metricCategory == evidence.labelKey.requiredMetricCategory)
    }

    @Test(
        "Provenance categories round trip through their artifact keys",
        arguments: ProvenanceCategory.allCases
    )
    func provenanceCategoriesRoundTrip(category: ProvenanceCategory) {
        #expect(category.stateKey.provenanceCategory == category)
    }

    @Test("The unavailable lane has no artifact key, so it cannot be looked up")
    func unavailableLaneHasNoKey() {
        let lane = ProvenanceLane.unavailable(.validatorNotCompiledIntoRelease)
        #expect(lane.stateKey == nil)
        #expect(ProvenanceLane.available(.absent).stateKey == .absent)
    }

    @Test(
        "Byte preservation statuses round trip",
        arguments: BytePreservationStatus.allCases
    )
    func preservationStatusesRoundTrip(status: BytePreservationStatus) {
        #expect(status.statusKey.preservationStatus == status)
    }

    @Test("Analysis errors round trip", arguments: AnalysisError.allCases)
    func analysisErrorsRoundTrip(error: AnalysisError) {
        #expect(error.errorKey.analysisError == error)
        // The two vocabularies share the exact wire spelling the requirements name.
        #expect(error.rawValue == error.errorKey.rawValue)
    }

    // MARK: - Provenance double

    @Test("The provenance stub walks its programmed states and repeats the last")
    func provenanceStubWalksStates() async {
        let analyzer = StubProvenanceAnalyzer([.absent, .indeterminate(indeterminate())])
        let policy = ProvenanceFixture.policy()
        let asset = PortValue.asset()

        #expect(await analyzer.analyze(asset, policy: policy) == .absent)
        #expect(await analyzer.analyze(asset, policy: policy).category == .indeterminate)
        #expect(await analyzer.analyze(asset, policy: policy).category == .indeterminate)
    }

    // MARK: - Fusion double

    @Test("A bound compatible rule resolves the entry for the lane combination")
    func boundRuleResolvesItsEntry() throws {
        let recorder = PortCallRecorder()
        let fuser = StubEvidenceFuser(recorder: recorder)
        let rule = FusionFixture.rule(showingKey: "copy.combined-summary")
        let binding = FusionFixture.binding(fusionRuleID: rule.id)

        let summary = try fuser.resolve(
            pixel: .noStrongSignalDetected,
            provenance: .absent,
            rule: rule,
            binding: binding
        )

        #expect(summary?.fusionRuleID == rule.id)
        #expect(summary?.copyKey.rawValue == "copy.combined-summary")
        #expect(recorder.didCall(PortCallKind.fuse))
    }

    @Test("An omitting entry yields no summary rather than an error")
    func omissionIsAnOrdinaryResult() throws {
        let fuser = StubEvidenceFuser()
        let rule = FusionFixture.rule(showingKey: nil)
        let binding = FusionFixture.binding(fusionRuleID: rule.id)

        #expect(
            try fuser.resolve(
                pixel: .signalsConsistentWithAIGeneration,
                provenance: .absent,
                rule: rule,
                binding: binding
            ) == nil
        )
    }

    @Test("A rule the session is not bound to is refused")
    func unboundRuleIsRefused() {
        let fuser = StubEvidenceFuser()
        let rule = FusionFixture.rule(id: "fusion-0002", showingKey: "copy.combined-summary")
        let binding = FusionFixture.binding(fusionRuleID: PortValue.artifactID("fusion-0001"))

        #expect(
            throws: FusionFault.ruleNotBoundToSession(
                expected: PortValue.artifactID("fusion-0001"),
                found: rule.id
            )
        ) {
            _ = try fuser.resolve(
                pixel: .notEnoughSignal,
                provenance: .absent,
                rule: rule,
                binding: binding
            )
        }
    }

    @Test("A session with no bound rule refuses every rule")
    func sessionWithoutARuleRefusesFusion() {
        let fuser = StubEvidenceFuser()
        let rule = FusionFixture.rule(showingKey: "copy.combined-summary")
        let binding = FusionFixture.binding(fusionRuleID: nil)

        #expect(throws: FusionFault.ruleNotBoundToSession(expected: nil, found: rule.id)) {
            _ = try fuser.resolve(
                pixel: .notEnoughSignal,
                provenance: .absent,
                rule: rule,
                binding: binding
            )
        }
    }

    @Test("A rule whose copy catalogue is not the session's is refused")
    func incompatibleCopyCatalogIsRefused() {
        let fuser = StubEvidenceFuser()
        let rule = FusionFixture.rule(
            showingKey: "copy.combined-summary",
            verdictCopyID: "copy-0009"
        )
        let binding = FusionFixture.binding(
            fusionRuleID: rule.id,
            verdictCopyID: "copy-0001"
        )

        #expect(
            throws: FusionFault.incompatibleVerdictCopy(
                expected: PortValue.artifactID("copy-0001"),
                found: PortValue.artifactID("copy-0009")
            )
        ) {
            _ = try fuser.resolve(
                pixel: .notEnoughSignal,
                provenance: .absent,
                rule: rule,
                binding: binding
            )
        }
    }

    @Test("Every one of the 15 enabled combinations resolves through the double")
    func allFifteenCombinationsResolve() throws {
        let fuser = StubEvidenceFuser()
        let rule = FusionFixture.rule(showingKey: "copy.combined-summary")
        let binding = FusionFixture.binding(fusionRuleID: rule.id)
        var resolved = 0

        for pixel in PixelEvidence.allCases {
            for provenance in FusionFixture.allEnabledStates {
                let summary = try fuser.resolve(
                    pixel: pixel,
                    provenance: provenance,
                    rule: rule,
                    binding: binding
                )
                #expect(summary != nil)
                resolved += 1
            }
        }

        #expect(resolved == FusionLaneCombination.requiredCombinationCount)
    }

    // MARK: - Photos importer double

    @Test("The photos importer records the session it imported into")
    func photosImporterRecordsSession() async throws {
        let recorder = PortCallRecorder()
        let sessionID = PortValue.sessionID()
        let importer = StubPhotosImporter(
            outcome: StubOutcome(always: PortValue.asset(sessionID: sessionID)),
            recorder: recorder
        )

        let asset = try await importer.importOne(PortValue.pickerItem(), into: sessionID)

        #expect(asset.route == .photosPicker)
        #expect(asset.sessionID == sessionID)
        #expect(recorder.callKinds == [.photosImport])
    }

    @Test("A provider that fails before any byte creates no ingest")
    func failingProviderYieldsNoAsset() async {
        let recorder = PortCallRecorder()
        let importer = StubPhotosImporter.alwaysFailingProvider(recorder: recorder)

        await #expect(throws: AnalysisFault.self) {
            _ = try await importer.importOne(PortValue.pickerItem(), into: PortValue.sessionID())
        }
        #expect(recorder.callKinds == [.photosImport])
    }

    @Test("Only exactly one selected item can be imported")
    func onlyOneItemIsSelectable() {
        #expect(PortValue.pickerSelection(itemCount: 0).soleItem == nil)
        #expect(PortValue.pickerSelection(itemCount: 0).isCancellation)
        #expect(PortValue.pickerSelection(itemCount: 1).soleItem != nil)
        #expect(PortValue.pickerSelection(itemCount: 2).soleItem == nil)
        #expect(!PortValue.pickerSelection(itemCount: 2).isCancellation)
    }

    // MARK: - Helpers

    private func indeterminate() -> IndeterminateSummary {
        IndeterminateSummary(
            provenancePolicyID: PortValue.artifactID("provenance-0001"),
            explanationKey: FusionFixture.copyKey("copy.indeterminate")
        )
    }
}
