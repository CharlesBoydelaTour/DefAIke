import DefAIkeDomain
import DefAIkeTestSupport
import Foundation
import PropertyBased
import Testing

@testable import DefAIkeApplication

// Design Property 30: terminal outcomes are disjoint and errors are singular.
//
// The design states it as: for any Analysis Session event sequence, the terminal value is
// exactly one of completed Evidence Report, cancelled, or failed with exactly one Analysis
// Error; no Analysis Error can decode as a pixel label, provenance state, unavailable
// state, Combined Summary, or cancellation; and every failed value contains no evidence
// lane or summary.
//
// The quantifier is the whole difficulty. "Exactly one terminal" is trivially true of a
// session where only one thing ever happens, so this file generates *event schedules* —
// orderings and interleavings of the events that can reach one live session — and requires
// the claim over each of them. The generated events are the ones production can actually
// deliver:
//
//   * one or several faults returned by an evidence branch, at generated stages, from
//     either lane;
//   * a runtime resource breach observed on either lane;
//   * a branch reporting the user's cancellation;
//   * the join arbitrating everything gathered so far and offering one terminal;
//   * the visible cancel control's cancellation request; and
//   * a framework result arriving for the running attempt, or for a released earlier one.
//
// ## Nothing is raced
//
// A property about event *order* is the easiest kind to write as a race and the least
// useful. Nothing here sleeps, polls, or hopes. The subject session is suspended inside
// inference at a `BranchGate` rendezvous, so `analyze` is itself suspended and every event
// below is delivered as a synchronous actor step in the order this file chose. The schedule
// is the test's, not the scheduler's. The gate is opened only after the last event, and the
// pipeline then resumes into a session whose terminal has already been decided.
//
// ## What each half of the claim is measured against
//
//   * **Exactly one terminal, ever.** Every offer's `TerminalCommit` is recorded. Exactly
//     one may report `committed`; every later offer must report `refusedAlreadyTerminal`
//     with the *same* standing outcome, and the outcome standing at the last event must be
//     the outcome the ended session reports. Schedules where two or more events would each
//     commit are generated deliberately, and the witness requires them: a run of schedules
//     with one offer each would satisfy singularity for free.
//   * **Pairwise disjoint.** All three directions are asserted, and not by enum inequality:
//     each standing outcome must satisfy exactly one of the three predicates, and the
//     completed, cancelled, and failed values in play are each required to fail the other
//     two predicates and to carry the other two's payloads as `nil`.
//   * **Exactly one error, and the right one.** When several faults are gathered, the
//     committed category must be the one ``CausalOrderReference`` predicts — a reference
//     model written in this file from the design's causal-order sentence and Requirement
//     11.17, not read out of ``CausalFaultArbitration``. Seven of its ten ranks are then
//     cross-checked against the order a *running* pipeline visits its stages in, which is
//     an oracle neither list can fake. Production's arbitration is also required to agree
//     with the reference model on the arrival order *and* on the reversed order, so a
//     category that depended on which branch returned first would fail.
//   * **No evidence in a failure.** Not "the result is absent": the shared call log must
//     show zero `calibrate`, zero `provenanceAnalyze`, and zero `fuse` calls, so no Pixel
//     Evidence was calibrated, no provenance result was produced, and no Combined Summary
//     was resolved.
//
// ## Every absence is measured beside a presence
//
// On **every** case, after the gate opens, the *same* coordinator, harness, ports, release,
// and call log run one more session that completes with a real Evidence Report, an
// available provenance lane, and a Combined Summary. So the measured zeros above sit beside
// measured ones taken through identical wiring rather than beside a path that produces
// nothing. The release binds provenance and fusion for exactly this reason: in a pixel-only
// composition "no provenance result and no Combined Summary" would hold trivially.
//
// Delivery is also measured. Every scheduled event is entered in a ledger together with the
// coordinator's own response to it and the outcome standing afterwards, and the ledger is
// compared position by position against the schedule and against the reference model's
// predicted standing at each position. A schedule that silently degenerated into one
// delivered event fails the ledger instead of satisfying disjointness for free.
//
// ## Why no arm throws
//
// `propertyCheck` runs its body under `try?`, so an error escaping the body reports a
// passing run in milliseconds with every arm skipped. Nothing below rethrows: the release
// build, the ingest, and every fallible construction are turned into an `Issue.record` and
// a counted unbuildable input, and the assertions run over a recorded value. The witness
// counts the cases, the delivered events, the offers, the accepted and refused commits, the
// multi-fault joins, and the control reports *outside* the body, where an issue is not
// suppressed, and requires all three terminal kinds, every event kind, every fault stage,
// all three admission answers, and both sources of a final terminal to have been observed.
// `completedBodies == cases` is paired with a case floor, because it passes vacuously as
// `0 == 0` when the body throws on the first case.
//
// ## What this file does not assert, and what it does not decide
//
//   * **No value here is an approved release input.** The release is `CoordinatorRelease`,
//     whose every artifact is synthetic; the error categories and stages are the
//     requirements' own closed vocabulary rather than a chosen policy; and the offered
//     Evidence Report, the session identifiers, and the byte seeds are synthetic. No
//     budget, deadline, boundary, tolerance, or approved value is fabricated, and no
//     fixture artifact is invented.
//   * **Property 35 owns "cancellation prevents all evidence commits."** Cancellation
//     appears here only as one of the three disjoint terminals and as one event a schedule
//     may contain. Nothing below claims anything about cancellation points, hooks, or
//     preemption.
//   * **Property 11 owns failure and retry isolation**, including which categories a
//     validation or preprocessing failure may present and what a following session
//     inherits. Nothing here runs a second attempt for comparison.
//   * **Property 29 owns the resource-limit rule.** A resource breach is generated here as
//     an event that contributes a fault, never as a claim about when a limit is breached.
//   * **Property 25 owns cleanup**, and **task 10.13** owns the cancellation-point
//     integration matrix.
//   * The vocabulary-disjointness arm is a claim about the closed domain vocabularies, not
//     about what a user is shown; **task 11.3** owns presentation.
//   * `SessionCancellationCommitTests` already pins a later non-cancelled commit and a
//     request after a mid-flight terminal at one example each,
//     `AnalysisCoordinatorTerminalTests` pins the single terminal at examples, and
//     `CausalFaultArbitrationTests` pins arbitration at examples. This file quantifies the
//     same statements over generated schedules, over multi-fault gathers, and against an
//     independently written reference model.

extension Tag {
    /// Design Property 30.
    ///
    /// Declared here rather than in a shared namespace: each design property owns one file,
    /// and a shared tag namespace would be a merge point between independently written
    /// property files.
    @Tag static var property30DisjointSingularTerminals: Self
}

@Suite(
    "Property 30: Terminal outcomes are disjoint and errors are singular",
    .tags(.property30DisjointSingularTerminals)
)
struct DisjointSingularTerminalOutcomePropertyTests {

    /// The number of generated cases requested.
    ///
    /// Above the library default of 100 because the coverage the witness requires is a
    /// product over six event kinds, ten stages, ten categories, and three terminal kinds,
    /// and because the interesting schedules — two or more committing offers, and a join
    /// with two or more gathered faults — are a fraction of uniform draws. Raising the
    /// count is the only honest way to reach that coverage; no assertion is relaxed to fit
    /// a smaller run.
    ///
    /// Five hundred rather than four: a measured run at 400 put the two thinnest cells —
    /// cases where two or more events would each commit, and refused offers — at roughly
    /// 130 and 165 against floors of 100. Raising the count moves those floors many standard
    /// deviations clear rather than lowering them to fit.
    static let generatedCaseCount = 500

    /// **Validates: Requirements 11.17, 11.18**
    @Test("One terminal, three disjoint kinds, one arbitrated error, and no evidence")
    func terminalOutcomesAreDisjointAndErrorsAreSingular() async {
        let witness = TerminalScheduleWitness()

        await propertyCheck(
            count: Self.generatedCaseCount,
            input: TerminalScheduleShape.generator
        ) { shape in
            witness.record(shape)
            guard let run = await TerminalScheduleRun.execute(shape: shape, witness: witness)
            else { return }

            run.checkTheReferenceOrderIsTotal()
            run.checkEveryScheduledEventWasDelivered()
            run.checkExactlyOneTerminalWasEverCommitted()
            run.checkTheThreeTerminalsArePairwiseDisjoint()
            run.checkCancellationCarriesNoErrorCategory()
            run.checkAFailedTerminalCarriesExactlyOneArbitratedError()
            run.checkArbitrationIsIndependentOfArrivalOrder()
            run.checkNoEvidenceReachedANonCompletedTerminal()
            run.checkThePositiveControlProducedEvidence()
            run.checkTheRunningPipelineAgreesWithTheReferenceOrder()
            run.checkNoErrorCategoryDecodesAsEvidence()

            witness.recordCompletedBody()
        }

        witness.expectMeasuredRun(requestedCases: Self.generatedCaseCount)
    }
}

// MARK: - The reference model for causal arbitration

