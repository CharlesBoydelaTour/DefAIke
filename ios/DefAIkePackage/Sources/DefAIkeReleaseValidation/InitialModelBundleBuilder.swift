import DefAIkeDomain
import DefAIkeModelBundle

// Assembling the Initial Model Bundle (Requirements 10.1 through 10.7, and 14.5).
//
// The builder does one thing: turn approved records into the exact bytes a release signs.
// It holds no state, computes no digest, states no verification rule, and makes no fitness
// judgement about its own output. Three properties are structural rather than asserted, and
// each one is why a line below looks the way it does.
//
// **It reuses the runtime's rules rather than restating them.** Everything the runtime
// verifier will later check is either derived from the record the verifier compares against,
// or left entirely to the verifier:
//
//   | Manifest field | Where it comes from | Which check it satisfies |
//   |---|---|---|
//   | `modelIdentity` | ``RequiredPixelModel/identity`` | 10.2, 10.4 |
//   | `modelFormat` | the only value ``ModelFormatDescriptor`` admits | 10.3 |
//   | `inputContract` | `configuration.preprocessingContract.modelInput` | 4.5–4.8 |
//   | `componentVersions.preprocessingContract` | `configuration.preprocessingContract.id` | 10.7 |
//   | `componentVersions.calibrationPolicy` | `configuration.calibrationPolicy.id` | 10.7 |
//   | `componentVersions.verdictCopyCompatibility` | `configuration.verdictCopyCatalog.compatibilityID` | 10.7 |
//   | `componentVersions.evidenceScope` | `request.evidenceScope.id` | 10.7 |
//   | `componentVersions.selfTestSpecification` | `request.selfTestSpecification.id` | 10.9 |
//   | `upstreamBoundaryMetadata` | the only value ``UpstreamBoundaryMetadata`` admits | 5.14 |
//   | artifact paths | ``ApprovedBundleLayout`` and ``ApprovedBundleLayout/fixtureAssetPath(suiteRelative:)`` | 10.5 |
//
// Derivation, not duplication: each of those is *read from the very record compatibility
// verification will compare it against*, so there is no second opinion to reconcile. The
// checks the builder does **not** make are as deliberate: it does not decide whether the
// canonicalization binding is approved, whether the designated key is trusted, whether the
// self-test cases resolve against the catalogue, or whether the staged weight blob is the
// approved one. Every one of those is a step in the fixed verification order, and the only
// implementation of that order is `DefAIkeModelBundle`'s.
//
// **It is reproducible.** Every byte it emits is a function of the approved inputs.
// Canonical encoding orders object members and set-valued fields deterministically, the
// digest inventory and the tree plan are ordered by the UTF-8 bytes of their canonical
// paths, and nothing reads a clock, a random source, an environment variable, or a process
// identifier. `InitialModelBundleBuilderTests` builds twice and compares bytes.
//
// **It cannot sign and cannot approve.** The signing key is an identity read from an
// approved record through a seam with nothing to choose among, the algorithm is read from
// the policy, and the output is a request. Nothing here constructs an ``ApprovalRecord``,
// and `BundleToolingBoundaryTests` scans the module's sources to keep it that way.

/// Assembles one Initial Model Bundle from approved records.
///
/// Synchronous and stateless: a build is a function of its request and its two seams, so two
/// builds over the same inputs produce the same finding or the same bytes.
public struct InitialModelBundleBuilder: Sendable {
    private let measurements: any BundleArtifactMeasuring
    private let keyGovernance: any ReleaseKeyGovernanceReading

    /// Creates a builder bound to one measurement seam and one key-governance record.
    ///
    /// Both are required with no default. A build that has not been told what its staged
    /// bytes measure to, or which key governance designated, cannot produce anything —
    /// rather than measuring under a construction this module chose or naming a key it
    /// picked.
    public init(
        measurements: any BundleArtifactMeasuring,
        keyGovernance: any ReleaseKeyGovernanceReading
    ) {
        self.measurements = measurements
        self.keyGovernance = keyGovernance
    }

