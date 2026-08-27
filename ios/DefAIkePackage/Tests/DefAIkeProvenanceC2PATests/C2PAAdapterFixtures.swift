import Foundation

@testable import DefAIkeDomain
@testable import DefAIkeProvenanceAPI
@testable import DefAIkeProvenanceC2PA

// Deliberately synthetic sample values for the conditional C2PA adapter tests.
//
// **Nothing here is an approved release input.** The trust store and its anchor bytes,
// the revocation behavior, the status mapping, the displayable fields, the limits, and
// the copy keys are placeholders for schema shape only. Every one of them is an
// unresolved external decision (design decision D5 and the Provenance Feasibility Gate),
// and no test asserts that a value here is correct: the tests assert what the *adapter*
// does with a given approved input, and what happens when one field is changed.
//
// In particular the anchor bytes below are the string `synthetic-test-anchors`. They are
// not a certificate, they establish no trust, and no test hands them to the real library.
//
// This target cannot import DefAIkeTestSupport — the doubles module belongs to no
// product and is not a dependency of this test target — so the bounded store, clock, and
// reader doubles below are local.

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

    static func text(_ value: String) -> ArtifactText {
        try! ArtifactText(validating: value)
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
}

// MARK: - Sample policy

enum PolicySample {
    /// The status keys this adapter emits for its structural read conditions.
    static func readerStatus(_ condition: C2PAReaderCondition) -> ProvenanceValidatorStatusID {
        C2PAStatusVocabulary.statusID(for: condition)
    }

    /// The status key this adapter emits for one library validation status code.
    static func libraryStatus(_ code: String) -> ProvenanceValidatorStatusID {
        C2PAStatusVocabulary.statusID(forLibraryCode: code)!
    }

    /// A representative library failure code from each classification family.
    static let byteBindingFailure = "assertion.dataHash.mismatch"
    static let cryptographicFailure = "claimSignature.mismatch"
    static let structuralFailure = "claim.malformed"
    static let unclassifiedFailure = "general.error"
    static let unsupportedAlgorithm = "algorithm.unsupported"

    /// A complete mapping over every key the adapter can emit in these tests.
    ///
    /// Synthetic. The real mapping is a release decision, and the point of listing every
    /// key here is only that a *complete* policy lets the tests reach all five states.
    static let statusMappings: [ProvenanceStatusMapping] = [
        .init(status: readerStatus(.allChecksPassed), state: .validated),
        .init(status: readerStatus(.noManifestFound), state: .absent),
        .init(status: readerStatus(.manifestNotEmbedded), state: .indeterminate),
        .init(status: readerStatus(.revocationAnswerUnavailable), state: .indeterminate),
        .init(status: readerStatus(.inputNotParsable), state: .indeterminate),
        .init(status: readerStatus(.containerNotSupported), state: .unsupported),
        .init(status: readerStatus(.validationResultAbsent), state: .indeterminate),
        .init(status: libraryStatus(byteBindingFailure), state: .invalid),
        .init(status: libraryStatus(cryptographicFailure), state: .invalid),
        .init(status: libraryStatus(structuralFailure), state: .invalid),
        .init(status: libraryStatus(unclassifiedFailure), state: .invalid),
        .init(status: libraryStatus(unsupportedAlgorithm), state: .unsupported),
    ]

    static func trustStore() -> ProvenanceTrustStoreDescriptor {
        try! ProvenanceTrustStoreDescriptor(
            store: Sample.evidence("trust-store.sample"),
            anchorCount: try! PositiveCount(validating: 1),
            isOfflineOnly: true
        )
    }

