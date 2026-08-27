import DefAIkeDomain
import DefAIkeProvenanceAPI

// The conditional Content Credential validation adapter.
//
// One inspection has exactly two outcomes: one of the five enabled provenance states,
// or one Provenance Feasibility Gate finding. There is no third result, no partial
// evidence, and no path that reports a state the signed Provenance Policy did not
// choose.
//
// The sequence is fixed, and each step exists to make one requirement structural
// rather than conventional:
//
//   | Step                                              | Why it is here                        |
//   |---------------------------------------------------|---------------------------------------|
//   | Read the object the request names, through the     | The exact encoded representation      |
//   | ephemeral store, by opaque key                     | retained for the session (Req 6.6)    |
//   | Compare what was read to the measured byte count   | A transformed or re-encoded copy      |
//   | and digest recorded while it was written           | cannot be reported on (Req 6.6)       |
//   | Hand the bytes to the validator with the policy's  | Offline, bounded, against the         |
//   | limits and the approved offline trust anchors      | approved store (Req 6.7, 6.8)         |
//   | Measure elapsed monotonic time against the policy  | Declared resource limits, honestly    |
//   | Normalize the library's findings                   | Vendor independence, bounded output   |
//   | Project through the signed mapping                 | Exactly one state (Req 6.9 - 6.14)    |
//
// Two things this adapter deliberately does **not** do:
//
//   * It never touches the network, and it holds nothing that could. Its inputs are a
//     byte array, a signed policy, and approved anchor bytes; a remote-only manifest is
//     reported as a condition the policy maps rather than fetched (Requirement 6.8).
//   * It never chooses a state. Every unanswerable condition leaves as a
//     ``ProvenanceFeasibilityFinding``.
//
// MARK: - Why this adapter does not conform to `ProvenanceAnalyzing`
//
// ``ProvenanceAnalyzing/analyze(_:policy:)`` returns ``ProvenanceEvidence``
// unconditionally: it cannot throw, and it has no case for "no approved input answers
// this". That is correct for the port — every condition a validator can *reach* is a
// state the policy chose — but it means a conformance would have to resolve a
// ``ProvenanceFeasibilityFinding`` by selecting a state, and no artifact in the current
// schema says which. ``ProvenancePolicy`` maps statuses, not faults; the one field that
// answers an unresolved question, ``ProvenanceRevocationBehavior/unavailableAnswerState``,
// is scoped to revocation alone.
//
// So the conformance is absent until an approved decision supplies the missing answer,
// and its absence is fail-closed rather than a gap: ``ProvenanceLaneProvider/resolve(analyzer:policy:manifest:)``
// treats a `nil` analyzer as the pixel-only lane regardless of what the signed manifest
// enables, so a composition that links this module still reports
// ``UnavailableReason/validatorNotCompiledIntoRelease`` until one exists. Linking is not
// approval, and neither is compiling.

/// Everything one inspection needs besides the bytes.
///
/// Bundled into one value so the adapter cannot be constructed with a policy and a copy
/// binding that were never approved together — ``ProvenanceOutcomeMapper`` already
/// refuses that pairing — and so the approved trust material is a required construction
/// argument rather than something an inspection can be run without.
public struct C2PAValidatorConfiguration: Sendable {
    /// The signed policy in force, taken from the mapper so there is one copy of it.
    public var policy: ProvenancePolicy { mapper.policy }

    /// The vendor-independent projection from normalized outcome to evidence state.
    public let mapper: ProvenanceOutcomeMapper

    /// The approved offline trust anchors, bound to the policy's declared store.
    public let trust: C2PAOfflineTrustMaterial

    /// Creates a configuration, or `nil` when the trust material is not the store the
    /// policy named.
    ///
    /// The identity check is on the store artifact reference, so anchors loaded from a
    /// different approved artifact — or from a store that was approved for a different
    /// policy version — cannot configure this validator.
    public init?(mapper: ProvenanceOutcomeMapper, trust: C2PAOfflineTrustMaterial) {
        guard trust.descriptor == mapper.policy.trustStore else { return nil }
        self.mapper = mapper
        self.trust = trust
    }
}

/// Validates Content Credentials in the exact retained encoded bytes, offline, under
/// the signed Provenance Policy's bounded resource controls.
public struct C2PAProvenanceValidator: Sendable {
    /// Where the retained bytes live. Addressed by opaque key only.
    private let store: any EphemeralFileStoring

    /// The validator seam. No default: a build that was not given one cannot inspect.
    private let reader: any C2PAManifestReading

    /// Monotonic readings for the declared processing-duration limit.
    private let clock: any SessionClock

    private let configuration: C2PAValidatorConfiguration
    private let normalizer: C2PAOutcomeNormalizer

    public init(
        store: any EphemeralFileStoring,
        reader: any C2PAManifestReading,
        clock: any SessionClock,
        configuration: C2PAValidatorConfiguration
    ) {
        self.store = store
        self.reader = reader
        self.clock = clock
        self.configuration = configuration
        self.normalizer = C2PAOutcomeNormalizer(policy: configuration.policy)
    }

    /// The signed policy this validator runs under.
    public var policy: ProvenancePolicy { configuration.policy }

