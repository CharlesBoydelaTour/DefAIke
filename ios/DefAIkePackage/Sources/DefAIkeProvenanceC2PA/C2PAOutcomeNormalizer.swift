import DefAIkeDomain
import DefAIkeProvenanceAPI

// Library findings in, one bounded vendor-independent outcome out.
//
// This is the whole "normalize" half of the adapter, and it is a pure function: no
// bytes, no library, no clock, no store. Everything it does is one of four things —
// name the status key, bound the details, make the details display-safe, and decide
// whether an invalidity category is even applicable — and every one of them fails
// closed rather than substituting a value.
//
// It does *not* decide a state. It reads ``ProvenancePolicy/state(for:)`` in exactly one
// place, and only to answer a question about the *outcome's shape*: an invalidity
// category is meaningful for an invalid result and is a contradiction beside any other
// state (Requirements 6.13 and 6.14), so the category has to be attached conditionally
// or the vendor-independent mapper will reject the outcome. The state itself is still
// chosen by ``ProvenanceOutcomeMapper`` from the same signed mapping, so the two cannot
// diverge.

/// Projects one library read onto a ``NormalizedProvenanceOutcome``.
public struct C2PAOutcomeNormalizer: Sendable {
    /// The signed policy whose status mapping, display allowlist, and limits govern.
    public let policy: ProvenancePolicy

    public init(policy: ProvenancePolicy) {
        self.policy = policy
    }

    /// Normalizes `outcome`, or reports the gate finding that stopped it.
    public func normalize(
        _ outcome: C2PAReadOutcome
    ) throws(ProvenanceFeasibilityFinding) -> NormalizedProvenanceOutcome {
        let status = try statusID(for: outcome.status)
        try checkRevocationAgreement(for: outcome.status, status: status)

        let signerDetails = try displayableSignerDetails(of: outcome)
        let assertionLabels = try displayableAssertionLabels(of: outcome)
        let unsupportedFeatures = try displayableUnsupportedFeatures(of: outcome)

        guard let normalized = NormalizedProvenanceOutcome(
            status: status,
            binding: Self.binding(outcome.binding),
            failedCheck: applicableFailedCheck(for: outcome, status: status),
            signerDetails: signerDetails,
            assertionLabels: assertionLabels,
            unsupportedFeatures: unsupportedFeatures
        ) else {
            // Unreachable: the contract's initializer rejects an unbounded list, a
            // repeated signer field, a signer detail tagged as an assertion label, and a
            // repeated label or feature — and every one of those is already excluded
            // above. Kept as a fail-closed branch rather than a force-unwrap so that
            // relaxing either side later surfaces a finding instead of a crash.
            throw .validatorDetailCountUnbounded(
                field: .assertionLabels,
                observed: assertionLabels.count + unsupportedFeatures.count
            )
        }
        return normalized
    }

    // MARK: - The status key

    private func statusID(
        for finding: C2PAStatusFinding
    ) throws(ProvenanceFeasibilityFinding) -> ProvenanceValidatorStatusID {
        switch finding {
        case let .readerCondition(condition):
            return C2PAStatusVocabulary.statusID(for: condition)
        case let .libraryStatus(code):
            guard let id = C2PAStatusVocabulary.statusID(forLibraryCode: code) else {
                throw .validatorStatusNotCanonical(rawStatus: code)
            }
            return id
        }
    }

    /// Requires the policy's two answers about an unresolvable revocation question to
    /// agree.
    ///
    /// ``ProvenanceRevocationBehavior/unavailableAnswerState`` and the status mapping
    /// both answer it, and the schema already forbids `validated` and `absent` on the
    /// first. Preferring one over the other in code would be this module deciding
    /// decision D5, so a disagreement stops here instead.
    private func checkRevocationAgreement(
        for finding: C2PAStatusFinding,
        status: ProvenanceValidatorStatusID
    ) throws(ProvenanceFeasibilityFinding) {
        guard case .readerCondition(.revocationAnswerUnavailable) = finding else { return }
        guard let mapped = policy.state(for: status) else {
            // The policy simply has no mapping. That is one cause with one name, and
            // the vendor-independent mapper already reports it, so it is left to it.
            return
        }
        let declared = policy.revocationBehavior.unavailableAnswerState
        guard mapped == declared else {
            throw .revocationBehaviorDisagreesWithStatusMapping(
                status: status,
                mappedState: mapped,
                declaredState: declared
            )
        }
    }

    // MARK: - The binding determination

    private static func binding(_ finding: C2PABindingFinding) -> NormalizedBindingOutcome {
        switch finding {
        case .boundToInspectedBytes: .boundToInspectedBytes
        case .notBound: .notBound
        case .notDetermined: .notDetermined
        }
    }