    /// Builds the canonical artifact tree, manifest, digest inventory, notices, and signing
    /// request for one bundle.
    public func build(
        _ request: InitialModelBundleBuildRequest
    ) throws(BundleBuildError) -> UnsignedInitialModelBundle {
        // Read once, at the start. The manifest records the designated key and the signing
        // request names it, and reading the record twice would let a nondeterministic seam put
        // two different keys into one build.
        let designated = try designatedKey(request)

        let notices = try noticeArtifacts(request)
        let metadata = try metadataArtifacts(request)
        let staged = try stagedArtifacts(request)

        let declared = try declaredRecords(
            request,
            notices: notices,
            metadata: metadata,
            staged: staged
        )
        let manifest = try assembledManifest(
            request,
            artifacts: declared,
            signingKey: designated.key
        )
        let manifestBytes = try canonicalBytes(of: manifest, role: .manifest)
        let manifestMeasurement = measurements.measureGeneratedFile(manifestBytes)

        return UnsignedInitialModelBundle(
            bundleID: request.bundleID,
            tree: treePlan(
                request,
                notices: notices,
                metadata: metadata,
                staged: staged,
                declared: declared,
                manifestBytes: manifestBytes,
                manifestMeasurement: manifestMeasurement
            ),
            manifest: manifest,
            manifestBytes: manifestBytes,
            digestInventory: declared,
            noticeIndex: notices.index,
            signingRequest: signingRequest(
                request,
                designated: designated,
                manifestBytes: manifestBytes,
                manifestDigest: manifestMeasurement.digest
            )
        )
    }

    // MARK: - Notices (Requirement 14.5)

    /// The notice index and the measured notice tree.
    private struct NoticeArtifacts {
        let index: BundleNoticeIndex
        let indexBytes: [UInt8]
        let indexMeasurement: BundleArtifactMeasurement
        let rootMeasurement: BundleArtifactMeasurement
    }

    /// Measures every approved notice text, writes the index, and measures the notice tree.
    ///
    /// Each notice is measured individually as well as through the tree digest, and that is
    /// not redundant: the tree digest covers whatever the tree holds, so it would still match
    /// a tree with a notice missing. Measuring each one is how "this notice is included"
    /// becomes a build obligation instead of a hope, and putting the measurement in the index
    /// is how an audit can tell an omitted notice from a present one without reading prose.
    private func noticeArtifacts(
        _ request: InitialModelBundleBuildRequest
    ) throws(BundleBuildError) -> NoticeArtifacts {
        let set = request.notices
        var indexed: [IndexedBundleNotice] = []
        indexed.reserveCapacity(set.allNotices.count)

        for (subject, reference) in Self.subjects(of: set) {
            let path = try noticePath(reference.rootRelativePath, under: request.noticeRoot)
            let measurement = try measuredStagedFile(at: path, role: .noticeText)
            indexed.append(
                IndexedBundleNotice(
                    subject: subject,
                    source: reference.source,
                    path: path,
                    byteCount: measurement.byteCount,
                    contentDigest: measurement.digest
                )
            )
        }

        let index = BundleNoticeIndex(
            id: set.id,
            schemaVersion: set.schemaVersion,
            noticeRoot: request.noticeRoot,
            notices: indexed,
            // The record, not the decision. A bundle does not carry its own approval.
            approvalSource: set.approval.source
        )
        let indexBytes = try canonicalBytes(of: index, role: .noticeIndex)

        return NoticeArtifacts(
            index: index,
            indexBytes: indexBytes,
            indexMeasurement: measurements.measureGeneratedFile(indexBytes),
            rootMeasurement: try measuredStagedTree(
                at: request.noticeRoot,
                role: .noticeRoot,
                construction: request.canonicalization.construction
            )
        )
    }

