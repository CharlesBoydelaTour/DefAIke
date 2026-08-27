import Foundation

@testable import DefAIkeDomain
@testable import DefAIkeModelBundle

// Deterministic doubles and sample artifacts for Model Bundle verification tests.
//
// Nothing here is an approved release input. The policies, keys, digests, and paths are
// synthetic: each test assembles one structurally valid candidate, changes exactly one
// thing, and asserts which finding verification produces.
//
// Two choices keep the doubles honest:
//
//   * digests are real SHA-256, computed by the same code the verifier uses, so a
//     single flipped byte actually changes a digest; and
//   * the signature stand-in binds key material to message bytes, so altering a signed
//     manifest really does break its signature instead of quietly still matching.

// MARK: - Sample values

enum Sample {
    static func artifact(_ value: String = "artifact.sample") -> ArtifactID {
        ArtifactID(value)!
    }

    static func bundle(_ value: String = "bundle.sample") -> ModelBundleID {
        ModelBundleID(value)!
    }

    static func appBuild(_ value: String = "build.sample") -> AppBuildID {
        AppBuildID(value)!
    }

    static func signingKey(_ value: String = "key.sample") -> SigningKeyID {
        SigningKeyID(value)!
    }

    static func approver(_ value: String = "role.release-owner") -> ApproverID {
        ApproverID(value)!
    }

    static func path(_ value: String) -> CanonicalRelativePath {
        CanonicalRelativePath(value)!
    }

    static func text(_ value: String) -> ArtifactText {
        try! ArtifactText(validating: value)
    }

    static func version(_ value: String = "1.0.0") -> SchemaSemanticVersion {
        try! SchemaSemanticVersion(validating: value)
    }

    static func byteCount(_ value: UInt64) -> PositiveByteCount {
        try! PositiveByteCount(validating: value)
    }

    static func digest(_ character: Character = "a") -> DefAIkeDomain.SHA256Digest {
        DefAIkeDomain.SHA256Digest(hexadecimal: String(repeating: character, count: 64))!
    }

    static func evidence(
        _ identifier: String = "evidence.sample",
        contentDigest: DefAIkeDomain.SHA256Digest = Sample.digest()
    ) -> EvidenceSource {
        EvidenceSource(
            artifact: artifact(identifier),
            version: version(),
            contentDigest: contentDigest
        )
    }

