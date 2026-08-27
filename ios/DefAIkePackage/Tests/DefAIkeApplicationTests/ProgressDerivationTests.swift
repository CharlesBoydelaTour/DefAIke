import DefAIkeDomain
import Testing

@testable import DefAIkeApplication

// Unit tests for honest progress derivation (spec task 10.4).
//
// Four things are being tested, and they are separable:
//
//   1. A determinate fraction appears only when every prerequisite in the design's rule
//      holds, and each missing prerequisite is named (Requirements 15.2 and 15.3).
//   2. Every refusal is explicitly indeterminate and says the analysis is continuing,
//      never stalled, completed, failed, or zero percent (Requirements 15.1 and 15.4).
//   3. A percentage exists only as a measured work fraction and is labeled as analysis
//      work progress (Requirement 15.11).
//   4. The derivation is pure, so no elapsed time and no repetition can change it.
//
// Property 34 (progress is honest and derived only from measured work) is spec task
// 10.10 and is not written here.

// MARK: - Fixtures

extension WorkAmount {
    /// A reliable count, which is the only kind that may contribute to a fraction.
    static func reliable(_ amount: UInt64, _ unit: ProgressUnit = .encodedBytes) -> WorkAmount {
        WorkAmount(amount: amount, unit: unit, reliability: .reliable)
    }

    /// A count the reporting operation does not vouch for.
    static func unreliable(_ amount: UInt64, _ unit: ProgressUnit = .encodedBytes) -> WorkAmount {
        WorkAmount(amount: amount, unit: unit, reliability: .unreliable)
    }
}

extension ReportedWork {
    /// A report whose completed and total counts are both reliable and in one unit.
    static func measured(
        completed: UInt64,
        total: UInt64,
        unit: ProgressUnit = .encodedBytes
    ) -> ReportedWork {
        ReportedWork(
            completed: .reliable(completed, unit),
            total: .reliable(total, unit)
        )
    }
}

// MARK: - Determinate progress

@Suite("Honest progress: determinate work")
struct DeterminateProgressTests {
    @Test(
        "A reliable in-range pair in one unit becomes determinate progress",
        arguments: ProgressUnit.allCases
    )
    func reliablePairIsDeterminate(unit: ProgressUnit) {
        let derived = DerivedAnalysisProgress(
            reported: .measured(completed: 3, total: 4, unit: unit),
            at: .inputValidation
        )

        #expect(
            derived.state == .determinate(
                completed: 3,
                total: 4,
                unit: unit,
                stage: .inputValidation
            )
        )
        #expect(derived.unmeasuredCause == nil)
        #expect(derived.indeterminateAssertion == nil)
        #expect(derived.fractionOfWorkCompleted == 0.75)
    }

    @Test("The reported amounts are carried through unaltered")
    func amountsAreNotRescaled() {
        // Nothing normalizes, rounds, or rescales a measurement: the state carries the
        // counts the operation reported, and the fraction is computed from those.
        let derived = DerivedAnalysisProgress(
            reported: .measured(completed: 1, total: 3),
            at: .preprocessing
        )

        guard case .determinate(let completed, let total, let unit, let stage) = derived.state
        else {
            Issue.record("a reliable in-range pair must derive determinate progress")
            return
        }
        #expect(completed == 1)
        #expect(total == 3)
        #expect(unit == .encodedBytes)
        #expect(stage == .preprocessing)
        #expect(derived.fractionOfWorkCompleted == 1.0 / 3.0)
    }

    @Test("Zero completed and fully completed are both usable measurements")
    func rangeBoundariesAreDeterminate() {
        let none = DerivedAnalysisProgress(
            reported: .measured(completed: 0, total: 10),
            at: .handoffVerification
        )
        let all = DerivedAnalysisProgress(
            reported: .measured(completed: 10, total: 10),
            at: .handoffVerification
        )

        #expect(none.isDeterminate)
        #expect(none.fractionOfWorkCompleted == 0)
        #expect(all.isDeterminate)
        #expect(all.fractionOfWorkCompleted == 1)
    }

    @Test("A determinate result always yields a usable fraction")
    func determinateAlwaysHasAFraction() {
        // The derivation may never construct a determinate state the domain would
        // refuse to divide: no zero total, no out-of-range completed count. This is the
        // invariant every refusal case below exists to protect.
        for total in UInt64(0)...4 {
            for completed in UInt64(0)...6 {
                let derived = DerivedAnalysisProgress(
                    reported: .measured(completed: completed, total: total),
                    at: .inference
                )
                if derived.isDeterminate {
                    #expect(derived.fractionOfWorkCompleted != nil)
                    #expect(derived.percentage != nil)
                } else {
                    #expect(derived.fractionOfWorkCompleted == nil)
                    #expect(derived.percentage == nil)
                }
            }
        }
    }

    @Test("The derived state reports the stage it was asked about", arguments: AnalysisStage.allCases)
    func stageIsCarried(stage: AnalysisStage) {
        #expect(
            DerivedAnalysisProgress(reported: .measured(completed: 1, total: 2), at: stage).stage
                == stage
        )
        #expect(DerivedAnalysisProgress(at: stage).stage == stage)
    }
}

