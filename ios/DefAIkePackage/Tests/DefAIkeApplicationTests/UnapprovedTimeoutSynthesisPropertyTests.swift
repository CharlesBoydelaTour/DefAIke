import DefAIkeDomain
import DefAIkeTestSupport
import Foundation
import PropertyBased
import Testing

@testable import DefAIkeApplication

// Design Property 36: no unapproved timeout is synthesized.
//
// The design states it as: for any Analysis Session whose measurements remain within the
// active Resource Budget and that receives no completion, cancellation, operating-system
// interruption, or defined Analysis Error, the coordinator keeps the session active with
// honest progress and does not create a timeout, failure, or verdict from elapsed time
// alone (Requirements 15.8, 15.9, and 15.10).
//
// ## This is a negative existential, and that is the whole difficulty
//
// "The session stays active" is satisfied for free by a session that never started, by a
// coordinator nobody asked anything, and by a clock nobody read. Three guards close those
// three holes, and each one is *measured* rather than assumed:
//
//   1. **The session is genuinely running at every observation.** The subject session is
//      suspended inside inference at a ``BranchGate`` rendezvous, so at every observation
//      the coordinator holds an active identity, has committed no terminal, has latched no
//      cancellation request, still admits framework results, reports
//      ``AnalysisStage/inference`` as its stage, and — the part a stalled fixture could not
//      fake — the shared call log shows one `validate`, one `preprocess`, one `loadModel`,
//      and one `infer`, with zero `calibrate`. The session has provably entered work and is
//      provably still inside it.
//   2. **The clock actually advanced, by arbitrarily large amounts.** Every advance is
//      recorded with the injected clock's monotonic instant and wall clock on both sides,
//      and the monotonic delta must equal the requested ``Duration`` exactly. The last
//      advance of every case is a mandated century, so "however far the clock advances" is
//      a per-case fact rather than a distributional hope.
//   3. **A real terminal event does reach a terminal, on every case.** Two positive
//      controls run through the same wiring: the subject session itself completes with a
//      real Evidence Report the instant the gate opens (work completion), and a second
//      gated session on the same release and the same already-advanced clock reaches
//      `cancelled` the instant the user's cancel control is activated. So "stays active" is
//      measured beside "terminates when a terminal event occurs", not beside a coordinator
//      that cannot terminate at all.
//
// ## Nothing sleeps, and nothing is raced
//
// Time is injected. ``VirtualSessionClock`` is the release's own ``SessionClock`` seam and
// never advances on its own; this file advances it by hand between synchronous actor steps.
// **No arm sleeps, polls a wall clock, or waits for real time to pass.** A test that
// actually waited would be slow, flaky, and would prove nothing about a timeout the app
// synthesizes — the interesting claim is precisely that unbounded virtual time changes
// nothing. Advances are bounded (at most six generated advances of up to one year plus one
// century) so the clock arithmetic cannot overflow, and the mandated century is what makes
// the bound generous rather than cautious.
//
// ## The two seams, and why both are driven
//
// Requirement 15.10 is a statement about two collaborators that production deliberately
// keeps apart, and neither one alone would carry it:
//
//   * ``ResourceController`` enforces *measured* budgets and holds no clock, deadline, or
//     elapsed-time member at all. It is driven directly here: with every named metric
//     reading inside the bound budget, every checkpoint must keep returning normally, no
//     breach may latch, and an evidence commit must stay permitted — across a century of
//     virtual time. That is Requirements 15.8 and 15.9's "permit analysis to continue".
//   * ``AnalysisCoordinator`` owns the terminal slot and does not check a resource metric.
//     It is observed for the terminal claim over the same clock and the same release-bound
//     budget.
//
// Saying so plainly: in production these are separate seams, so this file exercises both
// rather than pretending one drives the other.
//
// ## The structural half
//
// A runtime property cannot prove a *future* change will not synthesize a timeout. The
// second test in this suite audits the comment-stripped source of every file in
// `Sources/DefAIkeApplication` for elapsed-time and deadline-derived terminal decisions.
// Comment stripping is essential and not cosmetic: this module's prose says the words
// "timeout", "deadline", "elapsed", and "clock" repeatedly, precisely because their absence
// from the code is the requirement, so an unstripped scan would be a false positive on
// every file. One legitimate use is allowed, exactly and by line: ``SessionTerminalCleanup``
// reads a cleanup deadline out of the approved Data Lifecycle Policy and returns it
// (Requirements 9.8 and 11.15). That deadline is an approved artifact value being reported,
// never a duration being compared against a clock, and the allowance is pinned to the two
// lines that do it.
//
// ## No approved value appears anywhere in this file
//
// **No resource budget, deadline, timeout, or duration here is an approved release value.**
// The real budgets and cleanup deadlines are unresolved external decisions (open
// dependency E4 and design decision D6), and the release under test is
// ``CoordinatorRelease``, whose every artifact is synthetic. The clock magnitudes below are
// scaffolding chosen to be absurdly large, not candidate limits — which is the point of
// this property: a synthesized timeout would be an unapproved release decision made in
// code, so this file must not make one either.
//
// ## What this file does not claim
//
//   * **Property 34 (task 10.10) owns honest progress derivation.** Nothing here asserts
//     which prerequisites make progress determinate, what a percentage means, or how a
//     cause is selected. The only progress claims are the two Requirement 15.10 needs:
//     every observation yields one of the two honest forms — a measured readout, or an
//     explicit "analysis is continuing" — and the derived value is *identical* across a
//     century of clock advance, which is the sharpest available statement that time is not
//     feeding it.
//   * **Property 35 (task 10.11) owns cancellation.** Cancellation appears here only as the
//     positive control's terminal event.
//   * **Property 29 (task 10.8) owns the resource-limit rule.** Nothing here claims when a
//     limit *is* breached; every generated reading is inside its limit by construction.
//   * **Property 30 (task 10.9) owns terminal disjointness**, and **task 10.13** owns the
//     cancellation-point integration matrix.
//   * A host run says nothing about the operating system's own watchdog terminating the
//     process. That is a platform behaviour on a physical device, measured by the Device
//     Validation Plan, and it is a different concern from a timeout the app synthesizes —
//     which is the only thing this property is about.
//
// ## Why no arm throws
//
// `propertyCheck` runs its body under `try?` and discards a thrown error, so a `throw` in
// the body reports a passing run in milliseconds with every arm skipped. Nothing below
// rethrows: the release build, the ingest, and every fallible construction become an
// `Issue.record` plus a counted unbuildable input, and every throwing port call is turned
// into a value first. The witness counters live *outside* the body, where an issue is not
// suppressed, and `completedBodies == cases` is paired with `cases == requestedCount` and a
// case floor because it passes vacuously as `0 == 0` when the body throws on case one.

extension Tag {
    /// Design Property 36.
    @Tag static var property36NoSynthesizedTimeout: Self
}

@Suite(
    "Property 36: No unapproved timeout is synthesized",
    .tags(.property36NoSynthesizedTimeout)
)
struct UnapprovedTimeoutSynthesisPropertyTests {

    /// The number of generated cases requested.
    ///
    /// Each case runs the real startup gate, one gated session with several observations,
    /// one completion control, and one gated cancellation control, so the per-case cost is
    /// high. Two hundred and forty is enough for the witness's coverage product — eight
    /// clock magnitudes, ten stages, six progress shapes — while keeping the suite's
    /// runtime honest. No assertion is relaxed to fit it.
    static let generatedCaseCount = 240

    /// **Validates: Requirements 15.8, 15.9, 15.10**
    @Test("An arbitrarily advancing clock creates no terminal, no error, and no new progress")
    func anArbitrarilyAdvancingClockSynthesizesNoTimeout() async {
        let witness = TimeoutSynthesisWitness()

        await propertyCheck(
            count: Self.generatedCaseCount,
            input: TimeoutProbeShape.generator
        ) { shape in
            witness.record(shape)
            guard let run = await TimeoutProbeRun.execute(shape: shape, witness: witness)
            else { return }

            run.checkTheTerminalVocabularyCannotExpressATimeout()
            run.checkTheClockActuallyAdvanced()
            run.checkTheSessionWasGenuinelyRunningAtEveryObservation()
            run.checkNoTerminalWasCommittedHoweverFarTheClockAdvanced()
            run.checkWorkInsideTheBudgetKeptBeingPermitted()
            run.checkProgressStayedHonestAndIdentical()
            run.checkTheCompletionControlReachedItsTerminal()
            run.checkTheCancellationControlReachedItsTerminal()

            witness.recordCompletedBody()
        }

        witness.expectMeasuredRun(requestedCases: Self.generatedCaseCount)
    }

