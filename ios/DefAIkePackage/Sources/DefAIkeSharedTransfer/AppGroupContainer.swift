import DefAIkeDomain
import Foundation

// Locating the one directory both processes can reach.
//
// The Share Extension and the main app are separate processes with separate private
// containers, so the only place a handoff can happen is the registered App Group container.
// Resolving it has exactly one failure mode worth naming: the container is unavailable,
// because the App Group is not registered for this build or the entitlement is missing.
//
// That failure must not be recovered from. A fallback to the process's own temporary
// directory would look like it worked — staging would succeed, a ticket would be published,
// and the other process would find an empty ready slot forever, with encoded image bytes
// left in a location the handoff lifecycle does not own. So there is no fallback: an
// unavailable container keeps the transfer route unavailable.

/// The registered App Group container that holds the transfer store.
public enum AppGroupContainer {

    /// Why the App Group container could not be resolved.
    public enum ResolutionError: Error, Hashable, Sendable {
        /// The system reports no container for this identifier.
        ///
        /// The App Group is not registered for this build, or the entitlement is absent.
        /// Carries only the identifier, which is a build constant rather than user content.
        case containerUnavailable(appGroupID: String)
    }

    /// Directory name the transfer store owns inside the container.
    ///
    /// Fixed and non-user-derived. Everything below it is named by the store: scope
    /// directories by the digest of the scope, objects by 128 random bits.
    public static let transferDirectoryName = "transfers"

    /// The registered container itself, or a failure.
    ///
    /// The one place the entitlement is consulted, so every directory the two processes
    /// share fails closed for the same reason and in the same way.
    public static func container(
        forAppGroup appGroupID: String
    ) throws(ResolutionError) -> URL {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else {
            throw .containerUnavailable(appGroupID: appGroupID)
        }
        return container
    }

    /// The directory the transfer store should be rooted at, or a failure.
    ///
    /// The directory is not created here. Creating it is the store's job, because the store
    /// applies the approved data-protection level at creation and a directory created
    /// without that level would be a window in which staged bytes exist unprotected
    /// (Requirement 9.6).
    public static func transferRoot(
        forAppGroup appGroupID: String
    ) throws(ResolutionError) -> URL {
        try container(forAppGroup: appGroupID)
            .appending(path: transferDirectoryName, directoryHint: .isDirectory)
    }
}
