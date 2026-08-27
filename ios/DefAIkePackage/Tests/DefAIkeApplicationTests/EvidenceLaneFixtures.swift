import DefAIkeDomain
import Foundation

// Sample values the Evidence Coordinator needs in order to be called at all.
//
// **Nothing here is an approved release input.** The copy keys, the declared
// apparent-inconsistency combinations, the Provenance Policy fields, and every identifier
// are placeholders for schema shape only. Which lane combinations a release calls
// apparently inconsistent, and what the notice says, are unresolved external decisions
// (the fusion mappings and approved verdict copy the README lists as unresolved), so no
// test below asserts that a value here is correct. Each test asserts what the *join* does
// with a given approved input, and what changes when one input changes.
//
// Nothing here may be copied into a shipping artifact. `Fixture` in `ResourceFixtures.swift`
// already supplies the shared identifier, digest, and evidence-source helpers; this file
// adds only the evidence-lane values.

// MARK: - Scalars

enum EvidenceSample {
    static func copyKey(_ raw: String) -> ApprovedCopyKey {
        guard let key = ApprovedCopyKey(raw) else {
            preconditionFailure("fixture copy key is not canonical: \(raw)")
        }
        return key
    }

    static func approval(_ decision: ApprovalDecision = .approved) -> ApprovalRecord {
        guard let approver = ApproverID("role.release-owner") else {
            preconditionFailure("fixture approver identifier is not canonical")
        }
        return ApprovalRecord(
            source: Fixture.evidence("approval-0001"),
            decision: decision,
            approver: approver,
            decidedAt: Date(timeIntervalSince1970: 0)
        )
    }

    static func text(_ raw: String) -> ArtifactText {
        do {
            return try ArtifactText(validating: raw)
        } catch {
            preconditionFailure("fixture artifact text is not valid: \(error)")
        }
    }

    static func displayText(_ raw: String) -> DisplaySafeText {
        guard let value = DisplaySafeText(raw) else {
            preconditionFailure("fixture display text is not display-safe: \(raw)")
        }
        return value
    }

    static func version(_ raw: String = "1.0.0") -> SchemaSemanticVersion {
        do {
            return try SchemaSemanticVersion(validating: raw)
        } catch {
            preconditionFailure("fixture semantic version is not valid: \(error)")
        }
    }
}

// MARK: - Provenance lane values

enum ProvenanceSample {
    /// The policy identifier every enabled-state sample attributes itself to.
    static let policyID = Fixture.artifactID("provenance-policy-0001")

    /// A different policy version, for attribution-mismatch tests.
    static let otherPolicyID = Fixture.artifactID("provenance-policy-0002")

    static func validated(policyID: ArtifactID = ProvenanceSample.policyID) -> ProvenanceEvidence {
        .validated(
            ValidatedClaimSummary(
                provenancePolicyID: policyID,
                bindingStatus: .boundToInspectedBytes,
                signerFields: [
                    DisplaySafeField(
                        labelKey: EvidenceSample.copyKey("copy.provenance.field.signer-identity"),
                        value: EvidenceSample.displayText("Sample signer")
                    )
                ],
                assertionFields: []
            )
        )
    }

    static func invalid(policyID: ArtifactID = ProvenanceSample.policyID) -> ProvenanceEvidence {
        .invalid(
            InvaliditySummary(
                provenancePolicyID: policyID,
                category: .cryptographic,
                explanationKey: EvidenceSample.copyKey("copy.provenance.state.invalid")
            )
        )
    }

    static func unsupported(
        policyID: ArtifactID = ProvenanceSample.policyID
    ) -> ProvenanceEvidence {
        .unsupported(
            UnsupportedFeatureSummary(
                provenancePolicyID: policyID,
                explanationKey: EvidenceSample.copyKey("copy.provenance.state.unsupported"),
                unsupportedFeatures: [EvidenceSample.displayText("sample.feature")]
            )
        )
    }

    static func indeterminate(
        policyID: ArtifactID = ProvenanceSample.policyID
    ) -> ProvenanceEvidence {
        .indeterminate(
            IndeterminateSummary(
                provenancePolicyID: policyID,
                explanationKey: EvidenceSample.copyKey("copy.provenance.state.indeterminate")
            )
        )
    }

    /// One sample value for each of the five enabled states, in declaration order.
    static let allEnabledStates: [ProvenanceEvidence] = [
        validated(), invalid(), .absent, unsupported(), indeterminate(),
    ]

    /// Every lane a session can resolve: the five enabled states plus both unavailable
    /// reasons.
    static let allLanes: [ProvenanceLane] =
        allEnabledStates.map(ProvenanceLane.available)
        + UnavailableReason.allCases.map(ProvenanceLane.unavailable)