    /// **Validates: Requirements 15.10**
    ///
    /// The structural half of the negative existential. A runtime property shows that today's
    /// coordinator synthesizes no timeout; this shows there is nothing in the module for one
    /// to be derived *from*, which is what catches a future change a runtime test would not.
    @Test("No source in the application module derives a decision from elapsed time")
    func theApplicationModuleReadsNoClock() throws {
        let files = try TimeoutSourceAudit.moduleSourceFiles()
        #expect(
            files.count >= 16,
            "the audit must read the whole module; found \(files.count) sources"
        )

        var scannedFiles = 0
        var sawTheCleanupFile = false
        for file in files {
            let name = file.lastPathComponent
            let code = TimeoutSourceAudit.strippingComments(
                try String(contentsOf: file, encoding: .utf8)
            )
            scannedFiles += 1

            // No elapsed-time framework is even imported, so `Date`, `Timer`,
            // `DispatchQueue.asyncAfter`, and `ContinuousClock` are not in scope to be
            // reached. The token list is deliberately blunt: it forbids the *substrings*, so
            // a new identifier merely mentioning time fails the audit and has to be argued
            // for rather than slipping in.
            for token in TimeoutSourceAudit.forbiddenInEveryFile {
                #expect(
                    !code.contains(token),
                    "\(name) must not reference \(token) in code: elapsed time is out of every terminal decision (Requirement 15.10)"
                )
            }

            if name == TimeoutSourceAudit.cleanupDeadlineFile {
                sawTheCleanupFile = true
                TimeoutSourceAudit.checkTheOnlyLegitimateDeadlineUse(in: code, file: name)
            } else {
                for token in TimeoutSourceAudit.deadlineTokensAllowedOnlyInCleanup {
                    #expect(
                        !code.contains(token),
                        "\(name) must not reference \(token): a duration belongs to an approved artifact, and only \(TimeoutSourceAudit.cleanupDeadlineFile) reports one"
                    )
                }
            }
        }

        #expect(scannedFiles == files.count, "every source must be scanned")
        #expect(
            sawTheCleanupFile,
            "\(TimeoutSourceAudit.cleanupDeadlineFile) must exist for the allowance to be pinned to it"
        )
    }
}

// MARK: - The forbidden vocabulary, as a source-text audit

/// Reads the application module's own sources and forbids elapsed-time terminal logic.
///
/// The scan is a substring scan over comment-stripped code, which is the same shape task
/// 11.3 and the bundle-tooling audits established. Comment stripping is what makes it
/// meaningful here rather than merely noisy: `ResourceController`, `ProgressMeasurement`,
/// `ProgressDerivation`, `AnalysisCoordinator`, and `SessionCancellation` all *say* the
/// words "clock", "deadline", "elapsed", and "timeout" in prose, because declaring their
/// absence is the requirement. An unstripped scan would fail on the documentation that
/// promises the very thing being audited.
private enum TimeoutSourceAudit {

    /// The one file permitted to name a duration, and why.
    ///
    /// ``SessionTerminalCleanup`` reports the cleanup deadline the committed terminal
    /// outcome selects, read straight out of the approved ``DataLifecyclePolicy``
    /// (Requirements 9.8 and 11.15). That is an approved artifact value being *returned*,
    /// not a duration being compared against a clock — and the allowance below is pinned to
    /// the two lines that do it, so a third use fails the audit.
    static let cleanupDeadlineFile = "SessionTerminalCleanup.swift"

    /// Tokens no file in the module may contain in code.
    ///
    /// Blunt substrings on purpose. `"time"` and `"Time"` between them cover `timeout`,
    /// `Timer`, `TimeInterval`, `timeIntervalSince`, `DispatchTime`, `timedOut`, and
    /// `clock_gettime`; `"clock"` and `"Clock"` cover `ContinuousClock`, `SuspendingClock`,
    /// `SessionClock`, `wallClockNow`, and `monotonicNow`'s companions.
    static let forbiddenInEveryFile = [
        "time", "Time",
        "clock", "Clock",
        "Date",
        "sleep", "Sleep",
        "elapsed", "Elapsed",
        "expire", "Expire",
        "interval", "Interval",
        "instant", "Instant",
        "delay", "Delay",
        "watch", "Watch",
        "Dispatch",
        "Foundation",
    ]

    /// Tokens legitimate only in ``cleanupDeadlineFile``.
    static let deadlineTokensAllowedOnlyInCleanup = ["deadline", "Deadline", "Duration"]

    /// The two exact lines the cleanup file is allowed to spell a deadline on.
    ///
    /// Transcribed from the file rather than matched loosely, so a comparison, a subtraction,
    /// a stored deadline, or a second accessor would fail here instead of being absorbed.
    static let permittedDeadlineLineFragments = [
        "public func deadline(for outcome: SessionTerminalOutcome) -> ValidatedDuration",
        "policy.deadline(for: outcome.endReason.cleanupReason)",
    ]

