import DefAIkeDomain
import Foundation
import PropertyBased
import Testing

@testable import DefAIkeApplication

// Design Property 34: progress is honest and derived only from measured work.
//
// The design states it as: for any active Analysis Session and candidate progress
// measurements, an active progress state exists until one terminal transition; it is
// determinate if and only if completed and total are reliable measurements of the same unit,
// total is positive, and completed lies in `0...total`, in which case any displayed
// percentage equals their fraction and is labeled work progress; every other input is
// explicitly indeterminate.
//
// ## What makes this more than a restatement of the code
//
// The prerequisites are a conjunction, so "determinate if and only if all four hold" is
// satisfied trivially by anything that refuses everything, and equally trivially by a test
// that reads its expected answer out of ``DerivedAnalysisProgress``. Two things close that
// gap.
//
// **A reference model written from the requirement text.** ``HonestProgressReference``
// transcribes Requirement 15.2's sentence one clause at a time into
// ``HonestProgressReference/Clause`` and decides determinate-versus-indeterminate from those
// clauses alone. It reads `WorkAmount.reliability` and `WorkAmount.unit` — the public facts
// an adapter reports — and never `WorkAmount.isReliable`,
// `DerivedAnalysisProgress.isDeterminate`, or `UnmeasuredProgressCause`. Production is
// compared against it on generated reports, including hostile ones.
//
// **Each prerequisite is shown to be individually necessary.** Every case builds one
// canonical determinate base from its generated unit, stage, and magnitude, asserts that the
// base really does produce a fraction, and then perturbs exactly one clause of that same
// base nine ways. A perturbation that broke two clauses at once would prove nothing about
// either, so each one is checked against the reference model's *set* of unsatisfied clauses
// and required to have broken exactly the intended one. Two perturbations are honest
// exceptions and are labelled as such where they are built: the zero-total perturbation
// moves completed to zero as well, because leaving a positive completed count above a zero
// total would break the range clause too; and the absent-report perturbation removes both
// amounts at once, because that is what "the stage reported nothing" is.
//
// ## Integer and floating-point exactness
//
// Requirement 15.11's percentage is a count out of one hundred derived from the two measured
// amounts. ``HonestProgressReference/percentOutOfOneHundred(completed:total:)`` computes it
// with `multipliedFullWidth(by: 100)` and `dividingFullWidth`, so `completed * 100` cannot
// overflow `UInt64` and no `Double` is formed. It is the same exact arithmetic
// `DefAIkePresentation`'s `WorkProgressReadout.completedWorkOutOfOneHundred` documents and
// performs, re-derived here from the requirement rather than imported: this test target does
// not depend on that module, and re-deriving it is what lets the two be compared at all.
// `UInt64.max` is in the generated magnitude ladder, so the overflow path is exercised on
// roughly a twelfth of the cases rather than being reasoned about.
//
// Truncation toward zero is asserted as a boundary, not as a rounding preference: every case
// runs a near-completion probe where completed is one unit short of a total of at least one
// hundred, and requires the exact percentage to read `99`. The general statement is asserted
// alongside it — the exact percentage reaches one hundred only when the measured work has.
//
// ## A found defect, measured and not blessed
//
// `AnalysisProgressState.fractionOfWorkCompleted` and `AnalysisWorkPercentage.percent` form
// their value as `Double(completed) / Double(total)`, and that is not the requirement's
// percentage. Two consequences were confirmed by probe before this file was written, and
// both are recorded here rather than asserted as correct, because this task authors a test
// and does not edit production source:
//
//   1. **The `Double` percentage can read one hundred before the work has finished.** Above
//      2^53 the two amounts are no longer exactly representable, so for example
//      `completed = 2^54 - 1, total = 2^54` gives a fraction of exactly `1.0` and a percent
//      of exactly `100.0` while one unit of work remains. The exact percentage reads `99`.
//      The strongest *true* statement is asserted — a total within `Double`'s exactly
//      representable range cannot reach one hundred early, and the boundary at exactly 2^53
//      is generated — and every case counts how many of the deliberately generated
//      above-2^53 near-complete pairs the `Double` path read as one hundred. The count
//      appears in the witness read-out under its own name.
//   2. **The `Double` percentage does not truncate to the exact count.** `29` of `100`
//      units gives `28.999999999999996`, which truncates to `28`. So no arm claims
//      agreement between the two; the arms assert of `percent` only what holds
//      universally, and the exact reference carries the requirement's boundary.
//
// The shipping progress surface is unaffected: `WorkProgressReadout` re-guards the two
// usability conditions and computes its own exact integer, and it is the value a user sees.
// The defect is in the Application module's numeric progress quantity.
//
// The restriction to `Double`'s exactly representable range in
// ``ProgressCaseRun/checkTheDoublePercentageIsNotClaimedToBeExact()`` is load-bearing rather
// than decorative: removing it makes that arm fail on the first case, at
// `completed = UInt64.max - 1` out of `total = UInt64.max`. Anyone fixing the two members
// above can widen the guard to `UInt64.max` and the arm becomes the regression test for the
// fix.
//
// ## No clock, and nothing raced
//
// Requirements 15.2, 15.3, and 15.10 keep elapsed time out of progress and out of terminal
// decisions. Nothing here reads a clock, sleeps, polls, spawns a task, or orders anything by
// time. The derivation under test is a pure value function, so a rendezvous would have
// nothing to gate: the lifecycle window below is a generated ordering of positions, and the
// position index is the only ordering that exists.
//
// ## Every absence is measured beside a presence
//
// On **every** case the canonical base produces a determinate state with a real fraction and
// a real exact percentage, and the near-completion probe produces a second one. So each
// indeterminate assertion is taken beside a determinate result derived through the same
// entry point, and a run that had quietly stopped producing fractions fails the witness
// instead of passing on refusals. The witness additionally requires both units, both
// reliability flags, every magnitude in the ladder, all seven clauses, every named
// unmeasured cause, and both outcomes to have been *produced*.
//
// ## Why no arm throws
//
// `propertyCheck` runs its body under `try?` and discards a thrown error, so a body that
// threw on its first statement would report a passing run in milliseconds with every arm
// skipped. Nothing below rethrows: every fallible construction becomes a recorded value plus
// an `Issue.record`, and the witness counts cases, completed bodies, executed cases,
// derivations, and produced outcomes *outside* the body where an issue is not suppressed.
// `completedBodies == cases` is paired with `cases == requestedCount` and with per-case
// floors, because it passes vacuously as `0 == 0`.
//
// ## What this file does not assert
//
//   * **Property 36 (task 10.12) owns "no unapproved timeout is synthesized."** Nothing here
//     claims anything about deadlines, elapsed time, or a synthesized timeout.
//   * **Property 35 (task 10.11) owns cancellation.** Cancellation appears only as one of the
//     three terminal kinds a generated window may commit. No arm claims anything about
//     cancellation points, hooks, or prevented evidence commits.
//   * **Property 30 owns terminal disjointness and error singularity**, and it is asserted
//     there over generated event schedules against a live coordinator. The terminal side
//     here is deliberately narrow: only that progress and a committed terminal never occupy
//     the same position of one session's window, and that the progress vocabulary cannot
//     express a terminal.
//   * **Property 29 (task 10.8) owns the resource-limit rule**, and **task 10.13** owns the
//     integration matrix.
//   * Presentation is `DefAIkePresentation`'s, and **task 11.2** owns `WorkProgressReadout`.
//     This target does not depend on that module; the exact arithmetic is re-derived here,
//     not imported.
//   * No value here is an approved release input. Every stage, unit, magnitude, reliability
//     flag, error category, and session identifier is synthetic or drawn from the
//     requirements' own closed vocabulary. No budget, tolerance, deadline, baseline, or
//     approved value is fabricated.
//   * `ProgressDerivationTests` already pins each refusal, the percentage label, and
//     repeatability at examples: nine refusal reports at one stage, three range boundaries,
//     three percentages, and a 0...4 by 0...6 sweep of small pairs. This file quantifies the
//     same statements over generated units, magnitudes up to `UInt64.max`, reliability
//     flags, and lifecycle windows, and against an independently written reference model. It
//     duplicates none of those examples.

extension Tag {
    /// Design Property 34.
    ///
    /// Declared here rather than in a shared namespace: each design property owns one file,
    /// and a shared tag namespace would be a merge point between independently written
    /// property files.
    @Tag static var property34HonestMeasuredProgress: Self
}

@Suite(
    "Property 34: Progress is honest and derived only from measured work",
    .tags(.property34HonestMeasuredProgress)
)
struct HonestMeasuredProgressPropertyTests {

    /// The number of generated cases requested.
    ///
    /// Above the library default of 100 because the coverage the witness requires is a
    /// product over ten stages, two units, twelve magnitudes, four range positions, five
    /// presence shapes, and four reliability pairs, and because the free arm's thinnest cell
    /// — a well-formed reliable same-unit pair whose total is zero — is roughly one draw in
    /// a hundred and sixty. Four hundred cases draw two to six free reports each, so that
    /// cell lands in the low tens. Raising the count is the only honest way to reach the
    /// coverage; no assertion is relaxed to fit a smaller run.
    static let generatedCaseCount = 400

    /// **Validates: Requirements 15.1, 15.2, 15.3, 15.11**
    @Test("Determinate only under every prerequisite, and honest otherwise")
    func progressIsHonestAndDerivedOnlyFromMeasuredWork() async {
        let witness = HonestProgressWitness()

        await propertyCheck(
            count: Self.generatedCaseCount,
            input: HonestProgressShape.generator
        ) { shape in
            witness.record(shape)
            guard let run = ProgressCaseRun.execute(shape: shape, witness: witness) else {
                return
            }

            run.checkTheReferenceModelCoversEveryClause()
            run.checkTheCanonicalBaseIsDeterminate()
            run.checkEachPrerequisiteIsIndividuallyNecessary()
            run.checkProductionAgreesWithTheReferenceModel()
            run.checkTheExactPercentageTruncatesTowardZero()
            run.checkTheDoublePercentageIsNotClaimedToBeExact()
            run.checkEveryStateIsMeasuredOrExplicitlyContinuing()
            run.checkProgressIsNotOfferedAlongsideACommittedTerminal()
            run.checkTheQuantityCannotBeReadAsALikelihood()

            witness.recordCompletedBody()
        }

        witness.expectMeasuredRun(requestedCases: Self.generatedCaseCount)
    }
}

