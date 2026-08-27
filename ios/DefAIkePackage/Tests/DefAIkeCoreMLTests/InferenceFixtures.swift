import DefAIkeCoreML
import DefAIkeDomain
import CryptoKit
import Foundation

// Arguments the loader and the analyzer need in order to be called at all, and doubles
// for the three seams they reach through.
//
// **Nothing here is release evidence.** No signature is verified, no self-test is run,
// no compiled model is loaded, and no parity, tolerance, latency, or compute-unit
// placement is measured. The digests, component versions, and receipts are synthetic:
// they exist so a port that takes a verified bundle can be called. Real signature
// vectors, a real `.mlmodelc`, and real fixtures belong to task 6.11, and device
// behavior belongs to the physical-device suite.

// MARK: - Identifier and digest helpers

enum Fixture {
    static func artifactID(_ raw: String) -> ArtifactID {
        guard let id = ArtifactID(raw) else {
            preconditionFailure("fixture artifact identifier is not canonical: \(raw)")
        }
        return id
    }

    static func bundleID(_ raw: String = "bundle-0001") -> ModelBundleID {
        guard let id = ModelBundleID(raw) else {
            preconditionFailure("fixture bundle identifier is not canonical: \(raw)")
        }
        return id
    }

    static func sessionID(_ raw: String = "session-0001") -> AnalysisSessionID {
        guard let id = AnalysisSessionID(raw) else {
            preconditionFailure("fixture session identifier is not canonical: \(raw)")
        }
        return id
    }

    static func digest(ofUTF8 text: String) -> DefAIkeDomain.SHA256Digest {
        let computed = Array(CryptoKit.SHA256.hash(data: Data(text.utf8)))
        guard let digest = DefAIkeDomain.SHA256Digest(bytes: computed) else {
            preconditionFailure("SHA-256 produced an unexpected length")
        }
        return digest
    }

    static func text(_ raw: String) -> ArtifactText {
        do {
            return try ArtifactText(validating: raw)
        } catch {
            preconditionFailure("fixture text is not schema-valid: \(error)")
        }
    }
}

// MARK: - The bound contracts

enum ContractFixture {
    /// The fixed input contract: one 384x384 unsigned 8-bit RGB feature, with no
    /// app-side normalization. The schema validation cannot be loosened by a fixture,
    /// because ``ModelInputContract`` rejects any other shape itself.
    static func input(featureName: String = "image") -> ModelInputContract {
        do {
            return try ModelInputContract(
                featureName: Fixture.text(featureName),
                width: CenterCropContract.requiredEdge,
                height: CenterCropContract.requiredEdge,
                channelOrder: .rgb,
                elementType: .uint8,
                appliesAppSideNormalization: false
            )
        } catch {
            preconditionFailure("fixture input contract must be schema-valid: \(error)")
        }
    }

    /// The fixed output contract: one positive-going floating-point scalar named
    /// `logit`. ``ModelOutputContract`` refuses any other name.
    static func output(elementType: ModelElementType = .float32) -> ModelOutputContract {
        do {
            return try ModelOutputContract(
                featureName: Fixture.text(ModelOutputContract.requiredFeatureName),
                elementType: elementType,
                isPositiveGoing: true
            )
        } catch {
            preconditionFailure("fixture output contract must be schema-valid: \(error)")
        }
    }
}

// MARK: - A verified, activated bundle

enum BundleFixture {
    static func manifest(bundleID: String = "bundle-0001") -> ModelBundleManifest {
        do {
            return try ModelBundleManifest(
                schemaVersion: .v1,
                bundleID: Fixture.bundleID(bundleID),
                modelIdentity: RequiredPixelModel.identity,
                modelFormat: try ModelFormatDescriptor(
                    programKind: .mlProgram,
                    computePrecision: .float16,
                    minimumOS: .iOS17
                ),
                inputContract: ContractFixture.input(),
                outputContract: ContractFixture.output(),
                componentVersions: BundleComponentVersions(
                    coreMLModel: Fixture.artifactID("coreml-model-0001"),
                    preprocessingContract: Fixture.artifactID("preprocessing-0001"),
                    calibrationPolicy: Fixture.artifactID("calibration-0001"),
                    evidenceScope: Fixture.artifactID("scope-0001"),
                    verdictCopyCompatibility: Fixture.artifactID("copy-0001"),
                    selfTestSpecification: Fixture.artifactID("self-tests-0001")
                ),
                artifacts: [digestRecord()],
                compatibility: try CompatibilityMatrix(
                    compatibleAppBuilds: [appBuild()],
                    requiredCapabilities: [.pixelAnalysis],
                    minimumOS: .iOS17
                ),
                upstreamBoundaryMetadata: try UpstreamBoundaryMetadata(
                    rawLogitValue: UpstreamBoundaryMetadata.requiredValue,
                    role: .modelMetadataOnly
                ),
                signingKey: signingKey()
            )
        } catch {
            preconditionFailure("fixture manifest must be schema-valid: \(error)")
        }
    }

