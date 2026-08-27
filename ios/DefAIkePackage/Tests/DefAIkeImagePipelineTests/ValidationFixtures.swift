import DefAIkeDomain
import CryptoKit
import Foundation

// Arguments the validator needs in order to be called at all.
//
// **No number, action, unit pairing, or limit in this file is an approved release
// value.** Every one of them is an unresolved external decision (the Preprocessing
// Contract's metadata actions, the Resource Budget's measured limits). They exist so a
// port that takes a signed artifact can be exercised, and no test asserts that a value
// here is correct. Nothing here may be copied into a shipping artifact.
//
// The store below is a real streaming store with a real SHA-256, not a stub that
// returns canned bytes: the validator reads through it, so byte-identity and
// not-finalized behavior have to actually hold for the tests to mean anything.

// MARK: - Identifier helpers

enum Fixture {
    static func artifactID(_ raw: String) -> ArtifactID {
        guard let id = ArtifactID(raw) else {
            preconditionFailure("fixture artifact identifier is not canonical: \(raw)")
        }
        return id
    }

    static func sessionID(_ raw: String = "session-0001") -> AnalysisSessionID {
        guard let id = AnalysisSessionID(raw) else {
            preconditionFailure("fixture session identifier is not canonical: \(raw)")
        }
        return id
    }

    static func digest(of bytes: [UInt8]) -> DefAIkeDomain.SHA256Digest {
        let computed = Array(CryptoKit.SHA256.hash(data: Data(bytes)))
        guard let digest = DefAIkeDomain.SHA256Digest(bytes: computed) else {
            preconditionFailure("SHA-256 produced an unexpected length")
        }
        return digest
    }

    static func evidence(_ artifact: String) -> EvidenceSource {
        do {
            return EvidenceSource(
                artifact: artifactID(artifact),
                version: try SchemaSemanticVersion(validating: "0.1.0"),
                contentDigest: digest(of: Array(artifact.utf8))
            )
        } catch {
            preconditionFailure("fixture evidence source must be schema-valid: \(error)")
        }
    }
}

// MARK: - Preprocessing Contract

enum PreprocessingFixture {
    /// A schema-valid contract.
    ///
    /// Every metadata action, and the working-space identifier, is a parameter because
    /// they are unresolved release decisions (D10): a test that needs a particular
    /// handling states it, and no default here is a claim about what a release should
    /// bind. `orientationRules`, `colorProfileRules`, and `alphaRules` override the
    /// per-action defaults when a test needs different handling per state.
    ///
    /// The default working space is a real, resolvable Core Graphics identifier so the
    /// contract can actually be applied. Which space a release names is still an
    /// external decision.
    static func contract(
        id: String = "preprocessing-0001",
        supportedContainers: Set<StaticContainer> = Set(StaticContainer.allCases),
        // Ignoring the declaration is the one orientation action that is applicable in
        // every observed state, so it is what a test that is not about orientation gets.
        // `applyDeclaredOrientation` is deliberately not the default: bound to a state
        // that carries no declaration it fails closed, which is correct behavior and would
        // read as an unrelated failure in every other test.
        orientation: OrientationAction = .ignoreDeclaredOrientation,
        orientationRules: MetadataStateRules<OrientationAction>? = nil,
        colorProfile: ColorProfileAction = .convertToWorkingSpace,
        colorProfileRules: MetadataStateRules<ColorProfileAction>? = nil,
        alpha: AlphaAction = .discardAlphaChannel,
        alphaRules: MetadataStateRules<AlphaAction>? = nil,
        workingSpace: String = "kCGColorSpaceSRGB",
        workingSpaceProfileDigest: DefAIkeDomain.SHA256Digest? = nil,
        // The four geometry rules are unresolved release decisions too: the requirements
        // fix the 440 short edge and the 384 crop, not how a fractional long edge rounds,
        // where a sample sits inside a pixel, what happens outside the source, or which
        // way an odd leftover pixel goes. A test that is about one of them states it.
        rounding: RoundingRule = .halfUp,
        edgeRule: SampleEdgeRule = .clampToEdge,
        pixelCenterConvention: PixelCenterConvention = .halfPixelCenters,
        cropOffsetRule: CropOffsetRule = .floorHalfDifference
    ) -> PreprocessingContract {
        do {
            return try PreprocessingContract(
                id: Fixture.artifactID(id),
                schemaVersion: .v1,
                supportedContainers: supportedContainers,
                orientationRules: orientationRules ?? uniformRules(orientation),
                colorProfileRules: colorProfileRules ?? uniformRules(colorProfile),
                alphaRules: alphaRules ?? uniformRules(alpha),
                rgbWorkingSpace: ColorSpaceDescriptor(
                    identifier: try ArtifactText(validating: workingSpace),
                    profileDigest: workingSpaceProfileDigest
                ),
                resize: try ResizeContract(
                    interpolation: .bilinear,
                    targetShortEdge: ResizeContract.requiredShortEdge,
                    rounding: rounding,
                    edgeRule: edgeRule,
                    pixelCenterConvention: pixelCenterConvention
                ),
                crop: try CenterCropContract(
                    width: CenterCropContract.requiredEdge,
                    height: CenterCropContract.requiredEdge,
                    offsetRule: cropOffsetRule
                ),
                modelInput: try ModelInputContract(
                    featureName: try ArtifactText(validating: "image"),
                    width: CenterCropContract.requiredEdge,
                    height: CenterCropContract.requiredEdge,
                    channelOrder: .rgb,
                    elementType: .uint8,
                    appliesAppSideNormalization: false
                )
            )
        } catch {
            preconditionFailure("the preprocessing fixture must be schema-valid: \(error)")
        }
    }

