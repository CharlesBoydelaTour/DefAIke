import Foundation

// The signed Model Bundle manifest.
//
// A Model Bundle is one immutable, signed, versioned release unit: the Core ML model,
// the Preprocessing Contract, the Calibration Policy, scope metadata, the Approved
// Verdict Copy compatibility identifier, the release self-test specification, and a
// digest for every declared artifact (Requirements 10.5 through 10.7).
//
// The signature algorithm, trusted keys, and key governance are deliberately not here:
// they live in the Bundle Verification Policy so that no source-code default can decide
// what counts as a trusted release key.
//
// What the requirements do fix is recorded as validated constants: the Lowq checkpoint
// identity, its required weight digest, the FP16 `mlprogram` format, the iOS 17.0
// minimum, one UInt8 RGB input, one finite scalar named `logit`, and `1.390625` as
// upstream metadata. A manifest that disagrees with any of them cannot be constructed.

// MARK: - Required pixel-model identity

/// The sole pixel model Version 1 may bind (Requirements 1.16, 10.2, and 10.4).
///
/// A model refresh is a release process with its own repeated evidence
/// (Requirement 14.11), so changing these constants is a deliberate, auditable edit
/// rather than a configuration value.
public enum RequiredPixelModel {
    /// The Lowq checkpoint identifier.
    public static let checkpointIdentifier =
        "Thermostatic/community-forensics-low-quality-detector-2026-08"

    /// The required weight-blob SHA-256 digest.
    public static let weightDigestHexadecimal =
        "f073f8a325f63e35ef0668c985ac762486a1b50e57dcf5ae33d4647bd26d4c1e"

    /// The one model identity a Version 1 manifest may declare.
    public static let identity: ModelIdentity = {
        guard let checkpoint = ModelCheckpointIdentifier(checkpointIdentifier),
              let digest = SHA256Digest(hexadecimal: weightDigestHexadecimal)
        else {
            preconditionFailure("The required pixel-model identity constants are malformed.")
        }
        return ModelIdentity(checkpointIdentifier: checkpoint, requiredWeightDigest: digest)
    }()
}

// MARK: - Model format

/// The Core ML program kind.
public enum ModelProgramKind: String, Codable, Sendable, Hashable, CaseIterable {
    case mlProgram = "mlprogram"
    case neuralNetwork = "neuralnetwork"
    case pipeline
}

/// The weight and activation precision of the converted model.
public enum ModelComputePrecision: String, Codable, Sendable, Hashable, CaseIterable {
    case float16
    case float32
}

/// The converted model's format, fixed by Requirements 4.2 and 10.3.
public struct ModelFormatDescriptor: Hashable, Codable, Sendable {
    public let programKind: ModelProgramKind
    public let computePrecision: ModelComputePrecision
    public let minimumOS: PlatformVersion

    public init(
        programKind: ModelProgramKind,
        computePrecision: ModelComputePrecision,
        minimumOS: PlatformVersion
    ) throws {
        guard programKind == .mlProgram else {
            throw ArtifactSchemaError.fixedValueMismatch(
                field: "modelFormat.programKind",
                expected: ModelProgramKind.mlProgram.rawValue,
                found: programKind.rawValue
            )
        }
        guard computePrecision == .float16 else {
            throw ArtifactSchemaError.fixedValueMismatch(
                field: "modelFormat.computePrecision",
                expected: ModelComputePrecision.float16.rawValue,
                found: computePrecision.rawValue
            )
        }
        guard minimumOS == .iOS17 else {
            throw ArtifactSchemaError.fixedValueMismatch(
                field: "modelFormat.minimumOS",
                expected: PlatformVersion.iOS17.description,
                found: minimumOS.description
            )
        }
        self.programKind = programKind
        self.computePrecision = computePrecision
        self.minimumOS = minimumOS
    }

    private enum CodingKeys: String, CodingKey {
        case programKind, computePrecision, minimumOS
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                programKind: container.decode(ModelProgramKind.self, forKey: .programKind),
                computePrecision: container.decode(
                    ModelComputePrecision.self,
                    forKey: .computePrecision
                ),
                minimumOS: container.decode(PlatformVersion.self, forKey: .minimumOS)
            )
        } catch let error as ArtifactSchemaError {
            throw error.asDecodingError(codingPath: decoder.codingPath)
        }
    }
}

