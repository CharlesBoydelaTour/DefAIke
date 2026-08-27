import Foundation
import Testing

@testable import DefAIkeDomain

// Example tests for the resource-plan completeness and authority layer.
//
// Every test builds the coherent baseline, breaks exactly one thing, and requires the
// validator to refuse. What each one is really asserting is that a specific way of
// shipping an unmeasured number, an unpredeclared comparison, or a missing result is not
// available.
//
// The exhaustive generated coverage belongs to Property 28 (complete authoritative
// resource plans) and Property 32 (referentially complete plans and result records) in
// their own tasks. These examples pin the individual refusals so a regression names one
// field.

@Suite("Validated resource plan")
struct ValidatedResourcePlanTests {
    @Test("A coherent plan and budget pair validates and supplies the limits")
    func coherentPlanValidates() throws {
        let validated = try ResourcePlanSample.validated()

        #expect(validated.id == Sample.artifact(ResourcePlanSample.planIdentifier))
        #expect(!validated.enablesProvenance)
        #expect(validated.missingResultRule == .treatAsFailure)
        #expect(validated.candidateConfigurations.count == 1)

        for target in ExecutionTarget.allCases {
            for metric in ResourceMetric.requiredMetrics(for: target) {
                #expect(validated.hardLimit(metric, for: target) != nil)
            }
        }
        #expect(validated.hardLimit(.decodedPixelCount, for: .shareExtension) == nil)
        #expect(validated.hardLimit(.encodedInputSize, for: .mainApplication) == nil)
    }

    @Test("A provenance-enabled release validates with its provenance comparison")
    func provenanceEnabledPlanValidates() throws {
        let validated = try ResourcePlanSample.validated(provenanceEnabled: true)
        #expect(validated.enablesProvenance)
        #expect(validated.plan.comparison(for: .provenanceState) != nil)
    }

    // MARK: Approval

