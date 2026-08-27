import DefAIkeDomain
import Foundation
import PropertyBased
import Testing

@testable import DefAIkeSharedTransfer

// Design Property 6: handoff mutation fails closed.
//
// The design states it as: for any valid Share Extension ticket and payload, changing any
// payload byte, byte count, digest, preservation status, schema identity, or
// build-compatibility field before claim produces exactly `handoff-error`, deletes or
// quarantines the incomplete transfer, and starts no validation, provenance, or pixel
// inference.
//
// Every case below publishes one genuinely committed handoff, changes exactly one leaf of it,
// and then claims it. One leaf at a time is the whole discipline: a case that altered two
// fields would still fail closed, and the finding would no longer name a cause.
//
// ## The three things every mutation arm asserts
//
//   * **Exactly `handoff-error`, and nothing else.** Whenever the claim names a pending
//     session, its ``AnalysisFault`` is compared against the single exact value
//     `.analysis(.handoffError, stage: .handoffVerification)`, and separately against every
//     other member of the closed ``AnalysisError`` vocabulary and against `.cancelled`, so a
//     mutation cannot acquire `resource-limit`, `decoding-error`, or a cancellation on its way
//     out (Requirements 2.19, 11.13, and 11.17).
//   * **No downstream work.** Three independent measurements, two of them on the production
//     path: the mutated payload object's read count in the App Group container, the number of
//     objects the app-private session store was asked to create, and a stage spy the arm
//     routes an accepted ingest to. The spy's zeros would be vacuous on their own, so an
//     **unmutated control runs on every case** and is required to drive the same spy through
//     the same routing function exactly once per stage.
//   * **Cleanup.** Asserted against store state rather than against a return value: no
//     transfer scope survives in the shared container, the ready slot reads empty, the shared
//     container's used byte count is zero, and the app-private store owns no session scope and
//     zero bytes. A claim that reported the right error and left encoded image bytes behind
//     would satisfy the error requirement and violate Requirement 9.5.
//
// Two further guards keep an arm from passing on a mutation that never happened: each splice
// must report a previous value that differs from its replacement *and* produce bytes that
// differ from the record as published, and the untouched record is decoded on every case and
// required to still round-trip to the ticket the publication returned.
//
// ## Why the mutation is a scoped text splice
//
// `TransferManifestCoding.encode` sets no date strategy on purpose, so `createdAt` crosses as
// the domain's own exact `Date` representation. Re-serializing the record to change one member
// would perturb that value — the same hazard `JSONMemberSplice` in the domain tests and
// `ManifestMemberSplice` in the Model Bundle tests were written for — and an arm would then be
// unable to say whether a refusal came from the field it is about. ``TicketMemberSplice``
// therefore edits the encoded text in place and leaves every other byte alone.
//
// Scoping matters for the same reason it did there: `schemaVersion` appears twice in one
// record, once for the manifest envelope and once for the ticket inside it. A global
// substitution would change both and the finding would name two causes. The splice locates the
// sole `"ticket":{…}` body by brace depth and refuses — returning `nil` rather than unchanged
// text — whenever a member is not uniquely locatable in the scope it was asked for.
//
// ## Two dispositions, both named by the reference model, both required to occur
//
// ``ReferenceHandoffMutationModel`` decides each mutation's disposition from
// ``ShareTransferTicket/init(schemaVersion:transferID:sessionID:route:contentTypeHint:byteCount:sha256:preservationStatus:preservationBasis:extensionBuildID:createdAt:)``'s
// **documented invariants** rather than from a second reading of the claim path: the ticket
// refuses an unreadable schema version, a route other than the Share route, an empty payload,
// and a status its basis does not support, and the manifest envelope refuses an unreadable
// envelope version.
//
//   * A mutation the record's own validating decoder *accepts* leaves a readable commit
//     record. The session it names exists, so the claim resumes exactly that session in order
//     to end it with `handoff-error`.
//   * A mutation the decoder *refuses* leaves no readable commit record at all. No session
//     identifier is recoverable from it, so the material is removed and nothing is resumed —
//     `PublicationDefect.manifestMissing` with no pending session, which the adapter reports
//     as a discard rather than as a failed session.
//
// Both dispositions are asserted at full fidelity — the exact ``ShareClaimOutcome``, not a
// disjunction — and the witness requires both to have occurred on every case, so neither can
// quietly absorb the other.
//
// ## Two gaps this file found and does not paper over
//
// Both are reported rather than asserted, because asserting the observed behaviour would pin a
// gap as correct and asserting the requirement would fail against production. Neither is a
// coding slip; both follow from what the record does and does not bind.
//
//   1. **A refused record loses its session.** For the status and schema families the observed
//      outcome is a discard, so a *committed* handoff that was corrupted after publication is
//      indistinguishable from a publication that never committed, and the app returns nothing
//      where Requirements 2.19 and 11.13 ask for `handoff-error`. Evidence safety holds — no
//      verdict, no downstream work, nothing left on disk — but the error is not surfaced.
//   2. **The preservation status is not integrity-bound.** Changing `preservationStatus` and
//      `preservationBasis` *together*, to another pair the basis supports, produces a record
//      that decodes, resolves, and verifies: the digest covers the payload, and nothing covers
//      the status. Such a substitution upgrades the status across the boundary, which is
//      exactly what Requirement 2.19's status clause forbids. This file therefore represents
//      the status family by the single-field change, which is what the property's sentence
//      says, and leaves the joint substitution to the spec owner.
//
// ## What this file deliberately does not assert
//
//   * Byte, count, digest, status, and session preservation across a handoff that *did*
//     verify. That is Property 5's statement; the control arms here assert only enough to keep
//     the nonoccurrence claims honest.
//   * Declines and pre-publication cancellations. That is Property 7's statement, and nothing
//     below declines consent or cancels before the commit.
//   * Item counts and route vocabulary. That is Property 4's, and every count here is held at
//     exactly one so a refusal cannot be mistaken for a mutation being caught.
//   * That validation, provenance, or inference *code* was not entered. Those adapters live
//     outside this test target's module closure — the image pipeline and provenance modules are
//     not reachable from the module the Share Extension links, which is the point of the module
//     graph, and `ShareExtensionIngestCoordinatorTests`' source scan keeps it one. What is
//     asserted here is the ingest side: a mutated handoff produces no accepted ingest, so there
//     is nothing for either stage to be handed.
//
// ## The protection level is structural here, and it is held fixed
//
// Every store, object, and policy below uses one level, and it is entirely synthetic
// scaffolding, like every capacity, deadline, and budget limit in this target: **no protection
// level in a test is an approved release value**, and a host run is never Requirement 9.6
// evidence. The real `PlatformDataProtection` still applies it and still verifies it read back.
//
// It is pinned rather than generated for an environment reason rather than a product one.
// Development hosts have been observed to refuse opening a file for writing inside a directory
// carrying either the complete or the complete-unless-open attribute, failing with `EPERM`; a
// store rooted under such a directory then reports `.storeUnavailable` for reasons that have
// nothing to do with mutation, and every arm below would measure the host instead of the
// requirement. Whether a given host is in that state is not this file's subject, so the level is
// held at the one that is permitted either way, which keeps a failure here attributable to a
// handoff mutation rather than to the machine it ran on. `ProtectedEphemeralFileStoreTests` is
// where all three levels, the fail-closed refusal on a level that cannot be applied, and the
// verified read-back are pinned; nothing here weakens any of that, and a host run is never
// Requirement 9.6 evidence either way.
//
// ## Nothing here is an approved release value
//
// The Share Extension Resource Budget, the Extension Execution Policy, the Data Lifecycle
// Policy, the store capacity, the copy key the manual instruction addresses, the buffer sizes,
// the byte counts, and every identifier are synthetic fixtures that exist so a port taking a
// signed artifact can be called at all. No number below may be copied into a shipping artifact.
//
// ## Why no arm throws
//
// `propertyCheck` runs its body under `try?`, so an error escaping the body reports a passing
// run in milliseconds with every arm skipped. Nothing below rethrows: every throwing store,
// publication, splice, and claim call is wrapped into a value or reported through
// `Issue.record`, and ``MutationVariationWitness`` counts the cases and every arm *outside* the
// body, where an issue is not suppressed. The arm counters are compared against the case count
// rather than against a floor, and the last thing the body does is record that it reached the
// end, so a case that stopped early is countable rather than invisible.

extension Tag {
    /// Design Property 6.
    ///
    /// Declared in this file rather than in a shared tag namespace: each design property gets
    /// one dedicated file, and a shared namespace would be a merge point between property
    /// files written independently of each other.
    @Tag static var property6HandoffMutationFailsClosed: Self
}

@Suite(
    "Property 6: handoff mutation fails closed",
    .tags(.property6HandoffMutationFailsClosed)
)
struct HandoffMutationFailsClosedPropertyTests {
    /// Runs at the library default of 100 generated cases, which is the minimum the design
    /// requires; `PropertyToolchainWiringTests` pins that default. Every generator is composed
    /// with `zip`, so the shrinkers compose.
    ///
    /// **Validates: Requirements 2.19, 11.13**
    @Test("Every single-field mutation of a published handoff fails closed before any stage")
    func everyHandoffMutationFailsClosed() async {
        let witness = MutationVariationWitness()

        await propertyCheck(input: MutationShape.generator) { shape in
            witness.record(shape)
            let scenario = MutationScenario(shape: shape, witness: witness)

            // The controls run on both publication paths, and they run first when the shape
            // says so: the spies that every mutation arm asserts to be idle are the same
            // spies these two arms require to record a call, and neither container is shared,
            // so the order is free to vary and is generated.
            if shape.controlsRunFirst {
                await scenario.checkTheRealCoordinatorsUnmutatedHandoffStillVerifies()
                await scenario.checkAnUnmutatedPublicationStillVerifies()
                await scenario.checkEveryMutationFailsClosed()
                await scenario.checkThePortNarrowsOneLeafToExactlyHandoffError()
            } else {
                await scenario.checkEveryMutationFailsClosed()
                await scenario.checkThePortNarrowsOneLeafToExactlyHandoffError()
                await scenario.checkTheRealCoordinatorsUnmutatedHandoffStillVerifies()
                await scenario.checkAnUnmutatedPublicationStillVerifies()
            }

            witness.recordCompletedBody()
        }

        witness.expectVariedBaselines()
    }
}