// MARK: - The reference model for honest progress

/// When determinate progress is admissible, and what percentage it shows.
///
/// **Written from the requirement text, not from ``DerivedAnalysisProgress``.** Requirement
/// 15.2's sentence is reproduced verbatim in ``requirementProse`` and transcribed one clause
/// at a time into ``Clause``; Requirement 15.3 supplies the "any prerequisite missing or
/// invalid" direction, which is why ``unsatisfiedClauses(of:)`` returns every clause that
/// fails rather than the first. Nothing in this type reads
/// ``DerivedAnalysisProgress/isDeterminate``, ``DerivedAnalysisProgress/unmeasuredCause``,
/// ``UnmeasuredProgressCause``, `WorkAmount.isReliable`, or
/// ``AnalysisProgressState/fractionOfWorkCompleted``. It reads only the two things an
/// adapter reports about an amount — its unit and whether it is vouched for — and the two
/// numbers.
///
/// The arms compare *outcomes*: production's determinate-or-not against
/// ``isDeterminate(_:)``, and production's carried amounts against the report's own.
private enum HonestProgressReference {

    /// Requirement 15.2, quoted so a reader can check the transcription below.
    static let requirementProse = """
        WHEN reliable completed-work and total-work measurements exist for the same measured \
        unit, total work is greater than zero, and completed work is between zero and total \
        work inclusive, THE Result_Presenter SHALL derive determinate progress only from the \
        completed-work and total-work measurements.
        """

    /// Requirement 15.3, which fixes the direction the negative arms measure.
    static let refusalProse = """
        IF any prerequisite for a reliable completion fraction is missing or invalid, THEN \
        THE Result_Presenter SHALL display an explicitly indeterminate \
        Analysis_Progress_State.
        """

    /// One prerequisite from ``requirementProse``.
    ///
    /// Seven clauses, because the sentence's "measurements exist" is two measurements and
    /// its "reliable" is two amounts. The lower half of "between zero and total work
    /// inclusive" needs no clause: an amount is unsigned, so it cannot be below zero, and
    /// ``WorkAmount/init(reportedCount:unit:reliability:)`` refuses a negative framework
    /// count rather than widening it.
    enum Clause: String, Sendable, CaseIterable {
        /// "completed-work ... measurements exist".
        case completedMeasurementExists
        /// "... and total-work measurements exist".
        case totalMeasurementExists
        /// "for the same measured unit".
        case sameMeasuredUnit
        /// "reliable completed-work ... measurements".
        case completedIsReliable
        /// "reliable ... total-work measurements".
        case totalIsReliable
        /// "total work is greater than zero".
        case totalIsPositive
        /// "completed work is between zero and total work inclusive".
        case completedIsWithinTotal
    }

    /// The clauses of ``requirementProse`` that `reported` fails.
    ///
    /// Empty exactly when determinate progress is admissible. The four unit, reliability,
    /// positivity, and range clauses are evaluated only when both amounts exist, because
    /// there is nothing to compare otherwise; the existence clauses carry that case.
    static func unsatisfiedClauses(of reported: ReportedWork?) -> Set<Clause> {
        guard let reported else {
            // No report at all fails both existence clauses. Not an error and not a stall:
            // model load and calibration count nothing a user could see a fraction of.
            return [.completedMeasurementExists, .totalMeasurementExists]
        }
        var unsatisfied: Set<Clause> = []
        if reported.completed == nil { unsatisfied.insert(.completedMeasurementExists) }
        if reported.total == nil { unsatisfied.insert(.totalMeasurementExists) }
        guard let completed = reported.completed, let total = reported.total else {
            return unsatisfied
        }
        if completed.unit != total.unit { unsatisfied.insert(.sameMeasuredUnit) }
        if completed.reliability != .reliable { unsatisfied.insert(.completedIsReliable) }
        if total.reliability != .reliable { unsatisfied.insert(.totalIsReliable) }
        if total.amount == 0 { unsatisfied.insert(.totalIsPositive) }
        if completed.amount > total.amount { unsatisfied.insert(.completedIsWithinTotal) }
        return unsatisfied
    }

    /// Whether the requirement admits determinate progress for `reported`.
    static func isDeterminate(_ reported: ReportedWork?) -> Bool {
        unsatisfiedClauses(of: reported).isEmpty
    }

    /// Requirement 15.11's percentage: measured analysis work counted out of one hundred.
    ///
    /// Exact integer arithmetic, truncated toward zero, and `nil` for a pair the requirement
    /// gives no percentage at all. Three properties are the point:
    ///
    ///   * `completed * 100` overflows `UInt64` for any completed amount above roughly
    ///     1.8e17, so the multiply is taken at full width and the divide consumes both
    ///     words. `UInt64.max` out of `UInt64.max` is therefore an ordinary case rather than
    ///     a trap.
    ///   * No `Double` is formed, so no rounding model and no floating-point comparison
    ///     enters the value.
    ///   * Truncation toward zero means the value reaches one hundred only when
    ///     `completed == total`: `floor(completed * 100 / total) == 100` requires
    ///     `completed * 100 >= total * 100`, and `completed <= total` closes it.
    ///
    /// The guard is the requirement's own usability condition, so an unusable pair yields no
    /// percentage rather than a repaired one, and `dividingFullWidth` cannot trap: the
    /// quotient is at most one hundred and fits.
    static func percentOutOfOneHundred(completed: UInt64, total: UInt64) -> UInt8? {
        guard total > 0, completed <= total else { return nil }
        let scaled = completed.multipliedFullWidth(by: 100)
        let (quotient, _) = total.dividingFullWidth(scaled)
        guard quotient <= 100 else { return nil }
        return UInt8(quotient)
    }

    /// The largest total whose amounts `Double` still represents exactly, `2^53`.
    ///
    /// Not a tolerance and not an approved value: it is the exact boundary of `Double`'s
    /// integer range, and it is the boundary above which the Application module's
    /// `Double`-formed percentage stops agreeing with the requirement's percentage. Used
    /// only to state which half of the range a claim about that value can be made over.
    static let largestExactlyRepresentableTotal: UInt64 = 1 << 53
}

// MARK: - The generated vocabulary

/// One way to perturb a determinate base so that a named prerequisite fails.
///
/// Every case is something an adapter can actually report. The name says which clause the
/// perturbation is meant to break, and every arm checks that it broke exactly that one.
private enum BasePerturbation: String, Sendable, CaseIterable {
    /// The operation does not vouch for its completed count.
    case unreliableCompleted
    /// The operation does not vouch for its total.
    case unreliableTotal
    /// The total counts a different thing from the completed amount.
    case mismatchedTotalUnit
    /// The completed amount counts a different thing from the total.
    case mismatchedCompletedUnit
    /// The total is zero, so there is nothing to divide by.
    case zeroTotal
    /// Completed work exceeds the total, so the pair is not one consistent measurement.
    case completedExceedsTotal
    /// A total arrived with no completed count to compare against it.
    case missingCompleted
    /// Completed work was counted, but the operation does not know the total.
    case missingTotal
    /// The stage reported no measurement at all.
    case nothingReported

    /// The clause this perturbation is meant to break, and nothing else.
    ///
    /// ``nothingReported`` is the one entry that breaks two, because removing the whole
    /// report is removing both measurements. It is kept because Requirement 15.3's "missing"
    /// covers it and the derivation has a dedicated entry point for it.
    var brokenClauses: Set<HonestProgressReference.Clause> {
        switch self {
        case .unreliableCompleted: [.completedIsReliable]
        case .unreliableTotal: [.totalIsReliable]
        case .mismatchedTotalUnit, .mismatchedCompletedUnit: [.sameMeasuredUnit]
        case .zeroTotal: [.totalIsPositive]
        case .completedExceedsTotal: [.completedIsWithinTotal]
        case .missingCompleted: [.completedMeasurementExists]
        case .missingTotal: [.totalMeasurementExists]
        case .nothingReported: [.completedMeasurementExists, .totalMeasurementExists]
        }
    }

    /// The cause the derivation must name, given the base's unit and the other unit.
    ///
    /// Written from the perturbation's own meaning rather than from ``ProgressDerivation``:
    /// the amount this perturbation spoiled is the amount the cause has to name.
    func expectedCause(
        baseUnit: ProgressUnit,
        otherUnit: ProgressUnit
    ) -> UnmeasuredProgressCause {
        switch self {
        case .unreliableCompleted: .unreliableCompletedAmount
        case .unreliableTotal: .unreliableTotalAmount
        case .mismatchedTotalUnit: .unitMismatch(completed: baseUnit, total: otherUnit)
        case .mismatchedCompletedUnit: .unitMismatch(completed: otherUnit, total: baseUnit)
        case .zeroTotal: .totalIsNotPositive
        case .completedExceedsTotal: .completedExceedsTotal
        case .missingCompleted: .completedAmountMissing
        case .missingTotal: .totalAmountMissing
        case .nothingReported: .nothingReported
        }
    }
}

/// Which terminal a generated window commits, when it commits one.
///
/// The three kinds Requirement 15.7 names. Only their *kind* matters here — the payload
/// rules are Property 30's — but a real value of each is built so that "progress is not
/// offered alongside a committed terminal" is measured against actual terminal values rather
/// than against a placeholder.
private enum TerminalKind: String, Sendable, CaseIterable {
    case completed
    case cancelled
    case failed
}

