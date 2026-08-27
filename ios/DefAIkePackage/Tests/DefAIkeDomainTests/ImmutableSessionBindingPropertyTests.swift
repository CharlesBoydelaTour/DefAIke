import DefAIkeTestSupport
import Foundation
import PropertyBased
import Testing

@testable import DefAIkeDomain

// Design Property 13: session bundle binding is immutable and traceable.
//
// The design states it as: for any sequence of valid bundle activations and Analysis
// Sessions, each accepted session binds one complete active bundle snapshot containing its
// Model Bundle version, model identity, Core ML model version, Preprocessing Contract
// version, Calibration Policy version, and verified integrity receipt projection; later
// activation or rollback cannot change that snapshot, inference uses its bound model, and
// the report exposes exactly those identities, versions, and the `.verified` integrity
// status.
//
// One generated history per case, and four halves quantified over it:
//
//   * **the completeness half** — a session bound at history point *k* records the whole
//     tuple that point activated, member by member. Every stored member of the snapshot is
//     compared against the history entry it came from, so "complete" means the enumeration
//     is exhausted rather than sampled (Requirements 10.14, 4.12);
//   * **the immutability half** — after every later activation and rollback in the history,
//     that session still reports exactly the point-*k* snapshot. Asserted against the
//     history entry rather than against the value the earlier arm read, so a snapshot that
//     drifted and a snapshot that was re-derived both fail (Requirement 10.15);
//   * **the traceability half** — a real ``EvidenceReport`` built from the snapshot exposes
//     the same bound identifiers and the `.verified` integrity status, and the loaded model
//     the session admits for inference is the one its own history point supplied
//     (Requirements 10.18, 4.1, 4.12);
//   * **the distinctness half** — sessions bound at different history points report
//     different snapshots. Without it, "each session retains its own" would hold vacuously
//     in a history whose entries were indistinguishable.
//
// ## The positive control, and why the property needs one
//
// "A later activation cannot change the snapshot" is trivially true if no later activation
// ever moved the active pointer. Every case therefore ends with a check that it did: the
// number of pointer moves equals the number of history events after the first, the port
// reports the final entry rather than any bound one, and every session has at least one
// event after it that the port confirms changed what is active. The history's last event is
// never a binding point, so no session is exempt.
//
// ## How a bound snapshot is obtained at all
//
// A session binds a ``BoundModelBundle``, and that value is constructible from a signed
// manifest plus an activation receipt whose signature and self-test both passed. It does
// not require the released weight blob: the required weight digest is measured by the
// Model Bundle *verifier* (Property 2's subject, task 6.6), and the approved blob is absent
// from this repository, so no synthetic candidate can pass that measurement. Binding sits
// after activation, and its inputs are the manifest and the receipt. The history entries
// below are therefore built the way ``StartupPreflightFixtures`` builds the admitted one —
// real manifest, real receipt, real ``BoundModelBundle`` initializer — and no digest is
// fabricated to stand in for the approved one. Whether the real blob hashes to the required
// value is an integration question against the immutable artifact and belongs to task 6.11.
//
// Nothing here is release evidence. Every identifier, policy, digest, and receipt is
// synthetic and exists so that the real binder can be called at all. No signature algorithm
// ran, no compiled model was loaded, and no prediction was made.
//
// ## What this file does not assert
//
//   * What one prediction's output maps to, or how a load or execution failure is
//     categorized. That is Property 14's statement.
//   * Whether a manifest's artifact inventory is complete and mutation-sensitive, or
//     whether activation and rollback stay atomic under injected failures. Those are
//     Properties 26 and 27. This file moves the active pointer through the port's own
//     members and asserts only what immutability needs: that the move happened, and that a
//     bound session did not follow it.
//   * That only the Lowq checkpoint can bind. That is Property 2's.
//
// ## Why no arm throws
//
// `propertyCheck` runs its body under `try?`, so an error escaping the body reports a
// passing run in milliseconds with every arm skipped. Nothing below rethrows: each
// throwing fixture, binder, and report call is wrapped into a value or reported through
// `Issue.record`, and ``SessionBindingWitness`` counts the cases and every arm *outside*
// the body. Arm counters are compared against the case count rather than against a floor,
// and the last thing the body does is record that it reached the end.

extension Tag {
    /// Design Property 13.
    ///
    /// Declared here rather than in a shared tag namespace: each design property gets one
    /// dedicated file, and a shared namespace would be a merge point between property
    /// files written independently of each other.
    @Tag static var property13ImmutableSessionBinding: Self
}

@Suite(
    "Property 13: session bundle binding is immutable and traceable",
    .tags(.property13ImmutableSessionBinding)
)
struct ImmutableSessionBindingPropertyTests {
    /// Runs at the library default of 100 generated cases, which is the minimum the design
    /// requires; `PropertyToolchainWiringTests` pins that default. Every generator is
    /// composed with `zip`, so the shrinkers compose.
    ///
    /// **Validates: Requirements 4.1, 4.12, 10.14, 10.15, 10.18**
    @Test("Every session keeps and reports the complete snapshot it bound")
    func sessionsKeepTheirBoundSnapshot() async {
        let witness = SessionBindingWitness()

        await propertyCheck(input: BindingHistoryShape.generator) { shape in
            witness.record(shape)

            if let scenario = await SessionBindingScenario.built(shape, witness: witness) {
                await scenario.runTheHistory()
                scenario.checkEverySessionKeptItsCompleteSnapshot()
                scenario.checkEverySessionReportsWhatItBound()
                scenario.checkSessionsBoundAtDifferentPointsDiffer()
                await scenario.checkTheActivePointerReallyMoved()
            }

            witness.recordCompletedBody()
        }

        witness.expectVariedBaselines()
    }
}

