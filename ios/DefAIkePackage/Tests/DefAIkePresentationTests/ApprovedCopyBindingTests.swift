import Testing

@testable import DefAIkeDomain
@testable import DefAIkePresentation

// Version-bound copy lookup: what binds, what refuses, and what stays unresolvable.
//
// The shape of every refusal test is the same: start from a coherent synthetic set,
// change exactly one field, and assert the exact error case. That is what makes the
// binding auditable - a failure names one cause rather than "copy failed".

@Suite("Approved Verdict Copy binding")
struct ApprovedCopyBindingTests {

    // MARK: - Coherent bindings resolve

    @Test("A coherent pixel-only set binds and records the agreed versions")
    func pixelOnlyBinds() throws {
        let binding = try CopyFixture.pixelOnlyBinding()

        #expect(binding.catalogID == CopyFixture.catalogID)
        #expect(binding.compatibilityID == CopyFixture.compatibilityID)
        #expect(binding.capabilityManifestID == CopyFixture.capabilityManifestID)
        #expect(binding.sessionID == AnalysisSessionID("session.synthetic")!)
        #expect(binding.reachableSurfaces.isProvenanceEnabled == false)
        #expect(binding.reachableSurfaces.isFusionEnabled == false)
        #expect(binding.reachableSurfaces.combinedSummaryKeys.isEmpty)
    }

    @Test("Every pixel label resolves a label and an explanation", arguments: PixelEvidence.allCases)
    func pixelLabelsResolve(evidence: PixelEvidence) throws {
        let presentation = try CopyFixture.pixelOnlyBinding().presentation(forPixel: evidence)

        #expect(presentation.evidence == evidence)
        #expect(presentation.labelCopy.surface == .pixelLabel(evidence.labelKey))
        #expect(presentation.explanationCopy.surface == .pixelExplanation(evidence.labelKey))
        #expect(presentation.fixedLabelText.label == evidence.labelKey)
        #expect(presentation.labelCopy.localizationKey != presentation.explanationCopy.localizationKey)
        #expect(presentation.labelCopy.compatibilityID == CopyFixture.compatibilityID)
    }

    @Test("Every Analysis Error resolves a message and a recovery", arguments: AnalysisError.allCases)
    func errorsResolve(error: AnalysisError) throws {
        let presentation = try CopyFixture.pixelOnlyBinding().presentation(forError: error)

        #expect(presentation.error == error)
        #expect(presentation.messageCopy.surface == .analysisError(error.errorKey))
        #expect(presentation.recoveryCopy.surface == .errorRecovery(error.errorKey))
    }

    @Test(
        "A pixel-only release resolves the unavailable lane, never an enabled state",
        arguments: UnavailableReason.allCases
    )
    func unavailableLaneResolves(reason: UnavailableReason) throws {
        let presentation = try CopyFixture.pixelOnlyBinding()
            .presentation(forProvenance: .unavailable(reason))

        #expect(presentation.state == .unavailable(reason))
        #expect(presentation.stateCopy.surface == .provenanceUnavailable)
    }

    @Test("A provenance-enabled release resolves all five enabled states")
    func enabledStatesResolve() throws {
        let binding = try CopyFixture.provenanceBinding()

        for state in ProvenanceStateKey.allCases {
            let reference = try binding.reference(for: .provenanceState(state))
            #expect(reference.surface == .provenanceState(state))
        }
        // The unavailable state stays addressable in a provenance-enabled build: the
        // capability can be compiled and the lane can still be unavailable because the
        // signed manifest did not enable it.
        #expect(throws: Never.self) { try binding.reference(for: .provenanceUnavailable) }
    }

    // MARK: - Requirement 8.8: an enabled state is unreachable in a pixel-only build