/// What one position of a session's observation window offers.
///
/// Two cases, so a position cannot offer both and cannot offer neither. That shape is the
/// window's, not production's, and the arm that uses it says so.
private enum WindowOffer: Sendable {
    /// Work is active and this is the honest progress derived for it.
    case progress(DerivedAnalysisProgress)

    /// A terminal has been committed, so progress is no longer offered.
    case terminal(SessionTerminalOutcome)
}

/// One position of the window, with the report that produced it.
private struct WindowPosition: Sendable {
    let index: Int

    /// The report delivered at this position, or `nil` once the terminal stands.
    let reported: ReportedWork?

    /// Whether `reported` was genuinely absent rather than "there was no active work here".
    let isActive: Bool

    let offer: WindowOffer
}

// MARK: - Generated shape

/// Everything one generated case decides, as plain data.
///
/// The generator produces integers only. Every amount, unit, stage, reliability flag, and
/// terminal is built from them inside the run, where a construction that unexpectedly fails
/// is recorded as an issue rather than thrown.
///
/// ## How the baseline varies
///
///   * the **magnitude** of the base total, over a twelve-entry ladder that reaches
///     `UInt64.max` and brackets `Double`'s exact integer boundary at `2^53 - 1`, `2^53`,
///     and `2^53 + 1`;
///   * the base's **unit**, over both, and its **stage**, over all ten;
///   * where the base's completed amount sits **in range**, over none, middle, and all;
///   * the **length** of the observation window, over two to six positions;
///   * each free position's stage, both units independently, both reliability flags
///     independently, which amounts are **present**, its magnitude, and its range position —
///     including the two unusable shapes, a zero total and a completed amount above the
///     total; and
///   * which **terminal** the window commits and at which position, including a window that
///     commits none at all because the work is still active when observation stops.
///
/// One selector decides one free position. Its range is 41600 = 10 x 2 x 2 x 2 x 2 x 5 x 13
/// x 4, a multiple of every modulus it is reduced by, and each field reads a different digit,
/// so the eight choices are uniform and independent of one another. The base selector's range
/// is 1040 = 10 x 2 x 13 x 4 on the same principle, and the terminal selector's is
/// 1260 = 3 x 420, where 420 is the least common multiple of every window length plus one, so
/// the terminal's position is uniform for every generated length.
private struct HonestProgressShape: Sendable, CustomStringConvertible {

    /// Selector range for one free position. See the note above on why this exact size.
    static let positionSelectorBound = 41_599

    /// Selector range for the canonical base.
    static let baseSelectorBound = 1_039

    /// Selector range for the terminal kind and its position.
    static let terminalSelectorBound = 1_259

    /// Magnitudes the base and free totals are drawn from.
    ///
    /// Chosen rather than uniform, because the interesting magnitudes are not uniformly
    /// distributed: zero is the only way the positivity clause can fail, one and two make
    /// the truncation floor visible, `2^53 - 1`, `2^53`, and `2^53 + 1` bracket `Double`'s
    /// exact integer boundary, and `UInt64.max` is where `completed * 100` overflows a single
    /// word — above `UInt64.max / 100` the naive multiply traps or wraps, which is what the
    /// full-width arithmetic exists for. All are synthetic work counts; none is an approved
    /// limit.
    static let magnitudeLadder: [UInt64] = [
        0,
        1,
        2,
        3,
        7,
        100,
        4_096,
        1_000_000,
        1 << 32,
        (1 << 53) - 1,
        1 << 53,
        (1 << 53) + 1,
        .max,
    ]

    /// Drives synthetic identifiers, so a case's terminal payload varies.
    let seed: Int

    /// Decides the canonical determinate base.
    let baseSelector: Int

    /// One selector per free position, in window order.
    let positionSelectors: [Int]

    /// Decides the terminal kind and where it lands.
    let terminalSelector: Int

    // MARK: Derived

    var baseStage: AnalysisStage {
        AnalysisStage.allCases[baseSelector % AnalysisStage.allCases.count]
    }

    var baseUnit: ProgressUnit {
        ProgressUnit.allCases[(baseSelector / 10) % ProgressUnit.allCases.count]
    }

    /// The other unit, so a mismatch is always a real disagreement.
    var otherUnit: ProgressUnit {
        ProgressUnit.allCases.first { $0 != baseUnit } ?? baseUnit
    }

    var baseMagnitudeIndex: Int { (baseSelector / 20) % Self.magnitudeLadder.count }

    /// The magnitude this case's base was drawn from, before the positivity floor.
    var baseMagnitude: UInt64 { Self.magnitudeLadder[baseMagnitudeIndex] }

    /// The base's total, forced positive.
    ///
    /// The ladder's zero entry is the free arm's and the zero-total perturbation's business.
    /// The base has to be determinate for every perturbation of it to mean anything, so its
    /// total is at least one.
    var baseTotal: UInt64 { max(1, Self.magnitudeLadder[baseMagnitudeIndex]) }

    /// Where the base's completed amount sits inside `0...total`. Never above it.
    var baseCompleted: UInt64 {
        switch (baseSelector / 260) % 4 {
        case 0: 0
        case 1: baseTotal / 2
        case 2: baseTotal - (baseTotal / 2)
        default: baseTotal
        }
    }

    var windowLength: Int { positionSelectors.count }

    var terminalKind: TerminalKind {
        TerminalKind.allCases[terminalSelector % TerminalKind.allCases.count]
    }

    /// Where the terminal lands, or `windowLength` when the work is still active at the end.
    var terminalPosition: Int { (terminalSelector / 3) % (windowLength + 1) }

    var commitsATerminal: Bool { terminalPosition < windowLength }

    /// A synthetic error category for a failed terminal.
    var failedCategory: AnalysisError {
        AnalysisError.allCases[seed % AnalysisError.allCases.count]
    }

    /// A synthetic stage for a failed terminal.
    var failedStage: AnalysisStage {
        AnalysisStage.allCases[(seed / 10) % AnalysisStage.allCases.count]
    }

    /// The report one free position delivers.
    func freeReport(at index: Int) -> ReportedWork? {
        let selector = positionSelectors[index]
        let completedUnit = ProgressUnit.allCases[(selector / 10) % 2]
        let totalUnit = ProgressUnit.allCases[(selector / 20) % 2]
        let completedReliability = WorkMeasurementReliability.allCases[(selector / 40) % 2]
        let totalReliability = WorkMeasurementReliability.allCases[(selector / 80) % 2]
        let presence = (selector / 160) % 5
        let total = Self.magnitudeLadder[(selector / 800) % Self.magnitudeLadder.count]
        let rangePosition = (selector / 10_400) % 4
        let completed = Self.completedAmount(total: total, position: rangePosition)

        // Three of the five presence values keep both amounts, so a well-formed pair is the
        // common shape and the refusals below are reached by spoiling a specific clause
        // rather than by an absent report most of the time.
        let completedAmount = WorkAmount(
            amount: completed,
            unit: completedUnit,
            reliability: completedReliability
        )
        let totalAmount = WorkAmount(
            amount: Self.adjustedTotal(total: total, position: rangePosition),
            unit: totalUnit,
            reliability: totalReliability
        )
        switch presence {
        case 3: return ReportedWork(completed: nil, total: totalAmount)
        case 4: return ReportedWork(completed: completedAmount, total: nil)
        default: return ReportedWork(completed: completedAmount, total: totalAmount)
        }
    }

    /// Where a completed amount sits relative to `total`.
    ///
    /// Position 3 puts it above the total. At the very top of the range there is no amount
    /// above `UInt64.max`, so ``adjustedTotal(total:position:)`` lowers the total by one
    /// instead. That keeps positivity, both units, and both reliability flags intact, so the
    /// pair still fails the range clause and only the range clause.
    static func completedAmount(total: UInt64, position: Int) -> UInt64 {
        switch position {
        case 0: return 0
        case 1: return total / 2
        case 2: return total
        default:
            return total == .max ? .max : total + 1
        }
    }

    static func adjustedTotal(total: UInt64, position: Int) -> UInt64 {
        guard position == 3, total == .max else { return total }
        return .max - 1
    }

    var description: String {
        """
        seed \(seed), base \(baseCompleted)/\(baseTotal) \(baseUnit.rawValue) \
        at \(baseStage.rawValue), window \(windowLength) positions, \
        terminal \(terminalKind.rawValue) at \(terminalPosition)
        """
    }

    static var generator: Generator<HonestProgressShape, AnySequence<Any>> {
        zip(
            Gen.int(in: 0...9_999),
            Gen.int(in: 0...baseSelectorBound),
            Gen.int(in: 0...positionSelectorBound).array(of: 2...6),
            Gen.int(in: 0...terminalSelectorBound)
        )
        .map { seed, base, positions, terminal in
            HonestProgressShape(
                seed: seed,
                baseSelector: base,
                positionSelectors: positions,
                terminalSelector: terminal
            )
        }
        .eraseToAny()
    }
}

// MARK: - One perturbed report

/// A perturbation of the canonical base, and what it is meant to have broken.
private struct PerturbedReport: Sendable {
    let perturbation: BasePerturbation
    let reported: ReportedWork?
    let derived: DerivedAnalysisProgress
    let unsatisfiedByTheRequirement: Set<HonestProgressReference.Clause>
}

/// One free position's report and both verdicts on it.
private struct FreeObservation: Sendable {
    let index: Int
    let stage: AnalysisStage
    let reported: ReportedWork?
    let derived: DerivedAnalysisProgress
    let unsatisfiedByTheRequirement: Set<HonestProgressReference.Clause>

    /// The requirement's percentage for this report, or `nil` when it admits none.
    let referencePercent: UInt8?
}

