import DefAIkeDomain
import DefAIkeTestSupport
import Foundation

/// Structurally valid bundle values for driving the bundle and inference doubles.
///
/// The model identity is the one the requirements fix, because
/// ``ModelBundleManifest`` accepts no other. Everything else — artifact digests,
/// component versions, the signing key, the receipt — is synthetic. **No signature is
/// verified and no self-test is executed here**; those need real cryptography and a real
/// compiled model and belong to task 6.11.
enum BundleFixture {
    static func manifest(
        bundleID: String = "bundle-0001",
        appBuild: String = "build-0001",
        capabilities: Set<CapabilityID> = [.pixelAnalysis]
    ) -> ModelBundleManifest {
        do {
            return try ModelBundleManifest(
                schemaVersion: .v1,
                bundleID: PortValue.bundleID(bundleID),
                modelIdentity: RequiredPixelModel.identity,
                modelFormat: try ModelFormatDescriptor(
                    programKind: .mlProgram,
                    computePrecision: .float16,
                    minimumOS: .iOS17
                ),
                inputContract: PreprocessingFixture.contract().modelInput,
                outputContract: PreprocessingFixture.modelOutputContract(),
                componentVersions: BundleComponentVersions(
                    coreMLModel: PortValue.artifactID("coreml-model-0001"),
                    preprocessingContract: PortValue.artifactID("preprocessing-0001"),
                    calibrationPolicy: PortValue.artifactID("calibration-0001"),
                    evidenceScope: PortValue.artifactID("scope-0001"),
                    verdictCopyCompatibility: PortValue.artifactID("copy-0001"),
                    selfTestSpecification: PortValue.artifactID("self-tests-0001")
                ),
                artifacts: [digestRecord()],
                compatibility: try CompatibilityMatrix(
                    compatibleAppBuilds: [PortValue.appBuildID(appBuild)],
                    requiredCapabilities: capabilities,
                    minimumOS: .iOS17
                ),
                upstreamBoundaryMetadata: upstreamMetadata(),
                signingKey: signingKey()
            )
        } catch {
            preconditionFailure("the manifest fixture must be schema-valid: \(error)")
        }
    }

    /// A receipt whose signature and self-test outcomes are both `outcome`.
    ///
    /// Anything other than `.passed` makes the receipt unbindable, which is what a test
    /// uses to show that a failed candidate cannot become a ``BoundModelBundle``.
    static func receipt(
        bundleID: String = "bundle-0001",
        id: String = "receipt-0001",
        outcome: GateOutcome = .passed,
        generation: Int = 1
    ) -> ActivationReceipt {
        do {
            return try ActivationReceipt(
                id: PortValue.artifactID(id),
                schemaVersion: .v1,
                bundleID: PortValue.bundleID(bundleID),
                verificationPolicy: PortValue.artifactID("bundle-verification-0001"),
                verifiedManifestDigest: TestSHA256.digest(ofUTF8: "manifest-\(bundleID)"),
                verifiedArtifactDigests: [digestRecord()],
                signatureOutcome: outcome,
                selfTestOutcome: outcome,
                deviceContext: deviceContext(),
                activationGeneration: try PositiveCount(validating: generation),
                activatedAt: VirtualSessionClock.defaultStart
            )
        } catch {
            preconditionFailure("the receipt fixture must be schema-valid: \(error)")
        }
    }

    /// A bound bundle, or `nil` when the manifest and receipt do not agree.
    static func boundBundle(
        bundleID: String = "bundle-0001",
        appBuild: String = "build-0001",
        receiptBundleID: String? = nil,
        outcome: GateOutcome = .passed
    ) -> BoundModelBundle? {
        BoundModelBundle(
            manifest: manifest(bundleID: bundleID, appBuild: appBuild),
            receipt: receipt(bundleID: receiptBundleID ?? bundleID, outcome: outcome)
        )
    }

    /// A bound bundle that must exist, for tests whose subject is something else.
    static func requiredBoundBundle(
        bundleID: String = "bundle-0001",
        appBuild: String = "build-0001"
    ) -> BoundModelBundle {
        guard let bundle = boundBundle(bundleID: bundleID, appBuild: appBuild) else {
            preconditionFailure("the bound bundle fixture must be constructible")
        }
        return bundle
    }

    static func boundModel(
        bundleID: String = "bundle-0001",
        modelToken: UInt64 = 1
    ) -> BoundCoreMLModel {
        guard let model = BoundCoreMLModel(
            bundleID: PortValue.bundleID(bundleID),
            modelIdentity: RequiredPixelModel.identity,
            coreMLModelVersion: PortValue.artifactID("coreml-model-0001"),
            inputContract: PreprocessingFixture.contract().modelInput,
            outputContract: PreprocessingFixture.modelOutputContract(),
            model: LoadedModelToken(rawValue: modelToken)
        ) else {
            preconditionFailure("the required pixel model identity must be bindable")
        }
        return model
    }

    static func releaseContext(
        appBuild: String = "build-0001",
        capabilities: Set<CapabilityID> = [.pixelAnalysis]
    ) -> ReleaseContext {
        guard let context = ReleaseContext(
            device: deviceContext(appBuild: appBuild),
            approvedConfiguration: PortValue.configurationID(),
            capabilityManifestID: PortValue.artifactID("capability-0001"),
            compiledCapabilities: capabilities
        ) else {
            preconditionFailure("a pixel-analysis release context must be constructible")
        }
        return context
    }

    static func deviceContext(appBuild: String = "build-0001") -> DeviceContext {
        DeviceContext(
            hardwareIdentifier: hardware(),
            osVersion: .iOS17,
            appBuild: PortValue.appBuildID(appBuild),
            environment: .developmentMac
        )
    }

    // MARK: - Pieces

    static func digestRecord(
        path: String = "artifacts/model.mlmodelc"
    ) -> ArtifactDigestRecord {
        guard let canonicalPath = CanonicalRelativePath(path) else {
            preconditionFailure("artifact path is not canonical: \(path)")
        }
        return ArtifactDigestRecord(
            path: canonicalPath,
            kind: .directoryTree,
            byteCount: 4096,
            digest: TestSHA256.digest(ofUTF8: path)
        )
    }

    static func upstreamMetadata() -> UpstreamBoundaryMetadata {
        do {
            // The upstream Lowq boundary is fixed by Requirement 5.14 and is carried as
            // model metadata only. It is never a product verdict boundary.
            return try UpstreamBoundaryMetadata(
                rawLogitValue: UpstreamBoundaryMetadata.requiredValue,
                role: .modelMetadataOnly
            )
        } catch {
            preconditionFailure("the upstream metadata fixture must be schema-valid: \(error)")
        }
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