// MARK: - What one history event is

/// How the active pointer was moved.
///
/// Requirement 10.17 makes rollback run the identical local verification and atomic
/// activation path as a new candidate, and Requirement 10.15 does not distinguish the two:
/// a bound session must survive either. Generating both is what shows the session's
/// immutability does not depend on which port member moved the pointer.
private enum PointerMove: String, Hashable, Sendable, CaseIterable {
    case activation
    case rollback
}

/// One point in a generated history: what became active, and how.
private struct HistoryPoint {
    /// Position in the history, from zero.
    let index: Int

    /// How the pointer moved to this entry. `nil` for the initial state, which was already
    /// active before the history began.
    let move: PointerMove?

    /// The bundle this point activated.
    let bundle: BoundModelBundle

    /// Whether a session accepts an input at this point.
    let bindsSession: Bool
}

/// One session, the point it bound at, and the snapshot the binder returned.
private struct BoundAtPoint {
    let point: HistoryPoint
    let sessionID: AnalysisSessionID
    let snapshot: BoundAnalysisSession
}

// MARK: - Generated shape

/// One generated activation history interleaved with session creation.
///
/// Every field is a bounded integer or a flag, and each derived value is read off the shape
/// by modulus, so a family is exercised across all of its members over 100 cases instead of
/// collapsing onto one.
private struct BindingHistoryShape: Sendable, CustomStringConvertible {
    /// Drives the per-point artifact versions, receipt identities, and digests, so a case's
    /// values vary together and a failing case names one seed.
    let seed: Int

    /// How many points the history has, from ``minimumPointCount`` up.
    let pointSelector: Int

    /// Which point, besides the first, is guaranteed to bind a session.
    let secondBindSelector: Int

    /// Bit pattern selecting the optional extra binding points.
    let extraBindPattern: Int

    /// Bit pattern selecting `activation` or `rollback` for each move.
    let movePattern: Int

    /// Whether this build's composition enables on-device Content Credential validation.
    ///
    /// Generated because ``AnalysisSessionBinding/provenancePolicyID`` and
    /// ``AnalysisSessionBinding/fusionRuleID`` are the two optional members of the bound
    /// tuple: a completeness claim that only ever saw them absent would not cover them.
    let provenanceEnabled: Bool

    /// Whether this composition can also produce a Combined Summary.
    let fusionEnabled: Bool

    /// Whether every bound session is read again after each history event, rather than only
    /// at the end.
    ///
    /// Reading in the middle is what distinguishes "the snapshot never changed" from "the
    /// snapshot was correct once the history finished".
    let readsAfterEveryEvent: Bool

    /// The shortest history the property is meaningful over.
    ///
    /// Three: one point to bind the first session at, one to bind a second at, and one more
    /// so that even the last-bound session has a later event it has to survive.
    static let minimumPointCount = 3

    /// The longest generated history.
    ///
    /// Bounded well under ``AnalysisSessionBinder/defaultMaximumBoundSessionCount`` so that
    /// the binder's structural ceiling is never the thing being exercised; a history that
    /// tripped it would be measuring the ceiling instead of immutability.
    static let maximumPointCount = 7

    /// How many points this history has.
    var pointCount: Int {
        Self.minimumPointCount
            + pointSelector % (Self.maximumPointCount - Self.minimumPointCount + 1)
    }

    /// The point, after the first, that is guaranteed to bind a session.
    ///
    /// Always inside `1..<pointCount - 1`, so the guaranteed second session is never bound
    /// at the last point and always has a later event to survive.
    var secondBindIndex: Int { 1 + secondBindSelector % (pointCount - 2) }

    /// Which points bind a session.
    ///
    /// The first always does, so a session exists whose whole history follows it. The last
    /// never does, so every session has at least one later event. The guaranteed second
    /// makes the distinctness half non-vacuous without relying on the bit pattern.
    func bindsSession(at index: Int) -> Bool {
        if index == 0 { return true }
        if index == pointCount - 1 { return false }
        if index == secondBindIndex { return true }
        return (extraBindPattern >> (index - 1)) & 1 == 1
    }

    /// How the pointer moved to the point at `index`, or `nil` for the initial state.
    func move(to index: Int) -> PointerMove? {
        guard index > 0 else { return nil }
        return (movePattern >> (index - 1)) & 1 == 0 ? .activation : .rollback
    }

    /// How many pointer moves this history performs.
    var moveCount: Int { pointCount - 1 }

    // MARK: Per-point identifiers

    /// A canonical artifact version token for one point.
    ///
    /// The major component is pinned positive and the seed is offset off zero for the same
    /// reason the artifact fixtures do it: a token family that can collapse onto a rejected
    /// placeholder value would make a fraction of runs fail for a reason unrelated to the
    /// property.
    func token(_ role: String, at index: Int) -> String {
        "\(role).p13-\(1 + seed % 999)-\(index + 1)"
    }

    /// A 64-character lowercase digest for one point, distinct per point and per seed.
    ///
    /// Built by hand rather than hashed, because nothing about its value matters beyond
    /// being a canonical digest that differs between points: it stands in for a manifest
    /// digest a verifier measured, and this file measures no bytes.
    func digestHexadecimal(_ role: Int, at index: Int) -> String {
        let digits = Array("0123456789abcdef")
        var value = UInt64(bitPattern: Int64(seed &* 31 &+ index &* 7 &+ role))
        value = value &* 2_654_435_761 &+ 1
        var characters: [Character] = []
        for position in 0..<64 {
            characters.append(digits[Int((value >> UInt64(position % 60)) & 0xF)])
            value = value &* 6_364_136_223 &+ UInt64(position)
        }
        return String(characters)
    }