/// The near-completion probe: one unit of measured work short of finishing.
private struct NearCompletionProbe: Sendable {
    let total: UInt64
    let completed: UInt64
    let derived: DerivedAnalysisProgress
    let referencePercent: UInt8?

    /// The same total with the work finished, so the boundary has both sides.
    let finishedDerived: DerivedAnalysisProgress
    let finishedReferencePercent: UInt8?

    /// Whether `Double`'s exact integer range still covers this total.
    var isWithinExactDoubleRange: Bool {
        total <= HonestProgressReference.largestExactlyRepresentableTotal
    }
}

// MARK: - One executed case

/// Everything one generated case produced, and the arms over it.
private struct ProgressCaseRun: Sendable {
    let shape: HonestProgressShape

    /// The canonical determinate base every negative arm is measured against.
    let base: ReportedWork
    let baseDerived: DerivedAnalysisProgress
    let baseReferencePercent: UInt8?

    /// One entry per perturbation, in ``BasePerturbation/allCases`` order.
    let perturbed: [PerturbedReport]

    /// One entry per free window position.
    let free: [FreeObservation]

    /// The near-completion probe at this case's magnitude, and a second one deliberately
    /// above `Double`'s exact integer range.
    let nearCompletion: NearCompletionProbe
    let nearCompletionAboveExactRange: NearCompletionProbe

    /// The window: active positions offer progress, positions from the terminal on do not.
    let window: [WindowPosition]

    /// The terminal this window committed, or `nil` when work was still active at the end.
    let committedTerminal: SessionTerminalOutcome?

    static func execute(
        shape: HonestProgressShape,
        witness: HonestProgressWitness
    ) -> ProgressCaseRun? {
        let unit = shape.baseUnit
        let base = ReportedWork(
            completed: WorkAmount(
                amount: shape.baseCompleted,
                unit: unit,
                reliability: .reliable
            ),
            total: WorkAmount(amount: shape.baseTotal, unit: unit, reliability: .reliable)
        )
        let baseDerived = DerivedAnalysisProgress(reported: base, at: shape.baseStage)

        let perturbed = BasePerturbation.allCases.map { perturbation in
            let reported = Self.perturb(base, by: perturbation, shape: shape)
            return PerturbedReport(
                perturbation: perturbation,
                reported: reported,
                derived: DerivedAnalysisProgress(reported: reported, at: shape.baseStage),
                unsatisfiedByTheRequirement:
                    HonestProgressReference.unsatisfiedClauses(of: reported)
            )
        }

        let free = (0..<shape.windowLength).map { index -> FreeObservation in
            let selector = shape.positionSelectors[index]
            let stage = AnalysisStage.allCases[selector % AnalysisStage.allCases.count]
            let reported = shape.freeReport(at: index)
            return FreeObservation(
                index: index,
                stage: stage,
                reported: reported,
                derived: DerivedAnalysisProgress(reported: reported, at: stage),
                unsatisfiedByTheRequirement:
                    HonestProgressReference.unsatisfiedClauses(of: reported),
                referencePercent: Self.referencePercent(of: reported)
            )
        }

        let probeTotal = max(100, shape.baseTotal)
        // `UInt64.max` on purpose: it is above `Double`'s exact integer range, so the
        // divergence below is measured at the widest magnitude, and its completed amount is
        // far above `UInt64.max / 100`, so the exact percentage's full-width multiply is the
        // only way to compute the value without wrapping.
        let aboveExactRangeTotal = UInt64.max
        guard
            let nearCompletion = Self.nearCompletionProbe(
                total: probeTotal,
                unit: unit,
                stage: shape.baseStage
            ),
            let nearCompletionAboveExactRange = Self.nearCompletionProbe(
                total: aboveExactRangeTotal,
                unit: unit,
                stage: shape.baseStage
            ),
            let terminal = Self.terminal(shape: shape)
        else {
            // Never a finding about production: every input here is built from generated
            // integers inside validated ranges, so a refusal is a defect in this file. It is
            // recorded and counted so a run whose inputs quietly stopped being buildable
            // fails outside the body rather than shrinking its own coverage.
            Issue.record("the described progress inputs must all be buildable: \(shape)")
            witness.recordUnbuildableInput()
            return nil
        }

        var window: [WindowPosition] = []
        for observation in free {
            if observation.index < shape.terminalPosition {
                window.append(
                    WindowPosition(
                        index: observation.index,
                        reported: observation.reported,
                        isActive: true,
                        offer: .progress(observation.derived)
                    )
                )
            } else {
                window.append(
                    WindowPosition(
                        index: observation.index,
                        reported: nil,
                        isActive: false,
                        offer: .terminal(terminal)
                    )
                )
            }
        }

        let run = ProgressCaseRun(
            shape: shape,
            base: base,
            baseDerived: baseDerived,
            baseReferencePercent: HonestProgressReference.percentOutOfOneHundred(
                completed: shape.baseCompleted,
                total: shape.baseTotal
            ),
            perturbed: perturbed,
            free: free,
            nearCompletion: nearCompletion,
            nearCompletionAboveExactRange: nearCompletionAboveExactRange,
            window: window,
            committedTerminal: shape.commitsATerminal ? terminal : nil
        )
        witness.recordExecutedCase(run)
        return run
    }

    /// The requirement's percentage for a whole report, or `nil` when it admits none.
    private static func referencePercent(of reported: ReportedWork?) -> UInt8? {
        guard HonestProgressReference.isDeterminate(reported),
              let completed = reported?.completed,
              let total = reported?.total
        else { return nil }
        return HonestProgressReference.percentOutOfOneHundred(
            completed: completed.amount,
            total: total.amount
        )
    }

    /// One unit of measured work short of finishing, and the finished pair beside it.
    private static func nearCompletionProbe(
        total: UInt64,
        unit: ProgressUnit,
        stage: AnalysisStage
    ) -> NearCompletionProbe? {
        guard total >= 100 else { return nil }
        let completed = total - 1
        let almost = ReportedWork(
            completed: WorkAmount(amount: completed, unit: unit, reliability: .reliable),
            total: WorkAmount(amount: total, unit: unit, reliability: .reliable)
        )
        let finished = ReportedWork(
            completed: WorkAmount(amount: total, unit: unit, reliability: .reliable),
            total: WorkAmount(amount: total, unit: unit, reliability: .reliable)
        )
        return NearCompletionProbe(
            total: total,
            completed: completed,
            derived: DerivedAnalysisProgress(reported: almost, at: stage),
            referencePercent: HonestProgressReference.percentOutOfOneHundred(
                completed: completed,
                total: total
            ),
            finishedDerived: DerivedAnalysisProgress(reported: finished, at: stage),
            finishedReferencePercent: HonestProgressReference.percentOutOfOneHundred(
                completed: total,
                total: total
            )
        )
    }

    /// A real terminal value of the generated kind.
    ///
    /// **Synthetic.** The Evidence Report, the session identity, and the error category are
    /// synthetic values from the requirements' closed vocabularies; no arm claims their
    /// content is correct. Their only role is to be actual terminal values so that "progress
    /// is not offered alongside a committed terminal" is measured against one rather than
    /// against a placeholder.
    private static func terminal(shape: HonestProgressShape) -> SessionTerminalOutcome? {
        switch shape.terminalKind {
        case .cancelled:
            return .cancelled
        case .completed:
            guard let report = EvidenceReport(
                binding: SessionSample.binding(),
                pixel: PixelEvidence.allCases[shape.seed % PixelEvidence.allCases.count],
                provenance: .unavailable(.validatorNotCompiledIntoRelease),
                combinedSummary: nil,
                apparentInconsistency: nil,
                bytePreservationStatus: .unknown,
                inputQuality: SessionSample.inputQuality,
                onDeviceProcessing: true,
                scope: SessionSample.scope
            ) else { return nil }
            return .completed(report)
        case .failed:
            guard let snapshot = AnalysisFailureSnapshot(
                sessionID: SessionSample.binding().sessionID,
                error: shape.failedCategory,
                stage: shape.failedStage,
                bytePreservationStatus: nil,
                inputQuality: nil
            ) else { return nil }
            return .failed(snapshot)
        }
    }

    /// Applies exactly one perturbation to the canonical base.
    private static func perturb(
        _ base: ReportedWork,
        by perturbation: BasePerturbation,
        shape: HonestProgressShape
    ) -> ReportedWork? {
        guard let completed = base.completed, let total = base.total else { return nil }
        switch perturbation {
        case .unreliableCompleted:
            return ReportedWork(
                completed: WorkAmount(
                    amount: completed.amount,
                    unit: completed.unit,
                    reliability: .unreliable
                ),
                total: total
            )
        case .unreliableTotal:
            return ReportedWork(
                completed: completed,
                total: WorkAmount(
                    amount: total.amount,
                    unit: total.unit,
                    reliability: .unreliable
                )
            )
        case .mismatchedTotalUnit:
            return ReportedWork(
                completed: completed,
                total: WorkAmount(
                    amount: total.amount,
                    unit: shape.otherUnit,
                    reliability: total.reliability
                )
            )
        case .mismatchedCompletedUnit:
            return ReportedWork(
                completed: WorkAmount(
                    amount: completed.amount,
                    unit: shape.otherUnit,
                    reliability: completed.reliability
                ),
                total: total
            )
        case .zeroTotal:
            // Completed moves to zero as well, and that is the honest way to isolate the
            // positivity clause: leaving a positive completed count above a zero total would
            // break the range clause at the same time and the arm would prove nothing about
            // either. Zero out of zero fails positivity alone.
            return ReportedWork(
                completed: WorkAmount(amount: 0, unit: completed.unit, reliability: .reliable),
                total: WorkAmount(amount: 0, unit: total.unit, reliability: .reliable)
            )
        case .completedExceedsTotal:
            // At the top of the range there is no amount above `UInt64.max`, so the total is
            // lowered by one instead of raising completed. Positivity, both units, and both
            // reliability flags survive either way, so the range clause is still the only
            // one that fails.
            if total.amount == .max {
                return ReportedWork(
                    completed: WorkAmount(
                        amount: .max,
                        unit: completed.unit,
                        reliability: .reliable
                    ),
                    total: WorkAmount(
                        amount: .max - 1,
                        unit: total.unit,
                        reliability: .reliable
                    )
                )
            }
            return ReportedWork(
                completed: WorkAmount(
                    amount: total.amount + 1,
                    unit: completed.unit,
                    reliability: .reliable
                ),
                total: total
            )
        case .missingCompleted:
            return ReportedWork(completed: nil, total: total)
        case .missingTotal:
            return ReportedWork(completed: completed, total: nil)
        case .nothingReported:
            return nil
        }
    }

