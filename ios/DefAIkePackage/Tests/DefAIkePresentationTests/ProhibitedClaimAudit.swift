import Foundation

@testable import DefAIkePresentation

// The executable form of the probability-free contract.
//
// ``ProbabilityFreePresentationModel`` states that no presentation model has a field a
// prohibited claim could occupy. A doc comment cannot enforce that, so this audit walks
// a model's stored properties by reflection and reports any field that could carry a
// result magnitude or that is named as one.
//
// It lives in the test target rather than in the shipping module: the guarantee is
// structural, and a release build should not carry reflection code to re-check its own
// shape. Spec task 11.7's Property 23 uses the same audit over generated reports.
//
// The audit checks declared field types rather than only runtime values, so an
// `Optional<Double>` that happens to be `nil` is still reported. It is deliberately
// conservative in one direction only: it flags floating-point and `Decimal` fields
// anywhere in a model's value graph, because those are the shapes a probability,
// confidence, percentage, or logit arrives in. It does not flag integers, because a
// recorded pixel dimension and a byte count are measurements rather than result
// magnitudes, and banning them would push real data into looser types.

enum ProhibitedClaimAudit {
    /// Name fragments that mark a field as a result magnitude, matched
    /// case-insensitively against the property label.
    ///
    /// Every ``ProhibitedPresentationClaim`` category with a conventional field name
    /// appears here, so `probabilityOfAI`, `confidenceLevel`, and `rawLogit` are all
    /// caught by a fragment rather than needing an exact name.
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
    static let magnitudeTypeNames = [
        "Double",
        "Float",
        "Float16",
        "Float80",
        "CGFloat",
        "Decimal",
    ]

    /// Depth ceiling for the reflection walk. Presentation models are shallow value
    /// trees; the bound only stops a pathological graph from hanging a test.
    static let maximumDepth = 8

    struct Finding: Hashable, CustomStringConvertible {
        let path: String
        let reason: String

        var description: String { "\(path): \(reason)" }
    }

    /// Every prohibited-claim finding in `model`, in encounter order without repeats.
    static func findings<Model: ProbabilityFreePresentationModel>(in model: Model) -> [Finding] {
        var seen: Set<Finding> = []
        var ordered: [Finding] = []
        for finding in walk(model, path: "\(Model.self)", depth: 0)
        where seen.insert(finding).inserted {
            ordered.append(finding)
        }
        return ordered
    }

    private static func walk(_ value: Any, path: String, depth: Int) -> [Finding] {
        guard depth < maximumDepth else { return [] }

        var found: [Finding] = []
        if let reason = magnitudeReason(for: value) {
            found.append(Finding(path: path, reason: reason))
        }

        let mirror = Mirror(reflecting: value)

        // Look through an optional at the same path, so a wrapped value is reported
        // once and under the field's own name rather than as `field.some`.
        if mirror.displayStyle == .optional {
            guard let wrapped = mirror.children.first?.value else { return found }
            return found + walk(wrapped, path: path, depth: depth + 1)
        }

        for child in mirror.children {
            let label = child.label ?? "<unlabeled>"
            let childPath = "\(path).\(label)"

            if let fragment = prohibitedNameFragments.first(where: {
                label.lowercased().contains($0)
            }) {
                found.append(
                    Finding(
                        path: childPath,
                        reason: "field name contains the prohibited fragment '\(fragment)'"
                    )
                )
            }
            found += walk(child.value, path: childPath, depth: depth + 1)
        }
        return found
    }

    /// Why `value`'s declared type carries a result magnitude, or `nil` when it does not.
    private static func magnitudeReason(for value: Any) -> String? {
        let typeName = String(reflecting: type(of: value))
        guard
            let matched = magnitudeTypeNames.first(where: { name in
                typeName.range(of: "\\b\(name)\\b", options: .regularExpression) != nil
            })
        else {
            return nil
        }
        return """
            \(matched) is how a probability, confidence, percentage, score, or raw logit \
            arrives
            """
    }
}
