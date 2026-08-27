import DefAIkeDomain
import Foundation

// The manifest-store JSON, projected to the few facts the policy's mapping needs.
//
// The document has already been proved bounded by ``ArtifactEncodingProfile`` before
// this type sees it: within the policy's byte ceiling and nesting depth, valid UTF-8,
// and free of duplicate keys. So the work here is selection, not defence, and every
// field is optional — a shape this projection does not recognize yields no detail rather
// than a substituted one.
//
// Two rules make the selection deterministic, which matters because a validator that
// reports the same manifest as two different states across runs is a Provenance
// Feasibility Gate failure:
//
//   1. The status is chosen by *category precedence*, not by report order. A claim that
//      is not bound to these bytes is the most specific finding about these bytes, so a
//      byte-binding failure outranks a signature failure, which outranks a structural
//      one. Ties break on the smallest code, so the answer never depends on the order
//      the library happened to emit.
//   2. An informational condition that leaves revocation unresolved outranks a clean
//      pass, because a missing revocation answer is not a cryptographic success.
//
// Nothing here names a ``ProvenanceStateKey``.

/// One manifest-store document, projected to bounded vendor-independent facts.
struct C2PAManifestStoreProjection {
    /// Informational codes meaning the revocation question was not answered.
    ///
    /// All three are the C2PA specification's own spellings for "the responder was not
    /// consulted or did not answer". Requirement 6.8 forbids consulting one over the
    /// network, so on this device they are the expected outcome rather than an anomaly —
    /// which is exactly why the policy has to declare what they mean.
    static let revocationGapCodes: Set<String> = [
        "signingCredential.ocsp.inaccessible",
        "signingCredential.ocsp.skipped",
        "signingCredential.ocsp.unknown",
    ]

    /// Success codes reporting that a hard binding over the asset bytes matched.
    static let hardBindingSuccessCodes: Set<String> = [
        "assertion.alternativeContentRepresentation.match",
        "assertion.bmffHash.match",
        "assertion.boxesHash.match",
        "assertion.collectionHash.match",
        "assertion.dataHash.match",
        "assertion.hashedURI.match",
        "assertion.multiAssetHash.match",
    ]

    private let failureCodes: [String]
    private let informationalCodes: [String]
    private let successCodes: [String]
    private let details: [C2PARawDetail]
    private let labels: [String]

    /// Projects `json`, or `nil` when it is not a manifest-store object at all.
    init?(json: String) {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        let active = Self.activeManifest(in: root)
        self.details = Self.signerDetails(in: active)
        self.labels = Self.assertionLabels(in: active)

        let results = Self.statusCodes(in: root, active: active)
        self.failureCodes = results.failure
        self.informationalCodes = results.informational
        self.successCodes = results.success
    }

    // MARK: - The single reported condition

    /// The one condition this read reached.
    var statusFinding: C2PAStatusFinding {
        if let code = firstFailureCode {
            return .libraryStatus(code)
        }
        if informationalCodes.contains(where: Self.revocationGapCodes.contains) {
            return .readerCondition(.revocationAnswerUnavailable)
        }
        if successCodes.isEmpty {
            // A manifest was parsed but nothing was reported about validating it. Not a
            // pass, not a failure, and not absence: the validator produced no result.
            return .readerCondition(.validationResultAbsent)
        }
        return .readerCondition(.allChecksPassed)
    }

    /// The failure code that names this read, chosen deterministically.
    ///
    /// `nil` when no failure was reported. An unclassified failure code is still selected
    /// — last, and only when nothing classified is present — so the policy sees the code
    /// the library actually reported rather than nothing at all.
    var firstFailureCode: String? {
        let ranked = failureCodes.sorted { left, right in
            let leftRank = Self.precedence(of: left)
            let rightRank = Self.precedence(of: right)
            return leftRank == rightRank ? left < right : leftRank < rightRank
        }
        return ranked.first
    }

    /// Category precedence for choosing among several reported failures.
    private static func precedence(of code: String) -> Int {
        switch C2PAFailureClassification.category(forLibraryCode: code) {
        case .byteBinding: 0
        case .cryptographic: 1
        case .structural: 2
        case nil: 3
        }
    }

