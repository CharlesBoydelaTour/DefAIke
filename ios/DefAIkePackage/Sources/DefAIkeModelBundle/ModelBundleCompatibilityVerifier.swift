import DefAIkeDomain

// Steps 4 and 5 of the fixed verification order (design, Model Bundle Manager):
//
//   4. Verify checkpoint identity, required weight-blob digest, FP16 `mlprogram`
//      metadata, iOS minimum, input and output schema, preprocessing, calibration, copy,
//      and scope compatibility, and capability requirements.
//   5. Verify that the self-test specification, fixture identities, and expected results
//      exist and resolve.
//
// Both run over a ``VerifiedBundleArtifactTree``, so the manifest they read is the one the
// release signature covers and every declared artifact already matched its digest. That
// ordering is what makes these steps meaningful: comparing an unverified manifest against
// an approved configuration would be comparing the configuration to whatever a candidate
// chose to write.
//
// Every expected value arrives from an approved artifact. The component identifiers come
// from the validated ``ReleaseConfiguration`` the build binds, the running build and
// device come from ``ReleaseContext``, the role-to-path binding comes from
// ``ApprovedBundleLayout``, the byte ceiling for the bundle's canonical-JSON metadata
// comes from the Bundle Verification Policy, and the fixed model facts come from the
// requirements as validated domain constants. Nothing here is a compiled-in release
// value, and nothing continues when an expected value is absent.
//
// What this file does not do: load a model, run a fixture, write a receipt, or touch the
// active pointer. Steps 6 and 7 are ``ReleaseSelfTestRunner`` and task 6.3.

/// Resolves an integrity-verified candidate into one this build may run.
///
/// Holds no mutable state, and reaches the candidate's bytes only through the injected
/// content seam, so two runs over the same tree produce the same finding or the same
/// value.
///
/// Synchronous, for the same reason step 3 is: this is a decision over bytes and approved
/// values with no suspension point of its own. `ModelBundleManaging` is the asynchronous
/// boundary.
public struct ModelBundleCompatibilityVerifier: Sendable {
    private let content: any ModelBundleContentReading
    private let configuration: ReleaseConfiguration
    private let evidenceScope: EvidenceScope
    private let layout: ApprovedBundleLayout

    /// Creates a verifier bound to one approved configuration, scope, and layout.
    ///
    /// All four arguments are required with no default. A build that has not been given
    /// its validated policy set, the evidence scope it states, and the approved
    /// role-to-path binding cannot construct a verifier at all, which is what makes
    /// "no source-code default for any approved value" a compile-time fact.
    ///
    /// `evidenceScope` is separate because the scope a report states is a release artifact
    /// in its own right and the policy set does not carry it; the bundle's scope component
    /// version is checked against this one (Requirement 10.7).
    public init(
        content: any ModelBundleContentReading,
        configuration: ReleaseConfiguration,
        evidenceScope: EvidenceScope,
        layout: ApprovedBundleLayout
    ) {
        self.content = content
        self.configuration = configuration
        self.evidenceScope = evidenceScope
        self.layout = layout
    }

    /// Resolves `tree` for the running build, or reports why it may not be run.
    public func resolve(
        _ tree: VerifiedBundleArtifactTree,
        for context: ReleaseContext
    ) throws(ModelBundleVerificationError) -> CompatibleBundleCandidate {
        try requireApprovedLayout()
        try requireSameVerificationPolicy(tree)
        try requireApprovedCandidate(tree.bundleID, context: context)

        let manifest = tree.manifest
        try requireRequiredPixelModel(manifest)
        try requireRequiredModelFormat(manifest.modelFormat)
        try requireFixedInputContract(manifest.inputContract)
        try requireFixedOutputContract(manifest.outputContract)
        try requireCompatibleComponents(manifest.componentVersions)
        try requireCompatibleBuild(manifest.compatibility, context: context)

        // Enumerated once. Every later presence question is answered from this snapshot,
        // so a candidate cannot present one tree to the weight-blob check and another to
        // the fixture checks.
        let files = try regularFilePaths(in: tree.bundleID)
        let roles = try resolvedRoleArtifacts(tree)
        let plan = try verifiedSelfTestPlan(tree, roles: roles, files: files)

        // Last, because it is the only check here that streams a weight blob. Every
        // declarative refusal above costs nothing, so an incompatible candidate is
        // rejected without reading tens of megabytes twice, and the measurement runs only
        // for a candidate that is compatible in every other respect.
        let weightDigest = try measuredWeightDigest(
            tree,
            compiledModel: roles.compiledModel,
            files: files
        )

        return CompatibleBundleCandidate(
            tree: tree,
            layout: layout,
            capabilityManifestID: configuration.capabilityManifest.id,
            appBuild: context.device.appBuild,
            measuredWeightDigest: weightDigest,
            selfTests: plan
        )
    }

