import DefAIkeDomain
import DefAIkeProvenanceAPI

// The conditions that are Provenance Feasibility Gate findings rather than evidence.
//
// The provenance port is deliberately non-throwing: every outcome a validator can
// *reach* is one of the five enabled states, chosen by the signed Provenance Policy.
// That leaves a second, separate class of condition — the ones where no approved input
// answers the question at all:
//
//   * the policy does not map the status the validator reported;
//   * the status maps to `invalid` but nothing named which check failed;
//   * the retained bytes could not be inspected, or the bytes that were read are not
//     the retained bytes;
//   * the validator's output exceeded a limit the policy declared; or
//   * two approved inputs disagree with each other.
//
// The design routes exactly these to the Provenance Feasibility Gate before
// distribution: "crashes, unbounded data, ambiguous mappings, or fixture disagreement
// fail the Provenance Feasibility Gate". So this adapter reports them as a typed
// finding and stops. It does not select a state, because selecting one is the
// unapproved default that Requirement 6.9's exclusivity exists to prevent — and
// selecting `indeterminate` in particular would report an *approved processing result*
// (Requirement 6.14) for a condition no approval covers.
//
// An approved policy exercising the approved fixture suite cannot reach a finding at
// runtime. That is the gate's job to establish, not something this module asserts.

/// Which declared processing limit the validator's work exceeded.
///
/// Every limit is a ``ProvenancePolicy/processingLimits`` value. None is a bound this
/// module chose, and none can be raised, waived, or retried at a larger size.
public enum ProvenanceLimitBreach: Error, Hashable, Sendable {
    /// The manifest the validator parsed is larger than the policy permits.
    case manifestByteCount(observed: UInt64, limit: UInt64)

    /// The manifest nests deeper than the policy permits.
    case nestingDepth(observed: Int, limit: Int)

    /// The validator reported more assertions than the policy permits.
    case assertionCount(observed: Int, limit: Int)

    /// Validation took longer than the policy's declared maximum.
    ///
    /// Measured monotonically after the fact, because the resource and clock ports
    /// expose no deadline, timeout, or interruption member and this module does not
    /// invent one. A breach is therefore an honest measurement to review, not a
    /// runtime abort — which is precisely the resource evidence the gate collects.
    case processingDuration(observed: Duration, limit: Duration)
}

/// Why one inspection could not produce an approved provenance state.
///
/// Not an ``AnalysisError``: none of these is a user-facing analysis outcome, and none
/// may be presented. A caller must not resolve one by choosing a state.
public enum ProvenanceFeasibilityFinding: Error, Hashable, Sendable {
    /// The finalized object holding the retained bytes could not be read.
    ///
    /// Distinct from every other case because it is not necessarily a defect: a
    /// cancelled or cleaned-up session's object is legitimately gone. It is still not
    /// an evidence state, since nothing was inspected (Requirement 6.6).
    case retainedBytesUnreadable(EphemeralStoreError)

    /// The bytes that were read are not the bytes the request describes.
    ///
    /// Reporting a state here would attribute a finding to a byte sequence that is not
    /// the retained representation, which Requirement 6.6 forbids.
    case inspectedBytesAreNotTheRetainedBytes(
        expectedByteCount: UInt64,
        observedByteCount: UInt64
    )

    /// The validator's own status spelling is not a canonical status key, so no policy
    /// could have mapped it.
    ///
    /// Deliberately not repaired by lowercasing, trimming, or substituting: a munged
    /// key would silently resolve to a mapping the policy author never wrote.
    case validatorStatusNotCanonical(rawStatus: String)

    /// A detail the validator reported is not bounded display-safe text.
    ///
    /// The field is named so the gate's malformed-manifest fixtures can point at it.
    /// Dropping the detail instead would present a validated credential with a field
    /// missing and no indication why (Requirement 6.10).
    case validatorDetailNotDisplaySafe(field: ProvenanceDisplayField)

    /// The validator reported more details than one normalized outcome may carry.
    case validatorDetailCountUnbounded(field: ProvenanceDisplayField, observed: Int)

    /// A declared processing limit was exceeded.
    case processingLimitExceeded(ProvenanceLimitBreach)

    /// The validator could not be configured with the approved offline trust material.
    ///
    /// Never an evidence state: an unconfigured validator has not evaluated the approved
    /// trust store, so no answer it gives describes the policy that was in force.
    case validatorNotConfigurable

    /// The policy's mapping for the adapter's revocation-gap status disagrees with the
    /// policy's own declared revocation behavior.
    ///
    /// Two approved fields answer the same question, so a disagreement has no approved
    /// resolution. Preferring either one would be this module deciding what happens
    /// when revocation cannot be established offline, which is decision D5.
    case revocationBehaviorDisagreesWithStatusMapping(
        status: ProvenanceValidatorStatusID,
        mappedState: ProvenanceStateKey,
        declaredState: ProvenanceStateKey
    )

    /// The normalized outcome could not be projected onto a state.
    ///
    /// Carries the mapper's fault verbatim so the gate names the same cause the
    /// vendor-independent contract named.
    case mappingFault(ProvenanceMappingFault)
}
