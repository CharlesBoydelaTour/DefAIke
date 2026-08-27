// What this target links, and — the point of the file — what it does not.
//
// The Extension Execution Policy delegates all model inference to the main application
// (Requirement 11.11), and the design's module table says this target "never links Core ML
// model or C2PA". Both are claims about a *module closure*, and a comment cannot be one. What
// this file contributes is the vocabulary: every forbidden module is named once, in a closed
// enumeration, so a later change that adds a dependency has to delete a case here rather than
// quietly widening the graph.
//
// MARK: - Where the module-closure claim is actually established
//
// Not here. Two independent checks establish it, one over the declaration and one over the
// shipped bytes:
//
//   * `ios/Scripts/check-module-boundaries.py` checks the *declared* closure — the dependency
//     set in `ios/project.yml` and `DefAIkePackage/Package.swift` — so a widened graph is a
//     failure at the point it is written down.
//   * `ios/Scripts/check-share-extension-target.py` and
//     `ios/Scripts/check-capability-composition.py` check the *shipped bytes* of the built
//     `.appex`: `find` for model artifacts, `otool -L` for frameworks, `nm` / `nm -u` for
//     module symbols, and per-`.o` symbol attribution. Those are the checks that can see what
//     the linker did, which is the question the claim is about.
//
// MARK: - A `canImport` probe was removed from this file. Do not re-add it
//
// This file used to compute a `reachableForbiddenModules` set from eight
// `#if canImport(DefAIkeX)` blocks. It was removed for two independent reasons, either one
// sufficient:
//
//   * It measured the wrong thing. `canImport` is *reachability*, not linkage. Under Xcode
//     both capability compositions and every package module build into one shared
//     build-products directory, so a module this target does not depend on is still on its
//     import search path. Measured: five forbidden modules resolved as reachable in a
//     correct build. The probe therefore reports a false positive by design, cannot drive any
//     refusal, and establishes nothing that the two checks above do not establish properly.
//   * It broke the build. `canImport` resolves against that shared build-products directory,
//     where each package module's `.swiftmodule` is written *per architecture*. When the
//     architecture being compiled has not yet been emitted, `canImport` *errors* rather than
//     evaluating to `false`:
//
//         error: Could not find module 'DefAIkeModelBundle' for target
//         'x86_64-apple-ios-simulator'; found: arm64-apple-ios-simulator
//
//     A build-ordering race, so the module and architecture named varied run to run
//     (`DefAIkeModelBundle`/x86_64, `DefAIkeApplication`/arm64, `DefAIkeImagePipeline`/arm64,
//     `DefAIkeProvenanceC2PA`/x86_64). Measured over 5 runs: Debug passed on both schemes;
//     Release `DefAIkeApp-PixelOnly` passed; Release `DefAIkeApp-PixelPlusProvenance` failed
//     3 of 3 attempts at the default two-architecture setting, passed with `ARCHS=arm64`, and
//     passed once and failed once with `ONLY_ACTIVE_ARCH=YES`. Provenance was affected and
//     pixel-only was not because the longer package build lets module emission interleave with
//     the extension compile.
//
// Nothing here imports a forbidden module.

/// One module this target must not link.
///
/// Closed and enumerable, in the shape the release-input and approved-copy gap vocabularies
/// already use. Each case is one of the five things task 12.2 requires the extension target to
/// be shown not to contain, or the module that would carry it.
enum ForbiddenExtensionModule: String, Hashable, Sendable, CaseIterable, CustomStringConvertible {

    /// `MLModel` loading and one-logit inference.
    ///
    /// The pixel analyzer lives here. Linking it would put the Core ML runtime, and a code
    /// path that can execute the model, inside the extension (Requirement 11.11).
    case coreML = "DefAIkeCoreML"

    /// Bundle parsing, verification, self-tests, activation, and rollback.
    ///
    /// The compiled Core ML model is a Model Bundle artifact, so this is the module that
    /// would give the extension a way to locate or verify one.
    case modelBundle = "DefAIkeModelBundle"

    /// Container sniffing, complete decode, and the deterministic resize and crop.
    ///
    /// Not inference, but it is the stage that produces a model input, and a Share handoff
    /// hands over exact encoded bytes without decoding them (Requirements 2.3 and 11.12).
    case imagePipeline = "DefAIkeImagePipeline"

    /// The exact-pinned Content Credential adapter.
    ///
    /// Excluded from the extension in both capability compositions, not only the pixel-only
    /// one: provenance validation is main-application work under the main-application budget.
    case provenanceC2PA = "DefAIkeProvenanceC2PA"

    /// The Analysis Coordinator and the Evidence Coordinator.
    ///
    /// The extension creates a pending session by publishing a ticket and then stops. It
    /// joins no evidence lane, commits no terminal outcome, and presents no verdict.
    case application = "DefAIkeApplication"

    /// SwiftUI screens, the English String Catalog, and the report cards.
    ///
    /// Named because it is where approved copy is resolved. Its absence is why this target
    /// records its own approved-copy gaps instead of reusing the presentation layer's four
    /// vocabularies.
    case presentation = "DefAIkePresentation"

    /// Nonshipping release tooling.
    case releaseValidation = "DefAIkeReleaseValidation"

    /// Nonshipping in-memory fakes and call spies.
    case testSupport = "DefAIkeTestSupport"

    var description: String { rawValue }
}

/// The module closure this target compiled with, as the target declares it.
///
/// `linkedModules` is what this target declares and uses. It is two modules, and both are
/// shipped in the main application as well, so nothing here is extension-only code that a
/// release review would have to inspect separately. Whether the built `.appex` matches is a
/// question about the linker's output, answered by the product checks named in the file
/// comment rather than by a value compiled into this file.
enum ShareExtensionModuleClosure {

    /// The modules this target links, by name.
    ///
    /// Exactly the `DefAIkeShareExtensionKit` product: the pure domain core and the shared
    /// transfer module. Neither reaches inference, image decoding, provenance, or evidence
    /// assembly, which is the property that makes the transfer module shippable inside an
    /// extension at all.
    static let linkedModules: [String] = ["DefAIkeDomain", "DefAIkeSharedTransfer"]

    /// Whether the Apple frameworks that would let an extension run a model are absent.
    ///
    /// Separate from the DefAIke module list because these are Apple's, and a build could
    /// reach the Core ML runtime without going through `DefAIkeCoreML`. Unlike an DefAIke
    /// module, `canImport(CoreML)` is `true` in every iOS build — the SDK is always on the
    /// search path — so this is deliberately *not* expressed as a `canImport` probe. There is
    /// no honest compile-time answer here; the evidence is the absence of an `import CoreML`
    /// anywhere in this target's sources, which the accompanying source scan and a symbol
    /// inspection of the built `.appex` are what establish.
    ///
    /// Recorded so the two kinds of claim do not get conflated in a release record.
    static let appleInferenceFrameworksRequireProductInspection: [String] = [
        "CoreML",
        "Vision",
        "Accelerate",
    ]
}