    // MARK: Arms

    /// The reference model names every clause of the requirement it transcribes.
    ///
    /// Without this, a clause dropped from ``HonestProgressReference/Clause`` would silently
    /// stop being checked and every perturbation targeting it would agree with production by
    /// having nothing to say.
    func checkTheReferenceModelCoversEveryClause() {
        let brokenByAPerturbation = Set(
            BasePerturbation.allCases.flatMap(\.brokenClauses)
        )
        #expect(
            brokenByAPerturbation == Set(HonestProgressReference.Clause.allCases),
            """
            every transcribed clause must have a perturbation that breaks it: missing \
            \(Set(HonestProgressReference.Clause.allCases).subtracting(brokenByAPerturbation).map(\.rawValue).sorted())
            """
        )
        #expect(
            HonestProgressReference.requirementProse.contains("greater than zero"),
            "the transcribed requirement text must still contain the positivity clause"
        )
        #expect(
            HonestProgressReference.refusalProse.contains("indeterminate"),
            "the transcribed refusal text must still name the indeterminate state"
        )
    }

    /// The base every negative arm is measured against really is determinate.
    ///
    /// This is the positive control, and it runs on every case. Without it the nine
    /// perturbations below would all be indeterminate results taken beside nothing, and a
    /// derivation that had started refusing everything would satisfy them all.
    func checkTheCanonicalBaseIsDeterminate() {
        #expect(
            HonestProgressReference.isDeterminate(base),
            "the canonical base must satisfy every clause: \(shape)"
        )
        #expect(
            baseDerived.state == .determinate(
                completed: shape.baseCompleted,
                total: shape.baseTotal,
                unit: shape.baseUnit,
                stage: shape.baseStage
            ),
            "the base must derive the amounts it reported, unaltered: \(shape)"
        )
        #expect(baseDerived.isDeterminate, "base determinate: \(shape)")
        #expect(baseDerived.unmeasuredCause == nil, "base cause: \(shape)")
        #expect(
            baseDerived.indeterminateAssertion == nil,
            "a determinate state must assert nothing about continuation: \(shape)"
        )

        // A real fraction and a real exact percentage, not merely a determinate case label.
        guard let fraction = baseDerived.fractionOfWorkCompleted else {
            Issue.record("a determinate base must yield a fraction: \(shape)")
            return
        }
        #expect(fraction.isFinite, "the fraction must be finite: \(shape)")
        #expect(fraction >= 0 && fraction <= 1, "fraction \(fraction) outside 0...1: \(shape)")
        // Zero is a measurement, not a fallback: a determinate state reads zero exactly when
        // no work has been done, never because the measurement was unusable.
        #expect(
            (fraction == 0) == (shape.baseCompleted == 0),
            "fraction \(fraction) read zero for completed \(shape.baseCompleted): \(shape)"
        )
        guard let referencePercent = baseReferencePercent else {
            Issue.record("the requirement admits a percentage for the base: \(shape)")
            return
        }
        #expect(referencePercent <= 100, "reference percent \(referencePercent): \(shape)")
        #expect(
            baseDerived.percentage != nil,
            "a determinate base must yield a percentage: \(shape)"
        )
    }

    /// Each prerequisite alone is enough to force indeterminate progress.
    ///
    /// The prerequisites are a conjunction, so the substance is exactly this: nine
    /// perturbations of one determinate base, each breaking a single named clause, each
    /// required to refuse. The reference model's set of unsatisfied clauses is compared
    /// against the perturbation's declared target, so a perturbation that had drifted into
    /// breaking two clauses fails here instead of appearing to prove something about one.
    func checkEachPrerequisiteIsIndividuallyNecessary() {
        for entry in perturbed {
            let label = "\(entry.perturbation.rawValue) of \(shape)"
            #expect(
                entry.unsatisfiedByTheRequirement == entry.perturbation.brokenClauses,
                """
                \(label): the perturbation must break exactly \
                \(entry.perturbation.brokenClauses.map(\.rawValue).sorted()), broke \
                \(entry.unsatisfiedByTheRequirement.map(\.rawValue).sorted())
                """
            )
            #expect(
                HonestProgressReference.isDeterminate(entry.reported) == false,
                "\(label): the requirement must refuse a fraction"
            )
            #expect(
                entry.derived.state == .indeterminate(stage: shape.baseStage),
                "\(label): the derivation must be explicitly indeterminate"
            )
            #expect(
                entry.derived.isDeterminate == false,
                "\(label): no fraction may be claimed"
            )
            #expect(
                entry.derived.fractionOfWorkCompleted == nil,
                "\(label): no fraction may be projected"
            )
            // Absent rather than zero: "0%" is a claim that no work is done, which is a
            // different statement from "this work is not measurable".
            #expect(
                entry.derived.percentage == nil,
                "\(label): no percentage may be shown"
            )
            #expect(
                entry.derived.unmeasuredCause
                    == entry.perturbation.expectedCause(
                        baseUnit: shape.baseUnit,
                        otherUnit: shape.otherUnit
                    ),
                """
                \(label): the named cause must be the spoiled amount's, got \
                \(String(describing: entry.derived.unmeasuredCause))
                """
            )
            #expect(
                entry.derived.indeterminateAssertion == .analysisIsContinuing,
                "\(label): a refused fraction must say the analysis is continuing"
            )
            #expect(
                entry.derived.stage == shape.baseStage,
                "\(label): a refusal must still describe the stage it was asked about"
            )
        }
    }

    /// Production's verdict is the requirement's verdict, on every generated report.
    ///
    /// The comparison is the substance of the property: the expected answer comes from
    /// ``HonestProgressReference``, which was written from Requirement 15.2's sentence, and
    /// not from ``DerivedAnalysisProgress``. Hostile shapes are generated deliberately —
    /// mixed units, unreliable amounts, zero totals, completed amounts above their total,
    /// and half-present reports — so agreement is measured over the cases where the two
    /// could differ.
    func checkProductionAgreesWithTheReferenceModel() {
        for observation in free {
            let label = "position \(observation.index) of \(shape)"
            let admitted = observation.unsatisfiedByTheRequirement.isEmpty
            #expect(
                observation.derived.isDeterminate == admitted,
                """
                \(label): the requirement \(admitted ? "admits" : "refuses") a fraction but \
                the derivation \(observation.derived.isDeterminate ? "produced" : "refused") \
                one; unsatisfied \
                \(observation.unsatisfiedByTheRequirement.map(\.rawValue).sorted())
                """
            )
            #expect(
                (observation.derived.unmeasuredCause == nil) == admitted,
                "\(label): a cause must be named exactly when the fraction is refused"
            )

            guard admitted else {
                #expect(
                    observation.derived.state == .indeterminate(stage: observation.stage),
                    "\(label): a refused report must be explicitly indeterminate"
                )
                #expect(
                    observation.referencePercent == nil,
                    "\(label): the requirement admits no percentage for a refused report"
                )
                continue
            }

            // Determinate: the state must carry the report's own amounts, unaltered. Nothing
            // is clamped, rounded, rescaled, or substituted, because every repair would
            // produce a fraction the work never measured.
            guard case let .determinate(completed, total, unit, stage) = observation.derived.state
            else {
                Issue.record("\(label): an admitted report must derive a determinate state")
                continue
            }
            #expect(completed == observation.reported?.completed?.amount, "\(label): completed")
            #expect(total == observation.reported?.total?.amount, "\(label): total")
            #expect(unit == observation.reported?.completed?.unit, "\(label): unit")
            #expect(stage == observation.stage, "\(label): stage")
            #expect(
                observation.derived.fractionOfWorkCompleted != nil,
                "\(label): a determinate state must yield a usable fraction"
            )
            #expect(
                observation.referencePercent != nil,
                "\(label): the requirement admits a percentage for an admitted report"
            )
        }
    }

    /// The requirement's percentage truncates toward zero and reaches one hundred only when
    /// the measured work has.
    ///
    /// Asserted at the boundary rather than argued: the probe is one unit of measured work
    /// short of a total of at least one hundred, so the exact count reads `99` and the
    /// finished pair beside it reads `100`. A rounding-to-nearest implementation would read
    /// `100` on the first and pass a same-value comparison against itself, which is why the
    /// value is checked against the literal boundary and against the finished pair.
    func checkTheExactPercentageTruncatesTowardZero() {
        for probe in [nearCompletion, nearCompletionAboveExactRange] {
            let label = "near-completion at total \(probe.total) of \(shape)"
            #expect(
                probe.referencePercent == 99,
                """
                \(label): one unit short of \(probe.total) must read 99, read \
                \(String(describing: probe.referencePercent))
                """
            )
            #expect(
                probe.finishedReferencePercent == 100,
                """
                \(label): finished work must read 100, read \
                \(String(describing: probe.finishedReferencePercent))
                """
            )
            #expect(
                probe.derived.isDeterminate,
                "\(label): a near-complete reliable pair is a usable measurement"
            )
            #expect(
                probe.finishedDerived.isDeterminate,
                "\(label): a finished reliable pair is a usable measurement"
            )
        }

        // The general statement, over every determinate result this case produced: the exact
        // count reaches one hundred only when the two measured amounts are equal, and it is
        // at most 99 while any work remains.
        var usablePairs: [(UInt64, UInt64)] = [
            (shape.baseCompleted, shape.baseTotal),
            (nearCompletion.completed, nearCompletion.total),
            (nearCompletion.total, nearCompletion.total),
            (nearCompletionAboveExactRange.completed, nearCompletionAboveExactRange.total),
        ]
        for observation in free where observation.unsatisfiedByTheRequirement.isEmpty {
            if let completed = observation.reported?.completed?.amount,
               let total = observation.reported?.total?.amount {
                usablePairs.append((completed, total))
            }
        }
        for (completed, total) in usablePairs {
            guard let percent = HonestProgressReference.percentOutOfOneHundred(
                completed: completed,
                total: total
            ) else {
                Issue.record("the requirement admits a percentage for \(completed)/\(total)")
                continue
            }
            #expect(
                (percent == 100) == (completed == total),
                """
                \(completed)/\(total) read \(percent) out of one hundred: the count reaches \
                one hundred only when the measured work has
                """
            )
            #expect(
                completed == total || percent <= 99,
                "\(completed)/\(total) read \(percent) while work remained"
            )
            // A zero count means strictly under one hundredth of the work, and nothing else.
            // Compared at full width so the check itself cannot wrap where the value it is
            // checking would have.
            let scaled = completed.multipliedFullWidth(by: 100)
            let isUnderOneHundredth = scaled.high == 0 && scaled.low < total
            #expect(
                (percent == 0) == isUnderOneHundredth,
                "\(completed)/\(total) read \(percent): a zero count means under one hundredth"
            )
        }
    }

    /// What the Application module's `Double` percentage may be claimed to be.
    ///
    /// Only universally true statements are asserted here. Two things that a reader might
    /// expect are deliberately *not* asserted, because probing showed they are false of the
    /// current implementation, and this task authors a test rather than editing production
    /// source:
    ///
    ///   * `AnalysisWorkPercentage.percent` does not truncate to the requirement's count.
    ///     `29` of `100` gives `28.999999999999996`.
    ///   * Above `Double`'s exact integer range it can read exactly `100.0` while work
    ///     remains: `2^54 - 1` of `2^54` is one unit short and reads one hundred, where the
    ///     exact count reads `99`.
    ///
    /// The strongest true form of the boundary claim *is* asserted — a total inside
    /// `Double`'s exact integer range cannot reach one hundred early, and the boundary at
    /// exactly `2^53` is generated — and the above-range divergence is counted by name in
    /// the witness read-out so that it is reported rather than blessed.
    func checkTheDoublePercentageIsNotClaimedToBeExact() {
        var determinateStates: [(DerivedAnalysisProgress, UInt64, UInt64)] = [
            (baseDerived, shape.baseCompleted, shape.baseTotal),
            (nearCompletion.derived, nearCompletion.completed, nearCompletion.total),
            (nearCompletion.finishedDerived, nearCompletion.total, nearCompletion.total),
            (
                nearCompletionAboveExactRange.derived,
                nearCompletionAboveExactRange.completed,
                nearCompletionAboveExactRange.total
            ),
        ]
        for observation in free where observation.unsatisfiedByTheRequirement.isEmpty {
            if let completed = observation.reported?.completed?.amount,
               let total = observation.reported?.total?.amount {
                determinateStates.append((observation.derived, completed, total))
            }
        }

        for (derived, completed, total) in determinateStates {
            guard let percentage = derived.percentage else {
                Issue.record("a determinate state must carry a percentage: \(completed)/\(total)")
                continue
            }
            let percent = percentage.percent
            // Nonfinite values are inspected with `isFinite`, never with arithmetic: a
            // comparison against a `NaN` is false in both directions and would pass silently.
            #expect(percent.isFinite, "percent for \(completed)/\(total) is not finite")
            #expect(!percent.isNaN, "percent for \(completed)/\(total) is NaN")
            #expect(
                percent >= 0 && percent <= 100,
                "percent \(percent) for \(completed)/\(total) outside 0...100"
            )
            #expect(
                (percent == 0) == (completed == 0),
                "percent \(percent) read zero for completed \(completed)"
            )
            #expect(
                percentage.unit == derived.state.determinateUnitForTesting,
                "the percentage must carry the measured unit"
            )
            #expect(
                percentage.stage == derived.stage,
                "the percentage must carry the stage it describes"
            )
            if total <= HonestProgressReference.largestExactlyRepresentableTotal {
                #expect(
                    (percent == 100) == (completed == total),
                    """
                    \(completed)/\(total) is inside Double's exact integer range, so a \
                    percent of \(percent) must reach one hundred only when the work has
                    """
                )
            }
        }
    }

    /// An active session always has something honest to show, and it is never a terminal.
    ///
    /// Requirement 15.1 asks that an active state be displayed for the whole of active work.
    /// ``DerivedAnalysisProgress`` is total over every report by construction — its
    /// initializer is not failable and accepts an absent report — so what is *measured* here
    /// is the rest of the claim, over every generated state including the hostile ones: the
    /// state is exactly one of a measured readout or an explicit continuation assertion,
    /// never both and never neither; the assertion is present exactly when there is no
    /// fraction; and the assertion vocabulary cannot say stalled, completed, or failed,
    /// because those are terminals the session commits and one case is all that exists.
    func checkEveryStateIsMeasuredOrExplicitlyContinuing() {
        var states = [baseDerived, nearCompletion.derived, nearCompletion.finishedDerived]
        states.append(contentsOf: perturbed.map(\.derived))
        states.append(contentsOf: free.map(\.derived))

        for derived in states {
            let measured = derived.isDeterminate
            let continuing = derived.indeterminateAssertion != nil
            #expect(
                measured != continuing,
                """
                every state must be exactly one of a measurement or a continuation \
                assertion; measured \(measured), continuing \(continuing)
                """
            )
            #expect(
                (derived.fractionOfWorkCompleted != nil) == measured,
                "a fraction must exist exactly when the state is a measurement"
            )
            #expect(
                (derived.percentage != nil) == measured,
                "a percentage must exist exactly when the state is a measurement"
            )
            if continuing {
                #expect(
                    derived.indeterminateAssertion == .analysisIsContinuing,
                    "an unmeasured active state may assert nothing but continuation"
                )
            }
            #expect(
                derived.state.stage == derived.stage,
                "the state and the derivation must name one stage"
            )
        }

        // The vocabulary itself: "stalled", "completed", and "failed" are not expressible as
        // what progress asserts, and none of the progress vocabularies collides with the
        // session's end-reason vocabulary.
        #expect(
            IndeterminateProgressAssertion.allCases == [.analysisIsContinuing],
            """
            an unmeasured state must have exactly one thing to assert, found \
            \(IndeterminateProgressAssertion.allCases.map(\.rawValue).sorted())
            """
        )
        let progressVocabulary = Set(
            IndeterminateProgressAssertion.allCases.map(\.rawValue)
                + ProgressQuantitySemantics.allCases.map(\.rawValue)
                + ProgressUnit.allCases.map(\.rawValue)
        )
        let terminalVocabulary = Set(SessionEndReason.allCases.map(\.rawValue))
        #expect(
            progressVocabulary.isDisjoint(with: terminalVocabulary),
            """
            a progress vocabulary collides with the session's terminal vocabulary: \
            \(progressVocabulary.intersection(terminalVocabulary).sorted())
            """
        )
        for forbidden in ["stalled", "stall", "complete", "finish", "fail", "cancel", "error"] {
            #expect(
                progressVocabulary.allSatisfy { !$0.lowercased().contains(forbidden) },
                "a progress vocabulary can express \"\(forbidden)\": \(progressVocabulary.sorted())"
            )
        }
    }

    /// Progress and a committed terminal never occupy the same position of one window.
    ///
    /// Narrow on purpose. Requirements 15.1 and 15.11 need only that progress is offered
    /// while work is active and is not offered alongside a committed terminal; the rules that
    /// govern the commit itself — one terminal ever, three disjoint kinds, exactly one error,
    /// no evidence in a failure — are Property 30's and are asserted there against a live
    /// coordinator. What is measured here is that the window did not silently degenerate:
    /// the number of positions offering progress is exactly the generated terminal position,
    /// every one of them offered a real derived state, and every position from the terminal
    /// on offered a real terminal value and no progress. The two-case shape of
    /// ``WindowOffer`` is this file's, and it is what makes "never both" structural rather
    /// than asserted.
    func checkProgressIsNotOfferedAlongsideACommittedTerminal() {
        #expect(
            window.count == shape.windowLength,
            "the window must have one position per generated report: \(shape)"
        )

        var progressPositions: Set<Int> = []
        var terminalPositions: Set<Int> = []
        for position in window {
            switch position.offer {
            case let .progress(derived):
                progressPositions.insert(position.index)
                #expect(
                    position.isActive,
                    "position \(position.index) offered progress while not active: \(shape)"
                )
                #expect(
                    derived.isDeterminate || derived.indeterminateAssertion != nil,
                    "position \(position.index) offered neither a measurement nor a continuation"
                )
            case let .terminal(outcome):
                terminalPositions.insert(position.index)
                #expect(
                    position.isActive == false,
                    "position \(position.index) offered a terminal while active: \(shape)"
                )
                #expect(
                    position.reported == nil,
                    "position \(position.index) reported work after a terminal: \(shape)"
                )
                let kinds = [outcome.isCompleted, outcome.isCancelled, outcome.isFailed]
                #expect(
                    kinds.filter { $0 }.count == 1,
                    "the committed terminal must be exactly one kind: \(shape)"
                )
            }
        }

        #expect(
            progressPositions.count == shape.terminalPosition,
            """
            \(progressPositions.count) positions offered progress but the terminal landed at \
            \(shape.terminalPosition): \(shape)
            """
        )
        #expect(
            terminalPositions.count == shape.windowLength - shape.terminalPosition,
            "positions after the terminal: \(terminalPositions.count) of \(shape)"
        )
        #expect(
            progressPositions.isDisjoint(with: terminalPositions),
            "a position offered both progress and a terminal: \(shape)"
        )
        #expect(
            progressPositions.union(terminalPositions).count == shape.windowLength,
            "a position offered neither progress nor a terminal: \(shape)"
        )
        #expect(
            (committedTerminal != nil) == shape.commitsATerminal,
            "the window must commit a terminal exactly when one landed inside it: \(shape)"
        )
        if committedTerminal == nil {
            #expect(
                progressPositions.count == shape.windowLength,
                "a window with no terminal must offer progress throughout: \(shape)"
            )
        }
    }

    /// The percentage is analysis work progress and cannot be read as a result likelihood.
    ///
    /// Requirement 15.11 requires the identification, and Decision D3 forbids presenting any
    /// probability or confidence value including a percentage. The identification is settled
    /// by shape rather than by wording: ``ProgressQuantitySemantics`` has exactly one case,
    /// so "probability", "confidence", "certainty", and "likelihood" are not expressible as
    /// the meaning of the number. The dynamic casts below are the runtime half of the same
    /// claim: a progress value is not orderable against a decision boundary and has no
    /// serialized form to leak through.
    func checkTheQuantityCannotBeReadAsALikelihood() {
        #expect(
            ProgressQuantitySemantics.allCases == [.analysisWorkProgress],
            """
            a progress quantity must have exactly one meaning, found \
            \(ProgressQuantitySemantics.allCases.map(\.rawValue).sorted())
            """
        )
        #expect(AnalysisWorkPercentage.semantics == .analysisWorkProgress)

        guard let percentage = baseDerived.percentage else {
            Issue.record("the positive control must carry a percentage: \(shape)")
            return
        }
        #expect(
            ((percentage as Any) is any Comparable) == false,
            "a work percentage must not be orderable against a decision boundary"
        )
        #expect(
            ((percentage as Any) is any Encodable) == false,
            "a work percentage must have no serialized form to leak through"
        )
        #expect(
            ((baseDerived as Any) is any Encodable) == false,
            "derived progress must have no serialized form to leak through"
        )
        #expect(
            ((baseDerived.state as Any) is any Encodable) == false,
            "a progress state must have no serialized form to leak through"
        )

        // The unit a percentage is counted in is a unit of *work*. A weighted stage count or
        // a bare percent would be an estimate presented as a measurement, and neither is
        // expressible.
        #expect(
            Set(ProgressUnit.allCases.map(\.rawValue)) == ["encodedBytes", "imageRows"],
            """
            the measured work units must stay the two the application counts, found \
            \(ProgressUnit.allCases.map(\.rawValue).sorted())
            """
        )
        for forbidden in [
            "probability", "confidence", "certainty", "likelihood", "chance", "odds",
            "score", "logit", "percent", "step", "stage",
        ] {
            let vocabulary = ProgressUnit.allCases.map(\.rawValue)
                + ProgressQuantitySemantics.allCases.map(\.rawValue)
            #expect(
                vocabulary.allSatisfy { !$0.lowercased().contains(forbidden) },
                "a progress vocabulary can express \"\(forbidden)\": \(vocabulary.sorted())"
            )
        }
    }
}

