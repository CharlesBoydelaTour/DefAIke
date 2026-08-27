import DefAIkeDomain
import Testing

@testable import DefAIkeModelBundle
@testable import DefAIkeReleaseValidation

/// What building the Initial Model Bundle produces, and what it refuses to produce.
///
/// Three claims are worth stating because the tests below are what back them:
///
///   * **Reproducible.** Two builds from the same approved inputs produce byte-identical
///     manifest bytes, generated artifact bytes, digest inventory, tree plan, and signing
///     request. Asserted by building twice and comparing bytes rather than by reading the
///     code — and additionally by pinning the encoded order of the manifest's two `Set`-valued
///     fields, which is the one place `JSONEncoder` alone is not reproducible across
///     processes.
///   * **Derived, not invented.** Every manifest field that compatibility verification
///     compares against an approved record is read from that very record. Asserted field by
///     field against the bound ``ReleaseConfiguration``, so a future change that spells a
///     value here instead of reading it fails.
///   * **No key, no approval.** The signing key is the identity the injected governance record
///     designates, the algorithm is the bound policy's, and the output is a request. Asserted
///     positively, and asserted again by the refusals: a rejected designation, an absent
///     designation, and an unavailable record each stop the build.
@Suite("Initial Model Bundle creation")
struct InitialModelBundleBuilderTests {
    // MARK: - Reproducibility

    @Test("Two builds from the same approved inputs are byte-identical")
    func buildIsReproducible() throws {
        // The strong form of the claim: not "the values are equal" but "every byte sequence
        // the build emits is the same sequence". A tree plan, a manifest, a digest inventory,
        // and a signing request all compare by value here, and every one of them carries the
        // bytes rather than a summary of them.
        let request = try SampleBuildRequest.standard()
        let first = try SampleRelease.build(request: request)
        let second = try SampleRelease.build(request: request)

        #expect(first.manifestBytes == second.manifestBytes)
        #expect(first.digestInventory == second.digestInventory)
        #expect(first.tree == second.tree)
        #expect(first.signingRequest == second.signingRequest)
        #expect(first == second)

        // And every generated artifact's bytes, individually, so an equal tree cannot hide a
        // differing payload.
        for entry in first.tree.entries {
            guard case let .generatedFile(bytes) = entry.content else { continue }
            guard case let .generatedFile(other) = second.tree.entry(at: entry.path)?.content
            else {
                Issue.record("\(entry.path) is not a generated file in the second build")
                continue
            }
            #expect(bytes == other, "\(entry.path) differs between two builds")
        }
    }

