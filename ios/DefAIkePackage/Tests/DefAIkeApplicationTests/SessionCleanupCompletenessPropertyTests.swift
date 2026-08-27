import DefAIkeDomain
import DefAIkeTestSupport
import Foundation
import PropertyBased
import Testing

@testable import DefAIkeApplication

// Design Property 25: session cleanup is complete, idempotent, and visibility-bounded.
//
// The design states it as: for any app-controlled session file tree, terminal reason,
// interruption state, and valid Data Lifecycle Policy, cleanup removes all session-owned
// encoded bytes, decoded data, model inputs, logits, provenance data, evidence, reports, and
// errors by the applicable deadline; repeated cleanup has the same empty result, and startup
// cleanup completes before new ingest.
//
// That is four claims, and they fail separately.
//
// ## 1. Complete (Requirements 9.7, 9.8)
//
// After cleanup the ownership set is empty: no scope names the session, no key is listed
// under it, no incomplete copy is left holding a partial write, and the store's byte total is
// back to zero. Asserted for every generated tree and for **every one of the five cleanup
// reasons**, each over its own freshly built tree, so no reason inherits another's emptiness.
//
// ## 2. Idempotent (Requirement 9.8)
//
// The substance of idempotence is a *difference*, not a pair of successes: the first cleanup
// reports a nonzero removed-object count and every repeat reports zero, while the ownership
// set stays empty and the byte total stays unchanged. A double that always answered zero
// would fail the first half; one that recounted material it had not removed would fail the
// second.
//
// ## 3. Visibility-bounded by the selected policy deadline (Requirements 9.14, 9.17, 11.15)
//
// The deadline is *read from the policy under the reason the terminal selected*, never chosen
// in code. Every receipt is required to carry both its own reason and that reason's entry, and
// the generated policy gives all five reasons distinct numbers so reading the wrong entry is
// visible rather than indistinguishable. A second, deliberately *coincident* policy is then
// generated in which two reasons share one number: there the receipts must still carry the
// entry the policy declares and still carry their own distinct reasons, which is what keeps
// "the deadlines happen to be equal" from being read back as "the reasons are the same".
// Requirement 9.17 is checked at the boundary the requirement names: the clock is advanced
// past the reason's deadline and the ownership set is still empty.
//
// ## 4. Interrupted cleanup, and startup ordering (Requirements 9.9, 9.17, 11.16)
//
// The ordering is the requirement, so it is recorded rather than inferred. A generated
// interruption leaves a tree behind — finalized objects, one torn write, and transfer residue
// — and the **real seven-step startup gate** is run over it through a ledger that timestamps
// the sweep and every ingest step. Two facts come out of the ledger:
//
//   * the sweep ends before the first ingest event, and the snapshot taken at the sweep
//     boundary shows nothing analysis-bearing left; and
//   * when the sweep fails, the ledger holds **no ingest event at all**, because
//     `ReleaseAdmission` is the only value that reaches ingest and the gate never produces
//     one. Ingest here is the real `AnalysisSessionBinder.bind(accepting:)` over that
//     admission, so an ingest event cannot be recorded without the value the sweep gates.
//
// ## No deadline, limit, or identifier here is an approved release value
//
// The five numeric cleanup deadlines are an unresolved external decision (design decision
// D7). Every duration below is synthetic scaffolding generated to be *distinct*, or
// deliberately coincident, so an assertion can name which policy entry was read. Nothing
// here may be copied into a shipping artifact, and no assertion claims any number is correct.
//
// ## Data protection, and why "empty" here is a removal rather than an absence
//
// This property runs against the bounded virtual tree of `InMemoryEphemeralStore`, which has
// no file system, so the host condition in which a protected directory accepts a `create` and
// then refuses the file inside it cannot arise. It would matter if it could: a store that
// never managed to create anything would produce an empty ownership set for free and every
// emptiness assertion below would pass for the wrong reason. Two guards close that gap.
// First, every object is written at `.completeUntilFirstUserAuthentication`, so a later
// substitution of the file-backed store lands on the level that is known to work on this
// host rather than on one that intermittently refuses. Second — and this is the guard that
// carries the file — **every case asserts the material existed before cleanup**: a nonzero
// object count per session, an occupied scope, and a nonzero store byte total, and then
// requires the first cleanup's removed count to equal the object count and the byte total to
// fall by exactly the bytes that session held. `emptyPreCleanupSnapshots` is counted outside
// the body and required to be zero, so a run whose fixtures quietly stopped writing anything
// fails there instead of passing.
//
// No protection level in a test is an approved release value either. All three levels, and
// the fail-closed refusal when a level cannot be applied, are pinned by
// `ProtectedEphemeralFileStoreTests` in the shared-transfer module; this file pins none of
// them and asserts nothing about what iOS enforces.
//
// ## Neighbouring properties, and what this file does not assert
//
//   * **Property 11** (task 10.6) owns cancellation's own statement, and Properties 29, 30,
//     and 34 through 36 (tasks 10.8 through 10.12) own terminal disjointness, error
//     presentation, and the absence of a synthesized timeout. A clock is generated here and
//     read only through the injected seam; nothing sleeps, no elapsed duration is compared
//     against a limit this file chose, and no timeout is asserted anywhere.
//   * The Evidence Report display-session half of the design's sentence is a presentation
//     claim about a visible report; task 11.3 owns it. Nothing below states what a user sees.
//   * `SessionTerminalCleanupTests` and `SessionCancellationTests` pin the reason-to-deadline
//     selection at one example per terminal, including the cancellation deadline Requirement
//     11.15 names. This file quantifies the same statement over generated trees, reasons,
//     interruptions, clocks, policies, and repeat counts, and adds the completeness,
//     idempotence-difference, expiry, and startup-ordering claims those examples do not make.
//   * `ProtectedSessionDataDeleterTests` covers the file-backed deleter and its fail-closed
//     verification. The adapter is not exercised here.

extension Tag {
    /// Design Property 25.
    ///
    /// Declared in this file rather than in a shared tag namespace: each design property gets
    /// one dedicated file, and a shared namespace would be a merge point between property
    /// files written independently of each other.
    @Tag static var property25SessionCleanupCompleteness: Self
}

@Suite(
    "Property 25: Session cleanup is complete, idempotent, and visibility-bounded",
    .tags(.property25SessionCleanupCompleteness)
)
struct SessionCleanupCompletenessPropertyTests {

    /// Runs at 200 generated cases rather than the library default of 100.
    ///
    /// Each case sweeps all five cleanup reasons over its own tree and runs the startup gate
    /// twice, and the coverage assertions in ``CleanupWitness`` name every reason, both
    /// policy shapes, and both gate outcomes. Raising the count is how those assertions are
    /// met; none of them is weakened to fit a smaller run.
    ///
    /// **Validates: Requirements 9.7, 9.8, 9.9, 9.14, 9.17, 11.15, 11.16**
    @Test("Cleanup empties every generated tree, repeats to nothing, and precedes ingest")
    func sessionCleanupIsCompleteIdempotentAndBounded() async {
        let witness = CleanupWitness()

        await propertyCheck(count: 200, input: CleanupShape.generator) { shape in
            witness.record(shape)

            // Claims 1, 2, and 3, one freshly built tree per cleanup reason.
            for path in CleanupPath.allPaths {
                await CleanupScenario(shape: shape, path: path, witness: witness)
                    .checkRemovalIsCompleteIdempotentAndBounded()
            }

            // Claim 3 again, under a policy whose numbers deliberately coincide.
            await CoincidentDeadlineScenario(shape: shape, witness: witness)
                .checkReasonsStayDistinctWhenDeadlinesDoNot()

            // Claim 4: an interruption, the real startup gate, and the ledger.
            await StartupOrderingScenario(shape: shape, witness: witness)
                .checkTheSweepPrecedesIngest()
            await StartupOrderingScenario(shape: shape, witness: witness)
                .checkAFailedSweepAdmitsNoIngest()

            witness.recordCompletedBody()
        }

        witness.expectVariedBaselinesAndFullCoverage()
    }
}

// MARK: - The generated shape

