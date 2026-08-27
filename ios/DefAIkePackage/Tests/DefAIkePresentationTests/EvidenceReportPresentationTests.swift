import Foundation
import Testing

@testable import DefAIkeDomain
@testable import DefAIkePresentation

// The result surface: two cards every time, required transparency that cannot be dropped,
// fusion that never overrides a lane, and seven affordances that do not exist.
//
// These are example tests over the assembly's own behavior. They check the claims the
// assembly is responsible for:
//
//   1. both evidence cards are present for every lane state, including unavailable, and
//      neither can reach or rank the other (Requirements 7.2, 7.3, 7.8);
//   2. the Combined Summary is optional, approved-only, and a sibling of both cards
//      (Requirements 7.9 through 7.13, 7.17);
//   3. every required limitation and transparency field is present for every report
//      (Requirements 6.15, 8.10, 8.11, 8.12, 10.18);
//   4. the four required explanations come from approved keys and from nowhere else
//      (Requirements 6.5, 6.16, 6.17, 6.21); and
//   5. no forbidden affordance has a member to hang from (Requirements 8.13, 8.15, 9.14,
//      9.15).
//
// The exhaustive property over generated reports and catalogues is separate work. What is
// here is the assembly behavior, the totality of the enumerations, and the audits.

// MARK: - Both cards, always

@Suite("Both evidence cards are present for every lane state")
struct EvidenceCardPairTests {

    @Test("Every lane state yields both cards", arguments: ReportFixture.allLanes)
    func bothCardsForEveryLane(lane: ProvenanceLane) throws {
        let presentation = try ReportFixture.provenancePresentation(lane: lane)

        #expect(presentation.cards.pixel.evidence == .signalsConsistentWithAIGeneration)
        #expect(presentation.cards.provenance.lane.state == expectedState(for: lane))
    }

    @Test(
        "Every pixel label yields both cards in a pixel-only release",
        arguments: PixelEvidence.allCases
    )
    func bothCardsForEveryPixelLabel(pixel: PixelEvidence) throws {
        let presentation = try ReportFixture.pixelOnlyPresentation(pixel: pixel)

        #expect(presentation.cards.pixel.evidence == pixel)
        #expect(presentation.cards.pixel.fixedLabelText == FixedPixelLabelText(evidence: pixel))
        // The unavailable lane is a card, not a hidden one.
        #expect(presentation.cards.provenance.distinction == .releaseCannotValidate)
    }

    @Test("The pair has exactly two members and no collection to be empty")
    func pairShapeIsTwoCards() throws {
        let pair = try ReportFixture.pixelOnlyPresentation().cards
        let children = Mirror(reflecting: pair).children

        #expect(children.map { $0.label } == ["pixel", "provenance"])
        #expect(children.count == 2)

        // No array, set, dictionary, or optional. Those are the shapes that could hold one
        // card, no cards, or a ranked order.
        for child in children {
            let displayStyle = Mirror(reflecting: child.value).displayStyle
            #expect(displayStyle == .struct, "\(child.label ?? "?") is \(String(describing: displayStyle))")
        }
    }

    @Test("Neither card can hold the other lane's value")
    func cardsCannotCrossLanes() throws {
        let pair = try ReportFixture.provenancePresentation(lane: .available(.absent)).cards

        let pixelFieldTypes = Mirror(reflecting: pair.pixel).children.map {
            String(describing: type(of: $0.value))
        }
        let provenanceFieldTypes = Mirror(reflecting: pair.provenance).children.map {
            String(describing: type(of: $0.value))
        }

        #expect(pixelFieldTypes.contains { $0.contains("Provenance") } == false)
        #expect(provenanceFieldTypes.contains { $0.contains("Pixel") } == false)
    }

    @Test("No card or pair carries a rank, order, or priority")
    func cardsCarryNoRanking() throws {
        // Requirement 7.8 forbids ranking either lane. There is no field for one, so this
        // asserts the absence by name over the whole assembled value graph.
        let presentation = try ReportFixture.fusedPresentation()
        let names = FieldNames.collect(from: presentation)

        #expect(!names.isEmpty, "the reflection walk must find fields for this to mean anything")
        for forbidden in ["rank", "priority", "weight", "primary", "secondary", "strength", "order"] {
            #expect(
                names.contains { $0.contains(forbidden) } == false,
                "a field name contains '\(forbidden)': \(names.filter { $0.contains(forbidden) })"
            )
        }
    }

    /// The presentation state a lane projects to, so a card assertion names the lane rather
    /// than restating the projection.
    private func expectedState(for lane: ProvenanceLane) -> ProvenanceLanePresentationState {
        switch lane {
        case let .unavailable(reason): .unavailable(reason)
        case let .available(evidence): .available(evidence.category)
        }
    }
}

// MARK: - Fusion

@Suite("The Combined Summary is optional and never overrides a lane")
struct CombinedSummarySectionTests {

