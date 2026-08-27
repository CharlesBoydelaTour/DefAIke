import DefAIkeDomain
import Foundation

// The one thing the Photos route reaches out for, and the shape that makes the reach safe.
//
// `PhotosPicker` is SwiftUI, and a `PhotosPickerItem`'s representation arrives through
// `Transferable` as a temporary file the framework owns and reclaims. Two consequences
// drive everything below:
//
//   * The bytes have to be consumed inside the provider's access window. Apple's
//     `FileRepresentation` guidance is explicit that the receiver copies the temporary
//     representation into its own storage, and `NSItemProvider`'s file loading behaves
//     the same way (design, research findings 1 and 2). A URL that outlives the window
//     names nothing.
//   * Nothing about the picker can be exercised on a host, and `PhotosUI` would drag a
//     SwiftUI, iOS-shaped framework into a module the Share Extension links. So the
//     picker stays outside this module entirely: ``PhotosRepresentationAccess`` is the
//     seam, the same way ``PixelModelRuntimeLoading`` keeps Core ML out of the pixel
//     analyzer's rules.
//
// The window rule is structural rather than documented. There is no member here that
// returns a URL, a file handle, or a `Data`: the only way to see a representation is to
// be handed one inside a closure that the access call waits for. A caller that wanted to
// read the provider's file later would have nothing to hold onto.
//
// Deliberately absent, and each absence is the requirement:
//
//   * Any way to request full-library access, authorization status, or an asset by
//     identifier. Selected-item access only (Requirement 9.4).
//   * Any way to request a transcode. ``PhotosEncodingPolicy`` has one case, so a caller
//     cannot ask the picker to re-encode the user's image.
//   * Any way to filter, classify, or reject a representation by its type. Deciding
//     whether a container is a Supported Static Image is the Input Validator's work
//     against the actual bytes (Requirements 2.15 and 3.1); ingest preserves whatever
//     arrived, which is also why a screenshot needs no special case (Requirement 2.17).
//   * Any timeout, deadline, or retry.

// MARK: - What the request is allowed to say

/// The photo-library access the Photos route operates under.
///
/// One case, on purpose. Requirement 9.4 requires selected-item access instead of full
/// photo-library access, and the way to make that a fact about the code rather than a
/// review note is to leave full-library access unrepresentable: there is no value to
/// pass, no branch to take, and no authorization request to make.
public enum PhotosLibraryAccess: String, Hashable, Sendable, CaseIterable {
    /// Only the items the user explicitly selected in the picker are reachable.
    case selectedItemsOnly = "selected-items-only"
}

/// How the request asks the picker to resolve an item that has more than one encoding.
///
/// One case, on purpose. Apple's `.current` policy avoids transcoding *when possible*,
/// which is the closest a picker request can come to preserving the available encoded
/// bytes, and asking for a compatibility transcode would deliberately change them. So
/// the compatibility policy is not representable here.
///
/// Requesting this establishes nothing about byte originality. `.current` is a request,
/// not a guarantee, and the recorded ``BytePreservationStatus`` comes from what the
/// provider actually supplied — never from the fact that this was asked for
/// (Requirement 2.11 and design, main-app Photos sequence).
public enum PhotosEncodingPolicy: String, Hashable, Sendable, CaseIterable {
    /// Avoid transcoding where the picker can.
    case currentWhenPossible = "current-when-possible"
}

/// A container type a typed file representation is requested for.
///
/// These are the three Version 1 Supported Static Image containers, in the two Uniform
/// Type Identifier spellings HEIC/HEIF uses. The set exists so the request can name a
/// *typed* representation rather than accepting whatever generic form the picker offers
/// first; it is not a validation rule. A representation that arrives outside this set is
/// still retained, and the Input Validator refuses it by sniffing the actual container
/// (Requirements 2.15 and 2.16).
public enum RequestedImageContainer: String, Hashable, Sendable, CaseIterable {
    case jpeg = "public.jpeg"
    case png = "public.png"
    case heic = "public.heic"
    case heif = "public.heif"
}

/// The fixed representation request the Photos route makes.
///
/// A namespace rather than a constructible value, because none of it is a caller's
/// choice: the design fixes the typed request and the current-encoding policy, and
/// Requirement 9.4 fixes the access rule. Exposing them as parameters would create the
/// only thing that could go wrong here — a call site that asked for a transcode, for a
/// generic representation, or for wider access.
public enum PhotosRepresentationRequest: Sendable {
    /// Container types a typed file representation is requested for, in preference order.
    public static let requestedContainers: [RequestedImageContainer] =
        RequestedImageContainer.allCases

    /// The encoding-disambiguation policy the request carries.
    public static let encodingPolicy: PhotosEncodingPolicy = .currentWhenPossible

    /// The photo-library access the request operates under.
    public static let libraryAccess: PhotosLibraryAccess = .selectedItemsOnly

    /// How many items one picker presentation may return.
    ///
    /// The picker is configured for a single selection, and runtime counting stays
    /// authoritative anyway: `PhotosIngestCoordinator` refuses any other count before a
    /// session exists (Requirement 2.7).
    public static let maximumSelectionCount = 1
}

// MARK: - What the provider hands back

