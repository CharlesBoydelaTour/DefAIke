import DefAIkeDomain
import Foundation

// Step 6 of the fixed verification order: load the candidate and run its release
// self-tests offline under the active approved budget.
//
// Requirement 10.11 makes this the candidate's own test suite, not a rerun of the active
// bundle's, so the runner works entirely from a ``CompatibleBundleCandidate``: the model it
// loads, the fixtures it reads, the expectations it compares against, and the contracts it
// hands the executor all come from that one candidate.
//
// Three properties are worth naming because they are what makes a passing run mean
// something:
//
//   * Offline by construction. Every fixture byte comes from the candidate's own
//     digest-verified local tree through the same content seam step 3 used. There is no
//     member anywhere in this module's graph that could fetch one, so "with network
//     connectivity disabled" is a fact about the dependency graph rather than a runtime
//     hope (Requirements 10.20 and 10.21).
//   * Governed by the approved budget. The active Resource Budget for the main application
//     is read, never chosen: headroom is reserved before a fixture is loaded and released
//     afterwards, and the run stops on the first measured hard-limit breach. Nothing here
//     raises, waives, or supplies a limit, and the port it uses has no member that could.
//   * Comparison, not judgement. The executor reports observations; this file compares them
//     to the bundle's declared expectations and their declared tolerances. A missing
//     observation for a declared expectation is a finding, so a run that quietly produced
//     nothing cannot pass (Requirement 10.10).
//
// A candidate that fails anything below produces a finding and no value, so it cannot
// reach activation and cannot disturb the active bundle (Requirement 10.12).

/// Runs one compatible candidate's release self-tests offline.
///
/// Holds no mutable state of its own; the loaded model's lifetime is bounded by one call
/// to ``run(_:)``, and every exit path unloads it, so a rejected candidate never stays
/// resident.
public struct ReleaseSelfTestRunner: Sendable {
    /// The execution target release self-tests run in.
    ///
    /// Fixed, not configured: pixel inference exists only in the main application, and the
    /// Share Extension runs none (Requirements 2.6 and 11.3). The runner refuses the other
    /// target's budget rather than accepting a number measured for a process that never
    /// loads a model.
    public static let governedTarget: ExecutionTarget = .mainApplication

    private let execution: any ReleaseSelfTestExecuting
    private let content: any ModelBundleContentReading
    private let resources: any ResourceGoverning
    private let budget: ResourceBudget

    /// Creates a runner bound to one executor, one content seam, and one approved budget.
    ///
    /// Every argument is required with no default. In particular there is no default
    /// executor: a build that has not been given one cannot run self-tests, and a candidate
    /// whose self-tests did not run is never a candidate that passed.
    public init(
        execution: any ReleaseSelfTestExecuting,
        content: any ModelBundleContentReading,
        resources: any ResourceGoverning,
        budget: ResourceBudget
    ) {
        self.execution = execution
        self.content = content
        self.resources = resources
        self.budget = budget
    }

    /// Runs every case in `candidate`'s plan and compares each result to its declared
    /// expectations.
    ///
    /// Returns only when every case ran and every declared expectation agreed. Anything
    /// else is a finding.
    public func run(
        _ candidate: CompatibleBundleCandidate
    ) async throws(ModelBundleVerificationError) -> SelfTestedBundleCandidate {
        try requireGovernedBudget()

        // Sampled before the model is loaded, so a device already at a hard limit does not
        // have a candidate loaded onto it first.
        var unmeasurable = try await observedMetrics()

        let context = candidate.executionContext
        let model: LoadedModelToken
        do {
            model = try await execution.loadCandidate(context)
        } catch {
            throw ModelBundleVerificationError.selfTestCandidateLoadFailed(candidate.bundleID)
        }

        var executed: [SelfTestCaseID] = []
        var compared = 0
        do {
            for testCase in candidate.selfTests.cases {
                try await runCase(testCase, on: model, context: context)
                executed.append(testCase.id)
                compared += testCase.expectations.count
                unmeasurable.formUnion(try await observedMetrics())
            }
        } catch {
            // A rejected candidate must not stay loaded, however it was rejected.
            await execution.unload(model)
            throw error
        }
        await execution.unload(model)

        return SelfTestedBundleCandidate(
            candidate: candidate,
            report: SelfTestRunReport(
                specificationID: candidate.selfTests.specificationID,
                executedCases: executed,
                comparedExpectationCount: compared,
                resourceBudgetID: budget.id,
                unmeasurableMetrics: Array(unmeasurable)
            )
        )
    }

