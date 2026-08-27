import DefAIkeDomain
import Foundation
import PropertyBased
import Testing

@testable import DefAIkeSharedTransfer

// Design Property 7: a declined or prepublication-cancelled handoff has no side effect.
//
// The design states it as: for any valid Share Extension input, declining consent or
// cancelling the handoff before successful atomic ready publication leaves no ready transfer,
// Analysis Session, main-app analysis, or evidence verdict.
//
// Requirement 2.4 is the sentence being quantified: a declined or cancelled Share handoff
// ends without creating an Analysis Session, starting main-application analysis, or producing
// an evidence verdict. Publication is the Share route's only session-creation commit
// (Requirement 2.3), so "before that commit" is a *prefix* of the flow rather than a single
// instant, and this file walks the whole prefix: the consent action, the provider's access
// window, the streaming copy, and the atomic promotion. Every stop point in
// ``PrepublicationStopPoint`` runs on every generated case, so the property is quantified over
// where the handoff stopped as well as over the input.
//
// For each stop point the five absences the design names are measured on real surfaces:
//
//   * **no ready transfer** — the ready slot resolves `.empty`, no `.transfer(_, .ready)`
//     scope exists, and the App Group container owns no transfer scope in any state;
//   * **no Analysis Session** — the candidate identifier the extension allocated never
//     becomes pending, and the main app's claim finds `.nothingPending`;
//   * **no main-app analysis** — the claim read nothing out of the shared container and wrote
//     nothing into app-private session storage, so the verification path never ran;
//   * **no evidence verdict** — no accepted ingest exists, so nothing was handed to the
//     Input Validator, the provenance lane, or pixel inference, and a cancellation carries
//     the cancelled fault rather than any Analysis Error category (Requirement 11.17);
//   * **nothing left behind** — the shared container holds zero bytes, the staging scope was
//     removed, no resource headroom stayed reserved, and the host's own representation is
//     byte for byte what it was.
//
// ## Why the absences are not vacuous, which is the whole difficulty of this property
//
// Every assertion above is an absence, and absences are the easiest thing in the world to
// satisfy by accident: a store that cannot create a file, a coordinator that was never
// constructed, or a fixture that stopped being buildable all produce them for free. Three
// habits close that gap, and none of them is optional here.
//
//   1. **A positive control on every case.** Beside the seven stopped handoffs, each case runs
//      one handoff that is *not* stopped, in its own container. It must publish, must occupy
//      exactly one ready slot, must create the pending session the extension named, must be
//      claimable, must move the container's byte count above zero, and must hand exactly one
//      handle to each downstream consumer. Every zero asserted above is asserted against a
//      run that produced the same measurement as nonzero moments earlier, on the same store
//      implementation, at the same protection level.
//   2. **The stop point must be shown to have been reached.**
//      ``ReferenceStopPointModel`` states, from the flow order the requirements fix rather
//      than from the code, how far each point gets: whether the consent action was displayed,
//      whether the host was asked, whether its window opened, how many objects were created,
//      how many chunks reached the payload, and whether the promotion was attempted. A point
//      that silently degenerated into "stopped before anything happened" disagrees with that
//      table and fails, so "no bytes remain" cannot pass because no byte was ever attempted.
//   3. **The mid-copy point is pinned to the interior.** Its cancellation is required to have
//      landed after at least one chunk and before the last, and the bytes that reached storage
//      are required to be more than none and fewer than all. A partial copy really was in
//      flight when it was cancelled.
//
// ## What each stop point is, and which of them is a user action
//
// Five of the seven are user cancellations or a decline, and they reach production through the
// two seams a user acts on: ``ShareConsentDecision`` and task cancellation, which
// `EncodedAssetRetainer` observes at every chunk boundary.
//
// The seventh, ``PrepublicationStopPoint/interruptedAtTheAtomicPromotion``, is an
// interruption rather than a user action, and it is here because it is the last point in the
// prefix. A genuine user cancellation at that exact instant is not observable by production
// code and deliberately so: the copy has finished, and between the manifest's finalize and the
// promotion's rename there is no cancellation checkpoint, so a task cancelled there commits
// and publishes. That is not a counterexample to the property — the publication *succeeded*,
// so the property's antecedent does not hold — and inventing a checkpoint to make the arm
// symmetric would be adding production behavior no requirement asks for. What the arm
// therefore stops is the promotion itself, which is the only way a host can reach that
// boundary, and the outcome is checked to be a no-session failure carrying `handoff-error`
// rather than a cancellation wearing an error category or a cancellation wearing none.
// `SharedTransferStoreTests` and `ShareExtensionIngestCoordinatorTests` pin the same boundary
// at examples through the shared `PromotionRefusingStore`; the store below is this file's own
// so that the same wrapper can carry the append ledger the reached-ness table needs.
//
// ## What this file deliberately does not assert
//
//   * Byte, count, digest, and status preservation across a *completed* handoff. That is
//     Property 5's statement. The control here publishes and claims in order to be a control,
//     and checks only that it produced the session and the bytes it was asked for.
//   * Mutation of a published ticket, payload, count, digest, status, schema field, or build
//     field. That is Property 6's statement, and nothing below alters a published transfer:
//     the stopped arms never publish one, and the control's is read and claimed unchanged.
//   * Item counts, provider counts, and route vocabulary. That is Property 4's statement, and
//     every count below is held at exactly one so a refusal cannot be mistaken for a stopped
//     handoff.
//   * The pending-handoff recovery instruction, which is a *second* activation meeting a slot
//     the first one filled. No arm below ever fills a slot another arm can see.
//
// ## The protection level is structural here, and it is held fixed
//
// Every store, object, and policy below uses ``StopPointShape/protectionLevel``, and it is
// held at `completeUntilFirstUserAuthentication` rather than generated across the three
// levels. **No protection level in a test is an approved release value**, and a host run is
// never Requirement 9.6 evidence; the real `PlatformDataProtection` still applies the level
// and still verifies it read back, and the control's receipts are compared against the level
// that was requested.
//
// The reason it is pinned is an environment one, and for this property it is also a soundness
// one. On the development host these tests run on, creating a file inside a directory carrying
// the complete attribute is refused by the platform, so a store rooted under such a directory
// reports `.storeUnavailable` for reasons that have nothing to do with a handoff — measured by
// running this file at that level, where the control cannot publish and the arms below report
// a store failure in place of a cancellation. A store that cannot create a file leaves no
// ready transfer, no session, and no bytes, which is exactly what this property asserts, so
// pinning the level the platform permits is what keeps these arms from passing for the wrong
// reason, and the positive control is what proves they did not.
// `ProtectedEphemeralFileStoreTests` is where all three levels, the fail-closed refusal, and
// the verified read-back are pinned; nothing here weakens any of that, and none of it is
// Requirement 9.6 evidence, which only a physical device can produce.
//
// ## Nothing here is an approved release value
//
// The Share Extension Resource Budget, the Extension Execution Policy, the Data Lifecycle
// Policy, the store capacity, the copy key the manual instruction addresses, the buffer sizes,
// the byte counts, and every identifier are synthetic fixtures that exist so a port taking a
// signed artifact can be called at all. No number below may be copied into a shipping
// artifact.
//
// ## Why no arm throws
//
// `propertyCheck` runs its body under `try?`, so an error escaping the body reports a passing
// run in milliseconds with every arm skipped — and a property built entirely from absences is
// the easiest kind to pass that way. Nothing below rethrows: every throwing store,
// coordinator, and claim call is wrapped into a value or reported through `Issue.record`, and
// ``StopPointVariationWitness`` counts the cases and every arm *outside* the body, where an
// issue is not suppressed. The arm counters are compared against the case count rather than
// against a floor, and the last thing the body does is record that it reached the end, so a
// case that stopped early is countable rather than invisible.

extension Tag {
    /// Design Property 7.
    ///
    /// Declared in this file rather than in a shared tag namespace: each design property gets
    /// one dedicated file, and a shared namespace would be a merge point between property
    /// files written independently of each other.
    @Tag static var property7DeclinedOrCancelledHandoff: Self
}

@Suite(
    "Property 7: a declined or prepublication-cancelled handoff has no side effect",
    .tags(.property7DeclinedOrCancelledHandoff)
)
struct DeclinedOrCancelledHandoffPropertyTests {
    /// Runs at the library default of 100 generated cases, which is the minimum the design
    /// requires; `PropertyToolchainWiringTests` pins that default. Every generator is composed
    /// with `zip`, so the shrinkers compose.
    ///
    /// **Validates: Requirements 2.4**
    @Test("Declining or cancelling before the commit leaves no transfer, session, call, or verdict")
    func stoppingBeforeThePublicationCommitLeavesNothingBehind() async {
        let witness = StopPointVariationWitness()

        await propertyCheck(input: StopPointShape.generator) { shape in
            witness.record(shape)
            let scenario = StopPointScenario(shape: shape, witness: witness)
            defer { scenario.removeTemporaryRoots() }

            // The control runs first or last, so no stopped arm's absence can depend on a
            // published transfer having existed, or on one never having existed.
            if shape.controlRunsFirst { await scenario.checkAnUnstoppedHandoffPublishesAndClaims() }
            for point in shape.stopPointOrder {
                await scenario.checkStoppingAt(point)
            }
            if !shape.controlRunsFirst { await scenario.checkAnUnstoppedHandoffPublishesAndClaims() }

            scenario.checkCancellationNeverAcquiresAnErrorCategory()

            witness.recordCompletedBody()
        }

        witness.expectVariedBaselines()
    }
}

