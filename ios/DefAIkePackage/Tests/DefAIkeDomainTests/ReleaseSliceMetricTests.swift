import Foundation
import Testing

@testable import DefAIkeDomain

// Measuring one predeclared mandatory Release Gating Slice.
//
// Two behaviors carry the weight here, and both are asserted where a violation would
// change a number rather than only a type:
//
//   * An insufficient outcome stays inside every denominator Requirements 5.16 through
//     5.18 name. The counts below are chosen so that dropping the abstentions from the
//     false-positive denominator turns a slice that satisfies the budget into one that
//     does not, so the assertion bites instead of restating the schema.
//   * The confidence-interval result and its method are predeclared and consumed. Every
//     interval here arrives as an argument, a mismatch against the predeclared method or
//     level is refused, and a source audit asserts that no code in the domain can select
//     or compute one at all.
//
// No value in this file is an approved budget, boundary, slice, or interval. Budgets are
// stated where a test needs the pass decision to turn on them, and each expectation is
// written against the counts and the policy's own fields rather than against a release
// number nobody has chosen yet.

extension Sample {

    /// Label counts for one slice. Defaults describe a slice with both populations and
    /// abstentions in each of them.
    ///
    /// The eligible totals are derived from the labels rather than passed in, because
    /// ``SliceOutcomeCounts`` requires them to agree: a test that could set them
    /// independently would mostly be testing that invariant again.
    static func sliceCounts(
        realPositive: Int = 10,
        realNonPositive: Int = 890,
        realInsufficient: Int = 100,
        syntheticPositive: Int = 150,
        syntheticNonPositive: Int = 20,
        syntheticInsufficient: Int = 30,
        errors: Int = 0
    ) throws -> SliceOutcomeCounts {
        try SliceOutcomeCounts(
            eligibleRealImages: nonNegative(realPositive + realNonPositive + realInsufficient),
            eligibleSyntheticImages: nonNegative(
                syntheticPositive + syntheticNonPositive + syntheticInsufficient
            ),
            realPositiveLabels: nonNegative(realPositive),
            realNonPositiveLabels: nonNegative(realNonPositive),
            realInsufficientLabels: nonNegative(realInsufficient),
            syntheticPositiveLabels: nonNegative(syntheticPositive),
            syntheticNonPositiveLabels: nonNegative(syntheticNonPositive),
            syntheticInsufficientLabels: nonNegative(syntheticInsufficient),
            errorCount: nonNegative(errors)
        )
    }

    /// One percent, the ceiling Requirement 5.1 fixes. Used where a test needs the pass
    /// decision to turn on a stated number; it is not an approved budget.
    static func onePercentBudget() throws -> FalseAccusationBudget {
        try budget(FalseAccusationBudget.maximumRate)
    }

    /// A measurement of one slice, with everything defaulted to a measurable slice.
    static func measurement(
        slice: ReleaseGatingSliceSpecification? = nil,
        counts: SliceOutcomeCounts? = nil,
        interval: ConfidenceIntervalResult? = nil,
        budget: FalseAccusationBudget? = nil,
        passRule: FalseAccusationPassRule? = nil
    ) throws -> ReleaseSliceMeasurement {
        try ReleaseSliceMeasurement(
            slice: try slice ?? gatingSlice(),
            counts: try counts ?? sliceCounts(),
            falsePositiveRateInterval: try interval ?? Sample.interval(),
            measuredAgainst: try activate(
                try activatablePolicy(budget: budget, passRule: passRule)
            )
        )
    }
}

/// The exact ratio `numerator/denominator`, for stating an expected rate.
private func rate(_ numerator: Int, over denominator: Int) throws -> MeasuredRate {
    try MeasuredRate(
        numerator: Sample.nonNegative(numerator),
        denominator: Sample.count(denominator),
        field: "test.rate"
    )
}

