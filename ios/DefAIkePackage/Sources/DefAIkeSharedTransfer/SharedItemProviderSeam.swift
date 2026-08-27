import DefAIkeDomain
import Foundation

// The one thing the Share route reaches out for, and the shape that makes the reach safe.
//
// A share activation arrives as extension items carrying item providers, and an item
// provider's file representation is a temporary file the framework owns and reclaims.
// Apple's file-loading contract is the same one the picker's `Transferable` file
// representation follows: the receiver copies the temporary representation into its own
// storage before returning from the callback (design, research findings 1 and 2). Two
// consequences drive everything below, and they are the same two that shaped
// ``PhotosRepresentationAccess``:
//
//   * The bytes have to be consumed inside the provider's access window. A URL that
//     outlives the window names nothing.
//   * Nothing about a real item provider, an extension item, or the consent screen can be
//     exercised on a host. So the framework call site stays outside this module entirely
//     and ``SharedItemRepresentationAccess`` is the seam, which is what makes the
//     activation, consent, and staging rules host-testable with no share sheet, no host
//     application, and no device.
//
// The window rule is structural rather than documented. There is no member here that
// returns a URL, a file handle, or a `Data`: the only way to see a representation is to be
// handed one inside a closure that the access call waits for.
//
// Deliberately absent, and each absence is the requirement:
//
//   * Any way to reach a second item, or to reach the activation's other providers.
//     Counting is the coordinator's, before a byte is read (Requirement 2.7).
//   * Any way to request a transcode, a resize, or a re-encode. The Share route hands over
//     the exact available encoded bytes, so there is no representation-altering request to
//     make (Requirements 2.3 and 11.12).
//   * Any way to open the host's file in place. ``SharedItemAccessPolicy`` has one case, so
//     a caller cannot ask to analyze a file DefAIke does not own.
//   * Any timeout, deadline, or retry.
//   * Any way to reach the user's consent decision. Consent is a separate seam, and a
//     value of this one cannot be obtained without one (Requirements 2.2 and 11.10).

// MARK: - What the request is allowed to say

/// What the Share route does with the host's temporary representation.
///
/// One case, on purpose. An item provider can hand over a file to be opened in place, and
/// accepting that would leave the analyzed bytes in a location the host application still
/// owns and can change underneath a running analysis. Copying into app-controlled storage
/// is the only representable answer, so there is no value to pass and no branch to take.
public enum SharedItemAccessPolicy: String, Hashable, Sendable, CaseIterable {
    /// The representation is copied into DefAIke's own protected storage.
    case copyIntoAppControlledStorage = "copy-into-app-controlled-storage"
}

/// The fixed representation request the Share route makes.
///
/// A namespace rather than a constructible value, because none of it is a caller's choice:
/// the design fixes the typed request and the copy-in policy, and the activation rule fixes
/// the item count. Exposing them as parameters would create the only things that could go
/// wrong here — a call site that asked for a generic representation, for an in-place file,
/// or for more than one item.
public enum SharedItemRepresentationRequest: Sendable {
    /// Container types a typed file representation is requested for, in preference order.
    ///
    /// The same Version 1 set the Photos route requests. It exists so the request can name
    /// a *typed* representation rather than accepting whatever generic form arrives first;
    /// it is not a validation rule. A representation outside this set is still staged, and
    /// the Input Validator refuses it by sniffing the actual container
    /// (Requirements 2.15 and 2.16).
    public static let requestedContainers: [RequestedImageContainer] =
        RequestedImageContainer.allCases

    /// What happens to the host's temporary file.
    public static let accessPolicy: SharedItemAccessPolicy = .copyIntoAppControlledStorage

    /// How many items one activation may hand off.
    ///
    /// The activation rule limits what is offered, and runtime counting stays
    /// authoritative anyway: ``ShareExtensionIngestCoordinator`` refuses any other count
    /// before a byte is read (Requirement 2.7).
    public static let maximumActivationItemCount = 1
}

// MARK: - What the provider hands back

/// How the item provider answered the typed representation request.
///
/// The two cases are the only distinction a file-loading provider actually supports, and
/// both establish the same thing about originality: nothing. A sharing application never
/// declares that the representation it exposes is the source's unmodified original, and it
/// never declares that it transcoded, so ``preservationBasis`` cannot reach
/// ``PreservationBasis/providerDeclaredOriginalRepresentation`` or
/// ``PreservationBasis/providerDeclaredTransformedRepresentation`` from either case.
public enum SharedRepresentationForm: String, Hashable, Sendable, CaseIterable {
    /// The provider supplied a representation typed as one of the requested containers.
    case typedFileRepresentation = "typed-file-representation"

    /// A file arrived, but the provider did not identify it as a requested container.
    case untypedFileRepresentation = "untyped-file-representation"

