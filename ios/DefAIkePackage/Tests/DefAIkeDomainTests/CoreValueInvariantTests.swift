import Testing

@testable import DefAIkeDomain

/// Covers the structural invariants the task 1.2 core values enforce at
/// construction and decoding time.
///
/// The full foundational schema matrix — schema-version handling, every enum round
/// trip, unknown-required-semantics rejection, and the probability-free field audit
/// — is task 1.5. These tests check that each invariant this task introduced
/// actually holds, so a later task cannot build an unrepresentable value by
/// accident.
@Suite("Core domain value invariants")
struct CoreValueInvariantTests {

    // MARK: - Fixtures

    private static func artifact(_ rawValue: String) -> ArtifactID {
        guard let id = ArtifactID(rawValue) else {
            fatalError("test fixture identifier is not canonical: \(rawValue)")
        }
        return id
    }

    private static func copyKey(_ rawValue: String) -> ApprovedCopyKey {
        guard let key = ApprovedCopyKey(rawValue) else {
            fatalError("test fixture copy key is not canonical: \(rawValue)")
        }
        return key
    }

    private static func digest(_ byte: UInt8) -> SHA256Digest {
        guard let digest = SHA256Digest(bytes: Array(repeating: byte, count: 32)) else {
            fatalError("32 bytes must produce a digest")
        }
        return digest
    }

    private static func binding() -> AnalysisSessionBinding {
        guard
            let sessionID = AnalysisSessionID("session-0001"),
            let buildID = AppBuildID("build-0001"),
            let configurationID = ApprovedConfigurationID("configuration-0001"),
            let bundleID = ModelBundleID("bundle-0001"),
            let checkpoint = ModelCheckpointIdentifier("Example/checkpoint-0000-00"),
            let integrity = VerifiedBundleIntegrity(
                status: .verified,
                activationReceiptID: artifact("receipt-0001"),
                verificationPolicyID: artifact("verification-policy-0001"),
                verifiedManifestDigest: digest(0x11),
                verifiedArtifactDigests: [
                    ArtifactDigestRecord(
                        path: path("artifacts/model.mlmodelc"),
                        kind: .directoryTree,
                        byteCount: 4096,
                        digest: digest(0x22)
                    )
                ]
            )
        else {
            fatalError("test fixture binding could not be constructed")
        }
        return AnalysisSessionBinding(
            sessionID: sessionID,
            appBuildID: buildID,
            deviceConfigurationID: configurationID,
            modelBundleID: bundleID,
            modelIdentity: ModelIdentity(
                checkpointIdentifier: checkpoint,
                requiredWeightDigest: digest(0x33)
            ),
            coreMLModelVersion: artifact("coreml-model-0001"),
            modelBundleIntegrity: integrity,
            preprocessingContractID: artifact("preprocessing-0001"),
            calibrationPolicyID: artifact("calibration-0001"),
            verdictCopyCompatibilityID: artifact("copy-0001"),
            capabilityManifestID: artifact("capability-0001"),
            provenancePolicyID: nil,
            fusionRuleID: nil,
            lifecyclePolicyID: artifact("lifecycle-0001"),
            resourceBudgetID: artifact("budget-0001")
        )
    }

    private static func path(_ rawValue: String) -> CanonicalRelativePath {
        guard let path = CanonicalRelativePath(rawValue) else {
            fatalError("test fixture path is not canonical: \(rawValue)")
        }
        return path
    }

    private static func quality(width: Int, height: Int) -> InputQualityRecord {
        guard let record = InputQualityRecord(
            decodedWidthBeforeOrientation: width,
            decodedHeightBeforeOrientation: height
        ) else {
            fatalError("positive dimensions must produce a record")
        }
        return record
    }

    private static func report(
        provenance: ProvenanceLane,
        combinedSummary: CombinedSummary? = nil,
        apparentInconsistency: ApprovedCopyKey? = nil
    ) -> EvidenceReport? {
        EvidenceReport(
            binding: binding(),
            pixel: .noStrongSignalDetected,
            provenance: provenance,
            combinedSummary: combinedSummary,
            apparentInconsistency: apparentInconsistency,
            bytePreservationStatus: .unknown,
            inputQuality: quality(width: 900, height: 600),
            onDeviceProcessing: true,
            scope: .version1(id: artifact("scope-0001"))
        )
    }

