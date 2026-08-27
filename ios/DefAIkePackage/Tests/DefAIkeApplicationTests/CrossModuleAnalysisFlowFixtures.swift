import DefAIkeDomain
import DefAIkePresentation
import DefAIkeProvenanceAPI
import DefAIkeSharedTransfer
import DefAIkeTestSupport
import Foundation
import Testing

@testable import DefAIkeApplication

// Task 12.4: the scaffolding for the cross-module analysis flow.
//
// This file exists because task 12.4's subject is a *span*, and no other suite in the
// package can hold it. `DefAIkeSharedTransfer`, `DefAIkeApplication`, and
// `DefAIkePresentation` are siblings in the shipping graph: none depends on another, and
// `check-module-boundaries.py` keeps it that way deliberately. So the only place a real
// Photos or claimed-Share ingest, the real `AnalysisCoordinator`, and a real
// `AnalysisScreen` can be observed in one run is a *test* target that depends on all three.
// `DefAIkeApplicationTests` was chosen and its dependency list extended, rather than a new
// target created, because the coherent synthetic release this flow needs —
// `CoordinatorRelease`, which runs the real seven-step startup gate — already lives here.
//
// ## What is real here, and what is not
//
// Real, and driven end to end:
//
//   * `PhotosImportAdapter` and `PhotosIngestCoordinator` — the Photos route's streaming
//     copy, hashing, conservative preservation-basis derivation, and the decision about
//     whether a session exists at all.
//   * `ShareExtensionIngestCoordinator`, `SharedTransferStore`, `EncodedAssetRetainer`, and
//     `TransferManifestCoding` — the extension's consent gate, protected staging, bounded
//     ticket, and the atomic `staging → ready` promotion that *is* the Share route's
//     session-creation commit.
//   * `ShareHandoffClaimAdapter` and `ShareHandoffIngestCoordinator` — the atomic claim, the
//     recopy into app-private storage, the second digest, and the bundle binding that
//     happens strictly after verification.
//   * `AnalysisSessionBinder`, `AnalysisCoordinator`, `EvidenceCoordinator`,
//     `EvidenceLaneJoin`, `SessionTerminalCleanup`, and the real `EvidenceFusionRule`
//     lookup.
//   * `ApprovedCopyBinding`, `AnalysisScreen.projecting(_:)`, `AnalysisViewStateProjector`,
//     and `ProjectedWorkProgress`.
//
// Deliberately substituted, with the reason in each case:
//
//   * **The file system.** Both ingest routes write through
//     `InMemoryEphemeralStore`. What this task is about is the flow across module
//     boundaries, not storage; the real `ProtectedEphemeralFileStore` is exercised end to
//     end by `PhotosAndShareAdapterIntegrationTests` and `ProtectedEphemeralFileStoreTests`
//     in the shared-transfer target. Using the in-memory store also means **no file is
//     created inside a data-protected directory anywhere in this file**, so the known
//     intermittent host condition — a directory that accepts a protection attribute and
//     then refuses file creation inside it with `EPERM` — cannot arise. The host
//     representation each provider seam lends is an ordinary temporary file with no
//     protection attribute, which is the same thing a real framework provider hands over.
//   * **Data protection is requested at `.complete` and nothing weakens it.** No production
//     fail-closed path is relaxed to make anything here pass. Because no real file exists,
//     **no result in this file is Requirement 9.6 evidence**;
//     `PlatformDataProtection.enforcesDataProtection` is `false` off iOS regardless.
//   * **Validation, preprocessing, inference, and calibration** are the shared stubs. The
//     task says "fake/fixture inference", and the real Image I/O and Core ML paths belong to
//     their own targets' integration suites.
//   * **The provenance analyzer** is a fixture. It has to be: `DefAIkeProvenanceC2PA`'s
//     `C2PAProvenanceValidator` deliberately does not conform to `ProvenanceAnalyzing`, so
//     **there is no shipping provenance analyzer at all**, and `c2pa-swift` 0.0.12 refuses
//     configuration with synthetic anchors so every real read returns
//     `validatorNotConfigurable`. Every conditional-provenance assertion below is therefore
//     about the lane's *plumbing*, and the real validator path is unreachable.
//
// ## Nothing here is an approved release value
//
// Every identifier, byte sequence, deadline, budget limit, protection level, and copy key is
// synthetic scaffolding that exists so a port taking a signed artifact can be called at all.
// No number below may be copied into a shipping artifact, and no host result here is
// physical-device evidence.

// MARK: - Route axis

