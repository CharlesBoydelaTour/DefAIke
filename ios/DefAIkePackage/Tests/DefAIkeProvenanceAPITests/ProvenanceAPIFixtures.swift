import Foundation

@testable import DefAIkeDomain
@testable import DefAIkeProvenanceAPI

// Deliberately synthetic sample values for the provenance contract tests.
//
// **Nothing here is an approved release input.** The trust store, revocation behavior,
// status mapping, displayable fields, limits, copy keys, and capability manifest are
// placeholders for schema shape only. Every one of them is an unresolved external
// decision (design decision D5 and the Provenance Feasibility Gate), and no test
// asserts that a value here is correct: the tests assert what the *mapping* does with a
// given approved input, and what happens when one field is changed.
//
// This target cannot import DefAIkeTestSupport — the doubles module belongs to no
// product and is not a dependency of this test target — so the small spy below is local.

// MARK: - Sample scalars

enum Sample {
    static func artifact(_ value: String = "artifact.sample") -> ArtifactID {
        ArtifactID(value)!
    }

    static func copyKey(_ value: String) -> ApprovedCopyKey {
        ApprovedCopyKey(value)!
    }

    static func session(_ value: String = "session.sample") -> AnalysisSessionID {
        AnalysisSessionID(value)!
    }

    static func storageKey(_ value: String = "object.sample") -> EphemeralStorageKey {
        EphemeralStorageKey(value)!
    }

    static func status(_ value: String) -> ProvenanceValidatorStatusID {
        ProvenanceValidatorStatusID(value)!
    }

    static func text(_ value: String) -> ArtifactText {
        try! ArtifactText(validating: value)
    }

    static func display(_ value: String) -> DisplaySafeText {
        DisplaySafeText(value)!
    }

    static func version(_ value: String = "1.0.0") -> SchemaSemanticVersion {
        try! SchemaSemanticVersion(validating: value)
    }

    static func digest(_ character: Character = "a") -> DefAIkeDomain.SHA256Digest {
        DefAIkeDomain.SHA256Digest(hexadecimal: String(repeating: character, count: 64))!
    }

    static func evidence(_ identifier: String = "evidence.sample") -> EvidenceSource {
        EvidenceSource(
            artifact: artifact(identifier),
            version: version(),
            contentDigest: digest()
        )
    }

    static func approval(_ decision: ApprovalDecision = .approved) -> ApprovalRecord {
        ApprovalRecord(
            source: evidence("approval.sample"),
            decision: decision,
            approver: ApproverID("role.release-owner")!,
            decidedAt: Date(timeIntervalSince1970: 0)
        )
    }

    /// One accepted ingest. The digest and byte count are the measurements a real
    /// streaming copy would have produced; only their identity matters here.
    static func asset(
        session identifier: String = "session.sample",
        byteCount: UInt64 = 4_096,
        digestCharacter: Character = "b"
    ) -> ImportedEncodedAsset {
        let sessionID = session(identifier)
        let handle = EncodedAssetHandle(
            sessionID: sessionID,
            storageKey: storageKey("object.\(identifier)"),
            byteCount: byteCount,
            sha256: digest(digestCharacter),
            protection: .complete
        )!
        return ImportedEncodedAsset(
            route: .photosPicker,
            handle: handle,
            preservationStatus: .originalBytes,
            preservationBasis: .providerDeclaredOriginalRepresentation,
            contentTypeHint: ContentTypeHint("public.jpeg")
        )!
    }
}

// MARK: - Sample artifacts

enum PolicySample {
    static let validatedStatus = Sample.status("status.signature-valid")
    static let invalidStatus = Sample.status("status.signature-invalid")
    static let absentStatus = Sample.status("status.no-manifest")
    static let unsupportedStatus = Sample.status("status.unsupported-feature")
    static let indeterminateStatus = Sample.status("status.inconclusive")
    static let unmappedStatus = Sample.status("status.not-in-policy")

    /// Every status mapped to exactly one state, so the mapping tests exercise all five
    /// enabled states through one policy.
    static let statusMappings: [ProvenanceStatusMapping] = [
        .init(status: validatedStatus, state: .validated),
        .init(status: invalidStatus, state: .invalid),
        .init(status: absentStatus, state: .absent),
        .init(status: unsupportedStatus, state: .unsupported),
        .init(status: indeterminateStatus, state: .indeterminate),
    ]