// MARK: - Component versions and compatibility

/// The six component versions a Model Bundle carries (Requirement 10.7).
///
/// All six are required. Activation replaces them as one tuple, and a session binds
/// that tuple, so a bundle cannot ship with, for example, a model and no self-test
/// specification.
public struct BundleComponentVersions: Hashable, Codable, Sendable {
    public let coreMLModel: ArtifactID
    public let preprocessingContract: ArtifactID
    public let calibrationPolicy: ArtifactID
    public let evidenceScope: ArtifactID
    public let verdictCopyCompatibility: ArtifactID
    public let selfTestSpecification: ArtifactID

    public init(
        coreMLModel: ArtifactID,
        preprocessingContract: ArtifactID,
        calibrationPolicy: ArtifactID,
        evidenceScope: ArtifactID,
        verdictCopyCompatibility: ArtifactID,
        selfTestSpecification: ArtifactID
    ) {
        self.coreMLModel = coreMLModel
        self.preprocessingContract = preprocessingContract
        self.calibrationPolicy = calibrationPolicy
        self.evidenceScope = evidenceScope
        self.verdictCopyCompatibility = verdictCopyCompatibility
        self.selfTestSpecification = selfTestSpecification
    }
}

/// Which builds, capabilities, and operating systems a bundle is compatible with.
public struct CompatibilityMatrix: Hashable, Codable, Sendable {
    /// Application builds this bundle may activate under. Never empty: an empty set
    /// would make compatibility vacuously true.
    public let compatibleAppBuilds: Set<AppBuildID>

    /// Capabilities a build must compile for this bundle to be usable.
    public let requiredCapabilities: Set<CapabilityID>

    /// Minimum operating system for this bundle.
    public let minimumOS: PlatformVersion

    public init(
        compatibleAppBuilds: Set<AppBuildID>,
        requiredCapabilities: Set<CapabilityID>,
        minimumOS: PlatformVersion
    ) throws {
        try ArtifactSchemaValidation.requireNonEmpty(
            compatibleAppBuilds,
            field: "compatibility.compatibleAppBuilds"
        )
        guard requiredCapabilities.contains(.pixelAnalysis) else {
            throw ArtifactSchemaError.missingRequiredEntries(
                field: "compatibility.requiredCapabilities",
                keys: [CapabilityID.pixelAnalysis.rawValue]
            )
        }
        guard minimumOS >= .iOS17 else {
            throw ArtifactSchemaError.valueOutOfRange(
                field: "compatibility.minimumOS",
                value: minimumOS.description,
                allowed: "at least \(PlatformVersion.iOS17)"
            )
        }
        self.compatibleAppBuilds = compatibleAppBuilds
        self.requiredCapabilities = requiredCapabilities
        self.minimumOS = minimumOS
    }

    private enum CodingKeys: String, CodingKey {
        case compatibleAppBuilds, requiredCapabilities, minimumOS
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                compatibleAppBuilds: container.decode(
                    Set<AppBuildID>.self,
                    forKey: .compatibleAppBuilds
                ),
                requiredCapabilities: container.decode(
                    Set<CapabilityID>.self,
                    forKey: .requiredCapabilities
                ),
                minimumOS: container.decode(PlatformVersion.self, forKey: .minimumOS)
            )
        } catch let error as ArtifactSchemaError {
            throw error.asDecodingError(codingPath: decoder.codingPath)
        }
    }
}

// MARK: - Release self-tests

/// One expected result in a release self-test case.
///
/// Expected results are declared in the bundle. A runner compares against them and
/// never derives them from the implementation it is testing (Requirement 10.9).
public enum SelfTestExpectation: Hashable, Codable, Sendable {
    /// The raw logit must match `value` within `tolerance`.
    case rawLogit(value: Double, tolerance: NonNegativeDecimal)
    /// The calibrated label must be exactly this one.
    case pixelLabel(PixelLabelKey)
    /// The preprocessing output bytes must digest to this value.
    case preprocessingOutputDigest(SHA256Digest)
    /// The session must terminate with exactly this Analysis Error.
    case analysisError(AnalysisErrorKey)
}

