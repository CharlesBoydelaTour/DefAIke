import DefAIkeTestSupport
import Foundation
import Testing

@testable import DefAIkeDomain

// Schema version handling for every versioned value in the domain.
//
// Two families of versioned value exist, and they fail closed differently on purpose:
//
//   * Four core session values carry a plain `Int`. They are constructed in process,
//     so an unreadable version is a failed construction — `init?` returns `nil` — and
//     for the two that cross a process or file boundary it is also a decoding error.
//   * Twenty-one release artifacts carry an `ArtifactSchemaVersion`. They are read
//     from signed bytes, so an unreadable version is a decoding error that names
//     `schemaVersion` as the cause.
//
// The property both families share is that a version this build cannot fully
// interpret is refused rather than ignored. Ignoring it is the dangerous option: an
// artifact from a later revision could carry a field this build does not read, and
// silently dropping that field turns a signed decision into a partially applied one.
//
// Every artifact is also round tripped through its own encoding here, which is the
// positive control: a sweep that only ever asserts refusal would pass against a type
// that refuses everything.

// MARK: - Samples the schema tests need

extension Sample {
    /// A predeclared release-gating slice, at the required 95 percent level.
    ///
    /// The level is the only value the type fixes, so it is not a parameter. Everything
    /// else is a release decision the samples supply synthetically.
    static func gatingSlice(
        identifier: String = "slice.sample",
        intervalMethod: ConfidenceIntervalMethod = .wilsonScore,
        isContemporaryPhoneCameraSlice: Bool = true
    ) throws -> ReleaseGatingSliceSpecification {
        try ReleaseGatingSliceSpecification(
            id: slice(identifier),
            schemaVersion: .v1,
            eligibilityRule: evidence("evidence.eligibility"),
            outcomeMapping: evidence("evidence.outcome-mapping"),
            metricDefinition: evidence("evidence.metric"),
            datasetComposition: evidence("evidence.composition"),
            degradationCondition: evidence("evidence.degradation"),
            intervalMethod: intervalMethod,
            confidenceLevel: ratio(FalseAccusationPassRule.requiredConfidenceLevel),
            isContemporaryPhoneCameraSlice: isContemporaryPhoneCameraSlice
        )
    }

    /// A dataset lineage record covering one separated population pair.
    static func datasetLineage() throws -> DatasetLineageRecord {
        try DatasetLineageRecord(
            id: artifact("record.dataset-lineage"),
            schemaVersion: .v1,
            separationResults: [
                try PopulationSeparationResult(
                    firstPopulation: .heldOutCalibration,
                    secondPopulation: .productThresholdEvaluation,
                    sampleLevelOutcome: .passed,
                    contentLevelOutcome: .passed,
                    evidence: evidence("evidence.separation")
                )
            ],
            identifierCorrection: evidence("evidence.identifier-correction"),
            duplicateHashDisposition: evidence("evidence.duplicate-hashes")
        )
    }

    /// A self-test specification with one declared case.
    static func selfTestSpecification() throws -> ReleaseSelfTestSpecification {
        try ReleaseSelfTestSpecification(
            id: artifact("component.self-tests"),
            schemaVersion: .v1,
            fixtureSuite: artifact("suite.fixtures"),
            cases: [
                try SelfTestCase(
                    id: selfTestCase(),
                    fixture: fixture(),
                    expectations: [.pixelLabel(.notEnoughSignal)]
                )
            ]
        )
    }

    /// Every required resource measurement, for both targets, on one candidate.
    static func measurementSpecifications() throws -> [ResourceMeasurementSpecification] {
        try ExecutionTarget.allCases.flatMap { target in
            try ResourceMetric.requiredMetrics(for: target)
                .sorted { $0.rawValue < $1.rawValue }
                .map { metric in
                    try ResourceMeasurementSpecification(
                        metric: metric,
                        target: target,
                        hardwareIdentifier: hardware(),
                        osVersion: .iOS17,
                        appBuild: appBuild(),
                        workload: evidence("evidence.workload"),
                        warmth: .cold,
                        branchExecution: .serial,
                        startingThermalState: .nominal,
                        startingPowerCondition: .batteryUnplugged,
                        sampleCount: count(),
                        summaryStatistic: .median,
                        passLimit: limit(for: metric)
                    )
                }
        }
    }

