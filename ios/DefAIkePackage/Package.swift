// swift-tools-version: 6.1
//
// DefAIke iOS module graph.
//
// This package owns every reusable module in the `ios-app` design's
// "Xcode targets and module layout" table. The two shipping executables
// (`DefAIkeApp` and `DefAIkeShareExtension`) live in the Xcode project
// generated from `ios/project.yml`; they are thin shells that link exactly one
// composition product from this package.
//
// DefAIke ships one application composition. It compiles both Version 1 evidence
// capabilities — pixel analysis and Content Credential validation — so a single
// installed app carries both source lanes rather than splitting them across two
// signed archives. Compiling the validator is not approval to use it: the signed
// Release Capability Manifest, the Provenance Feasibility Gate, and
// `ProvenanceLaneProvider.resolve(...)` each have to agree before a validator is
// reachable, and any one of them short of that is the unavailable lane.
//
// Dependency rules enforced here and re-checked by
// `ios/Scripts/check-module-boundaries.py`:
//
//   * `DefAIkeDomain` has no target dependencies (pure core).
//   * The Share Extension composition links only `DefAIkeDomain` and
//     `DefAIkeSharedTransfer`; no inference, model-bundle, image-pipeline, or
//     provenance module is reachable from it. This is the negative case that keeps
//     the application composition's positive linkage measurement non-vacuous now
//     that no second application archive supplies one.
//   * `DefAIkeProvenanceC2PA` is reachable only from `DefAIkeAppKit`.
//   * `DefAIkeReleaseValidation` is not part of any shipping composition.
//   * `PropertyBased` (swift-property-based) is referenced only by test targets.

import PackageDescription

/// Modules the application composition links regardless of capability.
///
/// Separate from the conditional adapter below so the one module whose presence is a
/// capability claim stays visible at the composition's declaration site.
let sharedAppModules: [String] = [
    "DefAIkeDomain",
    "DefAIkeSharedTransfer",
    "DefAIkeApplication",
    "DefAIkeImagePipeline",
    "DefAIkeModelBundle",
    "DefAIkeCoreML",
    "DefAIkeProvenanceAPI",
    "DefAIkePresentation",
]

/// Test-only property-based testing library, exact-pinned per the design.
let propertyBased = Target.Dependency.product(
    name: "PropertyBased",
    package: "swift-property-based"
)

/// The reviewed Content Credential validator, exact-pinned per the design.
///
/// Reachable from `DefAIkeProvenanceC2PA` only. Ships a large native XCFramework and
/// pulls in transitive cryptography (`swift-certificates`, `swift-asn1`,
/// `swift-crypto`), all of which the Provenance Feasibility Gate reviews.
let contentCredentials = Target.Dependency.product(
    name: "C2PA",
    package: "c2pa-swift"
)

