import DefAIkeDomain
import Foundation
import Testing

@testable import DefAIkeApplication

/// The Photos route's one-item ingest coordinator.
///
/// The rule this suite exists to pin down is the design's line between an ingest attempt
/// and an Analysis Session: a session exists only once exactly one complete local
/// representation has been retained. Everything else follows from it — a dismissed picker,
/// a selection of any other count, a cancellation, and a provider that produced nothing all
/// end with no session, and they stay distinguishable from one another (Requirements 2.1,
/// 2.5, 2.7, 2.8, 2.18).
@Suite("Photos ingest coordinator")
struct PhotosIngestCoordinatorTests {

    private func makeCoordinator(
        importer: RecordingPhotosImporter,
        identity: ScriptedSessionIdentity = ScriptedSessionIdentity("session-candidate-0001")
    ) -> PhotosIngestCoordinator {
        PhotosIngestCoordinator(importer: importer, identity: identity)
    }

    // MARK: - A session only for exactly one local representation

    @Test("One selected item with a retained representation creates exactly one session")
    func oneItemCreatesOneSession() async throws {
        let importer = RecordingPhotosImporter(.accept)
        let identity = ScriptedSessionIdentity("session-candidate-0001")
        let coordinator = makeCoordinator(importer: importer, identity: identity)

        let outcome = await coordinator.ingest(Fixture.selection(itemCount: 1))

        let asset = try #require(outcome.acceptedIngest)
        #expect(asset.route == .photosPicker)
        #expect(asset.sessionID == Fixture.sessionID("session-candidate-0001"))
        #expect(outcome.sessionID == asset.sessionID)
        #expect(outcome.refusal == nil)
        // The candidate the coordinator minted is the identity the session took.
        #expect(identity.mintedIdentifiers == [asset.sessionID])
        #expect(await importer.calls.map(\.sessionID) == [asset.sessionID])
    }

    @Test("The one item the coordinator imports is the sole selected item")
    func theImportedItemIsTheSoleSelection() async throws {
        let importer = RecordingPhotosImporter(.accept)
        let selection = Fixture.selection(itemCount: 1)

        _ = await makeCoordinator(importer: importer).ingest(selection)

        let call = try #require(await importer.calls.first)
        #expect(call.token == selection.items[0].token)
    }

    @Test("A refused attempt creates no session and carries no ingest")
    func refusedAttemptCarriesNoIngest() async {
        let outcome = await makeCoordinator(importer: RecordingPhotosImporter([]))
            .ingest(Fixture.selection(itemCount: 0))

        // Structural: only the `sessionCreated` case can hold an asset, so a refusal has
        // nothing to carry and no session identifier to expose.
        #expect(outcome.acceptedIngest == nil)
        #expect(outcome.sessionID == nil)
    }

    // MARK: - Picker cancellation

    @Test("An empty selection ends the picker flow with no session")
    func emptySelectionIsCancellation() async {
        let importer = RecordingPhotosImporter([])
        let identity = ScriptedSessionIdentity([])

        let outcome = await PhotosIngestCoordinator(importer: importer, identity: identity)
            .ingest(PhotosPickerSelection(items: []))

        #expect(outcome == .noSession(.pickerCancelled))
        // Nothing was minted and no provider was touched, so there is nothing to clean up
        // and no evidence verdict to suppress (Requirement 2.18).
        #expect(identity.mintedIdentifiers.isEmpty)
        #expect(await importer.callCount == 0)
    }

    @Test("A dismissed picker is not a rejected selection")
    func dismissalIsDistinctFromRejection() async {
        let dismissed = await makeCoordinator(importer: RecordingPhotosImporter([]))
            .ingest(Fixture.selection(itemCount: 0))
        let rejected = await makeCoordinator(importer: RecordingPhotosImporter([]))
            .ingest(Fixture.selection(itemCount: 2))

        #expect(dismissed == .noSession(.pickerCancelled))
        #expect(rejected == .noSession(.itemCountRefused(2)))
        #expect(dismissed != rejected)
    }

    // MARK: - Any count other than one