    /// Inspects one accepted ingest.
    ///
    /// Derives the normalized request from the asset and the bound policy, so a caller
    /// cannot describe bytes other than the ones ingest retained or supply limits that
    /// disagree with the policy the session was bound to.
    public func inspect(
        _ asset: ImportedEncodedAsset
    ) async throws(ProvenanceFeasibilityFinding) -> ProvenanceEvidence {
        try await inspect(ProvenanceInspectionRequest(asset: asset, policy: policy))
    }

    /// Inspects the exact retained bytes one request names.
    public func inspect(
        _ request: ProvenanceInspectionRequest
    ) async throws(ProvenanceFeasibilityFinding) -> ProvenanceEvidence {
        let bytes = try await retainedBytes(for: request)
        let outcome = try measuredRead(of: bytes, limits: request.limits)
        try checkManifestLimits(outcome, limits: request.limits)
        let normalized = try normalizer.normalize(outcome)

        do {
            return try configuration.mapper.evidence(for: normalized)
        } catch {
            // Exhaustive over ``ProvenanceMappingFault``, and forwarded rather than
            // resolved. Every case is a condition no approved input answers, so
            // selecting a state here is exactly what must not happen.
            throw .mappingFault(error)
        }
    }

    // MARK: - The exact retained bytes

    /// Reads the finalized object the request names and proves it is the retained one.
    ///
    /// The digest is not recomputed: this module's dependency rule is `DefAIkeDomain`
    /// and `DefAIkeProvenanceAPI`, so it has no cryptographic implementation, and the
    /// store already measured the object while writing it. The check that *does* run
    /// here is the one the store cannot make on the caller's behalf — that the bytes
    /// handed to the validator are as long as the request says — which is enough to
    /// catch a truncated, extended, or substituted object.
    private func retainedBytes(
        for request: ProvenanceInspectionRequest
    ) async throws(ProvenanceFeasibilityFinding) -> [UInt8] {
        let receipt = await store.receipt(for: request.storageKey)
        guard let receipt else {
            throw .retainedBytesUnreadable(.notFound(request.storageKey))
        }
        guard request.inspectsExactly(byteCount: receipt.byteCount, sha256: receipt.sha256) else {
            throw .inspectedBytesAreNotTheRetainedBytes(
                expectedByteCount: request.byteCount,
                observedByteCount: receipt.byteCount
            )
        }

        let bytes: [UInt8]
        do {
            bytes = try await store.read(request.storageKey)
        } catch {
            throw .retainedBytesUnreadable(error)
        }

        guard UInt64(bytes.count) == request.byteCount else {
            throw .inspectedBytesAreNotTheRetainedBytes(
                expectedByteCount: request.byteCount,
                observedByteCount: UInt64(bytes.count)
            )
        }
        return bytes
    }

    // MARK: - The measured read

    /// Runs the validator and reports a duration breach as the declared limit it broke.
    ///
    /// Measurement is after the fact. The clock port exposes only readings and the
    /// resource port has no deadline member, because Requirement 15.5 forbids a
    /// requirement-level time limit no approved artifact measured — so this adapter
    /// records what the policy's declared maximum actually cost instead of inventing an
    /// interruption the library does not offer. A breach is a resource finding for the
    /// gate, never an evidence state.
    private func measuredRead(
        of bytes: [UInt8],
        limits: ProvenanceProcessingLimits
    ) throws(ProvenanceFeasibilityFinding) -> C2PAReadOutcome {
        let started = clock.monotonicNow
        let outcome: C2PAReadOutcome
        do {
            outcome = try reader.read(
                exactBytes: bytes,
                limits: limits,
                trust: configuration.trust
            )
        } catch {
            // Exhaustive over ``C2PAReadFault``. Both cases stay findings: a limit breach
            // has no approved evidence meaning, and an unconfigured validator has not
            // evaluated the approved trust store at all.
            switch error {
            case let .limitExceeded(breach):
                throw .processingLimitExceeded(breach)
            case .validatorNotConfigurable:
                throw .validatorNotConfigurable
            }
        }

        let elapsed = clock.elapsed(since: started)
        let allowed = limits.maximumProcessingDuration.duration
        guard elapsed <= allowed else {
            throw .processingLimitExceeded(
                .processingDuration(observed: elapsed, limit: allowed)
            )
        }
        return outcome
    }

    /// Enforces the manifest-shape limits the policy declared.
    ///
    /// Re-checked here rather than trusted from the seam, so a validator implementation
    /// that reports a manifest larger or deeper than the policy permits cannot have its
    /// findings turned into evidence. The assertion-count limit is enforced during
    /// normalization instead, where the list it bounds is built.
    private func checkManifestLimits(
        _ outcome: C2PAReadOutcome,
        limits: ProvenanceProcessingLimits
    ) throws(ProvenanceFeasibilityFinding) {
        if let byteCount = outcome.manifestByteCount {
            let limit = limits.maximumManifestByteCount.value
            guard byteCount <= limit else {
                throw .processingLimitExceeded(
                    .manifestByteCount(observed: byteCount, limit: limit)
                )
            }
        }
        if let depth = outcome.manifestNestingDepth {
            let limit = limits.maximumNestingDepth.value
            guard depth <= limit else {
                throw .processingLimitExceeded(.nestingDepth(observed: depth, limit: limit))
            }
        }
    }
}
