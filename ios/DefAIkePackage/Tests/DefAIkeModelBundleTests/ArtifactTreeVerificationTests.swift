import Testing

@testable import DefAIkeDomain
@testable import DefAIkeModelBundle

/// Artifact-tree verification: the tree must hold exactly what the manifest declares,
/// every declared digest must match what streaming measured, and nothing that could
/// point outside the bundle may be present.
@Suite("Model Bundle artifact tree verification")
struct ArtifactTreeVerificationTests {
    // MARK: Success

    @Test("A complete, unaltered candidate verifies")
    func completeCandidateVerifies() throws {
        let assembled = try BundleAssembler.standard()
        let verified = try assembled.verify()

        #expect(verified.bundleID == assembled.bundleID)
        #expect(verified.manifest == assembled.manifest)
        #expect(verified.manifestDigest == StreamingSHA256.digest(of: assembled.manifestBytes))
        #expect(verified.verificationPolicyID == assembled.policy.id)
        #expect(verified.signingKey == assembled.manifest.signingKey)
    }

    @Test("Verified artifacts are the declared set, ordered by canonical path")
    func verifiedArtifactsAreCompleteAndOrdered() throws {
        let verified = try BundleAssembler.standard().verify()
        #expect(
            verified.verifiedArtifacts.map(\.path.rawValue) == [
                BundleAssembler.modelTreePath,
                BundleAssembler.preprocessingPath,
                BundleAssembler.selfTestsPath,
            ]
        )
        #expect(
            verified.verifiedArtifact(at: Sample.path(BundleAssembler.modelTreePath))?.kind
                == .directoryTree
        )
    }

    @Test("Two runs over the same candidate produce the same verified value")
    func verificationIsRepeatable() throws {
        let assembled = try BundleAssembler.standard()
        let first = try assembled.verify()
        let second = try assembled.verify()
        #expect(first == second)
    }

    // MARK: Structure

    @Test("A symbolic link anywhere in the tree is refused")
    func symbolicLinkRefused() throws {
        var assembled = try BundleAssembler.standard()
        assembled.tree.addEntry(
            BundleTreeEntry(rawPath: "artifacts/model-link", kind: .symbolicLink)
        )
        #expect(assembled.verificationFinding() == .symbolicLinkPresent("artifacts/model-link"))
    }

    @Test("An entry that is neither a file nor a directory is refused")
    func unsupportedEntryKindRefused() throws {
        var assembled = try BundleAssembler.standard()
        assembled.tree.addEntry(BundleTreeEntry(rawPath: "artifacts/socket", kind: .other))
        #expect(assembled.verificationFinding() == .unsupportedEntryKind("artifacts/socket"))
    }

    @Test("A traversing or absolute entry path is refused before anything is read")
    func noncanonicalEntryPathsRefused() throws {
        for rawPath in [
            "artifacts/../escape.bin",
            "/absolute.bin",
            "artifacts//double.bin",
            "artifacts/./same.bin",
            "artifacts\\windows.bin",
            "artifacts/with space.bin",
        ] {
            var assembled = try BundleAssembler.standard()
            assembled.tree.addEntry(
                BundleTreeEntry(rawPath: rawPath, kind: .file(byteCount: 1))
            )
            #expect(
                assembled.verificationFinding() == .noncanonicalEntryPath(rawPath),
                "expected \(rawPath) to be refused"
            )
        }
    }

    @Test("A path reported twice is refused")
    func duplicateEntryRefused() throws {
        var assembled = try BundleAssembler.standard()
        assembled.tree.addEntry(
            BundleTreeEntry(
                rawPath: BundleAssembler.preprocessingPath,
                kind: .file(byteCount: 1)
            )
        )
        #expect(
            assembled.verificationFinding()
                == .duplicateTreeEntry(BundleAssembler.preprocessingPath)
        )
    }

    @Test("A tree above the entry ceiling is refused")
    func entryBudgetEnforced() throws {
        var assembled = try BundleAssembler.standard()
        let ceiling = ModelBundleIntegrityVerifier.maximumTreeEntryCount
        let existing = assembled.tree.treeEntries.count
        for index in 0..<(ceiling - existing + 1) {
            assembled.tree.addEntry(
                BundleTreeEntry(rawPath: "artifacts/filler-\(index).bin", kind: .file(byteCount: 0))
            )
        }
        #expect(
            assembled.verificationFinding()
                == .treeEntryBudgetExceeded(maximumEntryCount: ceiling, found: ceiling + 1)
        )
    }

    @Test("An unreadable tree is refused")
    func unreadableTreeRefused() throws {
        var assembled = try BundleAssembler.standard()
        assembled.tree.enumerationFault = .storeUnavailable
        #expect(assembled.verificationFinding() == .bundleTreeUnreadable(assembled.bundleID))
    }

    // MARK: Reserved root files

    @Test("A missing manifest or signature is refused")
    func reservedFilesRequired() throws {
        for name in [
            ModelBundleManifest.manifestFileName, ModelBundleManifest.signatureFileName,
        ] {
            var assembled = try BundleAssembler.standard()
            assembled.tree.removeEntry(name)
            #expect(
                assembled.verificationFinding() == .reservedFileMissing(name),
                "expected a missing \(name) to be refused"
            )
        }
    }

    @Test("A manifest that is a directory rather than a file is refused")
    func manifestMustBeAFile() throws {
        var assembled = try BundleAssembler.standard()
        assembled.tree.removeEntry(ModelBundleManifest.manifestFileName)
        assembled.tree.addDirectory(ModelBundleManifest.manifestFileName)
        #expect(
            assembled.verificationFinding()
                == .reservedFileNotAFile(ModelBundleManifest.manifestFileName)
        )
    }

    @Test("An unreadable manifest is refused")
    func unreadableManifestRefused() throws {
        var assembled = try BundleAssembler.standard()
        assembled.tree.unreadablePaths.insert(ModelBundleManifest.manifestFileName)
        #expect(
            assembled.verificationFinding()
                == .reservedFileUnreadable(ModelBundleManifest.manifestFileName)
        )
    }

    @Test("A manifest whose enumerated size understates it stops at the policy ceiling")
    func understatedManifestSizeStopsAtCeiling() throws {
        var assembled = try BundleAssembler.standard(manifestByteCeiling: 64)
        assembled.setReportedByteCount(ModelBundleManifest.manifestFileName, 32)
        #expect(
            assembled.verificationFinding()
                == .reservedFileExceedsCeiling(
                    name: ModelBundleManifest.manifestFileName,
                    ceiling: 64
                )
        )
    }

    @Test("An empty signature is refused")
    func emptySignatureRefused() throws {
        var assembled = try BundleAssembler.standard()
        assembled.tree.overwriteContent(ModelBundleManifest.signatureFileName, bytes: [])
        assembled.setReportedByteCount(ModelBundleManifest.signatureFileName, 0)
        #expect(assembled.verificationFinding() == .signatureEmpty)
    }

    @Test("A signature above the structural ceiling is refused")
    func oversizedSignatureRefused() throws {
        var assembled = try BundleAssembler.standard()
        let ceiling = UInt64(ModelBundleIntegrityVerifier.maximumSignatureByteCount)
        let oversized = [UInt8](repeating: 0x5A, count: Int(ceiling) + 1)
        assembled.tree.overwriteContent(
            ModelBundleManifest.signatureFileName,
            bytes: oversized
        )
        assembled.setReportedByteCount(
            ModelBundleManifest.signatureFileName,
            UInt64(oversized.count)
        )
        #expect(
            assembled.verificationFinding()
                == .signatureTooLarge(ceiling: ceiling, found: UInt64(oversized.count))
        )
    }

    // MARK: Declared-only contents

    @Test("An undeclared file in the tree is refused")
    func undeclaredFileRefused() throws {
        var assembled = try BundleAssembler.standard()
        assembled.tree.addFile("artifacts/leftover.tmp", text: "staging residue")
        #expect(
            assembled.verificationFinding()
                == .undeclaredTreeEntry(Sample.path("artifacts/leftover.tmp"))
        )
    }

    @Test("An undeclared empty directory in the tree is refused")
    func undeclaredDirectoryRefused() throws {
        var assembled = try BundleAssembler.standard()
        assembled.tree.addDirectory("artifacts/staging")
        #expect(
            assembled.verificationFinding()
                == .undeclaredTreeEntry(Sample.path("artifacts/staging"))
        )
    }

    @Test("An undeclared file at the bundle root is refused")
    func undeclaredRootFileRefused() throws {
        var assembled = try BundleAssembler.standard()
        assembled.tree.addFile("README.txt", text: "notes")
        #expect(assembled.verificationFinding() == .undeclaredTreeEntry(Sample.path("README.txt")))
    }

    @Test("A declared artifact absent from the tree is refused")
    func missingDeclaredArtifactRefused() throws {
        var assembled = try BundleAssembler.standard()
        assembled.tree.removeEntry(BundleAssembler.preprocessingPath)
        #expect(
            assembled.verificationFinding()
                == .declaredArtifactMissing(Sample.path(BundleAssembler.preprocessingPath))
        )
    }

    @Test("A container of a declared artifact must be a directory, not a file")
    func containerMustBeADirectory() throws {
        var assembled = try BundleAssembler.standard()
        assembled.tree.removeEntry("artifacts")
        assembled.tree.addFile("artifacts", text: "not a directory")
        #expect(assembled.verificationFinding() == .undeclaredTreeEntry(Sample.path("artifacts")))
    }

    // MARK: Declared kinds, sizes, and digests

    @Test("A directory declared as a file is refused")
    func directoryDeclaredAsFileRefused() throws {
        let assembled = try BundleAssembler.standard(artifactOverrides: { records in
            records.map { record in
                record.path.rawValue == BundleAssembler.modelTreePath
                    ? ArtifactDigestRecord(
                        path: record.path,
                        kind: .file,
                        byteCount: record.byteCount,
                        digest: record.digest
                    )
                    : record
            }
        })
        #expect(
            assembled.verificationFinding()
                == .declaredArtifactKindMismatch(
                    path: Sample.path(BundleAssembler.modelTreePath),
                    declared: .file
                )
        )
    }

    @Test("A file declared as a directory tree is refused")
    func fileDeclaredAsTreeRefused() throws {
        let assembled = try BundleAssembler.standard(artifactOverrides: { records in
            records.map { record in
                record.path.rawValue == BundleAssembler.preprocessingPath
                    ? ArtifactDigestRecord(
                        path: record.path,
                        kind: .directoryTree,
                        byteCount: record.byteCount,
                        digest: record.digest
                    )
                    : record
            }
        })
        #expect(
            assembled.verificationFinding()
                == .declaredArtifactKindMismatch(
                    path: Sample.path(BundleAssembler.preprocessingPath),
                    declared: .directoryTree
                )
        )
    }

    @Test("A declared directory tree with no members is refused")
    func emptyDeclaredTreeRefused() throws {
        var assembled = try BundleAssembler.standard()
        assembled.tree.addDirectory("artifacts/notices")
        var artifacts = assembled.manifest.artifacts
        artifacts.append(
            ArtifactDigestRecord(
                path: Sample.path("artifacts/notices"),
                kind: .directoryTree,
                byteCount: 1,
                digest: Sample.digest("f")
            )
        )
        assembled.manifest = try Sample.manifest(artifacts: artifacts)
        assembled.replaceManifest(bytes: try BundleAssembler.encode(assembled.manifest))

        #expect(
            assembled.verificationFinding()
                == .emptyDirectoryTreeArtifact(Sample.path("artifacts/notices"))
        )
    }

    @Test("Altering one byte of a declared file is refused")
    func fileContentMutationRefused() throws {
        var assembled = try BundleAssembler.standard()
        assembled.tree.overwriteContent(
            BundleAssembler.preprocessingPath,
            text: "preprocessing-CONTRACT"
        )
        #expect(
            assembled.verificationFinding()
                == .artifactDigestMismatch(Sample.path(BundleAssembler.preprocessingPath))
        )
    }

    @Test("Shortening a declared file is refused")
    func shortFileRefused() throws {
        var assembled = try BundleAssembler.standard()
        let declared = assembled.manifest.artifacts
            .first { $0.path.rawValue == BundleAssembler.preprocessingPath }!
            .byteCount
        assembled.tree.overwriteContent(BundleAssembler.preprocessingPath, text: "short")
        #expect(
            assembled.verificationFinding()
                == .artifactByteCountMismatch(
                    path: Sample.path(BundleAssembler.preprocessingPath),
                    declared: declared,
                    found: 5
                )
        )
    }

    @Test("Reading stops at the declared bound when a declared file grows")
    func longFileStopsAtDeclaredBound() throws {
        var assembled = try BundleAssembler.standard()
        let declared = assembled.manifest.artifacts
            .first { $0.path.rawValue == BundleAssembler.preprocessingPath }!
            .byteCount
        assembled.tree.overwriteContent(
            BundleAssembler.preprocessingPath,
            text: String(repeating: "x", count: Int(declared) + 100)
        )
        #expect(
            assembled.verificationFinding()
                == .artifactReadExceededDeclaredBound(
                    path: Sample.path(BundleAssembler.preprocessingPath),
                    bound: declared
                )
        )
    }

    @Test("An unreadable declared artifact is refused")
    func unreadableArtifactRefused() throws {
        var assembled = try BundleAssembler.standard()
        assembled.tree.unreadablePaths.insert(BundleAssembler.preprocessingPath)
        #expect(
            assembled.verificationFinding()
                == .artifactUnreadable(Sample.path(BundleAssembler.preprocessingPath))
        )
    }

    @Test("A declared digest that does not match the content is refused")
    func declaredDigestMustMatch() throws {
        let assembled = try BundleAssembler.standard(artifactOverrides: { records in
            records.map { record in
                record.path.rawValue == BundleAssembler.selfTestsPath
                    ? ArtifactDigestRecord(
                        path: record.path,
                        kind: record.kind,
                        byteCount: record.byteCount,
                        digest: Sample.digest("9")
                    )
                    : record
            }
        })
        #expect(
            assembled.verificationFinding()
                == .artifactDigestMismatch(Sample.path(BundleAssembler.selfTestsPath))
        )
    }

    // MARK: Directory-tree artifacts

    @Test("Altering one byte inside a declared tree is refused")
    func treeContentMutationRefused() throws {
        var assembled = try BundleAssembler.standard()
        assembled.tree.overwriteContent(
            "\(BundleAssembler.modelTreePath)/weights/weight.bin",
            text: "weight-blOb"
        )
        #expect(
            assembled.verificationFinding()
                == .artifactDigestMismatch(Sample.path(BundleAssembler.modelTreePath))
        )
    }

    @Test("Adding a member inside a declared tree is refused")
    func treeMemberAdditionRefused() throws {
        var assembled = try BundleAssembler.standard()
        assembled.tree.addFile("\(BundleAssembler.modelTreePath)/extra.bin", text: "extra")
        guard let finding = assembled.verificationFinding() else {
            Issue.record("expected an added tree member to be refused")
            return
        }
        // The added bytes push the tree past its declared total before the digest is
        // compared, so either finding names the tree; both are refusals.
        switch finding {
        case let .artifactByteCountMismatch(path, _, _),
            let .artifactReadExceededDeclaredBound(path, _):
            #expect(path.rawValue.hasPrefix(BundleAssembler.modelTreePath))
        case let .artifactDigestMismatch(path):
            #expect(path == Sample.path(BundleAssembler.modelTreePath))
        default:
            Issue.record("unexpected finding \(finding)")
        }
    }

    @Test("Removing a member from a declared tree is refused")
    func treeMemberRemovalRefused() throws {
        var assembled = try BundleAssembler.standard()
        assembled.tree.removeEntry("\(BundleAssembler.modelTreePath)/coremldata.bin")
        guard case let .artifactByteCountMismatch(path, _, _) = assembled.verificationFinding()
        else {
            Issue.record("expected a byte-count finding for the tree")
            return
        }
        #expect(path == Sample.path(BundleAssembler.modelTreePath))
    }

    @Test("Adding an empty subdirectory to a declared tree is refused")
    func treeEmptySubdirectoryAdditionRefused() throws {
        var assembled = try BundleAssembler.standard()
        assembled.tree.addDirectory("\(BundleAssembler.modelTreePath)/analytics")
        #expect(
            assembled.verificationFinding()
                == .artifactDigestMismatch(Sample.path(BundleAssembler.modelTreePath))
        )
    }

    @Test("Renaming a member of a declared tree is refused")
    func treeMemberRenameRefused() throws {
        var assembled = try BundleAssembler.standard()
        let original = "\(BundleAssembler.modelTreePath)/coremldata.bin"
        let bytes = assembled.tree.fileBytes[original]!
        assembled.tree.removeEntry(original)
        assembled.tree.addFile("\(BundleAssembler.modelTreePath)/coremldata.dat", bytes: bytes)
        #expect(
            assembled.verificationFinding()
                == .artifactDigestMismatch(Sample.path(BundleAssembler.modelTreePath))
        )
    }

    @Test("Moving bytes between two members of a declared tree is refused")
    func treeMemberByteShiftRefused() throws {
        var assembled = try BundleAssembler.standard()
        assembled.tree.overwriteContent(
            "\(BundleAssembler.modelTreePath)/coremldata.bin",
            text: "core-ml-dataw"
        )
        assembled.tree.overwriteContent(
            "\(BundleAssembler.modelTreePath)/weights/weight.bin",
            text: "eight-blob"
        )
        #expect(
            assembled.verificationFinding()
                == .artifactDigestMismatch(Sample.path(BundleAssembler.modelTreePath))
        )
    }
}
