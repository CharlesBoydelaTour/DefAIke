import Testing

@testable import DefAIkeDomain
@testable import DefAIkeModelBundle

/// Step 4 of the verification order: model identity, format, input and output schema,
/// component compatibility, and build compatibility.
///
/// Two things shape every test here.
///
/// First, the pass signal is not `nil`. Requirement 10.4 pins the weight-blob digest to a
/// specific SHA-256 value, so the only bundle that can pass step 4 completely is the one
/// carrying the real approved weights. A synthetic candidate that is compatible in every
/// other respect therefore stops at exactly the weight measurement, and that finding is the
/// evidence that everything before it passed.
///
/// Second, several of the facts the requirements fix are unreachable through a manifest at
/// all, because ``ModelBundleManifest`` and its component contracts refuse to hold them.
/// Those are asserted against the schema directly, so the requirement is covered from the
/// side that actually enforces it.
@Suite("Model identity and bundle compatibility")
struct ModelIdentityAndCompatibilityTests {
    // MARK: The compatible candidate

    @Test("A candidate compatible in every declarative respect reaches the weight measurement")
    func compatibleCandidateReachesWeightMeasurement() throws {
        let candidate = try CompatibleBundleAssembler.standard()
        #expect(
            candidate.compatibilityFinding() == candidate.weightMeasurementFinding,
            """
            every identity, format, schema, component, build, and self-test check must pass \
            before the weight blob is measured
            """
        )
    }

    @Test("The weight blob is measured from the bytes, not read from the manifest")
    func weightDigestIsMeasured() throws {
        let candidate = try CompatibleBundleAssembler.standard()
        _ = candidate.compatibilityFinding()
        #expect(
            candidate.reads.paths.contains(CompatibleBundleAssembler.weightBlobPath),
            "the declared required digest proves nothing unless the blob is actually hashed"
        )
    }

    @Test("A candidate with no weight blob at the approved path is refused by name")
    func missingWeightBlobRefused() throws {
        let candidate = try CompatibleBundleAssembler.standard(omitWeightBlob: true)
        #expect(
            candidate.compatibilityFinding()
                == .modelWeightBlobNotFound(Sample.path(CompatibleBundleAssembler.weightBlobPath))
        )
    }

    @Test("A weight-blob path naming a directory is refused rather than read")
    func weightBlobPathNamingADirectoryRefused() throws {
        let candidate = try CompatibleBundleAssembler.standard(
            layout: Sample.bundleLayout(
                weightBlob: "\(CompatibleBundleAssembler.modelTreePath)/weights"
            )
        )
        #expect(
            candidate.compatibilityFinding()
                == .modelWeightBlobNotFound(
                    Sample.path("\(CompatibleBundleAssembler.modelTreePath)/weights")
                )
        )
    }

    // MARK: The approved layout

    @Test("A layout whose record is a rejection is refused")
    func unapprovedLayoutRefused() throws {
        let candidate = try CompatibleBundleAssembler.standard(
            layout: Sample.bundleLayout(decision: .rejected)
        )
        #expect(
            candidate.compatibilityFinding()
                == .bundleLayoutNotApproved(Sample.artifact("evidence.bundle-layout"))
        )
    }

    @Test("A layout naming an undeclared path is refused, per role")
    func undeclaredRoleRefused() throws {
        let cases: [(BundleArtifactRole, ApprovedBundleLayout)] = [
            (.compiledModel, Sample.bundleLayout(compiledModel: "artifacts/absent.mlmodelc")),
            (.selfTestSpecification, Sample.bundleLayout(selfTestSpecification: "artifacts/absent.json")),
            (.fixtureCatalog, Sample.bundleLayout(fixtureCatalog: "artifacts/absent-catalog.json")),
            (.fixtureRoot, Sample.bundleLayout(fixtureRoot: "artifacts/absent-fixtures")),
        ]
        for (role, layout) in cases {
            let candidate = try CompatibleBundleAssembler.standard(layout: layout)
            #expect(
                candidate.compatibilityFinding()
                    == .roleArtifactNotDeclared(role: role, path: layout.path(for: role)),
                "\(role) must be refused by name when it is not declared"
            )
        }
    }

    @Test("A role bound to a declared artifact of the wrong kind is refused")
    func roleKindMismatchRefused() throws {
        // The self-test specification is a file role pointed at a declared directory tree.
        let layout = Sample.bundleLayout(
            selfTestSpecification: CompatibleBundleAssembler.fixtureRootPath,
            fixtureRoot: CompatibleBundleAssembler.selfTestsPath
        )
        let candidate = try CompatibleBundleAssembler.standard(layout: layout)
        #expect(
            candidate.compatibilityFinding()
                == .roleArtifactKindMismatch(
                    role: .selfTestSpecification,
                    path: Sample.path(CompatibleBundleAssembler.fixtureRootPath)
                )
        )
    }

    @Test("A layout cannot be constructed from paths that cannot describe one bundle")
    func incoherentLayoutIsNotRepresentable() {
        let source = Sample.evidence("evidence.bundle-layout")
        let approval = Sample.approval()
        func layout(
            compiledModel: String = "artifacts/model.mlmodelc",
            weightBlob: String = "artifacts/model.mlmodelc/weights/weight.bin",
            selfTests: String = "artifacts/self-tests.canonical.json",
            catalog: String = "artifacts/fixture-catalog.canonical.json",
            fixtures: String = "artifacts/fixtures"
        ) -> ApprovedBundleLayout? {
            ApprovedBundleLayout(
                source: source,
                compiledModel: Sample.path(compiledModel),
                modelWeightBlob: Sample.path(weightBlob),
                selfTestSpecification: Sample.path(selfTests),
                fixtureCatalog: Sample.path(catalog),
                fixtureRoot: Sample.path(fixtures),
                approval: approval
            )
        }
        #expect(layout() != nil)
        // The weight blob has to be inside the compiled model.
        #expect(layout(weightBlob: "artifacts/weight.bin") == nil)
        // The weight blob is not the compiled model itself.
        #expect(layout(weightBlob: "artifacts/model.mlmodelc") == nil)
        // Two roles cannot share a path.
        #expect(layout(catalog: "artifacts/self-tests.canonical.json") == nil)
        // Two separately declared roles cannot contain one another.
        #expect(layout(selfTests: "artifacts/fixtures/self-tests.canonical.json") == nil)
        // A reserved root file is never an artifact role.
        #expect(layout(selfTests: ModelBundleManifest.manifestFileName) == nil)
        #expect(layout(catalog: ModelBundleManifest.signatureFileName) == nil)
    }

    // MARK: Approved policy and catalogue

    @Test("A tree verified under another Bundle Verification Policy is refused")
    func policyMismatchRefused() throws {
        var candidate = try CompatibleBundleAssembler.standard()
        let other = try BundleVerificationPolicy(
            id: Sample.artifact("policy.bundle-verification"),
            schemaVersion: .v1,
            algorithm: .ed25519,
            canonicalizationProfile: candidate.integrity.policy.canonicalizationProfile,
            trustedKeys: candidate.integrity.policy.trustedKeys,
            rotationBehavior: .activeKeysOnly,
            revocationBehavior: .rejectBundle,
            maximumManifestByteCount: Sample.byteCount(262_144),
            reproducibilityEvidence: Sample.evidence("evidence.reproducibility")
        )
        // The tree is verified under a policy identifier the configuration does not bind.
        candidate.integrity.policy = try BundleVerificationPolicy(
            id: Sample.artifact("policy.other-verification"),
            schemaVersion: .v1,
            algorithm: other.algorithm,
            canonicalizationProfile: other.canonicalizationProfile,
            trustedKeys: other.trustedKeys,
            rotationBehavior: other.rotationBehavior,
            revocationBehavior: other.revocationBehavior,
            maximumManifestByteCount: other.maximumManifestByteCount,
            reproducibilityEvidence: other.reproducibilityEvidence
        )
        #expect(
            candidate.compatibilityFinding()
                == .verifiedUnderDifferentPolicy(
                    verified: Sample.artifact("policy.other-verification"),
                    bound: Sample.artifact("policy.bundle-verification")
                )
        )
    }

    @Test("A process running as a different capability manifest is refused")
    func capabilityManifestMismatchRefused() throws {
        let candidate = try CompatibleBundleAssembler.standard(
            contextCapabilityManifestIdentifier: "manifest.other"
        )
        #expect(
            candidate.compatibilityFinding()
                == .capabilityManifestMismatch(
                    context: Sample.artifact("manifest.other"),
                    bound: Sample.artifact("manifest.capability")
                )
        )
    }

    @Test("A bundle the capability manifest does not list is refused")
    func candidateOutsideApprovedCatalogRefused() throws {
        let candidate = try CompatibleBundleAssembler.standard(
            bundleCatalog: [Sample.bundle("bundle.other")]
        )
        #expect(
            candidate.compatibilityFinding()
                == .candidateNotInApprovedBundleCatalog(Sample.bundle())
        )
    }

    // MARK: Component compatibility

    @Test("Each of the four externally bound component versions must match")
    func componentVersionsMustMatch() throws {
        let mutations: [(BundleComponent, BundleComponentVersions, ArtifactID, ArtifactID)] = [
            (
                .preprocessingContract,
                Sample.compatibleComponentVersions(preprocessing: "contract.other"),
                Sample.artifact("contract.preprocessing"),
                Sample.artifact("contract.other")
            ),
            (
                .calibrationPolicy,
                Sample.compatibleComponentVersions(calibration: "policy.other-calibration"),
                Sample.artifact("policy.calibration"),
                Sample.artifact("policy.other-calibration")
            ),
            (
                .verdictCopyCompatibility,
                Sample.compatibleComponentVersions(copy: "copy.other"),
                Sample.artifact("copy.compatibility"),
                Sample.artifact("copy.other")
            ),
            (
                .evidenceScope,
                Sample.compatibleComponentVersions(scope: "scope.other"),
                Sample.artifact("scope.evidence"),
                Sample.artifact("scope.other")
            ),
        ]
        for (component, versions, expected, found) in mutations {
            let candidate = try CompatibleBundleAssembler.standard(componentVersions: versions)
            #expect(
                candidate.compatibilityFinding()
                    == .componentVersionIncompatible(
                        component: component,
                        expected: expected,
                        found: found
                    ),
                "\(component) must be refused by name"
            )
        }
    }

    @Test("The bundle's model input must be the buffer the bound contract produces")
    func inputFeatureNameMustAgreeWithBoundContract() throws {
        let candidate = try CompatibleBundleAssembler.standard(
            manifestInputFeatureName: "pixels",
            configurationInputFeatureName: "image"
        )
        #expect(
            candidate.compatibilityFinding()
                == .modelInputContractRejected(.featureNameDisagreesWithBoundContract)
        )
    }

    // MARK: Build compatibility

    @Test("An application build the bundle does not list is refused")
    func incompatibleAppBuildRefused() throws {
        let candidate = try CompatibleBundleAssembler.standard(
            compatibleAppBuilds: [Sample.appBuild("build.other")]
        )
        #expect(
            candidate.compatibilityFinding() == .appBuildNotCompatible(Sample.appBuild())
        )
    }

    @Test("A bundle requiring a capability this build does not compile is refused")
    func missingRequiredCapabilityRefused() throws {
        let candidate = try CompatibleBundleAssembler.standard(
            requiredCapabilities: [.pixelAnalysis, .contentCredentialValidation],
            contextCapabilities: [.pixelAnalysis]
        )
        #expect(
            candidate.compatibilityFinding()
                == .requiredCapabilitiesNotCompiled([.contentCredentialValidation])
        )
    }

    @Test("A device below the bundle's minimum operating system is refused")
    func osBelowBundleMinimumRefused() throws {
        let candidate = try CompatibleBundleAssembler.standard(
            bundleMinimumOS: try PlatformVersion(validating: "18.0.0"),
            contextOSVersion: .iOS17
        )
        #expect(
            candidate.compatibilityFinding()
                == .operatingSystemBelowBundleMinimum(
                    required: try PlatformVersion(validating: "18.0.0"),
                    running: .iOS17
                )
        )
    }

    @Test("A device above the bundle's minimum is compatible")
    func osAboveBundleMinimumAccepted() throws {
        let candidate = try CompatibleBundleAssembler.standard(
            bundleMinimumOS: .iOS17,
            contextOSVersion: try PlatformVersion(validating: "18.1.0")
        )
        #expect(candidate.compatibilityFinding() == candidate.weightMeasurementFinding)
    }

    // MARK: Facts the artifact schemas refuse to hold

    @Test("A manifest cannot declare any checkpoint but the Lowq one")
    func manifestAdmitsOnlyTheRequiredIdentity() throws {
        // The verifier still checks the identity, so this is the first of two independent
        // refusals rather than a substitute for it. What it establishes is that a candidate
        // naming another checkpoint cannot even become a manifest value: it is refused at
        // parsing, before compatibility is considered (Requirements 1.16 and 10.2).
        let other = ModelIdentity(
            checkpointIdentifier: ModelCheckpointIdentifier("Other/detector-2026-01")!,
            requiredWeightDigest: RequiredPixelModel.identity.requiredWeightDigest
        )
        #expect(other != RequiredPixelModel.identity)
        #expect(throws: ArtifactSchemaError.self) {
            _ = try ModelBundleManifest(
                schemaVersion: .v1,
                bundleID: Sample.bundle(),
                modelIdentity: other,
                modelFormat: Sample.modelFormat(),
                inputContract: Sample.modelInput(),
                outputContract: Sample.modelOutput(),
                componentVersions: Sample.componentVersions(),
                artifacts: [
                    ArtifactDigestRecord(
                        path: Sample.path("artifacts/model.mlmodelc"),
                        kind: .directoryTree,
                        byteCount: 8,
                        digest: Sample.digest()
                    )
                ],
                compatibility: Sample.compatibility(),
                upstreamBoundaryMetadata: Sample.upstreamMetadata(),
                signingKey: Sample.signingKey()
            )
        }
    }

    @Test("A manifest cannot declare a model that is not an FP16 mlprogram on iOS 17")
    func manifestAdmitsOnlyTheRequiredFormat() {
        let rejected: [(ModelProgramKind, ModelComputePrecision, PlatformVersion)] = [
            (.neuralNetwork, .float16, .iOS17),
            (.pipeline, .float16, .iOS17),
            (.mlProgram, .float32, .iOS17),
            (.mlProgram, .float16, try! PlatformVersion(validating: "16.0.0")),
            (.mlProgram, .float16, try! PlatformVersion(validating: "18.0.0")),
        ]
        for (kind, precision, minimumOS) in rejected {
            #expect(throws: ArtifactSchemaError.self) {
                _ = try ModelFormatDescriptor(
                    programKind: kind,
                    computePrecision: precision,
                    minimumOS: minimumOS
                )
            }
        }
        #expect(
            throws: Never.self,
            performing: {
                try ModelFormatDescriptor(
                    programKind: .mlProgram,
                    computePrecision: .float16,
                    minimumOS: .iOS17
                )
            }
        )
    }

    @Test("A manifest cannot declare an input other than one 384-square UInt8 RGB buffer")
    func manifestAdmitsOnlyTheRequiredInput() {
        let edge = CenterCropContract.requiredEdge
        func input(
            width: Int = CenterCropContract.requiredEdge,
            height: Int = CenterCropContract.requiredEdge,
            elementType: ModelElementType = .uint8,
            normalizes: Bool = false
        ) throws -> ModelInputContract {
            try ModelInputContract(
                featureName: Sample.text("image"),
                width: width,
                height: height,
                channelOrder: .rgb,
                elementType: elementType,
                appliesAppSideNormalization: normalizes
            )
        }
        #expect(throws: ArtifactSchemaError.self) { _ = try input(width: edge - 1) }
        #expect(throws: ArtifactSchemaError.self) { _ = try input(height: edge + 1) }
        #expect(throws: ArtifactSchemaError.self) { _ = try input(elementType: .float16) }
        #expect(throws: ArtifactSchemaError.self) { _ = try input(elementType: .float32) }
        #expect(throws: ArtifactSchemaError.self) { _ = try input(normalizes: true) }
        // Three-channel RGB is the only channel order that exists, so an input in another
        // order is not a value the vocabulary can express.
        #expect(ModelChannelOrder.allCases == [.rgb])
    }

    @Test("A manifest cannot declare an output other than one positive-going scalar logit")
    func manifestAdmitsOnlyTheRequiredOutput() {
        #expect(throws: ArtifactSchemaError.self) {
            _ = try ModelOutputContract(
                featureName: Sample.text("score"),
                elementType: .float32,
                isPositiveGoing: true
            )
        }
        #expect(throws: ArtifactSchemaError.self) {
            _ = try ModelOutputContract(
                featureName: Sample.text(ModelOutputContract.requiredFeatureName),
                elementType: .uint8,
                isPositiveGoing: true
            )
        }
        #expect(throws: ArtifactSchemaError.self) {
            _ = try ModelOutputContract(
                featureName: Sample.text(ModelOutputContract.requiredFeatureName),
                elementType: .float32,
                isPositiveGoing: false
            )
        }
    }

    // MARK: Findings stay inside the closed session vocabulary

    @Test("Every compatibility finding a session can see is model-load-error")
    func findingsMapToModelLoadError() throws {
        let findings: [ModelBundleVerificationError] = [
            .bundleLayoutNotApproved(Sample.artifact()),
            .candidateNotInApprovedBundleCatalog(Sample.bundle()),
            .modelWeightDigestMismatch(Sample.path("artifacts/model.mlmodelc/weights/weight.bin")),
            .modelInputContractRejected(.featureNameDisagreesWithBoundContract),
            .modelOutputContractRejected(.featureNameNotLogit),
            .requiredCapabilitiesNotCompiled([.pixelAnalysis]),
            .selfTestExpectationMismatch(case: Sample.selfTestCaseID(), kind: .rawLogit),
            .selfTestResourceLimitReached(.peakResidentMemory),
        ]
        for finding in findings {
            #expect(finding.analysisFault == .analysis(.modelLoadError, stage: .modelLoad))
            #expect(!finding.description.isEmpty)
        }
    }
}