    /// Every notice with the subject it attributes, checkpoint first.
    ///
    /// The checkpoint entry cannot be absent: ``ApprovedBundleNoticeSet/checkpointNotice`` is
    /// a required field, so Requirement 14.5's named subject is structural rather than
    /// checked here.
    private static func subjects(
        of set: ApprovedBundleNoticeSet
    ) -> [(BundleNoticeSubject, BundleNoticeReference)] {
        [(.lowqCheckpoint(set.checkpointNotice.checkpoint), set.checkpointNotice.notice)]
            + set.dependencyNotices.map { (.dependency($0.subject), $0.notice) }
    }

    /// The bundle-relative path of one notice text under the approved notice root.
    private func noticePath(
        _ rootRelative: CanonicalRelativePath,
        under root: CanonicalRelativePath
    ) throws(BundleBuildError) -> CanonicalRelativePath {
        guard let path = CanonicalRelativePath("\(root.rawValue)/\(rootRelative.rawValue)") else {
            throw BundleBuildError.noticePathNotResolvable(rootRelative)
        }
        return path
    }

    // MARK: - Generated metadata artifacts

    /// The two canonical-JSON artifacts a build writes from approved records.
    private struct MetadataArtifacts {
        let specificationBytes: [UInt8]
        let specificationMeasurement: BundleArtifactMeasurement
        let catalogBytes: [UInt8]
        let catalogMeasurement: BundleArtifactMeasurement
    }

    /// Encodes the approved self-test specification and fixture catalogue
    /// (Requirements 10.9 and 10.10).
    ///
    /// Encoded rather than staged, because both are approved *records* the release already
    /// holds as values, and re-encoding them here is what binds their bytes to the manifest
    /// digest inventory. Their contents are not inspected: whether every case resolves to a
    /// catalogued fixture whose asset is present with the catalogued digest is step 5 of the
    /// verification order, and restating it here would be a second copy of that rule.
    private func metadataArtifacts(
        _ request: InitialModelBundleBuildRequest
    ) throws(BundleBuildError) -> MetadataArtifacts {
        let specificationBytes = try canonicalBytes(
            of: request.selfTestSpecification,
            role: .selfTestSpecification
        )
        let catalogBytes = try canonicalBytes(of: request.fixtureCatalog, role: .fixtureCatalog)
        return MetadataArtifacts(
            specificationBytes: specificationBytes,
            specificationMeasurement: measurements.measureGeneratedFile(specificationBytes),
            catalogBytes: catalogBytes,
            catalogMeasurement: measurements.measureGeneratedFile(catalogBytes)
        )
    }

    // MARK: - Staged trees

    /// The two directory trees a build copies unchanged.
    private struct StagedArtifacts {
        let compiledModel: BundleArtifactMeasurement
        let fixtureRoot: BundleArtifactMeasurement
    }

    /// Measures the compiled model and the fixture assets where the release staged them.
    ///
    /// The compiled model is copied wholesale, weight blob included. The builder never reads,
    /// rewrites, or digests the weight blob on its own: Requirement 10.4 pins that digest and
    /// the only code that measures it against the pinned value is compatibility verification.
    private func stagedArtifacts(
        _ request: InitialModelBundleBuildRequest
    ) throws(BundleBuildError) -> StagedArtifacts {
        let construction = request.canonicalization.construction
        return StagedArtifacts(
            compiledModel: try measuredStagedTree(
                at: request.layout.compiledModel,
                role: .compiledModel,
                construction: construction
            ),
            fixtureRoot: try measuredStagedTree(
                at: request.layout.fixtureRoot,
                role: .fixtureRoot,
                construction: construction
            )
        )
    }

    // MARK: - The digest inventory (Requirement 10.5)

