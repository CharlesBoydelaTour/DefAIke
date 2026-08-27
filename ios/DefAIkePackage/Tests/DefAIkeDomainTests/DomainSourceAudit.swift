import Foundation

// Reading the domain's own declarations, so a "for every X" claim stays true.
//
// Two test registries enumerate the domain by hand: every closed string vocabulary,
// and every versioned release artifact. A hand-written registry rots silently — a new
// enum or a new artifact is simply never exercised, and the sweep still reports
// success over the old list. These helpers close that gap by comparing each registry
// against the declarations in `Sources/DefAIkeDomain`.
//
// This is a coverage audit, not a parser. It matches declaration lines the domain
// actually uses, and it fails closed: a missing source tree is an error rather than
// "nothing to check".
enum DomainSources {

    enum AuditError: Error, CustomStringConvertible {
        case sourcesNotFound(path: String)

        var description: String {
            switch self {
            case .sourcesNotFound(let path): return "domain sources not found at \(path)"
            }
        }
    }

    /// `Sources/DefAIkeDomain`, located relative to a test source file.
    ///
    /// Deriving the path from the caller's file rather than the working directory keeps
    /// the audit working from any checkout and under any test runner.
    static func directory(from file: String) throws -> URL {
        let sources = URL(fileURLWithPath: file)
            .deletingLastPathComponent()  // DefAIkeDomainTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // DefAIkePackage
            .appendingPathComponent("Sources/DefAIkeDomain")

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: sources.path,
            isDirectory: &isDirectory
        )
        guard exists, isDirectory.boolValue else {
            throw AuditError.sourcesNotFound(path: sources.path)
        }
        return sources
    }

    /// The text of every Swift file under the domain sources.
    static func swiftFileContents(from file: String) throws -> [String] {
        let sources = try directory(from: file)
        guard
            let enumerator = FileManager.default.enumerator(
                at: sources,
                includingPropertiesForKeys: nil
            )
        else {
            throw AuditError.sourcesNotFound(path: sources.path)
        }
        var contents: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            contents.append(try String(contentsOf: url, encoding: .utf8))
        }
        return contents
    }

    /// Every `public enum X: String` name the domain declares, nested ones included.
    static func closedStringVocabularyNames(from file: String) throws -> Set<String> {
        let declaration = /public enum ([A-Za-z0-9_]+): String\b/
        var names: Set<String> = []
        for text in try swiftFileContents(from: file) {
            for match in text.matches(of: declaration) {
                names.insert(String(match.1))
            }
        }
        return names
    }

    /// Every type that declares `public let <member>: <type>`, keyed by that type.
    ///
    /// The enclosing type is the nearest preceding public type declaration, which is
    /// how the domain sources are laid out: one member per line, and no member
    /// declared before its type.
    static func typesDeclaring(
        member: String,
        from file: String
    ) throws -> [String: Set<String>] {
        let typeDeclaration = /public (?:struct|final class|actor|enum) ([A-Za-z0-9_]+)/
        let prefix = "public let \(member): "

        var owners: [String: Set<String>] = [:]
        for text in try swiftFileContents(from: file) {
            var enclosing: String?
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                if let match = line.firstMatch(of: typeDeclaration) {
                    enclosing = String(match.1)
                }
                guard let declared = line.range(of: prefix), let owner = enclosing else {
                    continue
                }
                let type = line[declared.upperBound...]
                    .prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                owners[String(type), default: []].insert(owner)
            }
        }
        return owners
    }
}
