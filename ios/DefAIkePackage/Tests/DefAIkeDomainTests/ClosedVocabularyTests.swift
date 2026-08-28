import Foundation
import Testing

@testable import DefAIkeDomain

// The closed-vocabulary matrix for the whole domain.
//
// Every vocabulary in this module is closed on purpose: a pixel label, a provenance
// state, an error category, a cleanup reason, a gate name, and a metric name are all
// decided sets, and "some other value" is not a member of any of them. Three
// properties make that claim executable rather than aspirational:
//
//   * Every member survives a JSON round trip with its exact raw value, so an
//     artifact's wire spelling cannot drift from the value a build reads.
//   * A raw value this build does not implement is refused, never approximated to a
//     neighbouring member and never defaulted. That is the "unknown required
//     semantics" rule at the level of a single field.
//   * The registry below covers every closed vocabulary the domain declares. A
//     source audit enforces that, so adding an enum without registering it fails
//     here instead of quietly leaving a vocabulary untested.
//
// Requirements 5.2, 6.9, 8.2, and 11.17 fix the membership of four of these
// vocabularies exactly. Those four get their own named tests below, because a count
// and a spelling are the requirement, not an implementation detail.

// MARK: - Vocabulary descriptor

/// One closed, string-keyed, `Codable` vocabulary, prepared for the matrix tests.
///
/// The descriptor is built from the type itself rather than from hand-written
/// literals, so a registry row cannot disagree with the enum it stands for.
struct ClosedVocabulary: Sendable, CustomTestStringConvertible {
    /// The type name as written in the domain, without the module prefix.
    let name: String

    /// Every member's raw value, in `allCases` order.
    let rawValues: [String]

    /// Encodes every member and decodes the payload back, returning the decoded raw
    /// values in `allCases` order.
    let roundTrip: @Sendable () throws -> [String]

    /// Whether decoding a payload naming `member` was refused.
    let refuses: @Sendable (String) -> Bool

    var testDescription: String { name }

    /// Describes a closed vocabulary that a release artifact can carry.
    static func closed<Vocabulary>(_ type: Vocabulary.Type) -> ClosedVocabulary
    where
        Vocabulary: RawRepresentable & CaseIterable & Codable & Sendable,
        Vocabulary.RawValue == String
    {
        ClosedVocabulary(
            name: simpleName(of: type),
            rawValues: Vocabulary.allCases.map(\.rawValue),
            roundTrip: {
                let payload = try JSONEncoder().encode(Array(Vocabulary.allCases))
                let decoded = try JSONDecoder().decode([Vocabulary].self, from: payload)
                return decoded.map(\.rawValue)
            },
            refuses: { member in
                guard let payload = try? JSONSerialization.data(withJSONObject: [member]) else {
                    return false
                }
                return (try? JSONDecoder().decode([Vocabulary].self, from: payload)) == nil
            }
        )
    }

    /// `DefAIkeDomain.ArtifactDigestRecord.Kind` becomes `ArtifactDigestRecord.Kind`.
    private static func simpleName(of type: Any.Type) -> String {
        let qualified = String(reflecting: type)
        let prefix = "DefAIkeDomain."
        guard qualified.hasPrefix(prefix) else { return qualified }
        return String(qualified.dropFirst(prefix.count))
    }
}

/// Every closed string vocabulary the domain declares.
///
/// ``ArtifactStructuralBound`` is deliberately absent: it is the one closed string
/// vocabulary that is not `Codable`, because it labels a structural ceiling inside a
/// decode fault and is never read out of an artifact. It is checked separately.
enum DomainVocabularies {
    /// The one vocabulary that is closed but never decoded.
    static let nonCodableNames = ["ArtifactStructuralBound"]

    static let all: [ClosedVocabulary] = core + ports + releaseArtifacts

    /// Core session values (`Sources/DefAIkeDomain/Core`).
    static let core: [ClosedVocabulary] = [
        .closed(AnalysisError.self),
        .closed(ProgressUnit.self),
        .closed(ModelBundleIntegrityStatus.self),
        .closed(AnalysisStage.self),
        .closed(ArtifactDigestRecord.Kind.self),
        .closed(AnalysisScopeStatement.self),
        .closed(InputRoute.self),
        .closed(BytePreservationStatus.self),
        .closed(PreservationBasis.self),
        .closed(PixelEvidence.self),
        .closed(ProvenanceCategory.self),
        .closed(UnavailableReason.self),
        .closed(ClaimBindingStatus.self),
        .closed(InvalidityCategory.self),
        .closed(SessionEndReason.self),
    ]

