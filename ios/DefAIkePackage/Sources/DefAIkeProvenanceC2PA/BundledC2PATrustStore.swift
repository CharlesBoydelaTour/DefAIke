import CryptoKit
import DefAIkeDomain
import Foundation

/// The offline snapshot of the official C2PA conformance trust list bundled with DefAIke.
///
/// The snapshot is intentionally immutable and network-free. Updating it is an app release
/// change, not a runtime download. The descriptor in the active Provenance Policy must name
/// these exact bytes and this exact certificate count before they can configure a validator.
public enum BundledC2PATrustStore {
    /// Upstream `c2pa-org/conformance-public` revision used for this snapshot.
    public static let upstreamRevision = "2466172859fad1215f7aaf7e3768b41a0ac29abc"

    /// SHA-256 of `C2PA-TRUST-LIST.pem` at ``upstreamRevision``.
    public static let contentDigestHex =
        "75cacc98b79ecac33713c7ecfb58d4a0ef383f3c1f886e7409f9e37e8664aea5"

    /// Number of PEM certificates in the pinned snapshot.
    public static let anchorCount = 30

    /// Loads and verifies the bundled trust list against the descriptor the policy names.
    public static func material(
        matching descriptor: ProvenanceTrustStoreDescriptor
    ) -> C2PAOfflineTrustMaterial? {
        guard descriptor.isOfflineOnly,
              descriptor.anchorCount.value == anchorCount,
              descriptor.store.contentDigest.hexadecimalString == contentDigestHex,
              let url = Bundle.module.url(
                  forResource: "C2PA-TRUST-LIST",
                  withExtension: "pem",
                  subdirectory: "Trust"
              ),
              let data = try? Data(contentsOf: url)
        else {
            return nil
        }

        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == contentDigestHex else { return nil }

        let bytes = [UInt8](data)
        let certificateMarker = [UInt8]("-----BEGIN CERTIFICATE-----".utf8)
        guard Self.occurrenceCount(of: certificateMarker, in: bytes) == anchorCount else {
            return nil
        }
        return C2PAOfflineTrustMaterial(descriptor: descriptor, anchorBytes: bytes)
    }

    private static func occurrenceCount(of needle: [UInt8], in haystack: [UInt8]) -> Int {
        guard !needle.isEmpty, haystack.count >= needle.count else { return 0 }
        var count = 0
        var index = 0
        while index <= haystack.count - needle.count {
            if haystack[index..<(index + needle.count)].elementsEqual(needle) {
                count += 1
                index += needle.count
            } else {
                index += 1
            }
        }
        return count
    }
}
