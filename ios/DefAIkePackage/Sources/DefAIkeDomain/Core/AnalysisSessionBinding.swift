// The immutable snapshot a session is bound to when an input is accepted.

/// Integrity status a session may be bound to.
///
/// One case by construction. Candidate bundles have richer internal verification
/// outcomes, but only a verified bundle can enter a session binding, so an
/// unverified or partially verified bundle is not representable here
/// (Requirement 10.14).
public enum ModelBundleIntegrityStatus: String, Codable, Sendable, CaseIterable {
    case verified
}

/// The bounded, immutable integrity projection of an activation receipt.
///
/// The receipt itself holds the full verification record. This projection carries
/// only what a session and its report need: that verification succeeded, which
/// receipt and Bundle Verification Policy produced it, and the exact digests that
/// were verified. The Result Presenter surfaces the status without exposing digest
/// internals.
public struct VerifiedBundleIntegrity: Hashable, Codable, Sendable {
    public let status: ModelBundleIntegrityStatus
    public let activationReceiptID: ArtifactID
    /// The Bundle Verification Policy version that supplied the signature
    /// algorithm, trusted keys, and rotation and revocation rules. The application
    /// chooses none of those.
    public let verificationPolicyID: ArtifactID
    public let verifiedManifestDigest: SHA256Digest
    public let verifiedArtifactDigests: [ArtifactDigestRecord]

    /// Creates a projection, or `nil` when the digest inventory is empty or names
    /// the same canonical path twice.
    ///
    /// A verified bundle declares at least one artifact, and a duplicated path
    /// would make "the digests that were verified" ambiguous.
    public init?(
        status: ModelBundleIntegrityStatus,
        activationReceiptID: ArtifactID,
        verificationPolicyID: ArtifactID,
        verifiedManifestDigest: SHA256Digest,
        verifiedArtifactDigests: [ArtifactDigestRecord]
    ) {
        guard !verifiedArtifactDigests.isEmpty else { return nil }
        let paths = Set(verifiedArtifactDigests.map(\.path))
        guard paths.count == verifiedArtifactDigests.count else { return nil }
        self.status = status
        self.activationReceiptID = activationReceiptID
        self.verificationPolicyID = verificationPolicyID
        self.verifiedManifestDigest = verifiedManifestDigest
        self.verifiedArtifactDigests = verifiedArtifactDigests
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let integrity = VerifiedBundleIntegrity(
            status: try container.decode(ModelBundleIntegrityStatus.self, forKey: .status),
            activationReceiptID: try container.decode(
                ArtifactID.self, forKey: .activationReceiptID),
            verificationPolicyID: try container.decode(
                ArtifactID.self, forKey: .verificationPolicyID),
            verifiedManifestDigest: try container.decode(
                SHA256Digest.self, forKey: .verifiedManifestDigest),
            verifiedArtifactDigests: try container.decode(
                [ArtifactDigestRecord].self, forKey: .verifiedArtifactDigests)
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: CodingKeys.verifiedArtifactDigests,
                in: container,
                debugDescription: """
                    A verified integrity projection needs a nonempty digest \
                    inventory with unique canonical paths.
                    """
            )
        }
        self = integrity
    }
}

/// Everything an Analysis Session is bound to at the moment its input is accepted.
///
/// This is a value snapshot, taken once. A later activation or rollback cannot
/// change an active session, because the session holds these values rather than
/// consulting the active pointer again (Requirements 10.14, 10.15, and 10.18). The
/// same identifiers are what a report exposes (Requirement 4.12).
///
/// Every policy and release artifact appears as an ``ArtifactID`` only. The binding
/// records which artifact version was active; it does not carry, revalidate, or
/// vouch for that artifact's contents.
public struct AnalysisSessionBinding: Hashable, Sendable {
    public let sessionID: AnalysisSessionID
    public let appBuildID: AppBuildID
    public let deviceConfigurationID: ApprovedConfigurationID
    public let modelBundleID: ModelBundleID
    public let modelIdentity: ModelIdentity
    public let coreMLModelVersion: ArtifactID
    public let modelBundleIntegrity: VerifiedBundleIntegrity
    public let preprocessingContractID: ArtifactID
    public let calibrationPolicyID: ArtifactID
    public let verdictCopyCompatibilityID: ArtifactID
    public let capabilityManifestID: ArtifactID
    /// Present only in a provenance-enabled composition.
    public let provenancePolicyID: ArtifactID?
    /// Present only when an approved Evidence Fusion Rule is active.
    public let fusionRuleID: ArtifactID?
    public let lifecyclePolicyID: ArtifactID
    public let resourceBudgetID: ArtifactID

    public init(
        sessionID: AnalysisSessionID,
        appBuildID: AppBuildID,
        deviceConfigurationID: ApprovedConfigurationID,
        modelBundleID: ModelBundleID,
        modelIdentity: ModelIdentity,
        coreMLModelVersion: ArtifactID,
        modelBundleIntegrity: VerifiedBundleIntegrity,
        preprocessingContractID: ArtifactID,
        calibrationPolicyID: ArtifactID,
        verdictCopyCompatibilityID: ArtifactID,
        capabilityManifestID: ArtifactID,
        provenancePolicyID: ArtifactID?,
        fusionRuleID: ArtifactID?,
        lifecyclePolicyID: ArtifactID,
        resourceBudgetID: ArtifactID
    ) {
        self.sessionID = sessionID
        self.appBuildID = appBuildID
        self.deviceConfigurationID = deviceConfigurationID
        self.modelBundleID = modelBundleID
        self.modelIdentity = modelIdentity
        self.coreMLModelVersion = coreMLModelVersion
        self.modelBundleIntegrity = modelBundleIntegrity
        self.preprocessingContractID = preprocessingContractID
        self.calibrationPolicyID = calibrationPolicyID
        self.verdictCopyCompatibilityID = verdictCopyCompatibilityID
        self.capabilityManifestID = capabilityManifestID
        self.provenancePolicyID = provenancePolicyID
        self.fusionRuleID = fusionRuleID
        self.lifecyclePolicyID = lifecyclePolicyID
        self.resourceBudgetID = resourceBudgetID
    }
}
