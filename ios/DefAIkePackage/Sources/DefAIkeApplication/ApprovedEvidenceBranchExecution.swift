import DefAIkeDomain

// Whether the two evidence branches run serially or concurrently, and where that answer
// came from.
//
// The design is explicit that this is not a performance preference: after validation,
// pixel and enabled provenance work may run concurrently **only if** the active Device
// Validation Plan and the main-application Resource Budget approve that execution policy
// for the exact configuration; otherwise they run serially, because lower wall time is not
// automatically safer than lower peak memory, energy, or thermal headroom.
//
// So the coordinator must not choose. It also must not accept a bare
// ``EvidenceBranchExecution``, because a bare `.concurrent` from a call site is
// indistinguishable from an approved one. This type is the difference: it carries the
// Device Validation Plan version the answer was read from, so the coordinator can require
// that plan to be the one its bound Resource Budget cites before it runs anything
// concurrently.
//
// ``ValidatedResourcePlan/approvesConcurrentEvidenceBranches(for:)`` is the only place the
// answer is derived from measurements, and ``init(approvedBy:for:)`` is the only member
// here that calls it. A shipping build has no validated plan — a plan is nonshipping
// release evidence and validating one needs the fixture suite — so a composition root
// supplies the recorded answer and names the plan version it was recorded against, and the
// mismatch check below is what keeps that honest.
//
// Deliberately absent: any default, any way to say "concurrent if possible", and any
// timeout, deadline, or degree of parallelism. Serial is not a fallback this file invents;
// it is the answer the design gives whenever concurrency is not approved, and it is the
// answer an unmeasured or partially measured plan already produces.

/// A release-approved evidence-branch execution policy, with the plan it came from.
///
/// Holding this value means an approved Device Validation Plan version was named for the
/// answer it carries. It does not mean the answer applies to a particular session: that is
/// ``appliesTo(_:)``, because only a bound session knows which plan version governs it.
public struct ApprovedEvidenceBranchExecution: Hashable, Sendable {
    /// Whether the branches may overlap.
    public let execution: EvidenceBranchExecution

    /// The Device Validation Plan version this answer was read from.
    ///
    /// Compared against the bound Resource Budget's ``ResourceBudget/validationPlan``
    /// rather than trusted. Two plan versions mean the concurrency measurement and the
    /// limits governing the session describe different releases.
    public let validationPlan: ArtifactID

    /// Records an answer read from an approved plan.
    ///
    /// The plan version is required, not optional. An answer with no plan behind it is
    /// exactly what this type exists to make unrepresentable.
    public init(execution: EvidenceBranchExecution, validationPlan: ArtifactID) {
        self.execution = execution
        self.validationPlan = validationPlan
    }

    /// Derives the answer for one candidate configuration from a validated plan.
    ///
    /// The preferred path wherever a ``ValidatedResourcePlan`` exists, because then the
    /// answer and the plan version cannot disagree: both come from the same value.
    /// `.concurrent` only when every main-application measurement for that exact hardware
    /// identifier and operating-system version declares concurrent execution — an
    /// unmeasured or partially measured policy is not an approved one, and the plan's own
    /// accessor already answers `false` for it.
    public init(
        approvedBy plan: ValidatedResourcePlan,
        for configuration: CandidateDeviceConfiguration
    ) {
        self.execution = plan.approvesConcurrentEvidenceBranches(for: configuration)
            ? .concurrent
            : .serial
        self.validationPlan = plan.id
    }

    /// The always-safe policy, for a release with no approved concurrency measurement.
    ///
    /// Still names a plan version, because serial execution is a decision about a session
    /// governed by a plan rather than a universal constant.
    public static func serial(validationPlan: ArtifactID) -> ApprovedEvidenceBranchExecution {
        ApprovedEvidenceBranchExecution(execution: .serial, validationPlan: validationPlan)
    }

    /// Whether this answer governs `session`.
    ///
    /// True only when the plan named here is the plan the session's bound Resource Budget
    /// cites. The budget is a value inside the session snapshot, so this reads what the
    /// session was bound to rather than the active pointer.
    public func appliesTo(_ session: BoundAnalysisSession) -> Bool {
        validationPlan == session.resourceBudget.validationPlan
    }

    /// The execution this answer authorizes for `session`.
    ///
    /// ``EvidenceBranchExecution/serial`` whenever the answer does not govern the session,
    /// which is the design's own rule rather than a lenient fallback: concurrency requires
    /// the *active* plan to approve it for the exact configuration, and an answer recorded
    /// against a different plan version has not done that. Degrading here is safe in the
    /// only direction that matters — serial execution is measured by every plan that
    /// measures anything, and it can only lower peak memory, energy, and thermal load.
    public func execution(for session: BoundAnalysisSession) -> EvidenceBranchExecution {
        appliesTo(session) ? execution : .serial
    }
}
