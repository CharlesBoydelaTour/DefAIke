import Foundation

// The ingest ports: the two Version 1 routes into an Analysis Session.
//
// Neither port imports PhotosUI, UniformTypeIdentifiers, or `NSItemProvider`. A
// selection and a shared item arrive as bounded references the domain can generate,
// count, and reject, so the one-item rule, cancellation, and provider failure are all
// testable without a picker or a share sheet (Requirements 2.5 through 2.8).

/// One item the user selected in the system photo picker.
///
/// Selected-item access only: the reference names a single selection and grants
/// nothing else, which is how the Photos route avoids requesting full-library
/// authorization (Requirement 9.4).
public struct PhotosPickerItemReference: Hashable, Sendable {
    /// The framework-owned representation, valid only during provider access.
    public let token: ProviderToken

    /// What the picker claimed the content type is. Never trusted for classification.
    public let contentTypeHint: ContentTypeHint?

    public init(token: ProviderToken, contentTypeHint: ContentTypeHint?) {
        self.token = token
        self.contentTypeHint = contentTypeHint
    }
}

/// The complete result of one picker presentation.
///
/// The item count is unconstrained on purpose. Requirement 2.7 rejects any count
/// other than one *before* a session exists, so zero and many must be representable
/// in order to be rejected and tested (Property 4). An empty selection is the
/// cancellation case (Requirement 2.18).
public struct PhotosPickerSelection: Hashable, Sendable {
    public let items: [PhotosPickerItemReference]

    public init(items: [PhotosPickerItemReference]) {
        self.items = items
    }

    /// The sole selected item, or `nil` for any other count.
    ///
    /// The only sanctioned way to get from a selection to an item: there is no
    /// `first`, no `prefix(1)`, and no "pick the best representation".
    public var soleItem: PhotosPickerItemReference? {
        items.count == 1 ? items[0] : nil
    }

    /// Whether the user dismissed the picker without selecting anything.
    public var isCancellation: Bool { items.isEmpty }
}

/// One item offered to the Share Extension by the sharing application.
///
/// As with a picker selection, `itemCount` is unconstrained so a multi-item activation
/// can be represented and refused at runtime rather than being assumed away.
public struct SharedItemProvider: Hashable, Sendable {
    /// The framework-owned representation, valid only during provider access.
    public let token: ProviderToken

    /// How many items the activation offered.
    public let itemCount: Int

    /// What the sharing application claimed the content type is. Never trusted.
    public let contentTypeHint: ContentTypeHint?

    /// Creates a provider reference, or `nil` for a negative item count.
    public init?(token: ProviderToken, itemCount: Int, contentTypeHint: ContentTypeHint?) {
        guard itemCount >= 0 else { return nil }
        self.token = token
        self.itemCount = itemCount
        self.contentTypeHint = contentTypeHint
    }

    /// Whether this activation offered exactly the one item the requirements allow.
    public var offersExactlyOneItem: Bool { itemCount == 1 }
}

/// Proof that the user performed the visible consent action for one handoff.
///
/// A value of this type is the only thing that lets ``ShareTransferStaging`` read a
/// single byte, so "consent precedes byte access" is a signature-level rule rather
/// than a code-ordering convention (Requirements 2.2 and 11.10). It names the
/// Extension Execution Policy that required the action, so a build cannot stage
/// without a bound policy, and it names the exact provider that was consented to, so
/// consent for one item cannot be replayed for another.
public struct ConfirmedConsent: Hashable, Sendable {
    /// The provider the user consented to hand off.
    public let provider: SharedItemProvider

    /// The Extension Execution Policy version that required the consent action.
    public let extensionExecutionPolicyID: ArtifactID

    /// Wall-clock instant the user confirmed, for lifecycle evaluation only.
    public let confirmedAt: Date

    /// Creates consent, or `nil` when the activation did not offer exactly one item.
    ///
    /// A declined or cancelled action simply produces no value, which is why a
    /// pre-publication decline can leave no staging directory, no session, and no
    /// evidence: there was never a consent token to proceed with (Requirement 2.4).
    public init?(
        provider: SharedItemProvider,
        extensionExecutionPolicyID: ArtifactID,
        confirmedAt: Date
    ) {
        guard provider.offersExactlyOneItem else { return nil }
        self.provider = provider
        self.extensionExecutionPolicyID = extensionExecutionPolicyID
        self.confirmedAt = confirmedAt
    }
}

/// Copies one picker-selected item into protected app-private storage.
///
/// Returns an accepted ingest only when a local representation was streamed to
/// completion before the provider's access window closed. A failure before any byte
/// is held is a recoverable ingest-attempt failure that starts no session, so it
/// surfaces as a thrown fault the coordinator maps to "no session" rather than to a
/// user-facing evidence error (design, Ingest Coordinator).
public protocol PhotosImporting: Sendable {
    /// Streams `item` into a fresh session's storage and records its preservation
    /// status with an evidence basis.
    ///
    /// The session identifier is supplied by the caller rather than minted here: for
    /// the Photos route the coordinator creates a session only once exactly one local
    /// representation exists, and passing the identifier in keeps that decision in one
    /// place.
    func importOne(
        _ item: PhotosPickerItemReference,
        into sessionID: AnalysisSessionID
    ) async throws(AnalysisFault) -> ImportedEncodedAsset
}
