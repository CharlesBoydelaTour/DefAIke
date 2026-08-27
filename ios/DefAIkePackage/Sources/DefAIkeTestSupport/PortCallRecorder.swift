import DefAIkeDomain

/// One recorded port invocation.
///
/// Several properties are about a call that must *not* happen: an unsupported container
/// short-circuits before preprocessing, provenance, inference, calibration, and report
/// construction (Property 3); a handoff mismatch makes no downstream call at all
/// (Property 6); inference starts only after a complete successful decode (Property 8);
/// a cancelled session commits no evidence (Property 35). Asserting nonoccurrence needs
/// one shared, typed, ordered log rather than a boolean per double, which is what this
/// enum plus ``PortCallRecorder`` provides.
///
/// A case carries only the session identity where one exists. It never carries bytes,
/// dimensions, logits, evidence, or a token's raw value, so a recorder cannot become a
/// back channel that leaks what a port was refused access to.
public enum PortCall: Hashable, Sendable {
    // Ingest and transfer.
    case photosImport(AnalysisSessionID)
    case shareStage(ShareTransferID)
    case sharePeek
    case shareClaim
    case shareDiscardStaged

    // Image pipeline.
    case validate(AnalysisSessionID)
    case preprocess(AnalysisSessionID)

    // Model bundle and inference.
    case verifiedActiveBundle
    case activateLocalCandidate(ModelBundleID)
    case rollback(ModelBundleID)
    case loadModel(ModelBundleID)
    case infer(AnalysisSessionID)
    case calibrate

    // Evidence.
    case provenanceAnalyze(AnalysisSessionID)
    case fuse

    // Resources and lifecycle.
    case reserveResource(ResourceMetric)
    case releaseResource(ResourceMetric)
    case observeResource(ResourceMetric)
    case deleteSession(AnalysisSessionID)
    case deleteAbandonedData

    // Artifact reading.
    case readPolicyArtifact(ArtifactID)
    case readReleaseEvidence(ArtifactID)

    /// Calls that must not occur once a terminal outcome is committed.
    ///
    /// Requirement 11.14 stops pending decode, preprocessing, provenance validation, and
    /// inference on cancellation, and Requirement 11.18 forbids any evidence commit after
    /// a failure. Cleanup is deliberately absent: cleanup is exactly what *should* still
    /// run after a terminal outcome.
    public static let evidenceProducingCalls: Set<PortCallKind> = [
        .validate, .preprocess, .loadModel, .infer, .calibrate, .provenanceAnalyze, .fuse,
    ]

    /// This call's kind, with its payload dropped.
    public var kind: PortCallKind {
        switch self {
        case .photosImport: .photosImport
        case .shareStage: .shareStage
        case .sharePeek: .sharePeek
        case .shareClaim: .shareClaim
        case .shareDiscardStaged: .shareDiscardStaged
        case .validate: .validate
        case .preprocess: .preprocess
        case .verifiedActiveBundle: .verifiedActiveBundle
        case .activateLocalCandidate: .activateLocalCandidate
        case .rollback: .rollback
        case .loadModel: .loadModel
        case .infer: .infer
        case .calibrate: .calibrate
        case .provenanceAnalyze: .provenanceAnalyze
        case .fuse: .fuse
        case .reserveResource: .reserveResource
        case .releaseResource: .releaseResource
        case .observeResource: .observeResource
        case .deleteSession: .deleteSession
        case .deleteAbandonedData: .deleteAbandonedData
        case .readPolicyArtifact: .readPolicyArtifact
        case .readReleaseEvidence: .readReleaseEvidence
        }
    }
}

/// A ``PortCall`` with its payload dropped, for "did this kind of call happen" checks.
public enum PortCallKind: String, Hashable, Sendable, CaseIterable {
    case photosImport
    case shareStage
    case sharePeek
    case shareClaim
    case shareDiscardStaged
    case validate
    case preprocess
    case verifiedActiveBundle
    case activateLocalCandidate
    case rollback
    case loadModel
    case infer
    case calibrate
    case provenanceAnalyze
    case fuse
    case reserveResource
    case releaseResource
    case observeResource
    case deleteSession
    case deleteAbandonedData
    case readPolicyArtifact
    case readReleaseEvidence
}

/// An ordered, thread-safe log of port invocations, shared by every double in one test.
///
/// Order matters as much as occurrence: "consent before the first byte is read" and
/// "complete validation precedes inference" are both statements about sequence, and both
/// are checked with ``firstIndex(of:)`` on one log rather than by inspecting several
/// doubles separately.
public final class PortCallRecorder: Sendable {
    private let recorded = LockedBox<[PortCall]>([])

    public init() {}

    /// Appends one invocation.
    public func record(_ call: PortCall) {
        recorded.withValue { $0.append(call) }
    }

    /// Every invocation, in order.
    public var calls: [PortCall] { recorded.value }

    /// Every invocation's kind, in order.
    public var callKinds: [PortCallKind] { calls.map(\.kind) }

    /// Discards the log.
    public func reset() {
        recorded.set([])
    }

    /// Whether `call` was recorded.
    public func didCall(_ call: PortCall) -> Bool {
        calls.contains(call)
    }

    /// Whether any call of `kind` was recorded.
    public func didCall(_ kind: PortCallKind) -> Bool {
        callKinds.contains(kind)
    }

    /// How many calls of `kind` were recorded.
    public func callCount(of kind: PortCallKind) -> Int {
        callKinds.filter { $0 == kind }.count
    }

    /// Position of the first call of `kind`, or `nil` when it never happened.
    public func firstIndex(of kind: PortCallKind) -> Int? {
        callKinds.firstIndex(of: kind)
    }

    /// Whether every call of `first` precedes every call of `second`.
    ///
    /// `true` when either kind never occurred: an ordering claim about a call that did
    /// not happen is vacuous, and nonoccurrence is asserted separately with
    /// ``didCall(_:)-8p1ba``.
    public func allCalls(of first: PortCallKind, precede second: PortCallKind) -> Bool {
        let firstIndices = callKinds.enumerated().filter { $0.element == first }.map(\.offset)
        let secondIndices = callKinds.enumerated().filter { $0.element == second }.map(\.offset)
        guard let lastFirst = firstIndices.max(), let firstSecond = secondIndices.min() else {
            return true
        }
        return lastFirst < firstSecond
    }

    /// The kinds that were recorded, as a set.
    public var recordedKinds: Set<PortCallKind> { Set(callKinds) }

    /// Whether no evidence-producing port was called.
    ///
    /// The direct form of "produce no Analysis Session evidence verdict", used by the
    /// short-circuit, handoff-mutation, and cancellation properties.
    public var producedNoEvidenceWork: Bool {
        recordedKinds.isDisjoint(with: PortCall.evidenceProducingCalls)
    }
}