/// The two Version 1 ingest routes, as this file drives them.
///
/// `claimedShare` is the whole Share route and not just the claim: the extension stages and
/// publishes, then the main app claims. Naming it for the claim is a reminder that the
/// *session* the main app analyzes is one the publication already created.
enum FlowRoute: String, Sendable, CaseIterable, CustomStringConvertible {
    case photos = "photos-picker"
    case claimedShare = "claimed-share"

    var description: String { rawValue }

    /// The route an accepted ingest on this path must record (Requirement 2.8).
    var recordedRoute: InputRoute {
        switch self {
        case .photos: .photosPicker
        case .claimedShare: .shareExtension
        }
    }
}

/// The capability composition a flow runs under.
///
/// Three of the four combinations the manifest permits. `fusion` without `provenance` is
/// absent because it is not a composition: a Combined Summary needs an available provenance
/// lane, and `CoordinatorRelease` builds a manifest where fusion implies provenance.
enum FlowComposition: String, Sendable, CaseIterable, CustomStringConvertible {
    case pixelOnly = "pixel-only"
    case provenanceEnabled = "provenance-enabled"
    case provenanceAndFusion = "provenance-and-fusion"

    var description: String { rawValue }

    var enablesProvenance: Bool { self != .pixelOnly }
    var enablesFusion: Bool { self == .provenanceAndFusion }
}

// MARK: - The host's temporary representation

/// An ordinary temporary file standing in for what a framework provider lends.
///
/// No data-protection attribute is applied. A real `PhotosPickerItem` transfer and a real
/// `NSItemProvider` file representation both hand over a framework-owned temporary file, and
/// applying protection to it here would be modelling something the framework does not do —
/// as well as reaching for the one host behaviour this file is built to avoid.
enum FlowHostFile {
    /// Writes `bytes` to a fresh directory and returns the file, or `nil` when the host
    /// refused.
    ///
    /// `nil` rather than a `throws`, because the two provider seams below are typed
    /// `throws(PhotosProviderFault)` and `throws(SharedItemProviderFault)` and must turn a
    /// host refusal into their own vocabulary rather than propagate a `CocoaError`.
    static func write(_ bytes: [UInt8]) -> URL? {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(
                path: "defaike-t124-host-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        guard
            (try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )) != nil
        else { return nil }
        let fileURL = directory.appending(path: "representation", directoryHint: .notDirectory)
        guard (try? Data(bytes).write(to: fileURL)) != nil else { return nil }
        return fileURL
    }

    /// Reclaims a lent representation, the way a provider's access window does.
    static func reclaim(_ fileURL: URL) {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }
}

// MARK: - The Photos provider seam

/// A `PhotosRepresentationAccess` that lends a real file for exactly the access window.
///
/// The window really closes: the lent file is removed the moment the consume closure
/// returns, so an adapter that captured the URL and read it afterwards would read nothing.
/// That is what makes "the copy happened inside the window" a fact about the run rather than
/// a comment.
final class FlowPhotosProvider: PhotosRepresentationAccess, @unchecked Sendable {
    private let bytes: [UInt8]
    private let form: SuppliedRepresentationForm
    private let suppliedHint: ContentTypeHint?
    private let fault: PhotosProviderFault?
    private let lock = NSLock()
    private var requests = 0

    init(
        bytes: [UInt8],
        form: SuppliedRepresentationForm = .typedFileRepresentation,
        suppliedHint: ContentTypeHint? = Fixture.contentTypeHint(),
        failingWith fault: PhotosProviderFault? = nil
    ) {
        self.bytes = bytes
        self.form = form
        self.suppliedHint = suppliedHint
        self.fault = fault
    }

    /// How many times the provider was asked. Zero means no byte of the item was read.
    var requestCount: Int { lock.withLock { requests } }

    func withRepresentation(
        of item: PhotosPickerItemReference,
        consume: @Sendable (BorrowedRepresentation) async -> RetainedRepresentation
    ) async throws(PhotosProviderFault) -> RetainedRepresentation {
        lock.withLock { requests += 1 }
        if let fault { throw fault }
        guard let fileURL = FlowHostFile.write(bytes) else { throw .transferFailed }
        let retained = await consume(
            BorrowedRepresentation(
                fileURL: fileURL,
                suppliedContentTypeHint: suppliedHint,
                form: form
            )
        )
        FlowHostFile.reclaim(fileURL)
        return retained
    }
}

// MARK: - The Share provider and consent seams

/// A `SharedItemRepresentationAccess` whose access window also really closes.
final class FlowSharedItemProvider: SharedItemRepresentationAccess, @unchecked Sendable {
    private let bytes: [UInt8]
    private let form: SharedRepresentationForm
    private let fault: SharedItemProviderFault?
    private let lock = NSLock()
    private var requests = 0

    init(
        bytes: [UInt8],
        form: SharedRepresentationForm = .typedFileRepresentation,
        failingWith fault: SharedItemProviderFault? = nil
    ) {
        self.bytes = bytes
        self.form = form
        self.fault = fault
    }