    // MARK: - Approved inputs

    /// Requires the build's role-to-path binding to carry an approval.
    private func requireApprovedLayout() throws(ModelBundleVerificationError) {
        guard layout.approval.isApproved else {
            throw ModelBundleVerificationError.bundleLayoutNotApproved(layout.source.artifact)
        }
    }

    /// Requires the tree to have been verified under the policy this build binds.
    ///
    /// Without this, a caller could verify a candidate under one policy's keys and then
    /// check its compatibility against a configuration that binds another, so the
    /// signature would no longer pin the behavior the configuration describes.
    private func requireSameVerificationPolicy(
        _ tree: VerifiedBundleArtifactTree
    ) throws(ModelBundleVerificationError) {
        let bound = configuration.bundleVerificationPolicy.id
        guard tree.verificationPolicyID == bound else {
            throw ModelBundleVerificationError.verifiedUnderDifferentPolicy(
                verified: tree.verificationPolicyID,
                bound: bound
            )
        }
    }

    /// Requires the signed capability manifest to list this bundle.
    ///
    /// A bundle installed on the device is not a bundle this build may activate: the
    /// manifest's catalogue is the approved list, and the running context has to be the
    /// build that manifest describes.
    private func requireApprovedCandidate(
        _ bundle: ModelBundleID,
        context: ReleaseContext
    ) throws(ModelBundleVerificationError) {
        let manifest = configuration.capabilityManifest
        guard context.capabilityManifestID == manifest.id else {
            throw ModelBundleVerificationError.capabilityManifestMismatch(
                context: context.capabilityManifestID,
                bound: manifest.id
            )
        }
        guard manifest.approvedBundleCatalog.contains(bundle) else {
            throw ModelBundleVerificationError.candidateNotInApprovedBundleCatalog(bundle)
        }
    }

    // MARK: - Model identity and format

    /// Requires the sole permitted pixel model (Requirements 1.16 and 10.2).
    ///
    /// The manifest schema already refuses any other identity, so this is the second of
    /// two independent refusals rather than the only one. It is spelled out anyway: this
    /// is the step a release audit reads for "the model identity was verified", and a
    /// check that exists only as a side effect of a decoder is not one an auditor can
    /// find.
    private func requireRequiredPixelModel(
        _ manifest: ModelBundleManifest
    ) throws(ModelBundleVerificationError) {
        guard manifest.modelIdentity == RequiredPixelModel.identity else {
            throw ModelBundleVerificationError.modelIdentityNotTheRequiredPixelModel(
                manifest.modelIdentity.checkpointIdentifier
            )
        }
    }

    /// Requires an FP16 `mlprogram` with the required minimum deployment target
    /// (Requirements 4.2 and 10.3).
    private func requireRequiredModelFormat(
        _ format: ModelFormatDescriptor
    ) throws(ModelBundleVerificationError) {
        guard format.programKind == .mlProgram, format.computePrecision == .float16 else {
            throw ModelBundleVerificationError.modelFormatNotFP16MLProgram(
                programKind: format.programKind,
                precision: format.computePrecision
            )
        }
        guard format.minimumOS == .iOS17 else {
            throw ModelBundleVerificationError.modelDeploymentTargetMismatch(
                required: .iOS17,
                declared: format.minimumOS
            )
        }
    }

