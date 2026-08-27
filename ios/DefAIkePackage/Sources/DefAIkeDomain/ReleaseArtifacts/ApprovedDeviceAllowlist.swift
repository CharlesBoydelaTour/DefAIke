import Foundation

// Candidate device configurations and the signed Release Approved iPhone Allowlist.
//
// Which iPhones are approved is decision D6 and stays unresolved. This schema declares
// what an entry has to contain to be an entry at all: an exact hardware identifier, an
// exact iOS version at or above 17.0, Apple Neural Engine capability, and one coherent
// tuple of application build, Model Bundle, fixture suite, validation plan, capability
// set, and capability implementation versions, with a recorded result for every
// mandatory gate (Requirements 1.4, 13.1, 13.2, 13.17, and 13.18).
//
// The allowlist may legitimately be empty. An empty allowlist is not an error in the
// schema and is not a distribution approval either: Requirement 13.22 blocks
// distribution when no configuration passes, which ``permitsDistribution`` reports.

/// A candidate iPhone configuration under validation (Requirements 13.1 and 13.2).
public struct CandidateDeviceConfiguration: Hashable, Codable, Sendable {
    public let deviceModel: ArtifactText
    public let hardwareIdentifier: DeviceHardwareID
    public let osVersion: PlatformVersion
    public let appBuild: AppBuildID

    /// Always true: only Apple Neural Engine-capable configurations are candidates.
    public let isAppleNeuralEngineCapable: Bool

    public init(
        deviceModel: ArtifactText,
        hardwareIdentifier: DeviceHardwareID,
        osVersion: PlatformVersion,
        appBuild: AppBuildID,
        isAppleNeuralEngineCapable: Bool
    ) throws {
        guard osVersion >= .iOS17 else {
            throw ArtifactSchemaError.valueOutOfRange(
                field: "configuration.osVersion",
                value: osVersion.description,
                allowed: "at least \(PlatformVersion.iOS17)"
            )
        }
        guard isAppleNeuralEngineCapable else {
            throw ArtifactSchemaError.forbiddenValue(
                field: "configuration.isAppleNeuralEngineCapable",
                value: "false",
                reason: "only Apple Neural Engine-capable configurations are eligible"
            )
        }
        self.deviceModel = deviceModel
        self.hardwareIdentifier = hardwareIdentifier
        self.osVersion = osVersion
        self.appBuild = appBuild
        self.isAppleNeuralEngineCapable = isAppleNeuralEngineCapable
    }

    private enum CodingKeys: String, CodingKey {
        case deviceModel, hardwareIdentifier, osVersion, appBuild, isAppleNeuralEngineCapable
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                deviceModel: container.decode(ArtifactText.self, forKey: .deviceModel),
                hardwareIdentifier: container.decode(
                    DeviceHardwareID.self,
                    forKey: .hardwareIdentifier
                ),
                osVersion: container.decode(PlatformVersion.self, forKey: .osVersion),
                appBuild: container.decode(AppBuildID.self, forKey: .appBuild),
                isAppleNeuralEngineCapable: container.decode(
                    Bool.self,
                    forKey: .isAppleNeuralEngineCapable
                )
            )
        } catch let error as ArtifactSchemaError {
            throw error.asDecodingError(codingPath: decoder.codingPath)
        }
    }
}

/// The exact version tuple every gate result for one configuration must share.
///
/// Requirement 13.20 excludes a configuration whose evidence mixes builds, bundles,
/// fixture suites, plans, capability sets, or implementation versions, so the tuple is
/// one comparable value rather than fields spread across records.
public struct ValidationVersionTuple: Hashable, Codable, Sendable {
    public let appBuild: AppBuildID
    public let modelBundle: ModelBundleID
    public let fixtureSuite: ArtifactID
    public let validationPlan: ArtifactID
    public let capabilityManifest: ArtifactID
    public let capabilities: Set<CapabilityID>
    public let capabilityImplementationVersions: [CapabilityImplementationEntry]

    public init(
        appBuild: AppBuildID,
        modelBundle: ModelBundleID,
        fixtureSuite: ArtifactID,
        validationPlan: ArtifactID,
        capabilityManifest: ArtifactID,
        capabilities: Set<CapabilityID>,
        capabilityImplementationVersions: [CapabilityImplementationEntry]
    ) throws {
        guard capabilities.contains(.pixelAnalysis) else {
            throw ArtifactSchemaError.missingRequiredEntries(
                field: "versionTuple.capabilities",
                keys: [CapabilityID.pixelAnalysis.rawValue]
            )
        }
        try ArtifactSchemaValidation.requireExactCoverage(
            capabilityImplementationVersions.map(\.capability.rawValue),
            required: Set(capabilities.map(\.rawValue)),
            field: "versionTuple.capabilityImplementationVersions"
        )
        self.appBuild = appBuild
        self.modelBundle = modelBundle
        self.fixtureSuite = fixtureSuite
        self.validationPlan = validationPlan
        self.capabilityManifest = capabilityManifest
        self.capabilities = capabilities
        self.capabilityImplementationVersions = capabilityImplementationVersions
    }

    /// Whether this tuple enables on-device Content Credential validation.
    public var enablesProvenance: Bool { capabilities.contains(.contentCredentialValidation) }