    /// How many times the host was asked. Zero means no byte of the shared item was read.
    var requestCount: Int { lock.withLock { requests } }

    func withRepresentation(
        of provider: SharedItemProvider,
        consume: @Sendable (BorrowedSharedRepresentation) async -> StagedRepresentation
    ) async throws(SharedItemProviderFault) -> StagedRepresentation {
        lock.withLock { requests += 1 }
        if let fault { throw fault }
        guard let fileURL = FlowHostFile.write(bytes) else { throw .transferFailed }
        let staged = await consume(
            BorrowedSharedRepresentation(fileURL: fileURL, form: form)
        )
        FlowHostFile.reclaim(fileURL)
        return staged
    }
}

/// A consent presenter with one scripted answer.
///
/// `confirmed` builds the token from the request itself, so consent always names the
/// provider and the bound policy version it was presented for. A presenter that invented
/// either would be testing the coordinator's binding check rather than the flow, and
/// `ShareExtensionIngestCoordinatorTests` already owns that.
final class FlowConsentPresenter: ShareConsentPresenting, @unchecked Sendable {
    enum Answer: String, Sendable, CaseIterable {
        case confirm
        case decline
        case cancel
    }

    private let answer: Answer
    private let lock = NSLock()
    private var presentations = 0

    init(_ answer: Answer = .confirm) {
        self.answer = answer
    }

    /// How many times the visible action was presented.
    var presentationCount: Int { lock.withLock { presentations } }

    func presentConsent(for request: ShareConsentRequest) async -> ShareConsentDecision {
        lock.withLock { presentations += 1 }
        switch answer {
        case .decline:
            return .declined
        case .cancel:
            return .cancelled
        case .confirm:
            guard let consent = ConfirmedConsent(
                provider: request.provider,
                extensionExecutionPolicyID: request.extensionExecutionPolicyID,
                confirmedAt: Date(timeIntervalSince1970: 1_700_000_000)
            ) else {
                // A one-item provider always yields a token, so this is unreachable. It is
                // a cancellation rather than a force-unwrap because inventing consent is
                // the one thing this seam must never do.
                return .cancelled
            }
            return .confirmed(consent)
        }
    }
}

/// Mints the Share route's candidate session identifiers a test names, in order.
///
/// The Share mirror of `ScriptedSessionIdentity`. Separate because the two ports are
/// separate: the Photos candidate is minted by the application-side ingest coordinator, and
/// the Share candidate is minted inside the extension while staging.
final class FlowCandidateSessions: CandidateSessionIdentifierSource, @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [AnalysisSessionID]
    private var issued: [AnalysisSessionID] = []

    init(_ identifiers: [AnalysisSessionID]) {
        self.remaining = identifiers
    }

    convenience init(_ raw: String...) {
        self.init(raw.map { Fixture.sessionID($0) })
    }

    /// Identifiers handed out, in order.
    var mintedIdentifiers: [AnalysisSessionID] { lock.withLock { issued } }

    func makeCandidateSessionID() -> AnalysisSessionID {
        lock.withLock {
            guard !remaining.isEmpty else {
                preconditionFailure("the extension staged more candidates than the test scripted")
            }
            let next = remaining.removeFirst()
            issued.append(next)
            return next
        }
    }
}

// MARK: - A store wrapper that can corrupt one published object

/// The App Group store, wrapped so one already-written object's *bytes* can be replaced
/// while its recorded measurements stay what publication wrote.
///
/// This is the only way to reach the claim's own recomputation. Every check before it —
/// schema, route, staging build, the recorded byte count — passes, the recopy completes, and
/// the digest the app-private store computed over the bytes that actually arrived disagrees
/// with the ticket's. That is the `handoff-error` cell task 10.13 reported as out of reach,
/// and it is reachable here only because the real transfer store and the real claim adapter
/// are both in the run.
///
/// A locked class rather than an actor, so a substitution can be installed synchronously
/// between the publication and the claim.
final class FlowAppGroupStore: EphemeralFileStoring, @unchecked Sendable {
    let underlying: InMemoryEphemeralStore

    private let lock = NSLock()
    private var substitutions: [EphemeralStorageKey: [UInt8]] = [:]

    init(_ underlying: InMemoryEphemeralStore) {
        self.underlying = underlying
    }

    /// Makes every later read of `key` return `bytes`, leaving the receipt alone.
    func substituteRead(_ bytes: [UInt8], for key: EphemeralStorageKey) {
        lock.withLock { substitutions[key] = bytes }
    }

    private func substitution(for key: EphemeralStorageKey) -> [UInt8]? {
        lock.withLock { substitutions[key] }
    }