/// One generated case: a bounded virtual file tree, a policy, a clock, an interruption point,
/// and how many times cleanup repeats.
///
/// Every field varies something an assertion depends on, and ``CleanupWitness`` checks after
/// the run that each one actually varied:
///
///   * how many sessions own material and how many objects and bytes each one holds, so
///     "the ownership set is empty" is asserted over trees of different shapes rather than
///     over one;
///   * which objects are left mid-write, so a torn copy is present in some trees;
///   * which transfer slot states hold residue, so the startup sweep has cross-process
///     litter to remove as well as session material;
///   * the five deadlines and the order in which the reasons are assigned them, so no arm
///     depends on a particular reason holding the smallest number;
///   * which two reasons a coincident policy makes share a number;
///   * how much of the deadline has elapsed when cleanup runs, and where the clock starts;
///   * where the interrupted process died; and
///   * how many times cleanup is repeated.
private struct CleanupShape: Sendable, CustomStringConvertible {
    /// Drives every synthetic identifier, so a case's tree varies as one.
    let seed: Int

    /// How many sessions own material in the generated tree.
    let sessionCount: Int

    /// How many objects each session owns. At least one: a session with nothing stored
    /// would make an emptiness assertion vacuous.
    let objectsPerSession: Int

    /// Bytes per object. At least one, for the same reason.
    let bytesPerObject: Int

    /// Selects which objects are created and appended to but never finalized.
    let unfinalizedBits: Int

    /// Selects which of the three transfer slot states hold residue at startup.
    let transferSlotBits: Int

    /// Base for the generated deadlines, in milliseconds. Synthetic scaffolding.
    let deadlineBaseMilliseconds: Int

    /// Step between the generated deadlines, in milliseconds. Synthetic scaffolding.
    let deadlineStepMilliseconds: Int

    /// Rotates which reason is assigned the smallest generated deadline.
    let deadlineOrderSelector: Int

    /// Selects which unordered pair of reasons the coincident policy makes equal.
    let coincidenceSelector: Int

    /// How much of the deadline has elapsed when cleanup runs, in thousandths. Always
    /// under one, so the removal completes inside the window the policy allows.
    let elapsedPermille: Int

    /// How many times cleanup is repeated after the first pass. At least two calls total,
    /// because one repeat is the smallest observation idempotence can be made from.
    let repeatCount: Int

    /// Which write the interrupted process died on.
    let interruptionPointSelector: Int

    /// Offsets the generated clock's start instant.
    let clockStartOffsetSeconds: Int

    // MARK: Derived

    /// The five cleanup reasons in the order this case assigns deadlines to them.
    ///
    /// A rotation of the closed reason set, so every reason gets a distinct position and the
    /// smallest deadline moves between reasons across cases.
    private var rotatedReasons: [SessionCleanupReason] {
        let all = SessionCleanupReason.allCases
        let offset = deadlineOrderSelector % all.count
        return Array(all[offset...] + all[..<offset])
    }

    /// The milliseconds this case assigns to one reason.
    ///
    /// **Not an approved release value.** Distinct per reason by construction, which is the
    /// only meaningful property: it lets an assertion name which entry a receipt read.
    func deadlineMilliseconds(for reason: SessionCleanupReason) -> UInt64 {
        let position = rotatedReasons.firstIndex(of: reason) ?? 0
        return UInt64(deadlineBaseMilliseconds + deadlineStepMilliseconds * (position + 1))
    }

    /// The two reasons the coincident policy gives the same number.
    ///
    /// Drawn from the ten unordered pairs of the five reasons, so the pair moves across
    /// cases and no single pairing is special.
    var coincidentPair: (SessionCleanupReason, SessionCleanupReason) {
        let all = SessionCleanupReason.allCases
        var pairs: [(SessionCleanupReason, SessionCleanupReason)] = []
        for (index, first) in all.enumerated() {
            for second in all[(index + 1)...] { pairs.append((first, second)) }
        }
        return pairs[coincidenceSelector % pairs.count]
    }

    /// Whether the object at `index` within a session is left unfinalized.
    func leavesUnfinalized(objectIndex index: Int, sessionIndex: Int) -> Bool {
        let bit = (sessionIndex * 4 + index) % 12
        return unfinalizedBits & (1 << bit) != 0
    }

    /// The transfer slot states holding residue at startup.
    var residualTransferStates: [TransferSlotState] {
        TransferSlotState.allCases.enumerated().compactMap { index, state in
            transferSlotBits & (1 << index) != 0 ? state : nil
        }
    }

    /// The global write index the interrupted process died on.
    var interruptionPoint: Int { interruptionPointSelector % 6 }

    /// The instant the generated clock starts at.
    var clockStart: Date {
        VirtualSessionClock.defaultStart.addingTimeInterval(Double(clockStartOffsetSeconds))
    }

    /// A session identifier for one slot in the tree.
    func sessionID(_ index: Int) -> AnalysisSessionID {
        PortValue.sessionID("session-p25-\(seed)-\(index)")
    }

    /// A transfer identifier for one residual slot.
    func transferID(_ state: TransferSlotState) -> ShareTransferID {
        PortValue.transferID("transfer-p25-\(seed)-\(state.rawValue)")
    }

    var description: String {
        """
        seed \(seed), sessions \(sessionCount), objects \(objectsPerSession), \
        bytes \(bytesPerObject), unfinalizedBits \(unfinalizedBits), \
        transferStates \(residualTransferStates.map(\.rawValue)), \
        deadlineBase \(deadlineBaseMilliseconds)ms, step \(deadlineStepMilliseconds)ms, \
        order \(deadlineOrderSelector % 5), coincidentPair \(coincidentPair.0.rawValue)/\
        \(coincidentPair.1.rawValue), elapsed \(elapsedPermille)‰, \
        repeats \(repeatCount), interruptionPoint \(interruptionPoint), \
        clockOffset \(clockStartOffsetSeconds)s
        """
    }

    // MARK: Generators

    static var generator: Generator<CleanupShape, AnySequence<Any>> {
        zip(Gen.int(in: 0...9_999), treeShape, policyShape, runtimeShape)
            .map { raw in
                CleanupShape(
                    seed: raw.0,
                    sessionCount: raw.1.0,
                    objectsPerSession: raw.1.1,
                    bytesPerObject: raw.1.2,
                    unfinalizedBits: raw.1.3,
                    transferSlotBits: raw.1.4,
                    deadlineBaseMilliseconds: raw.2.0,
                    deadlineStepMilliseconds: raw.2.1,
                    deadlineOrderSelector: raw.2.2,
                    coincidenceSelector: raw.2.3,
                    elapsedPermille: raw.3.0,
                    repeatCount: raw.3.1,
                    interruptionPointSelector: raw.3.2,
                    clockStartOffsetSeconds: raw.3.3
                )
            }
            .eraseToAny()
    }

    /// The bounded virtual tree: how many sessions, objects, and bytes, which writes are
    /// torn, and which transfer slots hold residue.
    private static var treeShape: Generator<(Int, Int, Int, Int, Int), AnySequence<Any>> {
        zip(
            Gen.int(in: 1...4),
            Gen.int(in: 1...3),
            Gen.int(in: 1...96),
            Gen.int(in: 0...4_095),
            Gen.int(in: 0...7)
        )
        .eraseToAny()
    }

    /// The generated policy. Ranges keep every derived deadline inside
    /// ``ValidatedDuration``'s structural ceiling with room to spare.
    private static var policyShape: Generator<(Int, Int, Int, Int), AnySequence<Any>> {
        zip(
            Gen.int(in: 1_000...9_000),
            Gen.int(in: 1...4_000),
            // A multiple of the five reasons and of the ten pairs, so reducing by either
            // modulus stays uniform.
            Gen.int(in: 0...959),
            Gen.int(in: 0...959)
        )
        .eraseToAny()
    }

    /// The clock, the repeat count, and the interruption point.
    private static var runtimeShape: Generator<(Int, Int, Int, Int), AnySequence<Any>> {
        zip(
            // Strictly under one thousand, so elapsed time stays inside the deadline.
            Gen.int(in: 0...959),
            Gen.int(in: 2...4),
            Gen.int(in: 0...959),
            Gen.int(in: 0...959)
        )
        .eraseToAny()
    }
}

