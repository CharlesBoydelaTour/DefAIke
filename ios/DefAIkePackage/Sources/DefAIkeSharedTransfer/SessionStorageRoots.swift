import DefAIkeDomain
import Foundation

// The app-controlled file-system namespaces that hold session material.
//
// The design says deletion "means removal from all app-controlled file-system
// namespaces", so the Privacy Controller has to be able to name every one of them. There
// are exactly two, and they exist for different reasons:
//
//   * **App-private.** The main app's own container holds everything one Analysis Session
//     retains: the encoded copy, and any object a later stage writes. The Share Extension
//     never reads it, so it is the correct home for material that must not cross a process
//     boundary.
//   * **App Group.** The container both processes can reach. Its `transfers` subtree is
//     the handoff protocol's, owned by ``SharedTransferStore``. Its `sessions` subtree
//     exists because the main app resumes a claimed handoff *as a session*, and because a
//     terminated extension can leave session-shaped material there that the next start has
//     to remove (Requirement 11.16).
//
// The two subtrees are siblings rather than one shared directory, so the session lifecycle
// and the transfer lifecycle cannot delete each other's bytes: a pending handoff the user
// consented to survives a restart, and session material never does.
//
// No root is created here. Creating one is the store's job, because the store applies the
// approved data-protection level at creation and a directory that existed for even one
// moment without that level would be a gap in Requirement 9.6.

/// Where the Privacy Controller's session material lives.
public enum SessionStorageRoots {

    /// Directory name the session store owns inside whichever container holds it.
    ///
    /// Fixed and non-user-derived, like ``AppGroupContainer/transferDirectoryName``.
    /// Everything below it is named by the store: scope directories by the digest of the
    /// scope, objects by 128 random bits (Requirement 9.11).
    public static let sessionDirectoryName = "sessions"

    /// The app-private session root.
    ///
    /// `temporaryDirectory` defaults to this process's own temporary directory, which on
    /// iOS is inside the application's sandbox container and is therefore unreachable from
    /// the Share Extension and from every other application. It is a parameter only so a
    /// test can own its root; there is no configuration that moves session material
    /// outside the app container.
    public static func appPrivateRoot(
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> URL {
        temporaryDirectory.appending(path: sessionDirectoryName, directoryHint: .isDirectory)
    }

    /// The App Group session root, or a failure.
    ///
    /// Fails closed for exactly the reason ``AppGroupContainer/transferRoot(forAppGroup:)``
    /// does: an unresolvable container means the App Group is not registered for this
    /// build, and falling back to a process-private directory would leave session material
    /// in a location this lifecycle does not own.
    public static func appGroupRoot(
        forAppGroup appGroupID: String
    ) throws(AppGroupContainer.ResolutionError) -> URL {
        try AppGroupContainer.container(forAppGroup: appGroupID)
            .appending(path: sessionDirectoryName, directoryHint: .isDirectory)
    }
}