// MARK: - Where a handoff stopped

/// A point in the Share flow, before the atomic ready publication, at which the handoff ended.
///
/// The order of the cases is the order of the flow: consent is presented before the host is
/// asked, the host's window opens before a byte is read, the copy streams before the manifest
/// is written, and the promotion is last. Walking all seven is what makes the property a claim
/// about the whole prefix rather than about one convenient instant.
private enum PrepublicationStopPoint: String, Hashable, Sendable, CaseIterable {
    /// The activation ended before the consent action ever became visible.
    ///
    /// The presenter is reached and answers `cancelled` without having displayed anything, so
    /// this is distinguishable from ``cancelledAtTheConsentAction`` by what the user was shown
    /// rather than by what the coordinator decided. Both reduce to the same production
    /// decision, which is the point: the extension cannot tell them apart and must leave
    /// nothing behind either way.
    case abandonedBeforeTheConsentActionAppeared = "abandoned-before-consent-appeared"

    /// The consent action appeared and the user declined it (Requirement 2.4).
    case declinedAtTheConsentAction = "declined-at-consent"

    /// The consent action appeared and the user cancelled out of it (Requirement 2.4).
    case cancelledAtTheConsentAction = "cancelled-at-consent"

    /// Consent was confirmed and the host's access window closed with no representation,
    /// because the user cancelled while it was being retrieved.
    ///
    /// The window never opened onto a file, so the consume closure never ran and no byte of
    /// the shared item existed anywhere in DefAIke.
    case cancelledInTheProviderWindow = "cancelled-in-provider-window"

    /// The copy was cancelled at its first chunk boundary, before a byte reached storage.
    ///
    /// The host really did lend a representation and the staged object really was created, so
    /// this is the narrowest interesting point: something was created, and still nothing was
    /// written or kept.
    case cancelledBeforeTheFirstChunk = "cancelled-before-first-chunk"

    /// The copy was cancelled part way through, after at least one chunk and before the last.
    case cancelledPartwayThroughTheCopy = "cancelled-partway-through-copy"

    /// Staging finished — payload streamed, payload finalized, manifest written — and the
    /// atomic promotion never happened.
    ///
    /// An interruption rather than a user action; this file's header explains why the last
    /// point in the prefix has to be reached that way.
    case interruptedAtTheAtomicPromotion = "interrupted-at-atomic-promotion"

    /// Whether this point is a user decline or cancellation.
    ///
    /// Requirement 11.17 keeps cancellation out of the Analysis Error vocabulary, so the two
    /// families are checked against different outcomes and must not be collapsed.
    var isUserDecision: Bool { self != .interruptedAtTheAtomicPromotion }

    /// The consent answer this point drives.
    var consentScript: StopPointConsentPresenter.Script {
        switch self {
        case .abandonedBeforeTheConsentActionAppeared: .cancelWithoutDisplaying
        case .declinedAtTheConsentAction: .decline
        case .cancelledAtTheConsentAction: .cancelAfterDisplaying
        case .cancelledInTheProviderWindow,
             .cancelledBeforeTheFirstChunk,
             .cancelledPartwayThroughTheCopy,
             .interruptedAtTheAtomicPromotion:
            .confirm
        }
    }

    /// Whether the host offers a representation at all, or reports cancellation instead.
    var hostLendsARepresentation: Bool { self != .cancelledInTheProviderWindow }

    /// Whether this point stops the handoff by cancelling the task the copy runs in.
    var cancelsTheEnclosingTask: Bool {
        self == .cancelledBeforeTheFirstChunk || self == .cancelledPartwayThroughTheCopy
    }

    /// Whether this point refuses the atomic promotion.
    var refusesThePromotion: Bool { self == .interruptedAtTheAtomicPromotion }
}

// MARK: - The reference model

/// How far each stop point gets, written from the flow the requirements fix rather than from
/// the code under test.
///
/// The ordering is the requirement: the visible consent action comes before the host is
/// touched (Requirements 2.2 and 11.10), the host's window comes before a byte is read, and
/// the atomic publication is the only commit (Requirement 2.3). Reading the expected
/// reached-ness off this table rather than off the coordinator is what turns "the handoff
/// stopped where this arm meant it to" into a comparison against the requirement.
private enum ReferenceStopPointModel {
    /// What a stopped handoff is expected to have reached.
    struct Reach: Hashable, Sendable {
        /// Consent actions actually displayed to the user.
        let consentActionsDisplayed: Int
        /// Providers the host was asked about.
        let providersRequested: Int
        /// Times the host's access window opened onto a file.
        let windowsOpened: Int
        /// Objects created in the shared container.
        let objectsCreated: Int
        /// Attempts to promote staged material into the ready slot.
        let promotionsAttempted: Int
    }

    static func reach(
        of point: PrepublicationStopPoint,
        totalPayloadObjects: Int
    ) -> Reach {
        switch point {
        case .abandonedBeforeTheConsentActionAppeared:
            // The presenter answered without showing anything, so nothing downstream ran.
            return Reach(
                consentActionsDisplayed: 0,
                providersRequested: 0,
                windowsOpened: 0,
                objectsCreated: 0,
                promotionsAttempted: 0
            )
        case .declinedAtTheConsentAction, .cancelledAtTheConsentAction:
            // The action was shown and answered. The host is not reachable without a token.
            return Reach(
                consentActionsDisplayed: 1,
                providersRequested: 0,
                windowsOpened: 0,
                objectsCreated: 0,
                promotionsAttempted: 0
            )
        case .cancelledInTheProviderWindow:
            // Consent authorized the request, so the host was asked; it produced nothing.
            return Reach(
                consentActionsDisplayed: 1,
                providersRequested: 1,
                windowsOpened: 0,
                objectsCreated: 0,
                promotionsAttempted: 0
            )
        case .cancelledBeforeTheFirstChunk, .cancelledPartwayThroughTheCopy:
            // The window opened and the staged payload object was created. The manifest is
            // written only after the copy finalizes, so it does not exist yet.
            return Reach(
                consentActionsDisplayed: 1,
                providersRequested: 1,
                windowsOpened: 1,
                objectsCreated: 1,
                promotionsAttempted: 0
            )
        case .interruptedAtTheAtomicPromotion:
            // Staging is complete: the payload and the manifest both exist, and the first
            // promotion of the two was attempted and refused.
            return Reach(
                consentActionsDisplayed: 1,
                providersRequested: 1,
                windowsOpened: 1,
                objectsCreated: totalPayloadObjects,
                promotionsAttempted: 1
            )
        }
    }

    /// How many chunks are expected to have reached the payload object.
    ///
    /// `nil` where the number is a generated interior index rather than a derived constant;
    /// the mid-copy arm checks that index directly.
    static func payloadAppends(
        of point: PrepublicationStopPoint,
        totalAppends: Int
    ) -> Int? {
        switch point {
        case .abandonedBeforeTheConsentActionAppeared,
             .declinedAtTheConsentAction,
             .cancelledAtTheConsentAction,
             .cancelledInTheProviderWindow,
             .cancelledBeforeTheFirstChunk:
            return 0
        case .cancelledPartwayThroughTheCopy:
            return nil
        case .interruptedAtTheAtomicPromotion:
            return totalAppends
        }
    }
}

// MARK: - The main app's downstream consumers

/// A consumer the main application hands an accepted ingest to.
///
/// None of the three adapters is reachable from this module: the image pipeline, the
/// provenance modules, and the Core ML module are outside the closure the Share Extension
/// links, which `ShareExtensionIngestCoordinatorTests` pins by scanning the module's sources.
/// So what this vocabulary names is the *handoff to* each consumer, and what the ledger below
/// measures is whether ingest produced anything to hand over at all. For a stopped handoff
/// there is no accepted ingest, so every count is zero; the control produces one and hands it
/// over, which is what shows the counters move.
private enum MainAppConsumer: String, Hashable, Sendable, CaseIterable {
    case inputValidator = "input-validator"
    case provenanceLane = "provenance-lane"
    case pixelInference = "pixel-inference"
}

/// Records every handle handed to a downstream consumer.
///
/// A locked class rather than an actor, so the ledger can be read synchronously from an arm
/// without another suspension point in the middle of an assertion.
private final class MainAppCallLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var handlesByConsumer: [MainAppConsumer: [EncodedAssetHandle]] = [:]

    /// Hands `handle` to `consumer`, which is the only way a count here moves.
    func hand(_ handle: EncodedAssetHandle, to consumer: MainAppConsumer) {
        lock.lock()
        handlesByConsumer[consumer, default: []].append(handle)
        lock.unlock()
    }

    func callCount(of consumer: MainAppConsumer) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return handlesByConsumer[consumer]?.count ?? 0
    }

    var totalCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return handlesByConsumer.values.reduce(0) { $0 + $1.count }
    }

    /// Distinct handles handed to anyone. One means there was no second copy to diverge.
    var distinctHandles: Set<EncodedAssetHandle> {
        lock.lock()
        defer { lock.unlock() }
        return Set(handlesByConsumer.values.flatMap { $0 })
    }
}

