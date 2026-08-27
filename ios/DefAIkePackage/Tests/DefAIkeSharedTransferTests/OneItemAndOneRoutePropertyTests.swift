import DefAIkeDomain
import Foundation
import PropertyBased
import Testing

@testable import DefAIkeSharedTransfer

// Design Property 4: one item and one route per session.
//
// The design states it as: for any ingest request, an Analysis Session can be created if
// and only if the request contains exactly one locally available encoded representation and
// exactly one route from Photos Picker or Share Extension; zero, multiple, or unknown-route
// inputs create no session.
//
// That is one biconditional over two independent halves, and this file quantifies both over
// generated item counts, provider counts, route values, and representation availability:
//
//   * **the count half** — a request carrying any number of selected items or offered
//     providers other than one is refused *before* a session could exist, and the refusal is
//     reached before the consent action appears and before the host is asked for anything
//     (Requirements 2.5 and 2.7);
//   * **the representation half** — with the counts held at exactly one, a session exists if
//     and only if exactly one complete local representation was retained. An empty
//     representation and a provider that produced nothing are both no-session outcomes even
//     though the user consented and the host was asked (Requirement 2.5);
//   * **the route half** — the Version 1 route vocabulary is exactly the two routes, every
//     session-bearing value records exactly one of them, and a record naming any other route
//     does not resolve into a resumable session at all (Requirements 2.6 and 2.8).
//
// ## Why the nonoccurrence claims bite
//
// Every case runs a **control** request beside the generated one: exactly one provider
// offering exactly one item, and exactly one picker-selected item. When the generated
// request is refused, the spies must show that the consent action never appeared and the host
// was never asked; the control is what proves those same spies do record a call when one is
// made. It runs on every generated case rather than once, so a change that silently
// disconnects the consent step or the provider seam fails on most of 100 cases instead of on
// none of them.
//
// The Share route's ingest coordinator is the real one, so its refusal, its consent ordering,
// and its single publication commit are all observed rather than modelled: `handleActivation`
// decides, `ScriptedConsentPresenter` and `FakeSharedItemAccess` count what it actually
// reached for, and the real `SharedTransferStore` over a real protected directory decides
// whether a pending session exists.
//
// ## What this file asserts each half against, and what it does not
//
//   * The Share route's count gate is asserted against `ShareActivation.resolvedCandidate`
//     *and* against the real coordinator that consumes it.
//   * The Photos route's count gate is asserted against `PhotosPickerSelection` — `soleItem`
//     and `isCancellation` are the only production accessors from a selection to an item, and
//     the import port takes one item, so a selection of zero or many has nothing it can hand
//     across. `PhotosIngestCoordinator` lives in `DefAIkeApplication`, outside this test
//     target's module closure; `PhotosIngestCoordinatorTests` pins its five refusal outcomes
//     at examples, and this file quantifies the gate and the adapter that surround it over
//     generated counts.
//   * Cancellation is not generated here. A declined or cancelled handoff creating no side
//     effect is Property 7's statement, and byte, digest, and status preservation across a
//     completed handoff is Property 5's. Nothing below asserts either.
//   * `unsupported-static-format`, `unsupported-media`, and every other validation outcome
//     belong to Property 3. Ingest retains whatever arrived; this file never classifies it.
//
// ## Nothing here is an approved release value
//
// The Share Extension Resource Budget, the Extension Execution Policy, the Data Lifecycle
// Policy, the staged protection level, the approved-copy key the manual instruction addresses,
// and every identifier are synthetic fixtures that exist so a port taking a signed artifact
// can be called at all. The byte counts and chunk sizes are structural test scaffolding. No
// number below may be copied into a shipping artifact.
//
// ## Why no arm throws
//
// `propertyCheck` runs its body under `try?`, so an error escaping the body reports a passing
// run in milliseconds with every arm skipped. Nothing below rethrows: every throwing store,
// manifest, and coordinator call is wrapped into a value or reported through `Issue.record`,
// and ``IngestVariationWitness`` counts the cases and every arm *outside* the body, where an
// issue is not suppressed. The arm counters are compared against the case count rather than
// against a floor, and the last thing the body does is record that it reached the end, so a
// case that stopped early is countable rather than invisible.

extension Tag {
    /// Design Property 4.
    ///
    /// Declared in this file rather than in a shared tag namespace: each design property gets
    /// one dedicated file, and a shared namespace would be a merge point between property
    /// files written independently of each other.
    @Tag static var property4OneItemAndOneRoute: Self
}

@Suite(
    "Property 4: one item and one route per session",
    .tags(.property4OneItemAndOneRoute)
)
struct OneItemAndOneRoutePropertyTests {
    /// Runs at the library default of 100 generated cases, which is the minimum the design
    /// requires; `PropertyToolchainWiringTests` pins that default. Every generator is
    /// composed with `zip`, so the shrinkers compose.
    ///
    /// **Validates: Requirements 2.5, 2.6, 2.7, 2.8**
    @Test("A session arises only for one supported route and one local representation")
    func sessionsRequireOneItemAndOneRoute() async {
        let witness = IngestVariationWitness()

        await propertyCheck(input: IngestRequestShape.generator) { shape in
            witness.record(shape)
            let scenario = IngestScenario(shape: shape, witness: witness)
            defer { scenario.removeTemporaryRoots() }

            scenario.checkTheRouteVocabularyIsExactlyTheTwoSupportedRoutes()
            scenario.checkARecordNamingAnotherRouteDoesNotResolve()
            await scenario.checkThePickerSelectionAdmitsOnlyOneItem()
            await scenario.checkTheActivationAdmitsOnlyOneProviderOfferingOneItem()
            await scenario.checkOneLocalRepresentationDecidesWhetherASessionExists()
            await scenario.checkNoSecondSessionJoinsThePendingSlot()

            witness.recordCompletedBody()
        }

        witness.expectVariedBaselines()
    }
}

// MARK: - What a generated request offers

/// Why the provider never produced a local representation.
///
/// The three failures ``SharedItemProviderFault`` and ``PhotosProviderFault`` share, so one
/// generated availability drives both routes' seams and an audit can see the same reason on
/// either side. Cancellation is deliberately absent: it is a distinct outcome rather than a
/// failure, and a cancelled handoff having no side effect is Property 7's statement.
private enum ProviderNothingReason: String, Hashable, Sendable, CaseIterable {
    case itemUnavailable = "item-unavailable"
    case representationUnavailable = "representation-unavailable"
    case transferFailed = "transfer-failed"