/// Asserts that `build` fails with a schema error naming `field`.
private func rejects(
    _ field: String,
    _ build: () throws -> Void,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        try build()
        Issue.record(
            "a slice measurement was accepted that must be refused",
            sourceLocation: sourceLocation
        )
    } catch let error as ArtifactSchemaError {
        #expect(
            error.description.contains(field),
            "\(error.description) does not name \(field)",
            sourceLocation: sourceLocation
        )
    } catch {
        Issue.record("unexpected error \(error)", sourceLocation: sourceLocation)
    }
}

// MARK: - The three rates

@Suite("Release slice metrics")
struct ReleaseSliceMetricTests {

    @Test("Each rate is the exact ratio over its full eligible population")
    func ratesAreExactRatiosOverEligiblePopulations() throws {
        // Requirements 5.16 through 5.18. Every denominator is the eligible population
        // itself, read from the counts rather than rebuilt from the decisive labels.
        let counts = try Sample.sliceCounts()
        let measurement = try Sample.measurement(counts: counts)
        let expectedFalsePositiveRate = try rate(10, over: 1_000)
        let expectedTruePositiveRate = try rate(150, over: 200)
        let expectedCoverage = try rate(1_070, over: 1_200)

        #expect(measurement.falsePositiveRate == expectedFalsePositiveRate)
        #expect(measurement.truePositiveRate == expectedTruePositiveRate)
        #expect(measurement.coverage == expectedCoverage)

        #expect(measurement.falsePositiveRate?.denominator.value == counts.eligibleRealImages.value)
        #expect(
            measurement.truePositiveRate?.denominator.value == counts.eligibleSyntheticImages.value
        )
        #expect(measurement.coverage.denominator.value == counts.eligibleImageCount)
    }

    @Test("Dropping the abstentions from a denominator would turn a pass into a failure")
    func insufficientOutcomesStayInRateDenominators() throws {
        // Requirements 5.17 and 5.18 as an arithmetic fact rather than a field check. The
        // slice assigns the positive label to 10 of 1,000 eligible real images and abstains
        // on 100 of them. Against a 1% budget:
        //
        //   * with the abstentions retained, 10/1,000 is exactly 1% and satisfies it;
        //   * with the abstentions removed, 10/900 exceeds it.
        //
        // So the same evaluation run passes or fails purely on whether an abstention stays
        // in the denominator, which is what makes retaining it the whole point.
        let budget = try Sample.onePercentBudget()
        let measurement = try Sample.measurement(budget: budget)
        let observed = try #require(measurement.falsePositiveRate)
        let overEligibleRealImages = try rate(10, over: 1_000)
        let overDecisiveLabelsOnly = try rate(10, over: 900)

        #expect(observed == overEligibleRealImages)
        #expect(observed.isAtMost(budget.rate))
        #expect(measurement.budgetOutcome == .evaluated(.passed))

        #expect(!overDecisiveLabelsOnly.isAtMost(budget.rate))
        #expect(overDecisiveLabelsOnly != observed)
    }

    @Test("An abstention is never counted as a decisive label")
    func abstentionIsNeverADecisiveLabel() throws {
        // Coverage excludes the insufficient outcomes from its numerator and keeps them in
        // its denominator (Requirement 5.18). Reclassifying one abstention as a decisive
        // label therefore moves the numerator and leaves the denominator alone.
        let abstaining = try Sample.measurement()
        let decisive = try Sample.measurement(
            counts: try Sample.sliceCounts(realNonPositive: 891, realInsufficient: 99)
        )

        #expect(abstaining.coverage.denominator == decisive.coverage.denominator)
        #expect(abstaining.coverage.numerator.value + 1 == decisive.coverage.numerator.value)
        #expect(abstaining.insufficientOutcomeCount == 130)
        #expect(decisive.insufficientOutcomeCount == 129)
    }

    @Test("Coverage reaches 1 only when no eligible image abstained")
    func coverageIsOneOnlyWithoutAbstentions() throws {
        let withAbstentions = try Sample.measurement()
        #expect(!withAbstentions.coverage.isOne)
        #expect(!withAbstentions.coverage.isZero)

        let complete = try Sample.measurement(
            counts: try Sample.sliceCounts(realInsufficient: 0, syntheticInsufficient: 0)
        )
        #expect(complete.coverage.isOne)
        #expect(complete.insufficientOutcomeCount == 0)

        // Every eligible image abstaining is coverage of exactly zero, and it is a
        // measured zero: the denominator is still the full eligible population.
        let allAbstained = try Sample.measurement(
            counts: try Sample.sliceCounts(
                realPositive: 0,
                realNonPositive: 0,
                realInsufficient: 40,
                syntheticPositive: 0,
                syntheticNonPositive: 0,
                syntheticInsufficient: 60
            )
        )
        let noDecisiveLabel = try rate(0, over: 100)
        #expect(allAbstained.coverage == noDecisiveLabel)
        #expect(allAbstained.coverage.isZero)
    }

    @Test("The error count is reported beside the rates and is in none of them")
    func errorsAreReportedButNotInADenominator() throws {
        // Requirement 5.19 requires error counts reported. An Analysis Error produced no
        // label, and `SliceOutcomeCounts` pins each eligible population to the labels it
        // received, so an error is neither a numerator nor a denominator member. Changing
        // it must move nothing else.
        let clean = try Sample.measurement()
        let faulted = try Sample.measurement(counts: try Sample.sliceCounts(errors: 17))

        #expect(clean.errorCount.value == 0)
        #expect(faulted.errorCount.value == 17)
        #expect(faulted.falsePositiveRate == clean.falsePositiveRate)
        #expect(faulted.truePositiveRate == clean.truePositiveRate)
        #expect(faulted.coverage == clean.coverage)
    }

    @Test("Composition, degradation, and the slice's own identity are all reported")
    func everyReportedFieldIsPresent() throws {
        // The rest of Requirement 5.19's report. Each one is read from the predeclared
        // specification, so a measurement cannot exist without them.
        let slice = try Sample.gatingSlice()
        let counts = try Sample.sliceCounts()
        let measurement = try Sample.measurement(slice: slice, counts: counts)

        #expect(measurement.slice == slice.id)
        #expect(measurement.datasetComposition == slice.datasetComposition)
        #expect(measurement.degradationCondition == slice.degradationCondition)
        #expect(measurement.isContemporaryPhoneCameraSlice)
        #expect(measurement.calibrationPolicy == Sample.artifact("policy.calibration"))
        #expect(measurement.modelBundle == Sample.bundle())
        #expect(measurement.counts == counts)

        // Requirement 5.21's inputs are all readable from the measurement, and the two
        // declared ones come from the validated policy rather than from anything here.
        let declared = measurement.policy.policy
        #expect(measurement.falseAccusationBudget == declared.falseAccusationBudget)
        #expect(measurement.releasePassRule == declared.releasePassRule)
    }
}