    /// Application ports (`Sources/DefAIkeDomain/Ports`).
    static let ports: [ClosedVocabulary] = [
        .closed(TransferSlotState.self)
    ]

    /// Policy and release-artifact schemas (`Sources/DefAIkeDomain/ReleaseArtifacts`).
    static let releaseArtifacts: [ClosedVocabulary] = [
        .closed(AccessibilityWorkflow.self),
        .closed(AssistiveCondition.self),
        .closed(LocalizationTestVariant.self),
        .closed(GateOutcome.self),
        .closed(ApprovalDecision.self),
        .closed(SignatureAlgorithm.self),
        .closed(SigningKeyStatus.self),
        .closed(KeyRevocationBehavior.self),
        .closed(KeyRotationBehavior.self),
        .closed(ConfidenceIntervalMethod.self),
        .closed(BudgetPassStatistic.self),
        .closed(QualityRuleOutcome.self),
        .closed(UncoveredQualityInputBehavior.self),
        .closed(UpstreamBoundaryRole.self),
        .closed(CalibrationPopulation.self),
        .closed(SessionCleanupReason.self),
        .closed(FileProtectionLevel.self),
        .closed(PendingHandoffPolicy.self),
        .closed(DeviceGate.self),
        .closed(ComparisonMetric.self),
        .closed(ToleranceKind.self),
        .closed(ProcessWarmth.self),
        .closed(EvidenceBranchExecution.self),
        .closed(StartingPowerCondition.self),
        .closed(SummaryStatistic.self),
        .closed(MissingResultRule.self),
        .closed(PixelLabelKey.self),
        .closed(PixelMetricCategory.self),
        .closed(ProvenanceStateKey.self),
        .closed(BytePreservationStatusKey.self),
        .closed(AnalysisErrorKey.self),
        .closed(ExecutionTarget.self),
        .closed(ExecutionEnvironment.self),
        .closed(ModelProgramKind.self),
        .closed(ModelComputePrecision.self),
        .closed(StaticContainer.self),
        .closed(ImageMetadataState.self),
        .closed(OrientationAction.self),
        .closed(ColorProfileAction.self),
        .closed(ResizeInterpolation.self),
        .closed(RoundingRule.self),
        .closed(SampleEdgeRule.self),
        .closed(PixelCenterConvention.self),
        .closed(CropOffsetRule.self),
        .closed(ModelChannelOrder.self),
        .closed(ModelElementType.self),
        .closed(ProvenanceDisplayField.self),
        .closed(FixtureFamily.self),
        .closed(InheritedRedTeamStatus.self),
        .closed(ReleaseGate.self),
        .closed(ResourceMetric.self),
        .closed(ResourceLimitUnit.self),
        .closed(ThermalState.self),
    ]
}

// MARK: - Matrix

@Suite("Closed vocabulary matrix")
struct ClosedVocabularyTests {

    @Test("Every member round trips with its exact raw value",
          arguments: DomainVocabularies.all)
    func memberRoundTrip(vocabulary: ClosedVocabulary) throws {
        #expect(try vocabulary.roundTrip() == vocabulary.rawValues)
    }

