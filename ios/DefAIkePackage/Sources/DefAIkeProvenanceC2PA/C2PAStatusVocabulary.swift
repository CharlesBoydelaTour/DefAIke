import DefAIkeDomain

// The normalized status key space this adapter emits, and the failure classification
// that goes with it.
//
// ``ProvenanceValidatorStatusID`` is described in the domain as the "normalized,
// vendor-independent status key produced by a provenance validator", and the domain
// deliberately declares no constants for it: "the key space belongs to the approved
// policy". That leaves one thing an adapter must state, and it is stated here: *which
// keys this adapter can emit*, so a policy author can map exactly those and a key the
// policy did not map is a visible gap rather than a silent interpretation.
//
// Two rules keep this from becoming policy:
//
//   * every key maps to a state only through ``ProvenancePolicy/statusMappings``, and
//     nothing in this file names a ``ProvenanceStateKey``; and
//   * a library code is namespaced and otherwise passed through verbatim. It is not
//     grouped, ranked, lowercased, or rewritten, so the policy maps the C2PA
//     specification's own code and an audit can compare the two by string equality.
//
// The failure classification below is a different kind of statement. It answers "which
// of the three kinds of check failed", which Requirement 6.12 fixes as cryptographic,
// structural, or byte-binding. That is a factual property of the C2PA status code, not
// a policy choice — but it is still a normalization decision per code, so the table is
// explicit, closed, and fails closed on anything it does not list. Disagreement between
// this table and an approved fixture is a Provenance Feasibility Gate failure.

// MARK: - Conditions no status code describes

/// A condition of the read itself, which the library reports structurally rather than
/// as a validation status code.
///
/// Each case exists because the alternative is worse: without a key for "no manifest
/// was found", an adapter would have to decide on its own that absence means
/// ``ProvenanceStateKey/absent`` (Requirement 6.11), and without a key for "revocation
/// could not be established offline" it would have to decide what a missing answer
/// means. Both are release decisions, so both are keys the policy maps.
public enum C2PAReaderCondition: String, Hashable, Sendable, CaseIterable {
    /// Every check the validator performed succeeded and no informational condition
    /// qualified the result.
    case allChecksPassed = "all-checks-passed"

    /// The inspected bytes contain no Content Credential (Requirement 6.11).
    case noManifestFound = "no-manifest-found"

    /// A manifest is referenced but not embedded in the inspected bytes.
    ///
    /// Resolving it would require a network fetch, which Requirement 6.8 forbids. The
    /// adapter reports the condition rather than fetching, and the policy decides what
    /// an unresolvable remote manifest means.
    case manifestNotEmbedded = "manifest-not-embedded"

    /// Revocation status could not be established without network access.
    ///
    /// The policy answers this twice — once in ``ProvenanceRevocationBehavior`` and once
    /// in its status mapping — and the adapter requires the two to agree.
    case revocationAnswerUnavailable = "revocation-answer-unavailable"

    /// The validator refused the byte sequence before reaching any validation check.
    case inputNotParsable = "input-not-parsable"

    /// The container is outside the set the validator can read at all.
    case containerNotSupported = "container-not-supported"

    /// The validator produced a manifest but reported no validation result for it.
    case validationResultAbsent = "validation-result-absent"
}

// MARK: - The emitted key space

/// Builds the normalized status keys this adapter emits.
public enum C2PAStatusVocabulary {
    /// Namespace for every key this adapter emits.
    ///
    /// Present so the two families cannot collide and so a policy entry is visibly
    /// scoped to this validator rather than to provenance in general.
    public static let namespace = "c2pa"

    /// The key for a condition of the read.
    ///
    /// Total: every case's raw value is canonical ASCII with `-` separators, so this
    /// never fails.
    public static func statusID(for condition: C2PAReaderCondition) -> ProvenanceValidatorStatusID {
        guard let id = ProvenanceValidatorStatusID(
            "\(namespace).reader.\(condition.rawValue)"
        ) else {
            // Unreachable: `C2PAReaderCondition` raw values are fixed canonical text.
            // Kept as a trap rather than a fallback key, because a fallback would be an
            // unmapped-by-construction key masquerading as a real one.
            preconditionFailure("reader condition keys are canonical by construction")
        }
        return id
    }

    /// The key for a validation status code the library reported.
    ///
    /// `nil` when the library's own spelling is not canonical identifier syntax, which
    /// the adapter reports as a gate finding rather than repairing. C2PA 2.3 status
    /// codes are dotted ASCII tokens and are accepted as written.
    public static func statusID(forLibraryCode code: String) -> ProvenanceValidatorStatusID? {
        ProvenanceValidatorStatusID("\(namespace).status.\(code)")
    }

