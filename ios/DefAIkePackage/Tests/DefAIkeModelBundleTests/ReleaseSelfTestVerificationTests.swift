import Testing

@testable import DefAIkeDomain
@testable import DefAIkeModelBundle

/// Step 5 of the verification order: the release self-test specification, its fixture
/// identities, and its expected results have to exist and resolve before anything runs
/// (Requirements 10.9 and 10.10).
///
/// The pass signal is the weight measurement, as it is for step 4: a candidate whose
/// self-test artifacts are complete gets past every check here and stops at the weight blob.
/// Each test below removes, renames, or contradicts exactly one part of the self-test
/// evidence and asserts the finding that names it.
@Suite("Release self-test artifact verification")
struct ReleaseSelfTestVerificationTests {
    // MARK: Reading the specification and the catalogue

    @Test("A specification that is not well-formed JSON is refused as undecodable")
    func malformedSpecificationRefused() throws {
        let candidate = try CompatibleBundleAssembler.standard(
            selfTestsOverride: Array("{\"id\":".utf8)
        )
        guard case let .declaredArtifactNotDecodable(role, error) =
            candidate.compatibilityFinding()
        else {
            Issue.record("expected an undecodable self-test specification")
            return
        }
        #expect(role == .selfTestSpecification)
        #expect(error != .emptyPayload)
    }