    /// A device validation plan that treats a missing result as a failure.
    static func devicePlan() throws -> DeviceValidationPlan {
        try DeviceValidationPlan(
            id: artifact("plan.device-validation"),
            schemaVersion: .v1,
            candidateConfigurations: [try candidate()],
            fixtureSuite: artifact("suite.fixtures"),
            modelBundle: bundle(),
            capabilityManifest: artifact("manifest.capability"),
            comparisons: [
                try ComparisonSpecification(
                    metric: .categoricalOutcome,
                    reference: evidence("evidence.reference"),
                    tolerance: nil,
                    requiredAgreement: .one
                )
            ],
            measurements: try measurementSpecifications(),
            missingResultRule: .treatAsFailure,
            approval: approval()
        )
    }

    /// One physical-device result set covering every mandatory gate exactly once.
    static func deviceResultSet(
        environment: ExecutionEnvironment = .physicalIPhone
    ) throws -> DeviceValidationResultSet {
        try DeviceValidationResultSet(
            id: artifact("results.device-validation"),
            schemaVersion: .v1,
            configuration: try candidate(),
            versionTuple: try versionTuple(),
            environment: environment,
            gateResults: try DeviceGate.mandatoryGates
                .sorted { $0.rawValue < $1.rawValue }
                .map { gate in
                    let applicable = !gate.isProvenanceConditional
                    return try DeviceGateResultRecord(
                        gate: gate,
                        applicability: applicable ? .applicable : notApplicable(),
                        outcome: applicable ? .passed : .notExecuted,
                        measurements: [],
                        comparisons: applicable
                            ? [
                                try ComparisonRecord(
                                    metric: .categoricalOutcome,
                                    specification: evidence("evidence.comparison"),
                                    comparedFixtureCount: nonNegative(96),
                                    agreeingFixtureCount: nonNegative(96),
                                    maximumDeviation: nil,
                                    outcome: .passed
                                )
                            ]
                            : []
                    )
                }
        )
    }
}

// MARK: - Versioned artifact descriptor

/// One versioned release artifact, prepared for the schema-version sweep.
///
/// The version is spliced into the encoded *text* rather than through a
/// serializer round trip, so every other byte of the payload is untouched. That
/// matters: re-serializing an artifact that carries an exact decimal — a
/// false-accusation budget, a predeclared confidence level — can perturb the
/// decimal and make decoding fail for a reason that has nothing to do with the
/// schema version, which would turn a refusal assertion into a vacuous one.
struct VersionedArtifact: Sendable, CustomTestStringConvertible {
    let name: String

    /// Encodes the sample, splices `mutation` over its `schemaVersion` value, and
    /// decodes the result. Returns the decoding failure, or `nil` when the payload
    /// was accepted.
    let decodeFailure: @Sendable (_ mutation: SchemaVersionMutation) throws -> (any Error)?

    /// Whether the untouched sample decodes back to an equal value.
    let roundTrips: @Sendable () throws -> Bool

    /// How many times `"schemaVersion"` appears in the encoded payload.
    let schemaVersionOccurrences: @Sendable () throws -> Int

    var testDescription: String { name }