    func create(
        in scope: EphemeralStorageScope,
        protection: FileProtectionLevel
    ) async throws(EphemeralStoreError) -> EphemeralStorageKey {
        try await underlying.create(in: scope, protection: protection)
    }

    func append(
        _ chunk: [UInt8],
        to key: EphemeralStorageKey
    ) async throws(EphemeralStoreError) {
        try await underlying.append(chunk, to: key)
    }

    func finalize(
        _ key: EphemeralStorageKey
    ) async throws(EphemeralStoreError) -> EphemeralWriteReceipt {
        try await underlying.finalize(key)
    }

    func read(_ key: EphemeralStorageKey) async throws(EphemeralStoreError) -> [UInt8] {
        if let substituted = substitution(for: key) { return substituted }
        return try await underlying.read(key)
    }

    func receipt(for key: EphemeralStorageKey) async -> EphemeralWriteReceipt? {
        await underlying.receipt(for: key)
    }

    func move(
        _ key: EphemeralStorageKey,
        to scope: EphemeralStorageScope
    ) async throws(EphemeralStoreError) {
        try await underlying.move(key, to: scope)
    }

    func keys(in scope: EphemeralStorageScope) async -> Set<EphemeralStorageKey> {
        await underlying.keys(in: scope)
    }

    func deleteAll(
        in scope: EphemeralStorageScope,
        reason: SessionCleanupReason
    ) async throws(EphemeralStoreError) -> EphemeralDeletionReceipt {
        try await underlying.deleteAll(in: scope, reason: reason)
    }

    func occupiedScopes() async -> Set<EphemeralStorageScope> {
        await underlying.occupiedScopes()
    }
}

// MARK: - Approved copy for the flow's own release

/// Failures this file's helpers report, so no helper force-unwraps.
enum FlowSetupFailure: Error {
    case noAcceptedIngest
    case noPublishedHandoff
    case noResumedSession
    case noSessionRan
    case noCommittedTerminal
    case bindingUnavailable
}

/// A copy catalogue covering exactly the surfaces one flow composition can reach.
///
/// **Why this exists rather than reusing the release's own catalogue.**
/// `CoordinatorSample.copyCatalog()` covers the unconditional surfaces plus the five enabled
/// provenance states, and nothing else. `ReachableCopySurfaces` additionally requires a
/// `combinedSummary(_:)` entry for every key a bound fusion rule can produce, so a
/// fusion-enabled release built by `CoordinatorRelease.build(provenance: true, fusion: true)`
/// **cannot bind approved copy from its own registered catalogue** — the bind fails
/// `missingSurfaces`. That is a gap in the shared fixture rather than a production defect,
/// and `aFusionEnabledReleasesOwnCatalogueCannotBindItsSummaries` pins it. Editing the
/// shared fixture is out of scope here, so this file builds the superset it needs: the same
/// compatibility identifier, its own artifact identifier, and one entry per reachable
/// surface.
enum FlowCopy {
    /// The catalogue identifier this file's superset carries.
    ///
    /// Deliberately *not* `CoordinatorSample.copyCatalogID`: two different values under one
    /// artifact identifier would be a fixture that lies about which record it is.
    static let catalogID = "catalog.verdict-copy.flow-superset"

    /// A catalogue covering every surface `capabilities` and `fusionRule` can reach.
    static func catalog(
        capabilities: ReleaseCapabilityManifest,
        fusionRule: EvidenceFusionRule?
    ) -> ApprovedVerdictCopyCatalog {
        let reachable = ReachableCopySurfaces(
            capabilities: capabilities,
            fusionRule: fusionRule
        )
        let entries = reachable.surfaces
            .sorted { $0.description < $1.description }
            .map { surface in
                VerdictCopyEntry(surface: surface, localizationKey: key(for: surface))
            }
        do {
            return try ApprovedVerdictCopyCatalog(
                id: CoordinatorSample.artifact(catalogID),
                schemaVersion: .v1,
                compatibilityID: CoordinatorSample.artifact(
                    CoordinatorSample.copyCompatibilityID
                ),
                languageTag: CoordinatorSample.text(
                    ApprovedVerdictCopyCatalog.requiredLanguageTag
                ),
                entries: entries,
                approval: CoordinatorSample.approval()
            )
        } catch {
            preconditionFailure("the flow copy catalogue must be schema-valid: \(error)")
        }
    }

    /// The approved key one surface is addressed by.
    ///
    /// A Combined Summary surface is addressed by the key it carries, so the fusion rule's
    /// own key is the one the catalogue approves. Every other surface follows
    /// `CoordinatorSample`'s scheme, so a key here is recognisable as the same synthetic
    /// family.
    static func key(for surface: VerdictCopySurface) -> ApprovedCopyKey {
        if case let .combinedSummary(declared) = surface { return declared }
        return CoordinatorSample.copyKey(
            "copy.surface." + surface.description.replacingOccurrences(of: "/", with: ".")
        )
    }
}