    private enum CodingKeys: String, CodingKey {
        case appBuild, modelBundle, fixtureSuite, validationPlan, capabilityManifest
        case capabilities, capabilityImplementationVersions
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                appBuild: container.decode(AppBuildID.self, forKey: .appBuild),
                modelBundle: container.decode(ModelBundleID.self, forKey: .modelBundle),
                fixtureSuite: container.decode(ArtifactID.self, forKey: .fixtureSuite),
                validationPlan: container.decode(ArtifactID.self, forKey: .validationPlan),
                capabilityManifest: container.decode(ArtifactID.self, forKey: .capabilityManifest),
                capabilities: container.decode(Set<CapabilityID>.self, forKey: .capabilities),
                capabilityImplementationVersions: container.decode(
                    [CapabilityImplementationEntry].self,
                    forKey: .capabilityImplementationVersions
                )
            )
        } catch let error as ArtifactSchemaError {
            throw error.asDecodingError(codingPath: decoder.codingPath)
        }
    }
}

/// One allowlist entry: a configuration, its version tuple, and its gate evidence.
public struct ApprovedDeviceConfiguration: Hashable, Codable, Sendable {
    public let id: ApprovedConfigurationID
    public let configuration: CandidateDeviceConfiguration
    public let versionTuple: ValidationVersionTuple

    /// One reference per mandatory gate, each gate exactly once.
    public let gateEvidence: [GateResultReference]

    public init(
        id: ApprovedConfigurationID,
        configuration: CandidateDeviceConfiguration,
        versionTuple: ValidationVersionTuple,
        gateEvidence: [GateResultReference]
    ) throws {
        guard configuration.appBuild == versionTuple.appBuild else {
            throw ArtifactSchemaError.inconsistentReference(
                field: "entry.configuration.appBuild",
                expected: versionTuple.appBuild.rawValue,
                found: configuration.appBuild.rawValue
            )
        }
        try ArtifactSchemaValidation.requireExactCoverage(
            gateEvidence.map(\.gate.rawValue),
            required: Set(DeviceGate.mandatoryGates.map(\.rawValue)),
            field: "entry.gateEvidence"
        )
        for reference in gateEvidence where reference.gate.isProvenanceConditional {
            guard reference.applicability.isApplicable == versionTuple.enablesProvenance else {
                throw ArtifactSchemaError.inconsistentReference(
                    field: "entry.gateEvidence[\(reference.gate.rawValue)].applicability",
                    expected: versionTuple.enablesProvenance ? "applicable" : "not applicable",
                    found: reference.applicability.isApplicable ? "applicable" : "not applicable"
                )
            }
        }
        self.id = id
        self.configuration = configuration
        self.versionTuple = versionTuple
        self.gateEvidence = gateEvidence
    }

    /// Mandatory gates that are neither passing on a physical iPhone nor declared
    /// inapplicable by an approved decision.
    ///
    /// Nonempty means this entry is not distributable. The release validator, not this
    /// schema, decides what to do about it.
    public var unsatisfiedGates: Set<DeviceGate> {
        Set(gateEvidence.filter { !$0.isSatisfied }.map(\.gate))
    }

    private enum CodingKeys: String, CodingKey {
        case id, configuration, versionTuple, gateEvidence
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(ApprovedConfigurationID.self, forKey: .id),
                configuration: container.decode(
                    CandidateDeviceConfiguration.self,
                    forKey: .configuration
                ),
                versionTuple: container.decode(ValidationVersionTuple.self, forKey: .versionTuple),
                gateEvidence: container.decode([GateResultReference].self, forKey: .gateEvidence)
            )
        } catch let error as ArtifactSchemaError {
            throw error.asDecodingError(codingPath: decoder.codingPath)
        }
    }
}

/// The signed Release Approved iPhone Allowlist.
public struct ReleaseApprovedDeviceAllowlist: Hashable, Codable, Sendable {
    public let id: ArtifactID
    public let schemaVersion: ArtifactSchemaVersion

    /// Entries, possibly none. Emptiness blocks distribution rather than being invalid.
    public let entries: [ApprovedDeviceConfiguration]

    /// The release decision that approved this allowlist.
    public let approval: ApprovalRecord

    public init(
        id: ArtifactID,
        schemaVersion: ArtifactSchemaVersion,
        entries: [ApprovedDeviceConfiguration],
        approval: ApprovalRecord
    ) throws {
        try ArtifactSchemaValidation.requireUniqueKeys(
            entries.map(\.id.rawValue),
            field: "allowlist.entries"
        )
        try ArtifactSchemaValidation.requireUniqueKeys(
            entries.map { "\($0.configuration.hardwareIdentifier.rawValue)@"
                + "\($0.configuration.osVersion.description)/\($0.versionTuple.appBuild.rawValue)"
            },
            field: "allowlist.configurations"
        )
        self.id = id
        self.schemaVersion = schemaVersion
        self.entries = entries
        self.approval = approval
    }

    /// Whether any entry has every mandatory gate satisfied (Requirement 13.22).
    public var permitsDistribution: Bool {
        entries.contains { $0.unsatisfiedGates.isEmpty }
    }

    /// The entry matching an exact hardware identifier, iOS version, and build.
    ///
    /// Matching is exact, and a returned entry still has to be checked for satisfied
    /// gates: membership is not approval.
    public func entry(
        hardwareIdentifier: DeviceHardwareID,
        osVersion: PlatformVersion,
        appBuild: AppBuildID
    ) -> ApprovedDeviceConfiguration? {
        entries.first {
            $0.configuration.hardwareIdentifier == hardwareIdentifier
                && $0.configuration.osVersion == osVersion
                && $0.versionTuple.appBuild == appBuild
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, schemaVersion, entries, approval
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(ArtifactID.self, forKey: .id),
                schemaVersion: container.decode(ArtifactSchemaVersion.self, forKey: .schemaVersion),
                entries: container.decode([ApprovedDeviceConfiguration].self, forKey: .entries),
                approval: container.decode(ApprovalRecord.self, forKey: .approval)
            )
        } catch let error as ArtifactSchemaError {
            throw error.asDecodingError(codingPath: decoder.codingPath)
        }
    }
}