    // MARK: - The invalidity category

    /// The failed check, but only where an invalidity category is applicable.
    ///
    /// Attached when the policy maps this status to `invalid`, and withheld otherwise:
    /// unsupported and indeterminate are separate from invalid, so a category riding
    /// along with either would be a contradiction the mapper refuses. An unmapped status
    /// withholds it too, so the reported cause is the missing mapping rather than a
    /// category on a state that does not exist.
    private func applicableFailedCheck(
        for outcome: C2PAReadOutcome,
        status: ProvenanceValidatorStatusID
    ) -> InvalidityCategory? {
        guard policy.state(for: status) == .invalid else { return nil }
        return outcome.failedCheck
    }

    // MARK: - Bounded display projection

    /// Signer details for fields the policy permits displaying.
    ///
    /// A detail for a field outside ``ProvenancePolicy/displayableFields`` is dropped
    /// silently, because the policy decided it is not safe to show. A detail for a
    /// permitted field that is not display-safe is a finding, because dropping it would
    /// show a validated credential with a field missing and no stated reason.
    private func displayableSignerDetails(
        of outcome: C2PAReadOutcome
    ) throws(ProvenanceFeasibilityFinding) -> [NormalizedProvenanceDetail] {
        var details: [NormalizedProvenanceDetail] = []
        var seen: Set<ProvenanceDisplayField> = []
        for raw in outcome.signerDetails {
            guard raw.field != .assertionLabels else { continue }
            guard policy.displayableFields.contains(raw.field) else { continue }
            guard seen.insert(raw.field).inserted else { continue }
            guard let value = DisplaySafeText(raw.rawValue) else {
                throw .validatorDetailNotDisplaySafe(field: raw.field)
            }
            details.append(NormalizedProvenanceDetail(field: raw.field, value: value))
        }
        guard details.count <= NormalizedProvenanceOutcome.maximumDetailCount else {
            throw .validatorDetailCountUnbounded(
                field: .signerIdentity,
                observed: details.count
            )
        }
        return details
    }

    /// Assertion labels, deduplicated in first-read order and bounded by the policy.
    ///
    /// The policy's ``ProvenanceProcessingLimits/maximumAssertionCount`` is checked before
    /// the display allowlist, and before the mapper sees the list, for two reasons: an
    /// unbounded assertion list is a resource condition rather than a display one, so it
    /// applies even where labels are not shown; and reporting it as the declared limit it
    /// breached names the cause better than a mapping fault would.
    ///
    /// Deduplication preserves order because assertion sequence can itself be meaningful,
    /// and the contract requires the list to be free of repeats.
    private func displayableAssertionLabels(
        of outcome: C2PAReadOutcome
    ) throws(ProvenanceFeasibilityFinding) -> [DisplaySafeText] {
        let limit = policy.processingLimits.maximumAssertionCount.value
        guard outcome.assertionLabels.count <= limit else {
            throw .processingLimitExceeded(
                .assertionCount(observed: outcome.assertionLabels.count, limit: limit)
            )
        }
        guard policy.displayableFields.contains(.assertionLabels) else { return [] }
        return try Self.deduplicatedDisplaySafe(
            outcome.assertionLabels,
            field: .assertionLabels
        )
    }

    /// Unsupported feature names, deduplicated in first-read order.
    ///
    /// Tagged to ``ProvenanceDisplayField/assertionLabels`` only for the purpose of
    /// naming a finding: unsupported features are carried by
    /// ``UnsupportedFeatureSummary`` rather than by a display field, so no allowlist
    /// entry governs them.
    private func displayableUnsupportedFeatures(
        of outcome: C2PAReadOutcome
    ) throws(ProvenanceFeasibilityFinding) -> [DisplaySafeText] {
        try Self.deduplicatedDisplaySafe(outcome.unsupportedFeatures, field: .assertionLabels)
    }

    private static func deduplicatedDisplaySafe(
        _ raw: [String],
        field: ProvenanceDisplayField
    ) throws(ProvenanceFeasibilityFinding) -> [DisplaySafeText] {
        var values: [DisplaySafeText] = []
        var seen: Set<DisplaySafeText> = []
        for candidate in raw {
            guard let value = DisplaySafeText(candidate) else {
                throw .validatorDetailNotDisplaySafe(field: field)
            }
            guard seen.insert(value).inserted else { continue }
            values.append(value)
        }
        guard values.count <= NormalizedProvenanceOutcome.maximumDetailCount else {
            throw .validatorDetailCountUnbounded(field: field, observed: values.count)
        }
        return values
    }
}
