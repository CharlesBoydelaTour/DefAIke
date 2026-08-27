import Foundation

// The Bundle Verification Policy and the receipts activation writes.
//
// Requirement 10.6 requires a verifiable release signature over every artifact identity
// and digest plus the compatibility metadata, and Requirement 10.8 requires that
// signature, digests, identity, minimum OS, component compatibility, and copy
// compatibility to be verified before inference.
//
// Which algorithm, which keys, and what rotation and revocation mean are decision D8
// and are supplied by this approved artifact. Nothing in this module selects a default
// algorithm or trusts a key because it is present: a trusted key carries its own
// governance approval, and a revoked key stays representable so verification can refuse
// it by name.

// MARK: - Signature algorithm and keys

/// A signature algorithm a release may approve.
///
/// The vocabulary is bounded so an artifact cannot name an arbitrary algorithm string,
/// and no case is a default: the field is required.
public enum SignatureAlgorithm: String, Codable, Sendable, Hashable, CaseIterable {
    case ed25519
    case ecdsaP256SHA256 = "ecdsa-p256-sha256"
    case ecdsaP384SHA384 = "ecdsa-p384-sha384"
    case rsaPSS3072SHA256 = "rsa-pss-3072-sha256"
}

/// The lifecycle status of one release signing key.
public enum SigningKeyStatus: String, Codable, Sendable, Hashable, CaseIterable {
    case active
    case retired
    case revoked

    /// Whether a manifest signature may verify against a key in this state.
    public var permitsVerification: Bool { self == .active }
}

/// One key a Bundle Verification Policy trusts, with its governance approval.
///
/// Presence in the policy is not sufficient on its own: the key carries the approval
/// record that authorized it, and a retired or revoked key cannot verify.
public struct TrustedSigningKey: Hashable, Codable, Sendable {
    public let key: SigningKeyID
    public let algorithm: SignatureAlgorithm
    public let publicKeyDigest: SHA256Digest
    public let status: SigningKeyStatus

    /// The key-governance decision that authorized this key.
    public let governanceApproval: ApprovalRecord

    public init(
        key: SigningKeyID,
        algorithm: SignatureAlgorithm,
        publicKeyDigest: SHA256Digest,
        status: SigningKeyStatus,
        governanceApproval: ApprovalRecord
    ) {
        self.key = key
        self.algorithm = algorithm
        self.publicKeyDigest = publicKeyDigest
        self.status = status
        self.governanceApproval = governanceApproval
    }
}

/// What happens when a key's revocation status cannot be established.
///
/// Verification is offline, so this is answered by policy in advance. `treatAsTrusted`
/// is representable and rejected: an unresolved revocation question is not trust.
public enum KeyRevocationBehavior: String, Codable, Sendable, Hashable, CaseIterable {
    case rejectBundle = "reject-bundle"
    case treatAsTrusted = "treat-as-trusted"
}

/// Whether a rotated key's predecessors keep verifying already-installed bundles.
public enum KeyRotationBehavior: String, Codable, Sendable, Hashable, CaseIterable {
    /// Only currently active keys verify.
    case activeKeysOnly = "active-keys-only"
    /// Retired predecessors verify bundles signed before their retirement.
    case retiredKeysVerifyHistoricalBundles = "retired-keys-verify-historical-bundles"
}

/// The versioned policy that governs Model Bundle signature verification.
public struct BundleVerificationPolicy: Hashable, Codable, Sendable {
    public let id: ArtifactID
    public let schemaVersion: ArtifactSchemaVersion

    /// The one algorithm this policy accepts.
    public let algorithm: SignatureAlgorithm

    /// The canonicalization profile the signature covers, including the deterministic
    /// directory-tree digest rule.
    public let canonicalizationProfile: EvidenceSource

    /// Trusted keys. Never empty, and at least one must be active.
    public let trustedKeys: [TrustedSigningKey]

    public let rotationBehavior: KeyRotationBehavior
    public let revocationBehavior: KeyRevocationBehavior

    /// Ceiling on manifest size, so parsing is bounded before any allocation.
    public let maximumManifestByteCount: PositiveByteCount

    /// The reproducible-build evidence for bundles verified under this policy.
    public let reproducibilityEvidence: EvidenceSource

