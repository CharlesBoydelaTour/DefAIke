import DefAIkeDomain

// The Photos route's ingest coordinator: the one place that decides whether a session
// exists.
//
// The design draws a line the requirements depend on: a Photos provider retrieval is an
// **ingest attempt**, not yet an Analysis Session, because the system may have to fetch an
// iCloud asset and can fail before DefAIke holds anything. Everything in this file
// exists to make that line unavoidable rather than remembered:
//
//   * The only way out is ``PhotosIngestOutcome``, and only its `sessionCreated` case
//     carries an ``ImportedEncodedAsset``. A refusal has no asset to carry, so there is
//     no representation of "a session that failed during ingest" (Requirements 2.7 and
//     2.18).
//   * The candidate identifier is minted before the attempt and returned to nobody unless
//     the attempt succeeds, mirroring the Share route's candidate identifier under
//     `staging`.
//   * The count check runs before the port is touched. A selection of zero or many never
//     reaches a provider, so no byte is read for an ingest that was always going to be
//     refused.
//
// It holds no state. That is the requirement, not an implementation preference: a new
// selection after a refused or failed attempt must start from nothing, and the way to
// guarantee that no error category or session data survives is to have nowhere to keep it.
//
// Deliberately absent: any retry, any way to accept a selection's first item, any way to
// carry a previous attempt's outcome, and any presentation decision. What a user is shown
// after a no-session outcome is the Result Presenter's, and a refusal here is never an
// evidence verdict.

/// The candidate identifier one ingest attempt runs under.
///
/// A candidate, not a session. It names the storage scope the copy streams into and
/// becomes an Analysis Session's identity only once exactly one complete local
/// representation has been retained under it.
///
/// A protocol so the attempt is deterministic under test. There is no member that derives
/// an identifier from a file name, an asset identifier, a selection, or the bytes: an
/// identifier that carried any of those would be session-correlatable user content
/// (Requirement 9.11).
public protocol AnalysisSessionIdentityMinting: Sendable {
    func mintCandidateSessionID() -> AnalysisSessionID
}

/// Mints candidate identifiers from 128 random bits.
///
/// The same shape the Shared Transfer Store uses for a transfer identifier: system
/// randomness, hexadecimal, and no input at all, so nothing about the user's selection can
/// influence the result.
public struct RandomAnalysisSessionIdentity: AnalysisSessionIdentityMinting {
    /// Identifier length in hexadecimal characters: 16 random bytes.
    private static let characterCount = 32

    private static let hexadecimalDigits: [Character] = Array("0123456789abcdef")

    public init() {}

    public func mintCandidateSessionID() -> AnalysisSessionID {
        var generator = SystemRandomNumberGenerator()
        var raw = ""
        raw.reserveCapacity(Self.characterCount)
        for _ in 0..<(Self.characterCount / 2) {
            let byte = UInt8.random(in: .min ... .max, using: &generator)
            raw.append(Self.hexadecimalDigits[Int(byte >> 4)])
            raw.append(Self.hexadecimalDigits[Int(byte & 0x0F)])
        }
        guard let sessionID = AnalysisSessionID(raw) else {
            preconditionFailure("generated session identifier is not canonical: \(raw)")
        }
        return sessionID
    }
}

/// Why an ingest attempt created no Analysis Session.
///
/// Five distinct reasons, because they are five different facts. Collapsing any pair would
/// lose something an audit needs: a dismissed picker is not a rejected selection, a
/// cancellation is not a failure, and a provider that produced nothing is not a session
/// that failed.
public enum PhotosIngestRefusal: Hashable, Sendable {
    /// The user dismissed the picker without selecting anything.
    ///
    /// The picker flow ends here: no session, no evidence verdict, and nothing to clean up
    /// (Requirement 2.18).
    case pickerCancelled

    /// The selection contained a number of items other than one, so it was rejected
    /// before a session could exist (Requirement 2.7).
    ///
    /// Carries the count that was refused. Two or more items is the case this exists for;
    /// zero is ``pickerCancelled``, which is a dismissal rather than a rejection.
    case itemCountRefused(Int)

    /// The user cancelled during the attempt.
    ///
    /// Never an ``AnalysisError``: cancellation is a separate outcome and must not be
    /// presented as a failure category (Requirement 11.17).
    case cancelled

    /// No complete local representation was obtained, so no session was created.
    ///
    /// The category is what the import port reported, recorded for an audit only. It is
    /// *not* an Analysis Error the session ended with, because no session exists to end:
    /// the requirements treat a provider retrieval that produced nothing as a recoverable
    /// ingest attempt, and ``AnalysisError`` has no category for it. Nothing presents this
    /// value as an evidence error.
    case noLocalRepresentation(AnalysisError)

