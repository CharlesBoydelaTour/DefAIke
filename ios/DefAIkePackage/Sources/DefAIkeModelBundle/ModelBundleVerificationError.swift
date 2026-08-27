import DefAIkeDomain

// Why a candidate Model Bundle did not pass local verification.
//
// This vocabulary is deliberately separate from the closed ten-value `AnalysisError`
// set. A user sees exactly one category for every finding below — `model-load-error`
// at the model-load stage (Requirement 10.16) — while a release audit needs to know
// which of the fixed verification steps refused the candidate and why.
//
// Two rules shape every case:
//
//   * No case means "verified with a warning". Verification either produces a
//     ``VerifiedBundleArtifactTree`` or produces one of these findings.
//   * No case carries a framework error, a file-system path, or user content. Paths
//     here are canonical relative paths inside an immutable release artifact, which
//     are release-authored and contain no user-derived text.

/// One component version a Model Bundle carries and activation replaces as one tuple.
///
/// Named rather than described so a compatibility finding says which of the six
/// components disagreed (Requirements 10.7 and 10.13).
public enum BundleComponent: String, Hashable, Sendable, CaseIterable, CustomStringConvertible {
    case coreMLModel = "core-ml-model"
    case preprocessingContract = "preprocessing-contract"
    case calibrationPolicy = "calibration-policy"
    case evidenceScope = "evidence-scope"
    case verdictCopyCompatibility = "verdict-copy-compatibility"
    case selfTestSpecification = "self-test-specification"

    public var description: String { rawValue }
}

/// Which part of the fixed model-input contract a candidate violates.
///
/// Requirements 4.5 through 4.8 fix one 384-by-384 unsigned 8-bit RGB buffer with no
/// app-side normalization, and the buffer has to be the one the bound Preprocessing
/// Contract produces. Each way of failing that is named, so a finding does not reduce six
/// distinct release defects to "incompatible input".
public enum ModelInputDefect: String, Hashable, Sendable, CaseIterable, CustomStringConvertible {
    case elementTypeNotUInt8 = "element-type-not-uint8"
    case channelOrderNotRGB = "channel-order-not-rgb"
    case edgeNotRequiredCropSize = "edge-not-required-crop-size"
    case claimsAppSideNormalization = "claims-app-side-normalization"
    case featureNameDisagreesWithBoundContract = "feature-name-disagrees-with-bound-contract"
    case shapeDisagreesWithBoundContract = "shape-disagrees-with-bound-contract"

    public var description: String { rawValue }
}

/// Which part of the fixed model-output contract a candidate violates.
///
/// Requirement 4.9 fixes one finite positive-going raw logit named `logit`.
public enum ModelOutputDefect: String, Hashable, Sendable, CaseIterable, CustomStringConvertible {
    case featureNameNotLogit = "feature-name-not-logit"
    case elementTypeNotFloatingPoint = "element-type-not-floating-point"
    case notPositiveGoing = "not-positive-going"

    public var description: String { rawValue }
}

/// Why one Model Bundle candidate did not pass local verification.
public enum ModelBundleVerificationError: Error, Equatable, Sendable, CustomStringConvertible {
    // MARK: Reading the candidate tree

    /// The candidate's directory tree could not be enumerated at all.
    case bundleTreeUnreadable(ModelBundleID)

    /// The tree holds more entries than verification will walk.
    case treeEntryBudgetExceeded(maximumEntryCount: Int, found: Int)

    /// The same path was reported twice, so "the entry at this path" is ambiguous.
    case duplicateTreeEntry(String)

    /// An entry path is not a canonical relative path: absolute, traversing, empty
    /// component, backslash, whitespace, control character, or over length.
    case noncanonicalEntryPath(String)

    /// A symbolic link exists in the tree. A verified artifact tree is exactly the
    /// bytes it declares, and a link can point outside the bundle after verification.
    case symbolicLinkPresent(String)

    /// An entry is neither a regular file nor a directory.
    case unsupportedEntryKind(String)