    static func approval(
        _ decision: ApprovalDecision = .approved,
        identifier: String = "approval.sample"
    ) -> ApprovalRecord {
        ApprovalRecord(
            source: evidence(identifier),
            decision: decision,
            approver: approver(),
            decidedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    static func modelFormat() -> ModelFormatDescriptor {
        try! ModelFormatDescriptor(
            programKind: .mlProgram,
            computePrecision: .float16,
            minimumOS: .iOS17
        )
    }

    static func modelInput() -> ModelInputContract {
        try! ModelInputContract(
            featureName: text("image"),
            width: CenterCropContract.requiredEdge,
            height: CenterCropContract.requiredEdge,
            channelOrder: .rgb,
            elementType: .uint8,
            appliesAppSideNormalization: false
        )
    }

    static func modelOutput() -> ModelOutputContract {
        try! ModelOutputContract(
            featureName: text(ModelOutputContract.requiredFeatureName),
            elementType: .float32,
            isPositiveGoing: true
        )
    }

    static func componentVersions() -> BundleComponentVersions {
        BundleComponentVersions(
            coreMLModel: artifact("component.core-ml-model"),
            preprocessingContract: artifact("component.preprocessing"),
            calibrationPolicy: artifact("component.calibration"),
            evidenceScope: artifact("component.scope"),
            verdictCopyCompatibility: artifact("component.copy"),
            selfTestSpecification: artifact("component.self-tests")
        )
    }

    static func compatibility() -> CompatibilityMatrix {
        try! CompatibilityMatrix(
            compatibleAppBuilds: [appBuild()],
            requiredCapabilities: [.pixelAnalysis],
            minimumOS: .iOS17
        )
    }

    static func upstreamMetadata() -> UpstreamBoundaryMetadata {
        try! UpstreamBoundaryMetadata(
            rawLogitValue: UpstreamBoundaryMetadata.requiredValue,
            role: .modelMetadataOnly
        )
    }

    /// A structurally valid manifest.
    ///
    /// The defaulted parameters are the fields compatibility verification compares against
    /// approved values, so a test can change exactly one of them. The model identity is not
    /// among them: ``ModelBundleManifest`` admits only ``RequiredPixelModel/identity``, so
    /// "the manifest declares another checkpoint" is not a state a test can reach through
    /// this initializer, and the tests assert that refusal directly instead.
    static func manifest(
        bundleID: ModelBundleID = Sample.bundle(),
        artifacts: [ArtifactDigestRecord],
        signingKey: SigningKeyID = Sample.signingKey(),
        componentVersions: BundleComponentVersions = Sample.componentVersions(),
        compatibility: CompatibilityMatrix? = nil,
        inputContract: ModelInputContract? = nil,
        outputContract: ModelOutputContract? = nil
    ) throws -> ModelBundleManifest {
        try ModelBundleManifest(
            schemaVersion: .v1,
            bundleID: bundleID,
            modelIdentity: RequiredPixelModel.identity,
            modelFormat: modelFormat(),
            inputContract: inputContract ?? modelInput(),
            outputContract: outputContract ?? modelOutput(),
            componentVersions: componentVersions,
            artifacts: artifacts,
            compatibility: compatibility ?? Sample.compatibility(),
            upstreamBoundaryMetadata: upstreamMetadata(),
            signingKey: signingKey
        )
    }
}

// MARK: - Content store double

/// A bounded in-memory candidate bundle tree.
///
/// The enumeration and the bytes are stored separately on purpose: a test can make the
/// enumeration disagree with the content, which is what a store that under-reports a
/// file's size looks like from inside verification.
struct FakeBundleTree: ModelBundleContentReading {
    var treeEntries: [BundleTreeEntry] = []
    var fileBytes: [String: [UInt8]] = [:]
    var unreadablePaths: Set<String> = []
    var enumerationFault: BundleContentFault?

    func entries(in bundle: ModelBundleID) throws(BundleContentFault) -> [BundleTreeEntry] {
        if let enumerationFault { throw enumerationFault }
        return treeEntries
    }

    func readFile(
        at path: CanonicalRelativePath,
        in bundle: ModelBundleID,
        chunkByteCount: Int,
        into sink: (ArraySlice<UInt8>) -> BundleReadDisposition
    ) throws(BundleContentFault) {
        guard !unreadablePaths.contains(path.rawValue) else {
            throw BundleContentFault.entryUnreadable
        }
        guard let bytes = fileBytes[path.rawValue] else {
            throw BundleContentFault.entryMissing
        }
        guard chunkByteCount > 0 else { return }
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + chunkByteCount, bytes.count)
            if sink(bytes[offset..<end]) == .stop { return }
            offset = end
        }
    }

    // MARK: Assembly

    mutating func addFile(_ path: String, bytes: [UInt8], reportedByteCount: UInt64? = nil) {
        treeEntries.append(
            BundleTreeEntry(
                rawPath: path,
                kind: .file(byteCount: reportedByteCount ?? UInt64(bytes.count))
            )
        )
        fileBytes[path] = bytes
    }

    mutating func addFile(_ path: String, text: String) {
        addFile(path, bytes: Array(text.utf8))
    }

    mutating func addDirectory(_ path: String) {
        treeEntries.append(BundleTreeEntry(rawPath: path, kind: .directory))
    }

    mutating func addEntry(_ entry: BundleTreeEntry) {
        treeEntries.append(entry)
    }

    mutating func removeEntry(_ path: String) {
        treeEntries.removeAll { $0.rawPath == path }
        fileBytes[path] = nil
    }