// MARK: - Generated policies

/// The lifecycle policies one generated case runs against.
///
/// **No deadline in either policy is an approved release value.** Both are built from the
/// generated shape so that an assertion can name which entry was read; the numbers carry no
/// product meaning and nothing here may be copied into a shipping artifact.
private enum GeneratedPolicy {

    /// The artifact identifier both policies use.
    ///
    /// The same identifier the coordinator fixtures register, because the startup gate looks
    /// the lifecycle policy up by exact identifier. Only the deadlines vary.
    static var id: ArtifactID {
        CoordinatorSample.artifact(CoordinatorSample.lifecyclePolicyID)
    }

    /// A policy giving all five reasons distinct deadlines.
    static func distinct(_ shape: CleanupShape) -> DataLifecyclePolicy? {
        build { shape.deadlineMilliseconds(for: $0) }
    }

    /// A policy in which one generated pair of reasons shares a deadline.
    static func coincident(_ shape: CleanupShape) -> DataLifecyclePolicy? {
        let (first, second) = shape.coincidentPair
        return build { reason in
            shape.deadlineMilliseconds(for: reason == second ? first : reason)
        }
    }

    /// Builds a schema-valid policy, or `nil` when a generated number was out of range.
    ///
    /// A refusal is a defect in this file rather than a finding, and it is reported as an
    /// unbuildable input rather than thrown: `propertyCheck` discards an error thrown from
    /// its body, and a throw here would report a passing run with every arm skipped.
    private static func build(
        _ milliseconds: (SessionCleanupReason) -> UInt64
    ) -> DataLifecyclePolicy? {
        do {
            return try DataLifecyclePolicy(
                id: id,
                schemaVersion: .v1,
                deadlines: try SessionCleanupReason.allCases.map { reason in
                    DataLifecyclePolicy.Deadline(
                        reason: reason,
                        deadline: try ValidatedDuration(validating: milliseconds(reason))
                    )
                },
                approval: CoordinatorSample.approval()
            )
        } catch {
            return nil
        }
    }
}

// MARK: - The five cleanup paths

/// One cleanup reason and the port member that reaches it.
///
/// Three of the five reasons are selected by a committed ``SessionTerminalOutcome`` and go
/// through ``SessionTerminalCleanup``, which is the only place a terminal picks a deadline.
/// The remaining two have no terminal outcome to select them: `interrupted` names material a
/// dead process left, and `abandoned` names material found at startup, so they are reached
/// through the deletion port directly and through the startup sweep respectively. Covering
/// all five is what makes "for every terminal reason" a statement about the policy's whole
/// closed reason set rather than about the three a running session can commit.
private enum CleanupPath: Sendable {
    /// A committed terminal outcome, cleaned through ``SessionTerminalCleanup``.
    case terminal(SessionTerminalOutcome)

    /// A session end reason with no terminal outcome, cleaned through the port.
    case portReason(SessionEndReason)

    /// Material found at startup, cleaned by the abandoned sweep.
    case startupSweep

    /// Every path, one per cleanup reason.
    static var allPaths: [CleanupPath] {
        [
            .terminal(Fixture.completedOutcome()),
            .terminal(.cancelled),
            .terminal(Fixture.failedOutcome()),
            .portReason(.interrupted),
            .startupSweep,
        ]
    }

    /// The cleanup reason this path must produce.
    var expectedReason: SessionCleanupReason {
        switch self {
        case .terminal(let outcome): outcome.endReason.cleanupReason
        case .portReason(let reason): reason.cleanupReason
        case .startupSweep: .abandoned
        }
    }

    /// A label for assertion messages.
    var label: String { expectedReason.rawValue }
}

// MARK: - The virtual tree

/// One bounded virtual file tree, and what was written into it.
///
/// Holds the per-session object counts and byte totals it wrote, so an emptiness assertion
/// can be paired with the exact quantity that had to be removed for it to hold.
private struct VirtualTree {
    let store: InMemoryEphemeralStore
    let clock: VirtualSessionClock

    /// The sessions that own material, in write order.
    let sessions: [AnalysisSessionID]

    /// Objects written per session.
    let objectCountBySession: [AnalysisSessionID: Int]

    /// Bytes written per session.
    let byteCountBySession: [AnalysisSessionID: Int]

    /// Transfer slots holding residue.
    let transferScopes: [EphemeralStorageScope]

    /// When the material was created, for deadline evaluation.
    let createdAt: Date

    /// Total objects across every session.
    var sessionObjectCount: Int { objectCountBySession.values.reduce(0, +) }

    /// Total bytes across every session.
    var sessionByteCount: Int { byteCountBySession.values.reduce(0, +) }

    /// Builds a tree, or `nil` when the store refused a write.
    ///
    /// `truncatingAt` models an interruption: writes before it are finalized, the write at
    /// it is created and appended to but never finalized, and writes after it never happen.
    /// `nil` writes the whole tree, with individual objects left unfinalized where the shape
    /// says so.
    ///
    /// Returns `nil` rather than throwing, and the caller reports it as an unbuildable
    /// input: a throw would be discarded by `propertyCheck` and would report a passing run.
    static func build(
        shape: CleanupShape,
        truncatingAt truncationPoint: Int?,
        includeTransferResidue: Bool
    ) async -> VirtualTree? {
        let clock = VirtualSessionClock(start: shape.clockStart)
        let store = InMemoryEphemeralStore(clock: clock)
        let createdAt = clock.wallClockNow
        let bytes = PortValue.bytes(
            count: shape.bytesPerObject,
            seed: UInt8(truncatingIfNeeded: shape.seed)
        )

        var sessions: [AnalysisSessionID] = []
        var objectCounts: [AnalysisSessionID: Int] = [:]
        var byteCounts: [AnalysisSessionID: Int] = [:]
        var globalIndex = 0

        for sessionIndex in 0..<shape.sessionCount {
            let sessionID = shape.sessionID(sessionIndex)
            for objectIndex in 0..<shape.objectsPerSession {
                if let truncationPoint, globalIndex > truncationPoint {
                    globalIndex += 1
                    continue
                }
                let tornByInterruption = truncationPoint == globalIndex
                let tornByShape = shape.leavesUnfinalized(
                    objectIndex: objectIndex,
                    sessionIndex: sessionIndex
                )
                let leaveUnfinalized = tornByInterruption || (truncationPoint == nil && tornByShape)
                guard await write(
                    bytes,
                    for: sessionID,
                    into: store,
                    leaveUnfinalized: leaveUnfinalized
                ) else {
                    return nil
                }
                objectCounts[sessionID, default: 0] += 1
                byteCounts[sessionID, default: 0] += bytes.count
                globalIndex += 1
            }
            if objectCounts[sessionID] != nil { sessions.append(sessionID) }
        }

        // A tree with nothing in it would make every emptiness assertion vacuous, so it is
        // not a case this file accepts.
        guard !sessions.isEmpty else { return nil }

        var transferScopes: [EphemeralStorageScope] = []
        if includeTransferResidue {
            for state in shape.residualTransferStates {
                let scope = EphemeralStorageScope.transfer(shape.transferID(state), state)
                guard (try? await store.writeComplete(
                    bytes,
                    in: scope,
                    protection: Self.protectionLevel
                )) != nil else {
                    return nil
                }
                transferScopes.append(scope)
            }
        }

        return VirtualTree(
            store: store,
            clock: clock,
            sessions: sessions,
            objectCountBySession: objectCounts,
            byteCountBySession: byteCounts,
            transferScopes: transferScopes,
            createdAt: createdAt
        )
    }

    /// The data-protection level every object in this file is written at.
    ///
    /// **Not an approved release value.** Pinned to the level that is known to be applicable
    /// on this host so that a later substitution of the file-backed store does not turn a
    /// refused file creation into an ownership set that was empty because nothing was ever
    /// written. All three levels and the fail-closed refusal are pinned by
    /// `ProtectedEphemeralFileStoreTests`; nothing here asserts what iOS enforces.
    static let protectionLevel: FileProtectionLevel = .completeUntilFirstUserAuthentication