    // MARK: Reserved root files

    /// The manifest or its signature is absent from the bundle root.
    case reservedFileMissing(String)

    /// The manifest or signature path exists but is not a regular file.
    case reservedFileNotAFile(String)

    /// The manifest or signature exists but could not be read.
    case reservedFileUnreadable(String)

    /// The manifest exceeds the active policy's manifest ceiling. Checked before the
    /// bytes are read, so an oversized candidate is never fully loaded.
    case manifestTooLarge(ceiling: UInt64, found: UInt64)

    /// The detached signature exceeds the structural signature ceiling.
    case signatureTooLarge(ceiling: UInt64, found: UInt64)

    /// A reserved file kept producing bytes past its ceiling, so its enumerated size
    /// understated it. Reading stopped at the ceiling rather than continuing.
    case reservedFileExceedsCeiling(name: String, ceiling: UInt64)

    /// The signature file is empty. An empty signature is not a signature.
    case signatureEmpty

    // MARK: Manifest parsing

    /// The manifest bytes are not valid UTF-8.
    case manifestNotUTF8

    /// The manifest is not well-formed JSON.
    case manifestNotWellFormedJSON(byteOffset: Int)

    /// An object in the manifest declares the same key twice. A JSON decoder would
    /// silently keep one of them, so the document is refused instead.
    case manifestDuplicateKey(String)

    /// The manifest nests deeper than verification will walk.
    case manifestTooDeeplyNested(maximumDepth: Int)

    /// The manifest decoded but violates the signed-artifact schema.
    case manifestRejectedBySchema(ArtifactSchemaError)

    /// One manifest field is missing or has the wrong shape. Names the field by its
    /// coding path; carries no decoder message.
    case manifestFieldNotDecodable(field: String)

    /// The manifest describes a different bundle than the one being verified.
    case manifestBundleMismatch(requested: ModelBundleID, declared: ModelBundleID)

    /// One declared artifact path contains another, so the same bytes would be
    /// covered by two digest records and "the digest of this path" is ambiguous.
    case overlappingDeclaredArtifacts(outer: CanonicalRelativePath, inner: CanonicalRelativePath)

    // MARK: Policy-supplied canonicalization

    /// The build's canonicalization binding carries a rejection rather than an
    /// approval. Presence of a profile reference is not approval of it.
    case canonicalizationProfileNotApproved(ArtifactID)

    /// This build implements a different canonicalization profile than the active
    /// policy requires. Identity, version, and content digest must all match.
    case canonicalizationProfileMismatch(policyProfile: ArtifactID, buildProfile: ArtifactID)

    // MARK: Policy-supplied signature trust

    /// The manifest names a signing key the active policy does not list. An unknown
    /// key is never assumed trustworthy.
    case signingKeyNotTrusted(SigningKeyID)

    /// The policy lists the key, but its key-governance record is a rejection.
    case signingKeyGovernanceNotApproved(SigningKeyID)

    /// The signing key is revoked. The policy's revocation behavior rejects the
    /// bundle; a revoked key never verifies.
    case signingKeyRevoked(SigningKeyID)

    /// The signing key is retired and the policy's rotation rule admits active keys
    /// only.
    case retiredSigningKeyRejectedByRotationRule(SigningKeyID)

    /// The policy's rotation rule lets retired predecessors verify bundles signed
    /// before their retirement, but neither the policy nor the manifest carries a
    /// retirement instant or a signing instant, so that window is not establishable
    /// from the approved inputs. Verification fails closed rather than widening the
    /// rule to "any retired key".
    case retiredSigningKeyWindowNotEstablishable(SigningKeyID)

    /// This build carries no public key material for the trusted key. A missing key
    /// is a fail-closed refusal, never a skipped check.
    case signingKeyMaterialUnavailable(SigningKeyID)

    /// The supplied key material does not digest to the value the policy records for
    /// that key, so the material is not the approved key.
    case signingKeyMaterialDigestMismatch(SigningKeyID)