    /// Replaces one file's bytes without touching what the enumeration reports.
    mutating func overwriteContent(_ path: String, bytes: [UInt8]) {
        fileBytes[path] = bytes
    }

    mutating func overwriteContent(_ path: String, text: String) {
        overwriteContent(path, bytes: Array(text.utf8))
    }
}

// MARK: - Signature double

/// A deterministic stand-in for one approved signature algorithm.
///
/// Not cryptography and not a release key: the "signature" is
/// `sha256(keyMaterial || message)`. That is enough to make a signature check
/// byte-sensitive — altering a signed manifest breaks it — without embedding a real
/// signing key or asserting anything about a real algorithm.
struct FakeSignatureVerifier: BundleSignatureVerifying {
    var material: [String: [UInt8]] = [:]
    var supportedAlgorithms: Set<SignatureAlgorithm> = Set(SignatureAlgorithm.allCases)

    static func signature(over message: [UInt8], keyMaterial: [UInt8]) -> [UInt8] {
        StreamingSHA256.digest(of: keyMaterial + message).bytes
    }

    func publicKeyMaterial(for key: SigningKeyID) -> [UInt8]? {
        material[key.rawValue]
    }

    func verify(
        signature: [UInt8],
        over message: [UInt8],
        using algorithm: SignatureAlgorithm,
        publicKeyMaterial: [UInt8]
    ) -> SignatureCheckOutcome {
        guard supportedAlgorithms.contains(algorithm) else { return .algorithmUnsupported }
        let expected = Self.signature(over: message, keyMaterial: publicKeyMaterial)
        return signature == expected ? .verified : .notVerified
    }
}

// MARK: - Assembled candidate

/// One assembled candidate bundle plus the approved inputs verification needs.
struct AssembledBundle {
    var tree: FakeBundleTree
    var manifest: ModelBundleManifest
    var manifestBytes: [UInt8]
    var policy: BundleVerificationPolicy
    var canonicalization: ApprovedCanonicalizationProfile
    var signatures: FakeSignatureVerifier
    var bundleID: ModelBundleID

    var verifier: ModelBundleIntegrityVerifier {
        ModelBundleIntegrityVerifier(
            content: tree,
            signatures: signatures,
            policy: policy,
            canonicalization: canonicalization
        )
    }

    func verify() throws(ModelBundleVerificationError) -> VerifiedBundleArtifactTree {
        try verifier.verify(bundleID)
    }

    /// The finding verification produced, or `nil` when it succeeded.
    func verificationFinding() -> ModelBundleVerificationError? {
        do {
            _ = try verify()
            return nil
        } catch {
            return error
        }
    }

    /// Re-signs the manifest bytes currently in the tree.
    ///
    /// Used after a test rewrites the manifest on purpose, so the failure under test is
    /// the rewritten field rather than the broken signature it would otherwise cause.
    mutating func replaceManifest(bytes: [UInt8]) {
        manifestBytes = bytes
        tree.overwriteContent(ModelBundleManifest.manifestFileName, bytes: bytes)
        tree.treeEntries = tree.treeEntries.map { entry in
            entry.rawPath == ModelBundleManifest.manifestFileName
                ? BundleTreeEntry(rawPath: entry.rawPath, kind: .file(byteCount: UInt64(bytes.count)))
                : entry
        }
        resign()
    }

    /// Changes only what the enumeration reports for one file, leaving its bytes alone.
    mutating func setReportedByteCount(_ path: String, _ count: UInt64) {
        tree.treeEntries = tree.treeEntries.map { entry in
            entry.rawPath == path
                ? BundleTreeEntry(rawPath: path, kind: .file(byteCount: count))
                : entry
        }
    }