    /// One declared artifact per emitted file and tree, ordered by canonical path bytes.
    ///
    /// Ordering is imposed here rather than assumed of the caller, so the order the
    /// measurements happened in cannot reach the manifest bytes. It is the same ordering
    /// ``VerifiedBundleArtifactTree/verifiedArtifacts`` uses, so the inventory a build
    /// declares and the inventory a verification measures are comparable element by element.
    private func declaredRecords(
        _ request: InitialModelBundleBuildRequest,
        notices: NoticeArtifacts,
        metadata: MetadataArtifacts,
        staged: StagedArtifacts
    ) throws(BundleBuildError) -> [ArtifactDigestRecord] {
        let layout = request.layout
        return try assemble([
            record(layout.compiledModel, .directoryTree, staged.compiledModel),
            record(layout.selfTestSpecification, .file, metadata.specificationMeasurement),
            record(layout.fixtureCatalog, .file, metadata.catalogMeasurement),
            record(layout.fixtureRoot, .directoryTree, staged.fixtureRoot),
            record(request.noticeIndexPath, .file, notices.indexMeasurement),
            record(request.noticeRoot, .directoryTree, notices.rootMeasurement),
        ])
    }

    /// Every declared record, checked only for the two ways a *build* cannot proceed.
    ///
    /// Two artifacts on one path and one artifact inside another are refused because the
    /// builder cannot emit either: the first would have one file carry two digests, and the
    /// second would have the same bytes covered twice. Both are also runtime findings, and
    /// that is not a duplicated rule — it is the builder declining to write something it
    /// knows it cannot write, and naming the approved path that caused it rather than leaving
    /// an operator to read a verification finding about a path they did not choose.
    private func assemble(
        _ records: [ArtifactDigestRecord]
    ) throws(BundleBuildError) -> [ArtifactDigestRecord] {
        var seen = Set<String>()
        for candidate in records {
            guard !ReservedBundleFileNames.all.contains(candidate.path.rawValue) else {
                throw BundleBuildError.pathIsReservedBundleFile(candidate.path)
            }
            guard seen.insert(candidate.path.rawValue).inserted else {
                throw BundleBuildError.duplicateArtifactPath(candidate.path)
            }
        }
        let ordered = records.sorted {
            $0.path.rawValue.utf8.lexicographicallyPrecedes($1.path.rawValue.utf8)
        }
        for (offset, outer) in ordered.enumerated() {
            let prefix = outer.path.rawValue + "/"
            for inner in ordered[(offset + 1)...] where inner.path.rawValue.hasPrefix(prefix) {
                throw BundleBuildError.overlappingArtifactPaths(
                    outer: outer.path,
                    inner: inner.path
                )
            }
        }
        return ordered
    }

    private func record(
        _ path: CanonicalRelativePath,
        _ kind: ArtifactDigestRecord.Kind,
        _ measurement: BundleArtifactMeasurement
    ) -> ArtifactDigestRecord {
        ArtifactDigestRecord(
            path: path,
            kind: kind,
            byteCount: measurement.byteCount,
            digest: measurement.digest
        )
    }

    // MARK: - The manifest