// MARK: - One end-to-end flow

/// One coherent release, both real ingest paths into it, the real coordinator, and the real
/// presentation projection.
///
/// The coordinator half is `MatrixHarness`, reused from task 10.13 rather than rebuilt: it
/// already wires one `CoordinatorRelease` to `AnalysisCoordinator` with a distinct-deadline
/// cleanup policy and an optional gate at any pipeline suspension, which is exactly what the
/// cancellation and immutability arms below need. What this type adds is everything on either
/// side of it — the two real ingest adapters, and approved copy plus a screen on the way out.
struct AnalysisFlow {
    let harness: MatrixHarness
    let composition: FlowComposition

    /// The App Group container the extension publishes into and the app claims from.
    ///
    /// A *different* store from the release's app-private session store, which is the
    /// arrangement the claim adapter documents: the verified bytes have to end up somewhere
    /// the Share Extension cannot reach. Keeping them separate is also what lets
    /// "the shared container keeps nothing afterwards" be a statement about one store.
    let appGroup: FlowAppGroupStore

    /// The in-memory store behind ``appGroup``, for inspecting unfinalized objects.
    let appGroupObjects: InMemoryEphemeralStore

    let transfers: SharedTransferStore
    let extensionGovernor: FakeResourceGovernor

    /// Reads the active bundle for a copy binding without touching the shared call log.
    ///
    /// Deliberately recorder-free and deliberately a second `AnalysisSessionBinder`: the
    /// coordinator releases its binding on the one end path, so a terminal outcome carries
    /// no `AnalysisSessionBinding` for a screen to resolve copy through. Binding the same
    /// accepted ingest through an independent binder over the same admission and the same
    /// active bundle reproduces that value. The completed arms assert the reproduction is
    /// exact, which is what keeps it honest for the non-evidence arms.
    let presentationBundles: StubModelBundleManager
    let presentationBinder: AnalysisSessionBinder

    var release: CoordinatorRelease { harness.release }
    var coordinator: AnalysisCoordinator { harness.coordinator }
    var recorder: PortCallRecorder { harness.recorder }
    var sessions: InMemoryEphemeralStore { harness.release.ephemeral }
    var configuration: ReleaseConfiguration { harness.release.admission.configuration }
    var context: ReleaseContext { harness.release.admission.context }

    /// Builds a flow over a fresh release.
    ///
    /// Every pipeline stub and the gate are forwarded to `MatrixHarness`, so an arm states
    /// only the thing it is about.
    static func make(
        _ composition: FlowComposition = .pixelOnly,
        validated: StubOutcome<ValidatedImage>? = nil,
        prepared: StubOutcome<ModelImageInput>? = nil,
        model: StubOutcome<BoundCoreMLModel>? = nil,
        logit: StubOutcome<RawLogit>? = nil,
        evidence: StubOutcome<PixelEvidence>? = nil,
        provenanceState: ProvenanceEvidence = .absent,
        gateAt gatePoint: PipelineGatePoint? = nil,
        sessionID: String = "session-0001"
    ) async throws -> AnalysisFlow {
        let release = try await CoordinatorRelease.build(
            provenance: composition.enablesProvenance,
            fusion: composition.enablesFusion
        )
        let harness = MatrixHarness.make(
            release: release,
            validated: validated,
            prepared: prepared,
            model: model,
            logit: logit,
            evidence: evidence,
            provenanceState: provenanceState,
            gateAt: gatePoint,
            sessionID: sessionID
        )

        let appGroupObjects = InMemoryEphemeralStore(clock: release.clock)
        let appGroup = FlowAppGroupStore(appGroupObjects)
        let transfers = SharedTransferStore(
            store: appGroup,
            lifecyclePolicy: release.admission.configuration.lifecyclePolicy,
            extensionPolicy: release.admission.configuration.extensionExecutionPolicy,
            buildID: release.admission.context.device.appBuild,
            clock: release.clock,
            // Four passes over the flow's payload, so the staging copy and the claim's
            // recopy are genuinely chunked rather than one write each.
            chunkSizeInBytes: 64
        )
        let presentationBundles = StubModelBundleManager()
        await presentationBundles.installAndActivate(release.bundle)
        return AnalysisFlow(
            harness: harness,
            composition: composition,
            appGroup: appGroup,
            appGroupObjects: appGroupObjects,
            transfers: transfers,
            extensionGovernor: FakeResourceGovernor(target: .shareExtension),
            presentationBundles: presentationBundles,
            presentationBinder: AnalysisSessionBinder(
                admission: release.admission,
                bundles: presentationBundles
            )
        )
    }

