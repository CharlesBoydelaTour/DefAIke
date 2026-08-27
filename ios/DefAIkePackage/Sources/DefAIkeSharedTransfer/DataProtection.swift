import DefAIkeDomain
import Foundation

// Applying iOS Data Protection to every ephemeral file this module creates.
//
// Requirement 9.6 requires ephemeral analysis files to be stored with iOS data
// protection while they exist. Two consequences shape this file:
//
//   * Protection is applied *at creation*, not afterwards. Creating a file and then
//     setting its protection level leaves a window in which encoded image bytes exist
//     unprotected, and the requirement is about the whole time the file exists.
//   * There is no unprotected fallback. ``FileProtectionLevel`` has no `.none` case, and
//     a level that cannot be applied is ``EphemeralStoreError/protectionUnavailable(_:)``
//     rather than a downgrade.
//
// The protection attribute is only *enforced* by iOS. Other platforms accept and report
// the same attribute without hardware-backed enforcement, which is why
// ``DataProtectionApplying/enforcesDataProtection`` exists: the code path is identical
// and fully compiled everywhere, and the honest answer to "is this protected storage?"
// is a value a startup gate can check rather than a comment nobody reads.

/// Creates protected files and directories, or fails closed.
///
/// Injected rather than called directly so a test can drive the fail-closed path without
/// a device that refuses a protection level.
public protocol DataProtectionApplying: Sendable {
    /// Whether this applier's platform enforces iOS Data Protection.
    ///
    /// `false` means files carry the requested attribute but the platform does not
    /// enforce it. A development host is in that position, and a host run is therefore
    /// never Requirement 9.6 evidence.
    var enforcesDataProtection: Bool { get }

    /// Creates a directory at `url` with `level` applied from the moment it exists.
    ///
    /// Succeeds when the directory already exists and already carries `level`.
    func createProtectedDirectory(
        at url: URL,
        level: FileProtectionLevel
    ) throws(EphemeralStoreError)

    /// Creates an empty file at `url` with `level` applied from the moment it exists.
    ///
    /// Fails when a file already exists at `url`: overwriting would discard bytes an
    /// existing handle may still describe.
    func createProtectedFile(
        at url: URL,
        level: FileProtectionLevel
    ) throws(EphemeralStoreError)

    /// The protection level currently applied to the item, or `nil` when the item is
    /// missing or carries no readable level.
    func appliedLevel(ofItemAt url: URL) -> FileProtectionLevel?
}

/// Applies data protection through the platform's file system.
///
/// Every level in ``FileProtectionLevel`` maps to exactly one `FileProtectionType`, and
/// every creation is verified by reading the attribute back. An attribute that does not
/// read back as requested is treated as unavailable, so "the call did not throw" is not
/// mistaken for "the bytes are protected".
public struct PlatformDataProtection: DataProtectionApplying {
    public init() {}

    public var enforcesDataProtection: Bool {
        #if targetEnvironment(simulator)
        // The Simulator is not iOS for this purpose, and saying otherwise was a false claim.
        //
        // It accepts `setAttributes` with a protection key and then reports no protection key back
        // — measured, not assumed: `createProtectedDirectory` creates the directory and
        // `appliedLevel(ofItemAt:)` returns `nil` for it, so `verify` refuses with
        // `protectionUnavailable`. There is no hardware key hierarchy behind a simulated device,
        // so there is nothing for Data Protection to be enforced by.
        //
        // This matters beyond honesty. `ShareExtensionStartupGate`'s gate 7 refuses unless the
        // store reports that the platform enforces what the policy asked for. With `os(iOS)` this
        // property answered `true` in the Simulator, so that gate would have *passed* on a
        // platform that protects nothing — a Simulator run standing in for a device privacy gate,
        // which is exactly what this property exists to prevent.
        false
        #elseif os(iOS)
        true
        #else
        // The attribute is accepted and reported here, but only iOS backs it with Data
        // Protection. Reporting `true` would let a host result stand in for a device
        // privacy gate.
        false
        #endif
    }

    public func createProtectedDirectory(
        at url: URL,
        level: FileProtectionLevel
    ) throws(EphemeralStoreError) {
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) {
            // Already present. Do not assume it inherited the level: an interrupted
            // earlier run, or a directory created by another component, may carry
            // something else.
            try verify(level, at: url)
            return
        }
        do {
            try manager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: Self.creationAttributes(for: level)
            )
        } catch {
            throw .storeUnavailable
        }
        try verify(level, at: url)
    }

    public func createProtectedFile(
        at url: URL,
        level: FileProtectionLevel
    ) throws(EphemeralStoreError) {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: url.path) else {
            throw .storeUnavailable
        }
        guard manager.createFile(
            atPath: url.path,
            contents: nil,
            attributes: Self.creationAttributes(for: level)
        ) else {
            throw .storeUnavailable
        }
        do {
            try verify(level, at: url)
        } catch {
            // A file that exists without its protection level must not survive this
            // call: leaving it would leave unprotected storage behind.
            try? manager.removeItem(at: url)
            throw error
        }
    }

    public func appliedLevel(ofItemAt url: URL) -> FileProtectionLevel? {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let raw = attributes[.protectionKey] as? FileProtectionType
        else {
            return nil
        }
        return FileProtectionLevel(raw)
    }

    private func verify(
        _ level: FileProtectionLevel,
        at url: URL
    ) throws(EphemeralStoreError) {
        guard appliedLevel(ofItemAt: url) == level else {
            throw .protectionUnavailable(level)
        }
    }

    private static func creationAttributes(
        for level: FileProtectionLevel
    ) -> [FileAttributeKey: Any] {
        [.protectionKey: level.fileProtectionType]
    }
}

extension FileProtectionLevel {
    /// The platform attribute value for this level.
    ///
    /// Total in both directions and injective, so a level cannot be silently widened to a
    /// weaker one. No case maps to `FileProtectionType.none`.
    var fileProtectionType: FileProtectionType {
        switch self {
        case .complete: .complete
        case .completeUnlessOpen: .completeUnlessOpen
        case .completeUntilFirstUserAuthentication: .completeUntilFirstUserAuthentication
        }
    }

    /// The level for a platform attribute value, or `nil` when it is not one of the three
    /// protected levels the policy vocabulary allows.
    init?(_ fileProtectionType: FileProtectionType) {
        switch fileProtectionType {
        case .complete: self = .complete
        case .completeUnlessOpen: self = .completeUnlessOpen
        case .completeUntilFirstUserAuthentication: self = .completeUntilFirstUserAuthentication
        default: return nil
        }
    }
}