    @Test("An unavailable provenance lane omits fusion and records why")
    func unavailableLaneOmitsFusion() throws {
        let presentation = try ReportFixture.pixelOnlyPresentation()

        #expect(presentation.combinedSummary == .omitted(.provenanceLaneUnavailable))
        #expect(presentation.combinedSummary.summary == nil)
        #expect(presentation.combinedSummary.fusionRuleID == nil)
    }

    @Test(
        "Available lanes with no approved summary omit fusion and record why",
        arguments: ProvenanceCategory.allCases
    )
    func availableLaneWithoutRuleOmitsFusion(category: ProvenanceCategory) throws {
        let presentation = try ReportFixture.provenancePresentation(
            lane: ReportFixture.availableLane(category)
        )

        #expect(presentation.combinedSummary == .omitted(.noApprovedSummaryForThisCombination))
    }

    @Test("A shown summary names the rule version that produced it")
    func shownSummaryNamesItsRule() throws {
        let presentation = try ReportFixture.fusedPresentation()

        let summary = try #require(presentation.combinedSummary.summary)
        #expect(summary.fusionRuleID == CopyFixture.fusionRuleID)
        #expect(presentation.combinedSummary.fusionRuleID == CopyFixture.fusionRuleID)

        // The surface is addressed by the key the fusion rule produced; the localization
        // key is what the catalogue approved for that surface. The two are deliberately
        // distinct, which is how an unapproved summary key fails closed.
        let ruleKey = try #require(CopyFixture.summaryKeys[.signalsConsistentWithAIGeneration])
        #expect(summary.summaryCopy.surface == .combinedSummary(ruleKey))
        #expect(summary.summaryCopy.localizationKey != ruleKey)
    }

    @Test("A shown summary leaves both cards and every limitation in place")
    func shownSummaryDoesNotSuppressALane() throws {
        let fused = try ReportFixture.fusedPresentation()

        // Requirement 7.13: both immutable source-lane fields are retained alongside the
        // summary. Requirement 7.17: the limitations of both lanes survive.
        #expect(fused.cards.pixel.evidence == .signalsConsistentWithAIGeneration)
        #expect(fused.cards.provenance.lane.state == .available(.absent))
        #expect(fused.limitations.statesEveryRequiredScope)
        #expect(fused.combinedSummary.summary != nil)
    }

    @Test("The summary section holds no lane value and no override")
    func summarySectionHoldsOnlyTheSummary() throws {
        let summary = try #require(try ReportFixture.fusedPresentation().combinedSummary.summary)
        let labels = Mirror(reflecting: summary).children.map { $0.label }

        #expect(labels == ["summaryCopy", "fusionRuleID"])
    }

    @Test("Every omission reason is written down and enumerable")
    func omissionReasonsAreClosed() {
        #expect(FusionOmissionReason.allCases.count == 2)
        #expect(
            Set(FusionOmissionReason.allCases.map(\.rawValue)).count
                == FusionOmissionReason.allCases.count
        )
    }
}

// MARK: - Apparent inconsistency

@Suite("An apparent inconsistency stays visible beside both cards")
struct ApparentInconsistencyTests {

    @Test("A declared notice is carried, from the report's own approved key")
    func declaredNoticeIsCarried() throws {
        let presentation = try ReportFixture.provenancePresentation(
            lane: ReportFixture.availableLane(.validated),
            inconsistent: true
        )

        let reference = try #require(presentation.apparentInconsistency.reference)
        #expect(reference.surface == VerdictCopySurface.apparentInconsistency)
        #expect(
            reference.localizationKey
                == CopyFixture.localizationKey(for: .apparentInconsistency)
        )
        // Both lanes survive the notice (Requirement 7.8).
        #expect(
            presentation.cards.provenance.lane.state
                == ProvenanceLanePresentationState.available(.validated)
        )
        #expect(presentation.cards.pixel.evidence == .signalsConsistentWithAIGeneration)
    }

    @Test("A report that declared no notice says so rather than leaving it unanswered")
    func undeclaredNoticeIsAnswered() throws {
        let presentation = try ReportFixture.provenancePresentation(lane: .available(.absent))

        #expect(presentation.apparentInconsistency == .none)
        #expect(presentation.apparentInconsistency.reference == nil)
    }

    @Test("The notice lives beside the cards, not inside one")
    func noticeIsNotACardMember() throws {
        let presentation = try ReportFixture.provenancePresentation(
            lane: ReportFixture.availableLane(.validated),
            inconsistent: true
        )

        let pairNames = FieldNames.collect(from: presentation.cards)
        #expect(pairNames.contains("apparentinconsistency") == false)
        #expect(
            Mirror(reflecting: presentation).children.contains {
                $0.label == "apparentInconsistency"
            }
        )
    }
}

// MARK: - Limitations

@Suite("Every report states the fixed scope, false-result, and byte-status limitations")
struct EvidenceLimitationsTests {