    var photosFault: PhotosProviderFault {
        switch self {
        case .itemUnavailable: .itemUnavailable
        case .representationUnavailable: .representationUnavailable
        case .transferFailed: .transferFailed
        }
    }

    var sharedFault: SharedItemProviderFault {
        switch self {
        case .itemUnavailable: .itemUnavailable
        case .representationUnavailable: .representationUnavailable
        case .transferFailed: .transferFailed
        }
    }
}

/// What one ingest request's source actually exposes.
///
/// "Exactly one locally available encoded representation" is the property's other half, so
/// the three ways it can be absent are all representable: nothing offered at all, something
/// offered that holds no bytes, and one complete representation. Only the last is a local
/// representation, and the requirements draw the first two apart because they mean different
/// things to an audit — an empty representation was consented to and read, and a provider
/// that produced nothing never let a byte exist.
private enum RepresentationAvailability: Hashable, Sendable {
    /// One complete, nonempty representation the copy can finish.
    case oneCompleteRepresentation

    /// A representation arrived holding no bytes. Zero bytes are not an analyzable image.
    case emptyRepresentation

    /// The access window closed with no representation, so no byte was ever read.
    case providerProducedNothing(ProviderNothingReason)

    /// Whether this is the one case that yields a local representation.
    var yieldsOneLocalRepresentation: Bool { self == .oneCompleteRepresentation }

    /// Names the case in a failure message and in the witness's produced set.
    var key: String {
        switch self {
        case .oneCompleteRepresentation: "one-complete-representation"
        case .emptyRepresentation: "empty-representation"
        case .providerProducedNothing(let reason): "nothing/\(reason.rawValue)"
        }
    }

    /// The table the generator selects from.
    ///
    /// ``oneCompleteRepresentation`` appears twice so a third of generated cases create a
    /// session on both routes: the accepted arm is the positive control the nonoccurrence
    /// claims lean on, and it has to be reached often rather than occasionally.
    static let table: [RepresentationAvailability] = [
        .oneCompleteRepresentation,
        .oneCompleteRepresentation,
        .emptyRepresentation,
        .providerProducedNothing(.itemUnavailable),
        .providerProducedNothing(.representationUnavailable),
        .providerProducedNothing(.transferFailed),
    ]

    /// Every distinct value the table can produce.
    static let distinctKeys: Set<String> = Set(table.map(\.key))
}

// MARK: - Generated shape

/// One generated ingest request, plus the fixtures derived from it.
///
/// Every field is a bounded integer or a flag, and each derived value is read off the shape
/// by modulus, so a family is exercised across all of its members over 100 cases instead of
/// collapsing onto one. The counts are deliberately unconstrained above and below one:
/// Requirement 2.7 rejects any count other than one *before* a session exists, so the other
/// counts must exist in order to be rejected.
private struct IngestRequestShape: Sendable, CustomStringConvertible {
    /// Drives every synthetic identifier and the ticket's preservation basis, so a case's
    /// values vary together and a failing case names one seed.
    let seed: Int

    /// Whether the Photos control request runs before the Share control request.
    ///
    /// The two hold separate containers, so exercising both orders is what shows that neither
    /// route's session creation depends on the other having run.
    let photosRouteRunsFirst: Bool

    let selectedItemCountIndex: Int
    let providerCountIndex: Int
    let providerItemCountIndex: Int
    let availabilityIndex: Int

    /// Bytes in a complete representation. Bounded well below the synthetic budget and store
    /// ceilings: this property is about counts and routes, and a size large enough to reach a
    /// limit would make the outcome depend on a resource breach instead.
    let byteCount: Int

    let formIndex: Int
    let chunkIndex: Int
    let unknownRouteIndex: Int
    let hintIndex: Int

    // MARK: Counts

    /// How many items the generated picker selection carries: zero through five.
    var selectedItemCount: Int { selectedItemCountIndex % 6 }

    /// How many providers the generated activation offers: zero through three.
    var providerCount: Int { providerCountIndex % 4 }

    /// How many items the generated activation's sole provider reports: zero through three.
    var providerItemCount: Int { providerItemCountIndex % 4 }

    var availability: RepresentationAvailability {
        RepresentationAvailability.table[availabilityIndex % RepresentationAvailability.table.count]
    }

    // MARK: Derived fixtures

    var sharedForm: SharedRepresentationForm {
        SharedRepresentationForm.allCases[formIndex % SharedRepresentationForm.allCases.count]
    }

    var photosForm: SuppliedRepresentationForm {
        SuppliedRepresentationForm.allCases[formIndex % SuppliedRepresentationForm.allCases.count]
    }

    /// I/O buffer size for the streaming copy. A structural bound: it changes how many passes
    /// a copy takes, never whether a session exists.
    var chunkSizeInBytes: Int { Self.chunkSizes[chunkIndex % Self.chunkSizes.count] }

    var contentTypeHint: ContentTypeHint? {
        guard let raw = Self.hints[hintIndex % Self.hints.count] else { return nil }
        return Sample.contentTypeHint(raw)
    }

    /// The basis the generated ticket records. Its status is derived from it, never chosen.
    var ticketBasis: PreservationBasis {
        PreservationBasis.allCases[seed % PreservationBasis.allCases.count]
    }

    /// A route spelling outside the Version 1 vocabulary.
    var unknownRouteToken: String {
        Self.unknownRouteTokens[unknownRouteIndex % Self.unknownRouteTokens.count]
    }

    var bytes: [UInt8] { Sample.bytes(count: byteCount, seed: UInt8(truncatingIfNeeded: seed)) }

    // MARK: Requests

    /// The generated picker selection, with a distinct token per item.
    var selectedItems: [PhotosPickerItemReference] {
        (0..<selectedItemCount).map {
            Sample.pickerItem(token: UInt64($0 + 1), contentTypeHint: contentTypeHint)
        }
    }

    /// The generated activation. The first provider reports the generated item count; any
    /// others report one, because an activation offering more than one provider is refused on
    /// the provider count before any item count is consulted.
    var generatedActivation: ShareActivation {
        ShareActivation(
            providers: (0..<providerCount).map { index in
                Sample.sharedProvider(
                    token: UInt64(index + 1),
                    itemCount: index == 0 ? providerItemCount : 1,
                    contentTypeHint: contentTypeHint
                )
            }
        )
    }

    /// The control activation: exactly one provider offering exactly one item.
    var controlActivation: ShareActivation {
        Sample.activation(
            Sample.sharedProvider(token: 1, itemCount: 1, contentTypeHint: contentTypeHint)
        )
    }

    /// The control picker item: exactly one selected item.
    var controlPickerItem: PhotosPickerItemReference {
        Sample.pickerItem(token: 1, contentTypeHint: contentTypeHint)
    }

