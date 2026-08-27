import DefAIkeDomain
import Foundation

@testable import DefAIkeApplication

// The two port doubles and the arguments the Share handoff coordinator needs in order to be
// called at all.
//
// Both doubles record every call, because most of what task 4.5 has to prove is a
// *nonoccurrence*: an unverified handoff must never reach Model Bundle binding, and the only
// way to state that is to assert the bundle port was not called. The claimer records the
// build identity it was handed for the same reason — passing the wrong build would still
// produce a plausible-looking result.
//
// **Nothing here is release evidence.** No signature is verified, no digest is streamed, no
// self-test is run, and no compiled model is loaded. The manifest, receipt, and component
// versions are synthetic and exist so a port that takes a verified bundle can be called at
// all; real verification belongs to task 6.11.

// MARK: - Handoff values

extension Fixture {
    static func appBuild(_ raw: String = "build-pixel-only-0001") -> AppBuildID {
        guard let id = AppBuildID(raw) else {
            preconditionFailure("fixture app build identifier is not canonical: \(raw)")
        }
        return id
    }

    static func bundleID(_ raw: String = "bundle-0001") -> ModelBundleID {
        guard let id = ModelBundleID(raw) else {
            preconditionFailure("fixture bundle identifier is not canonical: \(raw)")
        }
        return id
    }

    static func transferID(_ raw: String = "transfer-0001") -> ShareTransferID {
        guard let id = ShareTransferID(raw) else {
            preconditionFailure("fixture transfer identifier is not canonical: \(raw)")
        }
        return id
    }

    static func configurationID(_ raw: String = "configuration-0001") -> ApprovedConfigurationID {
        guard let id = ApprovedConfigurationID(raw) else {
            preconditionFailure("fixture configuration identifier is not canonical: \(raw)")
        }
        return id
    }

    static func hardware(_ raw: String = "iPhone17.1") -> DeviceHardwareID {
        guard let id = DeviceHardwareID(raw) else {
            preconditionFailure("fixture hardware identifier is not canonical: \(raw)")
        }
        return id
    }

    static func signingKey(_ raw: String = "key.fixture") -> SigningKeyID {
        guard let id = SigningKeyID(raw) else {
            preconditionFailure("fixture signing key identifier is not canonical: \(raw)")
        }
        return id
    }

    static func text(_ raw: String) -> ArtifactText {
        do {
            return try ArtifactText(validating: raw)
        } catch {
            preconditionFailure("fixture text is not schema-valid: \(error)")
        }
    }

    /// A published ticket, as the extension would have written it.
    static func shareTicket(
        transferID: ShareTransferID = Fixture.transferID(),
        sessionID: AnalysisSessionID = Fixture.sessionID("session-pending-0001"),
        byteCount: UInt64 = 2_048,
        preservationBasis: PreservationBasis = .preservationHistoryNotEstablished,
        extensionBuildID: AppBuildID = Fixture.appBuild()
    ) -> ShareTransferTicket {
        guard let ticket = ShareTransferTicket(
            transferID: transferID,
            sessionID: sessionID,
            contentTypeHint: contentTypeHint(),
            byteCount: byteCount,
            sha256: digest("staged-\(sessionID.rawValue)"),
            preservationStatus: preservationBasis.mostConservativeStatus,
            preservationBasis: preservationBasis,
            extensionBuildID: extensionBuildID,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        ) else {
            preconditionFailure("the ticket fixture must be internally consistent")
        }
        return ticket
    }

    /// One published transfer awaiting the app, as a peek would report it.
    static func readyTransfer(
        ticket: ShareTransferTicket? = nil
    ) -> ReadyTransfer {
        ReadyTransfer(
            ticket: ticket ?? shareTicket(),
            storageKey: storageKey("fedcba98765432100123456789abcdef")
        )
    }
}

// MARK: - A verified, activated bundle

