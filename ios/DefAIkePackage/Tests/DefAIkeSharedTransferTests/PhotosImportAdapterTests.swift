import DefAIkeDomain
import Foundation
import Testing

@testable import DefAIkeSharedTransfer

/// The Photos route's import adapter and the provider seam it borrows through.
///
/// The rules under test are the ones the requirements make structural: the request is
/// selected-item and current-encoding with no other option representable (Requirements 2.1
/// and 9.4), the copy happens inside the provider's access window, the recorded
/// preservation status is conservative for both answers a picker can give (Requirement
/// 2.11), a provider that produced nothing is a no-session outcome distinct from a copy
/// that did not finish, and nothing here classifies or filters what arrived — which is why
/// a screenshot needs no case of its own (Requirement 2.17).
@Suite("Photos import adapter")
struct PhotosImportAdapterTests {

    private func makeStore(
        root: URL,
        capacityInBytes: UInt64 = testCapacityInBytes,
        protection: any DataProtectionApplying = PlatformDataProtection()
    ) -> ProtectedEphemeralFileStore {
        ProtectedEphemeralFileStore(
            configuration: .test(root: root, capacityInBytes: capacityInBytes),
            protection: protection,
            clock: FixedClock()
        )
    }

    private func makeAdapter(
        access: any PhotosRepresentationAccess,
        store: any EphemeralFileStoring,
        protection: FileProtectionLevel = .complete,
        chunkSizeInBytes: Int = EncodedAssetRetainer.defaultChunkSizeInBytes
    ) -> PhotosImportAdapter {
        PhotosImportAdapter(
            access: access,
            store: store,
            sessionFileProtection: protection,
            chunkSizeInBytes: chunkSizeInBytes
        )
    }

    // MARK: - What the request may say