/// The causal stage order, and the single fault a session reports when several arrive.
///
/// **Written from the specification, not from ``CausalFaultArbitration``.** The design's
/// "Deterministic arbitration" section spells the order as one sentence, reproduced in
/// ``designProse`` and transcribed one arrow at a time into ``enumeratedByTheDesign``. A
/// test that read the expected value out of the implementation would assert nothing, so
/// nothing in this type reads ``CausalFaultArbitration/causalStageOrder``,
/// ``CausalFaultArbitration/causalRank(of:)``, or the production ranking at all — and no
/// arm compares the two lists to each other. The arms compare *outcomes*.
///
/// Two stages are outside the design's sentence, and their ranks are derived rather than
/// chosen:
///
///   * ``AnalysisStage/provenanceValidation`` is not in the sentence. The sentence
///     enumerates the session's ordered prerequisite chain, and provenance validation runs
///     beside that chain rather than inside it — Requirement 6.9 has the validator return
///     one of five states rather than an error, so the only fault reachable at that stage
///     is a runtime resource breach on a lane that is resolving alongside the pixel chain.
///     A stage outside a complete enumeration cannot be earlier than one inside it without
///     contradicting the enumeration, so it ranks after every enumerated stage.
///   * ``AnalysisStage/evidenceJoining`` is last because nothing can be joined before both
///     lanes have resolved, so every other stage precedes it by construction.
///
/// Seven of the ten ranks are additionally cross-checked against the order a *running*
/// pipeline visits its stages in — see
/// ``TerminalScheduleRun/checkTheRunningPipelineAgreesWithTheReferenceOrder()`` — which is
/// an oracle derived from neither list.
private enum CausalOrderReference {

    /// The design's own sentence, quoted so a reader can check the transcription below.
    static let designProse = """
        handoff -> media/static classification -> decode/resource validation -> \
        preprocessing/resource validation -> model load -> inference -> output validation \
        -> calibration input
        """

    /// One entry per arrow in ``designProse``, in the sentence's order.
    static let enumeratedByTheDesign: [AnalysisStage] = [
        .handoffVerification,   // "handoff"
        .mediaClassification,   // "media/static classification"
        .inputValidation,       // "decode/resource validation"
        .preprocessing,         // "preprocessing/resource validation"
        .modelLoad,             // "model load"
        .inference,             // "inference"
        .outputValidation,      // "output validation"
        .calibration,           // "calibration input"
    ]

    /// The two stages the sentence does not name, ranked by the derivation above.
    static let derivedFromTheRequirements: [AnalysisStage] = [
        .provenanceValidation,
        .evidenceJoining,
    ]

    static let order: [AnalysisStage] = enumeratedByTheDesign + derivedFromTheRequirements

    /// Position of `stage`, or `nil` when this model does not rank it.
    ///
    /// Optional rather than total on purpose: an unranked stage must fail
    /// ``TerminalScheduleRun/checkTheReferenceOrderIsTotal()`` loudly instead of being
    /// given a rank by a `default` arm.
    static func rank(of stage: AnalysisStage) -> Int? { order.firstIndex(of: stage) }

    /// The single fault a session reports, given every fault gathered for one join.
    ///
    /// Two rules, in this order, and both come from the requirements rather than from the
    /// implementation:
    ///
    /// 1. **Cancellation dominates.** Requirement 11.17 keeps the cancelled terminal
    ///    distinct from every Analysis Error category, so a session that observed the
    ///    user's cancellation cannot report a failure alongside it.
    /// 2. **Otherwise the causally earliest stage wins**, by ``rank(of:)``, keeping the
    ///    first of equal-ranked faults so the answer is a function of the list alone.
    ///
    /// `nil` for an empty list, which is not a failure: a session whose branches all
    /// resolved has nothing to arbitrate.
    static func reportedFault(among gathered: [AnalysisFault]) -> AnalysisFault? {
        guard !gathered.isEmpty else { return nil }
        if let cancelled = gathered.first(where: { $0.isCancelled }) { return cancelled }
        var winner: AnalysisFault?
        var winnerRank = Int.max
        for fault in gathered {
            guard let stage = fault.stage, let candidateRank = rank(of: stage) else { continue }
            if candidateRank < winnerRank {
                winner = fault
                winnerRank = candidateRank
            }
        }
        return winner
    }

    /// The terminal outcome one fault produces, written from Requirements 11.17 and 11.18.
    ///
    /// Cancellation and failure are different terminals, so the two fault cases map to
    /// different outcomes rather than to one category. A failure carries exactly one
    /// category and one stage and has no evidence field to carry anything else.
    static func terminal(
        for fault: AnalysisFault,
        sessionID: AnalysisSessionID,
        bytePreservationStatus: BytePreservationStatus
    ) -> SessionTerminalOutcome? {
        switch fault {
        case .cancelled:
            return .cancelled
        case let .analysis(error, stage):
            guard let snapshot = AnalysisFailureSnapshot(
                sessionID: sessionID,
                error: error,
                stage: stage,
                bytePreservationStatus: bytePreservationStatus,
                inputQuality: nil
            ) else {
                return nil
            }
            return .failed(snapshot)
        }
    }
}

// MARK: - The generated event vocabulary

/// Which lane an event arrived from.
///
/// Recorded rather than acted on: Requirement 11.18 is about the reported category, and the
/// point of generating both lanes is that the lane a fault came from must not change the
/// answer.
private enum FaultLane: String, Sendable, CaseIterable {
    case pixel
    case provenance
}

/// One kind of event a schedule can contain.
private enum ScheduledEventKind: String, Sendable, CaseIterable {
    case branchFault
    case resourceBreach
    case branchCancellation
    case joinGatheredFaults
    case cancellationRequest
    case lateFrameworkResult
}

/// One event delivered to a live session.
///
/// Every case is something production can deliver. A branch never commits a terminal — it
/// returns an outcome and the join commits once — so the three fault-bearing cases
/// accumulate into the gather and only ``joinGatheredFaults`` offers a terminal for them.
private enum ScheduledEvent: Hashable, Sendable, CustomStringConvertible {
    /// A branch returned one Analysis Error, detected at `stage`.
    case branchFault(lane: FaultLane, error: AnalysisError, stage: AnalysisStage)

    /// Runtime resource control observed a hard-limit breach on `lane` at `stage`.
    case resourceBreach(lane: FaultLane, stage: AnalysisStage)

    /// A branch reported the user's cancellation. Carries no category and no stage.
    case branchCancellation(lane: FaultLane)

    /// The join arbitrates every fault gathered since the last join and offers one
    /// terminal: a failure when anything was gathered, a completed report when nothing was.
    case joinGatheredFaults

    /// The user activated the visible cancel control.
    case cancellationRequest

    /// A framework result arrived. `stale` names a released earlier attempt instead of the
    /// running one, which is the case an identifier-only check cannot see.
    case lateFrameworkResult(stale: Bool)

    var kind: ScheduledEventKind {
        switch self {
        case .branchFault: .branchFault
        case .resourceBreach: .resourceBreach
        case .branchCancellation: .branchCancellation
        case .joinGatheredFaults: .joinGatheredFaults
        case .cancellationRequest: .cancellationRequest
        case .lateFrameworkResult: .lateFrameworkResult
        }
    }

    /// The fault this event contributes to the gather, or `nil` when it contributes none.
    var contributedFault: AnalysisFault? {
        switch self {
        case let .branchFault(_, error, stage): .analysis(error, stage: stage)
        case let .resourceBreach(_, stage): .analysis(.resourceLimit, stage: stage)
        case .branchCancellation: .cancelled
        case .joinGatheredFaults, .cancellationRequest, .lateFrameworkResult: nil
        }
    }

    /// Whether this event offers a terminal to the write-once slot.
    var offersATerminal: Bool {
        switch self {
        case .joinGatheredFaults, .cancellationRequest: true
        case .branchFault, .resourceBreach, .branchCancellation, .lateFrameworkResult: false
        }
    }

    var description: String {
        switch self {
        case let .branchFault(lane, error, stage):
            "fault(\(lane.rawValue),\(error.rawValue)@\(stage.rawValue))"
        case let .resourceBreach(lane, stage):
            "breach(\(lane.rawValue)@\(stage.rawValue))"
        case let .branchCancellation(lane):
            "branchCancelled(\(lane.rawValue))"
        case .joinGatheredFaults:
            "join"
        case .cancellationRequest:
            "cancelRequest"
        case let .lateFrameworkResult(stale):
            "lateResult(stale:\(stale))"
        }
    }
}

// MARK: - Generated shape

/// Everything one generated case decides, as plain data.
///
/// The generator produces integers only. The release, the harness, the ingest, and the
/// offered report are built from them inside the run, where a construction that
/// unexpectedly fails is recorded as an issue rather than thrown: `propertyCheck` discards
/// an error thrown by its body, so a refusal that escaped as a throw would report a passing
/// test with every arm skipped.
///
/// ## How the baseline varies
///
///   * the **length** of the schedule, over two to seven events, so orderings of different
///     sizes are exercised rather than one fixed template;
///   * each event's **kind**, over all six, so faults, breaches, branch cancellations,
///     joins, cancel requests, and late results interleave freely;
///   * each fault's **stage**, over all ten, and each fault's **category**, over all ten,
///     drawn independently so a category is never implied by its stage;
///   * each fault's **lane**, so a gather can hold faults from both branches;
///   * whether a late result names the running attempt or a **released earlier** one; and
///   * the pixel label and provenance lane of the **offered** Evidence Report, so the
///     completed terminal in play is not one fixed value.
///
/// One selector decides one event. Its range is 3200 = 8 x 10 x 10 x 2 x 2, a multiple of
/// every modulus it is reduced by, and each field reads a different digit of the selector,
/// so the five choices are uniform and independent of one another.
private struct TerminalScheduleShape: Sendable, CustomStringConvertible {

    /// Selector range for one event. See the note above on why this exact size.
    static let eventSelectorBound = 3_199