// MARK: - The mutation families

/// One single-leaf change to a published handoff.
///
/// The five families the property's sentence names, several of them with more than one
/// independent leaf, because "any … field" is a claim about each field and not about one
/// representative of a group:
///
/// | Family | Leaves here |
/// |---|---|
/// | payload byte | one flipped byte, and a truncation |
/// | byte count | the ticket's `byteCount` |
/// | digest | the ticket's `sha256` |
/// | preservation status | the ticket's `preservationStatus` |
/// | schema identity | the ticket's schema version, and the manifest envelope's |
/// | build compatibility | the ticket's `extensionBuildID` |
///
/// The claim-side direction of the build disagreement — a correct ticket claimed by another
/// build — is the same disagreement seen from the other end and is pinned at an example by
/// `ShareHandoffClaimAdapterTests`, so it is not repeated here.
private enum HandoffMutation: String, Hashable, Sendable, CaseIterable {
    /// One payload byte flipped, with the length left alone, so only a recomputed digest can
    /// catch it.
    case payloadByteFlipped = "payload-byte-flipped"

    /// The payload shortened, with the object's recorded measurements left as written.
    case payloadTruncated = "payload-truncated"

    /// The ticket's `byteCount` changed to another positive number.
    case ticketByteCount = "ticket-byte-count"

    /// The ticket's `sha256` changed to another canonical digest.
    case ticketDigest = "ticket-digest"

    /// The ticket's `preservationStatus` changed to another status, on its own.
    case ticketPreservationStatus = "ticket-preservation-status"

    /// The ticket's schema version changed to one this build does not read.
    case ticketSchemaVersion = "ticket-schema-version"

    /// The manifest envelope's schema version changed to one this build does not read.
    case manifestSchemaVersion = "manifest-schema-version"

    /// The build recorded as having staged the transfer changed to another build.
    case ticketStagingBuild = "ticket-staging-build"

    /// The family this leaf belongs to, for coverage reporting.
    var family: String {
        switch self {
        case .payloadByteFlipped, .payloadTruncated: "payload"
        case .ticketByteCount: "byte-count"
        case .ticketDigest: "digest"
        case .ticketPreservationStatus: "preservation-status"
        case .ticketSchemaVersion, .manifestSchemaVersion: "schema-identity"
        case .ticketStagingBuild: "build-compatibility"
        }
    }

    /// Whether this leaf changes the payload object rather than the commit record.
    var changesThePayload: Bool {
        switch self {
        case .payloadByteFlipped, .payloadTruncated: true
        default: false
        }
    }

    /// How many times the claim is expected to read the staged payload object.
    ///
    /// A nonoccurrence measured on the production path rather than modelled. Every generated
    /// payload is larger than ``TransferManifestCoding/maximumEncodedByteCount``, so ready-slot
    /// resolution skips it as a manifest candidate and any read of it is the claim's own. One
    /// read for the two leaves that are only detectable from the bytes; none at all for every
    /// leaf the cheap checks or the slot resolution refuse first, because the requirement is
    /// that a mutated handoff is refused *before* its bytes are handled.
    var expectedPayloadReadCount: Int { changesThePayload ? 1 : 0 }

    /// How many objects the app-private session store is expected to be asked to create.
    ///
    /// The recopy is where an accepted ingest would come from, so a leaf refused before it
    /// leaves app-private storage untouched. A flipped byte is only detectable *from* the
    /// recopy's own measurements, so that one leaf creates an object and then has it removed;
    /// the truncation is refused by the length bound before the copy begins.
    var expectedSessionCreateCount: Int { self == .payloadByteFlipped ? 1 : 0 }
}

// MARK: - The reference model

/// What the requirements admit for one single-leaf mutation, written from the record's stated
/// invariants rather than from the claim path.
///
/// The distinction is whether the mutated record still decodes. ``ShareTransferTicket``
/// documents exactly which changes its decoder refuses — an unreadable schema version, a route
/// other than the Share route, an empty payload, and a status its basis does not support — and
/// ``TransferManifest`` documents the envelope version it refuses. A refused record carries no
/// recoverable session identifier, and a session that cannot be named cannot be resumed in
/// order to be terminated.
private enum ReferenceHandoffMutationModel {
    /// Where one mutation must end.
    enum Disposition: String, Hashable, Sendable, CaseIterable {
        /// The record still decodes, so the session it names exists and must end with exactly
        /// `handoff-error` (Requirements 2.19 and 11.13).
        case terminatesPendingSession = "terminates-pending-session"

        /// The record's own validating decoder refuses it, so no session identifier survives
        /// the mutation. The material is removed and nothing is resumed.
        case refusedBeforeASessionCanBeNamed = "refused-before-a-session-can-be-named"
    }

    static func disposition(of mutation: HandoffMutation) -> Disposition {
        switch mutation {
        case .ticketPreservationStatus:
            // A single-field status change leaves a status its basis does not support, which
            // the ticket's decoder refuses by construction.
            .refusedBeforeASessionCanBeNamed
        case .ticketSchemaVersion, .manifestSchemaVersion:
            // Neither decoder reads any version but its own current one.
            .refusedBeforeASessionCanBeNamed
        case .payloadByteFlipped, .payloadTruncated, .ticketByteCount, .ticketDigest,
             .ticketStagingBuild:
            // No stated invariant excludes any of these, so the record still decodes and the
            // session it names has to be resumed in order to be ended.
            .terminatesPendingSession
        }
    }
}

// MARK: - Generated shape

/// One generated mutation case, plus the fixtures derived from it.
///
/// Every field is a bounded integer or a flag, and each derived value is read off the shape by
/// modulus, so a family is exercised across all of its members over 100 cases instead of
/// collapsing onto one.
private struct MutationShape: Sendable, CustomStringConvertible {
    /// Drives the generated byte content, every replacement value, and every synthetic
    /// identifier suffix, so a case's values vary together and a failing case names one seed.
    let seed: Int

    /// Bytes in the published payload.
    ///
    /// Deliberately always **above** ``TransferManifestCoding/maximumEncodedByteCount``. Ready
    /// slot resolution reads every object in the slot that is small enough to be a manifest
    /// candidate, looking for the one that names itself; above that ceiling it skips the
    /// payload, which is what makes "the claim never read the payload" a statement about the
    /// claim rather than about resolution. It stays far below the synthetic budget and store
    /// ceilings, because a size large enough to reach a limit would make the outcome depend on
    /// a resource breach instead.
    let payloadByteCount: Int

    let basisIndex: Int
    let hintIndex: Int
    let chunkIndex: Int
    let flipOffsetIndex: Int
    let truncationIndex: Int
    let byteCountShiftIndex: Int
    let digestPositionIndex: Int
    let statusShiftIndex: Int
    let schemaVersionIndex: Int
    let foreignBuildIndex: Int

    /// Which leaf this case takes through the domain port on a freshly published slot.
    let portArmIndex: Int

    /// A nonzero value to flip a payload byte with, so the flipped byte always differs.
    let flipDelta: Int

    /// Whether the two unmutated controls run before the mutation arms.
    let controlsRunFirst: Bool

    // MARK: The published payload

    /// The bytes every arm in this case publishes.
    ///
    /// Stored rather than computed: ten arms read it many times each, and regenerating the
    /// sequence per access would make the suite's cost the generator's rather than the
    /// handoff's.
    let payloadBytes: [UInt8]

    /// The digest of the published payload, computed in this file rather than read from any
    /// value under test. Stored for the same reason.
    let expectedDigest: DefAIkeDomain.SHA256Digest

    init(
        seed: Int,
        payloadByteCount: Int,
        basisIndex: Int,
        hintIndex: Int,
        chunkIndex: Int,
        flipOffsetIndex: Int,
        truncationIndex: Int,
        byteCountShiftIndex: Int,
        digestPositionIndex: Int,
        statusShiftIndex: Int,
        schemaVersionIndex: Int,
        foreignBuildIndex: Int,
        portArmIndex: Int,
        flipDelta: Int,
        controlsRunFirst: Bool
    ) {
        self.seed = seed
        self.payloadByteCount = payloadByteCount
        self.basisIndex = basisIndex
        self.hintIndex = hintIndex
        self.chunkIndex = chunkIndex
        self.flipOffsetIndex = flipOffsetIndex
        self.truncationIndex = truncationIndex
        self.byteCountShiftIndex = byteCountShiftIndex
        self.digestPositionIndex = digestPositionIndex
        self.statusShiftIndex = statusShiftIndex
        self.schemaVersionIndex = schemaVersionIndex
        self.foreignBuildIndex = foreignBuildIndex
        self.portArmIndex = portArmIndex
        self.flipDelta = flipDelta
        self.controlsRunFirst = controlsRunFirst
        let bytes = Sample.bytes(
            count: payloadByteCount,
            seed: UInt8(truncatingIfNeeded: seed)
        )
        self.payloadBytes = bytes
        self.expectedDigest = StreamingSHA256.digest(of: Data(bytes))
    }

    // MARK: Preservation

    /// The basis the publication records, and therefore the status the ticket carries.
    ///
    /// All four, so all three Byte Preservation Statuses are published and the status mutation
    /// is exercised from each of them. The status is never a parameter: the store derives it
    /// from the basis.
    var basis: PreservationBasis {
        PreservationBasis.allCases[basisIndex % PreservationBasis.allCases.count]
    }

