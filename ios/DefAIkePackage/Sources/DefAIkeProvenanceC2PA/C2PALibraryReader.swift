import DefAIkeDomain
import C2PA
import Foundation

// The only file in DefAIke that imports a provenance library.
//
// Everything vendor-specific is here: the exact-pinned `c2pa-swift` 0.0.12 API, its
// settings surface, its manifest JSON shape, and its validation status codes. The rest
// of the module is a pure function over ``C2PAReadOutcome``, so replacing or removing
// the library changes this file and nothing else — and a pixel-only composition does not
// link this module at all, which is what keeps a validator out of that binary
// (Requirements 6.19 and 6.20).
//
// Three properties of this file matter more than the code:
//
//   1. **Offline by configuration and by construction.** Every network-capable setting
//      the library exposes is turned off explicitly, the allowed-host list is emptied,
//      and a manifest that is referenced but not embedded is *reported* rather than
//      fetched. None of that is a policy choice: the Provenance Policy schema already
//      fixes `trustStore.isOfflineOnly` to `true` and
//      `revocation.permitsNetworkRevocationCheck` to `false`, and Requirement 6.8
//      requires validation to complete with connectivity disabled.
//
//   2. **No trust of its own.** The anchors come from ``C2PAOfflineTrustMaterial``,
//      which comes from the artifact the signed policy named. Nothing here contains,
//      embeds, or falls back to a certificate, a trust list, or a system store.
//
//   3. **Bounded before decoded.** The manifest JSON the library returns is
//      attacker-influenced, so it is checked against the policy's byte and depth
//      ceilings by ``ArtifactEncodingProfile`` in one pass *before* any field is read.
//
// Every security-relevant verification setting is explicit. The validator verifies the
// bundled C2PA trust list, performs strict v1 validation, resolves ingredient conflicts,
// and leaves timestamp trust disabled until a separately pinned TSA trust list is bundled.

/// Reads Content Credentials with exact-pinned `c2pa-swift` 0.0.12, offline.
public struct C2PALibraryReader: C2PAManifestReading {
    /// Security-sensitive library settings left to the vendor default.
    ///
    /// Empty by construction: every such setting supported by the reviewed SDK is set in
    /// ``applyOfflineSettings(trust:)``.
    public static let unreviewedLibraryDefaults: [String] = []

    /// The exact reviewed library version this adapter is written against.
    ///
    /// Compared against ``ProvenancePolicy/validatorImplementationVersion`` by
    /// ``ProvenanceLaneProvider/resolve(analyzer:policy:manifest:)`` before a lane can be
    /// enabled, so a build carrying a different library cannot present itself as the
    /// reviewed one.
    public static let reviewedImplementationVersion = "0.0.12"

    /// Serializes configure-then-read against the library's process-global settings.
    ///
    /// `c2pa_load_settings` mutates state for the whole process, so applying the approved
    /// trust material and then reading is only correct as one critical section: two
    /// interleaved reads could otherwise validate bytes under the other's configuration.
    /// A shipping session inspects one image at a time, so this never contends in
    /// practice; it is here because the alternative correctness argument depends on a
    /// caller's behavior rather than on this type's.
    private static let configurationLock = NSLock()

    public init() {}

    public func read(
        exactBytes bytes: [UInt8],
        limits: ProvenanceProcessingLimits,
        trust: C2PAOfflineTrustMaterial
    ) throws(C2PAReadFault) -> C2PAReadOutcome {
        guard let container = C2PAContainerSignature.container(of: bytes) else {
            return C2PAReadOutcome(
                status: .readerCondition(.containerNotSupported),
                binding: .notDetermined
            )
        }

        Self.configurationLock.lock()
        defer { Self.configurationLock.unlock() }

        do {
            try Self.applyOfflineSettings(trust: trust)
        } catch {
            // The library refused the approved trust material or the offline settings, so
            // nothing was validated under the policy that was supposed to be in force.
            // That is a defect rather than a finding about the image, so it leaves as a
            // fault instead of becoming a state.
            throw .validatorNotConfigurable
        }

        let manifestJSON: String
        let isEmbedded: Bool
        do {
            // The reader and its stream are created, used, and released inside this one
            // synchronous scope. Neither is `Sendable`, and neither escapes.
            //
            // `Data(bytes)` is a second copy of the encoded image, because the library's
            // stream takes `Data`. That doubled peak allocation is a real resource cost
            // and is one of the figures the Provenance Feasibility Gate's device
            // measurements have to account for; it is not something an approved budget
            // has covered yet.
            let stream = try Stream(data: Data(bytes))
            let reader = try Reader(format: container.mimeType, stream: stream)
            isEmbedded = reader.isEmbedded()
            manifestJSON = try reader.json()
        } catch {
            // Every library error is one of two conditions. A reader that cannot be
            // constructed over a supported container has found no Content Credential to
            // validate; anything else is an input the validator refused. Neither is an
            // evidence state, and the library's message is deliberately discarded rather
            // than carried: a diagnostic built from image bytes is exactly what
            // Requirement 9.11 keeps out of a session.
            return C2PAReadOutcome(
                status: .readerCondition(Self.condition(for: error)),
                binding: .notDetermined
            )
        }

        guard isEmbedded else {
            // A remote manifest would have to be fetched, which Requirement 6.8 forbids.
            // The condition is reported; the network is not touched.
            return C2PAReadOutcome(
                status: .readerCondition(.manifestNotEmbedded),
                binding: .notDetermined
            )
        }

        return try Self.outcome(fromManifestJSON: manifestJSON, limits: limits)
    }

