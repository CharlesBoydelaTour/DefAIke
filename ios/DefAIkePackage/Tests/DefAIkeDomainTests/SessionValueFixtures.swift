import Foundation

@testable import DefAIkeDomain

// Synthetic core session values, for the foundational schema and vocabulary tests.
//
// `Sample` covers the release-artifact layer. This is the session layer: bindings,
// quality records, provenance lanes, reports, failure snapshots, and Share tickets.
// Nothing here is an approved identifier, digest, device, bundle, or policy version;
// every value exists so a test can build the full outcome matrix and assert what the
// domain refuses to represent.
//
// Builders return optionals rather than throwing, matching the `init?` shape of the
// values themselves: a test that expects a rejection reads it as `nil`, and a test
// that needs a valid value unwraps it.
enum SessionValue {

    // MARK: Identifiers

    static func session(_ value: String = "session.sample") -> AnalysisSessionID {
        AnalysisSessionID(value)!
    }

    static func transfer(_ value: String = "transfer.sample") -> ShareTransferID {
        ShareTransferID(value)!
    }

    static func artifact(_ value: String) -> ArtifactID {
        ArtifactID(value)!
    }

    static func copyKey(_ value: String) -> ApprovedCopyKey {
        ApprovedCopyKey(value)!
    }

    static func digest(_ character: Character = "a") -> SHA256Digest {
        SHA256Digest(hexadecimal: String(repeating: character, count: 64))!
    }

    static func text(_ value: String = "Example Signer") -> DisplaySafeText {
        DisplaySafeText(value)!
    }

    // MARK: Binding

    static func integrity() -> VerifiedBundleIntegrity {
        VerifiedBundleIntegrity(
            status: .verified,
            activationReceiptID: artifact("receipt.activation"),
            verificationPolicyID: artifact("policy.bundle-verification"),
            verifiedManifestDigest: digest("1"),
            verifiedArtifactDigests: [
                ArtifactDigestRecord(
                    path: CanonicalRelativePath("artifacts/model.mlmodelc")!,
                    kind: .directoryTree,
                    byteCount: 4096,
                    digest: digest("2")
                )
            ]
        )!
    }

    static func binding(
        provenanceEnabled: Bool = false,
        fusionEnabled: Bool = false
    ) -> AnalysisSessionBinding {
        AnalysisSessionBinding(
            sessionID: session(),
            appBuildID: AppBuildID("build.sample")!,
            deviceConfigurationID: ApprovedConfigurationID("configuration.sample")!,
            modelBundleID: ModelBundleID("bundle.sample")!,
            modelIdentity: RequiredPixelModel.identity,
            coreMLModelVersion: artifact("component.coreml"),
            modelBundleIntegrity: integrity(),
            preprocessingContractID: artifact("contract.preprocessing"),
            calibrationPolicyID: artifact("policy.calibration"),
            verdictCopyCompatibilityID: artifact("copy.compatibility"),
            capabilityManifestID: artifact("manifest.capability"),
            provenancePolicyID: provenanceEnabled ? artifact("policy.provenance") : nil,
            fusionRuleID: fusionEnabled ? artifact("rule.fusion") : nil,
            lifecyclePolicyID: artifact("policy.lifecycle"),
            resourceBudgetID: artifact("budget.main-application")
        )
    }

    // MARK: Input quality

    static func quality(width: Int = 900, height: Int = 600) -> InputQualityRecord {
        InputQualityRecord(
            decodedWidthBeforeOrientation: width,
            decodedHeightBeforeOrientation: height,
            validatedFeatures: [
                QualityFeatureID("quality.short-edge")!: .integer(min(width, height)),
                QualityFeatureID("quality.animated")!: .boolean(false),
            ]
        )!
    }

    // MARK: Provenance lanes

    static let provenancePolicyID = ArtifactID("policy.provenance")!

