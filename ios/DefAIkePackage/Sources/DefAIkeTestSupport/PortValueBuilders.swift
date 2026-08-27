import DefAIkeDomain
import Foundation

/// Builders for the port values a test needs to drive a double.
///
/// Deliberately narrow: these build *port* values — identifiers, tokens, handles, assets,
/// images, model inputs — and never a policy, budget, boundary, mapping, or gate record.
/// Artifact samples belong beside the artifact tests, so nothing here can quietly become
/// the source of an unapproved default.
///
/// Every builder traps on invalid input rather than returning an optional. A test fixture
/// that cannot be constructed is an authoring mistake, and trapping at the fixture keeps
/// the failure message pointed at the fixture instead of at the assertion downstream.
public enum PortValue {

    // MARK: - Identifiers

    public static func sessionID(_ raw: String = "session-0001") -> AnalysisSessionID {
        guard let id = AnalysisSessionID(raw) else {
            preconditionFailure("session identifier is not canonical: \(raw)")
        }
        return id
    }

    public static func transferID(_ raw: String = "transfer-0001") -> ShareTransferID {
        guard let id = ShareTransferID(raw) else {
            preconditionFailure("transfer identifier is not canonical: \(raw)")
        }
        return id
    }

    public static func appBuildID(_ raw: String = "build-0001") -> AppBuildID {
        guard let id = AppBuildID(raw) else {
            preconditionFailure("app build identifier is not canonical: \(raw)")
        }
        return id
    }

    public static func artifactID(_ raw: String = "artifact-0001") -> ArtifactID {
        guard let id = ArtifactID(raw) else {
            preconditionFailure("artifact identifier is not canonical: \(raw)")
        }
        return id
    }

    public static func bundleID(_ raw: String = "bundle-0001") -> ModelBundleID {
        guard let id = ModelBundleID(raw) else {
            preconditionFailure("bundle identifier is not canonical: \(raw)")
        }
        return id
    }

    public static func configurationID(
        _ raw: String = "configuration-0001"
    ) -> ApprovedConfigurationID {
        guard let id = ApprovedConfigurationID(raw) else {
            preconditionFailure("configuration identifier is not canonical: \(raw)")
        }
        return id
    }

    public static func storageKey(_ raw: String = "eph-00000001") -> EphemeralStorageKey {
        guard let key = EphemeralStorageKey(raw) else {
            preconditionFailure("storage key is not canonical: \(raw)")
        }
        return key
    }

    public static func contentTypeHint(_ raw: String = "public.jpeg") -> ContentTypeHint {
        guard let hint = ContentTypeHint(raw) else {
            preconditionFailure("content type hint is not acceptable: \(raw)")
        }
        return hint
    }

    // MARK: - Bytes

    /// A deterministic byte pattern of `count` bytes.
    ///
    /// Distinguishable rather than uniform, so a truncation or a reordering changes the
    /// digest and a byte-identity assertion actually bites.
    public static func bytes(count: Int, seed: UInt8 = 1) -> [UInt8] {
        precondition(count >= 0, "byte count cannot be negative")
        return (0..<count).map { index in
            UInt8(truncatingIfNeeded: index &* 31 &+ Int(seed))
        }
    }

    /// The digest of `bytes`, using the test SHA-256.
    public static func digest(of bytes: [UInt8]) -> SHA256Digest {
        TestSHA256.digest(of: bytes)
    }

    // MARK: - Handles and assets

    /// A handle describing `bytes` without writing them anywhere.
    ///
    /// For pure value tests. Anything that reads the bytes back should write them into an
    /// ``InMemoryEphemeralStore`` and build a handle from the receipt instead.
    public static func handle(
        sessionID: AnalysisSessionID = PortValue.sessionID(),
        bytes: [UInt8],
        storageKey: EphemeralStorageKey = PortValue.storageKey(),
        protection: FileProtectionLevel = .complete
    ) -> EncodedAssetHandle {
        guard let handle = EncodedAssetHandle(
            sessionID: sessionID,
            storageKey: storageKey,
            byteCount: UInt64(bytes.count),
            sha256: digest(of: bytes),
            protection: protection
        ) else {
            preconditionFailure("an encoded asset handle needs at least one byte")
        }
        return handle
    }

    /// An accepted ingest for `route`.
    ///
    /// The default status and basis are the most conservative pair, matching what ingest
    /// records when preservation history cannot be established.
    public static func asset(
        route: InputRoute = .photosPicker,
        sessionID: AnalysisSessionID = PortValue.sessionID(),
        bytes: [UInt8] = PortValue.bytes(count: 128),
        preservationStatus: BytePreservationStatus = .unknown,
        preservationBasis: PreservationBasis = .preservationHistoryNotEstablished,
        contentTypeHint: ContentTypeHint? = PortValue.contentTypeHint()
    ) -> ImportedEncodedAsset {
        guard let asset = ImportedEncodedAsset(
            route: route,
            handle: handle(sessionID: sessionID, bytes: bytes),
            preservationStatus: preservationStatus,
            preservationBasis: preservationBasis,
            contentTypeHint: contentTypeHint
        ) else {
            preconditionFailure(
                "preservation status \(preservationStatus) is not supported by basis "
                    + "\(preservationBasis)"
            )
        }
        return asset
    }