    /// Selector range for the offered report: 900 = 3 x 3 x 100.
    static let reportSelectorBound = 899

    /// Drives the synthetic byte seed, so a case's ingest varies.
    let seed: Int

    /// One selector per event, in delivery order.
    let eventSelectors: [Int]

    /// Selects the offered Evidence Report's pixel label and provenance lane.
    let reportSelector: Int

    // MARK: Derived

    var schedule: [ScheduledEvent] { eventSelectors.map(Self.event(from:)) }

    var offeredPixelIndex: Int { reportSelector % PixelEvidence.allCases.count }

    /// 0 selects an available lane; 1 and 2 select the two unavailable reasons.
    var offeredLaneIndex: Int { (reportSelector / 3) % 3 }

    /// A byte seed that is never zero, so the ingest's bytes differ from an empty pattern.
    var byteSeed: UInt8 { UInt8(truncatingIfNeeded: seed % 251) | 1 }

    /// How many events offer a terminal to the slot.
    var committingEventCount: Int { schedule.filter(\.offersATerminal).count }

    static func event(from selector: Int) -> ScheduledEvent {
        let stage = AnalysisStage.allCases[(selector / 8) % AnalysisStage.allCases.count]
        let error = AnalysisError.allCases[(selector / 80) % AnalysisError.allCases.count]
        let lane = FaultLane.allCases[(selector / 800) % FaultLane.allCases.count]
        let stale = (selector / 1_600) % 2 == 1
        // Two slots for a plain branch fault and two for the join, so a gather holding more
        // than one fault is common rather than rare. Every kind keeps a nonzero share.
        switch selector % 8 {
        case 0, 1: return .branchFault(lane: lane, error: error, stage: stage)
        case 2: return .resourceBreach(lane: lane, stage: stage)
        case 3: return .branchCancellation(lane: lane)
        case 4, 5: return .joinGatheredFaults
        case 6: return .cancellationRequest
        default: return .lateFrameworkResult(stale: stale)
        }
    }

    var description: String {
        "seed \(seed), schedule [\(schedule.map(\.description).joined(separator: " "))], report \(offeredPixelIndex)/\(offeredLaneIndex)"
    }

    static var generator: Generator<TerminalScheduleShape, AnySequence<Any>> {
        zip(
            Gen.int(in: 0...9_999),
            Gen.int(in: 0...eventSelectorBound).array(of: 2...7),
            Gen.int(in: 0...reportSelectorBound)
        )
        .map { seed, selectors, report in
            TerminalScheduleShape(
                seed: seed,
                eventSelectors: selectors,
                reportSelector: report
            )
        }
        .eraseToAny()
    }
}

// MARK: - What the coordinator answered

/// The coordinator's own response to one delivered event.
///
/// A response per event is what makes the ledger more than a restatement of the schedule: a
/// step that never reached the actor has no response to record.
private enum EventResponse: Sendable {
    /// The fault was gathered for the next join. No offer was made.
    case gathered(AnalysisFault)

    /// The join offered `offered` and the slot answered `commit`.
    case commit(TerminalCommit, offered: SessionTerminalOutcome)

    /// The cancel control's request and everything it did.
    case cancellation(CancellationRequestResult)

    /// A framework result's admission, and the value that landed (`nil` when discarded).
    case admission(
        FrameworkResultAdmission,
        landed: PixelEvidence?,
        target: AnalysisSessionIdentity
    )

    /// The offer's answer, or `nil` for an event that offered nothing.
    var terminalCommit: TerminalCommit? {
        switch self {
        case let .commit(commit, _): commit
        case let .cancellation(result): result.commit
        case .gathered, .admission: nil
        }
    }

    /// Whether this event set the session's terminal.
    var didCommit: Bool { terminalCommit?.didCommit ?? false }
}

/// One delivered event, its response, and what stood afterwards.
private struct DeliveredEvent: Sendable {
    let index: Int
    let event: ScheduledEvent

    /// The coordinator's answer, read back from the actor.
    let response: EventResponse

    /// ``AnalysisCoordinator/committedTerminal()`` read immediately after delivery.
    let standingAfter: SessionTerminalOutcome?

    /// How many faults were gathered and not yet joined afterwards.
    let gatheredCountAfter: Int
}

/// One join's arbitration answers, taken in both directions.
private struct ArbitrationObservation: Sendable {
    let index: Int
    let gathered: [AnalysisFault]

    /// ``CausalFaultArbitration/earliest(of:)`` over the arrival order.
    let productionInArrivalOrder: AnalysisFault?

    /// The same call over the reversed list.
    let productionInReverseOrder: AnalysisFault?

    /// ``CausalOrderReference/reportedFault(among:)`` over the arrival order.
    let reference: AnalysisFault?

    /// The same reference model over the reversed list.
    let referenceInReverseOrder: AnalysisFault?

    /// Whether reordering this gather must not change the selected fault.
    ///
    /// True when a cancellation is present — it dominates from either end — or when exactly
    /// one fault occupies the causally earliest stage. The design guarantees that shape in
    /// production: an adapter returns one normalized error per stage, so two faults cannot
    /// share a stage. This file generates the excluded shape anyway, and the arm asserts the
    /// weaker statement that still holds for it: both orders select a fault at the *same*
    /// causally earliest stage, so the reported location is order-independent even where the
    /// tie-break keeps whichever fault was offered first.
    var reorderingMustNotChangeTheAnswer: Bool {
        if gathered.contains(where: { $0.isCancelled }) { return true }
        let ranks = gathered.compactMap { $0.stage.flatMap(CausalOrderReference.rank(of:)) }
        guard let earliest = ranks.min() else { return true }
        return ranks.filter { $0 == earliest }.count == 1
    }

    /// The causally earliest rank in the gather, ignoring cancellation.
    var earliestRank: Int? {
        gathered.compactMap { $0.stage.flatMap(CausalOrderReference.rank(of:)) }.min()
    }
}

// MARK: - The reference model over one schedule

/// What the schedule predicts, computed from the events alone.
///
/// Built before any assertion runs and never from an observation, so a disagreement between
/// the coordinator and this model fails an arm rather than being absorbed into it.
private struct ScheduleExpectation: Sendable {
    /// The outcome standing after each event, positionally.
    let standingAfter: [SessionTerminalOutcome?]

    /// The gather size after each event, positionally.
    let gatheredCountAfter: [Int]

    /// The faults gathered at each join, keyed by the join's position.
    let gatheredAtJoin: [Int: [AnalysisFault]]

    /// The expected admission answer at each late-result position.
    let admissionAt: [Int: FrameworkResultAdmission]

    /// Positions that offer a terminal.
    let committingIndices: [Int]

    /// The position whose offer takes the slot, or `nil` when no event offers anything.
    let firstCommitIndex: Int?

    /// The outcome the session must end with, or `nil` when the *pipeline* commits its own
    /// completed terminal because no event took the slot.
    let finalStanding: SessionTerminalOutcome?

    static func model(
        schedule: [ScheduledEvent],
        identity: AnalysisSessionIdentity,
        staleIdentity: AnalysisSessionIdentity,
        bytePreservationStatus: BytePreservationStatus,
        offeredReport: EvidenceReport
    ) -> ScheduleExpectation? {
        var gathered: [AnalysisFault] = []
        var standing: SessionTerminalOutcome?
        var standingAfter: [SessionTerminalOutcome?] = []
        var gatheredCountAfter: [Int] = []
        var gatheredAtJoin: [Int: [AnalysisFault]] = [:]
        var admissionAt: [Int: FrameworkResultAdmission] = [:]
        var committingIndices: [Int] = []
        var firstCommitIndex: Int?

        for (index, event) in schedule.enumerated() {
            if let fault = event.contributedFault {
                gathered.append(fault)
            }
            switch event {
            case .joinGatheredFaults:
                committingIndices.append(index)
                gatheredAtJoin[index] = gathered
                let offered: SessionTerminalOutcome
                if let fault = CausalOrderReference.reportedFault(among: gathered) {
                    guard let terminal = CausalOrderReference.terminal(
                        for: fault,
                        sessionID: identity.sessionID,
                        bytePreservationStatus: bytePreservationStatus
                    ) else {
                        return nil
                    }
                    offered = terminal
                } else {
                    // The ordinary join: both lanes resolved and the report is offered.
                    offered = .completed(offeredReport)
                }
                if standing == nil {
                    standing = offered
                    firstCommitIndex = index
                }
                gathered.removeAll()
            case .cancellationRequest:
                committingIndices.append(index)
                if standing == nil {
                    standing = .cancelled
                    firstCommitIndex = index
                }
            case let .lateFrameworkResult(stale):
                if stale {
                    admissionAt[index] = .discardedStaleIdentity(offered: staleIdentity)
                } else if let standing {
                    admissionAt[index] = .discardedTerminalCommitted(standing)
                } else {
                    admissionAt[index] = .admitted
                }
            case .branchFault, .resourceBreach, .branchCancellation:
                break
            }
            standingAfter.append(standing)
            gatheredCountAfter.append(gathered.count)
        }

        return ScheduleExpectation(
            standingAfter: standingAfter,
            gatheredCountAfter: gatheredCountAfter,
            gatheredAtJoin: gatheredAtJoin,
            admissionAt: admissionAt,
            committingIndices: committingIndices,
            firstCommitIndex: firstCommitIndex,
            finalStanding: standing
        )
    }
}

// MARK: - One executed case