    /// The injected verifier does not implement the algorithm the policy approves.
    /// No other algorithm is substituted.
    case signatureAlgorithmUnsupported(SignatureAlgorithm)

    /// The signature does not verify over the exact manifest bytes.
    case manifestSignatureDidNotVerify(key: SigningKeyID)

    // MARK: Artifact tree contents

    /// The tree holds an entry the manifest does not declare and that is not an
    /// implied container of, or a member of, a declared artifact.
    case undeclaredTreeEntry(CanonicalRelativePath)

    /// A declared artifact is absent from the tree.
    case declaredArtifactMissing(CanonicalRelativePath)

    /// A declared artifact exists but is a file where a directory tree is declared,
    /// or the reverse.
    case declaredArtifactKindMismatch(
        path: CanonicalRelativePath,
        declared: ArtifactDigestRecord.Kind
    )

    /// A declared directory-tree artifact contains nothing, so its digest would
    /// cover no bytes.
    case emptyDirectoryTreeArtifact(CanonicalRelativePath)

    /// Observed bytes disagree with the declared byte count.
    case artifactByteCountMismatch(path: CanonicalRelativePath, declared: UInt64, found: UInt64)

    /// Reading stopped because content ran past the bytes the manifest accounts for.
    /// Verification never hashes more than a manifest declares, so the exact size of
    /// over-long content is unknown and is not guessed.
    ///
    /// For a file artifact the bound is that artifact's declared byte count. For a
    /// member of a directory-tree artifact it is the tree's remaining declared bytes.
    case artifactReadExceededDeclaredBound(path: CanonicalRelativePath, bound: UInt64)

    /// Observed content digests to a different value than the manifest declares.
    case artifactDigestMismatch(CanonicalRelativePath)

    /// Declared content exists but could not be read.
    case artifactUnreadable(CanonicalRelativePath)

    // MARK: Model identity and build compatibility

    /// The build's role-to-path binding carries a rejection rather than an approval.
    /// Presence of a layout is not approval of it.
    case bundleLayoutNotApproved(ArtifactID)

    /// The artifact tree was verified under a different Bundle Verification Policy than
    /// the one this build binds, so the compatibility decision would rest on a signature
    /// checked against another policy's keys and rules.
    case verifiedUnderDifferentPolicy(verified: ArtifactID, bound: ArtifactID)

    /// The running context and the validated configuration name different signed
    /// capability manifests, so the compatibility decision would rest on two different
    /// statements of what this build is approved to do.
    case capabilityManifestMismatch(context: ArtifactID, bound: ArtifactID)

    /// The signed capability manifest does not list this bundle among the ones this build
    /// may activate. Being installed is not being approved.
    case candidateNotInApprovedBundleCatalog(ModelBundleID)

    /// The manifest declares a checkpoint other than the sole permitted pixel model
    /// (Requirements 1.16 and 10.2).
    case modelIdentityNotTheRequiredPixelModel(ModelCheckpointIdentifier)

    /// The approved layout names a path the manifest does not declare as an artifact.
    case roleArtifactNotDeclared(role: BundleArtifactRole, path: CanonicalRelativePath)

    /// The declared artifact for this role is a file where a directory tree is required,
    /// or the reverse.
    case roleArtifactKindMismatch(role: BundleArtifactRole, path: CanonicalRelativePath)

    /// The tree holds no file at the weight-blob path the approved layout names.
    case modelWeightBlobNotFound(CanonicalRelativePath)

    /// The weight blob's bytes do not digest to the value the model identity pins
    /// (Requirement 10.4).
    case modelWeightDigestMismatch(CanonicalRelativePath)

    /// The declared model is not an FP16 `mlprogram` (Requirements 4.2 and 10.3).
    case modelFormatNotFP16MLProgram(
        programKind: ModelProgramKind,
        precision: ModelComputePrecision
    )

    /// The declared model minimum deployment target is not the required one.
    case modelDeploymentTargetMismatch(required: PlatformVersion, declared: PlatformVersion)