    var sessionIdentifier: (Int) -> String {
        { index in "session.p13-\(index + 1)" }
    }

    // MARK: Description

    var description: String {
        let binds = (0..<pointCount).filter { bindsSession(at: $0) }
        let moves = (1..<pointCount).compactMap { move(to: $0)?.rawValue }
        return """
            seed \(seed), \(pointCount) points, binds at \(binds), moves \(moves), \
            provenance \(provenanceEnabled), fusion \(fusionEnabled), \
            reads after every event \(readsAfterEveryEvent)
            """
    }

    // MARK: Generator

    static var generator: Generator<BindingHistoryShape, AnySequence<Any>> {
        zip(
            Gen.int(in: 0...9_999),
            index,
            index,
            Gen.int(in: 0...127),
            Gen.int(in: 0...127),
            Gen.bool,
            Gen.bool,
            Gen.bool
        )
        .map { raw in
            BindingHistoryShape(
                seed: raw.0,
                pointSelector: raw.1,
                secondBindSelector: raw.2,
                extraBindPattern: raw.3,
                movePattern: raw.4,
                provenanceEnabled: raw.5,
                fusionEnabled: raw.6,
                readsAfterEveryEvent: raw.7
            )
        }
        .eraseToAny()
    }

    /// A selector index.
    ///
    /// The range is a multiple of every modulus it is reduced by (1 through 5), so each
    /// history length and each guaranteed second binding point is drawn with equal
    /// probability rather than with a modulus bias.
    private static var index: Generator<Int, AnySequence<Any>> {
        Gen.int(in: 0...959).eraseToAny()
    }
}

// MARK: - The Model Bundle port, with a pointer a history can move

/// The Model Bundle port whose active pointer moves through its own members.
///
/// Written here rather than reused from the example-level binder tests, which keep theirs
/// `private`: the two need different things. This one stages the next entry and promotes it
/// through ``activateLocalCandidate(_:context:)`` or ``rollback(to:context:)``, so a
/// generated history moves the pointer the way the port says a release does, and it records
/// how many moves happened and how many times the pointer was read. Both counts are what
/// turn "the snapshot did not change" into "the snapshot did not change *although the
/// pointer did*".
private actor MovingBundleManager: ModelBundleManaging {
    private var active: BoundModelBundle
    private var staged: BoundModelBundle?
    private var reads = 0
    private var moves: [PointerMove] = []

    init(active: BoundModelBundle) {
        self.active = active
    }

    /// The next entry a move will promote.
    func stage(_ bundle: BoundModelBundle) {
        staged = bundle
    }

    /// How many times the active pointer was read through the port.
    var readCount: Int { reads }

    /// The moves this history performed, in order.
    var performedMoves: [PointerMove] { moves }

    /// The active bundle, read without going through the port.
    ///
    /// Used only by the positive control, which has to know what is active independently of
    /// what the binder was told.
    var currentActive: BoundModelBundle { active }

    func verifiedActiveBundle(
        for context: ReleaseContext
    ) throws(AnalysisFault) -> BoundModelBundle {
        reads += 1
        guard active.isCompatible(with: context) else {
            throw .analysis(.modelLoadError, stage: .modelLoad)
        }
        return active
    }

    func activateLocalCandidate(
        _ id: ModelBundleID,
        context: ReleaseContext
    ) throws(AnalysisFault) -> BoundModelBundle {
        try promote(.activation, context: context)
    }

    func rollback(
        to id: ModelBundleID,
        context: ReleaseContext
    ) throws(AnalysisFault) -> BoundModelBundle {
        try promote(.rollback, context: context)
    }

    private func promote(
        _ move: PointerMove,
        context: ReleaseContext
    ) throws(AnalysisFault) -> BoundModelBundle {
        guard let staged else { throw .analysis(.modelLoadError, stage: .modelLoad) }
        guard staged.isCompatible(with: context) else {
            throw .analysis(.modelLoadError, stage: .modelLoad)
        }
        active = staged
        self.staged = nil
        moves.append(move)
        return staged
    }
}

// MARK: - One generated history

/// One generated history, the real binder over it, and the sessions it bound.
///
/// The binder, the snapshot constructor, the report initializer, and the bound-model gate
/// are the production ones. The admission comes from running the real startup gate rather
/// than from constructing a ``ReleaseAdmission``, whose initializer is `fileprivate`
/// precisely so that only a passed gate can produce one.
private final class SessionBindingScenario {
    private let shape: BindingHistoryShape
    private let witness: SessionBindingWitness
    private let admission: ReleaseAdmission
    private let bundles: MovingBundleManager
    private let binder: AnalysisSessionBinder
    private let points: [HistoryPoint]

    /// Filled by ``runTheHistory()``.
    private var bound: [BoundAtPoint] = []
    private var readsAfterLastBind = 0

    private init(
        shape: BindingHistoryShape,
        witness: SessionBindingWitness,
        admission: ReleaseAdmission,
        bundles: MovingBundleManager,
        binder: AnalysisSessionBinder,
        points: [HistoryPoint]
    ) {
        self.shape = shape
        self.witness = witness
        self.admission = admission
        self.bundles = bundles
        self.binder = binder
        self.points = points
    }

    // MARK: - Assembly