// MARK: - Refused fractions

@Suite("Honest progress: refused fractions")
struct IndeterminateProgressTests {
    @Test("A zero total is not divided by")
    func zeroTotalIsRefused() {
        let derived = DerivedAnalysisProgress(
            reported: .measured(completed: 0, total: 0),
            at: .preprocessing
        )

        #expect(derived.state == .indeterminate(stage: .preprocessing))
        #expect(derived.unmeasuredCause == .totalIsNotPositive)
    }

    @Test("Completed work beyond the total is refused rather than clamped")
    func completedBeyondTotalIsRefused() {
        let derived = DerivedAnalysisProgress(
            reported: .measured(completed: 11, total: 10),
            at: .preprocessing
        )

        #expect(derived.state == .indeterminate(stage: .preprocessing))
        #expect(derived.unmeasuredCause == .completedExceedsTotal)
        // Clamping would have produced a confident, wrong "100%".
        #expect(derived.fractionOfWorkCompleted == nil)
        #expect(derived.percentage == nil)
    }

    @Test("Mismatched units yield indeterminate progress, not a fabricated fraction")
    func unitMismatchIsRefused() {
        let bytesOverRows = DerivedAnalysisProgress(
            reported: ReportedWork(
                completed: .reliable(5, .encodedBytes),
                total: .reliable(10, .imageRows)
            ),
            at: .preprocessing
        )
        let rowsOverBytes = DerivedAnalysisProgress(
            reported: ReportedWork(
                completed: .reliable(5, .imageRows),
                total: .reliable(10, .encodedBytes)
            ),
            at: .preprocessing
        )

        #expect(
            bytesOverRows.unmeasuredCause
                == .unitMismatch(completed: .encodedBytes, total: .imageRows)
        )
        #expect(
            rowsOverBytes.unmeasuredCause
                == .unitMismatch(completed: .imageRows, total: .encodedBytes)
        )
        // Neither unit is preferred: both directions refuse, and 5/10 never appears.
        #expect(bytesOverRows.fractionOfWorkCompleted == nil)
        #expect(rowsOverBytes.fractionOfWorkCompleted == nil)
    }

    @Test("An unreliable amount on either side is refused")
    func unreliableAmountIsRefused() {
        let unreliableCompleted = DerivedAnalysisProgress(
            reported: ReportedWork(completed: .unreliable(5), total: .reliable(10)),
            at: .inference
        )
        let unreliableTotal = DerivedAnalysisProgress(
            reported: ReportedWork(completed: .reliable(5), total: .unreliable(10)),
            at: .inference
        )
        let neitherReliable = DerivedAnalysisProgress(
            reported: ReportedWork(completed: .unreliable(5), total: .unreliable(10)),
            at: .inference
        )

        #expect(unreliableCompleted.unmeasuredCause == .unreliableCompletedAmount)
        #expect(unreliableTotal.unmeasuredCause == .unreliableTotalAmount)
        #expect(neitherReliable.unmeasuredCause == .unreliableCompletedAmount)
        for derived in [unreliableCompleted, unreliableTotal, neitherReliable] {
            #expect(derived.isDeterminate == false)
        }
    }

    @Test("A missing amount names which side was missing")
    func missingAmountsAreNamed() {
        #expect(
            DerivedAnalysisProgress(
                reported: ReportedWork(completed: nil, total: .reliable(10)),
                at: .modelLoad
            ).unmeasuredCause == .completedAmountMissing
        )
        #expect(
            DerivedAnalysisProgress(
                reported: ReportedWork(completed: .reliable(5), total: nil),
                at: .modelLoad
            ).unmeasuredCause == .totalAmountMissing
        )
        #expect(
            DerivedAnalysisProgress(
                reported: ReportedWork(completed: nil, total: nil),
                at: .modelLoad
            ).unmeasuredCause == .completedAmountMissing
        )
    }

    @Test("A stage that measures nothing is continuing, not stalled")
    func unmeasuredStageIsContinuing() {
        let derived = DerivedAnalysisProgress(at: .calibration)

        #expect(derived.state == .indeterminate(stage: .calibration))
        #expect(derived.unmeasuredCause == .nothingReported)
        #expect(derived.indeterminateAssertion == .analysisIsContinuing)
    }

    @Test("Every refusal is explicitly indeterminate and continuing")
    func everyRefusalIsExplicit() {
        // Requirement 15.4 applies to all of them, not only to the no-report case: a
        // refused fraction must never read as a finished, failed, or stuck session.
        let refusals: [ReportedWork?] = [
            nil,
            ReportedWork(completed: nil, total: nil),
            ReportedWork(completed: nil, total: .reliable(10)),
            ReportedWork(completed: .reliable(5), total: nil),
            ReportedWork(completed: .reliable(5, .encodedBytes), total: .reliable(10, .imageRows)),
            ReportedWork(completed: .unreliable(5), total: .reliable(10)),
            ReportedWork(completed: .reliable(5), total: .unreliable(10)),
            .measured(completed: 0, total: 0),
            .measured(completed: 11, total: 10),
        ]

        for report in refusals {
            let derived = DerivedAnalysisProgress(reported: report, at: .inference)
            #expect(derived.state == .indeterminate(stage: .inference))
            #expect(derived.unmeasuredCause != nil)
            #expect(derived.indeterminateAssertion == .analysisIsContinuing)
            #expect(derived.percentage == nil)
        }
    }

    @Test("An unknown-count sentinel cannot become a total")
    func negativeReportedCountIsNotAnAmount() {
        // A framework reports -1 for "unknown". Widening it would make the largest
        // expressible total, and every fraction after that would be arithmetic over a
        // fabricated denominator.
        #expect(
            WorkAmount(reportedCount: -1, unit: .encodedBytes, reliability: .reliable) == nil
        )
        #expect(
            WorkAmount(reportedCount: .min, unit: .imageRows, reliability: .reliable) == nil
        )

        let zero = WorkAmount(reportedCount: 0, unit: .encodedBytes, reliability: .reliable)
        #expect(zero?.amount == 0)
        let counted = WorkAmount(reportedCount: 4096, unit: .encodedBytes, reliability: .reliable)
        #expect(counted?.amount == 4096)

        // The sentinel becomes a missing measurement, so progress stays indeterminate.
        let derived = DerivedAnalysisProgress(
            reported: ReportedWork(
                completed: .reliable(512),
                total: WorkAmount(
                    reportedCount: -1,
                    unit: .encodedBytes,
                    reliability: .reliable
                )
            ),
            at: .inputValidation
        )
        #expect(derived.unmeasuredCause == .totalAmountMissing)
    }
}

