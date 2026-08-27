import Foundation
import PropertyBased
import Testing

@testable import DefAIkeDomain

// Design Property 33: release readiness is auditable and fail-closed.
//
// The design states it as: for any release capability set and release-readiness record,
// release is eligible only when every applicable mandatory gate has immutable source and
// version identifiers plus an explicit pass, every published claim has all required
// immutable bindings, and the signed Initial Model Bundle and Lowq governance decision
// pass; any missing/failing applicable gate or unresolved rights status blocks the
// affected distribution, while a nonapplicable conditional gate cannot silently become
// enabled.
//
// ## What "eligible" means here
//
// Eligibility is holding an ``EligibleRelease``. There is no status to read and no way to
// construct one around a record that did not satisfy every clause, so "blocks the affected
// distribution" is quantified as construction refusing with an ``ArtifactSchemaError`` —
// the strongest available form, because there is no partially eligible value to inspect
// afterwards.
//
// ## The arms
//
// Ten arms over every generated shape, each one a different way a release could reach
// distribution without the evidence Requirement 14 demands:
//
//   * **a complete record is eligible**, and everything the eligible value reports is what
//     the shape generated, unchanged. Without this arm the property passes by refusing
//     everything;
//   * **a gate with no executed result blocks**, quantified over every applicable entry of
//     ``ReleaseGate/allCases`` rather than a hand-picked gate, so a gate added to the
//     vocabulary is covered rather than skipped;
//   * **a gate whose citation does not resolve blocks**, in four forms: the cited artifact
//     is not carried by the release, the citation is at another version, it is at another
//     content digest, or it names a different record entirely. Requirement 14.1 asks for
//     source artifact identifiers *and* versions, so a reference that resolves to other
//     bytes at the same identifier maps the gate to no result;
//   * **a failing gate blocks**, again over every applicable entry;
//   * **the hard public-launch blockers name themselves** (Requirements 14.16 and 14.17).
//     Requirement 14.15 already blocks on any applicable mandatory entry, so what is
//     asserted is that the audit hears *which* blocker refused. The naming assertion lives
//     in whichever refusal arm the blocker actually reaches, derived from the gate; the
//     dedicated arm asserts that between them those arms reach every member of the set, so
//     a blocker added to it cannot go unchecked;
//   * **no waiver approves itself**: a rejected inapplicability decision waives nothing,
//     and an approval the release cannot resolve is a synthesized approval;
//   * **conditional applicability is the compiled capability set, in both directions**
//     (Requirements 6.2 and 14.1) — a provenance build recording the gate waived, and a
//     pixel-only build recording it applicable and passing;
//   * **the externally decided conclusions are read, never derived** (Requirement 14.4);
//   * **one record, one build, one bundle, one allowlist** (Requirement 14.11), including
//     that the supplied ``ValidatedAccessibilityGateMatrix`` answers for *this* record's
//     allowlist and application build;
//   * **a published claim's bindings come from the record**, not from the claim.
//
// The three gate faults are three different audit findings and are asserted at three
// different fields, because most of them land on the same ``ArtifactSchemaError`` case:
// `not-executed` on an applicable gate is missing evidence at
// `release.gateRecords[<gate>]`; an unresolvable citation is missing evidence at
// `release.gateRecords[<gate>].evidence`, naming the artifact; and `failed` is a forbidden
// value at `release.gateRecords[<gate>].outcome`. Asserting only the case would let one
// arm's refusal stand in for another's.
//
// ## What this file deliberately does not assert, and why
//
//   * **Whether a claim is completely bound.** Property 24 quantifies every one of
//     Requirement 8.16's bindings, structurally and semantically, over generated claims.
//     Here a validated claim is an *input*: the statement is about the record and its
//     gates, so the only claim arms are the ones whose mutation is on the *record* — the
//     bundle, limitations document, and correction channel a claim is bound to come from
//     the record, and two claims cannot share an identifier.
//   * **Whether the accessibility and Localization Readiness matrices are complete.**
//     Property 31 decides that, and ``ValidatedAccessibilityGateMatrix`` is a required
//     input here. What is added is that the validated matrix answers for this record.
//   * **Whether the device allowlist is coherent.** Property 1 quantifies that.
//   * **The governance gate failing through its outcome.** It cannot: its outcome is
//     required to report the ``ApprovalRecord`` it carries, so a failed outcome beside an
//     approved decision is refused earlier as that disagreement, and the gate blocks
//     through a rejected decision instead. The arm asserts the reachable path.
//   * **Mutation-focused unit tests.** Those are task 2.12's.
//
// ``EligibleReleaseTests`` pins each of these refusals at one field with one example. This
// file quantifies the same statement over generated release records.
//
// No value here is an approved distribution, capability set, Model Bundle, legal
// conclusion, governance decision, or measured benchmark. Every approval is a synthetic
// record whose decision the arm sets, every count is a small synthetic integer, every
// ratio is a generated multiple of one thousandth, and the whole shape exists so that
// eligibility can be asked to refuse it.

extension Tag {
    /// Design Property 33.
    ///
    /// Declared in this file rather than in a shared tag namespace: each design property
    /// gets one dedicated file, and a shared namespace would be a merge point between
    /// property files written independently of each other.
    @Tag static var property33ReleaseReadinessAudit: Self
}

@Suite(
    "Property 33: release readiness is auditable and fail-closed",
    .tags(.property33ReleaseReadinessAudit)
)
struct ReleaseReadinessAuditPropertyTests {
    /// Runs at the library default of 100 generated cases with shrinking, which is the
    /// minimum the design requires; `PropertyToolchainWiringTests` pins that default.
    /// Every generator is composed with `zip`, so the shrinkers compose.
    ///
    /// **Validates: Requirements 14.1, 14.4, 14.11, 14.12, 14.15, 14.16, 14.17**
    @Test("Release eligibility fails closed over generated release-readiness records")
    func releaseReadinessIsAuditableAndFailsClosed() async {
        let witness = ReleaseReadinessVariationWitness()

        await propertyCheck(input: ReleaseShape.generator) { shape in
            witness.record(shape)

            // The coherent baseline is built once per case and every arm mutates one stored
            // table — the gate entries, the evidence index, the claim list, or one
            // identifier — and reassembles from it, so a mutation cannot leave the record,
            // the manifest, the matrix, and the index disagreeing about anything except the
            // one thing the arm is about. It also means a case pays for two 56-cell matrix
            // validations rather than one per arm.
            let scenario: ReleaseScenario
            do {
                scenario = try ReleaseScenario(shape: shape)
            } catch {
                Issue.record("a coherent generated release record was refused: \(error) [\(shape)]")
                return
            }
            witness.recordBaseline(scenario)

            scenario.checkCompleteRecordIsEligible()
            scenario.checkEveryApplicableGateNeedsAnExecutedResult()
            scenario.checkEveryGateCitationMustResolve()
            scenario.checkEveryFailingApplicableGateBlocks()
            scenario.checkHardPublicLaunchBlockersNameThemselves()
            scenario.checkNoWaiverApprovesItself()
            scenario.checkConditionalApplicabilityMatchesTheManifest()
            scenario.checkExternalConclusionsAreReadNeverDerived()
            scenario.checkOneRecordOneBuildOneBundleOneAllowlist()
            scenario.checkPublishedClaimsAreBoundByTheRecord()
        }

        witness.expectVariedBaselines()
    }
}

// MARK: - Generated shape

/// The capability set one generated release compiled.
///
/// Fusion is a case of this enumeration rather than an independent draw. A manifest that
/// fuses evidence without a provenance lane is unrepresentable — the schema refuses it —
/// so drawing the two flags separately would spend a quarter of every run on releases that
/// cannot exist.
private enum CapabilitySet: Hashable, Sendable, CaseIterable, CustomStringConvertible {
    case pixelOnly
    case provenance
    case provenanceAndFusion

    var enablesProvenance: Bool { self != .pixelOnly }
    var enablesFusion: Bool { self == .provenanceAndFusion }

    /// The set whose provenance decision differs from this one, for the arm that validates
    /// a record against a manifest that compiled the other lane.
    ///
    /// Provenance always differs, so the conditional-applicability refusal always reports
    /// the provenance gate and the expected value is derivable.
    var opposite: CapabilitySet { self == .pixelOnly ? .provenance : .pixelOnly }

    var description: String {
        switch self {
        case .pixelOnly: "pixel-only"
        case .provenance: "provenance"
        case .provenanceAndFusion: "provenance+fusion"
        }
    }
}

/// One generated published claim's measured support, as plain data.
///
/// Only the numbers the record layer reads are generated. Whether a claim carries every
/// binding Requirement 8.16 lists is Property 24's statement, so the bindings here are
/// coherent by construction and never mutated: what this file needs from a claim is that
/// it is publishable, so that the arms which change the *record* can be observed to
/// unpublish it.
private struct ClaimShape: Sendable {
    /// Decisive real and synthetic label counts. At least one real label, so a generated
    /// claim always has measured support.
    let realDecisive: Int
    let syntheticDecisive: Int

    /// Insufficient counts in real, synthetic order, before the partial-regime floor.
    let insufficient: [Int]

    /// Which insufficient count is raised in the partial regime, so both populations can
    /// be the one that abstained.
    let insufficientFloor: Int

    /// Whether every eligible image received a decisive label, which is the only regime in
    /// which a coverage of exactly 1 agrees with the counts.
    let everyEligibleImageDecisive: Bool

    /// Coverage in thousandths, `1...999`, used in the regime where coverage is below 1.
    let coverageThousandths: Int

    /// The insufficient counts of this claim's coverage regime.
    ///
    /// Derived from the regime rather than drawn beside it: a generated flag next to
    /// generated counts could contradict them, and the claim would then be refused for a
    /// reason this property is not about.
    var insufficientCounts: [Int] {
        guard !everyEligibleImageDecisive else { return [0, 0] }
        var counts = insufficient
        counts[insufficientFloor % counts.count] += 1
        return counts
    }
}

/// Which member of each enumerable set a single-target arm breaks.
///
/// Generated rather than enumerated so the shrinker can reduce a failing arm to one gate
/// or one bundle, and so 100 cases spread across the sets instead of every case paying for
/// all of them. The sweeps that quantify over every gate do not use these.
private struct ReleaseSelectors: Sendable {
    let gate: Int
    let bundle: Int
}