    /// The declared model input is not the fixed single unsigned 8-bit RGB buffer the
    /// bound Preprocessing Contract produces.
    case modelInputContractRejected(ModelInputDefect)

    /// The declared model output is not the one finite positive-going scalar `logit`.
    case modelOutputContractRejected(ModelOutputDefect)

    /// One component version in the bundle is not the version this build binds
    /// (Requirements 10.7 and 10.8).
    case componentVersionIncompatible(
        component: BundleComponent,
        expected: ArtifactID,
        found: ArtifactID
    )

    /// The bundle's compatibility matrix does not list the running application build.
    case appBuildNotCompatible(AppBuildID)

    /// The bundle requires capabilities this build does not compile. A compatible build
    /// with a missing required capability is not compatible (Requirement 10.11).
    case requiredCapabilitiesNotCompiled([CapabilityID])

    /// The running operating system is below the bundle's declared minimum.
    case operatingSystemBelowBundleMinimum(required: PlatformVersion, running: PlatformVersion)

    // MARK: Release self-test artifacts

    /// A declared metadata artifact did not survive the bounded decode its role requires.
    ///
    /// Carries the exact decode fault, so an oversized payload, a duplicate key, a
    /// missing field, and a schema violation stay distinguishable in an audit.
    case declaredArtifactNotDecodable(role: BundleArtifactRole, error: ArtifactDecodingError)

    /// The self-test specification identifies itself as a different version than the one
    /// the manifest's component versions name.
    case selfTestSpecificationIdentifierMismatch(declared: ArtifactID, componentVersion: ArtifactID)

    /// The self-test specification names a fixture suite other than the catalogue the
    /// bundle carries.
    case selfTestFixtureCatalogMismatch(specification: ArtifactID, catalog: ArtifactID)

    /// A case names a fixture the bundle's catalogue does not carry, so the fixture it
    /// runs against is unresolvable (Requirement 10.10).
    case selfTestFixtureNotCatalogued(case: SelfTestCaseID, fixture: FixtureID)

    /// A catalogued asset path cannot be placed under the approved fixture root as a
    /// canonical path.
    case selfTestFixtureAssetPathNotResolvable(FixtureID)

    /// A required fixture asset is absent from the verified tree (Requirement 10.10).
    case selfTestFixtureAssetMissing(fixture: FixtureID, path: CanonicalRelativePath)

    /// A fixture asset holds fewer bytes than its catalogue entry declares.
    case selfTestFixtureByteCountMismatch(fixture: FixtureID, declared: UInt64, found: UInt64)

    /// A fixture asset kept producing bytes past the count its catalogue entry declares.
    ///
    /// Separate from ``selfTestFixtureByteCountMismatch(fixture:declared:found:)`` because
    /// reading stopped at the declared bound, so how much larger the asset actually is was
    /// never measured and is not guessed.
    case selfTestFixtureLargerThanCatalogued(fixture: FixtureID, declared: UInt64)

    /// A fixture asset's bytes do not digest to its catalogued value, so it is not the
    /// fixture the expected results were approved against.
    case selfTestFixtureDigestMismatch(FixtureID)

    /// One case declares two expectations of the same kind, so "the expected result" is
    /// ambiguous.
    case selfTestCaseRepeatsExpectation(case: SelfTestCaseID, kind: SelfTestExpectationKind)

    /// One case expects an Analysis Error and a successful result at the same time. A run
    /// cannot satisfy both, so the case could never pass and is refused as written.
    case selfTestCaseContradictsItself(SelfTestCaseID)

    // MARK: Release self-test execution

    /// The runner was given a budget or controller for the wrong execution target. Pixel
    /// self-tests run in the main application and are never governed by the extension's
    /// budget (Requirement 11.1).
    case selfTestBudgetTargetMismatch(expected: ExecutionTarget, found: ExecutionTarget)

    /// Continuing the run would exceed a hard limit in the active Resource Budget, so the
    /// self-tests did not complete — which is not a pass.
    case selfTestResourceLimitReached(ResourceMetric)