    /// Requires one 384-by-384 unsigned 8-bit RGB input that is exactly the buffer the
    /// bound Preprocessing Contract produces (Requirements 4.5 through 4.8).
    ///
    /// The last two checks are the ones the manifest schema cannot make: a structurally
    /// valid contract can still describe a different feature name or shape than the
    /// contract this build preprocesses with, and a mismatch there means the app feeds the
    /// model a buffer under a name it does not accept.
    private func requireFixedInputContract(
        _ input: ModelInputContract
    ) throws(ModelBundleVerificationError) {
        guard input.elementType == .uint8 else {
            throw ModelBundleVerificationError.modelInputContractRejected(.elementTypeNotUInt8)
        }
        guard input.channelOrder == .rgb else {
            throw ModelBundleVerificationError.modelInputContractRejected(.channelOrderNotRGB)
        }
        let edge = CenterCropContract.requiredEdge
        guard input.width == edge, input.height == edge else {
            throw ModelBundleVerificationError.modelInputContractRejected(
                .edgeNotRequiredCropSize
            )
        }
        guard !input.appliesAppSideNormalization else {
            throw ModelBundleVerificationError.modelInputContractRejected(
                .claimsAppSideNormalization
            )
        }
        let bound = configuration.preprocessingContract.modelInput
        guard input.featureName == bound.featureName else {
            throw ModelBundleVerificationError.modelInputContractRejected(
                .featureNameDisagreesWithBoundContract
            )
        }
        guard input == bound else {
            throw ModelBundleVerificationError.modelInputContractRejected(
                .shapeDisagreesWithBoundContract
            )
        }
    }

    /// Requires one positive-going floating-point scalar named `logit` (Requirement 4.9).
    private func requireFixedOutputContract(
        _ output: ModelOutputContract
    ) throws(ModelBundleVerificationError) {
        guard output.featureName.value == ModelOutputContract.requiredFeatureName else {
            throw ModelBundleVerificationError.modelOutputContractRejected(.featureNameNotLogit)
        }
        guard output.elementType != .uint8 else {
            throw ModelBundleVerificationError.modelOutputContractRejected(
                .elementTypeNotFloatingPoint
            )
        }
        guard output.isPositiveGoing else {
            throw ModelBundleVerificationError.modelOutputContractRejected(.notPositiveGoing)
        }
    }

    // MARK: - Component and build compatibility

    /// Requires the bundle's component versions to be the ones this build binds
    /// (Requirements 10.7 and 10.8).
    ///
    /// Four of the six have an approved counterpart here: the Preprocessing Contract and
    /// Calibration Policy the configuration resolved, the Approved Verdict Copy
    /// compatibility identifier the copy catalogue declares, and the evidence scope this
    /// build states. The remaining two are checked elsewhere in the order — the self-test
    /// specification against the artifact the bundle actually carries, in step 5, and the
    /// Core ML component version against the model the bundle actually carries, by the
    /// weight-digest measurement — because neither has a build-side identifier to compare
    /// against, and inventing one would be this module deciding a release value.
    private func requireCompatibleComponents(
        _ versions: BundleComponentVersions
    ) throws(ModelBundleVerificationError) {
        try requireComponent(
            .preprocessingContract,
            found: versions.preprocessingContract,
            expected: configuration.preprocessingContract.id
        )
        try requireComponent(
            .calibrationPolicy,
            found: versions.calibrationPolicy,
            expected: configuration.calibrationPolicy.id
        )
        try requireComponent(
            .verdictCopyCompatibility,
            found: versions.verdictCopyCompatibility,
            expected: configuration.verdictCopyCatalog.compatibilityID
        )
        try requireComponent(
            .evidenceScope,
            found: versions.evidenceScope,
            expected: evidenceScope.id
        )
    }

    private func requireComponent(
        _ component: BundleComponent,
        found: ArtifactID,
        expected: ArtifactID
    ) throws(ModelBundleVerificationError) {
        guard found == expected else {
            throw ModelBundleVerificationError.componentVersionIncompatible(
                component: component,
                expected: expected,
                found: found
            )
        }
    }

    /// Requires exact build membership, a compiled superset of the required capabilities,
    /// and an operating system at or above the bundle's minimum (Requirement 10.11).
    ///
    /// All three, every time. Each is reported separately, because "incompatible" without
    /// a reason is not something a release audit or a support path can act on.
    private func requireCompatibleBuild(
        _ compatibility: CompatibilityMatrix,
        context: ReleaseContext
    ) throws(ModelBundleVerificationError) {
        guard compatibility.compatibleAppBuilds.contains(context.device.appBuild) else {
            throw ModelBundleVerificationError.appBuildNotCompatible(context.device.appBuild)
        }
        let missing = compatibility.requiredCapabilities
            .subtracting(context.compiledCapabilities)
        guard missing.isEmpty else {
            throw ModelBundleVerificationError.requiredCapabilitiesNotCompiled(
                missing.sorted { $0.rawValue < $1.rawValue }
            )
        }
        guard context.device.osVersion >= compatibility.minimumOS else {
            throw ModelBundleVerificationError.operatingSystemBelowBundleMinimum(
                required: compatibility.minimumOS,
                running: context.device.osVersion
            )
        }
    }

