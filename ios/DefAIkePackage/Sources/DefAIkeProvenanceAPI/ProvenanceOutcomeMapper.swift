import DefAIkeDomain

// The result mapping contract: one normalized outcome in, exactly one enabled evidence
// state out.
//
// This is a pure function of three approved inputs — the signed Provenance Policy, the
// approved copy binding, and one ``NormalizedProvenanceOutcome`` — and it is the only
// place a ``ProvenanceEvidence`` value is constructed from validator findings. It lives
// in this module rather than in the C2PA adapter for two reasons: the mapping is
// vendor-independent, and keeping it here means it can be exercised without linking a
// validator at all.
//
// The mapper never chooses a state. The state comes from the policy's status mapping,
// and any condition the policy does not answer is a ``ProvenanceMappingFault`` rather
// than a default. In particular there is no branch that can produce `validated` from an
// unmapped status, a missing binding, or a failed check: a missing offline revocation
// answer reaches whichever state the policy's revocation behavior declares, which the
// policy schema already forbids from being `validated`.

/// Why a normalized outcome could not be projected onto an evidence state.
///
/// Not an ``AnalysisError``: a fault here is a policy or validator-normalization defect,
/// and the design routes exactly these conditions — ambiguous mappings, parser findings
/// the policy does not map, fixture disagreement — to the Provenance Feasibility Gate
/// before distribution. An approved policy exercising approved fixtures cannot reach one
/// at runtime.
///
/// A caller must not resolve a fault by selecting a state. Choosing one in code is the
/// exact substitution of an unapproved default that Requirement 6.9's exclusivity and
/// the design's "no silently validated" rule exist to prevent.
public enum ProvenanceMappingFault: Error, Hashable, Sendable {
    /// The policy has no mapping for this normalized status. A policy gap.
    case unmappedValidatorStatus(ProvenanceValidatorStatusID)

    /// The determined binding contradicts the mapped state: `validated` without
    /// binding to the inspected bytes, a byte-binding failure that also reports
    /// binding, or `absent` with a binding determination (Requirements 6.11 and 6.12).
    case bindingInconsistentWithMappedState(
        status: ProvenanceValidatorStatusID,
        state: ProvenanceStateKey,
        binding: NormalizedBindingOutcome
    )

    /// The status maps to `invalid` but the outcome names no failed check, so the
    /// invalidity category would have to be invented.
    case undeterminedInvalidityCategory(status: ProvenanceValidatorStatusID)

    /// The outcome names a failed check while mapping to a state that is not `invalid`.
    /// Unsupported and indeterminate are separate from invalid by Requirements 6.13
    /// and 6.14, so a failure category cannot ride along with them.
    case invalidityCategoryOnNonInvalidState(
        status: ProvenanceValidatorStatusID,
        state: ProvenanceStateKey,
        category: InvalidityCategory
    )

    /// The status maps to `absent` while the outcome reports details. Nothing was
    /// found, so nothing can be described (Requirements 6.11 and 7.6).
    case detailsReportedForAbsentState(status: ProvenanceValidatorStatusID)

    /// The outcome carries more assertion labels than the policy's approved limit.
    case assertionLimitExceeded(observed: Int, limit: Int)
}

/// Projects normalized validator outcomes onto the five enabled evidence states.
///
/// Deterministic and total over every outcome the policy maps: the same outcome always
/// yields the same state, the same bounded details, and the same field order.
public struct ProvenanceOutcomeMapper: Sendable {
    /// The signed policy whose status mapping, display allowlist, and limits govern.
    public let policy: ProvenancePolicy

    /// The approved copy keys required to build a displayable state.
    public let copy: ProvenanceCopyBinding

    private let invalidExplanation: ApprovedCopyKey
    private let unsupportedExplanation: ApprovedCopyKey
    private let indeterminateExplanation: ApprovedCopyKey

    /// Creates a mapper, or `nil` when the policy and the copy binding do not agree.
    ///
    /// The coverage checks are repeated here rather than assumed from
    /// ``ProvenanceCopyBinding``, so a binding built against a different value carrying
    /// the same artifact identifier cannot produce a mapper with a missing key. After
    /// this initializer, every lookup the mapping performs is known to resolve.
    public init?(policy: ProvenancePolicy, copy: ProvenanceCopyBinding) {
        guard copy.policyID == policy.id else { return nil }
        guard Set(copy.detailLabels.keys) == policy.displayableFields else { return nil }
        guard let invalidExplanation = copy.stateExplanations[.invalid],
              let unsupportedExplanation = copy.stateExplanations[.unsupported],
              let indeterminateExplanation = copy.stateExplanations[.indeterminate],
              copy.stateExplanations[.validated] != nil,
              copy.stateExplanations[.absent] != nil
        else {
            return nil
        }
        self.policy = policy
        self.copy = copy
        self.invalidExplanation = invalidExplanation
        self.unsupportedExplanation = unsupportedExplanation
        self.indeterminateExplanation = indeterminateExplanation
    }