    var publishedStatus: BytePreservationStatus { basis.mostConservativeStatus }

    /// A status the published one is not, for the single-field status splice.
    var replacementStatus: BytePreservationStatus {
        let others = BytePreservationStatus.allCases.filter { $0 != publishedStatus }
        return others[statusShiftIndex % others.count]
    }

    /// The representation form the real coordinator's host offers in the control arm.
    var sharedForm: SharedRepresentationForm {
        SharedRepresentationForm.allCases[basisIndex % SharedRepresentationForm.allCases.count]
    }

    /// The data-protection level every store, object, and policy in this file uses.
    ///
    /// Structural scaffolding, not an approved value, and deliberately not generated. See this
    /// file's header for the environment reason it is held fixed, and
    /// `ProtectedEphemeralFileStoreTests` for where all three levels are pinned.
    static let protectionLevel: FileProtectionLevel = .completeUntilFirstUserAuthentication

    var protectionLevel: FileProtectionLevel { Self.protectionLevel }

    // MARK: Replacement values

    /// I/O buffer size for the staging copy and the claiming recopy.
    var chunkSizeInBytes: Int { Self.chunkSizes[chunkIndex % Self.chunkSizes.count] }

    /// Which payload byte the flip lands on.
    var flipOffset: Int { flipOffsetIndex % payloadByteCount }

    /// The payload with exactly one byte changed and its length left alone.
    var flippedPayload: [UInt8] {
        var bytes = payloadBytes
        // Exclusive-or with a nonzero value, so the byte always changes.
        bytes[flipOffset] ^= UInt8(truncatingIfNeeded: flipDelta)
        return bytes
    }

    /// How many bytes the truncation removes. At least one, and far short of the whole payload.
    var truncatedByteCount: Int { 1 + truncationIndex % 240 }

    /// The payload with its tail removed and its recorded measurements left as written.
    var truncatedPayload: [UInt8] { Array(payloadBytes.prefix(payloadByteCount - truncatedByteCount)) }

    /// A positive byte count the published payload does not have.
    ///
    /// Below the real count, so it stays positive and the ticket's nonempty-payload invariant
    /// still holds: the point of this leaf is a record that decodes and then disagrees.
    var replacementByteCount: UInt64 {
        UInt64(payloadByteCount - (1 + byteCountShiftIndex % 240))
    }

    /// A canonical digest the published payload does not hash to.
    ///
    /// One hexadecimal character of the real digest replaced by a different one, so the
    /// replacement is still exactly 64 lowercase hexadecimal characters and still decodes: this
    /// leaf is about a record that disagrees, not about an unreadable one.
    var replacementDigest: String {
        var characters = Array(expectedDigest.hexadecimalString)
        let position = digestPositionIndex % characters.count
        let digits = Array("0123456789abcdef")
        let current = characters[position]
        let replacement = digits[(digits.firstIndex(of: current).map { $0 + 1 } ?? 1) % digits.count]
        characters[position] = replacement
        return String(characters)
    }

    /// A schema version this build does not read. Never the current one.
    var replacementSchemaVersion: Int {
        Self.foreignSchemaVersions[schemaVersionIndex % Self.foreignSchemaVersions.count]
    }

    /// A build identity the publishing build does not have.
    var replacementBuildID: AppBuildID {
        Sample.buildID("build-p6-foreign-\(foreignBuildIndex % 240)")
    }

    /// The leaf this case takes through the domain port.
    ///
    /// Generated rather than fixed, and the witness requires every leaf to have been taken
    /// through the port across the run, so the port's narrowing is traversed completely without
    /// paying for a second published handoff per leaf per case.
    var portCheckedMutation: HandoffMutation {
        HandoffMutation.allCases[portArmIndex % HandoffMutation.allCases.count]
    }

    // MARK: Derived fixtures

    var contentTypeHint: ContentTypeHint? {
        guard let raw = Self.hints[hintIndex % Self.hints.count] else { return nil }
        return Sample.contentTypeHint(raw)
    }

    /// Exactly one provider offering exactly one item, so a count refusal cannot be mistaken
    /// for a mutation being caught. Counts are Property 4's statement.
    var activation: ShareActivation {
        Sample.activation(
            Sample.sharedProvider(token: 1, itemCount: 1, contentTypeHint: contentTypeHint)
        )
    }

    var sharedOffer: FakeSharedItemAccess.Offer {
        .representation(bytes: payloadBytes, form: sharedForm)
    }

    // MARK: Identifiers

    func mutationSessionID(_ mutation: HandoffMutation) -> AnalysisSessionID {
        Sample.sessionID("session-p6-\(mutation.rawValue)")
    }

    var coordinatorControlSessionID: AnalysisSessionID {
        Sample.sessionID("session-p6-control-coordinator")
    }

    var publicationControlSessionID: AnalysisSessionID {
        Sample.sessionID("session-p6-control-publication")
    }

    var portSessionID: AnalysisSessionID { Sample.sessionID("session-p6-port") }

    /// The build every publication in this case records and every claim presents.
    var stagingBuildID: AppBuildID { Sample.buildID("build-p6-staging-0001") }

    /// A session no arm may ever resume.
    ///
    /// "The session that failed is the session that was pending" needs a value the claim could
    /// have named instead, or the assertion is only that it named something.
    var decoySessionID: AnalysisSessionID { Sample.sessionID("session-p6-decoy") }

    // MARK: Tables

    /// Structural buffer sizes. Test scaffolding, not approved values.
    static let chunkSizes = [64, 512, 1_024, 4_096]

    /// Provider-declared type hints, including none. Recorded, never trusted.
    static let hints: [String?] = [nil, "public.jpeg", "public.png", "public.heic", "public.heif"]

    /// Schema versions this build does not read.
    ///
    /// Zero and a negative value are as unreadable as a later one, and all four are refused by
    /// the same equality against the single current version.
    static let foreignSchemaVersions = [-1, 0, 2, 3]

    var description: String {
        """
        seed \(seed), \(payloadByteCount) payload bytes, basis \(basis.rawValue), \
        published status \(publishedStatus.rawValue), \
        replacement status \(replacementStatus.rawValue), \
        chunk \(chunkSizeInBytes), flip offset \(flipOffset) delta \(flipDelta), \
        truncated by \(truncatedByteCount), replacement count \(replacementByteCount), \
        replacement schema \(replacementSchemaVersion), \
        replacement build \(replacementBuildID.rawValue), \
        hint \(contentTypeHint?.rawValue ?? "none"), \
        port leaf \(portCheckedMutation.rawValue), controls first \(controlsRunFirst)
        """
    }

    // MARK: Generator

    static var generator: Generator<MutationShape, AnySequence<Any>> {
        zip(
            Gen.int(in: 0...9_999),
            // Always above the manifest ceiling; see `payloadByteCount`.
            Gen.int(in: 4_097...4_608),
            index,
            index,
            index,
            index,
            index,
            zip(index, index),
            zip(index, index),
            zip(index, index, Gen.int(in: 1...255), Gen.bool)
        )
        .map { raw in
            MutationShape(
                seed: raw.0,
                payloadByteCount: raw.1,
                basisIndex: raw.2,
                hintIndex: raw.3,
                chunkIndex: raw.4,
                flipOffsetIndex: raw.5,
                truncationIndex: raw.6,
                byteCountShiftIndex: raw.7.0,
                digestPositionIndex: raw.7.1,
                statusShiftIndex: raw.8.0,
                schemaVersionIndex: raw.8.1,
                foreignBuildIndex: raw.9.0,
                portArmIndex: raw.9.1,
                flipDelta: raw.9.2,
                controlsRunFirst: raw.9.3
            )
        }
        .eraseToAny()
    }

    /// A selector index.
    ///
    /// The range is a multiple of every modulus it is reduced by (2, 4, 5, 16, 240), so each
    /// table entry is drawn with equal probability rather than with a modulus bias.
    private static var index: Generator<Int, AnySequence<Any>> {
        Gen.int(in: 0...239).eraseToAny()
    }
}

// MARK: - Scoped splicing of one published record

/// Replaces the value of one member of a published transfer record, leaving every other byte
/// untouched.
///
/// Text splicing rather than a decode-and-re-encode round trip, for the reason the header
/// records: the record carries an exact `Date`, and re-serializing it would perturb a value no
/// arm is about.
///
/// Scoped, because `schemaVersion` appears twice in one record — once for the envelope and once
/// for the ticket inside it — and a global substitution would change two fields at once.
/// Members are located inside the sole `"ticket":{…}` body by brace depth, and the envelope's
/// own members are located strictly outside it.
///
/// Every refusal returns `nil` rather than the unchanged text, so an arm cannot assert against a
/// record it did not actually change.
private enum TicketMemberSplice {
    struct Spliced {
        let text: String
        let previousValue: String
    }

    /// `text` with the ticket's string-valued `member` set to `replacement`.
    static func settingTicketString(
        _ member: String,
        to replacement: String,
        in text: String
    ) -> Spliced? {
        // Written into a JSON string body verbatim, so a replacement needing an escape is
        // refused rather than silently producing a malformed record.
        guard !replacement.contains("\""), !replacement.contains("\\") else { return nil }
        guard let scope = soleTicketBodyRange(in: text) else { return nil }
        return splicingString(member, to: replacement, in: text, within: scope)
    }

    /// `text` with the ticket's number-valued `member` set to `replacement`.
    static func settingTicketNumber(
        _ member: String,
        to replacement: String,
        in text: String
    ) -> Spliced? {
        guard let scope = soleTicketBodyRange(in: text) else { return nil }
        return splicingNumber(member, to: replacement, in: text, within: scope)
    }

