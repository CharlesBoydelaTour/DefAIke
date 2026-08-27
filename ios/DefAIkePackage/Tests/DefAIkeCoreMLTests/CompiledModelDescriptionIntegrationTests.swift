import DefAIkeCoreML
import DefAIkeDomain
import CoreML
import Foundation
import Testing

// Task 6.11, Core ML half: the real compiled model's generated description, and one real
// prediction through the real adapters.
//
// **Nothing in this file is release evidence.** Every run here happens on a development
// host. Requirements 4.13 and 13.6 through 13.9 are Device Validation Suite gates on an
// approved physical iPhone under an approved Device Validation Plan, and a host or simulator
// pass satisfies none of them. Nothing below claims a compute-unit placement either: setting
// `MLComputeUnits.all` *permits* Apple Neural Engine execution and Core ML exposes no API
// that reports where a model ran, so Apple Neural Engine placement is unverified here and
// is not asserted.
//
// # What this adds over the tests already in this target
//
// Every other test in `DefAIkeCoreMLTests` drives the adapters through
// `StubRuntimeLoader`/`StubPixelModelRuntime`, so it measures the adapter against a schema
// a test wrote. `RuntimeContractCheckTests` owns the schema rules, `PixelModelLoadingTests`
// owns the load mapping, `PixelInferenceTests` owns the inference mapping, and task 6.8's
// `ModelOutputFailureMappingPropertyTests` owns the quantified output/failure mapping over
// generated outcomes. None of them ever loads a compiled model.
//
// This file loads the real one. Two seams are therefore distinguished throughout, and the
// distinction is stated in each test rather than left to the reader:
//
//   * the **runtime schema seam** — `RuntimeModelSchema` built by hand, which is what every
//     other test in this target measures; and
//   * the **compiled artifact** — an `MLModelDescription` read from a real `.mlmodelc` by
//     `CoreMLModelRuntime`, which is what this file measures.
//
// `RuntimeContractChecks.swift` explicitly defers one question to this task: the output
// rules accept both a scalar spelling and a one-element tensor spelling, and "which spelling
// the released model uses is confirmed against the real compiled model by the integration
// tests in task 6.11". ``realDescriptionProjectsToTheBoundSchema`` answers it.
//
// # What is absent, and what that costs
//
// The compiled model is not committed: `data/` is excluded by the repository's `.gitignore`,
// so a fresh clone has no `.mlmodelc` at all. Every test that needs one is therefore wired
// to ``ApprovedCompiledPixelModel`` and **skipped, with its reason visible in the run**,
// rather than falling back to a stub that would report a pass for a model it never loaded.
// ``absentCompiledModelIsRecorded`` runs in both worlds and requires the absence to name
// where it looked.
//
// Absent as well, and **not fabricated** anywhere below: the approved Device Validation
// Plan, therefore the approved raw-logit tolerance, the approved rank-agreement tolerance,
// and the approved expected categorical Pixel Evidence outcomes; and the Release Fixture
// Suite, therefore the 96 model-parity fixtures. ``missingApprovedDeviceInputsAreRecorded``
// enumerates them, names the requirement each one gates, and fails if this repository ever
// starts carrying one without this suite being extended to compare against it. **No
// tolerance, expected category, parity baseline, or reference logit is invented here**, and
// no assertion below compares a measured logit against a number.

// MARK: - Locating the compiled model

/// Whether a compiled pixel model is installed, and where it was looked for.
///
/// Deliberately not a `Bool`. A reader of a skipped run needs to know which paths were
/// searched, and an audit needs the absence to be a recorded value rather than an inference
/// from a test that did not execute.
enum CompiledPixelModelStatus: Equatable, CustomStringConvertible {
    /// No compiled model was found. Carries every location that was searched, in order.
    case absent(searchedPaths: [String])

    /// A compiled model directory is installed at this location.
    case present(location: URL)

    var description: String {
        switch self {
        case let .absent(paths):
            "no compiled pixel model at: \(paths.joined(separator: ", "))"
        case let .present(location):
            "compiled pixel model at \(location.path)"
        }
    }
}