    // MARK: The Photos route

    /// Runs one real Photos ingest attempt through the real adapter and coordinator.
    func ingestPhotos(
        sessionID: String = "session-0001",
        bytes: [UInt8] = FlowSample.payload(),
        form: SuppliedRepresentationForm = .typedFileRepresentation,
        itemCount: Int = 1,
        providerFault: PhotosProviderFault? = nil,
        provider: FlowPhotosProvider? = nil
    ) async -> PhotosIngestOutcome {
        let access = provider
            ?? FlowPhotosProvider(bytes: bytes, form: form, failingWith: providerFault)
        let ingest = PhotosIngestCoordinator(
            importer: PhotosImportAdapter(
                access: access,
                store: sessions,
                sessionFileProtection: FlowSample.protection,
                chunkSizeInBytes: 64
            ),
            identity: ScriptedSessionIdentity(sessionID)
        )
        let outcome = await ingest.ingest(Fixture.selection(itemCount: itemCount))
        if let accepted = outcome.acceptedIngest {
            await release.deleter.registerLiveSession(accepted.sessionID)
        }
        return outcome
    }

    // MARK: The Share route

    /// Runs one real extension activation: consent, protected staging, atomic publication.
    func publishShareHandoff(
        sessionID: String = "session-0001",
        bytes: [UInt8] = FlowSample.payload(),
        consent: FlowConsentPresenter.Answer = .confirm,
        form: SharedRepresentationForm = .typedFileRepresentation,
        itemCount: Int = 1,
        providerFault: SharedItemProviderFault? = nil,
        presenter: FlowConsentPresenter? = nil,
        provider: FlowSharedItemProvider? = nil
    ) async throws -> ShareHandoffOutcome {
        let access = provider
            ?? FlowSharedItemProvider(bytes: bytes, form: form, failingWith: providerFault)
        guard let extensionIngest = ShareExtensionIngestCoordinator(
            access: access,
            consentPresenter: presenter ?? FlowConsentPresenter(consent),
            transfers: transfers,
            governor: extensionGovernor,
            budget: configuration.resourceBudgets.shareExtension,
            instruction: FlowSample.openInstruction,
            candidateSessions: FlowCandidateSessions(sessionID)
        ) else {
            throw FlowSetupFailure.bindingUnavailable
        }
        guard let provider = SharedItemProvider(
            token: ProviderToken(rawValue: 1),
            itemCount: itemCount,
            contentTypeHint: Fixture.contentTypeHint()
        ) else {
            throw FlowSetupFailure.bindingUnavailable
        }
        return await extensionIngest.handleActivation(
            ShareActivation(providers: [provider])
        )
    }

    /// The real claim adapter, for an arm that needs its full-fidelity outcome.
    ///
    /// `ShareTransferClaiming` narrows a mismatch to one `AnalysisFault`, which is all the
    /// application side needs and less than an audit wants: it cannot say *which*
    /// independently recheckable fact disagreed. This is the surface that can.
    var claimAdapter: ShareHandoffClaimAdapter {
        ShareHandoffClaimAdapter(
            transfers: transfers,
            sessionStore: sessions,
            sessionFileProtection: FlowSample.protection,
            chunkSizeInBytes: 64
        )
    }

    /// Runs the main app's real claim: atomic claim, recopy, second digest, then binding.
    func claimShareHandoff() async -> ShareHandoffIngestOutcome {
        let ingest = ShareHandoffIngestCoordinator(
            claiming: claimAdapter,
            bundles: release.bundles
        )
        let outcome = await ingest.resumePendingHandoff(context: context)
        if let resumed = outcome.resumedSession {
            await release.deleter.registerLiveSession(resumed.sessionID)
        }
        return outcome
    }

    // MARK: Either route

    /// The accepted ingest one route produces, or a setup failure.
    ///
    /// The single entry point every arm that is not *about* a refusal uses, so an arm reads
    /// the same on both routes and the route axis stays a parameter rather than two bodies.
    func acceptedIngest(
        _ route: FlowRoute,
        sessionID: String = "session-0001",
        bytes: [UInt8] = FlowSample.payload()
    ) async throws -> ImportedEncodedAsset {
        switch route {
        case .photos:
            let outcome = await ingestPhotos(sessionID: sessionID, bytes: bytes)
            guard let asset = outcome.acceptedIngest else {
                throw FlowSetupFailure.noAcceptedIngest
            }
            return asset
        case .claimedShare:
            let published = try await publishShareHandoff(
                sessionID: sessionID,
                bytes: bytes
            )
            guard case .published = published else {
                throw FlowSetupFailure.noPublishedHandoff
            }
            guard let resumed = await claimShareHandoff().resumedSession else {
                throw FlowSetupFailure.noResumedSession
            }
            return resumed.asset
        }
    }