    /// The import port returned an ingest that does not belong to this attempt.
    ///
    /// Unreachable through the shipping adapter, which stamps its own route and the
    /// identifier it was handed. Kept as a fail-closed branch because the alternative is
    /// binding a session to bytes retained for a different session or arriving by a
    /// different route, which is exactly what Requirements 2.5 and 2.8 forbid. Removing
    /// whatever material such an adapter left behind is the Privacy Controller's, which
    /// owns every session scope's deletion.
    case foreignIngest
}

/// What one ingest attempt produced.
///
/// Two cases, and only one of them carries bytes. An `Optional<ImportedEncodedAsset>`
/// would have said the same thing about success and nothing at all about why a refusal
/// happened, and a `Result` would have made every refusal an error — which three of the
/// five are not.
public enum PhotosIngestOutcome: Hashable, Sendable {
    /// Exactly one local representation was retained, so exactly one Analysis Session now
    /// exists, bound to exactly this image and this route (Requirements 2.1, 2.5, 2.8).
    case sessionCreated(ImportedEncodedAsset)

    /// No Analysis Session was created, and why.
    case noSession(PhotosIngestRefusal)

    /// The accepted ingest, or `nil` when no session was created.
    public var acceptedIngest: ImportedEncodedAsset? {
        guard case .sessionCreated(let asset) = self else { return nil }
        return asset
    }

    /// The session that now exists, or `nil` when none does.
    public var sessionID: AnalysisSessionID? { acceptedIngest?.sessionID }

    /// Why no session was created, or `nil` when one was.
    public var refusal: PhotosIngestRefusal? {
        guard case .noSession(let refusal) = self else { return nil }
        return refusal
    }
}

/// Turns one picker presentation into at most one Analysis Session.
///
/// Stateless and reusable: each call is a complete attempt that shares nothing with the
/// last one.
public struct PhotosIngestCoordinator: Sendable {
    private let importer: any PhotosImporting
    private let identity: any AnalysisSessionIdentityMinting

    /// Creates the coordinator.
    ///
    /// - Parameters:
    ///   - importer: The Photos import port. The coordinator reaches the picker only
    ///     through it, so it never imports `PhotosUI` and never sees a file path.
    ///   - identity: Mints the candidate identifier each attempt runs under.
    public init(
        importer: any PhotosImporting,
        identity: any AnalysisSessionIdentityMinting = RandomAnalysisSessionIdentity()
    ) {
        self.importer = importer
        self.identity = identity
    }

    /// Runs one ingest attempt over the complete result of one picker presentation.
    ///
    /// Ordered so that each check happens before the work it would make pointless:
    ///
    /// 1. An empty selection is the user dismissing the picker. The flow ends with no
    ///    session and no evidence verdict (Requirement 2.18).
    /// 2. Any other count than one is rejected before a session could exist. The provider
    ///    is never touched, so no byte is read for a selection that was always going to be
    ///    refused (Requirement 2.7).
    /// 3. A candidate identifier is minted, and the sole item is streamed into that
    ///    scope's protected storage. Selected-item access only: the item reference names
    ///    one selection and grants nothing else, and no full-library authorization exists
    ///    anywhere in the path (Requirement 9.4).
    /// 4. A session exists only if that returned an accepted ingest whose route and
    ///    session are this attempt's. Any fault becomes a no-session outcome rather than a
    ///    session in a failed state (Requirements 2.1, 2.5, 2.8).
    ///
    /// Nothing here inspects the item's format, its origin, or whether it is a screenshot.
    /// A screenshot in a supported format is an ordinary selection and takes the ordinary
    /// path; whether the retained container is analyzable is decided later, against the
    /// actual bytes (Requirements 2.15 through 2.17).
    public func ingest(_ selection: PhotosPickerSelection) async -> PhotosIngestOutcome {
        guard !selection.isCancellation else { return .noSession(.pickerCancelled) }
        guard let item = selection.soleItem else {
            return .noSession(.itemCountRefused(selection.items.count))
        }

        // A candidate until the import succeeds. Minting it does not create a session, and
        // an attempt that fails returns it to nobody.
        let candidate = identity.mintCandidateSessionID()
        let asset: ImportedEncodedAsset
        do {
            asset = try await importer.importOne(item, into: candidate)
        } catch {
            switch error {
            case .cancelled:
                return .noSession(.cancelled)
            case .analysis(let category, _):
                return .noSession(.noLocalRepresentation(category))
            }
        }

        guard asset.sessionID == candidate, asset.route == .photosPicker else {
            return .noSession(.foreignIngest)
        }
        return .sessionCreated(asset)
    }
}