// MARK: - Empty populations

@Suite("Release slice metrics over an empty population")
struct EmptyPopulationSliceMetricTests {

    @Test("A real-image-only slice has no true-positive rate, and not a zero one")
    func realOnlySliceHasAbsentTruePositiveRate() throws {
        // Requirement 5.20 makes a contemporary phone-camera real-image subset a mandatory
        // slice. It has no synthetic population, so there is no true-positive rate to
        // report; zero would claim every synthetic image escaped detection.
        let measurement = try Sample.measurement(
            counts: try Sample.sliceCounts(
                syntheticPositive: 0,
                syntheticNonPositive: 0,
                syntheticInsufficient: 0
            )
        )

        let expectedFalsePositiveRate = try rate(10, over: 1_000)
        let expectedCoverage = try rate(900, over: 1_000)

        #expect(measurement.truePositiveRate == nil)
        #expect(measurement.falsePositiveRate == expectedFalsePositiveRate)
        #expect(measurement.coverage == expectedCoverage)
    }

    @Test("A slice with no eligible real image has no budget result, and never a pass")
    func syntheticOnlySliceHasNoBudgetResult() throws {
        // Requirement 5.1 scopes the budget to mandatory slices containing held-out real
        // images. With none of them there is no observed false-positive rate for
        // Requirement 5.21's rule to read, and the absence is reported as its own outcome
        // rather than as a passing or failing rule.
        let measurement = try Sample.measurement(
            counts: try Sample.sliceCounts(
                realPositive: 0,
                realNonPositive: 0,
                realInsufficient: 0
            )
        )

        let expectedTruePositiveRate = try rate(150, over: 200)

        #expect(measurement.falsePositiveRate == nil)
        #expect(measurement.budgetOutcome == .noObservedFalsePositiveRate)
        #expect(!measurement.budgetOutcome.isPassing)
        #expect(measurement.truePositiveRate == expectedTruePositiveRate)
    }