    // MARK: - Identifiers

    @Test("Identifiers reject empty, overlong, and noncanonical text")
    func identifierSyntax() {
        #expect(ArtifactID("") == nil)
        #expect(ArtifactID("has space") == nil)
        #expect(ArtifactID("has\nnewline") == nil)
        #expect(ArtifactID(String(repeating: "a", count: 257)) == nil)
        #expect(ArtifactID(String(repeating: "a", count: 256)) != nil)
        #expect(ModelCheckpointIdentifier("Example/checkpoint-2026-08") != nil)
        #expect(DeviceHardwareID("iPhone18,1") != nil)
        #expect(ArtifactID("artifact,with-comma") == nil)
    }

    @Test("A digest accepts exactly 32 bytes and canonical lowercase hexadecimal")
    func digestSyntax() {
        #expect(SHA256Digest(bytes: Array(repeating: 0, count: 31)) == nil)
        #expect(SHA256Digest(bytes: Array(repeating: 0, count: 33)) == nil)

        let hexadecimal = String(repeating: "ab", count: 32)
        let parsed = SHA256Digest(hexadecimal: hexadecimal)
        #expect(parsed?.hexadecimalString == hexadecimal)
        #expect(SHA256Digest(hexadecimal: hexadecimal.uppercased()) == nil)
        #expect(SHA256Digest(hexadecimal: String(repeating: "ab", count: 31)) == nil)
    }

    @Test("A canonical relative path rejects traversal and absolute forms")
    func relativePathSyntax() {
        #expect(CanonicalRelativePath("artifacts/model.mlmodelc") != nil)
        #expect(CanonicalRelativePath("/artifacts/model") == nil)
        #expect(CanonicalRelativePath("artifacts/../secret") == nil)
        #expect(CanonicalRelativePath("artifacts/./model") == nil)
        #expect(CanonicalRelativePath("artifacts//model") == nil)
        #expect(CanonicalRelativePath("artifacts\\model") == nil)
        #expect(CanonicalRelativePath("") == nil)
    }

    // MARK: - Byte preservation