    public init(
        id: ArtifactID,
        schemaVersion: ArtifactSchemaVersion,
        algorithm: SignatureAlgorithm,
        canonicalizationProfile: EvidenceSource,
        trustedKeys: [TrustedSigningKey],
        rotationBehavior: KeyRotationBehavior,
        revocationBehavior: KeyRevocationBehavior,
        maximumManifestByteCount: PositiveByteCount,
        reproducibilityEvidence: EvidenceSource
    ) throws {
        try ArtifactSchemaValidation.requireNonEmpty(trustedKeys, field: "trustedKeys")
        try ArtifactSchemaValidation.requireUniqueKeys(
            trustedKeys.map(\.key.rawValue),
            field: "trustedKeys"
        )
        guard trustedKeys.contains(where: { $0.status == .active }) else {
            throw ArtifactSchemaError.missingRequiredEntries(
                field: "trustedKeys",
                keys: ["at least one active key"]
            )
        }
        for trustedKey in trustedKeys where trustedKey.algorithm != algorithm {
            throw ArtifactSchemaError.inconsistentReference(
                field: "trustedKeys[\(trustedKey.key.rawValue)].algorithm",
                expected: algorithm.rawValue,
                found: trustedKey.algorithm.rawValue
            )
        }
        guard revocationBehavior == .rejectBundle else {
            throw ArtifactSchemaError.forbiddenValue(
                field: "revocationBehavior",
                value: revocationBehavior.rawValue,
                reason: "an unresolved revocation status cannot be treated as trust"
            )
        }
        self.id = id
        self.schemaVersion = schemaVersion
        self.algorithm = algorithm
        self.canonicalizationProfile = canonicalizationProfile
        self.trustedKeys = trustedKeys
        self.rotationBehavior = rotationBehavior
        self.revocationBehavior = revocationBehavior
        self.maximumManifestByteCount = maximumManifestByteCount
        self.reproducibilityEvidence = reproducibilityEvidence
    }

    /// The trusted key record for one identifier, or `nil` when the policy does not
    /// trust it. An unknown key is never assumed trustworthy.
    public func trustedKey(_ key: SigningKeyID) -> TrustedSigningKey? {
        trustedKeys.first { $0.key == key }
    }

    private enum CodingKeys: String, CodingKey {
        case id, schemaVersion, algorithm, canonicalizationProfile, trustedKeys, rotationBehavior
        case revocationBehavior, maximumManifestByteCount, reproducibilityEvidence
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(ArtifactID.self, forKey: .id),
                schemaVersion: container.decode(ArtifactSchemaVersion.self, forKey: .schemaVersion),
                algorithm: container.decode(SignatureAlgorithm.self, forKey: .algorithm),
                canonicalizationProfile: container.decode(
                    EvidenceSource.self,
                    forKey: .canonicalizationProfile
                ),
                trustedKeys: container.decode([TrustedSigningKey].self, forKey: .trustedKeys),
                rotationBehavior: container.decode(
                    KeyRotationBehavior.self,
                    forKey: .rotationBehavior
                ),
                revocationBehavior: container.decode(
                    KeyRevocationBehavior.self,
                    forKey: .revocationBehavior
                ),
                maximumManifestByteCount: container.decode(
                    PositiveByteCount.self,
                    forKey: .maximumManifestByteCount
                ),
                reproducibilityEvidence: container.decode(
                    EvidenceSource.self,
                    forKey: .reproducibilityEvidence
                )
            )
        } catch let error as ArtifactSchemaError {
            throw error.asDecodingError(codingPath: decoder.codingPath)
        }
    }
}

// MARK: - Activation receipt

/// The device and build context a result or receipt was produced in.
public struct DeviceContext: Hashable, Codable, Sendable {
    public let hardwareIdentifier: DeviceHardwareID
    public let osVersion: PlatformVersion
    public let appBuild: AppBuildID
    public let environment: ExecutionEnvironment

    public init(
        hardwareIdentifier: DeviceHardwareID,
        osVersion: PlatformVersion,
        appBuild: AppBuildID,
        environment: ExecutionEnvironment
    ) {
        self.hardwareIdentifier = hardwareIdentifier
        self.osVersion = osVersion
        self.appBuild = appBuild
        self.environment = environment
    }
}