    @Test("A slice with no eligible image at all is refused")
    func emptySliceIsRefused() throws {
        rejects("counts.eligibleImages") {
            _ = try Sample.measurement(
                counts: try Sample.sliceCounts(
                    realPositive: 0,
                    realNonPositive: 0,
                    realInsufficient: 0,
                    syntheticPositive: 0,
                    syntheticNonPositive: 0,
                    syntheticInsufficient: 0
                )
            )
        }
    }

    @Test("A rate over an empty population is unrepresentable")
    func rateOverAnEmptyPopulationCannotBeBuilt() throws {
        // The `nil` above is not a convention in the measurement: `MeasuredRate` requires a
        // positive denominator, so `0/0` has no value to be mistaken for zero.
        let overNothing = try MeasuredRate.rate(
            of: Sample.nonNegative(0),
            over: Sample.nonNegative(0),
            field: "test.rate"
        )
        #expect(overNothing == nil)
        #expect(throws: ArtifactSchemaError.self) {
            _ = try MeasuredRate(
                numerator: Sample.nonNegative(3),
                denominator: Sample.count(2),
                field: "test.rate"
            )
        }
    }
}

// MARK: - The predeclared confidence result

@Suite("Predeclared confidence-interval results")
struct PredeclaredConfidenceResultTests {

    @Test("The supplied interval is carried through unchanged")
    func suppliedIntervalIsCarriedUnchanged() throws {
        let interval = try Sample.interval(
            lower: Decimal(sign: .plus, exponent: -4, significand: 12),
            upper: Decimal(sign: .plus, exponent: -3, significand: 9)
        )
        let measurement = try Sample.measurement(interval: interval)

        #expect(measurement.falsePositiveRateInterval == interval)
        #expect(measurement.falsePositiveRateInterval.method == interval.method)
    }

    @Test("An interval computed with a method nobody predeclared is refused")
    func intervalWithAnotherMethodIsRefused() throws {
        // Requirement 5.15: the method is predeclared before evaluation begins. Supplying a
        // result from a different method is exactly the after-the-fact choice the
        // requirement exists to forbid, so it is refused rather than reported.
        for method in ConfidenceIntervalMethod.allCases where method != .wilsonScore {
            rejects("falsePositiveRateInterval.method") {
                _ = try Sample.measurement(interval: try Sample.interval(method: method))
            }
        }
    }

    @Test("An interval at a level other than the predeclared one is refused")
    func intervalAtAnotherLevelIsRefused() throws {
        // Requirement 5.19 fixes 95% for a mandatory Release Gating Slice. The level is
        // read from the predeclared specification, so a 90% or 99% result is refused
        // without this test or the code it exercises naming 95 anywhere.
        for level: Decimal in [
            Decimal(sign: .plus, exponent: -2, significand: 90),
            Decimal(sign: .plus, exponent: -2, significand: 99),
            1,
        ] {
            rejects("falsePositiveRateInterval.confidenceLevel") {
                _ = try Sample.measurement(interval: try Sample.interval(level: level))
            }
        }
    }