    /// Writes one object, finalized or deliberately torn. Reports success rather than
    /// throwing.
    private static func write(
        _ bytes: [UInt8],
        for sessionID: AnalysisSessionID,
        into store: InMemoryEphemeralStore,
        leaveUnfinalized: Bool
    ) async -> Bool {
        let scope = EphemeralStorageScope.session(sessionID)
        guard leaveUnfinalized else {
            return (try? await store.writeComplete(
                bytes,
                in: scope,
                protection: protectionLevel
            )) != nil
        }
        // Created and appended to, never finalized: an incomplete copy that is unreadable
        // and unpromotable, and that cleanup still has to remove.
        guard let key = try? await store.create(in: scope, protection: protectionLevel) else {
            return false
        }
        return (try? await store.append(bytes, to: key)) != nil
    }
}

// MARK: - Claims 1, 2, and 3

/// One cleanup reason run over its own freshly built tree.
private struct CleanupScenario {
    let shape: CleanupShape
    let path: CleanupPath
    let witness: CleanupWitness

    /// Removes every session's material, repeats the removal, and audits the receipts.
    func checkRemovalIsCompleteIdempotentAndBounded() async {
        guard let policy = GeneratedPolicy.distinct(shape) else {
            witness.recordUnbuildableInput()
            return
        }
        guard let tree = await VirtualTree.build(
            shape: shape,
            truncatingAt: nil,
            includeTransferResidue: path.expectedReason == .abandoned
        ) else {
            witness.recordUnbuildableInput()
            return
        }
        let deleter = FakeSessionDataDeleter(store: tree.store, clock: tree.clock)
        if path.expectedReason == .abandoned {
            // Abandoned material is by definition material with no live session, so nothing
            // is registered live: registering one would make the sweep skip it.
            for session in tree.sessions { await deleter.forgetLiveSession(session) }
        } else {
            for session in tree.sessions { await deleter.registerLiveSession(session) }
        }

        // The generated policy has to be the thing that makes the deadlines distinguishable,
        // so that is checked before any receipt is read.
        let declared = SessionCleanupReason.allCases.map { policy.deadline(for: $0).milliseconds }
        #expect(
            Set(declared).count == SessionCleanupReason.allCases.count,
            "the generated policy must give every reason its own deadline: \(declared)"
        )

        guard await checkMaterialExists(tree) else { return }

        // Some of the deadline has passed, but not all of it: the removal below completes
        // inside the window the policy allows for this reason.
        let deadline = policy.deadline(for: path.expectedReason)
        let elapsed = Int64(deadline.milliseconds) * Int64(shape.elapsedPermille) / 1_000
        tree.clock.advance(by: .milliseconds(elapsed))

        let first = await runCleanup(tree: tree, deleter: deleter, policy: policy)
        checkReceipts(first, tree: tree, policy: policy, isRepeat: false)
        await checkOwnershipSetIsEmpty(tree, after: "the first cleanup")

        let bytesAfterFirst = await tree.store.usedByteCount
        #expect(
            bytesAfterFirst == 0,
            "\(path.label): \(bytesAfterFirst) bytes survived the first cleanup"
        )

        // Idempotence is the difference between the two counts, not the pair of successes.
        for repetition in 1..<shape.repeatCount {
            let again = await runCleanup(tree: tree, deleter: deleter, policy: policy)
            checkReceipts(again, tree: tree, policy: policy, isRepeat: true)
            await checkOwnershipSetIsEmpty(tree, after: "repeat \(repetition)")
            let bytesNow = await tree.store.usedByteCount
            #expect(
                bytesNow == bytesAfterFirst,
                "\(path.label): repeat \(repetition) changed the byte total to \(bytesNow)"
            )
            witness.recordRepeat()
        }

        // Requirement 9.17 read at the boundary it names: once the reason's deadline has
        // expired, nothing from the session is left in app-controlled storage.
        #expect(
            tree.clock.isDue(createdAt: tree.createdAt, deadline: deadline) == false,
            "\(path.label): the removal did not complete inside its \(deadline) window"
        )
        tree.clock.advancePast(deadline)
        #expect(
            tree.clock.isDue(createdAt: tree.createdAt, deadline: deadline),
            "\(path.label): the generated clock did not reach the \(deadline) deadline"
        )
        await checkOwnershipSetIsEmpty(tree, after: "the deadline expired")
        witness.recordExpiryCheck()
    }

    /// Requires the material to be present, and counted, before anything is removed.
    ///
    /// The single most important guard in this file. Without it every emptiness assertion
    /// would hold just as well for a tree that was never written, and a store that could not
    /// create an object would look like a cleanup that worked.
    private func checkMaterialExists(_ tree: VirtualTree) async -> Bool {
        let occupied = await tree.store.occupiedScopes()
        let usedBytes = await tree.store.usedByteCount
        var everySessionHasMaterial = true

        for session in tree.sessions {
            let keys = await tree.store.keys(in: .session(session))
            let expected = tree.objectCountBySession[session] ?? 0
            if keys.count != expected || expected == 0 { everySessionHasMaterial = false }
            #expect(
                keys.count == expected && expected > 0,
                "\(path.label): session \(session.rawValue) holds \(keys.count) objects before cleanup, expected \(expected) and at least one"
            )
            #expect(
                occupied.contains(.session(session)),
                "\(path.label): session \(session.rawValue) does not own a scope before cleanup"
            )
        }

        #expect(
            usedBytes == tree.sessionByteCount + transferByteCount(tree),
            "\(path.label): the tree holds \(usedBytes) bytes before cleanup, expected \(tree.sessionByteCount + transferByteCount(tree))"
        )
        let present = everySessionHasMaterial && usedBytes > 0
        witness.recordPreCleanupSnapshot(
            objectCount: tree.sessionObjectCount,
            byteCount: usedBytes,
            wasPresent: present
        )
        return present
    }

    private func transferByteCount(_ tree: VirtualTree) -> Int {
        tree.transferScopes.count * shape.bytesPerObject
    }

    /// Runs this path's cleanup once, and reports the receipts it produced.
    ///
    /// Every failure becomes a recorded issue and an empty receipt list rather than a thrown
    /// error, so a store fault cannot end the case early and be reported as a pass.
    private func runCleanup(
        tree: VirtualTree,
        deleter: FakeSessionDataDeleter,
        policy: DataLifecyclePolicy
    ) async -> [SessionDeletionReceipt] {
        switch path {
        case .terminal(let outcome):
            let cleanup = SessionTerminalCleanup(deleter: deleter, policy: policy)
            // The deadline can be read before the deletion, and it has to be the same one
            // the receipt carries: the reason mapping is the outcome's, not the caller's.
            let announced = cleanup.deadline(for: outcome)
            #expect(
                announced == policy.deadline(for: path.expectedReason),
                "\(path.label): the announced deadline \(announced) is not the policy's entry"
            )
            var receipts: [SessionDeletionReceipt] = []
            for session in tree.sessions {
                let result = await cleanup.removeMaterial(for: session, after: outcome)
                guard let receipt = result.receipt else {
                    Issue.record(
                        "\(path.label): cleanup of \(session.rawValue) reported \(String(describing: result.storeFault))"
                    )
                    continue
                }
                #expect(
                    receipt.deadline == announced,
                    "\(path.label): the receipt's deadline is not the announced one"
                )
                receipts.append(receipt)
            }
            return receipts

        case .portReason(let reason):
            var receipts: [SessionDeletionReceipt] = []
            for session in tree.sessions {
                guard let receipt = try? await deleter.deleteSession(
                    session,
                    reason: reason,
                    policy: policy
                ) else {
                    Issue.record("\(path.label): cleanup of \(session.rawValue) failed")
                    continue
                }
                receipts.append(receipt)
            }
            return receipts

        case .startupSweep:
            guard let receipts = try? await deleter.deleteAbandonedData(policy: policy) else {
                Issue.record("\(path.label): the startup sweep failed")
                return []
            }
            return receipts
        }
    }

    /// Audits one cleanup's receipts against the policy and the tree.
    private func checkReceipts(
        _ receipts: [SessionDeletionReceipt],
        tree: VirtualTree,
        policy: DataLifecyclePolicy,
        isRepeat: Bool
    ) {
        let expectedDeadline = policy.deadline(for: path.expectedReason)

        if isRepeat {
            // A repeat removes nothing. The sweep answers that with no receipts at all,
            // because a scope it cannot see is a scope it issues no receipt for; the two
            // per-session paths answer it with a zero count. Either way the removed total
            // is zero, and that is what the assertion is about.
            let removed = receipts.reduce(0) { $0 + $1.removedObjectCount }
            #expect(
                removed == 0,
                "\(path.label): a repeated cleanup reported \(removed) objects removed"
            )
        } else {
            let removed = receipts.reduce(0) { $0 + $1.removedObjectCount }
            #expect(
                removed == tree.sessionObjectCount,
                "\(path.label): the first cleanup removed \(removed) of \(tree.sessionObjectCount) stored objects"
            )
            #expect(
                removed > 0,
                "\(path.label): the first cleanup removed nothing, so emptiness afterwards would not be a removal"
            )
            #expect(
                receipts.count == tree.sessions.count,
                "\(path.label): \(receipts.count) receipts for \(tree.sessions.count) sessions"
            )
            for receipt in receipts {
                let expectedForSession = tree.objectCountBySession[receipt.sessionID] ?? -1
                #expect(
                    receipt.removedObjectCount == expectedForSession,
                    "\(path.label): \(receipt.sessionID.rawValue) reported \(receipt.removedObjectCount) removed, stored \(expectedForSession)"
                )
            }
        }

        for receipt in receipts {
            // The reason is the one the path selected, and the deadline is that reason's
            // entry in the policy rather than a number anything chose.
            #expect(
                receipt.reason == path.expectedReason,
                "\(path.label): the receipt carries reason \(receipt.reason.rawValue)"
            )
            #expect(
                receipt.deadline == expectedDeadline,
                "\(path.label): the receipt carries \(receipt.deadline), policy says \(expectedDeadline)"
            )
            #expect(
                receipt.lifecyclePolicyID == policy.id,
                "\(path.label): the receipt names policy \(receipt.lifecyclePolicyID.rawValue)"
            )
            // Stamped from the injected clock, so no arm here depends on real time.
            #expect(
                receipt.completedAt == tree.clock.wallClockNow,
                "\(path.label): the receipt was not stamped from the injected clock"
            )
            // Every other reason's deadline is a different number under this policy, so a
            // receipt that read the wrong entry cannot pass the check above by coincidence.
            for other in SessionCleanupReason.allCases where other != path.expectedReason {
                #expect(
                    receipt.deadline != policy.deadline(for: other),
                    "\(path.label): the receipt's deadline also equals the \(other.rawValue) entry, so the reason it read is not identifiable"
                )
            }
            witness.recordReceipt(receipt)
        }
    }

    /// Requires no scope, no key, no incomplete copy, and no byte to name any session.
    private func checkOwnershipSetIsEmpty(_ tree: VirtualTree, after stage: String) async {
        let occupied = await tree.store.occupiedScopes()
        let sessionScopes = occupied.filter { scope in
            if case .session = scope { return true }
            return false
        }
        #expect(
            sessionScopes.isEmpty,
            "\(path.label): \(sessionScopes.count) session scopes survived \(stage)"
        )
        for session in tree.sessions {
            let keys = await tree.store.keys(in: .session(session))
            #expect(
                keys.isEmpty,
                "\(path.label): \(session.rawValue) still lists \(keys.count) objects after \(stage)"
            )
        }
        let unfinalized = await tree.store.unfinalizedKeys
        #expect(
            unfinalized.isEmpty,
            "\(path.label): \(unfinalized.count) incomplete copies survived \(stage)"
        )
        if path.expectedReason == .abandoned {
            // The sweep clears the cross-process litter as well, so the whole tree is empty
            // and the byte total is the strongest statement available.
            #expect(
                occupied.isEmpty,
                "\(path.label): \(occupied.count) scopes survived \(stage)"
            )
        }
        witness.recordEmptinessCheck()
    }
}

