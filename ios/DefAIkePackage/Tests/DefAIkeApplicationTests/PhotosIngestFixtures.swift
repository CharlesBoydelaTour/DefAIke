import DefAIkeDomain
import Foundation

@testable import DefAIkeApplication

// Picker values and the import-port double the ingest coordinator needs.
//
// The double records every call, because most of what this task has to prove is a
// *nonoccurrence*: a dismissed picker and a rejected item count must never reach the
// provider, so the assertion has to be about the call rather than about the result.
//
// **No value here is an approved release value.** The byte sequences and identifiers are
// test scaffolding.

extension Fixture {
    static func sessionID(_ raw: String = "session-0001") -> AnalysisSessionID {
        guard let id = AnalysisSessionID(raw) else {
            preconditionFailure("fixture session identifier is not canonical: \(raw)")
        }
        return id
    }

    static func contentTypeHint(_ raw: String = "public.jpeg") -> ContentTypeHint {
        guard let hint = ContentTypeHint(raw) else {
            preconditionFailure("fixture content type hint is not valid: \(raw)")
        }
        return hint
    }

    static func storageKey(
        _ raw: String = "0123456789abcdef0123456789abcdef"
    ) -> EphemeralStorageKey {
        guard let key = EphemeralStorageKey(raw) else {
            preconditionFailure("fixture storage key is not canonical: \(raw)")
        }
        return key
    }

    /// One selected item.
    static func pickerItem(token: UInt64 = 1) -> PhotosPickerItemReference {
        PhotosPickerItemReference(
            token: ProviderToken(rawValue: token),
            contentTypeHint: contentTypeHint()
        )
    }

    /// A selection of exactly `count` items, so any count can be represented and refused.
    static func selection(itemCount count: Int) -> PhotosPickerSelection {
        PhotosPickerSelection(
            items: (0..<max(count, 0)).map { pickerItem(token: UInt64($0 + 1)) }
        )
    }

    /// An accepted ingest for `sessionID`, as a successful import would return.
    static func importedAsset(
        route: InputRoute = .photosPicker,
        sessionID: AnalysisSessionID = Fixture.sessionID(),
        byteCount: UInt64 = 1_024,
        preservationBasis: PreservationBasis = .providerDeclaredCurrentRepresentationOnly
    ) -> ImportedEncodedAsset {
        guard
            let handle = EncodedAssetHandle(
                sessionID: sessionID,
                storageKey: storageKey(),
                byteCount: byteCount,
                sha256: digest("retained-\(sessionID.rawValue)"),
                protection: .complete
            ),
            let asset = ImportedEncodedAsset(
                route: route,
                handle: handle,
                preservationStatus: preservationBasis.mostConservativeStatus,
                preservationBasis: preservationBasis,
                contentTypeHint: contentTypeHint()
            )
        else {
            preconditionFailure("the imported asset fixture must be internally consistent")
        }
        return asset
    }
}

/// Mints the identifiers a test names, in order.
///
/// Deterministic so an assertion can say *which* identifier the attempt ran under, and
/// bounded so a coordinator that minted twice for one attempt fails instead of drifting.
final class ScriptedSessionIdentity: AnalysisSessionIdentityMinting, @unchecked Sendable {
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

    func mintCandidateSessionID() -> AnalysisSessionID {
        lock.withLock {
            guard !remaining.isEmpty else {
                preconditionFailure("the coordinator minted more candidates than the test scripted")
            }
            let next = remaining.removeFirst()
            issued.append(next)
            return next
        }
    }
}

/// A ``PhotosImporting`` double that records its calls and returns what a test queued.
///
/// It answers per call rather than once, so a test can queue a refusal followed by an
/// acceptance and prove that nothing from the first attempt reaches the second.
actor RecordingPhotosImporter: PhotosImporting {

    /// What one import call does.
    enum Answer: Sendable {
        /// Return an accepted ingest for the session the coordinator supplied.
        case accept
        /// Return an accepted ingest built by `make`, so a foreign route or session can be
        /// returned deliberately.
        case returnAsset(@Sendable (AnalysisSessionID) -> ImportedEncodedAsset)
        /// Throw the given fault.
        case fail(AnalysisFault)
    }

    /// One record per call: the item's provider token and the session it was asked for.
    struct Call: Hashable, Sendable {
        let token: ProviderToken
        let sessionID: AnalysisSessionID
    }

    private var answers: [Answer]
    private(set) var calls: [Call] = []

    init(_ answers: [Answer]) {
        self.answers = answers
    }

    init(_ answer: Answer) {
        self.answers = [answer]
    }

    var callCount: Int { calls.count }

    func importOne(
        _ item: PhotosPickerItemReference,
        into sessionID: AnalysisSessionID
    ) async throws(AnalysisFault) -> ImportedEncodedAsset {
        calls.append(Call(token: item.token, sessionID: sessionID))
        guard !answers.isEmpty else {
            preconditionFailure("the coordinator imported more times than the test scripted")
        }
        switch answers.removeFirst() {
        case .accept:
            return Fixture.importedAsset(sessionID: sessionID)
        case .returnAsset(let make):
            return make(sessionID)
        case .fail(let fault):
            throw fault
        }
    }
}