// MARK: - Percentage labeling

@Suite("Honest progress: the percentage is analysis work progress")
struct AnalysisWorkPercentageTests {
    @Test("A percentage comes only from the measured fraction")
    func percentageIsTheMeasuredFraction() throws {
        let derived = DerivedAnalysisProgress(
            reported: .measured(completed: 1, total: 4, unit: .imageRows),
            at: .preprocessing
        )

        let percentage = try #require(derived.percentage)
        #expect(percentage.percent == 25)
        #expect(percentage.unit == .imageRows)
        #expect(percentage.stage == .preprocessing)
        let fraction = try #require(derived.fractionOfWorkCompleted)
        #expect(percentage.percent == fraction * 100)
    }

    @Test("A percentage is always labeled analysis work progress")
    func percentageIsLabeledWorkProgress() {
        // The label is the type, not a string a caller passes in, so there is no
        // percentage from this module that could mean result probability or confidence
        // (Requirement 15.11). One case exists, by construction.
        #expect(AnalysisWorkPercentage.semantics == .analysisWorkProgress)
        #expect(ProgressQuantitySemantics.allCases == [.analysisWorkProgress])
    }

    @Test("The percentage spans the full measured range")
    func percentageSpansTheRange() {
        for (completed, expected) in [(UInt64(0), 0.0), (UInt64(2), 50.0), (UInt64(4), 100.0)] {
            let derived = DerivedAnalysisProgress(
                reported: .measured(completed: completed, total: 4),
                at: .inference
            )
            #expect(derived.percentage?.percent == expected)
        }
    }

