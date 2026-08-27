// The artifact-reading ports.
//
// Every policy, budget, deadline, boundary, trust rule, mapping, allowlist entry, and
// gate result is an externally approved, versioned input. Code reaches them only through
// these two ports, and only by exact identifier, which is what makes "no source-code
// default" checkable: there is no `defaultPolicy`, no `orDefault`, and no member that
// synthesizes an artifact when one is absent (Requirements 11.1, 14.1, and 14.15).
//
// The split is by role, not convenience:
//
//   * ``PolicyArtifactReading`` is what a shipping build reads at startup to decide
//     whether it may expose ingest at all.
//   * ``ReleaseEvidenceReading`` is what nonshipping tooling in
//     `DefAIkeReleaseValidation` reads to evaluate release eligibility. It is never
//     linked into a shipping composition.

/// Why a required artifact could not be supplied.
///
/// Distinct from ``ArtifactSchemaError``, which says an artifact is malformed. Absence
/// and malformation are both fail-closed, but they are different audit findings: a
/// missing artifact is a packaging or signing fault, a malformed one is an authoring
/// fault. Neither is ever an ``AnalysisError``, because a failed startup gate keeps
/// ingest unavailable instead of producing a user-facing evidence error.
/// `Equatable` rather than `Hashable`, matching ``ArtifactSchemaError``.
public enum ReleaseArtifactError: Error, Equatable, Sendable {
    /// No artifact exists under this identifier.
    case notFound(ArtifactID)

    /// The artifact exists but is not schema-valid.
    case invalid(ArtifactSchemaError)

    /// The artifact exists but its encoded bytes are unreadable.
    ///
    /// Separate from ``invalid(_:)`` because it is a different audit finding: the
    /// payload broke its bounded encoding profile, omitted a required field, or named
    /// semantics this build does not implement, so no artifact value was ever formed.
    case undecodable(ArtifactDecodingError)

    /// The artifact was found under a different identifier than the one requested,
    /// which means a reference does not resolve to what it names.
    case identifierMismatch(requested: ArtifactID, found: ArtifactID)

    /// The artifact store itself is unreadable. Carries no path and no framework error.
    case storeUnavailable
}

/// Reads the signed policies a shipping build needs.
///
/// Each member takes the exact identifier the build is bound to and returns the
/// validated value or throws. There is no "current" or "latest" accessor: a build reads
/// the version its signed capability manifest names, so an artifact swap cannot change
/// behavior without changing the manifest.
public protocol PolicyArtifactReading: Sendable {
    func capabilityManifest(
        _ id: ArtifactID
    ) async throws(ReleaseArtifactError) -> ReleaseCapabilityManifest

    func deviceAllowlist(
        _ id: ArtifactID
    ) async throws(ReleaseArtifactError) -> ReleaseApprovedDeviceAllowlist

    func lifecyclePolicy(
        _ id: ArtifactID
    ) async throws(ReleaseArtifactError) -> DataLifecyclePolicy

    func extensionExecutionPolicy(
        _ id: ArtifactID
    ) async throws(ReleaseArtifactError) -> ExtensionExecutionPolicy

    /// Both target budgets together.
    ///
    /// Requirement 11.1 is about the pair: a release with a main-application budget and
    /// no extension budget is invalid, so the pair is what a reader returns.
    func resourceBudgets(
        mainApplication: ArtifactID,
        shareExtension: ArtifactID
    ) async throws(ReleaseArtifactError) -> ResourceBudgetSet

    func bundleVerificationPolicy(
        _ id: ArtifactID
    ) async throws(ReleaseArtifactError) -> BundleVerificationPolicy

    func preprocessingContract(
        _ id: ArtifactID
    ) async throws(ReleaseArtifactError) -> PreprocessingContract

    func calibrationPolicy(
        _ id: ArtifactID
    ) async throws(ReleaseArtifactError) -> CalibrationPolicy

    func verdictCopyCatalog(
        _ id: ArtifactID
    ) async throws(ReleaseArtifactError) -> ApprovedVerdictCopyCatalog

    /// The Provenance Policy for a provenance-enabled build.
    ///
    /// Called only when the signed capability manifest binds one. A pixel-only build has
    /// an approved not-applicable decision instead of an identifier, so it never calls
    /// this and never needs a policy to exist.
    func provenancePolicy(
        _ id: ArtifactID
    ) async throws(ReleaseArtifactError) -> ProvenancePolicy

    /// The Evidence Fusion Rule, when the manifest binds one.
    ///
    /// A build with no bound rule shows no Combined Summary, which is a permitted
    /// release (Requirement 7.16).
    func fusionRule(
        _ id: ArtifactID
    ) async throws(ReleaseArtifactError) -> EvidenceFusionRule
}

/// Reads the immutable release evidence that decides distribution eligibility.
///
/// Implemented by nonshipping tooling. It reads records; it never writes, approves,
/// waives, or synthesizes one. A missing record is
/// ``ReleaseArtifactError/notFound(_:)``, which the evaluating validator treats as a
/// failed gate rather than as an absent-and-therefore-inapplicable gate: missing is never
/// equivalent to pass (Requirement 14.15).
public protocol ReleaseEvidenceReading: Sendable {
    func validationPlan(
        _ id: ArtifactID
    ) async throws(ReleaseArtifactError) -> DeviceValidationPlan

    /// The recorded outcome set for one candidate configuration.
    ///
    /// Result sets are never pooled across version tuples, so each is read by its own
    /// identifier and carries the tuple it was produced under (Requirement 13.20).
    func validationResults(
        _ id: ArtifactID
    ) async throws(ReleaseArtifactError) -> DeviceValidationResultSet

    func fixtureSuite(
        _ id: ArtifactID
    ) async throws(ReleaseArtifactError) -> ReleaseFixtureSuite

    func accessibilityGateMatrix(
        _ id: ArtifactID
    ) async throws(ReleaseArtifactError) -> AccessibilityGateMatrix

    func datasetLineage(
        _ id: ArtifactID
    ) async throws(ReleaseArtifactError) -> DatasetLineageRecord

    /// The recorded metrics for one mandatory calibration slice.
    func calibrationSliceResult(
        _ id: ReleaseSliceID
    ) async throws(ReleaseArtifactError) -> CalibrationSliceResult

    func releaseReadinessRecord(
        _ id: ArtifactID
    ) async throws(ReleaseArtifactError) -> ReleaseReadinessRecord
}