    @Test(
        "A pixel-only release cannot address an enabled provenance state",
        arguments: ProvenanceStateKey.allCases
    )
    func pixelOnlyCannotAddressEnabledStates(state: ProvenanceStateKey) throws {
        let binding = try CopyFixture.pixelOnlyBinding()

        #expect(throws: PresentationCopyError.unreachableSurface(.provenanceState(state))) {
            try binding.reference(for: .provenanceState(state))
        }
    }

    @Test("A pixel-only catalogue need not carry enabled provenance entries")
    func pixelOnlyCatalogueMayOmitProvenanceEntries() throws {
        let surfaces = VerdictCopySurface.unconditionalSurfaces

        #expect(throws: Never.self) {
            try ApprovedCopyBinding.bind(
                catalog: CopyFixture.catalog(surfaces: surfaces),
                session: CopyFixture.sessionBinding(),
                capabilities: CopyFixture.capabilityManifest(),
                fusionRule: nil
            )
        }
    }

    // MARK: - Requirement 8.1: every reachable surface needs an approved entry

    @Test("A provenance-enabled catalogue missing one enabled state fails closed")
    func provenanceCatalogueMissingOneStateFails() throws {
        let dropped = VerdictCopySurface.provenanceState(.indeterminate)
        let catalog = try CopyFixture.catalog(
            surfaces: CopyFixture.allSurfaces.subtracting([dropped])
        )

        #expect(throws: PresentationCopyError.missingSurfaces([dropped])) {
            try ApprovedCopyBinding.bind(
                catalog: catalog,
                session: CopyFixture.sessionBinding(provenanceEnabled: true),
                capabilities: CopyFixture.capabilityManifest(provenanceEnabled: true),
                fusionRule: nil
            )
        }
    }

    @Test(
        "Dropping any single unconditional surface fails closed",
        arguments: VerdictCopySurface.unconditionalSurfaces.sorted { $0.description < $1.description }
    )
    func droppingAnyUnconditionalSurfaceFails(dropped: VerdictCopySurface) throws {
        let catalog = try CopyFixture.catalog(
            surfaces: CopyFixture.allSurfaces.subtracting([dropped])
        )

        #expect(throws: PresentationCopyError.missingSurfaces([dropped])) {
            try ApprovedCopyBinding.bind(
                catalog: catalog,
                session: CopyFixture.sessionBinding(),
                capabilities: CopyFixture.capabilityManifest(),
                fusionRule: nil
            )
        }
    }

    @Test("Missing surfaces are reported in stable order")
    func missingSurfacesAreOrdered() throws {
        let dropped: Set<VerdictCopySurface> = [
            .evidenceScope,
            .correctionChannel,
            .apparentInconsistency,
        ]
        let catalog = try CopyFixture.catalog(
            surfaces: CopyFixture.allSurfaces.subtracting(dropped)
        )

        do {
            _ = try ApprovedCopyBinding.bind(
                catalog: catalog,
                session: CopyFixture.sessionBinding(),
                capabilities: CopyFixture.capabilityManifest(),
                fusionRule: nil
            )
            Issue.record("A catalogue missing three reachable surfaces must not bind.")
        } catch let PresentationCopyError.missingSurfaces(surfaces) {
            #expect(surfaces == surfaces.sorted { $0.description < $1.description })
            #expect(Set(surfaces) == dropped)
        }
    }

    // MARK: - Requirement 8.1: version-bound compatibility

    @Test("A catalogue for a different compatibility identifier fails closed")
    func catalogueCompatibilityMismatchFails() throws {
        let other = CopyFixture.artifact("copy.compatibility.v2")

        #expect(
            throws: PresentationCopyError.compatibilityMismatch(
                source: .copyCatalog,
                expected: CopyFixture.compatibilityID,
                found: other
            )
        ) {
            try ApprovedCopyBinding.bind(
                catalog: CopyFixture.catalog(compatibilityID: other),
                session: CopyFixture.sessionBinding(),
                capabilities: CopyFixture.capabilityManifest(),
                fusionRule: nil
            )
        }
    }

    @Test("A manifest naming different approved copy than the session fails closed")
    func manifestCompatibilityMismatchFails() throws {
        let other = CopyFixture.artifact("copy.compatibility.v2")

        #expect(
            throws: PresentationCopyError.compatibilityMismatch(
                source: .capabilityManifest,
                expected: CopyFixture.compatibilityID,
                found: other
            )
        ) {
            try ApprovedCopyBinding.bind(
                catalog: CopyFixture.catalog(),
                session: CopyFixture.sessionBinding(),
                capabilities: CopyFixture.capabilityManifest(verdictCopyCompatibility: other),
                fusionRule: nil
            )
        }
    }

    @Test("A session bound to a different capability manifest fails closed")
    func capabilityManifestMismatchFails() throws {
        let other = CopyFixture.artifact("manifest.capability.other")

        #expect(
            throws: PresentationCopyError.capabilityManifestMismatch(
                session: other,
                supplied: CopyFixture.capabilityManifestID
            )
        ) {
            try ApprovedCopyBinding.bind(
                catalog: CopyFixture.catalog(),
                session: CopyFixture.sessionBinding(capabilityManifestID: other),
                capabilities: CopyFixture.capabilityManifest(),
                fusionRule: nil
            )
        }
    }

    @Test("A rejected content approval fails closed: presence is not approval")
    func rejectedApprovalFails() throws {
        #expect(
            throws: PresentationCopyError.unapprovedCatalog(
                catalog: CopyFixture.catalogID,
                decision: .rejected
            )
        ) {
            try ApprovedCopyBinding.bind(
                catalog: CopyFixture.catalog(approval: .rejected),
                session: CopyFixture.sessionBinding(),
                capabilities: CopyFixture.capabilityManifest(),
                fusionRule: nil
            )
        }
    }

    // MARK: - Capability coherence between manifest and session

    @Test("A manifest enabling provenance against a session that does not fails closed")
    func provenanceBindingMismatchFails() throws {
        #expect(
            throws: PresentationCopyError.provenanceBindingMismatch(
                manifestEnablesProvenance: true,
                sessionBindsPolicy: false
            )
        ) {
            try ApprovedCopyBinding.bind(
                catalog: CopyFixture.catalog(),
                session: CopyFixture.sessionBinding(provenanceEnabled: false),
                capabilities: CopyFixture.capabilityManifest(provenanceEnabled: true),
                fusionRule: nil
            )
        }
    }

    @Test("A manifest enabling fusion against a session that does not fails closed")
    func fusionBindingMismatchFails() throws {
        #expect(
            throws: PresentationCopyError.fusionBindingMismatch(
                manifestEnablesFusion: true,
                sessionBindsRule: false
            )
        ) {
            try ApprovedCopyBinding.bind(
                catalog: CopyFixture.catalog(),
                session: CopyFixture.sessionBinding(provenanceEnabled: true, fusionEnabled: false),
                capabilities: CopyFixture.capabilityManifest(
                    provenanceEnabled: true,
                    fusionEnabled: true
                ),
                fusionRule: CopyFixture.fusionRule()
            )
        }
    }

    // MARK: - Fusion rule input

    @Test("Fusion enabled with no supplied rule fails closed")
    func missingFusionRuleFails() throws {
        #expect(throws: PresentationCopyError.missingFusionRule(expected: CopyFixture.fusionRuleID))
        {
            try ApprovedCopyBinding.bind(
                catalog: CopyFixture.catalog(),
                session: CopyFixture.sessionBinding(provenanceEnabled: true, fusionEnabled: true),
                capabilities: CopyFixture.capabilityManifest(
                    provenanceEnabled: true,
                    fusionEnabled: true
                ),
                fusionRule: nil
            )
        }
    }

    @Test("A rule supplied for a release without fusion fails closed")
    func unexpectedFusionRuleFails() throws {
        #expect(
            throws: PresentationCopyError.unexpectedFusionRule(supplied: CopyFixture.fusionRuleID)
        ) {
            try ApprovedCopyBinding.bind(
                catalog: CopyFixture.catalog(),
                session: CopyFixture.sessionBinding(provenanceEnabled: true),
                capabilities: CopyFixture.capabilityManifest(provenanceEnabled: true),
                fusionRule: CopyFixture.fusionRule()
            )
        }
    }

    @Test("A rule other than the bound rule fails closed")
    func fusionRuleIdentityMismatchFails() throws {
        let other = CopyFixture.artifact("rule.fusion.other")

        #expect(
            throws: PresentationCopyError.fusionRuleMismatch(
                expected: CopyFixture.fusionRuleID,
                found: other
            )
        ) {
            try ApprovedCopyBinding.bind(
                catalog: CopyFixture.catalog(),
                session: CopyFixture.sessionBinding(provenanceEnabled: true, fusionEnabled: true),
                capabilities: CopyFixture.capabilityManifest(
                    provenanceEnabled: true,
                    fusionEnabled: true
                ),
                fusionRule: CopyFixture.fusionRule(id: other)
            )
        }
    }

    @Test("A rule addressing different approved copy fails closed")
    func fusionRuleCompatibilityMismatchFails() throws {
        let other = CopyFixture.artifact("copy.compatibility.v2")

        #expect(
            throws: PresentationCopyError.compatibilityMismatch(
                source: .fusionRule,
                expected: CopyFixture.compatibilityID,
                found: other
            )
        ) {
            try ApprovedCopyBinding.bind(
                catalog: CopyFixture.catalog(),
                session: CopyFixture.sessionBinding(provenanceEnabled: true, fusionEnabled: true),
                capabilities: CopyFixture.capabilityManifest(
                    provenanceEnabled: true,
                    fusionEnabled: true
                ),
                fusionRule: CopyFixture.fusionRule(compatibleVerdictCopy: other)
            )
        }
    }

    // MARK: - Combined Summary reachability

    @Test("A summary key the active rule can produce resolves")
    func reachableSummaryResolves() throws {
        let binding = try CopyFixture.fusionBinding()
        let key = CopyFixture.summaryKeys[.signalsConsistentWithAIGeneration]!

        let presentation = try binding.presentation(
            forCombinedSummary: CombinedSummary(
                copyKey: key,
                fusionRuleID: CopyFixture.fusionRuleID
            )
        )

        #expect(presentation.summaryCopy.surface == .combinedSummary(key))
        #expect(presentation.fusionRuleID == CopyFixture.fusionRuleID)
    }

    @Test("A summary key no active disposition shows is unreachable")
    func omittedSummaryIsUnreachable() throws {
        let omitted: PixelLabelKey = .notEnoughSignal
        let binding = try CopyFixture.fusionBinding(omitting: [omitted])
        let key = CopyFixture.summaryKeys[omitted]!

        #expect(binding.reachableSurfaces.combinedSummaryKeys.contains(key) == false)
        #expect(throws: PresentationCopyError.unreachableSurface(.combinedSummary(key))) {
            try binding.presentation(
                forCombinedSummary: CombinedSummary(
                    copyKey: key,
                    fusionRuleID: CopyFixture.fusionRuleID
                )
            )
        }
    }

    @Test("A release without fusion reaches no summary surface at all")
    func noFusionReachesNoSummary() throws {
        let binding = try CopyFixture.provenanceBinding()

        for key in CopyFixture.summaryKeys.values {
            #expect(throws: PresentationCopyError.unreachableSurface(.combinedSummary(key))) {
                try binding.reference(for: .combinedSummary(key))
            }
        }
    }

    // MARK: - Declared keys

    @Test("An apparent-inconsistency notice must declare the approved key")
    func apparentInconsistencyKeyIsChecked() throws {
        let binding = try CopyFixture.provenanceBinding()
        let approved = CopyFixture.localizationKey(for: .apparentInconsistency)

        let reference = try binding.apparentInconsistencyReference(declaredKey: approved)
        #expect(reference.surface == .apparentInconsistency)
        #expect(reference.localizationKey == approved)

        let unapproved = CopyFixture.copyKey("copy.invented-notice")
        #expect(
            throws: PresentationCopyError.unapprovedCopyKey(
                surface: .apparentInconsistency,
                declared: unapproved,
                approved: approved
            )
        ) {
            try binding.apparentInconsistencyReference(declaredKey: unapproved)
        }
    }

    // MARK: - Requirement 8.18: English only

    @Test("The catalogue schema refuses any language other than English")
    func nonEnglishCatalogueIsRejected() {
        #expect(throws: (any Error).self) {
            try CopyFixture.catalog(languageTag: "fr")
        }
    }

    // MARK: - Probe

    @Test("The non-throwing probe agrees with resolution")
    func probeAgreesWithResolution() throws {
        let binding = try CopyFixture.pixelOnlyBinding()

        #expect(binding.localizationKey(for: .evidenceScope) != nil)
        #expect(binding.localizationKey(for: .provenanceState(.validated)) == nil)
        #expect(
            binding.localizationKey(for: .evidenceScope)
                == (try binding.reference(for: .evidenceScope)).localizationKey
        )
    }
}