    /// Maps one normalized outcome onto exactly one enabled provenance state.
    public func evidence(
        for outcome: NormalizedProvenanceOutcome
    ) throws(ProvenanceMappingFault) -> ProvenanceEvidence {
        let assertionLimit = policy.processingLimits.maximumAssertionCount.value
        guard outcome.assertionLabels.count <= assertionLimit else {
            throw .assertionLimitExceeded(
                observed: outcome.assertionLabels.count,
                limit: assertionLimit
            )
        }

        guard let state = policy.state(for: outcome.status) else {
            throw .unmappedValidatorStatus(outcome.status)
        }

        if let category = outcome.failedCheck, state != .invalid {
            throw .invalidityCategoryOnNonInvalidState(
                status: outcome.status,
                state: state,
                category: category
            )
        }

        switch state {
        case .validated:
            guard outcome.binding == .boundToInspectedBytes else {
                throw .bindingInconsistentWithMappedState(
                    status: outcome.status,
                    state: state,
                    binding: outcome.binding
                )
            }
            return .validated(
                ValidatedClaimSummary(
                    provenancePolicyID: policy.id,
                    bindingStatus: .boundToInspectedBytes,
                    signerFields: signerFields(of: outcome),
                    assertionFields: assertionFields(of: outcome)
                )
            )

        case .invalid:
            guard let category = outcome.failedCheck else {
                throw .undeterminedInvalidityCategory(status: outcome.status)
            }
            // A byte-binding failure and an established binding cannot both hold.
            guard category != .byteBinding || outcome.binding != .boundToInspectedBytes else {
                throw .bindingInconsistentWithMappedState(
                    status: outcome.status,
                    state: state,
                    binding: outcome.binding
                )
            }
            return .invalid(
                InvaliditySummary(
                    provenancePolicyID: policy.id,
                    category: category,
                    explanationKey: invalidExplanation
                )
            )

        case .absent:
            guard outcome.binding == .notDetermined else {
                throw .bindingInconsistentWithMappedState(
                    status: outcome.status,
                    state: state,
                    binding: outcome.binding
                )
            }
            guard !outcome.reportsAnyDetail else {
                throw .detailsReportedForAbsentState(status: outcome.status)
            }
            return .absent

        case .unsupported:
            return .unsupported(
                UnsupportedFeatureSummary(
                    provenancePolicyID: policy.id,
                    explanationKey: unsupportedExplanation,
                    unsupportedFeatures: outcome.unsupportedFeatures
                )
            )

        case .indeterminate:
            return .indeterminate(
                IndeterminateSummary(
                    provenancePolicyID: policy.id,
                    explanationKey: indeterminateExplanation
                )
            )
        }
    }

    // MARK: - Bounded display projection

    /// Signer-side fields the policy permits displaying, in fixed field order.
    ///
    /// Iterating the field vocabulary rather than the validator's list is what makes
    /// the displayed order independent of the order a validator reported details in.
    private func signerFields(of outcome: NormalizedProvenanceOutcome) -> [DisplaySafeField] {
        var fields: [DisplaySafeField] = []
        for field in ProvenanceDisplayField.allCases where field != .assertionLabels {
            guard policy.displayableFields.contains(field),
                  let detail = outcome.signerDetails.first(where: { $0.field == field }),
                  // Resolves for every displayable field: the initializer proved the
                  // label mapping covers exactly `policy.displayableFields`.
                  let labelKey = copy.detailLabels[field]
            else {
                continue
            }
            fields.append(DisplaySafeField(labelKey: labelKey, value: detail.value))
        }
        return fields
    }

    /// Assertion labels the policy permits displaying, in the order the validator read
    /// them, all under the one approved assertion-label key.
    private func assertionFields(of outcome: NormalizedProvenanceOutcome) -> [DisplaySafeField] {
        guard policy.displayableFields.contains(.assertionLabels),
              let labelKey = copy.detailLabels[.assertionLabels]
        else {
            return []
        }
        return outcome.assertionLabels.map {
            DisplaySafeField(labelKey: labelKey, value: $0)
        }
    }
}