/// Everything the release-eligibility layer reads, as plain data.
///
/// The generator produces data only. Artifacts are built from it inside the property body,
/// where a construction that unexpectedly throws is recorded as a failure rather than
/// escaping: `propertyCheck` discards an error thrown by its body, so a refusal that
/// escaped as a throw would pass vacuously.
///
/// ## How the baseline varies
///
/// A property whose baseline is one constant with a mutation applied asserts one example a
/// hundred times over, so every dimension the arms depend on is generated:
///
///   * all three compiled capability sets, which is what makes the conditional gates
///     applicable or waived and therefore changes which gates the sweeps visit — every
///     unconditional gate, plus one or both conditional ones — and how many waivers the
///     waiver arm has to reject: two, one, or none;
///   * an approved Model Bundle catalog of one to three bundles, and which one of them the
///     record distributes. A catalog of more than one is what makes "one of the approved
///     catalog" a set membership rather than an equality, and it is what lets the claim arm
///     move the record to another *approved* bundle;
///   * zero, one, or two published claims. Zero is a valid release that publishes no
///     benchmark claim, and two is what makes a repeated claim identifier representable;
///   * each claim's decisive and insufficient label counts, its coverage regime, and its
///     coverage value as a generated exact decimal;
///   * the gate every single-target arm breaks;
///   * every gate's cited result record, and the claim, catalog, and stray identifiers,
///     from ``seed``. Deriving them from one number keeps the reference set coherent
///     without a cross-reference table while still varying every gate citation between
///     cases.
///
/// The manifest, allowlist, matrix, application build, and the four approval records keep
/// the identifiers ``ReleaseReadinessSample`` and ``AccessibilityMatrixSample`` pin, so the
/// fixtures' allowlist, matrix, and external approvals stay the ones this record answers
/// for rather than coincidentally similar ones.
///
/// ``ReleaseReadinessVariationWitness`` checks after the run that this actually happened.
private struct ReleaseShape: Sendable, CustomStringConvertible {
    /// Drives every synthetic identifier the record cites, so the whole citation set varies
    /// together and stays coherent without a cross-reference table.
    let seed: Int

    let capabilities: CapabilitySet

    /// How many Model Bundles the manifest approves, `1...3`.
    let catalogSize: Int

    /// Which of the two things a supplied matrix can answer for the wrong release this case
    /// breaks: the device allowlist, or the application build.
    ///
    /// Generated rather than enumerated because each one costs a whole extra 56-cell matrix
    /// validation, and 100 cases cover both. The witness requires that they did.
    let strayMatrixTargetsAllowlist: Bool

    let claims: [ClaimShape]
    let selectors: ReleaseSelectors

    var description: String {
        """
        seed \(seed), \(capabilities) build, \(catalogSize) approved bundle(s), \
        \(claims.count) published claim(s), stray matrix answers for another \
        \(strayMatrixTargetsAllowlist ? "allowlist" : "application build")
        """
    }

    // MARK: Generators

    static var generator: Generator<ReleaseShape, AnySequence<Any>> {
        zip(
            Gen.int(in: 0...9_999),
            capabilities,
            Gen.int(in: 1...3),
            Gen.bool,
            claims,
            selectors
        )
        .map { raw in
            ReleaseShape(
                seed: raw.0,
                capabilities: raw.1,
                catalogSize: raw.2,
                strayMatrixTargetsAllowlist: raw.3,
                claims: raw.4,
                selectors: raw.5
            )
        }
        .eraseToAny()
    }

    private static var capabilities: Generator<CapabilitySet, AnySequence<Any>> {
        Gen.int(in: 0...(CapabilitySet.allCases.count - 1))
            .map { CapabilitySet.allCases[$0] }
            .eraseToAny()
    }

    private static var claims: Generator<[ClaimShape], AnySequence<Any>> {
        zip(
            Gen.int(in: 1...20),
            Gen.int(in: 0...20),
            Gen.int(in: 0...4).array(of: 2),
            Gen.int(in: 0...99),
            Gen.bool,
            Gen.int(in: 1...999)
        )
        .map {
            ClaimShape(
                realDecisive: $0.0,
                syntheticDecisive: $0.1,
                insufficient: $0.2,
                insufficientFloor: $0.3,
                everyEligibleImageDecisive: $0.4,
                coverageThousandths: $0.5
            )
        }
        .array(of: 0...2)
        .eraseToAny()
    }

    private static var selectors: Generator<ReleaseSelectors, AnySequence<Any>> {
        zip(Gen.int(in: 0...9_999), Gen.int(in: 0...9_999))
            .map { ReleaseSelectors(gate: $0.0, bundle: $0.1) }
            .eraseToAny()
    }
}

// MARK: - External conclusions

/// One conclusion Requirements 14.2 through 14.4, 14.9, 14.10, and 14.17 reserve for a
/// written external decision.
///
/// Enumerated rather than hand-picked so all three are checked the same way, and so the
/// arm's expectations are derived from the member instead of written out three times.
private enum ExternalConclusion: Hashable, Sendable, CaseIterable {
    case repositoryCodeLicense
    case datasetDistributionTerms
    case modelGovernanceDecision

    /// The gate whose outcome has to report this conclusion.
    var gate: ReleaseGate {
        switch self {
        case .repositoryCodeLicense: .repositoryCodeLicense
        case .datasetDistributionTerms: .dataDistributionRights
        case .modelGovernanceDecision: .modelGovernanceDecision
        }
    }

    /// The record field the carried ``ApprovalRecord`` sits at.
    var approvalField: String {
        switch self {
        case .repositoryCodeLicense: "release.distributionRights.repositoryCodeLicense"
        case .datasetDistributionTerms: "release.distributionRights.datasetDistributionTerms"
        case .modelGovernanceDecision: "release.modelGovernance.decision"
        }
    }

    /// The approval artifact the fixtures carry for this conclusion.
    var approvalIdentifier: String {
        switch self {
        case .repositoryCodeLicense: ReleaseReadinessSample.codeLicenseApprovalIdentifier
        case .datasetDistributionTerms: ReleaseReadinessSample.datasetTermsApprovalIdentifier
        case .modelGovernanceDecision: ReleaseReadinessSample.governanceApprovalIdentifier
        }
    }

    /// What a gate outcome that disagrees with this conclusion is told to be.
    ///
    /// The disagreement names the record that decides the gate, so an audit is pointed at the
    /// approval rather than at the gate alone.
    var expectedOutcomeDisagreement: String {
        "\(GateOutcome.passed.rawValue), the approved decision at \(approvalField)"
    }

    /// The conclusion one gate reports, or `nil` when the gate decides itself.
    ///
    /// Derived from ``ReleaseGate/isExternallyDecided`` rather than assumed, so a gate the
    /// production code adds to that set without a conclusion here fails instead of being
    /// swept as an ordinary gate.
    init?(gate: ReleaseGate) {
        guard let match = Self.allCases.first(where: { $0.gate == gate }) else { return nil }
        self = match
    }
}

// MARK: - Scenario

/// A generated shape and the coherent artifacts built from it.
///
/// Built once per case. The gate table, the claim list, the evidence citations, and the
/// three validated matrices are stored rather than regenerated, and every mutation arm
/// starts from a stored value so the only difference between the baseline and a mutation is
/// the one entry, outcome, reference, or identifier the arm is about.
private struct ReleaseScenario {
    let shape: ReleaseShape

    /// Builds artifacts from the shape. Stored rather than recreated per access: it caches
    /// the whole validated identifier set for the case.
    let builder: ReleaseBuilder

    // Baseline artifacts, all coherent with each other.
    let manifest: ReleaseCapabilityManifest
    let index: ReleaseEvidenceIndex
    let matrix: ValidatedAccessibilityGateMatrix

    /// The same matrix validated for another device allowlist, or for another application
    /// build, depending on the shape. Internally valid, and it answers for a release this
    /// record is not.
    let strayMatrix: ValidatedAccessibilityGateMatrix

    /// One entry per mandatory gate, every applicable one passing and every waived one
    /// carrying an approved decision.
    let gateRecords: [ReleaseGateRecord]

    let distributionRights: DistributionRightsRecord
    let governance: ModelGovernanceDecisionRecord
    let claims: [BenchmarkClaimRecord]

    let record: ReleaseReadinessRecord
    let eligible: EligibleRelease

    // MARK: Construction

    init(shape: ReleaseShape) throws {
        let builder = ReleaseBuilder(shape: shape)

        // Locals throughout, so no closure captures a partly initialized `self`.
        let manifest = try builder.manifest(capabilities: shape.capabilities)
        let index = try builder.evidenceIndex()
        let matrix = try builder.validatedMatrix(
            manifest: manifest,
            allowlist: builder.allowlistIdentifier,
            appBuild: builder.appBuildIdentifier,
            evidence: index
        )
        // One stray matrix per case, coherent with an allowlist and a manifest of its own so
        // the refusal is about whose release it answers for rather than about the matrix.
        let strayAllowlist = shape.strayMatrixTargetsAllowlist
            ? builder.strayAllowlistIdentifier
            : builder.allowlistIdentifier
        let strayAppBuild = shape.strayMatrixTargetsAllowlist
            ? builder.appBuildIdentifier
            : builder.strayAppBuildIdentifier
        let strayMatrix = try builder.validatedMatrix(
            manifest: try builder.manifest(
                capabilities: shape.capabilities,
                allowlist: strayAllowlist,
                appBuild: strayAppBuild
            ),
            allowlist: strayAllowlist,
            appBuild: strayAppBuild,
            evidence: index
        )
        let gateRecords = try builder.gateRecords(capabilities: shape.capabilities)
        let distributionRights = ReleaseReadinessSample.distributionRights()
        let governance = try ReleaseReadinessSample.governance()
        let claims = try builder.claims()
        let record = try builder.record(
            identifier: builder.recordIdentifier,
            appBuild: builder.appBuildIdentifier,
            capabilityManifest: builder.manifestIdentifier,
            modelBundle: builder.distributedBundleIdentifier,
            deviceAllowlist: builder.allowlistIdentifier,
            gateRecords: gateRecords,
            distributionRights: distributionRights,
            modelGovernance: governance,
            benchmarkClaims: claims
        )

        self.shape = shape
        self.builder = builder
        self.manifest = manifest
        self.index = index
        self.matrix = matrix
        self.strayMatrix = strayMatrix
        self.gateRecords = gateRecords
        self.distributionRights = distributionRights
        self.governance = governance
        self.claims = claims
        self.record = record
        self.eligible = try EligibleRelease(
            validating: record,
            capabilityManifest: manifest,
            accessibilityMatrix: matrix,
            evidence: index
        )
    }

    // MARK: Selections