    // MARK: - Role resolution

    /// The declared record for each separately declared role.
    struct RoleArtifacts {
        let compiledModel: ArtifactDigestRecord
        let selfTestSpecification: ArtifactDigestRecord
        let fixtureCatalog: ArtifactDigestRecord
        let fixtureRoot: ArtifactDigestRecord
    }

    /// Requires every separately declared role to resolve to a declared artifact of the
    /// right kind.
    private func resolvedRoleArtifacts(
        _ tree: VerifiedBundleArtifactTree
    ) throws(ModelBundleVerificationError) -> RoleArtifacts {
        var records: [BundleArtifactRole: ArtifactDigestRecord] = [:]
        for role in ApprovedBundleLayout.separatelyDeclaredRoles {
            let path = layout.path(for: role)
            guard let record = tree.verifiedArtifact(at: path) else {
                throw ModelBundleVerificationError.roleArtifactNotDeclared(role: role, path: path)
            }
            guard record.kind == role.requiredKind else {
                throw ModelBundleVerificationError.roleArtifactKindMismatch(
                    role: role,
                    path: path
                )
            }
            records[role] = record
        }
        // Total by construction: the loop covers every separately declared role and
        // throws rather than skipping one.
        guard let compiledModel = records[.compiledModel],
              let specification = records[.selfTestSpecification],
              let catalog = records[.fixtureCatalog],
              let fixtureRoot = records[.fixtureRoot]
        else {
            preconditionFailure("Every separately declared bundle role must resolve.")
        }
        return RoleArtifacts(
            compiledModel: compiledModel,
            selfTestSpecification: specification,
            fixtureCatalog: catalog,
            fixtureRoot: fixtureRoot
        )
    }

    /// Measures the weight blob and requires it to be the weights the identity pins
    /// (Requirement 10.4).
    ///
    /// The digest is measured from the bytes rather than read from the manifest, which is
    /// the whole point of the check: the manifest already *declares* the required digest —
    /// its schema admits no other identity — and a declaration compared against itself
    /// proves nothing. Reading is bounded by the compiled model tree's declared byte count,
    /// and those bytes are signature-covered and already matched their tree digest in
    /// step 3, so measuring here cannot be made to read more than the release signed for.
    ///
    /// One consequence is worth stating plainly: no synthetically assembled bundle can pass
    /// this check, because passing it requires the actual approved weight blob. That is the
    /// intended strength of the check, and it is why the positive path belongs to the
    /// integration tests that run against the real immutable artifact rather than to a
    /// unit test that could only fake it.
    private func measuredWeightDigest(
        _ tree: VerifiedBundleArtifactTree,
        compiledModel: ArtifactDigestRecord,
        files: Set<String>
    ) throws(ModelBundleVerificationError) -> SHA256Digest {
        let path = layout.modelWeightBlob
        guard files.contains(path.rawValue) else {
            throw ModelBundleVerificationError.modelWeightBlobNotFound(path)
        }
        let measured = try streamDigest(
            at: path,
            in: tree.bundleID,
            bound: compiledModel.byteCount
        )
        guard measured.digest == tree.manifest.modelIdentity.requiredWeightDigest else {
            throw ModelBundleVerificationError.modelWeightDigestMismatch(path)
        }
        return measured.digest
    }

    // MARK: - Release self-test artifacts