    /// Builds the admission, the history, and the binder, or `nil` when a described fixture
    /// was not buildable.
    static func built(
        _ shape: BindingHistoryShape,
        witness: SessionBindingWitness
    ) async -> SessionBindingScenario? {
        guard let admission = await Self.admission(shape, witness: witness) else { return nil }

        // The three component versions the binder checks against this build's validated
        // policy set are taken from the admitted bundle, so every history entry stays
        // admissible and the only thing that varies between entries is what a release may
        // legitimately vary. A history whose entries were inadmissible would be exercising
        // the refusal path, which belongs to task 6.4's example tests.
        let pinned = admission.bundle.componentVersions

        var points: [HistoryPoint] = []
        for index in 0..<shape.pointCount {
            guard let bundle = Self.historyBundle(shape, at: index, pinned: pinned) else {
                Self.report("history point \(index) must be buildable", witness)
                return nil
            }
            points.append(
                HistoryPoint(
                    index: index,
                    move: shape.move(to: index),
                    bundle: bundle,
                    bindsSession: shape.bindsSession(at: index)
                )
            )
        }

        guard let first = points.first else {
            Self.report("a generated history must have at least one point", witness)
            return nil
        }
        // Distinct history entries are what make the immutability and distinctness halves
        // observable at all, so this is checked rather than assumed.
        guard Set(points.map(\.bundle)).count == points.count else {
            Self.report("every history point must activate a distinguishable bundle", witness)
            return nil
        }

        let bundles = MovingBundleManager(active: first.bundle)
        return SessionBindingScenario(
            shape: shape,
            witness: witness,
            admission: admission,
            bundles: bundles,
            binder: AnalysisSessionBinder(admission: admission, bundles: bundles),
            points: points
        )
    }

    /// A coherent admission from the real startup gate.
    private static func admission(
        _ shape: BindingHistoryShape,
        witness: SessionBindingWitness
    ) async -> ReleaseAdmission? {
        guard let scenario = try? await PreflightSample.scenario(
            provenance: shape.provenanceEnabled,
            fusion: shape.fusionEnabled && shape.provenanceEnabled
        ) else {
            Self.report("the release scenario must be buildable", witness)
            return nil
        }
        guard let admission = try? await scenario.run() else {
            Self.report("the startup gate must admit a coherent release", witness)
            return nil
        }
        return admission
    }

    /// One history entry: a real manifest, a real receipt, and the bundle they bind to.
    ///
    /// Three of the six component versions vary per point and three do not. The three that
    /// vary — Core ML model, evidence scope, and self-test specification — are the ones a
    /// release may change without changing the policy set this build validated, so they are
    /// what makes two activations distinguishable through a session's snapshot. The receipt
    /// identity, manifest digest, verified digest inventory, and activation generation vary
    /// too, so the integrity projection differs per point as well.
    private static func historyBundle(
        _ shape: BindingHistoryShape,
        at index: Int,
        pinned: BundleComponentVersions
    ) -> BoundModelBundle? {
        guard let coreML = ArtifactID(shape.token("component.coreml", at: index)),
              let scope = ArtifactID(shape.token("component.scope", at: index)),
              let selfTests = ArtifactID(shape.token("component.self-tests", at: index)),
              let receiptID = ArtifactID(shape.token("receipt.activation", at: index)),
              let manifestDigest = SHA256Digest(
                  hexadecimal: shape.digestHexadecimal(0, at: index)
              ),
              let artifactDigest = SHA256Digest(
                  hexadecimal: shape.digestHexadecimal(1, at: index)
              ),
              let artifactPath = CanonicalRelativePath(
                  "artifacts/model-p13-\(index + 1).mlmodelc"
              ),
              let generation = try? PositiveCount(validating: index + 1)
        else {
            return nil
        }

        let components = BundleComponentVersions(
            coreMLModel: coreML,
            preprocessingContract: pinned.preprocessingContract,
            calibrationPolicy: pinned.calibrationPolicy,
            evidenceScope: scope,
            verdictCopyCompatibility: pinned.verdictCopyCompatibility,
            selfTestSpecification: selfTests
        )
        guard let manifest = try? PreflightSample.bundleManifest(
            componentVersions: components
        ) else {
            return nil
        }
        guard let receipt = try? ActivationReceipt(
            id: receiptID,
            schemaVersion: .v1,
            bundleID: manifest.bundleID,
            verificationPolicy: Sample.artifact("policy.bundle-verification"),
            verifiedManifestDigest: manifestDigest,
            verifiedArtifactDigests: [
                ArtifactDigestRecord(
                    path: artifactPath,
                    kind: .directoryTree,
                    byteCount: UInt64(4_096 + index),
                    digest: artifactDigest
                )
            ],
            signatureOutcome: .passed,
            selfTestOutcome: .passed,
            deviceContext: PreflightSample.device(),
            activationGeneration: generation,
            activatedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
        ) else {
            return nil
        }
        return BoundModelBundle(manifest: manifest, receipt: receipt)
    }

    // MARK: - Running the history

    /// Walks the history, moving the active pointer and binding sessions as it goes.
    ///
    /// Each move goes through the port member the shape selected, so the pointer is moved
    /// the way a release moves it rather than by writing a field. Each binding goes through
    /// the real ``AnalysisSessionBinder``, which reads the active pointer itself.
    func runTheHistory() async {
        for point in points {
            if let move = point.move {
                await bundles.stage(point.bundle)
                guard await self.moved(move) else {
                    report("history point \(point.index) must become active by \(move.rawValue)")
                    return
                }
                witness.recordPointerMove(move)
            }

            if point.bindsSession {
                guard let sessionID = AnalysisSessionID(shape.sessionIdentifier(point.index)) else {
                    report("the session identifier for point \(point.index) must be canonical")
                    return
                }
                let asset = PortValue.asset(route: .photosPicker, sessionID: sessionID)
                guard let snapshot = await self.snapshot(accepting: asset) else {
                    report("point \(point.index) must bind the bundle it activated")
                    return
                }
                bound.append(
                    BoundAtPoint(point: point, sessionID: sessionID, snapshot: snapshot)
                )
                witness.recordBoundSession()
            }

            // Reading in the middle of the history, not only at its end: a snapshot that is
            // correct once the history finishes is a weaker statement than one that was
            // never anything else.
            if shape.readsAfterEveryEvent {
                await checkEverySessionStillReportsItsSnapshot(stage: "point \(point.index)")
            }
        }

        readsAfterLastBind = await bundles.readCount
        witness.recordHistoryRun()
    }