    @Test("Raw values are unique and canonically spelled", arguments: DomainVocabularies.all)
    func rawValueSpelling(vocabulary: ClosedVocabulary) {
        #expect(!vocabulary.rawValues.isEmpty, "\(vocabulary.name) declares no member")
        #expect(
            Set(vocabulary.rawValues).count == vocabulary.rawValues.count,
            "\(vocabulary.name) spells two members the same way"
        )
        for raw in vocabulary.rawValues {
            #expect(
                Self.isCanonicalMemberSpelling(raw),
                "\(vocabulary.name) member '\(raw)' is neither lowerCamelCase nor kebab-case"
            )
        }
    }

    @Test("An unimplemented member is refused, not approximated",
          arguments: DomainVocabularies.all)
    func unknownMemberRefused(vocabulary: ClosedVocabulary) throws {
        let known = try #require(vocabulary.rawValues.first)
        // A payload can carry an invented member, a differently cased spelling of a
        // real one, an empty value, or a padded one. None of them names a semantic
        // this build implements, so each has to be refused rather than resolved to
        // the nearest member or replaced by a default.
        for unknown in [
            "definitely-not-a-member",
            known.uppercased(),
            known + "-extended",
            " \(known)",
            "",
        ] where unknown != known {
            #expect(
                vocabulary.refuses(unknown),
                "\(vocabulary.name) accepted the unimplemented member '\(unknown)'"
            )
        }
    }

    @Test("A known member is still accepted, so refusal is not blanket")
    func knownMemberAccepted() throws {
        // The negative control for the sweep above: the refusal predicate has to be
        // discriminating, or every row would pass for the wrong reason.
        for vocabulary in DomainVocabularies.all {
            let known = try #require(vocabulary.rawValues.first)
            #expect(
                !vocabulary.refuses(known),
                "\(vocabulary.name) refused its own member '\(known)'"
            )
        }
    }

    @Test("The one non-decoded vocabulary is still closed and unambiguous")
    func structuralBoundVocabulary() {
        // `ArtifactStructuralBound` labels a ceiling in a decode fault, so its raw
        // values are human-readable phrases rather than artifact keys. It is still a
        // closed set with distinct members.
        let raws = ArtifactStructuralBound.allCases.map(\.rawValue)
        #expect(raws.count == 4)
        #expect(Set(raws).count == raws.count)
        #expect(raws.allSatisfy { !$0.isEmpty })
        #expect(ArtifactStructuralBound.stringScalars.description == "string unicode scalars")
    }

    /// Whether `raw` is lowerCamelCase or kebab-case ASCII.
    ///
    /// Both spellings exist in the domain: a member whose meaning needs no wire
    /// spelling keeps its implicit Swift name, and a member that appears in signed
    /// JSON declares an explicit kebab-case value. Anything else — whitespace, an
    /// underscore, a leading capital — would be a third convention.
    private static func isCanonicalMemberSpelling(_ raw: String) -> Bool {
        guard !raw.isEmpty, raw.allSatisfy(\.isASCII) else { return false }
        let camel = /[a-z][a-zA-Z0-9]*/
        let kebab = /[a-z0-9]+(-[a-z0-9]+)*/
        return raw.wholeMatch(of: camel) != nil || raw.wholeMatch(of: kebab) != nil
    }
}

// MARK: - Registry coverage

@Suite("Closed vocabulary registry coverage")
struct ClosedVocabularyCoverageTests {

    @Test("The registry names every closed string vocabulary in the domain")
    func registryIsComplete() throws {
        let declared = try DomainSources.closedStringVocabularyNames(from: #filePath)
        #expect(!declared.isEmpty, "no vocabulary declarations were found to audit")

        let registered = Set(
            DomainVocabularies.all.map { $0.name.components(separatedBy: ".").last ?? $0.name }
        )
        .union(DomainVocabularies.nonCodableNames)

        // An unregistered vocabulary is an untested one: its members would never be
        // round tripped and an unimplemented member would never be shown to be
        // refused. Register it in `DomainVocabularies` rather than relaxing this.
        let missing = declared.subtracting(registered).sorted()
        let stale = registered.subtracting(declared).sorted()
        #expect(missing.isEmpty, "unregistered closed vocabularies: \(missing)")
        #expect(stale.isEmpty, "registered names that no longer exist: \(stale)")
    }

    @Test("Registry entries are distinct")
    func registryHasNoDuplicates() {
        let names = DomainVocabularies.all.map(\.name)
        #expect(Set(names).count == names.count, "a vocabulary is registered twice")
    }
}

// MARK: - Requirement-fixed vocabularies

@Suite("Requirement-fixed vocabularies")
struct RequirementFixedVocabularyTests {