    @Test("Every preservation basis supports exactly one conservative status")
    func preservationBasisIsConservative() {
        #expect(
            PreservationBasis.providerDeclaredOriginalRepresentation.mostConservativeStatus
                == .originalBytes
        )
        #expect(
            PreservationBasis.providerDeclaredTransformedRepresentation
                .mostConservativeStatus == .platformTransformedCopy
        )
        // Requesting a "current" representation is not proof of byte originality.
        #expect(
            PreservationBasis.providerDeclaredCurrentRepresentationOnly
                .mostConservativeStatus == .unknown
        )
        #expect(
            PreservationBasis.preservationHistoryNotEstablished.mostConservativeStatus
                == .unknown
        )
        #expect(
            !PreservationBasis.preservationHistoryNotEstablished.supports(.originalBytes)
        )
    }

    // MARK: - Input quality

    @Test("A quality record derives the short edge and rejects inconsistent input")
    func qualityRecordShortEdge() {
        #expect(Self.quality(width: 900, height: 600).shortEdgeBeforeOrientation == 600)
        #expect(Self.quality(width: 439, height: 440).shortEdgeBeforeOrientation == 439)
        #expect(InputQualityRecord.unmeasured.shortEdgeBeforeOrientation == nil)
        #expect(
            InputQualityRecord(
                decodedWidthBeforeOrientation: 0,
                decodedHeightBeforeOrientation: 100
            ) == nil
        )
        #expect(
            InputQualityRecord(
                decodedWidthBeforeOrientation: 100,
                decodedHeightBeforeOrientation: nil
            ) == nil
        )
        #expect(
            InputQualityRecord(
                schemaVersion: InputQualityRecord.currentSchemaVersion + 1,
                decodedWidthBeforeOrientation: 900,
                decodedHeightBeforeOrientation: 600
            ) == nil
        )
    }

    // MARK: - Provenance lane

    @Test("An unavailable lane exposes no evidence and no fusion category")
    func unavailableLaneBypassesFusion() {
        let lane = ProvenanceLane.unavailable(.validatorNotCompiledIntoRelease)
        #expect(lane.evidence == nil)
        #expect(lane.category == nil)
        #expect(!lane.isAvailable)
        #expect(lane.unavailableReason == .validatorNotCompiledIntoRelease)
    }

    @Test("Each enabled provenance state maps to exactly one distinct category")
    func enabledStateCategoriesAreDistinct() {
        let policyID = Self.artifact("provenance-policy-0001")
        let explanation = Self.copyKey("provenance.explanation.example")
        let states: [ProvenanceEvidence] = [
            .validated(
                ValidatedClaimSummary(
                    provenancePolicyID: policyID,
                    bindingStatus: .boundToInspectedBytes,
                    signerFields: [],
                    assertionFields: []
                )
            ),
            .invalid(
                InvaliditySummary(
                    provenancePolicyID: policyID,
                    category: .byteBinding,
                    explanationKey: explanation
                )
            ),
            .absent,
            .unsupported(
                UnsupportedFeatureSummary(
                    provenancePolicyID: policyID,
                    explanationKey: explanation,
                    unsupportedFeatures: []
                )
            ),
            .indeterminate(
                IndeterminateSummary(
                    provenancePolicyID: policyID,
                    explanationKey: explanation
                )
            ),
        ]

        let categories = states.map(\.category)
        #expect(Set(categories).count == ProvenanceCategory.allCases.count)
        #expect(Set(categories) == Set(ProvenanceCategory.allCases))
    }

    @Test("Display-safe text rejects unbounded and unsafe values")
    func displaySafeTextSyntax() {
        #expect(DisplaySafeText("Example Signer") != nil)
        #expect(DisplaySafeText("") == nil)
        #expect(DisplaySafeText("   ") == nil)
        #expect(DisplaySafeText("line\nbreak") == nil)
        #expect(DisplaySafeText("bidi\u{202E}override") == nil)
        #expect(
            DisplaySafeText(
                String(repeating: "a", count: DisplaySafeText.maximumCharacterCount + 1)
            ) == nil
        )
    }

    // MARK: - Evidence report

    @Test("A verified integrity projection needs unique nonempty digests")
    func integrityProjectionRejectsAmbiguousInventory() {
        let duplicate = ArtifactDigestRecord(
            path: Self.path("artifacts/model.mlmodelc"),
            kind: .directoryTree,
            byteCount: 4096,
            digest: Self.digest(0x22)
        )
        #expect(
            VerifiedBundleIntegrity(
                status: .verified,
                activationReceiptID: Self.artifact("receipt-0001"),
                verificationPolicyID: Self.artifact("verification-policy-0001"),
                verifiedManifestDigest: Self.digest(0x11),
                verifiedArtifactDigests: []
            ) == nil
        )
        #expect(
            VerifiedBundleIntegrity(
                status: .verified,
                activationReceiptID: Self.artifact("receipt-0001"),
                verificationPolicyID: Self.artifact("verification-policy-0001"),
                verifiedManifestDigest: Self.digest(0x11),
                verifiedArtifactDigests: [duplicate, duplicate]
            ) == nil
        )
    }

    @Test("An evidence scope must state every required covered and uncovered scope")
    func evidenceScopeCompleteness() {
        let id = Self.artifact("scope-0001")
        #expect(EvidenceScope.version1(id: id).includedStatements == [.wholeImageSynthesis])
        #expect(
            EvidenceScope.version1(id: id).excludedStatements
                == EvidenceScope.requiredExcludedStatements
        )
        #expect(
            EvidenceScope(
                id: id,
                includedStatements: [.wholeImageSynthesis],
                excludedStatements: EvidenceScope.requiredExcludedStatements
                    .subtracting([.audio])
            ) == nil
        )
        #expect(
            EvidenceScope(
                id: id,
                includedStatements: [],
                excludedStatements: EvidenceScope.requiredExcludedStatements
            ) == nil
        )
        #expect(
            EvidenceScope(
                id: id,
                includedStatements: [.wholeImageSynthesis, .video],
                excludedStatements: EvidenceScope.requiredExcludedStatements
            ) == nil
        )
    }

    @Test("An unavailable provenance lane cannot carry fusion or inconsistency copy")
    func unavailableLaneForbidsSummaryAndInconsistency() {
        let unavailable = ProvenanceLane.unavailable(.validatorNotCompiledIntoRelease)
        #expect(Self.report(provenance: unavailable) != nil)
        #expect(
            Self.report(
                provenance: unavailable,
                combinedSummary: CombinedSummary(
                    copyKey: Self.copyKey("fusion.summary.example"),
                    fusionRuleID: Self.artifact("fusion-0001")
                )
            ) == nil
        )
        #expect(
            Self.report(
                provenance: unavailable,
                apparentInconsistency: Self.copyKey("inconsistency.example")
            ) == nil
        )
        #expect(
            Self.report(
                provenance: .available(.absent),
                apparentInconsistency: Self.copyKey("inconsistency.example")
            ) != nil
        )
    }

    // MARK: - Progress

    @Test("Only a usable determinate measurement yields a fraction")
    func progressFractionRequiresUsableMeasurement() {
        #expect(
            AnalysisProgressState.determinate(
                completed: 5, total: 10, unit: .encodedBytes, stage: .inputValidation
            ).fractionOfWorkCompleted == 0.5
        )
        #expect(
            AnalysisProgressState.indeterminate(stage: .inference)
                .fractionOfWorkCompleted == nil
        )
        #expect(
            AnalysisProgressState.determinate(
                completed: 0, total: 0, unit: .encodedBytes, stage: .inputValidation
            ).fractionOfWorkCompleted == nil
        )
        #expect(
            AnalysisProgressState.determinate(
                completed: 11, total: 10, unit: .imageRows, stage: .preprocessing
            ).fractionOfWorkCompleted == nil
        )
    }

    // MARK: - Terminal outcomes

    @Test("Analysis errors keep their exact required raw values")
    func analysisErrorRawValues() {
        #expect(AnalysisError.allCases.count == 10)
        #expect(
            AnalysisError.allCases.map(\.rawValue) == [
                "unsupported-media",
                "unsupported-static-format",
                "decoding-error",
                "resource-limit",
                "preprocessing-error",
                "model-load-error",
                "inference-error",
                "invalid-output-error",
                "calibration-input-error",
                "handoff-error",
            ]
        )
    }

    @Test("Terminal outcomes are disjoint and evidence-free unless completed")
    func terminalOutcomesAreDisjoint() {
        guard
            let report = Self.report(provenance: .available(.absent)),
            let sessionID = AnalysisSessionID("session-0002"),
            let snapshot = AnalysisFailureSnapshot(
                sessionID: sessionID,
                error: .decodingError,
                stage: .inputValidation,
                bytePreservationStatus: .unknown,
                inputQuality: Self.quality(width: 900, height: 600)
            )
        else {
            Issue.record("terminal outcome fixtures could not be constructed")
            return
        }

        let outcomes: [SessionTerminalOutcome] = [
            .completed(report), .cancelled, .failed(snapshot),
        ]

        for outcome in outcomes {
            let flags = [outcome.isCompleted, outcome.isCancelled, outcome.isFailed]
            #expect(flags.filter { $0 }.count == 1)
            if !outcome.isCompleted {
                #expect(outcome.evidenceReport == nil)
            }
            if !outcome.isFailed {
                #expect(outcome.error == nil)
            }
        }

        #expect(SessionTerminalOutcome.completed(report).endReason == .completed)
        #expect(SessionTerminalOutcome.cancelled.endReason == .cancelled)
        #expect(SessionTerminalOutcome.failed(snapshot).endReason == .error)
        // A failure preserves what was measured, and carries no evidence field.
        #expect(snapshot.error == .decodingError)
        #expect(snapshot.inputQuality?.shortEdgeBeforeOrientation == 600)
    }
}