/// Locates the compiled Core ML model, read-only.
///
/// Two search locations, in order, and nothing else:
///
///   1. the path in `DEFAIKE_COMPILED_PIXEL_MODEL`, for a runner that installs the artifact
///      outside the working tree; then
///   2. `data/coreml/commfor-lowq-384.mlmodelc` inside the repository, which is where the
///      corpus tooling writes it and which `.gitignore` keeps out of version control.
///
/// There is no third location, no bundled default, and no writer. A checkout that has not
/// been given the compiled model cannot obtain one here, which is what keeps a missing
/// artifact a reported absence instead of a stub standing in for it.
enum ApprovedCompiledPixelModel {
    /// The in-repository directory name. Not an approved identifier: it is where the
    /// conversion tooling in this repository happens to write its output.
    static let repositoryRelativePath = "data/coreml/commfor-lowq-384.mlmodelc"

    static let environmentKey = "DEFAIKE_COMPILED_PIXEL_MODEL"

    /// Resolved once per process: the search is filesystem work and its answer cannot change
    /// during a run.
    static let status: CompiledPixelModelStatus = resolve()

    /// Whether a compiled model is installed, for a test's `.enabled(if:)` trait.
    static var isPresent: Bool {
        if case .present = status { return true }
        return false
    }

    static var location: URL? {
        guard case let .present(location) = status else { return nil }
        return location
    }

    /// Every location that was searched, in search order.
    static var searchedPaths: [String] {
        var paths: [String] = []
        if let installed = ProcessInfo.processInfo.environment[environmentKey] {
            paths.append(installed)
        }
        paths.append(repositoryModelURL.path)
        return paths
    }

    /// Derived from this file's own path so it does not depend on a working directory: five
    /// levels up from `Tests/DefAIkeCoreMLTests/<file>` is the repository root.
    private static var repositoryModelURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(repositoryRelativePath)
    }

    private static func resolve() -> CompiledPixelModelStatus {
        for path in searchedPaths {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else {
                continue
            }
            return .present(location: URL(fileURLWithPath: path))
        }
        return .absent(searchedPaths: searchedPaths)
    }
}

/// Hands the real loader the located compiled model and nothing else.
///
/// The production seam has no default and no search order on purpose, so a test supplies the
/// location exactly the way a shipping composition's Model Bundle layer would. `nil` when no
/// model is installed, which is the seam's fail-closed answer rather than a reason to look
/// elsewhere.
struct LocatedCompiledPixelModel: CompiledPixelModelLocating {
    let location: URL?

    func compiledModelLocation(for bundle: BoundModelBundle) -> URL? { location }
}

// MARK: - Missing approved device-validation inputs

/// One approved release input task 6.11 names that this repository does not carry.
///
/// Each entry names the artifact, the requirement clauses it gates, and how its arrival is
/// detected. Nothing here supplies a value: an entry is a recorded absence, and the only
/// transition it permits is from absent to "installed, so extend the comparison".
struct MissingApprovedDeviceInput: Hashable, CustomStringConvertible {
    /// What the requirements call the artifact.
    let artifact: String

    /// The requirement clauses that cannot be exercised without it.
    let gates: String

    /// File name searched for under the approved-fixture directory.
    let fileName: String

    /// Why no substitute is admissible.
    let whyNotSubstitutable: String

    var description: String {
        "\(artifact) (gates Requirements \(gates)) is absent: \(whyNotSubstitutable)"
    }
}

/// The approved inputs this task names and this repository does not have.
///
/// Read as a table rather than as prose so a run reports every one of them by name, and so
/// adding an approved artifact is a matter of installing a file rather than of rewriting a
/// suite.
enum MissingApprovedDeviceInputs {
    /// Where an installed approved artifact would be found. Matches the location the
    /// provenance and fusion integration suites already search, so a runner installs
    /// approved artifacts in one place.
    static let environmentKey = "DEFAIKE_APPROVED_FIXTURE_DIRECTORY"

