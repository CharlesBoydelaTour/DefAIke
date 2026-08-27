import DefAIkeTestSupport
import Foundation
import PropertyBased
import Testing

@testable import DefAIkeDomain

// Design Property 24: benchmark claims are completely bound.
//
// The design states it as: for any proposed user-facing benchmark claim, publication is
// allowed only when the claim includes immutable dataset identity and composition,
// degradation condition, model and Calibration Policy versions, sample counts, coverage,
// metric definition, evidence provenance, and uncertainty interval.
//
// Quantified here as one property with six arms over every generated shape. "Includes"
// is read in both of the senses the code distinguishes, because either one alone would
// leave a claim publishable that the requirement excludes:
//
//   * structurally — the member is in the encoded artifact at all. This is the arm the
//     task names: every one of the 14 top-level members is removed from the payload text
//     in turn, and each removal has to fail the decode. Nothing may supply a default;
//     ``BenchmarkClaimRecord`` has no optional member and no defaulted parameter, and
//     this arm is what keeps that true as the record changes.
//   * semantically — the member names something. A present field can still bind the
//     claim to nothing: a citation the release cannot resolve, a citation at a digest
//     other than the content the release carries, a measurement of another model,
//     Model Bundle, or Calibration Policy, a limitations document or correction channel
//     this release does not publish, a claim identifier that is a placeholder token, no
//     eligible image, no decisive label, zero coverage, a coverage that contradicts the
//     counts, or a point value where an uncertainty interval belongs.
//
// The arms:
//
//   * complete — a coherent generated claim is publishable, and every number and
//     reference the validated claim reports is the one the shape generated, unchanged;
//   * structural — each of the 14 encoded members removed in turn is refused, with the
//     untouched payload decoding back to the identical claim as the positive control;
//   * citations — each of the 7 cited records made unresolvable in turn is refused, and
//     so is a citation to other content at the same identifier;
//   * release binding — another model, bundle, Calibration Policy, limitations document,
//     or correction channel is refused, and so is a placeholder claim identifier;
//   * measured support — no eligible image, no decisive label, zero coverage, and a
//     coverage that contradicts the counts at either endpoint are refused, with both
//     coherent coverage regimes accepted as the positive control;
//   * uncertainty — a point "interval" and a degenerate confidence level are refused,
//     and an inverted interval is unrepresentable.
//
// ``ValidatedBenchmarkClaimTests`` pins each of these refusals at one field with one
// example. This file quantifies the same statement over generated shapes. The
// neighbouring property belongs to its own task: Property 33 is whether the release
// readiness record as a whole is auditable and fail-closed, and it is the layer that
// decides which claims a release publishes at all.
//
// No value here is an approved benchmark result, dataset, budget, or confidence level.
// Every count is a small synthetic integer, every ratio is a generated multiple of one
// thousandth, every identifier carries the generated seed, and the whole shape exists so
// that publication can be asked to refuse it.

extension Tag {
    /// Design Property 24.
    ///
    /// Declared in this file rather than in a shared tag namespace: each design property
    /// gets one dedicated file, and a shared namespace would be a merge point between
    /// property files written independently of each other.
    @Tag static var property24BenchmarkClaimBindings: Self
}

@Suite(
    "Property 24: benchmark claims are completely bound",
    .tags(.property24BenchmarkClaimBindings)
)
struct BenchmarkClaimBindingPropertyTests {
    /// Runs at the library default of 100 generated cases with shrinking, which is the
    /// minimum the design requires; `PropertyToolchainWiringTests` pins that default.
    ///
    /// **Validates: Requirements 8.16**
    @Test("Publication requires every binding over generated claims")
    func benchmarkClaimsAreCompletelyBound() async {
        let witness = BenchmarkClaimVariationWitness()

        await propertyCheck(input: BenchmarkClaimShape.generator) { shape in
            witness.record(shape)
            let scenario = BenchmarkClaimScenario(shape: shape)

            scenario.checkCompleteClaimIsPublishable()
            scenario.checkEveryEncodedMemberIsRequired()
            scenario.checkEveryCitationMustResolve()
            scenario.checkClaimDescribesTheReleaseThatPublishesIt()
            scenario.checkMeasuredSupportIsRequired()
            scenario.checkUncertaintyIntervalIsAnInterval()
        }

        witness.expectVariedBaselines()
    }
}

// MARK: - Generated shape

/// The label counts behind one generated claim, as plain data.
///
/// Split into decisive and insufficient rather than into the nine fields
/// ``SliceOutcomeCounts`` carries, because the two groups are what the claim layer reads:
/// Requirement 5.18 pools both ground-truth populations for coverage, and the decisive
/// total is the numerator. Eligible counts are derived rather than generated, so the
/// per-population sums the schema requires hold by construction and a generated case can
/// never fail for a reason this property is not about.
private struct CountsShape: Sendable {
    /// Decisive label counts, in real-positive, real-non-positive, synthetic-positive,
    /// synthetic-non-positive order.
    let decisiveLabels: [Int]

    /// Insufficient label counts, in real, synthetic order.
    let insufficientLabels: [Int]

    let errorCount: Int

    /// Which decisive count is raised to guarantee at least one decisive label.
    ///
    /// A floor is needed because a claim with no decisive label is one of the refusals
    /// this property asserts, so the baseline may not land there by chance. Selecting the
    /// slot rather than fixing it keeps every one of the four able to be the nonzero one.
    let decisiveFloor: Int