    // MARK: - The completeness half

    /// Each session's snapshot records the whole tuple its own history point activated
    /// (Requirements 10.14, 4.12), and still does after the whole history ran
    /// (Requirement 10.15).
    func checkEverySessionKeptItsCompleteSnapshot() {
        guard !bound.isEmpty else { return }

        for entry in bound {
            let bundle = entry.point.bundle
            let components = bundle.componentVersions
            let binding = entry.snapshot.binding

            // Every stored member of the binding, in declaration order. Enumerated rather
            // than compared as a whole value, so a missing member is named.
            #expect(binding.sessionID == entry.sessionID)
            #expect(binding.appBuildID == admission.context.device.appBuild)
            #expect(binding.deviceConfigurationID == admission.approvedConfiguration.id)
            #expect(binding.modelBundleID == bundle.bundleID)
            #expect(binding.modelIdentity == bundle.modelIdentity)
            #expect(binding.modelIdentity == RequiredPixelModel.identity)
            #expect(binding.coreMLModelVersion == components.coreMLModel)
            #expect(binding.preprocessingContractID == components.preprocessingContract)
            #expect(binding.calibrationPolicyID == components.calibrationPolicy)
            #expect(binding.verdictCopyCompatibilityID == components.verdictCopyCompatibility)
            #expect(binding.capabilityManifestID == admission.configuration.capabilityManifest.id)
            #expect(binding.lifecyclePolicyID == admission.configuration.lifecyclePolicy.id)
            #expect(
                binding.resourceBudgetID
                    == admission.configuration.resourceBudgets
                        .budget(for: admission.target).id
            )

            // The two conditional members. Present exactly when the admission enables the
            // capability, absent otherwise: an optional that was never generated in both
            // states would leave half of the tuple uncovered.
            #expect(
                binding.provenancePolicyID == admission.configuration.provenancePolicy?.id
            )
            #expect(binding.fusionRuleID == admission.configuration.fusionRule?.id)
            #expect(binding.provenancePolicyID == nil || admission.enablesProvenance)
            #expect(binding.fusionRuleID == nil || admission.enablesFusion)

            // The integrity receipt projection, member by member, and its status.
            let integrity = binding.modelBundleIntegrity
            #expect(integrity == bundle.integrity)
            #expect(integrity.status == .verified)
            #expect(integrity.activationReceiptID == bundle.integrity.activationReceiptID)
            #expect(integrity.verificationPolicyID == bundle.integrity.verificationPolicyID)
            #expect(integrity.verifiedManifestDigest == bundle.integrity.verifiedManifestDigest)
            #expect(integrity.verifiedArtifactDigests == bundle.integrity.verifiedArtifactDigests)