    static let all: [MissingApprovedDeviceInput] = [
        MissingApprovedDeviceInput(
            artifact: "Device Validation Plan",
            gates: "4.13, 13.3, 13.6, 13.7",
            fileName: "device-validation-plan.json",
            whyNotSubstitutable: """
                the approved preprocessing, raw-logit, and rank-agreement tolerances live \
                only in this signed plan, and a tolerance chosen anywhere else would turn a \
                parity gate into a rubber stamp
                """
        ),
        MissingApprovedDeviceInput(
            artifact: "approved categorical Pixel Evidence outcomes",
            gates: "13.8",
            fileName: "device-validation-plan.json",
            whyNotSubstitutable: """
                100% agreement is a claim about approved expected categories, and deriving \
                the expected category from what the detector produced would make the \
                comparison circular
                """
        ),
        MissingApprovedDeviceInput(
            artifact: "Release Fixture Suite, including the 96 model-parity fixtures",
            gates: "13.4, 13.6, 13.7, 13.8",
            fileName: "release-fixture-suite.json",
            whyNotSubstitutable: """
                a parity measurement is only meaningful over the immutable fixtures the \
                reference was measured on, and a substitute fixture measures a different \
                image
                """
        ),
        MissingApprovedDeviceInput(
            artifact: "approved signature known-answer vectors",
            gates: "10.6, 10.8",
            fileName: "signature-known-answer-vectors.json",
            whyNotSubstitutable: """
                no real signature algorithm runs anywhere in this repository, so there is \
                nothing for a known-answer vector to be answered by
                """
        ),
    ]

    /// The directory that would hold an installed approved artifact, or `nil` when the
    /// environment names none.
    static var installedDirectory: URL? {
        guard let path = ProcessInfo.processInfo.environment[environmentKey] else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Repository search location, mirroring the fusion and provenance integration suites.
    static var repositoryDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ApprovedFixtures")
    }

    /// Every directory searched for approved artifacts, in order.
    static var searchedDirectories: [URL] {
        var directories: [URL] = []
        if let installedDirectory { directories.append(installedDirectory) }
        directories.append(repositoryDirectory)
        return directories
    }

    /// Whether one entry's artifact is installed anywhere that is searched.
    static func isInstalled(_ input: MissingApprovedDeviceInput) -> Bool {
        searchedDirectories.contains { directory in
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(input.fileName).path
            )
        }
    }
}

// MARK: - The compiled artifact's generated description

@Suite("The real compiled pixel model's description and one real prediction")
struct CompiledModelDescriptionIntegrationTests {
    /// The number of model-parity fixtures Requirement 13.4 names. Read from the
    /// requirement, not chosen here.
    private static let requiredModelParityFixtureCount = 96

    /// Loads the installed compiled model through the real Core ML loader.
    private func runtime() async throws -> any PixelModelRuntime {
        let loader = CoreMLModelRuntimeLoader(
            locations: LocatedCompiledPixelModel(location: ApprovedCompiledPixelModel.location)
        )
        return try await loader.loadRuntime(for: BundleFixture.boundBundle())
    }