    @Test("The manifest's set-valued fields are encoded in a fixed order")
    func setValuedManifestFieldsAreOrdered() throws {
        // `compatibleAppBuilds` and `requiredCapabilities` are `Set`s, and `Set` iteration
        // order depends on Swift's per-process hash seed. Two builds inside one process agree
        // regardless, so the reproducibility test above cannot see this; the encoded order is
        // what makes two *processes* agree, and it is pinned here.
        let request = try SampleBuildRequest.standard(
            compatibility: try Sample.compatibilityMatrix(
                appBuilds: [
                    AppBuildID("build.zulu")!,
                    Sample.appBuild(),
                    AppBuildID("build.alpha")!,
                ],
                capabilities: [.pixelAnalysis, .shareExtensionHandoff, .evidenceFusion]
            )
        )
        let text = try #require(String(bytes: try SampleRelease.build(request: request).manifestBytes, encoding: .utf8))

        #expect(text.contains(#""compatibleAppBuilds":["build.alpha","build.sample","build.zulu"]"#))
        #expect(
            text.contains(
                #""requiredCapabilities":["evidence-fusion","pixel-analysis","share-extension-handoff"]"#
            )
        )
    }

    @Test("The digest inventory and the tree plan are ordered by canonical path bytes")
    func inventoryIsOrderedByPathBytes() throws {
        let built = try SampleRelease.build()
        let inventoryPaths = built.digestInventory.map(\.path.rawValue)
        #expect(inventoryPaths == inventoryPaths.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) })

        let treePaths = built.tree.entries.map(\.path.rawValue)
        #expect(treePaths == treePaths.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) })
    }

    // MARK: - What the tree holds

    @Test("Every release artifact is declared exactly once, with the kind its role requires")
    func declaredArtifactsCoverEveryRole() throws {
        let request = try SampleBuildRequest.standard()
        let built = try SampleRelease.build(request: request)
        let byPath = Dictionary(
            uniqueKeysWithValues: built.digestInventory.map { ($0.path.rawValue, $0) }
        )

        #expect(byPath.count == 6)
        #expect(byPath[StagedLayout.compiledModel]?.kind == .directoryTree)
        #expect(byPath[StagedLayout.selfTestSpecification]?.kind == .file)
        #expect(byPath[StagedLayout.fixtureCatalog]?.kind == .file)
        #expect(byPath[StagedLayout.fixtureRoot]?.kind == .directoryTree)
        #expect(byPath[StagedLayout.noticeIndex]?.kind == .file)
        #expect(byPath[StagedLayout.noticeRoot]?.kind == .directoryTree)

        // Every declared artifact carries a positive byte count and a measurement, and every
        // one of the five roles the runtime resolves is among them.
        for record in built.digestInventory {
            #expect(record.byteCount > 0, "\(record.path) declares no bytes")
        }
        for role in ApprovedBundleLayout.separatelyDeclaredRoles {
            #expect(byPath[request.layout.path(for: role).rawValue] != nil, "\(role) is not declared")
        }
    }

    @Test("The manifest is generated, is not self-declared, and is not the signature")
    func manifestIsAReservedGeneratedFile() throws {
        let built = try SampleRelease.build()
        let manifestPath = try #require(
            CanonicalRelativePath(ModelBundleManifest.manifestFileName)
        )
        let entry = try #require(built.tree.entry(at: manifestPath))

        #expect(entry.isDeclaredArtifact == false)
        if case let .generatedFile(bytes) = entry.content {
            #expect(bytes == built.manifestBytes)
        } else {
            Issue.record("the manifest must be a generated file")
        }
        #expect(built.digestInventory.allSatisfy { $0.path != manifestPath })

        // The detached signature is absent: this build produced a request, not a signature.
        #expect(built.tree.entry(at: built.signingRequest.signaturePath) == nil)
        #expect(built.signingRequest.signaturePath.rawValue == ModelBundleManifest.signatureFileName)
    }

    @Test("Container directories are described so the tree a release writes is complete")
    func containerDirectoriesAreDescribed() throws {
        let built = try SampleRelease.build()
        let container = try #require(built.tree.entry(at: Sample.path(StagedLayout.artifactsRoot)))
        #expect(container.content == .directory)
        #expect(container.measurement == nil)
        #expect(container.isDeclaredArtifact == false)
    }

    // MARK: - Derived rather than invented

    @Test("Every checkable manifest field is read from the record it is checked against")
    func manifestFieldsAreDerivedFromApprovedRecords() throws {
        let request = try SampleBuildRequest.standard()
        let manifest = try SampleRelease.build(request: request).manifest
        let configuration = request.configuration

        #expect(manifest.modelIdentity == RequiredPixelModel.identity)
        #expect(manifest.modelFormat.programKind == .mlProgram)
        #expect(manifest.modelFormat.computePrecision == .float16)
        #expect(manifest.modelFormat.minimumOS == .iOS17)
        #expect(manifest.inputContract == configuration.preprocessingContract.modelInput)
        #expect(manifest.outputContract == request.outputContract)
        #expect(manifest.compatibility == request.compatibility)
        #expect(manifest.schemaVersion == request.manifestSchemaVersion)
        #expect(
            manifest.upstreamBoundaryMetadata.rawLogitValue
                == UpstreamBoundaryMetadata.requiredValue
        )
        #expect(manifest.upstreamBoundaryMetadata.role == .modelMetadataOnly)

        let versions = manifest.componentVersions
        #expect(versions.preprocessingContract == configuration.preprocessingContract.id)
        #expect(versions.calibrationPolicy == configuration.calibrationPolicy.id)
        #expect(versions.verdictCopyCompatibility == configuration.verdictCopyCatalog.compatibilityID)
        #expect(versions.evidenceScope == request.evidenceScope.id)
        #expect(versions.selfTestSpecification == request.selfTestSpecification.id)
        #expect(versions.coreMLModel == request.coreMLModelVersion)
    }

    @Test("The self-test specification and fixture catalogue are the approved records")
    func selfTestArtifactsAreTheApprovedRecords() throws {
        // Requirement 10.9 makes the bundle responsible for identifying its specification,
        // fixtures, and expected results. They are encoded from the approved records rather
        // than assembled here, so a decoded round trip is the check that nothing was altered
        // on the way in.
        let request = try SampleBuildRequest.standard()
        let built = try SampleRelease.build(request: request)
        let decoder = request.configuration.manifestDecoder

        let specificationBytes = try Self.generatedBytes(
            built,
            at: request.layout.selfTestSpecification
        )
        let specification = try decoder.decode(
            ReleaseSelfTestSpecification.self,
            from: specificationBytes
        )
        #expect(specification == request.selfTestSpecification)

        let catalogBytes = try Self.generatedBytes(built, at: request.layout.fixtureCatalog)
        let catalog = try decoder.decode(ReleaseFixtureSuite.self, from: catalogBytes)
        #expect(catalog == request.fixtureCatalog)
    }

    // MARK: - Notices (Requirement 14.5)

    @Test("The notice index carries the checkpoint notice and every dependency notice")
    func noticeIndexCoversEveryApprovedNotice() throws {
        let request = try SampleBuildRequest.standard()
        let built = try SampleRelease.build(request: request)
        let index = built.noticeIndex

        #expect(index.id == request.notices.id)
        #expect(index.noticeRoot == request.noticeRoot)
        #expect(index.notices.count == 2)
        #expect(
            index.notices.contains {
                $0.subject == .lowqCheckpoint(Sample.requiredCheckpoint)
            }
        )
        #expect(
            index.notices.contains {
                $0.subject == .dependency(Sample.artifact("dependency.swift-property-based"))
            }
        )

        // Each entry records the measurement of the notice actually staged, so an omitted or
        // substituted notice is visible without reading the prose.
        let staged = StagedContent.sample()
        for entry in index.notices {
            let bytes = try #require(staged.files[entry.path.rawValue])
            #expect(entry.byteCount == UInt64(bytes.count))
            #expect(entry.contentDigest == StreamingSHA256.digest(of: bytes))
        }
        // Ordered by path bytes, so the index bytes do not depend on measurement order.
        let paths = index.notices.map(\.path.rawValue)
        #expect(paths == paths.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) })
    }

    @Test("The notice index names the approving record and never restates the decision")
    func noticeIndexCarriesTheRecordNotTheDecision() throws {
        let request = try SampleBuildRequest.standard()
        let index = try SampleRelease.build(request: request).noticeIndex
        #expect(index.approvalSource == request.notices.approval.source)
    }

    @Test("A notice set that is not approved cannot be constructed")
    func rejectedNoticeSetIsRefused() throws {
        #expect(throws: BundleBuildError.noticeSetNotApproved(Sample.artifact("notices.bundle"))) {
            _ = try Sample.noticeSet(decision: .rejected)
        }
    }

    @Test("A notice for another checkpoint cannot be constructed")
    func checkpointNoticeForAnotherCheckpointIsRefused() throws {
        let other = Sample.checkpoint("vendor/some-other-detector")
        #expect(throws: BundleBuildError.checkpointNoticeSubjectMismatch(other)) {
            _ = try Sample.noticeSet(checkpoint: other)
        }
    }

    @Test("Two notices for the same dependency cannot be constructed")
    func duplicateDependencyNoticeIsRefused() throws {
        let subject = Sample.artifact("dependency.repeated")
        let entries = (0..<2).map { index in
            ApprovedDependencyNotice(
                subject: subject,
                notice: BundleNoticeReference(
                    source: Sample.evidence("evidence.notice.\(index)"),
                    rootRelativePath: Sample.path("dependency-\(index).txt")
                )
            )
        }
        #expect(throws: BundleBuildError.duplicateNoticeSubject(subject)) {
            _ = try Sample.noticeSet(dependencies: entries)
        }
    }

    @Test("An absent notice text stops the build rather than being written")
    func absentNoticeTextIsRefused() throws {
        // The only outcome available to a missing notice is a finding: nothing in this module
        // can create the text, and the seam it reads through cannot write.
        let expected = BundleBuildError.stagedArtifactNotMeasurable(
            role: .noticeText,
            path: Sample.path("\(StagedLayout.noticeRoot)/\(StagedLayout.checkpointNoticePath)"),
            fault: .artifactMissing
        )
        #expect(throws: expected) {
            _ = try SampleRelease.build(staged: .sample(omitCheckpointNotice: true))
        }
    }

    // MARK: - Approved paths

    @Test("A notice index declared at a reserved bundle root name is refused")
    func reservedNoticeIndexPathIsRefused() throws {
        let request = try SampleBuildRequest.standard(
            noticeIndexPath: ModelBundleManifest.manifestFileName
        )
        #expect(
            throws: BundleBuildError.pathIsReservedBundleFile(
                Sample.path(ModelBundleManifest.manifestFileName)
            )
        ) {
            _ = try SampleRelease.build(request: request)
        }
    }

    @Test("A notice root that collides with a declared role path is refused")
    func collidingNoticeRootIsRefused() throws {
        var staged = StagedContent.sample()
        staged.addFile("\(StagedLayout.compiledModel)/NOTICE.txt", text: "notice")
        let request = try SampleBuildRequest.standard(
            notices: try Sample.noticeSet(
                checkpointPath: "NOTICE.txt",
                dependencies: []
            ),
            noticeIndexPath: "artifacts/notice-index.canonical.json",
            noticeRoot: StagedLayout.compiledModel
        )
        #expect(throws: BundleBuildError.duplicateArtifactPath(Sample.path(StagedLayout.compiledModel))) {
            _ = try SampleRelease.build(request: request, staged: staged)
        }
    }

    @Test("A notice root nested inside another declared artifact is refused")
    func nestedNoticeRootIsRefused() throws {
        var staged = StagedContent.sample()
        staged.addFile("\(StagedLayout.fixtureRoot)/notices/NOTICE.txt", text: "notice")
        let request = try SampleBuildRequest.standard(
            notices: try Sample.noticeSet(checkpointPath: "NOTICE.txt", dependencies: []),
            noticeIndexPath: "artifacts/notice-index.canonical.json",
            noticeRoot: "\(StagedLayout.fixtureRoot)/notices"
        )
        #expect(
            throws: BundleBuildError.overlappingArtifactPaths(
                outer: Sample.path(StagedLayout.fixtureRoot),
                inner: Sample.path("\(StagedLayout.fixtureRoot)/notices")
            )
        ) {
            _ = try SampleRelease.build(request: request, staged: staged)
        }
    }

    // MARK: - Staged content

    @Test("An absent compiled model stops the build")
    func absentCompiledModelIsRefused() throws {
        var staged = StagedContent.sample()
        staged.directories.remove(StagedLayout.compiledModel)
        for path in staged.files.keys where path.hasPrefix(StagedLayout.compiledModel + "/") {
            staged.files[path] = nil
        }
        let expected = BundleBuildError.stagedArtifactNotMeasurable(
            role: .compiledModel,
            path: Sample.path(StagedLayout.compiledModel),
            fault: .notADirectoryTree
        )
        #expect(throws: expected) { _ = try SampleRelease.build(staged: staged) }
    }

    @Test("A measurement seam that cannot run the approved construction stops the build")
    func unsupportedCanonicalizationConstructionIsRefused() throws {
        // The construction is an approved rule this module does not implement. A seam that
        // cannot execute it fails with that finding rather than measuring under some other
        // deterministic rule, which would produce a bundle whose digests answer a different
        // question than the signature covers.
        let seam = StagedMeasuringSeam(
            staged: .sample(),
            unsupportedConstructions: [.sortedKindTaggedRecords]
        )
        let expected = BundleBuildError.stagedArtifactNotMeasurable(
            role: .noticeRoot,
            path: Sample.path(StagedLayout.noticeRoot),
            fault: .constructionUnsupported
        )
        #expect(throws: expected) { _ = try SampleRelease.build(measurements: seam) }
    }

    @Test("An unavailable staging area stops the build")
    func unavailableStagingAreaIsRefused() throws {
        let seam = StagedMeasuringSeam(staged: .sample(), isUnavailable: true)
        #expect(throws: BundleBuildError.self) { _ = try SampleRelease.build(measurements: seam) }
    }

    // MARK: - Signing request

    @Test("The signing request names the designated key and the policy's algorithm")
    func signingRequestCarriesNoChoiceOfItsOwn() throws {
        let request = try SampleBuildRequest.standard()
        let built = try SampleRelease.build(request: request)
        let signing = built.signingRequest
        let policy = request.configuration.bundleVerificationPolicy

        #expect(signing.bundleID == request.bundleID)
        #expect(signing.message == built.manifestBytes)
        #expect(signing.messageDigest == StreamingSHA256.digest(of: built.manifestBytes))
        #expect(signing.messageDigest == built.manifestDigest)
        #expect(signing.signaturePath.rawValue == ModelBundleManifest.signatureFileName)

        // The key is the identity governance designated, and the manifest records the same
        // one, so nothing in the build could name a different key than the request does.
        #expect(signing.designatedKey == Sample.signingKey())
        #expect(built.manifest.signingKey == signing.designatedKey)

        // The algorithm is read from the bound policy, which is the field the runtime verifier
        // reads when it checks the resulting signature.
        #expect(signing.algorithm == policy.algorithm)
        #expect(signing.verificationPolicy == policy.id)

        // The record that designated the key travels as a reference.
        #expect(
            signing.keyGovernanceSource
                == Sample.approval(identifier: "approval.key-governance").source
        )
    }

    @Test("The algorithm follows the policy rather than a value the build holds")
    func algorithmFollowsThePolicy() throws {
        for algorithm in SignatureAlgorithm.allCases {
            let policy = try Sample.verificationPolicy(algorithm: algorithm)
            let built = try SampleRelease.build(
                request: try SampleBuildRequest.standard(policy: policy)
            )
            #expect(built.signingRequest.algorithm == algorithm)
        }
    }

    @Test("A governance record that designates no key stops the build")
    func absentDesignationIsRefused() throws {
        #expect(throws: BundleBuildError.noDesignatedSigningKey(Sample.bundle())) {
            _ = try SampleRelease.build(keyGovernance: FakeKeyGovernance())
        }
    }

    @Test("An unavailable governance record stops the build")
    func unavailableGovernanceRecordIsRefused() throws {
        #expect(throws: BundleBuildError.keyGovernanceRecordUnavailable(Sample.bundle())) {
            _ = try SampleRelease.build(
                keyGovernance: FakeKeyGovernance(fault: .recordUnavailable)
            )
        }
    }

    @Test("A designation carrying a rejection stops the build")
    func rejectedDesignationIsRefused() throws {
        // Presence is not approval, and this module cannot supply the missing one: there is no
        // member anywhere in it that records a decision.
        #expect(throws: BundleBuildError.designatedSigningKeyNotApproved(Sample.signingKey())) {
            _ = try SampleRelease.build(
                keyGovernance: .approving(decision: .rejected)
            )
        }
    }

    // MARK: - Helpers

    private static func generatedBytes(
        _ built: UnsignedInitialModelBundle,
        at path: CanonicalRelativePath
    ) throws -> [UInt8] {
        let entry = try #require(built.tree.entry(at: path))
        guard case let .generatedFile(bytes) = entry.content else {
            throw GeneratedBytesUnavailable()
        }
        return bytes
    }

    private struct GeneratedBytesUnavailable: Error {}
}