    // MARK: Identifiers

    var generatedPhotosSessionID: AnalysisSessionID { Sample.sessionID("session-p4-photos-generated") }
    var controlPhotosSessionID: AnalysisSessionID { Sample.sessionID("session-p4-photos-control") }
    var generatedShareCandidate: AnalysisSessionID { Sample.sessionID("session-p4-share-generated") }
    var firstControlCandidate: AnalysisSessionID { Sample.sessionID("session-p4-share-first") }
    var secondControlCandidate: AnalysisSessionID { Sample.sessionID("session-p4-share-second") }

    /// The Extension Execution Policy version the transfer-store fixture is bound to.
    var extensionPolicyID: ArtifactID { Sample.artifactID("extension-execution-0001") }

    var manifestKey: EphemeralStorageKey {
        Sample.storageKey("m" + Self.hexadecimal(UInt64(bitPattern: Int64(seed)) &* 2_654_435_761 &+ 1))
    }

    var payloadKey: EphemeralStorageKey {
        Sample.storageKey("p" + Self.hexadecimal(UInt64(bitPattern: Int64(seed)) &* 2_654_435_761 &+ 2))
    }

    // MARK: Tickets

    /// A structurally valid Share ticket, for the route arm.
    ///
    /// Its `createdAt` is the fixture instant rather than a generated one: the encoded record
    /// is re-serialized in that arm, and an exact instant keeps the round trip free of any
    /// decimal perturbation, so a refusal there is attributable to the route alone.
    var validTicket: ShareTransferTicket {
        Sample.ticket(
            transferID: Sample.transferID("transfer-p4-\(seed)"),
            sessionID: Sample.sessionID("session-p4-ticket"),
            contentTypeHint: contentTypeHint,
            byteCount: UInt64(byteCount),
            sha256: StreamingSHA256.digest(of: Data(bytes)),
            preservationBasis: ticketBasis,
            createdAt: fixtureNow
        )
    }

    /// A ticket that tries to record the Photos route, which is not constructible.
    var ticketNamingThePhotosRoute: ShareTransferTicket? {
        ShareTransferTicket(
            transferID: Sample.transferID("transfer-p4-\(seed)"),
            sessionID: Sample.sessionID("session-p4-ticket"),
            route: .photosPicker,
            contentTypeHint: contentTypeHint,
            byteCount: UInt64(byteCount),
            sha256: StreamingSHA256.digest(of: Data(bytes)),
            preservationStatus: ticketBasis.mostConservativeStatus,
            preservationBasis: ticketBasis,
            extensionBuildID: Sample.buildID(),
            createdAt: fixtureNow
        )
    }

    // MARK: Tables

    /// Structural buffer sizes. Test scaffolding, not an approved value.
    static let chunkSizes = [17, 64, 512, 4_096]

    /// Provider-declared type hints, including none. Recorded, never trusted.
    static let hints: [String?] = [nil, "public.jpeg", "public.png", "public.heic", "public.heif"]

    /// Route spellings outside the Version 1 vocabulary.
    ///
    /// Case variants and hyphenated forms are included on purpose: a decoder that matched a
    /// route loosely would accept a record whose route DefAIke never wrote. The empty
    /// string is the degenerate case a truncated write could leave behind.
    static let unknownRouteTokens = [
        "photos-picker",
        "PhotosPicker",
        "photospicker",
        "share-extension",
        "ShareExtension",
        "shareextension",
        "airDrop",
        "filesApp",
        "pasteboard",
        "",
    ]

    /// Sixteen lowercase hexadecimal digits. Storage keys are opaque names, so any canonical
    /// token will do; distinct prefixes keep the manifest from naming itself as its payload.
    private static func hexadecimal(_ value: UInt64) -> String {
        let digits: [Character] = Array("0123456789abcdef")
        var raw = ""
        var remaining = value
        for _ in 0..<16 {
            raw.append(digits[Int(remaining & 0xF)])
            remaining >>= 4
        }
        return raw
    }

    var description: String {
        """
        seed \(seed), selected \(selectedItemCount), providers \(providerCount), \
        provider items \(providerItemCount), availability \(availability.key), \
        \(byteCount) bytes, chunk \(chunkSizeInBytes), form \(sharedForm.rawValue), \
        basis \(ticketBasis.rawValue), hint \(contentTypeHint?.rawValue ?? "none"), \
        unknown route "\(unknownRouteToken)", \
        photos first \(photosRouteRunsFirst)
        """
    }

    // MARK: Generator

    static var generator: Generator<IngestRequestShape, AnySequence<Any>> {
        zip(
            Gen.int(in: 0...9_999),
            Gen.bool,
            index,
            index,
            index,
            index,
            Gen.int(in: 1...2_048),
            index,
            index,
            zip(index, index)
        )
        .map { raw in
            IngestRequestShape(
                seed: raw.0,
                photosRouteRunsFirst: raw.1,
                selectedItemCountIndex: raw.2,
                providerCountIndex: raw.3,
                providerItemCountIndex: raw.4,
                availabilityIndex: raw.5,
                byteCount: raw.6,
                formIndex: raw.7,
                chunkIndex: raw.8,
                unknownRouteIndex: raw.9.0,
                hintIndex: raw.9.1
            )
        }
        .eraseToAny()
    }

    /// A selector index.
    ///
    /// The range is a multiple of every modulus it is reduced by (2, 3, 4, 5, 6, 10), so each
    /// table entry is drawn with equal probability rather than with a modulus bias.
    private static var index: Generator<Int, AnySequence<Any>> {
        Gen.int(in: 0...119).eraseToAny()
    }
}

// MARK: - The reference model

/// What the requirements say about a count, written from the requirement rather than from the
/// code under test.
///
/// Small on purpose. The value of an oracle this shape is that it restates Requirement 2.7's
/// sentence — "a number of selected items other than one" — and the design's rule that both
/// of an activation's counts are checked, so the comparison is against the requirement rather
/// than against a second reading of the implementation.
private enum ReferenceIngestModel {
    /// How many items one picker selection may hand to the import port.
    static func admittedItemCount(selectedItemCount: Int) -> Int {
        selectedItemCount == 1 ? 1 : 0
    }

    /// Why an activation offering these counts may not be handed off, or `nil` when it may.
    static func activationRefusal(
        providerCount: Int,
        soleProviderItemCount: Int
    ) -> ShareActivationRefusal? {
        if providerCount == 0 { return .noProviderOffered }
        if providerCount != 1 { return .providerCountUnsupported(providerCount) }
        if soleProviderItemCount != 1 { return .itemCountUnsupported(soleProviderItemCount) }
        return nil
    }