    /// `text` with the envelope's number-valued `member` set to `replacement`.
    ///
    /// The scope is everything before the ticket object begins. The encoder sorts keys, so an
    /// envelope member that sorts after `ticket` would not be in that scope and would be
    /// refused here rather than silently spliced inside the ticket.
    static func settingEnvelopeNumber(
        _ member: String,
        to replacement: String,
        in text: String
    ) -> Spliced? {
        guard let opening = text.range(of: ticketNeedle, options: .literal) else { return nil }
        return splicingNumber(
            member,
            to: replacement,
            in: text,
            within: text.startIndex..<opening.lowerBound
        )
    }

    // MARK: Locating

    private static let ticketNeedle = "\"ticket\":{"

    /// The body of the sole `"ticket":{…}` object, brace to matching brace.
    ///
    /// Depth tracking with string skipping is what makes this different from a substring
    /// search: a nested object can repeat a member name, and a string value can contain a
    /// brace.
    private static func soleTicketBodyRange(in text: String) -> Range<String.Index>? {
        guard let opening = text.range(of: ticketNeedle, options: .literal),
            text.range(
                of: ticketNeedle,
                options: .literal,
                range: opening.upperBound..<text.endIndex
            ) == nil
        else { return nil }

        var index = opening.upperBound
        var depth = 1
        while index < text.endIndex {
            switch text[index] {
            case "\"":
                guard let end = closingQuote(
                    in: text,
                    from: text.index(after: index),
                    before: text.endIndex
                ) else { return nil }
                index = text.index(after: end)
                continue
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return opening.upperBound..<index }
            default:
                break
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// The sole occurrence of `needle` inside `scope`, or `nil` when it is absent or repeated.
    private static func soleOccurrence(
        of needle: String,
        in text: String,
        within scope: Range<String.Index>
    ) -> Range<String.Index>? {
        guard let found = text.range(of: needle, options: .literal, range: scope),
            text.range(
                of: needle,
                options: .literal,
                range: found.upperBound..<scope.upperBound
            ) == nil
        else { return nil }
        return found
    }

    private static func splicingString(
        _ member: String,
        to replacement: String,
        in text: String,
        within scope: Range<String.Index>
    ) -> Spliced? {
        guard let found = soleOccurrence(of: "\"\(member)\":\"", in: text, within: scope)
        else { return nil }
        let valueStart = found.upperBound
        guard let valueEnd = closingQuote(in: text, from: valueStart, before: scope.upperBound)
        else { return nil }
        return replacing(valueStart..<valueEnd, with: replacement, in: text)
    }

    private static func splicingNumber(
        _ member: String,
        to replacement: String,
        in text: String,
        within scope: Range<String.Index>
    ) -> Spliced? {
        guard let found = soleOccurrence(of: "\"\(member)\":", in: text, within: scope)
        else { return nil }
        let valueStart = found.upperBound
        // A number ends at the next member or the end of its object. A quote here would mean
        // the member is string-valued, which is a different splice and is refused.
        guard valueStart < scope.upperBound, text[valueStart] != "\"" else { return nil }
        var index = valueStart
        while index < scope.upperBound, text[index] != ",", text[index] != "}" {
            index = text.index(after: index)
        }
        return replacing(valueStart..<index, with: replacement, in: text)
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
        return Spliced(text: mutated, previousValue: previous)
    }

    /// The index of the quote that closes the string body starting at `start`.
    private static func closingQuote(
        in text: String,
        from start: String.Index,
        before limit: String.Index
    ) -> String.Index? {
        var index = start
        while index < limit {
            switch text[index] {
            case "\\":
                index = text.index(after: index)
                guard index < limit else { return nil }
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

// MARK: - The stages a mutated handoff must never reach

/// The three stages Requirements 2.19 and 11.13 forbid a mutated handoff from starting.
///
/// Neither adapter is reachable from this module — the image pipeline and the provenance
/// modules are outside the Share Extension's module closure by design — so this stands for the
/// *handing over* of an accepted ingest to each stage, which is the only part of the ordering
/// this module can observe. The zeros an arm asserts would be vacuous on their own, which is why
/// the control arms drive the same spy through the same routing function on every case.
private enum HandoffDownstreamStage: String, Hashable, Sendable, CaseIterable {
    case inputValidation = "input-validation"
    case provenanceValidation = "provenance-validation"
    case pixelInference = "pixel-inference"
}

/// Counts what an accepted ingest was handed to.
///
/// A locked class rather than an actor, so a count can be read synchronously from the middle of
/// an assertion.
private final class DownstreamStageSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [HandoffDownstreamStage: Int] = [:]
    private var sessions: Set<AnalysisSessionID> = []

    /// Hands `asset` to every stage, exactly as a coordinator would after a verified claim.
    func handOver(_ asset: ImportedEncodedAsset) {
        lock.lock()
        for stage in HandoffDownstreamStage.allCases { calls[stage, default: 0] += 1 }
        sessions.insert(asset.sessionID)
        lock.unlock()
    }

    func callCount(of stage: HandoffDownstreamStage) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return calls[stage] ?? 0
    }

    var totalCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls.values.reduce(0, +)
    }

    var sessionsHandedOver: Set<AnalysisSessionID> {
        lock.lock()
        defer { lock.unlock() }
        return sessions
    }
}

// MARK: - A store that can be mutated and that records what it was asked to do

/// The real protected store, wrapped so one object's bytes can be changed after it was
/// finalized and every read, create, and finalize is observable.
///
/// A wrapper rather than a double: the object on disk, its measurements, its protection level,
/// and its atomic rename are all the real ones. Two capabilities are added, and each exists
/// because the claim path cannot otherwise be reached on a host:
///
///   * **Substitution** is the only way to change a published record at all. The store hashes
///     and measures during the single streaming write, so a coherent slot's bytes always agree
///     with the record beside them, and a test that could not change them could only ever
///     assert that a correct handoff verifies.
///   * **Counting** turns "the payload was never read" and "no session object was created" into
///     assertions. Both are nonoccurrences, so neither can be observed from the result.
///
/// Receipts are deliberately the real ones, never adjusted to match a substitution. That
/// asymmetry is the point: the recorded measurements are what the publishing side wrote, and the
/// bytes are what the claiming side finds.
private final class HandoffMutationProbeStore: EphemeralFileStoring, @unchecked Sendable {
    /// The real store. Held so an arm can reach the members the port does not expose.
    let underlying: ProtectedEphemeralFileStore

    private let lock = NSLock()
    private var substitutions: [EphemeralStorageKey: [UInt8]] = [:]
    private var readCounts: [EphemeralStorageKey: Int] = [:]
    private var createdScopes: [EphemeralStorageScope] = []
    private var finalizedKeys: [EphemeralStorageKey] = []

    init(_ underlying: ProtectedEphemeralFileStore) {
        self.underlying = underlying
    }

    // MARK: Mutation and the ledger

    /// Makes every later read of `key` return `bytes` instead of what is on disk.
    func substitute(_ bytes: [UInt8], for key: EphemeralStorageKey) {
        lock.lock()
        substitutions[key] = bytes
        lock.unlock()
    }

    func readCount(of key: EphemeralStorageKey) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return readCounts[key] ?? 0
    }

    func createCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return createdScopes.count
    }

    func finalizeCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return finalizedKeys.count
    }

    /// Forgets the ledger without touching a byte on disk or dropping a substitution.
    ///
    /// Called between a publication and the claim that follows it, so the claim's counts
    /// describe the claim alone.
    func forgetObservations() {
        lock.lock()
        readCounts = [:]
        createdScopes = []
        finalizedKeys = []
        lock.unlock()
    }

    // MARK: Recording
    //
    // Each recorder is a separate synchronous method: `NSLock` is unavailable from an
    // asynchronous context, and the port members below are `async`.

    private func noteCreate(_ scope: EphemeralStorageScope) {
        lock.lock()
        createdScopes.append(scope)
        lock.unlock()
    }

    private func noteFinalize(_ key: EphemeralStorageKey) {
        lock.lock()
        finalizedKeys.append(key)
        lock.unlock()
    }

    /// Counts the read and returns the substituted bytes, if any.
    private func noteRead(_ key: EphemeralStorageKey) -> [UInt8]? {
        lock.lock()
        defer { lock.unlock() }
        readCounts[key, default: 0] += 1
        return substitutions[key]
    }

    // MARK: EphemeralFileStoring