    /// The gate every single-target arm breaks.
    var selectedEntry: ReleaseGateRecord {
        gateRecords[shape.selectors.gate % gateRecords.count]
    }

    /// The stored entry for one gate. Total by construction: the baseline table covers
    /// every gate exactly once, which the valid arm asserts.
    func entry(_ gate: ReleaseGate) -> ReleaseGateRecord {
        gateRecords.first { $0.gate == gate } ?? selectedEntry
    }

    /// The gate whose citation an evidence omission is reported at.
    ///
    /// ``EligibleRelease`` sweeps the gates in ascending identifier order, so when two
    /// gates cite one artifact the first of them reports. The two matrix gates do exactly
    /// that — both are pinned to the validated matrix — so the reporting gate is derived
    /// rather than assumed to be the gate the arm targeted.
    func reportingGate(citing artifact: ArtifactID) -> ReleaseGate? {
        gateRecords
            .filter { $0.evidence.artifact == artifact }
            .map(\.gate)
            .min { $0.rawValue < $1.rawValue }
    }

    // MARK: - Valid arm

    /// A complete, coherent generated record is eligible, and everything the eligible value
    /// reports is what the shape generated.
    ///
    /// Without this arm the property would pass by refusing everything. The equality against
    /// the unmutated record is the second half of it: Requirement 14.1 is about what the
    /// record maps, so a validator that repaired, waived, or filled a gate would satisfy
    /// every refusal arm below while approving a distribution nobody recorded.
    ///
    /// It also pins the arrangement invariant every sweep depends on — the table covers
    /// ``ReleaseGate/allCases`` exactly once — so a gate added to the vocabulary is swept
    /// automatically rather than being silently skipped.
    func checkCompleteRecordIsEligible() {
        // Bound to a `Bool` before being asserted: a failed `#expect` renders its receiver,
        // and rendering a record that carries every gate plus its claims buries the finding
        // in an artifact dump.
        let recordUnchanged = eligible.record == record
        #expect(recordUnchanged, "eligibility returned a record it was not given [\(shape)]")

        #expect(eligible.id == Sample.artifact(builder.recordIdentifier))
        #expect(eligible.capabilityManifest == Sample.artifact(builder.manifestIdentifier))
        #expect(eligible.accessibilityMatrix == Sample.artifact(builder.matrixIdentifier))
        #expect(eligible.appBuild == Sample.appBuild(builder.appBuildIdentifier))
        #expect(eligible.modelBundle == Sample.bundle(builder.distributedBundleIdentifier))
        #expect(eligible.deviceAllowlist == Sample.artifact(builder.allowlistIdentifier))

        // Requirements 6.2 and 14.1: the reported capability set is the compiled one, by
        // explicit applicability rather than by a field's absence.
        #expect(eligible.enablesProvenance == shape.capabilities.enablesProvenance)
        #expect(eligible.enablesFusion == shape.capabilities.enablesFusion)

        // Requirement 14.14: the published limitations and channel are this record's own.
        #expect(
            eligible.publishedActiveLimitations
                == Sample.evidence(builder.gateEvidenceIdentifier(.activeLimitationsPublication))
        )
        #expect(
            eligible.publishedCorrectionChannel
                == Sample.evidence(builder.gateEvidenceIdentifier(.correctionChannel))
        )

        // Requirement 14.4: the governance conclusion is exposed as the record that decided
        // it, never as a value this module computed.
        #expect(eligible.governanceDecision.isApproved)
        #expect(
            eligible.governanceDecision.source
                == Sample.evidence(ReleaseReadinessSample.governanceApprovalIdentifier)
        )

        // Requirement 14.1: every gate maps to the immutable reference the record recorded,
        // and the table is exactly the vocabulary.
        #expect(Set(gateRecords.map(\.gate)) == Set(ReleaseGate.allCases))
        #expect(
            gateRecords.count == ReleaseGate.allCases.count,
            "a mandatory gate was added or removed: \(gateRecords.count) entries"
        )
        for entry in gateRecords {
            #expect(
                eligible.evidence(for: entry.gate) == entry.evidence,
                "\(entry.gate.rawValue) reported \(eligible.evidence(for: entry.gate)) [\(shape)]"
            )
        }

        // Requirement 14.15: nothing blocks, and the record says so itself.
        #expect(record.unresolvedMandatoryGates.isEmpty)
        #expect(record.failingMandatoryGates.isEmpty)

        // Requirement 14.12: every generated claim is published, unchanged, and reachable
        // by its identifier. An empty list is a release that publishes no claim.
        #expect(eligible.publishableClaims.map(\.claim) == claims)
        #expect(eligible.publishableClaims.count == shape.claims.count)
        for claim in claims {
            #expect(eligible.claim(claim.id) != nil, "\(claim.id.rawValue) was not published")
        }
        #expect(eligible.claim(Sample.artifact(builder.unpublishedClaimIdentifier)) == nil)

        // Requirement 14.11: every other bundle the manifest approves is distributable too, so
        // the catalog refusal in the one-record arm is about set membership rather than about a
        // fixed equality against the one bundle this baseline happens to name.
        for bundle in builder.bundleIdentifiers
        where bundle != builder.distributedBundleIdentifier {
            do {
                let distributed = try validate(
                    try rebuilt(
                        modelBundle: bundle,
                        benchmarkClaims: try builder.claims(modelBundle: bundle)
                    )
                )
                #expect(distributed.modelBundle == Sample.bundle(bundle))
            } catch {
                Issue.record(
                    "approved bundle \(bundle) was not distributable: \(error) [\(shape)]"
                )
            }
        }
    }

    // MARK: - Missing evidence arm

    /// An applicable mandatory gate with no executed result blocks, and is reported as
    /// missing evidence rather than as a failure.
    ///
    /// Quantified over every applicable entry rather than one named gate, so a gate added to
    /// ``ReleaseGate`` is covered rather than skipped. The three externally decided gates
    /// land elsewhere and are derived, not excluded: their outcome is required to agree with
    /// the ``ApprovalRecord`` they carry, so `not-executed` is refused earlier as that
    /// disagreement, and the arm asserts the reported value to keep this finding distinct
    /// from the failing one.
    func checkEveryApplicableGateNeedsAnExecutedResult() {
        for entry in gateRecords where entry.applicability.isApplicable {
            guard let mutated = built("a not-executed \(entry.gate.rawValue) entry", {
                try self.builder.rebuilt(entry, outcome: .notExecuted)
            }) else { continue }
            #expect(mutated != entry, "the not-executed entry equals the baseline [\(shape)]")

            guard let candidate = built("a record with an unrun \(entry.gate.rawValue)", {
                try self.rebuilt(gateRecords: self.table(replacing: mutated))
            }) else { continue }

            // The record reports the gate as unresolved; eligibility refuses it.
            #expect(candidate.unresolvedMandatoryGates == [entry.gate])
            #expect(candidate.failingMandatoryGates.isEmpty)

            if let conclusion = ExternalConclusion(gate: entry.gate) {
                expectRefused(
                    "an unrun \(entry.gate.rawValue) beside an approved decision",
                    .inconsistentReference,
                    reportedField: "release.gateRecords[\(entry.gate.rawValue)].outcome",
                    reportedExpected: conclusion.expectedOutcomeDisagreement,
                    reportedFound: GateOutcome.notExecuted.rawValue
                ) {
                    _ = try self.validate(candidate)
                }
            } else {
                #expect(
                    !entry.gate.isExternallyDecided,
                    "\(entry.gate.rawValue) is externally decided with no conclusion to report"
                )
                expectRefused(
                    "an unrun \(entry.gate.rawValue) result",
                    .missingRequiredEntries,
                    reportedField: "release.gateRecords[\(entry.gate.rawValue)]",
                    reportedKeys: ["an executed result"]
                ) {
                    _ = try self.validate(candidate)
                }
            }
        }
    }

    // MARK: - Unresolvable citation arm

    /// Every gate's cited result has to exist, at exactly the version and content cited.
    ///
    /// Four forms, and they are four different audit findings. A reference to an artifact
    /// the release does not carry names no record at all, so the mapping Requirement 14.1
    /// requires would point at nothing. A reference at another version, or to other content
    /// at the same identifier, names a record that is not the one the gate result came from
    /// — which is what "immutable source and version identifiers" rules out, since a gate
    /// bound to a mutable document at a fixed identifier is not bound. And a gate citing a
    /// different document altogether is refused as a different document.
    ///
    /// The first form is swept over every gate. The other three target the selected gate,
    /// because they exercise the same three branches of
    /// ``ReleaseEvidenceIndex/requireResolved(_:field:)`` for any gate and 100 cases spread
    /// the selection across the vocabulary.
    func checkEveryGateCitationMustResolve() {
        for entry in gateRecords {
            let artifact = entry.evidence.artifact
            guard let reporting = reportingGate(citing: artifact) else {
                Issue.record("no gate cites \(artifact.rawValue) [\(shape)]")
                continue
            }
            guard let reduced = built("an index without \(artifact.rawValue)", {
                try self.builder.evidenceIndex(omitting: artifact.rawValue)
            }) else { continue }

            // Non-vacuity: the baseline resolved the citation and the reduced index does
            // not, so the refusal is about the removal rather than about the reference.
            #expect(index.resolves(entry.evidence), "the baseline did not carry \(artifact)")
            #expect(!reduced.resolves(entry.evidence), "the omission left \(artifact) resolvable")

            expectRefused(
                "a \(entry.gate.rawValue) citation the release does not carry",
                .missingRequiredEntries,
                reportedField: "release.gateRecords[\(reporting.rawValue)].evidence",
                reportedKeys: [artifact.rawValue]
            ) {
                _ = try self.validate(evidence: reduced)
            }
        }

        let selected = selectedEntry
        let field = "release.gateRecords[\(selected.gate.rawValue)].evidence"

        expectRefused(
            "a \(selected.gate.rawValue) citation at another version",
            .inconsistentReference,
            reportedField: "\(field).version",
            reportedFound: builder.strayVersion.description
        ) {
            let mutated = try self.builder.rebuilt(
                selected,
                evidence: EvidenceSource(
                    artifact: selected.evidence.artifact,
                    version: self.builder.strayVersion,
                    contentDigest: selected.evidence.contentDigest
                )
            )
            _ = try self.validate(try self.rebuilt(gateRecords: self.table(replacing: mutated)))
        }

        expectRefused(
            "a \(selected.gate.rawValue) citation to other content",
            .inconsistentReference,
            reportedField: "\(field).contentDigest",
            reportedFound: builder.strayDigest.hexadecimalString
        ) {
            let mutated = try self.builder.rebuilt(
                selected,
                evidence: EvidenceSource(
                    artifact: selected.evidence.artifact,
                    version: selected.evidence.version,
                    contentDigest: self.builder.strayDigest
                )
            )
            _ = try self.validate(try self.rebuilt(gateRecords: self.table(replacing: mutated)))
        }

        // A gate citing a different record entirely. The two matrix gates are pinned to the
        // validated matrix one layer earlier, so they are refused as naming another document
        // rather than as naming nothing; that pairing is the one-record arm's subject.
        if !selected.gate.isMatrixGate {
            expectRefused(
                "a \(selected.gate.rawValue) entry citing another record",
                .missingRequiredEntries,
                reportedField: field,
                reportedKeys: [builder.strayEvidenceIdentifier]
            ) {
                let mutated = try self.builder.rebuilt(
                    selected,
                    evidence: Sample.evidence(self.builder.strayEvidenceIdentifier)
                )
                _ = try self.validate(try self.rebuilt(gateRecords: self.table(replacing: mutated)))
            }
        }
    }

    // MARK: - Failing gate arm

    /// Any failing applicable mandatory entry blocks the affected distribution, and the
    /// refusal says whether the gate is a hard public-launch blocker.
    ///
    /// Quantified over every applicable entry, so Requirement 14.15's "any" is asserted as
    /// "any" rather than as one example. The three externally decided gates are derived
    /// again: a failed outcome beside an approved decision is that disagreement, so the
    /// finding, the field, and the reported value all follow from the gate.
    func checkEveryFailingApplicableGateBlocks() {
        for entry in gateRecords where entry.applicability.isApplicable {
            guard let mutated = built("a failed \(entry.gate.rawValue) entry", {
                try self.builder.rebuilt(entry, outcome: .failed)
            }) else { continue }
            #expect(mutated != entry, "the failed entry equals the baseline [\(shape)]")

            guard let candidate = built("a record with a failed \(entry.gate.rawValue)", {
                try self.rebuilt(gateRecords: self.table(replacing: mutated))
            }) else { continue }

            #expect(candidate.failingMandatoryGates == [entry.gate])
            #expect(candidate.unresolvedMandatoryGates.isEmpty)

            if let conclusion = ExternalConclusion(gate: entry.gate) {
                expectRefused(
                    "a failed \(entry.gate.rawValue) beside an approved decision",
                    .inconsistentReference,
                    reportedField: "release.gateRecords[\(entry.gate.rawValue)].outcome",
                    reportedExpected: conclusion.expectedOutcomeDisagreement,
                    reportedFound: GateOutcome.failed.rawValue
                ) {
                    _ = try self.validate(candidate)
                }
            } else {
                // Requirements 14.16 and 14.17: a hard public-launch blocker names itself, and
                // an ordinary mandatory entry does not. Both halves are derived from the gate,
                // so this is the one place either statement is made.
                let isHardBlocker = ReleaseGate.hardPublicLaunchBlockers.contains(entry.gate)
                expectRefused(
                    "a failed \(entry.gate.rawValue) result",
                    .forbiddenValue,
                    reportedField: "release.gateRecords[\(entry.gate.rawValue)].outcome",
                    reportedFound: GateOutcome.failed.rawValue,
                    reasonNamesHardBlocker: isHardBlocker,
                    reasonNamesGate: isHardBlocker ? entry.gate : nil
                ) {
                    _ = try self.validate(candidate)
                }
            }
        }
    }

    // MARK: - Hard blocker arm

    /// Requirements 14.16 and 14.17: every hard public-launch blocker is reached by an arm
    /// that requires it to name itself, and none of them can be waived.
    ///
    /// Requirement 14.15 already blocks on any applicable mandatory entry, so the blocker set
    /// changes no outcome; what matters is that an audit hears which hard blocker refused
    /// instead of "a gate failed". Two arms make that assertion, each for the mechanism its
    /// gates actually block through, and both derive it from
    /// ``ReleaseGate/hardPublicLaunchBlockers`` rather than from a list:
    ///
    ///   * the four signed Initial Model Bundle gates block through their recorded outcome,
    ///     and the failing-gate sweep requires the reason to name the gate;
    ///   * the Lowq governance decision cannot block that way. Its outcome is required to
    ///     report the ``ApprovalRecord`` it carries, so a failed outcome beside an approved
    ///     decision is refused earlier as that disagreement, and the gate blocks through a
    ///     rejected decision — which the external-conclusion arm requires to name the gate.
    ///     Asserting the outcome path there would assert an unreachable one.
    ///
    /// What this arm adds is that the partition is total: a gate added to the blocker set
    /// fails here rather than falling outside both arms and being silently unchecked. It runs
    /// no validation of its own, because either arm already refuses every member.
    func checkHardPublicLaunchBlockersNameThemselves() {
        let blockers = ReleaseGate.hardPublicLaunchBlockers.sorted { $0.rawValue < $1.rawValue }
        #expect(!blockers.isEmpty)
        #expect(
            blockers.allSatisfy { !$0.isConditional },
            "a hard public-launch blocker is waivable: \(blockers.filter(\.isConditional))"
        )

        for gate in blockers {
            if let conclusion = ExternalConclusion(gate: gate) {
                // Reached by the external-conclusion arm, which rejects this decision.
                #expect(
                    conclusion.gate == gate,
                    "\(gate.rawValue) blocks through a decision no arm rejects"
                )
            } else {
                // Reached by the failing-gate sweep, which only visits applicable entries.
                #expect(
                    entry(gate).applicability.isApplicable,
                    "\(gate.rawValue) is not an applicable entry the failing sweep visits"
                )
            }
        }
    }

    // MARK: - Waiver arm

    /// A waiver nobody approved, or one whose approval the release cannot resolve, waives
    /// nothing.
    ///
    /// Only the two conditional gates can carry a waiver at all, and only in the capability
    /// sets that waive them, so the sweep is over the entries this case actually waived: two
    /// for a pixel-only release, one for a provenance release, none when both lanes ship.
    /// The witness asserts all three occur.
    func checkNoWaiverApprovesItself() {
        for entry in gateRecords where !entry.applicability.isApplicable {
            let field = "release.gateRecords[\(entry.gate.rawValue)]"

            guard let rejected = built("a rejected \(entry.gate.rawValue) waiver", {
                try self.builder.rebuilt(
                    entry,
                    applicability: .notApplicable(
                        decision: Sample.approval(
                            .rejected,
                            identifier: self.builder.waiverApprovalIdentifier
                        )
                    )
                )
            }) else { continue }
            #expect(rejected != entry, "the rejected waiver equals the baseline [\(shape)]")

            guard let candidate = built("a record with a rejected waiver", {
                try self.rebuilt(gateRecords: self.table(replacing: rejected))
            }) else { continue }
            #expect(candidate.failingMandatoryGates == [entry.gate])

            expectRefused(
                "a rejected \(entry.gate.rawValue) inapplicability decision",
                .forbiddenValue,
                reportedField: "\(field).outcome",
                reportedFound: ApprovalDecision.rejected.rawValue
            ) {
                _ = try self.validate(candidate)
            }

            expectRefused(
                "a \(entry.gate.rawValue) waiver the release cannot resolve",
                .missingRequiredEntries,
                reportedField: "\(field).applicability.decision.source",
                reportedKeys: [builder.strayApprovalIdentifier]
            ) {
                let stray = try self.builder.rebuilt(
                    entry,
                    applicability: .notApplicable(
                        decision: Sample.approval(
                            identifier: self.builder.strayApprovalIdentifier
                        )
                    )
                )
                _ = try self.validate(try self.rebuilt(gateRecords: self.table(replacing: stray)))
            }
        }
    }

    // MARK: - Conditional applicability arm

    /// Requirements 6.2 and 14.1: a conditional gate's applicability is the compiled
    /// capability set, not a claim, in both directions.
    ///
    /// Both directions are faults, and both are exercised in every case rather than left to
    /// the generator. A provenance-enabled build recording the feasibility gate as waived
    /// ships a capability with no gate behind it; a pixel-only build recording it applicable
    /// and passing carries evidence for a lane it does not have. The first half of the arm
    /// gets both by validating the same record against a manifest that compiled the other
    /// lane, so whichever direction the shape did not generate is covered here.
    ///
    /// The second half flips one gate against this manifest. Which layer refuses is derived,
    /// because the record schema couples the two: fusion cannot be applicable while
    /// provenance is not, so the flips that would break that coupling are unrepresentable and
    /// are refused by ``ReleaseReadinessRecord`` with its own expected value, one layer below
    /// the validator.
    func checkConditionalApplicabilityMatchesTheManifest() {
        let compiled = shape.capabilities
        let opposite = compiled.opposite

        expectRefused(
            "a \(compiled) record validated against a \(opposite) manifest",
            .inconsistentReference,
            reportedField: "release.gateRecords[\(ReleaseGate.provenanceFeasibility.rawValue)]"
                + ".applicability",
            reportedExpected: opposite.enablesProvenance ? "applicable" : "not applicable",
            reportedFound: compiled.enablesProvenance ? "applicable" : "not applicable"
        ) {
            _ = try self.validate(
                manifest: try self.builder.manifest(capabilities: opposite)
            )
        }

        for gate in ReleaseGate.allCases where gate.isConditional {
            let entry = self.entry(gate)
            let declared = entry.applicability.isApplicable
            let flippedProvenance = gate == .provenanceFeasibility
                ? !compiled.enablesProvenance
                : compiled.enablesProvenance
            let flippedFusion = gate == .fusionRuleApproval
                ? !compiled.enablesFusion
                : compiled.enablesFusion

            // Fusion applicable while provenance is not is unrepresentable, so the record
            // schema refuses the flip before the validator sees it.
            let representable = !flippedFusion || flippedProvenance
            let coupling = "not applicable while provenance feasibility is not applicable"

            expectRefused(
                "a \(compiled) build declaring \(gate.rawValue) "
                    + (declared ? "not applicable" : "applicable"),
                .inconsistentReference,
                reportedField: representable
                    ? "release.gateRecords[\(gate.rawValue)].applicability"
                    : "release.gateRecords[\(ReleaseGate.fusionRuleApproval.rawValue)]"
                        + ".applicability",
                reportedExpected: representable
                    ? (declared ? "applicable" : "not applicable")
                    : coupling,
                reportedFound: representable
                    ? (declared ? "not applicable" : "applicable")
                    : "applicable"
            ) {
                let flipped = try self.builder.rebuilt(
                    entry,
                    applicability: declared
                        ? .notApplicable(
                            decision: Sample.approval(
                                identifier: self.builder.waiverApprovalIdentifier
                            )
                        )
                        : .applicable,
                    outcome: declared ? .notExecuted : .passed
                )
                _ = try self.validate(
                    try self.rebuilt(gateRecords: self.table(replacing: flipped))
                )
            }
        }
    }

    // MARK: - External conclusion arm

    /// Requirement 14.4: the legal, data-rights, and governance conclusions are externally
    /// supplied records this layer reads and never derives.
    ///
    /// Each of the three is checked the same way. A rejected decision blocks; an approval the
    /// release cannot resolve at the cited version and digest is a synthesized approval and
    /// blocks; and the gate's own outcome stays `passed` throughout, which is what makes the
    /// refusal about the decision rather than about the gate. That last assertion is the
    /// "never derives" half: if any code path computed the conclusion from the gate result,
    /// the pass would carry the record through.
    ///
    /// The other direction — a gate outcome that disagrees with an approved decision — is
    /// asserted by the missing and failing sweeps, which visit these three gates like any
    /// other and take the expected value from ``ExternalConclusion``.
    ///
    /// Only the governance gate is a hard public-launch blocker of the three (Requirement
    /// 14.17), so the reason is required to name a hard blocker, and to name the gate, exactly
    /// there.
    func checkExternalConclusionsAreReadNeverDerived() {
        for conclusion in ExternalConclusion.allCases {
            let gate = conclusion.gate
            let isHardBlocker = ReleaseGate.hardPublicLaunchBlockers.contains(gate)

            guard let rejected = built("a rejected \(gate.rawValue) decision", {
                try self.rejecting(conclusion)
            }) else { continue }

            // The gate still records a pass, and the record itself reports nothing failing:
            // the decision is the only thing that changed.
            #expect(rejected.record(for: gate).outcome == .passed)
            #expect(rejected.failingMandatoryGates.isEmpty)
            #expect(rejected.unresolvedMandatoryGates.isEmpty)

            expectRefused(
                "a rejected \(gate.rawValue) decision beside a passing gate",
                .forbiddenValue,
                reportedField: "\(conclusion.approvalField).decision",
                reportedFound: ApprovalDecision.rejected.rawValue,
                reasonNamesHardBlocker: isHardBlocker,
                reasonNamesGate: isHardBlocker ? gate : nil
            ) {
                _ = try self.validate(rejected)
            }

            expectRefused(
                "an approved \(gate.rawValue) decision the release cannot resolve",
                .missingRequiredEntries,
                reportedField: "\(conclusion.approvalField).source",
                reportedKeys: [conclusion.approvalIdentifier]
            ) {
                _ = try self.validate(
                    evidence: try self.builder.evidenceIndex(
                        omitting: conclusion.approvalIdentifier
                    )
                )
            }

        }

        // Requirement 14.9: the disclosures are required data, and the decision is separate.
        // The rejected governance record above and the eligible baseline carry identical
        // disclosures and differ only in the decision, so the refusal cannot be coming from
        // anything this module computed about the checkpoint.
        guard let rejected = built("a rejected governance decision", {
            try ReleaseReadinessSample.governance(decision: .rejected)
        }) else { return }
        #expect(
            governance.isIndependentNonPeerReviewed == rejected.isIndependentNonPeerReviewed
        )
        #expect(governance.redTeamValidationValid == rejected.redTeamValidationValid)
        #expect(governance.inheritedRedTeamStatus == rejected.inheritedRedTeamStatus)
        #expect(governance.modelIdentity == rejected.modelIdentity)
        #expect(governance.decision.decision != rejected.decision.decision)
        #expect(eligible.governanceDecision.isApproved)
    }

    // MARK: - One record arm

    /// Requirement 14.11: one record answers for one build, one bundle, and one allowlist.
    ///
    /// Every identifier the record carries is a free field, so each is required to be the
    /// artifact this release binds. That is the mechanism a model refresh relies on: the
    /// refresh changes the bundle, so its evidence cannot be recorded against this build's
    /// record and a fresh record has to repeat every gate.
    ///
    /// The validated matrix is pinned in both directions. Its own validation tied it to one
    /// allowlist and one application version; what is added here is that those are *this*
    /// record's, and that the two matrix gates cite the matrix that was validated rather than
    /// some other document. The stray matrix is internally valid — it was validated against a
    /// coherent allowlist and manifest of its own — so the refusal is about whose release it
    /// answers for. Which of the two it gets wrong is generated, and the witness requires both
    /// to have occurred.
    func checkOneRecordOneBuildOneBundleOneAllowlist() {
        expectRefused(
            "a record naming another capability manifest",
            .inconsistentReference,
            reportedField: "release.capabilityManifest",
            reportedExpected: builder.manifestIdentifier,
            reportedFound: builder.strayManifestIdentifier
        ) {
            _ = try self.validate(
                try self.rebuilt(capabilityManifest: self.builder.strayManifestIdentifier)
            )
        }

        expectRefused(
            "a record naming another application build",
            .inconsistentReference,
            reportedField: "release.appBuild",
            reportedExpected: builder.appBuildIdentifier,
            reportedFound: builder.strayAppBuildIdentifier
        ) {
            _ = try self.validate(
                try self.rebuilt(appBuild: self.builder.strayAppBuildIdentifier)
            )
        }

        expectRefused(
            "a record distributing a bundle outside the approved catalog",
            .inconsistentReference,
            reportedField: "release.modelBundle",
            reportedFound: builder.strayBundleIdentifier
        ) {
            _ = try self.validate(
                try self.rebuilt(
                    modelBundle: self.builder.strayBundleIdentifier,
                    benchmarkClaims: try self.builder.claims(
                        modelBundle: self.builder.strayBundleIdentifier
                    )
                )
            )
        }

        expectRefused(
            "a record naming another device allowlist",
            .inconsistentReference,
            reportedField: "release.deviceAllowlist",
            reportedExpected: builder.allowlistIdentifier,
            reportedFound: builder.strayAllowlistIdentifier
        ) {
            _ = try self.validate(
                try self.rebuilt(deviceAllowlist: self.builder.strayAllowlistIdentifier)
            )
        }

        // Non-vacuity: the stray matrix really answers for another release, and it differs
        // from the baseline in exactly the one field this case targets.
        let targetsAllowlist = shape.strayMatrixTargetsAllowlist
        #expect(
            (strayMatrix.allowlist != matrix.allowlist) == targetsAllowlist,
            "the stray matrix's allowlist is \(strayMatrix.allowlist) [\(shape)]"
        )
        #expect(
            (strayMatrix.appBuild != matrix.appBuild) != targetsAllowlist,
            "the stray matrix's application build is \(strayMatrix.appBuild) [\(shape)]"
        )

        expectRefused(
            targetsAllowlist
                ? "a matrix validated for another device allowlist"
                : "a matrix validated for another application version",
            .inconsistentReference,
            reportedField: targetsAllowlist
                ? "release.accessibilityMatrix.allowlist"
                : "release.accessibilityMatrix.appBuild",
            reportedExpected: targetsAllowlist
                ? builder.allowlistIdentifier
                : builder.appBuildIdentifier,
            reportedFound: targetsAllowlist
                ? builder.strayAllowlistIdentifier
                : builder.strayAppBuildIdentifier
        ) {
            _ = try self.validate(accessibilityMatrix: self.strayMatrix)
        }

        // The two matrix gates cite the validated matrix. The replacement is a record the
        // release *does* carry, so the refusal is about naming a different document rather
        // than about an unresolvable reference.
        let substitute = builder.gateEvidenceIdentifier(.privacyAudit)
        for gate in ReleaseGate.allCases where gate.isMatrixGate {
            expectRefused(
                "a \(gate.rawValue) entry citing a document outside the validated matrix",
                .inconsistentReference,
                reportedField: "release.gateRecords[\(gate.rawValue)].evidence",
                reportedExpected: builder.matrixIdentifier,
                reportedFound: substitute
            ) {
                let mutated = try self.builder.rebuilt(
                    self.entry(gate),
                    evidence: Sample.evidence(substitute)
                )
                _ = try self.validate(
                    try self.rebuilt(gateRecords: self.table(replacing: mutated))
                )
            }
        }

        // Requirement 14.1: the capability set the record answers for is one someone
        // approved, and its approval is a record the release carries.
        expectRefused(
            "a record mapped to an unapproved capability set",
            .forbiddenValue,
            reportedField: "release.capabilityManifest.approval.decision",
            reportedFound: ApprovalDecision.rejected.rawValue
        ) {
            _ = try self.validate(
                manifest: try self.builder.manifest(
                    capabilities: self.shape.capabilities,
                    approval: .rejected
                )
            )
        }

        expectRefused(
            "a capability-set approval the release cannot resolve",
            .missingRequiredEntries,
            reportedField: "release.capabilityManifest.approval.source",
            reportedKeys: [builder.strayApprovalIdentifier]
        ) {
            _ = try self.validate(
                manifest: try self.builder.manifest(
                    capabilities: self.shape.capabilities,
                    approvalEvidence: self.builder.strayApprovalIdentifier
                )
            )
        }
    }

    // MARK: - Claim binding arm

    /// Requirement 14.12: a published claim's bindings come from the release, not from the
    /// claim.
    ///
    /// This is the record's half of the statement, and it is the only claim question this
    /// file asks. Property 24 quantifies whether a claim carries every binding Requirement
    /// 8.16 lists, by mutating the claim; here the *record* moves and the claim stays, which
    /// is what shows the binding is sourced from the record rather than nominated by the
    /// claim. Three mutations, each of a different record field, plus the record schema's
    /// refusal to publish one identifier twice.
    func checkPublishedClaimsAreBoundByTheRecord() {
        guard let published = claims.first else {
            #expect(eligible.publishableClaims.isEmpty, "a release with no claim published one")
            return
        }
        let field = "claim[\(published.id.rawValue)]"
        let substitute = builder.gateEvidenceIdentifier(.privacyAudit)

        for gate in [ReleaseGate.activeLimitationsPublication, .correctionChannel] {
            let name = gate == .activeLimitationsPublication
                ? "activeLimitations"
                : "correctionChannel"
            expectRefused(
                "a claim bound to a \(name) this record no longer publishes",
                .inconsistentReference,
                reportedField: "\(field).\(name)",
                reportedFound: builder.gateEvidenceIdentifier(gate) + "@"
                    + Sample.version().description
            ) {
                let mutated = try self.builder.rebuilt(
                    self.entry(gate),
                    evidence: Sample.evidence(substitute)
                )
                _ = try self.validate(
                    try self.rebuilt(gateRecords: self.table(replacing: mutated))
                )
            }
        }

        // The Model Bundle a claim is measured on comes from the record. Only reachable with
        // more than one approved bundle: the replacement has to stay inside the catalog, or
        // the record would be refused at `release.modelBundle` first.
        if let other = builder.bundleIdentifiers.first(
            where: { $0 != builder.distributedBundleIdentifier }
        ) {
            expectRefused(
                "a claim measured on the bundle this record no longer distributes",
                .inconsistentReference,
                reportedField: "\(field).modelBundle",
                reportedExpected: other,
                reportedFound: builder.distributedBundleIdentifier
            ) {
                _ = try self.validate(try self.rebuilt(modelBundle: other))
            }
        }

        expectRefused(
            "a record publishing one claim identifier twice",
            .duplicateEntry,
            reportedField: "release.benchmarkClaims",
            reportedKeys: [published.id.rawValue]
        ) {
            _ = try self.validate(try self.rebuilt(benchmarkClaims: [published, published]))
        }
    }

    // MARK: - Reassembly

    /// The baseline gate table with one entry replaced.
    ///
    /// By gate rather than by position, so nothing depends on the table and the vocabulary
    /// happening to be in the same order.
    private func table(replacing entry: ReleaseGateRecord) -> [ReleaseGateRecord] {
        gateRecords.map { $0.gate == entry.gate ? entry : $0 }
    }

    /// The baseline record with one field replaced.
    ///
    /// Every parameter is optional rather than defaulting to a baseline literal or an empty
    /// collection: an empty-as-default sentinel would silently restore the claim list and
    /// make the claim arms pass vacuously.
    private func rebuilt(
        identifier: String? = nil,
        appBuild: String? = nil,
        capabilityManifest: String? = nil,
        modelBundle: String? = nil,
        deviceAllowlist: String? = nil,
        gateRecords replacement: [ReleaseGateRecord]? = nil,
        distributionRights rights: DistributionRightsRecord? = nil,
        modelGovernance: ModelGovernanceDecisionRecord? = nil,
        benchmarkClaims: [BenchmarkClaimRecord]? = nil
    ) throws -> ReleaseReadinessRecord {
        try builder.record(
            identifier: identifier ?? builder.recordIdentifier,
            appBuild: appBuild ?? builder.appBuildIdentifier,
            capabilityManifest: capabilityManifest ?? builder.manifestIdentifier,
            modelBundle: modelBundle ?? builder.distributedBundleIdentifier,
            deviceAllowlist: deviceAllowlist ?? builder.allowlistIdentifier,
            gateRecords: replacement ?? gateRecords,
            distributionRights: rights ?? distributionRights,
            modelGovernance: modelGovernance ?? governance,
            benchmarkClaims: benchmarkClaims ?? claims
        )
    }

    /// The baseline record with one external conclusion rejected.
    private func rejecting(_ conclusion: ExternalConclusion) throws -> ReleaseReadinessRecord {
        switch conclusion {
        case .repositoryCodeLicense:
            return try rebuilt(
                distributionRights: ReleaseReadinessSample.distributionRights(code: .rejected)
            )
        case .datasetDistributionTerms:
            return try rebuilt(
                distributionRights: ReleaseReadinessSample.distributionRights(data: .rejected)
            )
        case .modelGovernanceDecision:
            return try rebuilt(
                modelGovernance: try ReleaseReadinessSample.governance(decision: .rejected)
            )
        }
    }

    /// Validates the baseline with at most one input replaced.
    private func validate(
        _ replacement: ReleaseReadinessRecord? = nil,
        manifest: ReleaseCapabilityManifest? = nil,
        accessibilityMatrix: ValidatedAccessibilityGateMatrix? = nil,
        evidence: ReleaseEvidenceIndex? = nil
    ) throws -> EligibleRelease {
        try EligibleRelease(
            validating: replacement ?? record,
            capabilityManifest: manifest ?? self.manifest,
            accessibilityMatrix: accessibilityMatrix ?? matrix,
            evidence: evidence ?? index
        )
    }

    // MARK: - Refusal helpers

    /// Builds a value an arm needs, recording an issue rather than escaping on failure.
    ///
    /// `propertyCheck` discards an error thrown by its body without recording an issue, so a
    /// construction that unexpectedly threw would silently skip the arm and the property
    /// would pass vacuously — a trap this codebase has already sprung three times.
    private func built<T>(
        _ what: String,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ make: () throws -> T
    ) -> T? {
        do {
            return try make()
        } catch {
            Issue.record(
                "\(what) could not be built: \(error) [\(shape)]",
                sourceLocation: sourceLocation
            )
            return nil
        }
    }

    /// Requires `build` to refuse with a specific fault, recording an issue otherwise.
    ///
    /// Never rethrows, for the reason above.
    ///
    /// `reportedField` is asserted everywhere, because the arms here land on four faults
    /// between them and most of them share one: the case alone would let a missing result be
    /// refused for an unresolvable citation's reason, or one gate's failure stand in for
    /// another's, and still pass. `reportedKeys` is asserted wherever the fault carries them,
    /// which is what separates "this gate's citation is missing" from "this gate has no
    /// result". `reportedFound` and `reportedExpected` are asserted wherever two arms share
    /// both the case and the field — a `not-executed` and a `failed` outcome at an externally
    /// decided gate are one case at one field, and only the reported value tells them apart.
    private func expectRefused(
        _ what: String,
        _ expected: ReleaseReadinessFault,
        reportedField: String,
        reportedKeys: Set<String>? = nil,
        reportedExpected: String? = nil,
        reportedFound: String? = nil,
        reasonNamesHardBlocker: Bool? = nil,
        reasonNamesGate: ReleaseGate? = nil,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ build: () throws -> Void
    ) {
        do {
            try build()
            Issue.record("\(what) was accepted [\(shape)]", sourceLocation: sourceLocation)
        } catch let error as ArtifactSchemaError {
            #expect(
                ReleaseReadinessFault(error) == expected,
                "\(what) was refused as \(error) [\(shape)]",
                sourceLocation: sourceLocation
            )
            #expect(
                ReleaseReadinessFault.reportedField(error) == reportedField,
                "\(what) named \(ReleaseReadinessFault.reportedField(error)) [\(shape)]",
                sourceLocation: sourceLocation
            )
            if let reportedKeys {
                let named = ReleaseReadinessFault.reportedKeys(error) ?? []
                #expect(
                    named == reportedKeys,
                    """
                    \(what) named \(named.sorted()) rather than \(reportedKeys.sorted()) \
                    [\(shape)]
                    """,
                    sourceLocation: sourceLocation
                )
            }
            if let reportedExpected {
                #expect(
                    ReleaseReadinessFault.reportedExpected(error) == reportedExpected,
                    """
                    \(what) expected \(ReleaseReadinessFault.reportedExpected(error) ?? "nothing") \
                    [\(shape)]
                    """,
                    sourceLocation: sourceLocation
                )
            }
            if let reportedFound {
                #expect(
                    ReleaseReadinessFault.reportedFound(error) == reportedFound,
                    """
                    \(what) found \(ReleaseReadinessFault.reportedFound(error) ?? "nothing") \
                    rather than \(reportedFound) [\(shape)]
                    """,
                    sourceLocation: sourceLocation
                )
            }
            if let reasonNamesHardBlocker {
                let reason = ReleaseReadinessFault.reportedReason(error) ?? ""
                #expect(
                    reason.contains("hard public-launch blocker") == reasonNamesHardBlocker,
                    "\(what) was refused because \"\(reason)\" [\(shape)]",
                    sourceLocation: sourceLocation
                )
            }
            if let reasonNamesGate {
                let reason = ReleaseReadinessFault.reportedReason(error) ?? ""
                #expect(
                    reason.contains(reasonNamesGate.rawValue),
                    """
                    \(reasonNamesGate.rawValue) refused as "\(reason)" without naming itself \
                    [\(shape)]
                    """,
                    sourceLocation: sourceLocation
                )
            }
        } catch {
            Issue.record(
                "\(what) failed with a non-schema error \(error) [\(shape)]",
                sourceLocation: sourceLocation
            )
        }
    }
}