            // The remaining stored members of the snapshot itself: the bundle, the scope,
            // and the three policy values a session applies rather than looks up again.
            #expect(entry.snapshot.bundle == bundle)
            #expect(entry.snapshot.scope == EvidenceScope.version1(id: components.evidenceScope))
            #expect(entry.snapshot.scope.id == components.evidenceScope)
            #expect(entry.snapshot.preprocessingContract == admission.configuration.preprocessingContract)
            #expect(entry.snapshot.calibrationPolicy == admission.configuration.calibrationPolicy)
            #expect(
                entry.snapshot.resourceBudget
                    == admission.configuration.resourceBudgets.budget(for: admission.target)
            )
            #expect(entry.snapshot.provenancePolicy == admission.configuration.provenancePolicy)
            #expect(entry.snapshot.fusionRule == admission.configuration.fusionRule)
            #expect(entry.snapshot.activationGeneration == bundle.activationGeneration)
            #expect(entry.snapshot.enablesProvenance == admission.enablesProvenance)
            #expect(entry.snapshot.enablesFusion == admission.enablesFusion)

            witness.recordCompletenessCheck()
        }
    }

    // MARK: - The traceability half

    /// A report built from each snapshot exposes exactly the bound identifiers and the
    /// `.verified` integrity status, and the session admits only the model its own history
    /// point supplied (Requirements 10.18, 4.12, 4.1).
    func checkEverySessionReportsWhatItBound() {
        guard !bound.isEmpty else { return }
        guard let input = try? Sample.modelInput(), let output = try? Sample.modelOutput() else {
            report("the model contracts must be buildable")
            return
        }

        for entry in bound {
            let snapshot = entry.snapshot
            let components = entry.point.bundle.componentVersions

            // The lane and quality values are inputs this property supplies, not outputs it
            // asserts about: which provenance state a release reports is Property 19's
            // statement, and what one prediction maps to is Property 14's. What is checked
            // here is that the binding and scope cross into a report unchanged.
            guard let report = EvidenceReport(
                binding: snapshot.binding,
                pixel: .noStrongSignalDetected,
                provenance: .unavailable(.validatorNotCompiledIntoRelease),
                combinedSummary: nil,
                apparentInconsistency: nil,
                bytePreservationStatus: .unknown,
                inputQuality: SessionValue.quality(),
                onDeviceProcessing: true,
                scope: snapshot.scope
            ) else {
                self.report("a report must be constructible from a bound snapshot")
                continue
            }

            #expect(report.binding == snapshot.binding)
            #expect(report.scope == snapshot.scope)
            #expect(report.binding.modelBundleID == entry.point.bundle.bundleID)
            #expect(report.binding.modelIdentity == entry.point.bundle.modelIdentity)
            #expect(report.binding.coreMLModelVersion == components.coreMLModel)
            #expect(report.binding.preprocessingContractID == components.preprocessingContract)
            #expect(report.binding.calibrationPolicyID == components.calibrationPolicy)
            #expect(report.binding.modelBundleIntegrity == entry.point.bundle.integrity)
            #expect(report.binding.modelBundleIntegrity.status == .verified)
            #expect(report.scope.id == components.evidenceScope)

            // Requirement 4.1: inference executes the model from the bundle bound to the
            // session. The gate accepts the model this session's own point supplied.
            guard let ownModel = BoundCoreMLModel(
                bundleID: snapshot.modelBundleID,
                modelIdentity: snapshot.modelIdentity,
                coreMLModelVersion: snapshot.binding.coreMLModelVersion,
                inputContract: input,
                outputContract: output,
                model: LoadedModelToken(rawValue: 1)
            ) else {
                self.report("the bound model must be constructible for the bound identity")
                continue
            }
            #expect(snapshot.bindsLoadedModel(ownModel))
            #expect((try? snapshot.requireBoundModel(ownModel)) == ownModel)

            // And refuses one loaded from the entry the history ended on, whose Core ML
            // component version differs. This is the arm that would pass if a session read
            // the live pointer instead of its snapshot, which is why it is here beside the
            // accepted one rather than instead of it.
            guard let finalComponents = points.last?.bundle.componentVersions else { continue }
            if finalComponents.coreMLModel != components.coreMLModel {
                guard let laterModel = BoundCoreMLModel(
                    bundleID: snapshot.modelBundleID,
                    modelIdentity: snapshot.modelIdentity,
                    coreMLModelVersion: finalComponents.coreMLModel,
                    inputContract: input,
                    outputContract: output,
                    model: LoadedModelToken(rawValue: 2)
                ) else {
                    self.report("the later model must be constructible")
                    continue
                }
                #expect(!snapshot.bindsLoadedModel(laterModel))
                #expect(
                    (try? snapshot.requireBoundModel(laterModel)) == nil,
                    "a session must refuse a model loaded from a later activation"
                )
                witness.recordLaterModelRefusal()
            }

            witness.recordTraceabilityCheck()
        }
    }

    // MARK: - The distinctness half

    /// Sessions bound at different history points report different snapshots.
    ///
    /// Without this, "each session retains its own snapshot" would be satisfied by a history
    /// whose entries were indistinguishable, and the immutability half would be measuring
    /// nothing.
    func checkSessionsBoundAtDifferentPointsDiffer() {
        guard bound.count >= 2 else {
            report("every case must bind at least two sessions at different history points")
            return
        }

        for (offset, earlier) in bound.enumerated() {
            for later in bound[(offset + 1)...] {
                #expect(earlier.point.index != later.point.index)
                #expect(
                    earlier.snapshot != later.snapshot,
                    """
                    sessions bound at points \(earlier.point.index) and \(later.point.index) \
                    report the same snapshot
                    """
                )
                // Named rather than left to value inequality, so a difference in one
                // incidental field could not stand in for the bound tuple differing.
                #expect(
                    earlier.snapshot.binding.coreMLModelVersion
                        != later.snapshot.binding.coreMLModelVersion
                )
                #expect(earlier.snapshot.scope.id != later.snapshot.scope.id)
                #expect(
                    earlier.snapshot.activationGeneration != later.snapshot.activationGeneration
                )
                #expect(
                    earlier.snapshot.binding.modelBundleIntegrity.activationReceiptID
                        != later.snapshot.binding.modelBundleIntegrity.activationReceiptID
                )
                // And the bundle identifier is deliberately the same for both, because that
                // is the case a check comparing identifiers alone would miss.
                #expect(
                    earlier.snapshot.modelBundleID == later.snapshot.modelBundleID
                )
                witness.recordDistinctnessCheck()
            }
        }
    }

    // MARK: - The positive control

    /// The active pointer really moved, and every session has later events it survived.
    ///
    /// The immutability half is vacuous without this: "a later activation cannot change the
    /// snapshot" says nothing about a history in which nothing was ever activated.
    func checkTheActivePointerReallyMoved() async {
        guard !bound.isEmpty, let final = points.last else { return }

        let moves = await bundles.performedMoves
        #expect(
            moves.count == shape.moveCount,
            "the history performed \(moves.count) pointer moves, expected \(shape.moveCount)"
        )
        #expect(moves.count >= 1, "a history with no pointer move proves nothing")

        // What is active now is the history's last entry, not any session's bound one.
        let active = await bundles.currentActive
        #expect(active == final.bundle)
        #expect(await self.activeThroughPort() == final.bundle)

        for entry in bound {
            let laterEvents = points.filter { $0.index > entry.point.index && $0.move != nil }
            #expect(
                !laterEvents.isEmpty,
                "session at point \(entry.point.index) has no later activation to survive"
            )
            #expect(
                active != entry.snapshot.bundle,
                """
                the active bundle still equals the one session at point \
                \(entry.point.index) bound, so its snapshot was never at risk
                """
            )
            #expect(
                active.componentVersions.coreMLModel
                    != entry.snapshot.binding.coreMLModelVersion
            )
            #expect(active.activationGeneration != entry.snapshot.activationGeneration)
            witness.recordPositiveControl()
        }

        // The mechanism behind the outcome, in two parts.
        //
        // First, exactly: the active pointer was read once per binding over the whole
        // history and never otherwise. The pointer moves went through the port's activation
        // and rollback members, and the mid-history re-reads went through the binder's own
        // map, so any other number would mean a read this file cannot account for.
        #expect(
            readsAfterLastBind == bound.count,
            """
            the active pointer was read \(readsAfterLastBind) time(s) over a history that \
            bound \(bound.count) session(s)
            """
        )

        // Second: reading a bound session does not consult the port at all, so a snapshot
        // cannot observe an activation whatever the port would report. Counted from here
        // rather than from the end of the history, because the positive control above reads
        // the port deliberately.
        let readsBeforeRereading = await bundles.readCount
        for entry in bound {
            _ = await binder.boundSession(entry.sessionID)
        }
        #expect(
            await bundles.readCount == readsBeforeRereading,
            "reading a bound session consulted the active pointer"
        )

        // Every session is still bound, and to the snapshot its own point produced.
        #expect(await binder.boundSessionCount == bound.count)
        #expect(await binder.boundSessionIDs == Set(bound.map(\.sessionID)))
        await checkEverySessionStillReportsItsSnapshot(stage: "end of history")
        witness.recordPointerMoveCheck()
    }

    // MARK: - Re-reading

    /// Every bound session still reports the snapshot its own history point produced.
    ///
    /// Compared against the history entry rather than against the value the binder returned
    /// earlier, so a snapshot that drifted and one that was re-derived from the live pointer
    /// both fail here.
    private func checkEverySessionStillReportsItsSnapshot(stage: String) async {
        for entry in bound {
            guard let observed = await binder.boundSession(entry.sessionID) else {
                report("session at point \(entry.point.index) is not bound at \(stage)")
                continue
            }
            #expect(
                observed == entry.snapshot,
                "session at point \(entry.point.index) changed by \(stage)"
            )
            #expect(observed.bundle == entry.point.bundle)
            #expect(
                observed.binding.coreMLModelVersion
                    == entry.point.bundle.componentVersions.coreMLModel
            )
            #expect(observed.scope.id == entry.point.bundle.componentVersions.evidenceScope)
            #expect(observed.activationGeneration == entry.point.bundle.activationGeneration)
            #expect(observed.binding.modelBundleIntegrity == entry.point.bundle.integrity)
            #expect(observed.integrityStatus == .verified)
            witness.recordImmutabilityRead()
        }
    }

    // MARK: - Nonthrowing calls

    /// Whether the staged entry became active through `move`.
    ///
    /// Wrapped rather than rethrown: an error escaping the property body would report a
    /// passing run with every arm skipped.
    private func moved(_ move: PointerMove) async -> Bool {
        do {
            switch move {
            case .activation:
                _ = try await bundles.activateLocalCandidate(
                    admission.bundle.bundleID,
                    context: admission.context
                )
            case .rollback:
                _ = try await bundles.rollback(
                    to: admission.bundle.bundleID,
                    context: admission.context
                )
            }
            return true
        } catch {
            return false
        }
    }

    private func snapshot(
        accepting asset: ImportedEncodedAsset
    ) async -> BoundAnalysisSession? {
        do {
            return try await binder.bind(accepting: asset)
        } catch {
            return nil
        }
    }

    private func activeThroughPort() async -> BoundModelBundle? {
        do {
            return try await bundles.verifiedActiveBundle(for: admission.context)
        } catch {
            return nil
        }
    }

    // MARK: - Helpers

    private func report(_ message: Comment, sourceLocation: SourceLocation = #_sourceLocation) {
        Self.report(message, witness, sourceLocation: sourceLocation)
    }

    /// Records that a fixture this file described could not be built or used.
    ///
    /// Never a finding about the binder: every input here is built from generated integers
    /// inside validated ranges, so a refusal is a defect in this file. It is counted so a
    /// run whose inputs quietly stopped being buildable fails outside the body rather than
    /// shrinking its own coverage.
    private static func report(
        _ message: Comment,
        _ witness: SessionBindingWitness,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        witness.recordUnusableInput()
        Issue.record(message, sourceLocation: sourceLocation)
    }
}

