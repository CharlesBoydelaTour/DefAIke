import Foundation

@testable import DefAIkePresentation

// The executable form of "the forbidden controls are absent from the type".
//
// ``ExcludedResultControl`` names seven affordances Version 1 does not have. The claim it
// makes is not "we do not render them" - it is "there is no member they could hang from".
// A doc comment cannot enforce that, and neither can a code review of a diff that adds
// one innocuous-looking property, so this walks a model's stored properties by reflection
// and reports any field named as one of them.
//
// It sits in the test target for the same reason ``ProhibitedClaimAudit`` does: the
// guarantee is structural, and a release build should not carry reflection code to
// re-check its own shape.
//
// Two deliberate choices about the fragment list, both of which matter:
//
//   * **No bare `copy`.** Approved copy is addressed by reference throughout this module,
//     so `labelCopy`, `stateCopy`, `scopeCopy`, and `summaryCopy` are all correct field
//     names. Matching `copy` alone would flag every one of them and the only way to keep
//     the audit green would be to weaken it. The result-affordance spellings are matched
//     instead: `pasteboard`, `clipboard`, `copyResult`, `copyable`.
//   * **No bare `share`.** For the same reason: the Share Extension route is a legitimate
//     part of the vocabulary. `shareResult`, `shareSheet`, `shareAction`, `activityItem`,
//     and `shareable` are matched instead.
//
// Labels are normalized to lowercase alphanumerics before matching, so `shareResult`,
// `share_result`, and `shareresult` are the same name to this audit.
//
// The reflection walk sees stored properties, not methods, so a `func exportResult()`
// would slip past it. The comment-stripped source sweep in
// ``ForbiddenControlSourceAudit`` is the backstop for that: it reads the module's own
// sources for the framework entry points such an affordance would have to go through.
// Comments are stripped first, because this file and the module's own documentation both
// have to be able to say what is forbidden without tripping the check.

enum ForbiddenControlAudit {

    struct Finding: Hashable, CustomStringConvertible {
        let path: String
        let control: ExcludedResultControl
        let fragment: String

        var description: String {
            """
            \(path): '\(fragment)' could carry \(control.rawValue), \
            forbidden by Requirement \(control.forbiddenBy)
            """
        }
    }

    /// Field-name fragments that mark a member as one of the excluded affordances.
    static let prohibitedFragments: [(fragment: String, control: ExcludedResultControl)] = [
        ("history", .analysisHistory),
        ("previousresult", .analysisHistory),
        ("priorresult", .analysisHistory),
        ("recentresult", .analysisHistory),
        ("sessionlog", .analysisHistory),

        ("save", .saveResult),
        ("persist", .saveResult),
        ("bookmark", .saveResult),
        ("favorite", .saveResult),

        ("export", .exportResult),
        ("download", .exportResult),
        ("serialize", .exportResult),
        ("writeto", .exportResult),

        ("pasteboard", .copyResult),
        ("clipboard", .copyResult),
        ("copyresult", .copyResult),
        ("copyable", .copyResult),

        ("shareresult", .shareResult),
        ("sharesheet", .shareResult),
        ("shareaction", .shareResult),
        ("activityitem", .shareResult),
        ("shareable", .shareResult),
    ]

    /// Depth ceiling for the reflection walk, matching ``ProhibitedClaimAudit``.
    static let maximumDepth = 8

    /// Every forbidden-control finding in `model`, in encounter order without repeats.
    static func findings<Model: ProbabilityFreePresentationModel>(in model: Model) -> [Finding] {
        var seen: Set<Finding> = []
        var ordered: [Finding] = []
        for finding in walk(model, path: "\(Model.self)", depth: 0)
        where seen.insert(finding).inserted {
            ordered.append(finding)
        }
        return ordered
    }

    /// A label reduced to lowercase alphanumerics, so separator style does not matter.
    static func normalized(_ label: String) -> String {
        label.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func walk(_ value: Any, path: String, depth: Int) -> [Finding] {
        guard depth < maximumDepth else { return [] }

        let mirror = Mirror(reflecting: value)

        // Look through an optional at the same path, so a wrapped value is reported once
        // and under the field's own name.
        if mirror.displayStyle == .optional {
            guard let wrapped = mirror.children.first?.value else { return [] }
            return walk(wrapped, path: path, depth: depth + 1)
        }

        var found: [Finding] = []
        for child in mirror.children {
            let label = child.label ?? "<unlabeled>"
            let childPath = "\(path).\(label)"
            let name = normalized(label)

            for entry in prohibitedFragments where name.contains(entry.fragment) {
                found.append(
                    Finding(path: childPath, control: entry.control, fragment: entry.fragment)
                )
            }
            found += walk(child.value, path: childPath, depth: depth + 1)
        }
        return found
    }
}

// MARK: - Module source sweep

/// Reads the presentation module's own sources for the framework entry points a forbidden
/// affordance would have to go through.
///
/// The reflection audit sees stored properties. A control is also reachable through a
/// method, a view modifier, or a toolbar item, and none of those is a stored property. So
/// this asks a question about the *files*: does the module mention a pasteboard, a share
/// sheet, a file exporter, an archiver, a persistent store, or a network session at all.
///
/// Comments are stripped before matching. Both this file and the module's own
/// documentation have to be able to name what is excluded, and an audit that a doc comment
/// can fail is an audit that gets weakened rather than obeyed.
enum ForbiddenControlSourceAudit {

    /// Framework entry points a save, export, copy, share, history, or telemetry
    /// affordance would need. None of these is a plausible legitimate use in a module
    /// whose whole output is immutable view state over domain values.
    static let prohibitedTokens = [
        "UIPasteboard",
        "NSPasteboard",
        "ShareLink",
        "UIActivityViewController",
        "activityItems",
        "fileExporter",
        "NSKeyedArchiver",
        "NSKeyedUnarchiver",
        "UserDefaults",
        "NSPersistentContainer",
        "SwiftData",
        "URLSession",
        "URLRequest",
    ]

    /// The module's Swift sources, recursively, or `nil` when the checkout cannot be
    /// located.
    ///
    /// Recursive on purpose: the module has subdirectories, and a non-recursive listing
    /// would pass by reading nothing.
    static func moduleSources() -> [URL]? {
        guard let root = PackageSourceTree.packageRoot else { return nil }
        let directory = root.appending(path: "Sources/DefAIkePresentation")
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: nil
            )
        else {
            return nil
        }
        return enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
    }

    /// Removes `//` comment text so the sweep reads code rather than documentation.
    ///
    /// No source in this module puts `//` inside a string literal, and the sweep asserts
    /// the absence of tokens that would never appear in one, so a line-wise split is
    /// enough.
    static func strippingComments(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let marker = line.range(of: "//") else { return String(line) }
                return String(line[line.startIndex..<marker.lowerBound])
            }
            .joined(separator: "\n")
    }

    struct Finding: Hashable, CustomStringConvertible {
        let file: String
        let token: String

        var description: String { "\(file) mentions \(token)" }
    }

    /// Every prohibited token found in the module's comment-stripped sources.
    static func findings(in sources: [URL]) throws -> [Finding] {
        var found: [Finding] = []
        for url in sources {
            let code = strippingComments(try String(contentsOf: url, encoding: .utf8))
            for token in prohibitedTokens where code.contains(token) {
                found.append(Finding(file: url.lastPathComponent, token: token))
            }
        }
        return found
    }
}