// MARK: - Gate classification

extension ReleaseGate {
    /// Whether this gate's result reference is pinned to the validated accessibility and
    /// Localization Readiness matrix.
    ///
    /// Derived rather than listed at each use so the two gates the release validator pins
    /// stay in one place.
    fileprivate var isMatrixGate: Bool {
        self == .accessibilityMatrix || self == .localizationReadinessMatrix
    }
}

// MARK: - Builder

/// Builds every artifact the property needs from one generated shape.
///
/// Separate from the scenario so the stored baseline and every arm's mutation go through the
/// same construction path: an arm hands in one replaced entry, identifier, or list and gets
/// the same artifacts back otherwise.
///
/// The fixtures do the constructing wherever they expose the field an arm changes, so this
/// property quantifies what ``EligibleReleaseTests`` pins rather than building a parallel
/// record of its own. The capability manifest is assembled here instead, because the fixture
/// pins the approved bundle catalog to one bundle and this property generates it.
private struct ReleaseBuilder {
    let shape: ReleaseShape
    let seed: Int

    // MARK: Identifiers
    //
    // Stored rather than computed: this set is read a few thousand times per generated case
    // and every value is validated on construction.
    //
    // The manifest, allowlist, matrix, application build, calibration policy, and the four
    // approval records keep the identifiers the fixtures pin, so `AccessibilityMatrixSample`
    // produces the matrix this record answers for and `ReleaseReadinessSample` produces the
    // external approvals it carries. Everything the record cites for itself carries the seed.