// MARK: - The variation witness

/// Counts what the run generated and what it produced, outside the property body.
///
/// `propertyCheck` runs its body under `try?`, so a body that failed before its first
/// assertion reports a passing test in milliseconds with every arm skipped. Two habits
/// close that gap, and both matter:
///
///   * every arm counter is compared against the **case count**, or against a count this
///     run itself accumulated, rather than against a floor, so a run in which an arm
///     stopped being reached fails even if the absolute number still looks large; and
///   * ``recordCompletedBody()`` is the last thing the body does, so a case that ended
///     early is countable. `completedBodies == cases` alone would pass vacuously as
///     `0 == 0`, which is why the case floor sits beside it.
///
/// The produced sets are the substantive half. Both pointer-move kinds must actually have
/// moved the pointer, both provenance states and both fusion states must actually have been
/// bound, every history length must have been generated, and the number of immutability
/// re-reads must exceed the number of sessions — which is what turns "each session retains
/// its snapshot" from a claim about unreached branches into a claim about produced outcomes.
private final class SessionBindingWitness: @unchecked Sendable {
    private let lock = NSLock()

    // Arm counters.
    private var cases = 0
    private var completedBodies = 0
    private var historyRuns = 0
    private var pointerMoveChecks = 0
    private var boundSessions = 0
    private var completenessChecks = 0
    private var traceabilityChecks = 0
    private var laterModelRefusals = 0
    private var distinctnessChecks = 0
    private var immutabilityReads = 0
    private var positiveControls = 0
    private var pointerMoves = 0
    private var unusableInputs = 0