// MARK: - The consent double

/// A ``ShareConsentPresenting`` that separates "was asked" from "showed the user something".
///
/// The shared `ScriptedConsentPresenter` records one list, which is the right shape for
/// asserting that the consent action never appeared. This property needs the finer
/// distinction: ``Script/cancelWithoutDisplaying`` is a handoff abandoned before the action
/// became visible, and it has to be separable from a cancellation of the visible action.
private actor StopPointConsentPresenter: ShareConsentPresenting {
    /// What this presenter does when it is asked.
    enum Script: Hashable, Sendable {
        /// Answer `cancelled` without ever displaying the action.
        case cancelWithoutDisplaying
        /// Display the action, then decline.
        case decline
        /// Display the action, then cancel.
        case cancelAfterDisplaying
        /// Display the action, then confirm for the provider and policy it was shown.
        case confirm
    }

    private let script: Script

    /// Requests this presenter was asked to answer, in order.
    private(set) var askedRequests: [ShareConsentRequest] = []

    /// Requests whose consent action was actually displayed, in order. Empty means the user
    /// was never shown anything.
    private(set) var displayedRequests: [ShareConsentRequest] = []

    init(_ script: Script) {
        self.script = script
    }

    func presentConsent(for request: ShareConsentRequest) async -> ShareConsentDecision {
        askedRequests.append(request)
        switch script {
        case .cancelWithoutDisplaying:
            return .cancelled
        case .decline:
            displayedRequests.append(request)
            return .declined
        case .cancelAfterDisplaying:
            displayedRequests.append(request)
            return .cancelled
        case .confirm:
            displayedRequests.append(request)
            return .confirmed(
                Sample.consent(
                    for: request.provider,
                    policyID: request.extensionExecutionPolicyID
                )
            )
        }
    }
}

// MARK: - Cancelling the copy while it is in flight

/// Cancels the task a staging copy runs in, either before it starts or after a chosen chunk.
///
/// `EncodedAssetRetainer` checks `Task.isCancelled` at every chunk boundary, which is the only
/// cancellation seam the copy has, so a mid-copy cancellation has to arrive as a real task
/// cancellation rather than as a store fault. Getting that deterministic without a sleep or a
/// poll is what this actor is for:
///
///   * the work is wrapped in a task that first waits on ``waitUntilArmed()``, so it cannot
///     race past the trigger before the trigger has been wired;
///   * ``arm(_:)`` supplies the cancellation, which fires immediately at index zero and
///     otherwise from inside the store's `append` once the chosen chunk has landed;
///   * the retainer's next loop iteration observes the cancellation and stops.
///
/// Nothing here blocks waiting for the trigger to be reached, so a copy that failed earlier
/// than expected fails an assertion instead of hanging the run.
private actor MidCopyCancellationTrip {
    /// Chunks to let through before cancelling. Zero cancels before the work begins.
    let triggerAppendIndex: Int

    private var cancellation: (@Sendable () -> Void)?
    private var isArmed = false
    private var gate: CheckedContinuation<Void, Never>?
    private var appendsSeen = 0
    private var appendsWhenCancelled: Int?

    init(triggerAppendIndex: Int) {
        self.triggerAppendIndex = triggerAppendIndex
    }

    /// Wires the cancellation and lets the gated work start.
    func arm(_ cancellation: @escaping @Sendable () -> Void) {
        self.cancellation = cancellation
        isArmed = true
        if triggerAppendIndex == 0 { fire() }
        gate?.resume()
        gate = nil
    }

    /// Suspends the work until ``arm(_:)`` has run. Returns immediately if it already has.
    func waitUntilArmed() async {
        if isArmed { return }
        await withCheckedContinuation { continuation in gate = continuation }
    }

    /// Counts one chunk that reached storage, and cancels once the trigger is due.
    func noteAppend() {
        appendsSeen += 1
        if triggerAppendIndex > 0, appendsSeen == triggerAppendIndex { fire() }
    }

    /// Chunks that had landed when cancellation was requested, or `nil` if it never was.
    var appendsBeforeCancellation: Int? { appendsWhenCancelled }

    /// Chunks that landed in total, so an arm can see the copy stopped rather than finished.
    var appendsObserved: Int { appendsSeen }

    private func fire() {
        guard appendsWhenCancelled == nil else { return }
        appendsWhenCancelled = appendsSeen
        cancellation?()
    }
}

// MARK: - A store that records what it was asked to do, and can refuse the promotion

/// The real protected store, wrapped so every create, append, finalize, read, promotion, and
/// removal is observable, and so the atomic promotion can be refused.
///
/// A wrapper rather than a double: the object on disk, its measurements, its protection level,
/// its atomic rename, and its removals are all the real ones, and the only things added are a
/// ledger and one scripted refusal. The ledger is what makes "the handoff got this far and no
/// further" a measurement — for a property built out of absences, the ledger is the only thing
/// that separates "nothing was left behind" from "nothing was ever attempted".
///
/// A locked class rather than an actor, so the ledger can be read synchronously from an arm
/// without another suspension point in the middle of an assertion.
private final class StopPointLedgerStore: EphemeralFileStoring, @unchecked Sendable {
    /// The real store. Held so an arm can reach the members the port does not expose.
    let underlying: ProtectedEphemeralFileStore

    /// Cancels the enclosing task at a chosen chunk boundary, when this arm has one.
    private let trip: MidCopyCancellationTrip?

    /// Whether the atomic promotion is refused. `nil` promotes for real.
    private let promotionFault: EphemeralStoreError?

    private let lock = NSLock()
    private var createdKeys: [EphemeralStorageKey] = []
    private var appendedLengthsByKey: [EphemeralStorageKey: [Int]] = [:]
    private var finalizedKeys: [EphemeralStorageKey] = []
    private var readKeys: [EphemeralStorageKey] = []
    private var promotionAttempts = 0
    private var deletedScopes: [EphemeralStorageScope] = []

    init(
        _ underlying: ProtectedEphemeralFileStore,
        trip: MidCopyCancellationTrip? = nil,
        promotionFault: EphemeralStoreError? = nil
    ) {
        self.underlying = underlying
        self.trip = trip
        self.promotionFault = promotionFault
    }

    // MARK: The ledger

    /// Objects created, in order. The staged payload is the first; a manifest is the second.
    func createdObjectKeys() -> [EphemeralStorageKey] {
        lock.lock()
        defer { lock.unlock() }
        return createdKeys
    }

    /// Chunk lengths appended to `key`, in order.
    func appendedLengths(to key: EphemeralStorageKey) -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        return appendedLengthsByKey[key] ?? []
    }

    func finalizeCount(of key: EphemeralStorageKey) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return finalizedKeys.filter { $0 == key }.count
    }

    /// Reads attempted across every key. Zero means nothing read this container.
    func totalReadCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return readKeys.count
    }

    func promotionAttemptCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return promotionAttempts
    }

    func scopesRemoved() -> Set<EphemeralStorageScope> {
        lock.lock()
        defer { lock.unlock() }
        return Set(deletedScopes)
    }

    /// Forgets the ledger without touching a byte on disk.
    ///
    /// Called between a publication and the claim that follows it, so the claim's counts
    /// describe the claim alone.
    func forgetObservations() {
        lock.lock()
        createdKeys = []
        appendedLengthsByKey = [:]
        finalizedKeys = []
        readKeys = []
        promotionAttempts = 0
        deletedScopes = []
        lock.unlock()
    }

    // MARK: Recording
    //
    // Each recorder is a separate synchronous method: `NSLock` is unavailable from an
    // asynchronous context, and the port members below are `async`.

    private func noteCreate(_ key: EphemeralStorageKey) {
        lock.lock()
        createdKeys.append(key)
        lock.unlock()
    }

    private func noteAppend(_ length: Int, to key: EphemeralStorageKey) {
        lock.lock()
        appendedLengthsByKey[key, default: []].append(length)
        lock.unlock()
    }

    private func noteFinalize(_ key: EphemeralStorageKey) {
        lock.lock()
        finalizedKeys.append(key)
        lock.unlock()
    }

    private func noteRead(_ key: EphemeralStorageKey) {
        lock.lock()
        readKeys.append(key)
        lock.unlock()
    }

    private func notePromotionAttempt() {
        lock.lock()
        promotionAttempts += 1
        lock.unlock()
    }

    private func noteDeletion(_ scope: EphemeralStorageScope) {
        lock.lock()
        deletedScopes.append(scope)
        lock.unlock()
    }

    // MARK: EphemeralFileStoring

    func create(
        in scope: EphemeralStorageScope,
        protection: FileProtectionLevel
    ) async throws(EphemeralStoreError) -> EphemeralStorageKey {
        let key = try await underlying.create(in: scope, protection: protection)
        noteCreate(key)
        return key
    }

    func append(
        _ chunk: [UInt8],
        to key: EphemeralStorageKey
    ) async throws(EphemeralStoreError) {
        try await underlying.append(chunk, to: key)
        // Counted after the call, so a length here is a length that reached storage.
        noteAppend(chunk.count, to: key)
        // The cancellation lands between two chunks, which is where the retainer looks.
        await trip?.noteAppend()
    }

    func finalize(
        _ key: EphemeralStorageKey
    ) async throws(EphemeralStoreError) -> EphemeralWriteReceipt {
        let receipt = try await underlying.finalize(key)
        noteFinalize(key)
        return receipt
    }

    func read(_ key: EphemeralStorageKey) async throws(EphemeralStoreError) -> [UInt8] {
        // Counted before the call, so a read that failed is still a read that happened.
        noteRead(key)
        return try await underlying.read(key)
    }

    func receipt(for key: EphemeralStorageKey) async -> EphemeralWriteReceipt? {
        await underlying.receipt(for: key)
    }

    func move(
        _ key: EphemeralStorageKey,
        to scope: EphemeralStorageScope
    ) async throws(EphemeralStoreError) {
        notePromotionAttempt()
        if let promotionFault { throw promotionFault }
        try await underlying.move(key, to: scope)
    }

    func keys(in scope: EphemeralStorageScope) async -> Set<EphemeralStorageKey> {
        await underlying.keys(in: scope)
    }

    func deleteAll(
        in scope: EphemeralStorageScope,
        reason: SessionCleanupReason
    ) async throws(EphemeralStoreError) -> EphemeralDeletionReceipt {
        noteDeletion(scope)
        return try await underlying.deleteAll(in: scope, reason: reason)
    }

    func occupiedScopes() async -> Set<EphemeralStorageScope> {
        await underlying.occupiedScopes()
    }
}

