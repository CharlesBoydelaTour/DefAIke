import DefAIkeDomain
import Foundation
import Testing

@testable import DefAIkeSharedTransfer

// Task 4.10: the Photos and Share adapters, wired together, against the real file system.
//
// The four design properties in this target quantify general claims over generated cases.
// This file is the example half: eleven named scenarios from the design's "Photos and Share
// Extension integration" test list, each pinned end to end against the real
// ``PhotosImportAdapter``, ``ShareExtensionIngestCoordinator``, ``SharedTransferStore``,
// ``ShareHandoffClaimAdapter``, ``EncodedAssetRetainer``, ``ProtectedEphemeralFileStore``,
// and ``TransferManifestCoding``. Nothing below models an adapter it is asserting about.
//
// | Scenario | What this file adds |
// |---|---|
// | provider temporary-file lifetime | the retained copy outlives the host's reclamation, and the host's file is returned byte-identical |
// | chunked copy | two *independent* chunkings — staging and the claim's recopy — reach one digest |
// | one-item rejection | the storage-level consequence: a refused count leaves the container with zero bytes |
// | picker cancellation | recovery: the same stores accept a fresh accepted ingest afterwards |
// | screenshots | cross-route parity, so no screenshot special case can exist on either route |
// | supported formats | both routes request one container set, and each supplied type retains identically on both |
// | consent ordering | one *interleaved* timeline across three independent seams, not three separate counts |
// | publication interruption | every write boundary of one publication, and the claim that follows each |
// | claim mismatch | the mismatches that surface `handoff-error`, plus the create-count nonoccurrence in app-private storage |
// | file protection | the staged level and the session level are sourced independently and neither falls back |
// | pending-slot recovery | the offer *and* its three resolutions: open, discard, expire |
//
// ## What is deliberately not repeated here
//
// Property 4 (`OneItemAndOneRoutePropertyTests`) quantifies the count and route gates,
// Property 5 (`HandoffSessionAndBytePreservationPropertyTests`) byte, digest, and status
// preservation across a completed handoff, Property 6
// (`HandoffMutationFailsClosedPropertyTests`) single-leaf mutation of a published handoff,
// and Property 7 (`DeclinedOrCancelledHandoffPropertyTests`) declines and pre-publication
// cancellations. `PhotosImportAdapterTests`, `ShareExtensionIngestCoordinatorTests`,
// `ShareHandoffClaimAdapterTests`, `SharedTransferStoreTests`, `EncodedAssetRetentionTests`,
// and `ProtectedEphemeralFileStoreTests` pin each adapter in isolation. This file asserts
// what only the composition can show, and its wrappers, doubles, and splice are its own.
//
// Decoding, classification, and `unsupported-static-format` are the Input Validator's and
// are unreachable from this module: ingest retains whatever arrived, which is why the
// "supported formats" scenario below is about *preservation* across the four requested
// containers rather than about acceptance.
//
// ## The data-protection level is pinned, and the reason is the host rather than the product
//
// Development hosts have been observed to accept a directory carrying the complete or
// complete-unless-open attribute and then refuse to create or open a file for writing
// inside it, failing with `EPERM`. A store rooted under such a directory reports
// `.storeUnavailable` for reasons that have nothing to do with ingest, so every scenario
// below that is not *about* protection pins the one level that is permitted either way.
//
// **No protection level in a test is an approved release value.** The level a supported
// analysis lifecycle needs is a physical-device validation result.
// `ProtectedEphemeralFileStoreTests` is where all three levels, the fail-closed refusal on a
// level that cannot be applied, and the verified read-back are pinned; nothing here weakens
// any of that. The file-protection scenario below deliberately does *not* pin its level: it
// asserts the exact requested level when the host can apply it, the fail-closed refusal when
// it cannot, and records a loud known issue naming the level in the second case. A host run
// is never Requirement 9.6 evidence either way, and `enforcesDataProtection` is asserted
// rather than assumed so that is visible in the run.
//
// ## Nothing here is an approved release value
//
// The Share Extension Resource Budget, the Extension Execution Policy, the Data Lifecycle
// Policy, the store capacity, the buffer sizes, the byte counts, the approved-copy key the
// manual instruction addresses, and every identifier are synthetic fixtures that exist so a
// port taking a signed artifact can be called at all. No number below may be copied into a
// shipping artifact. No result below is physical-device evidence.

extension Tag {
    /// Task 4.10's integration scenarios.
    ///
    /// Declared in this file rather than in a shared tag namespace, for the same reason each
    /// property file declares its own: a shared namespace would be a merge point between
    /// files written independently of each other.
    @Tag static var photosAndShareAdapterIntegration: Self
}

// MARK: - Synthetic scaffolding constants

/// The data-protection level the scenarios that are not *about* protection pin.
///
/// Structural scaffolding, not an approved value. See this file's header for the host reason
/// it is pinned rather than varied.
private let integrationProtection: FileProtectionLevel = .completeUntilFirstUserAuthentication

/// A payload comfortably below ``TransferManifestCoding/maximumEncodedByteCount``.
///
/// A structural test size, not a Resource Budget value.
private let smallPayloadByteCount = 256

/// A payload deliberately *above* ``TransferManifestCoding/maximumEncodedByteCount``.
///
/// Ready-slot resolution reads every object in the slot small enough to be a manifest
/// candidate, looking for the one that names itself. Above that ceiling the payload is
/// skipped, which is what makes "the claim read the payload once, and only for the reason
/// the arm is about" a statement about the claim rather than about resolution. It stays far
/// below the synthetic budget and capacity ceilings so no arm's outcome depends on a
/// resource breach.
private let largePayloadByteCount = 5_000

/// Buffer sizes spanning one byte per pass, an uneven partition, exactly the payload, and more
/// than the payload.
///
/// Structural I/O bounds, not approved Resource Budget values: they change how many passes a
/// copy takes, never how large a copy may be.
private let integrationChunkSizes = [
    1, 7, 64, smallPayloadByteCount, smallPayloadByteCount * 4,
]

/// The write boundaries one publication of a single-pass payload has.
///
/// In order: create the staged payload, append its one chunk, finalize it, create the record,
/// append the record, finalize the record, rename the payload into the ready slot, rename the
/// record in. The last rename is the commit, so refusing *any* of these eight must leave no
/// session. The uninterrupted control asserts the count, so a change that adds a boundary
/// makes this coverage visibly stale rather than silently incomplete.
private let publicationWriteBoundaryCount = 8

// MARK: - One interleaved timeline across three independent seams

/// A step one handoff took, in the order the production path actually took it.
///
/// The consent-ordering requirement is about an *interleaving*: nothing may read, copy, hash,
/// or write a byte until the visible action has been confirmed. Three separate call counts
/// cannot say that — each of them is consistent with any order — so the consent presenter,
/// the item-provider seam, and the store all append into one shared log and the assertion is
/// on indices within it.
private enum HandoffStep: String, Hashable, Sendable {
    /// The presenter was asked. Not the same as having shown the user anything.
    case consentAsked = "consent-asked"
    /// The visible consent action was displayed.
    case consentDisplayed = "consent-displayed"
    /// The presenter answered.
    case consentAnswered = "consent-answered"
    /// The host's provider was asked for a representation.
    case providerAsked = "provider-asked"
    /// The host lent its temporary file.
    case representationLent = "representation-lent"
    case objectCreated = "object-created"
    case chunkAppended = "chunk-appended"
    case objectFinalized = "object-finalized"
    case objectPromoted = "object-promoted"
    case objectRead = "object-read"
    case scopeDeleted = "scope-deleted"
}

/// The ordered log three independent doubles append into.
///
/// A locked class rather than an actor, so an assertion can read the order synchronously
/// without another suspension point in the middle of it.
private final class HandoffTimeline: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [HandoffStep] = []

    func record(_ step: HandoffStep) {
        lock.lock()
        steps.append(step)
        lock.unlock()
    }

    func recorded() -> [HandoffStep] {
        lock.lock()
        defer { lock.unlock() }
        return steps
    }

    /// Where `step` first appears, or `nil` when it never did.
    func firstIndex(of step: HandoffStep) -> Int? {
        recorded().firstIndex(of: step)
    }

    func contains(_ step: HandoffStep) -> Bool { firstIndex(of: step) != nil }

    /// Every step that touched a byte of the shared item, in order.
    ///
    /// Reading the host's file, copying it, hashing it, and writing it all appear here, so
    /// "no byte was touched before consent" is one comparison rather than a list of them.
    func byteTouchingSteps() -> [HandoffStep] {
        recorded().filter {
            switch $0 {
            case .providerAsked, .representationLent, .objectCreated, .chunkAppended,
                 .objectFinalized, .objectPromoted, .objectRead:
                true
            case .consentAsked, .consentDisplayed, .consentAnswered, .scopeDeleted:
                false
            }
        }
    }
}

/// A consent presenter that writes into the shared timeline and separates "was asked" from
/// "showed the user something".
private actor TimelineConsentPresenter: ShareConsentPresenting {
    /// What this presenter does when it is asked.
    enum Answer: String, Hashable, Sendable, CaseIterable {
        /// Answer `cancelled` without ever displaying the action.
        case cancelWithoutDisplaying = "cancel-without-displaying"
        /// Display the action, then decline.
        case declineAfterDisplaying = "decline-after-displaying"
        /// Display the action, then cancel.
        case cancelAfterDisplaying = "cancel-after-displaying"
        /// Display the action, then confirm for the provider and policy it was shown.
        case confirmAfterDisplaying = "confirm-after-displaying"
    }

    private let answer: Answer
    private let timeline: HandoffTimeline

    /// Requests this presenter was asked to answer, in order.
    private(set) var askedRequests: [ShareConsentRequest] = []

    /// Requests whose action was actually displayed. Empty means the user saw nothing.
    private(set) var displayedRequests: [ShareConsentRequest] = []

    init(_ answer: Answer, timeline: HandoffTimeline) {
        self.answer = answer
        self.timeline = timeline
    }

    func presentConsent(for request: ShareConsentRequest) async -> ShareConsentDecision {
        askedRequests.append(request)
        timeline.record(.consentAsked)
        switch answer {
        case .cancelWithoutDisplaying:
            timeline.record(.consentAnswered)
            return .cancelled
        case .declineAfterDisplaying:
            displayedRequests.append(request)
            timeline.record(.consentDisplayed)
            timeline.record(.consentAnswered)
            return .declined
        case .cancelAfterDisplaying:
            displayedRequests.append(request)
            timeline.record(.consentDisplayed)
            timeline.record(.consentAnswered)
            return .cancelled
        case .confirmAfterDisplaying:
            displayedRequests.append(request)
            timeline.record(.consentDisplayed)
            timeline.record(.consentAnswered)
            return .confirmed(
                Sample.consent(
                    for: request.provider,
                    policyID: request.extensionExecutionPolicyID
                )
            )
        }
    }
}