    /// Which insufficient count is raised, in the regime that has any.
    let insufficientFloor: Int

    /// The four decisive counts with the floor applied. Their total is at least 1.
    var decisiveCounts: [Int] {
        var counts = decisiveLabels
        counts[decisiveFloor % counts.count] += 1
        return counts
    }

    /// The two insufficient counts with the floor applied. Their total is at least 1.
    var insufficientCounts: [Int] {
        var counts = insufficientLabels
        counts[insufficientFloor % counts.count] += 1
        return counts
    }
}

/// One generated uncertainty interval, as plain data.
///
/// Bounds and level are whole thousandths so they become exact `Decimal` values: the
/// property compares the reported interval against the generated one, and a value that
/// only existed as a rounded quotient would make that comparison about arithmetic rather
/// than about the claim being carried through unchanged.
private struct IntervalShape: Sendable {
    /// Lower bound in thousandths, `0...500`.
    let lowerThousandths: Int

    /// Interval width in thousandths, `1...499`, so the upper bound stays below 1 and
    /// strictly above the lower bound.
    let widthThousandths: Int

    /// Confidence level in thousandths, `1...999`, so it is strictly inside `0...1`.
    let levelThousandths: Int

    let methodIndex: Int

    var upperThousandths: Int { lowerThousandths + widthThousandths }
}

/// Which member of each enumerable set a mutation arm breaks.
///
/// Generated rather than enumerated so the shrinker can reduce a failing arm to one
/// citation, and so 100 cases spread across the sets instead of every case paying for
/// all of them.
private struct Selectors: Sendable {
    let citation: Int
    let placeholderToken: Int
}

/// Everything the benchmark-claim layer reads, as plain data.
///
/// The generator produces data only. Artifacts are built from it inside the property
/// body, where a construction that unexpectedly throws is recorded as a failure rather
/// than escaping: `propertyCheck` discards an error thrown by its body, so a refusal that
/// escaped as a throw would pass vacuously.
///
/// ## How the baseline varies
///
/// A property whose baseline is one constant with a mutation applied asserts one example
/// a hundred times over, so every dimension the arms depend on is generated rather than
/// fixed:
///
///   * four decisive label counts and two insufficient counts, each its own draw, so the
///     eligible and decisive totals derived from them differ between cases and between
///     the two ground-truth populations of one case;
///   * both coverage regimes, through ``everyEligibleImageDecisive``. The two are
///     genuinely different shapes rather than one shape with a different number:
///     coverage is exactly 1 with no insufficient outcome, or a generated fraction with
///     at least one, and those are the only two the counts admit;
///   * the coverage fraction itself, as a generated exact decimal strictly inside
///     `0...1`;
///   * both interval bounds and the confidence level, as generated exact decimals, and
///     the interval method over its whole closed set;
///   * every identifier, version, and content digest, from ``seed``. Deriving the whole
///     reference set from one number keeps it coherent without a cross-reference table
///     while still varying each of the seven citations between cases.
///
/// ``BenchmarkClaimVariationWitness`` checks after the run that this actually happened.
private struct BenchmarkClaimShape: Sendable, CustomStringConvertible {
    /// Drives every synthetic identifier, version, and digest, so the whole reference set
    /// varies together and stays coherent without a cross-reference table.
    let seed: Int

    /// Whether every eligible image received a decisive label, which is the only regime
    /// in which a coverage of exactly 1 agrees with the counts.
    let everyEligibleImageDecisive: Bool

    let counts: CountsShape

    /// Coverage in thousandths, `1...999`, used in the regime where coverage is below 1.
    let coverageThousandths: Int

    let interval: IntervalShape
    let selectors: Selectors

    /// Every top-level member ``BenchmarkClaimRecord`` encodes.
    ///
    /// Asserted against ``CanonicalArtifactPayload/topLevelKeys(_:)`` rather than listed
    /// as the member names, so a member added to the record is covered by the structural
    /// arm automatically and a member removed from it fails this count instead of being
    /// silently skipped.
    static let requiredMemberCount = 14

    /// The seven cited records the claim binds, in a fixed order so a generated selector
    /// indexes into it deterministically.
    ///
    /// Named rather than positional because the arms speak about them by name, and every
    /// one is checked separately so an audit hears which citation is unresolvable.
    static let citationNames = [
        "dataset",
        "datasetComposition",
        "degradationCondition",
        "metricDefinition",
        "evidenceProvenance",
        "activeLimitations",
        "correctionChannel",
    ]

    /// Citations whose content the release does not separately pin.
    ///
    /// The other two, `activeLimitations` and `correctionChannel`, are compared against
    /// the records the release publishes before their content is resolved, so a wrong
    /// digest there is refused as that disagreement instead. That refusal is the release
    /// binding arm's subject, and asserting it here would test the wrong layer.
    static var contentOnlyCitationNames: [String] { Array(citationNames.prefix(5)) }

    var description: String {
        "seed \(seed), coverage regime "
            + (everyEligibleImageDecisive ? "complete" : "partial")
            + ", decisive \(counts.decisiveCounts), insufficient "
            + "\(everyEligibleImageDecisive ? [0, 0] : counts.insufficientCounts)"
            + ", coverage \(coverageThousandths)/1000, interval "
            + "\(interval.lowerThousandths)...\(interval.upperThousandths)/1000 at "
            + "\(interval.levelThousandths)/1000"
    }