    /// One action for all four metadata states.
    static func uniformRules<Action: Hashable & Codable & Sendable>(
        _ action: Action
    ) -> MetadataStateRules<Action> {
        rules(Dictionary(uniqueKeysWithValues: ImageMetadataState.allCases.map { ($0, action) }))
    }

    /// One action per metadata state. Every state must appear, because the schema
    /// requires exact coverage.
    static func rules<Action: Hashable & Codable & Sendable>(
        _ perState: [ImageMetadataState: Action]
    ) -> MetadataStateRules<Action> {
        do {
            return try MetadataStateRules(
                rules: ImageMetadataState.allCases.compactMap { state in
                    perState[state].map { .init(state: state, action: $0) }
                }
            )
        } catch {
            preconditionFailure("a fixture rule map must cover every metadata state: \(error)")
        }
    }
}

// MARK: - Resource Budget

enum ResourceFixture {
    /// A schema-valid budget with generous synthetic limits.
    ///
    /// `overrides` replaces individual limits so a test can drive one metric to a
    /// breach without disturbing the others, or remove a numeric limit's unit
    /// coherence to exercise the fail-closed paths.
    static func budget(
        for target: ExecutionTarget = .mainApplication,
        id: String? = nil,
        defaultValue: Decimal = 1_000_000_000,
        overrides: [ResourceMetric: ValidatedLimit] = [:]
    ) -> ResourceBudget {
        do {
            return try ResourceBudget(
                id: Fixture.artifactID(id ?? "budget-\(target.rawValue)"),
                schemaVersion: .v1,
                target: target,
                hardLimits: try ResourceMetric.requiredMetrics(for: target)
                    .sorted { $0.rawValue < $1.rawValue }
                    .map { metric in
                        try ResourceLimitEntry(
                            metric: metric,
                            limit: overrides[metric] ?? defaultLimit(metric, value: defaultValue),
                            measurementConditions: Fixture.evidence(
                                "measurement-\(metric.rawValue)"
                            )
                        )
                    },
                validationPlan: Fixture.artifactID("validation-plan-0001")
            )
        } catch {
            preconditionFailure("the resource budget fixture must be schema-valid: \(error)")
        }
    }