    /// The evidence this form provides for a ``BytePreservationStatus``.
    ///
    /// A typed answer establishes that these are the bytes the sharing application
    /// currently exposes and nothing more. An untyped answer establishes no history at
    /// all. Both bases are ``BytePreservationStatus/unknown``, which is the conservative
    /// record Requirement 2.11 asks for; they stay distinct so an audit can see which one
    /// the host actually gave.
    public var preservationBasis: PreservationBasis {
        switch self {
        case .typedFileRepresentation: .providerDeclaredCurrentRepresentationOnly
        case .untypedFileRepresentation: .preservationHistoryNotEstablished
        }
    }
}

/// One shared item's representation, borrowed from the host's provider.
///
/// Valid only for the duration of the closure it is handed to. It is never stored,
/// returned, or captured past that point: ``fileURL`` names a location the framework owns
/// and reclaims, so reading it later is reading nothing.
///
/// The source is opened for reading only. Nothing in DefAIke writes, truncates, moves, or
/// removes the host's file — that is the host's to reclaim.
///
/// There is deliberately no content-type hint here. The hint a published ticket records is
/// the one the *consented* provider declared, which ``SharedTransferStore`` reads from the
/// consent token itself; a second hint arriving with the bytes would be a field nothing may
/// read and a second source for one diagnostic value.
public struct BorrowedSharedRepresentation: Hashable, Sendable {
    /// The host's temporary file, valid only inside the access window.
    public let fileURL: URL

    /// How the provider answered the typed request.
    public let form: SharedRepresentationForm

    public init(fileURL: URL, form: SharedRepresentationForm) {
        self.fileURL = fileURL
        self.form = form
    }
}

/// What the caller made of a borrowed representation before the window closed.
///
/// A `Result` rather than a throwing closure so the access implementation has nothing to
/// catch: it cannot swallow, translate, or replace a staging failure on the way out, and
/// the failure the caller produced is the one the caller sees.
///
/// Success is a published ticket, because there is no intermediate value between staging
/// and publication for a caller to hold. Reaching the end of the window with a ticket means
/// exactly one pending session exists; reaching it with a failure means none does.
public typealias StagedRepresentation = Result<ShareTransferTicket, ShareStagingFailure>

// MARK: - Faults the seam reports

/// Why the host never produced a local representation.
///
/// Every case here happens before DefAIke has read a byte of the shared item, and before
/// any publication could have committed, so no Analysis Session exists to fail
/// (Requirement 2.4). The cases exist so an audit can name which one happened.
///
/// Deliberately absent: any case meaning "loaded something else instead", and any way to
/// carry a framework error, a file path, a host bundle identifier, or a user-visible
/// message.
public enum SharedItemProviderFault: Error, Hashable, Sendable, CaseIterable {
    /// The offered item no longer names anything the provider can load.
    case itemUnavailable

    /// The provider produced no representation at all, including because retrieving the
    /// underlying asset did not complete.
    case representationUnavailable

    /// The provider reported a failure while producing the representation.
    case transferFailed

    /// The user cancelled while the representation was being retrieved.
    ///
    /// Kept separate from the three failures so cancellation is never reported as one: it
    /// is a distinct outcome, not an error category (Requirement 11.17).
    case cancelled
}

// MARK: - The seam

/// Loads one shared item's representation and lends it out for the length of the provider's
/// access window.
///
/// The only implementation that touches an extension item or an item provider lives in the
/// Share Extension target, where the framework already is. Everything this module does with
/// a shared representation is driven through this protocol, so the one-provider rule, the
/// consent ordering, the conservative preservation basis, the no-session outcomes, and the
/// atomic publication are all exercisable on a host with no share sheet and no device.
public protocol SharedItemRepresentationAccess: Sendable {
    /// Loads the representation ``SharedItemRepresentationRequest`` names and calls
    /// `consume` with it while the provider's access window is open.
    ///
    /// The contract is the shape: this call does not return until `consume` has, and
    /// `consume` is the only place a ``BorrowedSharedRepresentation`` exists. An
    /// implementation may reclaim the host's file the moment `consume` returns, and a
    /// correct caller cannot tell the difference — which is exactly the property that keeps
    /// the copy inside the window (design, byte and image lifecycle).
    ///
    /// - Parameters:
    ///   - provider: The single provider the user consented to hand off. Nothing here can
    ///     reach another provider from the same activation.
    ///   - consume: Called at most once, with the borrowed representation. Whatever it
    ///     produces is returned unchanged.
    /// - Returns: The value `consume` produced.
    /// - Throws: ``SharedItemProviderFault`` when no representation was produced at all, in
    ///   which case `consume` is not called and no byte of the item was ever read.
    func withRepresentation(
        of provider: SharedItemProvider,
        consume: @Sendable (BorrowedSharedRepresentation) async -> StagedRepresentation
    ) async throws(SharedItemProviderFault) -> StagedRepresentation
}