    @Test("A point value wearing an interval's name is refused")
    func pointIntervalIsRefused() throws {
        let point = Decimal(sign: .plus, exponent: -3, significand: 4)
        rejects("falsePositiveRateInterval") {
            _ = try Sample.measurement(
                interval: try Sample.interval(lower: point, upper: point)
            )
        }
    }

    @Test("A slice and a policy that disagree about the method are refused")
    func sliceAndPolicyMustAgreeAboutTheMethod() throws {
        // Both sides predeclare the method, so a disagreement leaves no single prediction
        // to compare the result against, and adopting either one would be this code
        // deciding which prediction counts.
        rejects("intervalMethod") {
            _ = try Sample.measurement(
                slice: try Sample.gatingSlice(intervalMethod: .clopperPearson),
                passRule: try Sample.passRule(intervalMethod: .wilsonScore)
            )
        }

        // The positive control: agreeing on another method is accepted, so the refusal is
        // about the disagreement rather than about the method named.
        let agreed = try Sample.measurement(
            slice: try Sample.gatingSlice(intervalMethod: .clopperPearson),
            interval: try Sample.interval(method: .clopperPearson),
            passRule: try Sample.passRule(intervalMethod: .clopperPearson)
        )
        #expect(agreed.falsePositiveRateInterval.method == .clopperPearson)
    }

    @Test("No source in the domain selects, names, or computes an interval method")
    func noSourceSelectsAnIntervalMethod() throws {
        // The structural half of "predeclared and consumed". Two facts about the domain
        // sources, each with the positive control that the search finds anything at all:
        //
        //   * Every `ConfidenceIntervalMethod` case name appears in exactly one file, the
        //     one declaring the vocabulary. A `switch` over the method, a per-method
        //     formula, or a default method would all have to name a case somewhere else.
        //   * No file constructs a `ConfidenceIntervalResult` at all. The type is declared
        //     in one place and built nowhere, so an interval can only arrive from decoded
        //     signed bytes or from an argument — never from a calculation.
        let sources = try DomainSourceFiles.byName(from: #filePath)
        #expect(sources.count > 1, "the domain source audit found nothing to read")

        let caseNames = [
            "wilsonScore", "clopperPearson", "agrestiCoull", "jeffreys", "bootstrapPercentile",
        ]
        #expect(caseNames.count == ConfidenceIntervalMethod.allCases.count)
        for name in caseNames {
            let naming = sources.filter { $0.value.contains(name) }.keys.sorted()
            #expect(
                naming == ["CalibrationPolicy.swift"],
                "\(name) is named outside the vocabulary that declares it: \(naming)"
            )
        }

        // The positive control for the second fact: the type is declared, in one file.
        let declaring = sources.filter {
            $0.value.contains("public struct ConfidenceIntervalResult")
        }
        .keys
        .sorted()
        #expect(declaring == ["CalibrationReleaseEvidence.swift"], "\(declaring)")

        let constructing = sources.filter { $0.value.contains("ConfidenceIntervalResult(") }
            .keys
            .sorted()
        #expect(constructing.isEmpty, "an interval is built in \(constructing)")
    }
}

// MARK: - The budget pass rule

@Suite("False Accusation Budget pass rule")
struct BudgetPassRuleTests {

    @Test("A rate or bound exactly equal to the budget passes")
    func equalityIsNotAnExcess() throws {
        // Requirement 5.22 blocks a slice that *exceeds* the budget, so equality passes.
        // Treating it as a failure would be a stricter rule than the approved one.
        let budget = try Sample.onePercentBudget()
        let measurement = try Sample.measurement(
            interval: try Sample.interval(upper: budget.rate),
            budget: budget
        )

        let observed = try #require(measurement.falsePositiveRate)
        #expect(observed.isAtMost(budget.rate))
        #expect(measurement.falsePositiveRateInterval.upperBound.value == budget.rate)
        #expect(measurement.budgetOutcome == .evaluated(.passed))
    }