    @Test("The scope statement and false-result statement come from approved keys")
    func requiredLimitationSurfaces() throws {
        let limitations = try ReportFixture.pixelOnlyPresentation().limitations

        #expect(limitations.scopeCopy.surface == .evidenceScope)
        #expect(limitations.falseResultCopy.surface == .falseResultLimitation)
    }

    @Test("Every required covered and uncovered scope is stated", arguments: ReportFixture.allLanes)
    func scopeCoverage(lane: ProvenanceLane) throws {
        let limitations = try ReportFixture.provenancePresentation(lane: lane).limitations

        #expect(limitations.statesEveryRequiredScope)
        #expect(limitations.coveredScopes == [.wholeImageSynthesis])
        #expect(
            Set(limitations.uncoveredScopes) == EvidenceScope.requiredExcludedStatements
        )
        // Ordered by the closed vocabulary, so the order is stable under localization.
        #expect(
            limitations.uncoveredScopes
                == AnalysisScopeStatement.allCases.filter(
                    EvidenceScope.requiredExcludedStatements.contains
                )
        )
    }

    @Test(
        "Every byte status carries its approved limitation",
        arguments: BytePreservationStatus.allCases
    )
    func byteStatusLimitation(status: BytePreservationStatus) throws {
        let disclosure = try ReportFixture.pixelOnlyPresentation(
            bytePreservationStatus: status
        ).limitations.bytePreservation

        #expect(disclosure.status == status)
        #expect(
            disclosure.limitationCopy.surface == .bytePreservationLimitation(status.statusKey)
        )
    }

    @Test("The two statuses Requirement 6.15 names are the transformed and unknown ones")
    func transformedAndUnknownAreNamed() throws {
        for status in BytePreservationStatus.allCases {
            let disclosure = try ReportFixture.pixelOnlyPresentation(
                bytePreservationStatus: status
            ).limitations.bytePreservation

            #expect(
                disclosure.isNamedByTransformedOrUnknownRequirement
                    == (status != .originalBytes),
                "\(status)"
            )
            // Named or not, the limitation is attached either way.
            #expect(disclosure.limitationCopy.localizationKey.rawValue.isEmpty == false)
        }
    }

    @Test("No limitation member is optional")
    func limitationsAreNotOptional() throws {
        let limitations = try ReportFixture.pixelOnlyPresentation().limitations

        for child in Mirror(reflecting: limitations).children {
            #expect(
                Mirror(reflecting: child.value).displayStyle != .optional,
                "\(child.label ?? "?") is optional"
            )
        }
    }
}

// MARK: - Technical details

@Suite("Every report exposes the required transparency fields")
struct EvidenceTechnicalDetailsTests {