/// One self-test case: a fixture and everything it must produce.
public struct SelfTestCase: Hashable, Codable, Sendable {
    public let id: SelfTestCaseID
    public let fixture: FixtureID
    public let expectations: [SelfTestExpectation]

    public init(id: SelfTestCaseID, fixture: FixtureID, expectations: [SelfTestExpectation]) throws {
        try ArtifactSchemaValidation.requireNonEmpty(
            expectations,
            field: "selfTestCase.expectations"
        )
        for expectation in expectations {
            if case let .rawLogit(value, _) = expectation {
                try ArtifactSchemaValidation.requireFinite(
                    value,
                    field: "selfTestCase.expectations.rawLogit"
                )
            }
        }
        self.id = id
        self.fixture = fixture
        self.expectations = expectations
    }

    private enum CodingKeys: String, CodingKey {
        case id, fixture, expectations
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(SelfTestCaseID.self, forKey: .id),
                fixture: container.decode(FixtureID.self, forKey: .fixture),
                expectations: container.decode([SelfTestExpectation].self, forKey: .expectations)
            )
        } catch let error as ArtifactSchemaError {
            throw error.asDecodingError(codingPath: decoder.codingPath)
        }
    }
}

/// The release self-test specification a bundle names (Requirements 10.9 and 10.11).
public struct ReleaseSelfTestSpecification: Hashable, Codable, Sendable {
    public let id: ArtifactID
    public let schemaVersion: ArtifactSchemaVersion

    /// The fixture suite the cases draw from.
    public let fixtureSuite: ArtifactID

    /// At least one case: a specification with no cases proves nothing.
    public let cases: [SelfTestCase]

    public init(
        id: ArtifactID,
        schemaVersion: ArtifactSchemaVersion,
        fixtureSuite: ArtifactID,
        cases: [SelfTestCase]
    ) throws {
        try ArtifactSchemaValidation.requireNonEmpty(cases, field: "selfTests.cases")
        try ArtifactSchemaValidation.requireUniqueKeys(
            cases.map(\.id.rawValue),
            field: "selfTests.cases"
        )
        self.id = id
        self.schemaVersion = schemaVersion
        self.fixtureSuite = fixtureSuite
        self.cases = cases
    }

    private enum CodingKeys: String, CodingKey {
        case id, schemaVersion, fixtureSuite, cases
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(ArtifactID.self, forKey: .id),
                schemaVersion: container.decode(ArtifactSchemaVersion.self, forKey: .schemaVersion),
                fixtureSuite: container.decode(ArtifactID.self, forKey: .fixtureSuite),
                cases: container.decode([SelfTestCase].self, forKey: .cases)
            )
        } catch let error as ArtifactSchemaError {
            throw error.asDecodingError(codingPath: decoder.codingPath)
        }
    }
}

// MARK: - Manifest

/// The signed manifest at the root of a Model Bundle.
public struct ModelBundleManifest: Hashable, Codable, Sendable {
    /// Canonical file name of the manifest itself.
    public static let manifestFileName = "manifest.canonical.json"

    /// Canonical file name of the manifest signature.
    public static let signatureFileName = "manifest.signature"

    public let schemaVersion: ArtifactSchemaVersion
    public let bundleID: ModelBundleID

    /// Exactly ``RequiredPixelModel/identity``.
    public let modelIdentity: ModelIdentity

    public let modelFormat: ModelFormatDescriptor
    public let inputContract: ModelInputContract
    public let outputContract: ModelOutputContract
    public let componentVersions: BundleComponentVersions

    /// Every declared artifact, each exactly once.
    public let artifacts: [ArtifactDigestRecord]

    public let compatibility: CompatibilityMatrix

    /// The upstream Lowq boundary, carried as metadata (Requirement 5.14).
    public let upstreamBoundaryMetadata: UpstreamBoundaryMetadata