    /// A Provenance Policy the analyzer double can be called with.
    ///
    /// Schema shape only: the trust store, revocation behavior, status mapping, limits,
    /// and displayable fields are all unresolved release decisions.
    static func policy(id: ArtifactID = ProvenanceSample.policyID) -> ProvenancePolicy {
        do {
            guard let status = ProvenanceValidatorStatusID("status.no-manifest") else {
                preconditionFailure("fixture validator status is not canonical")
            }
            return try ProvenancePolicy(
                id: id,
                schemaVersion: .v1,
                capability: .contentCredentialValidation,
                validatorImplementationVersion: EvidenceSample.version("0.0.12"),
                validatorBinaryDigest: Fixture.digest("validator-binary"),
                supportedSpecification: Fixture.evidence("specification-0001"),
                trustStore: try ProvenanceTrustStoreDescriptor(
                    store: Fixture.evidence("trust-store-0001"),
                    anchorCount: try PositiveCount(validating: 1),
                    isOfflineOnly: true
                ),
                revocationBehavior: try ProvenanceRevocationBehavior(
                    permitsNetworkRevocationCheck: false,
                    unavailableAnswerState: .indeterminate,
                    approval: EvidenceSample.approval()
                ),
                supportedAssertionLabels: [EvidenceSample.text("c2pa.actions")],
                displayableFields: [.signerIdentity],
                processingLimits: ProvenanceProcessingLimits(
                    maximumManifestByteCount: try PositiveByteCount(validating: 65_536),
                    maximumAssertionCount: try PositiveCount(validating: 8),
                    maximumNestingDepth: try PositiveCount(validating: 4),
                    maximumProcessingDuration: try ValidatedDuration(validating: 5_000)
                ),
                resourceBudget: Fixture.artifactID("budget-main-application"),
                statusMappings: [ProvenanceStatusMapping(status: status, state: .absent)],
                feasibilityApproval: EvidenceSample.approval()
            )
        } catch {
            preconditionFailure("the provenance policy fixture must be schema-valid: \(error)")
        }
    }

    /// One accepted ingest. Only the identity of the recorded measurements matters here.
    static func asset(
        sessionID raw: String = "session-0001",
        digestSeed: String = "asset-bytes"
    ) -> ImportedEncodedAsset {
        guard let sessionID = AnalysisSessionID(raw),
              let storageKey = EphemeralStorageKey("eph-00000001"),
              let handle = EncodedAssetHandle(
                  sessionID: sessionID,
                  storageKey: storageKey,
                  byteCount: 4_096,
                  sha256: Fixture.digest(digestSeed),
                  protection: .complete
              ),
              let asset = ImportedEncodedAsset(
                  route: .photosPicker,
                  handle: handle,
                  preservationStatus: .originalBytes,
                  preservationBasis: .providerDeclaredOriginalRepresentation,
                  contentTypeHint: ContentTypeHint("public.jpeg")
              )
        else {
            preconditionFailure("the accepted ingest fixture must be representable")
        }
        return asset
    }
}

// MARK: - Session values

enum SessionSample {
    static let copyCompatibilityID = Fixture.artifactID("copy-compatibility-0001")
    static let otherCopyCompatibilityID = Fixture.artifactID("copy-compatibility-0002")
    static let fusionRuleID = Fixture.artifactID("fusion-rule-0001")
    static let otherFusionRuleID = Fixture.artifactID("fusion-rule-0002")

    /// A session binding for one composition.
    ///
    /// `provenancePolicyID` is `nil` for a pixel-only composition and the bound policy
    /// version for a provenance-enabled one, which is what the coordinator's attribution
    /// check compares the resolved lane against.
    static func binding(
        provenancePolicyID: ArtifactID? = nil,
        fusionRuleID: ArtifactID? = nil,
        verdictCopyCompatibilityID: ArtifactID = SessionSample.copyCompatibilityID
    ) -> AnalysisSessionBinding {
        guard let sessionID = AnalysisSessionID("session-0001"),
              let appBuildID = AppBuildID("build-0001"),
              let configurationID = ApprovedConfigurationID("configuration-0001"),
              let bundleID = ModelBundleID("bundle-0001"),
              let checkpoint = ModelCheckpointIdentifier("checkpoint-0001"),
              let modelPath = CanonicalRelativePath("model.mlmodelc"),
              let integrity = VerifiedBundleIntegrity(
                  status: .verified,
                  activationReceiptID: Fixture.artifactID("receipt-0001"),
                  verificationPolicyID: Fixture.artifactID("bundle-policy-0001"),
                  verifiedManifestDigest: Fixture.digest("manifest"),
                  verifiedArtifactDigests: [
                      ArtifactDigestRecord(
                          path: modelPath,
                          kind: .directoryTree,
                          byteCount: 1_024,
                          digest: Fixture.digest("model")
                      )
                  ]
              )
        else {
            preconditionFailure("the session binding fixture must be representable")
        }
        return AnalysisSessionBinding(
            sessionID: sessionID,
            appBuildID: appBuildID,
            deviceConfigurationID: configurationID,
            modelBundleID: bundleID,
            modelIdentity: ModelIdentity(
                checkpointIdentifier: checkpoint,
                requiredWeightDigest: Fixture.digest("weights")
            ),
            coreMLModelVersion: Fixture.artifactID("coreml-0001"),
            modelBundleIntegrity: integrity,
            preprocessingContractID: Fixture.artifactID("preprocessing-0001"),
            calibrationPolicyID: Fixture.artifactID("calibration-0001"),
            verdictCopyCompatibilityID: verdictCopyCompatibilityID,
            capabilityManifestID: Fixture.artifactID("capability-manifest-0001"),
            provenancePolicyID: provenancePolicyID,
            fusionRuleID: fusionRuleID,
            lifecyclePolicyID: Fixture.artifactID("lifecycle-0001"),
            resourceBudgetID: Fixture.artifactID("budget-main-application")
        )
    }