    static func policy(
        id: String = "provenance.sample",
        displayableFields: Set<ProvenanceDisplayField> = [
            .signerIdentity, .claimGenerator, .assertionLabels,
        ],
        maximumManifestByteCount: UInt64 = 65_536,
        maximumAssertionCount: Int = 8,
        maximumNestingDepth: Int = 8,
        maximumProcessingMilliseconds: UInt64 = 5_000,
        revocationState: ProvenanceStateKey = .indeterminate,
        statusMappings: [ProvenanceStatusMapping] = PolicySample.statusMappings,
        trustStore: ProvenanceTrustStoreDescriptor = PolicySample.trustStore()
    ) -> ProvenancePolicy {
        do {
            return try ProvenancePolicy(
                id: Sample.artifact(id),
                schemaVersion: .v1,
                capability: .contentCredentialValidation,
                validatorImplementationVersion: Sample.version("0.0.12"),
                validatorBinaryDigest: Sample.digest("c"),
                supportedSpecification: Sample.evidence("specification.sample"),
                trustStore: trustStore,
                revocationBehavior: try ProvenanceRevocationBehavior(
                    permitsNetworkRevocationCheck: false,
                    unavailableAnswerState: revocationState,
                    approval: Sample.approval()
                ),
                supportedAssertionLabels: [Sample.text("c2pa.actions")],
                displayableFields: displayableFields,
                processingLimits: ProvenanceProcessingLimits(
                    maximumManifestByteCount: try PositiveByteCount(
                        validating: maximumManifestByteCount
                    ),
                    maximumAssertionCount: try PositiveCount(validating: maximumAssertionCount),
                    maximumNestingDepth: try PositiveCount(validating: maximumNestingDepth),
                    maximumProcessingDuration: try ValidatedDuration(
                        validating: maximumProcessingMilliseconds
                    )
                ),
                resourceBudget: Sample.artifact("budget.main-application"),
                statusMappings: statusMappings,
                feasibilityApproval: Sample.approval()
            )
        } catch {
            preconditionFailure("the provenance policy sample must be schema-valid: \(error)")
        }
    }
}

// MARK: - Sample copy

enum CopySample {
    static func stateKey(_ state: ProvenanceStateKey) -> ApprovedCopyKey {
        Sample.copyKey("copy.provenance.state.\(state.rawValue)")
    }

    static func fieldKey(_ field: ProvenanceDisplayField) -> ApprovedCopyKey {
        Sample.copyKey("copy.provenance.field.\(field.rawValue)")
    }

    static func catalog() -> ApprovedVerdictCopyCatalog {
        var entries = VerdictCopySurface.unconditionalSurfaces.map { surface in
            VerdictCopyEntry(
                surface: surface,
                localizationKey: Sample.copyKey(
                    "copy.surface.\(surface.description.replacingOccurrences(of: "/", with: "."))"
                )
            )
        }
        for state in ProvenanceStateKey.allCases {
            entries.append(
                VerdictCopyEntry(surface: .provenanceState(state), localizationKey: stateKey(state))
            )
        }
        do {
            return try ApprovedVerdictCopyCatalog(
                id: Sample.artifact("copy.sample"),
                schemaVersion: .v1,
                compatibilityID: Sample.artifact("copy-compatibility.sample"),
                languageTag: Sample.text(ApprovedVerdictCopyCatalog.requiredLanguageTag),
                entries: entries,
                approval: Sample.approval()
            )
        } catch {
            preconditionFailure("the copy catalogue sample must be schema-valid: \(error)")
        }
    }

    static func binding(for policy: ProvenancePolicy) -> ProvenanceCopyBinding {
        let labels = Dictionary(
            uniqueKeysWithValues: policy.displayableFields.map { ($0, fieldKey($0)) }
        )
        guard let binding = ProvenanceCopyBinding(
            policy: policy,
            catalog: catalog(),
            detailLabels: labels
        ) else {
            preconditionFailure("the copy binding sample must cover the policy's fields")
        }
        return binding
    }

    static func mapper(for policy: ProvenancePolicy) -> ProvenanceOutcomeMapper {
        guard let mapper = ProvenanceOutcomeMapper(policy: policy, copy: binding(for: policy)) else {
            preconditionFailure("the mapper sample must accept the policy and copy binding")
        }
        return mapper
    }
}

// MARK: - Sample capability manifest