/// One generated schedule, delivered to a live session, plus its positive control.
///
/// Every field is a recording. The assertions below read only recordings, so no arm can
/// depend on the order the actor happened to run in.
private struct TerminalScheduleRun {
    let shape: TerminalScheduleShape
    let schedule: [ScheduledEvent]
    let offeredReport: EvidenceReport
    let identity: AnalysisSessionIdentity
    let staleIdentity: AnalysisSessionIdentity
    let expectation: ScheduleExpectation
    let ledger: [DeliveredEvent]
    let observations: [ArbitrationObservation]

    /// The outcome standing at the moment before the gate opened.
    let standingBeforeGate: SessionTerminalOutcome?

    /// The subject session, after the pipeline resumed and ended.
    let subject: CompletedAnalysisSession

    /// The subject session's own call log.
    let subjectCallKinds: [PortCallKind]

    /// The positive control: one clean session through the identical wiring.
    let control: CompletedAnalysisSession

    /// The control's own call log, taken after the subject's log was cleared.
    let controlCallKinds: [PortCallKind]

    /// The three port calls whose absence is what "no evidence" means here.
    ///
    /// `calibrate` is the only way Pixel Evidence exists, `provenanceAnalyze` the only way a
    /// provenance result exists, and `fuse` the only way a Combined Summary exists.
    static let evidenceProducingKinds: [PortCallKind] = [
        .calibrate, .provenanceAnalyze, .fuse,
    ]

    // MARK: Execution

    static func execute(
        shape: TerminalScheduleShape,
        witness: TerminalScheduleWitness
    ) async -> TerminalScheduleRun? {
        let release: CoordinatorRelease
        do {
            // Provenance and fusion are bound so the control provably produces a provenance
            // result and a Combined Summary. Without them, "the failed session has neither"
            // would hold in a composition that never produces either.
            release = try await CoordinatorRelease.build(provenance: true, fusion: true)
        } catch {
            Issue.record("the synthetic release must pass its own startup gate: \(error)")
            witness.recordUnbuildableInput()
            return nil
        }

        guard let offeredReport = Self.offeredReport(shape: shape) else {
            Issue.record("the offered Evidence Report must be representable [\(shape)]")
            witness.recordUnbuildableInput()
            return nil
        }

        let gate = BranchGate()
        let harness = CoordinatorHarness.make(release: release, gate: gate)
        let asset: ImportedEncodedAsset
        do {
            asset = try await release.acceptedIngest(byteSeed: shape.byteSeed)
        } catch {
            Issue.record("the accepted ingest must be writable: \(error) [\(shape)]")
            witness.recordUnbuildableInput()
            return nil
        }

        let schedule = shape.schedule
        async let running = harness.coordinator.analyze(asset)
        // The pixel branch suspends inside inference, so `analyze` is suspended too and every
        // event below lands while the session is genuinely in flight. The ordering is this
        // file's, established by a rendezvous rather than raced for.
        await gate.waitUntilReached()

        guard let identity = await harness.coordinator.activeIdentity() else {
            Issue.record("the gated session must be the running attempt [\(shape)]")
            witness.recordUnbuildableInput()
            await gate.openGate()
            _ = await running
            return nil
        }
        let staleIdentity = AnalysisSessionIdentity(
            sessionID: identity.sessionID,
            generation: identity.generation &+ 7
        )

        guard let expectation = ScheduleExpectation.model(
            schedule: schedule,
            identity: identity,
            staleIdentity: staleIdentity,
            bytePreservationStatus: asset.preservationStatus,
            offeredReport: offeredReport
        ) else {
            Issue.record("every modelled failure snapshot must be representable [\(shape)]")
            witness.recordUnbuildableInput()
            await gate.openGate()
            _ = await running
            return nil
        }

        var gathered: [AnalysisFault] = []
        var ledger: [DeliveredEvent] = []
        var observations: [ArbitrationObservation] = []
        var deliveryFailed = false

        for (index, event) in schedule.enumerated() {
            let response: EventResponse
            switch event {
            case .branchFault, .resourceBreach, .branchCancellation:
                guard let fault = event.contributedFault else {
                    Issue.record("\(event) must contribute a fault [\(shape)]")
                    deliveryFailed = true
                    response = .gathered(.cancelled)
                    break
                }
                gathered.append(fault)
                response = .gathered(fault)

            case .joinGatheredFaults:
                // The offered terminal is built from *production's* arbitration, and the
                // reference model predicts it separately. A disagreement therefore shows up
                // twice: once here, and once as a standing outcome the model did not expect.
                let arrivalOrder = CausalFaultArbitration.earliest(of: gathered)
                let reverseOrder = CausalFaultArbitration.earliest(of: gathered.reversed())
                let observation = ArbitrationObservation(
                    index: index,
                    gathered: gathered,
                    productionInArrivalOrder: arrivalOrder,
                    productionInReverseOrder: reverseOrder,
                    reference: CausalOrderReference.reportedFault(among: gathered),
                    referenceInReverseOrder: CausalOrderReference.reportedFault(
                        among: gathered.reversed()
                    )
                )
                observations.append(observation)
                witness.recordJoin(observation)
                let offered: SessionTerminalOutcome
                if let fault = arrivalOrder {
                    guard let terminal = CausalOrderReference.terminal(
                        for: fault,
                        sessionID: identity.sessionID,
                        bytePreservationStatus: asset.preservationStatus
                    ) else {
                        Issue.record("the arbitrated terminal must be representable [\(shape)]")
                        deliveryFailed = true
                        response = .gathered(fault)
                        break
                    }
                    offered = terminal
                } else {
                    offered = .completed(offeredReport)
                }
                let commit = await harness.coordinator.commitTerminal(offered, for: identity)
                gathered.removeAll()
                response = .commit(commit, offered: offered)

            case .cancellationRequest:
                response = .cancellation(
                    await harness.coordinator.requestCancellation(for: identity)
                )

            case let .lateFrameworkResult(stale):
                let target = stale ? staleIdentity : identity
                // A calibrated label produced by work already in flight. Requirement 11.18
                // says a failed session carries no Pixel Evidence, so this is the value that
                // must have nowhere to land.
                let admitted = await harness.coordinator.admit(
                    PixelEvidence.signalsConsistentWithAIGeneration,
                    for: target
                )
                let admission = await harness.coordinator.admitFrameworkResult(for: target)
                response = .admission(admission, landed: admitted.value, target: target)
            }

            // Read back from the actor after every event, so a step that never reached it
            // cannot be entered in the ledger as though it had.
            let standing = await harness.coordinator.committedTerminal()
            ledger.append(
                DeliveredEvent(
                    index: index,
                    event: event,
                    response: response,
                    standingAfter: standing,
                    gatheredCountAfter: gathered.count
                )
            )
            witness.recordDeliveredEvent(event)
        }

        let standingBeforeGate = await harness.coordinator.committedTerminal()
        await gate.openGate()
        let subjectOutcome = await running

        guard !deliveryFailed else {
            witness.recordUnbuildableInput()
            return nil
        }
        guard let subject = subjectOutcome.completed else {
            Issue.record("the subject session must reach a terminal [\(shape)]")
            witness.recordUnbuildableInput()
            return nil
        }
        let subjectCallKinds = harness.recorder.callKinds

        // The positive control, through the *same* coordinator, harness, ports, release, and
        // call log. The gate is open now, so this session runs the whole pipeline and
        // produces a real Evidence Report — the measured one that every measured zero above
        // is read beside. The log is cleared first so the two are never mixed.
        harness.recorder.reset()
        let controlAsset: ImportedEncodedAsset
        do {
            controlAsset = try await release.acceptedIngest(
                byteSeed: shape.byteSeed ^ 0x5A
            )
        } catch {
            Issue.record("the control ingest must be writable: \(error) [\(shape)]")
            witness.recordUnbuildableInput()
            return nil
        }
        guard let control = await harness.coordinator.analyze(controlAsset).completed else {
            Issue.record("the positive control must reach a terminal [\(shape)]")
            witness.recordUnbuildableInput()
            return nil
        }
        let controlCallKinds = harness.recorder.callKinds

        let run = TerminalScheduleRun(
            shape: shape,
            schedule: schedule,
            offeredReport: offeredReport,
            identity: identity,
            staleIdentity: staleIdentity,
            expectation: expectation,
            ledger: ledger,
            observations: observations,
            standingBeforeGate: standingBeforeGate,
            subject: subject,
            subjectCallKinds: subjectCallKinds,
            control: control,
            controlCallKinds: controlCallKinds
        )
        witness.recordExecutedCase(run)
        return run
    }

    /// The Evidence Report an ordinary join offers.
    ///
    /// **Synthetic.** The subject session is suspended inside inference, so no real lanes
    /// have resolved and this value stands in for the report a completed join would offer.
    /// Its only role is to be a completed terminal the slot must treat like any other; no
    /// arm claims its content is correct, and the *real* report is what the positive control
    /// and the pipeline-committed cases produce.
    private static func offeredReport(shape: TerminalScheduleShape) -> EvidenceReport? {
        let lane: ProvenanceLane
        switch shape.offeredLaneIndex {
        case 0: lane = .available(.absent)
        case 1: lane = .unavailable(.validatorNotCompiledIntoRelease)
        default: lane = .unavailable(.capabilityNotEnabledByReleaseCapabilityManifest)
        }
        return EvidenceReport(
            binding: SessionSample.binding(),
            pixel: PixelEvidence.allCases[shape.offeredPixelIndex],
            provenance: lane,
            combinedSummary: nil,
            apparentInconsistency: nil,
            bytePreservationStatus: .unknown,
            inputQuality: SessionSample.inputQuality,
            onDeviceProcessing: true,
            scope: SessionSample.scope
        )
    }