    // MARK: - The approved budget

    /// Requires the supplied budget and controller to govern the main application.
    ///
    /// Both halves matter. A budget measured for the Share Extension describes a process
    /// that never loads a model, and a controller for the other target would enforce it
    /// against the wrong limits.
    private func requireGovernedBudget() throws(ModelBundleVerificationError) {
        guard budget.target == Self.governedTarget else {
            throw ModelBundleVerificationError.selfTestBudgetTargetMismatch(
                expected: Self.governedTarget,
                found: budget.target
            )
        }
        guard resources.target == Self.governedTarget else {
            throw ModelBundleVerificationError.selfTestBudgetTargetMismatch(
                expected: Self.governedTarget,
                found: resources.target
            )
        }
    }

    /// Samples every metric the budget defines and reports the unmeasurable ones.
    ///
    /// A measured breach stops the run: the self-tests did not complete, and an incomplete
    /// run is not a pass. An unmeasurable metric is neither a breach nor a pass — it is
    /// recorded in the report and does not decide anything, because treating "cannot
    /// measure" as "exceeded" would make a candidate unverifiable in an environment that
    /// simply has no counter for it.
    private func observedMetrics()
        async throws(ModelBundleVerificationError) -> Set<ResourceMetric>
    {
        var unmeasurable = Set<ResourceMetric>()
        for entry in budget.hardLimits {
            let observation = await resources.observe(entry.metric, budget: budget)
            if observation.breachesHardLimit {
                throw ModelBundleVerificationError.selfTestResourceLimitReached(entry.metric)
            }
            if !observation.isMeasured {
                unmeasurable.insert(entry.metric)
            }
        }
        return unmeasurable
    }

    /// Reserves headroom for one fixture's bytes, or reports the breach.
    ///
    /// Reserved before the bytes are read rather than after, which is the only ordering in
    /// which a reservation can prevent anything. A fixture whose declared size does not fit
    /// the active budget is refused without being loaded.
    private func reservation(
        forFixtureBytes byteCount: UInt64
    ) async throws(ModelBundleVerificationError) -> ResourceReservation? {
        guard let amount = try? PositiveDecimal(validating: Decimal(byteCount)),
              let request = ResourceReservationRequest(
                  metric: .peakResidentMemory,
                  amount: amount,
                  unit: .bytes,
                  stage: .modelLoad
              )
        else {
            // A catalogued fixture always declares a positive byte count, so this is
            // unreachable for a resolved plan. Reserving nothing is the fail-closed choice
            // if it ever were: the metric is still sampled after every case.
            return nil
        }
        do {
            return try await resources.reserve(request, budget: budget)
        } catch {
            // A measured breach and anything else are reported apart, so a cancelled
            // reservation is never written down as a budget breach. Both refuse the
            // candidate: the run did not complete either way.
            guard error.analysisError == .resourceLimit else {
                throw ModelBundleVerificationError.selfTestResourceReservationRefused(
                    .peakResidentMemory
                )
            }
            throw ModelBundleVerificationError.selfTestResourceLimitReached(.peakResidentMemory)
        }
    }

    // MARK: - One case