    func create(
        in scope: EphemeralStorageScope,
        protection: FileProtectionLevel
    ) async throws(EphemeralStoreError) -> EphemeralStorageKey {
        noteCreate(scope)
        return try await underlying.create(in: scope, protection: protection)
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
        noteFinalize(key)
        return try await underlying.finalize(key)
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

// MARK: - One App Group container and the app that claims from it

/// The two roots one handoff spans, and the real surfaces on each side of it.
///
/// Two separate stores, because the whole point of the claim is that the verified bytes end up
/// somewhere the Share Extension cannot reach. Two separate `SharedTransferStore` instances over
/// one shared container, because the extension and the app are two processes: one publishes and
/// the other claims, so the record really does cross a boundary instead of being handed back
/// through memory.
///
/// One container per arm, created and removed by the arm, so no arm's leftover material can
/// satisfy another arm's single-ready-slot or cleanup assertion.
private struct MutationHandoffContainer {
    let root: URL
    let appGroup: HandoffMutationProbeStore
    let session: HandoffMutationProbeStore
    let extensionSide: SharedTransferStore
    let claimAdapter: ShareHandoffClaimAdapter

    init(label: String, shape: MutationShape) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(
                path: "defaike-p6-\(label)-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        self.root = root
        let appGroup = HandoffMutationProbeStore(
            ProtectedEphemeralFileStore(
                configuration: .test(
                    root: root.appending(path: "appgroup", directoryHint: .isDirectory),
                    containerProtection: shape.protectionLevel
                ),
                protection: PlatformDataProtection(),
                clock: FixedClock(fixtureNow)
            )
        )
        let session = HandoffMutationProbeStore(
            ProtectedEphemeralFileStore(
                configuration: .test(
                    root: root.appending(path: "private", directoryHint: .isDirectory),
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
            buildID: shape.stagingBuildID,
            chunkSizeInBytes: shape.chunkSizeInBytes
        )
        self.claimAdapter = ShareHandoffClaimAdapter(
            transfers: SharedTransferStore.test(
                over: appGroup,
                extensionPolicy: policy,
                buildID: shape.stagingBuildID,
                chunkSizeInBytes: shape.chunkSizeInBytes
            ),
            sessionStore: session,
            sessionFileProtection: shape.protectionLevel,
            chunkSizeInBytes: shape.chunkSizeInBytes
        )
    }

    /// Removes everything this arm owned. Tolerant of a root that was never created.
    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Transfer scopes the shared container still owns, in any state.
    func survivingTransferScopes() async -> Set<EphemeralStorageScope> {
        await appGroup.underlying.occupiedScopes().filter {
            if case .transfer = $0 { return true }
            return false
        }
    }

    /// Session scopes the app-private store still owns.
    func survivingSessionScopes() async -> Set<EphemeralStorageScope> {
        await session.underlying.occupiedScopes().filter {
            if case .session = $0 { return true }
            return false
        }
    }
}

// MARK: - The scenario

/// One generated case, run against the real publication, record coding, and claim surfaces.
private struct MutationScenario {
    let shape: MutationShape
    let witness: MutationVariationWitness

    // MARK: - Every mutation

    /// Every single-leaf mutation of a committed handoff fails closed
    /// (Requirements 2.19 and 11.13).
    func checkEveryMutationFailsClosed() async {
        for mutation in HandoffMutation.allCases {
            await checkOneMutationFailsClosed(mutation)
        }
    }

    private func checkOneMutationFailsClosed(_ mutation: HandoffMutation) async {
        let container = MutationHandoffContainer(label: mutation.rawValue, shape: shape)
        defer { container.remove() }
        let spy = DownstreamStageSpy()

        guard let published = await publish(
            into: container,
            sessionID: shape.mutationSessionID(mutation)
        ) else { return }
        guard let record = await locateRecord(of: published.ticket, in: container) else { return }

        // The untouched control: the record as published still decodes, and it still describes
        // the ticket the publication returned. A splice is only meaningful against that.
        switch TransferManifestCoding.decode(orNil: record.bytes) {
        case .some(let decoded):
            #expect(decoded.ticket == published.ticket)
            #expect(decoded.payloadKey == published.payloadKey)
            #expect(decoded.manifestKey == record.key)
            witness.recordUntouchedRoundTrip()
        case .none:
            reportUnbuildableInput("\(mutation.rawValue): the published record must decode")
            return
        }

        guard await apply(mutation, to: record, payloadKey: published.payloadKey, in: container)
        else { return }

        // Counts from here on describe the claim alone.
        container.appGroup.forgetObservations()
        container.session.forgetObservations()

        let outcome = await container.claimAdapter.attemptClaim(
            claimingBuildID: shape.stagingBuildID
        )

        await checkTheOutcomeIsFailClosed(
            outcome,
            mutation: mutation,
            published: published,
            record: record,
            in: container,
            spy: spy
        )
        witness.recordMutationArm(mutation)
    }

    /// Everything one mutated claim must and must not have done.
    private func checkTheOutcomeIsFailClosed(
        _ outcome: ShareClaimOutcome,
        mutation: HandoffMutation,
        published: PublishedHandoff,
        record: LocatedRecord,
        in container: MutationHandoffContainer,
        spy: DownstreamStageSpy
    ) async {
        let disposition = ReferenceHandoffMutationModel.disposition(of: mutation)

        // No accepted ingest, ever. This is the conjunct everything else hangs off: with no
        // asset there is nothing any stage could be handed.
        #expect(
            outcome.verifiedHandoff == nil,
            "\(mutation.rawValue) produced an accepted ingest"
        )

        switch disposition {
        case .terminatesPendingSession:
            if let failed = outcome.failedHandoff {
                // Exactly the session the commit created, resumed only in order to end.
                #expect(failed.sessionID == published.ticket.sessionID)
                #expect(failed.sessionID != shape.decoySessionID)
                #expect(failed.transferID == published.ticket.transferID)
                #expect(
                    failed.failure == expectedFailure(of: mutation, published: published),
                    "\(mutation.rawValue) failed as \(failed.failure)"
                )
                checkTheFaultIsExactlyHandoffError(failed.fault, mutation: mutation)
                witness.recordTerminatedSession(mutation)
            } else {
                Issue.record(
                    """
                    \(mutation.rawValue) leaves a readable commit record, so the session it \
                    names must be resumed and ended; the claim reported \(outcome)
                    """
                )
            }

        case .refusedBeforeASessionCanBeNamed:
            // The record's own decoder refused it, so no session identifier survived and
            // nothing can be resumed. Asserted at full fidelity rather than as "not verified".
            #expect(
                outcome == .discarded(
                    .defective(
                        DefectiveTransfer(
                            transferID: published.ticket.transferID,
                            pendingSession: nil,
                            defect: .manifestMissing
                        )
                    )
                ),
                "\(mutation.rawValue) was refused as \(outcome)"
            )
            #expect(
                outcome.failedHandoff == nil,
                "\(mutation.rawValue) named a session no readable record could have named"
            )
            witness.recordRefusedRecord(mutation)
        }

        // The nonoccurrences, two of them measured on the production path.
        #expect(
            container.appGroup.readCount(of: published.payloadKey)
                == mutation.expectedPayloadReadCount,
            """
            \(mutation.rawValue) read the staged payload \
            \(container.appGroup.readCount(of: published.payloadKey)) time(s), expected \
            \(mutation.expectedPayloadReadCount)
            """
        )
        #expect(
            container.session.createCount() == mutation.expectedSessionCreateCount,
            """
            \(mutation.rawValue) created \(container.session.createCount()) app-private \
            object(s), expected \(mutation.expectedSessionCreateCount)
            """
        )
        // The commit record was read on this side; the exact number of resolution passes is a
        // strategy detail rather than a requirement.
        #expect(
            container.appGroup.readCount(of: record.key) >= 1,
            "\(mutation.rawValue) never read the commit record it was refusing"
        )

        // Nothing was handed to any stage. The routing is the same function the controls drive,
        // so these zeros are a consequence of the claim's own result rather than of this arm
        // never calling the spy: a claim that produced an ingest would route it here and fail.
        routeIfAccepted(outcome, to: spy)
        for stage in HandoffDownstreamStage.allCases {
            #expect(
                spy.callCount(of: stage) == 0,
                "\(mutation.rawValue) started \(stage.rawValue)"
            )
        }
        #expect(spy.sessionsHandedOver.isEmpty)

        await checkNothingSurvives(mutation.rawValue, in: container)
        witness.recordNonoccurrenceChecked()
    }

    /// Hands an accepted ingest to every downstream stage, and hands nothing to any of them when
    /// the claim produced none.
    ///
    /// The single routing function both the mutation arms and the controls go through. That is
    /// what makes the arms' zeros a measurement: a claim that produced an ingest would route it
    /// here, and the same call on the control's verified handoff is what shows the stages do
    /// record when something is handed to them.
    private func routeIfAccepted(_ outcome: ShareClaimOutcome, to spy: DownstreamStageSpy) {
        guard let verified = outcome.verifiedHandoff else { return }
        spy.handOver(verified.asset)
    }

    /// The fault is the single exact value the requirements name, and no other.
    private func checkTheFaultIsExactlyHandoffError(
        _ fault: AnalysisFault,
        mutation: HandoffMutation
    ) {
        #expect(
            fault == .analysis(.handoffError, stage: .handoffVerification),
            "\(mutation.rawValue) surfaced \(fault)"
        )
        // Spelled out against the closed vocabulary as well, so a mutation cannot acquire
        // another category or a cancellation on the way out (Requirement 11.17).
        #expect(fault.analysisError == .handoffError)
        #expect(fault.stage == .handoffVerification)
        #expect(!fault.isCancelled)
        for other in AnalysisError.allCases where other != .handoffError {
            #expect(
                fault.analysisError != other,
                "\(mutation.rawValue) surfaced \(other.rawValue)"
            )
        }
        witness.recordExactHandoffError()
    }

    /// Through the domain port, one generated leaf per case is either exactly `handoff-error` or
    /// nothing at all — never an accepted ingest.
    ///
    /// A dedicated container and a freshly published handoff, because the port has to be the
    /// *first* thing to claim the slot for its result to mean anything: asking it about a slot
    /// another attempt already consumed could only ever produce "nothing pending". Which leaf it
    /// is is generated, and the witness requires every leaf to have been checked here across the
    /// run, so this is a full traversal spread over cases rather than a sample of one.
    func checkThePortNarrowsOneLeafToExactlyHandoffError() async {
        let mutation = shape.portCheckedMutation
        let container = MutationHandoffContainer(label: "port-\(mutation.rawValue)", shape: shape)
        defer { container.remove() }

        guard let published = await publish(
            into: container,
            sessionID: shape.portSessionID
        ) else { return }
        guard let record = await locateRecord(of: published.ticket, in: container) else { return }
        guard await apply(mutation, to: record, payloadKey: published.payloadKey, in: container)
        else { return }

        let disposition = ReferenceHandoffMutationModel.disposition(of: mutation)
        do {
            let claimed = try await container.claimAdapter.claimReadyTransfer(
                claimingBuildID: shape.stagingBuildID
            )
            #expect(
                claimed == nil,
                "\(mutation.rawValue) yielded an accepted ingest through the port"
            )
            #expect(
                disposition == .refusedBeforeASessionCanBeNamed,
                """
                \(mutation.rawValue) leaves a readable commit record, so the port must throw \
                rather than report nothing pending
                """
            )
        } catch {
            checkTheFaultIsExactlyHandoffError(error, mutation: mutation)
            #expect(
                disposition == .terminatesPendingSession,
                """
                \(mutation.rawValue) leaves no readable commit record, so no session could \
                have been named to throw for
                """
            )
        }
        await checkNothingSurvives("port \(mutation.rawValue)", in: container)
        witness.recordPortChecked(mutation)
    }

    /// The failed transfer is gone from every namespace, asserted against store state.
    private func checkNothingSurvives(
        _ label: String,
        in container: MutationHandoffContainer
    ) async {
        #expect(
            await container.survivingTransferScopes().isEmpty,
            "\(label) left transfer material in the shared container"
        )
        #expect(
            await container.survivingSessionScopes().isEmpty,
            "\(label) left session material in app-private storage"
        )
        if let slot = await readySlot(of: container) {
            #expect(slot == ReadySlotState.empty, "\(label) left a pending handoff behind")
        }
        #expect(
            await usedByteCount(of: container.appGroup) == 0,
            "\(label) left bytes in the shared container"
        )
        #expect(
            await usedByteCount(of: container.session) == 0,
            "\(label) left bytes in app-private storage"
        )
        witness.recordCleanupChecked()
    }

    // MARK: - The controls

    /// An unmutated publication still verifies, and a verified ingest does reach every stage
    /// (the positive control for every zero asserted above).
    func checkAnUnmutatedPublicationStillVerifies() async {
        let container = MutationHandoffContainer(label: "control", shape: shape)
        defer { container.remove() }
        let spy = DownstreamStageSpy()

        guard let published = await publish(
            into: container,
            sessionID: shape.publicationControlSessionID
        ) else { return }
        container.appGroup.forgetObservations()
        container.session.forgetObservations()

        let outcome = await container.claimAdapter.attemptClaim(
            claimingBuildID: shape.stagingBuildID
        )
        guard let verified = outcome.verifiedHandoff else {
            reportUnbuildableInput("an unmutated publication must verify: \(outcome)")
            return
        }
        #expect(outcome.failedHandoff == nil)
        #expect(verified.sessionID == shape.publicationControlSessionID)
        #expect(verified.transferID == published.ticket.transferID)
        // Every field the property mutates elsewhere is the field the session carries here.
        #expect(verified.asset.byteCount == UInt64(shape.payloadByteCount))
        #expect(verified.asset.sha256 == shape.expectedDigest)
        #expect(verified.asset.preservationStatus == shape.publishedStatus)
        #expect(verified.asset.preservationBasis == shape.basis)
        #expect(verified.asset.route == .shareExtension)

        // The same routing function every mutation arm asserts to be idle, driven once.
        routeIfAccepted(outcome, to: spy)
        for stage in HandoffDownstreamStage.allCases {
            #expect(
                spy.callCount(of: stage) == 1,
                "the control drove \(stage.rawValue) \(spy.callCount(of: stage)) time(s)"
            )
        }
        #expect(spy.totalCalls == HandoffDownstreamStage.allCases.count)
        #expect(spy.sessionsHandedOver == [shape.publicationControlSessionID])

        // The payload really was read and recopied on this side, which is the same measurement
        // the refusal arms assert to be zero.
        #expect(container.appGroup.readCount(of: published.payloadKey) == 1)
        #expect(container.session.createCount() == 1)
        #expect(container.session.finalizeCount() == 1)

        // The shared container keeps nothing; the session owns exactly the verified bytes.
        #expect(await container.survivingTransferScopes().isEmpty)
        #expect(await usedByteCount(of: container.appGroup) == 0)
        #expect(
            await container.session.keys(in: .session(verified.sessionID))
                == [verified.asset.handle.storageKey]
        )
        if let bytes = await read(verified.asset.handle.storageKey, from: container.session) {
            #expect(bytes == shape.payloadBytes)
        }
        witness.recordPublicationControl()
    }

    /// The real Share Extension ingest coordinator's own consented handoff still verifies.
    ///
    /// The mutation arms publish through ``SharedTransferStore/publishTransfer(ofFileAt:consent:sessionID:basis:)``
    /// — the same commit the coordinator performs — because its `basis` parameter is the only
    /// place the two statuses a sharing application cannot establish can come from, and the
    /// status family has to be mutated from all three published statuses. This arm keeps the
    /// coordinator's own consent step, staged protection level, and atomic promotion in the
    /// property rather than only in its example tests.
    func checkTheRealCoordinatorsUnmutatedHandoffStillVerifies() async {
        let container = MutationHandoffContainer(label: "coordinator", shape: shape)
        defer { container.remove() }
        let spy = DownstreamStageSpy()
        let access = FakeSharedItemAccess(shape.sharedOffer)

        guard let coordinator = ShareExtensionIngestCoordinator(
            access: access,
            consentPresenter: ScriptedConsentPresenter.confirming(),
            transfers: container.extensionSide,
            governor: ProgrammedShareResourceGovernor(),
            budget: Sample.shareBudget(),
            instruction: Sample.manualInstruction(),
            candidateSessions: FixedCandidateSessionIdentifierSource(
                shape.coordinatorControlSessionID
            )
        ) else {
            reportUnbuildableInput("the Share ingest coordinator fixture must be constructible")
            return
        }

        let handoff = await coordinator.handleActivation(shape.activation)
        guard let ticket = handoff.publishedTicket else {
            reportUnbuildableInput(
                "a consented one-item activation must publish one transfer: \(handoff)"
            )
            return
        }
        #expect(ticket.sessionID == shape.coordinatorControlSessionID)
        #expect(ticket.byteCount == UInt64(shape.payloadByteCount))
        #expect(ticket.sha256 == shape.expectedDigest)
        #expect(ticket.extensionBuildID == shape.stagingBuildID)

        let outcome = await container.claimAdapter.attemptClaim(
            claimingBuildID: shape.stagingBuildID
        )
        guard let verified = outcome.verifiedHandoff else {
            reportUnbuildableInput("the coordinator's own handoff must verify: \(outcome)")
            return
        }
        #expect(verified.sessionID == shape.coordinatorControlSessionID)
        #expect(verified.asset.sha256 == shape.expectedDigest)
        #expect(verified.asset.preservationStatus == shape.sharedForm.preservationBasis.mostConservativeStatus)

        routeIfAccepted(outcome, to: spy)
        #expect(spy.totalCalls == HandoffDownstreamStage.allCases.count)
        #expect(spy.sessionsHandedOver == [shape.coordinatorControlSessionID])
        #expect(await container.survivingTransferScopes().isEmpty)
        await access.cleanUp()
        witness.recordCoordinatorControl()
    }

    // MARK: - Publication, location, and mutation

    /// One committed handoff and the object holding its bytes.
    struct PublishedHandoff {
        let ticket: ShareTransferTicket
        let payloadKey: EphemeralStorageKey
    }

    /// The commit record inside the ready slot, and the bytes it was published as.
    struct LocatedRecord {
        let key: EphemeralStorageKey
        let bytes: [UInt8]
        let text: String
    }

    /// Publishes one transfer through the real store commit.
    private func publish(
        into container: MutationHandoffContainer,
        sessionID: AnalysisSessionID
    ) async -> PublishedHandoff? {
        guard let source = try? makeProviderFile(shape.payloadBytes) else {
            reportUnbuildableInput("a provider representation fixture must be writable")
            return nil
        }
        defer { removeProviderFile(source) }

        let ticket: ShareTransferTicket
        do {
            ticket = try await container.extensionSide.publishTransfer(
                ofFileAt: source,
                consent: Sample.consent(contentTypeHint: shape.contentTypeHint),
                sessionID: sessionID,
                basis: shape.basis
            )
        } catch {
            reportUnbuildableInput("a nonempty representation must be publishable: \(error)")
            return nil
        }

        // The commit really happened, so a later refusal is a refusal of a published handoff
        // rather than of nothing.
        guard let slot = await readySlot(of: container),
            let ready = slot.publishedTransfer,
            ready.ticket == ticket
        else {
            reportUnbuildableInput("a returned ticket must leave one pending handoff")
            return nil
        }
        #expect(ticket.sessionID == sessionID)
        #expect(ticket.preservationStatus == shape.publishedStatus)
        #expect(ticket.preservationBasis == shape.basis)
        witness.recordPublishedCommit(status: ticket.preservationStatus, basis: ticket.preservationBasis)
        return PublishedHandoff(ticket: ticket, payloadKey: ready.storageKey)
    }

    /// Finds the commit record in the ready slot the way the store does: the sole object that
    /// decodes as a record naming itself.
    ///
    /// Objects too large to be a record are skipped without being read, exactly as resolution
    /// skips them, so locating the record never reads the payload and never disturbs the
    /// nonoccurrence this file asserts. A record that is not uniquely locatable is a refusal
    /// rather than a guess.
    private func locateRecord(
        of ticket: ShareTransferTicket,
        in container: MutationHandoffContainer
    ) async -> LocatedRecord? {
        let scope = EphemeralStorageScope.transfer(ticket.transferID, .ready)
        var located: [LocatedRecord] = []
        for key in await container.appGroup.keys(in: scope).sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let receipt = await container.appGroup.receipt(for: key),
                receipt.byteCount <= TransferManifestCoding.maximumEncodedByteCount
            else { continue }
            guard let bytes = await read(key, from: container.appGroup) else { continue }
            guard let decoded = TransferManifestCoding.decode(orNil: bytes),
                decoded.manifestKey == key
            else { continue }
            located.append(
                LocatedRecord(key: key, bytes: bytes, text: String(decoding: bytes, as: UTF8.self))
            )
        }
        guard located.count == 1, let record = located.first else {
            reportUnbuildableInput(
                "exactly one commit record must be locatable; found \(located.count)"
            )
            return nil
        }
        return record
    }

    /// Applies one single-leaf mutation, or reports that it could not be applied.
    ///
    /// Returns `false` without mutating anything when the leaf could not be located or when the
    /// replacement would have left the record unchanged, so an arm never asserts a refusal
    /// against material it did not actually change.
    private func apply(
        _ mutation: HandoffMutation,
        to record: LocatedRecord,
        payloadKey: EphemeralStorageKey,
        in container: MutationHandoffContainer
    ) async -> Bool {
        switch mutation {
        case .payloadByteFlipped:
            let mutated = shape.flippedPayload
            // Exactly one position differs, and the length is untouched, so only a recomputed
            // digest can catch it.
            guard mutated.count == shape.payloadByteCount,
                zip(mutated, shape.payloadBytes).filter(!=).count == 1
            else {
                reportUnbuildableInput("a byte flip must change exactly one byte")
                return false
            }
            container.appGroup.substitute(mutated, for: payloadKey)
            witness.recordMutationApplied(mutation)
            return true

        case .payloadTruncated:
            let mutated = shape.truncatedPayload
            guard !mutated.isEmpty, mutated.count < shape.payloadByteCount else {
                reportUnbuildableInput("a truncation must shorten a nonempty payload")
                return false
            }
            container.appGroup.substitute(mutated, for: payloadKey)
            witness.recordMutationApplied(mutation)
            return true

        case .ticketByteCount:
            let replacement = shape.replacementByteCount
            guard replacement > 0, replacement != record.decodedByteCountOrZero else {
                reportUnbuildableInput("a byte-count splice must name another positive count")
                return false
            }
            return substitute(
                TicketMemberSplice.settingTicketNumber(
                    "byteCount",
                    to: String(replacement),
                    in: record.text
                ),
                for: mutation,
                over: record,
                in: container
            )

        case .ticketDigest:
            return substitute(
                TicketMemberSplice.settingTicketString(
                    "sha256",
                    to: shape.replacementDigest,
                    in: record.text
                ),
                for: mutation,
                over: record,
                in: container
            )

        case .ticketPreservationStatus:
            return substitute(
                TicketMemberSplice.settingTicketString(
                    "preservationStatus",
                    to: shape.replacementStatus.rawValue,
                    in: record.text
                ),
                for: mutation,
                over: record,
                in: container
            )

        case .ticketSchemaVersion:
            return substitute(
                TicketMemberSplice.settingTicketNumber(
                    "schemaVersion",
                    to: String(shape.replacementSchemaVersion),
                    in: record.text
                ),
                for: mutation,
                over: record,
                in: container
            )

        case .manifestSchemaVersion:
            return substitute(
                TicketMemberSplice.settingEnvelopeNumber(
                    "schemaVersion",
                    to: String(shape.replacementSchemaVersion),
                    in: record.text
                ),
                for: mutation,
                over: record,
                in: container
            )

        case .ticketStagingBuild:
            guard shape.replacementBuildID != shape.stagingBuildID else {
                reportUnbuildableInput("a build splice must name another build")
                return false
            }
            return substitute(
                TicketMemberSplice.settingTicketString(
                    "extensionBuildID",
                    to: shape.replacementBuildID.rawValue,
                    in: record.text
                ),
                for: mutation,
                over: record,
                in: container
            )
        }
    }

    /// Installs a spliced record, after checking that the splice actually changed it.
    private func substitute(
        _ spliced: TicketMemberSplice.Spliced?,
        for mutation: HandoffMutation,
        over record: LocatedRecord,
        in container: MutationHandoffContainer
    ) -> Bool {
        guard let spliced else {
            reportUnbuildableInput(
                "\(mutation.rawValue): the member must be uniquely locatable and changed"
            )
            return false
        }
        let mutated = Array(spliced.text.utf8)
        // Both halves matter: the splice reported replacing something different, and the bytes
        // that will be read really are not the bytes that were published.
        #expect(spliced.text != record.text, "\(mutation.rawValue) changed nothing")
        #expect(mutated != record.bytes, "\(mutation.rawValue) produced the published bytes")
        // And it replaced a value that was actually there. None of the members spliced here —
        // a digest, a status word, a build identity, or a number — is ever the empty string, so
        // an empty previous value would mean the splice landed on a position rather than on a
        // member and the arm would be asserting a refusal of something it did not locate.
        #expect(
            !spliced.previousValue.isEmpty,
            "\(mutation.rawValue) reported replacing nothing"
        )
        container.appGroup.substitute(mutated, for: record.key)
        witness.recordMutationApplied(mutation)
        return true
    }

    /// The exact failure a mutation that leaves a readable record must produce.
    ///
    /// Named per leaf rather than left as "some mismatch", so a leaf that started being caught
    /// somewhere else fails here instead of passing.
    private func expectedFailure(
        of mutation: HandoffMutation,
        published: PublishedHandoff
    ) -> ShareClaimFailure {
        switch mutation {
        case .payloadByteFlipped:
            // Same length, different bytes: only the digest recomputed over the recopy differs.
            return .mismatch(.digest)
        case .payloadTruncated:
            // The object's recorded length still matches the ticket, so the disagreement is
            // between the record and what the read actually returned.
            return .mismatch(.byteCount)
        case .ticketByteCount, .ticketDigest:
            // The record still decodes, and the measurements taken during the publishing write
            // no longer describe it, so the slot never resolves into a resumable transfer.
            return .slotNotResumable(
                .defective(
                    DefectiveTransfer(
                        transferID: published.ticket.transferID,
                        pendingSession: published.ticket.sessionID,
                        defect: .measurementMismatch
                    )
                )
            )
        case .ticketStagingBuild:
            return .mismatch(.stagingBuildIdentity)
        case .ticketPreservationStatus, .ticketSchemaVersion, .manifestSchemaVersion:
            // Unreachable: the reference model classifies these as refused before a session can
            // be named, and the caller only asks for a failure in the other disposition.
            return .mismatch(.preservationStatus)
        }
    }

    // MARK: - Nonthrowing store calls

    private func read(
        _ key: EphemeralStorageKey,
        from store: HandoffMutationProbeStore
    ) async -> [UInt8]? {
        do {
            return try await store.read(key)
        } catch {
            Issue.record("a finalized object must be readable: \(error)")
            return nil
        }
    }

    private func readySlot(of container: MutationHandoffContainer) async -> ReadySlotState? {
        do {
            return try await container.extensionSide.readySlotState()
        } catch {
            Issue.record("the ready slot must be readable: \(error)")
            return nil
        }
    }

    private func usedByteCount(of store: HandoffMutationProbeStore) async -> UInt64? {
        do {
            return try await store.underlying.usedByteCount()
        } catch {
            Issue.record("a store must be able to measure what it holds: \(error)")
            return nil
        }
    }

    private func reportUnbuildableInput(
        _ message: Comment,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        witness.recordUnbuildableInput()
        Issue.record(message, sourceLocation: sourceLocation)
    }
}