enum ManifestSample {
    /// A manifest that enables provenance and binds `policy`.
    ///
    /// Used only to prove the opposite of what it looks like: even a manifest that
    /// enables the capability cannot produce an enabled lane without a compiled analyzer.
    static func provenanceEnabled(for policy: ProvenancePolicy) -> ReleaseCapabilityManifest {
        do {
            return try ReleaseCapabilityManifest(
                id: Sample.artifact("capability-manifest.sample"),
                schemaVersion: .v1,
                appBuild: AppBuildID("build.sample")!,
                compositionIdentifier: Sample.text("Sample provenance composition"),
                compiledCapabilities: [.pixelAnalysis, .contentCredentialValidation],
                implementationVersions: [
                    CapabilityImplementationEntry(
                        capability: .pixelAnalysis,
                        version: Sample.version("1.0.0")
                    ),
                    CapabilityImplementationEntry(
                        capability: .contentCredentialValidation,
                        version: policy.validatorImplementationVersion
                    ),
                ],
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
                    provenancePolicy: .bound(policy.id),
                    fusionRule: .notApplicable(decision: Sample.approval())
                ),
                approval: Sample.approval()
            )
        } catch {
            preconditionFailure("the capability manifest sample must be schema-valid: \(error)")
        }
    }
}

// MARK: - Trust material and configuration

enum TrustSample {
    /// Synthetic anchor bytes. Not a certificate, and never handed to the real library.
    static let anchorBytes = [UInt8]("synthetic-test-anchors".utf8)

    static func material(for policy: ProvenancePolicy) -> C2PAOfflineTrustMaterial {
        guard let material = C2PAOfflineTrustMaterial(
            descriptor: policy.trustStore,
            anchorBytes: anchorBytes
        ) else {
            preconditionFailure("nonempty synthetic anchors must be representable")
        }
        return material
    }

    static func configuration(for policy: ProvenancePolicy) -> C2PAValidatorConfiguration {
        guard let configuration = C2PAValidatorConfiguration(
            mapper: CopySample.mapper(for: policy),
            trust: material(for: policy)
        ) else {
            preconditionFailure("trust material for this policy must configure the validator")
        }
        return configuration
    }
}

// MARK: - Bounded doubles

/// A bounded in-memory finalized-object store.
///
/// Holds only what the adapter reads: finalized objects with the measurements a real
/// streaming copy would have produced. Writing, moving, and cleanup are outside these
/// tests, so those members trap rather than pretending to work.
actor StubFinalizedObjectStore: EphemeralFileStoring {
    private var objects: [EphemeralStorageKey: (bytes: [UInt8], receipt: EphemeralWriteReceipt)] = [:]
    private var readFailure: EphemeralStoreError?

    /// Records one finalized object, with the byte count and digest the receipt reports.
    ///
    /// `declaredByteCount` and `declaredDigest` default to matching the bytes. A test
    /// overrides them to model a receipt that disagrees with what the object holds.
    func store(
        key: EphemeralStorageKey,
        session: AnalysisSessionID,
        bytes: [UInt8],
        declaredByteCount: UInt64? = nil,
        declaredDigest: DefAIkeDomain.SHA256Digest = Sample.digest("b")
    ) {
        let receipt = EphemeralWriteReceipt(
            key: key,
            scope: .session(session),
            byteCount: declaredByteCount ?? UInt64(bytes.count),
            sha256: declaredDigest,
            protection: .complete
        )
        objects[key] = (bytes, receipt)
    }

    func failNextRead(with error: EphemeralStoreError) {
        readFailure = error
    }

    func read(_ key: EphemeralStorageKey) throws(EphemeralStoreError) -> [UInt8] {
        if let readFailure {
            self.readFailure = nil
            throw readFailure
        }
        guard let object = objects[key] else { throw .notFound(key) }
        return object.bytes
    }

    func receipt(for key: EphemeralStorageKey) -> EphemeralWriteReceipt? {
        objects[key]?.receipt
    }

    func create(
        in scope: EphemeralStorageScope,
        protection: FileProtectionLevel
    ) throws(EphemeralStoreError) -> EphemeralStorageKey {
        throw .storeUnavailable
    }

    func append(
        _ chunk: [UInt8],
        to key: EphemeralStorageKey
    ) throws(EphemeralStoreError) -> Void {
        throw .storeUnavailable
    }

    func finalize(
        _ key: EphemeralStorageKey
    ) throws(EphemeralStoreError) -> EphemeralWriteReceipt {
        throw .storeUnavailable
    }

    func move(
        _ key: EphemeralStorageKey,
        to scope: EphemeralStorageScope
    ) throws(EphemeralStoreError) -> Void {
        throw .storeUnavailable
    }

    func keys(in scope: EphemeralStorageScope) -> Set<EphemeralStorageKey> {
        Set(objects.filter { $0.value.receipt.scope == scope }.keys)
    }

    func deleteAll(
        in scope: EphemeralStorageScope,
        reason: SessionCleanupReason
    ) throws(EphemeralStoreError) -> EphemeralDeletionReceipt {
        throw .storeUnavailable
    }

    func occupiedScopes() -> Set<EphemeralStorageScope> {
        Set(objects.values.map(\.receipt.scope))
    }
}