    mutating func resign() {
        guard let keyMaterial = signatures.publicKeyMaterial(for: manifest.signingKey) else {
            return
        }
        let signature = FakeSignatureVerifier.signature(
            over: manifestBytes,
            keyMaterial: keyMaterial
        )
        tree.overwriteContent(ModelBundleManifest.signatureFileName, bytes: signature)
        tree.treeEntries = tree.treeEntries.map { entry in
            entry.rawPath == ModelBundleManifest.signatureFileName
                ? BundleTreeEntry(
                    rawPath: entry.rawPath,
                    kind: .file(byteCount: UInt64(signature.count))
                )
                : entry
        }
    }
}

/// Assembles structurally valid candidate bundles.
///
/// The standard candidate mirrors the design's Model Bundle layout: a manifest and its
/// detached signature at the root, an `artifacts/` container, two declared canonical
/// JSON files, and one declared compiled-model directory tree with a nested
/// subdirectory.
enum BundleAssembler {
    static let modelTreePath = "artifacts/model.mlmodelc"
    static let preprocessingPath = "artifacts/preprocessing.canonical.json"
    static let selfTestsPath = "artifacts/self-tests.canonical.json"

    /// Content of the standard candidate's declared directory tree, by path relative to
    /// the tree root. `nil` bytes mark a directory.
    static let modelTreeMembers: [(relativePath: String, bytes: [UInt8]?)] = [
        ("coremldata.bin", Array("core-ml-data".utf8)),
        ("weights", nil),
        ("weights/weight.bin", Array("weight-blob".utf8)),
    ]

    static func standard(
        bundleID: ModelBundleID = Sample.bundle(),
        declaredBundleID: ModelBundleID? = nil,
        signingKeyID: SigningKeyID = Sample.signingKey(),
        trustedKeyID: SigningKeyID? = nil,
        keyStatus: SigningKeyStatus = .active,
        keyAlgorithm: SignatureAlgorithm? = nil,
        policyAlgorithm: SignatureAlgorithm = .ed25519,
        rotationBehavior: KeyRotationBehavior = .activeKeysOnly,
        governance: ApprovalDecision = .approved,
        canonicalizationApproval: ApprovalDecision = .approved,
        canonicalizationProfile: EvidenceSource? = nil,
        construction: BundleTreeDigestConstruction = .sortedKindTaggedRecords,
        manifestByteCeiling: UInt64 = 65_536,
        supportedAlgorithms: Set<SignatureAlgorithm> = Set(SignatureAlgorithm.allCases),
        keyMaterial: [UInt8] = Array("public-key-material".utf8),
        omitKeyMaterial: Bool = false,
        declaredKeyMaterialDigest: DefAIkeDomain.SHA256Digest? = nil,
        artifactOverrides: ([ArtifactDigestRecord]) -> [ArtifactDigestRecord] = { $0 }
    ) throws -> AssembledBundle {
        var tree = FakeBundleTree()
        tree.addDirectory("artifacts")
        tree.addFile(preprocessingPath, text: "preprocessing-contract")
        tree.addFile(selfTestsPath, text: "self-test-specification")
        tree.addDirectory(modelTreePath)
        for member in modelTreeMembers {
            let path = "\(modelTreePath)/\(member.relativePath)"
            if let bytes = member.bytes {
                tree.addFile(path, bytes: bytes)
            } else {
                tree.addDirectory(path)
            }
        }

        let declared = artifactOverrides([
            fileRecord(preprocessingPath, in: tree),
            fileRecord(selfTestsPath, in: tree),
            treeRecord(modelTreePath, in: tree, construction: construction),
        ])

        let manifest = try Sample.manifest(
            bundleID: declaredBundleID ?? bundleID,
            artifacts: declared,
            signingKey: signingKeyID
        )
        let manifestBytes = try encode(manifest)
        tree.addFile(ModelBundleManifest.manifestFileName, bytes: manifestBytes)

        let signature = FakeSignatureVerifier.signature(
            over: manifestBytes,
            keyMaterial: keyMaterial
        )
        tree.addFile(ModelBundleManifest.signatureFileName, bytes: signature)

        let trustedKey = TrustedSigningKey(
            key: trustedKeyID ?? signingKeyID,
            algorithm: keyAlgorithm ?? policyAlgorithm,
            publicKeyDigest: declaredKeyMaterialDigest
                ?? StreamingSHA256.digest(of: keyMaterial),
            status: keyStatus,
            governanceApproval: Sample.approval(governance)
        )
        var keys = [trustedKey]
        if keyStatus != .active {
            // A policy always carries at least one active key. The candidate still names
            // the nonactive one, which is the case under test.
            keys.append(
                TrustedSigningKey(
                    key: Sample.signingKey("key.active"),
                    algorithm: keyAlgorithm ?? policyAlgorithm,
                    publicKeyDigest: Sample.digest("b"),
                    status: .active,
                    governanceApproval: Sample.approval()
                )
            )
        }
        let profile = canonicalizationProfile ?? Sample.evidence("evidence.canonicalization")
        let policy = try BundleVerificationPolicy(
            id: Sample.artifact("policy.bundle-verification"),
            schemaVersion: .v1,
            algorithm: policyAlgorithm,
            canonicalizationProfile: profile,
            trustedKeys: keys,
            rotationBehavior: rotationBehavior,
            revocationBehavior: .rejectBundle,
            maximumManifestByteCount: Sample.byteCount(manifestByteCeiling),
            reproducibilityEvidence: Sample.evidence("evidence.reproducibility")
        )

        return AssembledBundle(
            tree: tree,
            manifest: manifest,
            manifestBytes: manifestBytes,
            policy: policy,
            canonicalization: ApprovedCanonicalizationProfile(
                profile: profile,
                construction: construction,
                approval: Sample.approval(canonicalizationApproval)
            ),
            signatures: FakeSignatureVerifier(
                material: omitKeyMaterial ? [:] : [signingKeyID.rawValue: keyMaterial],
                supportedAlgorithms: supportedAlgorithms
            ),
            bundleID: bundleID
        )
    }