    // MARK: Arms

    /// The reference model ranks every stage exactly once.
    ///
    /// Without this, a stage missing from ``CausalOrderReference/order`` would be skipped by
    /// the reference arbitration and could silently agree with production by returning
    /// whatever was left.
    func checkTheReferenceOrderIsTotal() {
        let ranked = CausalOrderReference.order
        #expect(
            Set(ranked) == Set(AnalysisStage.allCases),
            "the reference order must rank every stage: missing \(Set(AnalysisStage.allCases).subtracting(ranked).map(\.rawValue).sorted())"
        )
        #expect(
            ranked.count == AnalysisStage.allCases.count,
            "the reference order must rank each stage once, found \(ranked.count) entries"
        )
        for stage in AnalysisStage.allCases {
            #expect(
                CausalOrderReference.rank(of: stage) != nil,
                "\(stage.rawValue) is unranked by the reference model"
            )
        }
        // The transcription is checked against the sentence it came from, not against the
        // production list.
        #expect(
            CausalOrderReference.designProse.contains("calibration input"),
            "the quoted design sentence must still name the last enumerated stage"
        )
        #expect(
            CausalOrderReference.enumeratedByTheDesign.count == 8,
            "the design sentence enumerates eight stages, transcribed \(CausalOrderReference.enumeratedByTheDesign.count)"
        )
    }

    /// Every scheduled event was delivered, in order, and the coordinator answered each one.
    ///
    /// The ledger is compared position by position against the schedule *and* against the
    /// reference model's predicted standing outcome and gather size at each position. A
    /// schedule that degenerated into fewer delivered events, or an event whose response
    /// came from the wrong kind of call, fails here rather than making a later arm vacuous.
    func checkEveryScheduledEventWasDelivered() {
        #expect(
            ledger.count == schedule.count,
            "\(schedule.count) events were scheduled but \(ledger.count) were delivered [\(shape)]"
        )
        #expect(
            ledger.map(\.index) == Array(schedule.indices),
            "the ledger positions must be the schedule's, found \(ledger.map(\.index)) [\(shape)]"
        )
        #expect(
            ledger.map(\.event) == schedule,
            "the delivered events must be the scheduled ones [\(shape)]"
        )

        for entry in ledger {
            // The response's shape must match the event's kind, so a step cannot be recorded
            // as delivered on the strength of another step's answer.
            switch (entry.event, entry.response) {
            case let (event, .gathered(fault)):
                #expect(
                    event.contributedFault == fault,
                    "\(event) gathered \(fault) [\(shape)]"
                )
            case (.joinGatheredFaults, .commit):
                break
            case (.cancellationRequest, .cancellation):
                break
            case (.lateFrameworkResult, .admission):
                break
            default:
                Issue.record("\(entry.event) got a response of the wrong kind [\(shape)]")
            }

            #expect(
                entry.standingAfter == expectation.standingAfter[entry.index],
                """
                after event \(entry.index) (\(entry.event)) the standing outcome was \
                \(String(describing: entry.standingAfter)) but the model predicts \
                \(String(describing: expectation.standingAfter[entry.index])) [\(shape)]
                """
            )
            #expect(
                entry.gatheredCountAfter == expectation.gatheredCountAfter[entry.index],
                """
                after event \(entry.index) the gather held \(entry.gatheredCountAfter) faults, \
                model predicts \(expectation.gatheredCountAfter[entry.index]) [\(shape)]
                """
            )
        }

        // Every late result's admission is the model's, which is what proves the discarded
        // ones carried no value rather than simply not being looked at.
        for entry in ledger {
            guard case let .admission(admission, landed, target) = entry.response else {
                continue
            }
            guard let expected = expectation.admissionAt[entry.index] else {
                Issue.record("event \(entry.index) admitted a result unexpectedly [\(shape)]")
                continue
            }
            #expect(
                admission == expected,
                "event \(entry.index) admitted \(admission), model predicts \(expected) [\(shape)]"
            )
            if expected.isAdmitted {
                #expect(
                    landed == .signalsConsistentWithAIGeneration,
                    "a result offered to a running attempt with no terminal must be usable [\(shape)]"
                )
            } else {
                #expect(
                    landed == nil,
                    "a discarded framework result must carry no value [\(shape)]"
                )
            }
            #expect(
                target == (entry.event == .lateFrameworkResult(stale: true)
                    ? staleIdentity : identity),
                "the late result named the wrong attempt [\(shape)]"
            )
        }
    }

    /// Exactly one terminal, ever.
    ///
    /// Not "at least one" and not "the right one": at most one offer may report
    /// ``TerminalCommit/committed(_:)``, every other offer must report
    /// ``TerminalCommit/refusedAlreadyTerminal(_:)`` carrying the *unchanged* standing
    /// outcome, and the outcome standing at the last event must be the one the ended session
    /// reports — which is how the coordinator's own later offer is shown to have changed
    /// nothing.
    func checkExactlyOneTerminalWasEverCommitted() {
        let offers = ledger.filter { $0.response.terminalCommit != nil }
        let accepted = offers.filter(\.response.didCommit)

        #expect(
            offers.count == expectation.committingIndices.count,
            "\(expectation.committingIndices.count) events offer a terminal but \(offers.count) offers reached the slot [\(shape)]"
        )
        #expect(
            accepted.count <= 1,
            "\(accepted.count) offers were accepted; the slot is written once [\(shape)]"
        )
        #expect(
            accepted.count == (expectation.firstCommitIndex == nil ? 0 : 1),
            "the model predicts \(expectation.firstCommitIndex == nil ? 0 : 1) accepted offer, observed \(accepted.count) [\(shape)]"
        )
        #expect(
            accepted.first?.index == expectation.firstCommitIndex,
            """
            the accepted offer was at \(String(describing: accepted.first?.index)) but the \
            model predicts \(String(describing: expectation.firstCommitIndex)) [\(shape)]
            """
        )

        if let firstCommitIndex = expectation.firstCommitIndex,
           let standing = expectation.finalStanding {
            for offer in offers where offer.index > firstCommitIndex {
                guard let commit = offer.response.terminalCommit else { continue }
                #expect(
                    commit.didCommit == false,
                    "the offer at \(offer.index) overwrote a standing terminal [\(shape)]"
                )
                #expect(
                    commit == .refusedAlreadyTerminal(standing),
                    "the offer at \(offer.index) was answered \(commit) rather than a refusal reporting the standing outcome [\(shape)]"
                )
                #expect(
                    commit.standingOutcome == standing,
                    "a refusal must report the standing outcome unchanged [\(shape)]"
                )
            }
        }

        #expect(
            standingBeforeGate == expectation.finalStanding,
            """
            the outcome standing before the gate opened was \
            \(String(describing: standingBeforeGate)), model predicts \
            \(String(describing: expectation.finalStanding)) [\(shape)]
            """
        )

        if let standing = expectation.finalStanding {
            // The pipeline resumed after this and offered its own terminal. The session's
            // outcome is still the one committed mid-flight, which is the observable form of
            // "committing twice cannot change the answer".
            #expect(
                subject.outcome == standing,
                "the ended session reports \(subject.outcome) rather than the terminal committed mid-flight [\(shape)]"
            )
        } else {
            // No event took the slot, so the coordinator's own join committed the one
            // terminal. Its report is the produced one, not the offered synthetic one.
            #expect(
                subject.outcome.isCompleted,
                "with no offer the pipeline must commit its own completed terminal [\(shape)]"
            )
            #expect(
                subject.evidenceReport != nil,
                "the pipeline-committed terminal must carry an Evidence Report [\(shape)]"
            )
            #expect(
                subject.evidenceReport?.binding != offeredReport.binding,
                "the pipeline-committed report must be the produced one, not the offered synthetic one [\(shape)]"
            )
        }
    }

    /// The three terminals are pairwise disjoint, in all three directions.
    ///
    /// Asserted over the ended session's outcome, over every outcome that stood during the
    /// schedule, and over the three concrete values in play — so the claim covers the
    /// completed report the control produced, the cancelled terminal, and whatever failure
    /// the arbitration selected, rather than only whichever one this case reached.
    func checkTheThreeTerminalsArePairwiseDisjoint() {
        var subjects: [SessionTerminalOutcome] = [subject.outcome, control.outcome, .cancelled]
        subjects.append(contentsOf: ledger.compactMap(\.standingAfter))
        subjects.append(contentsOf: expectation.standingAfter.compactMap { $0 })

        for outcome in subjects {
            let predicates = [outcome.isCompleted, outcome.isCancelled, outcome.isFailed]
            #expect(
                predicates.filter { $0 }.count == 1,
                "\(outcome) satisfies \(predicates.filter { $0 }.count) of the three terminal predicates [\(shape)]"
            )

            if outcome.isCompleted {
                // completed is not cancelled and not failed.
                #expect(outcome.isCancelled == false, "a completed terminal is cancelled")
                #expect(outcome.isFailed == false, "a completed terminal is failed")
                #expect(outcome.evidenceReport != nil, "a completed terminal has no report")
                #expect(outcome.failure == nil, "a completed terminal carries a snapshot")
                #expect(outcome.error == nil, "a completed terminal carries a category")
                #expect(outcome.endReason == .completed, "a completed terminal ends otherwise")
            }
            if outcome.isCancelled {
                // cancelled is not completed and not failed.
                #expect(outcome.isCompleted == false, "a cancelled terminal is completed")
                #expect(outcome.isFailed == false, "a cancelled terminal is failed")
                #expect(outcome.evidenceReport == nil, "a cancelled terminal carries a report")
                #expect(outcome.failure == nil, "a cancelled terminal carries a snapshot")
                #expect(outcome.error == nil, "a cancelled terminal carries a category")
                #expect(outcome.endReason == .cancelled, "a cancelled terminal ends otherwise")
            }
            if outcome.isFailed {
                // failed is not completed and not cancelled.
                #expect(outcome.isCompleted == false, "a failed terminal is completed")
                #expect(outcome.isCancelled == false, "a failed terminal is cancelled")
                #expect(outcome.evidenceReport == nil, "a failed terminal carries a report")
                #expect(outcome.error != nil, "a failed terminal carries no category")
                #expect(outcome.endReason == .error, "a failed terminal ends otherwise")
            }
        }
    }

    /// Cancellation acquires no Analysis Error category on any path.
    ///
    /// Requirement 11.17 keeps the cancelled terminal out of the ten categories, so this
    /// checks the whole vocabulary rather than one representative value, and checks the
    /// fault as well as the terminal: a fault that gained a category or a stage would give
    /// the cancelled terminal a failure location.
    func checkCancellationCarriesNoErrorCategory() {
        let cancelled = SessionTerminalOutcome.cancelled
        #expect(cancelled.error == nil, "the cancelled terminal reports a category")
        #expect(cancelled.failure == nil, "the cancelled terminal reports a snapshot")
        for category in AnalysisError.allCases {
            #expect(
                cancelled.error != category,
                "the cancelled terminal reported \(category.rawValue)"
            )
        }
        #expect(AnalysisFault.cancelled.analysisError == nil, "cancellation gained a category")
        #expect(AnalysisFault.cancelled.stage == nil, "cancellation gained a stage")
        #expect(AnalysisFault.cancelled.isCancelled, "cancellation must report itself")

        for entry in ledger {
            guard case let .cancellation(result) = entry.response else { continue }
            guard let standing = result.standingOutcome else { continue }
            if standing.isCancelled {
                #expect(
                    standing.error == nil,
                    "a cancellation request produced a categorised terminal [\(shape)]"
                )
            }
        }

        if subject.outcome.isCancelled {
            #expect(subject.error == nil, "the cancelled session reported a category")
            #expect(
                subject.evidenceReport == nil,
                "the cancelled session reported an Evidence Report"
            )
        }
    }

    /// A failed terminal carries exactly one category, and it is the arbitrated one.
    ///
    /// The comparison is against ``CausalOrderReference``, written in this file from the
    /// design's sentence and Requirement 11.17. The count is taken by filtering the whole
    /// ten-category vocabulary down to the reported value, so "exactly one" is a count and
    /// not a non-`nil` check.
    func checkAFailedTerminalCarriesExactlyOneArbitratedError() {
        guard let firstCommitIndex = expectation.firstCommitIndex,
              let standing = expectation.finalStanding,
              standing.isFailed
        else {
            return
        }
        guard let snapshot = subject.outcome.failure else {
            Issue.record("a failed terminal must carry its snapshot [\(shape)]")
            return
        }
        guard let gathered = expectation.gatheredAtJoin[firstCommitIndex] else {
            Issue.record(
                "a failed terminal must have come from a join, found none at \(firstCommitIndex) [\(shape)]"
            )
            return
        }
        guard let expectedFault = CausalOrderReference.reportedFault(among: gathered),
              case let .analysis(expectedError, expectedStage) = expectedFault
        else {
            Issue.record(
                "the reference model must select one Analysis Error from \(gathered) [\(shape)]"
            )
            return
        }

        let reported = AnalysisError.allCases.filter { $0 == snapshot.error }
        #expect(
            reported.count == 1,
            "a failed terminal must present exactly one of the ten categories, found \(reported.map(\.rawValue)) [\(shape)]"
        )
        #expect(
            snapshot.error == expectedError,
            "the committed category is \(snapshot.error.rawValue) but the reference model selects \(expectedError.rawValue) from \(gathered) [\(shape)]"
        )
        #expect(
            snapshot.stage == expectedStage,
            "the committed stage is \(snapshot.stage.rawValue) but the reference model selects \(expectedStage.rawValue) [\(shape)]"
        )
        // The selected stage really is the causally earliest one in the gather, by this
        // file's ranking. A model that agreed with production while ranking nothing would
        // fail here.
        guard let selectedRank = CausalOrderReference.rank(of: expectedStage) else {
            Issue.record("the selected stage must be ranked [\(shape)]")
            return
        }
        for fault in gathered {
            guard let stage = fault.stage, let rank = CausalOrderReference.rank(of: stage) else {
                continue
            }
            #expect(
                selectedRank <= rank,
                "\(stage.rawValue) is causally earlier than the selected \(expectedStage.rawValue) [\(shape)]"
            )
        }
        // No cancellation was gathered: a gather holding one produces the cancelled
        // terminal, never a categorised failure.
        #expect(
            gathered.contains(where: { $0.isCancelled }) == false,
            "a gather containing cancellation must not produce a failed terminal [\(shape)]"
        )
    }

    /// Arbitration does not depend on which branch returned first.
    ///
    /// Three statements, and they are deliberately not one:
    ///
    ///   * **Arbitration is a function of the offered list alone.** Each gather is arbitrated
    ///     in arrival order and in the reversed order, and each answer must equal the
    ///     reference model's answer *for that same list*. Nothing about timing enters either
    ///     side.
    ///   * **Reordering cannot change the answer** for every gather production can actually
    ///     produce — one where a cancellation dominates, or where a single fault occupies the
    ///     causally earliest stage. The design guarantees that shape, because an adapter
    ///     returns one normalized error per stage.
    ///   * **For the shape the design excludes** — two faults sharing the causally earliest
    ///     stage, which this file still generates — reordering may change which of the tied
    ///     faults is kept, and the tie rule keeps whichever was offered first. What must
    ///     still hold is that both orders select a fault at the *same* earliest stage, so the
    ///     reported causal location is order-independent. Asserting invariance here instead
    ///     would be asserting something the implementation deliberately does not promise.
    func checkArbitrationIsIndependentOfArrivalOrder() {
        for observation in observations {
            #expect(
                observation.productionInArrivalOrder == observation.reference,
                """
                arbitration selected \
                \(String(describing: observation.productionInArrivalOrder)) from \
                \(observation.gathered) but the reference model selects \
                \(String(describing: observation.reference)) [\(shape)]
                """
            )
            #expect(
                observation.productionInReverseOrder == observation.referenceInReverseOrder,
                """
                arbitration selected \
                \(String(describing: observation.productionInReverseOrder)) from the reversed \
                gather but the reference model selects \
                \(String(describing: observation.referenceInReverseOrder)) [\(shape)]
                """
            )

            if observation.gathered.isEmpty {
                #expect(
                    observation.reference == nil,
                    "an empty gather is not a failure [\(shape)]"
                )
                continue
            }

            if observation.reorderingMustNotChangeTheAnswer {
                #expect(
                    observation.productionInArrivalOrder == observation.productionInReverseOrder,
                    "arbitration is not permutation invariant over \(observation.gathered) [\(shape)]"
                )
            } else {
                // The excluded tie shape. The category kept is the first offered; the causal
                // location must be the same from either end.
                let arrivalStage = observation.productionInArrivalOrder?.stage
                let reverseStage = observation.productionInReverseOrder?.stage
                #expect(
                    arrivalStage == reverseStage,
                    """
                    reordering moved the reported stage from \
                    \(String(describing: arrivalStage)) to \(String(describing: reverseStage)) \
                    [\(shape)]
                    """
                )
                if let stage = arrivalStage {
                    #expect(
                        CausalOrderReference.rank(of: stage) == observation.earliestRank,
                        "a tie selected a fault outside the causally earliest stage [\(shape)]"
                    )
                }
            }
        }
    }

    /// No evidence reached a session whose terminal was committed before the evidence
    /// stages.
    ///
    /// Measured against the call log rather than against the result. `calibrate` is the only
    /// way Pixel Evidence exists, `provenanceAnalyze` the only way a provenance result
    /// exists, and `fuse` the only way a Combined Summary exists, so three zeros are the
    /// direct form of Requirement 11.18's "without Pixel Evidence, Provenance Evidence, or a
    /// Combined Summary".
    func checkNoEvidenceReachedANonCompletedTerminal() {
        guard expectation.finalStanding != nil else {
            // No event took the slot, so the pipeline ran to its own completed terminal and
            // the evidence stages are supposed to have run. That case is asserted in
            // `checkExactlyOneTerminalWasEverCommitted`.
            return
        }

        // The session did reach inference before the terminal was committed, so the zeros
        // below are about the stages *after* the commit rather than about a session that
        // never started.
        #expect(
            subjectCallKinds.contains(.validate),
            "the subject session must have reached validation [\(shape)]"
        )
        #expect(
            subjectCallKinds.contains(.infer),
            "the subject session must have reached inference [\(shape)]"
        )

        for kind in Self.evidenceProducingKinds {
            let count = subjectCallKinds.filter { $0 == kind }.count
            #expect(
                count == 0,
                "\(count) \(kind.rawValue) calls happened after the terminal was committed [\(shape)]"
            )
        }

        if subject.outcome.isFailed || subject.outcome.isCancelled {
            #expect(
                subject.evidenceReport == nil,
                "a \(subject.outcome.isFailed ? "failed" : "cancelled") session carries an Evidence Report [\(shape)]"
            )
            #expect(
                subject.outcome.evidenceReport?.combinedSummary == nil,
                "a non-completed session carries a Combined Summary [\(shape)]"
            )
            #expect(
                subject.fusionFault == nil,
                "fusion was attempted for a non-completed session [\(shape)]"
            )
        }
    }

    /// The positive control produced, through identical wiring, everything the arm above
    /// required to be absent.
    ///
    /// This is what turns three zeros into a measurement. Same coordinator, same harness,
    /// same ports, same release, same call log — only the schedule is missing.
    func checkThePositiveControlProducedEvidence() {
        #expect(
            control.outcome.isCompleted,
            "the positive control must complete, got \(control.outcome) [\(shape)]"
        )
        guard let report = control.evidenceReport else {
            Issue.record("the positive control must produce an Evidence Report [\(shape)]")
            return
        }
        #expect(control.error == nil, "the control reported a category [\(shape)]")
        #expect(
            report.provenance.isAvailable,
            "the control's provenance lane must be available [\(shape)]"
        )
        #expect(
            report.combinedSummary != nil,
            "the control must produce a Combined Summary [\(shape)]"
        )
        #expect(control.fusionFault == nil, "the control's fusion rule did not apply [\(shape)]")

        for kind in Self.evidenceProducingKinds {
            let count = controlCallKinds.filter { $0 == kind }.count
            #expect(
                count == 1,
                "the control made \(count) \(kind.rawValue) calls, expected one [\(shape)]"
            )
        }
    }

    /// Seven of the reference model's ten ranks, checked against a running pipeline.
    ///
    /// The control session's call log is an ordering neither the design sentence nor
    /// ``CausalFaultArbitration`` produced: it is the order the coordinator actually visits
    /// its stages in. Each observable port call maps to the stage it runs in, and the
    /// observed sequence must be strictly increasing under ``CausalOrderReference/rank(of:)``.
    ///
    /// The three stages with no observable call — handoff verification, which runs before
    /// the coordinator; media classification, which runs inside validation; and output
    /// validation, which runs inside inference — keep the ranks the design sentence gives
    /// them.
    func checkTheRunningPipelineAgreesWithTheReferenceOrder() {
        let stageOfCall: [PortCallKind: AnalysisStage] = [
            .validate: .inputValidation,
            .preprocess: .preprocessing,
            .loadModel: .modelLoad,
            .infer: .inference,
            .calibrate: .calibration,
            .provenanceAnalyze: .provenanceValidation,
            .fuse: .evidenceJoining,
        ]
        let observed = controlCallKinds.compactMap { stageOfCall[$0] }
        #expect(
            observed.count == stageOfCall.count,
            "the control must visit each observable stage once, observed \(observed.map(\.rawValue)) [\(shape)]"
        )
        for (earlier, later) in zip(observed, observed.dropFirst()) {
            guard let earlierRank = CausalOrderReference.rank(of: earlier),
                  let laterRank = CausalOrderReference.rank(of: later)
            else {
                Issue.record("an observed stage is unranked [\(shape)]")
                continue
            }
            #expect(
                earlierRank < laterRank,
                "the pipeline ran \(earlier.rawValue) before \(later.rawValue) but the reference model ranks them \(earlierRank) and \(laterRank) [\(shape)]"
            )
        }
    }

    /// No Analysis Error category decodes as a pixel label, a provenance state, the
    /// unavailable state, a Combined Summary, or cancellation.
    ///
    /// A claim about the closed domain vocabularies, not about presentation: the encoded
    /// keys are what a signed artifact and a fixture name an expected outcome by, so a
    /// spelling that decoded two ways is what would let an error be read as evidence. What a
    /// user is *shown* for each outcome is task 11.3's subject.
    func checkNoErrorCategoryDecodesAsEvidence() {
        let cancelledTerminalName = String(describing: SessionTerminalOutcome.cancelled)
        for error in AnalysisError.allCases {
            let spelling = error.rawValue
            #expect(
                PixelLabelKey(rawValue: spelling) == nil,
                "\(spelling) decodes as a pixel label key"
            )
            #expect(
                PixelEvidence(rawValue: spelling) == nil,
                "\(spelling) decodes as Pixel Evidence"
            )
            #expect(
                ProvenanceStateKey(rawValue: spelling) == nil,
                "\(spelling) decodes as a provenance state key"
            )
            #expect(
                UnavailableReason(rawValue: spelling) == nil,
                "\(spelling) decodes as the unavailable provenance reason"
            )
            #expect(
                spelling != cancelledTerminalName,
                "\(spelling) spells the cancelled terminal"
            )
            #expect(
                AnalysisErrorKey(rawValue: spelling) != nil,
                "\(spelling) is not in the encoded Analysis Error vocabulary"
            )
        }

        // The copy surfaces keep the same separation: an error surface and an evidence
        // surface can never resolve to the same approved key.
        let errorSurfaces = Set(
            AnalysisErrorKey.allCases.flatMap {
                [
                    VerdictCopySurface.analysisError($0).description,
                    VerdictCopySurface.errorRecovery($0).description,
                ]
            }
        )
        var evidenceSurfaces = Set(
            PixelLabelKey.allCases.flatMap {
                [
                    VerdictCopySurface.pixelLabel($0).description,
                    VerdictCopySurface.pixelExplanation($0).description,
                ]
            }
        )
        evidenceSurfaces.formUnion(
            ProvenanceStateKey.allCases.map { VerdictCopySurface.provenanceState($0).description }
        )
        evidenceSurfaces.insert(VerdictCopySurface.provenanceUnavailable.description)
        if let summary = control.evidenceReport?.combinedSummary {
            evidenceSurfaces.insert(
                VerdictCopySurface.combinedSummary(summary.copyKey).description
            )
        }
        #expect(
            errorSurfaces.isDisjoint(with: evidenceSurfaces),
            "an Analysis Error surface collides with an evidence surface: \(errorSurfaces.intersection(evidenceSurfaces).sorted())"
        )
    }
}