    /// The Resource Controller did not grant headroom for a reason other than a hard-limit
    /// breach — a cancelled reservation, for instance.
    ///
    /// Kept separate so a cancelled or otherwise aborted reservation is not recorded as a
    /// measured budget breach. Either way the run did not complete, and an incomplete run is
    /// not a pass.
    case selfTestResourceReservationRefused(ResourceMetric)

    /// The candidate's compiled model could not be loaded, so its self-tests could not
    /// run (Requirement 4.14).
    case selfTestCandidateLoadFailed(ModelBundleID)

    /// Execution of one case failed after its fixture was prepared.
    case selfTestExecutionFailed(SelfTestCaseID)

    /// One case produced a missing, misnamed, nonscalar, nonnumeric, or nonfinite output
    /// (Requirement 4.16).
    case selfTestOutputInvalid(SelfTestCaseID)

    /// One case declares an expected result the run produced no value for. A missing
    /// result is never a pass (Requirement 10.10).
    case selfTestExpectationNotProduced(case: SelfTestCaseID, kind: SelfTestExpectationKind)

    /// One case produced a value that disagrees with its declared expected result, within
    /// the tolerance the bundle itself declares.
    case selfTestExpectationMismatch(case: SelfTestCaseID, kind: SelfTestExpectationKind)

    // MARK: Receipts and atomic activation

    /// The activation record store is unavailable, or its published pointer could not be
    /// read. The active bundle is left alone rather than replaced without a record of it.
    case activationRecordStoreUnavailable

    /// No further activation generation is representable, so a new activation could not be
    /// told apart from the current one.
    case activationGenerationExhausted

    /// The receipt identifier this activation would write is not a canonical identifier.
    case activationReceiptIdentityNotCanonical(ModelBundleID)

    /// The receipt violates its own schema — an empty or duplicate-path digest inventory.
    case activationReceiptRejectedBySchema(ArtifactSchemaError)

    /// The receipt does not authorize a session binding for the bundle it describes, so
    /// activation stops rather than publishing a pointer nothing can bind.
    case activationReceiptNotBindable(ModelBundleID)

    /// A different receipt already exists under that identifier. A persisted receipt is
    /// immutable, so the record is kept and the activation is refused.
    case activationReceiptConflict(ArtifactID)

    /// The receipt could not be persisted. Nothing was published.
    case activationReceiptNotPersisted(ArtifactID)

    /// The new pointer could not be staged. The published pointer was never touched.
    case activationPointerNotStaged(ModelBundleID)

    /// Staged activation state did not reach stable storage, so it was discarded rather
    /// than published.
    case activationStateNotSynchronized(ModelBundleID)

    /// The atomic replacement of the published pointer did not complete. The previous
    /// pointer stands and the previously active bundle is unchanged (Requirement 10.12).
    case activationPointerNotReplaced(ModelBundleID)

    // MARK: Using the active bundle

    /// No verified compatible Model Bundle is active, so pixel inference is prevented
    /// (Requirement 10.16). Never satisfied from a persisted receipt: a record that a
    /// verification run happened is not a substitute for one.
    case noActiveModelBundle

    /// The active bundle is not compatible with the running build, device, or operating
    /// system. Nothing falls back to an older or unverified asset.
    case activeModelBundleNotCompatible(ModelBundleID)

    /// The one closed-vocabulary outcome a session may see for any finding here.
    ///
    /// Requirement 10.16 fixes it: without a verified compatible bundle, pixel
    /// inference is prevented and the session ends with `model-load-error`. The
    /// finding itself stays in the release audit trail and is never presented as a
    /// user-facing category (Requirement 11.17).
    public var analysisFault: AnalysisFault {
        .analysis(.modelLoadError, stage: .modelLoad)
    }