    let recordIdentifier: String
    let manifestIdentifier = ReleaseReadinessSample.manifestIdentifier
    let allowlistIdentifier = ReleaseReadinessSample.allowlistIdentifier
    let matrixIdentifier = ReleaseReadinessSample.matrixIdentifier
    let appBuildIdentifier = ReleaseReadinessSample.appBuildIdentifier
    let configurationIdentifier = AccessibilityMatrixSample.baselineConfigurationIdentifier
    let calibrationPolicyIdentifier = ReleaseReadinessSample.calibrationPolicyIdentifier
    let manifestApprovalIdentifier = ReleaseReadinessSample.sharedApprovalIdentifier
    let allowlistApprovalIdentifier = AccessibilityMatrixSample.allowlistApprovalIdentifier

    /// The approval every waived conditional gate cites.
    let waiverApprovalIdentifier: String

    /// The Model Bundles this manifest approves, and the one the record distributes.
    let bundleIdentifiers: [String]
    let distributedBundleIdentifier: String

    /// Claim evidence, shared by every generated claim of one case.
    let datasetIdentifier: String
    let compositionIdentifier: String
    let degradationIdentifier: String
    let metricIdentifier: String
    let runIdentifier: String

    /// A claim identifier this release does not publish, for the accessor assertion.
    let unpublishedClaimIdentifier: String