    /// Checks the cleanup file's deadline use is exactly the two permitted lines.
    static func checkTheOnlyLegitimateDeadlineUse(in code: String, file: String) {
        let deadlineLines = code
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { $0.contains("deadline") || $0.contains("Deadline") }

        #expect(
            deadlineLines.count == permittedDeadlineLineFragments.count,
            "\(file) may spell a deadline on exactly \(permittedDeadlineLineFragments.count) lines; found \(deadlineLines.count): \(deadlineLines.map { $0.trimmingCharacters(in: .whitespaces) })"
        )
        for fragment in permittedDeadlineLineFragments {
            #expect(
                deadlineLines.contains(where: { $0.contains(fragment) }),
                "\(file) no longer contains the permitted deadline line `\(fragment)`; a changed deadline use must be argued for, not re-permitted"
            )
        }
        // The permitted use *reports* an approved artifact value. It must not name a duration
        // type of its own, so `ValidatedDuration` is the only `Duration` spelling allowed.
        let withoutValidated = code.replacingOccurrences(
            of: "ValidatedDuration",
            with: ""
        )
        #expect(
            !withoutValidated.contains("Duration"),
            "\(file) may name a duration only as the approved artifact's `ValidatedDuration`"
        )
    }

    /// Removes `//` comment text so the scan reads code rather than documentation.
    ///
    /// No source in this module puts `//` inside a string literal, and the scan asserts the
    /// absence of exactly the tokens that would appear in one, so a line-wise split is
    /// enough. Its failure mode is a false pass on a file that does not exist, which
    /// ``moduleSourceFiles()`` refuses.
    static func strippingComments(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let marker = line.range(of: "//") else { return String(line) }
                return String(line[line.startIndex..<marker.lowerBound])
            }
            .joined(separator: "\n")
    }

    static func moduleSourceFiles() throws -> [URL] {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/DefAIkeApplication")
        let files = try FileManager.default
            .contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(
            !files.isEmpty,
            "the module's sources must be readable for this audit to mean anything"
        )
        return files.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

// MARK: - Generated shape

/// How far one advance moves the injected clock.
///
/// **No value here is an approved analysis-time limit.** They are magnitudes chosen to span
/// a millisecond to a year so that "arbitrarily advancing" is exercised rather than
/// asserted, and the run additionally mandates ``TimeoutProbeShape/mandatedFinalAdvance``.
private enum ClockAdvanceMagnitude: Int, Sendable, CaseIterable, CustomStringConvertible {
    case oneMillisecond = 0
    case quarterSecond
    case oneMinute
    case oneHour
    case oneDay
    case oneWeek
    case thirtyDays
    case oneYear

    /// Whole milliseconds, so every advance lands on an exact nanosecond and the monotonic
    /// delta can be asserted for exact equality rather than within a tolerance.
    var milliseconds: Int64 {
        switch self {
        case .oneMillisecond: 1
        case .quarterSecond: 250
        case .oneMinute: 60_000
        case .oneHour: 3_600_000
        case .oneDay: 86_400_000
        case .oneWeek: 604_800_000
        case .thirtyDays: 2_592_000_000
        case .oneYear: 31_536_000_000
        }
    }

    var duration: Duration { .milliseconds(milliseconds) }

    /// Whether this magnitude is one a synthesized timeout would plausibly have fired at.
    ///
    /// Recorded for the read-out only. Nothing branches on it: the assertion is the same at
    /// one millisecond and at one year, which is the property.
    var isLarge: Bool { milliseconds >= ClockAdvanceMagnitude.oneDay.milliseconds }

    var description: String { "\(milliseconds)ms" }
}

/// Which honest report the progress derivation is handed.
///
/// Both determinate and indeterminate inputs appear, because the claim is about the derived
/// value being invariant under clock advance in *either* form. Which form a given input
/// produces is Property 34's statement, not this file's.
private enum TimeoutProgressShape: Int, Sendable, CaseIterable {
    case measuredInRange = 0
    case totalMissing
    case completedMissing
    case unreliableCompleted
    case unitMismatch
    case nothingReported
}

/// Everything one generated case decides, as plain data.
///
/// The generator produces integers only. The release, the harness, the ingest, the resource
/// controller, and the progress report are built from them inside the run, where a
/// construction that unexpectedly fails is recorded as an issue rather than thrown.
///
/// ## How the baseline varies
///
///   * the **number** of clock advances, over two to six, so runs of different lengths are
///     exercised rather than one fixed template;
///   * each advance's **magnitude**, over all eight, from a millisecond to a year;
///   * which two **resource metrics** each checkpoint names, over the seven the
///     main-application budget defines, drawn independently so a pair may repeat a metric;
///   * the **stage** each checkpoint reports, over all ten;
///   * the **readings** the governor answers with, all strictly inside the bound limits; and
///   * the **progress report** shape, its two amounts, and its unit.
///
/// One selector decides one advance-and-checkpoint step. Its range is
/// 3920 = 8 x 7 x 7 x 10, a multiple of every modulus it is reduced by, and each field
/// reads a different digit, so the four choices are uniform and independent.
private struct TimeoutProbeShape: Sendable, CustomStringConvertible {

    /// Selector range for one step. See the note above on why this exact size.
    static let stepSelectorBound = 3_919

    /// Selector range for the progress report: 1200 = 6 x 10 x 10 x 2.
    static let progressSelectorBound = 1_199

    /// The highest governor reading a case may program.
    ///
    /// Comfortably inside the synthetic budget's limits, with room for the reservation the
    /// run also takes out, so every generated reading is in budget by construction. Property
    /// 29 owns what happens at and past a limit.
    static let readingBound = 500_000

    /// The advance every case ends with, whatever it generated.
    ///
    /// A century, in whole milliseconds. This is what makes "however far the clock advances"
    /// a per-case fact: a run that only ever nudged the clock by a millisecond would satisfy
    /// the property while proving almost nothing.
    static let mandatedFinalAdvance = Duration.milliseconds(3_153_600_000_000)

    /// Drives the synthetic byte seed and the session identifiers, so a case's ingest varies.
    let seed: Int

    /// One selector per generated advance, in delivery order.
    let stepSelectors: [Int]

    /// Selects the governor's readings.
    let readingSelector: Int

    /// Selects the progress report's shape, amounts, and unit.
    let progressSelector: Int

    // MARK: Derived

    /// A byte seed that is never zero, so the ingest's bytes differ from an empty pattern.
    var byteSeed: UInt8 { UInt8(truncatingIfNeeded: seed % 251) | 1 }

    /// The main-application budget's metric set, in a stable order.
    static let mainApplicationMetrics: [ResourceMetric] = ResourceMetric
        .requiredMetrics(for: .mainApplication)
        .sorted { $0.rawValue < $1.rawValue }

    var magnitudes: [ClockAdvanceMagnitude] {
        stepSelectors.map { ClockAdvanceMagnitude.allCases[$0 % 8] }
    }

    var metricPairs: [(ResourceMetric, ResourceMetric)] {
        stepSelectors.map { selector in
            let metrics = Self.mainApplicationMetrics
            return (
                metrics[(selector / 8) % metrics.count],
                metrics[(selector / 56) % metrics.count]
            )
        }
    }

    var stages: [AnalysisStage] {
        stepSelectors.map {
            AnalysisStage.allCases[($0 / 392) % AnalysisStage.allCases.count]
        }
    }

    /// The reading programmed for `metric`, always strictly inside its limit.
    ///
    /// The metrics get different readings so a governor that ignored the budget, or a
    /// controller that read one metric's number for another, would move the comparison.
    func reading(for metric: ResourceMetric) -> Decimal {
        let index = Self.mainApplicationMetrics.firstIndex(of: metric) ?? 0
        return Decimal((readingSelector + index * 7_919) % Self.readingBound)
    }

    var progressShape: TimeoutProgressShape {
        TimeoutProgressShape.allCases[progressSelector % TimeoutProgressShape.allCases.count]
    }

    private var completedDigit: Int { (progressSelector / 6) % 10 }
    private var totalDigit: Int { (progressSelector / 60) % 10 }
    private var unitIndex: Int { (progressSelector / 600) % 2 }

    /// A total of at least one, and a completed count inside `0...total`.
    private var totalAmount: UInt64 { UInt64(totalDigit + 1) }
    private var completedAmount: UInt64 { UInt64(completedDigit % (totalDigit + 1)) }

    private var reportedUnit: ProgressUnit { unitIndex == 0 ? .encodedBytes : .imageRows }
    private var otherUnit: ProgressUnit { unitIndex == 0 ? .imageRows : .encodedBytes }

    /// The report the progress derivation is handed, or `nil` for a stage counting nothing.
    var reportedWork: ReportedWork? {
        let completed = WorkAmount(
            amount: completedAmount,
            unit: reportedUnit,
            reliability: .reliable
        )
        let total = WorkAmount(
            amount: totalAmount,
            unit: reportedUnit,
            reliability: .reliable
        )
        switch progressShape {
        case .measuredInRange:
            return ReportedWork(completed: completed, total: total)
        case .totalMissing:
            return ReportedWork(completed: completed, total: nil)
        case .completedMissing:
            return ReportedWork(completed: nil, total: total)
        case .unreliableCompleted:
            return ReportedWork(
                completed: WorkAmount(
                    amount: completedAmount,
                    unit: reportedUnit,
                    reliability: .unreliable
                ),
                total: total
            )
        case .unitMismatch:
            return ReportedWork(
                completed: completed,
                total: WorkAmount(
                    amount: totalAmount,
                    unit: otherUnit,
                    reliability: .reliable
                )
            )
        case .nothingReported:
            return nil
        }
    }

    var description: String {
        "seed \(seed), advances [\(magnitudes.map(\.description).joined(separator: " "))] + century, reading \(readingSelector), progress \(progressShape)"
    }

    static var generator: Generator<TimeoutProbeShape, AnySequence<Any>> {
        zip(
            Gen.int(in: 0...9_999),
            Gen.int(in: 0...stepSelectorBound).array(of: 2...6),
            Gen.int(in: 0...readingBound),
            Gen.int(in: 0...progressSelectorBound)
        )
        .map { seed, steps, reading, progress in
            TimeoutProbeShape(
                seed: seed,
                stepSelectors: steps,
                readingSelector: reading,
                progressSelector: progress
            )
        }
        .eraseToAny()
    }
}

// MARK: - One observation of a running session over an advanced clock

/// Everything read back after one clock advance, on both sides of it.
///
/// Recorded rather than asserted inline so the arms compare a whole run and a step that
/// never reached the actor has nothing to be entered as. Observation zero is the baseline:
/// its advance is zero, and it is what every later observation's progress value and call
/// counts are compared against.
private struct TimeoutObservation: Sendable {
    let index: Int

    /// How far this observation advanced the clock. Zero for the baseline.
    let advance: Duration

    /// Whether this observation delivered the mandated century.
    let isTheMandatedCentury: Bool

    let wallClockBefore: Date
    let wallClockAfter: Date
    let monotonicBefore: ContinuousClock.Instant
    let monotonicAfter: ContinuousClock.Instant

    // The coordinator, read after the advance.
    let activeIdentity: AnalysisSessionIdentity?
    let committedTerminal: SessionTerminalOutcome?
    let cancellationRequested: Bool
    let admission: FrameworkResultAdmission
    let landedLateResult: PixelEvidence?
    let reportedStage: AnalysisStage?
    let callCounts: [PortCallKind: Int]

    // The resource controller, read after the advance.
    let checkpointMetrics: (ResourceMetric, ResourceMetric)
    let checkpointStage: AnalysisStage
    let checkpointFault: AnalysisFault?
    let breach: ResourceBreach?
    let permitsEvidenceCommit: Bool
    let outstandingReservationTokens: [ResourceReservationToken]
    let governorCallCount: Int

    // Honest progress, derived at the stage the coordinator reports.
    let progress: DerivedAnalysisProgress
}

// MARK: - One executed case

/// One generated case: a running session, a series of advances, and two positive controls.
private struct TimeoutProbeRun: Sendable {
    let shape: TimeoutProbeShape

    /// The subject session's identity, captured while it was suspended inside inference.
    let identity: AnalysisSessionIdentity

    /// The call counts at the rendezvous, before any clock advance.
    let callCountsAtTheGate: [PortCallKind: Int]

    /// The governor's call count after the reservation and before the first checkpoint.
    let governorCallsBeforeObservations: Int

    /// The reservation taken out before the advances, which must survive all of them.
    let reservationToken: ResourceReservationToken

    let observations: [TimeoutObservation]

    /// The completion control: the subject session, resumed and ended.
    let completionControl: CompletedAnalysisSession

    /// The cancellation control: a second gated session on the same already-advanced clock.
    let cancellationControl: CompletedAnalysisSession

    /// What the cancellation control's terminal slot held immediately before the request.
    let cancellationControlTerminalBeforeRequest: SessionTerminalOutcome?

    /// What activating the cancel control did.
    let cancellationControlRequest: CancellationRequestResult

    /// The call counts a session provably inside inference must show.
    ///
    /// One of each of the four ports the pipeline reaches before inference returns, and zero
    /// calibrations because the logit has not come back yet. This is guard (1): a coordinator
    /// that had never been asked anything would show four zeros here and fail.
    static let expectedCallCountsInsideInference: [PortCallKind: Int] = [
        .validate: 1,
        .preprocess: 1,
        .loadModel: 1,
        .infer: 1,
        .calibrate: 0,
    ]

    // MARK: Execution

    static func execute(
        shape: TimeoutProbeShape,
        witness: TimeoutSynthesisWitness
    ) async -> TimeoutProbeRun? {
        let release: CoordinatorRelease
        do {
            release = try await CoordinatorRelease.build()
        } catch {
            Issue.record("the synthetic release must pass its own startup gate: \(error)")
            witness.recordUnbuildableInput()
            return nil
        }

        // The controller governs the main application over *this release's* bound budget
        // pair, so the numbers in force are the artifacts' rather than constants of this
        // file's. None of them is an approved release limit.
        let governor = RecordingResourceGovernor(target: .mainApplication)
        guard let controller = ResourceController(
            target: .mainApplication,
            budgets: release.admission.configuration.resourceBudgets,
            governor: governor
        ) else {
            Issue.record("a main-application controller over the bound budget must exist")
            witness.recordUnbuildableInput()
            return nil
        }
        for metric in TimeoutProbeShape.mainApplicationMetrics where !metric.isCategorical {
            await governor.setReading(shape.reading(for: metric), for: metric)
        }

        let subjectSessionID = "session-0001"
        let controlSessionID = "session-0002"
        let gate = BranchGate()
        let harness = CoordinatorHarness.make(
            release: release,
            sessionID: subjectSessionID,
            gate: gate
        )
        let asset: ImportedEncodedAsset
        do {
            asset = try await release.acceptedIngest(
                sessionID: subjectSessionID,
                byteSeed: shape.byteSeed
            )
        } catch {
            Issue.record("the accepted ingest must be writable: \(error) [\(shape)]")
            witness.recordUnbuildableInput()
            return nil
        }

        // The pixel branch suspends inside inference, so `analyze` is itself suspended and
        // every step below lands while the session is genuinely in flight. The ordering is
        // this file's, established by a rendezvous rather than raced for, and nothing sleeps.
        async let running = harness.coordinator.analyze(asset)
        await gate.waitUntilReached()

        guard let identity = await harness.coordinator.activeIdentity() else {
            Issue.record("the gated session must be the running attempt [\(shape)]")
            witness.recordUnbuildableInput()
            await gate.openGate()
            _ = await running
            return nil
        }
        let callCountsAtTheGate = Self.callCounts(harness.recorder)

        // Headroom granted before any time passes. It must still be outstanding after a
        // century, because nothing in the controller expires a reservation.
        let reserved = await Self.reserve(controller, at: .inputValidation)
        guard let reservation = reserved.0 else {
            Issue.record(
                "in-budget headroom must be grantable: \(String(describing: reserved.1)) [\(shape)]"
            )
            witness.recordUnbuildableInput()
            await gate.openGate()
            _ = await running
            return nil
        }
        let governorCallsBeforeObservations = await governor.calls().count

        // The baseline observation advances nothing; the generated advances follow; the
        // mandated century is last.
        let advances: [Duration] =
            [.zero] + shape.magnitudes.map(\.duration) + [TimeoutProbeShape.mandatedFinalAdvance]
        let metricPairs = shape.metricPairs
        let stages = shape.stages

        var observations: [TimeoutObservation] = []
        for (index, advance) in advances.enumerated() {
            // Step 0 is the baseline and reuses the first generated pair; the mandated
            // century reuses the last. Both keep the checkpoint arguments in range without a
            // separate generator.
            let pairIndex = min(max(index - 1, 0), metricPairs.count - 1)
            let (metricA, metricB) = metricPairs[pairIndex]
            let checkpointStage = stages[pairIndex]

            let wallClockBefore = release.clock.wallClockNow
            let monotonicBefore = release.clock.monotonicNow
            // Virtual time only. `VirtualSessionClock` never advances on its own and nothing
            // here sleeps, so the whole run costs no wall-clock time at all.
            release.clock.advance(by: advance)
            let wallClockAfter = release.clock.wallClockNow
            let monotonicAfter = release.clock.monotonicNow

            let activeIdentity = await harness.coordinator.activeIdentity()
            let committedTerminal = await harness.coordinator.committedTerminal()
            let cancellationRequested = await harness.coordinator.isCancellationRequested()
            let admitted = await harness.coordinator.admit(
                PixelEvidence.signalsConsistentWithAIGeneration,
                for: identity
            )
            let admission = await harness.coordinator.admitFrameworkResult(for: identity)
            let reportedStage = await harness.coordinator.currentStage()
            let callCounts = Self.callCounts(harness.recorder)

            let checkpointFault = await Self.checkpointFault(
                controller,
                metricA,
                metricB,
                at: checkpointStage
            )
            let breach = await controller.currentBreach()
            let permits = await controller.permits(.evidenceReport)
            let outstanding = await controller.outstandingReservations().map(\.token)
            let governorCallCount = await governor.calls().count

            let observation = TimeoutObservation(
                index: index,
                advance: advance,
                isTheMandatedCentury: index == advances.count - 1,
                wallClockBefore: wallClockBefore,
                wallClockAfter: wallClockAfter,
                monotonicBefore: monotonicBefore,
                monotonicAfter: monotonicAfter,
                activeIdentity: activeIdentity,
                committedTerminal: committedTerminal,
                cancellationRequested: cancellationRequested,
                admission: admission,
                landedLateResult: admitted.value,
                reportedStage: reportedStage,
                callCounts: callCounts,
                checkpointMetrics: (metricA, metricB),
                checkpointStage: checkpointStage,
                checkpointFault: checkpointFault,
                breach: breach,
                permitsEvidenceCommit: permits,
                outstandingReservationTokens: outstanding,
                governorCallCount: governorCallCount,
                // Derived at the stage the coordinator itself reports, so the progress value
                // describes the work actually in flight. No clock reaches this call: the
                // derivation takes a report and a stage and nothing else.
                progress: DerivedAnalysisProgress(
                    reported: shape.reportedWork,
                    at: reportedStage ?? checkpointStage
                )
            )
            observations.append(observation)
            witness.recordObservation(observation)
        }

        // Positive control one: a real terminal event. The gate opens, inference returns, and
        // the *same* session on the *same* century-advanced clock reaches its completed
        // terminal with a real Evidence Report.
        await gate.openGate()
        let subjectOutcome = await running
        guard let completionControl = subjectOutcome.completed else {
            Issue.record("the subject session must reach a terminal once work completes [\(shape)]")
            witness.recordUnbuildableInput()
            return nil
        }

        // Positive control two: the other real terminal event. A second gated session over
        // the same release, the same clock, the same budget, and the same call log, held
        // inside inference, advanced by another century, and then cancelled by the visible
        // control. Its own gate, because `BranchGate` opens once.
        harness.recorder.reset()
        let controlGate = BranchGate()
        let controlHarness = CoordinatorHarness.make(
            release: release,
            sessionID: controlSessionID,
            gate: controlGate
        )
        let controlAsset: ImportedEncodedAsset
        do {
            controlAsset = try await release.acceptedIngest(
                sessionID: controlSessionID,
                byteSeed: shape.byteSeed ^ 0x5A | 1
            )
        } catch {
            Issue.record("the control ingest must be writable: \(error) [\(shape)]")
            witness.recordUnbuildableInput()
            return nil
        }
        async let controlRunning = controlHarness.coordinator.analyze(controlAsset)
        await controlGate.waitUntilReached()
        guard let controlIdentity = await controlHarness.coordinator.activeIdentity() else {
            Issue.record("the control session must be the running attempt [\(shape)]")
            witness.recordUnbuildableInput()
            await controlGate.openGate()
            _ = await controlRunning
            return nil
        }
        release.clock.advance(by: TimeoutProbeShape.mandatedFinalAdvance)
        let controlTerminalBeforeRequest = await controlHarness.coordinator.committedTerminal()
        let request = await controlHarness.coordinator.requestCancellation(for: controlIdentity)
        await controlGate.openGate()
        guard let cancellationControl = await controlRunning.completed else {
            Issue.record("the cancellation control must reach a terminal [\(shape)]")
            witness.recordUnbuildableInput()
            return nil
        }

        let run = TimeoutProbeRun(
            shape: shape,
            identity: identity,
            callCountsAtTheGate: callCountsAtTheGate,
            governorCallsBeforeObservations: governorCallsBeforeObservations,
            reservationToken: reservation.token,
            observations: observations,
            completionControl: completionControl,
            cancellationControl: cancellationControl,
            cancellationControlTerminalBeforeRequest: controlTerminalBeforeRequest,
            cancellationControlRequest: request
        )
        witness.recordExecutedCase(run)
        return run
    }

    /// Every port-call count this file asserts on, read from the shared log.
    private static func callCounts(_ recorder: PortCallRecorder) -> [PortCallKind: Int] {
        var counts: [PortCallKind: Int] = [:]
        for kind in Self.expectedCallCountsInsideInference.keys {
            counts[kind] = recorder.callCount(of: kind)
        }
        return counts
    }

    /// Samples two metrics and reports the fault, or `nil` when both read in budget.
    ///
    /// A named function rather than an inline `do`/`catch` so the port's typed fault is what
    /// the catch binds — and so that nothing throws out of the property body, where an error
    /// would be discarded and report a passing run with every arm skipped.
    private static func checkpointFault(
        _ controller: ResourceController,
        _ first: ResourceMetric,
        _ second: ResourceMetric,
        at stage: AnalysisStage
    ) async -> AnalysisFault? {
        do {
            try await controller.checkpoint(first, second, at: stage)
            return nil
        } catch {
            return error
        }
    }

    /// Reserves one unit of decoded-pixel headroom, or reports the fault.
    ///
    /// One pixel against a limit the release's budget states in pixels: the smallest request
    /// that still exercises the reservation path, so the grant cannot be confused with a
    /// judgement about an approved amount.
    private static func reserve(
        _ controller: ResourceController,
        at stage: AnalysisStage
    ) async -> (ResourceReservation?, AnalysisFault?) {
        do {
            return (
                try await controller.reserve(
                    .decodedPixelCount,
                    amount: CoordinatorSample.positive(1),
                    unit: CoordinatorSample.limitUnit(for: .decodedPixelCount),
                    at: stage
                ),
                nil
            )
        } catch {
            return (nil, error)
        }
    }

    // MARK: - Arms

    /// A timeout terminal is unrepresentable, not merely unobserved.
    ///
    /// The runtime arms show that no timeout *fired*. This one shows there is no timeout to
    /// fire: the terminal vocabulary is closed at three cases and the Analysis Error
    /// vocabulary at ten, and the ten are the requirements' own closed set transcribed here
    /// rather than read back out of the enumeration under test.
    func checkTheTerminalVocabularyCannotExpressATimeout() {
        // Transcribed from the requirements' closed Analysis Error set and the design's error
        // table. A test that read this list out of `AnalysisError` would assert nothing.
        let requiredCategories: Set<String> = [
            "unsupported-media",
            "unsupported-static-format",
            "decoding-error",
            "resource-limit",
            "preprocessing-error",
            "model-load-error",
            "inference-error",
            "invalid-output-error",
            "calibration-input-error",
            "handoff-error",
        ]
        let actualCategories = Set(AnalysisError.allCases.map(\.rawValue))
        #expect(
            actualCategories == requiredCategories,
            "the Analysis Error set must be exactly the requirements' ten categories; extra \(actualCategories.subtracting(requiredCategories).sorted()), missing \(requiredCategories.subtracting(actualCategories).sorted())"
        )
        #expect(
            AnalysisError.allCases.count == 10,
            "the closed set holds ten categories, found \(AnalysisError.allCases.count)"
        )
        // No category, and no cleanup reason, spells a time-derived outcome. A future case
        // named for elapsed time would fail here before it could ever be committed.
        for token in ["time", "Time", "deadline", "expire", "stall", "elapsed", "too-long"] {
            for category in AnalysisError.allCases {
                #expect(
                    !category.rawValue.contains(token),
                    "the Analysis Error `\(category.rawValue)` names \(token): a timeout category is not an approved release decision"
                )
            }
            for reason in SessionEndReason.allCases {
                #expect(
                    !reason.rawValue.contains(token),
                    "the session end reason `\(reason.rawValue)` names \(token)"
                )
            }
        }
        // A fault is cancellation or exactly one category, with nothing in between, so there
        // is no third thing a clock could produce.
        for category in AnalysisError.allCases {
            for stage in AnalysisStage.allCases {
                let fault = AnalysisFault.analysis(category, stage: stage)
                #expect(fault.isCancelled == false)
                #expect(fault.analysisError == category)
                #expect(fault.stage == stage)
            }
        }
        #expect(AnalysisFault.cancelled.analysisError == nil)
        #expect(AnalysisFault.cancelled.stage == nil)

        // Every terminal actually produced in this case is exactly one of the three kinds.
        for (label, outcome) in [
            ("completion control", completionControl.outcome),
            ("cancellation control", cancellationControl.outcome),
        ] {
            let kinds = [outcome.isCompleted, outcome.isCancelled, outcome.isFailed]
            #expect(
                kinds.filter { $0 }.count == 1,
                "the \(label)'s terminal must be exactly one of the three kinds, found \(kinds)"
            )
        }
    }

    /// The clock advanced, by the requested amount, including by a century.
    ///
    /// Guard (2). Without this the whole property could be satisfied by a clock nobody
    /// touched. The monotonic delta is asserted for exact equality — every advance is a whole
    /// number of milliseconds, so it lands on an exact nanosecond — and the wall clock is
    /// asserted to move forward by the same amount within floating-point tolerance, because
    /// `Date` carries seconds as a `Double`.
    func checkTheClockActuallyAdvanced() {
        guard let baseline = observations.first, let last = observations.last else {
            Issue.record("a case must record at least a baseline and a final observation")
            return
        }
        #expect(
            observations.count >= 4,
            "a case advances the clock at least three times plus a baseline, recorded \(observations.count) observations [\(shape)]"
        )
        #expect(baseline.advance == .zero, "observation zero is the baseline and advances nothing")
        #expect(
            baseline.monotonicBefore == baseline.monotonicAfter,
            "the baseline must not move the clock"
        )
        #expect(
            last.isTheMandatedCentury,
            "the final observation must deliver the mandated century advance"
        )
        #expect(
            last.advance == TimeoutProbeShape.mandatedFinalAdvance,
            "the mandated final advance must be a century, found \(last.advance)"
        )

        for observation in observations.dropFirst() {
            #expect(
                observation.advance > .zero,
                "observation \(observation.index) must advance the clock [\(shape)]"
            )
            // The exact claim: virtual monotonic time moved by precisely what was asked for.
            #expect(
                observation.monotonicBefore.duration(to: observation.monotonicAfter)
                    == observation.advance,
                "observation \(observation.index) requested \(observation.advance) but the monotonic clock moved \(observation.monotonicBefore.duration(to: observation.monotonicAfter)) [\(shape)]"
            )
            let expectedSeconds = Self.seconds(in: observation.advance)
            let movedSeconds = observation.wallClockAfter
                .timeIntervalSince(observation.wallClockBefore)
            #expect(
                movedSeconds > 0,
                "observation \(observation.index) left the wall clock where it was [\(shape)]"
            )
            #expect(
                abs(movedSeconds - expectedSeconds) <= max(1e-6, expectedSeconds * 1e-12),
                "observation \(observation.index) moved the wall clock \(movedSeconds)s, expected \(expectedSeconds)s [\(shape)]"
            )
        }

        // Monotonic across the whole run, and by an absurd amount in total.
        let totalMoved = baseline.monotonicBefore.duration(to: last.monotonicAfter)
        let requestedTotal = observations.map(\.advance).reduce(Duration.zero, +)
        #expect(
            totalMoved == requestedTotal,
            "the run requested \(requestedTotal) in total but the clock moved \(totalMoved) [\(shape)]"
        )
        #expect(
            totalMoved >= TimeoutProbeShape.mandatedFinalAdvance,
            "every case must advance the clock by at least a century, moved \(totalMoved)"
        )
        for (earlier, later) in zip(observations, observations.dropFirst()) {
            #expect(
                earlier.monotonicAfter <= later.monotonicBefore,
                "observations \(earlier.index) and \(later.index) are out of clock order"
            )
        }
    }

    /// The session was genuinely running at every observation.
    ///
    /// Guard (1), and the one that keeps this property from being about an idle coordinator.
    /// Each observation must show the *same* active attempt, no committed terminal, no
    /// latched cancellation, an attempt that still admits results, `inference` as the
    /// reported stage, and the four measured port calls that prove work was entered — with
    /// zero calibrations, because the logit has not come back yet. And none of those counts
    /// may move: advancing the clock must not push the pipeline forward or abort it.
    func checkTheSessionWasGenuinelyRunningAtEveryObservation() {
        #expect(
            callCountsAtTheGate == Self.expectedCallCountsInsideInference,
            "at the rendezvous the session must be provably inside inference; log shows \(Self.readable(callCountsAtTheGate)) [\(shape)]"
        )
        for observation in observations {
            #expect(
                observation.activeIdentity == identity,
                "observation \(observation.index) must still hold the same active attempt, found \(String(describing: observation.activeIdentity)) [\(shape)]"
            )
            #expect(
                observation.reportedStage == .inference,
                "observation \(observation.index) must still report inference, found \(String(describing: observation.reportedStage?.rawValue)) [\(shape)]"
            )
            #expect(
                observation.admission == .admitted,
                "observation \(observation.index) must still admit framework results, found \(observation.admission) [\(shape)]"
            )
            #expect(
                observation.landedLateResult == .signalsConsistentWithAIGeneration,
                "observation \(observation.index) must still let a result land, so the session is not quietly over [\(shape)]"
            )
            #expect(
                observation.callCounts == Self.expectedCallCountsInsideInference,
                "observation \(observation.index) moved the pipeline: \(Self.readable(observation.callCounts)) [\(shape)]"
            )
            #expect(
                observation.callCounts == callCountsAtTheGate,
                "observation \(observation.index) changed the call log a clock advance must not touch [\(shape)]"
            )
        }
    }

    /// No terminal was committed, and no cancellation latched, however far the clock advanced.
    ///
    /// The core of the negative existential (Requirement 15.10). The subject session received
    /// no completion, no cancellation, no operating-system interruption, and no Analysis
    /// Error — only time — so the slot must be empty at every observation, including after a
    /// century.
    func checkNoTerminalWasCommittedHoweverFarTheClockAdvanced() {
        for observation in observations {
            #expect(
                observation.committedTerminal == nil,
                "observation \(observation.index) found a terminal after \(observation.advance): \(String(describing: observation.committedTerminal)) [\(shape)]"
            )
            #expect(
                observation.committedTerminal?.error == nil,
                "observation \(observation.index) synthesized an Analysis Error from elapsed time [\(shape)]"
            )
            #expect(
                observation.cancellationRequested == false,
                "observation \(observation.index) latched a cancellation nobody requested [\(shape)]"
            )
            #expect(
                observation.admission.standingOutcome == nil,
                "observation \(observation.index) reports a standing outcome for a session with no terminal event [\(shape)]"
            )
            #expect(
                observation.admission.wasDiscardedByCancellation == false,
                "observation \(observation.index) discarded a result as cancelled without a cancellation [\(shape)]"
            )
        }
    }

    /// Work still inside the budget kept being permitted (Requirements 15.8 and 15.9).
    ///
    /// Every named metric reads inside the bound limit, so the controller must keep returning
    /// normally from every checkpoint, must latch no breach, must keep permitting the
    /// main application's evidence commit, and must still be holding the headroom it granted
    /// before any time passed. The governor's call count is what proves the checkpoints
    /// actually sampled rather than being skipped: two observations apart it must grow by
    /// exactly the two metrics each one named.
    func checkWorkInsideTheBudgetKeptBeingPermitted() {
        for observation in observations {
            #expect(
                observation.checkpointFault == nil,
                "observation \(observation.index) stopped in-budget work at \(observation.checkpointStage.rawValue) with \(String(describing: observation.checkpointFault)) [\(shape)]"
            )
            #expect(
                observation.breach == nil,
                "observation \(observation.index) latched a breach from elapsed time: \(String(describing: observation.breach)) [\(shape)]"
            )
            #expect(
                observation.permitsEvidenceCommit,
                "observation \(observation.index) stopped permitting the evidence commit [\(shape)]"
            )
            #expect(
                observation.outstandingReservationTokens == [reservationToken],
                "observation \(observation.index) lost or duplicated the granted headroom: \(observation.outstandingReservationTokens.count) reservations [\(shape)]"
            )
            // Two `observe` calls per checkpoint, cumulative on top of the one reservation
            // taken before the run. A checkpoint that returned without sampling would leave
            // this count behind.
            #expect(
                observation.governorCallCount
                    == governorCallsBeforeObservations + 2 * (observation.index + 1),
                "observation \(observation.index) performed \(observation.governorCallCount - governorCallsBeforeObservations - 2 * observation.index) samples instead of two [\(shape)]"
            )
        }
    }

    /// Progress stayed honest, and stayed identical across a century.
    ///
    /// Two claims, both narrow, because Property 34 owns progress derivation:
    ///
    ///   * **Honest.** Every observation yields exactly one of the two honest forms — a
    ///     measured determinate readout, or an explicit indeterminate state asserting that
    ///     analysis is continuing. Never nothing, never "stalled", never "0% done" standing
    ///     in for an unmeasured stage. "Stalled" is unrepresentable rather than merely
    ///     unused, which is asserted on the assertion vocabulary itself.
    ///   * **Not fed by time.** The whole derived value — state, cause, fraction — is
    ///     *identical* at every observation, including after the mandated century. That is
    ///     the sharpest available statement that no fraction is derived from elapsed time:
    ///     no work completed between observations, so nothing about the value may move.
    func checkProgressStayedHonestAndIdentical() {
        guard let baseline = observations.first else {
            Issue.record("a case must record a baseline observation")
            return
        }
        for observation in observations {
            let progress = observation.progress
            // Total by construction: there is always a state to display, so an active stage
            // never shows nothing (Requirement 15.1).
            #expect(
                progress.state.stage == .inference,
                "observation \(observation.index) derived progress for the wrong stage: \(progress.state.stage.rawValue) [\(shape)]"
            )
            // Exactly one honest form.
            #expect(
                progress.isDeterminate == (progress.indeterminateAssertion == nil),
                "observation \(observation.index) is neither determinate nor explicitly indeterminate [\(shape)]"
            )
            if progress.isDeterminate {
                #expect(
                    progress.fractionOfWorkCompleted != nil,
                    "a determinate state must carry a usable measured fraction [\(shape)]"
                )
                #expect(
                    progress.unmeasuredCause == nil,
                    "a determinate state must name no refusal cause [\(shape)]"
                )
            } else {
                // Continuing, not stalled, completed, or failed (Requirement 15.4).
                #expect(
                    progress.indeterminateAssertion == .analysisIsContinuing,
                    "an indeterminate state must assert the analysis is continuing [\(shape)]"
                )
                #expect(
                    progress.percentage == nil,
                    "an unmeasured stage must not be shown as a percentage [\(shape)]"
                )
                #expect(
                    progress.unmeasuredCause != nil,
                    "an indeterminate state must name why no fraction was derived [\(shape)]"
                )
            }
            // The invariance claim.
            #expect(
                progress == baseline.progress,
                "observation \(observation.index) changed the derived progress after \(observation.advance) with no work completed [\(shape)]"
            )
            #expect(
                progress.fractionOfWorkCompleted == baseline.progress.fractionOfWorkCompleted,
                "observation \(observation.index) changed the measured fraction after \(observation.advance) [\(shape)]"
            )
            #expect(
                progress.unmeasuredCause == baseline.progress.unmeasuredCause,
                "observation \(observation.index) changed the refusal cause after \(observation.advance) [\(shape)]"
            )
        }
        // "Stalled", "completed", and "failed" are not progress states at all: the assertion
        // vocabulary has one member, so an unmeasured stage cannot be projected as a stopped
        // one.
        #expect(
            IndeterminateProgressAssertion.allCases == [.analysisIsContinuing],
            "the indeterminate assertion vocabulary must hold only `analysisIsContinuing`, found \(IndeterminateProgressAssertion.allCases.map(\.rawValue))"
        )
    }

    /// Positive control one: work completing does reach a terminal, through the same wiring.
    ///
    /// Guard (3), first half. The subject session's own resumption. It ran the whole pipeline
    /// over a clock already advanced by a century and produced a real Evidence Report the
    /// moment inference returned — so "stays active" above is the behaviour of a session
    /// waiting on work, not of a coordinator that cannot terminate.
    func checkTheCompletionControlReachedItsTerminal() {
        #expect(
            completionControl.identity == identity,
            "the completion control must be the same attempt that stayed active [\(shape)]"
        )
        #expect(
            completionControl.outcome.isCompleted,
            "work completing must reach the completed terminal, found \(completionControl.outcome) [\(shape)]"
        )
        #expect(
            completionControl.evidenceReport != nil,
            "the completion control must produce a real Evidence Report [\(shape)]"
        )
        #expect(
            completionControl.error == nil,
            "a completed session carries no Analysis Error [\(shape)]"
        )
        // Cleanup ran under the completed reason's own approved deadline. No number is
        // asserted here: the deadline is read from the release's Data Lifecycle Policy, and
        // Property 25 owns cleanup.
        #expect(
            completionControl.cleanup.receipt?.reason == .completed,
            "the completion control must be cleaned up as a completed session [\(shape)]"
        )
    }

    /// Positive control two: the user's cancellation does reach a terminal, over the same
    /// already-advanced clock.
    ///
    /// Guard (3), second half, and the sharper of the two. The control session was held
    /// inside inference exactly like the subject, the clock was advanced by another century
    /// while it waited, and its terminal slot was still empty — and then a single real
    /// terminal event ended it immediately. What was missing from the subject was therefore a
    /// terminal *event*, not the capability to terminate.
    func checkTheCancellationControlReachedItsTerminal() {
        #expect(
            cancellationControlTerminalBeforeRequest == nil,
            "the control session must also stay active over an advanced clock, found \(String(describing: cancellationControlTerminalBeforeRequest)) [\(shape)]"
        )
        #expect(
            cancellationControlRequest.latchedRequest,
            "the cancel control's request must latch on a running session [\(shape)]"
        )
        #expect(
            cancellationControlRequest.isCancelled,
            "the request must claim the terminal with cancelled [\(shape)]"
        )
        #expect(
            cancellationControl.outcome == .cancelled,
            "a real cancellation must reach the cancelled terminal, found \(cancellationControl.outcome) [\(shape)]"
        )
        #expect(
            cancellationControl.evidenceReport == nil,
            "a cancelled session carries no Evidence Report [\(shape)]"
        )
        #expect(
            cancellationControl.error == nil,
            "cancellation is not an Analysis Error category [\(shape)]"
        )
        #expect(
            cancellationControl.identity != identity,
            "the cancellation control must be a different attempt from the subject [\(shape)]"
        )
    }

    // MARK: - Helpers

    /// A `Duration` as seconds, computed the same way ``VirtualSessionClock`` does.
    static func seconds(in duration: Duration) -> Double {
        Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
    }

    /// A stable, readable rendering of a call-count map for a failure message.
    static func readable(_ counts: [PortCallKind: Int]) -> String {
        counts
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue)=\($0.value)" }
            .joined(separator: " ")
    }
}

