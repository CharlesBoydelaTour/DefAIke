import Foundation

// The Share transfer ports: the minimal cross-process surface.
//
// The store has exactly three states and one ready slot. Successful atomic
// `staging` → `ready` publication is the sole Share-route session-creation commit, and
// claim changes ownership without changing the ticket's `AnalysisSessionID`
// (Requirements 2.3, 2.8, and 11.12).

/// The three transfer states, and nothing else.
///
/// A fourth state, or a "published but not yet readable" intermediate, would create a
/// window in which a session exists with no complete bytes. Publication is atomic
/// precisely so that window does not exist.
public enum TransferSlotState: String, Codable, Sendable, CaseIterable {
    /// The extension is still writing. Never promoted if interrupted.
    case staging
    /// One complete, protected, published transfer awaiting the main app. The
    /// session is `AwaitingMainApp` from here.
    case ready
    /// The main app has taken ownership. Short-lived.
    case claimed
}

/// Identity of one Share transfer slot.
///
/// Distinct from ``AnalysisSessionID``: the transfer is the cross-process container,
/// the session is the analysis. One transfer carries exactly one candidate session
/// identifier, and claim must preserve it.
public struct ShareTransferID: CanonicalIdentifier {
    public let rawValue: String

    public init?(_ rawValue: String) {
        guard CanonicalIdentifierSyntax.isCanonical(
            rawValue,
            maximumCharacterCount: Self.maximumCharacterCount
        ) else {
            return nil
        }
        self.rawValue = rawValue
    }
}

/// The bounded record published alongside the staged bytes.
///
/// Every field the main app reverifies is here, and each is required: byte count,
/// digest, preservation status, its basis, the schema version, and the extension's
/// build identity. Requirement 2.19 turns any disagreement into `handoff-error`
/// before validation, provenance processing, or inference, so the ticket is
/// deliberately small, `Codable`, and free of anything the main app cannot recheck.
///
/// The ticket holds no evidence, no decoded pixels, no model input, and no model
/// output (design, Shared Transfer Store).
public struct ShareTransferTicket: Hashable, Codable, Sendable {
    /// The only schema version this build reads or writes.
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let transferID: ShareTransferID

    /// A candidate session identifier while the slot is `staging`; the identity of one
    /// pending session once publication succeeds. Claim preserves it unchanged.
    public let sessionID: AnalysisSessionID

    /// Always ``InputRoute/shareExtension``.
    public let route: InputRoute

    public let contentTypeHint: ContentTypeHint?
    public let byteCount: UInt64
    public let sha256: SHA256Digest
    public let preservationStatus: BytePreservationStatus
    public let preservationBasis: PreservationBasis

    /// The build that staged the transfer. Compared against the claiming build so two
    /// installed compositions cannot exchange tickets (Requirement 2.19).
    public let extensionBuildID: AppBuildID

    /// Wall-clock instant the ticket was written, for lifecycle evaluation only.
    public let createdAt: Date

    /// Creates a ticket, or `nil` when it is internally inconsistent.
    ///
    /// Rejects an unreadable schema version, a route other than the Share route, an
    /// empty payload, and a preservation status its basis does not support. The last
    /// one matters most: a tampered ticket that flips only the status, or only the
    /// basis, cannot be constructed, so the mutation is caught at decode rather than
    /// by a hand-written comparison the claim path might forget (Property 6).
    public init?(
        schemaVersion: Int = ShareTransferTicket.currentSchemaVersion,
        transferID: ShareTransferID,
        sessionID: AnalysisSessionID,
        route: InputRoute = .shareExtension,
        contentTypeHint: ContentTypeHint?,
        byteCount: UInt64,
        sha256: SHA256Digest,
        preservationStatus: BytePreservationStatus,
        preservationBasis: PreservationBasis,
        extensionBuildID: AppBuildID,
        createdAt: Date
    ) {
        guard schemaVersion == Self.currentSchemaVersion else { return nil }
        guard route == .shareExtension else { return nil }
        guard byteCount > 0 else { return nil }
        guard preservationBasis.supports(preservationStatus) else { return nil }
        self.schemaVersion = schemaVersion
        self.transferID = transferID
        self.sessionID = sessionID
        self.route = route
        self.contentTypeHint = contentTypeHint
        self.byteCount = byteCount
        self.sha256 = sha256
        self.preservationStatus = preservationStatus
        self.preservationBasis = preservationBasis
        self.extensionBuildID = extensionBuildID
        self.createdAt = createdAt
    }

