import Foundation

// Locates the package's own source tree so a test can read a resource as authored.
//
// Every other test in this target works on values. These localization tests also have to
// answer questions about *files*: is there exactly one String Catalog under `Sources/`,
// are the Localization Readiness catalogs outside every shipping target, is there a
// stray `.lproj` directory. Those are facts about the checkout, and Requirement 8.18 -
// English is the only Version 1 user-facing language - is a fact of exactly that kind.
// A value-level test cannot see a second catalog that nobody imported yet.
//
// The root is found by walking up from this file to the directory holding
// `Package.swift`, so it does not depend on the working directory a test runner chose.
// When the walk fails the tests fail: a missing source tree means the question was not
// answered, and a skipped boundary check is indistinguishable from a passing one.

enum PackageSourceTree {
    /// The directory holding `Package.swift`, or `nil` when this file is not inside a
    /// package checkout.
    static let packageRoot: URL? = {
        var directory = URL(filePath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let manifest = directory.appending(path: "Package.swift")
            if FileManager.default.fileExists(atPath: manifest.path) {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }()

    /// Path of the one String Catalog the presentation module ships, relative to the
    /// package root.
    static let shippedCatalogRelativePath =
        "Sources/DefAIkePresentation/ApprovedCopy/Localizable.xcstrings"

    /// Directory holding the Localization Readiness Suite catalogs, relative to the
    /// package root.
    static let readinessCatalogRelativePath =
        "Tests/DefAIkePresentationTests/Resources/LocalizationReadiness"

    /// Every `.xcstrings` file under `directory`, sorted by path.
    static func stringCatalogs(under directory: URL) -> [URL] {
        files(under: directory) { $0.pathExtension == "xcstrings" }
    }

    /// Every `.lproj` directory under `directory`, sorted by path.
    ///
    /// A `.lproj` is the other way a localization arrives, so "one catalog with one
    /// language" is only half the check.
    static func localizationDirectories(under directory: URL) -> [URL] {
        files(under: directory) { $0.pathExtension == "lproj" }
    }

    private static func files(
        under directory: URL,
        matching predicate: (URL) -> Bool
    ) -> [URL] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: nil
            )
        else {
            return []
        }
        return enumerator
            .compactMap { $0 as? URL }
            .filter(predicate)
            .sorted { $0.path < $1.path }
    }
}