    // Artifacts and values this release does not carry, for the refusal arms.
    let strayManifestIdentifier: String
    let strayAllowlistIdentifier: String
    let strayAppBuildIdentifier: String
    let strayBundleIdentifier: String
    let strayApprovalIdentifier: String
    let strayEvidenceIdentifier: String

    /// A version and a content digest this release carries no evidence at.
    let strayVersion: SchemaSemanticVersion
    let strayDigest: SHA256Digest

    /// Every artifact identifier the baseline cites, and the evidence records themselves.
    let citedIdentifiers: [String]
    let citedEvidence: [EvidenceSource]

    init(shape: ReleaseShape) {
        let seed = shape.seed
        self.shape = shape
        self.seed = seed

        recordIdentifier = "record.release-readiness-\(seed)"
        waiverApprovalIdentifier = "approval.waiver-\(seed)"
        bundleIdentifiers = (0..<shape.catalogSize).map { "bundle.model-\(seed)-\($0)" }
        distributedBundleIdentifier = bundleIdentifiers[
            shape.selectors.bundle % bundleIdentifiers.count
        ]
        datasetIdentifier = "evidence.dataset-\(seed)"
        compositionIdentifier = "evidence.composition-\(seed)"
        degradationIdentifier = "evidence.degradation-\(seed)"
        metricIdentifier = "evidence.metric-\(seed)"
        runIdentifier = "evidence.run-\(seed)"
        unpublishedClaimIdentifier = "claim.benchmark-\(seed)-unpublished"

        strayManifestIdentifier = "manifest.capability-elsewhere-\(seed)"
        strayAllowlistIdentifier = "allowlist.devices-elsewhere-\(seed)"
        strayAppBuildIdentifier = "build.app-elsewhere-\(seed)"
        strayBundleIdentifier = "bundle.model-elsewhere-\(seed)"
        strayApprovalIdentifier = "approval.elsewhere-\(seed)"
        strayEvidenceIdentifier = "evidence.elsewhere-\(seed)"

        // `Sample.evidence` pins version 1.0.0 and one content digest for every record this
        // release carries, so a second major version and a different digest are the values
        // nothing resolves at.
        strayVersion = Sample.version("2.\(seed % 1_000).0")
        strayDigest = Sample.digest("b")

        let identifiers = Self.citedIdentifiers(
            seed: seed,
            waiverApproval: "approval.waiver-\(seed)",
            claimEvidence: [
                "evidence.dataset-\(seed)",
                "evidence.composition-\(seed)",
                "evidence.degradation-\(seed)",
                "evidence.metric-\(seed)",
                "evidence.run-\(seed)",
            ]
        )
        citedIdentifiers = identifiers
        citedEvidence = identifiers.map { Sample.evidence($0) }
    }