    /// Decodes the candidate's self-test specification and fixture catalogue and resolves
    /// every case against the verified tree (Requirements 10.9 and 10.10).
    private func verifiedSelfTestPlan(
        _ tree: VerifiedBundleArtifactTree,
        roles: RoleArtifacts,
        files: Set<String>
    ) throws(ModelBundleVerificationError) -> VerifiedSelfTestPlan {
        let specification: ReleaseSelfTestSpecification = try decodedArtifact(
            role: .selfTestSpecification,
            record: roles.selfTestSpecification,
            in: tree.bundleID
        )
        let declared = tree.manifest.componentVersions.selfTestSpecification
        guard specification.id == declared else {
            throw ModelBundleVerificationError.selfTestSpecificationIdentifierMismatch(
                declared: specification.id,
                componentVersion: declared
            )
        }

        let catalog: ReleaseFixtureSuite = try decodedArtifact(
            role: .fixtureCatalog,
            record: roles.fixtureCatalog,
            in: tree.bundleID
        )
        guard specification.fixtureSuite == catalog.id else {
            throw ModelBundleVerificationError.selfTestFixtureCatalogMismatch(
                specification: specification.fixtureSuite,
                catalog: catalog.id
            )
        }

        var cases: [VerifiedSelfTestCase] = []
        cases.reserveCapacity(specification.cases.count)
        for testCase in specification.cases {
            cases.append(
                try resolvedCase(testCase, catalog: catalog, in: tree.bundleID, files: files)
            )
        }
        return VerifiedSelfTestPlan(
            specification: specification,
            fixtureCatalog: catalog,
            cases: cases
        )
    }

    /// Resolves one case's expectations and its fixture's bytes.
    private func resolvedCase(
        _ testCase: SelfTestCase,
        catalog: ReleaseFixtureSuite,
        in bundle: ModelBundleID,
        files: Set<String>
    ) throws(ModelBundleVerificationError) -> VerifiedSelfTestCase {
        try requireCoherentExpectations(testCase)

        guard let entry = catalog.fixtures.first(where: { $0.id == testCase.fixture }) else {
            throw ModelBundleVerificationError.selfTestFixtureNotCatalogued(
                case: testCase.id,
                fixture: testCase.fixture
            )
        }
        guard let assetPath = layout.fixtureAssetPath(suiteRelative: entry.assetPath) else {
            throw ModelBundleVerificationError.selfTestFixtureAssetPathNotResolvable(entry.id)
        }
        guard files.contains(assetPath.rawValue) else {
            throw ModelBundleVerificationError.selfTestFixtureAssetMissing(
                fixture: entry.id,
                path: assetPath
            )
        }

        let declaredByteCount = entry.byteCount.value
        let measured: (digest: SHA256Digest, byteCount: UInt64)
        do {
            measured = try streamDigest(at: assetPath, in: bundle, bound: declaredByteCount)
        } catch .artifactReadExceededDeclaredBound {
            // Reported against the fixture rather than the path: a release audit cites the
            // fixture identity the expected results were approved against.
            throw ModelBundleVerificationError.selfTestFixtureLargerThanCatalogued(
                fixture: entry.id,
                declared: declaredByteCount
            )
        }
        guard measured.byteCount == declaredByteCount else {
            throw ModelBundleVerificationError.selfTestFixtureByteCountMismatch(
                fixture: entry.id,
                declared: declaredByteCount,
                found: measured.byteCount
            )
        }
        guard measured.digest == entry.contentDigest else {
            throw ModelBundleVerificationError.selfTestFixtureDigestMismatch(entry.id)
        }

        return VerifiedSelfTestCase(
            id: testCase.id,
            fixture: entry.id,
            assetPath: assetPath,
            byteCount: declaredByteCount,
            contentDigest: entry.contentDigest,
            expectations: testCase.expectations
        )
    }

    /// Requires one case's expectations to describe a single satisfiable outcome.
    ///
    /// The schema already requires at least one expectation. Two further ways a case can
    /// be unrunnable as written are refused here: declaring the same kind twice, so "the
    /// expected result" is ambiguous, and expecting both an Analysis Error and a
    /// successful result, which no run can satisfy. Both would otherwise reach the runner
    /// and fail there as a comparison mismatch, which would report the wrong cause.
    private func requireCoherentExpectations(
        _ testCase: SelfTestCase
    ) throws(ModelBundleVerificationError) {
        var seen = Set<SelfTestExpectationKind>()
        for expectation in testCase.expectations {
            guard seen.insert(expectation.kind).inserted else {
                throw ModelBundleVerificationError.selfTestCaseRepeatsExpectation(
                    case: testCase.id,
                    kind: expectation.kind
                )
            }
        }
        let expectsError = seen.contains(.analysisError)
        let expectsResult = seen.contains { $0.describesSuccessfulResult }
        guard !(expectsError && expectsResult) else {
            throw ModelBundleVerificationError.selfTestCaseContradictsItself(testCase.id)
        }
    }