    /// A bound-shaped buffer whose every byte is `fill`.
    ///
    /// The content is arbitrary and is **not** a parity fixture: nothing below interprets it
    /// or compares the logit it produces against a reference. Distinct fills exist only so
    /// the buffer can be shown to reach the graph.
    private func pixels(fill: UInt8) throws -> PreparedPixelData {
        let edge = CenterCropContract.requiredEdge
        return try #require(
            PreparedPixelData(
                edge: edge,
                channelOrder: .rgb,
                bytes: [UInt8](repeating: fill, count: edge * edge * 3)
            )
        )
    }

    // MARK: The generated description

    /// Requirements 4.9 and 4.14, measured on the **compiled artifact** rather than on the
    /// runtime schema seam.
    ///
    /// This is the question `RuntimeContractChecks.swift` defers to this task. The output
    /// rules there accept a scalar spelling and a one-element tensor spelling, and until now
    /// nothing established which one the released model uses. It uses the tensor spelling:
    /// `logit` is declared as a one-element FP16 multi-array. That is asserted exactly, so a
    /// re-conversion that changed the surfaced spelling or precision has to be re-approved
    /// instead of being absorbed silently.
    @Test(
        "The real model description projects to exactly the schema the bound contracts fix",
        .enabled(
            if: ApprovedCompiledPixelModel.isPresent,
            "no compiled pixel model is installed; data/ is not under version control"
        )
    )
    func realDescriptionProjectsToTheBoundSchema() async throws {
        let schema = try await runtime().schema
        let edge = CenterCropContract.requiredEdge

        // Exactly one input and one output. An extra feature would mean the adapter had to
        // choose one, which is how it would start measuring something other than what was
        // released.
        #expect(schema.inputs.count == 1, "the compiled model declares \(schema.inputs.count) inputs")
        #expect(
            schema.outputs.count == 1,
            "the compiled model declares \(schema.outputs.count) outputs"
        )

        let input = try #require(schema.inputs.first)
        #expect(input.name == ContractFixture.input().featureName.value)
        #expect(
            input.kind == .image(width: edge, height: edge, pixelFormat: .bgra8),
            "the compiled input is \(input.kind)"
        )
        // The pixel-format rule the input check applies, on the format the artifact actually
        // declares rather than on one a fixture chose.
        if case let .image(_, _, pixelFormat) = input.kind {
            #expect(pixelFormat.carriesThreeColorChannels)
        }

        let output = try #require(schema.outputs.first)
        #expect(output.name == ModelOutputContract.requiredFeatureName)
        #expect(
            output.kind == .tensor(elementCount: 1, element: .float16),
            "the compiled output is \(output.kind)"
        )
        // One number, whichever spelling: asserted through the same predicate the production
        // check uses, so the tensor assertion above is a record of the released spelling
        // rather than the whole of the rule.
        switch output.kind {
        case let .scalar(element):
            #expect(element.isFloatingPoint)
        case let .tensor(elementCount, element):
            #expect(elementCount == 1)
            #expect(element.isFloatingPoint)
        case .image, .unsupported:
            Issue.record("the compiled output is neither a scalar nor a tensor: \(output.kind)")
        }

        // And the production check itself admits the real description against the signed
        // contracts, which is the claim Requirement 4.14 rests on.
        #expect(throws: Never.self) {
            try RuntimeSchemaCheck.validate(
                schema,
                inputContract: ContractFixture.input(),
                outputContract: ContractFixture.output()
            )
        }
    }

    /// Requirement 4.1 and Requirement 4.14, end to end through the real loader.
    ///
    /// The real `CoreMLModelRuntimeLoader`, the real `CoreMLPixelModelLoader`, the real
    /// schema check, and the real store: a compiled model that disagreed with the signed
    /// contracts in any respect would be refused here, and the bound model would not exist.
    @Test(
        "The real compiled model is admitted by the real loader and registered once",
        .enabled(
            if: ApprovedCompiledPixelModel.isPresent,
            "no compiled pixel model is installed; data/ is not under version control"
        )
    )
    func realModelIsAdmittedByTheLoader() async throws {
        let bundle = BundleFixture.boundBundle()
        let store = LoadedPixelModelStore()
        let loader = CoreMLPixelModelLoader(
            runtimeLoader: CoreMLModelRuntimeLoader(
                locations: LocatedCompiledPixelModel(
                    location: ApprovedCompiledPixelModel.location
                )
            ),
            loadedModels: store
        )

        let model = try await loader.loadModel(from: bundle)

        #expect(model.bundleID == bundle.bundleID)
        #expect(model.modelIdentity == RequiredPixelModel.identity)
        #expect(model.inputContract == bundle.manifest.inputContract)
        #expect(model.outputContract == bundle.manifest.outputContract)
        #expect(model.accepts(PixelFixture.modelInput()))
        #expect(await store.loadedModelCount == 1)
        #expect(await store.runtime(for: model.model) != nil)
    }

    /// Requirement 4.9, on the real graph.
    ///
    /// One prediction, one feature, and one finite number. Finiteness is asserted with
    /// `isFinite`, `isNaN`, and `isInfinite`, and identity with `bitPattern` and `sign`,
    /// never with an arithmetic comparison: `NaN != NaN` makes an equality assertion over a
    /// nonfinite value meaningless, and `-0.0 == 0.0` while the two signs differ.
    ///
    /// **No reference logit is compared against.** The number is asserted to be finite and
    /// to reach the analyzer unchanged; whether it is the *right* number is Requirement
    /// 13.7's parity gate, which has no approved tolerance or reference in this repository.
    @Test(
        "One real prediction yields exactly one finite logit, unchanged by the analyzer",
        .enabled(
            if: ApprovedCompiledPixelModel.isPresent,
            "no compiled pixel model is installed; data/ is not under version control"
        )
    )
    func realPredictionYieldsOneFiniteLogit() async throws {
        let bundle = BundleFixture.boundBundle()
        let store = LoadedPixelModelStore()
        let loader = CoreMLPixelModelLoader(
            runtimeLoader: CoreMLModelRuntimeLoader(
                locations: LocatedCompiledPixelModel(
                    location: ApprovedCompiledPixelModel.location
                )
            ),
            loadedModels: store
        )
        let model = try await loader.loadModel(from: bundle)
        let prepared = try pixels(fill: 0x7F)
        let analyzer = CoreMLPixelAnalyzer(
            loadedModels: store,
            preparedPixels: StubPixelResolver(pixels: prepared)
        )

        // What the graph emitted, read through the same runtime the analyzer will use.
        let runtime = try #require(await store.runtime(for: model.model))
        let raw = try await runtime.predict(prepared)

        // Exactly the one required feature, and nothing else. An extra feature is what the
        // output check refuses rather than ignores.
        #expect(
            Set(raw.features.keys) == [ModelOutputContract.requiredFeatureName],
            "the real prediction returned \(raw.features.keys.sorted())"
        )
        let emitted = try #require(raw.features[ModelOutputContract.requiredFeatureName])
        guard case let .scalar(emittedValue) = emitted else {
            Issue.record("the real prediction did not project to one number: \(emitted)")
            return
        }
        #expect(emittedValue.isFinite, "the emitted logit must be finite")
        #expect(!emittedValue.isNaN)
        #expect(!emittedValue.isInfinite)

        // The same prediction through the real analyzer.
        let logit = try await analyzer.infer(PixelFixture.modelInput(), model: model)

        #expect(logit.value.isFinite, "the returned logit must be finite")
        #expect(!logit.value.isNaN)
        #expect(!logit.value.isInfinite)
        #expect(logit.value.sign == emittedValue.sign, "the sign was not preserved")
        // `bitPattern` admits no rescale, clamp, round, sign flip, or narrowing round trip,
        // and separates the two zeros that `==` cannot. A transform here would silently
        // redefine the positive-going direction the contract fixes and would invalidate
        // every parity measurement made later against an approved reference.
        #expect(
            logit.value.bitPattern == emittedValue.bitPattern,
            "the analyzer did not return the number the model emitted"
        )
    }

    /// The prepared buffer reaches the graph.
    ///
    /// Without this, "one finite logit" would also hold for an adapter that ignored its
    /// input and returned a constant, and every parity measurement built on top of it would
    /// be measuring nothing. Two buffers that differ in every byte have to produce different
    /// numbers.
    ///
    /// This is **not** a parity claim and not a monotonicity claim: no expected value, no
    /// ordering, and no tolerance is asserted, only that the numbers differ.
    @Test(
        "Distinct prepared buffers reach the graph and produce distinct logits",
        .enabled(
            if: ApprovedCompiledPixelModel.isPresent,
            "no compiled pixel model is installed; data/ is not under version control"
        )
    )
    func distinctBuffersProduceDistinctLogits() async throws {
        let runtime = try await runtime()
        var patterns: Set<UInt64> = []
        for fill in [UInt8(0x00), 0x7F, 0xFF] {
            let result = try await runtime.predict(try pixels(fill: fill))
            let value = try #require(result.features[ModelOutputContract.requiredFeatureName])
            guard case let .scalar(raw) = value else {
                Issue.record("fill 0x\(String(fill, radix: 16)) did not project to one number")
                return
            }
            #expect(raw.isFinite, "fill 0x\(String(fill, radix: 16)) produced a nonfinite logit")
            patterns.insert(raw.bitPattern)
        }
        #expect(
            patterns.count == 3,
            """
            three buffers differing in every byte produced \(patterns.count) distinct logit \
            bit pattern(s); the prepared buffer may not be reaching the graph
            """
        )
    }

    /// What the compiled artifact's own metadata does and does not establish.
    ///
    /// Two halves, and the second is the point. The description string agrees with the
    /// upstream boundary the domain pins, the required short edge, and the required crop
    /// edge — so the artifact and the code are talking about the same preprocessing. But the
    /// metadata carries **no** field equal to the Requirement 10.2 checkpoint identifier, so
    /// model identity is not establishable from the compiled model and has to come from the
    /// signed Model Bundle manifest. Recorded as an absence with a positive control, so the
    /// claim is not that the read failed.
    @Test(
        "The compiled model's metadata agrees on preprocessing but carries no model identity",
        .enabled(
            if: ApprovedCompiledPixelModel.isPresent,
            "no compiled pixel model is installed; data/ is not under version control"
        )
    )
    func compiledMetadataAgreesOnPreprocessingButNotOnIdentity() async throws {
        let location = try #require(ApprovedCompiledPixelModel.location)
        let configuration = MLModelConfiguration()
        // The same configuration the production loader uses. It *permits* Apple Neural
        // Engine execution and reports nothing about where the model ran, so no placement
        // claim follows from it.
        configuration.computeUnits = .all
        let model = try MLModel(contentsOf: location, configuration: configuration)
        let metadata = model.modelDescription.metadata

        // Positive control: the metadata was read at all, so the absence below is an
        // absence rather than an empty dictionary.
        #expect(!metadata.isEmpty, "the compiled model carries no metadata to audit")
        let summary = try #require(
            metadata[MLModelMetadataKey.description] as? String,
            "the compiled model carries no description string"
        )

        // The upstream raw-logit boundary the domain pins, as the artifact spells it. This
        // is metadata about the upstream checkpoint and never a product verdict boundary;
        // `UpstreamBoundaryMetadata` fixes that role, and no calibration decision is taken
        // from it here.
        #expect(
            summary.contains("\(UpstreamBoundaryMetadata.requiredValue)"),
            "the description does not mention the pinned upstream boundary: \(summary)"
        )
        #expect(
            summary.contains("\(ResizeContract.requiredShortEdge)"),
            "the description does not mention the required short edge"
        )
        #expect(
            summary.contains("\(CenterCropContract.requiredEdge)"),
            "the description does not mention the required crop edge"
        )

        // The recorded gap. Every metadata value, as text, and none of them is the required
        // checkpoint identifier — so Requirement 10.2 cannot be verified from the compiled
        // artifact and is verified from the signed manifest instead
        // (`ModelIdentityAndCompatibilityTests`, and task 6.6's Property 2).
        let values = metadata.values.map { "\($0)" }
        #expect(
            !values.contains(RequiredPixelModel.checkpointIdentifier),
            """
            the compiled model now carries the required checkpoint identifier in its \
            metadata; this suite must be extended to compare it
            """
        )
    }

    // MARK: Absences, recorded rather than filled in

    /// The absence of a compiled model is recorded, and never a pass.
    ///
    /// Always runs. While absent it requires the searched paths to be named and requires the
    /// loader to refuse rather than substitute anything — so the skips above are wired to a
    /// check that bites. Once installed it requires the located directory to exist.
    @Test("An absent compiled model is recorded and never reports a pass")
    func absentCompiledModelIsRecorded() async throws {
        switch ApprovedCompiledPixelModel.status {
        case let .absent(searchedPaths):
            #expect(!searchedPaths.isEmpty, "an absence must name where it looked")
            let described = ApprovedCompiledPixelModel.status.description
            #expect(searchedPaths.allSatisfy { described.contains($0) })

        case let .present(location):
            var isDirectory: ObjCBool = false
            #expect(
                FileManager.default.fileExists(
                    atPath: location.path,
                    isDirectory: &isDirectory
                ) && isDirectory.boolValue
            )
        }

        // The check bites in both worlds: a build given no location refuses with the
        // fail-closed fault rather than searching for a model of its own.
        let loader = CoreMLModelRuntimeLoader(
            locations: LocatedCompiledPixelModel(location: nil)
        )
        await #expect(throws: ModelRuntimeLoadFault.compiledModelUnavailable) {
            try await loader.loadRuntime(for: BundleFixture.boundBundle())
        }

        // And a runtime whose description disagrees with the signed contracts is refused at
        // load, so "the real model was admitted" above is not a vacuous acceptance.
        let store = LoadedPixelModelStore()
        let disagreeing = CoreMLPixelModelLoader(
            runtimeLoader: StubRuntimeLoader(
                outcome: .success(
                    StubPixelModelRuntime(schema: SchemaFixture.matching(outputName: "var_318"))
                )
            ),
            loadedModels: store
        )
        await #expect(throws: AnalysisFault.analysis(.modelLoadError, stage: .modelLoad)) {
            try await disagreeing.loadModel(from: BundleFixture.boundBundle())
        }
        #expect(await store.loadedModelCount == 0)
    }

    /// The approved device-validation inputs this task names, recorded as absences.
    ///
    /// Requirements 4.13 and 13.6 through 13.9 are comparisons against approved references
    /// under approved tolerances. None of those references, tolerances, or expected
    /// categories exists in this repository, and **inventing one would convert a fail-closed
    /// release gate into a rubber stamp**. So each is named here with the requirement it
    /// gates, and the assertion is that it is still absent: the moment one is installed this
    /// test fails, which is the signal to extend this suite to compare against it rather
    /// than to keep skipping.
    @Test("Absent approved device-validation inputs are named and never substituted")
    func missingApprovedDeviceInputsAreRecorded() throws {
        #expect(
            !MissingApprovedDeviceInputs.all.isEmpty,
            "the recorded-absence table must not be empty"
        )
        #expect(
            !MissingApprovedDeviceInputs.searchedDirectories.isEmpty,
            "an absence must name where it looked"
        )

        for input in MissingApprovedDeviceInputs.all {
            #expect(!input.gates.isEmpty, "\(input.artifact) must name what it gates")
            #expect(
                !MissingApprovedDeviceInputs.isInstalled(input),
                """
                \(input.description) — it is now installed under \
                \(MissingApprovedDeviceInputs.searchedDirectories.map(\.path)
                    .joined(separator: ", ")); \
                extend this suite to compare against it instead of skipping
                """
            )
        }

        // The schema the plan would be read through exists, so an installed plan can be
        // decoded rather than parsed ad hoc. Which is also how the gap below is visible.
        #expect(ComparisonMetric.allCases.contains(.rawLogit))
        #expect(ComparisonMetric.allCases.contains(.rankAgreement))
        #expect(ComparisonMetric.allCases.contains(.categoricalOutcome))
        #expect(!ComparisonMetric.rawLogit.isCategorical)
        #expect(!ComparisonMetric.rankAgreement.isCategorical)
        #expect(ComparisonMetric.categoricalOutcome.isCategorical)

        // Recorded schema gap, reported and not worked around: `ComparisonMetric` has no
        // member for decoded model metadata, so the agreement between the compiled model's
        // description string and the pinned upstream boundary that
        // ``compiledMetadataAgreesOnPreprocessingButNotOnIdentity`` measures cannot be
        // expressed as a Device Validation Plan comparison at all. That is a gap in the
        // artifact schema rather than a missing file, and it is not filled in here.
        let metadataMetrics = ComparisonMetric.allCases.filter {
            $0.rawValue.contains("metadata")
        }
        #expect(
            metadataMetrics.isEmpty,
            """
            ComparisonMetric now carries a decoded-metadata metric \
            (\(metadataMetrics.map(\.rawValue).joined(separator: ", "))); the recorded schema \
            gap is closed and this note must be replaced by a comparison
            """
        )

        // Requirement 13.4's count is read from the requirement, not chosen here, and it is
        // stated so an installed suite is checkable against it rather than accepted on
        // sight.
        #expect(Self.requiredModelParityFixtureCount == 96)
        #expect(FixtureFamily.allCases.contains(.modelParity))
    }

    /// Requirements 4.10 and 10.21, asserted structurally.
    ///
    /// There is no observable network seam in this module to leave untouched: nothing in
    /// `DefAIkeCoreML` can reach the network, so "inference happened on the device" is a
    /// property of the dependency graph rather than something a run can measure. Stating it
    /// as a source audit is the honest form — and a later change that imported a networking
    /// framework would fail here instead of quietly widening what inference can touch.
    @Test("Nothing in the Core ML module can reach the network or the file system")
    func moduleHasNoNetworkSurface() throws {
        let forbidden = [
            "import Network", "import FoundationNetworking", "URLSession", "URLRequest",
            "NSURLConnection", "FileManager", "import CFNetwork", "MLModelCollection",
        ]
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/DefAIkeCoreML")
        let files = try FileManager.default
            .contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty, "the module's sources must be readable for this to mean anything")
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for token in forbidden {
                #expect(
                    !text.contains(token),
                    "\(file.lastPathComponent) must not reference \(token)"
                )
            }
        }
    }
}