    /// What the read determined about the hard binding to the inspected bytes.
    ///
    /// Three answers, kept apart: a failed hard binding is `notBound`, a matched hard
    /// binding is `boundToInspectedBytes`, and anything else is `notDetermined`. The last
    /// case is what stops an unbound claim from reaching the validated state — the
    /// vendor-independent mapper refuses `validated` without an established binding.
    var bindingFinding: C2PABindingFinding {
        if failureCodes.contains(where: C2PAFailureClassification.byteBinding.contains) {
            return .notBound
        }
        if !failureCodes.isEmpty {
            return .notDetermined
        }
        if successCodes.contains(where: Self.hardBindingSuccessCodes.contains) {
            return .boundToInspectedBytes
        }
        return .notDetermined
    }

    // MARK: - Bounded details

    /// Signer-side details, at most one per display field.
    ///
    /// ``ProvenanceDisplayField/bindingStatus`` is deliberately not produced here:
    /// ``ValidatedClaimSummary`` already carries the binding as a first-class field, so a
    /// detail row would duplicate it, and composing one would mean this module writing
    /// display text rather than reading a value.
    var signerDetails: [C2PARawDetail] { details }

    /// Assertion labels, in the order the manifest declared them.
    var assertionLabels: [String] { labels }

    /// Features the validator does not support, by name.
    ///
    /// Always empty for this library: `c2pa-swift` 0.0.12 reports unsupportedness through
    /// a validation status code, not by naming the feature, and
    /// ``UnsupportedFeatureSummary/unsupportedFeatures`` explicitly permits an empty list
    /// for exactly that case. Naming one from a status code would be this module
    /// inventing display text for a feature the validator did not name.
    var unsupportedFeatures: [String] { [] }

    // MARK: - Document navigation

    /// The active manifest, whether the document inlines it or names it by label.
    ///
    /// Both shapes appear across specification versions. A label that resolves to nothing
    /// yields no active manifest rather than an empty one, so a detail is absent instead
    /// of blank.
    private static func activeManifest(in root: [String: Any]) -> [String: Any] {
        if let inlined = root["active_manifest"] as? [String: Any] { return inlined }
        if let label = root["active_manifest"] as? String,
           let manifests = root["manifests"] as? [String: Any],
           let named = manifests[label] as? [String: Any] {
            return named
        }
        return [:]
    }

    private static func signerDetails(in manifest: [String: Any]) -> [C2PARawDetail] {
        var details: [C2PARawDetail] = []
        let signature = manifest["signature_info"] as? [String: Any] ?? [:]

        if let issuer = signature["issuer"] as? String {
            details.append(C2PARawDetail(field: .signerIdentity, rawValue: issuer))
        }
        if let generator = claimGenerator(in: manifest) {
            details.append(C2PARawDetail(field: .claimGenerator, rawValue: generator))
        }
        if let time = signature["time"] as? String {
            details.append(C2PARawDetail(field: .validationTime, rawValue: time))
        }
        return details
    }

    /// The claim generator, preferring the structured entry over the legacy string.
    private static func claimGenerator(in manifest: [String: Any]) -> String? {
        if let info = manifest["claim_generator_info"] as? [[String: Any]],
           let name = info.first?["name"] as? String {
            return name
        }
        return manifest["claim_generator"] as? String
    }

    private static func assertionLabels(in manifest: [String: Any]) -> [String] {
        guard let assertions = manifest["assertions"] as? [[String: Any]] else { return [] }
        return assertions.compactMap { $0["label"] as? String }
    }

    /// The three status-code lists, from either the current or the legacy shape.
    ///
    /// The legacy `validation_status` array carried failures only, so it is read as
    /// failures. Reading it as anything else would turn a 1.x failure into a pass.
    private static func statusCodes(
        in root: [String: Any],
        active: [String: Any]
    ) -> (failure: [String], informational: [String], success: [String]) {
        let container = (root["validation_results"] as? [String: Any])
            ?? (active["validation_results"] as? [String: Any])
        if let activeResults = container?["activeManifest"] as? [String: Any] {
            return (
                failure: codes(in: activeResults["failure"]),
                informational: codes(in: activeResults["informational"]),
                success: codes(in: activeResults["success"])
            )
        }
        let legacy = codes(in: root["validation_status"] ?? active["validation_status"])
        return (failure: legacy, informational: [], success: [])
    }

    private static func codes(in value: Any?) -> [String] {
        guard let entries = value as? [[String: Any]] else { return [] }
        return entries.compactMap { $0["code"] as? String }
    }
}