// MARK: - Non-vacuity witness

/// Counts what the run generated, advanced, observed, and produced — outside the property
/// body.
///
/// `propertyCheck` runs its body under `try?` and discards a thrown error, so a body that
/// failed on its first statement would report a passing test in milliseconds with every arm
/// skipped. `completedBodies == cases` alone does not catch that: it passes vacuously as
/// `0 == 0`. The case floor, `cases == requestedCases`, the per-case counts, and the
/// produced sets are what close the gap, and they live here because an issue recorded
/// outside the body is not suppressed.
///
/// The substantive half is the produced sets. Every clock magnitude must have been
/// delivered, both honest progress forms must have been produced, all six generated report
/// shapes must have been seen, every stage must have been checkpointed, and *every* case
/// must have produced both positive controls — which is what turns "no terminal was
/// committed" from a claim about an idle coordinator into a measured absence beside two
/// measured presences.
private final class TimeoutSynthesisWitness: @unchecked Sendable {
    private let lock = NSLock()

    // Run shape.
    private var cases = 0
    private var completedBodies = 0
    private var executedCases = 0
    private var unbuildableInputs = 0

    // Advancing.
    private var observations = 0
    private var advances = 0
    private var largeAdvances = 0
    /// Whole milliseconds of virtual time this run advanced, summed.
    ///
    /// `Int64` rather than a wider type: the largest run advances roughly 8e14 milliseconds,
    /// four orders of magnitude inside the range, and `Int128` needs macOS 15 while this
    /// package's development host floor is macOS 14.
    private var totalAdvancedMilliseconds: Int64 = 0
    private var casesWithACenturyAdvance = 0