// MARK: - Claim 3 under a coincident policy

/// The same deadline selection, under a policy whose numbers deliberately collide.
///
/// This is the arm that keeps the distinctness of the generated policy from doing the
/// assertions' work. When two reasons share a number, a receipt that read the wrong entry
/// would compare equal — so what is required here is that the receipt still carries **its
/// own reason** and the number the policy declares **for that reason**. The policy is read;
/// nothing infers a reason from a deadline or a deadline from a reason.
private struct CoincidentDeadlineScenario {
    let shape: CleanupShape
    let witness: CleanupWitness

    func checkReasonsStayDistinctWhenDeadlinesDoNot() async {
        guard let policy = GeneratedPolicy.coincident(shape) else {
            witness.recordUnbuildableInput()
            return
        }
        let (first, second) = shape.coincidentPair
        #expect(
            policy.deadline(for: first) == policy.deadline(for: second),
            "the coincident policy must actually make \(first.rawValue) and \(second.rawValue) share a deadline"
        )

        for path in CleanupPath.allPaths {
            guard let tree = await VirtualTree.build(
                shape: shape,
                truncatingAt: nil,
                includeTransferResidue: false
            ) else {
                witness.recordUnbuildableInput()
                return
            }
            let deleter = FakeSessionDataDeleter(store: tree.store, clock: tree.clock)
            for session in tree.sessions { await deleter.forgetLiveSession(session) }
            let objectCount = tree.sessionObjectCount
            #expect(
                objectCount > 0,
                "the coincident arm needs material to remove, found \(objectCount) objects"
            )

            let receipts = await removeAll(tree: tree, deleter: deleter, policy: policy, path: path)
            let removed = receipts.reduce(0) { $0 + $1.removedObjectCount }
            #expect(
                removed == objectCount,
                "coincident \(path.label): removed \(removed) of \(objectCount) objects"
            )
            for receipt in receipts {
                #expect(
                    receipt.reason == path.expectedReason,
                    "coincident \(path.label): the receipt carries \(receipt.reason.rawValue)"
                )
                #expect(
                    receipt.deadline == policy.deadline(for: path.expectedReason),
                    "coincident \(path.label): the receipt's deadline is not the policy's entry for \(path.label)"
                )
                witness.recordCoincidentReceipt(receipt)
            }
            let occupied = await tree.store.occupiedScopes()
            #expect(
                occupied.isEmpty,
                "coincident \(path.label): \(occupied.count) scopes survived cleanup"
            )
        }
        witness.recordCoincidentPair(first, second)
    }

    private func removeAll(
        tree: VirtualTree,
        deleter: FakeSessionDataDeleter,
        policy: DataLifecyclePolicy,
        path: CleanupPath
    ) async -> [SessionDeletionReceipt] {
        switch path {
        case .terminal(let outcome):
            let cleanup = SessionTerminalCleanup(deleter: deleter, policy: policy)
            var receipts: [SessionDeletionReceipt] = []
            for session in tree.sessions {
                if let receipt = await cleanup.removeMaterial(for: session, after: outcome)
                    .receipt {
                    receipts.append(receipt)
                } else {
                    Issue.record("coincident \(path.label): cleanup reported a store fault")
                }
            }
            return receipts
        case .portReason(let reason):
            var receipts: [SessionDeletionReceipt] = []
            for session in tree.sessions {
                if let receipt = try? await deleter.deleteSession(
                    session,
                    reason: reason,
                    policy: policy
                ) {
                    receipts.append(receipt)
                } else {
                    Issue.record("coincident \(path.label): cleanup failed")
                }
            }
            return receipts
        case .startupSweep:
            guard let receipts = try? await deleter.deleteAbandonedData(policy: policy) else {
                Issue.record("coincident \(path.label): the sweep failed")
                return []
            }
            return receipts
        }
    }
}

// MARK: - Claim 4: interruption, the real gate, and the ledger