    static func policy(
        id: String = "provenance.sample",
        implementationVersion: String = "0.0.12",
        displayableFields: Set<ProvenanceDisplayField> = [
            .signerIdentity, .claimGenerator, .assertionLabels,
        ],
        maximumAssertionCount: Int = 8,
        statusMappings: [ProvenanceStatusMapping] = PolicySample.statusMappings,
        feasibility: ApprovalDecision = .approved
    ) -> ProvenancePolicy {
        do {
            return try ProvenancePolicy(
                id: Sample.artifact(id),
                schemaVersion: .v1,
                capability: .contentCredentialValidation,
                validatorImplementationVersion: Sample.version(implementationVersion),
                validatorBinaryDigest: Sample.digest("c"),
                supportedSpecification: Sample.evidence("specification.sample"),
                trustStore: try ProvenanceTrustStoreDescriptor(
                    store: Sample.evidence("trust-store.sample"),
                    anchorCount: try PositiveCount(validating: 1),
                    isOfflineOnly: true
                ),
                revocationBehavior: try ProvenanceRevocationBehavior(
                    permitsNetworkRevocationCheck: false,
                    unavailableAnswerState: .indeterminate,
                    approval: Sample.approval()
                ),
                supportedAssertionLabels: [Sample.text("c2pa.actions")],
                displayableFields: displayableFields,
                processingLimits: ProvenanceProcessingLimits(
                    maximumManifestByteCount: try PositiveByteCount(validating: 65_536),
                    maximumAssertionCount: try PositiveCount(validating: maximumAssertionCount),
                    maximumNestingDepth: try PositiveCount(validating: 4),
                    maximumProcessingDuration: try ValidatedDuration(validating: 5_000)
                ),
                resourceBudget: Sample.artifact("budget.main-application"),
                statusMappings: statusMappings,
                feasibilityApproval: Sample.approval(feasibility)
            )
        } catch {
            preconditionFailure("the provenance policy sample must be schema-valid: \(error)")
        }
    }
}

enum CopySample {
    /// Localization key stems for the five enabled provenance states.
    static func stateKey(_ state: ProvenanceStateKey) -> ApprovedCopyKey {
        Sample.copyKey("copy.provenance.state.\(state.rawValue)")
    }

    static func fieldKey(_ field: ProvenanceDisplayField) -> ApprovedCopyKey {
        Sample.copyKey("copy.provenance.field.\(field.rawValue)")
    }

    /// Detail labels covering exactly one policy's displayable fields.
    static func detailLabels(for policy: ProvenancePolicy) -> [ProvenanceDisplayField: ApprovedCopyKey] {
        Dictionary(uniqueKeysWithValues: policy.displayableFields.map { ($0, fieldKey($0)) })
    }

    /// A catalogue carrying copy for every unconditional surface plus, unless a state is
    /// omitted, all five enabled provenance states.
    static func catalog(
        id: String = "copy.sample",
        compatibilityID: String = "copy-compatibility.sample",
        omitting omitted: ProvenanceStateKey? = nil,
        approval decision: ApprovalDecision = .approved
    ) -> ApprovedVerdictCopyCatalog {
        var entries = VerdictCopySurface.unconditionalSurfaces.map { surface in
            VerdictCopyEntry(
                surface: surface,
                localizationKey: Sample.copyKey("copy.surface.\(stableKey(for: surface))")
            )
        }
        for state in ProvenanceStateKey.allCases where state != omitted {
            entries.append(
                VerdictCopyEntry(surface: .provenanceState(state), localizationKey: stateKey(state))
            )
        }
        do {
            return try ApprovedVerdictCopyCatalog(
                id: Sample.artifact(id),
                schemaVersion: .v1,
                compatibilityID: Sample.artifact(compatibilityID),
                languageTag: Sample.text(ApprovedVerdictCopyCatalog.requiredLanguageTag),
                entries: entries,
                approval: Sample.approval(decision)
            )
        } catch {
            preconditionFailure("the copy catalogue sample must be schema-valid: \(error)")
        }
    }

    /// A canonical-identifier-safe rendering of a surface's stable key.
    private static func stableKey(for surface: VerdictCopySurface) -> String {
        surface.description.replacingOccurrences(of: "/", with: ".")
    }
}

enum ManifestSample {
    /// A capability manifest for one composition.
    ///
    /// The schema itself couples provenance to a bound policy and fusion to provenance,
    /// so `provenancePolicy` cannot be bound in a pixel-only manifest.
    static func manifest(
        capabilities: Set<CapabilityID> = [.pixelAnalysis],
        provenancePolicy: ArtifactID? = nil,
        provenanceImplementationVersion: String = "0.0.12"
    ) -> ReleaseCapabilityManifest {
        do {
            var implementations = [
                CapabilityImplementationEntry(
                    capability: .pixelAnalysis,
                    version: Sample.version("1.0.0")
                )
            ]
            if capabilities.contains(.contentCredentialValidation) {
                implementations.append(
                    CapabilityImplementationEntry(
                        capability: .contentCredentialValidation,
                        version: Sample.version(provenanceImplementationVersion)
                    )
                )
            }
            let provenanceBinding: ConditionalArtifactBinding<ArtifactID> =
                if let provenancePolicy {
                    .bound(provenancePolicy)
                } else {
                    .notApplicable(decision: Sample.approval())
                }
            return try ReleaseCapabilityManifest(
                id: Sample.artifact("capability-manifest.sample"),
                schemaVersion: .v1,
                appBuild: AppBuildID("build.sample")!,
                compositionIdentifier: Sample.text("Sample composition"),
                compiledCapabilities: capabilities,
                implementationVersions: implementations,
                approvedConfigurationAllowlist: Sample.artifact("allowlist.sample"),
                approvedBundleCatalog: [ModelBundleID("bundle.sample")!],
                policyCompatibility: try PolicyCompatibilitySet(
                    preprocessingContract: Sample.artifact("preprocessing.sample"),
                    calibrationPolicy: Sample.artifact("calibration.sample"),
                    lifecyclePolicy: Sample.artifact("lifecycle.sample"),
                    extensionExecutionPolicy: Sample.artifact("extension-policy.sample"),
                    mainApplicationResourceBudget: Sample.artifact("budget.main-application"),
                    shareExtensionResourceBudget: Sample.artifact("budget.share-extension"),
                    bundleVerificationPolicy: Sample.artifact("bundle-policy.sample"),
                    verdictCopyCompatibility: Sample.artifact("copy-compatibility.sample"),
                    provenancePolicy: provenanceBinding,
                    fusionRule: .notApplicable(decision: Sample.approval())
                ),
                approval: Sample.approval()
            )
        } catch {
            preconditionFailure("the capability manifest sample must be schema-valid: \(error)")
        }
    }