    @Test("A specification declaring the same key twice is refused")
    func duplicateKeyInSpecificationRefused() throws {
        // A general-purpose decoder keeps one of the two silently, so the same signed bytes
        // could read as two different specifications.
        let candidate = try CompatibleBundleAssembler.standard(
            selfTestsOverride: Array(
                #"{"id":"spec.self-tests","id":"spec.other","schemaVersion":1}"#.utf8
            )
        )
        #expect(
            candidate.compatibilityFinding()
                == .declaredArtifactNotDecodable(
                    role: .selfTestSpecification,
                    error: .duplicateKey(path: ArtifactDecodingError.rootPath, key: "id")
                )
        )
    }

    @Test("A specification above the approved ceiling is refused before its bytes are read")
    func oversizedSpecificationRefused() throws {
        // The ceiling is the approved Bundle Verification Policy's number, and it bounds
        // every canonical-JSON artifact in the bundle rather than the manifest alone. The
        // refusal comes from the declared byte count, so an oversized artifact is never
        // loaded — which is why the padding below does not have to be valid JSON.
        let ceiling: UInt64 = 100_000
        let candidate = try CompatibleBundleAssembler.standard(
            manifestByteCeiling: ceiling,
            selfTestsOverride: Array(repeating: UInt8(ascii: " "), count: Int(ceiling) * 2)
        )
        #expect(
            candidate.compatibilityFinding()
                == .declaredArtifactNotDecodable(
                    role: .selfTestSpecification,
                    error: .payloadTooLarge(limitBytes: ceiling, actualBytes: ceiling * 2)
                )
        )
        #expect(
            !candidate.reads.paths.contains(CompatibleBundleAssembler.selfTestsPath),
            "an oversized artifact is refused from its declared size, not by reading it"
        )
    }

    @Test("An unreadable specification is refused")
    func unreadableSpecificationRefused() throws {
        let candidate = try CompatibleBundleAssembler.standard(treeOverrides: { tree in
            tree.unreadablePaths.insert(CompatibleBundleAssembler.selfTestsPath)
        })
        #expect(
            candidate.compatibilityFinding()
                == .artifactUnreadable(Sample.path(CompatibleBundleAssembler.selfTestsPath))
        )
    }

    @Test("A catalogue that is not a fixture suite is refused as undecodable")
    func malformedCatalogRefused() throws {
        let candidate = try CompatibleBundleAssembler.standard(
            catalogOverride: Array(#"{"id":"suite.fixtures"}"#.utf8)
        )
        guard case let .declaredArtifactNotDecodable(role, _) =
            candidate.compatibilityFinding()
        else {
            Issue.record("expected an undecodable fixture catalogue")
            return
        }
        #expect(role == .fixtureCatalog)
    }

    // MARK: The specification identifies itself and its suite

    @Test("A specification that is not the version the manifest names is refused")
    func specificationIdentifierMismatchRefused() throws {
        let candidate = try CompatibleBundleAssembler.standard(
            specificationIdentifier: "spec.other",
            componentVersions: Sample.compatibleComponentVersions(selfTests: "spec.self-tests")
        )
        #expect(
            candidate.compatibilityFinding()
                == .selfTestSpecificationIdentifierMismatch(
                    declared: Sample.artifact("spec.other"),
                    componentVersion: Sample.artifact("spec.self-tests")
                )
        )
    }

    @Test("A specification naming a fixture suite the bundle does not carry is refused")
    func fixtureSuiteMismatchRefused() throws {
        let candidate = try CompatibleBundleAssembler.standard(
            specificationFixtureSuite: "suite.elsewhere"
        )
        #expect(
            candidate.compatibilityFinding()
                == .selfTestFixtureCatalogMismatch(
                    specification: Sample.artifact("suite.elsewhere"),
                    catalog: Sample.artifact("suite.fixtures")
                )
        )
    }

    // MARK: Every named fixture resolves

    @Test("A case naming a fixture the catalogue does not carry is refused")
    func uncataloguedFixtureRefused() throws {
        // The catalogue is built from the first entry only, so the second case names a
        // fixture identity nothing in the bundle describes.
        let present = SampleSelfTest(caseID: "self-test.one", fixtureID: "fixture.one")
        let absent = SampleSelfTest(
            caseID: "self-test.two",
            fixtureID: "fixture.two",
            suiteRelativePath: "two.jpg"
        )
        var candidate = try CompatibleBundleAssembler.standard(selfTests: [present])
        candidate.specification = try ReleaseSelfTestSpecification(
            id: Sample.artifact("spec.self-tests"),
            schemaVersion: .v1,
            fixtureSuite: Sample.artifact("suite.fixtures"),
            cases: [try present.specificationCase(), try absent.specificationCase()]
        )
        candidate.integrity = try Self.reassembled(candidate)
        #expect(
            candidate.compatibilityFinding()
                == .selfTestFixtureNotCatalogued(
                    case: Sample.selfTestCaseID("self-test.two"),
                    fixture: Sample.fixtureID("fixture.two")
                )
        )
    }

    @Test("A catalogued fixture whose asset is absent from the tree is refused")
    func missingFixtureAssetRefused() throws {
        // Two catalogued fixtures, one asset removed before the manifest is written, so the
        // artifact tree is internally consistent and the only defect is the missing fixture
        // the specification still requires (Requirement 10.10).
        let candidate = try CompatibleBundleAssembler.standard(
            selfTests: [
                SampleSelfTest(
                    caseID: "self-test.present",
                    fixtureID: "fixture.present",
                    suiteRelativePath: "present.jpg"
                ),
                SampleSelfTest(
                    caseID: "self-test.absent",
                    fixtureID: "fixture.absent",
                    suiteRelativePath: "absent.jpg"
                ),
            ],
            treeOverrides: { tree in
                tree.removeEntry("\(CompatibleBundleAssembler.fixtureRootPath)/absent.jpg")
            }
        )
        #expect(
            candidate.compatibilityFinding()
                == .selfTestFixtureAssetMissing(
                    fixture: Sample.fixtureID("fixture.absent"),
                    path: Sample.path("\(CompatibleBundleAssembler.fixtureRootPath)/absent.jpg")
                )
        )
    }

    @Test("A declared fixture tree with nothing in it is refused by integrity")
    func emptyFixtureTreeRefused() throws {
        // The other way a required fixture can be absent: the bundle declares a fixture tree
        // and ships none of it. Integrity catches this before step 5, and a bundle whose
        // fixture tree has no bytes cannot even be described by a manifest, so both layers
        // keep it away from activation.
        #expect(throws: (any Error).self) {
            _ = try CompatibleBundleAssembler.standard(treeOverrides: { tree in
                tree.removeEntry("\(CompatibleBundleAssembler.fixtureRootPath)/sample.jpg")
            })
        }
    }

    @Test("A catalogue entry pointing outside the fixture tree is refused by name")
    func fixtureAssetOutsideTheTreeRefused() throws {
        // The tree still holds a fixture asset, so integrity passes; the catalogue simply
        // names a path that is not where the asset lives.
        let candidate = try CompatibleBundleAssembler.standard(
            selfTests: [
                SampleSelfTest(suiteRelativePath: "sample.jpg"),
                SampleSelfTest(
                    caseID: "self-test.moved",
                    fixtureID: "fixture.moved",
                    suiteRelativePath: "nested/moved.jpg"
                ),
            ],
            treeOverrides: { tree in
                tree.removeEntry(
                    "\(CompatibleBundleAssembler.fixtureRootPath)/nested/moved.jpg"
                )
            }
        )
        // The declared fixture-tree digest no longer matches, which is the integrity layer's
        // finding for a removed member.
        #expect(candidate.compatibilityFinding() != nil)

        // With the tree consistent and only the catalogue's path wrong, step 5 names it.
        var relocated = try CompatibleBundleAssembler.standard()
        relocated.catalog = try ReleaseFixtureSuite(
            id: Sample.artifact("suite.fixtures"),
            schemaVersion: .v1,
            provenanceApplicability: .notApplicable(decision: Sample.approval()),
            fixtures: [
                try FixtureRecord(
                    id: Sample.fixtureID(),
                    family: .modelParity,
                    assetPath: Sample.path("elsewhere/sample.jpg"),
                    contentDigest: StreamingSHA256.digest(of: Array("fixture-bytes".utf8)),
                    byteCount: Sample.byteCount(UInt64("fixture-bytes".utf8.count)),
                    source: Sample.evidence("evidence.fixture"),
                    expectations: [.pixelLabel(.noStrongSignalDetected)]
                )
            ]
        )
        relocated.integrity = try Self.reassembled(relocated)
        #expect(
            relocated.compatibilityFinding()
                == .selfTestFixtureAssetMissing(
                    fixture: Sample.fixtureID(),
                    path: Sample.path(
                        "\(CompatibleBundleAssembler.fixtureRootPath)/elsewhere/sample.jpg"
                    )
                )
        )
    }

    @Test("A catalogue entry that cannot be placed under the fixture root is refused")
    func unresolvableFixturePathRefused() throws {
        // A canonical suite-relative path that no longer fits inside a canonical path once
        // the fixture root is prepended.
        let long = String(repeating: "a", count: CanonicalRelativePath.maximumCharacterCount - 4)
        var candidate = try CompatibleBundleAssembler.standard()
        candidate.catalog = try ReleaseFixtureSuite(
            id: Sample.artifact("suite.fixtures"),
            schemaVersion: .v1,
            provenanceApplicability: .notApplicable(decision: Sample.approval()),
            fixtures: [
                try FixtureRecord(
                    id: Sample.fixtureID(),
                    family: .modelParity,
                    assetPath: Sample.path("\(long).jpg"),
                    contentDigest: Sample.digest(),
                    byteCount: Sample.byteCount(8),
                    source: Sample.evidence("evidence.fixture"),
                    expectations: [.pixelLabel(.noStrongSignalDetected)]
                )
            ]
        )
        candidate.integrity = try Self.reassembled(candidate)
        #expect(
            candidate.compatibilityFinding()
                == .selfTestFixtureAssetPathNotResolvable(Sample.fixtureID())
        )
    }

    @Test("A catalogue entry that understates its asset's size is refused by name")
    func fixtureLargerThanCataloguedRefused() throws {
        let candidate = try CompatibleBundleAssembler.standard(
            selfTests: [SampleSelfTest(bytes: Array("thirteen-byte".utf8), declaredByteCount: 4)]
        )
        #expect(
            candidate.compatibilityFinding()
                == .selfTestFixtureLargerThanCatalogued(fixture: Sample.fixtureID(), declared: 4),
            "reading stops at the declared bound, so the real size is unknown and not guessed"
        )
    }

    @Test("A catalogue entry that overstates its asset's size is refused by name")
    func fixtureSmallerThanCataloguedRefused() throws {
        let candidate = try CompatibleBundleAssembler.standard(
            selfTests: [SampleSelfTest(bytes: Array("four".utf8), declaredByteCount: 32)]
        )
        #expect(
            candidate.compatibilityFinding()
                == .selfTestFixtureByteCountMismatch(
                    fixture: Sample.fixtureID(),
                    declared: 32,
                    found: 4
                )
        )
    }

    @Test("A catalogue entry whose declared digest disagrees with the asset is refused")
    func fixtureDigestMismatchRefused() throws {
        let candidate = try CompatibleBundleAssembler.standard(
            selfTests: [SampleSelfTest(declaredDigest: Sample.digest("c"))]
        )
        #expect(
            candidate.compatibilityFinding()
                == .selfTestFixtureDigestMismatch(Sample.fixtureID()),
            "a fixture whose bytes changed is not the fixture the expectations were approved against"
        )
    }

    @Test("Every catalogued fixture asset a case names is actually streamed")
    func everyFixtureIsMeasured() throws {
        let candidate = try CompatibleBundleAssembler.standard(
            selfTests: [
                SampleSelfTest(
                    caseID: "self-test.one",
                    fixtureID: "fixture.one",
                    suiteRelativePath: "one.jpg",
                    bytes: Array("one".utf8)
                ),
                SampleSelfTest(
                    caseID: "self-test.two",
                    fixtureID: "fixture.two",
                    suiteRelativePath: "two.jpg",
                    bytes: Array("two".utf8)
                ),
            ]
        )
        #expect(candidate.compatibilityFinding() == candidate.weightMeasurementFinding)
        let streamed = Set(candidate.reads.paths(under: CompatibleBundleAssembler.fixtureRootPath))
        #expect(
            streamed == [
                "\(CompatibleBundleAssembler.fixtureRootPath)/one.jpg",
                "\(CompatibleBundleAssembler.fixtureRootPath)/two.jpg",
            ]
        )
    }

    // MARK: Expectations have to describe one satisfiable outcome

    @Test("A case declaring two expectations of the same kind is refused")
    func repeatedExpectationKindRefused() throws {
        let candidate = try CompatibleBundleAssembler.standard(
            selfTests: [
                SampleSelfTest(
                    expectations: [
                        .rawLogit(value: 1.0, tolerance: Sample.nonNegativeDecimal(0)),
                        .rawLogit(value: 2.0, tolerance: Sample.nonNegativeDecimal(0)),
                    ]
                )
            ]
        )
        #expect(
            candidate.compatibilityFinding()
                == .selfTestCaseRepeatsExpectation(
                    case: Sample.selfTestCaseID(),
                    kind: .rawLogit
                )
        )
    }

    @Test("A case expecting an Analysis Error and a result at the same time is refused")
    func contradictoryExpectationsRefused() throws {
        let candidate = try CompatibleBundleAssembler.standard(
            selfTests: [
                SampleSelfTest(
                    expectations: [
                        .analysisError(.decodingError),
                        .pixelLabel(.noStrongSignalDetected),
                    ]
                )
            ]
        )
        #expect(
            candidate.compatibilityFinding()
                == .selfTestCaseContradictsItself(Sample.selfTestCaseID())
        )
    }

    @Test("A case expecting only an Analysis Error is coherent")
    func errorOnlyCaseAccepted() throws {
        let candidate = try CompatibleBundleAssembler.standard(
            selfTests: [SampleSelfTest(expectations: [.analysisError(.decodingError)])]
        )
        #expect(candidate.compatibilityFinding() == candidate.weightMeasurementFinding)
    }

    @Test("A specification with no cases is not representable")
    func emptySpecificationIsNotRepresentable() {
        // Requirement 10.9 makes the specification the bundle's own statement of what must
        // hold. One with no cases states nothing, and the schema refuses it, so "the
        // self-tests passed" can never mean "there were none".
        #expect(throws: ArtifactSchemaError.self) {
            _ = try ReleaseSelfTestSpecification(
                id: Sample.artifact("spec.self-tests"),
                schemaVersion: .v1,
                fixtureSuite: Sample.artifact("suite.fixtures"),
                cases: []
            )
        }
    }

    @Test("A case with no expected results is not representable")
    func expectationlessCaseIsNotRepresentable() {
        #expect(throws: ArtifactSchemaError.self) {
            _ = try SelfTestCase(
                id: Sample.selfTestCaseID(),
                fixture: Sample.fixtureID(),
                expectations: []
            )
        }
    }

    @Test("A case expecting a nonfinite logit is not representable")
    func nonFiniteExpectationIsNotRepresentable() {
        for value in [Double.nan, .infinity, -.infinity] {
            #expect(throws: ArtifactSchemaError.self) {
                _ = try SelfTestCase(
                    id: Sample.selfTestCaseID(),
                    fixture: Sample.fixtureID(),
                    expectations: [
                        .rawLogit(value: value, tolerance: Sample.nonNegativeDecimal(0))
                    ]
                )
            }
        }
    }

    // MARK: Plan shape

    @Test("Resolved cases are ordered by identifier, whatever order the specification used")
    func planOrderingIsDeterministic() throws {
        let tests = [
            SampleSelfTest(caseID: "self-test.c", fixtureID: "fixture.c", suiteRelativePath: "c.jpg"),
            SampleSelfTest(caseID: "self-test.a", fixtureID: "fixture.a", suiteRelativePath: "a.jpg"),
            SampleSelfTest(caseID: "self-test.b", fixtureID: "fixture.b", suiteRelativePath: "b.jpg"),
        ]
        let plan = try CompatibleBundleAssembler.standard(selfTests: tests).plan()
        #expect(
            plan.cases.map(\.id.rawValue) == ["self-test.a", "self-test.b", "self-test.c"]
        )
        #expect(plan.declaredExpectationCount == 3)
    }

    // MARK: Helpers

    /// Rebuilds the tree, manifest, and signature after a test rewrites a bundle artifact.
    ///
    /// The specification and catalogue are declared artifacts, so changing one changes its
    /// digest and the manifest that covers it. Reassembling keeps the failure under test the
    /// rewritten artifact rather than the broken integrity it would otherwise cause.
    private static func reassembled(_ candidate: CompatibleCandidate) throws -> AssembledBundle {
        var rebuilt = try CompatibleBundleAssembler.standard(
            bundleID: candidate.integrity.bundleID,
            selfTests: candidate.selfTests,
            selfTestsOverride: try CompatibleBundleAssembler.encode(candidate.specification),
            catalogOverride: try CompatibleBundleAssembler.encode(candidate.catalog)
        ).integrity
        rebuilt.resign()
        return rebuilt
    }
}