    // MARK: Gate evidence

    /// The evidence identifier the baseline record cites for one gate.
    ///
    /// The two matrix gates cite the validated matrix itself, because that is the artifact
    /// the release validator pins them to. Every other gate cites its own seeded result
    /// record, so each citation varies per case and a sweep can name exactly one.
    func gateEvidenceIdentifier(_ gate: ReleaseGate) -> String {
        gate.isMatrixGate ? matrixIdentifier : "evidence.release-\(seed).\(gate.rawValue)"
    }

    /// Every artifact identifier the coherent baseline cites, each one once, and the evidence
    /// records themselves.
    ///
    /// De-duplicated as a list rather than a set so the order is stable: the two matrix gates
    /// share one citation, and ``ReleaseEvidenceIndex`` refuses a repeated artifact.
    ///
    /// Both are stored rather than computed. The unresolvable-citation sweep rebuilds the
    /// index once per gate, and reconstructing every record each time would spend the run
    /// re-parsing content digests instead of exercising eligibility.
    static func citedIdentifiers(
        seed: Int,
        waiverApproval: String,
        claimEvidence: [String]
    ) -> [String] {
        var identifiers: [String] = []
        for candidate in ReleaseGate.allCases.map({
            $0.isMatrixGate
                ? ReleaseReadinessSample.matrixIdentifier
                : "evidence.release-\(seed).\($0.rawValue)"
        })
            + [
                ReleaseReadinessSample.sharedApprovalIdentifier,
                AccessibilityMatrixSample.allowlistApprovalIdentifier,
                waiverApproval,
                ReleaseReadinessSample.codeLicenseApprovalIdentifier,
                ReleaseReadinessSample.datasetTermsApprovalIdentifier,
                ReleaseReadinessSample.governanceApprovalIdentifier,
                AccessibilityMatrixSample.accessibilityEvidenceIdentifier,
                AccessibilityMatrixSample.localizationEvidenceIdentifier,
            ]
            + claimEvidence
        where !identifiers.contains(candidate) {
            identifiers.append(candidate)
        }
        return identifiers
    }

    /// The release evidence the baseline cites, minus whatever an arm removes.
    ///
    /// `omitting` is how an arm makes one citation unresolvable without touching the record
    /// that cites it, which is the difference between "this reference names nothing" and
    /// "this record names something else". It filters the stored records, so the removal is
    /// the only difference from the baseline index.
    func evidenceIndex(omitting omitted: String? = nil) throws -> ReleaseEvidenceIndex {
        guard let omitted else { return try ReleaseEvidenceIndex(records: citedEvidence) }
        return try ReleaseEvidenceIndex(
            records: citedEvidence.filter { $0.artifact.rawValue != omitted }
        )
    }

    // MARK: Capability manifest

    /// The signed manifest the record answers for.
    ///
    /// Assembled here rather than taken from
    /// ``ReleaseReadinessSample/capabilityManifest(provenanceEnabled:fusionEnabled:approval:approvalEvidence:)``
    /// because that fixture pins the approved bundle catalog to one bundle, the allowlist,
    /// and the application build, and three arms generate exactly those. The conditional
    /// policy bindings the manifest schema couples to the compiled capability set are derived
    /// from one ``CapabilitySet`` rather than being separate knobs a caller could leave
    /// inconsistent.
    func manifest(
        capabilities: CapabilitySet,
        approval: ApprovalDecision = .approved,
        approvalEvidence: String? = nil,
        allowlist: String? = nil,
        appBuild: String? = nil
    ) throws -> ReleaseCapabilityManifest {
        var compiled: Set<CapabilityID> = [.pixelAnalysis]
        if capabilities.enablesProvenance { compiled.insert(.contentCredentialValidation) }
        if capabilities.enablesFusion { compiled.insert(.evidenceFusion) }
        return try ReleaseCapabilityManifest(
            id: Sample.artifact(manifestIdentifier),
            schemaVersion: .v1,
            appBuild: Sample.appBuild(appBuild ?? appBuildIdentifier),
            compositionIdentifier: Sample.text(
                capabilities.enablesProvenance ? "pixel-plus-provenance" : "pixel-only"
            ),
            compiledCapabilities: compiled,
            implementationVersions: compiled.sorted { $0.rawValue < $1.rawValue }
                .map { CapabilityImplementationEntry(capability: $0, version: Sample.version()) },
            approvedConfigurationAllowlist: Sample.artifact(allowlist ?? allowlistIdentifier),
            approvedBundleCatalog: bundleIdentifiers.map(Sample.bundle),
            policyCompatibility: try Sample.policyCompatibility(
                provenance: capabilities.enablesProvenance
                    ? .bound(Sample.artifact("policy.provenance"))
                    : .notApplicable(decision: Sample.approval()),
                fusion: capabilities.enablesFusion
                    ? .bound(Sample.artifact("rule.fusion"))
                    : .notApplicable(decision: Sample.approval())
            ),
            approval: Sample.approval(
                approval,
                identifier: approvalEvidence ?? manifestApprovalIdentifier
            )
        )
    }

    // MARK: Accessibility matrix

    /// One validated accessibility and Localization Readiness matrix.
    ///
    /// Every input is required, so no caller can restore the baseline allowlist or application
    /// build by omission. The coverage is one approved configuration deliberately: whether
    /// the matrices cover every required cell is Property 31's statement, and a second
    /// position would double the 56 cells this property builds twice per case without changing
    /// anything it asserts.
    func validatedMatrix(
        manifest: ReleaseCapabilityManifest,
        allowlist allowlistIdentifier: String,
        appBuild: String,
        evidence index: ReleaseEvidenceIndex
    ) throws -> ValidatedAccessibilityGateMatrix {
        let entries = [
            try AccessibilityMatrixSample.entry(
                identifier: configurationIdentifier,
                appBuild: appBuild,
                capabilityManifest: manifestIdentifier
            )
        ]
        return try ValidatedAccessibilityGateMatrix(
            validating: try AccessibilityMatrixSample.matrix(
                coverage: AccessibilityMatrixSample.coverage(of: entries)
            ),
            against: try AccessibilityMatrixSample.allowlist(
                identifier: allowlistIdentifier,
                entries: entries,
                approvalEvidence: allowlistApprovalIdentifier
            ),
            capabilityManifest: manifest,
            evidence: index
        )
    }

    // MARK: Gate records

    /// One entry per mandatory gate, every applicable one passing.
    ///
    /// The whole citation table is supplied rather than left to the fixture's default, so a
    /// change to that default cannot silently restore a citation an arm meant to move.
    func gateRecords(capabilities: CapabilitySet) throws -> [ReleaseGateRecord] {
        try ReleaseReadinessSample.gateRecords(
            provenanceApplicable: capabilities.enablesProvenance,
            fusionApplicable: capabilities.enablesFusion,
            waiverEvidence: waiverApprovalIdentifier,
            evidenceIdentifiers: Dictionary(
                uniqueKeysWithValues: ReleaseGate.allCases.map {
                    ($0, gateEvidenceIdentifier($0))
                }
            )
        )
    }