    /// Assembles the signed manifest from approved records.
    ///
    /// Every field is either an approved input or read from the artifact compatibility
    /// verification compares it against; see this file's table. The domain's validating
    /// initializer is the refusal, so a manifest this build emits cannot violate the schema a
    /// runtime parse enforces.
    private func assembledManifest(
        _ request: InitialModelBundleBuildRequest,
        artifacts: [ArtifactDigestRecord],
        signingKey: SigningKeyID
    ) throws(BundleBuildError) -> ModelBundleManifest {
        let configuration = request.configuration
        do {
            return try ModelBundleManifest(
                schemaVersion: request.manifestSchemaVersion,
                bundleID: request.bundleID,
                modelIdentity: RequiredPixelModel.identity,
                modelFormat: try ModelFormatDescriptor(
                    programKind: .mlProgram,
                    computePrecision: .float16,
                    minimumOS: .iOS17
                ),
                inputContract: configuration.preprocessingContract.modelInput,
                outputContract: request.outputContract,
                componentVersions: BundleComponentVersions(
                    coreMLModel: request.coreMLModelVersion,
                    preprocessingContract: configuration.preprocessingContract.id,
                    calibrationPolicy: configuration.calibrationPolicy.id,
                    evidenceScope: request.evidenceScope.id,
                    verdictCopyCompatibility: configuration.verdictCopyCatalog.compatibilityID,
                    selfTestSpecification: request.selfTestSpecification.id
                ),
                artifacts: artifacts,
                compatibility: request.compatibility,
                upstreamBoundaryMetadata: try UpstreamBoundaryMetadata(
                    rawLogitValue: UpstreamBoundaryMetadata.requiredValue,
                    role: .modelMetadataOnly
                ),
                signingKey: signingKey
            )
        } catch let error as ArtifactSchemaError {
            throw BundleBuildError.manifestRejectedBySchema(error)
        } catch {
            // Unreachable: every initializer above throws `ArtifactSchemaError`. Refusing
            // rather than trapping keeps the fail-closed direction if that ever changes.
            throw BundleBuildError.manifestRejectedBySchema(
                .missingRequiredEntries(field: "manifest", keys: ["assembled manifest"])
            )
        }
    }

    // MARK: - The tree plan

    /// Describes the canonical artifact tree, container directories included.
    private func treePlan(
        _ request: InitialModelBundleBuildRequest,
        notices: NoticeArtifacts,
        metadata: MetadataArtifacts,
        staged: StagedArtifacts,
        declared: [ArtifactDigestRecord],
        manifestBytes: [UInt8],
        manifestMeasurement: BundleArtifactMeasurement
    ) -> CanonicalBundleTreePlan {
        var entries: [PlannedBundleEntry] = []
        let generated: [CanonicalRelativePath: [UInt8]] = [
            request.noticeIndexPath: notices.indexBytes,
            request.layout.selfTestSpecification: metadata.specificationBytes,
            request.layout.fixtureCatalog: metadata.catalogBytes,
        ]

        for artifact in declared {
            let content: PlannedBundleContent = generated[artifact.path]
                .map { PlannedBundleContent.generatedFile(bytes: $0) } ?? .stagedDirectoryTree
            entries.append(
                PlannedBundleEntry(
                    path: artifact.path,
                    content: content,
                    measurement: BundleArtifactMeasurement(
                        byteCount: artifact.byteCount,
                        digest: artifact.digest
                    ),
                    isDeclaredArtifact: true
                )
            )
        }

        // The manifest: a reserved root file, generated, and never self-declared.
        entries.append(
            PlannedBundleEntry(
                path: ReservedBundleFileNames.manifest,
                content: .generatedFile(bytes: manifestBytes),
                measurement: manifestMeasurement,
                isDeclaredArtifact: false
            )
        )

        // Container directories, so the described tree is the tree a release writes. The
        // runtime accepts an implied container of a declared artifact and requires it to be a
        // directory, so these are named rather than left to a materializer's judgement.
        for path in Self.containerPaths(of: declared) {
            entries.append(
                PlannedBundleEntry(
                    path: path,
                    content: .directory,
                    measurement: nil,
                    isDeclaredArtifact: false
                )
            )
        }
        return CanonicalBundleTreePlan(entries: entries)
    }

    /// Every strict ancestor directory of every declared artifact, deduplicated.
    private static func containerPaths(
        of declared: [ArtifactDigestRecord]
    ) -> [CanonicalRelativePath] {
        var seen = Set<String>()
        var paths: [CanonicalRelativePath] = []
        for artifact in declared {
            var components = artifact.path.rawValue.split(separator: "/").map(String.init)
            components.removeLast()
            while !components.isEmpty {
                let joined = components.joined(separator: "/")
                if seen.insert(joined).inserted, let path = CanonicalRelativePath(joined) {
                    paths.append(path)
                }
                components.removeLast()
            }
        }
        return paths
    }

    // MARK: - The signing request