/// An item-provider seam whose access window really closes and which logs into the timeline.
///
/// The lent file is written for real, lent for exactly the length of the consume closure, and
/// reclaimed the moment the closure returns unless an arm asks to keep it. Keeping it is what
/// lets an arm read the host's representation back and show it was never written to.
private actor TimelineSharedItemAccess: SharedItemRepresentationAccess {
    private let bytes: [UInt8]
    private let form: SharedRepresentationForm
    private let timeline: HandoffTimeline
    private let reclaimsRepresentation: Bool

    /// Providers this seam was asked about, in order. Empty means the host was never touched.
    private(set) var requestedProviders: [SharedItemProvider] = []

    /// Files this seam lent, so an arm can read or remove them afterwards.
    private(set) var lentFiles: [URL] = []

    init(
        bytes: [UInt8],
        form: SharedRepresentationForm = .typedFileRepresentation,
        timeline: HandoffTimeline,
        reclaimsRepresentation: Bool = true
    ) {
        self.bytes = bytes
        self.form = form
        self.timeline = timeline
        self.reclaimsRepresentation = reclaimsRepresentation
    }

    func withRepresentation(
        of provider: SharedItemProvider,
        consume: @Sendable (BorrowedSharedRepresentation) async -> StagedRepresentation
    ) async throws(SharedItemProviderFault) -> StagedRepresentation {
        requestedProviders.append(provider)
        timeline.record(.providerAsked)
        guard let fileURL = try? Self.writeTemporaryRepresentation(bytes) else {
            throw .transferFailed
        }
        lentFiles.append(fileURL)
        timeline.record(.representationLent)
        let outcome = await consume(
            BorrowedSharedRepresentation(fileURL: fileURL, form: form)
        )
        // The window closes here, exactly as a framework provider's does.
        if reclaimsRepresentation {
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        }
        return outcome
    }

    /// Reclaims anything this seam lent and did not already reclaim.
    func reclaimLentFiles() {
        for file in lentFiles {
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
    }

    private static func writeTemporaryRepresentation(_ bytes: [UInt8]) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(
                path: "defaike-t410-host-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        // A host-shaped name, so nothing downstream can be reading the extension.
        let fileURL = directory.appending(path: "representation", directoryHint: .notDirectory)
        try Data(bytes).write(to: fileURL)
        return fileURL
    }
}

// MARK: - Cancelling a copy while it is in flight

/// Cancels the task a streaming copy runs in, once a chosen number of chunks have landed.
///
/// ``EncodedAssetRetainer`` checks `Task.isCancelled` at every chunk boundary, which is the
/// only cancellation seam the copy has, so a genuinely mid-copy cancellation has to arrive as
/// a real task cancellation rather than as a store fault. Two pieces make that deterministic
/// with no sleep and no poll: the copy suspends in ``waitUntilArmed()`` at its first store
/// call, so it cannot race past the trigger before the trigger is wired, and ``noteAppend()``
/// fires the cancellation from inside the store once the chosen chunk has landed.
///
/// Nothing here blocks waiting for the trigger to be reached, so a copy that stopped earlier
/// than the arm expected fails an assertion instead of hanging the run.
private actor CopyProgressGate {
    /// Chunks to let through before cancelling.
    let cancelAfterAppendCount: Int

    private var cancellation: (@Sendable () -> Void)?
    private var isArmed = false
    private var gate: CheckedContinuation<Void, Never>?
    private var appendsSeen = 0
    private var appendsWhenCancelled: Int?

    init(cancelAfterAppendCount: Int) {
        self.cancelAfterAppendCount = cancelAfterAppendCount
    }

    /// Wires the cancellation and lets the gated copy start.
    func arm(_ cancellation: @escaping @Sendable () -> Void) {
        self.cancellation = cancellation
        isArmed = true
        if cancelAfterAppendCount == 0 { fire() }
        gate?.resume()
        gate = nil
    }

    /// Suspends the copy until ``arm(_:)`` has run. Returns immediately if it already has.
    func waitUntilArmed() async {
        if isArmed { return }
        await withCheckedContinuation { continuation in gate = continuation }
    }

    /// Counts one chunk that reached storage, and cancels once the trigger is due.
    func noteAppend() {
        appendsSeen += 1
        if cancelAfterAppendCount > 0, appendsSeen == cancelAfterAppendCount { fire() }
    }

    /// Chunks that landed in total, so an arm can see the copy stopped rather than finished.
    var appendsObserved: Int { appendsSeen }

    /// Chunks that had landed when cancellation was requested, or `nil` if it never was.
    var appendsBeforeCancellation: Int? { appendsWhenCancelled }

    private func fire() {
        guard appendsWhenCancelled == nil else { return }
        appendsWhenCancelled = appendsSeen
        cancellation?()
    }
}

// MARK: - The real store, wrapped

/// The real protected store, wrapped so every write boundary is observable, one chosen
/// boundary can be refused, and one key's bytes can be made to disagree with its receipt.
///
/// A wrapper rather than a double: the object on disk, its measurements, its protection
/// level, its atomic rename, and its removals are all the real ones. Three things are added,
/// and each is a scenario this file could not otherwise reach:
///
///   * **A write-boundary ledger.** For a property built out of absences the ledger is the
///     only thing that separates "nothing was left behind" from "nothing was attempted", and
///     it is what lets the chunked-copy scenario show the chunking actually happened.
///   * **One refused mutating operation.** Publication is a fixed sequence of creates,
///     appends, finalizes, and renames; refusing the *n*-th one is an interruption at that
///     write boundary. `deleteAll` is deliberately never refused: it is the cleanup path
///     every arm then asserts on, and refusing it would measure the wrapper rather than the
///     adapter.
///   * **One substituted read.** The recorded measurements stay what the publishing side
///     wrote while the bytes become what the claiming side finds, which is the only way to
///     reach the claim's *own* recomputation rather than the store's resolution check.
///
/// A locked class rather than an actor, so the ledger can be read synchronously from the
/// middle of an assertion.
private final class IngestLedgerStore: EphemeralFileStoring, @unchecked Sendable {
    /// The real store. Held so an arm can reach the members the port does not expose.
    let underlying: ProtectedEphemeralFileStore

    private let timeline: HandoffTimeline?
    private let gate: CopyProgressGate?

    /// Which mutating operation, counted from zero, is refused. `nil` refuses none.
    private let refusedMutatingOperationIndex: Int?

    private let lock = NSLock()
    private var mutatingOperations = 0
    private var createdKeys: [EphemeralStorageKey] = []
    private var appendedLengthsByKey: [EphemeralStorageKey: [Int]] = [:]
    private var finalizedKeys: [EphemeralStorageKey] = []
    private var readKeys: [EphemeralStorageKey] = []
    private var promotedKeys: [EphemeralStorageKey] = []
    private var deletedScopes: [EphemeralStorageScope] = []
    private var substitutions: [EphemeralStorageKey: [UInt8]] = [:]

    init(
        _ underlying: ProtectedEphemeralFileStore,
        timeline: HandoffTimeline? = nil,
        gate: CopyProgressGate? = nil,
        refusingMutatingOperationAtIndex refusedMutatingOperationIndex: Int? = nil
    ) {
        self.underlying = underlying
        self.timeline = timeline
        self.gate = gate
        self.refusedMutatingOperationIndex = refusedMutatingOperationIndex
    }

    // MARK: The ledger

    /// Creates, appends, finalizes, and renames attempted, in total.
    ///
    /// The number of write boundaries one operation has. Asserted by the interruption
    /// scenario's control so a change that adds a boundary makes its coverage visibly stale
    /// rather than silently incomplete.
    func mutatingOperationCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return mutatingOperations
    }

    /// Objects created, in order. For a publication the payload is first and the manifest
    /// second.
    func createdObjectKeys() -> [EphemeralStorageKey] {
        lock.lock()
        defer { lock.unlock() }
        return createdKeys
    }

    /// Chunk lengths appended to `key`, in order. Its count is the number of copy passes.
    func appendedLengths(to key: EphemeralStorageKey) -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        return appendedLengthsByKey[key] ?? []
    }

    func finalizedObjectKeys() -> [EphemeralStorageKey] {
        lock.lock()
        defer { lock.unlock() }
        return finalizedKeys
    }

    /// Reads attempted against `key`. Zero means the claim never handled those bytes.
    func readCount(of key: EphemeralStorageKey) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return readKeys.filter { $0 == key }.count
    }

    func promotionCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return promotedKeys.count
    }

    func scopesDeleted() -> Set<EphemeralStorageScope> {
        lock.lock()
        defer { lock.unlock() }
        return Set(deletedScopes)
    }

    /// Forgets the ledger without touching a byte on disk and without dropping a
    /// substitution.
    ///
    /// Called between a publication and the claim that follows it, so the claim's counts
    /// describe the claim alone.
    func forgetObservations() {
        lock.lock()
        mutatingOperations = 0
        createdKeys = []
        appendedLengthsByKey = [:]
        finalizedKeys = []
        readKeys = []
        promotedKeys = []
        deletedScopes = []
        lock.unlock()
    }

    /// Makes every later read of `key` return `bytes` instead of what is on disk.
    ///
    /// The receipt is deliberately left alone: the asymmetry is the point.
    func substituteRead(_ bytes: [UInt8], for key: EphemeralStorageKey) {
        lock.lock()
        substitutions[key] = bytes
        lock.unlock()
    }

    // MARK: Recording
    //
    // Each recorder is a separate synchronous method: `NSLock` is unavailable from an
    // asynchronous context, and the port members below are `async`.

    /// Claims the next mutating-operation slot and reports whether it is the refused one.
    private func claimMutatingOperation() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let index = mutatingOperations
        mutatingOperations += 1
        return index == refusedMutatingOperationIndex
    }

    private func noteCreate(_ key: EphemeralStorageKey) {
        lock.lock()
        createdKeys.append(key)
        lock.unlock()
        timeline?.record(.objectCreated)
    }

    private func noteAppend(_ length: Int, to key: EphemeralStorageKey) {
        lock.lock()
        appendedLengthsByKey[key, default: []].append(length)
        lock.unlock()
        timeline?.record(.chunkAppended)
    }

    private func noteFinalize(_ key: EphemeralStorageKey) {
        lock.lock()
        finalizedKeys.append(key)
        lock.unlock()
        timeline?.record(.objectFinalized)
    }

    /// Counts the read and returns the substituted bytes, if any.
    private func noteRead(_ key: EphemeralStorageKey) -> [UInt8]? {
        lock.lock()
        readKeys.append(key)
        let substituted = substitutions[key]
        lock.unlock()
        timeline?.record(.objectRead)
        return substituted
    }

    private func notePromotion(_ key: EphemeralStorageKey) {
        lock.lock()
        promotedKeys.append(key)
        lock.unlock()
        timeline?.record(.objectPromoted)
    }

    private func noteDeletion(_ scope: EphemeralStorageScope) {
        lock.lock()
        deletedScopes.append(scope)
        lock.unlock()
        timeline?.record(.scopeDeleted)
    }

    // MARK: EphemeralFileStoring

    func create(
        in scope: EphemeralStorageScope,
        protection: FileProtectionLevel
    ) async throws(EphemeralStoreError) -> EphemeralStorageKey {
        // The copy suspends here until an arm that cancels mid-copy has wired its trigger.
        await gate?.waitUntilArmed()
        guard !claimMutatingOperation() else { throw .storeUnavailable }
        let key = try await underlying.create(in: scope, protection: protection)
        noteCreate(key)
        return key
    }

    func append(
        _ chunk: [UInt8],
        to key: EphemeralStorageKey
    ) async throws(EphemeralStoreError) {
        guard !claimMutatingOperation() else { throw .storeUnavailable }
        try await underlying.append(chunk, to: key)
        // Counted after the call, so a length here is a length that reached storage.
        noteAppend(chunk.count, to: key)
        // The cancellation lands between two chunks, which is where the retainer looks.
        await gate?.noteAppend()
    }

    func finalize(
        _ key: EphemeralStorageKey
    ) async throws(EphemeralStoreError) -> EphemeralWriteReceipt {
        guard !claimMutatingOperation() else { throw .storeUnavailable }
        let receipt = try await underlying.finalize(key)
        noteFinalize(key)
        return receipt
    }

    func read(_ key: EphemeralStorageKey) async throws(EphemeralStoreError) -> [UInt8] {
        // Counted before the call, so a read that failed is still a read that happened.
        if let substituted = noteRead(key) { return substituted }
        return try await underlying.read(key)
    }

    func receipt(for key: EphemeralStorageKey) async -> EphemeralWriteReceipt? {
        await underlying.receipt(for: key)
    }

    func move(
        _ key: EphemeralStorageKey,
        to scope: EphemeralStorageScope
    ) async throws(EphemeralStoreError) {
        guard !claimMutatingOperation() else { throw .storeUnavailable }
        try await underlying.move(key, to: scope)
        notePromotion(key)
    }

    func keys(in scope: EphemeralStorageScope) async -> Set<EphemeralStorageKey> {
        await underlying.keys(in: scope)
    }

    func deleteAll(
        in scope: EphemeralStorageScope,
        reason: SessionCleanupReason
    ) async throws(EphemeralStoreError) -> EphemeralDeletionReceipt {
        // Never refused, and never counted as a write boundary: this is the cleanup path
        // every interruption arm then asserts on.
        noteDeletion(scope)
        return try await underlying.deleteAll(in: scope, reason: reason)
    }

    func occupiedScopes() async -> Set<EphemeralStorageScope> {
        await underlying.occupiedScopes()
    }
}

// MARK: - Changing one member of a published record

/// Replaces the value of one member of an encoded transfer record, leaving every other byte
/// untouched.
///
/// A text splice rather than a decode-and-re-encode round trip. ``TransferManifestCoding``
/// sets no date strategy on purpose, so `createdAt` crosses as the domain's own exact `Date`
/// representation; re-serializing the record to change one member would perturb a value no
/// arm here is about, and the arm could then not say whether a refusal came from the member
/// it changed.
///
/// **Uniqueness is the safety property.** A member is spliced only when its name occurs
/// exactly once in the whole record, so an envelope member and a ticket member that share a
/// name — `schemaVersion` does — are refused rather than both changed. That refusal is a
/// `nil` return the arms `#require`, which means a later schema that duplicates a member name
/// fails a test rather than silently splicing the wrong occurrence. The arms below
/// consequently never touch `schemaVersion`; the schema-identity family is Property 6's.
///
/// Every refusal returns `nil` rather than the unchanged bytes, so an arm cannot assert
/// against a record it did not actually change.
private enum RecordMemberSplice {
    struct Spliced {
        let bytes: [UInt8]
        let previousValue: String
    }

    /// The record with the string-valued `member` set to `replacement`.
    static func settingString(
        _ member: String,
        to replacement: String,
        in bytes: [UInt8]
    ) -> Spliced? {
        // Written into a JSON string body verbatim, so a replacement needing an escape is
        // refused rather than silently producing a malformed record.
        guard !replacement.contains("\""), !replacement.contains("\\") else { return nil }
        guard let text = String(bytes: bytes, encoding: .utf8) else { return nil }
        guard let found = soleOccurrence(of: "\"\(member)\":\"", in: text) else { return nil }
        let valueStart = found.upperBound
        guard let valueEnd = closingQuote(in: text, from: valueStart) else { return nil }
        return replacing(valueStart..<valueEnd, with: replacement, in: text)
    }

    /// The record with the number-valued `member` set to `replacement`.
    static func settingNumber(
        _ member: String,
        to replacement: String,
        in bytes: [UInt8]
    ) -> Spliced? {
        guard let text = String(bytes: bytes, encoding: .utf8) else { return nil }
        guard let found = soleOccurrence(of: "\"\(member)\":", in: text) else { return nil }
        let valueStart = found.upperBound
        // A quote here would mean the member is string-valued, which is a different splice
        // and is refused rather than producing a malformed number.
        guard valueStart < text.endIndex, text[valueStart] != "\"" else { return nil }
        var index = valueStart
        while index < text.endIndex, text[index] != ",", text[index] != "}" {
            index = text.index(after: index)
        }
        return replacing(valueStart..<index, with: replacement, in: text)
    }

    /// The sole occurrence of `needle`, or `nil` when it is absent or repeated.
    private static func soleOccurrence(
        of needle: String,
        in text: String
    ) -> Range<String.Index>? {
        guard let found = text.range(of: needle, options: .literal),
            text.range(
                of: needle,
                options: .literal,
                range: found.upperBound..<text.endIndex
            ) == nil
        else { return nil }
        return found
    }

    /// Replaces `range`, refusing a replacement that would leave the record unchanged.
    private static func replacing(
        _ range: Range<String.Index>,
        with replacement: String,
        in text: String
    ) -> Spliced? {
        let previous = String(text[range])
        guard previous != replacement else { return nil }
        var mutated = text
        mutated.replaceSubrange(range, with: replacement)
        return Spliced(bytes: Array(mutated.utf8), previousValue: previous)
    }