    @Test("Each predeclared statistic reads exactly the inputs it names")
    func eachStatisticReadsItsOwnInputs() throws {
        // Requirement 5.21 states the rule over the observed rate and its predeclared
        // interval, and `BudgetPassStatistic` is which of the two the policy reads. Here
        // the observed rate satisfies a 1% budget and the interval's upper bound does not,
        // so the three statistics have to disagree.
        let budget = try Sample.onePercentBudget()
        let wideInterval = try Sample.interval(
            upper: Decimal(sign: .plus, exponent: -2, significand: 4)
        )
        let outcomes = try BudgetPassStatistic.allCases.map { statistic in
            try Sample.measurement(
                interval: wideInterval,
                budget: budget,
                passRule: try Sample.passRule(statistic: statistic)
            ).budgetOutcome
        }

        #expect(
            outcomes == [
                .evaluated(.passed),  // observed-rate
                .evaluated(.failed),  // interval-upper-bound
                .evaluated(.failed),  // both
            ],
            "\(zip(BudgetPassStatistic.allCases, outcomes).map { "\($0.rawValue)=\($1)" })"
        )
    }

    @Test("An observed rate above the budget fails under every statistic")
    func anExcessiveRateFails() throws {
        let budget = try Sample.onePercentBudget()
        // 11 positive labels in 1,000 eligible real images is 1.1%, above the budget.
        let counts = try Sample.sliceCounts(realPositive: 11, realNonPositive: 889)
        for statistic in BudgetPassStatistic.allCases {
            let measurement = try Sample.measurement(
                counts: counts,
                interval: try Sample.interval(upper: budget.rate),
                budget: budget,
                passRule: try Sample.passRule(statistic: statistic)
            )
            #expect(
                measurement.budgetOutcome == .evaluated(statistic == .intervalUpperBound
                    ? .passed
                    : .failed),
                "\(statistic.rawValue) read the wrong input"
            )
        }
    }

    @Test("An exact comparison is not decided by a rounded quotient")
    func comparisonIsExact() throws {
        // 1/3 has no exact decimal form. Comparing it against a budget by rounding it
        // first would answer about the rounding, so the comparison multiplies instead.
        let third = try rate(1, over: 3)
        #expect(third.isAtMost(Decimal(1) / Decimal(3)) == false)
        #expect(third.isAtMost(Decimal(sign: .plus, exponent: -1, significand: 4)))
        #expect(!third.isAtMost(Decimal(sign: .plus, exponent: -1, significand: 3)))
        #expect(third.description == "1/3")

        // A comparison whose product cannot be represented exactly refuses rather than
        // guesses. This rate is plainly below the limit, and the answer is still `false`:
        // an unrepresentable comparison blocks instead of certifying a pass.
        let tinyRate = try rate(1, over: 1_000_000)
        #expect(!tinyRate.isAtMost(.greatestFiniteMagnitude))
    }
}

// MARK: - Reading the domain sources

/// The domain's Swift sources keyed by file name.
///
/// `DomainSources` returns file contents without their names, which is enough for a
/// registry sweep but not for "this appears in exactly one file". This adds the names.
enum DomainSourceFiles {

    static func byName(from file: String) throws -> [String: String] {
        let directory = try DomainSources.directory(from: file)
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: nil
            )
        else {
            throw DomainSources.AuditError.sourcesNotFound(path: directory.path)
        }
        var contents: [String: String] = [:]
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            contents[url.lastPathComponent] = try String(contentsOf: url, encoding: .utf8)
        }
        return contents
    }
}