// MARK: - Reading a determinate unit back

extension AnalysisProgressState {
    /// The unit of a determinate state, for comparison against a percentage's own unit.
    ///
    /// A test-only accessor so that an arm can compare the two without pattern matching at
    /// every use. It reads the case payload and decides nothing.
    fileprivate var determinateUnitForTesting: ProgressUnit? {
        guard case let .determinate(_, _, unit, _) = self else { return nil }
        return unit
    }
}

// MARK: - Non-vacuity witness

/// Counts what the run generated, derived, and produced — outside the property body.
///
/// `propertyCheck` runs its body under `try?` and discards a thrown error, so a body that
/// failed on its first statement would report a passing test in milliseconds with every arm
/// skipped. `completedBodies == cases` alone does not catch that: it passes vacuously as
/// `0 == 0`. The case floor, the per-case counts, and the produced sets are what close the
/// gap, and they live here because an issue recorded outside the body is not suppressed.
///
/// The produced sets are the substantive half. Both units, both reliability flags, every
/// magnitude in the ladder, all seven clauses, every named unmeasured cause, every stage,
/// all three terminal kinds, and both determinate and indeterminate outcomes must have been
/// **produced**, and every case must have produced at least two real fractions — which is
/// what turns each indeterminate assertion into a measurement taken beside a determinate one
/// rather than beside a path that produces nothing.
///
/// The thresholds sit far below what the requested number of uniform draws produces, so they
/// witness variation rather than pinning a distribution.
private final class HonestProgressWitness: @unchecked Sendable {
    private let lock = NSLock()

