@testable import DefAIkeDomain

// Two structural audits over the domain's session values, and the reflection walk
// they share.
//
// The presentation module has its own probability-free audit over presentation models
// (`DefAIkePresentationTests/ProhibitedClaimAudit.swift`). That one cannot see the
// domain: it is generic over a presentation marker protocol, and it runs in a
// different test target. But a probability that never reaches a presentation model
// because no domain value can hold one is a stronger guarantee than a probability
// filtered out on the way to the screen, so the same question has to be asked one
// layer down.
//
// Scope is deliberate and narrow: these audits cover the **session value graph** —
// what one Analysis Session produces and what crosses the handoff boundary. They do
// not cover the release-artifact layer, which legitimately carries exact decimals: a
// Calibration Policy holds a false-accusation budget and a predeclared confidence
// level, and a Resource Budget holds measured numeric limits. Those are approved
// release inputs, never user-facing result fields. `ProhibitedMagnitudeAudit` is sharp
// enough to flag them, which is exactly why its scope is stated rather than assumed.

/// A depth-bounded reflection walk over a value graph.
enum DomainValueWalk {
    /// Depth ceiling for the walk. Session values are shallow value trees; the bound
    /// only stops a pathological graph from hanging a test.
    static let maximumDepth = 12

    /// Types walked as opaque leaves.
    ///
    /// `Date` is here because Foundation reflects it as a stored
    /// `timeIntervalSinceReferenceDate` double. A wall-clock instant recorded for
    /// lifecycle evaluation is not a result magnitude, and descending into
    /// Foundation's storage detail would report one on every timestamp.
    static let opaqueLeafTypeNames: Set<String> = ["Date"]

    /// Calls `body` for the root and for every reachable child, with a dotted path.
    ///
    /// An optional is looked through at the same path, so a wrapped value is reported
    /// under its field's own name rather than as `field.some`.
    static func visit(
        _ root: Any,
        rootName: String,
        _ body: (_ path: String, _ value: Any) -> Void
    ) {
        walk(root, path: rootName, depth: 0, body)
    }

    private static func walk(
        _ value: Any,
        path: String,
        depth: Int,
        _ body: (String, Any) -> Void
    ) {
        guard depth < maximumDepth else { return }
        body(path, value)

        if isOpaqueLeaf(value) { return }

        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let wrapped = mirror.children.first?.value else { return }
            walk(wrapped, path: path, depth: depth + 1, body)
            return
        }
        for child in mirror.children {
            let label = child.label ?? "<unlabeled>"
            walk(child.value, path: "\(path).\(label)", depth: depth + 1, body)
        }
    }

    private static func isOpaqueLeaf(_ value: Any) -> Bool {
        !typeNameTokens(of: type(of: value)).isDisjoint(with: opaqueLeafTypeNames)
    }

    /// Every identifier in a fully qualified type name.
    ///
    /// A declared type is what matters, not a runtime value, so an `Optional<Double>`
    /// that happens to be `nil` still has to be recognised. Reflection reports it as
    /// `Swift.Optional<Swift.Double>`, an array of them as
    /// `Swift.Array<Swift.Optional<Swift.Double>>`, and — on Darwin — a `Decimal` as
    /// `__C.NSDecimal`. Splitting the name into identifiers recognises all of those,
    /// while a name that merely *ends* in a magnitude type, such as
    /// `PositiveDecimal`, is left to be reported through the stored `Decimal` it
    /// wraps rather than twice.
    static func typeNameTokens(of type: Any.Type) -> Set<String> {
        Set(
            String(reflecting: type)
                .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") })
                .map(String.init)
        )
    }

    /// `Foundation.Date` becomes `Date`; `DefAIkeDomain.PixelEvidence` becomes
    /// `PixelEvidence`. For naming a walk's root only.
    static func simpleTypeName(of type: Any.Type) -> String {
        let qualified = String(reflecting: type)
        guard let separator = qualified.lastIndex(of: ".") else { return qualified }
        return String(qualified[qualified.index(after: separator)...])
    }
}

