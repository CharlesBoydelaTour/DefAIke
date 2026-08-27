import DefAIkeDomain

// Steps 1 through 3 of the fixed verification order (design, Model Bundle Manager):
//
//   1. Parse the bounded manifest with duplicate-key rejection, canonical path
//      validation, no symlink traversal, and schema and version limits.
//   2. Validate the manifest signature against the active Bundle Verification Policy
//      and trusted release-key identifier.
//   3. Stream-hash every declared artifact and reject missing, extra, duplicate,
//      size-mismatched, or digest-mismatched content.
//
// Steps 4 through 7 — model identity and compatibility, self-test verification,
// candidate load and offline self-test execution, receipts and atomic activation —
// are separate values built on this one.
//
// Every trust answer here comes from the injected policy. This file contains no
// algorithm choice, no key, no rotation rule, and no revocation rule, and it has no
// path that continues when one of those is absent.

/// The reserved root entries of every Model Bundle, as canonical paths.
enum ReservedBundleFile {
    static let manifest = canonical(ModelBundleManifest.manifestFileName)
    static let signature = canonical(ModelBundleManifest.signatureFileName)

    static let names: Set<String> = [manifest.rawValue, signature.rawValue]

    private static func canonical(_ name: String) -> CanonicalRelativePath {
        guard let path = CanonicalRelativePath(name) else {
            preconditionFailure("A reserved Model Bundle file name must be a canonical path.")
        }
        return path
    }
}

/// Verifies a locally installed candidate's manifest, signature, and artifact tree.
///
/// Holds no mutable state: one verifier can be reused, and two runs over the same tree
/// produce the same finding or the same verified value.
///
/// Synchronous on purpose. Verification is a decision over bytes with no suspension
/// point of its own, so keeping it synchronous makes it a plain function a test can call
/// and keeps chunk hashing free of cross-isolation closure passing. `ModelBundleManaging`
/// is the asynchronous boundary, and the adapter that conforms to it decides where this
/// work runs.
public struct ModelBundleIntegrityVerifier: Sendable {
    /// Read granularity for stream hashing.
    ///
    /// A memory bound only. Chunk boundaries cannot change a digest, so no artifact's
    /// verification result depends on this number.
    public static let readChunkByteCount = 64 * 1024

    /// Ceiling on entries in one candidate tree. A structural bound that keeps a walk
    /// finite; not an approved value.
    public static let maximumTreeEntryCount = 8192

    /// Ceiling on a detached signature. The largest signature any algorithm in
    /// ``SignatureAlgorithm`` produces is under 512 bytes; this is a structural bound
    /// well above that, not an approved value.
    public static let maximumSignatureByteCount = 4096

    private let content: any ModelBundleContentReading
    private let signatures: any BundleSignatureVerifying
    private let policy: BundleVerificationPolicy
    private let canonicalization: ApprovedCanonicalizationProfile

    /// Creates a verifier bound to one approved policy and canonicalization profile.
    ///
    /// Both are required arguments with no default. A build that has not been given
    /// them cannot construct a verifier, which is what makes "no source-code default
    /// for the algorithm, keys, rotation, or revocation" a compile-time fact rather
    /// than a review note.
    public init(
        content: any ModelBundleContentReading,
        signatures: any BundleSignatureVerifying,
        policy: BundleVerificationPolicy,
        canonicalization: ApprovedCanonicalizationProfile
    ) {
        self.content = content
        self.signatures = signatures
        self.policy = policy
        self.canonicalization = canonicalization
    }

    /// Verifies one locally installed candidate.
    ///
    /// `bundle` names an artifact already present on the device. There is no URL and
    /// no fetch: verification reads what a release installed and nothing else
    /// (Requirements 10.19 and 10.21).
    public func verify(
        _ bundle: ModelBundleID
    ) throws(ModelBundleVerificationError) -> VerifiedBundleArtifactTree {
        try requireApprovedCanonicalization()

        let entries = try validatedEntries(in: bundle)
        let manifestBytes = try readReservedFile(
            ReservedBundleFile.manifest,
            in: bundle,
            entries: entries,
            ceiling: policy.maximumManifestByteCount.value
        )
        let parsed = try ModelBundleManifestParser.parse(
            manifestBytes,
            for: bundle,
            policy: policy
        )

        let signatureBytes = try readReservedFile(
            ReservedBundleFile.signature,
            in: bundle,
            entries: entries,
            ceiling: UInt64(Self.maximumSignatureByteCount)
        )
        try verifySignature(
            signatureBytes,
            over: manifestBytes,
            key: parsed.manifest.signingKey
        )

        let verified = try verifyArtifacts(parsed.manifest, entries: entries, in: bundle)

        return VerifiedBundleArtifactTree(
            bundleID: bundle,
            manifest: parsed.manifest,
            manifestDigest: parsed.manifestDigest,
            verifiedArtifacts: verified,
            verificationPolicyID: policy.id,
            signingKey: parsed.manifest.signingKey
        )
    }