/// How the provider answered the typed representation request.
///
/// The two cases are the only distinction the picker actually supports, and both of them
/// establish the same thing about originality: nothing. `PhotosUI` never declares that a
/// representation is the asset's unmodified original, and it never declares that it
/// transcoded, so ``preservationBasis`` cannot reach
/// ``PreservationBasis/providerDeclaredOriginalRepresentation`` or
/// ``PreservationBasis/providerDeclaredTransformedRepresentation`` from either case.
public enum SuppliedRepresentationForm: String, Hashable, Sendable, CaseIterable {
    /// The provider supplied a representation typed as one of the requested containers.
    case typedFileRepresentation = "typed-file-representation"

    /// A file arrived, but the provider did not identify it as a requested container.
    case untypedFileRepresentation = "untyped-file-representation"

    /// The evidence this form provides for a ``BytePreservationStatus``.
    ///
    /// A typed answer under the current-encoding request establishes that these are the
    /// provider's current bytes and nothing more. An untyped answer establishes no
    /// history at all. Both bases are ``BytePreservationStatus/unknown``, which is the
    /// conservative record Requirement 2.11 asks for; they stay distinct so an audit can
    /// see which one the provider actually gave.
    public var preservationBasis: PreservationBasis {
        switch self {
        case .typedFileRepresentation: .providerDeclaredCurrentRepresentationOnly
        case .untypedFileRepresentation: .preservationHistoryNotEstablished
        }
    }
}

/// One item's representation, borrowed from the provider.
///
/// Valid only for the duration of the closure it is handed to. It is never stored,
/// returned, or captured past that point: ``fileURL`` names a location the framework
/// owns and reclaims, so reading it later is reading nothing.
///
/// The source is opened for reading only. Nothing here writes, truncates, moves, or
/// removes the provider's file — that is the provider's to reclaim.
public struct BorrowedRepresentation: Hashable, Sendable {
    /// The provider's temporary file, valid only inside the access window.
    public let fileURL: URL

    /// The content type the provider said it supplied.
    ///
    /// Recorded, never trusted: classification sniffs the actual container later. This is
    /// what the provider claimed about the bytes it handed over, which is not the same as
    /// what the picker claimed about the item before it was loaded.
    public let suppliedContentTypeHint: ContentTypeHint?

    /// How the provider answered the typed request.
    public let form: SuppliedRepresentationForm

    public init(
        fileURL: URL,
        suppliedContentTypeHint: ContentTypeHint?,
        form: SuppliedRepresentationForm
    ) {
        self.fileURL = fileURL
        self.suppliedContentTypeHint = suppliedContentTypeHint
        self.form = form
    }
}

/// What the caller made of a borrowed representation before the window closed.
///
/// A `Result` rather than a throwing closure so the access implementation has nothing to
/// catch: it cannot swallow, translate, or replace a retention failure on the way out,
/// and the retention error the caller produced is the one the caller sees.
public typealias RetainedRepresentation = Result<
    ImportedEncodedAsset, EncodedAssetRetentionError
>

// MARK: - Faults the seam reports

/// Why the provider never produced a local representation.
///
/// Every case here happens before DefAIke has read a byte of the item, which the
/// requirements treat as a recoverable ingest attempt rather than a failed analysis:
/// ``AnalysisError`` deliberately has no category for it, and no Analysis Session exists
/// to fail. The cases exist so an audit can name which one happened.
///
/// Deliberately absent: any case meaning "loaded something else instead", and any way to
/// carry a framework error, a file path, or a user-visible message.
public enum PhotosProviderFault: Error, Hashable, Sendable, CaseIterable {
    /// The selected item no longer names anything the provider can load.
    case itemUnavailable

    /// The provider produced no representation, including because retrieving the asset
    /// itself did not complete — an iCloud fetch, for example.
    case representationUnavailable

    /// The provider reported a failure while producing the representation.
    case transferFailed

    /// The user cancelled while the representation was being retrieved.
    ///
    /// Kept separate from the three failures so cancellation is never reported as one:
    /// it is a distinct outcome, not an error category (Requirement 11.17).
    case cancelled
}

// MARK: - The seam

/// Loads one selected item's representation and lends it out for the length of the
/// provider's access window.
///
/// The only implementation that touches `PhotosUI` lives in the app composition, where
/// SwiftUI already is. Everything this module does with a representation is driven
/// through this protocol, so the one-item rule, the conservative preservation basis, the
/// no-session outcomes, and the streaming copy are all exercisable on a host with no
/// picker, no photo library, and no device.
public protocol PhotosRepresentationAccess: Sendable {
    /// Loads the representation ``PhotosRepresentationRequest`` names and calls `consume`
    /// with it while the provider's access window is open.
    ///
    /// The contract is the shape: this call does not return until `consume` has, and
    /// `consume` is the only place a ``BorrowedRepresentation`` exists. An implementation
    /// may reclaim the provider's file the moment `consume` returns, and a correct caller
    /// cannot tell the difference — which is exactly the property that keeps the copy
    /// inside the window (design, byte and image lifecycle).
    ///
    /// - Parameters:
    ///   - item: The single selected item. Selected-item access only; nothing here can
    ///     reach another asset in the library.
    ///   - consume: Called at most once, with the borrowed representation. Whatever it
    ///     produces is returned unchanged.
    /// - Returns: The value `consume` produced.
    /// - Throws: ``PhotosProviderFault`` when no representation was produced at all, in
    ///   which case `consume` is not called and no byte of the item was ever read.
    func withRepresentation(
        of item: PhotosPickerItemReference,
        consume: @Sendable (BorrowedRepresentation) async -> RetainedRepresentation
    ) async throws(PhotosProviderFault) -> RetainedRepresentation
}