// MARK: - One App Group container and the app on the other side of it

/// The two roots one handoff spans, and the real surfaces on each side of it.
///
/// Two separate stores, because the whole point of "no main-app analysis" is that nothing
/// reached app-private storage. Two separate `SharedTransferStore` instances over one shared
/// container, because the extension and the app are two processes: one stages and the other
/// claims, so a claim that finds nothing really did look across a boundary.
private struct StopPointContainer {
    let appGroupRoot: URL
    let sessionRoot: URL

    /// The shared container, with a ledger and this arm's scripted promotion behavior.
    let appGroup: StopPointLedgerStore

    /// App-private session storage, with a ledger. Anything here is a main-app side effect.
    let session: StopPointLedgerStore

    /// The extension's view of the transfer store.
    let extensionSide: SharedTransferStore

    /// The main app's claim.
    let claimAdapter: ShareHandoffClaimAdapter

    init(
        appGroupRoot: URL,
        sessionRoot: URL,
        shape: StopPointShape,
        trip: MidCopyCancellationTrip? = nil,
        promotionFault: EphemeralStoreError? = nil
    ) {
        self.appGroupRoot = appGroupRoot
        self.sessionRoot = sessionRoot
        let appGroup = StopPointLedgerStore(
            ProtectedEphemeralFileStore(
                configuration: .test(
                    root: appGroupRoot,
                    containerProtection: shape.protectionLevel
                ),
                protection: PlatformDataProtection(),
                clock: FixedClock(fixtureNow)
            ),
            trip: trip,
            promotionFault: promotionFault
        )
        let session = StopPointLedgerStore(
            ProtectedEphemeralFileStore(
                configuration: .test(
                    root: sessionRoot,
                    containerProtection: shape.protectionLevel
                ),
                protection: PlatformDataProtection(),
                clock: FixedClock(fixtureNow)
            )
        )
        self.appGroup = appGroup
        self.session = session
        let policy = Sample.extensionPolicy(stagedFileProtection: shape.protectionLevel)
        self.extensionSide = SharedTransferStore.test(
            over: appGroup,
            extensionPolicy: policy,
            chunkSizeInBytes: shape.chunkSizeInBytes
        )
        self.claimAdapter = ShareHandoffClaimAdapter(
            transfers: SharedTransferStore.test(
                over: appGroup,
                extensionPolicy: policy,
                chunkSizeInBytes: shape.chunkSizeInBytes
            ),
            sessionStore: session,
            sessionFileProtection: shape.protectionLevel,
            chunkSizeInBytes: shape.chunkSizeInBytes
        )
    }

    /// Transfer scopes the shared container still owns, in any of the three states.
    func transferScopes() async -> Set<EphemeralStorageScope> {
        await appGroup.underlying.occupiedScopes().filter { scope in
            if case .transfer = scope { return true }
            return false
        }
    }

    /// Ready transfer scopes the shared container still owns.
    func readyTransferScopes() async -> Set<EphemeralStorageScope> {
        await appGroup.underlying.occupiedScopes().filter { scope in
            if case .transfer(_, .ready) = scope { return true }
            return false
        }
    }
}

// MARK: - What one stopped handoff did

/// One activation's outcome, and what every spy around it observed.
private struct StoppedAttempt {
    let outcome: ShareHandoffOutcome
    let consentActionsAsked: Int
    let consentActionsDisplayed: Int
    let providersRequested: Int
    let windowsOpened: Int
    /// Reservations the governor still holds. Nonempty is a headroom leak.
    let outstandingReservations: Int
    /// The bytes the host lent, read back after the attempt, when it lent any.
    let hostRepresentation: [UInt8]?
}

// MARK: - Generated shape

/// One generated case, plus the fixtures derived from it.
///
/// Every field is a bounded integer or a flag, and each derived value is read off the shape by
/// modulus, so a family is exercised across all of its members over 100 cases instead of
/// collapsing onto one.
private struct StopPointShape: Sendable, CustomStringConvertible {
    /// Drives the generated byte content, the mid-copy trigger, and every synthetic
    /// identifier suffix, so a case's values vary together and a failing case names one seed.
    let seed: Int

    /// Bytes in the generated representation.
    ///
    /// Bounded well below the synthetic budget and store ceilings: a size large enough to
    /// reach a limit would stop the handoff for a resource reason instead of the generated
    /// one, and a resource breach is Requirement 11.8's statement rather than this property's.
    let byteCount: Int

    let appendTargetIndex: Int
    let formIndex: Int
    let hintIndex: Int
    let orderIndex: Int

    /// Whether the unstopped control runs before the stopped arms.
    let controlRunsFirst: Bool

    // MARK: The generated representation

    var bytes: [UInt8] { Sample.bytes(count: byteCount, seed: UInt8(truncatingIfNeeded: seed)) }

    /// The digest of the generated sequence, computed here rather than read from any value
    /// under test. The control's ticket is compared against this.
    var expectedDigest: DefAIkeDomain.SHA256Digest { StreamingSHA256.digest(of: Data(bytes)) }

    // MARK: The copy's partition

    /// Chunks the staging copy aims for.
    ///
    /// At least three, so the mid-copy trigger has a strict interior to land in: one chunk
    /// would make "after the first and before the last" empty.
    var appendTarget: Int { Self.appendTargets[appendTargetIndex % Self.appendTargets.count] }

    /// I/O buffer size for the streaming copy, derived so the append count is knowable.
    ///
    /// Structural scaffolding, not an approved value: it changes how many passes a copy takes,
    /// never how large a copy may be.
    var chunkSizeInBytes: Int { max(1, byteCount / appendTarget) }

    /// Chunk lengths the whole copy would write.
    var appendLengths: [Int] {
        Self.uniformLengths(of: byteCount, chunkedBy: chunkSizeInBytes)
    }

    var totalAppendCount: Int { appendLengths.count }

    /// The chunk after which the mid-copy cancellation lands.
    ///
    /// Strictly inside the copy: at least one chunk has reached storage and at least one has
    /// not, so the arm measures a partial copy rather than a copy that had not begun or one
    /// that had already finished.
    var midCopyTriggerIndex: Int {
        guard totalAppendCount > 1 else { return 1 }
        return 1 + (seed % (totalAppendCount - 1))
    }

    /// Bytes that reach storage before the mid-copy cancellation.
    var midCopyByteCount: Int {
        appendLengths.prefix(midCopyTriggerIndex).reduce(0, +)
    }

    // MARK: Protection

    /// The data-protection level every store, object, and policy in this file uses.
    ///
    /// Structural scaffolding, not an approved value, and deliberately not generated. See this
    /// file's header for the environment reason it is held fixed and why that matters more
    /// here than elsewhere, and `ProtectedEphemeralFileStoreTests` for where all three levels
    /// and the fail-closed refusal are pinned.
    static let protectionLevel: FileProtectionLevel = .completeUntilFirstUserAuthentication

    var protectionLevel: FileProtectionLevel { Self.protectionLevel }

    // MARK: Derived fixtures

    var sharedForm: SharedRepresentationForm {
        SharedRepresentationForm.allCases[formIndex % SharedRepresentationForm.allCases.count]
    }

    var contentTypeHint: ContentTypeHint? {
        guard let raw = Self.hints[hintIndex % Self.hints.count] else { return nil }
        return Sample.contentTypeHint(raw)
    }

    /// Exactly one provider offering exactly one item, so a count refusal cannot be mistaken
    /// for a stopped handoff. Counts are Property 4's statement.
    var provider: SharedItemProvider {
        Sample.sharedProvider(token: 1, itemCount: 1, contentTypeHint: contentTypeHint)
    }

    var activation: ShareActivation { Sample.activation(provider) }