    // MARK: Generators

    static var generator: Generator<BenchmarkClaimShape, AnySequence<Any>> {
        zip(
            Gen.int(in: 0...9_999),
            Gen.bool,
            counts,
            Gen.int(in: 1...999),
            interval,
            selectors
        )
        .map { raw in
            BenchmarkClaimShape(
                seed: raw.0,
                everyEligibleImageDecisive: raw.1,
                counts: raw.2,
                coverageThousandths: raw.3,
                interval: raw.4,
                selectors: raw.5
            )
        }
        .eraseToAny()
    }

    private static var counts: Generator<CountsShape, AnySequence<Any>> {
        zip(
            Gen.int(in: 0...30).array(of: 4),
            Gen.int(in: 0...30).array(of: 2),
            Gen.int(in: 0...5),
            Gen.int(in: 0...99),
            Gen.int(in: 0...99)
        )
        .map {
            CountsShape(
                decisiveLabels: $0.0,
                insufficientLabels: $0.1,
                errorCount: $0.2,
                decisiveFloor: $0.3,
                insufficientFloor: $0.4
            )
        }
        .eraseToAny()
    }

    private static var interval: Generator<IntervalShape, AnySequence<Any>> {
        zip(
            Gen.int(in: 0...500),
            Gen.int(in: 1...499),
            Gen.int(in: 1...999),
            Gen.int(in: 0...(ConfidenceIntervalMethod.allCases.count - 1))
        )
        .map {
            IntervalShape(
                lowerThousandths: $0.0,
                widthThousandths: $0.1,
                levelThousandths: $0.2,
                methodIndex: $0.3
            )
        }
        .eraseToAny()
    }

    private static var selectors: Generator<Selectors, AnySequence<Any>> {
        zip(Gen.int(in: 0...99), Gen.int(in: 0...99))
            .map { Selectors(citation: $0.0, placeholderToken: $0.1) }
            .eraseToAny()
    }
}

// MARK: - Scenario

/// A generated shape and the artifacts built from it.
///
/// Every arm mutates one plain data table — the citation table, the counts, the coverage
/// value, or the interval — and lets the claim be rebuilt from it, so a mutation cannot
/// leave two parts of the shape disagreeing about anything except the one thing the arm
/// is about.
private struct BenchmarkClaimScenario {
    let shape: BenchmarkClaimShape

    // MARK: Identifiers, evidence, and scalars

    private var seed: Int { shape.seed }

    private func artifact(_ raw: String) -> ArtifactID { ArtifactID(raw)! }

    var claimID: ArtifactID { artifact("claim.benchmark-\(seed)") }
    var bundleID: ModelBundleID { ModelBundleID("bundle.model-\(seed)")! }
    var calibrationPolicyID: ArtifactID { artifact("policy.calibration-\(seed)") }

    /// The artifact identifier behind one named citation.
    func citationArtifact(_ name: String) -> ArtifactID {
        artifact("evidence.\(name)-\(seed)")
    }

    /// A placeholder token where a decided claim identifier belongs.
    ///
    /// Drawn from the schema's own placeholder vocabulary, filtered to the tokens that are
    /// canonical identifiers: `??` is refused one layer lower, by identifier syntax, so it
    /// would test the wrong thing here.
    var placeholderID: ArtifactID {
        let tokens = ArtifactSchemaValidation.placeholderTokens.sorted().compactMap(ArtifactID.init)
        return tokens[shape.selectors.placeholderToken % tokens.count]
    }

    private var version: SchemaSemanticVersion {
        try! SchemaSemanticVersion(validating: "1.\(seed % 1_000).0")
    }

    /// A version this release does not carry any citation at.
    private var otherVersion: SchemaSemanticVersion {
        try! SchemaSemanticVersion(validating: "2.\(seed % 1_000).0")
    }

    private func digest(salt: Int) -> SHA256Digest {
        let hexadecimal = String(salt, radix: 16)
        return SHA256Digest(
            hexadecimal: String(repeating: "0", count: 64 - hexadecimal.count) + hexadecimal
        )!
    }

    /// The digest of the content this release carries.
    private var contentDigest: SHA256Digest { digest(salt: seed) }

    /// A digest of content this release does not carry. Distinct from ``contentDigest``
    /// for every generated seed, because the seed range stops well below the offset.
    private var otherContentDigest: SHA256Digest { digest(salt: seed + 100_000) }

    var intervalMethod: ConfidenceIntervalMethod {
        ConfidenceIntervalMethod.allCases[shape.interval.methodIndex]
    }

    /// The citation this case's content and version arms break.
    var selectedCitation: String {
        let names = BenchmarkClaimShape.contentOnlyCitationNames
        return names[shape.selectors.citation % names.count]
    }

    /// An exact decimal from whole thousandths, so no generated ratio is a rounded
    /// quotient.
    private func thousandths(_ value: Int) -> Decimal {
        Decimal(sign: .plus, exponent: -3, significand: Decimal(value))
    }

    // MARK: Baseline tables

