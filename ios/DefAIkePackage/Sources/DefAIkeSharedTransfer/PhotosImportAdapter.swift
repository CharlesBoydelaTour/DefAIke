import DefAIkeDomain
import Foundation

// The Photos route's import adapter.
//
// It does one thing: take the single item the user selected, borrow the provider's
// representation, and stream it into protected session-owned storage before the window
// closes. Everything else about the Photos route belongs somewhere else, and that is
// what keeps this file short:
//
//   * Counting the selection and deciding whether a session exists is
//     `PhotosIngestCoordinator`'s, on the application side of the ``PhotosImporting``
//     port (Requirements 2.5, 2.7, and 2.18).
//   * Copying and hashing is ``EncodedAssetRetainer``'s. There is no second copy path
//     here: the same streaming utility the Share route stages through is the one the
//     Photos route retains through, so the two routes cannot measure the same bytes
//     differently (Requirement 2.14).
//   * Deciding whether the container is analyzable is the Input Validator's. This adapter
//     never inspects, filters, or classifies what arrived, which is why a screenshot in a
//     supported format needs no case of its own (Requirements 2.15 through 2.17).
//
// The recorded ``BytePreservationStatus`` is derived, not chosen. The adapter passes the
// basis the provider's answer supports and ``EncodedAssetRetainer`` derives the most
// conservative status from it, so no path here can record `originalBytes`: `PhotosUI`
// declares no such thing, and the `.current` request is not evidence of it.

/// Why one Photos import attempt produced no accepted ingest.
///
/// Every case is a no-session outcome. An Analysis Session exists only once exactly one
/// complete local representation has been retained, so there is no case here that leaves
/// a session behind in any state — including a failed one.
///
/// The three cases are the distinctions the requirements draw, and they stay separate
/// because they mean different things to an audit:
///
/// | Case | The provider | DefAIke's storage |
/// |---|---|---|
/// | ``noRepresentationObtained(_:)`` | Offered nothing | Never held a byte of the item |
/// | ``representationNotRetained(_:)`` | Offered a representation | The copy of it did not complete |
/// | ``cancelled`` | Either | Nothing survives; not an error |
public enum PhotosImportFailure: Error, Hashable, Sendable {
    /// The provider's access window closed without a representation, so no byte of the
    /// item was ever read.
    ///
    /// This is the "provider failure before any bytes were obtained" the requirements
    /// treat as a recoverable ingest attempt. It is deliberately not an
    /// ``AnalysisError``: no session exists to fail, and inventing a user-facing evidence
    /// category for it would misdescribe what happened.
    case noRepresentationObtained(PhotosProviderFault)

    /// A representation was offered and the retained copy of it did not complete.
    ///
    /// Nothing partial survives: ``EncodedAssetRetainer`` removes what it created before
    /// reporting, and its cleanup is idempotent.
    case representationNotRetained(EncodedAssetRetentionError)

    /// The user cancelled the attempt, on either side of the window.
    ///
    /// A separate case rather than a payload, because cancellation must never be
    /// presented as a failure category (Requirement 11.17).
    case cancelled

    /// The stage a Photos ingest failure is detected in.
    ///
    /// Media classification is the first stage the Photos route reaches, and the closed
    /// stage vocabulary has no earlier one — a provider retrieval is an ingest attempt
    /// rather than a session stage, so there is nothing more precise to name.
    public static let stage: AnalysisStage = .mediaClassification

    /// The narrowed ``AnalysisFault`` view of this failure, for the ``PhotosImporting``
    /// port.
    ///
    /// The port is typed `throws(AnalysisFault)`, so a failure has to cross it as either
    /// cancellation or one ``AnalysisError``. Neither describes a provider retrieval that
    /// held no bytes, and that is intentional in the domain: the fault is only the
    /// transport that tells the caller no ingest exists.
    /// `PhotosIngestCoordinator` turns any fault from this port into a no-session outcome
    /// and never presents the category, and
    /// ``PhotosImportAdapter/attemptImport(of:into:)`` is the surface that keeps the
    /// precise reason for an audit.
    ///
    /// Cancellation passes through from wherever it arrived, so no cancelled attempt can
    /// acquire an error category on the way out. A store capacity breach is the one
    /// failure that has a truthful category — continuing would exceed a bounded ceiling,
    /// which is `resource-limit`.
    public var fault: AnalysisFault {
        switch self {
        case .cancelled:
            return .cancelled
        case .noRepresentationObtained(.cancelled):
            return .cancelled
        case .representationNotRetained(.cancelled):
            return .cancelled
        case .representationNotRetained(.store(.capacityExceeded(scope: _))):
            return .analysis(.resourceLimit, stage: Self.stage)
        case .noRepresentationObtained, .representationNotRetained:
            return .analysis(.decodingError, stage: Self.stage)
        }
    }
}

