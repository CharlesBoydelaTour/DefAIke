import DefAIkeDomain

/// A bundle manager over an in-memory catalogue of locally installed candidates.
///
/// Faithful to the parts activation properties depend on:
///
///   * only candidates the test installed exist — there is no fetch, download, or remote
///     catalogue member, matching the port;
///   * activation and rollback run the identical path, so "prior" gets no free pass;
///   * activation is atomic against an injected failure: on any programmed failure the
///     previously active bundle stays exactly as it was, so an observer sees the complete
///     old tuple or the complete new one; and
///   * an incompatible bundle is `model-load-error` and never falls through to an older
///     asset.
///
/// It performs no signature verification, no digest streaming, and no self-test execution.
/// Those need real cryptography and a real compiled model and belong to task 6.11.
public actor StubModelBundleManager: ModelBundleManaging {
    /// Where a programmed activation failure lands.
    ///
    /// Named after the design's fixed verification order so a fault-injection test states
    /// the boundary it means rather than a step number.
    public enum ActivationFailurePoint: String, Hashable, Sendable, CaseIterable {
        case manifestVerification
        case signatureVerification
        case artifactDigests
        case compatibility
        case selfTests
        case receiptWrite
        case pointerWrite
        case modelLoad
    }

    private let recorder: PortCallRecorder?
    private var catalogue: [ModelBundleID: BoundModelBundle] = [:]
    private var activeBundleID: ModelBundleID?
    private var failurePoints: [ModelBundleID: ActivationFailurePoint] = [:]

    public init(recorder: PortCallRecorder? = nil) {
        self.recorder = recorder
    }

    // MARK: - Programming

    /// Installs a locally available candidate.
    public func install(_ bundle: BoundModelBundle) {
        catalogue[bundle.bundleID] = bundle
    }

    /// Installs a candidate and makes it active without running the activation path,
    /// modelling the bundle delivered inside the application version.
    public func installAndActivate(_ bundle: BoundModelBundle) {
        catalogue[bundle.bundleID] = bundle
        activeBundleID = bundle.bundleID
    }

    /// Makes activation of `id` fail at `point`.
    public func failActivation(of id: ModelBundleID, at point: ActivationFailurePoint) {
        failurePoints[id] = point
    }

    /// Clears a programmed failure.
    public func succeedActivation(of id: ModelBundleID) {
        failurePoints.removeValue(forKey: id)
    }

    // MARK: - Inspection

    /// The complete currently active tuple, or `nil` when nothing is active.
    ///
    /// The atomicity oracle: it is either a complete bundle or nothing, never a mixture.
    public func activeBundle() -> BoundModelBundle? {
        activeBundleID.flatMap { catalogue[$0] }
    }

    /// Where activation of `id` is programmed to fail.
    public func programmedFailurePoint(of id: ModelBundleID) -> ActivationFailurePoint? {
        failurePoints[id]
    }

    // MARK: - ModelBundleManaging

    public func verifiedActiveBundle(
        for context: ReleaseContext
    ) throws(AnalysisFault) -> BoundModelBundle {
        recorder?.record(.verifiedActiveBundle)
        guard let bundle = activeBundle() else {
            throw .analysis(.modelLoadError, stage: .modelLoad)
        }
        guard bundle.isCompatible(with: context) else {
            throw .analysis(.modelLoadError, stage: .modelLoad)
        }
        return bundle
    }

    public func activateLocalCandidate(
        _ id: ModelBundleID,
        context: ReleaseContext
    ) throws(AnalysisFault) -> BoundModelBundle {
        recorder?.record(.activateLocalCandidate(id))
        return try verifyAndActivate(id, context: context)
    }

    public func rollback(
        to id: ModelBundleID,
        context: ReleaseContext
    ) throws(AnalysisFault) -> BoundModelBundle {
        recorder?.record(.rollback(id))
        // The identical path: a retained bundle is re-verified exactly like a new one.
        return try verifyAndActivate(id, context: context)
    }

    // MARK: - Helpers

    private func verifyAndActivate(
        _ id: ModelBundleID,
        context: ReleaseContext
    ) throws(AnalysisFault) -> BoundModelBundle {
        guard let candidate = catalogue[id] else {
            throw .analysis(.modelLoadError, stage: .modelLoad)
        }
        if failurePoints[id] != nil {
            // Every failure point behaves identically from the outside: the active
            // pointer is untouched and the outcome is model-load-error.
            throw .analysis(.modelLoadError, stage: .modelLoad)
        }
        guard candidate.isCompatible(with: context) else {
            throw .analysis(.modelLoadError, stage: .modelLoad)
        }
        // The commit: one assignment, after every check.
        activeBundleID = id
        return candidate
    }
}