/// What one operation the ledger recorded was.
///
/// A recorded sequence rather than an end state, because the ordering *is* the requirement:
/// a final state in which the tree is empty and a session is bound is reachable in either
/// order, and only one of the two orders satisfies Requirement 9.9.
private enum CleanupLedgerEvent: Equatable, CustomStringConvertible {
    /// The startup sweep was entered.
    case sweepBegan

    /// The sweep returned, with what the tree still held at that instant.
    case sweepEnded(sessionScopeCount: Int, usedByteCount: Int, receiptCount: Int)

    /// The sweep refused.
    case sweepFailed

    /// A terminal cleanup ran.
    case terminalCleanup(SessionCleanupReason)

    /// New ingest wrote its own material. Only reachable while holding an admission.
    case ingestWrote

    /// The binder accepted the new input. Only reachable while holding an admission.
    case ingestBound

    var isIngest: Bool { self == .ingestWrote || self == .ingestBound }

    var description: String {
        switch self {
        case .sweepBegan: "sweep-began"
        case .sweepEnded(let scopes, let bytes, let receipts):
            "sweep-ended(scopes: \(scopes), bytes: \(bytes), receipts: \(receipts))"
        case .sweepFailed: "sweep-failed"
        case .terminalCleanup(let reason): "terminal-cleanup(\(reason.rawValue))"
        case .ingestWrote: "ingest-wrote"
        case .ingestBound: "ingest-bound"
        }
    }
}

/// An append-only record of cleanup and ingest operations, in the order they happened.
private final class CleanupLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [CleanupLedgerEvent] = []

    func append(_ event: CleanupLedgerEvent) {
        lock.lock()
        recorded.append(event)
        lock.unlock()
    }

    var events: [CleanupLedgerEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

/// A ``SessionDataDeleting`` that writes what it did into a ledger.
///
/// A decorator, not a replacement: every deletion is the wrapped deleter's, and the only
/// thing added is the record. It snapshots the tree immediately after the sweep returns,
/// inside the gate and therefore before the gate can produce an admission, which is what
/// makes "nothing analysis-bearing survived the interruption" an observation at the sweep
/// boundary rather than a conclusion drawn from the end state.
private struct LedgerRecordingDeleter: SessionDataDeleting {
    let inner: FakeSessionDataDeleter
    let store: InMemoryEphemeralStore
    let ledger: CleanupLedger

    func deleteSession(
        _ id: AnalysisSessionID,
        reason: SessionEndReason,
        policy: DataLifecyclePolicy
    ) async throws(EphemeralStoreError) -> SessionDeletionReceipt {
        let receipt = try await inner.deleteSession(id, reason: reason, policy: policy)
        ledger.append(.terminalCleanup(receipt.reason))
        return receipt
    }

    func deleteAbandonedData(
        policy: DataLifecyclePolicy
    ) async throws(EphemeralStoreError) -> [SessionDeletionReceipt] {
        ledger.append(.sweepBegan)
        let receipts: [SessionDeletionReceipt]
        do {
            receipts = try await inner.deleteAbandonedData(policy: policy)
        } catch {
            ledger.append(.sweepFailed)
            throw error
        }
        let occupied = await store.occupiedScopes()
        let sessionScopes = occupied.filter { scope in
            if case .session = scope { return true }
            return false
        }
        ledger.append(
            .sweepEnded(
                sessionScopeCount: sessionScopes.count,
                usedByteCount: await store.usedByteCount,
                receiptCount: receipts.count
            )
        )
        return receipts
    }
}

/// An interrupted tree, the real startup gate over it, and the ledger of what happened.
private struct StartupOrderingScenario {
    let shape: CleanupShape
    let witness: CleanupWitness

    /// The sweep runs first, empties the tree, and only then is ingest reachable.
    func checkTheSweepPrecedesIngest() async {
        guard let run = await runGate(failingTheSweep: false) else { return }

        guard case .admitted(let admission) = run.outcome else {
            Issue.record("the coherent release was not admitted: \(run.outcome)")
            return
        }

        // Ingest is performed through the value the gate produced, so no ingest event can be
        // recorded without the sweep having returned first.
        await admitIngest(under: admission, run: run)

        let events = run.ledger.events
        #expect(events.first == .sweepBegan, "the ledger does not open with the sweep: \(events)")
        guard let sweepEnd = events.firstIndex(where: { event in
            if case .sweepEnded = event { return true }
            return false
        }) else {
            Issue.record("the sweep never completed: \(events)")
            return
        }
        let ingestIndices = events.indices.filter { events[$0].isIngest }
        #expect(
            !ingestIndices.isEmpty,
            "no ingest was recorded, so the ordering claim has nothing to bite on"
        )
        #expect(
            ingestIndices.allSatisfy { $0 > sweepEnd },
            "ingest was admitted before startup cleanup finished: \(events)"
        )
        #expect(
            events.contains(.ingestBound),
            "the binder never accepted the new input: \(events)"
        )

        // What the tree held at the instant the sweep returned. Nothing analysis-bearing may
        // survive an interruption, and the material was counted before the gate ran.
        if case .sweepEnded(let scopes, let bytes, let receipts) = events[sweepEnd] {
            #expect(
                scopes == 0,
                "\(scopes) session scopes survived the interruption at the sweep boundary"
            )
            #expect(
                bytes == 0,
                "\(bytes) bytes survived the interruption at the sweep boundary"
            )
            #expect(
                receipts == run.sessionCount,
                "the sweep issued \(receipts) receipts for \(run.sessionCount) abandoned sessions"
            )
        }

        // The gate audits every startup receipt itself; these are the values it required.
        let sweepReceipts = admission.startupCleanup
        #expect(
            sweepReceipts.allSatisfy { $0.reason == .abandoned },
            "a startup receipt carried a reason other than abandoned"
        )
        #expect(
            sweepReceipts.allSatisfy { $0.deadline == run.policy.deadline(for: .abandoned) },
            "a startup receipt carried a deadline other than the abandoned entry"
        )
        let removed = sweepReceipts.reduce(0) { $0 + $1.removedObjectCount }
        #expect(
            removed == run.objectCount,
            "the sweep removed \(removed) of \(run.objectCount) abandoned objects"
        )
        witness.recordStartupSweep(interruptedObjectCount: run.objectCount)
    }

    /// A sweep that refuses closes ingest completely: no admission, and no ingest event.
    func checkAFailedSweepAdmitsNoIngest() async {
        guard let run = await runGate(failingTheSweep: true) else { return }

        guard case .refused(let failure) = run.outcome else {
            Issue.record("a refused startup cleanup still admitted ingest: \(run.outcome)")
            return
        }
        // The typed failure, not its description: the gate has to refuse *because* cleanup
        // did, rather than because some other step happened to fail on the same input.
        guard case .startupCleanupFailed(let fault) = failure else {
            Issue.record("the refusal did not name the cleanup failure: \(failure)")
            return
        }
        #expect(
            fault == .storeUnavailable,
            "the refusal carried store fault \(fault), expected the injected one"
        )

        let events = run.ledger.events
        #expect(events.contains(.sweepBegan), "the sweep was never attempted: \(events)")
        #expect(events.contains(.sweepFailed), "the sweep did not report a failure: \(events)")
        // The structural half of the ordering claim: `ReleaseAdmission` is the only value
        // that reaches ingest, and the gate produced none, so there is nothing to ingest
        // through. Material is still on disk, and the next start sweeps it again.
        #expect(
            events.allSatisfy { !$0.isIngest },
            "ingest happened after a failed startup cleanup: \(events)"
        )
        witness.recordRefusedGate()
    }

    // MARK: The gate

    /// What one gate run produced.
    private enum GateOutcome: CustomStringConvertible {
        case admitted(ReleaseAdmission)
        case refused(PreflightFailure)

        var description: String {
            switch self {
            case .admitted: "admitted"
            case .refused(let failure): "refused(\(failure))"
            }
        }
    }

    /// One gate run and everything an assertion needs from it.
    private struct GateRun {
        let outcome: GateOutcome
        let ledger: CleanupLedger
        let store: InMemoryEphemeralStore
        let bundles: StubModelBundleManager
        let policy: DataLifecyclePolicy
        let sessionCount: Int
        let objectCount: Int
    }

    /// Builds an interrupted tree, runs the real seven-step gate over it, and returns both.
    ///
    /// Every artifact is the coordinator fixtures' coherent synthetic release, with the
    /// generated lifecycle policy substituted so this case's deadlines are the ones the gate
    /// binds. Nothing is bypassed: the operating-system floor, the manifest approval and
    /// composition match, the allowlist entry and its version tuple, the active bundle, this
    /// target's budget and its validation plan, startup cleanup, and the module graph are all
    /// evaluated, and the sweep is step 5 of the seven.
    private func runGate(failingTheSweep: Bool) async -> GateRun? {
        guard let policy = GeneratedPolicy.distinct(shape) else {
            witness.recordUnbuildableInput()
            return nil
        }
        // Truncated at the generated interruption point: finalized objects, one torn write,
        // and nothing after it, plus whatever transfer residue the shape asked for.
        guard let tree = await VirtualTree.build(
            shape: shape,
            truncatingAt: shape.interruptionPoint,
            includeTransferResidue: true
        ) else {
            witness.recordUnbuildableInput()
            return nil
        }

        // The interruption itself: material exists, no session is live, and no terminal
        // deletion receipt was ever written.
        let inner = FakeSessionDataDeleter(store: tree.store, clock: tree.clock)
        for session in tree.sessions { await inner.forgetLiveSession(session) }

        let objectCount = tree.sessionObjectCount
        let usedBytes = await tree.store.usedByteCount
        // The same anti-vacuity guard the other arms use: an interrupted tree with nothing
        // in it would make the sweep-boundary snapshot meaningless.
        #expect(
            objectCount > 0 && usedBytes > 0,
            "the interrupted tree holds \(objectCount) objects and \(usedBytes) bytes"
        )
        witness.recordPreCleanupSnapshot(
            objectCount: objectCount,
            byteCount: usedBytes,
            wasPresent: objectCount > 0 && usedBytes > 0
        )
        witness.recordInterruptionPoint(shape.interruptionPoint, torn: objectCount)

        if failingTheSweep {
            await tree.store.failNextOperation(with: .storeUnavailable)
        }

        let ledger = CleanupLedger()
        let cleanup = LedgerRecordingDeleter(inner: inner, store: tree.store, ledger: ledger)
        let policies = InMemoryArtifactStore()
        await policies.register(CoordinatorSample.capabilityManifest(provenance: false, fusion: false))
        await policies.register(CoordinatorSample.allowlist(provenance: false, fusion: false))
        await policies.register(policy)
        await policies.register(CoordinatorSample.extensionExecutionPolicy())
        await policies.register(CoordinatorSample.budgetSet())
        await policies.register(CoordinatorSample.verificationPolicy())
        await policies.register(CoordinatorSample.preprocessingContract())
        await policies.register(CoordinatorSample.calibrationPolicy())
        await policies.register(CoordinatorSample.copyCatalog())

        let bundle = CoordinatorSample.boundBundle()
        let bundles = StubModelBundleManager()
        await bundles.installAndActivate(bundle)

        let preflight = StartupPreflight(
            device: CoordinatorSample.deviceContext(),
            composition: CoordinatorSample.composition(provenance: false, fusion: false),
            capabilityManifest: CoordinatorSample.artifact(CoordinatorSample.capabilityManifestID),
            verdictCopyCatalog: CoordinatorSample.artifact(CoordinatorSample.copyCatalogID),
            embeddedBundle: Fixture.bundleID(CoordinatorSample.bundleID),
            target: .mainApplication
        )

        let outcome: GateOutcome
        do {
            outcome = .admitted(
                try await preflight.run(policies: policies, bundles: bundles, cleanup: cleanup)
            )
        } catch {
            // Reported as a value: a throw escaping into `propertyCheck` would be discarded.
            outcome = .refused(error)
        }

        return GateRun(
            outcome: outcome,
            ledger: ledger,
            store: tree.store,
            bundles: bundles,
            policy: policy,
            sessionCount: tree.sessions.count,
            objectCount: objectCount
        )
    }

    /// Accepts a new input through the admission the gate produced.
    ///
    /// The admission is used, not merely held: it is what `AnalysisSessionBinder` binds every
    /// session against, so this call is unreachable without the value step 5 gates. That is
    /// what makes the ledger's ordering a structural fact rather than an ordering this test
    /// chose to write down.
    private func admitIngest(under admission: ReleaseAdmission, run: GateRun) async {
        let sessionID = PortValue.sessionID("session-p25-ingest-\(shape.seed)")
        run.ledger.append(.ingestWrote)
        guard let receipt = try? await run.store.writeComplete(
            PortValue.bytes(count: max(shape.bytesPerObject, 1), seed: 7),
            in: .session(sessionID),
            protection: VirtualTree.protectionLevel
        ) else {
            Issue.record("the new session's material could not be written")
            return
        }

        let binder = AnalysisSessionBinder(admission: admission, bundles: run.bundles)
        let asset = PortValue.asset(route: .photosPicker, receipt: receipt)
        guard (try? await binder.bind(accepting: asset)) != nil else {
            Issue.record("the binder refused an input from a coherent admitted release")
            return
        }
        run.ledger.append(.ingestBound)

        // The new session's material is the only thing in the tree: it arrived after the
        // sweep, so it is not residue the sweep should have taken.
        let occupied = await run.store.occupiedScopes()
        #expect(
            occupied == [.session(sessionID)],
            "after ingest the tree holds \(occupied.count) scopes, expected only the new one"
        )
        witness.recordIngestAfterSweep()
    }
}

