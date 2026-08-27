import Testing

@testable import DefAIkeDomain
@testable import DefAIkePresentation

// Requirements 1.6 through 1.10, 1.15, 8.17, 9.16, 14.9, and 14.14, checked on a host.
//
// The four disclosure destinations are values projected from one input, so everything these
// requirements ask of them is assertable without a view, a navigation stack, a simulator, or a
// device. These tests construct real release artifacts, project the destinations, and read back
// what each screen states.
//
// Several tests assert that something is *not* stated, and none of those is a placeholder. Two
// requirements are satisfied only in part, for two different reasons that both matter:
//
//   * Requirement 1.9 needs the application to identify the project as nonprofit and free, and
//     Requirement 9.16 needs per-topic labels, a provenance availability statement, deadline
//     units, and names for the absent data practices. All of those are sentences, none has
//     approved wording, and the screens record the gaps rather than inventing text.
//   * Requirement 14.14's correction channel has no address anywhere in this repository. The
//     screen carries the published reference and refuses to claim an actionable address.
//
// Asserting the gaps is how they stay visible instead of reading as an oversight, and it is what
// lets task 11.8 snapshot these screens knowing exactly which of their content is approved.

@Suite("Disclosure destination screens")
struct DisclosureScreenTests {

    // MARK: - Fixtures

    /// Synthetic release artifacts coherent with ``CopyFixture``'s session binding.
    ///
    /// Nothing here is approved anything, and no numeric deadline, governance conclusion, or
    /// legal decision expressed here is a product value. The durations are distinct so a test
    /// can tell one reason's deadline from another's, which is the only property they need.
    enum DisclosureFixture {

        static let lifecyclePolicyID = CopyFixture.artifact("policy.lifecycle.synthetic")
        static let scopeID = CopyFixture.artifact("scope.evidence.synthetic")

        /// A distinct synthetic duration per cleanup reason.
        static func duration(for reason: SessionCleanupReason) -> ValidatedDuration {
            let milliseconds: UInt64 =
                switch reason {
                case .completed: 1_000
                case .cancelled: 2_000
                case .errorTerminated: 3_000
                case .interrupted: 4_000
                case .abandoned: 5_000
                }
            // Safe: every value is positive and far inside the schema's ceiling.
            return try! ValidatedDuration(validating: milliseconds)
        }

        static func lifecyclePolicy(
            id: ArtifactID = lifecyclePolicyID
        ) throws -> DataLifecyclePolicy {
            try DataLifecyclePolicy(
                id: id,
                schemaVersion: .v1,
                deadlines: SessionCleanupReason.allCases.map {
                    DataLifecyclePolicy.Deadline(reason: $0, deadline: duration(for: $0))
                },
                approval: CopyFixture.approval()
            )
        }

        /// The model identity ``CopyFixture``'s session binding carries.
        static var sessionModelIdentity: ModelIdentity {
            CopyFixture.sessionBinding().modelIdentity
        }

        static func governance(
            modelIdentity: ModelIdentity? = nil,
            isIndependentNonPeerReviewed: Bool = true,
            redTeamValidationValid: Bool = false,
            inheritedRedTeamStatus: InheritedRedTeamStatus = .invalidNoReportInherited
        ) throws -> ModelGovernanceDecisionRecord {
            try ModelGovernanceDecisionRecord(
                modelIdentity: modelIdentity ?? sessionModelIdentity,
                isIndependentNonPeerReviewed: isIndependentNonPeerReviewed,
                redTeamValidationValid: redTeamValidationValid,
                inheritedRedTeamStatus: inheritedRedTeamStatus,
                decision: CopyFixture.approval()
            )
        }

        /// A gate record for one gate, with the conditional gates waived by decision.
        static func gateRecord(
            _ gate: ReleaseGate,
            outcome: GateOutcome = .passed
        ) throws -> ReleaseGateRecord {
            if gate.isConditional {
                return try ReleaseGateRecord(
                    gate: gate,
                    applicability: .notApplicable(decision: CopyFixture.approval()),
                    outcome: .notExecuted,
                    evidence: CopyFixture.evidence("evidence.\(gate.rawValue)")
                )
            }
            return try ReleaseGateRecord(
                gate: gate,
                applicability: .applicable,
                outcome: outcome,
                evidence: CopyFixture.evidence("evidence.\(gate.rawValue)")
            )
        }