    // Run shape.
    private var cases = 0
    private var completedBodies = 0
    private var executedCases = 0
    private var unbuildableInputs = 0

    // Counted work.
    private var derivations = 0
    private var determinateResults = 0
    private var indeterminateResults = 0
    private var freeDeterminateResults = 0
    private var freeIndeterminateResults = 0
    private var perturbationsApplied = 0
    private var casesWithTwoOrMoreFractions = 0
    private var overflowingMultiplies = 0

    /// Near-complete pairs above `Double`'s exact integer range whose `Double` percentage
    /// read one hundred while a unit of measured work remained.
    ///
    /// A **reported production divergence**, not a coverage floor and not an approved
    /// behavior. `AnalysisWorkPercentage.percent` forms `Double(completed) / Double(total)`,
    /// which is exactly `1.0` once the two amounts collapse onto one `Double`. The exact
    /// count reads `99` for the same pair. This task may not edit production source, so the
    /// divergence is measured and named here instead of being asserted as correct.
    private var doublePercentagesReadingOneHundredEarly = 0

    /// The same pairs, counted, so the number above is read against its denominator.
    private var aboveExactRangeNearCompletePairs = 0

    // Produced outputs.
    private var producedUnits: Set<ProgressUnit> = []
    private var producedReliabilities: Set<WorkMeasurementReliability> = []
    private var producedStages: Set<AnalysisStage> = []
    private var witnessedClauses: Set<HonestProgressReference.Clause> = []
    private var singlyWitnessedClauses: Set<HonestProgressReference.Clause> = []
    private var producedCauses: Set<String> = []
    private var freeProducedCauses: Set<String> = []
    private var producedTerminalKinds: Set<TerminalKind> = []
    private var producedReferencePercents: Set<UInt8> = []

    // Generated baseline.
    private var seeds: Set<Int> = []
    private var windowLengths: Set<Int> = []
    private var baseMagnitudes: Set<UInt64> = []
    private var freeMagnitudes: Set<UInt64> = []
    private var terminalPositions: Set<String> = []

    func record(_ shape: HonestProgressShape) {
        lock.lock()
        defer { lock.unlock() }
        cases += 1
        seeds.insert(shape.seed)
        windowLengths.insert(shape.windowLength)
        baseMagnitudes.insert(shape.baseMagnitude)
        producedUnits.insert(shape.baseUnit)
        producedStages.insert(shape.baseStage)
        terminalPositions.insert(shape.commitsATerminal ? "inside" : "stillActive")
    }

    /// Records the outcomes one fully executed case produced.
    func recordExecutedCase(_ run: ProgressCaseRun) {
        lock.lock()
        defer { lock.unlock() }
        executedCases += 1

        var fractionsThisCase = 0
        for derived in [run.baseDerived, run.nearCompletion.derived,
                        run.nearCompletion.finishedDerived,
                        run.nearCompletionAboveExactRange.derived] {
            derivations += 1
            if derived.isDeterminate {
                determinateResults += 1
                if derived.fractionOfWorkCompleted != nil { fractionsThisCase += 1 }
            } else {
                indeterminateResults += 1
            }
        }
        if fractionsThisCase >= 2 { casesWithTwoOrMoreFractions += 1 }

        // A completed amount above `UInt64.max / 100` is the overflow path the exact
        // arithmetic exists for: `completed * 100` no longer fits in one word.
        for completed in [run.shape.baseCompleted, run.nearCompletionAboveExactRange.completed] {
            if completed > UInt64.max / 100 { overflowingMultiplies += 1 }
        }

        // The terminal kind is recorded only when the window actually committed it, so the
        // coverage requirement is about produced terminals rather than generated intentions.
        if run.committedTerminal != nil {
            producedTerminalKinds.insert(run.shape.terminalKind)
        }

        for entry in run.perturbed {
            derivations += 1
            perturbationsApplied += 1
            if entry.derived.isDeterminate {
                determinateResults += 1
            } else {
                indeterminateResults += 1
            }
            witnessedClauses.formUnion(entry.unsatisfiedByTheRequirement)
            if entry.unsatisfiedByTheRequirement.count == 1,
               let only = entry.unsatisfiedByTheRequirement.first {
                singlyWitnessedClauses.insert(only)
            }
            if let cause = entry.derived.unmeasuredCause {
                producedCauses.insert(Self.name(of: cause))
            }
        }

        for observation in run.free {
            derivations += 1
            producedStages.insert(observation.stage)
            if let completed = observation.reported?.completed {
                producedUnits.insert(completed.unit)
                producedReliabilities.insert(completed.reliability)
                freeMagnitudes.insert(completed.amount)
            }
            if let total = observation.reported?.total {
                producedUnits.insert(total.unit)
                producedReliabilities.insert(total.reliability)
                freeMagnitudes.insert(total.amount)
            }
            witnessedClauses.formUnion(observation.unsatisfiedByTheRequirement)
            if observation.derived.isDeterminate {
                determinateResults += 1
                freeDeterminateResults += 1
            } else {
                indeterminateResults += 1
                freeIndeterminateResults += 1
            }
            if let cause = observation.derived.unmeasuredCause {
                let name = Self.name(of: cause)
                producedCauses.insert(name)
                freeProducedCauses.insert(name)
            }
            if let percent = observation.referencePercent {
                producedReferencePercents.insert(percent)
            }
        }

        if let percent = run.baseReferencePercent { producedReferencePercents.insert(percent) }
        if let percent = run.nearCompletion.referencePercent {
            producedReferencePercents.insert(percent)
        }
        if let percent = run.nearCompletion.finishedReferencePercent {
            producedReferencePercents.insert(percent)
        }

        // The reported divergence, measured against its own denominator.
        let probe = run.nearCompletionAboveExactRange
        if probe.isWithinExactDoubleRange == false {
            aboveExactRangeNearCompletePairs += 1
            if let percentage = probe.derived.percentage, percentage.percent == 100 {
                doublePercentagesReadingOneHundredEarly += 1
            }
        }
    }