enum HandoffBundleFixture {
    static func manifest(bundleID: String = "bundle-0001") -> ModelBundleManifest {
        do {
            return try ModelBundleManifest(
                schemaVersion: .v1,
                bundleID: Fixture.bundleID(bundleID),
                modelIdentity: RequiredPixelModel.identity,
                modelFormat: try ModelFormatDescriptor(
                    programKind: .mlProgram,
                    computePrecision: .float16,
                    minimumOS: .iOS17
                ),
                inputContract: try ModelInputContract(
                    featureName: Fixture.text("image"),
                    width: CenterCropContract.requiredEdge,
                    height: CenterCropContract.requiredEdge,
                    channelOrder: .rgb,
                    elementType: .uint8,
                    appliesAppSideNormalization: false
                ),
                outputContract: try ModelOutputContract(
                    featureName: Fixture.text(ModelOutputContract.requiredFeatureName),
                    elementType: .float32,
                    isPositiveGoing: true
                ),
                componentVersions: BundleComponentVersions(
                    coreMLModel: Fixture.artifactID("coreml-model-0001"),
                    preprocessingContract: Fixture.artifactID("preprocessing-0001"),
                    calibrationPolicy: Fixture.artifactID("calibration-0001"),
                    evidenceScope: Fixture.artifactID("scope-0001"),
                    verdictCopyCompatibility: Fixture.artifactID("copy-0001"),
                    selfTestSpecification: Fixture.artifactID("self-tests-0001")
                ),
                artifacts: [digestRecord()],
                compatibility: try CompatibilityMatrix(
                    compatibleAppBuilds: [Fixture.appBuild()],
                    requiredCapabilities: [.pixelAnalysis],
                    minimumOS: .iOS17
                ),
                upstreamBoundaryMetadata: try UpstreamBoundaryMetadata(
                    rawLogitValue: UpstreamBoundaryMetadata.requiredValue,
                    role: .modelMetadataOnly
                ),
                signingKey: Fixture.signingKey()
            )
        } catch {
            preconditionFailure("the manifest fixture must be schema-valid: \(error)")
        }
    }