    @Test("Every bound component version is disclosed")
    func everyComponentIsDisclosed() throws {
        let details = try ReportFixture.pixelOnlyPresentation().technicalDetails
        let disclosures = details.components.disclosures

        #expect(disclosures.map(\.component) == DisclosedComponent.allCases)
        #expect(disclosures.allSatisfy { !$0.identifier.isEmpty })

        let binding = CopyFixture.sessionBinding()
        #expect(details.components.modelBundle == binding.modelBundleID)
        #expect(
            details.components.modelCheckpoint == binding.modelIdentity.checkpointIdentifier
        )
        #expect(details.components.coreMLModel == binding.coreMLModelVersion)
        #expect(details.components.preprocessingContract == binding.preprocessingContractID)
        #expect(details.components.calibrationPolicy == binding.calibrationPolicyID)
        #expect(
            details.components.verdictCopyCompatibility == binding.verdictCopyCompatibilityID
        )
    }

    @Test("The component vocabulary is closed and its identifiers are unique")
    func componentVocabularyIsClosed() {
        #expect(DisclosedComponent.allCases.count == 6)
        #expect(
            Set(DisclosedComponent.allCases.map(\.rawValue)).count
                == DisclosedComponent.allCases.count
        )
    }

    @Test("Every recorded pre-orientation dimension is exposed")
    func recordedDimensions() throws {
        let details = try ReportFixture.provenancePresentation(
            lane: .available(.absent),
            inputQuality: ViewStateFixture.quality(width: 1024, height: 768)
        ).technicalDetails

        #expect(details.dimensions.recorded.map(\.dimension) == PreOrientationDimension.allCases)
        #expect(details.dimensions.pixels(for: .decodedWidth) == 1024)
        #expect(details.dimensions.pixels(for: .decodedHeight) == 768)
        #expect(details.dimensions.pixels(for: .shortEdge) == 768)
        #expect(details.dimensions.unrecorded.isEmpty)
    }

    @Test("An unmeasured record reports absence rather than substituting a value")
    func unmeasuredDimensions() throws {
        let details = try ReportFixture.provenancePresentation(
            lane: .available(.absent),
            inputQuality: .unmeasured
        ).technicalDetails

        #expect(details.dimensions.recorded.isEmpty)
        #expect(details.dimensions.unrecorded == PreOrientationDimension.allCases)
        for dimension in PreOrientationDimension.allCases {
            #expect(details.dimensions.pixels(for: dimension) == nil)
        }
    }

    @Test("The on-device status reflects the recorded fact in both directions")
    func onDeviceStatus() throws {
        let onDevice = try ReportFixture.provenancePresentation(
            lane: .available(.absent),
            onDeviceProcessing: true
        ).technicalDetails
        let notRecorded = try ReportFixture.provenancePresentation(
            lane: .available(.absent),
            onDeviceProcessing: false
        ).technicalDetails

        #expect(onDevice.onDeviceProcessing == .allProcessingOnDevice)
        #expect(notRecorded.onDeviceProcessing == .notRecordedAsFullyOnDevice)
        #expect(OnDeviceProcessingStatus.allCases.count == 2)
    }

    @Test("The integrity status is verified and exposes no digest")
    func integrityDisclosure() throws {
        let integrity = try ReportFixture.pixelOnlyPresentation().technicalDetails.integrity
        let source = CopyFixture.integrity()

        #expect(integrity.status == .verified)
        #expect(ModelBundleIntegrityStatus.allCases == [.verified])
        #expect(integrity.activationReceipt == source.activationReceiptID)
        #expect(integrity.verificationPolicy == source.verificationPolicyID)
        #expect(integrity.verifiedArtifactCount == source.verifiedArtifactDigests.count)
        #expect(integrity.verifiedArtifactCount >= 1)

        // The domain's own note: the Result Presenter surfaces the status without exposing
        // digest internals.
        let types = FieldTypes.collect(from: integrity)
        #expect(!types.isEmpty)
        #expect(types.contains { $0.contains("SHA256Digest") } == false, "\(types)")
        #expect(types.contains { $0.contains("ArtifactDigestRecord") } == false, "\(types)")
    }

    @Test("No transparency member carries a raw model output or a magnitude")
    func noRawOutputOrMagnitude() throws {
        let details = try ReportFixture.fusedPresentation().technicalDetails

        #expect(ProhibitedClaimAudit.findings(in: details).isEmpty)
        let names = FieldNames.collect(from: details)
        #expect(!names.isEmpty)
        #expect(names.contains { $0.contains("logit") } == false)
    }
}

// MARK: - Required explanations

@Suite("The required explanations come from approved keys and nowhere else")
struct RequiredExplanationTests {

    @Test(
        "An unavailable lane carries the approved unavailable explanation",
        arguments: UnavailableReason.allCases
    )
    func unavailableExplanation(reason: UnavailableReason) throws {
        let card = try ReportFixture.provenancePresentation(
            lane: .unavailable(reason)
        ).cards.provenance

        // Requirement 6.5, and Requirement 8.8's "unavailable rather than absent, invalid,
        // or authentic": the state copy addresses the unavailable surface specifically.
        #expect(card.lane.stateCopy.surface == .provenanceUnavailable)
        #expect(card.lane.state == .unavailable(reason))
        #expect(card.distinction == .releaseCannotValidate)
        #expect(card.claimBinding == .notApplicable)
        #expect(card.screenshotExplanation == .notApplicable)
    }

    @Test("A validated claim carries the approved binding statement")
    func validatedBindingStatement() throws {
        let card = try ReportFixture.provenancePresentation(
            lane: ReportFixture.availableLane(.validated)
        ).cards.provenance

        // Requirement 6.17 constrains the wording behind the validated-state surface. The
        // card names the requirement by resolving to that same approved reference.
        #expect(card.claimBinding == .validatedClaimBinding(card.lane.stateCopy))
        #expect(card.lane.stateCopy.surface == .provenanceState(.validated))
    }

    @Test(
        "Only a validated claim carries a binding statement",
        arguments: ProvenanceCategory.allCases.filter { $0 != .validated }
    )
    func nonValidatedStatesCarryNoBindingStatement(category: ProvenanceCategory) throws {
        let card = try ReportFixture.provenancePresentation(
            lane: ReportFixture.availableLane(category)
        ).cards.provenance

        #expect(card.claimBinding == .notApplicable)
    }

