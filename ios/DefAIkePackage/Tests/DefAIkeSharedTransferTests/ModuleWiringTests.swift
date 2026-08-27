import Testing

@testable import DefAIkeSharedTransfer

/// Confirms the shared-transfer test target is wired to its module.
///
/// Retention and store behavior is covered by `ProtectedEphemeralFileStoreTests`,
/// `EncodedAssetRetentionTests`, and `StreamingSHA256Tests`; publication, claim, the
/// single ready slot, and startup cleanup by `SharedTransferStoreTests` and
/// `TransferManifestTests`; the Photos provider seam and import by
/// `PhotosImportAdapterTests`; the session roots and Privacy Controller deletion by
/// `ProtectedSessionDataDeleterTests`. The Share Extension and main-app handoff flows
/// arrive with tasks 4.4, 4.5, and 4.7 through 4.10.
@Suite("DefAIkeSharedTransfer module wiring")
struct ModuleWiringTests {
    @Test("Module marker identifies the shared transfer store")
    func moduleMarker() {
        #expect(DefAIkeSharedTransferModule.name == "DefAIkeSharedTransfer")
    }
}