    /// The order the stop points run in.
    ///
    /// Rotated by the generated index, so no arm's absence can depend on another arm having
    /// run before it.
    var stopPointOrder: [PrepublicationStopPoint] {
        let all = PrepublicationStopPoint.allCases
        let offset = orderIndex % all.count
        return Array(all[offset...]) + Array(all[..<offset])
    }

    var firstStopPoint: PrepublicationStopPoint {
        // The rotation is over a nonempty `CaseIterable`, so this is never the fallback.
        stopPointOrder.first ?? .declinedAtTheConsentAction
    }

    // MARK: Identifiers

    /// The candidate identifier a stopped arm allocates.
    ///
    /// Distinct per stop point, so "no session was created" is a statement about *this* arm's
    /// candidate rather than about some identifier nobody named.
    func candidateSessionID(for point: PrepublicationStopPoint) -> AnalysisSessionID {
        Sample.sessionID("session-p7-\(point.rawValue)")
    }

    var controlCandidateSessionID: AnalysisSessionID { Sample.sessionID("session-p7-control") }

    /// An identifier no arm may ever resume.
    ///
    /// "The control resumed the identifier the extension allocated" needs a value the claim
    /// could have produced instead, or the assertion is only that claim produced *something*.
    var decoySessionID: AnalysisSessionID { Sample.sessionID("session-p7-decoy") }

    // MARK: Tables

    /// Target chunk counts for the staging copy. Structural test scaffolding.
    static let appendTargets = [3, 5, 8, 13]

    /// Provider-declared type hints, including none. Recorded, never trusted.
    static let hints: [String?] = [nil, "public.jpeg", "public.png", "public.heic", "public.heif"]

    /// Lengths of a uniform partition of `total` bytes into buffers of `chunk` bytes.
    static func uniformLengths(of total: Int, chunkedBy chunk: Int) -> [Int] {
        guard total > 0, chunk > 0 else { return [] }
        var lengths: [Int] = []
        var remaining = total
        while remaining > 0 {
            let take = min(chunk, remaining)
            lengths.append(take)
            remaining -= take
        }
        return lengths
    }

    var description: String {
        """
        seed \(seed), \(byteCount) bytes, form \(sharedForm.rawValue), \
        hint \(contentTypeHint?.rawValue ?? "none"), chunk \(chunkSizeInBytes) \
        (\(totalAppendCount) appends, mid-copy after \(midCopyTriggerIndex)), \
        first stop \(firstStopPoint.rawValue), control first \(controlRunsFirst)
        """
    }

    // MARK: Generator

    static var generator: Generator<StopPointShape, AnySequence<Any>> {
        zip(
            Gen.int(in: 0...9_999),
            Gen.int(in: 64...4_000),
            index,
            index,
            index,
            zip(index, Gen.bool)
        )
        .map { raw in
            StopPointShape(
                seed: raw.0,
                byteCount: raw.1,
                appendTargetIndex: raw.2,
                formIndex: raw.3,
                hintIndex: raw.4,
                orderIndex: raw.5.0,
                controlRunsFirst: raw.5.1
            )
        }
        .eraseToAny()
    }

    /// A selector index.
    ///
    /// The range is a multiple of every modulus it is reduced by (2, 4, 5, 7), so each table
    /// entry and each rotation is drawn with equal probability rather than with a modulus
    /// bias.
    private static var index: Generator<Int, AnySequence<Any>> {
        Gen.int(in: 0...279).eraseToAny()
    }
}

// MARK: - The scenario

/// One generated case, run against the real consent, staging, publication, and claim surfaces.
///
/// Eight containers, because each arm has to be able to say "this container holds nothing"
/// without another arm's material satisfying or spoiling it: the seven stopped arms each own a
/// shared container and an app-private store, and the control owns its own pair so its
/// published transfer never occupies a slot a stopped arm would then meet as a pending
/// handoff.
private struct StopPointScenario {
    let shape: StopPointShape
    let witness: StopPointVariationWitness

    private let control: StopPointContainer
    private let stopped: [PrepublicationStopPoint: StopPointContainer]
    private let trips: [PrepublicationStopPoint: MidCopyCancellationTrip]

    init(shape: StopPointShape, witness: StopPointVariationWitness) {
        self.shape = shape
        self.witness = witness
        self.control = StopPointContainer(
            appGroupRoot: Self.temporaryRoot("control-appgroup"),
            sessionRoot: Self.temporaryRoot("control-session"),
            shape: shape
        )

        var trips: [PrepublicationStopPoint: MidCopyCancellationTrip] = [:]
        var containers: [PrepublicationStopPoint: StopPointContainer] = [:]
        for point in PrepublicationStopPoint.allCases {
            let trip: MidCopyCancellationTrip?
            switch point {
            case .cancelledBeforeTheFirstChunk:
                trip = MidCopyCancellationTrip(triggerAppendIndex: 0)
            case .cancelledPartwayThroughTheCopy:
                trip = MidCopyCancellationTrip(triggerAppendIndex: shape.midCopyTriggerIndex)
            default:
                trip = nil
            }
            if let trip { trips[point] = trip }
            containers[point] = StopPointContainer(
                appGroupRoot: Self.temporaryRoot("\(point.rawValue)-appgroup"),
                sessionRoot: Self.temporaryRoot("\(point.rawValue)-session"),
                shape: shape,
                trip: trip,
                promotionFault: point.refusesThePromotion ? .storeUnavailable : nil
            )
        }
        self.trips = trips
        self.stopped = containers
    }

    /// Removes every directory this case owned.
    ///
    /// Synchronous and unconditional so it can run from a `defer` in the property body, and
    /// tolerant of a root that was never created: an arm whose store was never written to has
    /// nothing on disk, which is not a failure.
    func removeTemporaryRoots() {
        var roots = [control.appGroupRoot, control.sessionRoot]
        for container in stopped.values {
            roots.append(container.appGroupRoot)
            roots.append(container.sessionRoot)
        }
        for root in roots {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - The positive control

    /// A handoff that is *not* stopped publishes once, creates the pending session the
    /// extension named, is claimable, and moves every counter the stopped arms require to be
    /// zero (Requirements 2.3 and 11.12).
    ///
    /// This is what makes the rest of the file mean anything. It runs on every generated case
    /// rather than once, against the same store implementation and the same protection level,
    /// so a store that could not create a file, a coordinator that would not construct, or a
    /// fixture that stopped being buildable fails here instead of quietly satisfying seven
    /// absences.
    func checkAnUnstoppedHandoffPublishesAndClaims() async {
        let candidate = shape.controlCandidateSessionID
        let access = FakeSharedItemAccess(
            .representation(bytes: shape.bytes, form: shape.sharedForm),
            reclaimsRepresentation: false
        )
        let presenter = StopPointConsentPresenter(.confirm)
        let governor = ProgrammedShareResourceGovernor()
        guard
            let coordinator = ShareExtensionIngestCoordinator(
                access: access,
                consentPresenter: presenter,
                transfers: control.extensionSide,
                governor: governor,
                budget: Sample.shareBudget(),
                instruction: Sample.manualInstruction(),
                candidateSessions: FixedCandidateSessionIdentifierSource(candidate)
            )
        else {
            reportUnbuildableInput("the Share ingest coordinator fixture must be constructible")
            return
        }

        guard let before = await readySlot(of: control) else { return }
        #expect(before == ReadySlotState.empty)
        #expect(await control.readyTransferScopes().isEmpty)
        #expect(await usedBytes(of: control) == 0)

        let outcome = await coordinator.handleActivation(shape.activation)
        await access.cleanUp()

        guard let ticket = outcome.publishedTicket else {
            reportUnbuildableInput(
                """
                the control must publish: a consented one-item activation at \
                \(shape.protectionLevel) produced \(outcome)
                """
            )
            return
        }

        // The consent action appeared and the host was asked, so the spies the stopped arms
        // read zeroes from do record a call when one is made.
        #expect(await presenter.displayedRequests.count == 1)
        #expect(await access.requestedProviders.count == 1)
        #expect(await access.consumeCount == 1)

        // Exactly one ready transfer, and exactly one pending session, and it is the candidate
        // the extension allocated rather than any other identifier.
        #expect(await control.readyTransferScopes().count == 1)
        #expect(ticket.sessionID == candidate)
        #expect(ticket.sessionID != shape.decoySessionID)
        #expect(ticket.route == .shareExtension)
        #expect(ticket.byteCount == UInt64(shape.byteCount))
        #expect(ticket.sha256 == shape.expectedDigest)
        #expect(ticket.contentTypeHint == shape.contentTypeHint)
        if let published = await readySlot(of: control)?.publishedTransfer {
            #expect(published.ticket == ticket)
        } else {
            Issue.record("a published handoff must leave exactly one pending transfer")
        }

        // The container holds bytes. This is the measurement every stopped arm asserts as
        // zero, taken on the same store moments apart.
        if let used = await usedBytes(of: control) {
            #expect(
                used > 0,
                "a published transfer must occupy storage; the container reports \(used) bytes"
            )
            #expect(used >= UInt64(shape.byteCount))
        }

        // The whole copy streamed, and the manifest joined it, so the ledger the stopped arms
        // read zeroes from does count writes on this store.
        let created = control.appGroup.createdObjectKeys()
        #expect(created.count == 2, "publication created \(created.count) object(s), expected 2")
        if let payloadKey = created.first {
            #expect(
                control.appGroup.appendedLengths(to: payloadKey) == shape.appendLengths,
                "the control streamed a partition other than the one the shape describes"
            )
            #expect(control.appGroup.finalizeCount(of: payloadKey) == 1)
        }
        #expect(await governor.outstandingReservations().isEmpty)

        // The main app claims it, which is what shows `.nothingPending` in the stopped arms is
        // a statement about the slot rather than about the claim never working.
        control.appGroup.forgetObservations()
        control.session.forgetObservations()
        let claim = await control.claimAdapter.attemptClaim(claimingBuildID: Sample.buildID())
        guard let verified = claim.verifiedHandoff else {
            reportUnbuildableInput("the control's published handoff must verify: \(claim)")
            return
        }
        #expect(verified.sessionID == candidate)
        #expect(verified.sessionID != shape.decoySessionID)
        #expect(verified.transferID == ticket.transferID)
        #expect(verified.asset.route == .shareExtension)
        #expect(verified.asset.byteCount == ticket.byteCount)
        #expect(verified.asset.sha256 == ticket.sha256)
        #expect(control.appGroup.totalReadCount() > 0, "the claim must have read the payload")
        #expect(control.session.createdObjectKeys().count == 1)
        #expect(
            await control.session.underlying.keys(in: .session(candidate))
                == [verified.asset.handle.storageKey],
            "the resumed session must own exactly the object the claim names"
        )
        #expect(verified.asset.handle.protection == shape.protectionLevel)