    /// Reserves headroom, reads one fixture, runs it, and compares the result.
    ///
    /// The reservation is held for as long as the bytes are resident — through execution,
    /// not only through the read — because peak resident memory is what the budget limits.
    /// It is returned on every exit path, so a failing case does not leak headroom that
    /// would then refuse the next one.
    private func runCase(
        _ testCase: VerifiedSelfTestCase,
        on model: LoadedModelToken,
        context: SelfTestExecutionContext
    ) async throws(ModelBundleVerificationError) {
        let held = try await reservation(forFixtureBytes: testCase.byteCount)
        do {
            let bytes = try readFixture(testCase, in: context.bundleID)
            let payload = SelfTestFixturePayload(
                fixture: testCase.fixture,
                assetPath: testCase.assetPath,
                bytes: bytes,
                contentDigest: testCase.contentDigest
            )
            let observed = try await observation(
                for: testCase,
                payload: payload,
                model: model,
                context: context
            )
            try compare(testCase, against: observed)
        } catch {
            if let held { await resources.release(held) }
            throw error
        }
        if let held { await resources.release(held) }
    }

    private func readFixture(
        _ testCase: VerifiedSelfTestCase,
        in bundle: ModelBundleID
    ) throws(ModelBundleVerificationError) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(Int(min(testCase.byteCount, UInt64(Int.max))))
        var exceeded = false
        do {
            try content.readFile(
                at: testCase.assetPath,
                in: bundle,
                chunkByteCount: ModelBundleIntegrityVerifier.readChunkByteCount
            ) { chunk in
                guard UInt64(bytes.count) + UInt64(chunk.count) <= testCase.byteCount else {
                    exceeded = true
                    return .stop
                }
                bytes.append(contentsOf: chunk)
                return .proceed
            }
        } catch {
            throw ModelBundleVerificationError.artifactUnreadable(testCase.assetPath)
        }
        guard !exceeded else {
            throw ModelBundleVerificationError.selfTestFixtureLargerThanCatalogued(
                fixture: testCase.fixture,
                declared: testCase.byteCount
            )
        }
        guard UInt64(bytes.count) == testCase.byteCount else {
            throw ModelBundleVerificationError.selfTestFixtureByteCountMismatch(
                fixture: testCase.fixture,
                declared: testCase.byteCount,
                found: UInt64(bytes.count)
            )
        }
        guard StreamingSHA256.digest(of: bytes) == testCase.contentDigest else {
            throw ModelBundleVerificationError.selfTestFixtureDigestMismatch(testCase.fixture)
        }
        return bytes
    }

    /// Runs one case and maps an executor fault to the finding it deserves.
    private func observation(
        for testCase: VerifiedSelfTestCase,
        payload: SelfTestFixturePayload,
        model: LoadedModelToken,
        context: SelfTestExecutionContext
    ) async throws(ModelBundleVerificationError) -> SelfTestObservation {
        do {
            return try await execution.run(payload, on: model, context: context)
        } catch {
            switch error {
            case .modelLoadFailed:
                throw ModelBundleVerificationError.selfTestCandidateLoadFailed(context.bundleID)
            case .executionFailed:
                throw ModelBundleVerificationError.selfTestExecutionFailed(testCase.id)
            case .invalidOutput:
                throw ModelBundleVerificationError.selfTestOutputInvalid(testCase.id)
            }
        }
    }

    /// Compares one case's observation against every expectation it declares.
    ///
    /// A declared expectation with no observed value and one with a disagreeing value are
    /// separate findings, because "the run produced nothing" and "the run produced the
    /// wrong thing" are different release defects.
    private func compare(
        _ testCase: VerifiedSelfTestCase,
        against observation: SelfTestObservation
    ) throws(ModelBundleVerificationError) {
        for expectation in testCase.expectations {
            guard observation.carriesValue(for: expectation.kind) else {
                throw ModelBundleVerificationError.selfTestExpectationNotProduced(
                    case: testCase.id,
                    kind: expectation.kind
                )
            }
            guard expectation.isSatisfied(by: observation) else {
                throw ModelBundleVerificationError.selfTestExpectationMismatch(
                    case: testCase.id,
                    kind: expectation.kind
                )
            }
        }
    }
}
