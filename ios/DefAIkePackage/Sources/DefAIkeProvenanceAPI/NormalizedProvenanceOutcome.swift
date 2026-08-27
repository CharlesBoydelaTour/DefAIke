import DefAIkeDomain

// The normalized output side of the provenance contract.
//
// A vendor validator reports its findings in its own vocabulary: its own status enum,
// its own error types, its own arbitrarily deep manifest structures. None of that may
// reach the domain, for three separate reasons:
//
//   * the five exclusive evidence states are chosen by the signed Provenance Policy's
//     status mapping, not by a library's spelling (Requirements 6.9 through 6.14);
//   * manifest content is attacker-influenced, so anything projected for display is
//     bounded and display-safe before it becomes an evidence value; and
//   * swapping or removing the validator must not change a domain type, which is what
//     keeps the pixel-only composition free of validator code at all.
//
// So an adapter's whole job on the output side is to normalize: report which policy
// status key it reached, what it determined about byte binding, which check failed if
// one did, and the bounded details it read. Everything after that is a pure decision
// made by ``ProvenanceOutcomeMapper``.

/// What a validator determined about binding to the inspected bytes.
///
/// Three cases, deliberately not a `Bool`: "not bound" and "not determined" are
/// different findings. Collapsing them would let an inconclusive result read as a
/// definite binding failure, and Requirement 6.14 keeps inconclusive processing
/// separate from Requirement 6.12's definite invalidity.
public enum NormalizedBindingOutcome: String, Hashable, Codable, Sendable, CaseIterable {
    /// The claim is cryptographically bound to the exact inspected bytes.
    case boundToInspectedBytes
    /// The validator determined the claim is not bound to the inspected bytes.
    case notBound
    /// Binding was not determined: no manifest was found, or processing did not
    /// reach a conclusion.
    case notDetermined
}

/// One bounded detail a validator read, tagged with the display field it belongs to.
///
/// The tag is a ``ProvenanceDisplayField``, so the signed policy's `displayableFields`
/// allowlist decides whether the detail may be shown at all. The value is
/// ``DisplaySafeText``, so it is already length-bounded and free of line breaks,
/// control characters, and bidirectional controls. A validator supplies no label: the
/// label is an Approved Verdict Copy key, which is what stops a manifest from writing
/// its own user-facing sentence.
public struct NormalizedProvenanceDetail: Hashable, Sendable {
    public let field: ProvenanceDisplayField
    public let value: DisplaySafeText

    public init(field: ProvenanceDisplayField, value: DisplaySafeText) {
        self.field = field
        self.value = value
    }
}

/// One validator result, normalized to vendor-independent bounded values.
///
/// This is the only shape ``ProvenanceOutcomeMapper`` accepts, and it carries no
/// evidence state: the state is the policy's decision. It also carries no probability,
/// score, or trust conclusion — a validator reports what it observed.
public struct NormalizedProvenanceOutcome: Hashable, Sendable {
    /// Structural ceiling on how many details one outcome may carry per list.
    ///
    /// A safety bound so a hostile manifest cannot make the display projection
    /// unbounded, not an approved value. The approved assertion ceiling is the
    /// policy's `processingLimits.maximumAssertionCount`, which
    /// ``ProvenanceOutcomeMapper`` enforces separately.
    public static let maximumDetailCount = 64

    /// The normalized status key the signed policy maps onto one evidence state.
    public let status: ProvenanceValidatorStatusID

    /// What the validator determined about binding to the inspected bytes.
    public let binding: NormalizedBindingOutcome

    /// Which validation check failed, when the validator determined one.
    ///
    /// `nil` for every outcome that is not a definite validation failure. The mapper
    /// refuses to invent a category, so a status the policy maps to `invalid` without
    /// a named failed check is a fail-closed fault rather than a guess.
    public let failedCheck: InvalidityCategory?

    /// Signer-side details, at most one per display field.
    ///
    /// Unique field tags make the projected order deterministic: the mapper emits them
    /// in a fixed field order, so the same outcome always produces the same displayed
    /// list regardless of the order a validator happened to report them in.
    public let signerDetails: [NormalizedProvenanceDetail]

    /// Assertion labels the validator read, in the order it read them.
    ///
    /// Governed by ``ProvenanceDisplayField/assertionLabels``. Order is preserved
    /// rather than sorted, because assertion sequence can itself be meaningful.
    public let assertionLabels: [DisplaySafeText]

    /// Features the validator does not support (Requirement 6.13).
    ///
    /// May be empty: a validator can know that something is outside its capability set
    /// without being able to name it.
    public let unsupportedFeatures: [DisplaySafeText]

    /// Creates a normalized outcome, or `nil` when it is not bounded and unambiguous.
    ///
    /// Rejects:
    ///
    /// * any list longer than ``maximumDetailCount``;
    /// * a repeated signer display field, which would make the displayed order and the
    ///   displayed value ambiguous;
    /// * a signer detail tagged ``ProvenanceDisplayField/assertionLabels``, so
    ///   assertion labels arrive through exactly one field and cannot be counted twice
    ///   against the policy's assertion limit; and
    /// * a repeated assertion label or unsupported feature, which would duplicate a
    ///   displayed row.
    public init?(
        status: ProvenanceValidatorStatusID,
        binding: NormalizedBindingOutcome,
        failedCheck: InvalidityCategory?,
        signerDetails: [NormalizedProvenanceDetail] = [],
        assertionLabels: [DisplaySafeText] = [],
        unsupportedFeatures: [DisplaySafeText] = []
    ) {
        guard signerDetails.count <= Self.maximumDetailCount,
              assertionLabels.count <= Self.maximumDetailCount,
              unsupportedFeatures.count <= Self.maximumDetailCount
        else {
            return nil
        }
        guard signerDetails.allSatisfy({ $0.field != .assertionLabels }) else { return nil }
        guard Set(signerDetails.map(\.field)).count == signerDetails.count else { return nil }
        guard Set(assertionLabels).count == assertionLabels.count else { return nil }
        guard Set(unsupportedFeatures).count == unsupportedFeatures.count else { return nil }
        self.status = status
        self.binding = binding
        self.failedCheck = failedCheck
        self.signerDetails = signerDetails
        self.assertionLabels = assertionLabels
        self.unsupportedFeatures = unsupportedFeatures
    }

    /// Whether this outcome reports any detail at all.
    ///
    /// Used to reject details alongside an `absent` state: no Content Credential was
    /// found, so there is nothing a detail could describe, and presenting one beside
    /// absence would read as evidence (Requirements 6.11 and 7.6).
    public var reportsAnyDetail: Bool {
        !signerDetails.isEmpty || !assertionLabels.isEmpty || !unsupportedFeatures.isEmpty
    }
}