// MARK: - The witness

/// Counters and coverage sets, all maintained and asserted **outside** the property body.
///
/// `propertyCheck` runs its body under `try?`, so an error thrown from the body is discarded
/// and the run reports a pass in milliseconds with every arm skipped. `completedBodies ==
/// cases` alone does not catch that: it holds vacuously as `0 == 0` when the body throws on
/// the first case. The case floor, the counted receipts, emptiness checks, expiry checks,
/// sweeps, and refusals are what close the gap, and they live here because an issue recorded
/// outside the body is not suppressed. ``recordCompletedBody()`` is the body's last statement
/// and ``record(_:)`` its first, so a case that ended early is countable in both directions.
///
/// ``emptyPreCleanupSnapshots`` is the anti-vacuity witness for the whole file. Every cleanup
/// is preceded by a snapshot of what the tree held, and a snapshot with no objects or no
/// bytes is counted here and required to be zero: a run whose fixtures stopped writing
/// anything fails at this counter rather than passing on emptiness it never had to create.
private final class CleanupWitness: @unchecked Sendable {
    private let lock = NSLock()

    // Run shape.
    private var cases = 0
    private var completedBodies = 0
    private var unbuildableInputs = 0

    // Counted work.
    private var receipts = 0
    private var coincidentReceipts = 0
    private var repeats = 0
    private var emptinessChecks = 0
    private var expiryChecks = 0
    private var startupSweeps = 0
    private var refusedGates = 0
    private var ingestChecks = 0

    // The anti-vacuity guard.
    private var preCleanupSnapshots = 0
    private var emptyPreCleanupSnapshots = 0
    private var smallestPreCleanupObjectCount = Int.max
    private var smallestPreCleanupByteCount = Int.max

    // Produced outputs.
    private var producedReasons: Set<SessionCleanupReason> = []
    private var producedCoincidentReasons: Set<SessionCleanupReason> = []
    private var producedRemovedCounts: Set<Int> = []
    private var producedCoincidentPairs: Set<String> = []
    private var producedInterruptionPoints: Set<Int> = []

    // Generated baseline.
    private var seeds: Set<Int> = []
    private var sessionCounts: Set<Int> = []
    private var objectCounts: Set<Int> = []
    private var byteCounts: Set<Int> = []
    private var transferStateSets: Set<String> = []
    private var deadlineSets: Set<String> = []
    private var elapsedPermilles: Set<Int> = []
    private var repeatCounts: Set<Int> = []
    private var clockStarts: Set<Int> = []