        /// A pixel-only release-readiness record.
        ///
        /// `outcomes` overrides individual gate results, which is how a test exercises an
        /// unpublished limitations reference or an unsupplied correction channel.
        static func release(
            capabilityManifest: ArtifactID = CopyFixture.capabilityManifestID,
            governance: ModelGovernanceDecisionRecord? = nil,
            outcomes: [ReleaseGate: GateOutcome] = [:]
        ) throws -> ReleaseReadinessRecord {
            try ReleaseReadinessRecord(
                id: CopyFixture.artifact("record.release-readiness.synthetic"),
                schemaVersion: .v1,
                appBuild: AppBuildID("build.synthetic")!,
                capabilityManifest: capabilityManifest,
                modelBundle: ModelBundleID("bundle.synthetic")!,
                deviceAllowlist: CopyFixture.artifact("allowlist.devices.synthetic"),
                gateRecords: try ReleaseGate.allCases.map {
                    try gateRecord($0, outcome: outcomes[$0] ?? .passed)
                },
                distributionRights: DistributionRightsRecord(
                    repositoryCodeLicense: CopyFixture.approval(),
                    datasetDistributionTerms: CopyFixture.approval()
                ),
                modelGovernance: try governance ?? self.governance(),
                benchmarkClaims: []
            )
        }

        /// A coherent pixel-only input: the composition this release actually ships.
        static func pixelOnlyInput(
            governance: ModelGovernanceDecisionRecord? = nil,
            outcomes: [ReleaseGate: GateOutcome] = [:]
        ) throws -> DisclosureScreenInput {
            DisclosureScreenInput(
                capabilities: try CopyFixture.capabilityManifest(),
                lifecyclePolicy: try lifecyclePolicy(),
                release: try release(governance: governance, outcomes: outcomes),
                session: CopyFixture.sessionBinding(),
                scope: .version1(id: scopeID),
                copy: try CopyFixture.pixelOnlyBinding()
            )
        }

        /// A coherent provenance-enabled input, so the conditional statement can be checked in
        /// the other composition.
        static func provenanceInput() throws -> DisclosureScreenInput {
            DisclosureScreenInput(
                capabilities: try CopyFixture.capabilityManifest(provenanceEnabled: true),
                lifecyclePolicy: try lifecyclePolicy(),
                release: try release(),
                session: CopyFixture.sessionBinding(provenanceEnabled: true),
                scope: .version1(id: scopeID),
                copy: try CopyFixture.provenanceBinding()
            )
        }
    }

    // MARK: - 8.17: every destination is reachable

    @Test("A coherent input projects all four destinations")
    func projectionYieldsEveryDestination() throws {
        let screens = try DisclosureScreens.projecting(try DisclosureFixture.pixelOnlyInput())

        #expect(screens.reachesEveryRequiredDestination)
        #expect(screens.pathMappingsAgree)
        #expect(screens.sessionID == CopyFixture.sessionBinding().sessionID)
    }

    @Test("Every required destination names one screen, and every screen is named")
    func destinationMappingIsTotalInBothDirections() throws {
        let screens = try DisclosureScreens.projecting(try DisclosureFixture.pixelOnlyInput())

        var named: Set<DisclosureScreenKind> = []
        for destination in RequiredDisclosureDestination.allCases {
            let kind = screens.screen(for: destination)
            named.insert(kind)
            // The report path and the screen's own entry path must be the same path, or a
            // report would offer a path leading somewhere else.
            #expect(destination.path == kind.entryPath, "\(destination)")
        }
        #expect(named == Set(DisclosureScreenKind.allCases))
    }

    @Test("Each screen states approved copy for its own content")
    func eachScreenStatesApprovedCopy() throws {
        let screens = try DisclosureScreens.projecting(try DisclosureFixture.pixelOnlyInput())

        let expected: [DisclosureScreenKind: VerdictCopySurface] = [
            .privacy: .privacyExplanation,
            .modelInformation: .modelInformation,
            .scopeAndLimitations: .evidenceScope,
            .correctionChannel: .correctionChannel,
        ]
        for kind in DisclosureScreenKind.allCases {
            let reference = screens.statementCopy(for: kind)
            #expect(reference.surface == expected[kind], "\(kind)")
            #expect(reference.localizationKey.rawValue.isEmpty == false)
        }
    }