    /// A receipt whose signature and self-test outcomes both passed, which is the only
    /// kind ``BoundModelBundle`` accepts. No cryptography ran to produce it.
    static func receipt(bundleID: String = "bundle-0001") -> ActivationReceipt {
        do {
            return try ActivationReceipt(
                id: Fixture.artifactID("receipt-0001"),
                schemaVersion: .v1,
                bundleID: Fixture.bundleID(bundleID),
                verificationPolicy: Fixture.artifactID("bundle-verification-0001"),
                verifiedManifestDigest: Fixture.digest(ofUTF8: "manifest-\(bundleID)"),
                verifiedArtifactDigests: [digestRecord()],
                signatureOutcome: .passed,
                selfTestOutcome: .passed,
                deviceContext: DeviceContext(
                    hardwareIdentifier: hardware(),
                    osVersion: .iOS17,
                    appBuild: appBuild(),
                    environment: .developmentMac
                ),
                activationGeneration: try PositiveCount(validating: 1),
                activatedAt: Date(timeIntervalSince1970: 0)
            )
        } catch {
            preconditionFailure("fixture receipt must be schema-valid: \(error)")
        }
    }

    static func boundBundle(bundleID: String = "bundle-0001") -> BoundModelBundle {
        guard let bundle = BoundModelBundle(
            manifest: manifest(bundleID: bundleID),
            receipt: receipt(bundleID: bundleID)
        ) else {
            preconditionFailure("the bound bundle fixture must be constructible")
        }
        return bundle
    }

    static func digestRecord(
        path: String = "artifacts/model.mlmodelc"
    ) -> ArtifactDigestRecord {
        guard let canonical = CanonicalRelativePath(path) else {
            preconditionFailure("artifact path is not canonical: \(path)")
        }
        return ArtifactDigestRecord(
            path: canonical,
            kind: .directoryTree,
            byteCount: 4096,
            digest: Fixture.digest(ofUTF8: path)
        )
    }

    static func appBuild(_ raw: String = "build-0001") -> AppBuildID {
        guard let id = AppBuildID(raw) else {
            preconditionFailure("app build identifier is not canonical: \(raw)")
        }
        return id
    }

    static func signingKey(_ raw: String = "key.fixture") -> SigningKeyID {
        guard let id = SigningKeyID(raw) else {
            preconditionFailure("signing key identifier is not canonical: \(raw)")
        }
        return id
    }

    static func hardware(_ raw: String = "iPhone17.1") -> DeviceHardwareID {
        guard let id = DeviceHardwareID(raw) else {
            preconditionFailure("hardware identifier is not canonical: \(raw)")
        }
        return id
    }
}

// MARK: - A bound model

enum ModelFixture {
    /// A bound model naming `token`. Used to drive the analyzer without going through
    /// the loader, including with a token no store ever issued.
    static func bound(token: UInt64) -> BoundCoreMLModel {
        guard let model = BoundCoreMLModel(
            bundleID: Fixture.bundleID(),
            modelIdentity: RequiredPixelModel.identity,
            coreMLModelVersion: Fixture.artifactID("coreml-model-0001"),
            inputContract: ContractFixture.input(),
            outputContract: ContractFixture.output(),
            model: LoadedModelToken(rawValue: token)
        ) else {
            preconditionFailure("the required pixel model identity must be bindable")
        }
        return model
    }
}

// MARK: - Runtime schemas and results

