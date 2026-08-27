#if DEBUG

import DefAIkeDomain
import DefAIkeSharedTransfer
import Foundation

// ============================================================================================
// A DEVELOPMENT-ONLY data-protection applier. IT PROTECTS NOTHING.
// ============================================================================================
//
// `#if DEBUG` throughout, like the rest of the development seam. See
// `DevelopmentProvisioning.swift` for what that seam is and why none of it may ship.
//
// # The problem this exists for
//
// No Analysis Session can run on the iOS Simulator without it, and that is not a bug in the
// application. `PlatformDataProtection.createProtectedDirectory(at:level:)` sets the protection
// attribute and then reads it back, refusing with `protectionUnavailable` when the value does not
// return. The Simulator accepts the attribute and reports nothing back, because there is no
// hardware key hierarchy behind a simulated device — so every protected directory creation fails,
// and with it every ingest attempt, on either route. Measured: the Photos route refuses with
// `noLocalRepresentation(decodingError)`, and the underlying fault is
// `protectionUnavailable(.complete)`.
//
// That refusal is correct. Requirement 9.6 wants session bytes protected for their whole lifetime,
// `FileProtectionLevel` deliberately has no unprotected case, and the honest answer on a platform
// that cannot protect them is to refuse rather than to stage them anyway. Nothing about the
// shipping path is changed here.
//
// # What this type trades away, explicitly
//
// It applies the attribute best-effort and does not require it to read back. So on the Simulator
// the analysis path proceeds and **the encoded image bytes a session retains are genuinely
// unprotected**. That is a real privacy property given up, in exchange for being able to see the
// application's own progress and result screens locally.
//
// Three things keep the trade contained and visible:
//
//   1. **`enforcesDataProtection` is `false`.** It never claims otherwise, so
//      `ShareExtensionStartupGate`'s gate 7 still refuses, no store reports protected storage, and
//      no result obtained through this applier can be read as Requirement 9.6 evidence. This is
//      the same shape the host checks already use — see `RecordingDataProtection` in
//      `CompositionRootFidelityFixtures.swift`, which reports `false` for the same reason.
//   2. **Every use is logged.** A local run says out loud, per path, that it wrote through an
//      applier that protects nothing.
//   3. **It is unreachable outside DEBUG, and unreachable in DEBUG on a device.** The type is
//      inside `#if DEBUG`, and `DevelopmentProvisioning` only selects it under
//      `#if targetEnvironment(simulator)`. A DEBUG build on a physical iPhone gets
//      `PlatformDataProtection` and therefore the real guarantee.
//
// Replacing it is not a code change: run on a physical iPhone, where `PlatformDataProtection`
// applies and verifies the level the signed Extension Execution Policy asked for.

/// Applies the protection attribute without requiring the platform to honour it.
///
/// Deliberately not named `Lenient…` or `Relaxed…`: it protects nothing, and the name should say
/// so at every call site.
struct SimulatorDataProtection: DataProtectionApplying {

    /// Always `false`. The Simulator enforces nothing, and this type does not pretend otherwise.
    ///
    /// Load-bearing rather than cosmetic: it is the value the Share Extension's own gate reads to
    /// refuse, and the value every "no result here is Requirement 9.6 evidence" claim rests on.
    var enforcesDataProtection: Bool { false }

    func createProtectedDirectory(
        at url: URL,
        level: FileProtectionLevel
    ) throws(EphemeralStoreError) {
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            do {
                try manager.createDirectory(
                    at: url,
                    withIntermediateDirectories: true,
                    attributes: [.protectionKey: Self.attribute(for: level)]
                )
            } catch {
                // A directory that cannot be created at all is still a refusal: this type relaxes
                // the read-back check and nothing else.
                throw .storeUnavailable
            }
        }
        report("directory", url: url, level: level)
    }

    func createProtectedFile(
        at url: URL,
        level: FileProtectionLevel
    ) throws(EphemeralStoreError) {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: url.path) else {
            // Preserved exactly: overwriting an existing object is refused on every platform,
            // because it would make one object's bytes depend on another's lifetime.
            throw .storeUnavailable
        }
        guard manager.createFile(
            atPath: url.path,
            contents: nil,
            attributes: [.protectionKey: Self.attribute(for: level)]
        ) else {
            throw .storeUnavailable
        }
        report("file", url: url, level: level)
    }

    /// What the platform actually applied, which on the Simulator is nothing.
    ///
    /// Reports the real answer rather than the requested one. A caller that asks what level is on
    /// an object gets `nil`, so nothing can conclude from this applier that a level was applied.
    func appliedLevel(ofItemAt url: URL) -> FileProtectionLevel? {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let raw = attributes[.protectionKey] as? FileProtectionType
        else {
            return nil
        }
        return Self.level(for: raw)
    }

    /// The level one platform attribute value names, or `nil` when it is not a protected one.
    ///
    /// `FileProtectionLevel.init?(_: FileProtectionType)` exists but is internal to
    /// `DefAIkeSharedTransfer`, so the mapping is restated here rather than reached into. Total
    /// over the three protected cases and `nil` for everything else — in particular for
    /// `FileProtectionType.none`, so an unprotected object can never be reported as protected.
    private static func level(for attribute: FileProtectionType) -> FileProtectionLevel? {
        switch attribute {
        case .complete: .complete
        case .completeUnlessOpen: .completeUnlessOpen
        case .completeUntilFirstUserAuthentication: .completeUntilFirstUserAuthentication
        default: nil
        }
    }

    /// The platform attribute for one level.
    ///
    /// Duplicated from `FileProtectionLevel.fileProtectionType`, which is internal to
    /// `DefAIkeSharedTransfer`. Total over the three cases, so a new level cannot be silently
    /// mapped to a weaker one here either.
    private static func attribute(for level: FileProtectionLevel) -> FileProtectionType {
        switch level {
        case .complete: .complete
        case .completeUnlessOpen: .completeUnlessOpen
        case .completeUntilFirstUserAuthentication: .completeUntilFirstUserAuthentication
        }
    }

    /// Says out loud that something was written through an applier that protects nothing.
    ///
    /// The last path component only. Scope directories are named by the digest of the scope and
    /// objects by 128 random bits (Requirement 9.11), so a leaf name is not
    /// session-correlatable user content — but the full path would name the container, so it is
    /// not logged.
    private func report(_ kind: String, url: URL, level: FileProtectionLevel) {
        DevelopmentDiagnostics.emit(
            "unprotected-\(kind)-written",
            "requested \(level.rawValue), applied none, leaf \(url.lastPathComponent)"
        )
    }
}

#endif