    static func of<Artifact: Codable & Equatable & Sendable>(
        _ name: String,
        _ build: @escaping @Sendable () throws -> Artifact
    ) -> VersionedArtifact {
        VersionedArtifact(
            name: name,
            decodeFailure: { mutation in
                let payload = try CanonicalArtifactPayload.text(try build())
                let mutated = try #require(
                    mutation.spliced(into: payload),
                    "\(name) has no top-level schemaVersion to mutate"
                )
                do {
                    _ = try JSONDecoder().decode(Artifact.self, from: Data(mutated.utf8))
                    return nil
                } catch {
                    return error
                }
            },
            roundTrips: {
                let artifact = try build()
                let payload = try CanonicalArtifactPayload.bytes(artifact)
                return try JSONDecoder().decode(Artifact.self, from: Data(payload)) == artifact
            },
            schemaVersionOccurrences: {
                try CanonicalArtifactPayload.text(try build())
                    .ranges(of: "\"schemaVersion\":").count
            }
        )
    }
}

/// What a payload's `schemaVersion` member is replaced with.
enum SchemaVersionMutation: Sendable, CustomTestStringConvertible {
    /// The member is removed, so only a substituted default could let it decode.
    case absent
    /// The member holds this literal JSON value instead.
    case value(String)

    /// Versions and shapes this build cannot interpret.
    static let unreadable: [SchemaVersionMutation] = [
        .absent,
        .value("null"),
        .value("0"),
        .value("-1"),
        .value("\(ArtifactSchemaVersion.maximumSupported + 1)"),
        .value("\(ArtifactSchemaVersion.maximumSupported + 1000)"),
        .value("\"1\""),
        .value("1.5"),
        .value("true"),
    ]

    var testDescription: String {
        switch self {
        case .absent: return "absent"
        case .value(let literal): return literal
        }
    }

    /// `payload` with this mutation applied, or `nil` when it declares no version.
    func spliced(into payload: String) -> String? {
        let key = "\"schemaVersion\":"
        guard let keyRange = payload.range(of: key) else { return nil }

        var valueEnd = keyRange.upperBound
        while valueEnd < payload.endIndex, payload[valueEnd] != ",", payload[valueEnd] != "}" {
            valueEnd = payload.index(after: valueEnd)
        }

        switch self {
        case .value(let literal):
            return payload.replacingCharacters(
                in: keyRange.upperBound..<valueEnd,
                with: literal
            )
        case .absent:
            // Take one adjacent separator with the member so the result stays
            // well-formed JSON: an absent field has to be refused on its own merits,
            // not because the payload became unparseable.
            var start = keyRange.lowerBound
            var end = valueEnd
            if valueEnd < payload.endIndex, payload[valueEnd] == "," {
                end = payload.index(after: valueEnd)
            } else if start > payload.startIndex, payload[payload.index(before: start)] == "," {
                start = payload.index(before: start)
            }
            return payload.replacingCharacters(in: start..<end, with: "")
        }
    }
}

/// Every versioned release artifact the domain declares.
enum VersionedArtifacts {
    static let all: [VersionedArtifact] = [
        .of("PreprocessingContract") { try Sample.preprocessingContract() },
        .of("CalibrationPolicy") { try Sample.calibrationPolicy() },
        .of("ReleaseGatingSliceSpecification") { try Sample.gatingSlice() },
        .of("DatasetLineageRecord") { try Sample.datasetLineage() },
        .of("ProvenancePolicy") { try Sample.provenancePolicy() },
        .of("EvidenceFusionRule") { try Sample.fusionRule() },
        .of("DataLifecyclePolicy") { try Sample.lifecyclePolicy() },
        .of("ExtensionExecutionPolicy") { try Sample.extensionExecutionPolicy() },
        .of("ResourceBudget") { try Sample.resourceBudget(target: .mainApplication) },
        .of("ModelBundleManifest") { try Sample.manifest() },
        .of("ReleaseSelfTestSpecification") { try Sample.selfTestSpecification() },
        .of("BundleVerificationPolicy") { try Sample.verificationPolicy() },
        .of("ActivationReceipt") { try Sample.activationReceipt() },
        .of("ReleaseCapabilityManifest") { try Sample.capabilityManifest() },
        .of("ReleaseApprovedDeviceAllowlist") {
            try Sample.allowlist(entries: [try Sample.approvedConfiguration()])
        },
        .of("DeviceValidationPlan") { try Sample.devicePlan() },
        .of("DeviceValidationResultSet") { try Sample.deviceResultSet() },
        .of("ReleaseFixtureSuite") { try Sample.fixtureSuite() },
        .of("ApprovedVerdictCopyCatalog") { try Sample.copyCatalog() },
        .of("AccessibilityGateMatrix") { try Sample.accessibilityMatrix() },
        .of("ReleaseReadinessRecord") { try Sample.releaseRecord() },
    ]
}