    /// Every key a policy must map for this adapter's structural conditions.
    ///
    /// The library-code half of the key space is open by nature — the specification
    /// defines the codes, not this module — so completeness of *that* half is a fixture
    /// question for the Provenance Feasibility Gate, not something source can assert.
    public static var readerConditionKeys: [ProvenanceValidatorStatusID] {
        C2PAReaderCondition.allCases.map(statusID(for:))
    }
}

// MARK: - Failure classification

/// Classifies a C2PA failure status code as one of the three kinds of check.
///
/// Explicit and closed. An unlisted code classifies as `nil`, and a `nil` alongside a
/// status the policy maps to `invalid` becomes
/// ``ProvenanceMappingFault/undeterminedInvalidityCategory(status:)`` — a gate finding
/// rather than a guess. `general.error` is deliberately absent for exactly that reason:
/// it is the library's own catch-all and says nothing about which check failed.
public enum C2PAFailureClassification {
    /// Codes reporting that the claim's hard binding to the asset bytes does not hold.
    ///
    /// The hard binding is what ties a claim to *these* bytes, so a failure here is
    /// Requirement 6.12's byte-binding case and must stay separate from a signature
    /// failure: the signature can be perfectly valid over a claim that describes
    /// different bytes.
    static let byteBinding: Set<String> = [
        "assertion.alternativeContentRepresentation.hashMismatch",
        "assertion.bmffHash.mismatch",
        "assertion.boxesHash.mismatch",
        "assertion.boxesHash.unknownBox",
        "assertion.cloud-data.hardBinding",
        "assertion.collectionHash.incorrectFileCount",
        "assertion.collectionHash.mismatch",
        "assertion.dataHash.mismatch",
        "assertion.external-reference.hardBinding",
        "assertion.hardBinding.redacted",
        "assertion.hashedURI.mismatch",
        "assertion.multiAssetHash.mismatch",
        "assertion.multiAssetHash.missingPart",
        "assertion.multipleHardBindings",
        "claim.hardBindings.missing",
        "hashedURI.mismatch",
        "ingredient.hashedURI.mismatch",
    ]

    /// Codes reporting that a signature, credential, or timestamp did not verify.
    static let cryptographic: Set<String> = [
        "algorithm.unsupported",
        "claimSignature.mismatch",
        "claimSignature.missing",
        "claimSignature.outsideValidity",
        "ingredient.claimSignature.mismatch",
        "ingredient.claimSignature.missing",
        "manifest.timestamp.invalid",
        "manifest.timestamp.wrongParents",
        "signingCredential.expired",
        "signingCredential.invalid",
        "signingCredential.ocsp.revoked",
        "signingCredential.revoked",
        "signingCredential.untrusted",
    ]

    /// Codes reporting that the manifest's required structure is malformed, absent, or
    /// inconsistent.
    static let structural: Set<String> = [
        "assertion.action.ingredientMismatch",
        "assertion.action.malformed",
        "assertion.action.missing",
        "assertion.action.redacted",
        "assertion.action.redactionMismatch",
        "assertion.action.softBindingMissing",
        "assertion.alternativeContentRepresentation.malformed",
        "assertion.alternativeContentRepresentation.missing",
        "assertion.bmffHash.malformed",
        "assertion.boxesHash.malformed",
        "assertion.cbor.invalid",
        "assertion.cloud-data.actions",
        "assertion.cloud-data.labelMismatch",
        "assertion.cloud-data.malformed",
        "assertion.collectionHash.invalidURI",
        "assertion.collectionHash.malformed",
        "assertion.dataHash.malformed",
        "assertion.external-reference.actions",
        "assertion.external-reference.created",
        "assertion.external-reference.malformed",
        "assertion.inaccessible",
        "assertion.ingredient.malformed",
        "assertion.json.invalid",
        "assertion.missing",
        "assertion.multiAssetHash.malformed",
        "assertion.notRedacted",
        "assertion.outsideManifest",
        "assertion.selfRedacted",
        "assertion.timestamp.malformed",
        "assertion.undeclared",
        "claim.cbor.invalid",
        "claim.malformed",
        "claim.missing",
        "claim.multiple",
        "hashedURI.missing",
        "ingredient.manifest.mismatch",
        "ingredient.manifest.missing",
        "manifest.compressed.invalid",
        "manifest.inaccessible",
        "manifest.missing",
        "manifest.multipleParents",
        "manifest.update.invalid",
        "manifest.update.wrongParents",
    ]

    /// The kind of check `code` reports, or `nil` when this adapter does not classify it.
    ///
    /// The three tables are disjoint, so the answer does not depend on lookup order.
    public static func category(forLibraryCode code: String) -> InvalidityCategory? {
        if byteBinding.contains(code) { return .byteBinding }
        if cryptographic.contains(code) { return .cryptographic }
        if structural.contains(code) { return .structural }
        return nil
    }
}