        // And the downstream ledger counts a handoff when one happens.
        let ledger = MainAppCallLedger()
        for consumer in MainAppConsumer.allCases {
            ledger.hand(verified.asset.handle, to: consumer)
        }
        #expect(ledger.totalCallCount == MainAppConsumer.allCases.count)
        #expect(ledger.distinctHandles.count == 1)
        for consumer in MainAppConsumer.allCases {
            #expect(ledger.callCount(of: consumer) == 1)
        }

        // Exactly one pending session existed, so a second claim finds nothing.
        #expect(
            await control.claimAdapter.attemptClaim(claimingBuildID: Sample.buildID())
                == ShareClaimOutcome.nothingPending
        )
        witness.recordControlPublishedAndClaimed()
    }

    // MARK: - One stopped handoff

    /// A handoff stopped at `point` produces the expected no-session outcome, is shown to have
    /// stopped there, and leaves no ready transfer, no session, no main-app call, no verdict,
    /// and no bytes (Requirement 2.4).
    func checkStoppingAt(_ point: PrepublicationStopPoint) async {
        guard let container = stopped[point] else {
            reportUnbuildableInput("every stop point must own a container")
            return
        }
        let candidate = shape.candidateSessionID(for: point)

        guard let before = await readySlot(of: container) else { return }
        #expect(before == ReadySlotState.empty)

        guard let attempt = await run(point, in: container, candidate: candidate) else { return }

        // 1. The outcome vocabulary. A decline and a cancellation are their own cases and
        //    never an Analysis Error; the promotion interruption is a no-session failure whose
        //    category is `handoff-error` and never a cancellation (Requirement 11.17).
        checkTheOutcome(attempt.outcome, at: point)

        // 2. The stop point was reached, and no further. Compared against the reference table
        //    rather than against the coordinator, so an arm that degenerated into "stopped
        //    before anything happened" fails instead of satisfying every absence for free.
        await checkTheAttemptReached(point, attempt: attempt, in: container)

        // 3. No ready transfer, in any state, and no bytes.
        #expect(
            await container.readyTransferScopes().isEmpty,
            "\(point.rawValue) left a ready transfer behind"
        )
        #expect(
            await readySlot(of: container) == ReadySlotState.empty,
            "\(point.rawValue) left the ready slot occupied"
        )
        let leftoverScopes = await container.transferScopes()
        #expect(
            leftoverScopes.isEmpty,
            "\(point.rawValue) left transfer material behind: \(leftoverScopes.count) scope(s)"
        )
        #expect(
            await usedBytes(of: container) == 0,
            "\(point.rawValue) left bytes in the shared container"
        )

        // 4. No headroom stayed reserved, so a stopped handoff does not leave the next
        //    activation short (Requirement 11.8's release-on-every-path half).
        #expect(
            attempt.outstandingReservations == 0,
            "\(point.rawValue) leaked \(attempt.outstandingReservations) reservation(s)"
        )

        // 5. The host's own representation is exactly what it was: a stopped handoff reads
        //    from the provider's file and never writes, truncates, moves, or removes it.
        if let lent = attempt.hostRepresentation {
            #expect(
                lent == shape.bytes,
                "\(point.rawValue) changed the host's representation"
            )
        }

        // 6. No Analysis Session, and no main-app analysis. Ledgers are cleared first, so the
        //    claim's counts describe the claim alone.
        container.appGroup.forgetObservations()
        container.session.forgetObservations()
        let claim = await container.claimAdapter.attemptClaim(claimingBuildID: Sample.buildID())
        #expect(
            claim == ShareClaimOutcome.nothingPending,
            "\(point.rawValue) left something claimable: \(claim)"
        )
        #expect(claim.verifiedHandoff == nil)
        #expect(claim.failedHandoff == nil)
        #expect(
            container.appGroup.totalReadCount() == 0,
            "\(point.rawValue): the claim read the shared container"
        )
        #expect(
            container.session.createdObjectKeys().isEmpty,
            "\(point.rawValue): the claim wrote app-private session storage"
        )
        #expect(await container.session.underlying.occupiedScopes().isEmpty)
        #expect(await container.session.underlying.keys(in: .session(candidate)).isEmpty)

        // 7. No evidence verdict: no accepted ingest exists, so nothing was handed to the
        //    Input Validator, the provenance lane, or pixel inference.
        let ledger = MainAppCallLedger()
        if let asset = claim.verifiedHandoff?.asset {
            // Unreachable while the claim is `.nothingPending`. It stays here rather than as a
            // comment so a regression that produced a session would be recorded as a routed
            // call rather than silently ignored.
            for consumer in MainAppConsumer.allCases {
                ledger.hand(asset.handle, to: consumer)
            }
        }
        #expect(
            ledger.totalCallCount == 0,
            "\(point.rawValue) routed \(ledger.totalCallCount) accepted ingest(s) downstream"
        )
        for consumer in MainAppConsumer.allCases {
            #expect(ledger.callCount(of: consumer) == 0)
        }

        witness.recordStopPointChecked(point)
    }

    // MARK: - The outcome

    /// The outcome a stopped handoff reports, checked against the vocabulary the requirements
    /// fix for it.
    private func checkTheOutcome(
        _ outcome: ShareHandoffOutcome,
        at point: PrepublicationStopPoint
    ) {
        #expect(
            outcome.publishedTicket == nil,
            "\(point.rawValue) published a ticket: \(outcome)"
        )
        switch point {
        case .abandonedBeforeTheConsentActionAppeared,
             .cancelledAtTheConsentAction,
             .cancelledInTheProviderWindow,
             .cancelledBeforeTheFirstChunk,
             .cancelledPartwayThroughTheCopy:
            #expect(
                outcome == ShareHandoffOutcome.cancelled,
                "\(point.rawValue) must report cancellation, got \(outcome)"
            )
        case .declinedAtTheConsentAction:
            #expect(
                outcome == ShareHandoffOutcome.declined,
                "\(point.rawValue) must report a decline, got \(outcome)"
            )
        case .interruptedAtTheAtomicPromotion:
            guard case .failed(let failure) = outcome else {
                Issue.record("\(point.rawValue) must report a no-session failure, got \(outcome)")
                return
            }
            // The promotion is a store operation, so the failure names the store rather than
            // the copy: the bytes were complete and the rename was refused.
            #expect(failure == ShareStagingFailure.stagingIncomplete(.store(.storeUnavailable)))
            // An interruption is not a cancellation and must not be reported as one, and it
            // is not a resource condition either.
            #expect(
                failure.fault
                    == AnalysisFault.analysis(.handoffError, stage: .handoffVerification)
            )
            #expect(failure.fault != AnalysisFault.cancelled)
        }
        // A refused activation is Property 4's outcome and must not stand in for any of these.
        if case .activationRefused(let refusal) = outcome {
            Issue.record("\(point.rawValue) was refused on counts instead: \(refusal)")
        }
        // A pending-handoff recovery would mean another arm's transfer was visible here.
        if case .pendingHandoff(let recovery) = outcome {
            Issue.record(
                "\(point.rawValue) met a pending handoff: \(recovery.pendingTransfer.rawValue)"
            )
        }
        witness.recordOutcome(outcome, at: point)
    }

    /// Cancellation never acquires an Analysis Error category, whatever route it arrived by
    /// (Requirement 11.17).
    ///
    /// A pure-value check over the two failures that carry a cancellation, beside the arms
    /// that produce them: the coordinator's cancelled case, and a cancelled copy reported
    /// through the transfer store.
    func checkCancellationNeverAcquiresAnErrorCategory() {
        #expect(ShareStagingFailure.cancelled.fault == AnalysisFault.cancelled)
        #expect(
            ShareStagingFailure.stagingIncomplete(.stagingFailed(.cancelled)).fault
                == AnalysisFault.cancelled
        )
        #expect(
            ShareStagingFailure.noRepresentationObtained(.cancelled).fault
                == AnalysisFault.cancelled
        )
        witness.recordCancellationCategoryCheck()
    }

    // MARK: - The stop point was reached

    /// How far the attempt got, compared against ``ReferenceStopPointModel``.
    ///
    /// This is the half of the property that keeps the absences honest. Without it, every arm
    /// below would be satisfied by a handoff that never started.
    private func checkTheAttemptReached(
        _ point: PrepublicationStopPoint,
        attempt: StoppedAttempt,
        in container: StopPointContainer
    ) async {
        // Publication creates the payload and then the manifest, so a complete staging is two
        // objects. Derived rather than pinned, so the table states the shape of the flow.
        let expected = ReferenceStopPointModel.reach(of: point, totalPayloadObjects: 2)

        // The presenter is always asked, because the coordinator reaches it for every
        // activation that passes the count and pending-slot gates. What varies is whether it
        // displayed anything.
        #expect(
            attempt.consentActionsAsked == 1,
            "\(point.rawValue) asked for consent \(attempt.consentActionsAsked) time(s)"
        )
        #expect(
            attempt.consentActionsDisplayed == expected.consentActionsDisplayed,
            """
            \(point.rawValue) displayed \(attempt.consentActionsDisplayed) consent action(s), \
            expected \(expected.consentActionsDisplayed)
            """
        )
        #expect(
            attempt.providersRequested == expected.providersRequested,
            """
            \(point.rawValue) asked the host about \(attempt.providersRequested) provider(s), \
            expected \(expected.providersRequested)
            """
        )
        #expect(
            attempt.windowsOpened == expected.windowsOpened,
            """
            \(point.rawValue) opened \(attempt.windowsOpened) access window(s), expected \
            \(expected.windowsOpened)
            """
        )

        let created = container.appGroup.createdObjectKeys()
        #expect(
            created.count == expected.objectsCreated,
            """
            \(point.rawValue) created \(created.count) object(s) in the shared container, \
            expected \(expected.objectsCreated)
            """
        )
        #expect(
            container.appGroup.promotionAttemptCount() == expected.promotionsAttempted,
            """
            \(point.rawValue) attempted \(container.appGroup.promotionAttemptCount()) \
            promotion(s), expected \(expected.promotionsAttempted)
            """
        )

        // Whatever was created was removed, so "no bytes remain" is a removal rather than an
        // absence of any attempt.
        if !created.isEmpty {
            let removed = container.appGroup.scopesRemoved()
            #expect(
                removed.contains(where: { scope in
                    if case .transfer(_, .staging) = scope { return true }
                    return false
                }),
                "\(point.rawValue) created staged material and never removed the staging scope"
            )
        }

        guard let payloadKey = created.first else {
            #expect(
                ReferenceStopPointModel.payloadAppends(of: point, totalAppends: 1) == 0,
                "\(point.rawValue) was expected to create a payload object"
            )
            witness.recordReachChecked(point)
            return
        }

        let lengths = container.appGroup.appendedLengths(to: payloadKey)
        let streamed = lengths.reduce(0, +)
        if let expectedAppends = ReferenceStopPointModel.payloadAppends(
            of: point,
            totalAppends: shape.totalAppendCount
        ) {
            #expect(
                lengths.count == expectedAppends,
                """
                \(point.rawValue) streamed \(lengths.count) chunk(s) into the payload, \
                expected \(expectedAppends)
                """
            )
            if point == .interruptedAtTheAtomicPromotion {
                // The whole representation reached storage and was finalized, and the bounded
                // ticket joined it, so the arm really did stop at the promotion rather than
                // during the copy. Staging was complete and there was something to promote.
                #expect(lengths == shape.appendLengths)
                #expect(streamed == shape.byteCount)
                #expect(container.appGroup.finalizeCount(of: payloadKey) == 1)
                if created.count > 1 {
                    let manifestKey = created[1]
                    #expect(manifestKey != payloadKey)
                    #expect(container.appGroup.finalizeCount(of: manifestKey) == 1)
                    #expect(container.appGroup.appendedLengths(to: manifestKey).count == 1)
                }
                witness.recordCompleteStagingInterrupted()
            } else {
                #expect(streamed == 0, "\(point.rawValue) wrote \(streamed) byte(s)")
                #expect(container.appGroup.finalizeCount(of: payloadKey) == 0)
            }
        } else {
            // The mid-copy arm: strictly interior, so a partial copy really was in flight.
            let trigger = shape.midCopyTriggerIndex
            #expect(trigger >= 1, "the mid-copy trigger must be after at least one chunk")
            #expect(
                trigger < shape.totalAppendCount,
                """
                the mid-copy trigger (\(trigger)) must be before the last of \
                \(shape.totalAppendCount) chunk(s)
                """
            )
            #expect(
                lengths.count == trigger,
                """
                the mid-copy cancellation landed after \(lengths.count) chunk(s), expected \
                \(trigger) of \(shape.totalAppendCount)
                """
            )
            #expect(
                streamed == shape.midCopyByteCount,
                "the partial copy wrote \(streamed) bytes, expected \(shape.midCopyByteCount)"
            )
            #expect(streamed > 0, "the mid-copy arm must have written at least one byte")
            #expect(
                streamed < shape.byteCount,
                "the mid-copy arm wrote the whole representation and was not partial"
            )
            // Nothing was finalized: an incomplete copy is never promoted.
            #expect(container.appGroup.finalizeCount(of: payloadKey) == 0)

            if let trip = trips[point] {
                #expect(
                    await trip.appendsBeforeCancellation == trigger,
                    "the cancellation was requested at a different chunk than the trigger"
                )
                #expect(
                    await trip.appendsObserved == trigger,
                    "the copy continued past the cancellation"
                )
                witness.recordPartialCopyCancelled(after: trigger)
            } else {
                Issue.record("the mid-copy arm must own a cancellation trip")
            }
        }
        witness.recordReachChecked(point)
    }

    // MARK: - Running one stopped handoff

    /// Runs one activation, stopped at `point`, through the real coordinator.
    ///
    /// Returns `nil` only when a fixture could not be built, which is a defect in this file
    /// rather than a finding about the coordinator; the witness counts it so a run whose inputs
    /// stopped being buildable fails outside the body.
    private func run(
        _ point: PrepublicationStopPoint,
        in container: StopPointContainer,
        candidate: AnalysisSessionID
    ) async -> StoppedAttempt? {
        let access: FakeSharedItemAccess =
            point.hostLendsARepresentation
            ? FakeSharedItemAccess(
                .representation(bytes: shape.bytes, form: shape.sharedForm),
                reclaimsRepresentation: false
            )
            : FakeSharedItemAccess(.noRepresentation(.cancelled))
        let presenter = StopPointConsentPresenter(point.consentScript)
        let governor = ProgrammedShareResourceGovernor()
        guard
            let coordinator = ShareExtensionIngestCoordinator(
                access: access,
                consentPresenter: presenter,
                transfers: container.extensionSide,
                governor: governor,
                budget: Sample.shareBudget(),
                instruction: Sample.manualInstruction(),
                candidateSessions: FixedCandidateSessionIdentifierSource(candidate)
            )
        else {
            reportUnbuildableInput("the Share ingest coordinator fixture must be constructible")
            return nil
        }

        let outcome: ShareHandoffOutcome
        if point.cancelsTheEnclosingTask, let trip = trips[point] {
            // The copy has to be cancelled from outside itself, and the gate is what keeps the
            // work from racing past the trigger before the trigger exists.
            let activation = shape.activation
            let work = Task { () -> ShareHandoffOutcome in
                await trip.waitUntilArmed()
                return await coordinator.handleActivation(activation)
            }
            await trip.arm { work.cancel() }
            outcome = await work.value
        } else {
            outcome = await coordinator.handleActivation(shape.activation)
        }

        // Read the host's file before reclaiming it: "left exactly as it was" is a claim about
        // a file the provider still owns.
        let lentBytes = await Self.lentRepresentationBytes(of: access)
        await access.cleanUp()

        return StoppedAttempt(
            outcome: outcome,
            consentActionsAsked: await presenter.askedRequests.count,
            consentActionsDisplayed: await presenter.displayedRequests.count,
            providersRequested: await access.requestedProviders.count,
            windowsOpened: await access.consumeCount,
            outstandingReservations: await governor.outstandingReservations().count,
            hostRepresentation: lentBytes
        )
    }

    // MARK: - Nonthrowing store reads

    /// The container's ready slot, or `nil` when the store could not say.
    ///
    /// Wrapped rather than rethrown: an error escaping the property body would report a
    /// passing run with every arm skipped.
    private func readySlot(of container: StopPointContainer) async -> ReadySlotState? {
        do {
            return try await container.extensionSide.readySlotState()
        } catch {
            Issue.record("the ready slot must be readable: \(error)")
            return nil
        }
    }

    /// Bytes the container holds, or `nil` when the store could not say.
    private func usedBytes(of container: StopPointContainer) async -> UInt64? {
        do {
            return try await container.appGroup.underlying.usedByteCount()
        } catch {
            Issue.record("the store's used byte count must be readable: \(error)")
            return nil
        }
    }

    // MARK: - Helpers

    private func reportUnbuildableInput(
        _ message: Comment,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        witness.recordUnbuildableInput()
        Issue.record(message, sourceLocation: sourceLocation)
    }

    /// The bytes still in the file the host lent, or `nil` when it lent none.
    ///
    /// Read while the file is still the provider's, and opened for reading only, because the
    /// claim being checked is that a stopped handoff left the host's representation alone.
    private static func lentRepresentationBytes(
        of access: FakeSharedItemAccess
    ) async -> [UInt8]? {
        guard let lent = await access.lentFiles.first else { return nil }
        guard let data = try? Data(contentsOf: lent) else { return nil }
        return Array(data)
    }

    private static func temporaryRoot(_ label: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(
                path: "defaike-p7-\(label)-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
    }
}