    /// The seven cited records the coherent baseline binds, each at this shape's version
    /// and content digest.
    func baselineCitations() -> [String: EvidenceSource] {
        var table: [String: EvidenceSource] = [:]
        for name in BenchmarkClaimShape.citationNames {
            table[name] = EvidenceSource(
                artifact: citationArtifact(name),
                version: version,
                contentDigest: contentDigest
            )
        }
        return table
    }

    /// The release evidence the baseline cites, minus whatever an arm removes.
    ///
    /// `omitting` names a citation rather than an artifact, which is how an arm makes one
    /// reference unresolvable without touching the claim that cites it: the difference
    /// between "this reference names nothing" and "this claim names something else".
    func evidenceIndex(omitting omitted: String? = nil) throws -> ReleaseEvidenceIndex {
        try ReleaseEvidenceIndex(
            records: BenchmarkClaimShape.citationNames
                .filter { $0 != omitted }
                .map { name in
                    EvidenceSource(
                        artifact: citationArtifact(name),
                        version: version,
                        contentDigest: contentDigest
                    )
                }
        )
    }

    /// Counts built from one decisive and one insufficient table.
    ///
    /// The eligible totals are derived from the two tables rather than supplied, so the
    /// per-population sums ``SliceOutcomeCounts`` requires hold for whatever tables an arm
    /// hands in. Every arm that changes the counts goes through here, so it cannot leave
    /// the counts internally inconsistent and be refused for that instead.
    func counts(decisive: [Int], insufficient: [Int]) throws -> SliceOutcomeCounts {
        try SliceOutcomeCounts(
            eligibleRealImages: try NonNegativeCount(
                validating: decisive[0] + decisive[1] + insufficient[0]
            ),
            eligibleSyntheticImages: try NonNegativeCount(
                validating: decisive[2] + decisive[3] + insufficient[1]
            ),
            realPositiveLabels: try NonNegativeCount(validating: decisive[0]),
            realNonPositiveLabels: try NonNegativeCount(validating: decisive[1]),
            realInsufficientLabels: try NonNegativeCount(validating: insufficient[0]),
            syntheticPositiveLabels: try NonNegativeCount(validating: decisive[2]),
            syntheticNonPositiveLabels: try NonNegativeCount(validating: decisive[3]),
            syntheticInsufficientLabels: try NonNegativeCount(validating: insufficient[1]),
            errorCount: try NonNegativeCount(validating: shape.counts.errorCount)
        )
    }

    /// The counts for one coverage regime.
    ///
    /// The complete regime has no insufficient outcome, so every eligible image is
    /// decisive; the partial regime has at least one, so the decisive total is strictly
    /// below the eligible total. Those are the only two the counts admit, and coverage
    /// has exactly one admissible form in each.
    func counts(everyEligibleImageDecisive: Bool) throws -> SliceOutcomeCounts {
        try counts(
            decisive: shape.counts.decisiveCounts,
            insufficient: everyEligibleImageDecisive ? [0, 0] : shape.counts.insufficientCounts
        )
    }

    /// The eligible image count of one regime, split by ground-truth population.
    ///
    /// Used by the no-decisive-label arm to keep the eligible totals exactly the
    /// baseline's while moving every one of those images to an insufficient outcome.
    func eligibleCounts(everyEligibleImageDecisive: Bool) -> [Int] {
        let decisive = shape.counts.decisiveCounts
        let insufficient = everyEligibleImageDecisive ? [0, 0] : shape.counts.insufficientCounts
        return [
            decisive[0] + decisive[1] + insufficient[0],
            decisive[2] + decisive[3] + insufficient[1],
        ]
    }

    /// The one coverage value that agrees with one regime's counts.
    func coverage(everyEligibleImageDecisive: Bool) throws -> UnitInterval {
        everyEligibleImageDecisive
            ? .one
            : try UnitInterval(validating: thousandths(shape.coverageThousandths))
    }

    func uncertaintyInterval(
        lowerThousandths: Int? = nil,
        upperThousandths: Int? = nil,
        levelThousandths: Int? = nil
    ) throws -> ConfidenceIntervalResult {
        try ConfidenceIntervalResult(
            method: intervalMethod,
            confidenceLevel: try UnitInterval(
                validating: thousandths(levelThousandths ?? shape.interval.levelThousandths)
            ),
            lowerBound: try UnitInterval(
                validating: thousandths(lowerThousandths ?? shape.interval.lowerThousandths)
            ),
            upperBound: try UnitInterval(
                validating: thousandths(upperThousandths ?? shape.interval.upperThousandths)
            )
        )
    }

    // MARK: Builders

    /// One citation from a table, refusing rather than substituting when it is absent.
    private func citation(
        _ name: String,
        in table: [String: EvidenceSource]
    ) throws -> EvidenceSource {
        guard let found = table[name] else {
            throw ArtifactSchemaError.missingRequiredEntries(
                field: "test.citations",
                keys: [name]
            )
        }
        return found
    }