/// The deterministic JSON writer the manifest bytes are produced through.
///
/// Separate from the builder's tests because the behavior being pinned is narrow and
/// consequential: a signed artifact's bytes have to be a function of its value alone.
@Suite("Canonical artifact encoding")
struct CanonicalArtifactEncodingTests {
    @Test("Object members are ordered by their encoded key bytes")
    func objectKeysAreOrdered() throws {
        let input = Array(#"{"zulu":1,"alpha":2,"mike":{"delta":3,"bravo":4}}"#.utf8)
        let output = try CanonicalArtifactEncoding.canonicalized(input)
        #expect(
            String(decoding: output, as: UTF8.self)
                == #"{"alpha":2,"mike":{"bravo":4,"delta":3},"zulu":1}"#
        )
    }

    @Test("An array of strings is ordered and every other array keeps its order")
    func onlyStringArraysAreOrdered() throws {
        // The two set-valued manifest fields are arrays of strings and decode back into sets,
        // so ordering them is semantics-preserving. Every order-significant array in the
        // schema holds objects or numbers, and those are copied through untouched.
        let input = Array(
            #"{"strings":["c","a","b"],"objects":[{"n":2},{"n":1}],"numbers":[3,1,2]}"#.utf8
        )
        let output = try CanonicalArtifactEncoding.canonicalized(input)
        #expect(
            String(decoding: output, as: UTF8.self)
                == #"{"numbers":[3,1,2],"objects":[{"n":2},{"n":1}],"strings":["a","b","c"]}"#
        )
    }

    @Test("Numbers and literals are copied verbatim rather than reformatted")
    func scalarsAreCopiedVerbatim() throws {
        // A number that were reparsed and reprinted could change a signed artifact's bytes and
        // could lose precision. Copying the token is what makes that impossible.
        let input = Array(
            #"{"a":1.390625,"b":-0.0,"c":1e-7,"d":true,"e":false,"f":null,"g":"\u00e9\/x"}"#.utf8
        )
        let output = try CanonicalArtifactEncoding.canonicalized(input)
        #expect(String(decoding: output, as: UTF8.self) == String(decoding: input, as: UTF8.self))
    }

    @Test("Two encodings of the same value produce the same bytes")
    func encodingIsAFunctionOfTheValue() throws {
        let value = try Sample.selfTestSpecification()
        let first = try CanonicalArtifactEncoding.canonicalBytes(of: value)
        let second = try CanonicalArtifactEncoding.canonicalBytes(of: value)
        #expect(first == second)
    }

    @Test("Malformed bytes are refused rather than rewritten")
    func malformedBytesAreRefused() throws {
        #expect(throws: CanonicalEncodingFault.self) {
            _ = try CanonicalArtifactEncoding.canonicalized(Array(#"{"a":}"#.utf8))
        }
        #expect(throws: CanonicalEncodingFault.self) {
            _ = try CanonicalArtifactEncoding.canonicalized(Array(#"{"a":1"#.utf8))
        }
        #expect(throws: CanonicalEncodingFault.self) {
            _ = try CanonicalArtifactEncoding.canonicalized(Array(#"{"a":1} trailing"#.utf8))
        }
    }

    @Test("A document deeper than the walked bound is refused")
    func excessiveNestingIsRefused() throws {
        let depth = CanonicalArtifactEncoding.maximumDepth + 1
        let deep = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        #expect(
            throws: CanonicalEncodingFault.tooDeep(
                maximumDepth: CanonicalArtifactEncoding.maximumDepth
            )
        ) {
            _ = try CanonicalArtifactEncoding.canonicalized(Array(deep.utf8))
        }
    }
}