    @Test(
        "A selection of any count other than one is refused before a session exists",
        arguments: [2, 3, 5, 17]
    )
    func multipleItemsAreRefused(count: Int) async {
        let importer = RecordingPhotosImporter([])
        let identity = ScriptedSessionIdentity([])

        let outcome = await PhotosIngestCoordinator(importer: importer, identity: identity)
            .ingest(Fixture.selection(itemCount: count))

        #expect(outcome == .noSession(.itemCountRefused(count)))
        // The count check runs before anything else, so no candidate is minted and no byte
        // is read for a selection that was always going to be refused (Requirement 2.7).
        #expect(identity.mintedIdentifiers.isEmpty)
        #expect(await importer.callCount == 0)
    }

    @Test("There is no path that takes the first item of a multiple selection")
    func noPathTakesTheFirstOfMany() async {
        let importer = RecordingPhotosImporter([.accept])
        let outcome = await makeCoordinator(
            importer: importer,
            identity: ScriptedSessionIdentity([])
        ).ingest(Fixture.selection(itemCount: 4))

        #expect(outcome.acceptedIngest == nil)
        #expect(await importer.callCount == 0)
    }

    // MARK: - No local representation

    @Test(
        "Every import error category ends the attempt with no session",
        arguments: AnalysisError.allCases
    )
    func importErrorProducesNoSession(category: AnalysisError) async {
        let importer = RecordingPhotosImporter(
            .fail(.analysis(category, stage: .mediaClassification))
        )

        let outcome = await makeCoordinator(importer: importer).ingest(
            Fixture.selection(itemCount: 1)
        )

        // The category is recorded for an audit, not committed as a session's terminal
        // Analysis Error: no session exists to terminate.
        #expect(outcome == .noSession(.noLocalRepresentation(category)))
        #expect(outcome.acceptedIngest == nil)
        #expect(await importer.callCount == 1)
    }

    @Test("A provider failure and a cancellation are different no-session outcomes")
    func providerFailureAndCancellationStayDistinct() async {
        let providerFault = AnalysisFault.analysis(.decodingError, stage: .mediaClassification)
        let failed = await makeCoordinator(
            importer: RecordingPhotosImporter(.fail(providerFault))
        ).ingest(Fixture.selection(itemCount: 1))
        let cancelled = await makeCoordinator(
            importer: RecordingPhotosImporter(.fail(.cancelled))
        ).ingest(Fixture.selection(itemCount: 1))

        #expect(failed == .noSession(.noLocalRepresentation(.decodingError)))
        #expect(cancelled == .noSession(.cancelled))
        #expect(failed != cancelled)
    }

    @Test("Cancellation during the attempt is never recorded as an error category")
    func cancellationIsNotAnErrorCategory() async throws {
        let outcome = await makeCoordinator(
            importer: RecordingPhotosImporter(.fail(.cancelled))
        ).ingest(Fixture.selection(itemCount: 1))

        #expect(outcome == .noSession(.cancelled))
        let refusal = try #require(outcome.refusal)
        // A cancellation cannot be read back as `noLocalRepresentation(_:)` of any
        // category, so it cannot be presented as a failure (Requirement 11.17).
        for category in AnalysisError.allCases {
            #expect(refusal != .noLocalRepresentation(category))
        }
    }

    // MARK: - The port's answer has to belong to this attempt

    @Test("An ingest for another session is refused rather than bound")
    func foreignSessionIsRefused() async {
        let importer = RecordingPhotosImporter(
            .returnAsset { _ in
                Fixture.importedAsset(sessionID: Fixture.sessionID("session-somebody-else"))
            }
        )

        let outcome = await makeCoordinator(importer: importer).ingest(
            Fixture.selection(itemCount: 1)
        )

        // Binding this would mean two sessions in play for one selection, which is what
        // Requirement 2.5 forbids.
        #expect(outcome == .noSession(.foreignIngest))
    }

