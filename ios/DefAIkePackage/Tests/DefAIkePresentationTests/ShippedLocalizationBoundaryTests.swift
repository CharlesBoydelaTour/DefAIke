import Foundation
import Testing

@testable import DefAIkePresentation

// English is the only Version 1 user-facing language, and the readiness catalogs are test
// resources.
//
// Requirement 8.18 is a claim about the whole shipping archive, not about one file, so
// these tests ask questions about the checkout rather than about a value:
//
//   * exactly one String Catalog exists under `Sources/`, and it is the presentation
//     module's English one;
//   * no `.lproj` directory exists under `Sources/`, because that is the other way a
//     localization arrives and a value-level check cannot see it;
//   * the four readiness catalogs are inside the test target, which belongs to no product,
//     so nothing linkable into the app or the Share Extension can reach them; and
//   * every readiness language tag carries a BCP 47 private-use subtag, so no readiness
//     file names a locale anyone ships.
//
// The last point is belt and braces on top of the first three: location already makes the
// files unreachable from a product, and the tags make that visible to a reader.
//
// Verified only for what a host can see. Whether the built `.ipa` contains exactly one
// localization is an archive check on a machine with Xcode, and it stays part of the
// release gate rather than being claimed here.

@Suite("English is the only shipped user-facing language")
struct ShippedLocalizationBoundaryTests {

    static func packageRoot() throws -> URL {
        try #require(
            PackageSourceTree.packageRoot,
            "the package source tree is required to check the localization boundary"
        )
    }

    @Test("Exactly one String Catalog exists under Sources, and it is the English one")
    func onlyOneShippedCatalog() throws {
        let root = try Self.packageRoot()
        let catalogs = PackageSourceTree.stringCatalogs(under: root.appending(path: "Sources"))

        #expect(catalogs.count == 1, "\(catalogs.map(\.lastPathComponent))")
        #expect(
            catalogs.first?.path
                == root.appending(path: PackageSourceTree.shippedCatalogRelativePath).path
        )
    }

    @Test("No shipping module carries an lproj localization directory")
    func noShippedLprojDirectory() throws {
        let root = try Self.packageRoot()
        let directories = PackageSourceTree.localizationDirectories(
            under: root.appending(path: "Sources")
        )

        #expect(directories.isEmpty, "\(directories.map(\.lastPathComponent))")
    }

    @Test("The shipped catalog declares English and nothing else")
    func shippedCatalogIsEnglishOnly() throws {
        let catalog = try EnglishStringCatalog.loadShippedCatalog()

        #expect(catalog.languageTags == [EnglishStringCatalog.requiredLanguageTag])
    }

    @Test("Every readiness catalog lives inside the test target")
    func readinessCatalogsAreTestResources() throws {
        let root = try Self.packageRoot()
        let expected = root.appending(path: PackageSourceTree.readinessCatalogRelativePath)

        for variant in LocalizationReadinessVariant.allCases {
            let url = expected
                .appending(path: variant.resourceName)
                .appendingPathExtension(EnglishStringCatalog.resourceExtension)
            #expect(
                FileManager.default.fileExists(atPath: url.path),
                "\(variant.rawValue) is missing from \(expected.lastPathComponent)"
            )
        }

        // No readiness catalog anywhere else, so a copy cannot drift into a shipping
        // target unnoticed.
        let testCatalogs = PackageSourceTree.stringCatalogs(under: root.appending(path: "Tests"))
        let directories = Set(testCatalogs.map { $0.deletingLastPathComponent().path })
        #expect(directories == [expected.path], "\(testCatalogs.map(\.path))")
        #expect(testCatalogs.count == LocalizationReadinessVariant.allCases.count)
    }

    @Test("Every readiness language tag is private use and is not English")
    func readinessTagsArePrivateUse() {
        for variant in LocalizationReadinessVariant.allCases {
            let tag = variant.languageTag
            #expect(tag.contains("-x-"), "\(tag)")
            #expect(tag != EnglishStringCatalog.requiredLanguageTag, "\(tag)")
        }
    }

    @Test("No readiness language tag appears in the shipped catalog")
    func readinessTagsAreAbsentFromTheShippedCatalog() throws {
        let shipped = try EnglishStringCatalog.loadShippedCatalog().languageTags

        for variant in LocalizationReadinessVariant.allCases {
            #expect(shipped.contains(variant.languageTag) == false, "\(variant.languageTag)")
        }
    }
}