    /// A receipt whose signature and self-test outcomes both passed, which is the only kind
    /// ``BoundModelBundle`` accepts. No cryptography ran to produce it.
    static func receipt(bundleID: String = "bundle-0001") -> ActivationReceipt {
        do {
            return try ActivationReceipt(
                id: Fixture.artifactID("receipt-0001"),
                schemaVersion: .v1,
                bundleID: Fixture.bundleID(bundleID),
                verificationPolicy: Fixture.artifactID("bundle-verification-0001"),
                verifiedManifestDigest: Fixture.digest("manifest-\(bundleID)"),
                verifiedArtifactDigests: [digestRecord()],
                signatureOutcome: .passed,
                selfTestOutcome: .passed,
                deviceContext: deviceContext(),
                activationGeneration: try PositiveCount(validating: 1),
                activatedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        } catch {
            preconditionFailure("the receipt fixture must be schema-valid: \(error)")
        }
    }

    static func boundBundle(bundleID: String = "bundle-0001") -> BoundModelBundle {
        guard let bundle = BoundModelBundle(
            manifest: manifest(bundleID: bundleID),
            receipt: receipt(bundleID: bundleID)
        ) else {
            preconditionFailure("the bound bundle fixture must be constructible")
        }
        return bundle
    }

    static func digestRecord(
        path: String = "artifacts/model.mlmodelc"
    ) -> ArtifactDigestRecord {
        guard let canonical = CanonicalRelativePath(path) else {
            preconditionFailure("fixture artifact path is not canonical: \(path)")
        }
        return ArtifactDigestRecord(
            path: canonical,
            kind: .directoryTree,
            byteCount: 4_096,
            digest: Fixture.digest(path)
        )
    }

    static func deviceContext(appBuild: AppBuildID = Fixture.appBuild()) -> DeviceContext {
        DeviceContext(
            hardwareIdentifier: Fixture.hardware(),
            osVersion: .iOS17,
            appBuild: appBuild,
            environment: .developmentMac
        )
    }

    /// The running build, device, and capability set the coordinator is handed.
    ///
    /// `appBuild` is what the claim compares the ticket's staging build against, so a test
    /// can put the two on either side of that comparison.
    static func releaseContext(
        appBuild: AppBuildID = Fixture.appBuild(),
        capabilities: Set<CapabilityID> = [.pixelAnalysis]
    ) -> ReleaseContext {
        guard let context = ReleaseContext(
            device: deviceContext(appBuild: appBuild),
            approvedConfiguration: Fixture.configurationID(),
            capabilityManifestID: Fixture.artifactID("capability-manifest-0001"),
            compiledCapabilities: capabilities
        ) else {
            preconditionFailure("the release context fixture must be constructible")
        }
        return context
    }
}

// MARK: - Port doubles

/// A ``ShareTransferClaiming`` double that records its calls and answers what a test queued.
///
/// The recorded build identity matters as much as the answer: the coordinator has to hand
/// the claim *the running build*, and a coordinator that passed a constant would still
/// return a plausible outcome.
actor RecordingShareClaimer: ShareTransferClaiming {

    /// What ``peekReadyTransfer()`` answers.
    enum PeekAnswer: Sendable {
        /// Report one published transfer.
        case pending(ReadyTransfer)
        /// Report an empty ready slot.
        case empty
        /// Fail to say what is pending.
        case fail(EphemeralStoreError)
    }

    /// What ``claimReadyTransfer(claimingBuildID:)`` answers.
    enum ClaimAnswer: Sendable {
        /// Return an accepted ingest built from the build identity it was handed.
        case verified(@Sendable (AppBuildID) -> ImportedEncodedAsset)
        /// Report that nothing was pending after all.
        case nothingPending
        /// Throw the given fault, as a mismatch or a cancellation would.
        case fail(AnalysisFault)
    }

    /// One recorded call, in order.
    enum Call: Hashable, Sendable {
        case peek
        case claim(AppBuildID)
    }

    private let peekAnswer: PeekAnswer
    private let claimAnswer: ClaimAnswer
    private(set) var calls: [Call] = []

    init(peek: PeekAnswer, claim: ClaimAnswer = .nothingPending) {
        self.peekAnswer = peek
        self.claimAnswer = claim
    }

    var claimedBuildIDs: [AppBuildID] {
        calls.compactMap {
            guard case .claim(let build) = $0 else { return nil }
            return build
        }
    }

    func peekReadyTransfer() async throws(EphemeralStoreError) -> ReadyTransfer? {
        calls.append(.peek)
        switch peekAnswer {
        case .pending(let transfer): return transfer
        case .empty: return nil
        case .fail(let error): throw error
        }
    }

    func claimReadyTransfer(
        claimingBuildID: AppBuildID
    ) async throws(AnalysisFault) -> ImportedEncodedAsset? {
        calls.append(.claim(claimingBuildID))
        switch claimAnswer {
        case .verified(let make): return make(claimingBuildID)
        case .nothingPending: return nil
        case .fail(let fault): throw fault
        }
    }
}

/// A ``ModelBundleManaging`` double that records whether it was reached at all.
///
/// The call count is the assertion task 4.5 needs: "bind the Model Bundle only after
/// successful verification" is a nonoccurrence on every failing path, and the result cannot
/// show it.
actor RecordingBundleManager: ModelBundleManaging {
    enum Answer: Sendable {
        case active(BoundModelBundle)
        case fail(AnalysisFault)
    }

    private let answer: Answer
    private(set) var activeBundleRequests: [ReleaseContext] = []
    private(set) var activationRequests: [ModelBundleID] = []
    private(set) var rollbackRequests: [ModelBundleID] = []

    init(_ answer: Answer = .active(HandoffBundleFixture.boundBundle())) {
        self.answer = answer
    }

    /// Every call across every member. Zero is what a refused handoff must produce.
    var callCount: Int {
        activeBundleRequests.count + activationRequests.count + rollbackRequests.count
    }

    func verifiedActiveBundle(
        for context: ReleaseContext
    ) async throws(AnalysisFault) -> BoundModelBundle {
        activeBundleRequests.append(context)
        switch answer {
        case .active(let bundle): return bundle
        case .fail(let fault): throw fault
        }
    }

    func activateLocalCandidate(
        _ id: ModelBundleID,
        context: ReleaseContext
    ) async throws(AnalysisFault) -> BoundModelBundle {
        activationRequests.append(id)
        switch answer {
        case .active(let bundle): return bundle
        case .fail(let fault): throw fault
        }
    }

    func rollback(
        to id: ModelBundleID,
        context: ReleaseContext
    ) async throws(AnalysisFault) -> BoundModelBundle {
        rollbackRequests.append(id)
        switch answer {
        case .active(let bundle): return bundle
        case .fail(let fault): throw fault
        }
    }
}