    static let scope = EvidenceScope.version1(id: Fixture.artifactID("evidence-scope-0001"))

    static let inputQuality: InputQualityRecord = {
        guard let record = InputQualityRecord(
            decodedWidthBeforeOrientation: 1_024,
            decodedHeightBeforeOrientation: 768
        ) else {
            preconditionFailure("the input quality fixture must be self-consistent")
        }
        return record
    }()
}

// MARK: - Approved copy catalogue

enum CopyCatalogSample {
    /// A catalogue covering every unconditional surface plus all five enabled provenance
    /// states.
    ///
    /// `omittingInconsistencyNotice` drops the `apparent-inconsistency` surface so a test
    /// can prove a classifier cannot be built without approved wording.
    static func catalog(
        id: ArtifactID = Fixture.artifactID("copy-catalog-0001"),
        compatibilityID: ArtifactID = SessionSample.copyCompatibilityID,
        omittingInconsistencyNotice: Bool = false,
        approval decision: ApprovalDecision = .approved
    ) -> ApprovedVerdictCopyCatalog {
        var surfaces = VerdictCopySurface.unconditionalSurfaces
        if omittingInconsistencyNotice {
            surfaces.remove(.apparentInconsistency)
        }
        for state in ProvenanceStateKey.allCases {
            surfaces.insert(.provenanceState(state))
        }
        let entries = surfaces.map { surface in
            VerdictCopyEntry(
                surface: surface,
                localizationKey: EvidenceSample.copyKey(
                    "copy.surface." + surface.description.replacingOccurrences(of: "/", with: ".")
                )
            )
        }
        do {
            return try ApprovedVerdictCopyCatalog(
                id: id,
                schemaVersion: .v1,
                compatibilityID: compatibilityID,
                languageTag: EvidenceSample.text(
                    ApprovedVerdictCopyCatalog.requiredLanguageTag
                ),
                entries: entries,
                approval: EvidenceSample.approval(decision)
            )
        } catch {
            preconditionFailure("the copy catalogue fixture must be schema-valid: \(error)")
        }
    }

    /// The notice key `catalog()` approves for the apparent-inconsistency surface.
    static var noticeKey: ApprovedCopyKey {
        guard let key = catalog().localizationKey(for: .apparentInconsistency) else {
            preconditionFailure("the catalogue fixture must approve the inconsistency notice")
        }
        return key
    }
}

// MARK: - Recording analyzer

/// A ``ProvenanceAnalyzing`` double that records everything it was given.
///
/// The recording is the assertion: the port hands it an accepted ingest and a policy and
/// nothing else, so what it saw cannot include the pixel lane, and what it returns is one
/// ``ProvenanceEvidence`` value. There is no member through which it could reach a raw
/// logit, an execution status, or Pixel Evidence (Requirement 7.4).
final class RecordingProvenanceAnalyzer: ProvenanceAnalyzing, @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [AnalysisSessionID] = []
    private var digests: [DefAIkeDomain.SHA256Digest] = []
    private var policies: [ArtifactID] = []
    private let result: ProvenanceEvidence

    init(returning result: ProvenanceEvidence) {
        self.result = result
    }

    var inspectedSessions: [AnalysisSessionID] { lock.withLock { sessions } }
    var inspectedDigests: [DefAIkeDomain.SHA256Digest] { lock.withLock { digests } }
    var appliedPolicies: [ArtifactID] { lock.withLock { policies } }

    func analyze(
        _ asset: ImportedEncodedAsset,
        policy: ProvenancePolicy
    ) async -> ProvenanceEvidence {
        lock.withLock {
            sessions.append(asset.sessionID)
            digests.append(asset.sha256)
            policies.append(policy.id)
        }
        return result
    }
}