    /// One gate entry with one field replaced.
    ///
    /// Every other field is copied off the stored entry, so a mutation cannot change the
    /// applicability, the outcome, and the citation at once — which would leave a refusal free
    /// to be about any of them.
    func rebuilt(
        _ entry: ReleaseGateRecord,
        applicability: GateApplicability? = nil,
        outcome: GateOutcome? = nil,
        evidence: EvidenceSource? = nil
    ) throws -> ReleaseGateRecord {
        try ReleaseGateRecord(
            gate: entry.gate,
            applicability: applicability ?? entry.applicability,
            outcome: outcome ?? entry.outcome,
            evidence: evidence ?? entry.evidence
        )
    }

    // MARK: Claims

    /// The generated published claims, each completely bound to this release.
    ///
    /// The bundle is a parameter because two arms move the record to another bundle and the
    /// claims have to follow: a claim left on the old bundle would be refused as that
    /// disagreement, which is the claim arm's subject rather than those arms'.
    func claims(modelBundle: String? = nil) throws -> [BenchmarkClaimRecord] {
        try shape.claims.enumerated().map { offset, claim in
            let insufficient = claim.insufficientCounts
            return try ReleaseReadinessSample.claim(
                identifier: "claim.benchmark-\(seed)-\(offset)",
                modelBundle: modelBundle ?? distributedBundleIdentifier,
                calibrationPolicy: calibrationPolicyIdentifier,
                counts: try ReleaseReadinessSample.outcomeCounts(
                    eligibleReal: claim.realDecisive + insufficient[0],
                    eligibleSynthetic: claim.syntheticDecisive + insufficient[1],
                    realDecisive: claim.realDecisive,
                    syntheticDecisive: claim.syntheticDecisive
                ),
                coverage: claim.everyEligibleImageDecisive
                    ? 1
                    : Decimal(sign: .plus, exponent: -3, significand: Decimal(
                        claim.coverageThousandths
                    )),
                dataset: datasetIdentifier,
                composition: compositionIdentifier,
                degradation: degradationIdentifier,
                metricDefinition: metricIdentifier,
                evidenceProvenance: runIdentifier,
                activeLimitations: gateEvidenceIdentifier(.activeLimitationsPublication),
                correctionChannel: gateEvidenceIdentifier(.correctionChannel)
            )
        }
    }

    // MARK: Record

    /// One release-readiness record. Every input is required, so no caller can restore a
    /// baseline field by omission.
    func record(
        identifier: String,
        appBuild: String,
        capabilityManifest: String,
        modelBundle: String,
        deviceAllowlist: String,
        gateRecords: [ReleaseGateRecord],
        distributionRights: DistributionRightsRecord,
        modelGovernance: ModelGovernanceDecisionRecord,
        benchmarkClaims: [BenchmarkClaimRecord]
    ) throws -> ReleaseReadinessRecord {
        try ReleaseReadinessSample.record(
            identifier: identifier,
            appBuild: appBuild,
            capabilityManifest: capabilityManifest,
            modelBundle: modelBundle,
            deviceAllowlist: deviceAllowlist,
            gateRecords: gateRecords,
            distributionRights: distributionRights,
            modelGovernance: modelGovernance,
            benchmarkClaims: benchmarkClaims
        )
    }
}

// MARK: - Fault classification

/// Which ``ArtifactSchemaError`` a refusal reported, without its value strings.
///
/// Asserting the case rather than the whole value keeps the property about *why* a release
/// was refused while leaving the audit message free to change. The field, the reported keys,
/// the expected and found values, and the reason are asserted separately, because most arms
/// here land on the same case.
private enum ReleaseReadinessFault: Equatable {
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

    /// The artifact field a refusal named. Every case names one.
    static func reportedField(_ error: ArtifactSchemaError) -> String {
        switch error {
        case let .emptyValue(field): field
        case let .placeholderValue(field, _): field
        case let .noncanonicalValue(field, _): field
        case let .valueOutOfRange(field, _, _): field
        case let .nonPositiveValue(field, _): field
        case let .nonFiniteValue(field, _): field
        case let .duplicateEntry(field, _): field
        case let .missingRequiredEntries(field, _): field
        case let .unexpectedEntries(field, _): field
        case let .fixedValueMismatch(field, _, _): field
        case let .forbiddenValue(field, _, _): field
        case let .inconsistentReference(field, _, _): field
        }
    }

    /// The entry keys a refusal named, or `nil` for a fault that names no key set.
    ///
    /// This is what makes the gate sweeps exact: an unrun gate and an unresolvable citation
    /// both report a missing entry set, and only the keys distinguish "no executed result"
    /// from "the release carries no such artifact".
    static func reportedKeys(_ error: ArtifactSchemaError) -> Set<String>? {
        switch error {
        case let .duplicateEntry(_, key): [key]
        case let .missingRequiredEntries(_, keys): Set(keys)
        case let .unexpectedEntries(_, keys): Set(keys)
        default: nil
        }
    }

    /// The value a refusal expected, for the faults that name one.
    static func reportedExpected(_ error: ArtifactSchemaError) -> String? {
        switch error {
        case let .fixedValueMismatch(_, expected, _): expected
        case let .inconsistentReference(_, expected, _): expected
        default: nil
        }
    }

    /// The offending value a refusal reported.
    ///
    /// This is what separates two arms that share both the case and the field: at an
    /// externally decided gate, an unrun result and a failed result are one
    /// ``ArtifactSchemaError/inconsistentReference`` at one field, and only the found value
    /// says which happened.
    static func reportedFound(_ error: ArtifactSchemaError) -> String? {
        switch error {
        case let .placeholderValue(_, value): value
        case let .noncanonicalValue(_, value): value
        case let .valueOutOfRange(_, value, _): value
        case let .nonPositiveValue(_, value): value
        case let .nonFiniteValue(_, value): value
        case let .fixedValueMismatch(_, _, found): found
        case let .forbiddenValue(_, value, _): value
        case let .inconsistentReference(_, _, found): found
        default: nil
        }
    }

    /// Why a forbidden value is forbidden, which is where a hard public-launch blocker names
    /// itself.
    static func reportedReason(_ error: ArtifactSchemaError) -> String? {
        switch error {
        case let .forbiddenValue(_, _, reason): reason
        default: nil
        }
    }
}

// MARK: - Non-vacuity witness

/// Records what the generator actually produced, so the property cannot pass by generating
/// one fixed shape a hundred times.
///
/// A property whose baseline never varies asserts one example a hundred times over. This
/// collects the dimensions the arms depend on and requires each to have been exercised with
/// more than one value. It also counts the coherent baselines that were actually built: a run
/// where every baseline construction threw would otherwise report nothing, because
/// `propertyCheck` discards an error thrown by its body.
private final class ReleaseReadinessVariationWitness: @unchecked Sendable {
    private let lock = NSLock()
    private var seeds = Set<Int>()
    private var capabilitySets = Set<CapabilitySet>()
    private var catalogSizes = Set<Int>()
    private var claimCounts = Set<Int>()
    private var coverageRegimes = Set<Bool>()
    private var strayMatrixTargets = Set<Bool>()
    private var applicableGateCounts = Set<Int>()
    private var waivedGateCounts = Set<Int>()
    private var selectedGates = Set<ReleaseGate>()
    private var distributedBundles = Set<String>()
    private var eligibleSampleCounts = Set<Int>()
    private var cases = 0
    private var baselines = 0

    func record(_ shape: ReleaseShape) {
        lock.lock()
        defer { lock.unlock() }
        cases += 1
        seeds.insert(shape.seed)
        capabilitySets.insert(shape.capabilities)
        catalogSizes.insert(shape.catalogSize)
        claimCounts.insert(shape.claims.count)
        strayMatrixTargets.insert(shape.strayMatrixTargetsAllowlist)
        for claim in shape.claims {
            coverageRegimes.insert(claim.everyEligibleImageDecisive)
        }
    }

    func recordBaseline(_ scenario: ReleaseScenario) {
        lock.lock()
        defer { lock.unlock() }
        baselines += 1
        applicableGateCounts.insert(scenario.gateRecords.filter(\.applicability.isApplicable).count)
        waivedGateCounts.insert(scenario.gateRecords.filter { !$0.applicability.isApplicable }.count)
        selectedGates.insert(scenario.selectedEntry.gate)
        distributedBundles.insert(scenario.builder.distributedBundleIdentifier)
        for claim in scenario.eligible.publishableClaims {
            eligibleSampleCounts.insert(claim.eligibleSampleCount)
        }
    }

    func expectVariedBaselines() {
        lock.lock()
        defer { lock.unlock() }

        #expect(cases >= 100, "the design requires at least 100 generated cases")
        #expect(baselines == cases, "every generated case built a coherent baseline")

        // A constant baseline would show 1 in each of these.
        #expect(seeds.count >= 60, "distinct generated seeds: \(seeds.count)")
        #expect(
            capabilitySets == Set(CapabilitySet.allCases),
            "generated capability sets: \(capabilitySets.map(\.description).sorted())"
        )
        #expect(catalogSizes == [1, 2, 3], "generated catalog sizes: \(catalogSizes.sorted())")
        #expect(claimCounts == [0, 1, 2], "generated claim counts: \(claimCounts.sorted())")
        #expect(coverageRegimes == [false, true], "both claim coverage regimes are generated")

        // Each case builds one stray matrix, so the two things a matrix can answer for the
        // wrong release are only both covered if the selection covered them.
        #expect(
            strayMatrixTargets == [false, true],
            "a stray matrix answered for another allowlist and for another application build"
        )
        #expect(
            eligibleSampleCounts.count >= 10,
            "distinct published sample totals: \(eligibleSampleCounts.count)"
        )
        #expect(
            distributedBundles.count >= 60,
            "distinct distributed bundles: \(distributedBundles.count)"
        )

        // The capability set decides how many entries the missing, unresolved, and failing
        // sweeps visit and how many the waiver arm visits, so all three arrangements have to
        // occur or one of those arms never runs.
        #expect(
            applicableGateCounts == [
                ReleaseGate.unconditionalGates.count,
                ReleaseGate.unconditionalGates.count + 1,
                ReleaseGate.allCases.count,
            ],
            "generated applicable gate counts: \(applicableGateCounts.sorted())"
        )
        #expect(
            waivedGateCounts == [0, 1, 2],
            "generated waived gate counts: \(waivedGateCounts.sorted())"
        )

        // The single-target arms pick one gate per case, so the version, digest, and
        // substituted-citation forms only reach the vocabulary if the selection did.
        #expect(
            selectedGates.count >= 20,
            "gates targeted by the single-gate arms: \(selectedGates.count)"
        )
    }
}