// MARK: - Nonthrowing record coding

extension TransferManifestCoding {
    /// The decoded record, or `nil`.
    ///
    /// The real bounded decoder; only its typed error is turned into an absence, so a call can
    /// sit inside a property body without an escaping error reporting a passing run.
    fileprivate static func decode(orNil bytes: [UInt8]) -> TransferManifest? {
        try? decode(bytes)
    }
}

extension MutationScenario.LocatedRecord {
    /// The byte count the record as published carries, or zero when it does not decode.
    ///
    /// Used only to check that a replacement byte count really is a different number.
    fileprivate var decodedByteCountOrZero: UInt64 {
        TransferManifestCoding.decode(orNil: bytes)?.ticket.byteCount ?? 0
    }
}

// MARK: - The variation witness

/// Counts what the run generated and what it produced, outside the property body.
///
/// `propertyCheck` runs its body under `try?`, so a body that failed before its first assertion
/// reports a passing test in milliseconds with every arm skipped. Two habits close that gap,
/// and both matter:
///
///   * every arm counter is compared against the **case count** rather than against a floor, so
///     a run in which an arm stopped being reached fails even if the absolute number still looks
///     large; and
///   * ``recordCompletedBody()`` is the last thing the body does, so a case that ended early is
///     countable. `completedBodies == cases` alone would pass vacuously as `0 == 0`, which is
///     why the case floor sits beside it.
///
/// The produced sets are the substantive half: every mutation leaf must have been *applied* and
/// *judged*, both dispositions must have occurred, every published status and basis must have
/// been mutated from, and both controls must have run — which is what turns "mutation fails
/// closed" from a claim about unreached branches into a claim about produced outcomes.
private final class MutationVariationWitness: @unchecked Sendable {
    private let lock = NSLock()