enum SchemaFixture {
    /// A description that matches the bound contracts.
    static func matching(
        inputName: String = "image",
        outputName: String = ModelOutputContract.requiredFeatureName,
        pixelFormat: RuntimeImagePixelFormat = .bgra8,
        outputKind: RuntimeFeatureKind = .scalar(.float64)
    ) -> RuntimeModelSchema {
        RuntimeModelSchema(
            inputs: [
                RuntimeFeatureDescription(
                    name: inputName,
                    kind: .image(
                        width: CenterCropContract.requiredEdge,
                        height: CenterCropContract.requiredEdge,
                        pixelFormat: pixelFormat
                    )
                )
            ],
            outputs: [RuntimeFeatureDescription(name: outputName, kind: outputKind)]
        )
    }

    /// A description whose input is replaced wholesale, for the input-kind rules.
    static func withInputKind(_ kind: RuntimeFeatureKind) -> RuntimeModelSchema {
        RuntimeModelSchema(
            inputs: [RuntimeFeatureDescription(name: "image", kind: kind)],
            outputs: matching().outputs
        )
    }
}

enum ResultFixture {
    static func logit(_ value: Double) -> RuntimeFeatureResult {
        RuntimeFeatureResult([ModelOutputContract.requiredFeatureName: .scalar(value)])
    }
}

// MARK: - Prepared pixels

enum PixelFixture {
    /// One bound-shaped buffer. The byte pattern is arbitrary: nothing in this task
    /// interprets pixel content, and no fixture here is a parity fixture.
    static func bound(edge: Int = CenterCropContract.requiredEdge) -> PreparedPixelData {
        guard let pixels = PreparedPixelData(
            edge: edge,
            channelOrder: .rgb,
            bytes: [UInt8](repeating: 0x7F, count: edge * edge * 3)
        ) else {
            preconditionFailure("fixture pixels must satisfy the packing invariant")
        }
        return pixels
    }

    /// The model input the analyzer is called with, matching the bound contract.
    static func modelInput(
        bufferToken: UInt64 = 1,
        contract: ModelInputContract = ContractFixture.input()
    ) -> ModelImageInput {
        ModelImageInput(
            sessionID: Fixture.sessionID(),
            buffer: ModelInputToken(rawValue: bufferToken),
            contract: contract,
            preprocessingContractID: Fixture.artifactID("preprocessing-0001")
        )
    }
}

// MARK: - Seam doubles

/// Counts calls across isolation boundaries so a test can assert that a refused
/// precondition stopped before the framework would have been reached.
actor CallCounter {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

/// A model runtime that returns exactly what a test tells it to.
struct StubPixelModelRuntime: PixelModelRuntime {
    let schema: RuntimeModelSchema
    let outcome: Result<RuntimeFeatureResult, ModelPredictionFault>
    let calls: CallCounter?

    init(
        schema: RuntimeModelSchema = SchemaFixture.matching(),
        outcome: Result<RuntimeFeatureResult, ModelPredictionFault> = .success(
            ResultFixture.logit(0.5)
        ),
        calls: CallCounter? = nil
    ) {
        self.schema = schema
        self.outcome = outcome
        self.calls = calls
    }

    func predict(
        _ pixels: PreparedPixelData
    ) async throws(ModelPredictionFault) -> RuntimeFeatureResult {
        await calls?.record()
        switch outcome {
        case .success(let result): return result
        case .failure(let fault): throw fault
        }
    }
}

/// A runtime loader that returns exactly what a test tells it to.
struct StubRuntimeLoader: PixelModelRuntimeLoading {
    let outcome: Result<StubPixelModelRuntime, ModelRuntimeLoadFault>

    init(
        outcome: Result<StubPixelModelRuntime, ModelRuntimeLoadFault> = .success(
            StubPixelModelRuntime()
        )
    ) {
        self.outcome = outcome
    }

    func loadRuntime(
        for bundle: BoundModelBundle
    ) async throws(ModelRuntimeLoadFault) -> any PixelModelRuntime {
        switch outcome {
        case .success(let runtime): return runtime
        case .failure(let fault): throw fault
        }
    }
}

/// A prepared-pixel resolver that returns exactly what a test tells it to.
struct StubPixelResolver: PreparedPixelResolving {
    let pixels: PreparedPixelData?

    init(pixels: PreparedPixelData? = PixelFixture.bound()) {
        self.pixels = pixels
    }

    func preparedPixels(for token: ModelInputToken) async -> PreparedPixelData? {
        pixels
    }
}