    // Produced outcomes.
    private var performedMoveKinds: Set<String> = []

    // Generated baseline.
    private var seeds: Set<Int> = []
    private var pointCounts: Set<Int> = []
    private var bindPatterns: Set<String> = []
    private var provenanceStates: Set<Bool> = []
    private var fusionStates: Set<Bool> = []
    private var readCadences: Set<Bool> = []
    private var expectedMoves = 0

    func record(_ shape: BindingHistoryShape) {
        lock.lock()
        defer { lock.unlock() }
        cases += 1
        seeds.insert(shape.seed)
        pointCounts.insert(shape.pointCount)
        bindPatterns.insert(
            (0..<shape.pointCount).map { shape.bindsSession(at: $0) ? "1" : "0" }.joined()
        )
        provenanceStates.insert(shape.provenanceEnabled)
        fusionStates.insert(shape.fusionEnabled && shape.provenanceEnabled)
        readCadences.insert(shape.readsAfterEveryEvent)
        expectedMoves += shape.moveCount
    }

    func recordHistoryRun() {
        lock.lock()
        historyRuns += 1
        lock.unlock()
    }

    func recordPointerMove(_ move: PointerMove) {
        lock.lock()
        pointerMoves += 1
        performedMoveKinds.insert(move.rawValue)
        lock.unlock()
    }

    func recordBoundSession() {
        lock.lock()
        boundSessions += 1
        lock.unlock()
    }

    func recordCompletenessCheck() {
        lock.lock()
        completenessChecks += 1
        lock.unlock()
    }

    func recordTraceabilityCheck() {
        lock.lock()
        traceabilityChecks += 1
        lock.unlock()
    }

    func recordLaterModelRefusal() {
        lock.lock()
        laterModelRefusals += 1
        lock.unlock()
    }

    func recordDistinctnessCheck() {
        lock.lock()
        distinctnessChecks += 1
        lock.unlock()
    }

    func recordImmutabilityRead() {
        lock.lock()
        immutabilityReads += 1
        lock.unlock()
    }

    func recordPositiveControl() {
        lock.lock()
        positiveControls += 1
        lock.unlock()
    }

    func recordPointerMoveCheck() {
        lock.lock()
        pointerMoveChecks += 1
        lock.unlock()
    }

    func recordUnusableInput() {
        lock.lock()
        unusableInputs += 1
        lock.unlock()
    }

    /// Called last in the body, so a case that stopped early is countable.
    func recordCompletedBody() {
        lock.lock()
        completedBodies += 1
        lock.unlock()
    }

    func expectVariedBaselines() {
        lock.lock()
        defer { lock.unlock() }

        #expect(cases >= 100, "the design requires at least 100 generated cases; ran \(cases)")
        #expect(
            completedBodies == cases,
            "\(cases - completedBodies) of \(cases) cases did not reach the end of the body"
        )
        #expect(
            unusableInputs == 0,
            "\(unusableInputs) described inputs could not be built or used at all"
        )

        // Every arm ran on every case. Compared against the case count rather than against
        // a floor: an arm that stopped being reached fails here even when the absolute
        // number still looks large.
        #expect(historyRuns == cases, "histories run: \(historyRuns)")
        #expect(pointerMoveChecks == cases, "positive controls run: \(pointerMoveChecks)")

        // Every history event moved the pointer through the port, and both port members
        // were used across the run.
        #expect(
            pointerMoves == expectedMoves,
            "\(pointerMoves) pointer moves happened, \(expectedMoves) were described"
        )
        #expect(
            performedMoveKinds == Set(PointerMove.allCases.map(\.rawValue)),
            "pointer-move kinds never performed: \(Set(PointerMove.allCases.map(\.rawValue)).subtracting(performedMoveKinds).sorted())"
        )

        // The per-session arms ran once per bound session, and every case bound at least
        // two so that the distinctness half had a pair to compare.
        #expect(boundSessions >= cases * 2, "sessions bound: \(boundSessions)")
        #expect(
            completenessChecks == boundSessions,
            "completeness checks: \(completenessChecks) over \(boundSessions) sessions"
        )
        #expect(
            traceabilityChecks == boundSessions,
            "traceability checks: \(traceabilityChecks) over \(boundSessions) sessions"
        )
        #expect(
            positiveControls == boundSessions,
            "positive controls: \(positiveControls) over \(boundSessions) sessions"
        )
        #expect(
            laterModelRefusals == boundSessions,
            """
            \(laterModelRefusals) of \(boundSessions) sessions refused a model loaded from \
            the history's final activation; every session was bound before it
            """
        )
        #expect(
            distinctnessChecks >= cases,
            "session pairs compared: \(distinctnessChecks)"
        )

        // A session's snapshot was re-read at least once per session, and more often than
        // once per session overall: the end-of-history pass alone would equal
        // `boundSessions`, so exceeding it is what shows the mid-history cadence ran too.
        #expect(
            immutabilityReads > boundSessions,
            "immutability re-reads: \(immutabilityReads) over \(boundSessions) sessions"
        )

        // The generated baseline actually varied.
        #expect(seeds.count >= 50, "generated seeds: \(seeds.count)")
        #expect(
            pointCounts == Set(
                BindingHistoryShape.minimumPointCount...BindingHistoryShape.maximumPointCount
            ),
            "generated history lengths: \(pointCounts.sorted())"
        )
        #expect(bindPatterns.count >= 20, "generated binding patterns: \(bindPatterns.count)")
        #expect(provenanceStates == [false, true], "only one provenance state was generated")
        #expect(fusionStates == [false, true], "only one fusion state was generated")
        #expect(readCadences == [false, true], "only one read cadence was generated")
    }
}