/// The immutable receipt activation writes after every check passes.
///
/// The receipt records outcomes rather than asserting success: `signatureOutcome` and
/// `selfTestOutcome` are separate recorded results, and ``isBindable`` is true only when
/// both passed. Requirement 10.12 keeps a failed candidate from replacing the active
/// bundle, so a receipt for a failed candidate is representable and simply not
/// bindable. The receipt carries no image or session data (design, Model Bundle format).
public struct ActivationReceipt: Hashable, Codable, Sendable {
    public let id: ArtifactID
    public let schemaVersion: ArtifactSchemaVersion

    public let bundleID: ModelBundleID
    public let verificationPolicy: ArtifactID

    /// Digest of the manifest that was verified.
    public let verifiedManifestDigest: SHA256Digest

    /// Every artifact digest that was checked, as verified.
    public let verifiedArtifactDigests: [ArtifactDigestRecord]

    public let signatureOutcome: GateOutcome
    public let selfTestOutcome: GateOutcome

    public let deviceContext: DeviceContext

    /// Monotonic activation generation, so an observer can tell two activations apart.
    public let activationGeneration: PositiveCount

    public let activatedAt: Date

    public init(
        id: ArtifactID,
        schemaVersion: ArtifactSchemaVersion,
        bundleID: ModelBundleID,
        verificationPolicy: ArtifactID,
        verifiedManifestDigest: SHA256Digest,
        verifiedArtifactDigests: [ArtifactDigestRecord],
        signatureOutcome: GateOutcome,
        selfTestOutcome: GateOutcome,
        deviceContext: DeviceContext,
        activationGeneration: PositiveCount,
        activatedAt: Date
    ) throws {
        try ArtifactSchemaValidation.requireNonEmpty(
            verifiedArtifactDigests,
            field: "receipt.verifiedArtifactDigests"
        )
        try ArtifactSchemaValidation.requireUniqueKeys(
            verifiedArtifactDigests.map(\.path.rawValue),
            field: "receipt.verifiedArtifactDigests"
        )
        self.id = id
        self.schemaVersion = schemaVersion
        self.bundleID = bundleID
        self.verificationPolicy = verificationPolicy
        self.verifiedManifestDigest = verifiedManifestDigest
        self.verifiedArtifactDigests = verifiedArtifactDigests
        self.signatureOutcome = signatureOutcome
        self.selfTestOutcome = selfTestOutcome
        self.deviceContext = deviceContext
        self.activationGeneration = activationGeneration
        self.activatedAt = activatedAt
    }

    /// Whether a session may bind the bundle this receipt describes.
    ///
    /// Only a receipt whose signature and self-test both passed is bindable. A missing
    /// result is not a pass.
    public var isBindable: Bool {
        signatureOutcome.isPassing && selfTestOutcome.isPassing
    }

    private enum CodingKeys: String, CodingKey {
        case id, schemaVersion, bundleID, verificationPolicy, verifiedManifestDigest
        case verifiedArtifactDigests, signatureOutcome, selfTestOutcome, deviceContext
        case activationGeneration, activatedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(ArtifactID.self, forKey: .id),
                schemaVersion: container.decode(ArtifactSchemaVersion.self, forKey: .schemaVersion),
                bundleID: container.decode(ModelBundleID.self, forKey: .bundleID),
                verificationPolicy: container.decode(ArtifactID.self, forKey: .verificationPolicy),
                verifiedManifestDigest: container.decode(
                    SHA256Digest.self,
                    forKey: .verifiedManifestDigest
                ),
                verifiedArtifactDigests: container.decode(
                    [ArtifactDigestRecord].self,
                    forKey: .verifiedArtifactDigests
                ),
                signatureOutcome: container.decode(GateOutcome.self, forKey: .signatureOutcome),
                selfTestOutcome: container.decode(GateOutcome.self, forKey: .selfTestOutcome),
                deviceContext: container.decode(DeviceContext.self, forKey: .deviceContext),
                activationGeneration: container.decode(
                    PositiveCount.self,
                    forKey: .activationGeneration
                ),
                activatedAt: container.decode(Date.self, forKey: .activatedAt)
            )
        } catch let error as ArtifactSchemaError {
            throw error.asDecodingError(codingPath: decoder.codingPath)
        }
    }
}