    /// The claim, built from the tables an arm may have mutated.
    func claim(
        identifier: ArtifactID? = nil,
        modelIdentity: ModelIdentity = RequiredPixelModel.identity,
        modelBundle: ModelBundleID? = nil,
        calibrationPolicy: ArtifactID? = nil,
        citations: [String: EvidenceSource]? = nil,
        counts: SliceOutcomeCounts? = nil,
        coverage: UnitInterval? = nil,
        interval: ConfidenceIntervalResult? = nil
    ) throws -> BenchmarkClaimRecord {
        let table = citations ?? baselineCitations()
        return BenchmarkClaimRecord(
            id: identifier ?? claimID,
            dataset: try citation("dataset", in: table),
            datasetComposition: try citation("datasetComposition", in: table),
            degradationCondition: try citation("degradationCondition", in: table),
            modelIdentity: modelIdentity,
            modelBundle: modelBundle ?? bundleID,
            calibrationPolicy: calibrationPolicy ?? calibrationPolicyID,
            counts: try counts ?? self.counts(
                everyEligibleImageDecisive: shape.everyEligibleImageDecisive
            ),
            coverage: try coverage ?? self.coverage(
                everyEligibleImageDecisive: shape.everyEligibleImageDecisive
            ),
            metricDefinition: try citation("metricDefinition", in: table),
            evidenceProvenance: try citation("evidenceProvenance", in: table),
            uncertaintyInterval: try interval ?? uncertaintyInterval(),
            activeLimitations: try citation("activeLimitations", in: table),
            correctionChannel: try citation("correctionChannel", in: table)
        )
    }

    /// Validates a claim against the bindings this release publishes.
    ///
    /// The bundle, Calibration Policy, limitations document, and correction channel come
    /// from the release rather than from the claim, which is what keeps a claim from
    /// nominating its own. They are this scenario's baseline values in every arm; an arm
    /// that breaks one of them changes the *claim*, so the disagreement is the claim's.
    func validate(
        _ claim: BenchmarkClaimRecord,
        evidence index: ReleaseEvidenceIndex? = nil
    ) throws -> ValidatedBenchmarkClaim {
        let baseline = baselineCitations()
        return try ValidatedBenchmarkClaim(
            validating: claim,
            modelBundle: bundleID,
            calibrationPolicy: calibrationPolicyID,
            activeLimitations: try citation("activeLimitations", in: baseline),
            correctionChannel: try citation("correctionChannel", in: baseline),
            evidence: try index ?? evidenceIndex()
        )
    }

    // MARK: Complete arm

    /// A coherent generated claim is publishable, and everything it reports is what the
    /// shape generated.
    ///
    /// Without this arm the property would pass by refusing everything. The equality
    /// against the unmutated record is the second half of it: Requirement 8.16 is about
    /// what a claim carries, so a validator that repaired, normalized, or filled a field
    /// would satisfy every refusal arm below while publishing a claim nobody wrote.
    func checkCompleteClaimIsPublishable() {
        let record: BenchmarkClaimRecord
        let validated: ValidatedBenchmarkClaim
        do {
            record = try claim()
            validated = try validate(record)
        } catch {
            Issue.record("a completely bound generated claim was refused: \(error) [\(shape)]")
            return
        }

        #expect(validated.claim == record, "publication altered the claim [\(shape)]")
        #expect(validated.id == claimID)

        let decisive = shape.counts.decisiveCounts.reduce(0, +)
        let insufficient = shape.everyEligibleImageDecisive
            ? 0
            : shape.counts.insufficientCounts.reduce(0, +)
        #expect(validated.decisiveSampleCount == decisive)
        #expect(validated.eligibleSampleCount == decisive + insufficient)
        #expect(validated.eligibleSampleCount > 0)

        // Requirement 5.18 pools both populations, and abstention stays in the
        // denominator: full coverage exactly when nothing abstained.
        #expect(
            (validated.coverage == .one) == shape.everyEligibleImageDecisive,
            "reported coverage \(validated.coverage) [\(shape)]"
        )
        do {
            let generatedCoverage = try coverage(
                everyEligibleImageDecisive: shape.everyEligibleImageDecisive
            )
            let generatedInterval = try uncertaintyInterval()
            #expect(validated.coverage == generatedCoverage)
            #expect(validated.uncertaintyInterval == generatedInterval)
            #expect(validated.boundEvidence == Set(baselineCitations().values))
        } catch {
            Issue.record("a generated baseline value could not be rebuilt: \(error) [\(shape)]")
        }