/// A clock whose monotonic reading advances by a fixed amount on each read.
///
/// One advance per read makes the elapsed measurement of a single `read` call exactly
/// `step`, which is what lets a test drive the declared processing-duration limit from
/// either side without a real delay.
final class SteppingClock: SessionClock, @unchecked Sendable {
    private let lock = NSLock()
    private let step: Duration
    private var reading: ContinuousClock.Instant

    init(step: Duration) {
        self.step = step
        self.reading = ContinuousClock.now
    }

    var wallClockNow: Date { Date(timeIntervalSince1970: 0) }

    var monotonicNow: ContinuousClock.Instant {
        lock.withLock {
            let current = reading
            reading = reading.advanced(by: step)
            return current
        }
    }
}

/// A validator seam that returns a prepared outcome and records what it was handed.
///
/// Records the bytes so a test can prove the adapter passed the exact retained sequence,
/// and never touches a network, a file, or a native binary.
final class StubManifestReader: C2PAManifestReading, @unchecked Sendable {
    private let lock = NSLock()
    private let result: Result<C2PAReadOutcome, C2PAReadFault>
    private var reads: [[UInt8]] = []

    init(returning outcome: C2PAReadOutcome) {
        self.result = .success(outcome)
    }

    init(failingWith fault: C2PAReadFault) {
        self.result = .failure(fault)
    }

    var readCount: Int { lock.withLock { reads.count } }

    var lastReadBytes: [UInt8]? { lock.withLock { reads.last } }

    func read(
        exactBytes bytes: [UInt8],
        limits: ProvenanceProcessingLimits,
        trust: C2PAOfflineTrustMaterial
    ) throws(C2PAReadFault) -> C2PAReadOutcome {
        lock.withLock { reads.append(bytes) }
        switch result {
        case let .success(outcome): return outcome
        case let .failure(fault): throw fault
        }
    }
}

// MARK: - Assembling one inspection

enum InspectionSample {
    static let bytes: [UInt8] = Array(repeating: 0x2A, count: 64)

    static func asset(
        session identifier: String = "session.sample",
        byteCount: UInt64 = UInt64(InspectionSample.bytes.count),
        digest: DefAIkeDomain.SHA256Digest = Sample.digest("b"),
        preservation: BytePreservationStatus = .originalBytes,
        basis: PreservationBasis = .providerDeclaredOriginalRepresentation
    ) -> ImportedEncodedAsset {
        let sessionID = Sample.session(identifier)
        let handle = EncodedAssetHandle(
            sessionID: sessionID,
            storageKey: Sample.storageKey("object.\(identifier)"),
            byteCount: byteCount,
            sha256: digest,
            protection: .complete
        )!
        return ImportedEncodedAsset(
            route: .photosPicker,
            handle: handle,
            preservationStatus: preservation,
            preservationBasis: basis,
            contentTypeHint: ContentTypeHint("public.jpeg")
        )!
    }

    /// A validator over a store that already holds the asset's retained bytes.
    static func validator(
        policy: ProvenancePolicy,
        outcome: C2PAReadOutcome,
        clockStep: Duration = .milliseconds(1)
    ) async -> (C2PAProvenanceValidator, StubManifestReader, ImportedEncodedAsset) {
        let reader = StubManifestReader(returning: outcome)
        let asset = asset()
        let store = StubFinalizedObjectStore()
        await store.store(
            key: asset.handle.storageKey,
            session: asset.sessionID,
            bytes: bytes
        )
        let validator = C2PAProvenanceValidator(
            store: store,
            reader: reader,
            clock: SteppingClock(step: clockStep),
            configuration: TrustSample.configuration(for: policy)
        )
        return (validator, reader, asset)
    }
}