    @Test("An absent credential carries the approved screenshot explanation")
    func screenshotExplanation() throws {
        let card = try ReportFixture.provenancePresentation(
            lane: .available(.absent)
        ).cards.provenance

        guard case let .shownForAbsentCredential(reference) = card.screenshotExplanation else {
            Issue.record("an absent credential must carry the approved explanation")
            return
        }
        #expect(reference.surface == .screenshotProvenanceExplanation)
        #expect(
            reference.localizationKey
                == CopyFixture.localizationKey(for: .screenshotProvenanceExplanation)
        )
    }

    @Test(
        "Only an absent credential carries the screenshot explanation",
        arguments: ProvenanceCategory.allCases.filter { $0 != .absent }
    )
    func otherStatesCarryNoScreenshotExplanation(category: ProvenanceCategory) throws {
        let card = try ReportFixture.provenancePresentation(
            lane: ReportFixture.availableLane(category)
        ).cards.provenance

        #expect(card.screenshotExplanation == .notApplicable)
    }

    @Test("Indeterminate is distinguished from unavailable")
    func indeterminateIsDistinctFromUnavailable() throws {
        let indeterminate = try ReportFixture.provenancePresentation(
            lane: ReportFixture.availableLane(.indeterminate)
        ).cards.provenance
        let unavailable = try ReportFixture.provenancePresentation(
            lane: .unavailable(.validatorNotCompiledIntoRelease)
        ).cards.provenance

        // Requirement 6.21: an enabled-validator processing result, not the unavailable
        // state. Different distinction, different lane case, different approved surface.
        #expect(indeterminate.distinction == .enabledValidatorInconclusive)
        #expect(unavailable.distinction == .releaseCannotValidate)
        #expect(indeterminate.distinction != unavailable.distinction)
        #expect(indeterminate.lane.stateCopy.surface == .provenanceState(.indeterminate))
        #expect(unavailable.lane.stateCopy.surface == .provenanceUnavailable)
        #expect(indeterminate.lane.stateCopy.localizationKey != unavailable.lane.stateCopy.localizationKey)
    }

    @Test("Every conclusive enabled state is distinguished from an inconclusive one")
    func conclusiveStatesAreDistinguished() throws {
        for category in ProvenanceCategory.allCases {
            let card = try ReportFixture.provenancePresentation(
                lane: ReportFixture.availableLane(category)
            ).cards.provenance

            #expect(
                card.distinction
                    == (category == .indeterminate
                        ? .enabledValidatorInconclusive
                        : .enabledValidatorResult),
                "\(category)"
            )
            #expect(card.distinction != .releaseCannotValidate, "\(category)")
        }
        #expect(ProvenanceLaneDistinction.allCases.count == 3)
    }

    @Test("Every resolved reference is the key the bound catalogue approved")
    func everyReferenceIsApproved() throws {
        let presentation = try ReportFixture.fusedPresentation()
        let copy = try ViewStateFixture.fusionBinding()

        for reference in CopyReferences.collect(from: presentation) {
            #expect(
                copy.localizationKey(for: reference.surface) == reference.localizationKey,
                "\(reference.surface) resolved to an unapproved key"
            )
        }
        #expect(CopyReferences.collect(from: presentation).isEmpty == false)
    }
}

// MARK: - Disclosure paths

@Suite("Every report offers a path to the required information")
struct ReportDisclosurePathTests {

    @Test("Each path resolves to its approved surface")
    func pathSurfaces() throws {
        let paths = try ReportFixture.pixelOnlyPresentation().disclosurePaths

        #expect(paths.reference(for: .modelInformation).surface == .modelInformation)
        #expect(paths.reference(for: .privacyBehavior).surface == .privacyExplanation)
        #expect(paths.reference(for: .correctionChannel).surface == .correctionChannel)
    }

    @Test("Every required destination is reachable", arguments: RequiredDisclosureDestination.allCases)
    func everyDestinationIsReachable(destination: RequiredDisclosureDestination) throws {
        let paths = try ReportFixture.pixelOnlyPresentation().disclosurePaths
        let reference = paths.reference(reaching: destination)

        #expect(
            [.modelInformation, .privacyExplanation, .correctionChannel]
                .contains(reference.surface)
        )
        #expect(reference.localizationKey.rawValue.isEmpty == false)
    }

    @Test("The six destinations Requirement 8.17 names are all covered by three paths")
    func destinationVocabularyIsComplete() {
        #expect(RequiredDisclosureDestination.allCases.count == 6)
        #expect(ReportDisclosurePath.allCases.count == 3)
        #expect(
            Set(RequiredDisclosureDestination.allCases.map(\.path))
                == Set(ReportDisclosurePath.allCases)
        )
    }

    @Test("Every lane state and pixel label still offers every path")
    func pathsAreUnconditional() throws {
        for lane in ReportFixture.allLanes {
            let paths = try ReportFixture.provenancePresentation(lane: lane).disclosurePaths
            for path in ReportDisclosurePath.allCases {
                #expect(paths.reference(for: path).localizationKey.rawValue.isEmpty == false)
            }
        }
    }
}

// MARK: - Forbidden controls

@Suite("The forbidden controls are absent from the type")
struct ForbiddenControlExclusionTests {