    @Test("An ingest recorded against the other route is refused rather than bound")
    func foreignRouteIsRefused() async {
        let importer = RecordingPhotosImporter(
            .returnAsset { session in
                Fixture.importedAsset(route: .shareExtension, sessionID: session)
            }
        )

        let outcome = await makeCoordinator(importer: importer).ingest(
            Fixture.selection(itemCount: 1)
        )

        // Exactly one route is recorded per session, and this route is the Photos picker
        // (Requirement 2.8).
        #expect(outcome == .noSession(.foreignIngest))
    }

    @Test("Both Version 1 routes exist, and this coordinator only ever records one")
    func onlyOneRouteIsRecorded() async throws {
        #expect(InputRoute.allCases == [.photosPicker, .shareExtension])
        let outcome = await makeCoordinator(importer: RecordingPhotosImporter(.accept))
            .ingest(Fixture.selection(itemCount: 1))
        let asset = try #require(outcome.acceptedIngest)
        #expect(asset.route == .photosPicker)
    }

    // MARK: - Nothing crosses between attempts

    @Test("A new selection after a refusal starts from nothing")
    func attemptsShareNothing() async throws {
        let importer = RecordingPhotosImporter([
            .fail(.analysis(.decodingError, stage: .mediaClassification)),
            .accept,
        ])
        let identity = ScriptedSessionIdentity(
            "session-candidate-first",
            "session-candidate-second"
        )
        let coordinator = PhotosIngestCoordinator(importer: importer, identity: identity)

        let refused = await coordinator.ingest(Fixture.selection(itemCount: 1))
        let accepted = await coordinator.ingest(Fixture.selection(itemCount: 1))

        #expect(refused == .noSession(.noLocalRepresentation(.decodingError)))
        let asset = try #require(accepted.acceptedIngest)
        // A fresh candidate, and no trace of the first attempt's category in the second
        // outcome. The coordinator holds no state, so there is nowhere for one to hide.
        #expect(asset.sessionID == Fixture.sessionID("session-candidate-second"))
        #expect(accepted.refusal == nil)
        #expect(
            identity.mintedIdentifiers == [
                Fixture.sessionID("session-candidate-first"),
                Fixture.sessionID("session-candidate-second"),
            ]
        )
    }

    @Test("Exactly one candidate identifier is minted per attempt that reaches the port")
    func oneCandidatePerAttempt() async {
        let importer = RecordingPhotosImporter([.accept, .accept])
        let identity = ScriptedSessionIdentity("session-candidate-a", "session-candidate-b")
        let coordinator = PhotosIngestCoordinator(importer: importer, identity: identity)

        _ = await coordinator.ingest(Fixture.selection(itemCount: 1))
        _ = await coordinator.ingest(Fixture.selection(itemCount: 1))

        #expect(identity.mintedIdentifiers.count == 2)
        #expect(await importer.callCount == 2)
    }

    // MARK: - Candidate identifiers

    @Test("Minted candidate identifiers are canonical, opaque, and distinct")
    func randomIdentitiesAreCanonicalAndDistinct() {
        let identity = RandomAnalysisSessionIdentity()
        var seen: Set<AnalysisSessionID> = []
        for _ in 0..<256 {
            let minted = identity.mintCandidateSessionID()
            // 16 random bytes in hexadecimal, carrying no file name, asset identifier, or
            // byte-derived value (Requirement 9.11).
            #expect(minted.rawValue.count == 32)
            #expect(minted.rawValue.allSatisfy { $0.isHexDigit && !$0.isUppercase })
            #expect(seen.insert(minted).inserted)
        }
    }

    @Test("Nothing in the module reaches the photo library or requests authorization")
    func moduleRequestsNoLibraryAuthorization() throws {
        // Requirement 9.4 is selected-item access. The coordinator reaches the picker only
        // through the import port, so no photo-library surface may appear here at all; a
        // later change that reaches for one fails this test.
        let forbidden = [
            "import Photos",
            "import PhotosUI",
            "PHPhotoLibrary",
            "PHAsset",
            "PHAuthorizationStatus",
            "requestAuthorization",
            "authorizationStatus",
        ]
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/DefAIkeApplication")
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