    // MARK: - Canonicalization

    /// Requires the build's tree-digest construction to be the approved profile the
    /// active policy names.
    ///
    /// Both halves matter. An unapproved correspondence is refused because presence is
    /// not approval, and a profile this build does not implement is refused because
    /// computing some other deterministic digest would silently answer a different
    /// question than the signature covers.
    private func requireApprovedCanonicalization() throws(ModelBundleVerificationError) {
        guard canonicalization.approval.isApproved else {
            throw ModelBundleVerificationError.canonicalizationProfileNotApproved(
                canonicalization.profile.artifact
            )
        }
        guard canonicalization.profile == policy.canonicalizationProfile else {
            throw ModelBundleVerificationError.canonicalizationProfileMismatch(
                policyProfile: policy.canonicalizationProfile.artifact,
                buildProfile: canonicalization.profile.artifact
            )
        }
    }

    // MARK: - Tree structure

    /// One entry that survived structural validation.
    private struct ValidatedEntry: Hashable, Sendable {
        let path: CanonicalRelativePath
        let isDirectory: Bool
        /// Bytes the enumeration reported. Zero for a directory.
        let reportedByteCount: UInt64
    }

    /// Enumerates the tree and refuses anything a verified tree cannot contain.
    ///
    /// Runs before the manifest is read, so a symbolic link cannot be followed to
    /// reach the manifest itself, and a traversing path cannot be read at all.
    private func validatedEntries(
        in bundle: ModelBundleID
    ) throws(ModelBundleVerificationError) -> [ValidatedEntry] {
        let raw: [BundleTreeEntry]
        do {
            raw = try content.entries(in: bundle)
        } catch {
            throw ModelBundleVerificationError.bundleTreeUnreadable(bundle)
        }
        guard raw.count <= Self.maximumTreeEntryCount else {
            throw ModelBundleVerificationError.treeEntryBudgetExceeded(
                maximumEntryCount: Self.maximumTreeEntryCount,
                found: raw.count
            )
        }

        var seen = Set<String>()
        var validated: [ValidatedEntry] = []
        validated.reserveCapacity(raw.count)
        for entry in raw {
            guard seen.insert(entry.rawPath).inserted else {
                throw ModelBundleVerificationError.duplicateTreeEntry(entry.rawPath)
            }
            let isDirectory: Bool
            let reportedByteCount: UInt64
            switch entry.kind {
            case let .file(byteCount):
                isDirectory = false
                reportedByteCount = byteCount
            case .directory:
                isDirectory = true
                reportedByteCount = 0
            case .symbolicLink:
                throw ModelBundleVerificationError.symbolicLinkPresent(entry.rawPath)
            case .other:
                throw ModelBundleVerificationError.unsupportedEntryKind(entry.rawPath)
            }
            guard let path = CanonicalRelativePath(entry.rawPath) else {
                throw ModelBundleVerificationError.noncanonicalEntryPath(entry.rawPath)
            }
            validated.append(
                ValidatedEntry(
                    path: path,
                    isDirectory: isDirectory,
                    reportedByteCount: reportedByteCount
                )
            )
        }
        return validated
    }

    // MARK: - Reserved files