    func record(_ shape: CleanupShape) {
        lock.lock()
        defer { lock.unlock() }
        cases += 1
        seeds.insert(shape.seed)
        sessionCounts.insert(shape.sessionCount)
        objectCounts.insert(shape.objectsPerSession)
        byteCounts.insert(shape.bytesPerObject)
        transferStateSets.insert(shape.residualTransferStates.map(\.rawValue).joined(separator: "+"))
        deadlineSets.insert(
            SessionCleanupReason.allCases
                .map { "\(shape.deadlineMilliseconds(for: $0))" }
                .joined(separator: "/")
        )
        elapsedPermilles.insert(shape.elapsedPermille)
        repeatCounts.insert(shape.repeatCount)
        clockStarts.insert(shape.clockStartOffsetSeconds)
    }

    func recordPreCleanupSnapshot(objectCount: Int, byteCount: Int, wasPresent: Bool) {
        lock.lock()
        defer { lock.unlock() }
        preCleanupSnapshots += 1
        if !wasPresent { emptyPreCleanupSnapshots += 1 }
        smallestPreCleanupObjectCount = min(smallestPreCleanupObjectCount, objectCount)
        smallestPreCleanupByteCount = min(smallestPreCleanupByteCount, byteCount)
    }

    func recordReceipt(_ receipt: SessionDeletionReceipt) {
        lock.lock()
        defer { lock.unlock() }
        receipts += 1
        producedReasons.insert(receipt.reason)
        producedRemovedCounts.insert(receipt.removedObjectCount)
    }

    func recordCoincidentReceipt(_ receipt: SessionDeletionReceipt) {
        lock.lock()
        defer { lock.unlock() }
        coincidentReceipts += 1
        producedCoincidentReasons.insert(receipt.reason)
    }

    func recordCoincidentPair(_ first: SessionCleanupReason, _ second: SessionCleanupReason) {
        lock.lock()
        producedCoincidentPairs.insert("\(first.rawValue)+\(second.rawValue)")
        lock.unlock()
    }

    func recordRepeat() {
        lock.lock()
        repeats += 1
        lock.unlock()
    }

    func recordEmptinessCheck() {
        lock.lock()
        emptinessChecks += 1
        lock.unlock()
    }

    func recordExpiryCheck() {
        lock.lock()
        expiryChecks += 1
        lock.unlock()
    }

    func recordStartupSweep(interruptedObjectCount: Int) {
        lock.lock()
        startupSweeps += 1
        producedRemovedCounts.insert(interruptedObjectCount)
        lock.unlock()
    }

    func recordRefusedGate() {
        lock.lock()
        refusedGates += 1
        lock.unlock()
    }

    func recordIngestAfterSweep() {
        lock.lock()
        ingestChecks += 1
        lock.unlock()
    }

    func recordInterruptionPoint(_ point: Int, torn objectCount: Int) {
        lock.lock()
        producedInterruptionPoints.insert(point)
        _ = objectCount
        lock.unlock()
    }

    /// Records that an input this file described could not be built.
    ///
    /// Never a finding about cleanup: every input is derived from generated integers inside
    /// validated ranges, so a refusal is a defect here. Counted so a run whose inputs quietly
    /// stopped being buildable fails outside the body rather than shrinking its own coverage.
    func recordUnbuildableInput() {
        lock.lock()
        unbuildableInputs += 1
        lock.unlock()
    }

    /// Called last in the body, so a case that ended early is countable.
    func recordCompletedBody() {
        lock.lock()
        completedBodies += 1
        lock.unlock()
    }

    func expectVariedBaselinesAndFullCoverage() {
        lock.lock()
        defer { lock.unlock() }

        // The run happened. The floor is what keeps the equality below from holding
        // vacuously when the body throws on the first case.
        #expect(cases >= 100, "the design requires at least 100 generated cases; ran \(cases)")
        #expect(
            completedBodies == cases,
            "\(cases - completedBodies) of \(cases) cases did not reach the end of the body"
        )
        #expect(
            unbuildableInputs == 0,
            "\(unbuildableInputs) described inputs could not be built at all"
        )

        // The anti-vacuity guard. Every cleanup was preceded by material that had to be
        // removed for the emptiness assertions to mean anything.
        #expect(
            preCleanupSnapshots >= cases,
            "pre-cleanup snapshots taken: \(preCleanupSnapshots) over \(cases) cases"
        )
        #expect(
            emptyPreCleanupSnapshots == 0,
            "\(emptyPreCleanupSnapshots) cleanups ran against a tree that held nothing, so their emptiness afterwards was an absence rather than a removal"
        )
        #expect(
            smallestPreCleanupObjectCount >= 1,
            "the smallest pre-cleanup object count was \(smallestPreCleanupObjectCount)"
        )
        #expect(
            smallestPreCleanupByteCount >= 1,
            "the smallest pre-cleanup byte count was \(smallestPreCleanupByteCount)"
        )

        // Counted work. Each case cleans five trees, repeats each at least once, sweeps two
        // interrupted trees, and runs the coincident arm over five more, so the floors sit
        // far below what a case performs and far enough above zero that a run which built
        // only fixtures fails here.
        #expect(receipts >= 500, "deletion receipts audited: \(receipts)")
        #expect(coincidentReceipts >= 500, "coincident-policy receipts audited: \(coincidentReceipts)")
        #expect(repeats >= 500, "repeated cleanups performed: \(repeats)")
        #expect(emptinessChecks >= 1_000, "ownership-set checks performed: \(emptinessChecks)")
        #expect(expiryChecks >= 500, "deadline-expiry checks performed: \(expiryChecks)")
        #expect(startupSweeps >= 100, "gated startup sweeps observed: \(startupSweeps)")
        #expect(refusedGates >= 100, "refused startup gates observed: \(refusedGates)")
        #expect(ingestChecks >= 100, "post-sweep ingests observed: \(ingestChecks)")

        // The substantive half: every reason was produced in a receipt rather than offered.
        let missing = Set(SessionCleanupReason.allCases).subtracting(producedReasons)
        #expect(
            missing.isEmpty,
            "cleanup reasons never produced in a receipt: \(missing.map(\.rawValue).sorted())"
        )
        #expect(
            producedCoincidentReasons == Set(SessionCleanupReason.allCases),
            "reasons never produced under a coincident policy: \(producedCoincidentReasons.map(\.rawValue).sorted())"
        )
        #expect(
            producedRemovedCounts.contains(0),
            "no repeated cleanup ever reported zero removals, so idempotence was not observed"
        )
        #expect(
            producedRemovedCounts.contains(where: { $0 > 0 }),
            "no cleanup ever reported a removal, so completeness was not observed"
        )
        #expect(
            producedCoincidentPairs.count >= 5,
            "coincident reason pairs exercised: \(producedCoincidentPairs.count)"
        )
        #expect(
            producedInterruptionPoints.count >= 4,
            "interruption points exercised: \(producedInterruptionPoints.sorted())"
        )

        // The generated baseline actually varied. The thresholds sit far below what 200
        // uniform draws produce, so they witness variation rather than pinning a
        // distribution.
        #expect(seeds.count >= 50, "generated seeds: \(seeds.count)")
        #expect(sessionCounts == [1, 2, 3, 4], "generated session counts: \(sessionCounts.sorted())")
        #expect(objectCounts == [1, 2, 3], "generated object counts: \(objectCounts.sorted())")
        #expect(byteCounts.count >= 30, "generated byte sizes: \(byteCounts.count)")
        #expect(
            transferStateSets.count >= 5,
            "generated transfer residue sets: \(transferStateSets.count)"
        )
        #expect(deadlineSets.count >= 50, "generated deadline tuples: \(deadlineSets.count)")
        #expect(elapsedPermilles.count >= 50, "generated elapsed fractions: \(elapsedPermilles.count)")
        #expect(repeatCounts == [2, 3, 4], "generated repeat counts: \(repeatCounts.sorted())")
        #expect(clockStarts.count >= 50, "generated clock offsets: \(clockStarts.count)")
    }
}