    /// Every model this task adds, boxed so one audit can walk all of them.
    static func everyModel() throws -> [(name: String, findings: [ForbiddenControlAudit.Finding])] {
        let fused = try ReportFixture.fusedPresentation()
        let pixelOnly = try ReportFixture.pixelOnlyPresentation()
        return [
            ("EvidenceReportPresentation.fused", ForbiddenControlAudit.findings(in: fused)),
            ("EvidenceReportPresentation.pixelOnly", ForbiddenControlAudit.findings(in: pixelOnly)),
            ("EvidenceCardPair", ForbiddenControlAudit.findings(in: fused.cards)),
            ("PixelEvidenceCard", ForbiddenControlAudit.findings(in: fused.cards.pixel)),
            ("ProvenanceEvidenceCard", ForbiddenControlAudit.findings(in: fused.cards.provenance)),
            ("EvidenceLimitations", ForbiddenControlAudit.findings(in: fused.limitations)),
            (
                "BytePreservationDisclosure",
                ForbiddenControlAudit.findings(in: fused.limitations.bytePreservation)
            ),
            ("EvidenceTechnicalDetails", ForbiddenControlAudit.findings(in: fused.technicalDetails)),
            (
                "BoundComponentVersions",
                ForbiddenControlAudit.findings(in: fused.technicalDetails.components)
            ),
            (
                "RecordedDimensions",
                ForbiddenControlAudit.findings(in: fused.technicalDetails.dimensions)
            ),
            (
                "BundleIntegrityDisclosure",
                ForbiddenControlAudit.findings(in: fused.technicalDetails.integrity)
            ),
            ("ReportDisclosurePaths", ForbiddenControlAudit.findings(in: fused.disclosurePaths)),
        ]
    }

    @Test("No model this task adds has a member a forbidden control could hang from")
    func noModelCarriesAForbiddenControl() throws {
        let models = try Self.everyModel()

        #expect(models.count == 12)
        for model in models {
            #expect(model.findings.isEmpty, "\(model.name): \(model.findings)")
        }
    }

    @Test("No model this task adds represents a prohibited claim")
    func noModelRepresentsAProhibitedClaim() throws {
        let fused = try ReportFixture.fusedPresentation()

        #expect(ProhibitedClaimAudit.findings(in: fused).isEmpty)
        #expect(ProhibitedClaimAudit.findings(in: fused.cards).isEmpty)
        #expect(ProhibitedClaimAudit.findings(in: fused.cards.pixel).isEmpty)
        #expect(ProhibitedClaimAudit.findings(in: fused.cards.provenance).isEmpty)
        #expect(ProhibitedClaimAudit.findings(in: fused.limitations).isEmpty)
        #expect(ProhibitedClaimAudit.findings(in: fused.technicalDetails).isEmpty)
        #expect(ProhibitedClaimAudit.findings(in: fused.disclosurePaths).isEmpty)
    }

    @Test("Every pixel label and lane state passes both audits")
    func everyStatePassesBothAudits() throws {
        for pixel in PixelEvidence.allCases {
            for lane in ReportFixture.allLanes {
                let presentation = try ReportFixture.provenancePresentation(
                    pixel: pixel,
                    lane: lane
                )
                #expect(ForbiddenControlAudit.findings(in: presentation).isEmpty)
                #expect(ProhibitedClaimAudit.findings(in: presentation).isEmpty)
            }
        }
    }

    @Test("The forbidden-control audit rejects each affordance it is meant to catch")
    func auditCatchesEachAffordance() {
        // Proves the audit can fail. Nothing shaped like this is representable in the
        // shipping module.
        let findings = ForbiddenControlAudit.findings(in: NonCompliantResultSurface.populated)
        let caught = Set(findings.map(\.control))

        #expect(caught.contains(.analysisHistory), "\(findings)")
        #expect(caught.contains(.saveResult), "\(findings)")
        #expect(caught.contains(.exportResult), "\(findings)")
        #expect(caught.contains(.copyResult), "\(findings)")
        #expect(caught.contains(.shareResult), "\(findings)")
    }

    @Test("The audit matches regardless of separator style")
    func auditNormalizesNames() {
        #expect(ForbiddenControlAudit.normalized("shareResult") == "shareresult")
        #expect(ForbiddenControlAudit.normalized("share_result") == "shareresult")
        #expect(ForbiddenControlAudit.normalized("Share Result") == "shareresult")
    }

    @Test("The audit does not flag an approved-copy field name")
    func auditToleratesApprovedCopyFields() throws {
        // The reason the fragment list contains no bare 'copy' and no bare 'share'.
        // Approved copy is addressed by reference throughout this module, and the Share
        // Extension is a legitimate ingest route.
        let names = FieldNames.collect(from: try ReportFixture.fusedPresentation())

        #expect(names.contains { $0.hasSuffix("copy") }, "\(names.sorted())")
        #expect(ForbiddenControlAudit.findings(in: try ReportFixture.fusedPresentation()).isEmpty)
    }