// MARK: - Non-vacuity witness

/// Counts what the run generated, delivered, offered, and produced — outside the property
/// body.
///
/// `propertyCheck` runs its body under `try?` and discards a thrown error, so a body that
/// failed on its first statement would report a passing test in milliseconds with every arm
/// skipped. `completedBodies == cases` alone does not catch that: it passes vacuously as
/// `0 == 0`. The case floor, the per-case counts, and the produced sets are what close the
/// gap, and they live here because an issue recorded outside the body is not suppressed.
///
/// The produced sets are the substantive half. All three terminal kinds, both sources of a
/// final terminal, every event kind, every fault stage, all three admission answers, and
/// joins holding two or more faults must have been **observed**, and one Evidence Report
/// must have been produced by the positive control in **every** case — which is what turns
/// "a failure carries no evidence" from a claim about an unreached branch into a measured
/// zero beside a measured one.
///
/// The thresholds sit far below what the requested number of uniform draws produces, so
/// they witness variation rather than pinning a distribution.
private final class TerminalScheduleWitness: @unchecked Sendable {
    private let lock = NSLock()

    // Run shape.
    private var cases = 0
    private var completedBodies = 0
    private var unbuildableInputs = 0
    private var executedCases = 0

    // Delivery.
    private var deliveredEvents = 0
    private var offers = 0
    private var acceptedOffers = 0
    private var refusedOffers = 0
    private var joins = 0
    private var multiFaultJoins = 0
    private var joinsWithGatheredFaults = 0
    private var permutationInvariantJoins = 0
    private var sameStageTieJoins = 0
    private var casesWithTwoOrMoreOffers = 0
    private var controlReports = 0
    private var measuredZeroCases = 0
    private var measuredOneCases = 0