let package = Package(
    name: "DefAIkePackage",
    platforms: [
        // Shipping minimum (Requirements 1.2 and 4.2). The Xcode app and
        // extension targets set the same value and are iPhone-only.
        .iOS(.v17),
        // Development and test host only. No DefAIke product is distributed
        // for macOS; host results are development checks, never physical-device
        // release evidence.
        .macOS(.v14),
    ],
    products: [
        // The application composition. Compiles both evidence capabilities: pixel
        // analysis, and Content Credential validation through the conditional
        // provenance adapter.
        //
        // Linking the adapter is what makes the provenance lane *possible*, and
        // nothing more. Producing provenance evidence additionally requires the
        // Provenance Feasibility Gate to pass and the signed Release Capability
        // Manifest to enable the capability, bind the policy version, and name this
        // exact adapter release.
        .library(
            name: "DefAIkeAppKit",
            targets: sharedAppModules + ["DefAIkeProvenanceC2PA"]
        ),
        // Share Extension composition: staging and transfer only.
        .library(
            name: "DefAIkeShareExtensionKit",
            targets: ["DefAIkeDomain", "DefAIkeSharedTransfer"]
        ),
        // Nonshipping release tooling, linked only by test and tool targets.
        .library(
            name: "DefAIkeReleaseValidation",
            targets: ["DefAIkeReleaseValidation"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/x-sheep/swift-property-based.git",
            exact: "2.0.0"
        ),
        // The reviewed Content Credential validator, exact-pinned to the release the
        // design names. Referenced by `DefAIkeProvenanceC2PA` alone, so it is absent
        // from the Share Extension composition's module closure.
        //
        // Exact-pinning this dependency is not approval to enable the capability: the
        // Provenance Feasibility Gate (implementation feasibility, correctness fixtures,
        // resource limits, security and dependency review, and physical-device
        // validation) is separate, and `ProvenanceLaneProvider` additionally requires an
        // exact match against the signed Release Capability Manifest.
        .package(
            url: "https://github.com/contentauth/c2pa-swift.git",
            exact: "0.0.12"
        ),
    ],
    targets: [
        // MARK: - Domain core

        .target(
            name: "DefAIkeDomain",
            dependencies: []
        ),

        // MARK: - Shared transfer (app + extension)

        .target(
            name: "DefAIkeSharedTransfer",
            dependencies: ["DefAIkeDomain"]
        ),

        // MARK: - Application orchestration

        .target(
            name: "DefAIkeApplication",
            dependencies: ["DefAIkeDomain", "DefAIkeProvenanceAPI"]
        ),

        // MARK: - Platform adapters

        .target(
            name: "DefAIkeImagePipeline",
            dependencies: ["DefAIkeDomain"]
        ),
        .target(
            name: "DefAIkeModelBundle",
            dependencies: ["DefAIkeDomain"]
        ),
        .target(
            name: "DefAIkeCoreML",
            dependencies: ["DefAIkeDomain"]
        ),
        .target(
            name: "DefAIkeProvenanceAPI",
            dependencies: ["DefAIkeDomain"]
        ),
        .target(
            name: "DefAIkeProvenanceC2PA",
            dependencies: ["DefAIkeDomain", "DefAIkeProvenanceAPI", contentCredentials]
        ),

        // MARK: - Presentation

        // The English String Catalog is carried verbatim rather than compiled into a
        // localization table. A localized-string lookup that misses returns the key, and
        // `ResolvedCopyReference` forbids ever showing a raw key to a user, so the
        // catalog is parsed and validated and a missing value is a release-validation
        // failure. `.process` would compile it away, and so — measured, not assumed —
        // does `.copy` on the file itself: under Xcode a `.xcstrings` named in a resource
        // phase is claimed by the String Catalog compiler whatever rule declared it, and
        // the built bundle receives `en.lproj/Localizable.strings` with the review states
        // and comments discarded. `EnglishStringCatalog.loadShippedCatalog()` then fails,
        // and startup blocks with `approvedCopyUnreadable`.
        //
        // So the *directory* is copied rather than the file. A directory resource is an
        // opaque copy under both build systems: SwiftPM and Xcode both place it in the
        // bundle unchanged, and neither recurses into it looking for a file type to
        // compile. The catalog keeps its `.xcstrings` name and stays editable in Xcode's
        // String Catalog editor; what changes is that it is addressed through a
        // subdirectory at runtime.
        //
        // The directory is `ApprovedCopy` and deliberately not `Resources`. A `.bundle`
        // whose top level contains a directory named `Resources` reads to `codesign` as a
        // framework-style bundle, which then expects `Contents/Info.plist` and refuses the
        // whole bundle with "bundle format unrecognized, invalid, or unsuitable" — measured,
        // not assumed. That breaks every signed build, so the name matters as much as the
        // choice to copy a directory at all.
        .target(
            name: "DefAIkePresentation",
            dependencies: ["DefAIkeDomain"],
            resources: [.copy("ApprovedCopy")]
        ),

        // MARK: - Nonshipping release tooling

        .target(
            name: "DefAIkeReleaseValidation",
            dependencies: ["DefAIkeDomain", "DefAIkeModelBundle"]
        ),

        // MARK: - Nonshipping test support

        // Bounded in-memory fakes and call spies for every application port. It
        // belongs to no product, so it cannot be linked into the app, the Share
        // Extension, or the application composition; only test targets may depend
        // on it, and `check-module-boundaries.py` enforces both rules.
        .target(
            name: "DefAIkeTestSupport",
            dependencies: ["DefAIkeDomain"]
        ),

        // MARK: - Tests

        .testTarget(
            name: "DefAIkeDomainTests",
            dependencies: ["DefAIkeDomain", "DefAIkeTestSupport", propertyBased]
        ),
        .testTarget(
            name: "DefAIkeTestSupportTests",
            dependencies: ["DefAIkeTestSupport", "DefAIkeDomain", propertyBased]
        ),
        .testTarget(
            name: "DefAIkeSharedTransferTests",
            dependencies: ["DefAIkeSharedTransfer", "DefAIkeDomain", propertyBased]
        ),
        // `DefAIkeTestSupport` is here for one reason: `ReleaseAdmission` is
        // constructible only by a passed `StartupPreflight`, so the only honest way to
        // exercise `AnalysisCoordinator` against the real `AnalysisSessionBinder` is to
        // run that gate. The in-memory artifact store, bundle manager, and cleanup fakes
        // are exactly the ports it needs. A test target depending on this module is what
        // the module exists for, and `check-module-boundaries.py` still forbids any
        // product or shipping module from reaching it.
        //
        // `DefAIkeSharedTransfer` and `DefAIkePresentation` are here for task 12.4, the
        // cross-module analysis-flow tests. That task's whole subject is one span the
        // per-module suites cannot reach: a *real* Photos or claimed-Share ingest, through
        // the real coordinator, to a real presentation value. The three modules are
        // siblings in the shipping graph — none of them depends on another — so this edge
        // exists only in the test target that has to observe all three at once. No
        // production dependency is added: the composition still links what it linked,
        // `DefAIkePresentation` still depends on `DefAIkeDomain` alone, and
        // `check-module-boundaries.py` constrains regular targets and products rather than
        // test targets for exactly this reason.
        .testTarget(
            name: "DefAIkeApplicationTests",
            dependencies: [
                "DefAIkeApplication",
                "DefAIkeDomain",
                "DefAIkeProvenanceAPI",
                "DefAIkeSharedTransfer",
                "DefAIkePresentation",
                "DefAIkeTestSupport",
                propertyBased,
            ]
        ),
        .testTarget(
            name: "DefAIkeImagePipelineTests",
            dependencies: ["DefAIkeImagePipeline", "DefAIkeDomain", propertyBased]
        ),
        .testTarget(
            name: "DefAIkeModelBundleTests",
            dependencies: ["DefAIkeModelBundle", "DefAIkeDomain", propertyBased]
        ),
        .testTarget(
            name: "DefAIkeCoreMLTests",
            dependencies: ["DefAIkeCoreML", "DefAIkeDomain", propertyBased]
        ),
        .testTarget(
            name: "DefAIkeProvenanceAPITests",
            dependencies: ["DefAIkeProvenanceAPI", "DefAIkeDomain", propertyBased]
        ),
        .testTarget(
            name: "DefAIkeProvenanceC2PATests",
            dependencies: [
                "DefAIkeProvenanceC2PA",
                "DefAIkeProvenanceAPI",
                "DefAIkeDomain",
            ]
        ),
        // The Localization Readiness Suite catalogs are test resources. They belong to a
        // test target, so no product and no shipping executable can reach them, and
        // English stays the only Version 1 user-facing language (Requirement 8.18).
        .testTarget(
            name: "DefAIkePresentationTests",
            dependencies: ["DefAIkePresentation", "DefAIkeDomain", propertyBased],
            resources: [.copy("Resources/LocalizationReadiness")]
        ),
        .testTarget(
            name: "DefAIkeReleaseValidationTests",
            dependencies: [
                "DefAIkeReleaseValidation",
                "DefAIkeDomain",
                "DefAIkeModelBundle",
                propertyBased,
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
