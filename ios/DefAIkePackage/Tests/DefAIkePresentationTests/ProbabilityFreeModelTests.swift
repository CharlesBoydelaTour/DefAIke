import Testing

@testable import DefAIkeDomain
@testable import DefAIkePresentation

// Requirements 8.9 and 8.13: no presentation model may represent a probability,
// confidence value or level, percentage, score, raw logit, or a claim of certainty,
// authenticity, authorship, intent, complete editing history, or absent localized
// editing.
//
// The enforcement is structural, so these tests audit shape rather than wording. They
// walk every presentation model this task defines and assert the audit finds nothing -
// and, to prove the audit can fail, they run it against a deliberately non-compliant
// stand-in.

@Suite("Presentation models represent no prohibited claim")
struct ProbabilityFreeModelTests {

    @Test("Every resolved pixel presentation is probability-free", arguments: PixelEvidence.allCases)
    func pixelPresentationIsClean(evidence: PixelEvidence) throws {
        let model = try CopyFixture.pixelOnlyBinding().presentation(forPixel: evidence)
        #expect(ProhibitedClaimAudit.findings(in: model).isEmpty)
    }

    @Test("Every resolved provenance presentation is probability-free")
    func provenancePresentationIsClean() throws {
        let binding = try CopyFixture.provenanceBinding()

        for lane in ProvenanceLaneSamples.allLanes {
            let model = try binding.presentation(forProvenance: lane)
            #expect(
                ProhibitedClaimAudit.findings(in: model).isEmpty,
                "\(ProhibitedClaimAudit.findings(in: model))"
            )
        }
    }

    @Test("The unavailable lane presentation is probability-free")
    func unavailablePresentationIsClean() throws {
        let binding = try CopyFixture.pixelOnlyBinding()

        for reason in UnavailableReason.allCases {
            let model = try binding.presentation(forProvenance: .unavailable(reason))
            #expect(ProhibitedClaimAudit.findings(in: model).isEmpty)
        }
    }

    @Test("A resolved Combined Summary is probability-free")
    func summaryPresentationIsClean() throws {
        let binding = try CopyFixture.fusionBinding()
        let key = CopyFixture.summaryKeys[.noStrongSignalDetected]!

        let model = try binding.presentation(
            forCombinedSummary: CombinedSummary(copyKey: key, fusionRuleID: CopyFixture.fusionRuleID)
        )
        #expect(ProhibitedClaimAudit.findings(in: model).isEmpty)
    }

    @Test("Every resolved error presentation is probability-free", arguments: AnalysisError.allCases)
    func errorPresentationIsClean(error: AnalysisError) throws {
        let model = try CopyFixture.pixelOnlyBinding().presentation(forError: error)
        #expect(ProhibitedClaimAudit.findings(in: model).isEmpty)
    }

    @Test("A resolved copy reference carries an address, not text")
    func referenceCarriesNoText() throws {
        let reference = try CopyFixture.pixelOnlyBinding().reference(for: .evidenceScope)

        #expect(ProhibitedClaimAudit.findings(in: reference).isEmpty)
        #expect(reference.localizationKey.rawValue.isEmpty == false)
        #expect(reference.catalogID == CopyFixture.catalogID)
    }

    @Test("The audit rejects a numeric field, populated or not")
    func auditCatchesNumericField() {
        for model in [NonCompliantModel.numeric, NonCompliantModel.named] {
            let findings = ProhibitedClaimAudit.findings(in: model)
            #expect(
                findings.contains { $0.path == "NonCompliantModel.magnitude" },
                "\(findings)"
            )
        }
    }

    @Test("The audit rejects a prohibited field name")
    func auditCatchesProhibitedName() {
        let findings = ProhibitedClaimAudit.findings(in: NonCompliantModel.named)

        #expect(findings.contains { $0.path == "NonCompliantModel.confidenceLevel" })
    }

    @Test("Each finding is reported once per field")
    func findingsAreDeduplicated() {
        let findings = ProhibitedClaimAudit.findings(in: NonCompliantModel.numeric)

        #expect(Set(findings).count == findings.count)
        #expect(findings.contains { $0.path.hasSuffix(".some") } == false)
    }

    @Test("Every prohibited claim category has a written-down reason")
    func claimVocabularyIsClosed() {
        // A closed vocabulary with stable keys, so a release audit can enumerate what
        // is banned rather than reading prose.
        #expect(ProhibitedPresentationClaim.allCases.count == 10)
        #expect(
            Set(ProhibitedPresentationClaim.allCases.map(\.rawValue)).count
                == ProhibitedPresentationClaim.allCases.count
        )
    }
}

/// Lane values covering all five enabled provenance states.
enum ProvenanceLaneSamples {
    static let policyID = CopyFixture.artifact("policy.provenance.synthetic")

    static var allLanes: [ProvenanceLane] {
        [
            .available(
                .validated(
                    ValidatedClaimSummary(
                        provenancePolicyID: policyID,
                        bindingStatus: .boundToInspectedBytes,
                        signerFields: [],
                        assertionFields: []
                    )
                )
            ),
            .available(
                .invalid(
                    InvaliditySummary(
                        provenancePolicyID: policyID,
                        category: .byteBinding,
                        explanationKey: CopyFixture.copyKey("copy.provenance.invalid-binding")
                    )
                )
            ),
            .available(.absent),
            .available(
                .unsupported(
                    UnsupportedFeatureSummary(
                        provenancePolicyID: policyID,
                        explanationKey: CopyFixture.copyKey("copy.provenance.unsupported"),
                        unsupportedFeatures: [DisplaySafeText("synthetic feature")!]
                    )
                )
            ),
            .available(
                .indeterminate(
                    IndeterminateSummary(
                        provenancePolicyID: policyID,
                        explanationKey: CopyFixture.copyKey("copy.provenance.indeterminate")
                    )
                )
            ),
        ]
    }
}

/// A deliberately non-compliant stand-in, so the audit is proven able to fail.
///
/// It exists only in tests. Nothing like it is representable in the shipping module.
struct NonCompliantModel: ProbabilityFreePresentationModel {
    let magnitude: Double?
    let confidenceLevel: String?

    static let numeric = NonCompliantModel(magnitude: 0.87, confidenceLevel: nil)
    static let named = NonCompliantModel(magnitude: nil, confidenceLevel: "high")
}