    /// Encodes a manifest to the bytes a release would sign.
    ///
    /// Sorted keys and unescaped slashes keep the bytes stable and legible, so a test
    /// that rewrites one signed field can find it. Verification never re-encodes a
    /// manifest, so this shape is a test convenience rather than a required form.
    static func encode(_ manifest: ModelBundleManifest) throws -> [UInt8] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return Array(try encoder.encode(manifest))
    }

    static func fileRecord(_ path: String, in tree: FakeBundleTree) -> ArtifactDigestRecord {
        let bytes = tree.fileBytes[path] ?? []
        return ArtifactDigestRecord(
            path: Sample.path(path),
            kind: .file,
            byteCount: UInt64(bytes.count),
            digest: StreamingSHA256.digest(of: bytes)
        )
    }

    static func treeRecord(
        _ root: String,
        in tree: FakeBundleTree,
        construction: BundleTreeDigestConstruction = .sortedKindTaggedRecords
    ) -> ArtifactDigestRecord {
        let prefix = root + "/"
        var members: [BundleTreeDigest.Member] = []
        var total: UInt64 = 0
        for entry in tree.treeEntries where entry.rawPath.hasPrefix(prefix) {
            let relative = String(entry.rawPath.dropFirst(prefix.count))
            switch entry.kind {
            case .directory:
                members.append(.directory(relativePath: relative))
            case .file:
                let bytes = tree.fileBytes[entry.rawPath] ?? []
                total += UInt64(bytes.count)
                members.append(
                    .file(
                        relativePath: relative,
                        byteCount: UInt64(bytes.count),
                        digest: StreamingSHA256.digest(of: bytes)
                    )
                )
            case .symbolicLink, .other:
                continue
            }
        }
        return ArtifactDigestRecord(
            path: Sample.path(root),
            kind: .directoryTree,
            byteCount: total,
            digest: BundleTreeDigest.digest(of: members, construction: construction)
        )
    }
}