/// Streams one picker-selected item into protected app-private session storage.
///
/// A value type holding no state between calls: each import borrows one representation,
/// retains one copy, and returns. Two concurrent imports share nothing, so a stale one
/// cannot affect the other's bytes.
public struct PhotosImportAdapter: PhotosImporting {
    private let access: any PhotosRepresentationAccess
    private let retainer: EncodedAssetRetainer
    private let sessionFileProtection: FileProtectionLevel

    /// Creates the adapter.
    ///
    /// - Parameters:
    ///   - access: The provider seam. The only implementation that touches `PhotosUI`
    ///     lives in the app composition.
    ///   - store: Protected, app-private ephemeral storage. Session material only: the
    ///     Photos route never writes to the App Group container, because nothing has to
    ///     cross a process boundary.
    ///   - sessionFileProtection: The iOS data-protection level retained session bytes
    ///     are created with (Requirement 9.6). Required, with no default: the level a
    ///     supported analysis lifecycle needs is a physical-device validation result, and
    ///     compiling one in here would make an unvalidated choice look approved. A level
    ///     that cannot be applied fails the retention closed rather than falling back to
    ///     unprotected bytes.
    ///   - chunkSizeInBytes: I/O buffer size for the streaming copy. A structural bound:
    ///     it changes how many passes a copy takes, never how large a copy may be, and
    ///     the finalized bytes, count, and digest are identical for every value.
    public init(
        access: any PhotosRepresentationAccess,
        store: any EphemeralFileStoring,
        sessionFileProtection: FileProtectionLevel,
        chunkSizeInBytes: Int = EncodedAssetRetainer.defaultChunkSizeInBytes
    ) {
        self.access = access
        self.retainer = EncodedAssetRetainer(store: store, chunkSizeInBytes: chunkSizeInBytes)
        self.sessionFileProtection = sessionFileProtection
    }

    // MARK: - The adapter's own surface

    /// Borrows `item`'s representation and retains one copy of it under `sessionID`.
    ///
    /// The full-fidelity result: success is exactly one complete local representation, and
    /// a failure names how far the attempt got. `importOne(_:into:)` narrows this to the
    /// domain port; this is the surface an audit and the adapter's own tests read.
    ///
    /// `sessionID` is a candidate, not a session. It names the storage scope the copy is
    /// streamed into, and it becomes a session's identity only when this call succeeds —
    /// the same way the Share route's candidate identifier means nothing until publication
    /// commits (design, Analysis Session state machine).
    public func attemptImport(
        of item: PhotosPickerItemReference,
        into sessionID: AnalysisSessionID
    ) async -> Result<ImportedEncodedAsset, PhotosImportFailure> {
        let retained: RetainedRepresentation
        do {
            // The copy happens inside this closure, which is inside the provider's access
            // window. Nothing captures the borrowed representation, so there is no URL to
            // read after the window has closed.
            retained = try await access.withRepresentation(of: item) { borrowed in
                await self.retain(borrowed, into: sessionID)
            }
        } catch {
            // No representation was produced, so `consume` never ran and no byte of the
            // item was read. There is nothing to clean up and no session to end.
            return .failure(error == .cancelled ? .cancelled : .noRepresentationObtained(error))
        }

        switch retained {
        case .success(let asset):
            return .success(asset)
        case .failure(.cancelled):
            return .failure(.cancelled)
        case .failure(let error):
            return .failure(.representationNotRetained(error))
        }
    }

    /// Streams the borrowed representation into the session's protected storage.
    ///
    /// The basis comes from what the provider actually answered and the status is derived
    /// from the basis by ``EncodedAssetRetainer``, so there is no argument here that could
    /// claim byte originality. The recorded content-type hint is the one the provider
    /// supplied with the bytes rather than the one the picker claimed for the placeholder:
    /// the hint describes what was retained.
    private func retain(
        _ borrowed: BorrowedRepresentation,
        into sessionID: AnalysisSessionID
    ) async -> RetainedRepresentation {
        do {
            return .success(
                try await retainer.retainAsset(
                    ofFileAt: borrowed.fileURL,
                    route: .photosPicker,
                    for: sessionID,
                    basis: borrowed.form.preservationBasis,
                    contentTypeHint: borrowed.suppliedContentTypeHint,
                    protection: sessionFileProtection
                )
            )
        } catch {
            return .failure(error)
        }
    }

    // MARK: - PhotosImporting

    /// The domain port. Returns an accepted ingest, or throws the narrowed fault.
    public func importOne(
        _ item: PhotosPickerItemReference,
        into sessionID: AnalysisSessionID
    ) async throws(AnalysisFault) -> ImportedEncodedAsset {
        switch await attemptImport(of: item, into: sessionID) {
        case .success(let asset):
            return asset
        case .failure(let failure):
            throw failure.fault
        }
    }
}