    @Test("The excluded-control vocabulary is closed and declared on the presentation")
    func excludedVocabularyIsClosed() {
        #expect(ExcludedResultControl.allCases.count == 7)
        #expect(
            Set(ExcludedResultControl.allCases.map(\.rawValue)).count
                == ExcludedResultControl.allCases.count
        )
        #expect(EvidenceReportPresentation.excludedControls == Set(ExcludedResultControl.allCases))
        for control in ExcludedResultControl.allCases {
            #expect(control.forbiddenBy.isEmpty == false)
        }
    }

    @Test("The module's sources mention no pasteboard, share sheet, exporter, or store")
    func moduleSourcesMentionNoForbiddenEntryPoint() throws {
        let sources = try #require(
            ForbiddenControlSourceAudit.moduleSources(),
            "the module's sources must be readable for this to mean anything"
        )
        #expect(sources.count > 1, "the recursive sweep found \(sources.count) file(s)")

        let findings = try ForbiddenControlSourceAudit.findings(in: sources)
        #expect(findings.isEmpty, "\(findings)")
    }

    @Test("The source sweep reads code rather than documentation")
    func sourceSweepStripsComments() {
        let source = """
            // This module renders no UIPasteboard affordance.
            let value = 1  // and no ShareLink either
            """
        let stripped = ForbiddenControlSourceAudit.strippingComments(source)

        #expect(stripped.contains("UIPasteboard") == false)
        #expect(stripped.contains("ShareLink") == false)
        #expect(stripped.contains("let value = 1"))
    }
}

// MARK: - Ephemeral exposure

@Suite("A result presentation has no serialized form")
struct ResultPresentationIsEphemeralTests {

    @Test("No model this task adds is codable")
    func noModelIsCodable() throws {
        // Requirement 9.14 exposes Evidence Report data only during the active session, and
        // the domain report is deliberately not serializable. A presentation that could be
        // encoded would be the thing a history, save, or export affordance reads.
        let fused = try ReportFixture.fusedPresentation()
        let values: [(String, Any)] = [
            ("EvidenceReportPresentation", fused),
            ("EvidenceCardPair", fused.cards),
            ("PixelEvidenceCard", fused.cards.pixel),
            ("ProvenanceEvidenceCard", fused.cards.provenance),
            ("EvidenceLimitations", fused.limitations),
            ("EvidenceTechnicalDetails", fused.technicalDetails),
            ("ReportDisclosurePaths", fused.disclosurePaths),
            ("CombinedSummarySection", fused.combinedSummary),
            ("ApparentInconsistencyNotice", fused.apparentInconsistency),
        ]

        #expect(values.count == 9)
        for (name, value) in values {
            #expect((value is any Encodable) == false, "\(name) is Encodable")
            #expect((value is any Decodable) == false, "\(name) is Decodable")
        }
    }
}

// MARK: - Gaps

@Suite("Missing approved copy is enumerated, never invented")
struct ReportCopyGapTests {

    @Test("Every enumerated gap names the requirement it gates")
    func gapsNameTheirRequirement() {
        #expect(UnapprovedReportSurface.allCases.count == 10)
        #expect(
            Set(UnapprovedReportSurface.allCases.map(\.rawValue)).count
                == UnapprovedReportSurface.allCases.count
        )
        for gap in UnapprovedReportSurface.allCases {
            #expect(gap.gates.isEmpty == false, "\(gap)")
        }
        #expect(
            EvidenceReportPresentation.unapprovedSurfaces == Set(UnapprovedReportSurface.allCases)
        )
    }

    @Test("No enumerated gap is actually a surface the approved vocabulary defines")
    func gapsAreGenuinelyMissing() throws {
        // The point of enumerating a gap is that no approved wording exists for it. If one
        // of these matched a real surface, the honest fix would be to resolve it instead.
        let reachable = Set(
            try ViewStateFixture.fusionBinding().reachableSurfaces.surfaces.map(\.description)
        )

        #expect(reachable.isEmpty == false)
        for gap in UnapprovedReportSurface.allCases {
            #expect(reachable.contains(gap.rawValue) == false, "\(gap.rawValue) is a real surface")
        }
    }

    @Test("The missing screenshot-origin input is recorded rather than assumed")
    func missingInputIsRecorded() {
        #expect(UnavailableEvidenceInput.allCases == [.screenshotOriginDetermination])
        #expect(UnavailableEvidenceInput.screenshotOriginDetermination.narrows == "6.16")
    }

    @Test("Every surface the assembly resolves is required of every release")
    func resolvedSurfacesAreUnconditional() {
        // Why the assembly's copy-error path is defensive rather than reachable: every
        // surface it resolves beyond the two lanes is in the unconditional set, so a
        // successfully bound catalogue already covers all of them.
        let named: Set<VerdictCopySurface> = [
            .evidenceScope,
            .falseResultLimitation,
            .screenshotProvenanceExplanation,
            .modelInformation,
            .privacyExplanation,
            .correctionChannel,
            .apparentInconsistency,
        ]
        let required = named.union(
            BytePreservationStatusKey.allCases.map(VerdictCopySurface.bytePreservationLimitation)
        )

        #expect(required.isSubset(of: VerdictCopySurface.unconditionalSurfaces))
    }
}