    @Test("A rejected plan supplies no limit")
    func rejectedPlanRefused() throws {
        #expect(throws: ArtifactSchemaError.self) {
            try ResourcePlanSample.validated(
                plan: try ResourcePlanSample.plan(approval: .rejected)
            )
        }
    }

    @Test("A plan approval citing evidence the release does not carry is refused")
    func unresolvableApprovalRefused() throws {
        #expect(throws: ArtifactSchemaError.self) {
            try ResourcePlanSample.validated(
                plan: try ResourcePlanSample.plan(approvalEvidence: "approval.elsewhere")
            )
        }
    }

    // MARK: References

    @Test("A plan naming another capability manifest, suite, or bundle is refused")
    func mismatchedReferencesRefused() throws {
        #expect(throws: ArtifactSchemaError.self) {
            try ResourcePlanSample.validated(
                plan: try ResourcePlanSample.plan(capabilityManifest: "manifest.other")
            )
        }
        #expect(throws: ArtifactSchemaError.self) {
            try ResourcePlanSample.validated(
                plan: try ResourcePlanSample.plan(fixtureSuite: "suite.other")
            )
        }
        #expect(throws: ArtifactSchemaError.self) {
            try ResourcePlanSample.validated(
                plan: try ResourcePlanSample.plan(modelBundle: "bundle.unapproved")
            )
        }
    }

    @Test("A candidate configuration built from another application build is refused")
    func mismatchedCandidateBuildRefused() throws {
        #expect(throws: ArtifactSchemaError.self) {
            try ResourcePlanSample.validated(
                plan: try ResourcePlanSample.plan(
                    configurations: [try ResourcePlanSample.candidate(appBuild: "build.other")]
                )
            )
        }
    }

    @Test("A budget citing another Device Validation Plan is refused")
    func budgetCitingAnotherPlanRefused() throws {
        #expect(throws: ArtifactSchemaError.self) {
            try ResourcePlanSample.validated(
                budgets: try ResourcePlanSample.budgets(
                    mainApplicationPlan: "plan.other",
                    shareExtensionPlan: "plan.other"
                )
            )
        }
    }

    @Test("A fixture suite disagreeing with the manifest about provenance is refused")
    func provenanceApplicabilityMustAgree() throws {
        #expect(throws: ArtifactSchemaError.self) {
            try ResourcePlanSample.validated(
                fixtureSuite: try ResourcePlanSample.fixtureSuite(provenanceEnabled: true),
                provenanceEnabled: false
            )
        }
    }

    // MARK: Comparisons

    @Test("A plan omitting a required comparison is refused")
    func omittedComparisonRefused() throws {
        for omitted in ComparisonMetric.requiredComparisons(provenanceEnabled: false) {
            #expect(throws: ArtifactSchemaError.self) {
                try ResourcePlanSample.validated(
                    plan: try ResourcePlanSample.plan(
                        comparisons: try ResourcePlanSample.comparisons(omitting: [omitted])
                    )
                )
            }
        }
    }

    @Test("A pixel-only plan predeclaring the provenance comparison is refused")
    func unexpectedProvenanceComparisonRefused() throws {
        #expect(throws: ArtifactSchemaError.self) {
            try ResourcePlanSample.validated(
                plan: try ResourcePlanSample.plan(
                    comparisons: try ResourcePlanSample.comparisons(
                        including: [.provenanceState]
                    )
                )
            )
        }
    }

    @Test("A provenance-enabled plan omitting the provenance comparison is refused")
    func missingProvenanceComparisonRefused() throws {
        #expect(throws: ArtifactSchemaError.self) {
            try ResourcePlanSample.validated(
                plan: try ResourcePlanSample.plan(
                    provenanceEnabled: true,
                    comparisons: try ResourcePlanSample.comparisons(
                        provenanceEnabled: true,
                        omitting: [.provenanceState]
                    )
                ),
                provenanceEnabled: true
            )
        }
    }

    @Test("A comparison referencing evidence the release does not carry is refused")
    func unresolvableComparisonReferenceRefused() throws {
        var comparisons = try ResourcePlanSample.comparisons(omitting: [.rawLogit])
        comparisons.append(
            try ResourcePlanSample.comparison(.rawLogit, reference: "evidence.elsewhere")
        )
        #expect(throws: ArtifactSchemaError.self) {
            try ResourcePlanSample.validated(
                plan: try ResourcePlanSample.plan(comparisons: comparisons)
            )
        }
    }

    // MARK: Measurements

    @Test("A measurement for a device the plan does not list is refused")
    func measurementForUnlistedDeviceRefused() throws {
        let listed = try ResourcePlanSample.candidate()
        let unlisted = try ResourcePlanSample.candidate(hardware: "iPhone17.9")
        let measurements = try ResourcePlanSample.measurements(
            configurations: [listed],
            adding: [
                try ResourcePlanSample.measurement(
                    .warmAnalysisLatency,
                    target: .mainApplication,
                    configuration: unlisted
                )
            ]
        )
        #expect(throws: ArtifactSchemaError.self) {
            try ResourcePlanSample.validated(
                plan: try ResourcePlanSample.plan(
                    configurations: [listed],
                    measurements: measurements
                )
            )
        }
    }

    @Test("A measurement taken at another application build is refused")
    func measurementAtAnotherBuildRefused() throws {
        let candidate = try ResourcePlanSample.candidate()
        let mixed = try ResourcePlanSample.measurement(
            .warmAnalysisLatency,
            target: .mainApplication,
            configuration: candidate,
            appBuild: Sample.appBuild("build.other")
        )
        #expect(throws: ArtifactSchemaError.self) {
            try ResourcePlanSample.validated(
                plan: try ResourcePlanSample.plan(
                    configurations: [candidate],
                    measurements: try ResourcePlanSample.measurements(
                        configurations: [candidate],
                        replacing: mixed
                    )
                )
            )
        }
    }

    @Test("A measurement citing a workload the release does not carry is refused")
    func unresolvableWorkloadRefused() throws {
        let candidate = try ResourcePlanSample.candidate()
        let detached = try ResourcePlanSample.measurement(
            .warmAnalysisLatency,
            target: .mainApplication,
            configuration: candidate,
            workload: "evidence.elsewhere"
        )
        #expect(throws: ArtifactSchemaError.self) {
            try ResourcePlanSample.validated(
                plan: try ResourcePlanSample.plan(
                    configurations: [candidate],
                    measurements: try ResourcePlanSample.measurements(
                        configurations: [candidate],
                        replacing: detached
                    )
                )
            )
        }
    }

    // MARK: Authoritative limits

    @Test("A budget number the plan did not measure is refused")
    func unmeasuredBudgetNumberRefused() throws {
        #expect(throws: ArtifactSchemaError.self) {
            try ResourcePlanSample.validated(
                budgets: try ResourcePlanSample.budgets(
                    replacingMainApplication: try ResourcePlanSample.limitEntry(
                        .warmAnalysisLatency,
                        value: ResourcePlanSample.baselineLimitValue + 1
                    )
                )
            )
        }
    }

    @Test("A budget limit differing from one candidate's measurement is refused")
    func perDeviceLimitDisagreementRefused() throws {
        let first = try ResourcePlanSample.candidate()
        let second = try ResourcePlanSample.candidate(hardware: "iPhone17.2")
        // The second candidate is measured at a laxer limit than the first, so no single
        // shipped budget number can be the limit both were measured against.
        let relaxed = try ResourcePlanSample.measurement(
            .warmAnalysisLatency,
            target: .mainApplication,
            configuration: second,
            passLimit: ResourcePlanSample.limit(
                .warmAnalysisLatency,
                value: ResourcePlanSample.baselineLimitValue * 2
            )
        )
        #expect(throws: ArtifactSchemaError.self) {
            try ResourcePlanSample.validated(
                plan: try ResourcePlanSample.plan(
                    configurations: [first, second],
                    measurements: try ResourcePlanSample.measurements(
                        configurations: [first, second],
                        replacing: relaxed
                    )
                )
            )
        }
    }

    @Test("Two candidates measured at the same limit validate")
    func matchingPerDeviceLimitsValidate() throws {
        let first = try ResourcePlanSample.candidate()
        let second = try ResourcePlanSample.candidate(hardware: "iPhone17.2")
        let validated = try ResourcePlanSample.validated(
            plan: try ResourcePlanSample.plan(configurations: [first, second])
        )
        #expect(validated.candidateConfigurations.count == 2)
    }

    @Test("A numeric limit in the wrong unit is refused")
    func mismatchedUnitRefused() throws {
        #expect(throws: ArtifactSchemaError.self) {
            try ResourcePlanSample.validated(
                budgets: try ResourcePlanSample.budgets(
                    replacingMainApplication: try ResourcePlanSample.limitEntry(
                        .warmAnalysisLatency,
                        unit: .bytes
                    )
                )
            )
        }
    }

    @Test("Every metric declares the unit it is measured in")
    func requiredUnitsAreFixed() {
        #expect(ResourceMetric.decodedPixelCount.requiredUnit == .pixels)
        #expect(ResourceMetric.encodedInputSize.requiredUnit == .bytes)
        #expect(ResourceMetric.peakResidentMemory.requiredUnit == .bytes)
        #expect(ResourceMetric.temporaryStorage.requiredUnit == .bytes)
        #expect(ResourceMetric.energyImpact.requiredUnit == .milliwattHours)
        #expect(ResourceMetric.thermalState.requiredUnit == nil)
        for metric in [
            ResourceMetric.coldModelLoadTime, .warmAnalysisLatency, .handoffLatency,
        ] {
            #expect(metric.requiredUnit == .milliseconds)
            #expect(metric.measuresElapsedTime)
        }
        #expect(!ResourceMetric.peakResidentMemory.measuresElapsedTime)
        #expect(!ResourceMetric.thermalState.measuresElapsedTime)
    }

    @Test("A thermal limit of critical admits everything and is refused")
    func criticalThermalLimitRefused() throws {
        #expect(throws: ArtifactSchemaError.self) {
            try ResourcePlanSample.validated(
                budgets: try ResourcePlanSample.budgets(
                    replacingMainApplication: try ResourcePlanSample.limitEntry(
                        .thermalState,
                        thermal: .critical
                    )
                )
            )
        }
    }

    @Test("Measurement conditions the release does not carry are refused")
    func unresolvableConditionsRefused() throws {
        #expect(throws: ArtifactSchemaError.self) {
            try ResourcePlanSample.validated(
                budgets: try ResourcePlanSample.budgets(
                    replacingShareExtension: try ResourcePlanSample.limitEntry(
                        .handoffLatency,
                        conditions: "evidence.elsewhere"
                    )
                )
            )
        }
    }

    // MARK: Analysis-time authority

    @Test("An analysis-time limit comes from the plan and only for a time metric")
    func analysisTimeLimitsComeFromThePlan() throws {
        let validated = try ResourcePlanSample.validated()

        for (metric, target) in [
            (ResourceMetric.coldModelLoadTime, ExecutionTarget.mainApplication),
            (.warmAnalysisLatency, .mainApplication),
            (.handoffLatency, .shareExtension),
        ] {
            let limit = try #require(
                validated.analysisTimeLimitMilliseconds(metric, for: target)
            )
            #expect(limit.value == ResourcePlanSample.baselineLimitValue)
        }

        // Not an elapsed-time metric: there is no analysis-time limit to report, and no
        // number is invented in its place.
        #expect(
            validated.analysisTimeLimitMilliseconds(
                .peakResidentMemory,
                for: .mainApplication
            ) == nil
        )
        #expect(validated.analysisTimeLimitMilliseconds(.thermalState, for: .mainApplication) == nil)
        // A time metric of the other target is not this target's limit.
        #expect(
            validated.analysisTimeLimitMilliseconds(
                .handoffLatency,
                for: .mainApplication
            ) == nil
        )
        #expect(
            validated.analysisTimeLimitMilliseconds(
                .warmAnalysisLatency,
                for: .shareExtension
            ) == nil
        )
    }

    // MARK: Branch execution

    @Test("Concurrent evidence branches need the plan to have measured them")
    func concurrencyRequiresMeasurement() throws {
        let candidate = try ResourcePlanSample.candidate()
        let serial = try ResourcePlanSample.validated(
            plan: try ResourcePlanSample.plan(configurations: [candidate])
        )
        #expect(!serial.approvesConcurrentEvidenceBranches(for: candidate))

        let concurrent = try ResourcePlanSample.validated(
            plan: try ResourcePlanSample.plan(
                configurations: [candidate],
                measurements: try ResourcePlanSample.measurements(
                    configurations: [candidate],
                    branchExecution: .concurrent
                )
            )
        )
        #expect(concurrent.approvesConcurrentEvidenceBranches(for: candidate))

        // One main-application metric measured serially is enough to withhold approval:
        // a partially measured execution policy is not an approved one.
        let mixed = try ResourcePlanSample.validated(
            plan: try ResourcePlanSample.plan(
                configurations: [candidate],
                measurements: try ResourcePlanSample.measurements(
                    configurations: [candidate],
                    branchExecution: .concurrent,
                    replacing: try ResourcePlanSample.measurement(
                        .warmAnalysisLatency,
                        target: .mainApplication,
                        configuration: candidate,
                        branchExecution: .serial
                    )
                )
            )
        )
        #expect(!mixed.approvesConcurrentEvidenceBranches(for: candidate))

        // A configuration this plan never measured is never approved for concurrency.
        let unlisted = try ResourcePlanSample.candidate(hardware: "iPhone17.9")
        #expect(!concurrent.approvesConcurrentEvidenceBranches(for: unlisted))
    }
}