    @Test("Exactly three pixel labels exist, in both the value and the key vocabulary")
    func threePixelLabels() {
        // Requirement 5.2 fixes the label set at three, and Requirement 8.2 fixes
        // which three. The display strings live in Approved Verdict Copy, so what the
        // domain owns is the membership and the key spelling.
        #expect(PixelEvidence.allCases.count == 3)
        #expect(PixelLabelKey.allCases.count == 3)
        #expect(
            PixelLabelKey.allCases.map(\.rawValue) == [
                "signals-consistent-with-ai-generation",
                "no-strong-signal-detected",
                "not-enough-signal",
            ]
        )
        // The runtime value and the encoded key must name the same three labels, or an
        // artifact could describe a label the evidence lane cannot produce.
        #expect(
            PixelEvidence.allCases.map { String(describing: $0) }
                == PixelLabelKey.allCases.map { String(describing: $0) }
        )
    }

    @Test("Each pixel label keeps its fixed metric category")
    func pixelMetricCategories() {
        // Requirement 5.3. Abstention is its own category rather than an exclusion.
        #expect(PixelMetricCategory.allCases.count == 3)
        #expect(
            PixelLabelKey.allCases.map(\.requiredMetricCategory)
                == [.positive, .nonPositive, .insufficient]
        )
    }

    @Test("Exactly five enabled provenance states exist and none of them is unavailable")
    func fiveProvenanceStates() {
        // Requirement 6.9 fixes the enabled state set at five. The unavailable lane is
        // a separate fact about the installed release (Requirements 6.4 and 6.21), so
        // it is outside both vocabularies and outside the fusion key space.
        #expect(ProvenanceCategory.allCases.count == 5)
        #expect(ProvenanceStateKey.allCases.count == 5)
        #expect(
            ProvenanceCategory.allCases.map(\.rawValue)
                == ProvenanceStateKey.allCases.map(\.rawValue)
        )
        #expect(
            ProvenanceCategory.allCases.map(\.rawValue)
                == ["validated", "invalid", "absent", "unsupported", "indeterminate"]
        )
        #expect(!ProvenanceCategory.allCases.map(\.rawValue).contains("unavailable"))
        #expect(!ProvenanceStateKey.allCases.map(\.rawValue).contains("unavailable"))
        // Three reasons, not two: the application composition links the validator
        // unconditionally, so "no validator was compiled in" stopped covering every
        // unavailable lane and `validatorEnablementUnapproved` names the linked-but-unusable
        // case. All three resolve to the one approved `provenanceUnavailable` copy surface, so
        // adding one was a vocabulary change and not a copy-approval change.
        #expect(UnavailableReason.allCases.count == 3)
    }

    @Test("The two byte-preservation vocabularies name the same three states")
    func bytePreservationVocabulariesAgree() {
        #expect(
            BytePreservationStatus.allCases.map { String(describing: $0) }
                == BytePreservationStatusKey.allCases.map { String(describing: $0) }
        )
        #expect(
            BytePreservationStatusKey.allCases.map(\.rawValue)
                == ["original-bytes", "platform-transformed-copy", "unknown"]
        )
    }

    @Test("Every terminal end reason has a cleanup reason to select")
    func endReasonsAndCleanupReasonsAgree() {
        // The mapping itself belongs to the lifecycle task. What matters here is that
        // the two closed sets stay the same size and shape, so cleanup can never be
        // asked to run for a reason no terminal outcome produces, or a session end up
        // with no deadline. The one deliberate spelling difference is `error` against
        // `error-terminated`.
        #expect(SessionEndReason.allCases.count == SessionCleanupReason.allCases.count)
        let endNames = Set(SessionEndReason.allCases.map { String(describing: $0) })
        let cleanupNames = Set(SessionCleanupReason.allCases.map { String(describing: $0) })
        #expect(endNames.subtracting(cleanupNames) == ["error"])
        #expect(cleanupNames.subtracting(endNames) == ["errorTerminated"])
    }

    @Test("Error, label, provenance, and unavailable vocabularies share no spelling")
    func categoriesAreDistinguishable() {
        // Requirement 11.17: an Analysis Error category has to be distinguishable from
        // every pixel label, every provenance state, the unavailable state, the
        // Combined Summary, and the cancelled terminal state. A shared raw value would
        // make two of those indistinguishable in an artifact or a copy key.
        let runtime =
            AnalysisError.allCases.map(\.rawValue)
            + PixelEvidence.allCases.map(\.rawValue)
            + ProvenanceCategory.allCases.map(\.rawValue)
            + UnavailableReason.allCases.map(\.rawValue)
        #expect(Set(runtime).count == runtime.count)

        let encoded =
            AnalysisErrorKey.allCases.map(\.rawValue)
            + PixelLabelKey.allCases.map(\.rawValue)
            + ProvenanceStateKey.allCases.map(\.rawValue)
        #expect(Set(encoded).count == encoded.count)

        // The cancelled terminal state and a Combined Summary are separate shapes
        // rather than members of any of these vocabularies, so nothing can name them
        // as an error category.
        #expect(!runtime.contains("cancelled"))
        #expect(!runtime.contains(where: { $0.contains("summary") }))
        #expect(!encoded.contains("cancelled"))
    }
}