    // Arm counters.
    private var cases = 0
    private var completedBodies = 0
    private var publishedCommits = 0
    private var untouchedRoundTrips = 0
    private var mutationsApplied = 0
    private var mutationArms = 0
    private var exactHandoffErrors = 0
    private var portChecks = 0

    /// Cases whose generated port leaf is one that leaves a readable record, and therefore one
    /// the port must throw for. Counted from the shape rather than from the outcome, so the
    /// expected number of exact-fault assertions stays exact.
    private var portTerminatingSelections = 0

    private var nonoccurrenceChecks = 0
    private var cleanupChecks = 0
    private var publicationControls = 0
    private var coordinatorControls = 0
    private var unbuildableInputs = 0

    // Produced outcomes.
    private var appliedLeaves: Set<HandoffMutation> = []
    private var judgedLeaves: Set<HandoffMutation> = []
    private var families: Set<String> = []
    private var terminatedLeaves: Set<HandoffMutation> = []
    private var refusedLeaves: Set<HandoffMutation> = []
    private var portCheckedLeaves: Set<HandoffMutation> = []
    private var dispositionsObserved: Set<ReferenceHandoffMutationModel.Disposition> = []
    private var publishedStatuses: Set<BytePreservationStatus> = []
    private var publishedBases: Set<PreservationBasis> = []