    // Enforcement and progress.
    private var checkpointsPerformed = 0
    private var governorSamples = 0
    private var determinateObservations = 0
    private var indeterminateObservations = 0

    // Controls.
    private var completionControls = 0
    private var cancellationControls = 0

    // Produced coverage.
    private var observedMagnitudes: Set<Int64> = []
    private var observedCheckpointStages: Set<AnalysisStage> = []
    private var observedCheckpointMetrics: Set<ResourceMetric> = []
    private var observedProgressForms: Set<String> = []
    private var observedUnmeasuredCauses = 0

    // Generated baseline.
    private var seeds: Set<Int> = []
    private var advanceCounts: Set<Int> = []
    private var progressShapes: Set<Int> = []
    private var readingSelectors: Set<Int> = []

    func record(_ shape: TimeoutProbeShape) {
        lock.lock()
        defer { lock.unlock() }
        cases += 1
        seeds.insert(shape.seed)
        advanceCounts.insert(shape.stepSelectors.count)
        progressShapes.insert(shape.progressShape.rawValue)
        readingSelectors.insert(shape.readingSelector)
    }

    func recordObservation(_ observation: TimeoutObservation) {
        lock.lock()
        defer { lock.unlock() }
        observations += 1
        checkpointsPerformed += 1
        governorSamples += 2
        observedCheckpointStages.insert(observation.checkpointStage)
        observedCheckpointMetrics.insert(observation.checkpointMetrics.0)
        observedCheckpointMetrics.insert(observation.checkpointMetrics.1)
        if observation.advance > .zero {
            advances += 1
            let milliseconds = observation.advance.components.seconds * 1_000
                + observation.advance.components.attoseconds / 1_000_000_000_000_000
            observedMagnitudes.insert(milliseconds)
            totalAdvancedMilliseconds += milliseconds
            if milliseconds >= ClockAdvanceMagnitude.oneDay.milliseconds { largeAdvances += 1 }
        }
        if observation.progress.isDeterminate {
            determinateObservations += 1
            observedProgressForms.insert("determinate")
        } else {
            indeterminateObservations += 1
            observedProgressForms.insert("indeterminate")
        }
        if observation.progress.unmeasuredCause != nil { observedUnmeasuredCauses += 1 }
    }