    /// The index of the quote that closes the string body starting at `start`.
    private static func closingQuote(in text: String, from start: String.Index) -> String.Index? {
        var index = start
        while index < text.endIndex {
            switch text[index] {
            case "\\":
                index = text.index(after: index)
                guard index < text.endIndex else { return nil }
            case "\"":
                return index
            default:
                break
            }
            index = text.index(after: index)
        }
        return nil
    }
}

// MARK: - Scenario vocabularies

/// A supplied representation type, including the two a screenshot arrives as.
///
/// The four requested containers, one container the request does not name, and no hint at
/// all. Ingest never classifies, so all six are retained; the point of walking them is that
/// the retained bytes, count, digest, status, and basis are identical for every one of them
/// and on both routes (Requirements 2.14 through 2.17).
private enum SuppliedType: String, Hashable, Sendable, CaseIterable {
    case jpegPhoto = "public.jpeg"
    case pngScreenshot = "public.png"
    case heicScreenshot = "public.heic"
    case heifPhoto = "public.heif"
    /// A container the typed request does not ask for. Still retained; the Input Validator
    /// decides whether it is analyzable, against the actual bytes.
    case unrequestedContainer = "public.tiff"
    /// The provider supplied no hint at all.
    case noHint = ""

    var hint: ContentTypeHint? {
        self == .noHint ? nil : Sample.contentTypeHint(rawValue)
    }

    /// Whether this is one of the types a photo-library screenshot arrives as.
    var isScreenshotContainer: Bool {
        self == .pngScreenshot || self == .heicScreenshot
    }
}

/// One way a published handoff can disagree with what the claiming process measures.
///
/// Exactly the mismatches that surface `handoff-error`. The families whose disposition is a
/// discard rather than a failed session — a single-field `preservationStatus` change, and
/// either schema version — are Property 6's subject and are reported there as an open
/// spec-versus-implementation tension; the one such family exercised here is covered by its
/// own test below, which asserts the *observed* disposition and names the gap.
private enum ClaimMismatch: String, Hashable, Sendable, CaseIterable {
    /// One payload byte changed after publication, with the length left alone, so only a
    /// digest recomputed over the recopied bytes can catch it.
    case payloadByteFlipped = "payload-byte-flipped"

    /// The payload shortened, with the object's recorded measurements left as written.
    case payloadTruncated = "payload-truncated"

    /// The record's `byteCount` changed to another positive number.
    case ticketByteCount = "ticket-byte-count"

    /// The record's `sha256` changed to another canonical digest.
    case ticketDigest = "ticket-digest"

    /// The build recorded as having staged the transfer changed to another build.
    case ticketStagingBuild = "ticket-staging-build"

    /// The record left alone, and the claim presented by a different build. The same
    /// disagreement seen from the other end.
    case claimingBuildDiffers = "claiming-build-differs"

    /// How many objects the app-private session store is expected to be asked to create.
    ///
    /// The recopy is where an accepted ingest would come from, so a mismatch refused before
    /// it leaves app-private storage untouched — which is the ordering Requirements 2.19 and
    /// 11.13 are about. A flipped byte is detectable only *from* the recopy's own
    /// measurements, so that one arm creates an object and then has it removed.
    var expectedSessionCreateCount: Int {
        self == .payloadByteFlipped ? 1 : 0
    }
}

// MARK: - The suite

@Suite(
    "Photos and Share adapter integration",
    .tags(.photosAndShareAdapterIntegration)
)
struct PhotosAndShareAdapterIntegrationTests {

    // MARK: - Scaffolding

    /// The two roots one handoff spans: the shared container and the app's own.
    ///
    /// Separate roots, because the whole point of the claim is that the verified bytes end up
    /// somewhere the Share Extension cannot reach. A single root would let an arm pass while
    /// the bytes never left the shared container.
    private struct Roots {
        let appGroup: URL
        let appPrivate: URL
    }

    /// Runs `body` with two fresh empty roots and removes them afterwards.
    private func withPairedRoots<T>(_ body: (Roots) async throws -> T) async throws -> T {
        try await withTemporaryRoot { root in
            try await body(
                Roots(
                    appGroup: root.appending(path: "appgroup", directoryHint: .isDirectory),
                    appPrivate: root.appending(path: "private", directoryHint: .isDirectory)
                )
            )
        }
    }

    private func makeFileStore(
        root: URL,
        capacityInBytes: UInt64 = testCapacityInBytes,
        containerProtection: FileProtectionLevel = integrationProtection,
        protection: any DataProtectionApplying = PlatformDataProtection()
    ) -> ProtectedEphemeralFileStore {
        ProtectedEphemeralFileStore(
            configuration: .test(
                root: root,
                capacityInBytes: capacityInBytes,
                containerProtection: containerProtection
            ),
            protection: protection,
            clock: FixedClock(fixtureNow)
        )
    }

    private func makePhotosAdapter(
        access: any PhotosRepresentationAccess,
        store: any EphemeralFileStoring,
        sessionFileProtection: FileProtectionLevel = integrationProtection,
        chunkSizeInBytes: Int = 64
    ) -> PhotosImportAdapter {
        PhotosImportAdapter(
            access: access,
            store: store,
            sessionFileProtection: sessionFileProtection,
            chunkSizeInBytes: chunkSizeInBytes
        )
    }