    // Produced outputs.
    private var observedTerminalKinds: Set<String> = []
    private var observedFinalSources: Set<String> = []
    private var observedEventKinds: Set<ScheduledEventKind> = []
    private var observedFaultStages: Set<AnalysisStage> = []
    private var offeredCategories: Set<AnalysisError> = []
    private var committedCategories: Set<AnalysisError> = []
    private var observedFaultLanes: Set<FaultLane> = []
    private var observedAdmissions: Set<String> = []

    // Generated baseline.
    private var seeds: Set<Int> = []
    private var scheduleLengths: Set<Int> = []
    private var offeredReportShapes: Set<String> = []

    func record(_ shape: TerminalScheduleShape) {
        lock.lock()
        defer { lock.unlock() }
        cases += 1
        seeds.insert(shape.seed)
        scheduleLengths.insert(shape.eventSelectors.count)
        offeredReportShapes.insert("\(shape.offeredPixelIndex)/\(shape.offeredLaneIndex)")
    }

    func recordDeliveredEvent(_ event: ScheduledEvent) {
        lock.lock()
        defer { lock.unlock() }
        deliveredEvents += 1
        observedEventKinds.insert(event.kind)
        switch event {
        case let .branchFault(lane, error, stage):
            observedFaultLanes.insert(lane)
            offeredCategories.insert(error)
            observedFaultStages.insert(stage)
        case let .resourceBreach(lane, stage):
            observedFaultLanes.insert(lane)
            offeredCategories.insert(.resourceLimit)
            observedFaultStages.insert(stage)
        case let .branchCancellation(lane):
            observedFaultLanes.insert(lane)
        case .joinGatheredFaults, .cancellationRequest, .lateFrameworkResult:
            break
        }
    }