    /// Whether a request creates an Analysis Session.
    ///
    /// The property's biconditional: both halves have to hold, and neither one alone is
    /// enough.
    static func createsSession(
        countGatePassed: Bool,
        availability: RepresentationAvailability
    ) -> Bool {
        countGatePassed && availability.yieldsOneLocalRepresentation
    }
}

// MARK: - One App Group container

/// One transfer store over its own protected directory.
///
/// A real store over a real directory rather than a double: publication is a rename on a file
/// system, and a double that models a rename as a dictionary update cannot show that a
/// refused activation left nothing resumable behind.
private struct ShareContainer {
    let root: URL
    let fileStore: ProtectedEphemeralFileStore
    let transfers: SharedTransferStore

    init(root: URL, chunkSizeInBytes: Int) {
        self.root = root
        let fileStore = ProtectedEphemeralFileStore(
            configuration: .test(root: root),
            protection: PlatformDataProtection(),
            clock: FixedClock(fixtureNow)
        )
        self.fileStore = fileStore
        self.transfers = SharedTransferStore.test(
            over: fileStore,
            chunkSizeInBytes: chunkSizeInBytes
        )
    }

    /// Every transfer scope the underlying store still owns.
    func transferScopes() async -> Set<EphemeralStorageScope> {
        await fileStore.occupiedScopes().filter {
            if case .transfer = $0 { return true }
            return false
        }
    }
}

/// One app-private session store over its own protected directory.
private struct PhotosContainer {
    let root: URL
    let store: ProtectedEphemeralFileStore

    init(root: URL) {
        self.root = root
        self.store = ProtectedEphemeralFileStore(
            configuration: .test(root: root),
            protection: PlatformDataProtection(),
            clock: FixedClock(fixtureNow)
        )
    }
}

/// What one Share activation did, and what the spies around it observed.
private struct ShareAttempt {
    let outcome: ShareHandoffOutcome

    /// Providers the host was asked about. Zero means the host was never touched.
    let requestedProviders: Int

    /// How many times bytes were borrowed.
    let consumeCount: Int

    /// Consent actions presented. Zero means the consent screen never appeared.
    let presentedRequests: Int
}

// MARK: - The scenario

/// One generated ingest request, run against the real ingest surfaces.
///
/// Three separate containers, because the single ready slot is a property of one App Group
/// container: the generated activation and the control activation must not compete for the
/// same slot, and the Photos runs must not be able to satisfy a Share assertion. The two
/// Photos runs share one container under distinct session scopes, which is what lets "the
/// refused selection stored nothing" be checked per scope.
private struct IngestScenario {
    let shape: IngestRequestShape
    let witness: IngestVariationWitness

    private let generatedShare: ShareContainer
    private let controlShare: ShareContainer
    private let photos: PhotosContainer

    init(shape: IngestRequestShape, witness: IngestVariationWitness) {
        self.shape = shape
        self.witness = witness
        self.generatedShare = ShareContainer(
            root: Self.temporaryRoot("share-generated"),
            chunkSizeInBytes: shape.chunkSizeInBytes
        )
        self.controlShare = ShareContainer(
            root: Self.temporaryRoot("share-control"),
            chunkSizeInBytes: shape.chunkSizeInBytes
        )
        self.photos = PhotosContainer(root: Self.temporaryRoot("photos"))
    }

    /// Removes every directory this case owned.
    ///
    /// Synchronous and unconditional so it can run from a `defer` in the property body, and
    /// tolerant of a root that was never created: a case whose store was never written to has
    /// nothing on disk, which is not a failure.
    func removeTemporaryRoots() {
        for root in [generatedShare.root, controlShare.root, photos.root] {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - The route vocabulary

    /// The Version 1 route set is exactly the two routes, and the generated unknown spelling
    /// is outside it (Requirements 2.6 and 2.8).
    func checkTheRouteVocabularyIsExactlyTheTwoSupportedRoutes() {
        #expect(InputRoute.allCases == [.photosPicker, .shareExtension])
        #expect(
            Set(InputRoute.allCases.map(\.rawValue)) == ["photosPicker", "shareExtension"],
            "the Version 1 ingest routes are exactly the picker and the Share Extension"
        )
        // A route DefAIke never wrote is not a route it can read. If this ever fails, the
        // token table in this file has drifted into the vocabulary and the arm below would be
        // asserting nothing.
        #expect(
            InputRoute(rawValue: shape.unknownRouteToken) == nil,
            "\"\(shape.unknownRouteToken)\" must be outside the route vocabulary"
        )
        witness.recordRouteVocabularyCheck()
    }

    // MARK: - An unknown route

    /// A published record naming any route other than the Share route does not resolve into a
    /// resumable session (Requirements 2.6 and 2.8).
    ///
    /// Asserted against the real cross-process path: the bounded manifest a publication writes
    /// and a claim reads. Two controls run first — the unaltered bytes resolve, and
    /// re-serializing without touching the route still resolves — so a refusal below is
    /// attributable to the route rather than to the splice that changed it.
    func checkARecordNamingAnotherRouteDoesNotResolve() {
        let ticket = shape.validTicket
        guard
            let manifest = TransferManifest(
                ticket: ticket,
                manifestKey: shape.manifestKey,
                payloadKey: shape.payloadKey
            )
        else {
            reportUnbuildableInput("a valid transfer manifest must be constructible")
            return
        }
        guard let encoded = try? TransferManifestCoding.encode(manifest) else {
            reportUnbuildableInput("a valid transfer manifest must encode")
            return
        }

        switch Self.decodeManifest(encoded) {
        case .success(let resolved):
            #expect(resolved.ticket == ticket)
            #expect(resolved.ticket.route == .shareExtension)
            witness.recordManifestControl()
        case .failure(let fault):
            reportUnbuildableInput("a valid transfer manifest must resolve: \(fault)")
        }

        guard let reserialized = Self.splicingTicketRoute(encoded, to: nil) else {
            reportUnbuildableInput("the manifest must be re-serializable")
            return
        }
        switch Self.decodeManifest(reserialized) {
        case .success(let resolved):
            #expect(
                resolved.ticket == ticket,
                "re-serializing without touching the route must be lossless"
            )
            witness.recordManifestControl()
        case .failure(let fault):
            reportUnbuildableInput("an untouched re-serialization must resolve: \(fault)")
        }