    /// An accepted ingest built from a store receipt, so the bytes are readable.
    public static func asset(
        route: InputRoute,
        receipt: EphemeralWriteReceipt,
        preservationStatus: BytePreservationStatus = .unknown,
        preservationBasis: PreservationBasis = .preservationHistoryNotEstablished,
        contentTypeHint: ContentTypeHint? = nil
    ) -> ImportedEncodedAsset {
        guard case .session(let sessionID) = receipt.scope else {
            preconditionFailure("an accepted ingest needs a session-owned receipt")
        }
        guard let handle = EncodedAssetHandle(sessionID: sessionID, receipt: receipt),
              let asset = ImportedEncodedAsset(
                  route: route,
                  handle: handle,
                  preservationStatus: preservationStatus,
                  preservationBasis: preservationBasis,
                  contentTypeHint: contentTypeHint
              )
        else {
            preconditionFailure("could not build an accepted ingest from the receipt")
        }
        return asset
    }

    // MARK: - Picker and share references

    public static func pickerItem(
        token: UInt64 = 1,
        contentTypeHint: ContentTypeHint? = PortValue.contentTypeHint()
    ) -> PhotosPickerItemReference {
        PhotosPickerItemReference(
            token: ProviderToken(rawValue: token),
            contentTypeHint: contentTypeHint
        )
    }

    /// A selection of `count` items, for one-item-rule tests.
    public static func pickerSelection(itemCount count: Int) -> PhotosPickerSelection {
        PhotosPickerSelection(
            items: (0..<max(count, 0)).map { pickerItem(token: UInt64($0 + 1)) }
        )
    }

    public static func sharedItemProvider(
        token: UInt64 = 1,
        itemCount: Int = 1,
        contentTypeHint: ContentTypeHint? = PortValue.contentTypeHint()
    ) -> SharedItemProvider {
        guard let provider = SharedItemProvider(
            token: ProviderToken(rawValue: token),
            itemCount: itemCount,
            contentTypeHint: contentTypeHint
        ) else {
            preconditionFailure("a shared item provider cannot offer \(itemCount) items")
        }
        return provider
    }

    /// Consent for `provider`.
    ///
    /// Returns `nil` when the provider does not offer exactly one item, which is the case
    /// a test asserts on: a multi-item activation can never produce consent, so it can
    /// never reach the bytes.
    public static func consent(
        for provider: SharedItemProvider,
        policyID: ArtifactID = PortValue.artifactID("extension-execution-0001"),
        at instant: Date = VirtualSessionClock.defaultStart
    ) -> ConfirmedConsent? {
        ConfirmedConsent(
            provider: provider,
            extensionExecutionPolicyID: policyID,
            confirmedAt: instant
        )
    }

    // MARK: - Images

    public static func dimensions(width: Int, height: Int) -> PixelDimensions {
        guard let dimensions = PixelDimensions(width: width, height: height) else {
            preconditionFailure("pixel dimensions must be positive: \(width)x\(height)")
        }
        return dimensions
    }

    public static func validatedImage(
        sessionID: AnalysisSessionID = PortValue.sessionID(),
        source: EncodedAssetHandle? = nil,
        container: StaticContainer = .jpeg,
        width: Int = 800,
        height: Int = 600,
        decodedImageToken: UInt64 = 1,
        preprocessingContractID: ArtifactID = PortValue.artifactID("preprocessing-0001"),
        additionalQualityFeatures: [QualityFeatureID: ValidatedQualityValue] = [:]
    ) -> ValidatedImage {
        ValidatedImage(
            sessionID: sessionID,
            source: source ?? handle(sessionID: sessionID, bytes: bytes(count: 128)),
            container: container,
            dimensions: dimensions(width: width, height: height),
            decodedImage: DecodedImageToken(rawValue: decodedImageToken),
            preprocessingContractID: preprocessingContractID,
            additionalQualityFeatures: additionalQualityFeatures
        )
    }

    public static func modelInput(
        sessionID: AnalysisSessionID = PortValue.sessionID(),
        bufferToken: UInt64 = 1,
        preprocessingContractID: ArtifactID = PortValue.artifactID("preprocessing-0001")
    ) -> ModelImageInput {
        guard let input = ModelImageInput(
            sessionID: sessionID,
            buffer: ModelInputToken(rawValue: bufferToken),
            edge: CenterCropContract.requiredEdge,
            channelOrder: .rgb,
            elementType: .uint8,
            preprocessingContractID: preprocessingContractID
        ) else {
            preconditionFailure("the fixed model input shape must be representable")
        }
        return input
    }

    // MARK: - Logits

    /// A finite logit.
    ///
    /// Traps on NaN and infinity: those are `invalid-output-error`, not a logit value.
    public static func logit(_ value: Double) -> RawLogit {
        guard let logit = RawLogit(value) else {
            preconditionFailure("a raw logit must be finite, found \(value)")
        }
        return logit
    }
}