    @Test("Each destination screen answers for exactly the destinations mapped to it")
    func screensAnswerForTheirDestinations() throws {
        let screens = try DisclosureScreens.projecting(try DisclosureFixture.pixelOnlyInput())

        #expect(
            Set(screens.modelInformation.destinations) == [
                .selectedModelIdentity,
                .independentNonPeerReviewedReleaseStatus,
                .invalidInheritedRedTeamStatus,
            ]
        )
        #expect(screens.scopeAndLimitations.destinations == [.measuredLimitations])
        #expect(screens.correctionChannel.destinations == [.correctionChannel])
    }

    // MARK: - 9.16: the privacy explanation

    @Test("The privacy screen answers every topic Requirement 9.16 names")
    func privacyScreenAnswersEveryTopic() throws {
        let screens = try DisclosureScreens.projecting(try DisclosureFixture.pixelOnlyInput())
        let privacy = screens.privacy

        #expect(privacy.answersEveryRequiredTopic)
        #expect(privacy.coveredTopics == PrivacyTopic.allCases)
        #expect(privacy.explanationCopy.surface == .privacyExplanation)
        #expect(privacy.pixelInference == .onDevice)
        #expect(privacy.photoAccess == .selectedItemOnly)
        #expect(privacy.networkRequirement == .noneForAnalysis)
        #expect(privacy.modelDelivery == .packagedInsideApplication)
        #expect(privacy.removalScope == .everyApplicationControlledNamespace)
    }

    @Test("The privacy screen states all five absent data practices")
    func privacyScreenStatesEveryAbsence() throws {
        let screens = try DisclosureScreens.projecting(try DisclosureFixture.pixelOnlyInput())

        #expect(screens.privacy.statesEveryAbsentDataPractice)
        #expect(screens.privacy.absentDataPractices == AbsentDataPractice.allCases)
        for practice in AbsentDataPractice.allCases {
            #expect(practice.forbiddenBy.isEmpty == false, "\(practice)")
        }
    }

    @Test("Cleanup deadlines are the supplied values, one per reason, unchanged")
    func cleanupDeadlinesComeFromTheSuppliedPolicy() throws {
        let input = try DisclosureFixture.pixelOnlyInput()
        let privacy = try DisclosureScreens.projecting(input).privacy

        #expect(privacy.statesEveryCleanupDeadline)
        #expect(privacy.lifecyclePolicyID == input.lifecyclePolicy.id)
        #expect(privacy.cleanupDeadlines.map(\.reason) == SessionCleanupReason.allCases)
        for reason in SessionCleanupReason.allCases {
            // The screen carries the policy's own value. Nothing is rounded, defaulted, or
            // chosen here, which is what makes the deadline a supplied number.
            #expect(privacy.deadline(for: reason) == input.lifecyclePolicy.deadline(for: reason))
        }
    }

    @Test("A different supplied policy changes every deadline the screen states")
    func deadlinesTrackThePolicyRatherThanAConstant() throws {
        let input = try DisclosureFixture.pixelOnlyInput()
        let baseline = try DisclosureScreens.projecting(input).privacy

        // A second policy at the same identifier with doubled deadlines. If the screen carried
        // constants rather than the artifact's values, this would project identically.
        let doubled = try DataLifecyclePolicy(
            id: DisclosureFixture.lifecyclePolicyID,
            schemaVersion: .v1,
            deadlines: try SessionCleanupReason.allCases.map { reason in
                DataLifecyclePolicy.Deadline(
                    reason: reason,
                    deadline: try ValidatedDuration(
                        validating: DisclosureFixture.duration(for: reason).milliseconds * 2
                    )
                )
            },
            approval: CopyFixture.approval()
        )
        let second = DisclosureScreenInput(
            capabilities: input.capabilities,
            lifecyclePolicy: doubled,
            release: input.release,
            session: input.session,
            scope: input.scope,
            copy: input.copy
        )
        let changed = try DisclosureScreens.projecting(second).privacy

        for reason in SessionCleanupReason.allCases {
            let before = try #require(baseline.deadline(for: reason))
            let after = try #require(changed.deadline(for: reason))
            #expect(after.milliseconds == before.milliseconds * 2, "\(reason)")
        }
    }

    // MARK: - 9.16: conditional provenance in both compositions

    @Test("A pixel-only release states that provenance validation is not part of it")
    func pixelOnlyReleaseStatesNoProvenanceValidation() throws {
        let screens = try DisclosureScreens.projecting(try DisclosureFixture.pixelOnlyInput())

        // Not "found nothing" and not "could not tell": the capability is absent from the
        // build, which is the same distinction Requirement 8.8 draws for the evidence lane.
        #expect(screens.privacy.provenanceValidation == .notPartOfThisRelease)
    }

    @Test("A provenance-enabled release states that validation runs on the device")
    func provenanceReleaseStatesLocalValidation() throws {
        let screens = try DisclosureScreens.projecting(try DisclosureFixture.provenanceInput())

        #expect(screens.privacy.provenanceValidation == .validatedOnDevice)
        // Every other privacy answer is identical across the two compositions, so the
        // conditional statement is the only thing the capability set changes.
        #expect(screens.privacy.answersEveryRequiredTopic)
        #expect(screens.privacy.statesEveryAbsentDataPractice)
    }

    // MARK: - 1.6 through 1.9: funding and access

    @Test("The privacy screen states every access claim Requirements 1.6 to 1.9 require")
    func privacyScreenStatesEveryAccessClaim() throws {
        let screens = try DisclosureScreens.projecting(try DisclosureFixture.pixelOnlyInput())

        #expect(screens.privacy.statesEveryAccessClaim)
        #expect(screens.privacy.accessClaims == ProjectAccessClaim.allCases)
        #expect(screens.privacy.accessClaims.contains(.nonprofitProject))
        #expect(screens.privacy.accessClaims.contains(.zeroMonetaryCost))
        #expect(screens.privacy.accessClaims.contains(.noAccountRequired))
        #expect(screens.privacy.accessClaims.contains(.noAdvertising))
        #expect(screens.privacy.accessClaims.contains(.outsideASubscription))
        for claim in ProjectAccessClaim.allCases {
            #expect(claim.required.isEmpty == false, "\(claim)")
        }
    }

    @Test("The funding statement is recorded as blocked rather than written")
    func fundingStatementIsRecordedAsBlocked() throws {
        // Requirement 1.9 asks the application to *identify* the project as nonprofit and free,
        // which is a sentence. The facts are true of the build by construction and are stated
        // structurally above; no approved wording for them exists, so the statement is a
        // recorded gap and nothing is rendered for it.
        #expect(
            PrivacyDisclosureScreen.unapprovedSurfaces.contains(.projectFundingStatement)
        )
        #expect(
            UnapprovedDisclosureSurface.projectFundingStatement.isApprovedCopyDecision
        )
    }

    // MARK: - 8.17 and 14.9: model information

    @Test("Model information discloses the session's own model and its release status")
    func modelInformationDisclosesTheBoundModel() throws {
        let input = try DisclosureFixture.pixelOnlyInput()
        let screen = try DisclosureScreens.projecting(input).modelInformation

        #expect(screen.modelIdentity == input.session.modelIdentity)
        #expect(screen.modelBundleID == input.session.modelBundleID)
        #expect(screen.coreMLModelVersion == input.session.coreMLModelVersion)
        #expect(screen.calibrationPolicyID == input.session.calibrationPolicyID)
        #expect(screen.informationCopy.surface == .modelInformation)
    }

    @Test("The inherited red-team status is presented as invalid, never as valid")
    func redTeamStatusIsPresentedAsInvalid() throws {
        let screens = try DisclosureScreens.projecting(try DisclosureFixture.pixelOnlyInput())
        let screen = screens.modelInformation

        #expect(screen.peerReview == .independentNonPeerReviewed)
        #expect(screen.redTeamValidation == .noValidInheritedReport)
        #expect(screen.presentsAValidInheritedRedTeamReport == false)
        #expect(screen.makesTheRequiredGovernanceDisclosures)
        #expect(screens.makesTheRequiredGovernanceDisclosures)
    }

    @Test("A false upstream flag can never project a valid inherited report")
    func aFalseFlagCannotProjectAValidReport() throws {
        // The domain refuses the incoherent pairing outright, so a record claiming both a false
        // validation flag and an inherited valid report does not exist to be rendered.
        #expect(throws: (any Error).self) {
            try DisclosureFixture.governance(
                redTeamValidationValid: false,
                inheritedRedTeamStatus: .validReportInherited
            )
        }

        // And the projection's own rule is independent of that: a false flag yields the invalid
        // disclosure whatever the status field says.
        let screens = try DisclosureScreens.projecting(
            try DisclosureFixture.pixelOnlyInput(
                governance: try DisclosureFixture.governance(
                    redTeamValidationValid: false,
                    inheritedRedTeamStatus: .invalidNoReportInherited
                )
            )
        )
        #expect(screens.modelInformation.redTeamValidation == .noValidInheritedReport)
    }

    @Test("The disclosure follows the record rather than a constant")
    func disclosureFollowsTheGovernanceRecord() throws {
        // Nothing here hard-codes the current checkpoint's values. A future refresh that
        // genuinely inherits a valid report projects the other case, and one that inherits none
        // projects the invalid case even with a passing flag.
        let inherited = try DisclosureScreens.projecting(
            try DisclosureFixture.pixelOnlyInput(
                governance: try DisclosureFixture.governance(
                    isIndependentNonPeerReviewed: false,
                    redTeamValidationValid: true,
                    inheritedRedTeamStatus: .validReportInherited
                )
            )
        )
        #expect(inherited.modelInformation.redTeamValidation == .validInheritedReport)
        #expect(inherited.modelInformation.peerReview == .peerReviewed)
        #expect(inherited.modelInformation.makesTheRequiredGovernanceDisclosures == false)

        let notInherited = try DisclosureScreens.projecting(
            try DisclosureFixture.pixelOnlyInput(
                governance: try DisclosureFixture.governance(
                    redTeamValidationValid: true,
                    inheritedRedTeamStatus: .invalidNoReportInherited
                )
            )
        )
        #expect(notInherited.modelInformation.redTeamValidation == .noValidInheritedReport)
    }

    @Test("A governance record describing another model is refused")
    func anotherModelIsRefused() throws {
        let other = ModelIdentity(
            checkpointIdentifier: ModelCheckpointIdentifier("checkpoint.other-synthetic")!,
            requiredWeightDigest: CopyFixture.digest("e")
        )
        let input = try DisclosureFixture.pixelOnlyInput(
            governance: try DisclosureFixture.governance(modelIdentity: other)
        )

        #expect(
            throws: DisclosureAssemblyError.modelIdentityMismatch(
                session: input.session.modelIdentity,
                governance: other
            )
        ) {
            try DisclosureScreens.projecting(input)
        }
    }

    // MARK: - 14.14: published limitations and correction channel

    @Test("The published limitations reference is the release record's own entry")
    func limitationsReferenceComesFromTheRecord() throws {
        let input = try DisclosureFixture.pixelOnlyInput()
        let screen = try DisclosureScreens.projecting(input).modelInformation
        let gate = input.release.record(for: .activeLimitationsPublication)

        #expect(screen.activeLimitations.source == gate.evidence)
        #expect(screen.activeLimitations.artifact == gate.evidence.artifact)
        #expect(screen.activeLimitations.version == gate.evidence.version)
    }

    @Test("An unpublished limitations reference produces no screens")
    func unpublishedLimitationsRefuses() throws {
        for outcome in [GateOutcome.failed, .notExecuted] {
            let input = try DisclosureFixture.pixelOnlyInput(
                outcomes: [.activeLimitationsPublication: outcome]
            )
            #expect(
                throws: DisclosureAssemblyError.activeLimitationsNotPublished(outcome: outcome)
            ) {
                try DisclosureScreens.projecting(input)
            }
        }
    }

    @Test("The correction channel carries the supplied reference and claims no address")
    func correctionChannelCarriesTheSuppliedReference() throws {
        let input = try DisclosureFixture.pixelOnlyInput()
        let screen = try DisclosureScreens.projecting(input).correctionChannel
        let gate = input.release.record(for: .correctionChannel)

        #expect(screen.channelCopy.surface == .correctionChannel)
        #expect(screen.channel.source == gate.evidence)
        // Nothing in this repository supplies the channel's contents, so the screen says so
        // rather than showing a placeholder a user might act on.
        #expect(screen.presentsAnActionableAddress == false)
        #expect(
            CorrectionChannelScreen.unapprovedSurfaces == [.correctionChannelAddress]
        )
        #expect(
            UnapprovedDisclosureSurface.correctionChannelAddress.isApprovedCopyDecision == false
        )
    }

    @Test("An unsupplied correction channel produces no screens")
    func unsuppliedCorrectionChannelRefuses() throws {
        for outcome in [GateOutcome.failed, .notExecuted] {
            let input = try DisclosureFixture.pixelOnlyInput(
                outcomes: [.correctionChannel: outcome]
            )
            #expect(
                throws: DisclosureAssemblyError.correctionChannelNotSupplied(outcome: outcome)
            ) {
                try DisclosureScreens.projecting(input)
            }
        }
    }

    // MARK: - 1.10 and 1.15: scope and limitations

    @Test("The limitations screen states the whole evidence scope")
    func limitationsScreenStatesTheWholeScope() throws {
        let screen = try DisclosureScreens.projecting(
            try DisclosureFixture.pixelOnlyInput()
        ).scopeAndLimitations

        #expect(screen.statesEveryRequiredScope)
        #expect(screen.coveredScopes == [.wholeImageSynthesis])
        #expect(
            Set(screen.uncoveredScopes) == EvidenceScope.requiredExcludedStatements
        )
        // Order comes from the closed statement vocabulary, not from anything derived from
        // English, so it is stable under localization.
        #expect(
            screen.uncoveredScopes
                == AnalysisScopeStatement.allCases.filter(
                    EvidenceScope.requiredExcludedStatements.contains
                )
        )
        #expect(screen.scopeCopy.surface == .evidenceScope)
        #expect(screen.falseResultCopy.surface == .falseResultLimitation)
    }

    @Test("The limitations screen explains all three pixel labels with their exact strings")
    func limitationsScreenExplainsEveryLabel() throws {
        let screen = try DisclosureScreens.projecting(
            try DisclosureFixture.pixelOnlyInput()
        ).scopeAndLimitations

        #expect(screen.explainsEveryPixelLabel)
        #expect(screen.labelExplanations.map(\.label) == PixelLabelKey.allCases)
        for explanation in screen.labelExplanations {
            #expect(
                explanation.labelText == FixedPixelLabelText(label: explanation.label),
                "\(explanation.label)"
            )
            #expect(
                explanation.explanationCopy.surface == .pixelExplanation(explanation.label),
                "\(explanation.label)"
            )
        }
    }

    @Test("Pixel evidence is stated as probabilistic, with every unestablished property listed")
    func pixelEvidenceIsStatedAsProbabilistic() throws {
        let screen = try DisclosureScreens.projecting(
            try DisclosureFixture.pixelOnlyInput()
        ).scopeAndLimitations

        #expect(screen.evidenceStrength == .probabilisticEvidence)
        #expect(screen.accountsForEveryUnestablishedProperty)
        #expect(
            screen.unestablishedProperties == UnestablishedByPixelEvidence.allCases
        )
    }

    @Test("Requirement 1.15 is only partly sayable, and the unsayable part is recorded")
    func requirement1_15IsPartlyBlocked() throws {
        let screen = try DisclosureScreens.projecting(
            try DisclosureFixture.pixelOnlyInput()
        ).scopeAndLimitations

        // Certainty, authenticity, and the localized-edit exclusion have approved framing in
        // the three pixel explanations and the scope statement. Authorship, intent, and the
        // editing sequence have none, and none may be written here.
        #expect(
            screen.propertiesWithoutApprovedFraming == [.authorship, .intent, .editingSequence]
        )
        #expect(
            ScopeAndLimitationsScreen.unapprovedSurfaces
                .contains(.pixelEvidenceNonEstablishmentStatement)
        )
    }

    // MARK: - Coherence

    @Test("A copy binding from another session is refused")
    func anotherSessionsCopyBindingIsRefused() throws {
        let input = try DisclosureScreenInput(
            capabilities: CopyFixture.capabilityManifest(),
            lifecyclePolicy: DisclosureFixture.lifecyclePolicy(),
            release: DisclosureFixture.release(),
            session: CopyFixture.sessionBinding(sessionID: "session.first-synthetic"),
            scope: .version1(id: DisclosureFixture.scopeID),
            copy: ViewStateFixture.pixelOnlyBinding(session: "session.second-synthetic")
        )

        #expect(
            throws: DisclosureAssemblyError.copyBindingSessionMismatch(
                session: AnalysisSessionID("session.first-synthetic")!,
                binding: AnalysisSessionID("session.second-synthetic")!
            )
        ) {
            try DisclosureScreens.projecting(input)
        }
    }

    @Test("Each record that disagrees about the capability manifest is named")
    func capabilityManifestDisagreementNamesItsSource() throws {
        let other = CopyFixture.artifact("manifest.capability.other-synthetic")

        // The session binding disagrees.
        var input = try DisclosureScreenInput(
            capabilities: CopyFixture.capabilityManifest(),
            lifecyclePolicy: DisclosureFixture.lifecyclePolicy(),
            release: DisclosureFixture.release(),
            session: CopyFixture.sessionBinding(capabilityManifestID: other),
            scope: .version1(id: DisclosureFixture.scopeID),
            copy: try CopyFixture.pixelOnlyBinding()
        )
        #expect(
            throws: DisclosureAssemblyError.capabilityManifestMismatch(
                source: .sessionBinding,
                expected: CopyFixture.capabilityManifestID,
                found: other
            )
        ) {
            try DisclosureScreens.projecting(input)
        }

        // The release record disagrees.
        input = try DisclosureScreenInput(
            capabilities: CopyFixture.capabilityManifest(),
            lifecyclePolicy: DisclosureFixture.lifecyclePolicy(),
            release: DisclosureFixture.release(capabilityManifest: other),
            session: CopyFixture.sessionBinding(),
            scope: .version1(id: DisclosureFixture.scopeID),
            copy: try CopyFixture.pixelOnlyBinding()
        )
        #expect(
            throws: DisclosureAssemblyError.capabilityManifestMismatch(
                source: .releaseRecord,
                expected: CopyFixture.capabilityManifestID,
                found: other
            )
        ) {
            try DisclosureScreens.projecting(input)
        }
    }

    @Test("A lifecycle policy the session was not bound to is refused")
    func anotherLifecyclePolicyIsRefused() throws {
        let other = CopyFixture.artifact("policy.lifecycle.other-synthetic")
        let input = try DisclosureScreenInput(
            capabilities: CopyFixture.capabilityManifest(),
            lifecyclePolicy: DisclosureFixture.lifecyclePolicy(id: other),
            release: DisclosureFixture.release(),
            session: CopyFixture.sessionBinding(),
            scope: .version1(id: DisclosureFixture.scopeID),
            copy: try CopyFixture.pixelOnlyBinding()
        )

        #expect(
            throws: DisclosureAssemblyError.lifecyclePolicyMismatch(
                session: DisclosureFixture.lifecyclePolicyID,
                supplied: other
            )
        ) {
            try DisclosureScreens.projecting(input)
        }
    }

    // MARK: - Determinism

    @Test("The same input projects to the same value")
    func projectionIsDeterministic() throws {
        let input = try DisclosureFixture.pixelOnlyInput()

        let first = try DisclosureScreens.projecting(input)
        let second = try DisclosureScreens.projecting(input)

        // Value equality over the whole aggregate, which is what lets task 11.8 snapshot these
        // screens on a host with no view hierarchy.
        #expect(first == second)
        #expect(first.hashValue == second.hashValue)
    }

    @Test("The two capability compositions differ in exactly the conditional statement")
    func compositionsDifferOnlyWhereTheCapabilitySetDoes() throws {
        let pixelOnly = try DisclosureScreens.projecting(
            try DisclosureFixture.pixelOnlyInput()
        )
        let provenance = try DisclosureScreens.projecting(
            try DisclosureFixture.provenanceInput()
        )

        #expect(pixelOnly.privacy != provenance.privacy)
        #expect(pixelOnly.privacy.provenanceValidation != provenance.privacy.provenanceValidation)
        // The other three destinations do not depend on the capability set at all.
        #expect(pixelOnly.modelInformation == provenance.modelInformation)
        #expect(pixelOnly.scopeAndLimitations == provenance.scopeAndLimitations)
        #expect(pixelOnly.correctionChannel == provenance.correctionChannel)
    }

    // MARK: - Recorded copy gaps

    @Test("Every recorded gap names the requirement it gates and has a unique key")
    func gapsNameTheirRequirement() {
        for surface in UnapprovedDisclosureSurface.allCases {
            #expect(surface.gates.isEmpty == false, "\(surface)")
            #expect(surface.rawValue.isEmpty == false, "\(surface)")
        }
        #expect(
            Set(UnapprovedDisclosureSurface.allCases.map(\.rawValue)).count
                == UnapprovedDisclosureSurface.allCases.count
        )
    }

    @Test("The four recorded gap vocabularies are pairwise disjoint")
    func gapVocabulariesArePairwiseDisjoint() {
        // The same rule tasks 11.2, 11.3, and 11.4 already follow: a surface recorded once is
        // recorded in one place, so an audit reading all four lists sees each gap exactly once.
        let disclosure = Set(UnapprovedDisclosureSurface.allCases.map(\.rawValue))
        let accessibility = Set(UnapprovedAccessibilitySurface.allCases.map(\.rawValue))
        let report = Set(UnapprovedReportSurface.allCases.map(\.rawValue))
        let viewState = Set(UnapprovedViewStateSurface.allCases.map(\.rawValue))

        #expect(disclosure.isDisjoint(with: accessibility))
        #expect(disclosure.isDisjoint(with: report))
        #expect(disclosure.isDisjoint(with: viewState))
        #expect(accessibility.isDisjoint(with: report))
        #expect(accessibility.isDisjoint(with: viewState))
        #expect(report.isDisjoint(with: viewState))
    }

    @Test("Every recorded gap is claimed by one of the four screens")
    func everyGapIsClaimedByAScreen() {
        // A gap no screen claims would be a gap nobody is waiting on, which is either a stale
        // entry or a screen that quietly stopped needing the surface.
        #expect(
            DisclosureScreens.unapprovedSurfaces == Set(UnapprovedDisclosureSurface.allCases)
        )
        for surface in UnapprovedDisclosureSurface.allCases {
            #expect(DisclosureScreens.unapprovedSurfaces.contains(surface), "\(surface)")
        }
    }

    @Test("The two externally supplied items are recorded, not invented")
    func externallySuppliedItemsAreRecorded() {
        // The correction channel's address is external content; the deadline unit is approved
        // wording. Both are blocked, and the distinction is who unblocks them.
        #expect(
            UnapprovedDisclosureSurface.allCases.filter { !$0.isApprovedCopyDecision }
                == [.correctionChannelAddress]
        )
        #expect(
            UnapprovedDisclosureSurface.cleanupDeadlineDurationUnit.isApprovedCopyDecision
        )
    }

    // MARK: - Structural exclusions

    @Test("No disclosure screen can carry a probability, confidence, or magnitude field")
    func screensCarryNoResultMagnitude() throws {
        let screens = try DisclosureScreens.projecting(try DisclosureFixture.pixelOnlyInput())

        #expect(ProhibitedClaimAudit.findings(in: screens).isEmpty)
        #expect(ProhibitedClaimAudit.findings(in: screens.privacy).isEmpty)
        #expect(ProhibitedClaimAudit.findings(in: screens.modelInformation).isEmpty)
        #expect(ProhibitedClaimAudit.findings(in: screens.scopeAndLimitations).isEmpty)
        #expect(ProhibitedClaimAudit.findings(in: screens.correctionChannel).isEmpty)
    }

    @Test("No disclosure screen can carry a forbidden result affordance")
    func screensCarryNoForbiddenAffordance() throws {
        let screens = try DisclosureScreens.projecting(try DisclosureFixture.pixelOnlyInput())

        #expect(ForbiddenControlAudit.findings(in: screens).isEmpty)
        #expect(ForbiddenControlAudit.findings(in: screens.privacy).isEmpty)
        #expect(ForbiddenControlAudit.findings(in: screens.modelInformation).isEmpty)
        #expect(ForbiddenControlAudit.findings(in: screens.scopeAndLimitations).isEmpty)
        #expect(ForbiddenControlAudit.findings(in: screens.correctionChannel).isEmpty)
    }
}