    /// The five enabled provenance states, in `ProvenanceCategory.allCases` order.
    static let enabledEvidence: [ProvenanceEvidence] = [
        .validated(
            ValidatedClaimSummary(
                provenancePolicyID: provenancePolicyID,
                bindingStatus: .boundToInspectedBytes,
                signerFields: [
                    DisplaySafeField(
                        labelKey: ApprovedCopyKey("copy.provenance.signer")!,
                        value: DisplaySafeText("Example Signer")!
                    )
                ],
                assertionFields: []
            )
        ),
        .invalid(
            InvaliditySummary(
                provenancePolicyID: provenancePolicyID,
                category: .byteBinding,
                explanationKey: ApprovedCopyKey("copy.provenance.invalid")!
            )
        ),
        .absent,
        .unsupported(
            UnsupportedFeatureSummary(
                provenancePolicyID: provenancePolicyID,
                explanationKey: ApprovedCopyKey("copy.provenance.unsupported")!,
                unsupportedFeatures: [DisplaySafeText("example feature")!]
            )
        ),
        .indeterminate(
            IndeterminateSummary(
                provenancePolicyID: provenancePolicyID,
                explanationKey: ApprovedCopyKey("copy.provenance.indeterminate")!
            )
        ),
    ]

    /// Every representable lane: two unavailable reasons and five enabled states.
    static let allLanes: [ProvenanceLane] =
        UnavailableReason.allCases.map { ProvenanceLane.unavailable($0) }
        + enabledEvidence.map { ProvenanceLane.available($0) }

    /// One completed report for every pixel label crossed with every lane.
    static let allReports: [EvidenceReport] = PixelEvidence.allCases.flatMap { pixel in
        allLanes.compactMap { report(pixel: pixel, provenance: $0) }
    }

    // MARK: Terminal values

    static func summary() -> CombinedSummary {
        CombinedSummary(
            copyKey: copyKey("copy.fusion.summary"),
            fusionRuleID: artifact("rule.fusion")
        )
    }

    static func report(
        schemaVersion: Int = EvidenceReport.currentSchemaVersion,
        pixel: PixelEvidence = .noStrongSignalDetected,
        provenance: ProvenanceLane = .available(.absent),
        combinedSummary: CombinedSummary? = nil,
        apparentInconsistency: ApprovedCopyKey? = nil,
        bytePreservationStatus: BytePreservationStatus = .unknown,
        inputQuality: InputQualityRecord? = nil,
        onDeviceProcessing: Bool = true
    ) -> EvidenceReport? {
        EvidenceReport(
            schemaVersion: schemaVersion,
            binding: binding(
                provenanceEnabled: provenance.isAvailable,
                fusionEnabled: combinedSummary != nil
            ),
            pixel: pixel,
            provenance: provenance,
            combinedSummary: combinedSummary,
            apparentInconsistency: apparentInconsistency,
            bytePreservationStatus: bytePreservationStatus,
            inputQuality: inputQuality ?? quality(),
            onDeviceProcessing: onDeviceProcessing,
            scope: .version1(id: artifact("component.scope"))
        )
    }

    static func snapshot(
        schemaVersion: Int = AnalysisFailureSnapshot.currentSchemaVersion,
        error: AnalysisError = .decodingError,
        stage: AnalysisStage = .inputValidation,
        bytePreservationStatus: BytePreservationStatus? = .unknown,
        inputQuality: InputQualityRecord? = nil
    ) -> AnalysisFailureSnapshot? {
        AnalysisFailureSnapshot(
            schemaVersion: schemaVersion,
            sessionID: session(),
            error: error,
            stage: stage,
            bytePreservationStatus: bytePreservationStatus,
            inputQuality: inputQuality ?? quality()
        )
    }

    static func ticket(
        schemaVersion: Int = ShareTransferTicket.currentSchemaVersion,
        route: InputRoute = .shareExtension,
        byteCount: UInt64 = 2048,
        preservationStatus: BytePreservationStatus = .originalBytes,
        preservationBasis: PreservationBasis = .providerDeclaredOriginalRepresentation
    ) -> ShareTransferTicket? {
        ShareTransferTicket(
            schemaVersion: schemaVersion,
            transferID: transfer(),
            sessionID: session(),
            route: route,
            contentTypeHint: ContentTypeHint("public.jpeg"),
            byteCount: byteCount,
            sha256: digest("3"),
            preservationStatus: preservationStatus,
            preservationBasis: preservationBasis,
            extensionBuildID: AppBuildID("build.sample")!,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}