    static func numeric(_ value: Decimal, _ unit: ResourceLimitUnit) -> ValidatedLimit {
        do {
            return .numeric(value: try PositiveDecimal(validating: value), unit: unit)
        } catch {
            preconditionFailure("\(value) is not a positive decimal: \(error)")
        }
    }

    private static func defaultLimit(
        _ metric: ResourceMetric,
        value: Decimal
    ) -> ValidatedLimit {
        metric.isCategorical
            ? .thermal(maximumState: .fair)
            : numeric(value, unit(for: metric))
    }

    /// A unit that matches each metric's dimension. Only the pairing is meaningful in a
    /// fixture; the number is a measured release decision.
    static func unit(for metric: ResourceMetric) -> ResourceLimitUnit {
        switch metric {
        case .decodedPixelCount: .pixels
        case .encodedInputSize, .peakResidentMemory, .temporaryStorage: .bytes
        case .coldModelLoadTime, .warmAnalysisLatency, .handoffLatency: .milliseconds
        case .energyImpact: .milliwattHours
        case .thermalState: .milliseconds
        }
    }
}

// MARK: - In-memory ephemeral store

/// A bounded in-memory ``EphemeralFileStoring`` with real streaming semantics.
///
/// Unfinalized objects are unreadable and finalized objects are immutable, exactly as
/// the port requires, and the digest is computed over the appended chunks rather than
/// supplied by the caller. Nothing here touches the file system, so the tests run
/// without a protected container.
actor InMemoryEncodedAssetStore: EphemeralFileStoring {
    private struct Object {
        var scope: EphemeralStorageScope
        var bytes: [UInt8]
        var protection: FileProtectionLevel
        var receipt: EphemeralWriteReceipt?
    }

    private var objects: [EphemeralStorageKey: Object] = [:]
    private var nextKey = 1

    /// Writes one complete object and returns its finalized receipt.
    func write(
        _ bytes: [UInt8],
        in scope: EphemeralStorageScope,
        protection: FileProtectionLevel = .complete,
        chunkSize: Int = 4096
    ) async throws -> EphemeralWriteReceipt {
        let key = try await create(in: scope, protection: protection)
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + chunkSize, bytes.count)
            try await append(Array(bytes[offset..<end]), to: key)
            offset = end
        }
        return try await finalize(key)
    }

    /// Creates an object that is deliberately never finalized.
    func createUnfinalized(in scope: EphemeralStorageScope) async throws -> EphemeralStorageKey {
        try await create(in: scope, protection: .complete)
    }

    func create(
        in scope: EphemeralStorageScope,
        protection: FileProtectionLevel
    ) async throws(EphemeralStoreError) -> EphemeralStorageKey {
        guard let key = EphemeralStorageKey("object-\(nextKey)") else {
            throw .storeUnavailable
        }
        nextKey += 1
        objects[key] = Object(scope: scope, bytes: [], protection: protection, receipt: nil)
        return key
    }

    func append(
        _ chunk: [UInt8],
        to key: EphemeralStorageKey
    ) async throws(EphemeralStoreError) -> Void {
        guard var object = objects[key] else { throw .notFound(key) }
        guard object.receipt == nil else { throw .alreadyFinalized(key) }
        object.bytes.append(contentsOf: chunk)
        objects[key] = object
    }

    func finalize(
        _ key: EphemeralStorageKey
    ) async throws(EphemeralStoreError) -> EphemeralWriteReceipt {
        guard var object = objects[key] else { throw .notFound(key) }
        if let receipt = object.receipt { return receipt }
        let receipt = EphemeralWriteReceipt(
            key: key,
            scope: object.scope,
            byteCount: UInt64(object.bytes.count),
            sha256: Fixture.digest(of: object.bytes),
            protection: object.protection
        )
        object.receipt = receipt
        objects[key] = object
        return receipt
    }

    func read(_ key: EphemeralStorageKey) async throws(EphemeralStoreError) -> [UInt8] {
        guard let object = objects[key] else { throw .notFound(key) }
        guard object.receipt != nil else { throw .notFinalized(key) }
        return object.bytes
    }

    func receipt(for key: EphemeralStorageKey) async -> EphemeralWriteReceipt? {
        objects[key]?.receipt
    }

    func move(
        _ key: EphemeralStorageKey,
        to scope: EphemeralStorageScope
    ) async throws(EphemeralStoreError) -> Void {
        guard var object = objects[key] else { throw .notFound(key) }
        guard object.receipt != nil else { throw .notFinalized(key) }
        object.scope = scope
        objects[key] = object
    }

    func keys(in scope: EphemeralStorageScope) async -> Set<EphemeralStorageKey> {
        Set(objects.filter { $0.value.scope == scope }.keys)
    }

    func deleteAll(
        in scope: EphemeralStorageScope,
        reason: SessionCleanupReason
    ) async throws(EphemeralStoreError) -> EphemeralDeletionReceipt {
        let owned = objects.filter { $0.value.scope == scope }.map(\.key)
        for key in owned { objects.removeValue(forKey: key) }
        return EphemeralDeletionReceipt(
            scope: scope,
            reason: reason,
            removedObjectCount: owned.count,
            completedAt: Date(timeIntervalSince1970: 0)
        )
    }

    func occupiedScopes() async -> Set<EphemeralStorageScope> {
        Set(objects.values.map(\.scope))
    }
}