        // Seven distinct citations, so no two of the bindings Requirement 8.16 lists
        // collapsed into one reference.
        #expect(validated.boundEvidence.count == BenchmarkClaimShape.citationNames.count)
    }

    // MARK: Structural arm

    /// Every one of the 14 encoded members is required, and nothing substitutes a default.
    ///
    /// The member list comes from the encoded payload rather than from a list written
    /// here, and its size is asserted, so a binding added to the record is covered
    /// automatically and one removed fails the count instead of being silently skipped.
    ///
    /// Removal is a splice of the payload *text*. A `JSONSerialization` round trip
    /// perturbs exact decimals, and a claim carries three of them — coverage and both
    /// interval bounds — so a decode failure could come from the perturbed decimal rather
    /// than from the removed member, and this arm would pass vacuously. Three assertions
    /// close that off: the untouched payload decodes back to the identical claim; each
    /// spliced payload is still parseable JSON, so the refusal is not about broken bytes;
    /// and each spliced payload is missing exactly the one member.
    func checkEveryEncodedMemberIsRequired() {
        let record: BenchmarkClaimRecord
        let payload: String
        let keys: [String]
        do {
            record = try claim()
            payload = try CanonicalArtifactPayload.text(record)
            keys = try CanonicalArtifactPayload.topLevelKeys(record)
        } catch {
            Issue.record("a generated claim could not be encoded: \(error) [\(shape)]")
            return
        }

        // The positive control. Every refusal below is attributable to the removed member
        // only if the untouched bytes read back as the same claim, exact decimals included.
        do {
            let decoded = try JSONDecoder().decode(
                BenchmarkClaimRecord.self,
                from: Data(payload.utf8)
            )
            #expect(decoded == record, "the untouched payload did not round trip [\(shape)]")
        } catch {
            Issue.record("the untouched payload failed to decode: \(error) [\(shape)]")
            return
        }

        #expect(
            keys.count == BenchmarkClaimShape.requiredMemberCount,
            "a claim binding was added or removed: \(keys)"
        )
        #expect(Set(keys).count == keys.count, "the encoded claim repeats a member: \(keys)")

        for key in keys {
            guard let mutated = JSONMemberSplice.removingTopLevelMember(key, from: payload) else {
                Issue.record("\(key) was not a top-level member of the encoded claim [\(shape)]")
                continue
            }
            let remaining = JSONMemberSplice.topLevelMemberRanges(in: mutated)
            #expect(remaining[key] == nil, "splicing left \(key) in the payload [\(shape)]")
            #expect(
                remaining.count == keys.count - 1,
                "splicing \(key) changed more than one member [\(shape)]"
            )
            #expect(
                (try? JSONSerialization.jsonObject(with: Data(mutated.utf8))) != nil,
                "splicing \(key) left the payload unparseable [\(shape)]"
            )
            expectDecodeRefused("a claim payload without \(key)", mutated)
        }
    }

    // MARK: Citation arm

    /// Every cited record has to exist, at exactly the version and content cited.
    ///
    /// Three forms, and they are different audit findings. A reference to an artifact the
    /// release does not carry names no record at all. A reference at another version, or
    /// to other content at the same identifier, names a record that is not the one the
    /// measurement came from — which is what "immutable" in Requirement 8.16 rules out,
    /// since a claim bound to a mutable document at a fixed identifier is not bound.
    func checkEveryCitationMustResolve() {
        for name in BenchmarkClaimShape.citationNames {
            expectRefused("a claim citing missing \(name)", .missingRequiredEntries) {
                _ = try self.validate(
                    try self.claim(),
                    evidence: try self.evidenceIndex(omitting: name)
                )
            }
        }

        let name = selectedCitation
        expectRefused("a \(name) citation at another version", .inconsistentReference) {
            var citations = self.baselineCitations()
            citations[name] = EvidenceSource(
                artifact: self.citationArtifact(name),
                version: self.otherVersion,
                contentDigest: self.contentDigest
            )
            _ = try self.validate(try self.claim(citations: citations))
        }

        expectRefused("a \(name) citation to other content", .inconsistentReference) {
            var citations = self.baselineCitations()
            citations[name] = EvidenceSource(
                artifact: self.citationArtifact(name),
                version: self.version,
                contentDigest: self.otherContentDigest
            )
            _ = try self.validate(try self.claim(citations: citations))
        }
    }

    // MARK: Release binding arm

    /// A claim describes the release that publishes it, and names itself with a decision.
    ///
    /// A claim measured on another model, bundle, or Calibration Policy is a measurement
    /// of different code or different thresholds. The two identity forms are asserted
    /// separately because only the second is about the weights: a claim naming the
    /// required checkpoint while binding another weight digest reads as the right model.
    ///
    /// The limitations and correction channel are repointed at a record the release *does*
    /// carry, so the refusal is about the claim naming a different document rather than
    /// about an unresolvable reference — that is the citation arm's subject.
    func checkClaimDescribesTheReleaseThatPublishesIt() {
        expectRefused("a claim measured on another checkpoint", .inconsistentReference) {
            _ = try self.validate(
                try self.claim(
                    modelIdentity: ModelIdentity(
                        checkpointIdentifier: ModelCheckpointIdentifier(
                            "Synthetic/other-checkpoint-\(self.seed)"
                        )!,
                        requiredWeightDigest: RequiredPixelModel.identity.requiredWeightDigest
                    )
                )
            )
        }

        expectRefused("a claim measured on other weights", .inconsistentReference) {
            _ = try self.validate(
                try self.claim(
                    modelIdentity: ModelIdentity(
                        checkpointIdentifier: RequiredPixelModel.identity.checkpointIdentifier,
                        requiredWeightDigest: self.otherContentDigest
                    )
                )
            )
        }

        expectRefused("a claim measured on another Model Bundle", .inconsistentReference) {
            _ = try self.validate(
                try self.claim(modelBundle: ModelBundleID("bundle.model-other-\(self.seed)")!)
            )
        }

        expectRefused("a claim measured on another Calibration Policy", .inconsistentReference) {
            _ = try self.validate(
                try self.claim(
                    calibrationPolicy: self.artifact("policy.calibration-other-\(self.seed)")
                )
            )
        }

        for name in ["activeLimitations", "correctionChannel"] {
            expectRefused("a claim publishing another \(name)", .inconsistentReference) {
                var citations = self.baselineCitations()
                citations[name] = try self.citation("dataset", in: citations)
                _ = try self.validate(try self.claim(citations: citations))
            }
        }

        expectRefused("a placeholder claim identifier", .placeholderValue) {
            _ = try self.validate(try self.claim(identifier: self.placeholderID))
        }
    }

    // MARK: Measured support arm

    /// The counts and coverage are measurements rather than absences.
    ///
    /// Zero is not a small measurement here, it is the count nobody took: a claim over no
    /// eligible image reports nothing, and a claim with no decisive label has no value for
    /// an interval to be an interval around. Zero coverage is the same absence written in
    /// the other field.
    ///
    /// Coverage is pinned to the counts at both endpoints and nowhere else. Between them
    /// the metric definition is the authority, so this arm asserts only the two endpoints,
    /// and it asserts both coherent regimes as its positive control — otherwise a
    /// validator that refused every coverage value would satisfy the refusals below.
    func checkMeasuredSupportIsRequired() {
        for regime in [true, false] {
            do {
                _ = try validate(
                    try claim(
                        counts: try counts(everyEligibleImageDecisive: regime),
                        coverage: try coverage(everyEligibleImageDecisive: regime)
                    )
                )
            } catch {
                let regimeName = regime ? "complete" : "partial"
                Issue.record(
                    """
                    a coherent claim in the \(regimeName) coverage regime was refused: \
                    \(error) [\(shape)]
                    """
                )
            }
        }

        expectRefused("a claim measured over no eligible image", .nonPositiveValue) {
            // Zero eligible images in both populations. Representable — the sums agree —
            // and it is the count nobody took rather than a measured emptiness.
            _ = try self.validate(
                try self.claim(
                    counts: try self.counts(decisive: [0, 0, 0, 0], insufficient: [0, 0])
                )
            )
        }

        expectRefused("a claim with no decisive label", .nonPositiveValue) {
            // Every eligible image abstained, so coverage would be zero and the rate would
            // have no support. The eligible totals stay exactly the baseline's, so the only
            // thing that changed is which outcome those images received.
            _ = try self.validate(
                try self.claim(
                    counts: try self.counts(
                        decisive: [0, 0, 0, 0],
                        insufficient: self.eligibleCounts(
                            everyEligibleImageDecisive: self.shape.everyEligibleImageDecisive
                        )
                    )
                )
            )
        }

        expectRefused("a claim reporting zero coverage", .nonPositiveValue) {
            _ = try self.validate(try self.claim(coverage: .zero))
        }

        expectRefused(
            "full coverage while an eligible image abstained", .inconsistentReference
        ) {
            _ = try self.validate(
                try self.claim(
                    counts: try self.counts(everyEligibleImageDecisive: false),
                    coverage: .one
                )
            )
        }

        expectRefused(
            "coverage below 1 while every eligible image was decisive", .inconsistentReference
        ) {
            _ = try self.validate(
                try self.claim(
                    counts: try self.counts(everyEligibleImageDecisive: true),
                    coverage: try self.coverage(everyEligibleImageDecisive: false)
                )
            )
        }
    }

    // MARK: Uncertainty arm

    /// The reported interval expresses uncertainty.
    ///
    /// A lower bound equal to the upper bound is a point value: the schema accepts it,
    /// because equal bounds are a valid ordering, and Requirement 8.16 asks for an
    /// uncertainty interval, which that expresses none of. A confidence level of 0 or 1 is
    /// the same degeneracy moved into the level. The level's *value* stays a claim
    /// decision, so nothing here fixes one.
    ///
    /// An inverted interval is refused one layer lower, by
    /// ``ConfidenceIntervalResult`` itself, which is the strongest available form: there
    /// is no claim to build. Asserting it at the scalar layer rather than at the claim is
    /// deliberate.
    func checkUncertaintyIntervalIsAnInterval() {
        for bound in [shape.interval.lowerThousandths, shape.interval.upperThousandths] {
            expectRefused("a point interval at \(bound)/1000", .valueOutOfRange) {
                _ = try self.validate(
                    try self.claim(
                        interval: try self.uncertaintyInterval(
                            lowerThousandths: bound,
                            upperThousandths: bound
                        )
                    )
                )
            }
        }

        for level in [0, 1_000] {
            expectRefused("a confidence level of \(level)/1000", .valueOutOfRange) {
                _ = try self.validate(
                    try self.claim(
                        interval: try self.uncertaintyInterval(levelThousandths: level)
                    )
                )
            }
        }

        expectRefused("an inverted interval", .valueOutOfRange) {
            _ = try self.uncertaintyInterval(
                lowerThousandths: self.shape.interval.upperThousandths,
                upperThousandths: self.shape.interval.lowerThousandths
            )
        }
    }

    // MARK: Refusal helpers

    /// Requires `build` to refuse with a specific fault, recording an issue otherwise.
    ///
    /// Never rethrows. `propertyCheck` discards an error thrown by its body without
    /// recording an issue, so a refusal that escaped as a throw would make this property
    /// pass vacuously.
    func expectRefused(
        _ what: String,
        _ expected: BenchmarkClaimFault,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ build: () throws -> Void
    ) {
        do {
            try build()
            Issue.record("\(what) was accepted [\(shape)]", sourceLocation: sourceLocation)
        } catch let error as ArtifactSchemaError {
            #expect(
                BenchmarkClaimFault(error) == expected,
                "\(what) was refused as \(error) [\(shape)]",
                sourceLocation: sourceLocation
            )
        } catch {
            Issue.record(
                "\(what) failed with a non-schema error \(error) [\(shape)]",
                sourceLocation: sourceLocation
            )
        }
    }

    /// Requires a payload to fail to decode as a claim, recording an issue otherwise.
    ///
    /// Separate from ``expectRefused(_:_:sourceLocation:_:)`` because a missing member is
    /// caught before any field is validated, so it surfaces as a `DecodingError` rather
    /// than as an ``ArtifactSchemaError``. Never rethrows, for the same reason.
    func expectDecodeRefused(
        _ what: String,
        _ payload: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        do {
            let decoded = try JSONDecoder().decode(
                BenchmarkClaimRecord.self,
                from: Data(payload.utf8)
            )
            Issue.record(
                """
                \(what) decoded to \(decoded.id.rawValue), so something supplied a default \
                [\(shape)]
                """,
                sourceLocation: sourceLocation
            )
        } catch is DecodingError {
            return
        } catch {
            Issue.record(
                "\(what) failed with a non-decoding error \(error) [\(shape)]",
                sourceLocation: sourceLocation
            )
        }
    }
}