/// Reports any field that could carry a result magnitude, or is named as one.
///
/// Requirements 8.9 and 8.13 forbid a probability, confidence value or level,
/// percentage, score, or raw logit on any user-facing surface. The enforcement is
/// structural rather than editorial: a domain session value has no field such a
/// number could occupy. A doc comment cannot hold that line, so this walks a value's
/// stored properties and reports every field that could.
///
/// It flags floating-point and `Decimal` fields anywhere in a value graph, because
/// those are the shapes a probability, confidence, percentage, or logit arrives in.
/// It does not flag integers: a recorded pixel dimension and a byte count are
/// measurements rather than result magnitudes, and banning them would push real data
/// into looser types.
enum ProhibitedMagnitudeAudit {
    /// Name fragments that mark a field as a result magnitude, matched
    /// case-insensitively. Kept aligned with the presentation audit's list so the two
    /// layers ban the same vocabulary.
    static let prohibitedNameFragments = [
        "probab",
        "confidence",
        "certainty",
        "percent",
        "score",
        "logit",
        "likelihood",
        "chance",
    ]

    /// Scalar type names that carry a result magnitude.
    ///
    /// `NSDecimal` is here because that is the name reflection reports for a
    /// Foundation `Decimal` on Darwin. Without it, the one numeric type an approved
    /// artifact actually uses would slip past.
    static let magnitudeTypeNames: Set<String> = [
        "Double",
        "Float",
        "Float16",
        "Float80",
        "CGFloat",
        "Decimal",
        "NSDecimal",
    ]

    struct Finding: Hashable, CustomStringConvertible {
        let path: String
        let reason: String

        var description: String { "\(path): \(reason)" }
    }

    /// Every finding reachable from `value`, without repeats.
    static func findings(in value: Any, named name: String? = nil) -> [Finding] {
        let rootName = name ?? DomainValueWalk.simpleTypeName(of: type(of: value))
        var seen: Set<Finding> = []
        var ordered: [Finding] = []

        DomainValueWalk.visit(value, rootName: rootName) { path, child in
            let matched = DomainValueWalk.typeNameTokens(of: type(of: child))
                .intersection(magnitudeTypeNames)
                .sorted()
            if let typeName = matched.first {
                let finding = Finding(
                    path: path,
                    reason: """
                        \(typeName) is how a probability, confidence, percentage, score, \
                        or raw logit arrives
                        """
                )
                if seen.insert(finding).inserted { ordered.append(finding) }
            }
            guard let field = path.components(separatedBy: ".").last else { return }
            if let fragment = prohibitedNameFragments.first(where: {
                field.lowercased().contains($0)
            }) {
                let finding = Finding(
                    path: path,
                    reason: "field name contains the prohibited fragment '\(fragment)'"
                )
                if seen.insert(finding).inserted { ordered.append(finding) }
            }
        }
        return ordered
    }
}

/// Reports any evidence value reachable from a non-completed terminal outcome.
///
/// Requirement 11.18: an Analysis Error is presented with a recovery action and *no*
/// Pixel Evidence, Provenance Evidence, or Combined Summary. The domain makes that
/// structural — a failure snapshot has no evidence field and a cancelled outcome has
/// no payload at all — so the check is for reachability rather than for a value being
/// blank.
enum EvidenceReachabilityAudit {
    /// Type names that carry, or are part of, an evidence verdict.
    static let evidenceTypeNames: Set<String> = [
        "EvidenceReport",
        "PixelEvidence",
        "ProvenanceLane",
        "ProvenanceEvidence",
        "ProvenanceCategory",
        "CombinedSummary",
        "ValidatedClaimSummary",
        "InvaliditySummary",
        "UnsupportedFeatureSummary",
        "IndeterminateSummary",
        "EvidenceScope",
    ]

    /// Paths at which an evidence value is reachable from `value`, without repeats.
    ///
    /// Declared types count, so a field that could hold a Combined Summary is reported
    /// even when it holds nothing. The requirement is about shape: a failure has no
    /// evidence field, rather than an evidence field left blank.
    static func evidencePaths(in value: Any, named name: String? = nil) -> [String] {
        let rootName = name ?? DomainValueWalk.simpleTypeName(of: type(of: value))
        var seen: Set<String> = []
        var found: [String] = []
        DomainValueWalk.visit(value, rootName: rootName) { path, child in
            let tokens = DomainValueWalk.typeNameTokens(of: type(of: child))
            guard !tokens.isDisjoint(with: evidenceTypeNames) else { return }
            if seen.insert(path).inserted { found.append(path) }
        }
        return found
    }
}