    /// Records an input this file described but could not build.
    ///
    /// Never a finding about production: every input is built from generated integers inside
    /// validated ranges, so a refusal is a defect in this file.
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
            derivations \(derivations) (determinate \(determinateResults), \
            indeterminate \(indeterminateResults)); \
            free arm (determinate \(freeDeterminateResults), \
            indeterminate \(freeIndeterminateResults)); \
            perturbations \(perturbationsApplied), \
            cases with two or more fractions \(casesWithTwoOrMoreFractions), \
            overflowing multiplies \(overflowingMultiplies); \
            units \(producedUnits.map(\.rawValue).sorted()), \
            reliabilities \(producedReliabilities.map(\.rawValue).sorted()), \
            stages \(producedStages.count)/\(AnalysisStage.allCases.count), \
            clauses \(witnessedClauses.count)/\(HonestProgressReference.Clause.allCases.count), \
            singly witnessed clauses \(singlyWitnessedClauses.count), \
            causes \(producedCauses.sorted()), \
            free-arm causes \(freeProducedCauses.count), \
            terminal kinds \(producedTerminalKinds.map(\.rawValue).sorted()), \
            reference percents \(producedReferencePercents.count) \
            (min \(producedReferencePercents.min().map(String.init) ?? "none"), \
            max \(producedReferencePercents.max().map(String.init) ?? "none")); \
            REPORTED DIVERGENCE: Double percentages reading one hundred early \
            \(doublePercentagesReadingOneHundredEarly)/\(aboveExactRangeNearCompletePairs); \
            seeds \(seeds.count), window lengths \(windowLengths.sorted()), \
            base magnitudes \(baseMagnitudes.count)/\(HonestProgressShape.magnitudeLadder.count), \
            free magnitudes \(freeMagnitudes.count), \
            terminal placements \(terminalPositions.sorted())
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
            "\(cases - executedCases) of \(cases) cases derived nothing"
        )
        #expect(
            unbuildableInputs == 0,
            "\(unbuildableInputs) described inputs could not be built at all"
        )

        // Counted work. Every case derives four fixed states plus nine perturbations plus two
        // to six free positions, so the floors sit far below what the requested count
        // produces and far enough above zero that a run which built only fixtures fails here.
        #expect(derivations >= 15 * cases, "derivations: \(derivations)")
        #expect(
            perturbationsApplied == BasePerturbation.allCases.count * cases,
            "perturbations applied: \(perturbationsApplied)"
        )
        #expect(determinateResults >= 4 * cases, "determinate results: \(determinateResults)")
        #expect(
            indeterminateResults >= BasePerturbation.allCases.count * cases,
            "indeterminate results: \(indeterminateResults)"
        )
        #expect(
            overflowingMultiplies >= cases,
            """
            completed amounts above one hundredth of `UInt64.max`, where scaling by one \
            hundred overflows a single word: \(overflowingMultiplies)
            """
        )

        // Every absence was measured beside a presence, on every case.
        #expect(
            casesWithTwoOrMoreFractions == cases,
            """
            \(cases - casesWithTwoOrMoreFractions) cases produced fewer than two real \
            fractions, so their indeterminate assertions stood beside nothing
            """
        )

        // The free arm produced both outcomes, so agreement with the reference model was
        // measured on reports the two could have disagreed about.
        #expect(
            freeDeterminateResults >= 20,
            "free-arm reports the requirement admitted: \(freeDeterminateResults)"
        )
        #expect(
            freeIndeterminateResults >= cases,
            "free-arm reports the requirement refused: \(freeIndeterminateResults)"
        )
        #expect(
            freeProducedCauses.count >= 5,
            "distinct causes the free arm produced: \(freeProducedCauses.sorted())"
        )

        // The substantive half: the outputs were produced, not merely described.
        #expect(
            producedUnits == Set(ProgressUnit.allCases),
            """
            units never measured: \
            \(Set(ProgressUnit.allCases).subtracting(producedUnits).map(\.rawValue).sorted())
            """
        )
        #expect(
            producedReliabilities == Set(WorkMeasurementReliability.allCases),
            """
            reliability flags never reported: \
            \(Set(WorkMeasurementReliability.allCases).subtracting(producedReliabilities).map(\.rawValue).sorted())
            """
        )
        #expect(
            producedStages == Set(AnalysisStage.allCases),
            """
            stages never carried by a progress state: \
            \(Set(AnalysisStage.allCases).subtracting(producedStages).map(\.rawValue).sorted())
            """
        )
        #expect(
            witnessedClauses == Set(HonestProgressReference.Clause.allCases),
            """
            clauses never failed by a generated report: \
            \(Set(HonestProgressReference.Clause.allCases).subtracting(witnessedClauses).map(\.rawValue).sorted())
            """
        )
        // The four prerequisites the task names, each shown to be individually sufficient to
        // force indeterminate progress: the perturbation that broke it broke nothing else.
        #expect(
            singlyWitnessedClauses == Set(HonestProgressReference.Clause.allCases),
            """
            clauses never shown to be individually necessary: \
            \(Set(HonestProgressReference.Clause.allCases).subtracting(singlyWitnessedClauses).map(\.rawValue).sorted())
            """
        )
        #expect(
            producedCauses == Set(Self.everyCauseName),
            """
            unmeasured causes never produced: \
            \(Set(Self.everyCauseName).subtracting(producedCauses).sorted())
            """
        )
        #expect(
            producedTerminalKinds == Set(TerminalKind.allCases),
            """
            terminal kinds never committed: \
            \(Set(TerminalKind.allCases).subtracting(producedTerminalKinds).map(\.rawValue).sorted())
            """
        )
        #expect(
            producedReferencePercents.contains(0),
            "no case produced a zero-out-of-one-hundred measurement"
        )
        #expect(
            producedReferencePercents.contains(99),
            "no case produced the truncation boundary at ninety-nine"
        )
        #expect(
            producedReferencePercents.contains(100),
            "no case produced a finished measurement"
        )
        #expect(
            producedReferencePercents.count >= 4,
            "distinct exact percentages produced: \(producedReferencePercents.sorted())"
        )

        // The generated baseline actually varied.
        #expect(seeds.count >= 100, "generated seeds: \(seeds.count)")
        #expect(
            windowLengths == [2, 3, 4, 5, 6],
            "generated window lengths: \(windowLengths.sorted())"
        )
        #expect(
            baseMagnitudes.count == HonestProgressShape.magnitudeLadder.count,
            """
            base magnitudes never drawn: \
            \(Set(HonestProgressShape.magnitudeLadder).subtracting(baseMagnitudes).sorted())
            """
        )
        #expect(
            freeMagnitudes.contains(0) && freeMagnitudes.contains(UInt64.max),
            "the free arm must reach both ends of the magnitude ladder: \(freeMagnitudes.count)"
        )
        #expect(
            terminalPositions == ["inside", "stillActive"],
            """
            the window must sometimes end while work is still active and sometimes commit a \
            terminal inside itself: \(terminalPositions.sorted())
            """
        )

        // The reported divergence is stated in the read-out with its denominator and carries
        // no floor and no ceiling: it is a production finding, not a coverage requirement.
        #expect(
            aboveExactRangeNearCompletePairs == cases,
            """
            every case must probe one near-complete pair above Double's exact integer range; \
            probed \(aboveExactRangeNearCompletePairs) of \(cases)
            """
        )
    }

    /// A stable name for one cause, so the produced set can be compared.
    ///
    /// ``UnmeasuredProgressCause/unitMismatch(completed:total:)`` carries a payload, so the
    /// name drops it: the arms already check the payload, and the witness only needs to know
    /// the case was produced.
    private static func name(of cause: UnmeasuredProgressCause) -> String {
        switch cause {
        case .nothingReported: "nothingReported"
        case .completedAmountMissing: "completedAmountMissing"
        case .totalAmountMissing: "totalAmountMissing"
        case .unitMismatch: "unitMismatch"
        case .unreliableCompletedAmount: "unreliableCompletedAmount"
        case .unreliableTotalAmount: "unreliableTotalAmount"
        case .totalIsNotPositive: "totalIsNotPositive"
        case .completedExceedsTotal: "completedExceedsTotal"
        }
    }

    /// Every cause the derivation can name.
    ///
    /// Written out rather than derived from the enum, because ``UnmeasuredProgressCause`` is
    /// not `CaseIterable`: a case added to production without a generated report that reaches
    /// it must fail this comparison rather than silently shrink the coverage requirement.
    private static let everyCauseName = [
        "nothingReported",
        "completedAmountMissing",
        "totalAmountMissing",
        "unitMismatch",
        "unreliableCompletedAmount",
        "unreliableTotalAmount",
        "totalIsNotPositive",
        "completedExceedsTotal",
    ]
}