    private func makeCoordinator(
        access: any SharedItemRepresentationAccess,
        consentPresenter: any ShareConsentPresenting,
        transfers: SharedTransferStore,
        governor: any ResourceGoverning = ProgrammedShareResourceGovernor(),
        budget: ResourceBudget = Sample.shareBudget(),
        instruction: ManualOpenInstruction = Sample.manualInstruction(),
        candidateSessions: any CandidateSessionIdentifierSource =
            FixedCandidateSessionIdentifierSource()
    ) throws -> ShareExtensionIngestCoordinator {
        try #require(
            ShareExtensionIngestCoordinator(
                access: access,
                consentPresenter: consentPresenter,
                transfers: transfers,
                governor: governor,
                budget: budget,
                instruction: instruction,
                candidateSessions: candidateSessions
            )
        )
    }

    private func makeClaimAdapter(
        appGroupStore: any EphemeralFileStoring,
        sessionStore: any EphemeralFileStoring,
        sessionFileProtection: FileProtectionLevel = integrationProtection,
        stagedFileProtection: FileProtectionLevel = integrationProtection,
        lifecyclePolicy: DataLifecyclePolicy = Sample.lifecyclePolicy(),
        buildID: AppBuildID = Sample.buildID(),
        now: Date = fixtureNow,
        chunkSizeInBytes: Int = 64
    ) -> ShareHandoffClaimAdapter {
        ShareHandoffClaimAdapter(
            transfers: SharedTransferStore.test(
                over: appGroupStore,
                lifecyclePolicy: lifecyclePolicy,
                extensionPolicy: Sample.extensionPolicy(
                    stagedFileProtection: stagedFileProtection
                ),
                buildID: buildID,
                now: now,
                chunkSizeInBytes: chunkSizeInBytes
            ),
            sessionStore: sessionStore,
            sessionFileProtection: sessionFileProtection,
            chunkSizeInBytes: chunkSizeInBytes
        )
    }

    /// The extension side of the transfer store, with this file's pinned protection level.
    private func makeExtensionSide(
        over store: any EphemeralFileStoring,
        stagedFileProtection: FileProtectionLevel = integrationProtection,
        lifecyclePolicy: DataLifecyclePolicy = Sample.lifecyclePolicy(),
        buildID: AppBuildID = Sample.buildID(),
        now: Date = fixtureNow,
        chunkSizeInBytes: Int = 64
    ) -> SharedTransferStore {
        SharedTransferStore.test(
            over: store,
            lifecyclePolicy: lifecyclePolicy,
            extensionPolicy: Sample.extensionPolicy(
                stagedFileProtection: stagedFileProtection
            ),
            buildID: buildID,
            now: now,
            chunkSizeInBytes: chunkSizeInBytes
        )
    }

    /// Transfer scopes the shared container still owns, in any state.
    private func transferScopes(
        of store: ProtectedEphemeralFileStore
    ) async -> Set<EphemeralStorageScope> {
        await store.occupiedScopes().filter {
            if case .transfer = $0 { return true }
            return false
        }
    }

    /// Session scopes the app-private store still owns.
    private func sessionScopes(
        of store: ProtectedEphemeralFileStore
    ) async -> Set<EphemeralStorageScope> {
        await store.occupiedScopes().filter {
            if case .session = $0 { return true }
            return false
        }
    }

    /// The single object one session scope holds, with its receipt and its bytes.
    private func soleSessionObject(
        of sessionID: AnalysisSessionID,
        in store: ProtectedEphemeralFileStore
    ) async throws -> (receipt: EphemeralWriteReceipt, bytes: [UInt8]) {
        let keys = await store.keys(in: .session(sessionID))
        let key = try #require(keys.count == 1 ? keys.first : nil)
        let receipt = try #require(await store.receipt(for: key))
        return (receipt, try await store.read(key))
    }

    /// The published record in one transfer's ready slot, found the way production finds it.
    ///
    /// Self-naming rather than content sniffing, exactly as ``SharedTransferStore`` does: a
    /// candidate is the manifest only when it decodes as one whose `manifestKey` is the key it
    /// was read from. Read through the underlying store so the ledger's counts stay the
    /// claim's own.
    private func locatePublishedRecord(
        of transferID: ShareTransferID,
        in store: IngestLedgerStore
    ) async throws -> (key: EphemeralStorageKey, manifest: TransferManifest, bytes: [UInt8]) {
        let scope = EphemeralStorageScope.transfer(transferID, .ready)
        let keys = await store.underlying.keys(in: scope)
        for key in keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let receipt = await store.underlying.receipt(for: key),
                receipt.byteCount <= TransferManifestCoding.maximumEncodedByteCount
            else { continue }
            let bytes = try await store.underlying.read(key)
            guard let manifest = try? TransferManifestCoding.decode(bytes),
                manifest.manifestKey == key
            else { continue }
            return (key, manifest, bytes)
        }
        throw IntegrationScaffoldingFault.noPublishedRecord(transferID)
    }

    /// Asserts `fault` is exactly one `handoff-error` at the handoff stage and nothing else.
    ///
    /// Compared against the single exact value *and* against every other member of the closed
    /// ``AnalysisError`` vocabulary and against cancellation, so a mismatch cannot acquire
    /// `resource-limit`, `decoding-error`, or a cancellation on its way out
    /// (Requirements 2.19, 11.13, and 11.17).
    private func expectExactlyHandoffError(
        _ fault: AnalysisFault,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(
            fault == .analysis(.handoffError, stage: .handoffVerification),
            sourceLocation: sourceLocation
        )
        #expect(!fault.isCancelled, sourceLocation: sourceLocation)
        #expect(fault.analysisError == .handoffError, sourceLocation: sourceLocation)
        for other in AnalysisError.allCases where other != .handoffError {
            #expect(fault.analysisError != other, sourceLocation: sourceLocation)
        }
        for stage in AnalysisStage.allCases where stage != .handoffVerification {
            #expect(fault.stage != stage, sourceLocation: sourceLocation)
        }
    }

    // MARK: - Scenario 1: provider temporary-file lifetime

    /// **Validates: Requirements 2.9, 2.10, 2.11, 2.12, 9.5**
    @Test("A Photos copy outlives the provider reclaiming its temporary representation")
    func photosCopyOutlivesProviderReclamation() async throws {
        try await withTemporaryRoot { root in
            let store = makeFileStore(root: root)
            let session = Sample.sessionID("session-t410-photos-lifetime")
            let bytes = Sample.bytes(count: largePayloadByteCount, seed: 11)
            // The provider keeps its lent file past the window, so the host's representation
            // can be read back and compared. A framework provider reclaims immediately; the
            // reclaiming case is the second half of this arm.
            let access = FakePhotosAccess.lending(bytes, reclaimsRepresentation: false)

            let asset = try await makePhotosAdapter(access: access, store: store, chunkSizeInBytes: 512)
                .importOne(Sample.pickerItem(), into: session)

            // The provider's file is read only. Nothing in DefAIke writes, truncates,
            // moves, or removes it: that is the provider's to reclaim.
            let lent = try #require(await access.lentFiles.first)
            let hostBytesAfterCopy = try Array(Data(contentsOf: lent))
            #expect(hostBytesAfterCopy == bytes)

            // Now the provider reclaims, which is what a framework provider does the moment
            // the window closes.
            await access.cleanUp()
            #expect(!FileManager.default.fileExists(atPath: lent.path))

            // The copy is still there, still complete, and still byte-identical.
            let stored = try await soleSessionObject(of: session, in: store)
            #expect(stored.bytes == bytes)
            #expect(stored.receipt.byteCount == UInt64(bytes.count))
            #expect(stored.receipt.sha256 == StreamingSHA256.digest(of: Data(bytes)))
            #expect(asset.sha256 == stored.receipt.sha256)
            #expect(asset.handle.storageKey == stored.receipt.key)
        }
    }

    /// **Validates: Requirements 2.9, 2.10, 2.11, 2.12**
    @Test("A Photos import whose provider reclaims at the window's close still holds the bytes")
    func photosImportSurvivesAnImmediateReclamation() async throws {
        try await withTemporaryRoot { root in
            let store = makeFileStore(root: root)
            let session = Sample.sessionID("session-t410-photos-reclaimed")
            let bytes = Sample.bytes(count: smallPayloadByteCount, seed: 12)
            // The default: the lent file is gone the instant the consume closure returns.
            let access = FakePhotosAccess.lending(bytes)

            let asset = try await makePhotosAdapter(access: access, store: store)
                .importOne(Sample.pickerItem(), into: session)

            // The window really closed, so "the copy survived reclamation" is not vacuous.
            let lent = try #require(await access.lentFiles.first)
            #expect(!FileManager.default.fileExists(atPath: lent.path))

            let stored = try await soleSessionObject(of: session, in: store)
            #expect(stored.bytes == bytes)
            #expect(asset.byteCount == UInt64(bytes.count))
        }
    }

    /// **Validates: Requirements 2.3, 9.5, 11.12**
    @Test("A claimed handoff's bytes outlive the host reclaiming its representation")
    func claimedHandoffOutlivesHostReclamation() async throws {
        try await withPairedRoots { roots in
            let appGroup = IngestLedgerStore(makeFileStore(root: roots.appGroup))
            let session = IngestLedgerStore(makeFileStore(root: roots.appPrivate))
            let bytes = Sample.bytes(count: largePayloadByteCount, seed: 13)
            let timeline = HandoffTimeline()
            // The host keeps its lent file past the window so it can be compared afterwards.
            let access = TimelineSharedItemAccess(
                bytes: bytes,
                timeline: timeline,
                reclaimsRepresentation: false
            )
            let coordinator = try makeCoordinator(
                access: access,
                consentPresenter: TimelineConsentPresenter(
                    .confirmAfterDisplaying,
                    timeline: timeline
                ),
                transfers: makeExtensionSide(over: appGroup, chunkSizeInBytes: 512)
            )

            let outcome = await coordinator.handleActivation(
                Sample.activation(Sample.sharedProvider())
            )
            let ticket = try #require(outcome.publishedTicket)

            // The host's representation was read and nothing else.
            let lent = try #require(await access.lentFiles.first)
            let hostBytesAfterStaging = try Array(Data(contentsOf: lent))
            #expect(hostBytesAfterStaging == bytes)

            // The host reclaims, then the main application claims. The claim reads the App
            // Group copy, never the host's file, so it cannot depend on that file surviving.
            await access.reclaimLentFiles()
            #expect(!FileManager.default.fileExists(atPath: lent.path))

            let claim = await makeClaimAdapter(
                appGroupStore: appGroup,
                sessionStore: session,
                chunkSizeInBytes: 512
            ).attemptClaim(claimingBuildID: Sample.buildID())
            let verified = try #require(claim.verifiedHandoff)
            #expect(verified.sessionID == ticket.sessionID)

            let stored = try await soleSessionObject(
                of: ticket.sessionID,
                in: session.underlying
            )
            #expect(stored.bytes == bytes)
            #expect(stored.receipt.sha256 == ticket.sha256)
            // The shared container keeps nothing once the session owns the bytes.
            #expect(await transferScopes(of: appGroup.underlying).isEmpty)
        }
    }

    // MARK: - Scenario 2: chunked copy

    /// **Validates: Requirements 2.9, 2.12, 2.14, 11.12**
    @Test(
        "Staging and the claim's recopy chunk independently and reach one digest",
        arguments: integrationChunkSizes
    )
    func independentChunkingsReachOneDigest(stagingChunkSize: Int) async throws {
        try await withPairedRoots { roots in
            let appGroup = IngestLedgerStore(makeFileStore(root: roots.appGroup))
            let sessionStore = IngestLedgerStore(makeFileStore(root: roots.appPrivate))
            let bytes = Sample.bytes(count: smallPayloadByteCount, seed: 21)
            let expectedDigest = StreamingSHA256.digest(of: Data(bytes))
            let timeline = HandoffTimeline()
            // The claim's buffer is deliberately *not* the staging buffer, so the digest is
            // reached twice through two different partitions of the same byte sequence.
            let claimChunkSize = stagingChunkSize == 1 ? smallPayloadByteCount : 1

            let coordinator = try makeCoordinator(
                access: TimelineSharedItemAccess(bytes: bytes, timeline: timeline),
                consentPresenter: TimelineConsentPresenter(
                    .confirmAfterDisplaying,
                    timeline: timeline
                ),
                transfers: makeExtensionSide(
                    over: appGroup,
                    chunkSizeInBytes: stagingChunkSize
                )
            )
            let ticket = try #require(
                await coordinator.handleActivation(
                    Sample.activation(Sample.sharedProvider())
                ).publishedTicket
            )

            // The staged payload is the first object the publication created, and the number
            // of passes over it is the partition the buffer size actually produced.
            let stagedPayloadKey = try #require(appGroup.createdObjectKeys().first)
            let stagingPasses = appGroup.appendedLengths(to: stagedPayloadKey)
            let expectedStagingPasses = Int(
                (smallPayloadByteCount + stagingChunkSize - 1) / stagingChunkSize
            )
            #expect(stagingPasses.count == expectedStagingPasses)
            #expect(stagingPasses.reduce(0, +) == smallPayloadByteCount)
            #expect(ticket.byteCount == UInt64(smallPayloadByteCount))
            #expect(ticket.sha256 == expectedDigest)

            appGroup.forgetObservations()
            let claim = await makeClaimAdapter(
                appGroupStore: appGroup,
                sessionStore: sessionStore,
                chunkSizeInBytes: claimChunkSize
            ).attemptClaim(claimingBuildID: Sample.buildID())
            let verified = try #require(claim.verifiedHandoff)

            let recopiedKey = try #require(sessionStore.createdObjectKeys().first)
            let claimPasses = sessionStore.appendedLengths(to: recopiedKey)
            let expectedClaimPasses = Int(
                (smallPayloadByteCount + claimChunkSize - 1) / claimChunkSize
            )
            #expect(claimPasses.count == expectedClaimPasses)
            #expect(claimPasses.reduce(0, +) == smallPayloadByteCount)

            // Two partitions, one digest, and the bytes on disk are the provider's.
            #expect(verified.asset.sha256 == expectedDigest)
            #expect(verified.asset.byteCount == UInt64(smallPayloadByteCount))
            let stored = try await soleSessionObject(
                of: ticket.sessionID,
                in: sessionStore.underlying
            )
            #expect(stored.bytes == bytes)
        }
    }

    /// **Validates: Requirements 2.12, 2.14**
    @Test(
        "Every buffer size retains one identical Photos object",
        arguments: integrationChunkSizes
    )
    func everyBufferSizeRetainsOneIdenticalPhotosObject(chunkSize: Int) async throws {
        try await withTemporaryRoot { root in
            let store = IngestLedgerStore(makeFileStore(root: root))
            let session = Sample.sessionID("session-t410-photos-chunked")
            let bytes = Sample.bytes(count: smallPayloadByteCount, seed: 21)

            let asset = try await makePhotosAdapter(
                access: FakePhotosAccess.lending(bytes),
                store: store,
                chunkSizeInBytes: chunkSize
            ).importOne(Sample.pickerItem(), into: session)

            let key = try #require(store.createdObjectKeys().first)
            let passes = store.appendedLengths(to: key)
            #expect(
                passes.count == Int((smallPayloadByteCount + chunkSize - 1) / chunkSize)
            )
            // Exactly one object, finalized exactly once: a partial copy is neither readable
            // nor promotable, so a second object would mean the bytes could diverge.
            #expect(store.createdObjectKeys().count == 1)
            #expect(store.finalizedObjectKeys() == [key])
            #expect(asset.sha256 == StreamingSHA256.digest(of: Data(bytes)))
            let stored = try await soleSessionObject(of: session, in: store.underlying)
            #expect(stored.bytes == bytes)
            #expect(await store.underlying.unfinalizedKeys.isEmpty)
        }
    }

    // MARK: - Scenario 3: one-item rejection

    /// Activations that must be refused, with the refusal each one produces.
    ///
    /// Zero and many have to be representable in order to be refused, which is why
    /// ``ShareActivation`` constrains neither count.
    private static func refusedActivations() -> [(ShareActivation, ShareActivationRefusal)] {
        [
            (Sample.activation(), .noProviderOffered),
            (
                Sample.activation(
                    Sample.sharedProvider(token: 1),
                    Sample.sharedProvider(token: 2)
                ),
                .providerCountUnsupported(2)
            ),
            (
                Sample.activation(Sample.sharedProvider(itemCount: 0)),
                .itemCountUnsupported(0)
            ),
            (
                Sample.activation(Sample.sharedProvider(itemCount: 2)),
                .itemCountUnsupported(2)
            ),
            (
                Sample.activation(Sample.sharedProvider(itemCount: 7)),
                .itemCountUnsupported(7)
            ),
        ]
    }

    /// **Validates: Requirements 2.5, 2.7, 9.5, 11.8**
    @Test("A refused item count leaves the shared container holding nothing at all")
    func refusedItemCountLeavesTheContainerEmpty() async throws {
        // Property 4 quantifies the count gate itself over generated counts. What this arm
        // adds is the storage-level consequence of a refusal, measured on the real container:
        // not merely "no ticket", but no scope, no bytes, and no object the store was ever
        // asked to create.
        for (activation, expected) in Self.refusedActivations() {
            try await withTemporaryRoot { root in
                let appGroup = IngestLedgerStore(makeFileStore(root: root))
                let timeline = HandoffTimeline()
                let access = TimelineSharedItemAccess(
                    bytes: Sample.bytes(count: smallPayloadByteCount, seed: 31),
                    timeline: timeline
                )
                let presenter = TimelineConsentPresenter(
                    .confirmAfterDisplaying,
                    timeline: timeline
                )
                let transfers = makeExtensionSide(over: appGroup)
                let coordinator = try makeCoordinator(
                    access: access,
                    consentPresenter: presenter,
                    transfers: transfers
                )

                let outcome = await coordinator.handleActivation(activation)

                #expect(outcome == .activationRefused(expected))
                #expect(outcome.publishedTicket == nil)
                // Decided before the provider is touched and before the action appears.
                #expect(await presenter.askedRequests.isEmpty)
                #expect(await presenter.displayedRequests.isEmpty)
                #expect(await access.requestedProviders.isEmpty)
                #expect(timeline.recorded().isEmpty)
                // Nothing was created, so there is nothing to have cleaned up.
                #expect(appGroup.mutatingOperationCount() == 0)
                #expect(await transferScopes(of: appGroup.underlying).isEmpty)
                let used = try await appGroup.underlying.usedByteCount()
                #expect(used == 0)
                let slot = try await transfers.readySlotState()
                #expect(slot == .empty)
            }
        }
    }

    /// **Validates: Requirements 2.5, 2.7**
    @Test("Exactly one provider offering one item is what publishes, in the same wiring")
    func exactlyOneItemPublishesInTheSameWiring() async throws {
        // The positive control for the arm above: the same coordinator, the same store, and
        // the same doubles, so the emptiness those assertions rely on is a consequence of the
        // count rather than of nothing ever working.
        try await withTemporaryRoot { root in
            let appGroup = IngestLedgerStore(makeFileStore(root: root))
            let timeline = HandoffTimeline()
            let coordinator = try makeCoordinator(
                access: TimelineSharedItemAccess(
                    bytes: Sample.bytes(count: smallPayloadByteCount, seed: 31),
                    timeline: timeline
                ),
                consentPresenter: TimelineConsentPresenter(
                    .confirmAfterDisplaying,
                    timeline: timeline
                ),
                transfers: makeExtensionSide(over: appGroup)
            )

            let outcome = await coordinator.handleActivation(
                Sample.activation(Sample.sharedProvider())
            )

            #expect(outcome.publishedTicket != nil)
            #expect(appGroup.mutatingOperationCount() > 0)
            let used = try await appGroup.underlying.usedByteCount()
            #expect(used > 0)
        }
    }

    /// **Validates: Requirements 2.5, 2.7**
    @Test("A picker selection other than one has nothing it can hand to the import port")
    func pickerSelectionOtherThanOneHandsNothingOver() {
        // `PhotosIngestCoordinator` is in `DefAIkeApplication`, outside this target's module
        // closure, and `PhotosIngestCoordinatorTests` pins its refusal outcomes. What is
        // reachable here is the gate the import port sits behind: `soleItem` is the only
        // sanctioned way from a selection to an item, and `PhotosImporting` takes one item, so
        // a selection of any other count has nothing to pass.
        #expect(PhotosPickerSelection(items: []).soleItem == nil)
        #expect(PhotosRepresentationRequest.maximumSelectionCount == 1)
        for count in [2, 3, 9] {
            let selection = PhotosPickerSelection(
                items: (0..<count).map { Sample.pickerItem(token: UInt64($0)) }
            )
            #expect(selection.soleItem == nil)
            #expect(!selection.isCancellation)
        }
        #expect(PhotosPickerSelection(items: [Sample.pickerItem()]).soleItem != nil)

        // The Share route's own gate is a value, not a check: consent for an activation that
        // did not offer exactly one item is not constructible, so no token exists to stage
        // with.
        for count in [0, 2, 7] {
            #expect(
                ConfirmedConsent(
                    provider: Sample.sharedProvider(itemCount: count),
                    extensionExecutionPolicyID: Sample.artifactID("extension-execution-0001"),
                    confirmedAt: fixtureNow
                ) == nil
            )
        }
        #expect(SharedItemRepresentationRequest.maximumActivationItemCount == 1)
    }

    // MARK: - Scenario 4: picker cancellation

    /// **Validates: Requirements 2.18, 3.13, 3.15, 11.17**
    @Test("A cancelled picker leaves nothing, and the same store then accepts a real selection")
    func cancelledPickerLeavesNothingAndTheNextSelectionSucceeds() async throws {
        try await withTemporaryRoot { root in
            let store = IngestLedgerStore(makeFileStore(root: root))
            let cancelledSession = Sample.sessionID("session-t410-picker-cancelled")

            // An empty selection is the picker cancellation, and it never reaches the port.
            let dismissed = PhotosPickerSelection(items: [])
            #expect(dismissed.isCancellation)
            #expect(dismissed.soleItem == nil)

            // A cancellation the provider itself reports is the other half of the same
            // outcome: no session, and not an error category.
            let cancelling = FakePhotosAccess.failing(.cancelled)
            let outcome = await makePhotosAdapter(access: cancelling, store: store)
                .attemptImport(of: Sample.pickerItem(), into: cancelledSession)
            #expect(outcome == .failure(.cancelled))
            let failure = try #require(outcome.failure)
            #expect(failure.fault == .cancelled)
            #expect(failure.fault.analysisError == nil)
            for error in AnalysisError.allCases {
                #expect(failure.fault.analysisError != error)
            }
            #expect(await sessionScopes(of: store.underlying).isEmpty)
            #expect(store.mutatingOperationCount() == 0)

            // The recovery half, which is what makes this an integration statement: the same
            // store, with no restart and no reconfiguration, accepts the next selection and
            // carries no error category or session data from the cancelled attempt.
            let nextSession = Sample.sessionID("session-t410-picker-retry")
            let bytes = Sample.bytes(count: smallPayloadByteCount, seed: 41)
            let asset = try await makePhotosAdapter(
                access: FakePhotosAccess.lending(bytes),
                store: store
            ).importOne(Sample.pickerItem(), into: nextSession)

            #expect(asset.sessionID == nextSession)
            #expect(asset.route == .photosPicker)
            let stored = try await soleSessionObject(of: nextSession, in: store.underlying)
            #expect(stored.bytes == bytes)
            // The cancelled session never owned anything, then or now.
            #expect(await store.underlying.keys(in: .session(cancelledSession)).isEmpty)
            #expect(
                await sessionScopes(of: store.underlying) == [.session(nextSession)]
            )
        }
    }

    /// **Validates: Requirements 2.18, 3.13, 9.8, 11.14, 11.17**
    @Test("Cancelling part way through the copy leaves nothing and does not poison the store")
    func cancellingPartWayThroughTheCopyLeavesNothing() async throws {
        try await withTemporaryRoot { root in
            let gate = CopyProgressGate(cancelAfterAppendCount: 2)
            let store = IngestLedgerStore(makeFileStore(root: root), gate: gate)
            let session = Sample.sessionID("session-t410-midcopy")
            // Eight passes at this buffer size, so cancelling after two is genuinely mid-copy
            // rather than before the work began.
            let bytes = Sample.bytes(count: 1_024, seed: 42)
            let adapter = makePhotosAdapter(
                access: FakePhotosAccess.lending(bytes),
                store: store,
                chunkSizeInBytes: 128
            )

            let task = Task {
                await adapter.attemptImport(of: Sample.pickerItem(), into: session)
            }
            // Wiring the trigger before the copy may start is what makes the boundary
            // deterministic without a sleep.
            await gate.arm { task.cancel() }
            let outcome = await task.value

            #expect(outcome == .failure(.cancelled))
            let midCopyFailure = try #require(outcome.failure)
            #expect(midCopyFailure.fault == .cancelled)
            let appendsBefore = try #require(await gate.appendsBeforeCancellation)
            #expect(appendsBefore == 2)
            // The copy stopped within one buffer of the cancellation rather than finishing.
            #expect(await gate.appendsObserved < 8)
            // Nothing partial survives, and nothing is left unfinalizable in the store.
            #expect(await sessionScopes(of: store.underlying).isEmpty)
            let used = try await store.underlying.usedByteCount()
            #expect(used == 0)

            // A fresh attempt through a fresh window succeeds against the same store.
            let retry = Sample.sessionID("session-t410-midcopy-retry")
            let asset = try await makePhotosAdapter(
                access: FakePhotosAccess.lending(bytes),
                store: store,
                chunkSizeInBytes: 128
            ).importOne(Sample.pickerItem(), into: retry)
            #expect(asset.sha256 == StreamingSHA256.digest(of: Data(bytes)))
        }
    }

    // MARK: - Scenarios 5 and 6: screenshots and every supported format

    /// **Validates: Requirements 2.6, 2.15, 2.16**
    @Test("Both routes request exactly one container set, and neither can widen it")
    func bothRoutesRequestOneContainerSet() {
        // A screenshot is an ordinary PNG or HEIC selection, and the four requested container
        // spellings are the Version 1 Supported Static Image set in the two forms HEIC/HEIF
        // uses. The set exists so the request can name a *typed* representation; it is not a
        // validation rule, and it must be the same set on both routes or one route could
        // retain a container the other never asks for.
        #expect(
            PhotosRepresentationRequest.requestedContainers
                == SharedItemRepresentationRequest.requestedContainers
        )
        #expect(
            PhotosRepresentationRequest.requestedContainers == RequestedImageContainer.allCases
        )
        // Neither route can ask for a transcode or for an in-place file, so no route-specific
        // representation-altering request exists to diverge on.
        #expect(PhotosEncodingPolicy.allCases == [.currentWhenPossible])
        #expect(SharedItemAccessPolicy.allCases == [.copyIntoAppControlledStorage])
        #expect(PhotosLibraryAccess.allCases == [.selectedItemsOnly])
    }

    /// **Validates: Requirements 2.9, 2.10, 2.11, 2.12, 2.14, 2.17, 9.4, 9.5**
    @Test(
        "One byte sequence retains identically on both routes for every supplied type",
        arguments: SuppliedType.allCases
    )
    fileprivate func everySuppliedTypeRetainsIdenticallyOnBothRoutes(
        supplied: SuppliedType
    ) async throws {
        try await withPairedRoots { roots in
            let photosStore = makeFileStore(
                root: roots.appPrivate.appending(path: "photos", directoryHint: .isDirectory)
            )
            let appGroup = IngestLedgerStore(makeFileStore(root: roots.appGroup))
            let sessionStore = IngestLedgerStore(
                makeFileStore(
                    root: roots.appPrivate.appending(
                        path: "share",
                        directoryHint: .isDirectory
                    )
                )
            )
            // One byte sequence, offered under both routes. Ingest never classifies, so the
            // supplied type may vary while the bytes do not — which is what makes the
            // comparison below about preservation rather than about acceptance.
            let bytes = Sample.bytes(count: smallPayloadByteCount, seed: 51)
            let expectedDigest = StreamingSHA256.digest(of: Data(bytes))
            let photosSession = Sample.sessionID("session-t410-photos-format")

            let photosAsset = try await makePhotosAdapter(
                access: FakePhotosAccess.lending(
                    bytes,
                    form: .typedFileRepresentation,
                    suppliedContentTypeHint: supplied.hint
                ),
                store: photosStore
            ).importOne(Sample.pickerItem(), into: photosSession)

            let timeline = HandoffTimeline()
            let coordinator = try makeCoordinator(
                access: TimelineSharedItemAccess(bytes: bytes, timeline: timeline),
                consentPresenter: TimelineConsentPresenter(
                    .confirmAfterDisplaying,
                    timeline: timeline
                ),
                transfers: makeExtensionSide(over: appGroup)
            )
            let ticket = try #require(
                await coordinator.handleActivation(
                    Sample.activation(
                        Sample.sharedProvider(contentTypeHint: supplied.hint)
                    )
                ).publishedTicket
            )
            let claim = await makeClaimAdapter(
                appGroupStore: appGroup,
                sessionStore: sessionStore
            ).attemptClaim(claimingBuildID: Sample.buildID())
            let shareAsset = try #require(claim.verifiedHandoff).asset

            // Requirement 2.14: byte-identical inputs through the two routes produce accepted
            // ingests that agree on everything an analysis reads except the recorded route.
            #expect(photosAsset.byteCount == shareAsset.byteCount)
            #expect(photosAsset.sha256 == shareAsset.sha256)
            #expect(photosAsset.sha256 == expectedDigest)
            #expect(photosAsset.preservationStatus == shareAsset.preservationStatus)
            #expect(photosAsset.preservationBasis == shareAsset.preservationBasis)
            #expect(photosAsset.contentTypeHint == shareAsset.contentTypeHint)
            // The hint is recorded verbatim, including its absence, and never used to filter.
            #expect(photosAsset.contentTypeHint == supplied.hint)
            #expect(ticket.contentTypeHint == supplied.hint)
            // Exactly one route each, and they are the two Version 1 routes.
            #expect(photosAsset.route == .photosPicker)
            #expect(shareAsset.route == .shareExtension)
            #expect(photosAsset.route != shareAsset.route)
            // A typed answer from either provider establishes the current representation and
            // nothing more, so neither route can record byte originality.
            #expect(photosAsset.preservationStatus == .unknown)
            #expect(
                photosAsset.preservationBasis == .providerDeclaredCurrentRepresentationOnly
            )

            // And the bytes on disk under each route are the provider's, byte for byte.
            let photosStored = try await soleSessionObject(
                of: photosSession,
                in: photosStore
            )
            let shareStored = try await soleSessionObject(
                of: ticket.sessionID,
                in: sessionStore.underlying
            )
            #expect(photosStored.bytes == bytes)
            #expect(shareStored.bytes == bytes)
            #expect(photosStored.receipt.sha256 == shareStored.receipt.sha256)
        }
    }

    /// **Validates: Requirements 2.15, 2.16, 2.17**
    @Test("A screenshot takes the ordinary route with no case of its own")
    func aScreenshotTakesTheOrdinaryRoute() async throws {
        try await withTemporaryRoot { root in
            let store = makeFileStore(root: root)
            // The same bytes offered as a screenshot container and as a photo container. No
            // stage in ingest inspects which it is, so the two retentions must be
            // indistinguishable apart from the recorded hint.
            let bytes = Sample.bytes(count: smallPayloadByteCount, seed: 52)
            var retained: [SuppliedType: ImportedEncodedAsset] = [:]
            for (index, supplied) in SuppliedType.allCases.enumerated() {
                // One session scope per supplied type, so no retention can satisfy another's
                // "exactly one object" reading.
                let session = Sample.sessionID("session-t410-shot-\(index)")
                retained[supplied] = try await makePhotosAdapter(
                    access: FakePhotosAccess.lending(
                        bytes,
                        suppliedContentTypeHint: supplied.hint
                    ),
                    store: store
                ).importOne(Sample.pickerItem(), into: session)
            }

            let baseline = try #require(retained[.jpegPhoto])
            #expect(SuppliedType.allCases.filter(\.isScreenshotContainer).count == 2)
            for supplied in SuppliedType.allCases {
                let asset = try #require(retained[supplied])
                #expect(asset.byteCount == baseline.byteCount)
                #expect(asset.sha256 == baseline.sha256)
                #expect(asset.preservationStatus == baseline.preservationStatus)
                #expect(asset.preservationBasis == baseline.preservationBasis)
                #expect(asset.route == baseline.route)
                #expect(asset.handle.protection == baseline.handle.protection)
                // Only the recorded hint distinguishes them, and only for an audit.
                #expect(asset.contentTypeHint == supplied.hint)
            }
        }
    }

    // MARK: - Scenario 7: consent ordering

    /// **Validates: Requirements 2.2, 2.3, 11.9, 11.10**
    @Test("Nothing touches a byte before the confirmed consent step in one shared timeline")
    func nothingTouchesAByteBeforeConsentInOneTimeline() async throws {
        try await withTemporaryRoot { root in
            let timeline = HandoffTimeline()
            let appGroup = IngestLedgerStore(
                makeFileStore(root: root),
                timeline: timeline
            )
            let access = TimelineSharedItemAccess(
                bytes: Sample.bytes(count: smallPayloadByteCount, seed: 71),
                timeline: timeline
            )
            let presenter = TimelineConsentPresenter(
                .confirmAfterDisplaying,
                timeline: timeline
            )
            let policy = Sample.extensionPolicy(stagedFileProtection: integrationProtection)
            let transfers = makeExtensionSide(over: appGroup)
            let coordinator = try makeCoordinator(
                access: access,
                consentPresenter: presenter,
                transfers: transfers
            )

            let outcome = await coordinator.handleActivation(
                Sample.activation(Sample.sharedProvider())
            )
            #expect(outcome.publishedTicket != nil)

            // One log, three independent seams. Separate per-seam counts are each consistent
            // with any order; an index comparison inside one log is not.
            let steps = timeline.recorded()
            let asked = try #require(timeline.firstIndex(of: .consentAsked))
            let displayed = try #require(timeline.firstIndex(of: .consentDisplayed))
            let answered = try #require(timeline.firstIndex(of: .consentAnswered))
            let providerAsked = try #require(timeline.firstIndex(of: .providerAsked))
            let lent = try #require(timeline.firstIndex(of: .representationLent))
            let created = try #require(timeline.firstIndex(of: .objectCreated))
            let appended = try #require(timeline.firstIndex(of: .chunkAppended))
            let finalized = try #require(timeline.firstIndex(of: .objectFinalized))
            let promoted = try #require(timeline.firstIndex(of: .objectPromoted))

            #expect(asked < displayed)
            #expect(displayed < answered)
            // The host is not reached, and no byte is read, copied, hashed, or written, until
            // after the visible action has been answered.
            #expect(answered < providerAsked)
            #expect(providerAsked < lent)
            #expect(lent < created)
            #expect(created < appended)
            #expect(appended < finalized)
            // The commit is last: both promotions follow every write, and the manifest's
            // rename into the ready slot is the final step of the whole activation.
            #expect(finalized < promoted)
            #expect(steps.last == .objectPromoted)
            #expect(steps.filter { $0 == .objectPromoted }.count == 2)
            #expect(appGroup.promotionCount() == 2)
            // Stated once more as a set comparison, so a step added later without an index
            // comparison still cannot precede the answer.
            let beforeTheAnswer = steps.prefix(answered)
            #expect(!beforeTheAnswer.contains(.providerAsked))
            #expect(!beforeTheAnswer.contains(.objectCreated))
            #expect(!beforeTheAnswer.contains(.chunkAppended))
            #expect(timeline.byteTouchingSteps().count == steps.count - 3)

            // The request names the provider that was presented and the policy version the
            // store is actually bound to, read from the store rather than from a second copy
            // handed to the coordinator separately (Requirement 11.9).
            let requests = await presenter.displayedRequests
            #expect(requests.count == 1)
            let request = try #require(requests.first)
            #expect(request.provider == Sample.sharedProvider())
            let boundPolicyID = await transfers.extensionExecutionPolicyID
            #expect(request.extensionExecutionPolicyID == boundPolicyID)
            #expect(request.extensionExecutionPolicyID == policy.id)
        }
    }

    /// Consent answers that authorize nothing, and the outcome each produces.
    private static let unauthorizingAnswers:
        [(TimelineConsentPresenter.Answer, ShareHandoffOutcome)] = [
            (.cancelWithoutDisplaying, .cancelled),
            (.declineAfterDisplaying, .declined),
            (.cancelAfterDisplaying, .cancelled),
        ]

    /// **Validates: Requirements 2.2, 2.4, 9.5, 11.10, 11.17**
    @Test("An answer that is not a confirmation reads no byte and leaves no material")
    func anUnconfirmedAnswerReadsNoByte() async throws {
        for (answer, expected) in Self.unauthorizingAnswers {
            try await withTemporaryRoot { root in
                let timeline = HandoffTimeline()
                let appGroup = IngestLedgerStore(
                    makeFileStore(root: root),
                    timeline: timeline
                )
                let access = TimelineSharedItemAccess(
                    bytes: Sample.bytes(count: smallPayloadByteCount, seed: 72),
                    timeline: timeline
                )
                let presenter = TimelineConsentPresenter(answer, timeline: timeline)
                let transfers = makeExtensionSide(over: appGroup)
                let coordinator = try makeCoordinator(
                    access: access,
                    consentPresenter: presenter,
                    transfers: transfers
                )

                let outcome = await coordinator.handleActivation(
                    Sample.activation(Sample.sharedProvider())
                )

                #expect(outcome == expected)
                #expect(outcome.publishedTicket == nil)
                // The action was reached, so this is an answer rather than a refused count.
                #expect(await presenter.askedRequests.count == 1)
                #expect(
                    await presenter.displayedRequests.isEmpty
                        == (answer == .cancelWithoutDisplaying)
                )
                // And not one byte of the shared item was touched.
                #expect(timeline.byteTouchingSteps().isEmpty)
                #expect(await access.requestedProviders.isEmpty)
                #expect(appGroup.mutatingOperationCount() == 0)
                #expect(await transferScopes(of: appGroup.underlying).isEmpty)
                let used = try await appGroup.underlying.usedByteCount()
                #expect(used == 0)
                let slot = try await transfers.readySlotState()
                #expect(slot == .empty)
            }
        }
    }

    /// **Validates: Requirements 2.2, 11.9, 11.10**
    @Test("A consent token for another provider or another policy authorizes nothing")
    func aTokenForSomethingElseAuthorizesNothing() async throws {
        try await withTemporaryRoot { root in
            let presented = Sample.sharedProvider(token: 1)
            let other = Sample.sharedProvider(token: 2)
            let boundPolicyID = Sample.artifactID("extension-execution-0001")
            let unboundPolicyID = Sample.artifactID("extension-execution-9999")
            // Consent is proof of one action for one provider under one bound policy. A token
            // naming anything else is not weaker evidence, it is evidence of a different
            // thing, so each of these is checked before the host is reached at all.
            let cases: [(ConfirmedConsent, ConsentBindingDefect)] = [
                (
                    Sample.consent(for: other, policyID: boundPolicyID),
                    .providerMismatch
                ),
                (
                    Sample.consent(for: presented, policyID: unboundPolicyID),
                    .unboundExtensionExecutionPolicy
                ),
            ]

            for (consent, expected) in cases {
                let timeline = HandoffTimeline()
                let appGroup = IngestLedgerStore(
                    makeFileStore(
                        root: root.appending(
                            path: expected.rawValue,
                            directoryHint: .isDirectory
                        )
                    ),
                    timeline: timeline
                )
                let access = TimelineSharedItemAccess(
                    bytes: Sample.bytes(count: smallPayloadByteCount, seed: 73),
                    timeline: timeline
                )
                let coordinator = try makeCoordinator(
                    access: access,
                    consentPresenter: TimelineConsentPresenter(
                        .confirmAfterDisplaying,
                        timeline: timeline
                    ),
                    transfers: makeExtensionSide(over: appGroup)
                )

                let outcome = await coordinator.attemptStaging(
                    of: presented,
                    consent: consent
                )

                #expect(outcome == .failure(.consentNotBound(expected)))
                #expect(timeline.byteTouchingSteps().isEmpty)
                #expect(await access.requestedProviders.isEmpty)
                #expect(appGroup.mutatingOperationCount() == 0)
                let used = try await appGroup.underlying.usedByteCount()
                #expect(used == 0)
            }
        }
    }

    // MARK: - Scenario 8: publication interruption at every write boundary

    /// **Validates: Requirements 2.4, 9.5, 9.9, 11.8, 11.16**
    @Test(
        "An interruption at any write boundary publishes nothing and leaves nothing",
        arguments: 0..<publicationWriteBoundaryCount
    )
    func anInterruptionAtAnyWriteBoundaryPublishesNothing(boundary: Int) async throws {
        try await withPairedRoots { roots in
            let sessionStore = IngestLedgerStore(makeFileStore(root: roots.appPrivate))
            let appGroup = IngestLedgerStore(
                makeFileStore(root: roots.appGroup),
                refusingMutatingOperationAtIndex: boundary
            )
            let timeline = HandoffTimeline()
            let access = TimelineSharedItemAccess(
                bytes: Sample.bytes(count: smallPayloadByteCount, seed: 81),
                timeline: timeline
            )
            let transfers = makeExtensionSide(
                over: appGroup,
                // One pass over the payload, so the boundary indices below are fixed.
                chunkSizeInBytes: smallPayloadByteCount
            )
            let coordinator = try makeCoordinator(
                access: access,
                consentPresenter: TimelineConsentPresenter(
                    .confirmAfterDisplaying,
                    timeline: timeline
                ),
                transfers: transfers
            )

            let outcome = await coordinator.handleActivation(
                Sample.activation(Sample.sharedProvider())
            )

            // No session, whichever boundary was interrupted. Publication is the only commit,
            // so there was never a half-published slot to inherit.
            #expect(outcome.publishedTicket == nil)
            guard case .failed(let failure) = outcome else {
                Issue.record("boundary \(boundary) must produce a failed staging outcome")
                return
            }
            // Every one of these is an incomplete handoff rather than a cancellation or a
            // resource breach: a store that refused is not a limit that was reached.
            expectExactlyHandoffError(failure.fault)
            #expect(failure != .cancelled)

            // The interruption really happened where the arm said, and no further boundary was
            // attempted after it.
            #expect(appGroup.mutatingOperationCount() == boundary + 1)

            // Nothing is left in the shared container: not a staged payload, not a record, not
            // an emptied slot holding bytes, and not an unfinalizable partial object.
            #expect(await transferScopes(of: appGroup.underlying).isEmpty)
            let used = try await appGroup.underlying.usedByteCount()
            #expect(used == 0)
            let slot = try await transfers.readySlotState()
            #expect(slot == .empty)
            // Cleanup ran rather than the material happening to be absent.
            #expect(!appGroup.scopesDeleted().isEmpty)

            // And the main application, on the other side of the container, sees no pending
            // handoff at all rather than a broken one.
            let claim = await makeClaimAdapter(
                appGroupStore: appGroup,
                sessionStore: sessionStore
            ).attemptClaim(claimingBuildID: Sample.buildID())
            #expect(claim == .nothingPending)
            #expect(await sessionScopes(of: sessionStore.underlying).isEmpty)
            #expect(sessionStore.mutatingOperationCount() == 0)

            // A restart after the interruption keeps nothing and still succeeds, which is what
            // Requirements 9.9 and 11.16 ask of the next start.
            let report = try await transfers.runStartupCleanup()
            #expect(report.retainedTransfer == nil)
            #expect(report.removedObjectCount == 0)
        }
    }

    /// **Validates: Requirements 2.3, 11.12**
    @Test("The same publication with no interruption commits at the eighth write boundary")
    func anUninterruptedPublicationCommitsAtTheLastBoundary() async throws {
        // The control for the arm above, and the assertion that pins its boundary count.
        try await withPairedRoots { roots in
            let appGroup = IngestLedgerStore(makeFileStore(root: roots.appGroup))
            let sessionStore = IngestLedgerStore(makeFileStore(root: roots.appPrivate))
            let timeline = HandoffTimeline()
            let bytes = Sample.bytes(count: smallPayloadByteCount, seed: 81)
            let transfers = makeExtensionSide(
                over: appGroup,
                chunkSizeInBytes: smallPayloadByteCount
            )
            let coordinator = try makeCoordinator(
                access: TimelineSharedItemAccess(bytes: bytes, timeline: timeline),
                consentPresenter: TimelineConsentPresenter(
                    .confirmAfterDisplaying,
                    timeline: timeline
                ),
                transfers: transfers
            )

            let outcome = await coordinator.handleActivation(
                Sample.activation(Sample.sharedProvider())
            )
            guard case .published(let published) = outcome else {
                Issue.record("the uninterrupted control must publish, got \(outcome)")
                return
            }

            #expect(
                appGroup.mutatingOperationCount() == publicationWriteBoundaryCount,
                """
                A publication of a single-pass payload has exactly \
                \(publicationWriteBoundaryCount) write boundaries. If this changed, the \
                interruption arm's argument range is stale.
                """
            )
            // The handoff ends with an instruction rather than a launch.
            #expect(published.instruction == Sample.manualInstruction())
            #expect(ManualOpenInstruction.launchMechanism == .manualUserAction)
            // And it really committed, on the other side of the container.
            let claim = await makeClaimAdapter(
                appGroupStore: appGroup,
                sessionStore: sessionStore
            ).attemptClaim(claimingBuildID: Sample.buildID())
            let verified = try #require(claim.verifiedHandoff)
            #expect(verified.sessionID == published.sessionID)
            let stored = try await soleSessionObject(
                of: published.sessionID,
                in: sessionStore.underlying
            )
            #expect(stored.bytes == bytes)
        }
    }

    // MARK: - Scenario 9: claim mismatch

    /// One published handoff, and the pieces an arm needs to disagree with it.
    private struct PublishedHandoffUnderTest {
        let ticket: ShareTransferTicket
        let payloadBytes: [UInt8]
        let recordKey: EphemeralStorageKey
        let recordBytes: [UInt8]
        let payloadKey: EphemeralStorageKey
    }

    /// Publishes one handoff through the real coordinator and locates its record.
    private func publishForMismatch(
        bytes: [UInt8],
        over appGroup: IngestLedgerStore,
        buildID: AppBuildID = Sample.buildID()
    ) async throws -> PublishedHandoffUnderTest {
        let timeline = HandoffTimeline()
        let coordinator = try makeCoordinator(
            access: TimelineSharedItemAccess(bytes: bytes, timeline: timeline),
            consentPresenter: TimelineConsentPresenter(
                .confirmAfterDisplaying,
                timeline: timeline
            ),
            transfers: makeExtensionSide(over: appGroup, buildID: buildID, chunkSizeInBytes: 512)
        )
        let ticket = try #require(
            await coordinator.handleActivation(
                Sample.activation(Sample.sharedProvider())
            ).publishedTicket
        )
        let located = try await locatePublishedRecord(of: ticket.transferID, in: appGroup)
        // Every field this file changes must round-trip unchanged first, so an arm cannot pass
        // on a record that was already broken.
        #expect(located.manifest.ticket == ticket)
        return PublishedHandoffUnderTest(
            ticket: ticket,
            payloadBytes: bytes,
            recordKey: located.key,
            recordBytes: located.bytes,
            payloadKey: located.manifest.payloadKey
        )
    }

    /// **Validates: Requirements 2.19, 11.13, 11.17, 9.5**
    @Test(
        "Every mismatch that surfaces handoff-error ends that pending session and nothing else",
        arguments: ClaimMismatch.allCases
    )
    fileprivate func everySurfacedMismatchEndsThatPendingSession(
        mismatch: ClaimMismatch
    ) async throws {
        try await withPairedRoots { roots in
            let appGroup = IngestLedgerStore(makeFileStore(root: roots.appGroup))
            let sessionStore = IngestLedgerStore(makeFileStore(root: roots.appPrivate))
            // Above the record ceiling, so ready-slot resolution skips the payload as a record
            // candidate and every read of it below is the claim's own.
            let bytes = Sample.bytes(count: largePayloadByteCount, seed: 91)
            let published = try await publishForMismatch(bytes: bytes, over: appGroup)
            let foreignBuild = Sample.buildID("build-t410-foreign-0001")
            var claimingBuild = Sample.buildID()

            switch mismatch {
            case .payloadByteFlipped:
                // One byte changed, the length left alone, and the object's recorded
                // measurements left as written: only a digest recomputed over the recopied
                // bytes can catch this.
                var flipped = bytes
                flipped[largePayloadByteCount / 2] ^= 0x5A
                #expect(flipped != bytes)
                appGroup.substituteRead(flipped, for: published.payloadKey)
            case .payloadTruncated:
                appGroup.substituteRead(
                    Array(bytes.prefix(largePayloadByteCount - 100)),
                    for: published.payloadKey
                )
            case .ticketByteCount:
                let spliced = try #require(
                    RecordMemberSplice.settingNumber(
                        "byteCount",
                        to: String(largePayloadByteCount - 100),
                        in: published.recordBytes
                    )
                )
                #expect(spliced.previousValue == String(largePayloadByteCount))
                #expect(spliced.bytes != published.recordBytes)
                appGroup.substituteRead(spliced.bytes, for: published.recordKey)
            case .ticketDigest:
                // Still exactly sixty-four lowercase hexadecimal characters, so the record
                // still decodes: this arm is about a record that disagrees, not one that is
                // unreadable.
                let real = published.ticket.sha256.hexadecimalString
                var characters = Array(real)
                characters[0] = characters[0] == "0" ? "1" : "0"
                let spliced = try #require(
                    RecordMemberSplice.settingString(
                        "sha256",
                        to: String(characters),
                        in: published.recordBytes
                    )
                )
                #expect(spliced.previousValue == real)
                appGroup.substituteRead(spliced.bytes, for: published.recordKey)
            case .ticketStagingBuild:
                let spliced = try #require(
                    RecordMemberSplice.settingString(
                        "extensionBuildID",
                        to: foreignBuild.rawValue,
                        in: published.recordBytes
                    )
                )
                #expect(spliced.previousValue == Sample.buildID().rawValue)
                appGroup.substituteRead(spliced.bytes, for: published.recordKey)
            case .claimingBuildDiffers:
                // The record is left exactly as published; the disagreement arrives from the
                // claiming side instead. Two installed compositions share no slot by design,
                // so this is checked before a byte is read either way.
                claimingBuild = foreignBuild
            }

            appGroup.forgetObservations()
            let claim = await makeClaimAdapter(
                appGroupStore: appGroup,
                sessionStore: sessionStore,
                chunkSizeInBytes: 512
            ).attemptClaim(claimingBuildID: claimingBuild)

            guard case .failed(let failed) = claim else {
                Issue.record("\(mismatch.rawValue) must fail the pending session, got \(claim)")
                return
            }
            // The session that failed is the session that was pending, resumed in order to be
            // ended rather than invented for the error.
            #expect(failed.sessionID == published.ticket.sessionID)
            #expect(failed.transferID == published.ticket.transferID)
            #expect(failed.sessionID != Sample.sessionID("session-t410-decoy"))
            expectExactlyHandoffError(failed.fault)

            // The exact failure, so an audit can tell a foreign build from a corrupted
            // payload, and so a mismatch cannot be reported as a repaired value.
            let expectedFailure: ShareClaimFailure = switch mismatch {
            case .payloadByteFlipped: .mismatch(.digest)
            case .payloadTruncated: .mismatch(.byteCount)
            case .ticketByteCount, .ticketDigest:
                .slotNotResumable(
                    .defective(
                        DefectiveTransfer(
                            transferID: published.ticket.transferID,
                            pendingSession: published.ticket.sessionID,
                            defect: .measurementMismatch
                        )
                    )
                )
            case .ticketStagingBuild, .claimingBuildDiffers:
                .mismatch(.stagingBuildIdentity)
            }
            #expect(failed.failure == expectedFailure)
            #expect(claim.verifiedHandoff == nil)

            // The ordering Requirements 2.19 and 11.13 are about, measured as a nonoccurrence
            // on the production path: a mismatch refused before the recopy never asks
            // app-private storage for an object at all.
            #expect(
                sessionStore.createdObjectKeys().count == mismatch.expectedSessionCreateCount
            )

            // Nothing survives anywhere: not the staged bytes, not the record, and not
            // however much of a recopy completed.
            #expect(await transferScopes(of: appGroup.underlying).isEmpty)
            #expect(await sessionScopes(of: sessionStore.underlying).isEmpty)
            let sharedUsed = try await appGroup.underlying.usedByteCount()
            let privateUsed = try await sessionStore.underlying.usedByteCount()
            #expect(sharedUsed == 0)
            #expect(privateUsed == 0)
        }
    }

    /// **Validates: Requirements 2.19, 11.13**
    @Test("The claiming port narrows a mismatch to exactly one handoff error")
    func theClaimingPortNarrowsAMismatchToOneHandoffError() async throws {
        try await withPairedRoots { roots in
            let appGroup = IngestLedgerStore(makeFileStore(root: roots.appGroup))
            let sessionStore = IngestLedgerStore(makeFileStore(root: roots.appPrivate))
            let bytes = Sample.bytes(count: largePayloadByteCount, seed: 92)
            let published = try await publishForMismatch(bytes: bytes, over: appGroup)
            var flipped = bytes
            flipped[0] ^= 0xFF
            appGroup.substituteRead(flipped, for: published.payloadKey)
            let adapter = makeClaimAdapter(
                appGroupStore: appGroup,
                sessionStore: sessionStore,
                chunkSizeInBytes: 512
            )

            // The narrow domain port has to report the mismatch as a thrown fault rather than
            // as a returned value, because `nil` means "nothing pending" and a failed handoff
            // must never be presented as an ordinary launch with no share.
            await #expect(throws: AnalysisFault.analysis(.handoffError, stage: .handoffVerification)) {
                try await adapter.claimReadyTransfer(claimingBuildID: Sample.buildID())
            }
        }
    }

    /// **Validates: Requirements 2.3, 2.12, 11.12**
    @Test("An unmutated claim verifies, so the mismatch arms are not vacuous")
    func anUnmutatedClaimVerifies() async throws {
        try await withPairedRoots { roots in
            let appGroup = IngestLedgerStore(makeFileStore(root: roots.appGroup))
            let sessionStore = IngestLedgerStore(makeFileStore(root: roots.appPrivate))
            let bytes = Sample.bytes(count: largePayloadByteCount, seed: 91)
            let published = try await publishForMismatch(bytes: bytes, over: appGroup)

            appGroup.forgetObservations()
            let claim = await makeClaimAdapter(
                appGroupStore: appGroup,
                sessionStore: sessionStore,
                chunkSizeInBytes: 512
            ).attemptClaim(claimingBuildID: Sample.buildID())

            let verified = try #require(claim.verifiedHandoff)
            #expect(verified.sessionID == published.ticket.sessionID)
            #expect(verified.transferID == published.ticket.transferID)
            #expect(verified.asset.sha256 == published.ticket.sha256)
            #expect(verified.asset.byteCount == published.ticket.byteCount)
            // Carried across unchanged rather than re-derived from the bytes.
            #expect(verified.asset.preservationStatus == published.ticket.preservationStatus)
            #expect(verified.asset.preservationBasis == published.ticket.preservationBasis)
            // The claim did read the payload once and did create one session object, which is
            // what makes the mismatch arms' zeros mean something.
            #expect(appGroup.readCount(of: published.payloadKey) == 1)
            #expect(sessionStore.createdObjectKeys().count == 1)
            let stored = try await soleSessionObject(
                of: published.ticket.sessionID,
                in: sessionStore.underlying
            )
            #expect(stored.bytes == bytes)
        }
    }

    /// **Validates: Requirements 2.19, 11.13**
    @Test("A record the decoder refuses is discarded without naming a session, as reported")
    func aRefusedRecordIsDiscardedWithoutNamingASession() async throws {
        try await withPairedRoots { roots in
            let appGroup = IngestLedgerStore(makeFileStore(root: roots.appGroup))
            let sessionStore = IngestLedgerStore(makeFileStore(root: roots.appPrivate))
            let bytes = Sample.bytes(count: largePayloadByteCount, seed: 93)
            let published = try await publishForMismatch(bytes: bytes, over: appGroup)

            // The recorded route changed to the other Version 1 route. `ShareTransferTicket`'s
            // decoder refuses any route but the Share route, so the record no longer decodes at
            // all and no session identifier survives it.
            let spliced = try #require(
                RecordMemberSplice.settingString(
                    "route",
                    to: InputRoute.photosPicker.rawValue,
                    in: published.recordBytes
                )
            )
            #expect(spliced.previousValue == InputRoute.shareExtension.rawValue)
            appGroup.substituteRead(spliced.bytes, for: published.recordKey)

            let claim = await makeClaimAdapter(
                appGroupStore: appGroup,
                sessionStore: sessionStore,
                chunkSizeInBytes: 512
            ).attemptClaim(claimingBuildID: Sample.buildID())

            // ─────────────────────────────────────────────────────────────────────────────
            // REPORTED GAP, asserted as observed rather than as correct.
            //
            // A handoff that *did* commit and was corrupted afterwards is here
            // indistinguishable from a publication that never committed: the record is
            // undecodable, so no session identifier is recoverable, the store reports a
            // missing record with no pending session, and the claim discards it. Requirements
            // 2.19 and 11.13 ask for `handoff-error` for a committed session whose bytes or
            // status no longer agree, and this path surfaces none.
            //
            // Task 4.8 found and reported the same tension for the single-field
            // `preservationStatus` and schema-version families, and it is awaiting a spec
            // decision. The substance still holds and is asserted below — no verdict, no
            // accepted ingest, nothing left on disk — but the label is not surfaced. Nothing
            // here asserts the observed disposition is correct, and nothing here changes
            // production.
            // ─────────────────────────────────────────────────────────────────────────────
            #expect(
                claim
                    == .discarded(
                        .defective(
                            DefectiveTransfer(
                                transferID: published.ticket.transferID,
                                pendingSession: nil,
                                defect: .manifestMissing
                            )
                        )
                    )
            )
            #expect(claim.failedHandoff == nil)
            #expect(claim.verifiedHandoff == nil)

            // Evidence safety, which does hold: no accepted ingest, no app-private object, and
            // nothing left in either store.
            #expect(sessionStore.createdObjectKeys().isEmpty)
            #expect(await transferScopes(of: appGroup.underlying).isEmpty)
            #expect(await sessionScopes(of: sessionStore.underlying).isEmpty)
            let sharedUsed = try await appGroup.underlying.usedByteCount()
            #expect(sharedUsed == 0)

            // The narrow domain port collapses a discard onto `nil`, which is the same answer
            // an empty slot gives, because both mean there is no session to resume and none to
            // terminate. Exercised on a second published handoff, because the first one's
            // material was removed by the discard above and the slot is empty again.
            let second = try await publishForMismatch(bytes: bytes, over: appGroup)
            let secondSpliced = try #require(
                RecordMemberSplice.settingString(
                    "route",
                    to: InputRoute.photosPicker.rawValue,
                    in: second.recordBytes
                )
            )
            appGroup.substituteRead(secondSpliced.bytes, for: second.recordKey)
            let port = try await makeClaimAdapter(
                appGroupStore: appGroup,
                sessionStore: sessionStore,
                chunkSizeInBytes: 512
            ).claimReadyTransfer(claimingBuildID: Sample.buildID())
            #expect(port == nil)
            #expect(await transferScopes(of: appGroup.underlying).isEmpty)
        }
    }

    // MARK: - Scenario 10: file protection

    /// **Validates: Requirement 9.6**
    @Test("This host does not enforce data protection, so no result here is release evidence")
    func thisHostDoesNotEnforceDataProtection() async throws {
        // Asserted rather than assumed, so it is visible in the run. The attribute is accepted
        // and reported on a development host; only iOS backs it with Data Protection, and
        // `PlatformDataProtection` reports that honestly instead of letting a host result stand
        // in for a device privacy gate.
        #expect(!PlatformDataProtection().enforcesDataProtection)
        try await withTemporaryRoot { root in
            let store = makeFileStore(root: root)
            #expect(!(await store.enforcesDataProtection))
        }
        // No level is unprotected, on any platform: there is no value to fall back to.
        #expect(FileProtectionLevel.allCases.count == 3)
    }

    /// **Validates: Requirement 9.6**
    @Test(
        "A requested level is either applied exactly or fails the retention closed",
        arguments: FileProtectionLevel.allCases
    )
    func aRequestedLevelIsAppliedExactlyOrFailsClosed(
        level: FileProtectionLevel
    ) async throws {
        try await withTemporaryRoot { root in
            // The container level matches the requested object level, so the arm is measuring
            // one level rather than a combination of two.
            let store = makeFileStore(root: root, containerProtection: level)
            let session = Sample.sessionID("session-t410-protection")
            let bytes = Sample.bytes(count: smallPayloadByteCount, seed: 101)
            let outcome = await makePhotosAdapter(
                access: FakePhotosAccess.lending(bytes),
                store: store,
                sessionFileProtection: level
            ).attemptImport(of: Sample.pickerItem(), into: session)

            switch outcome {
            case .success(let asset):
                // Exactly the requested level, never a different one: a level that read back
                // as something else is treated as unavailable rather than accepted.
                #expect(asset.handle.protection == level)
                let stored = try await soleSessionObject(of: session, in: store)
                #expect(stored.receipt.protection == level)
                for other in FileProtectionLevel.allCases where other != level {
                    #expect(asset.handle.protection != other)
                }
            case .failure(let failure):
                // The fail-closed path. Unprotected bytes are not an acceptable fallback, so a
                // level that cannot be applied refuses the retention and stores nothing.
                #expect(
                    failure == .representationNotRetained(.store(.protectionUnavailable(level)))
                        || failure == .representationNotRetained(.store(.storeUnavailable))
                )
                #expect(await sessionScopes(of: store).isEmpty)
                let used = try await store.usedByteCount()
                #expect(used == 0)
            }

            // Development hosts have been observed to accept a directory carrying the complete
            // or complete-unless-open attribute and then refuse to create or open a file for
            // writing inside it. That is a property of the host's keybag state, not of this
            // module, so it is recorded loudly as a known intermittent issue naming the level
            // rather than silently weakening the assertion above or skipping the arm.
            withKnownIssue(
                """
                This host could not apply a data-protection level, so the exact-level half of \
                this arm was not reached for it. The fail-closed half was asserted instead. A \
                host run is never Requirement 9.6 evidence; \
                ProtectedEphemeralFileStoreTests pins all three levels and the refusal.
                """,
                isIntermittent: true
            ) {
                if case .failure = outcome {
                    Issue.record(
                        "this host refused the \(level.rawValue) data-protection level"
                    )
                }
            }
        }
    }

    /// **Validates: Requirements 9.5, 9.6, 11.9**
    @Test("The staged level and the session level are sourced independently")
    func theStagedAndSessionLevelsAreSourcedIndependently() async throws {
        try await withPairedRoots { roots in
            // The staged level comes from the bound Extension Execution Policy; the session
            // level is injected into the claim adapter. Two sources, so a build cannot satisfy
            // one requirement by reusing the other's answer. The refusing applier is scoped to
            // the app-private store, so the staged side succeeds and the claim's recopy is the
            // side that has to fail closed.
            let refusedSessionLevel = FileProtectionLevel.complete
            let appGroup = IngestLedgerStore(makeFileStore(root: roots.appGroup))
            let sessionStore = IngestLedgerStore(
                makeFileStore(
                    root: roots.appPrivate,
                    containerProtection: integrationProtection,
                    protection: RefusingDataProtection(refusedLevel: refusedSessionLevel)
                )
            )
            let bytes = Sample.bytes(count: smallPayloadByteCount, seed: 102)
            let published = try await publishForMismatch(bytes: bytes, over: appGroup)

            // The staged object carries the policy's level, read back from what was written.
            let stagedKeys = await appGroup.underlying.keys(
                in: .transfer(published.ticket.transferID, .ready)
            )
            #expect(stagedKeys.contains(published.payloadKey))
            let stagedReceipt = try #require(
                await appGroup.underlying.receipt(for: published.payloadKey)
            )
            #expect(stagedReceipt.protection == integrationProtection)

            // The claim asks app-private storage for the injected level, which this applier
            // refuses, and the claim fails closed rather than recopying unprotected bytes.
            let claim = await makeClaimAdapter(
                appGroupStore: appGroup,
                sessionStore: sessionStore,
                sessionFileProtection: refusedSessionLevel
            ).attemptClaim(claimingBuildID: Sample.buildID())

            guard case .failed(let failed) = claim else {
                Issue.record("a refused session level must fail the claim closed, got \(claim)")
                return
            }
            #expect(
                failed.failure == .recopyRefused(.protectionUnavailable(refusedSessionLevel))
            )
            #expect(failed.sessionID == published.ticket.sessionID)
            expectExactlyHandoffError(failed.fault)
            // Nothing unprotected was left behind on either side.
            #expect(await sessionScopes(of: sessionStore.underlying).isEmpty)
            #expect(await transferScopes(of: appGroup.underlying).isEmpty)
            let privateUsed = try await sessionStore.underlying.usedByteCount()
            #expect(privateUsed == 0)
        }
    }

    // MARK: - Scenario 11: pending-slot recovery

    /// **Validates: Requirements 2.4, 9.5, 11.10**
    @Test("A pending handoff is offered for recovery without touching the host again")
    func aPendingHandoffIsOfferedForRecovery() async throws {
        try await withTemporaryRoot { root in
            let appGroup = IngestLedgerStore(makeFileStore(root: root))
            let transfers = makeExtensionSide(over: appGroup)
            let firstTimeline = HandoffTimeline()
            let first = try makeCoordinator(
                access: TimelineSharedItemAccess(
                    bytes: Sample.bytes(count: smallPayloadByteCount, seed: 111),
                    timeline: firstTimeline
                ),
                consentPresenter: TimelineConsentPresenter(
                    .confirmAfterDisplaying,
                    timeline: firstTimeline
                ),
                transfers: transfers
            )
            let ticket = try #require(
                await first.handleActivation(
                    Sample.activation(Sample.sharedProvider())
                ).publishedTicket
            )

            // A second activation, with its own host and its own consent screen.
            let secondTimeline = HandoffTimeline()
            let secondAccess = TimelineSharedItemAccess(
                bytes: Sample.bytes(count: smallPayloadByteCount, seed: 112),
                timeline: secondTimeline
            )
            let secondPresenter = TimelineConsentPresenter(
                .confirmAfterDisplaying,
                timeline: secondTimeline
            )
            let second = try makeCoordinator(
                access: secondAccess,
                consentPresenter: secondPresenter,
                transfers: transfers,
                candidateSessions: FixedCandidateSessionIdentifierSource(
                    Sample.sessionID("session-t410-second-candidate")
                )
            )
            let outcome = await second.handleActivation(
                Sample.activation(Sample.sharedProvider(token: 2))
            )

            // The handoff the user already consented to is never replaced, and the second
            // activation is answered with a recovery instruction instead.
            #expect(
                outcome
                    == .pendingHandoff(
                        PendingHandoffRecovery(
                            pendingTransfer: ticket.transferID,
                            instruction: Sample.manualInstruction()
                        )
                    )
            )
            #expect(outcome.publishedTicket == nil)
            // Asking again would offer a handoff that cannot be performed, so the second
            // consent action never appears and the second host is never touched.
            #expect(await secondPresenter.askedRequests.isEmpty)
            #expect(await secondAccess.requestedProviders.isEmpty)
            #expect(secondTimeline.recorded().isEmpty)

            // And the pending slot still holds exactly the first handoff, unchanged.
            let slot = try await transfers.readySlotState()
            #expect(slot.publishedTransfer?.ticket == ticket)
            let readyScopes = await appGroup.underlying.occupiedScopes().filter {
                if case .transfer(_, .ready) = $0 { return true }
                return false
            }
            #expect(readyScopes == [.transfer(ticket.transferID, .ready)])
        }
    }

    /// **Validates: Requirements 2.3, 9.5, 11.12, 11.16**
    @Test("Opening the pending handoff frees the slot for the next share")
    func openingThePendingHandoffFreesTheSlot() async throws {
        try await withPairedRoots { roots in
            let appGroup = IngestLedgerStore(makeFileStore(root: roots.appGroup))
            let sessionStore = IngestLedgerStore(makeFileStore(root: roots.appPrivate))
            let bytes = Sample.bytes(count: smallPayloadByteCount, seed: 113)
            let transfers = makeExtensionSide(over: appGroup)
            let firstTimeline = HandoffTimeline()
            let ticket = try #require(
                await makeCoordinator(
                    access: TimelineSharedItemAccess(bytes: bytes, timeline: firstTimeline),
                    consentPresenter: TimelineConsentPresenter(
                        .confirmAfterDisplaying,
                        timeline: firstTimeline
                    ),
                    transfers: transfers
                ).handleActivation(Sample.activation(Sample.sharedProvider())).publishedTicket
            )

            // A restart before the user opens the app keeps the consented handoff and removes
            // nothing else, which is what Requirements 9.9 and 11.16 ask of the next start.
            let report = try await transfers.runStartupCleanup()
            #expect(report.retainedTransfer == ticket.transferID)
            let slotAfterRestart = try await transfers.readySlotState()
            #expect(slotAfterRestart.publishedTransfer?.ticket == ticket)

            // The user opens DefAIke: the claim resumes exactly that session.
            let claim = await makeClaimAdapter(
                appGroupStore: appGroup,
                sessionStore: sessionStore
            ).attemptClaim(claimingBuildID: Sample.buildID())
            let verified = try #require(claim.verifiedHandoff)
            #expect(verified.sessionID == ticket.sessionID)
            let stored = try await soleSessionObject(
                of: ticket.sessionID,
                in: sessionStore.underlying
            )
            #expect(stored.bytes == bytes)

            // The slot is free, and the next share publishes an entirely new transfer.
            let slot = try await transfers.readySlotState()
            #expect(slot == .empty)
            #expect(await transferScopes(of: appGroup.underlying).isEmpty)

            let nextTimeline = HandoffTimeline()
            let nextTicket = try #require(
                await makeCoordinator(
                    access: TimelineSharedItemAccess(
                        bytes: Sample.bytes(count: smallPayloadByteCount, seed: 114),
                        timeline: nextTimeline
                    ),
                    consentPresenter: TimelineConsentPresenter(
                        .confirmAfterDisplaying,
                        timeline: nextTimeline
                    ),
                    transfers: transfers,
                    candidateSessions: FixedCandidateSessionIdentifierSource(
                        Sample.sessionID("session-t410-after-open")
                    )
                ).handleActivation(Sample.activation(Sample.sharedProvider())).publishedTicket
            )
            #expect(nextTicket.transferID != ticket.transferID)
            #expect(nextTicket.sessionID != ticket.sessionID)
        }
    }

    /// **Validates: Requirements 9.5, 9.8, 11.15**
    @Test("Discarding the pending handoff frees the slot and leaves no bytes")
    func discardingThePendingHandoffFreesTheSlot() async throws {
        try await withTemporaryRoot { root in
            let appGroup = IngestLedgerStore(makeFileStore(root: root))
            let transfers = makeExtensionSide(over: appGroup)
            let timeline = HandoffTimeline()
            let ticket = try #require(
                await makeCoordinator(
                    access: TimelineSharedItemAccess(
                        bytes: Sample.bytes(count: smallPayloadByteCount, seed: 115),
                        timeline: timeline
                    ),
                    consentPresenter: TimelineConsentPresenter(
                        .confirmAfterDisplaying,
                        timeline: timeline
                    ),
                    transfers: transfers
                ).handleActivation(Sample.activation(Sample.sharedProvider())).publishedTicket
            )

            // The other half of the recovery instruction: the user discards rather than opens.
            // Every state of the transfer goes, and the removal is idempotent.
            let receipts = try await transfers.discardTransfer(
                ticket.transferID,
                reason: .abandoned
            )
            #expect(receipts.count == TransferSlotState.allCases.count)
            #expect(receipts.allSatisfy { $0.reason == .abandoned })
            #expect(receipts.reduce(0) { $0 + $1.removedObjectCount } == 2)
            let repeated = try await transfers.discardTransfer(
                ticket.transferID,
                reason: .abandoned
            )
            #expect(repeated.reduce(0) { $0 + $1.removedObjectCount } == 0)

            let slot = try await transfers.readySlotState()
            #expect(slot == .empty)
            #expect(await transferScopes(of: appGroup.underlying).isEmpty)
            let used = try await appGroup.underlying.usedByteCount()
            #expect(used == 0)

            // And the next share publishes normally.
            let nextTimeline = HandoffTimeline()
            let nextTicket = try #require(
                await makeCoordinator(
                    access: TimelineSharedItemAccess(
                        bytes: Sample.bytes(count: smallPayloadByteCount, seed: 116),
                        timeline: nextTimeline
                    ),
                    consentPresenter: TimelineConsentPresenter(
                        .confirmAfterDisplaying,
                        timeline: nextTimeline
                    ),
                    transfers: transfers,
                    candidateSessions: FixedCandidateSessionIdentifierSource(
                        Sample.sessionID("session-t410-after-discard")
                    )
                ).handleActivation(Sample.activation(Sample.sharedProvider())).publishedTicket
            )
            #expect(nextTicket.transferID != ticket.transferID)
        }
    }

    /// **Validates: Requirements 9.9, 11.16**
    @Test("An expired pending handoff is not a session, and does not block the next share")
    func anExpiredPendingHandoffDoesNotBlockTheNextShare() async throws {
        try await withPairedRoots { roots in
            let appGroup = IngestLedgerStore(makeFileStore(root: roots.appGroup))
            let sessionStore = IngestLedgerStore(makeFileStore(root: roots.appPrivate))
            // A synthetic deadline. The real numbers are an unresolved external decision.
            let abandonedMilliseconds: UInt64 = 60_000
            let policy = Sample.lifecyclePolicy(abandonedMilliseconds: abandonedMilliseconds)
            let publishing = makeExtensionSide(over: appGroup, lifecyclePolicy: policy)
            let timeline = HandoffTimeline()
            let ticket = try #require(
                await makeCoordinator(
                    access: TimelineSharedItemAccess(
                        bytes: Sample.bytes(count: smallPayloadByteCount, seed: 117),
                        timeline: timeline
                    ),
                    consentPresenter: TimelineConsentPresenter(
                        .confirmAfterDisplaying,
                        timeline: timeline
                    ),
                    transfers: publishing
                ).handleActivation(Sample.activation(Sample.sharedProvider())).publishedTicket
            )

            // Later, past the abandoned-session deadline. The comparison is inclusive, so
            // material exactly at its deadline is due for cleanup.
            let later = fixtureNow.addingTimeInterval(
                Double(abandonedMilliseconds) / 1_000
            )
            let afterExpiry = makeExtensionSide(
                over: appGroup,
                lifecyclePolicy: policy,
                now: later
            )
            let expiredSlot = try await afterExpiry.readySlotState()
            #expect(expiredSlot == .unusable(.expired(ticket.transferID)))
            #expect(expiredSlot.publishedTransfer == nil)

            // An expired pending handoff is discarded under the lifecycle policy rather than
            // reported as a failed analysis: there is no session for the app to terminate.
            let claim = await makeClaimAdapter(
                appGroupStore: appGroup,
                sessionStore: sessionStore,
                lifecyclePolicy: policy,
                now: later
            ).attemptClaim(claimingBuildID: Sample.buildID())
            #expect(claim == .discarded(.expired(ticket.transferID)))
            #expect(claim.failedHandoff == nil)
            #expect(claim.verifiedHandoff == nil)
            #expect(await sessionScopes(of: sessionStore.underlying).isEmpty)
            #expect(await transferScopes(of: appGroup.underlying).isEmpty)

            // And the next share is not blocked by what expired.
            let nextTimeline = HandoffTimeline()
            let nextTicket = try #require(
                await makeCoordinator(
                    access: TimelineSharedItemAccess(
                        bytes: Sample.bytes(count: smallPayloadByteCount, seed: 118),
                        timeline: nextTimeline
                    ),
                    consentPresenter: TimelineConsentPresenter(
                        .confirmAfterDisplaying,
                        timeline: nextTimeline
                    ),
                    transfers: afterExpiry,
                    candidateSessions: FixedCandidateSessionIdentifierSource(
                        Sample.sessionID("session-t410-after-expiry")
                    )
                ).handleActivation(Sample.activation(Sample.sharedProvider())).publishedTicket
            )
            #expect(nextTicket.transferID != ticket.transferID)
        }
    }
}

/// A scaffolding precondition this file could not satisfy.
///
/// Thrown rather than force-unwrapped so a broken arm fails at its own line with a name,
/// instead of trapping and taking the whole run with it.
private enum IntegrationScaffoldingFault: Error, Hashable, Sendable {
    case noPublishedRecord(ShareTransferID)
}