    /// Ingests through `route` and runs the session to its single terminal outcome.
    func run(
        _ route: FlowRoute,
        sessionID: String = "session-0001",
        bytes: [UInt8] = FlowSample.payload()
    ) async throws -> CompletedAnalysisSession {
        let asset = try await acceptedIngest(route, sessionID: sessionID, bytes: bytes)
        guard let session = await coordinator.analyze(asset).completed else {
            throw FlowSetupFailure.noSessionRan
        }
        return session
    }

    // MARK: Presentation

    /// Approved copy bound to one session, through the flow's own superset catalogue.
    ///
    /// The snapshot is released again before returning. A binder refuses a second binding of
    /// a session it already holds, and a retry legitimately reuses the identifier, so holding
    /// the snapshot here would make the second attempt's copy unbindable for a reason that
    /// belongs to this helper rather than to the flow. Nothing is lost: the binding is a
    /// value, and `theReportsBindingIsTheReleasesActiveBundleSnapshot` is what establishes
    /// that it is the same value the report carries.
    func copyBinding(
        for asset: ImportedEncodedAsset
    ) async throws -> ApprovedCopyBinding {
        let bound = try await presentationBinder.bind(accepting: asset)
        await presentationBinder.release(asset.sessionID)
        return try ApprovedCopyBinding.bind(
            catalog: FlowCopy.catalog(
                capabilities: configuration.capabilityManifest,
                fusionRule: configuration.fusionRule
            ),
            session: bound.binding,
            capabilities: configuration.capabilityManifest,
            fusionRule: configuration.fusionRule
        )
    }

    /// The screen one terminal outcome projects to, through a real projector.
    ///
    /// The projector rather than the pure function, so the ordering watermark is exercised
    /// too: an arm that applies a superseded attempt afterwards gets the real refusal.
    @MainActor
    func project(
        _ session: CompletedAnalysisSession,
        copy: ApprovedCopyBinding,
        onto projector: AnalysisViewStateProjector
    ) throws -> ScreenProjection {
        try projector.apply(
            .session(
                AnalysisSessionSnapshot(
                    identity: SessionAttemptIdentity(
                        sessionID: session.sessionID,
                        attemptGeneration: session.identity.generation
                    ),
                    phase: .ended(session.outcome),
                    copy: copy
                )
            )
        )
    }

    // MARK: Inspection

    /// Objects the app-private store still holds for one session.
    func sessionObjectCount(_ sessionID: AnalysisSessionID) async -> Int {
        await sessions.keys(in: .session(sessionID)).count
    }

    /// Every scope the App Group container still holds an object in.
    func occupiedTransferScopes() async -> Set<EphemeralStorageScope> {
        await appGroupObjects.occupiedScopes()
    }
}

// MARK: - Synthetic scalars

/// The synthetic values this flow needs as arguments.
///
/// **No value here is an approved release value.** The payload size, the buffer size, the
/// protection level, and the instruction's copy key are scaffolding.
enum FlowSample {
    /// The data-protection level both ingest adapters request.
    ///
    /// `.complete` on purpose. Nothing here weakens a production fail-closed path to make a
    /// test pass: the store is in-memory, so the level travels with the write receipt and no
    /// file is created for a host to refuse. It is not an approved release value — the level
    /// a supported analysis lifecycle needs is a physical-device validation result.
    static let protection: FileProtectionLevel = .complete

    /// The "Open DefAIke" instruction, as an approved copy key rather than a sentence.
    static let openInstruction = ManualOpenInstruction(
        copyKey: CoordinatorSample.copyKey("copy.surface.share.manual-open-instruction")
    )

    /// A deterministic payload. Reproducible so a failure can be replayed.
    static func payload(count: Int = 256, seed: UInt8 = 1) -> [UInt8] {
        PortValue.bytes(count: count, seed: seed)
    }
}

// MARK: - Reading a projected screen

/// Case accessors this file's assertions need.
///
/// `AnalysisScreen` exposes the values a *view* reads — the report, the error category, the
/// progress, the recovery — and deliberately not the screen structs themselves, because a
/// view has no reason to switch on the family. An assertion does: "the completed screen's two
/// cards were both resolved" is a claim about the struct rather than about one of its fields.
/// These accessors are the test target's, and they add no capability to the module.
extension AnalysisScreen {
    var completedScreen: CompletedScreen? {
        guard case let .completed(screen) = self else { return nil }
        return screen
    }