    // MARK: - Offline configuration

    /// Applies the approved anchors and turns off every network-capable setting.
    ///
    /// `c2pa_load_settings` is process-global, so this runs before each read rather than
    /// once at construction: a validator must never inspect bytes under settings some
    /// other caller left behind.
    private static func applyOfflineSettings(trust: C2PAOfflineTrustMaterial) throws {
        guard let anchors = String(bytes: trust.anchorBytes, encoding: .utf8) else {
            throw C2PAReaderConfigurationError.trustAnchorsNotUTF8
        }
        let definition = C2PASettingsDefinition(
            version: 1,
            trust: TrustSettings(
                verifyTrustList: true,
                userAnchors: anchors,
                trustAnchors: anchors
            ),
            core: CoreSettings(allowedNetworkHosts: []),
            verify: VerifySettings(
                verifyAfterReading: true,
                verifyTrust: true,
                verifyTimestampTrust: false,
                ocspFetch: false,
                remoteManifestFetch: false,
                skipIngredientConflictResolution: false,
                strictV1Validation: true
            )
        )
        _ = try C2PASettings(definition: definition)
    }

    private enum C2PAReaderConfigurationError: Error {
        case trustAnchorsNotUTF8
    }

    /// Codes the native library uses for "this asset carries no Content Credential".
    ///
    /// `C2PAError.api` carries the Rust error's own text rather than a structured code, so
    /// absence has to be recognized by that text. Both spellings are the C2PA reference
    /// implementation's names for a missing manifest store: `ManifestNotFound` when no
    /// manifest is present and `JumbfNotFound` when the asset carries no JUMBF box to
    /// hold one.
    ///
    /// Matching on a message is brittle by nature, and the fail-closed direction is
    /// chosen deliberately: an unrecognized message becomes
    /// ``C2PAReaderCondition/inputNotParsable`` rather than absence, so a message this
    /// build does not know can never be presented as "no provenance evidence found"
    /// (Requirements 6.11 and 8.7). Confirming both spellings against the reviewed binary
    /// is a Provenance Feasibility Gate fixture item.
    static let absentManifestErrorMarkers = ["ManifestNotFound", "JumbfNotFound"]

    /// Which read condition a library error is.
    private static func condition(for error: any Error) -> C2PAReaderCondition {
        let message = String(describing: error)
        return absentManifestErrorMarkers.contains(where: message.contains)
            ? .noManifestFound
            : .inputNotParsable
    }

    // MARK: - Bounded manifest projection