// MARK: - Accepted ingest

enum IngestFixture {
    /// An accepted ingest whose handle names bytes already written to `store`.
    ///
    /// The content-type hint is deliberately a lie in several tests: it is retained for
    /// diagnostics and must never influence classification, so passing a wrong hint is
    /// how that is checked.
    static func asset(
        bytes: [UInt8],
        in store: InMemoryEncodedAssetStore,
        sessionID: AnalysisSessionID = Fixture.sessionID(),
        route: InputRoute = .photosPicker,
        preservationBasis: PreservationBasis = .providerDeclaredOriginalRepresentation,
        contentTypeHint: String? = nil
    ) async throws -> ImportedEncodedAsset {
        let receipt = try await store.write(bytes, in: .session(sessionID))
        guard let handle = EncodedAssetHandle(sessionID: sessionID, receipt: receipt) else {
            preconditionFailure("fixture handle rejected a receipt for \(bytes.count) byte(s)")
        }
        guard let asset = ImportedEncodedAsset(
            route: route,
            handle: handle,
            preservationStatus: preservationBasis.mostConservativeStatus,
            preservationBasis: preservationBasis,
            contentTypeHint: contentTypeHint.flatMap(ContentTypeHint.init)
        ) else {
            preconditionFailure("fixture ingest rejected a coherent status and basis pair")
        }
        return asset
    }

    /// An accepted ingest whose handle names an object that was never finalized.
    ///
    /// The handle has to be built by hand: the receipt-based initializer only accepts a
    /// finalized object, which is the behavior being relied on everywhere else.
    static func assetNamingUnfinalizedObject(
        in store: InMemoryEncodedAssetStore,
        declaredByteCount: UInt64,
        sessionID: AnalysisSessionID = Fixture.sessionID()
    ) async throws -> ImportedEncodedAsset {
        let key = try await store.createUnfinalized(in: .session(sessionID))
        guard let handle = EncodedAssetHandle(
            sessionID: sessionID,
            storageKey: key,
            byteCount: declaredByteCount,
            sha256: Fixture.digest(of: []),
            protection: .complete
        ) else {
            preconditionFailure("fixture handle rejected a positive byte count")
        }
        guard let asset = ImportedEncodedAsset(
            route: .photosPicker,
            handle: handle,
            preservationStatus: .unknown,
            preservationBasis: .preservationHistoryNotEstablished,
            contentTypeHint: nil
        ) else {
            preconditionFailure("fixture ingest rejected a coherent status and basis pair")
        }
        return asset
    }
}