    /// The key this manifest's signature is expected to verify against. Whether that
    /// key is trusted is a Bundle Verification Policy question.
    public let signingKey: SigningKeyID

    public init(
        schemaVersion: ArtifactSchemaVersion,
        bundleID: ModelBundleID,
        modelIdentity: ModelIdentity,
        modelFormat: ModelFormatDescriptor,
        inputContract: ModelInputContract,
        outputContract: ModelOutputContract,
        componentVersions: BundleComponentVersions,
        artifacts: [ArtifactDigestRecord],
        compatibility: CompatibilityMatrix,
        upstreamBoundaryMetadata: UpstreamBoundaryMetadata,
        signingKey: SigningKeyID
    ) throws {
        guard modelIdentity == RequiredPixelModel.identity else {
            throw ArtifactSchemaError.fixedValueMismatch(
                field: "manifest.modelIdentity",
                expected: """
                    \(RequiredPixelModel.checkpointIdentifier) with weight digest \
                    \(RequiredPixelModel.weightDigestHexadecimal)
                    """,
                found: """
                    \(modelIdentity.checkpointIdentifier.rawValue) with weight digest \
                    \(modelIdentity.requiredWeightDigest.hexadecimalString)
                    """
            )
        }
        try ArtifactSchemaValidation.requireNonEmpty(artifacts, field: "manifest.artifacts")
        try ArtifactSchemaValidation.requireUniqueKeys(
            artifacts.map(\.path.rawValue),
            field: "manifest.artifacts"
        )
        for artifact in artifacts {
            guard artifact.path.rawValue != Self.manifestFileName,
                  artifact.path.rawValue != Self.signatureFileName
            else {
                throw ArtifactSchemaError.forbiddenValue(
                    field: "manifest.artifacts",
                    value: artifact.path.rawValue,
                    reason: "the manifest and its signature are not self-declared artifacts"
                )
            }
            guard artifact.byteCount > 0 else {
                throw ArtifactSchemaError.nonPositiveValue(
                    field: "manifest.artifacts[\(artifact.path.rawValue)].byteCount",
                    value: "\(artifact.byteCount)"
                )
            }
        }
        self.schemaVersion = schemaVersion
        self.bundleID = bundleID
        self.modelIdentity = modelIdentity
        self.modelFormat = modelFormat
        self.inputContract = inputContract
        self.outputContract = outputContract
        self.componentVersions = componentVersions
        self.artifacts = artifacts
        self.compatibility = compatibility
        self.upstreamBoundaryMetadata = upstreamBoundaryMetadata
        self.signingKey = signingKey
    }

    /// Declared artifact paths, for comparison against a real directory tree.
    public var declaredPaths: Set<String> { Set(artifacts.map(\.path.rawValue)) }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, bundleID, modelIdentity, modelFormat, inputContract, outputContract
        case componentVersions, artifacts, compatibility, upstreamBoundaryMetadata, signingKey
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                schemaVersion: container.decode(ArtifactSchemaVersion.self, forKey: .schemaVersion),
                bundleID: container.decode(ModelBundleID.self, forKey: .bundleID),
                modelIdentity: container.decode(ModelIdentity.self, forKey: .modelIdentity),
                modelFormat: container.decode(ModelFormatDescriptor.self, forKey: .modelFormat),
                inputContract: container.decode(ModelInputContract.self, forKey: .inputContract),
                outputContract: container.decode(ModelOutputContract.self, forKey: .outputContract),
                componentVersions: container.decode(
                    BundleComponentVersions.self,
                    forKey: .componentVersions
                ),
                artifacts: container.decode([ArtifactDigestRecord].self, forKey: .artifacts),
                compatibility: container.decode(CompatibilityMatrix.self, forKey: .compatibility),
                upstreamBoundaryMetadata: container.decode(
                    UpstreamBoundaryMetadata.self,
                    forKey: .upstreamBoundaryMetadata
                ),
                signingKey: container.decode(SigningKeyID.self, forKey: .signingKey)
            )
        } catch let error as ArtifactSchemaError {
            throw error.asDecodingError(codingPath: decoder.codingPath)
        }
    }
}