// MARK: - Artifact schema versions

@Suite("Release artifact schema versions")
struct ArtifactSchemaVersionTests {

    @Test("Every versioned artifact round trips through its own encoding",
          arguments: VersionedArtifacts.all)
    func artifactRoundTrips(artifact: VersionedArtifact) throws {
        #expect(try artifact.roundTrips(), "\(artifact.name) did not survive a round trip")
    }

    @Test("Every artifact declares exactly one schema version",
          arguments: VersionedArtifacts.all)
    func oneVersionPerArtifact(artifact: VersionedArtifact) throws {
        // One version per artifact, at the top level. A nested second version would
        // make "the schema version of this artifact" ambiguous, and would make the
        // sweep below mutate an arbitrary one of them.
        let declared = try artifact.schemaVersionOccurrences()
        #expect(declared == 1, "\(artifact.name) declares \(declared) schema versions")
    }

    @Test("The declared schema version is accepted, so refusal is not blanket",
          arguments: VersionedArtifacts.all)
    func declaredVersionAccepted(artifact: VersionedArtifact) throws {
        // The negative control for the refusal sweep: splicing the version this build
        // does support has to leave the payload decodable, or every refusal below
        // would pass for an unrelated reason.
        #expect(
            try artifact.decodeFailure(
                .value("\(ArtifactSchemaVersion.maximumSupported)")
            ) == nil,
            "\(artifact.name) refused its own schema version"
        )
    }

    @Test(
        "An unreadable schema version is refused, for every artifact",
        arguments: VersionedArtifacts.all,
        SchemaVersionMutation.unreadable
    )
    func unreadableVersionRefused(
        artifact: VersionedArtifact,
        mutation: SchemaVersionMutation
    ) throws {
        let failure = try artifact.decodeFailure(mutation)
        #expect(
            failure is DecodingError,
            """
            \(artifact.name) accepted schemaVersion \(mutation.testDescription), \
            so something interpreted or substituted a version this build does not support
            """
        )
    }

    @Test("An out-of-range version names schemaVersion as the cause",
          arguments: VersionedArtifacts.all)
    func versionFaultNamesTheField(artifact: VersionedArtifact) throws {
        // A fail-closed decode is only useful to an audit if it says which field
        // failed. Both directions are checked: below the floor and above the ceiling.
        for (mutation, expected) in [
            (
                SchemaVersionMutation.value("0"),
                ArtifactSchemaError.nonPositiveValue(field: "schemaVersion", value: "0")
            ),
            (
                SchemaVersionMutation.value("\(ArtifactSchemaVersion.maximumSupported + 1)"),
                ArtifactSchemaError.valueOutOfRange(
                    field: "schemaVersion",
                    value: "\(ArtifactSchemaVersion.maximumSupported + 1)",
                    allowed: "1...\(ArtifactSchemaVersion.maximumSupported)"
                )
            ),
        ] {
            let failure = try #require(
                try artifact.decodeFailure(mutation),
                "\(artifact.name) accepted \(mutation.testDescription)"
            )
            #expect(
                Self.underlyingSchemaError(of: failure) == expected,
                "\(artifact.name) reported \(failure) rather than \(expected)"
            )
        }
    }

    @Test("Only version 1 exists in this source revision")
    func supportedVersionRange() throws {
        #expect(ArtifactSchemaVersion.maximumSupported == 1)
        #expect(ArtifactSchemaVersion.v1.value == 1)
        #expect(try ArtifactSchemaVersion(validating: 1) == .v1)
        #expect(ArtifactSchemaVersion.v1.rawSchemaValue == 1)
        #expect(ArtifactSchemaVersion.v1.description == "1")
    }

    @Test("A schema version is not comparable across an unsupported boundary")
    func versionOrdering() throws {
        // Ordering exists so a later revision can compare versions. It cannot be used
        // to accept an unsupported one, because such a value is unconstructible.
        #expect(try ArtifactSchemaVersion(validating: 1) == ArtifactSchemaVersion.v1)
        #expect(throws: ArtifactSchemaError.self) {
            try ArtifactSchemaVersion(validating: ArtifactSchemaVersion.maximumSupported + 1)
        }
        #expect(throws: ArtifactSchemaError.self) { try ArtifactSchemaVersion(validating: 0) }
        #expect(throws: ArtifactSchemaError.self) { try ArtifactSchemaVersion(validating: -7) }
    }

    /// The `ArtifactSchemaError` a decoding failure was raised for, if any.
    private static func underlyingSchemaError(of error: any Error) -> ArtifactSchemaError? {
        guard case let .dataCorrupted(context) = error as? DecodingError else { return nil }
        return context.underlyingError as? ArtifactSchemaError
    }
}