// MARK: - The variation witness

/// Counts what the run generated and what it produced, outside the property body.
///
/// `propertyCheck` runs its body under `try?`, so a body that failed before its first
/// assertion reports a passing test in milliseconds with every arm skipped — and a property
/// whose every assertion is an absence is the easiest kind to pass that way. Two habits close
/// that gap, and both matter:
///
///   * every arm counter is compared against the **case count** rather than against a floor,
///     so a run in which an arm stopped being reached fails even if the absolute number still
///     looks large; and
///   * ``recordCompletedBody()`` is the last thing the body does, so a case that ended early
///     is countable. `completedBodies == cases` alone would pass vacuously as `0 == 0`, which
///     is why the case floor sits beside it.
///
/// The produced sets are the substantive half. All seven stop points must have been reached and
/// must have produced the outcome the reference table assigns them, a complete staging must
/// have been interrupted at the promotion, partial copies must have been cancelled at several
/// distinct interior chunks, and a control must have published *and* been claimed on every
/// single case — which is what turns "nothing was left behind" from a claim about unreached
/// branches into a claim about produced outcomes.
private final class StopPointVariationWitness: @unchecked Sendable {
    private let lock = NSLock()

    // Arm counters.
    private var cases = 0
    private var completedBodies = 0
    private var stopPointChecks = 0
    private var reachChecks = 0
    private var controlPublications = 0
    private var cancellationCategoryChecks = 0
    private var completeStagingsInterrupted = 0
    private var unbuildableInputs = 0