    public var description: String {
        switch self {
        case let .bundleTreeUnreadable(bundle):
            return "the artifact tree of bundle \(bundle.rawValue) could not be enumerated"
        case let .treeEntryBudgetExceeded(maximum, found):
            return "the artifact tree holds \(found) entries, above the \(maximum) walked"
        case let .duplicateTreeEntry(path):
            return "the artifact tree reports \"\(path)\" more than once"
        case let .noncanonicalEntryPath(path):
            return "\"\(path)\" is not a canonical relative artifact path"
        case let .symbolicLinkPresent(path):
            return "\"\(path)\" is a symbolic link; a verified artifact tree holds none"
        case let .unsupportedEntryKind(path):
            return "\"\(path)\" is neither a regular file nor a directory"
        case let .reservedFileMissing(name):
            return "the bundle root has no \(name)"
        case let .reservedFileNotAFile(name):
            return "\(name) is not a regular file"
        case let .reservedFileUnreadable(name):
            return "\(name) could not be read"
        case let .manifestTooLarge(ceiling, found):
            return "the manifest is \(found) bytes, above the policy ceiling of \(ceiling)"
        case let .signatureTooLarge(ceiling, found):
            return "the signature is \(found) bytes, above the \(ceiling)-byte ceiling"
        case let .reservedFileExceedsCeiling(name, ceiling):
            return "\(name) runs past its \(ceiling)-byte ceiling"
        case .signatureEmpty:
            return "the signature file is empty"
        case .manifestNotUTF8:
            return "the manifest bytes are not valid UTF-8"
        case let .manifestNotWellFormedJSON(offset):
            return "the manifest is not well-formed JSON at byte \(offset)"
        case let .manifestDuplicateKey(key):
            return "the manifest declares the key \"\(key)\" twice in one object"
        case let .manifestTooDeeplyNested(maximum):
            return "the manifest nests deeper than \(maximum) levels"
        case let .manifestRejectedBySchema(error):
            return "the manifest violates its schema: \(error.description)"
        case let .manifestFieldNotDecodable(field):
            return "the manifest field \(field) is missing or has the wrong shape"
        case let .manifestBundleMismatch(requested, declared):
            return """
                bundle \(requested.rawValue) was requested but its manifest declares \
                \(declared.rawValue)
                """
        case let .overlappingDeclaredArtifacts(outer, inner):
            return """
                declared artifact \"\(inner.rawValue)\" lies inside declared artifact \
                \"\(outer.rawValue)\"; the same bytes cannot carry two digest records
                """
        case let .canonicalizationProfileNotApproved(profile):
            return "the canonicalization profile \(profile.rawValue) is not approved"
        case let .canonicalizationProfileMismatch(policyProfile, buildProfile):
            return """
                the active policy requires canonicalization profile \
                \(policyProfile.rawValue); this build implements \(buildProfile.rawValue)
                """
        case let .signingKeyNotTrusted(key):
            return "the active policy does not trust signing key \(key.rawValue)"
        case let .signingKeyGovernanceNotApproved(key):
            return "the key-governance record for \(key.rawValue) is not an approval"
        case let .signingKeyRevoked(key):
            return "signing key \(key.rawValue) is revoked"
        case let .retiredSigningKeyRejectedByRotationRule(key):
            return "signing key \(key.rawValue) is retired and the rotation rule admits active keys only"
        case let .retiredSigningKeyWindowNotEstablishable(key):
            return """
                signing key \(key.rawValue) is retired and no retirement or signing \
                instant is available, so the historical-bundle window cannot be established
                """
        case let .signingKeyMaterialUnavailable(key):
            return "this build carries no public key material for \(key.rawValue)"
        case let .signingKeyMaterialDigestMismatch(key):
            return "the supplied key material is not the key the policy records for \(key.rawValue)"
        case let .signatureAlgorithmUnsupported(algorithm):
            return "the injected verifier does not implement \(algorithm.rawValue)"
        case let .manifestSignatureDidNotVerify(key):
            return "the manifest signature does not verify under \(key.rawValue)"
        case let .undeclaredTreeEntry(path):
            return "\"\(path.rawValue)\" is present but not declared by the manifest"
        case let .declaredArtifactMissing(path):
            return "declared artifact \"\(path.rawValue)\" is absent"
        case let .declaredArtifactKindMismatch(path, declared):
            return "declared artifact \"\(path.rawValue)\" is not a \(declared.rawValue)"
        case let .emptyDirectoryTreeArtifact(path):
            return "declared directory tree \"\(path.rawValue)\" contains nothing"
        case let .artifactByteCountMismatch(path, declared, found):
            return """
                \"\(path.rawValue)\" holds \(found) bytes; the manifest declares \(declared)
                """
        case let .artifactReadExceededDeclaredBound(path, bound):
            return "reading \"\(path.rawValue)\" stopped after its declared bound of \(bound) bytes"
        case let .artifactDigestMismatch(path):
            return "\"\(path.rawValue)\" does not match its declared digest"
        case let .artifactUnreadable(path):
            return "declared artifact \"\(path.rawValue)\" could not be read"
        case let .bundleLayoutNotApproved(layout):
            return "the bundle layout \(layout.rawValue) is not approved"
        case let .verifiedUnderDifferentPolicy(verified, bound):
            return """
                the artifact tree was verified under policy \(verified.rawValue); this \
                build binds \(bound.rawValue)
                """
        case let .capabilityManifestMismatch(context, bound):
            return """
                this process runs as capability manifest \(context.rawValue); the \
                validated configuration binds \(bound.rawValue)
                """
        case let .candidateNotInApprovedBundleCatalog(bundle):
            return "the capability manifest does not list bundle \(bundle.rawValue)"
        case let .modelIdentityNotTheRequiredPixelModel(checkpoint):
            return """
                the manifest declares checkpoint \(checkpoint.rawValue); the sole \
                permitted pixel model is \(RequiredPixelModel.checkpointIdentifier)
                """
        case let .roleArtifactNotDeclared(role, path):
            return "the \(role) at \"\(path.rawValue)\" is not a declared artifact"
        case let .roleArtifactKindMismatch(role, path):
            return "the \(role) at \"\(path.rawValue)\" is not a \(role.requiredKind.rawValue)"
        case let .modelWeightBlobNotFound(path):
            return "the artifact tree holds no weight blob at \"\(path.rawValue)\""
        case let .modelWeightDigestMismatch(path):
            return "\"\(path.rawValue)\" does not match the required weight-blob digest"
        case let .modelFormatNotFP16MLProgram(programKind, precision):
            return """
                the declared model is a \(precision.rawValue) \(programKind.rawValue); an \
                FP16 mlprogram is required
                """
        case let .modelDeploymentTargetMismatch(required, declared):
            return """
                the declared model minimum deployment target is \(declared); \(required) \
                is required
                """
        case let .modelInputContractRejected(defect):
            return "the declared model input is rejected: \(defect)"
        case let .modelOutputContractRejected(defect):
            return "the declared model output is rejected: \(defect)"
        case let .componentVersionIncompatible(component, expected, found):
            return """
                the bundle's \(component) is \(found.rawValue); this build binds \
                \(expected.rawValue)
                """
        case let .appBuildNotCompatible(build):
            return "the bundle is not compatible with application build \(build.rawValue)"
        case let .requiredCapabilitiesNotCompiled(capabilities):
            return """
                the bundle requires capabilities this build does not compile: \
                \(capabilities.map(\.rawValue).sorted().joined(separator: ", "))
                """
        case let .operatingSystemBelowBundleMinimum(required, running):
            return "the bundle requires at least \(required); this device runs \(running)"
        case let .declaredArtifactNotDecodable(role, error):
            return "the \(role) is not decodable: \(error.description)"
        case let .selfTestSpecificationIdentifierMismatch(declared, componentVersion):
            return """
                the self-test specification identifies itself as \(declared.rawValue); the \
                manifest names \(componentVersion.rawValue)
                """
        case let .selfTestFixtureCatalogMismatch(specification, catalog):
            return """
                the self-test specification names fixture suite \(specification.rawValue); \
                the bundle carries \(catalog.rawValue)
                """
        case let .selfTestFixtureNotCatalogued(caseID, fixture):
            return """
                self-test case \(caseID.rawValue) names fixture \(fixture.rawValue), which \
                the bundle's catalogue does not carry
                """
        case let .selfTestFixtureAssetPathNotResolvable(fixture):
            return "the catalogued asset path for fixture \(fixture.rawValue) is not resolvable"
        case let .selfTestFixtureAssetMissing(fixture, path):
            return "fixture \(fixture.rawValue) is absent from \"\(path.rawValue)\""
        case let .selfTestFixtureByteCountMismatch(fixture, declared, found):
            return """
                fixture \(fixture.rawValue) holds \(found) bytes; its catalogue entry \
                declares \(declared)
                """
        case let .selfTestFixtureLargerThanCatalogued(fixture, declared):
            return """
                fixture \(fixture.rawValue) runs past the \(declared) bytes its catalogue \
                entry declares
                """
        case let .selfTestFixtureDigestMismatch(fixture):
            return "fixture \(fixture.rawValue) does not match its catalogued digest"
        case let .selfTestCaseRepeatsExpectation(caseID, kind):
            return "self-test case \(caseID.rawValue) declares \(kind) more than once"
        case let .selfTestCaseContradictsItself(caseID):
            return """
                self-test case \(caseID.rawValue) expects an Analysis Error and a \
                successful result at the same time
                """
        case let .selfTestBudgetTargetMismatch(expected, found):
            return """
                release self-tests are governed by the \(expected.rawValue) budget; a \
                \(found.rawValue) budget was supplied
                """
        case let .selfTestResourceLimitReached(metric):
            return "the self-test run would exceed the active hard limit for \(metric.rawValue)"
        case let .selfTestResourceReservationRefused(metric):
            return "the self-test run was not granted \(metric.rawValue) headroom"
        case let .selfTestCandidateLoadFailed(bundle):
            return "the compiled model of candidate \(bundle.rawValue) could not be loaded"
        case let .selfTestExecutionFailed(caseID):
            return "self-test case \(caseID.rawValue) failed to execute"
        case let .selfTestOutputInvalid(caseID):
            return "self-test case \(caseID.rawValue) produced an invalid model output"
        case let .selfTestExpectationNotProduced(caseID, kind):
            return "self-test case \(caseID.rawValue) produced no \(kind)"
        case let .selfTestExpectationMismatch(caseID, kind):
            return "self-test case \(caseID.rawValue) produced a \(kind) that disagrees"
        case .activationRecordStoreUnavailable:
            return "the activation record store is unavailable"
        case .activationGenerationExhausted:
            return "no further activation generation is representable"
        case let .activationReceiptIdentityNotCanonical(bundle):
            return """
                the receipt identifier for an activation of \(bundle.rawValue) is not a \
                canonical identifier
                """
        case let .activationReceiptRejectedBySchema(error):
            return "the activation receipt violates its schema: \(error.description)"
        case let .activationReceiptNotBindable(bundle):
            return "the activation receipt for \(bundle.rawValue) authorizes no session binding"
        case let .activationReceiptConflict(receipt):
            return "a different receipt is already persisted as \(receipt.rawValue)"
        case let .activationReceiptNotPersisted(receipt):
            return "the activation receipt \(receipt.rawValue) could not be persisted"
        case let .activationPointerNotStaged(bundle):
            return "the active pointer for \(bundle.rawValue) could not be staged"
        case let .activationStateNotSynchronized(bundle):
            return """
                staged activation state for \(bundle.rawValue) did not reach stable storage
                """
        case let .activationPointerNotReplaced(bundle):
            return "the active pointer was not replaced with \(bundle.rawValue)"
        case .noActiveModelBundle:
            return "no verified compatible Model Bundle is active"
        case let .activeModelBundleNotCompatible(bundle):
            return "the active bundle \(bundle.rawValue) is not compatible with this build"
        }
    }
}