// MARK: - Fault classification

/// Which ``ArtifactSchemaError`` a refusal reported, without its field strings.
///
/// Asserting the case rather than the whole value keeps the property about *why* a claim
/// was refused while leaving the audit message free to change. Asserting nothing about
/// the case would let an unrelated fault stand in for the one an arm is about.
private enum BenchmarkClaimFault: Equatable {
    case emptyValue
    case placeholderValue
    case noncanonicalValue
    case valueOutOfRange
    case nonPositiveValue
    case nonFiniteValue
    case duplicateEntry
    case missingRequiredEntries
    case unexpectedEntries
    case fixedValueMismatch
    case forbiddenValue
    case inconsistentReference

    init(_ error: ArtifactSchemaError) {
        switch error {
        case .emptyValue: self = .emptyValue
        case .placeholderValue: self = .placeholderValue
        case .noncanonicalValue: self = .noncanonicalValue
        case .valueOutOfRange: self = .valueOutOfRange
        case .nonPositiveValue: self = .nonPositiveValue
        case .nonFiniteValue: self = .nonFiniteValue
        case .duplicateEntry: self = .duplicateEntry
        case .missingRequiredEntries: self = .missingRequiredEntries
        case .unexpectedEntries: self = .unexpectedEntries
        case .fixedValueMismatch: self = .fixedValueMismatch
        case .forbiddenValue: self = .forbiddenValue
        case .inconsistentReference: self = .inconsistentReference
        }
    }
}