    /// Builds the request an approved signing step is handed.
    private func signingRequest(
        _ request: InitialModelBundleBuildRequest,
        designated: DesignatedReleaseSigningKey,
        manifestBytes: [UInt8],
        manifestDigest: SHA256Digest
    ) -> BundleSigningRequest {
        BundleSigningRequest(
            bundleID: request.bundleID,
            message: manifestBytes,
            messageDigest: manifestDigest,
            signaturePath: ReservedBundleFileNames.signature,
            designatedKey: designated.key,
            // Read from the bound policy, which is the same field the runtime verifier reads
            // when it checks the resulting signature.
            algorithm: request.configuration.bundleVerificationPolicy.algorithm,
            keyGovernanceSource: designated.governance.source,
            verificationPolicy: request.configuration.bundleVerificationPolicy.id
        )
    }

    /// The key the approved record designates, refusing a designation under a rejection.
    ///
    /// Reading `isApproved` is not declaring approval: the decision was made in the record,
    /// and a rejection stops the build. There is no branch that continues without a
    /// designation and none that picks a different key.
    private func designatedKey(
        _ request: InitialModelBundleBuildRequest
    ) throws(BundleBuildError) -> DesignatedReleaseSigningKey {
        let designated: DesignatedReleaseSigningKey
        do {
            designated = try keyGovernance.designatedSigningKey(forBundle: request.bundleID)
        } catch {
            throw error == .noDesignatedKey
                ? BundleBuildError.noDesignatedSigningKey(request.bundleID)
                : BundleBuildError.keyGovernanceRecordUnavailable(request.bundleID)
        }
        guard designated.governance.isApproved else {
            throw BundleBuildError.designatedSigningKeyNotApproved(designated.key)
        }
        return designated
    }

    // MARK: - Seam calls

    private func measuredStagedFile(
        at path: CanonicalRelativePath,
        role: BundleBuildArtifactRole
    ) throws(BundleBuildError) -> BundleArtifactMeasurement {
        do {
            return try measurements.measureStagedFile(at: path)
        } catch {
            throw BundleBuildError.stagedArtifactNotMeasurable(
                role: role,
                path: path,
                fault: error
            )
        }
    }

    private func measuredStagedTree(
        at path: CanonicalRelativePath,
        role: BundleBuildArtifactRole,
        construction: BundleTreeDigestConstruction
    ) throws(BundleBuildError) -> BundleArtifactMeasurement {
        do {
            return try measurements.measureStagedDirectoryTree(
                at: path,
                construction: construction
            )
        } catch {
            throw BundleBuildError.stagedArtifactNotMeasurable(
                role: role,
                path: path,
                fault: error
            )
        }
    }

    private func canonicalBytes(
        of value: some Encodable,
        role: BundleBuildArtifactRole
    ) throws(BundleBuildError) -> [UInt8] {
        do {
            return try CanonicalArtifactEncoding.canonicalBytes(of: value)
        } catch {
            throw BundleBuildError.artifactNotEncodable(role: role, fault: error)
        }
    }
}

// MARK: - Reserved names

/// The bundle root files a build writes but never declares as artifacts.
///
/// Read from ``ModelBundleManifest`` rather than spelled out, so the two cannot drift. The
/// manifest schema already refuses a self-declared manifest or signature; naming them here
/// lets a build finding cite the approved path that would have collided, and gives the tree
/// plan and the signing request the canonical paths without an optional to unwrap.
enum ReservedBundleFileNames {
    static let manifest = canonical(ModelBundleManifest.manifestFileName)
    static let signature = canonical(ModelBundleManifest.signatureFileName)

    static let all: Set<String> = [manifest.rawValue, signature.rawValue]

    private static func canonical(_ name: String) -> CanonicalRelativePath {
        guard let path = CanonicalRelativePath(name) else {
            preconditionFailure("A reserved Model Bundle file name must be a canonical path.")
        }
        return path
    }
}