    // Produced outcomes.
    private var pointsChecked: Set<PrepublicationStopPoint> = []
    private var outcomeKeysByPoint: [PrepublicationStopPoint: Set<String>] = [:]
    private var interiorTriggers: Set<Int> = []

    // Generated baseline.
    private var seeds: Set<Int> = []
    private var byteCounts: Set<Int> = []
    private var appendTargets: Set<Int> = []
    private var totalAppendCounts: Set<Int> = []
    private var forms: Set<SharedRepresentationForm> = []
    private var hintKeys: Set<String> = []
    private var firstStopPoints: Set<PrepublicationStopPoint> = []
    private var controlOrders: Set<Bool> = []

    func record(_ shape: StopPointShape) {
        lock.lock()
        defer { lock.unlock() }
        cases += 1
        seeds.insert(shape.seed)
        byteCounts.insert(shape.byteCount)
        appendTargets.insert(shape.appendTarget)
        totalAppendCounts.insert(shape.totalAppendCount)
        forms.insert(shape.sharedForm)
        hintKeys.insert(shape.contentTypeHint?.rawValue ?? "none")
        firstStopPoints.insert(shape.firstStopPoint)
        controlOrders.insert(shape.controlRunsFirst)
    }

    func recordStopPointChecked(_ point: PrepublicationStopPoint) {
        lock.lock()
        stopPointChecks += 1
        pointsChecked.insert(point)
        lock.unlock()
    }

    func recordReachChecked(_ point: PrepublicationStopPoint) {
        lock.lock()
        reachChecks += 1
        lock.unlock()
    }

    /// Records which outcome case a stop point produced.
    ///
    /// The case name rather than the value, because a failure payload carries a store error
    /// that is not part of what varies; what matters is that each point produced exactly one
    /// outcome case across the whole run.
    func recordOutcome(_ outcome: ShareHandoffOutcome, at point: PrepublicationStopPoint) {
        let key: String
        switch outcome {
        case .published: key = "published"
        case .activationRefused: key = "activation-refused"
        case .declined: key = "declined"
        case .cancelled: key = "cancelled"
        case .pendingHandoff: key = "pending-handoff"
        case .failed: key = "failed"
        }
        lock.lock()
        outcomeKeysByPoint[point, default: []].insert(key)
        lock.unlock()
    }

    func recordPartialCopyCancelled(after appends: Int) {
        lock.lock()
        interiorTriggers.insert(appends)
        lock.unlock()
    }

    func recordCompleteStagingInterrupted() {
        lock.lock()
        completeStagingsInterrupted += 1
        lock.unlock()
    }

    func recordControlPublishedAndClaimed() {
        lock.lock()
        controlPublications += 1
        lock.unlock()
    }

    func recordCancellationCategoryCheck() {
        lock.lock()
        cancellationCategoryChecks += 1
        lock.unlock()
    }

    /// Records that a fixture this file described could not be built.
    ///
    /// Never a finding about the property: every input here is built from generated integers
    /// inside validated ranges, so a refusal is a defect in this file. It is counted so a run
    /// whose inputs quietly stopped being buildable fails outside the body rather than
    /// shrinking its own coverage.
    func recordUnbuildableInput() {
        lock.lock()
        unbuildableInputs += 1
        lock.unlock()
    }

    /// Called last in the body, so a case that stopped early is countable.
    func recordCompletedBody() {
        lock.lock()
        completedBodies += 1
        lock.unlock()
    }

    func expectVariedBaselines() {
        lock.lock()
        defer { lock.unlock() }

        #expect(cases >= 100, "the design requires at least 100 generated cases; ran \(cases)")
        #expect(
            completedBodies == cases,
            "\(cases - completedBodies) of \(cases) cases did not reach the end of the body"
        )
        #expect(
            unbuildableInputs == 0,
            "\(unbuildableInputs) described inputs could not be built at all"
        )

        // Every arm ran on every case. Compared against the case count rather than against a
        // floor: an arm that stopped being reached fails here even when the absolute number
        // still looks large.
        let pointCount = PrepublicationStopPoint.allCases.count
        #expect(
            stopPointChecks == cases * pointCount,
            "stop points checked: \(stopPointChecks), expected \(cases * pointCount)"
        )
        #expect(
            reachChecks == cases * pointCount,
            "reach checks: \(reachChecks), expected \(cases * pointCount)"
        )
        #expect(
            controlPublications == cases,
            "controls that published and were claimed: \(controlPublications) of \(cases)"
        )
        #expect(
            cancellationCategoryChecks == cases,
            "cancellation category checks: \(cancellationCategoryChecks)"
        )
        #expect(
            completeStagingsInterrupted == cases,
            "complete stagings interrupted at the promotion: \(completeStagingsInterrupted)"
        )

        // The substantive half: every stop point was reached, and each produced exactly the
        // one outcome case its family allows.
        #expect(
            pointsChecked == Set(PrepublicationStopPoint.allCases),
            """
            stop points never reached: \
            \(Set(PrepublicationStopPoint.allCases).subtracting(pointsChecked).map(\.rawValue).sorted())
            """
        )
        for point in PrepublicationStopPoint.allCases {
            let produced = outcomeKeysByPoint[point] ?? []
            let expected: Set<String>
            switch point {
            case .declinedAtTheConsentAction:
                expected = ["declined"]
            case .interruptedAtTheAtomicPromotion:
                expected = ["failed"]
            default:
                expected = ["cancelled"]
            }
            #expect(
                produced == expected,
                "\(point.rawValue) produced \(produced.sorted()), expected \(expected.sorted())"
            )
        }
        // Several distinct interior chunks, so the mid-copy arm exercised a family of partial
        // copies rather than one convenient boundary.
        #expect(
            interiorTriggers.count >= 4,
            "distinct interior cancellation points: \(interiorTriggers.sorted())"
        )
        #expect(
            interiorTriggers.allSatisfy { $0 >= 1 },
            "an interior cancellation landed before the first chunk"
        )

        // The generated baseline actually varied.
        #expect(seeds.count >= 50, "generated seeds: \(seeds.count)")
        #expect(byteCounts.count >= 50, "generated byte counts: \(byteCounts.count)")
        #expect(
            appendTargets == Set(StopPointShape.appendTargets),
            "generated chunk targets: \(appendTargets.sorted())"
        )
        #expect(
            totalAppendCounts.count >= 4,
            "distinct copy partitions written: \(totalAppendCounts.sorted())"
        )
        #expect(
            forms == Set(SharedRepresentationForm.allCases),
            "generated representation forms: \(forms.map(\.rawValue).sorted())"
        )
        #expect(hintKeys.count >= 4, "generated content-type hints: \(hintKeys.sorted())")
        #expect(
            firstStopPoints == Set(PrepublicationStopPoint.allCases),
            """
            stop points that never ran first: \
            \(Set(PrepublicationStopPoint.allCases).subtracting(firstStopPoints).map(\.rawValue).sorted())
            """
        )
        #expect(controlOrders == [false, true], "only one control order was generated")
    }
}