    func recordJoin(_ observation: ArbitrationObservation) {
        lock.lock()
        defer { lock.unlock() }
        joins += 1
        if observation.gathered.count >= 2 { multiFaultJoins += 1 }
        if observation.gathered.isEmpty { return }
        joinsWithGatheredFaults += 1
        if observation.reorderingMustNotChangeTheAnswer {
            permutationInvariantJoins += 1
        } else {
            sameStageTieJoins += 1
        }
    }

    /// Records the outcomes one fully executed case produced.
    func recordExecutedCase(_ run: TerminalScheduleRun) {
        lock.lock()
        defer { lock.unlock() }
        executedCases += 1

        let caseOffers = run.ledger.filter { $0.response.terminalCommit != nil }
        offers += caseOffers.count
        acceptedOffers += caseOffers.filter(\.response.didCommit).count
        refusedOffers += caseOffers.filter { !$0.response.didCommit }.count
        if caseOffers.count >= 2 { casesWithTwoOrMoreOffers += 1 }

        let outcome = run.subject.outcome
        if outcome.isCompleted { observedTerminalKinds.insert("completed") }
        if outcome.isCancelled { observedTerminalKinds.insert("cancelled") }
        if outcome.isFailed { observedTerminalKinds.insert("failed") }
        if let category = outcome.error { committedCategories.insert(category) }
        observedFinalSources.insert(
            run.expectation.finalStanding == nil ? "pipeline" : "offered"
        )

        for entry in run.ledger {
            guard case let .admission(admission, _, _) = entry.response else { continue }
            switch admission {
            case .admitted: observedAdmissions.insert("admitted")
            case .discardedTerminalCommitted: observedAdmissions.insert("terminalCommitted")
            case .discardedStaleIdentity: observedAdmissions.insert("staleIdentity")
            case .discardedNoActiveSession: observedAdmissions.insert("noActiveSession")
            }
        }

        if run.control.evidenceReport != nil { controlReports += 1 }
        let controlEvidenceCalls = TerminalScheduleRun.evidenceProducingKinds.allSatisfy { kind in
            run.controlCallKinds.contains(kind)
        }
        if controlEvidenceCalls { measuredOneCases += 1 }
        if run.expectation.finalStanding != nil {
            let subjectEvidenceCalls = TerminalScheduleRun.evidenceProducingKinds.contains {
                kind in run.subjectCallKinds.contains(kind)
            }
            if !subjectEvidenceCalls { measuredZeroCases += 1 }
        }
    }

    /// Records an input this file described but could not build.
    ///
    /// Never a finding about the coordinator: every input here is built from generated
    /// integers inside validated ranges, so a refusal is a defect in this file. It is
    /// counted so a run whose inputs quietly stopped being buildable fails outside the body
    /// rather than shrinking its own coverage.
    func recordUnbuildableInput() {
        lock.lock()
        unbuildableInputs += 1
        lock.unlock()
    }

    /// Called last in the body, so a case that stopped early is countable.
    func recordCompletedBody() {
        lock.lock()
        completedBodies += 1
        lock.unlock()
    }

    func expectMeasuredRun(requestedCases: Int) {
        lock.lock()
        defer { lock.unlock() }

        let readOut = """
            cases \(cases)/\(requestedCases), completed bodies \(completedBodies), \
            executed \(executedCases), unbuildable \(unbuildableInputs); \
            delivered events \(deliveredEvents), offers \(offers) \
            (accepted \(acceptedOffers), refused \(refusedOffers)), \
            joins \(joins) (with faults \(joinsWithGatheredFaults), \
            multi-fault \(multiFaultJoins), \
            reorder-invariant \(permutationInvariantJoins), \
            same-stage ties \(sameStageTieJoins)), \
            cases with two or more offers \(casesWithTwoOrMoreOffers); \
            control reports \(controlReports), measured ones \(measuredOneCases), \
            measured zeros \(measuredZeroCases); \
            terminal kinds \(observedTerminalKinds.sorted()), \
            final sources \(observedFinalSources.sorted()), \
            event kinds \(observedEventKinds.map(\.rawValue).sorted()), \
            fault stages \(observedFaultStages.count)/\(AnalysisStage.allCases.count), \
            offered categories \(offeredCategories.count)/\(AnalysisError.allCases.count), \
            committed categories \(committedCategories.count), \
            fault lanes \(observedFaultLanes.map(\.rawValue).sorted()), \
            admissions \(observedAdmissions.sorted()); \
            seeds \(seeds.count), schedule lengths \(scheduleLengths.sorted()), \
            offered report shapes \(offeredReportShapes.count)
            """

        #expect(
            cases == requestedCases && completedBodies == cases && executedCases == cases,
            "read-out: \(readOut)"
        )
        #expect(
            cases >= requestedCases,
            "the run must generate \(requestedCases) cases; ran \(cases)"
        )
        #expect(
            completedBodies == cases,
            "\(cases - completedBodies) of \(cases) cases did not reach the end of the body"
        )
        #expect(
            executedCases == cases,
            "\(cases - executedCases) of \(cases) cases did not execute a schedule"
        )
        #expect(
            unbuildableInputs == 0,
            "\(unbuildableInputs) described inputs could not be built at all"
        )

        // Counted work. Schedules hold two to seven events, so the floors sit far below what
        // the requested count produces and far enough above zero that a run which built only
        // fixtures fails here rather than passing.
        #expect(deliveredEvents >= 2 * cases, "delivered events: \(deliveredEvents)")
        #expect(offers >= cases / 2, "terminal offers reaching the slot: \(offers)")
        #expect(acceptedOffers >= cases / 2, "accepted offers: \(acceptedOffers)")
        #expect(refusedOffers >= 100, "refused offers: \(refusedOffers)")
        #expect(joins >= cases / 2, "joins arbitrated: \(joins)")
        #expect(
            multiFaultJoins >= 40,
            "joins holding two or more gathered faults: \(multiFaultJoins)"
        )
        #expect(
            permutationInvariantJoins >= 100,
            "joins whose answer had to survive reordering: \(permutationInvariantJoins)"
        )
        // Every gather with a fault in it was classified as one or the other, so no join
        // slipped past both branches of the arm. The tie count itself carries no floor: the
        // excluded same-stage shape is rare by construction — a measured run put it at 7 in
        // 500 cases — and a floor on it would be a coin flip rather than a coverage
        // requirement. It is reported instead.
        #expect(
            permutationInvariantJoins + sameStageTieJoins == joinsWithGatheredFaults,
            """
            \(joinsWithGatheredFaults) joins held faults but \
            \(permutationInvariantJoins + sameStageTieJoins) were classified by the \
            reordering arm
            """
        )
        #expect(
            casesWithTwoOrMoreOffers >= 100,
            "cases where two or more events would each commit: \(casesWithTwoOrMoreOffers)"
        )

        // Every absence was measured beside a presence, on every case.
        #expect(
            controlReports == cases,
            "\(cases - controlReports) cases produced no positive-control Evidence Report"
        )
        #expect(
            measuredOneCases == cases,
            "\(cases - measuredOneCases) positive controls did not call every evidence port"
        )
        #expect(
            measuredZeroCases >= 100,
            "cases where a committed terminal measured three evidence zeros: \(measuredZeroCases)"
        )

        // The substantive half: the outputs were produced, not merely offered.
        #expect(
            observedTerminalKinds == ["cancelled", "completed", "failed"],
            "terminal kinds never produced: \(Set(["cancelled", "completed", "failed"]).subtracting(observedTerminalKinds).sorted())"
        )
        #expect(
            observedFinalSources == ["offered", "pipeline"],
            "a terminal was only ever committed by \(observedFinalSources.sorted())"
        )
        #expect(
            observedEventKinds == Set(ScheduledEventKind.allCases),
            "event kinds never delivered: \(Set(ScheduledEventKind.allCases).subtracting(observedEventKinds).map(\.rawValue).sorted())"
        )
        #expect(
            observedFaultStages == Set(AnalysisStage.allCases),
            "stages never carried by a generated fault: \(Set(AnalysisStage.allCases).subtracting(observedFaultStages).map(\.rawValue).sorted())"
        )
        #expect(
            offeredCategories == Set(AnalysisError.allCases),
            "categories never offered: \(Set(AnalysisError.allCases).subtracting(offeredCategories).map(\.rawValue).sorted())"
        )
        #expect(
            committedCategories.count >= 5,
            "distinct categories reaching a committed terminal: \(committedCategories.map(\.rawValue).sorted())"
        )
        #expect(
            observedFaultLanes == Set(FaultLane.allCases),
            "faults only ever arrived from \(observedFaultLanes.map(\.rawValue).sorted())"
        )
        #expect(
            observedAdmissions == ["admitted", "staleIdentity", "terminalCommitted"],
            "admission answers never observed: \(Set(["admitted", "staleIdentity", "terminalCommitted"]).subtracting(observedAdmissions).sorted())"
        )

        // The generated baseline actually varied.
        #expect(seeds.count >= 100, "generated seeds: \(seeds.count)")
        #expect(
            scheduleLengths == [2, 3, 4, 5, 6, 7],
            "generated schedule lengths: \(scheduleLengths.sorted())"
        )
        #expect(
            offeredReportShapes.count >= 6,
            "generated offered-report shapes: \(offeredReportShapes.count)"
        )
    }
}