// MARK: - Registry coverage

@Suite("Versioned value registry coverage")
struct VersionedValueCoverageTests {

    @Test("The sweep covers every artifact that declares an artifact schema version")
    func artifactRegistryIsComplete() throws {
        let owners = try DomainSources.typesDeclaring(member: "schemaVersion", from: #filePath)
        let declared = try #require(owners["ArtifactSchemaVersion"])
        #expect(!declared.isEmpty, "no versioned artifacts were found to audit")

        // An unswept artifact is one whose version handling nobody checked: an
        // unreadable version could be interpreted or substituted there and no test
        // would notice. Add it to `VersionedArtifacts` rather than relaxing this.
        let registered = Set(VersionedArtifacts.all.map(\.name))
        let missing = declared.subtracting(registered).sorted()
        let stale = registered.subtracting(declared).sorted()
        #expect(missing.isEmpty, "versioned artifacts missing from the sweep: \(missing)")
        #expect(stale.isEmpty, "swept names that are no longer versioned artifacts: \(stale)")
    }

    @Test("Exactly four core session values carry their own schema version")
    func coreVersionedValues() throws {
        let owners = try DomainSources.typesDeclaring(member: "schemaVersion", from: #filePath)
        // The artifact layer uses the validated `ArtifactSchemaVersion` scalar. A core
        // session value uses a plain `Int` and validates it in its own initializer,
        // because it is built in process rather than read from signed bytes. Pinning
        // the list keeps a fifth one from appearing unversioned or unchecked.
        #expect(
            owners["Int"] == [
                "EvidenceReport",
                "AnalysisFailureSnapshot",
                "InputQualityRecord",
                "ShareTransferTicket",
            ]
        )
        #expect(owners.keys.sorted() == ["ArtifactSchemaVersion", "Int"])
    }

    @Test("Registry entries are distinct")
    func registryHasNoDuplicates() {
        let names = VersionedArtifacts.all.map(\.name)
        #expect(Set(names).count == names.count, "an artifact is swept twice")
    }
}

// MARK: - Core session value versions

@Suite("Core session value schema versions")
struct CoreSchemaVersionTests {

    @Test("Every core versioned value is at version 1")
    func currentVersions() {
        #expect(EvidenceReport.currentSchemaVersion == 1)
        #expect(AnalysisFailureSnapshot.currentSchemaVersion == 1)
        #expect(InputQualityRecord.currentSchemaVersion == 1)
        #expect(ShareTransferTicket.currentSchemaVersion == 1)
    }

    @Test("An Evidence Report cannot be constructed at another version")
    func reportVersionGoverned() {
        #expect(SessionValue.report(schemaVersion: 1) != nil)
        for version in [0, -1, 2, 99] {
            #expect(
                SessionValue.report(schemaVersion: version) == nil,
                "an Evidence Report was built at schema version \(version)"
            )
        }
    }