    // Generated baseline.
    private var seeds: Set<Int> = []
    private var payloadByteCounts: Set<Int> = []
    private var bases: Set<PreservationBasis> = []
    private var replacementStatuses: Set<BytePreservationStatus> = []
    private var chunkSizes: Set<Int> = []
    private var hintKeys: Set<String> = []
    private var replacementSchemaVersions: Set<Int> = []
    private var replacementBuildIDs: Set<String> = []
    private var flipOffsets: Set<Int> = []
    private var truncationLengths: Set<Int> = []
    private var portLeafSelections: Set<HandoffMutation> = []
    private var controlOrders: Set<Bool> = []

    func record(_ shape: MutationShape) {
        lock.lock()
        defer { lock.unlock() }
        cases += 1
        seeds.insert(shape.seed)
        payloadByteCounts.insert(shape.payloadByteCount)
        bases.insert(shape.basis)
        replacementStatuses.insert(shape.replacementStatus)
        chunkSizes.insert(shape.chunkSizeInBytes)
        hintKeys.insert(shape.contentTypeHint?.rawValue ?? "none")
        replacementSchemaVersions.insert(shape.replacementSchemaVersion)
        replacementBuildIDs.insert(shape.replacementBuildID.rawValue)
        flipOffsets.insert(shape.flipOffset)
        truncationLengths.insert(shape.truncatedByteCount)
        portLeafSelections.insert(shape.portCheckedMutation)
        if ReferenceHandoffMutationModel.disposition(of: shape.portCheckedMutation)
            == .terminatesPendingSession
        {
            portTerminatingSelections += 1
        }
        controlOrders.insert(shape.controlsRunFirst)
    }

    func recordPublishedCommit(status: BytePreservationStatus, basis: PreservationBasis) {
        lock.lock()
        publishedCommits += 1
        publishedStatuses.insert(status)
        publishedBases.insert(basis)
        lock.unlock()
    }

    func recordUntouchedRoundTrip() {
        lock.lock()
        untouchedRoundTrips += 1
        lock.unlock()
    }

    func recordMutationApplied(_ mutation: HandoffMutation) {
        lock.lock()
        mutationsApplied += 1
        appliedLeaves.insert(mutation)
        lock.unlock()
    }

    func recordMutationArm(_ mutation: HandoffMutation) {
        lock.lock()
        mutationArms += 1
        judgedLeaves.insert(mutation)
        families.insert(mutation.family)
        lock.unlock()
    }

    func recordTerminatedSession(_ mutation: HandoffMutation) {
        lock.lock()
        terminatedLeaves.insert(mutation)
        dispositionsObserved.insert(.terminatesPendingSession)
        lock.unlock()
    }

    func recordRefusedRecord(_ mutation: HandoffMutation) {
        lock.lock()
        refusedLeaves.insert(mutation)
        dispositionsObserved.insert(.refusedBeforeASessionCanBeNamed)
        lock.unlock()
    }

    func recordExactHandoffError() {
        lock.lock()
        exactHandoffErrors += 1
        lock.unlock()
    }

    func recordPortChecked(_ mutation: HandoffMutation) {
        lock.lock()
        portChecks += 1
        portCheckedLeaves.insert(mutation)
        lock.unlock()
    }

    func recordNonoccurrenceChecked() {
        lock.lock()
        nonoccurrenceChecks += 1
        lock.unlock()
    }

    func recordCleanupChecked() {
        lock.lock()
        cleanupChecks += 1
        lock.unlock()
    }

    func recordPublicationControl() {
        lock.lock()
        publicationControls += 1
        lock.unlock()
    }

    func recordCoordinatorControl() {
        lock.lock()
        coordinatorControls += 1
        lock.unlock()
    }

    /// Records that a fixture this file described could not be built.
    ///
    /// Never a finding about mutation: every input here is built from generated integers inside
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

        let leafCount = HandoffMutation.allCases.count
        #expect(cases >= 100, "the design requires at least 100 generated cases; ran \(cases)")
        #expect(
            completedBodies == cases,
            "\(cases - completedBodies) of \(cases) cases did not reach the end of the body"
        )
        #expect(
            unbuildableInputs == 0,
            "\(unbuildableInputs) described inputs could not be built at all"
        )

        // Every arm ran on every case, compared against the case count rather than a floor.
        // One publication per mutation leaf plus one for each control.
        // One publication per mutation leaf, one for the publication control, and one for the
        // port arm. The coordinator control publishes through the coordinator instead, so it is
        // counted by its own arm rather than here.
        #expect(publishedCommits == cases * (leafCount + 2), "publications: \(publishedCommits)")
        #expect(
            untouchedRoundTrips == cases * leafCount,
            "untouched round-trip controls: \(untouchedRoundTrips)"
        )
        // One mutation per leaf, plus the one the port arm applies to its own fresh slot.
        #expect(
            mutationsApplied == cases * (leafCount + 1),
            "mutations applied: \(mutationsApplied)"
        )
        #expect(mutationArms == cases * leafCount, "mutation arms judged: \(mutationArms)")
        #expect(
            nonoccurrenceChecks == cases * leafCount,
            "nonoccurrence checks: \(nonoccurrenceChecks)"
        )
        // One per mutation arm, plus one for the port arm's own container.
        #expect(
            cleanupChecks == cases * (leafCount + 1),
            "cleanup checks: \(cleanupChecks)"
        )
        #expect(portChecks == cases, "port checks: \(portChecks)")
        #expect(publicationControls == cases, "publication controls: \(publicationControls)")
        #expect(coordinatorControls == cases, "coordinator controls: \(coordinatorControls)")
        // One exact-fault assertion per leaf whose record still decodes, plus one for every case
        // whose generated port leaf was such a leaf. Both terms come from the closed leaf set and
        // from the generated shape, so the total is exact rather than a floor.
        let terminatingLeaves = HandoffMutation.allCases.filter {
            ReferenceHandoffMutationModel.disposition(of: $0) == .terminatesPendingSession
        }
        #expect(
            exactHandoffErrors
                == cases * terminatingLeaves.count + portTerminatingSelections,
            "exact handoff-error assertions: \(exactHandoffErrors)"
        )

        // The substantive half: the outcomes were produced, not merely offered.
        #expect(
            appliedLeaves == Set(HandoffMutation.allCases),
            """
            leaves never mutated: \
            \(Set(HandoffMutation.allCases).subtracting(appliedLeaves).map(\.rawValue).sorted())
            """
        )
        #expect(
            judgedLeaves == Set(HandoffMutation.allCases),
            """
            leaves never judged: \
            \(Set(HandoffMutation.allCases).subtracting(judgedLeaves).map(\.rawValue).sorted())
            """
        )
        #expect(
            families == Set(HandoffMutation.allCases.map(\.family)),
            "families exercised: \(families.sorted())"
        )
        // Both dispositions occurred, so neither can have quietly absorbed the other.
        #expect(
            dispositionsObserved == Set(ReferenceHandoffMutationModel.Disposition.allCases),
            "dispositions observed: \(dispositionsObserved.map(\.rawValue).sorted())"
        )
        #expect(
            terminatedLeaves == Set(terminatingLeaves),
            "leaves that terminated a session: \(terminatedLeaves.map(\.rawValue).sorted())"
        )
        #expect(
            refusedLeaves
                == Set(HandoffMutation.allCases).subtracting(Set(terminatingLeaves)),
            "leaves refused before a session: \(refusedLeaves.map(\.rawValue).sorted())"
        )
        // The port's narrowing was traversed completely across the run, not sampled.
        #expect(
            portCheckedLeaves == Set(HandoffMutation.allCases),
            """
            leaves never taken through the port: \
            \(Set(HandoffMutation.allCases).subtracting(portCheckedLeaves).map(\.rawValue).sorted())
            """
        )
        // Every published status and basis was mutated from, so the status leaf is exercised
        // from each of the three statuses rather than from one.
        #expect(
            publishedStatuses == Set(BytePreservationStatus.allCases),
            """
            statuses never published: \
            \(Set(BytePreservationStatus.allCases).subtracting(publishedStatuses).map(\.rawValue).sorted())
            """
        )
        #expect(
            publishedBases == Set(PreservationBasis.allCases),
            """
            bases never published: \
            \(Set(PreservationBasis.allCases).subtracting(publishedBases).map(\.rawValue).sorted())
            """
        )

        // The generated baseline actually varied.
        #expect(seeds.count >= 50, "generated seeds: \(seeds.count)")
        #expect(
            payloadByteCounts.count >= 50,
            "generated payload byte counts: \(payloadByteCounts.count)"
        )
        #expect(
            bases == Set(PreservationBasis.allCases),
            "generated bases: \(bases.map(\.rawValue).sorted())"
        )
        #expect(
            replacementStatuses == Set(BytePreservationStatus.allCases),
            "generated replacement statuses: \(replacementStatuses.map(\.rawValue).sorted())"
        )
        #expect(
            chunkSizes == Set(MutationShape.chunkSizes),
            "generated chunk sizes: \(chunkSizes.sorted())"
        )
        #expect(hintKeys.count >= 4, "generated content-type hints: \(hintKeys.sorted())")
        #expect(
            replacementSchemaVersions == Set(MutationShape.foreignSchemaVersions),
            "generated replacement schema versions: \(replacementSchemaVersions.sorted())"
        )
        #expect(
            replacementBuildIDs.count >= 30,
            "generated replacement build identities: \(replacementBuildIDs.count)"
        )
        #expect(flipOffsets.count >= 30, "generated flip offsets: \(flipOffsets.count)")
        #expect(
            truncationLengths.count >= 30,
            "generated truncation lengths: \(truncationLengths.count)"
        )
        #expect(
            portLeafSelections == Set(HandoffMutation.allCases),
            """
            leaves never selected for the port arm: \
            \(Set(HandoffMutation.allCases).subtracting(portLeafSelections).map(\.rawValue).sorted())
            """
        )
        #expect(controlOrders == [false, true], "only one arm order was generated")
    }
}