// MARK: - Non-vacuity witness

/// Records what the generator actually produced, so the property cannot pass by
/// generating one fixed shape a hundred times.
///
/// A property whose baseline never varies asserts one example a hundred times over. This
/// collects the dimensions the arms depend on and requires each to have been exercised
/// with more than one value. The thresholds are far below what 100 uniform draws produce,
/// so this witnesses variation rather than pinning a distribution.
private final class BenchmarkClaimVariationWitness: @unchecked Sendable {
    private let lock = NSLock()
    private var seeds = Set<Int>()
    private var coverageRegimes = Set<Bool>()
    private var eligibleCounts = Set<Int>()
    private var decisiveCounts = Set<Int>()
    private var coverageValues = Set<Int>()
    private var intervalBounds = Set<[Int]>()
    private var confidenceLevels = Set<Int>()
    private var intervalMethods = Set<Int>()
    private var cases = 0

    func record(_ shape: BenchmarkClaimShape) {
        lock.lock()
        defer { lock.unlock() }
        cases += 1
        seeds.insert(shape.seed)
        coverageRegimes.insert(shape.everyEligibleImageDecisive)
        let decisive = shape.counts.decisiveCounts.reduce(0, +)
        let insufficient = shape.everyEligibleImageDecisive
            ? 0
            : shape.counts.insufficientCounts.reduce(0, +)
        decisiveCounts.insert(decisive)
        eligibleCounts.insert(decisive + insufficient)
        coverageValues.insert(shape.coverageThousandths)
        intervalBounds.insert([shape.interval.lowerThousandths, shape.interval.upperThousandths])
        confidenceLevels.insert(shape.interval.levelThousandths)
        intervalMethods.insert(shape.interval.methodIndex)
    }

    func expectVariedBaselines() {
        lock.lock()
        defer { lock.unlock() }

        #expect(cases >= 100, "the design requires at least 100 generated cases")
        // A constant baseline would show 1 in each of these.
        #expect(seeds.count >= 80, "generated seeds: \(seeds.count)")
        #expect(coverageRegimes == [false, true], "both coverage regimes are generated")
        #expect(decisiveCounts.count >= 30, "generated decisive totals: \(decisiveCounts.count)")
        #expect(eligibleCounts.count >= 30, "generated eligible totals: \(eligibleCounts.count)")
        #expect(coverageValues.count >= 80, "generated coverage values: \(coverageValues.count)")
        #expect(intervalBounds.count >= 80, "generated interval bounds: \(intervalBounds.count)")
        #expect(
            confidenceLevels.count >= 80,
            "generated confidence levels: \(confidenceLevels.count)"
        )
        #expect(
            intervalMethods.count == ConfidenceIntervalMethod.allCases.count,
            "generated interval methods: \(intervalMethods.sorted())"
        )
    }
}
