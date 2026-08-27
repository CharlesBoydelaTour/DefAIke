import DefAIkeDomain

/// An in-memory ``PolicyArtifactReading`` and ``ReleaseEvidenceReading`` pair.
///
/// Registration is explicit and lookup is by exact identifier. There is no default, no
/// fallback, and no synthesized artifact: an unregistered identifier is
/// ``ReleaseArtifactError/notFound(_:)``. That is the whole point of the double — it lets
/// a test show that an absent policy or an absent gate record fails closed, which is
/// impossible to demonstrate against a reader that invents one (Requirements 11.1, 14.1,
/// and 14.15).
///
/// It stores only values that already passed their own schema validation, because every
/// artifact type in `ReleaseArtifacts` validates in its initializer. A malformed artifact
/// is therefore not registrable: malformed-encoding tests build payload bytes with
/// ``CanonicalArtifactPayload`` and decode them through `BoundedArtifactDecoder` instead
/// of going through this store.
public actor InMemoryArtifactStore: PolicyArtifactReading, ReleaseEvidenceReading {
    private let recorder: PortCallRecorder?

    // Runtime policies.
    private var capabilityManifests: [ArtifactID: ReleaseCapabilityManifest] = [:]
    private var deviceAllowlists: [ArtifactID: ReleaseApprovedDeviceAllowlist] = [:]
    private var lifecyclePolicies: [ArtifactID: DataLifecyclePolicy] = [:]
    private var extensionPolicies: [ArtifactID: ExtensionExecutionPolicy] = [:]
    private var resourceBudgets: [ArtifactID: ResourceBudget] = [:]
    private var verificationPolicies: [ArtifactID: BundleVerificationPolicy] = [:]
    private var preprocessingContracts: [ArtifactID: PreprocessingContract] = [:]
    private var calibrationPolicies: [ArtifactID: CalibrationPolicy] = [:]
    private var verdictCopyCatalogs: [ArtifactID: ApprovedVerdictCopyCatalog] = [:]
    private var provenancePolicies: [ArtifactID: ProvenancePolicy] = [:]
    private var fusionRules: [ArtifactID: EvidenceFusionRule] = [:]

    // Release evidence.
    private var validationPlans: [ArtifactID: DeviceValidationPlan] = [:]
    private var validationResults: [ArtifactID: DeviceValidationResultSet] = [:]
    private var fixtureSuites: [ArtifactID: ReleaseFixtureSuite] = [:]
    private var accessibilityMatrices: [ArtifactID: AccessibilityGateMatrix] = [:]
    private var datasetLineages: [ArtifactID: DatasetLineageRecord] = [:]
    private var calibrationSlices: [ReleaseSliceID: CalibrationSliceResult] = [:]
    private var readinessRecords: [ArtifactID: ReleaseReadinessRecord] = [:]

    public init(recorder: PortCallRecorder? = nil) {
        self.recorder = recorder
    }

    // MARK: - Registration

    public func register(_ value: ReleaseCapabilityManifest) { capabilityManifests[value.id] = value }
    public func register(_ value: ReleaseApprovedDeviceAllowlist) { deviceAllowlists[value.id] = value }
    public func register(_ value: DataLifecyclePolicy) { lifecyclePolicies[value.id] = value }
    public func register(_ value: ExtensionExecutionPolicy) { extensionPolicies[value.id] = value }
    public func register(_ value: ResourceBudget) { resourceBudgets[value.id] = value }
    public func register(_ value: BundleVerificationPolicy) { verificationPolicies[value.id] = value }
    public func register(_ value: PreprocessingContract) { preprocessingContracts[value.id] = value }
    public func register(_ value: CalibrationPolicy) { calibrationPolicies[value.id] = value }
    public func register(_ value: ApprovedVerdictCopyCatalog) { verdictCopyCatalogs[value.id] = value }
    public func register(_ value: ProvenancePolicy) { provenancePolicies[value.id] = value }
    public func register(_ value: EvidenceFusionRule) { fusionRules[value.id] = value }
    public func register(_ value: DeviceValidationPlan) { validationPlans[value.id] = value }
    public func register(_ value: DeviceValidationResultSet) { validationResults[value.id] = value }
    public func register(_ value: ReleaseFixtureSuite) { fixtureSuites[value.id] = value }
    public func register(_ value: AccessibilityGateMatrix) { accessibilityMatrices[value.id] = value }
    public func register(_ value: DatasetLineageRecord) { datasetLineages[value.id] = value }
    public func register(_ value: CalibrationSliceResult) { calibrationSlices[value.slice] = value }
    public func register(_ value: ReleaseReadinessRecord) { readinessRecords[value.id] = value }

    /// Registers both target budgets at once.
    public func register(_ budgets: ResourceBudgetSet) {
        register(budgets.mainApplication)
        register(budgets.shareExtension)
    }

    /// Removes one registration, so a test can show what an absent artifact does.
    public func forgetPolicyArtifact(_ id: ArtifactID) {
        capabilityManifests.removeValue(forKey: id)
        deviceAllowlists.removeValue(forKey: id)
        lifecyclePolicies.removeValue(forKey: id)
        extensionPolicies.removeValue(forKey: id)
        resourceBudgets.removeValue(forKey: id)
        verificationPolicies.removeValue(forKey: id)
        preprocessingContracts.removeValue(forKey: id)
        calibrationPolicies.removeValue(forKey: id)
        verdictCopyCatalogs.removeValue(forKey: id)
        provenancePolicies.removeValue(forKey: id)
        fusionRules.removeValue(forKey: id)
    }

    /// Removes one release-evidence registration.
    public func forgetReleaseEvidence(_ id: ArtifactID) {
        validationPlans.removeValue(forKey: id)
        validationResults.removeValue(forKey: id)
        fixtureSuites.removeValue(forKey: id)
        accessibilityMatrices.removeValue(forKey: id)
        datasetLineages.removeValue(forKey: id)
        readinessRecords.removeValue(forKey: id)
    }

    // MARK: - PolicyArtifactReading

    public func capabilityManifest(
        _ id: ArtifactID
    ) throws(ReleaseArtifactError) -> ReleaseCapabilityManifest {
        try require(capabilityManifests[id], id)
    }

    public func deviceAllowlist(
        _ id: ArtifactID
    ) throws(ReleaseArtifactError) -> ReleaseApprovedDeviceAllowlist {
        try require(deviceAllowlists[id], id)
    }

    public func lifecyclePolicy(
        _ id: ArtifactID
    ) throws(ReleaseArtifactError) -> DataLifecyclePolicy {
        try require(lifecyclePolicies[id], id)
    }

    public func extensionExecutionPolicy(
        _ id: ArtifactID
    ) throws(ReleaseArtifactError) -> ExtensionExecutionPolicy {
        try require(extensionPolicies[id], id)
    }

    public func resourceBudgets(
        mainApplication: ArtifactID,
        shareExtension: ArtifactID
    ) throws(ReleaseArtifactError) -> ResourceBudgetSet {
        let application = try require(resourceBudgets[mainApplication], mainApplication)
        let `extension` = try require(resourceBudgets[shareExtension], shareExtension)
        do {
            return try ResourceBudgetSet(
                mainApplication: application,
                shareExtension: `extension`
            )
        } catch let error as ArtifactSchemaError {
            throw .invalid(error)
        } catch {
            throw .storeUnavailable
        }
    }

    public func bundleVerificationPolicy(
        _ id: ArtifactID
    ) throws(ReleaseArtifactError) -> BundleVerificationPolicy {
        try require(verificationPolicies[id], id)
    }

    public func preprocessingContract(
        _ id: ArtifactID
    ) throws(ReleaseArtifactError) -> PreprocessingContract {
        try require(preprocessingContracts[id], id)
    }

    public func calibrationPolicy(
        _ id: ArtifactID
    ) throws(ReleaseArtifactError) -> CalibrationPolicy {
        try require(calibrationPolicies[id], id)
    }

    public func verdictCopyCatalog(
        _ id: ArtifactID
    ) throws(ReleaseArtifactError) -> ApprovedVerdictCopyCatalog {
        try require(verdictCopyCatalogs[id], id)
    }

    public func provenancePolicy(
        _ id: ArtifactID
    ) throws(ReleaseArtifactError) -> ProvenancePolicy {
        try require(provenancePolicies[id], id)
    }

    public func fusionRule(
        _ id: ArtifactID
    ) throws(ReleaseArtifactError) -> EvidenceFusionRule {
        try require(fusionRules[id], id)
    }

    // MARK: - ReleaseEvidenceReading

    public func validationPlan(
        _ id: ArtifactID
    ) throws(ReleaseArtifactError) -> DeviceValidationPlan {
        try requireEvidence(validationPlans[id], id)
    }

    public func validationResults(
        _ id: ArtifactID
    ) throws(ReleaseArtifactError) -> DeviceValidationResultSet {
        try requireEvidence(validationResults[id], id)
    }

    public func fixtureSuite(
        _ id: ArtifactID
    ) throws(ReleaseArtifactError) -> ReleaseFixtureSuite {
        try requireEvidence(fixtureSuites[id], id)
    }

    public func accessibilityGateMatrix(
        _ id: ArtifactID
    ) throws(ReleaseArtifactError) -> AccessibilityGateMatrix {
        try requireEvidence(accessibilityMatrices[id], id)
    }

    public func datasetLineage(
        _ id: ArtifactID
    ) throws(ReleaseArtifactError) -> DatasetLineageRecord {
        try requireEvidence(datasetLineages[id], id)
    }

    public func calibrationSliceResult(
        _ id: ReleaseSliceID
    ) throws(ReleaseArtifactError) -> CalibrationSliceResult {
        recorder?.record(.readReleaseEvidence(sliceArtifactID(id)))
        guard let value = calibrationSlices[id] else {
            throw .notFound(sliceArtifactID(id))
        }
        return value
    }

    public func releaseReadinessRecord(
        _ id: ArtifactID
    ) throws(ReleaseArtifactError) -> ReleaseReadinessRecord {
        try requireEvidence(readinessRecords[id], id)
    }

    // MARK: - Helpers

    private func require<Value>(
        _ value: Value?,
        _ id: ArtifactID
    ) throws(ReleaseArtifactError) -> Value {
        recorder?.record(.readPolicyArtifact(id))
        guard let value else { throw .notFound(id) }
        return value
    }

    private func requireEvidence<Value>(
        _ value: Value?,
        _ id: ArtifactID
    ) throws(ReleaseArtifactError) -> Value {
        recorder?.record(.readReleaseEvidence(id))
        guard let value else { throw .notFound(id) }
        return value
    }

    /// A slice identifier reported through the ``ArtifactID``-shaped error case.
    ///
    /// Slice results are keyed by ``ReleaseSliceID``; the error vocabulary names artifacts.
    /// The conversion is syntactic, and both identifier types share the same canonical
    /// syntax, so it cannot fail.
    private func sliceArtifactID(_ id: ReleaseSliceID) -> ArtifactID {
        guard let artifactID = ArtifactID(id.rawValue) else {
            preconditionFailure("a canonical slice identifier is a canonical artifact identifier")
        }
        return artifactID
    }
}