    /// Decodes a ticket and revalidates every invariant.
    ///
    /// Fail-closed: a ticket that arrives across the App Group boundary with an
    /// unreadable schema version, a wrong route, an empty payload, or a status its
    /// basis does not support is a decoding failure, never a repaired value.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let ticket = ShareTransferTicket(
            schemaVersion: try container.decode(Int.self, forKey: .schemaVersion),
            transferID: try container.decode(ShareTransferID.self, forKey: .transferID),
            sessionID: try container.decode(AnalysisSessionID.self, forKey: .sessionID),
            route: try container.decode(InputRoute.self, forKey: .route),
            contentTypeHint: try container.decodeIfPresent(
                ContentTypeHint.self, forKey: .contentTypeHint),
            byteCount: try container.decode(UInt64.self, forKey: .byteCount),
            sha256: try container.decode(SHA256Digest.self, forKey: .sha256),
            preservationStatus: try container.decode(
                BytePreservationStatus.self, forKey: .preservationStatus),
            preservationBasis: try container.decode(
                PreservationBasis.self, forKey: .preservationBasis),
            extensionBuildID: try container.decode(AppBuildID.self, forKey: .extensionBuildID),
            createdAt: try container.decode(Date.self, forKey: .createdAt)
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: CodingKeys.schemaVersion,
                in: container,
                debugDescription: """
                    A Share transfer ticket must use schema version \
                    \(Self.currentSchemaVersion), the Share route, a nonempty payload, \
                    and a preservation status its basis supports.
                    """
            )
        }
        self = ticket
    }

    /// Whether this ticket matches what the claiming process independently measured.
    ///
    /// Compares only recomputable facts: the recopied byte count and digest, and the
    /// claiming build's identity. Every mismatch is `handoff-error` before any image
    /// or provenance work (Requirements 2.19 and 11.13).
    public func matches(
        recomputedByteCount: UInt64,
        recomputedDigest: SHA256Digest,
        claimingBuildID: AppBuildID
    ) -> Bool {
        byteCount == recomputedByteCount
            && sha256 == recomputedDigest
            && extensionBuildID == claimingBuildID
    }
}

/// One published transfer: its ticket and the stored bytes it describes.
public struct ReadyTransfer: Hashable, Sendable {
    public let ticket: ShareTransferTicket

    /// The finalized, protected object holding the exact staged bytes.
    public let storageKey: EphemeralStorageKey

    public init(ticket: ShareTransferTicket, storageKey: EphemeralStorageKey) {
        self.ticket = ticket
        self.storageKey = storageKey
    }
}

/// The extension side of the transfer store.
///
/// ``stageOne(_:consent:)`` requires a ``ConfirmedConsent``, so it cannot be called
/// before the user's visible action. It publishes atomically or leaves nothing: an
/// interrupted staging slot is never promoted, and a decline, cancellation, provider
/// failure, or resource breach before publication removes staging and creates no
/// session and no evidence (Requirements 2.4, 11.8, and 11.11).
///
/// This port is implemented in `DefAIkeSharedTransfer`, which the Share Extension
/// links. Nothing reachable from it performs inference or provenance validation.
public protocol ShareTransferStaging: Sendable {
    /// Streams the consented provider's exact available bytes into `staging`, then
    /// atomically publishes one `ready` transfer.
    ///
    /// The returned ticket is the commit point: its existence means a pending Share
    /// session exists. A thrown fault means it does not.
    func stageOne(
        _ provider: SharedItemProvider,
        consent: ConfirmedConsent
    ) async throws(AnalysisFault) -> ShareTransferTicket

    /// Removes any `staging` material this process left behind, at startup and after
    /// an abandoned attempt.
    ///
    /// Idempotent. Runs before the extension accepts work (Requirement 11.16).
    func discardStagedMaterial(
        policy: DataLifecyclePolicy
    ) async throws(EphemeralStoreError) -> Void
}

/// The main-app side of the transfer store.
///
/// A claim recopies into protected app-private storage, recomputes the byte count and
/// digest, and compares them against the ticket before anything else happens. Only
/// then does the session resume under its unchanged identifier, and only then is the
/// Model Bundle bound (Requirements 2.3, 2.19, and 11.13).
public protocol ShareTransferClaiming: Sendable {
    /// The published transfer awaiting this app, or `nil` when the ready slot is
    /// empty.
    ///
    /// Peeking does not claim: it is how the app decides whether to resume a pending
    /// session at all, and how a recovery instruction is offered when a second share
    /// arrives while a transfer is already pending.
    func peekReadyTransfer() async throws(EphemeralStoreError) -> ReadyTransfer?

    /// Atomically claims the ready transfer, reverifies it, and returns it as an
    /// accepted ingest under its original session identifier.
    ///
    /// Returns `nil` when the ready slot is empty. Throws
    /// `.analysis(.handoffError, stage: .handoffVerification)` on any ticket, payload,
    /// status, schema, or build mismatch, after deleting the failed transfer.
    func claimReadyTransfer(
        claimingBuildID: AppBuildID
    ) async throws(AnalysisFault) -> ImportedEncodedAsset?
}