    private func readReservedFile(
        _ path: CanonicalRelativePath,
        in bundle: ModelBundleID,
        entries: [ValidatedEntry],
        ceiling: UInt64
    ) throws(ModelBundleVerificationError) -> [UInt8] {
        guard let entry = entries.first(where: { $0.path == path }) else {
            throw ModelBundleVerificationError.reservedFileMissing(path.rawValue)
        }
        guard !entry.isDirectory else {
            throw ModelBundleVerificationError.reservedFileNotAFile(path.rawValue)
        }
        // Refused from the enumerated size, before a single byte is read.
        if entry.reportedByteCount > ceiling {
            throw Self.overCeilingFinding(
                path,
                ceiling: ceiling,
                found: entry.reportedByteCount
            )
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(Int(entry.reportedByteCount))
        var exceeded = false
        do {
            try content.readFile(
                at: path,
                in: bundle,
                chunkByteCount: Self.readChunkByteCount
            ) { chunk in
                guard UInt64(bytes.count) + UInt64(chunk.count) <= ceiling else {
                    exceeded = true
                    return .stop
                }
                bytes.append(contentsOf: chunk)
                return .proceed
            }
        } catch {
            throw ModelBundleVerificationError.reservedFileUnreadable(path.rawValue)
        }
        // The enumerated size understated the content. Reading already stopped at the
        // ceiling, so the exact size is unknown and is not guessed.
        guard !exceeded else {
            throw ModelBundleVerificationError.reservedFileExceedsCeiling(
                name: path.rawValue,
                ceiling: ceiling
            )
        }
        if path == ReservedBundleFile.signature, bytes.isEmpty {
            throw ModelBundleVerificationError.signatureEmpty
        }
        return bytes
    }

    /// Reports an over-ceiling reserved file as the finding its role deserves.
    private static func overCeilingFinding(
        _ path: CanonicalRelativePath,
        ceiling: UInt64,
        found: UInt64
    ) -> ModelBundleVerificationError {
        path == ReservedBundleFile.manifest
            ? .manifestTooLarge(ceiling: ceiling, found: found)
            : .signatureTooLarge(ceiling: ceiling, found: found)
    }

    // MARK: - Signature

    /// Verifies the detached signature over the exact manifest bytes.
    ///
    /// Every decision below reads a policy field. The algorithm is `policy.algorithm`,
    /// the trusted set is `policy.trustedKeys`, the rotation answer is
    /// `policy.rotationBehavior`, and the revocation answer is
    /// `policy.revocationBehavior` — which the policy schema already constrains to
    /// rejecting the bundle, so an unresolved revocation question is never trust.
    private func verifySignature(
        _ signature: [UInt8],
        over manifestBytes: [UInt8],
        key: SigningKeyID
    ) throws(ModelBundleVerificationError) {
        let trusted = try authorizedKey(key)

        guard let material = signatures.publicKeyMaterial(for: key), !material.isEmpty else {
            throw ModelBundleVerificationError.signingKeyMaterialUnavailable(key)
        }
        guard StreamingSHA256.digest(of: material) == trusted.publicKeyDigest else {
            throw ModelBundleVerificationError.signingKeyMaterialDigestMismatch(key)
        }

        switch signatures.verify(
            signature: signature,
            over: manifestBytes,
            using: policy.algorithm,
            publicKeyMaterial: material
        ) {
        case .verified:
            return
        case .notVerified:
            throw ModelBundleVerificationError.manifestSignatureDidNotVerify(key: key)
        case .algorithmUnsupported:
            throw ModelBundleVerificationError.signatureAlgorithmUnsupported(policy.algorithm)
        }
    }

    /// The policy's record for one key, when that key may verify this bundle.
    private func authorizedKey(
        _ key: SigningKeyID
    ) throws(ModelBundleVerificationError) -> TrustedSigningKey {
        guard let trusted = policy.trustedKey(key) else {
            throw ModelBundleVerificationError.signingKeyNotTrusted(key)
        }
        guard trusted.governanceApproval.isApproved else {
            throw ModelBundleVerificationError.signingKeyGovernanceNotApproved(key)
        }
        // The algorithm is read from one place, `policy.algorithm`, and the policy
        // schema already requires every trusted key to record that same algorithm, so
        // there is no second opinion to reconcile here.
        switch trusted.status {
        case .active:
            return trusted
        case .revoked:
            throw ModelBundleVerificationError.signingKeyRevoked(key)
        case .retired:
            switch policy.rotationBehavior {
            case .activeKeysOnly:
                throw ModelBundleVerificationError.retiredSigningKeyRejectedByRotationRule(key)
            case .retiredKeysVerifyHistoricalBundles:
                // The rule is "predecessors verify bundles signed before their
                // retirement". Applying it needs a retirement instant and a signing
                // instant, and neither the policy's key record nor the manifest
                // carries one. Widening it to "any retired key" would be this module
                // inventing a rotation rule, so verification fails closed instead.
                throw ModelBundleVerificationError.retiredSigningKeyWindowNotEstablishable(key)
            }
        }
    }

    // MARK: - Artifact tree

    /// Stream-hashes every declared artifact and requires the tree to hold exactly
    /// what the manifest declares.
    private func verifyArtifacts(
        _ manifest: ModelBundleManifest,
        entries: [ValidatedEntry],
        in bundle: ModelBundleID
    ) throws(ModelBundleVerificationError) -> [ArtifactDigestRecord] {
        let declared = manifest.artifacts.reduce(into: [String: ArtifactDigestRecord]()) {
            $0[$1.path.rawValue] = $1
        }
        let treeRoots = manifest.artifacts
            .filter { $0.kind == .directoryTree }
            .map { $0.path.rawValue + "/" }
        var containers = Set<String>()
        for path in declared.keys {
            containers.formUnion(Self.strictAncestors(of: path))
        }
        let byPath = entries.reduce(into: [String: ValidatedEntry]()) { $0[$1.path.rawValue] = $1 }
        let ordered = Self.orderedByPath(manifest.artifacts)

        // Presence and kind first. A directory declared as a file also makes every one
        // of its members undeclared, and the mismatch is the finding worth reporting.
        for record in ordered {
            guard let entry = byPath[record.path.rawValue] else {
                throw ModelBundleVerificationError.declaredArtifactMissing(record.path)
            }
            guard entry.isDirectory == (record.kind == .directoryTree) else {
                throw ModelBundleVerificationError.declaredArtifactKindMismatch(
                    path: record.path,
                    declared: record.kind
                )
            }
        }

        try requireDeclaredOnlyContents(
            entries,
            declared: declared,
            containers: containers,
            treeRoots: treeRoots
        )

        var verified: [ArtifactDigestRecord] = []
        verified.reserveCapacity(ordered.count)
        for record in ordered {
            switch record.kind {
            case .file:
                try verifyFileArtifact(record, in: bundle)
            case .directoryTree:
                try verifyDirectoryTreeArtifact(record, entries: entries, in: bundle)
            }
            verified.append(record)
        }
        return verified
    }

    /// Requires every present entry to be declared, an implied container of a declared
    /// artifact, or a member of a declared directory tree.
    ///
    /// This is the "extra content" half of mutation sensitivity: an added file, an
    /// added empty directory, or a leftover staging file is a finding even when every
    /// declared digest still matches.
    private func requireDeclaredOnlyContents(
        _ entries: [ValidatedEntry],
        declared: [String: ArtifactDigestRecord],
        containers: Set<String>,
        treeRoots: [String]
    ) throws(ModelBundleVerificationError) {
        for entry in entries {
            let path = entry.path.rawValue
            // The manifest and its signature were already read as regular files.
            if ReservedBundleFile.names.contains(path) { continue }
            if declared[path] != nil { continue }
            if containers.contains(path) {
                guard entry.isDirectory else {
                    throw ModelBundleVerificationError.undeclaredTreeEntry(entry.path)
                }
                continue
            }
            if treeRoots.contains(where: { path.hasPrefix($0) }) { continue }
            throw ModelBundleVerificationError.undeclaredTreeEntry(entry.path)
        }
    }

    /// Stream-hashes one declared file artifact. Its kind is already established.
    private func verifyFileArtifact(
        _ record: ArtifactDigestRecord,
        in bundle: ModelBundleID
    ) throws(ModelBundleVerificationError) {
        let measured = try streamDigest(
            at: record.path,
            in: bundle,
            declaredByteCount: record.byteCount
        )
        guard measured.byteCount == record.byteCount else {
            throw ModelBundleVerificationError.artifactByteCountMismatch(
                path: record.path,
                declared: record.byteCount,
                found: measured.byteCount
            )
        }
        guard measured.digest == record.digest else {
            throw ModelBundleVerificationError.artifactDigestMismatch(record.path)
        }
    }

    /// Digests one declared directory-tree artifact. Its kind is already established.
    private func verifyDirectoryTreeArtifact(
        _ record: ArtifactDigestRecord,
        entries: [ValidatedEntry],
        in bundle: ModelBundleID
    ) throws(ModelBundleVerificationError) {
        let prefix = record.path.rawValue + "/"
        let members = entries.filter { $0.path.rawValue.hasPrefix(prefix) }
        guard !members.isEmpty else {
            throw ModelBundleVerificationError.emptyDirectoryTreeArtifact(record.path)
        }

        var digestMembers: [BundleTreeDigest.Member] = []
        digestMembers.reserveCapacity(members.count)
        var total: UInt64 = 0
        for member in Self.orderedByPath(members, path: \.path) {
            let relative = String(member.path.rawValue.dropFirst(prefix.count))
            if member.isDirectory {
                digestMembers.append(.directory(relativePath: relative))
                continue
            }
            // Each member is bounded by the tree's own declared total, so a candidate
            // cannot make verification hash more bytes than its manifest declares even
            // when the enumeration under-reports a member's size.
            let remaining = total > record.byteCount ? 0 : record.byteCount - total
            let measured = try streamDigest(
                at: member.path,
                in: bundle,
                declaredByteCount: remaining
            )
            let (sum, overflow) = total.addingReportingOverflow(measured.byteCount)
            guard !overflow else {
                throw ModelBundleVerificationError.artifactReadExceededDeclaredBound(
                    path: record.path,
                    bound: record.byteCount
                )
            }
            total = sum
            digestMembers.append(
                .file(
                    relativePath: relative,
                    byteCount: measured.byteCount,
                    digest: measured.digest
                )
            )
        }

        guard total == record.byteCount else {
            throw ModelBundleVerificationError.artifactByteCountMismatch(
                path: record.path,
                declared: record.byteCount,
                found: total
            )
        }
        let digest = BundleTreeDigest.digest(
            of: digestMembers,
            construction: canonicalization.construction
        )
        guard digest == record.digest else {
            throw ModelBundleVerificationError.artifactDigestMismatch(record.path)
        }
    }

    /// Hashes one file while it streams, stopping the moment it runs past
    /// `declaredByteCount`.
    private func streamDigest(
        at path: CanonicalRelativePath,
        in bundle: ModelBundleID,
        declaredByteCount: UInt64
    ) throws(ModelBundleVerificationError) -> (digest: SHA256Digest, byteCount: UInt64) {
        var hasher = StreamingSHA256()
        var observed: UInt64 = 0
        var exceeded = false
        do {
            try content.readFile(
                at: path,
                in: bundle,
                chunkByteCount: Self.readChunkByteCount
            ) { chunk in
                let (sum, overflow) = observed.addingReportingOverflow(UInt64(chunk.count))
                guard !overflow, sum <= declaredByteCount else {
                    exceeded = true
                    return .stop
                }
                observed = sum
                hasher.update(chunk)
                return .proceed
            }
        } catch {
            throw ModelBundleVerificationError.artifactUnreadable(path)
        }
        guard !exceeded else {
            throw ModelBundleVerificationError.artifactReadExceededDeclaredBound(
                path: path,
                bound: declaredByteCount
            )
        }
        return (hasher.finalize(), observed)
    }

    // MARK: - Path helpers

    /// Every strict ancestor directory path of `path`, nearest first.
    static func strictAncestors(of path: String) -> [String] {
        var components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return [] }
        components.removeLast()
        var ancestors: [String] = []
        while !components.isEmpty {
            ancestors.append(components.joined(separator: "/"))
            components.removeLast()
        }
        return ancestors
    }

    /// Orders records by the UTF-8 bytes of their canonical path.
    ///
    /// Byte ordering rather than `String` ordering, so the sequence a receipt records
    /// does not depend on Unicode collation behavior.
    private static func orderedByPath(
        _ records: [ArtifactDigestRecord]
    ) -> [ArtifactDigestRecord] {
        orderedByPath(records, path: \.path)
    }

    private static func orderedByPath<Element>(
        _ elements: [Element],
        path: KeyPath<Element, CanonicalRelativePath>
    ) -> [Element] {
        elements.sorted {
            $0[keyPath: path].rawValue.utf8
                .lexicographicallyPrecedes($1[keyPath: path].rawValue.utf8)
        }
    }
}