    @Test("A failure snapshot cannot be constructed at another version")
    func snapshotVersionGoverned() {
        #expect(SessionValue.snapshot(schemaVersion: 1) != nil)
        for version in [0, -1, 2, 99] {
            #expect(
                SessionValue.snapshot(schemaVersion: version) == nil,
                "a failure snapshot was built at schema version \(version)"
            )
        }
    }

    @Test("A quality record refuses another version, on construction and on decode")
    func qualityRecordVersionGoverned() throws {
        #expect(InputQualityRecord.unmeasured.schemaVersion == 1)
        for version in [0, -1, 2, 99] {
            #expect(
                InputQualityRecord(
                    schemaVersion: version,
                    decodedWidthBeforeOrientation: 900,
                    decodedHeightBeforeOrientation: 600
                ) == nil,
                "a quality record was built at schema version \(version)"
            )
        }

        let record = try #require(
            InputQualityRecord(
                decodedWidthBeforeOrientation: 900,
                decodedHeightBeforeOrientation: 600
            )
        )
        #expect(try Self.decodes(record) == record)
        for version in [0, 2] {
            let mutated = try #require(
                try CanonicalArtifactPayload.replacingTopLevelValue(
                    "schemaVersion",
                    with: version,
                    in: record
                )
            )
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(InputQualityRecord.self, from: Data(mutated))
            }
        }
    }

    @Test("A Share ticket refuses another version, on construction and on decode")
    func shareTicketVersionGoverned() throws {
        let ticket = try #require(SessionValue.ticket())
        #expect(try Self.decodes(ticket) == ticket)

        for version in [0, -1, 2, 99] {
            #expect(
                SessionValue.ticket(schemaVersion: version) == nil,
                "a Share ticket was built at schema version \(version)"
            )
        }
        for version in [0, 2] {
            let mutated = try #require(
                try CanonicalArtifactPayload.replacingTopLevelValue(
                    "schemaVersion",
                    with: version,
                    in: ticket
                )
            )
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(ShareTransferTicket.self, from: Data(mutated))
            }
        }
        // A ticket crosses a process boundary, so an absent version is as unreadable as
        // a wrong one: nothing may assume the current revision wrote it.
        let removed = try #require(
            try CanonicalArtifactPayload.removingTopLevelKey("schemaVersion", from: ticket)
        )
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ShareTransferTicket.self, from: Data(removed))
        }
    }

    @Test("A report and a terminal outcome have no serialized form at all")
    func reportHasNoSerializedForm() {
        // The design keeps an Evidence Report in memory for the active session and
        // then discards it: there is no save, export, share, or history surface. That
        // is enforced by the type not being codable, so there is no serialized shape
        // for a result to leak through. A codable report would be a new persistence
        // path rather than a formatting detail.
        for type in [
            EvidenceReport.self as Any.Type,
            SessionTerminalOutcome.self,
            AnalysisFailureSnapshot.self,
            AnalysisSessionBinding.self,
        ] {
            #expect(!Self.isEncodable(type), "\(type) gained a serialized form")
            #expect(!Self.isDecodable(type), "\(type) gained a serialized form")
        }

        // The two values that legitimately cross a boundary are codable, so the check
        // above distinguishes "not serializable" from "nothing is serializable".
        for type in [ShareTransferTicket.self as Any.Type, InputQualityRecord.self] {
            #expect(Self.isEncodable(type) && Self.isDecodable(type))
        }
    }

    private static func isEncodable(_ type: Any.Type) -> Bool { type is any Encodable.Type }

    private static func isDecodable(_ type: Any.Type) -> Bool { type is any Decodable.Type }

    private static func decodes<Value: Codable>(_ value: Value) throws -> Value {
        try JSONDecoder().decode(
            Value.self,
            from: Data(try CanonicalArtifactPayload.bytes(value))
        )
    }
}