    var errorScreen: AnalysisErrorScreen? {
        guard case let .error(screen) = self else { return nil }
        return screen
    }

    var activeScreen: ActiveScreen? {
        guard case let .active(screen) = self else { return nil }
        return screen
    }
}

// MARK: - One run, with its accepted ingest kept

/// One completed flow and the accepted ingest it ran over.
///
/// The asset is kept because most cross-module claims are comparisons *between* the two ends:
/// the status the route recorded against the status the report shows, and the session the
/// ingest created against the session the screen names. A helper that returned only the
/// terminal outcome would make every one of those unstatable.
struct FlowRun: Sendable {
    let asset: ImportedEncodedAsset
    let session: CompletedAnalysisSession

    var sessionID: AnalysisSessionID { asset.sessionID }
}

extension AnalysisFlow {
    /// Ingests through `route`, runs the session, and keeps both ends.
    func runFlow(
        _ route: FlowRoute,
        sessionID: String = "session-0001",
        bytes: [UInt8] = FlowSample.payload()
    ) async throws -> FlowRun {
        let asset = try await acceptedIngest(route, sessionID: sessionID, bytes: bytes)
        guard let session = await coordinator.analyze(asset).completed else {
            throw FlowSetupFailure.noSessionRan
        }
        return FlowRun(asset: asset, session: session)
    }

    /// Builds a flow over an already-constructed release.
    ///
    /// Needed by any arm whose programmed port outcome mentions the release itself — a model
    /// loader that has to answer with *this* release's bundle, for instance — because the
    /// value cannot be built before the release exists.
    static func make(
        over release: CoordinatorRelease,
        composition: FlowComposition,
        validated: StubOutcome<ValidatedImage>? = nil,
        prepared: StubOutcome<ModelImageInput>? = nil,
        model: StubOutcome<BoundCoreMLModel>? = nil,
        logit: StubOutcome<RawLogit>? = nil,
        evidence: StubOutcome<PixelEvidence>? = nil,
        provenanceState: ProvenanceEvidence = .absent,
        gateAt gatePoint: PipelineGatePoint? = nil,
        sessionID: String = "session-0001"
    ) async -> AnalysisFlow {
        let harness = MatrixHarness.make(
            release: release,
            validated: validated,
            prepared: prepared,
            model: model,
            logit: logit,
            evidence: evidence,
            provenanceState: provenanceState,
            gateAt: gatePoint,
            sessionID: sessionID
        )
        let appGroupObjects = InMemoryEphemeralStore(clock: release.clock)
        let appGroup = FlowAppGroupStore(appGroupObjects)
        let presentationBundles = StubModelBundleManager()
        await presentationBundles.installAndActivate(release.bundle)
        return AnalysisFlow(
            harness: harness,
            composition: composition,
            appGroup: appGroup,
            appGroupObjects: appGroupObjects,
            transfers: SharedTransferStore(
                store: appGroup,
                lifecyclePolicy: release.admission.configuration.lifecyclePolicy,
                extensionPolicy: release.admission.configuration.extensionExecutionPolicy,
                buildID: release.admission.context.device.appBuild,
                clock: release.clock,
                chunkSizeInBytes: 64
            ),
            extensionGovernor: FakeResourceGovernor(target: .shareExtension),
            presentationBundles: presentationBundles,
            presentationBinder: AnalysisSessionBinder(
                admission: release.admission,
                bundles: presentationBundles
            )
        )
    }

    /// The success values `MatrixHarness` would have used, for an arm that programs a
    /// sequence and has to supply them itself.
    var successfulValidatedImage: ValidatedImage {
        PortValue.validatedImage(
            sessionID: PortValue.sessionID("session-0001"),
            preprocessingContractID: CoordinatorSample.artifact(
                CoordinatorSample.preprocessingContractID
            )
        )
    }

    var successfulModelInput: ModelImageInput {
        PortValue.modelInput(
            sessionID: PortValue.sessionID("session-0001"),
            preprocessingContractID: CoordinatorSample.artifact(
                CoordinatorSample.preprocessingContractID
            )
        )
    }
}

/// The stamped success values, reachable before a flow exists.
enum FlowSuccess {
    static func validatedImage(sessionID: String = "session-0001") -> ValidatedImage {
        PortValue.validatedImage(
            sessionID: PortValue.sessionID(sessionID),
            preprocessingContractID: CoordinatorSample.artifact(
                CoordinatorSample.preprocessingContractID
            )
        )
    }

    static func modelInput(sessionID: String = "session-0001") -> ModelImageInput {
        PortValue.modelInput(
            sessionID: PortValue.sessionID(sessionID),
            preprocessingContractID: CoordinatorSample.artifact(
                CoordinatorSample.preprocessingContractID
            )
        )
    }
}