// MARK: - Assembly refusal

@Suite("Assembly refuses records that must agree and do not")
struct ReportAssemblyRefusalTests {

    @Test("A binding for another session is refused")
    func mismatchedBindingIsRefused() throws {
        let screen = try ReportFixture.pixelOnlyScreen()
        let otherBinding = try ViewStateFixture.pixelOnlyBinding(session: "session.other")

        #expect(throws: EvidenceReportAssemblyError.copyBindingSessionMismatch(
            screen: ViewStateFixture.sessionID("session.synthetic"),
            binding: ViewStateFixture.sessionID("session.other")
        )) {
            try EvidenceReportPresentation.assembling(screen, copy: otherBinding)
        }
    }

    @Test("Assembly is a pure function of the screen and its binding")
    func assemblyIsDeterministic() throws {
        let screen = try ReportFixture.fusedScreen()
        let copy = try ViewStateFixture.fusionBinding()

        let first = try EvidenceReportPresentation.assembling(screen, copy: copy)
        let second = try EvidenceReportPresentation.assembling(screen, copy: copy)

        #expect(first == second)
    }

    @Test("The assembled presentation keeps the screen's identity and recovery")
    func identityAndRecoveryAreCarried() throws {
        let screen = try ReportFixture.pixelOnlyScreen()
        let presentation = try ReportFixture.pixelOnlyPresentation()

        #expect(presentation.identity == screen.identity)
        #expect(presentation.recovery == screen.recovery)
        #expect(presentation.recovery == .selectAnotherImage)
    }
}

// MARK: - Reflection helpers

/// Normalized stored-property names in a value graph.
///
/// Shared by the ranking, magnitude, and approved-copy assertions so each one states its
/// claim over the whole assembled value rather than over one type.
enum FieldNames {
    static func collect<Model: ProbabilityFreePresentationModel>(from model: Model) -> [String] {
        var names: [String] = []
        walk(model, depth: 0, into: &names)
        return names
    }

    private static func walk(_ value: Any, depth: Int, into names: inout [String]) {
        guard depth < ForbiddenControlAudit.maximumDepth else { return }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let wrapped = mirror.children.first?.value else { return }
            walk(wrapped, depth: depth + 1, into: &names)
            return
        }
        for child in mirror.children {
            if let label = child.label {
                names.append(ForbiddenControlAudit.normalized(label))
            }
            walk(child.value, depth: depth + 1, into: &names)
        }
    }
}

/// Declared field type names in a value graph.
enum FieldTypes {
    static func collect<Model: ProbabilityFreePresentationModel>(from model: Model) -> [String] {
        var types: [String] = []
        walk(model, depth: 0, into: &types)
        return types
    }

    private static func walk(_ value: Any, depth: Int, into types: inout [String]) {
        guard depth < ForbiddenControlAudit.maximumDepth else { return }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let wrapped = mirror.children.first?.value else { return }
            walk(wrapped, depth: depth + 1, into: &types)
            return
        }
        for child in mirror.children {
            types.append(String(reflecting: type(of: child.value)))
            walk(child.value, depth: depth + 1, into: &types)
        }
    }
}

/// Every ``ResolvedCopyReference`` in a value graph.
///
/// Used to assert that every user-facing string the surface will render is addressed by a
/// key the bound catalogue approved, without having to enumerate the members by hand.
enum CopyReferences {
    static func collect<Model: ProbabilityFreePresentationModel>(
        from model: Model
    ) -> [ResolvedCopyReference] {
        var found: [ResolvedCopyReference] = []
        walk(model, depth: 0, into: &found)
        return found
    }

    private static func walk(_ value: Any, depth: Int, into found: inout [ResolvedCopyReference]) {
        guard depth < ForbiddenControlAudit.maximumDepth else { return }
        if let reference = value as? ResolvedCopyReference {
            found.append(reference)
            return
        }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let wrapped = mirror.children.first?.value else { return }
            walk(wrapped, depth: depth + 1, into: &found)
            return
        }
        for child in mirror.children {
            walk(child.value, depth: depth + 1, into: &found)
        }
    }
}

/// A deliberately non-compliant result surface, so the forbidden-control audit is proven
/// able to fail.
///
/// It exists only in tests. Nothing shaped like it is representable in the shipping module.
struct NonCompliantResultSurface: ProbabilityFreePresentationModel {
    let analysisHistory: [String]
    let saveAction: String
    let exportAction: String
    let pasteboardItem: String
    let shareResultAction: String

    static let populated = NonCompliantResultSurface(
        analysisHistory: ["earlier"],
        saveAction: "save",
        exportAction: "export",
        pasteboardItem: "item",
        shareResultAction: "share"
    )
}
