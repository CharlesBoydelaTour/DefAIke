import DefAIkeDomain

// Stubs for the two evidence-lane ports.

/// Returns a programmed provenance state without a C2PA library.
///
/// Non-throwing, matching the port: every validator condition — including a parser fault,
/// an inconclusive result, and a missing offline revocation answer — is an enabled state
/// chosen by the approved mapping, never an error that ends the session.
///
/// The stub records the asset it was given and never receives the pixel lane, so a test
/// can assert structurally that provenance analysis did not touch the raw logit,
/// execution status, or Pixel Evidence (Requirement 7.4).
public final class StubProvenanceAnalyzer: ProvenanceAnalyzing, Sendable {
    private let states: LockedBox<[ProvenanceEvidence]>
    private let last: LockedBox<ProvenanceEvidence>
    private let recorder: PortCallRecorder?
    private let inspected = LockedBox<[SHA256Digest]>([])

    /// Creates an analyzer that always returns `state`.
    public init(always state: ProvenanceEvidence, recorder: PortCallRecorder? = nil) {
        self.states = LockedBox([])
        self.last = LockedBox(state)
        self.recorder = recorder
    }

    /// Creates an analyzer that walks `states`, repeating the last one.
    public init(_ states: [ProvenanceEvidence], recorder: PortCallRecorder? = nil) {
        precondition(!states.isEmpty, "a provenance stub needs at least one state")
        self.states = LockedBox(Array(states.dropLast()))
        self.last = LockedBox(states[states.count - 1])
        self.recorder = recorder
    }

    /// Digests of the assets the analyzer inspected, in order.
    ///
    /// Requirements 2.13 and 6.6 require the identical retained encoded byte sequence
    /// the Input Validator receives. Comparing this against what validation saw is how a
    /// test proves the two lanes read the same bytes.
    public var inspectedDigests: [SHA256Digest] { inspected.value }

    public func analyze(
        _ asset: ImportedEncodedAsset,
        policy: ProvenancePolicy
    ) async -> ProvenanceEvidence {
        recorder?.record(.provenanceAnalyze(asset.sessionID))
        inspected.withValue { $0.append(asset.sha256) }
        return states.withValue { remaining in
            guard !remaining.isEmpty else { return last.value }
            return remaining.removeFirst()
        }
    }
}

/// Looks up the real rule, so fusion behavior is the rule's and not the stub's.
///
/// A stub that returned a canned summary would test nothing: exhaustiveness,
/// determinism, and optional omission are properties of ``EvidenceFusionRule``, which is
/// already total over the 15 combinations. This double supplies only the two
/// session-compatibility checks the port is responsible for, and records that fusion was
/// consulted at all — which is what the pixel-only composition must never do.
public final class StubEvidenceFuser: EvidenceFusing, Sendable {
    private let recorder: PortCallRecorder?

    public init(recorder: PortCallRecorder? = nil) {
        self.recorder = recorder
    }

    public func resolve(
        pixel: PixelEvidence,
        provenance: ProvenanceEvidence,
        rule: EvidenceFusionRule,
        binding: AnalysisSessionBinding
    ) throws(FusionFault) -> CombinedSummary? {
        recorder?.record(.fuse)
        guard binding.fusionRuleID == rule.id else {
            throw .ruleNotBoundToSession(expected: binding.fusionRuleID, found: rule.id)
        }
        guard binding.verdictCopyCompatibilityID == rule.compatibleVerdictCopy else {
            throw .incompatibleVerdictCopy(
                expected: binding.verdictCopyCompatibilityID,
                found: rule.compatibleVerdictCopy
            )
        }
        let combination = FusionLaneCombination.lookupKey(pixel: pixel, provenance: provenance)
        switch rule.disposition(for: combination) {
        case .omit:
            return nil
        case .show(let copyKey):
            return CombinedSummary(copyKey: copyKey, fusionRuleID: rule.id)
        }
    }
}