    @Test("An unusable state yields no percentage at all")
    func noPercentageWithoutAMeasurement() {
        // Absent rather than zero: "0%" is a claim that no work is done, which is a
        // different statement from "this work is not measurable".
        #expect(AnalysisWorkPercentage(.indeterminate(stage: .inference)) == nil)
        #expect(
            AnalysisWorkPercentage(
                .determinate(completed: 0, total: 0, unit: .encodedBytes, stage: .inference)
            ) == nil
        )
        #expect(
            AnalysisWorkPercentage(
                .determinate(completed: 5, total: 4, unit: .encodedBytes, stage: .inference)
            ) == nil
        )
    }
}

// MARK: - Purity

@Suite("Honest progress: derivation is pure")
struct ProgressDerivationPurityTests {
    @Test("Repeating a derivation cannot change it")
    func derivationIsRepeatable() {
        // The derivation holds no clock and no history, so no amount of elapsed time and
        // no number of repetitions can move the state, add a countdown, or produce a
        // terminal outcome (Requirement 15.10). An implementation that accumulated
        // anything per call would fail here.
        let report = ReportedWork.measured(completed: 7, total: 9)
        let first = DerivedAnalysisProgress(reported: report, at: .inference)

        for _ in 0..<200 {
            #expect(DerivedAnalysisProgress(reported: report, at: .inference) == first)
        }
        #expect(first.fractionOfWorkCompleted == 7.0 / 9.0)
    }

    @Test("A revised total is a new measurement, not a broken promise")
    func totalsMayBeRevised() {
        // Nothing stores a previous fraction to smooth against, so a stage that learns a
        // larger total simply reports a smaller fraction. Holding a stored maximum to
        // keep a bar from moving backwards would turn the measurement into an estimate.
        let before = DerivedAnalysisProgress(
            reported: .measured(completed: 5, total: 10),
            at: .inputValidation
        )
        let after = DerivedAnalysisProgress(
            reported: .measured(completed: 5, total: 20),
            at: .inputValidation
        )

        #expect(before.fractionOfWorkCompleted == 0.5)
        #expect(after.fractionOfWorkCompleted == 0.25)
    }
}
