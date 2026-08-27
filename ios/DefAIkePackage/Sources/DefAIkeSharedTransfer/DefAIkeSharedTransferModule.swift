/// Boundary marker for the coordinated App Group transfer store.
///
/// Responsibility: transfer ticket schema, streaming copy and SHA-256 hashing,
/// file protection, `staging` → `ready` → `claimed` directory states, atomic
/// publication and claim, single-ready-slot policy, and startup cleanup driven
/// by the injected Data Lifecycle Policy.
///
/// Dependency rule: `DefAIkeDomain` only, plus Foundation and CryptoKit. This
/// module ships in both the main app and the Share Extension, so it must never
/// reach inference, model-bundle, image-pipeline, provenance, or presentation
/// code.
///
/// Present: ``StreamingSHA256``, ``PlatformDataProtection``,
/// ``ProtectedEphemeralFileStore``, ``EncodedAssetRetainer``, and
/// ``SystemSessionClock`` — protected retention of encoded bytes and the
/// streaming integrity measurements taken while copying them (task 4.1) — plus
/// ``AppGroupContainer`` and ``SharedTransferStore``, the coordinated
/// `staging` → `ready` → `claimed` publication and claim protocol with its
/// bounded manifest encoding, single-ready-slot rule, and policy-driven startup
/// cleanup (task 4.3), plus ``PhotosRepresentationAccess`` and
/// ``PhotosImportAdapter``, the Photos route's provider seam and the import that
/// streams one selected item into protected session storage inside the
/// provider's access window (task 4.2).
///
/// The Photos seam is a protocol, not an implementation: `PhotosUI` is never
/// imported here, so nothing SwiftUI- or iOS-shaped reaches the Share
/// Extension, and the one call site that touches the picker lives in the app
/// composition.
///
/// Also present: ``SessionStorageRoots`` and ``ProtectedSessionDataDeleter``,
/// the Privacy Controller's side of the byte lifecycle — the app-private and
/// App Group session roots, terminal removal of everything one session owns
/// under the deadline its terminal reason selects, verified-complete deletion,
/// and the startup sweep whose failure keeps ingest closed (task 10.3).
///
/// Also present: ``SharedItemRepresentationAccess``, ``ShareActivation``,
/// ``ShareConsentPresenting``, ``ManualOpenInstruction``, and
/// ``ShareExtensionIngestCoordinator`` — the Share Extension's activation,
/// consent, and staging flow (task 4.4). It enforces one provider before a byte
/// is read, reaches the provider only through a ``ConfirmedConsent``, streams
/// the exact available bytes through ``EncodedAssetRetainer`` into protected
/// staging, drives ``SharedTransferStore``'s single atomic publication, and ends
/// with the manual "Open DefAIke" instruction as approved copy rather than a
/// programmatic launch. The item-provider and consent surfaces are protocols:
/// no extension item, item provider, or consent view is constructed here, so
/// nothing UIKit- or extension-shaped enters the module and the one framework
/// call site lives in the Share Extension target.
///
/// Still to come: the main app's claim verification and session resumption
/// (task 4.5), which builds on ``SharedTransferStore/claimReadyTransfer()`` and
/// owns the recopy, the second digest, and the compatibility comparison behind
/// the `handoff-error` outcome.
public enum DefAIkeSharedTransferModule: Sendable {
    /// Stable module identifier used by module-boundary and release-audit checks.
    public static let name = "DefAIkeSharedTransfer"
}