    @Test("The request names the supported containers, current encoding, and one item")
    func requestIsFixed() {
        #expect(
            PhotosRepresentationRequest.requestedContainers
                == [.jpeg, .png, .heic, .heif]
        )
        #expect(PhotosRepresentationRequest.encodingPolicy == .currentWhenPossible)
        #expect(PhotosRepresentationRequest.libraryAccess == .selectedItemsOnly)
        #expect(PhotosRepresentationRequest.maximumSelectionCount == 1)
    }

    @Test("Selected-item access is the only representable photo-library access")
    func fullLibraryAccessIsUnrepresentable() {
        // Requirement 9.4 is a fact about the vocabulary, not a branch that could be taken
        // the other way: there is no value to pass that would widen access.
        #expect(PhotosLibraryAccess.allCases == [.selectedItemsOnly])
    }

    @Test("A transcode is not a representable request")
    func transcodeIsUnrepresentable() {
        // Asking the picker to re-encode the user's image would deliberately change the
        // bytes Requirements 2.9 through 2.11 exist to preserve.
        #expect(PhotosEncodingPolicy.allCases == [.currentWhenPossible])
    }

    @Test("Nothing in the module requests photo-library authorization")
    func moduleRequestsNoLibraryAuthorization() throws {
        // Requirement 9.4 says selected-item access instead of full photo-library access.
        // The picker grants that without an authorization prompt, so the way to keep the
        // requirement true is for no authorization surface to exist in the module at all.
        // A later change that reaches for one fails here rather than quietly widening what
        // the app can see.
        let forbidden = [
            "import Photos",
            "import PhotosUI",
            "PHPhotoLibrary",
            "PHAsset",
            "PHAuthorizationStatus",
            "requestAuthorization",
            "authorizationStatus",
            "NSPhotoLibraryUsageDescription",
            "NSPhotoLibraryAddUsageDescription",
        ]
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/DefAIkeSharedTransfer")
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

    // MARK: - One accepted ingest

    @Test("An accepted import retains the provider's bytes exactly, for one route")
    func acceptedImportRetainsExactBytes() async throws {
        try await withTemporaryRoot { root in
            let bytes = Sample.bytes(count: 120_000)
            let store = makeStore(root: root)
            let access = FakePhotosAccess.lending(bytes)
            let session = Sample.sessionID()

            let asset = try await makeAdapter(access: access, store: store)
                .importOne(Sample.pickerItem(), into: session)

            #expect(asset.route == .photosPicker)
            #expect(asset.sessionID == session)
            #expect(asset.byteCount == UInt64(bytes.count))
            #expect(asset.sha256 == StreamingSHA256.digest(of: Data(bytes)))
            #expect(try await store.read(asset.handle.storageKey) == bytes)
            #expect(await store.keys(in: .session(session)) == [asset.handle.storageKey])
            #expect(await access.requestedItems.count == 1)
        }
    }

    @Test("The recorded hint is what the provider supplied, not what the picker claimed")
    func recordedHintDescribesTheSuppliedBytes() async throws {
        try await withTemporaryRoot { root in
            let supplied = Sample.contentTypeHint("public.heic")
            let access = FakePhotosAccess.lending(
                Sample.bytes(count: 512),
                suppliedContentTypeHint: supplied
            )

            let asset = try await makeAdapter(access: access, store: makeStore(root: root))
                .importOne(
                    // The placeholder claimed something else entirely.
                    Sample.pickerItem(contentTypeHint: Sample.contentTypeHint("public.jpeg")),
                    into: Sample.sessionID()
                )

            #expect(asset.contentTypeHint == supplied)
        }
    }

    @Test("A provider that supplies no hint yields an ingest with no hint")
    func missingHintIsRecordedAsAbsent() async throws {
        try await withTemporaryRoot { root in
            let access = FakePhotosAccess.lending(
                Sample.bytes(count: 64),
                suppliedContentTypeHint: nil
            )

            let asset = try await makeAdapter(access: access, store: makeStore(root: root))
                .importOne(Sample.pickerItem(), into: Sample.sessionID())

            #expect(asset.contentTypeHint == nil)
        }
    }

    @Test(
        "Every buffer size retains the same bytes, count, and digest",
        arguments: [1, 13, 4_096, 1 << 20]
    )
    func bufferSizeDoesNotChangeTheImport(chunkSize: Int) async throws {
        try await withTemporaryRoot { root in
            let bytes = Sample.bytes(count: 30_007)
            let store = makeStore(root: root)
            let session = Sample.sessionID()

            let asset = try await makeAdapter(
                access: FakePhotosAccess.lending(bytes),
                store: store,
                chunkSizeInBytes: chunkSize
            ).importOne(Sample.pickerItem(), into: session)

            #expect(asset.byteCount == UInt64(bytes.count))
            #expect(asset.sha256 == StreamingSHA256.digest(of: Data(bytes)))
            #expect(try await store.read(asset.handle.storageKey) == bytes)
        }
    }

    @Test(
        "The retained object carries the injected protection level",
        arguments: FileProtectionLevel.allCases
    )
    func retainedObjectUsesTheInjectedProtection(level: FileProtectionLevel) async throws {
        try await withTemporaryRoot { root in
            // There is no compiled-in default: the level is a required initializer argument,
            // so a build that has not been given one cannot retain anything
            // (Requirement 9.6).
            let store = makeStore(root: root)
            let asset = try await makeAdapter(
                access: FakePhotosAccess.lending(Sample.bytes(count: 256)),
                store: store,
                protection: level
            ).importOne(Sample.pickerItem(), into: Sample.sessionID())

            #expect(asset.handle.protection == level)
            let stored = try #require(await store.receipt(for: asset.handle.storageKey))
            #expect(stored.protection == level)
        }
    }

    // MARK: - The copy happens inside the provider's window

    @Test("The copy completes before the provider's access window closes")
    func copyCompletesInsideTheWindow() async throws {
        try await withTemporaryRoot { root in
            let bytes = Sample.bytes(count: 80_000)
            let store = makeStore(root: root)
            let session = Sample.sessionID()
            let access = WindowObservingPhotosAccess(
                bytes: bytes,
                store: store,
                sessionID: session
            )

            let asset = try await makeAdapter(
                access: access,
                store: store,
                chunkSizeInBytes: 1_024
            ).importOne(Sample.pickerItem(), into: session)

            // The finalized object already existed at the instant the closure returned, so
            // the copy was not deferred past the window.
            #expect(await access.keysAtWindowClose == [asset.handle.storageKey])
            #expect(try await store.read(asset.handle.storageKey) == bytes)
            // And the provider's file was still intact when the copy finished, so the copy
            // read the representation rather than a remnant of it.
            #expect(await access.representationSurvivedTheCopy)
        }
    }

    @Test("A representation reclaimed at the window's close is already fully retained")
    func reclaimedRepresentationIsAlreadyRetained() async throws {
        try await withTemporaryRoot { root in
            let bytes = Sample.bytes(count: 65_537)
            let store = makeStore(root: root)
            // The double removes the lent file the moment the consume closure returns. An
            // adapter that kept the URL and copied afterwards would read nothing.
            let access = FakePhotosAccess.lending(bytes)

            let asset = try await makeAdapter(access: access, store: store, chunkSizeInBytes: 512)
                .importOne(Sample.pickerItem(), into: Sample.sessionID())

            #expect(try await store.read(asset.handle.storageKey) == bytes)
            for lent in await access.lentFiles {
                #expect(!FileManager.default.fileExists(atPath: lent.path))
            }
        }
    }

    @Test("The provider's representation is read only and left exactly as it was")
    func providerRepresentationIsUntouched() async throws {
        try await withTemporaryRoot { root in
            let bytes = Sample.bytes(count: 4_321)
            // Keeping the lent file is the only way to inspect it afterwards.
            let access = FakePhotosAccess.lending(bytes, reclaimsRepresentation: false)
            defer { Task { await access.cleanUp() } }

            _ = try await makeAdapter(access: access, store: makeStore(root: root))
                .importOne(Sample.pickerItem(), into: Sample.sessionID())

            let lent = try #require(await access.lentFiles.first)
            #expect(FileManager.default.fileExists(atPath: lent.path))
            #expect(try Array(Data(contentsOf: lent)) == bytes)
        }
    }

    // MARK: - Conservative preservation status

    @Test(
        "Both provider answers record a conservative unknown status",
        arguments: SuppliedRepresentationForm.allCases
    )
    func statusIsConservativeForEveryProviderAnswer(
        form: SuppliedRepresentationForm
    ) async throws {
        try await withTemporaryRoot { root in
            let asset = try await makeAdapter(
                access: FakePhotosAccess.lending(Sample.bytes(count: 900), form: form),
                store: makeStore(root: root)
            ).importOne(Sample.pickerItem(), into: Sample.sessionID())

            // A `.current` request is not evidence of byte originality, and the picker never
            // declares a transform, so neither answer can reach a stronger status.
            #expect(asset.preservationStatus == .unknown)
            #expect(asset.preservationBasis == form.preservationBasis)
            #expect(asset.preservationBasis.supports(asset.preservationStatus))
            #expect(asset.preservationStatus != .originalBytes)
            #expect(asset.preservationStatus != .platformTransformedCopy)
        }
    }

    @Test("The two provider answers stay distinguishable in the recorded basis")
    func providerAnswersAreDistinguishable() {
        #expect(
            SuppliedRepresentationForm.typedFileRepresentation.preservationBasis
                == .providerDeclaredCurrentRepresentationOnly
        )
        #expect(
            SuppliedRepresentationForm.untypedFileRepresentation.preservationBasis
                == .preservationHistoryNotEstablished
        )
        #expect(
            SuppliedRepresentationForm.typedFileRepresentation.preservationBasis
                != SuppliedRepresentationForm.untypedFileRepresentation.preservationBasis
        )
    }

    // MARK: - Screenshots and every supplied representation are preserved

    @Test(
        "A representation is retained whatever the provider called it",
        arguments: ["public.png", "public.jpeg", "public.heic", "public.heif", "public.tiff"]
    )
    func everySuppliedTypeIsRetainedWithoutClassification(rawHint: String) async throws {
        try await withTemporaryRoot { root in
            // A screenshot arrives as an ordinary PNG or HEIC selection, so preserving it
            // needs no case of its own (Requirement 2.17). The last argument is a container
            // the Input Validator will refuse: ingest still retains it, because deciding
            // what is analyzable belongs to the validator and the actual bytes
            // (Requirements 2.15 and 2.16).
            let bytes = Sample.bytes(count: 2_048)
            let store = makeStore(root: root)
            let hint = Sample.contentTypeHint(rawHint)

            let asset = try await makeAdapter(
                access: FakePhotosAccess.lending(bytes, suppliedContentTypeHint: hint),
                store: store
            ).importOne(Sample.pickerItem(), into: Sample.sessionID())

            #expect(asset.contentTypeHint == hint)
            #expect(try await store.read(asset.handle.storageKey) == bytes)
        }
    }

    @Test("Byte-identical representations retain identically whatever they are called")
    func identicalBytesRetainIdentically() async throws {
        try await withTemporaryRoot { root in
            let bytes = Sample.bytes(count: 5_000)
            let store = makeStore(root: root)

            let screenshot = try await makeAdapter(
                access: FakePhotosAccess.lending(
                    bytes,
                    suppliedContentTypeHint: Sample.contentTypeHint("public.png")
                ),
                store: store
            ).importOne(Sample.pickerItem(), into: Sample.sessionID("session-screenshot"))

            let photo = try await makeAdapter(
                access: FakePhotosAccess.lending(
                    bytes,
                    suppliedContentTypeHint: Sample.contentTypeHint("public.heic")
                ),
                store: store
            ).importOne(Sample.pickerItem(), into: Sample.sessionID("session-photo"))

            #expect(screenshot.sha256 == photo.sha256)
            #expect(screenshot.byteCount == photo.byteCount)
            #expect(screenshot.preservationStatus == photo.preservationStatus)
            #expect(screenshot.route == photo.route)
        }
    }

    // MARK: - A provider that produced nothing

    @Test(
        "A provider failure before any byte never reaches the copy and stores nothing",
        arguments: [
            PhotosProviderFault.itemUnavailable,
            .representationUnavailable,
            .transferFailed,
        ]
    )
    func preByteProviderFailureStoresNothing(fault: PhotosProviderFault) async throws {
        try await withTemporaryRoot { root in
            let store = makeStore(root: root)
            let access = FakePhotosAccess.failing(fault)
            let session = Sample.sessionID()

            let outcome = await makeAdapter(access: access, store: store)
                .attemptImport(of: Sample.pickerItem(), into: session)

            #expect(outcome == .failure(.noRepresentationObtained(fault)))
            // No byte of the item was ever read, so the copy was never entered and the
            // session scope holds nothing.
            #expect(await access.consumeCount == 0)
            #expect(await store.keys(in: .session(session)).isEmpty)
            #expect(await store.occupiedScopes().isEmpty)
        }
    }

    @Test("A pre-byte provider failure crosses the port as an ingest fault, not a verdict")
    func preByteProviderFailureCrossesThePortAsAFault() async throws {
        try await withTemporaryRoot { root in
            let adapter = makeAdapter(
                access: FakePhotosAccess.failing(.representationUnavailable),
                store: makeStore(root: root)
            )

            await #expect(throws: AnalysisFault.self) {
                _ = try await adapter.importOne(Sample.pickerItem(), into: Sample.sessionID())
            }
            // The port has no way to say "no session", so the fault is only the transport.
            // It is never `handoff-error`, which belongs to the Share route alone.
            let fault = PhotosImportFailure
                .noRepresentationObtained(.representationUnavailable).fault
            #expect(fault.analysisError != .handoffError)
            #expect(fault.stage == .mediaClassification)
        }
    }

    @Test("Provider cancellation is cancellation, never an error category")
    func providerCancellationIsNotAnError() async throws {
        try await withTemporaryRoot { root in
            let store = makeStore(root: root)
            let access = FakePhotosAccess.failing(.cancelled)
            let session = Sample.sessionID()
            let adapter = makeAdapter(access: access, store: store)

            #expect(
                await adapter.attemptImport(of: Sample.pickerItem(), into: session)
                    == .failure(.cancelled)
            )
            await #expect(throws: AnalysisFault.cancelled) {
                _ = try await adapter.importOne(Sample.pickerItem(), into: session)
            }
            #expect(await store.occupiedScopes().isEmpty)
        }
    }

    // MARK: - A representation that did not finish copying

    @Test("An empty representation is refused and leaves nothing behind")
    func emptyRepresentationIsRefused() async throws {
        try await withTemporaryRoot { root in
            let store = makeStore(root: root)
            let access = FakePhotosAccess.lending([])
            let session = Sample.sessionID()

            let outcome = await makeAdapter(access: access, store: store)
                .attemptImport(of: Sample.pickerItem(), into: session)

            // A representation *was* offered, which is what keeps this distinct from a
            // provider that produced nothing.
            #expect(outcome == .failure(.representationNotRetained(.emptySource)))
            #expect(await access.consumeCount == 1)
            #expect(await store.keys(in: .session(session)).isEmpty)
        }
    }

    @Test("A copy that exceeds the store's capacity is a resource-limit fault")
    func capacityBreachIsAResourceLimit() async throws {
        try await withTemporaryRoot { root in
            let store = makeStore(root: root, capacityInBytes: 512)
            let session = Sample.sessionID()
            let adapter = makeAdapter(
                access: FakePhotosAccess.lending(Sample.bytes(count: 8_000)),
                store: store,
                chunkSizeInBytes: 128
            )

            let outcome = await adapter.attemptImport(of: Sample.pickerItem(), into: session)
            #expect(
                outcome
                    == .failure(
                        .representationNotRetained(
                            .store(.capacityExceeded(scope: .session(session)))
                        )
                    )
            )
            // A bounded ceiling refused the copy, which is the one retention failure with a
            // truthful user-facing category.
            let failure = try #require(outcome.failure)
            #expect(failure.fault == .analysis(.resourceLimit, stage: .mediaClassification))
            #expect(await store.keys(in: .session(session)).isEmpty)
            let used = try await store.usedByteCount()
            #expect(used == 0)
        }
    }

    @Test("A protection level that cannot be applied fails closed and stores nothing")
    func unavailableProtectionFailsClosed() async throws {
        try await withTemporaryRoot { root in
            let store = ProtectedEphemeralFileStore(
                configuration: .test(root: root, containerProtection: .completeUnlessOpen),
                protection: RefusingDataProtection(refusedLevel: .complete),
                clock: FixedClock()
            )
            let session = Sample.sessionID()

            let outcome = await makeAdapter(
                access: FakePhotosAccess.lending(Sample.bytes(count: 256)),
                store: store,
                protection: .complete
            ).attemptImport(of: Sample.pickerItem(), into: session)

            #expect(
                outcome
                    == .failure(
                        .representationNotRetained(.store(.protectionUnavailable(.complete)))
                    )
            )
            #expect(await store.keys(in: .session(session)).isEmpty)
        }
    }

    @Test("Cancelling during the copy leaves nothing behind and is not an error")
    func cancellationDuringCopyLeavesNothing() async throws {
        try await withTemporaryRoot { root in
            let store = makeStore(root: root)
            let session = Sample.sessionID()
            let adapter = makeAdapter(
                access: FakePhotosAccess.lending(Sample.bytes(count: 400_000)),
                store: store,
                chunkSizeInBytes: 256
            )

            let task = Task {
                await adapter.attemptImport(of: Sample.pickerItem(), into: session)
            }
            task.cancel()

            let outcome = await task.value
            #expect(outcome == .failure(.cancelled))
            let failure = try #require(outcome.failure)
            #expect(failure.fault == .cancelled)
            #expect(await store.keys(in: .session(session)).isEmpty)
            let used = try await store.usedByteCount()
            #expect(used == 0)
        }
    }

    // MARK: - The narrowed port view

    @Test("No import failure maps to a handoff error")
    func noFailureBecomesAHandoffError() {
        // `handoff-error` is the Share route's category. The Photos route has no handoff to
        // verify, so nothing here may produce it (Requirement 2.19).
        var failures: [PhotosImportFailure] = [.cancelled]
        for fault in PhotosProviderFault.allCases {
            failures.append(.noRepresentationObtained(fault))
        }
        for error in Self.retentionErrors {
            failures.append(.representationNotRetained(error))
        }
        for failure in failures {
            #expect(failure.fault.analysisError != .handoffError)
        }
    }

    @Test("Cancellation never acquires an error category, whichever side it arrived from")
    func cancellationNeverBecomesAnErrorCategory() {
        for failure: PhotosImportFailure in [
            .cancelled,
            .noRepresentationObtained(.cancelled),
            .representationNotRetained(.cancelled),
        ] {
            #expect(failure.fault == .cancelled)
            #expect(failure.fault.analysisError == nil)
        }
    }

    @Test("Every failure that is not a cancellation reports the same ingest stage")
    func nonCancellationFailuresReportOneStage() {
        var failures: [PhotosImportFailure] = []
        for fault in PhotosProviderFault.allCases where fault != .cancelled {
            failures.append(.noRepresentationObtained(fault))
        }
        for error in Self.retentionErrors where error != .cancelled {
            failures.append(.representationNotRetained(error))
        }
        #expect(!failures.isEmpty)
        for failure in failures {
            #expect(failure.fault.stage == PhotosImportFailure.stage)
        }
    }

    /// Every ``EncodedAssetRetentionError`` shape, since the type is not `CaseIterable`.
    private static let retentionErrors: [EncodedAssetRetentionError] = [
        .sourceUnreadable,
        .emptySource,
        .incompleteCopy(expectedByteCount: 10, copiedByteCount: 4),
        .cancelled,
        .store(.storeUnavailable),
        .store(.capacityExceeded(scope: .session(Sample.sessionID()))),
        .store(.protectionUnavailable(.complete)),
        .store(.notFound(Sample.storageKey("0123456789abcdef0123456789abcdef"))),
    ]
}

extension Result {
    /// The failure, or `nil` on success. Reads better than a `switch` in an assertion.
    var failure: Failure? {
        guard case .failure(let error) = self else { return nil }
        return error
    }
}