        // The two off-vocabulary values: an unknown spelling, and the other supported route.
        // Neither may resolve, because a record carrying either one does not describe a
        // pending Share session.
        for replacement in [shape.unknownRouteToken, InputRoute.photosPicker.rawValue] {
            guard let spliced = Self.splicingTicketRoute(encoded, to: replacement) else {
                reportUnbuildableInput("the route field must be spliceable to \"\(replacement)\"")
                continue
            }
            #expect(spliced != encoded, "the splice must actually change the record")
            switch Self.decodeManifest(spliced) {
            case .success(let resolved):
                Issue.record(
                    """
                    a record naming route "\(replacement)" must not resolve into a session, \
                    got \(resolved.ticket.route.rawValue)
                    """
                )
            case .failure:
                witness.recordOffVocabularyRouteRefusal(replacement)
            }
        }

        // And the other route is not even constructible in a Share ticket, so the refusal
        // above is a second line rather than the only one (Requirement 2.8).
        #expect(shape.ticketNamingThePhotosRoute == nil)
        witness.recordUnknownRouteCheck()
    }

    // MARK: - The picker selection's count

    /// A picker selection admits exactly one item to the import port and nothing otherwise
    /// (Requirements 2.5 and 2.7).
    func checkThePickerSelectionAdmitsOnlyOneItem() async {
        let selection = PhotosPickerSelection(items: shape.selectedItems)
        let admitted = ReferenceIngestModel.admittedItemCount(
            selectedItemCount: shape.selectedItemCount
        )

        #expect(selection.items.count == shape.selectedItemCount)
        #expect(selection.isCancellation == (shape.selectedItemCount == 0))
        #expect((selection.soleItem == nil ? 0 : 1) == admitted)
        if admitted == 1 {
            #expect(selection.soleItem == shape.selectedItems[0])
        } else {
            #expect(selection.soleItem == nil)
        }

        // Drive the real adapter through the only accessor a selection has, and require the
        // provider to have been asked exactly as many times as the gate admits. A selection of
        // zero or many has nothing to hand across: the port takes one item.
        let access = FakePhotosAccess(shape.photosOffer)
        let adapter = makePhotosAdapter(access: access)
        var accepted: ImportedEncodedAsset?
        if let item = selection.soleItem {
            if case .success(let asset) = await adapter.attemptImport(
                of: item,
                into: shape.generatedPhotosSessionID
            ) {
                accepted = asset
            }
        }

        #expect(await access.requestedItems.count == admitted)
        #expect(await access.consumeCount <= admitted)

        let expectsSession = ReferenceIngestModel.createsSession(
            countGatePassed: admitted == 1,
            availability: shape.availability
        )
        #expect((accepted != nil) == expectsSession)
        if accepted == nil {
            #expect(
                await photos.store.keys(in: .session(shape.generatedPhotosSessionID)).isEmpty,
                "a refused picker selection leaves no session material"
            )
        }
        witness.recordPickerGateCheck()
    }

    // MARK: - The activation's counts

    /// An activation is handed off only when it offers exactly one provider offering exactly
    /// one item, and any other count is refused before the consent action appears and before
    /// the host is asked for anything (Requirements 2.5 and 2.7).
    func checkTheActivationAdmitsOnlyOneProviderOfferingOneItem() async {
        let activation = shape.generatedActivation
        let expectedRefusal = ReferenceIngestModel.activationRefusal(
            providerCount: shape.providerCount,
            soleProviderItemCount: shape.providerItemCount
        )

        #expect(activation.providers.count == shape.providerCount)
        if let expectedRefusal {
            #expect(activation.resolvedCandidate == .refused(expectedRefusal))
        } else {
            #expect(activation.resolvedCandidate == .oneItem(activation.providers[0]))
        }

        // Consent for a provider that does not offer exactly one item is not constructible, so
        // the count rule cannot be sidestepped by calling the staging port directly with a
        // token (Requirement 2.7).
        let consent = ConfirmedConsent(
            provider: Sample.sharedProvider(itemCount: shape.providerItemCount),
            extensionExecutionPolicyID: shape.extensionPolicyID,
            confirmedAt: fixtureNow
        )
        #expect((consent != nil) == (shape.providerItemCount == 1))

        guard
            let attempt = await run(
                activation,
                in: generatedShare,
                candidate: shape.generatedShareCandidate
            )
        else { return }

        if let expectedRefusal {
            #expect(attempt.outcome == .activationRefused(expectedRefusal))
            #expect(attempt.outcome.publishedTicket == nil)
            // Refused before anything is asked of the host, so the consent action never
            // appeared and no byte of any offered item was read.
            #expect(attempt.presentedRequests == 0)
            #expect(attempt.requestedProviders == 0)
            #expect(attempt.consumeCount == 0)
            #expect(await generatedShare.transferScopes().isEmpty)
            #expect(await readySlot(of: generatedShare) == ReadySlotState.empty)
            #expect(await usedBytes(of: generatedShare) == 0)
            witness.recordActivationRefusal(expectedRefusal)
        } else {
            // The positive control for the nonoccurrence above: when the counts do pass, the
            // consent action really is presented and the host really is asked, so those spies
            // would have recorded a call had one been made.
            #expect(attempt.presentedRequests == 1)
            #expect(attempt.requestedProviders == 1)
            if case .activationRefused(let refusal) = attempt.outcome {
                Issue.record("one provider offering one item must not be refused: \(refusal)")
            }
        }
        witness.recordActivationGateCheck()
    }

    // MARK: - One local representation

    /// With the counts held at exactly one, a session exists on either route if and only if
    /// exactly one complete local representation was retained (Requirement 2.5).
    func checkOneLocalRepresentationDecidesWhetherASessionExists() async {
        if shape.photosRouteRunsFirst {
            await checkThePhotosControlRequest()
            await checkTheShareControlRequest()
        } else {
            await checkTheShareControlRequest()
            await checkThePhotosControlRequest()
        }
        witness.recordRepresentationCheck()
    }

    private func checkThePhotosControlRequest() async {
        let expectsSession = shape.availability.yieldsOneLocalRepresentation
        let access = FakePhotosAccess(shape.photosOffer)
        let adapter = makePhotosAdapter(access: access)
        let session = shape.controlPhotosSessionID

        switch await adapter.attemptImport(of: shape.controlPickerItem, into: session) {
        case .success(let asset):
            #expect(expectsSession, "\(shape.availability.key) must not create a session")
            // Exactly one recorded route, and it is this route (Requirement 2.8).
            #expect(asset.route == .photosPicker)
            #expect(asset.route != .shareExtension)
            #expect(asset.sessionID == session)
            #expect(asset.byteCount == UInt64(shape.byteCount))
            // Exactly one image is bound to the session: the scope holds one object, and it is
            // the one the accepted ingest names (Requirement 2.5).
            #expect(await photos.store.keys(in: .session(session)) == [asset.handle.storageKey])
            witness.recordCreatedSession(route: .photosPicker)
        case .failure:
            #expect(!expectsSession, "a complete local representation must create a session")
            #expect(await photos.store.keys(in: .session(session)).isEmpty)
            witness.recordNoSession(route: .photosPicker)
        }
        witness.recordPhotosControlRequest()
    }

    private func checkTheShareControlRequest() async {
        let expectsSession = shape.availability.yieldsOneLocalRepresentation
        guard
            let attempt = await run(
                shape.controlActivation,
                in: controlShare,
                candidate: shape.firstControlCandidate
            )
        else { return }

        // The counts pass, so the consent action is presented on every availability: a
        // representation that turned out to be absent is not a count refusal.
        #expect(attempt.presentedRequests == 1)
        #expect(attempt.requestedProviders == 1)
        #expect((attempt.outcome.publishedTicket != nil) == expectsSession)

        guard let ticket = attempt.outcome.publishedTicket else {
            #expect(!expectsSession, "a complete local representation must create a session")
            #expect(await readySlot(of: controlShare) == ReadySlotState.empty)
            #expect(await controlShare.transferScopes().isEmpty)
            #expect(await usedBytes(of: controlShare) == 0)
            witness.recordNoSession(route: .shareExtension)
            witness.recordShareControlRequest()
            return
        }

        #expect(expectsSession, "\(shape.availability.key) must not create a session")
        // Exactly one recorded route, and it is this route (Requirement 2.8).
        #expect(ticket.route == .shareExtension)
        #expect(ticket.route != .photosPicker)
        // The pending session is the candidate this attempt allocated, and there is exactly
        // one of it (Requirements 2.5 and 2.3).
        #expect(ticket.sessionID == shape.firstControlCandidate)
        #expect(ticket.byteCount == UInt64(shape.byteCount))
        if let published = await readySlot(of: controlShare)?.publishedTransfer {
            #expect(published.ticket == ticket)
        } else {
            Issue.record("a published handoff must leave exactly one pending transfer")
        }
        witness.recordCreatedSession(route: .shareExtension)
        witness.recordShareControlRequest()
    }

    // MARK: - No second session

    /// A second request creates no second session: the pending slot holds exactly one, and it
    /// stays the first one (Requirements 2.5 and 2.8).
    ///
    /// The second attempt runs with a different candidate identifier, so "no second session
    /// was created" is observable rather than assumed: the slot would have to name the second
    /// candidate for a second session to exist.
    func checkNoSecondSessionJoinsThePendingSlot() async {
        let pendingBefore = await readySlot(of: controlShare)?.publishedTransfer
        guard
            let second = await run(
                shape.controlActivation,
                in: controlShare,
                candidate: shape.secondControlCandidate
            )
        else { return }

        #expect(second.outcome.publishedTicket == nil)
        let pendingAfter = await readySlot(of: controlShare)?.publishedTransfer
        #expect(pendingAfter?.ticket == pendingBefore?.ticket)

        if let pendingBefore {
            guard case .pendingHandoff(let recovery) = second.outcome else {
                Issue.record("a pending handoff must not be replaced, got \(second.outcome)")
                witness.recordSecondRequestCheck()
                return
            }
            #expect(recovery.pendingTransfer == pendingBefore.ticket.transferID)
            #expect(pendingAfter?.ticket.sessionID == pendingBefore.ticket.sessionID)
            #expect(pendingAfter?.ticket.sessionID != shape.secondControlCandidate)
            // The slot is checked before the consent action, so the second request never asked
            // the user and never read a byte.
            #expect(second.presentedRequests == 0)
            #expect(second.requestedProviders == 0)
            #expect(second.consumeCount == 0)
            witness.recordPendingHandoffRefusal()
        } else {
            // The first attempt created nothing, so the slot was empty and the second attempt
            // creates nothing either: a failed attempt leaves no session for a retry to
            // inherit.
            #expect(pendingAfter == nil)
            #expect(await controlShare.transferScopes().isEmpty)
            witness.recordEmptySlotRetry()
        }
        witness.recordSecondRequestCheck()
    }

    // MARK: - Running one request

    /// Runs one activation through the real coordinator and reports what the spies saw.
    ///
    /// Returns `nil` only when a fixture could not be built, which is a defect in this file
    /// rather than a finding about the coordinator; the witness counts it so a run whose
    /// inputs stopped being buildable fails outside the body.
    private func run(
        _ activation: ShareActivation,
        in container: ShareContainer,
        candidate: AnalysisSessionID
    ) async -> ShareAttempt? {
        let access = FakeSharedItemAccess(shape.sharedOffer)
        let presenter = ScriptedConsentPresenter.confirming()
        guard
            let coordinator = ShareExtensionIngestCoordinator(
                access: access,
                consentPresenter: presenter,
                transfers: container.transfers,
                governor: ProgrammedShareResourceGovernor(),
                budget: Sample.shareBudget(),
                instruction: Sample.manualInstruction(),
                candidateSessions: FixedCandidateSessionIdentifierSource(candidate)
            )
        else {
            reportUnbuildableInput("the Share ingest coordinator fixture must be constructible")
            return nil
        }

        let outcome = await coordinator.handleActivation(activation)
        return ShareAttempt(
            outcome: outcome,
            requestedProviders: await access.requestedProviders.count,
            consumeCount: await access.consumeCount,
            presentedRequests: await presenter.presentedRequests.count
        )
    }

    private func makePhotosAdapter(access: any PhotosRepresentationAccess) -> PhotosImportAdapter {
        PhotosImportAdapter(
            access: access,
            store: photos.store,
            sessionFileProtection: .complete,
            chunkSizeInBytes: shape.chunkSizeInBytes
        )
    }

    // MARK: - Nonthrowing store reads

    /// The container's ready slot, or `nil` when the store could not say.
    ///
    /// Wrapped rather than rethrown: an error escaping the property body would report a
    /// passing run with every arm skipped.
    private func readySlot(of container: ShareContainer) async -> ReadySlotState? {
        do {
            return try await container.transfers.readySlotState()
        } catch {
            Issue.record("the ready slot must be readable: \(error)")
            return nil
        }
    }

    /// Bytes the container holds, or `nil` when the store could not say.
    private func usedBytes(of container: ShareContainer) async -> UInt64? {
        do {
            return try await container.fileStore.usedByteCount()
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

    private static func temporaryRoot(_ label: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(
                path: "defaike-p4-\(label)-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
    }

    /// Decodes a published manifest into a value, so nothing throws out of an arm.
    private static func decodeManifest(
        _ bytes: [UInt8]
    ) -> Result<TransferManifest, TransferManifestCodingFault> {
        do {
            return .success(try TransferManifestCoding.decode(bytes))
        } catch {
            return .failure(error)
        }
    }

    /// Re-serializes an encoded manifest, optionally replacing the ticket's route.
    ///
    /// A structured splice rather than a text substitution: it edits exactly the one member
    /// the arm is about, and passing `nil` performs the same round trip without touching it,
    /// which is the control that makes a spliced-route refusal attributable to the route.
    /// Returns `nil` when the record does not have the shape this file expects, which is a
    /// defect in this file rather than a finding.
    private static func splicingTicketRoute(_ encoded: [UInt8], to route: String?) -> [UInt8]? {
        guard
            var record = (try? JSONSerialization.jsonObject(with: Data(encoded)))
                as? [String: Any],
            var ticket = record["ticket"] as? [String: Any],
            let existing = ticket["route"] as? String,
            existing == InputRoute.shareExtension.rawValue
        else { return nil }
        if let route {
            guard route != existing else { return nil }
            ticket["route"] = route
            record["ticket"] = ticket
        }
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: record,
                options: [.sortedKeys]
            )
        else { return nil }
        return Array(data)
    }
}

// MARK: - Provider offers

extension IngestRequestShape {
    /// What the Share route's host offers for this case.
    fileprivate var sharedOffer: FakeSharedItemAccess.Offer {
        switch availability {
        case .oneCompleteRepresentation:
            .representation(bytes: bytes, form: sharedForm)
        case .emptyRepresentation:
            .representation(bytes: [], form: sharedForm)
        case .providerProducedNothing(let reason):
            .noRepresentation(reason.sharedFault)
        }
    }

    /// What the Photos route's provider offers for this case.
    fileprivate var photosOffer: FakePhotosAccess.Offer {
        switch availability {
        case .oneCompleteRepresentation:
            .representation(
                bytes: bytes,
                form: photosForm,
                suppliedContentTypeHint: contentTypeHint
            )
        case .emptyRepresentation:
            .representation(
                bytes: [],
                form: photosForm,
                suppliedContentTypeHint: contentTypeHint
            )
        case .providerProducedNothing(let reason):
            .noRepresentation(reason.photosFault)
        }
    }
}

// MARK: - The variation witness

/// Counts what the run generated and what it produced, outside the property body.
///
/// `propertyCheck` runs its body under `try?`, so a body that failed before its first
/// assertion reports a passing test in milliseconds with every arm skipped. Two habits close
/// that gap, and both matter:
///
///   * every arm counter is compared against the **case count** rather than against a floor,
///     so a run in which an arm stopped being reached fails even if the absolute number still
///     looks large; and
///   * ``recordCompletedBody()`` is the last thing the body does, so a case that ended early
///     is countable. `completedBodies == cases` alone would pass vacuously as `0 == 0`, which
///     is why the case floor sits beside it.
///
/// The produced sets are the substantive half. Both routes must have *created* a session and
/// must have *produced* a no-session outcome, all six selected-item counts and all four
/// provider counts must have been offered, each of the three activation refusals must have
/// been returned by the real coordinator, and a pending handoff must actually have refused a
/// second request — which is what turns "one item and one route" from a claim about unreached
/// branches into a claim about produced outcomes.
///
/// The variation thresholds are far below what 100 uniform draws produce, so they witness
/// variation rather than pinning a distribution.
private final class IngestVariationWitness: @unchecked Sendable {
    private let lock = NSLock()

    // Arm counters.
    private var cases = 0
    private var completedBodies = 0
    private var routeVocabularyChecks = 0
    private var unknownRouteChecks = 0
    private var manifestControls = 0
    private var offVocabularyRefusals = 0
    private var pickerGateChecks = 0
    private var activationGateChecks = 0
    private var representationChecks = 0
    private var photosControlRequests = 0
    private var shareControlRequests = 0
    private var secondRequestChecks = 0
    private var unbuildableInputs = 0

    // Produced outcomes.
    private var producedSessionRoutes: Set<InputRoute> = []
    private var producedNoSessionRoutes: Set<InputRoute> = []
    private var producedRefusalKinds: Set<String> = []
    private var producedRefusedCounts: Set<Int> = []
    private var pendingHandoffRefusals = 0
    private var emptySlotRetries = 0
    private var refusedRouteTokens: Set<String> = []

    // Generated baseline.
    private var seeds: Set<Int> = []
    private var selectedItemCounts: Set<Int> = []
    private var providerCounts: Set<Int> = []
    private var providerItemCounts: Set<Int> = []
    private var availabilityKeys: Set<String> = []
    private var byteCounts: Set<Int> = []
    private var chunkSizes: Set<Int> = []
    private var sharedForms: Set<SharedRepresentationForm> = []
    private var photosForms: Set<SuppliedRepresentationForm> = []
    private var ticketBases: Set<PreservationBasis> = []
    private var hintKeys: Set<String> = []
    private var unknownRouteTokens: Set<String> = []
    private var routeOrders: Set<Bool> = []

    /// Every activation refusal the real coordinator must have returned.
    static let requiredRefusalKinds: Set<String> = [
        "no-provider-offered",
        "provider-count-unsupported",
        "item-count-unsupported",
    ]

    func record(_ shape: IngestRequestShape) {
        lock.lock()
        defer { lock.unlock() }
        cases += 1
        seeds.insert(shape.seed)
        selectedItemCounts.insert(shape.selectedItemCount)
        providerCounts.insert(shape.providerCount)
        providerItemCounts.insert(shape.providerItemCount)
        availabilityKeys.insert(shape.availability.key)
        byteCounts.insert(shape.byteCount)
        chunkSizes.insert(shape.chunkSizeInBytes)
        sharedForms.insert(shape.sharedForm)
        photosForms.insert(shape.photosForm)
        ticketBases.insert(shape.ticketBasis)
        hintKeys.insert(shape.contentTypeHint?.rawValue ?? "none")
        unknownRouteTokens.insert(shape.unknownRouteToken)
        routeOrders.insert(shape.photosRouteRunsFirst)
    }

    func recordRouteVocabularyCheck() {
        lock.lock()
        routeVocabularyChecks += 1
        lock.unlock()
    }

    func recordUnknownRouteCheck() {
        lock.lock()
        unknownRouteChecks += 1
        lock.unlock()
    }

    func recordManifestControl() {
        lock.lock()
        manifestControls += 1
        lock.unlock()
    }

    func recordOffVocabularyRouteRefusal(_ token: String) {
        lock.lock()
        offVocabularyRefusals += 1
        refusedRouteTokens.insert(token)
        lock.unlock()
    }

    func recordPickerGateCheck() {
        lock.lock()
        pickerGateChecks += 1
        lock.unlock()
    }

    func recordActivationGateCheck() {
        lock.lock()
        activationGateChecks += 1
        lock.unlock()
    }

    func recordActivationRefusal(_ refusal: ShareActivationRefusal) {
        lock.lock()
        switch refusal {
        case .noProviderOffered:
            producedRefusalKinds.insert("no-provider-offered")
        case .providerCountUnsupported(let count):
            producedRefusalKinds.insert("provider-count-unsupported")
            producedRefusedCounts.insert(count)
        case .itemCountUnsupported(let count):
            producedRefusalKinds.insert("item-count-unsupported")
            producedRefusedCounts.insert(count)
        }
        lock.unlock()
    }

    func recordRepresentationCheck() {
        lock.lock()
        representationChecks += 1
        lock.unlock()
    }

    func recordPhotosControlRequest() {
        lock.lock()
        photosControlRequests += 1
        lock.unlock()
    }

    func recordShareControlRequest() {
        lock.lock()
        shareControlRequests += 1
        lock.unlock()
    }

    func recordCreatedSession(route: InputRoute) {
        lock.lock()
        producedSessionRoutes.insert(route)
        lock.unlock()
    }

    func recordNoSession(route: InputRoute) {
        lock.lock()
        producedNoSessionRoutes.insert(route)
        lock.unlock()
    }

    func recordPendingHandoffRefusal() {
        lock.lock()
        pendingHandoffRefusals += 1
        lock.unlock()
    }

    func recordEmptySlotRetry() {
        lock.lock()
        emptySlotRetries += 1
        lock.unlock()
    }

    func recordSecondRequestCheck() {
        lock.lock()
        secondRequestChecks += 1
        lock.unlock()
    }

    /// Records that a fixture this file described could not be built.
    ///
    /// Never a finding about ingest: every input here is built from generated integers inside
    /// validated ranges, so a refusal is a defect in this file. It is counted so a run whose
    /// inputs quietly stopped being buildable fails outside the body rather than shrinking its
    /// own coverage.
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
        #expect(routeVocabularyChecks == cases, "route vocabulary checks: \(routeVocabularyChecks)")
        #expect(unknownRouteChecks == cases, "unknown route checks: \(unknownRouteChecks)")
        #expect(pickerGateChecks == cases, "picker gate checks: \(pickerGateChecks)")
        #expect(activationGateChecks == cases, "activation gate checks: \(activationGateChecks)")
        #expect(representationChecks == cases, "representation checks: \(representationChecks)")
        #expect(photosControlRequests == cases, "Photos control requests: \(photosControlRequests)")
        #expect(shareControlRequests == cases, "Share control requests: \(shareControlRequests)")
        #expect(secondRequestChecks == cases, "second request checks: \(secondRequestChecks)")
        // Two manifest controls and two off-vocabulary refusals per case.
        #expect(manifestControls == cases * 2, "manifest controls resolved: \(manifestControls)")
        #expect(
            offVocabularyRefusals == cases * 2,
            "off-vocabulary route records refused: \(offVocabularyRefusals)"
        )

        // The substantive half: the outcomes were produced, not merely offered.
        #expect(
            producedSessionRoutes == Set(InputRoute.allCases),
            """
            routes that never created a session: \
            \(Set(InputRoute.allCases).subtracting(producedSessionRoutes).map(\.rawValue).sorted())
            """
        )
        #expect(
            producedNoSessionRoutes == Set(InputRoute.allCases),
            """
            routes that never produced a no-session outcome: \
            \(Set(InputRoute.allCases).subtracting(producedNoSessionRoutes).map(\.rawValue).sorted())
            """
        )
        #expect(
            producedRefusalKinds == Self.requiredRefusalKinds,
            """
            activation refusals never returned: \
            \(Self.requiredRefusalKinds.subtracting(producedRefusalKinds).sorted())
            """
        )
        #expect(
            producedRefusedCounts.count >= 3,
            "refused counts observed: \(producedRefusedCounts.sorted())"
        )
        #expect(
            pendingHandoffRefusals >= 1,
            "a pending handoff never refused a second request: \(pendingHandoffRefusals)"
        )
        #expect(
            emptySlotRetries >= 1,
            "a no-session attempt was never retried against an empty slot: \(emptySlotRetries)"
        )
        #expect(
            refusedRouteTokens.count >= 5,
            "off-vocabulary route spellings refused: \(refusedRouteTokens.count)"
        )

        // The generated baseline actually varied.
        #expect(seeds.count >= 50, "generated seeds: \(seeds.count)")
        #expect(
            selectedItemCounts == Set(0...5),
            "selected-item counts never generated: \(Set(0...5).subtracting(selectedItemCounts).sorted())"
        )
        #expect(
            providerCounts == Set(0...3),
            "provider counts never generated: \(Set(0...3).subtracting(providerCounts).sorted())"
        )
        #expect(
            providerItemCounts == Set(0...3),
            "provider item counts never generated: \(Set(0...3).subtracting(providerItemCounts).sorted())"
        )
        #expect(
            availabilityKeys == RepresentationAvailability.distinctKeys,
            """
            availabilities never generated: \
            \(RepresentationAvailability.distinctKeys.subtracting(availabilityKeys).sorted())
            """
        )
        #expect(byteCounts.count >= 50, "generated byte counts: \(byteCounts.count)")
        #expect(
            chunkSizes == Set(IngestRequestShape.chunkSizes),
            "generated chunk sizes: \(chunkSizes.sorted())"
        )
        #expect(
            sharedForms == Set(SharedRepresentationForm.allCases),
            "generated Share representation forms: \(sharedForms.map(\.rawValue).sorted())"
        )
        #expect(
            photosForms == Set(SuppliedRepresentationForm.allCases),
            "generated Photos representation forms: \(photosForms.map(\.rawValue).sorted())"
        )
        #expect(
            ticketBases == Set(PreservationBasis.allCases),
            "generated ticket bases: \(ticketBases.map(\.rawValue).sorted())"
        )
        #expect(hintKeys.count >= 4, "generated content-type hints: \(hintKeys.sorted())")
        #expect(
            unknownRouteTokens.count >= 5,
            "generated off-vocabulary route spellings: \(unknownRouteTokens.count)"
        )
        #expect(routeOrders == [false, true], "only one route order was generated")
    }
}