    // MARK: - Bounded reads

    /// Reads and decodes one declared canonical-JSON artifact.
    ///
    /// The byte ceiling is the approved Bundle Verification Policy's manifest ceiling: it
    /// is the one approved bound on a bundle's canonical-JSON metadata, and the only
    /// alternative would be a size constant in this file. Decoding goes through
    /// ``BoundedArtifactDecoder``, so the duplicate-key, nesting, and schema refusals a
    /// signed artifact needs are the same ones every other release artifact gets.
    private func decodedArtifact<Value: Decodable>(
        role: BundleArtifactRole,
        record: ArtifactDigestRecord,
        in bundle: ModelBundleID
    ) throws(ModelBundleVerificationError) -> Value {
        let ceiling = configuration.bundleVerificationPolicy.maximumManifestByteCount.value
        guard record.byteCount <= ceiling else {
            throw ModelBundleVerificationError.declaredArtifactNotDecodable(
                role: role,
                error: .payloadTooLarge(limitBytes: ceiling, actualBytes: record.byteCount)
            )
        }
        let bytes = try readFully(at: record.path, in: bundle, bound: record.byteCount)
        do {
            return try configuration.manifestDecoder.decode(Value.self, from: bytes)
        } catch {
            throw ModelBundleVerificationError.declaredArtifactNotDecodable(
                role: role,
                error: error
            )
        }
    }

    /// Every path in the tree that holds a regular file.
    ///
    /// Enumerated rather than inferred from a successful read, so a directory or a
    /// nonexistent path is a named finding instead of a read fault. Step 3 already refused
    /// every symbolic link and every entry that is neither a file nor a directory, so a
    /// path absent from this set is genuinely not a readable artifact.
    private func regularFilePaths(
        in bundle: ModelBundleID
    ) throws(ModelBundleVerificationError) -> Set<String> {
        let entries: [BundleTreeEntry]
        do {
            entries = try content.entries(in: bundle)
        } catch {
            throw ModelBundleVerificationError.bundleTreeUnreadable(bundle)
        }
        return Set(
            entries.compactMap { entry in
                guard case .file = entry.kind else { return nil }
                return entry.rawPath
            }
        )
    }

    /// Reads at most `bound` bytes from one declared path.
    private func readFully(
        at path: CanonicalRelativePath,
        in bundle: ModelBundleID,
        bound: UInt64
    ) throws(ModelBundleVerificationError) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(Int(min(bound, UInt64(Int.max))))
        var exceeded = false
        do {
            try content.readFile(
                at: path,
                in: bundle,
                chunkByteCount: ModelBundleIntegrityVerifier.readChunkByteCount
            ) { chunk in
                guard UInt64(bytes.count) + UInt64(chunk.count) <= bound else {
                    exceeded = true
                    return .stop
                }
                bytes.append(contentsOf: chunk)
                return .proceed
            }
        } catch {
            throw ModelBundleVerificationError.artifactUnreadable(path)
        }
        guard !exceeded else {
            throw ModelBundleVerificationError.artifactReadExceededDeclaredBound(
                path: path,
                bound: bound
            )
        }
        return bytes
    }

    /// Hashes one file while it streams, stopping the moment it runs past `bound`.
    private func streamDigest(
        at path: CanonicalRelativePath,
        in bundle: ModelBundleID,
        bound: UInt64
    ) throws(ModelBundleVerificationError) -> (digest: SHA256Digest, byteCount: UInt64) {
        var hasher = StreamingSHA256()
        var observed: UInt64 = 0
        var exceeded = false
        do {
            try content.readFile(
                at: path,
                in: bundle,
                chunkByteCount: ModelBundleIntegrityVerifier.readChunkByteCount
            ) { chunk in
                let (sum, overflow) = observed.addingReportingOverflow(UInt64(chunk.count))
                guard !overflow, sum <= bound else {
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
                bound: bound
            )
        }
        return (hasher.finalize(), observed)
    }
}