    /// The pixel-only composition's manifest: no validator compiled, no policy bound.
    static let pixelOnly = manifest()

    /// A provenance-enabled manifest bound to `policy`.
    static func provenanceEnabled(for policy: ProvenancePolicy) -> ReleaseCapabilityManifest {
        manifest(
            capabilities: [.pixelAnalysis, .contentCredentialValidation],
            provenancePolicy: policy.id,
            provenanceImplementationVersion: policy.validatorImplementationVersion.rawSchemaValue
        )
    }
}

// MARK: - Session values for report composition

enum ReportSample {
    static func binding(provenancePolicyID: ArtifactID?) -> AnalysisSessionBinding {
        AnalysisSessionBinding(
            sessionID: Sample.session(),
            appBuildID: AppBuildID("build.sample")!,
            deviceConfigurationID: ApprovedConfigurationID("configuration.sample")!,
            modelBundleID: ModelBundleID("bundle.sample")!,
            modelIdentity: ModelIdentity(
                checkpointIdentifier: ModelCheckpointIdentifier("checkpoint.sample")!,
                requiredWeightDigest: Sample.digest("d")
            ),
            coreMLModelVersion: Sample.artifact("coreml.sample"),
            modelBundleIntegrity: VerifiedBundleIntegrity(
                status: .verified,
                activationReceiptID: Sample.artifact("receipt.sample"),
                verificationPolicyID: Sample.artifact("bundle-policy.sample"),
                verifiedManifestDigest: Sample.digest("e"),
                verifiedArtifactDigests: [
                    ArtifactDigestRecord(
                        path: CanonicalRelativePath("model.mlmodelc")!,
                        kind: .directoryTree,
                        byteCount: 1_024,
                        digest: Sample.digest("f")
                    )
                ]
            )!,
            preprocessingContractID: Sample.artifact("preprocessing.sample"),
            calibrationPolicyID: Sample.artifact("calibration.sample"),
            verdictCopyCompatibilityID: Sample.artifact("copy-compatibility.sample"),
            capabilityManifestID: Sample.artifact("capability-manifest.sample"),
            provenancePolicyID: provenancePolicyID,
            fusionRuleID: nil,
            lifecyclePolicyID: Sample.artifact("lifecycle.sample"),
            resourceBudgetID: Sample.artifact("budget.main-application")
        )
    }

    static func report(
        provenance: ProvenanceLane,
        combinedSummary: CombinedSummary?,
        apparentInconsistency: ApprovedCopyKey? = nil
    ) -> EvidenceReport? {
        EvidenceReport(
            binding: binding(provenancePolicyID: provenance.isAvailable
                ? Sample.artifact("provenance.sample")
                : nil),
            pixel: .noStrongSignalDetected,
            provenance: provenance,
            combinedSummary: combinedSummary,
            apparentInconsistency: apparentInconsistency,
            bytePreservationStatus: .originalBytes,
            inputQuality: InputQualityRecord(
                decodedWidthBeforeOrientation: 1_024,
                decodedHeightBeforeOrientation: 768
            )!,
            onDeviceProcessing: true,
            scope: .version1(id: Sample.artifact("scope.sample"))
        )
    }
}

// MARK: - Recording analyzer

/// Records every call so a test can prove a lane never reached a validator.
///
/// A pixel-only build cannot construct one of these at all, because the adapter module
/// is not linked. The spy exists to prove the weaker runtime statement: a provider that
/// resolved to the unavailable lane does not call an analyzer it was handed.
final class RecordingProvenanceAnalyzer: ProvenanceAnalyzing, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [AnalysisSessionID] = []
    private let result: ProvenanceEvidence

    init(returning result: ProvenanceEvidence = .absent) {
        self.result = result
    }

    var callCount: Int {
        lock.withLock { calls.count }
    }

    var inspectedSessions: [AnalysisSessionID] {
        lock.withLock { calls }
    }

    func analyze(
        _ asset: ImportedEncodedAsset,
        policy: ProvenancePolicy
    ) async -> ProvenanceEvidence {
        lock.withLock { calls.append(asset.sessionID) }
        return result
    }
}