@Suite("Admissible device validation results")
struct AdmissibleDeviceValidationResultTests {
    @Test("A complete physical-device result set is admissible")
    func completeResultSetAdmissible() throws {
        let plan = try ResourcePlanSample.validated()
        let admitted = try AdmissibleDeviceValidationResult(
            admitting: try ResourcePlanSample.resultSet(),
            under: plan
        )
        let candidate = try ResourcePlanSample.candidate()
        #expect(admitted.plan == plan.id)
        #expect(admitted.satisfiesEveryMandatoryGate)
        #expect(admitted.configuration == candidate)
    }

    @Test("A simulator result set is never release evidence")
    func simulatorResultSetInadmissible() throws {
        let plan = try ResourcePlanSample.validated()
        for environment in ExecutionEnvironment.allCases
        where environment != .physicalIPhone {
            #expect(throws: ArtifactSchemaError.self) {
                try AdmissibleDeviceValidationResult(
                    admitting: try ResourcePlanSample.resultSet(environment: environment),
                    under: plan
                )
            }
        }
    }

    @Test("A result set produced under other versions is inadmissible")
    func mismatchedVersionTupleInadmissible() throws {
        let plan = try ResourcePlanSample.validated()

        /// The baseline tuple with exactly one element pointed somewhere else.
        func tuple(
            modelBundle: String = "bundle.sample",
            fixtureSuite: String = ResourcePlanSample.fixtureSuiteIdentifier,
            validationPlan: String = ResourcePlanSample.planIdentifier,
            capabilityManifest: String = ResourcePlanSample.manifestIdentifier
        ) throws -> ValidationVersionTuple {
            try ValidationVersionTuple(
                appBuild: Sample.appBuild(),
                modelBundle: Sample.bundle(modelBundle),
                fixtureSuite: Sample.artifact(fixtureSuite),
                validationPlan: Sample.artifact(validationPlan),
                capabilityManifest: Sample.artifact(capabilityManifest),
                capabilities: [.pixelAnalysis],
                capabilityImplementationVersions: [
                    CapabilityImplementationEntry(
                        capability: .pixelAnalysis,
                        version: Sample.version()
                    )
                ]
            )
        }

        // The baseline tuple is the plan's own, so only the mutations are refused.
        _ = try AdmissibleDeviceValidationResult(
            admitting: try ResourcePlanSample.resultSet(versionTuple: try tuple()),
            under: plan
        )
        for mutated in [
            try tuple(modelBundle: "bundle.other"),
            try tuple(fixtureSuite: "suite.other"),
            try tuple(validationPlan: "plan.other"),
            try tuple(capabilityManifest: "manifest.other"),
        ] {
            #expect(throws: ArtifactSchemaError.self) {
                try AdmissibleDeviceValidationResult(
                    admitting: try ResourcePlanSample.resultSet(versionTuple: mutated),
                    under: plan
                )
            }
        }
    }

    @Test("A result set recorded under another capability set is inadmissible")
    func mismatchedCapabilitySetInadmissible() throws {
        let plan = try ResourcePlanSample.validated()
        #expect(throws: ArtifactSchemaError.self) {
            try AdmissibleDeviceValidationResult(
                admitting: try ResourcePlanSample.resultSet(provenanceEnabled: true),
                under: plan
            )
        }
    }

    @Test("A result set for a configuration the plan does not cover is inadmissible")
    func unlistedConfigurationInadmissible() throws {
        let plan = try ResourcePlanSample.validated()
        #expect(throws: ArtifactSchemaError.self) {
            try AdmissibleDeviceValidationResult(
                admitting: try ResourcePlanSample.resultSet(
                    configuration: try ResourcePlanSample.candidate(hardware: "iPhone17.9")
                ),
                under: plan
            )
        }
    }

    @Test("A missing measurement is never a pass")
    func missingMeasurementInadmissible() throws {
        let plan = try ResourcePlanSample.validated()
        // The gate that reports handoff latency records a comparison instead, so the
        // metric has no result anywhere in the set.
        let stripped = try ResourcePlanSample.gateRecord(
            .handoffLatency,
            measurements: [],
            comparisons: [try ResourcePlanSample.comparisonRecord(.categoricalOutcome)]
        )
        #expect(throws: ArtifactSchemaError.self) {
            try AdmissibleDeviceValidationResult(
                admitting: try ResourcePlanSample.resultSet(
                    gateResults: try ResourcePlanSample.gateRecords(
                        overrides: [.handoffLatency: stripped]
                    )
                ),
                under: plan
            )
        }
    }

    @Test("An unexecuted measurement is a missing result rather than a pass")
    func unexecutedMeasurementInadmissible() throws {
        let plan = try ResourcePlanSample.validated()
        let unexecuted = try ResourcePlanSample.gateRecord(
            .coldModelLoad,
            measurements: [
                try ResourcePlanSample.measurementRecord(
                    .coldModelLoadTime,
                    target: .mainApplication,
                    rawValues: [],
                    outcome: .notExecuted
                )
            ],
            outcome: .notExecuted
        )
        #expect(throws: ArtifactSchemaError.self) {
            try AdmissibleDeviceValidationResult(
                admitting: try ResourcePlanSample.resultSet(
                    gateResults: try ResourcePlanSample.gateRecords(
                        overrides: [.coldModelLoad: unexecuted]
                    )
                ),
                under: plan
            )
        }
    }

    @Test("A measurement taken against another limit or statistic is inadmissible")
    func mismatchedMeasurementContractInadmissible() throws {
        let plan = try ResourcePlanSample.validated()

        let otherLimit = try ResourcePlanSample.gateRecord(
            .warmAnalysisLatency,
            measurements: [
                try ResourcePlanSample.measurementRecord(
                    .warmAnalysisLatency,
                    target: .mainApplication,
                    limit: ResourcePlanSample.limit(
                        .warmAnalysisLatency,
                        value: ResourcePlanSample.baselineLimitValue * 3
                    )
                )
            ]
        )
        #expect(throws: ArtifactSchemaError.self) {
            try AdmissibleDeviceValidationResult(
                admitting: try ResourcePlanSample.resultSet(
                    gateResults: try ResourcePlanSample.gateRecords(
                        overrides: [.warmAnalysisLatency: otherLimit]
                    )
                ),
                under: plan
            )
        }

        let otherStatistic = try ResourcePlanSample.gateRecord(
            .warmAnalysisLatency,
            measurements: [
                try ResourcePlanSample.measurementRecord(
                    .warmAnalysisLatency,
                    target: .mainApplication,
                    summaryStatistic: .maximum
                )
            ]
        )
        #expect(throws: ArtifactSchemaError.self) {
            try AdmissibleDeviceValidationResult(
                admitting: try ResourcePlanSample.resultSet(
                    gateResults: try ResourcePlanSample.gateRecords(
                        overrides: [.warmAnalysisLatency: otherStatistic]
                    )
                ),
                under: plan
            )
        }
    }

    @Test("A measurement citing a specification other than the plan is inadmissible")
    func mismatchedSpecificationInadmissible() throws {
        let plan = try ResourcePlanSample.validated()
        let detached = try ResourcePlanSample.gateRecord(
            .mainApplicationEnergy,
            measurements: [
                try ResourcePlanSample.measurementRecord(
                    .energyImpact,
                    target: .mainApplication,
                    specification: "plan.other"
                )
            ]
        )
        #expect(throws: ArtifactSchemaError.self) {
            try AdmissibleDeviceValidationResult(
                admitting: try ResourcePlanSample.resultSet(
                    gateResults: try ResourcePlanSample.gateRecords(
                        overrides: [.mainApplicationEnergy: detached]
                    )
                ),
                under: plan
            )
        }
    }

    @Test("A summary outside the samples it summarizes is inadmissible")
    func fabricatedSummaryInadmissible() throws {
        let plan = try ResourcePlanSample.validated()
        let fabricated = try ResourcePlanSample.gateRecord(
            .mainApplicationPeakMemory,
            measurements: [
                try ResourcePlanSample.measurementRecord(
                    .peakResidentMemory,
                    target: .mainApplication,
                    rawValues: [90, 100],
                    summaryValue: 80
                ),
                try ResourcePlanSample.measurementRecord(
                    .decodedPixelCount,
                    target: .mainApplication
                ),
            ]
        )
        #expect(throws: ArtifactSchemaError.self) {
            try AdmissibleDeviceValidationResult(
                admitting: try ResourcePlanSample.resultSet(
                    gateResults: try ResourcePlanSample.gateRecords(
                        overrides: [.mainApplicationPeakMemory: fabricated]
                    )
                ),
                under: plan
            )
        }
    }

    @Test("A pass above the limit, or a failure below it, is inadmissible")
    func outcomeMustFollowFromTheMeasurement() throws {
        let plan = try ResourcePlanSample.validated()
        let overLimit = ResourcePlanSample.baselineLimitValue + 1

        let falsePass = try ResourcePlanSample.gateRecord(
            .warmAnalysisLatency,
            measurements: [
                try ResourcePlanSample.measurementRecord(
                    .warmAnalysisLatency,
                    target: .mainApplication,
                    rawValues: [overLimit],
                    summaryValue: overLimit,
                    outcome: .passed
                )
            ]
        )
        #expect(throws: ArtifactSchemaError.self) {
            try AdmissibleDeviceValidationResult(
                admitting: try ResourcePlanSample.resultSet(
                    gateResults: try ResourcePlanSample.gateRecords(
                        overrides: [.warmAnalysisLatency: falsePass]
                    )
                ),
                under: plan
            )
        }

        let falseFailure = try ResourcePlanSample.gateRecord(
            .warmAnalysisLatency,
            measurements: [
                try ResourcePlanSample.measurementRecord(
                    .warmAnalysisLatency,
                    target: .mainApplication,
                    outcome: .failed
                )
            ],
            outcome: .failed
        )
        #expect(throws: ArtifactSchemaError.self) {
            try AdmissibleDeviceValidationResult(
                admitting: try ResourcePlanSample.resultSet(
                    gateResults: try ResourcePlanSample.gateRecords(
                        overrides: [.warmAnalysisLatency: falseFailure]
                    )
                ),
                under: plan
            )
        }
    }

    @Test("A recorded breach is admissible evidence and fails its gate")
    func recordedBreachIsAdmissibleAndFails() throws {
        let plan = try ResourcePlanSample.validated()
        let overLimit = ResourcePlanSample.baselineLimitValue + 1
        let breach = try ResourcePlanSample.gateRecord(
            .warmAnalysisLatency,
            measurements: [
                try ResourcePlanSample.measurementRecord(
                    .warmAnalysisLatency,
                    target: .mainApplication,
                    rawValues: [overLimit],
                    summaryValue: overLimit,
                    outcome: .failed
                )
            ],
            outcome: .failed
        )
        let admitted = try AdmissibleDeviceValidationResult(
            admitting: try ResourcePlanSample.resultSet(
                gateResults: try ResourcePlanSample.gateRecords(
                    overrides: [.warmAnalysisLatency: breach]
                )
            ),
            under: plan
        )
        #expect(!admitted.satisfiesEveryMandatoryGate)
        #expect(admitted.results.unsatisfiedGates == [.warmAnalysisLatency])
    }

    @Test("A missing comparison is never a pass")
    func missingComparisonInadmissible() throws {
        let plan = try ResourcePlanSample.validated()
        let stripped = try ResourcePlanSample.gateRecord(
            .rawLogitParity,
            comparisons: [try ResourcePlanSample.comparisonRecord(.categoricalOutcome)]
        )
        #expect(throws: ArtifactSchemaError.self) {
            try AdmissibleDeviceValidationResult(
                admitting: try ResourcePlanSample.resultSet(
                    gateResults: try ResourcePlanSample.gateRecords(
                        overrides: [.rawLogitParity: stripped]
                    )
                ),
                under: plan
            )
        }
    }

    @Test("A numeric comparison with no measured deviation is inadmissible")
    func numericComparisonNeedsDeviation() throws {
        let plan = try ResourcePlanSample.validated()
        let undeclared = try ResourcePlanSample.gateRecord(
            .preprocessingParity,
            comparisons: [
                try ResourcePlanSample.comparisonRecord(
                    .preprocessingOutput,
                    maximumDeviation: nil
                )
            ]
        )
        #expect(throws: ArtifactSchemaError.self) {
            try AdmissibleDeviceValidationResult(
                admitting: try ResourcePlanSample.resultSet(
                    gateResults: try ResourcePlanSample.gateRecords(
                        overrides: [.preprocessingParity: undeclared]
                    )
                ),
                under: plan
            )
        }
    }

    @Test("A comparison pass outside the declared tolerance is inadmissible")
    func comparisonPassMustBeWithinTolerance() throws {
        let plan = try ResourcePlanSample.validated()
        let overTolerance = try ResourcePlanSample.gateRecord(
            .rawLogitParity,
            comparisons: [
                try ResourcePlanSample.comparisonRecord(.rawLogit, maximumDeviation: 2)
            ]
        )
        #expect(throws: ArtifactSchemaError.self) {
            try AdmissibleDeviceValidationResult(
                admitting: try ResourcePlanSample.resultSet(
                    gateResults: try ResourcePlanSample.gateRecords(
                        overrides: [.rawLogitParity: overTolerance]
                    )
                ),
                under: plan
            )
        }
    }

    @Test("Categorical agreement below the declared ratio cannot pass")
    func categoricalAgreementMustMeetTheRatio() throws {
        let plan = try ResourcePlanSample.validated()
        let shortfall = try ResourcePlanSample.gateRecord(
            .categoricalAgreement,
            comparisons: [
                try ResourcePlanSample.comparisonRecord(
                    .categoricalOutcome,
                    compared: 96,
                    agreeing: 95
                )
            ]
        )
        #expect(throws: ArtifactSchemaError.self) {
            try AdmissibleDeviceValidationResult(
                admitting: try ResourcePlanSample.resultSet(
                    gateResults: try ResourcePlanSample.gateRecords(
                        overrides: [.categoricalAgreement: shortfall]
                    )
                ),
                under: plan
            )
        }
    }

    @Test("A passing gate cannot carry a failing result")
    func gateOutcomeFollowsItsResults() throws {
        let plan = try ResourcePlanSample.validated()
        let overLimit = ResourcePlanSample.baselineLimitValue + 1
        let inconsistent = try ResourcePlanSample.gateRecord(
            .handoffLatency,
            measurements: [
                try ResourcePlanSample.measurementRecord(
                    .handoffLatency,
                    target: .shareExtension,
                    rawValues: [overLimit],
                    summaryValue: overLimit,
                    outcome: .failed
                )
            ],
            outcome: .passed
        )
        #expect(throws: ArtifactSchemaError.self) {
            try AdmissibleDeviceValidationResult(
                admitting: try ResourcePlanSample.resultSet(
                    gateResults: try ResourcePlanSample.gateRecords(
                        overrides: [.handoffLatency: inconsistent]
                    )
                ),
                under: plan
            )
        }
    }

    @Test("Both targets are required separately")
    func bothTargetSetsRequired() throws {
        let plan = try ResourcePlanSample.validated()
        // Every Share Extension gate records a comparison instead of its measurement, so
        // the main-application set is complete and the extension set is empty.
        var overrides: [DeviceGate: DeviceGateResultRecord] = [:]
        for gate in DeviceGate.allCases where gate.measurementTarget == .shareExtension {
            overrides[gate] = try ResourcePlanSample.gateRecord(
                gate,
                measurements: [],
                comparisons: [try ResourcePlanSample.comparisonRecord(.categoricalOutcome)]
            )
        }
        #expect(throws: ArtifactSchemaError.self) {
            try AdmissibleDeviceValidationResult(
                admitting: try ResourcePlanSample.resultSet(
                    gateResults: try ResourcePlanSample.gateRecords(overrides: overrides)
                ),
                under: plan
            )
        }
    }
}