    /// Turns one manifest-store JSON document into a bounded read outcome.
    ///
    /// The document is validated against the policy's ceilings in one pass first, so a
    /// decompression bomb, a deeply nested manifest, or a duplicate key meets a declared
    /// limit before anything is allocated per field.
    private static func outcome(
        fromManifestJSON json: String,
        limits: ProvenanceProcessingLimits
    ) throws(C2PAReadFault) -> C2PAReadOutcome {
        let payload = [UInt8](json.utf8)
        let encodingLimits = ArtifactEncodingLimits(
            maximumByteCount: limits.maximumManifestByteCount,
            maximumNestingDepth: limits.maximumNestingDepth.value
        )

        let report: ArtifactEncodingReport
        do {
            report = try ArtifactEncodingProfile.validate(payload, limits: encodingLimits)
        } catch {
            switch error {
            case let .payloadTooLarge(limitBytes, actualBytes):
                throw .limitExceeded(
                    .manifestByteCount(observed: actualBytes, limit: limitBytes)
                )
            case let .nestingTooDeep(limit, _):
                // The one-pass scan stops at the first level past the ceiling and reports
                // the ceiling, not how deep the document actually goes, so the observed
                // depth is the smallest value consistent with the breach. Reading further
                // to find the true depth is the unbounded parse the ceiling prevents.
                throw .limitExceeded(.nestingDepth(observed: limit + 1, limit: limit))
            default:
                // The library produced output its own reader cannot describe as a bounded
                // document. Nothing was projected, so there is no manifest to report on.
                return C2PAReadOutcome(
                    status: .readerCondition(.validationResultAbsent),
                    binding: .notDetermined
                )
            }
        }

        guard let store = C2PAManifestStoreProjection(json: json) else {
            return C2PAReadOutcome(
                status: .readerCondition(.validationResultAbsent),
                binding: .notDetermined
            )
        }

        return C2PAReadOutcome(
            status: store.statusFinding,
            binding: store.bindingFinding,
            failedCheck: store.firstFailureCode.flatMap(
                C2PAFailureClassification.category(forLibraryCode:)
            ),
            manifestByteCount: report.byteCount,
            manifestNestingDepth: report.observedNestingDepth,
            signerDetails: store.signerDetails,
            assertionLabels: store.assertionLabels,
            unsupportedFeatures: store.unsupportedFeatures
        )
    }
}

// MARK: - Container signature

/// Recognizes the four static containers Version 1 accepts, by their leading bytes.
///
/// The vendor API has to be told which format it is reading, and the only trustworthy
/// source is the bytes themselves: ``ContentTypeHint`` is a provider claim and is never
/// consulted here or anywhere else. The check is over the byte prefix only, so it is a
/// factual recognition rather than a decision about what is supported —
/// ``StaticContainer`` is where that is decided, in the domain.
///
/// This duplicates the `ftyp` brand grouping in the image pipeline's content sniffer
/// deliberately: this module's dependency rule is `DefAIkeDomain` and
/// `DefAIkeProvenanceAPI`, so it cannot reach that sniffer, and the provenance lane
/// must not be able to change what the pixel lane classified. The two agree on brands by
/// construction because both enumerate the same fixed list; a brand this table does not
/// list yields no container, which reports
/// ``C2PAReaderCondition/containerNotSupported`` rather than guessing a format.
enum C2PAContainerSignature {
    private static let jpegPrefix: [UInt8] = [0xFF, 0xD8, 0xFF]
    private static let pngPrefix: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// ISO base media brands the image pipeline groups as HEIC, including the image
    /// sequence brands.
    private static let heicBrands: Set<String> = [
        "heic", "heix", "heim", "heis", "hevc", "hevx", "hevm", "hevs", "msf1",
    ]

    /// ISO base media brands the image pipeline groups as HEIF.
    private static let heifBrands: Set<String> = ["mif1", "mif2", "miaf"]

    static func container(of bytes: [UInt8]) -> StaticContainer? {
        if bytes.starts(with: jpegPrefix) { return .jpeg }
        if bytes.starts(with: pngPrefix) { return .png }
        guard ascii(bytes, at: 4, count: 4) == "ftyp",
              let brand = ascii(bytes, at: 8, count: 4)
        else {
            return nil
        }
        if heicBrands.contains(brand) { return .heic }
        if heifBrands.contains(brand) { return .heif }
        return nil
    }

    /// The ASCII text at a fixed offset, or `nil` when the prefix is short or not ASCII.
    private static func ascii(_ bytes: [UInt8], at offset: Int, count: Int) -> String? {
        guard bytes.count >= offset + count else { return nil }
        let window = bytes[offset..<(offset + count)]
        guard window.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
        return String(decoding: window, as: UTF8.self)
    }
}

extension StaticContainer {
    /// The media type the validator identifies this container by.
    ///
    /// The four values are the registered media types for the four containers, not a
    /// choice: a wrong one would make the validator read the asset with the wrong handler.
    var mimeType: String {
        switch self {
        case .jpeg: "image/jpeg"
        case .png: "image/png"
        case .heic: "image/heic"
        case .heif: "image/heif"
        }
    }
}