    /// Records the outcomes one fully executed case produced.
    func recordExecutedCase(_ run: TimeoutProbeRun) {
        lock.lock()
        defer { lock.unlock() }
        executedCases += 1
        if run.observations.contains(where: \.isTheMandatedCentury) {
            casesWithACenturyAdvance += 1
        }
        if run.completionControl.evidenceReport != nil { completionControls += 1 }
        if run.cancellationControl.outcome == .cancelled { cancellationControls += 1 }
    }

    /// Records an input this file described but could not build.
    ///
    /// Never a finding about the coordinator: every input here is built from generated
    /// integers inside validated ranges, so a refusal is a defect in this file. It is counted
    /// so a run whose inputs quietly stopped being buildable fails outside the body rather
    /// than shrinking its own coverage.
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

        let years = Double(totalAdvancedMilliseconds) / 31_536_000_000
        let readOut = """
            cases \(cases)/\(requestedCases), completed bodies \(completedBodies), \
            executed \(executedCases), unbuildable \(unbuildableInputs); \
            observations \(observations), advances \(advances) \
            (large \(largeAdvances)), virtual time advanced ~\(Int(years)) years, \
            cases with the mandated century \(casesWithACenturyAdvance); \
            checkpoints \(checkpointsPerformed), governor samples \(governorSamples); \
            progress determinate \(determinateObservations), \
            indeterminate \(indeterminateObservations), \
            causes named \(observedUnmeasuredCauses), \
            forms \(observedProgressForms.sorted()); \
            completion controls \(completionControls), \
            cancellation controls \(cancellationControls); \
            magnitudes \(observedMagnitudes.count)/\(ClockAdvanceMagnitude.allCases.count + 1), \
            checkpoint stages \(observedCheckpointStages.count)/\(AnalysisStage.allCases.count), \
            checkpoint metrics \(observedCheckpointMetrics.count)/\(TimeoutProbeShape.mainApplicationMetrics.count); \
            seeds \(seeds.count), advance counts \(advanceCounts.sorted()), \
            progress shapes \(progressShapes.sorted()), \
            reading selectors \(readingSelectors.count)
            """

        // The run happened at all.
        #expect(
            cases == requestedCases && completedBodies == cases && executedCases == cases,
            "read-out: \(readOut)"
        )
        #expect(
            cases == requestedCases,
            "the run must generate \(requestedCases) cases; ran \(cases)"
        )
        #expect(
            cases >= 100,
            "a run this thin cannot support the coverage floors below; ran \(cases) cases"
        )
        #expect(
            completedBodies == cases,
            "\(cases - completedBodies) of \(cases) cases did not reach the end of the body"
        )
        #expect(
            executedCases == cases,
            "\(cases - executedCases) of \(cases) cases did not execute a probe"
        )
        #expect(
            unbuildableInputs == 0,
            "\(unbuildableInputs) described inputs could not be built at all"
        )

        // Counted work. Each case records a baseline, two to six generated advances, and the
        // mandated century, so the floors sit far below what the requested count produces and
        // far enough above zero that a run which built only fixtures fails here.
        #expect(observations >= 4 * cases, "observations of a running session: \(observations)")
        #expect(advances >= 3 * cases, "clock advances delivered: \(advances)")
        #expect(largeAdvances >= cases, "advances of a day or more: \(largeAdvances)")
        #expect(
            casesWithACenturyAdvance == cases,
            "\(cases - casesWithACenturyAdvance) cases never advanced the clock by a century"
        )
        #expect(
            totalAdvancedMilliseconds >= Int64(cases) * 3_153_600_000_000,
            "total virtual time advanced: \(totalAdvancedMilliseconds) ms"
        )
        #expect(
            checkpointsPerformed == observations,
            "every observation must sample the budget; \(checkpointsPerformed) of \(observations) did"
        )
        #expect(
            governorSamples == 2 * observations,
            "every checkpoint names two metrics; \(governorSamples) samples for \(observations) checkpoints"
        )

        // Every absence was measured beside two presences, on every case.
        #expect(
            completionControls == cases,
            "\(cases - completionControls) cases produced no positive-control Evidence Report"
        )
        #expect(
            cancellationControls == cases,
            "\(cases - cancellationControls) cases produced no positive-control cancelled terminal"
        )

        // The substantive half: the inputs were actually varied and both honest progress
        // forms were actually produced.
        #expect(
            observedMagnitudes.count == ClockAdvanceMagnitude.allCases.count + 1,
            "clock magnitudes never delivered: expected all \(ClockAdvanceMagnitude.allCases.count) generated plus the century, saw \(observedMagnitudes.sorted())"
        )
        #expect(
            observedMagnitudes.contains(3_153_600_000_000),
            "the mandated century was never delivered"
        )
        #expect(
            observedProgressForms == ["determinate", "indeterminate"],
            "progress forms never produced: \(Set(["determinate", "indeterminate"]).subtracting(observedProgressForms).sorted())"
        )
        #expect(
            determinateObservations >= 100,
            "observations carrying a measured fraction: \(determinateObservations)"
        )
        #expect(
            indeterminateObservations >= 100,
            "observations carrying an explicit continuing state: \(indeterminateObservations)"
        )
        #expect(
            observedUnmeasuredCauses == indeterminateObservations,
            "\(indeterminateObservations - observedUnmeasuredCauses) indeterminate observations named no cause"
        )
        #expect(
            observedCheckpointStages == Set(AnalysisStage.allCases),
            "stages never checkpointed: \(Set(AnalysisStage.allCases).subtracting(observedCheckpointStages).map(\.rawValue).sorted())"
        )
        #expect(
            observedCheckpointMetrics == Set(TimeoutProbeShape.mainApplicationMetrics),
            "metrics never sampled: \(Set(TimeoutProbeShape.mainApplicationMetrics).subtracting(observedCheckpointMetrics).map(\.rawValue).sorted())"
        )

        // The generated baseline actually varied.
        #expect(seeds.count >= 100, "generated seeds: \(seeds.count)")
        #expect(
            advanceCounts == [2, 3, 4, 5, 6],
            "generated advance counts: \(advanceCounts.sorted())"
        )
        #expect(
            progressShapes == Set(TimeoutProgressShape.allCases.map(\.rawValue)),
            "progress report shapes never generated: \(Set(TimeoutProgressShape.allCases.map(\.rawValue)).subtracting(progressShapes).sorted())"
        )
        #expect(readingSelectors.count >= 100, "generated governor readings: \(readingSelectors.count)")
    }
}
