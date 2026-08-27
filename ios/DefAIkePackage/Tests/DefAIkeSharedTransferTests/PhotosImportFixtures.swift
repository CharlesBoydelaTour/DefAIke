import DefAIkeDomain
import Foundation

@testable import DefAIkeSharedTransfer

// The provider seam double, and the picker values the Photos adapter needs as arguments.
//
// The important thing about ``FakePhotosAccess`` is that its access window is **real**: it
// writes the programmed bytes to a temporary file, lends that file for exactly the length
// of the consume closure, and removes it the moment the closure returns. An adapter that
// captured the URL and read it afterwards would find nothing, so "copy it before the
// provider's access expires" is a property the double enforces rather than a comment the
// tests trust.
//
// **No value here is an approved release value.** The byte sequences, capacities, and
// protection levels are test scaffolding.

extension Sample {
    /// One selected item, with the hint the *picker* claimed for the placeholder.
    ///
    /// Distinct from the hint the provider supplies with the bytes: the adapter records the
    /// second, never the first.
    static func pickerItem(
        token: UInt64 = 1,
        contentTypeHint: ContentTypeHint? = Sample.contentTypeHint()
    ) -> PhotosPickerItemReference {
        PhotosPickerItemReference(
            token: ProviderToken(rawValue: token),
            contentTypeHint: contentTypeHint
        )
    }
}

/// A ``PhotosRepresentationAccess`` whose access window really closes.
///
/// Programmed with one outcome per instance, because one instance stands for one picker
/// presentation. It records what it did so a test can assert a nonoccurrence — most
/// importantly that a provider which produced nothing never reached the copy at all.
actor FakePhotosAccess: PhotosRepresentationAccess {

    /// What this provider does when asked for a representation.
    enum Offer: Sendable {
        /// Lend a representation built from `bytes` for the length of the window.
        case representation(
            bytes: [UInt8],
            form: SuppliedRepresentationForm,
            suppliedContentTypeHint: ContentTypeHint?
        )

        /// Produce no representation at all, so no byte is ever read.
        case noRepresentation(PhotosProviderFault)
    }

    private let offer: Offer

    /// Whether the lent file is removed when the window closes.
    ///
    /// Removal is the realistic behavior and the default. A test can keep the file to prove
    /// that the adapter left the provider's representation untouched.
    private let reclaimsRepresentation: Bool

    /// Items the provider was asked about, in order.
    private(set) var requestedItems: [PhotosPickerItemReference] = []

    /// How many times the consume closure ran.
    private(set) var consumeCount = 0

    /// Files this provider lent, so a test can check they are gone afterwards.
    private(set) var lentFiles: [URL] = []

    init(_ offer: Offer, reclaimsRepresentation: Bool = true) {
        self.offer = offer
        self.reclaimsRepresentation = reclaimsRepresentation
    }

    /// Lends a representation containing `bytes`, typed as a requested container.
    static func lending(
        _ bytes: [UInt8],
        form: SuppliedRepresentationForm = .typedFileRepresentation,
        suppliedContentTypeHint: ContentTypeHint? = Sample.contentTypeHint(),
        reclaimsRepresentation: Bool = true
    ) -> FakePhotosAccess {
        FakePhotosAccess(
            .representation(
                bytes: bytes,
                form: form,
                suppliedContentTypeHint: suppliedContentTypeHint
            ),
            reclaimsRepresentation: reclaimsRepresentation
        )
    }

    /// Produces nothing, which is the pre-byte provider failure.
    static func failing(_ fault: PhotosProviderFault) -> FakePhotosAccess {
        FakePhotosAccess(.noRepresentation(fault))
    }

    func withRepresentation(
        of item: PhotosPickerItemReference,
        consume: @Sendable (BorrowedRepresentation) async -> RetainedRepresentation
    ) async throws(PhotosProviderFault) -> RetainedRepresentation {
        requestedItems.append(item)

        switch offer {
        case .noRepresentation(let fault):
            // Nothing is written and `consume` is never called, so no byte of the item
            // exists anywhere in DefAIke.
            throw fault

        case .representation(let bytes, let form, let hint):
            guard let fileURL = try? Self.writeTemporaryRepresentation(bytes) else {
                throw .transferFailed
            }
            lentFiles.append(fileURL)
            consumeCount += 1
            let outcome = await consume(
                BorrowedRepresentation(
                    fileURL: fileURL,
                    suppliedContentTypeHint: hint,
                    form: form
                )
            )
            // The window closes here. A framework provider reclaims its temporary
            // representation at this point, so this one does too.
            if reclaimsRepresentation {
                try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
            }
            return outcome
        }
    }

    /// Removes anything this provider lent and did not reclaim.
    func cleanUp() {
        for file in lentFiles {
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
    }

    private static func writeTemporaryRepresentation(_ bytes: [UInt8]) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: "defaike-picker-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A provider-shaped name, so nothing downstream can be reading the extension.
        let fileURL = directory.appending(path: "representation", directoryHint: .notDirectory)
        try Data(bytes).write(to: fileURL)
        return fileURL
    }
}

/// A provider that lends a representation and reports what the adapter did inside the
/// window.
///
/// Used for the one assertion the ordinary double cannot make: that the retained bytes were
/// already complete *before* the window closed, rather than complete only because the file
/// happened to survive.
actor WindowObservingPhotosAccess: PhotosRepresentationAccess {
    private let bytes: [UInt8]
    private let store: any EphemeralFileStoring

    /// Keys the session scope owned at the instant the consume closure returned.
    private(set) var keysAtWindowClose: Set<EphemeralStorageKey> = []

    /// Whether the lent file still existed when the closure returned.
    private(set) var representationSurvivedTheCopy = false

    private let sessionID: AnalysisSessionID

    init(bytes: [UInt8], store: any EphemeralFileStoring, sessionID: AnalysisSessionID) {
        self.bytes = bytes
        self.store = store
        self.sessionID = sessionID
    }

    func withRepresentation(
        of item: PhotosPickerItemReference,
        consume: @Sendable (BorrowedRepresentation) async -> RetainedRepresentation
    ) async throws(PhotosProviderFault) -> RetainedRepresentation {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: "defaike-window-\(UUID().uuidString)", directoryHint: .isDirectory)
        guard
            (try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )) != nil
        else {
            throw .transferFailed
        }
        let fileURL = directory.appending(path: "representation", directoryHint: .notDirectory)
        guard (try? Data(bytes).write(to: fileURL)) != nil else { throw .transferFailed }

        let outcome = await consume(
            BorrowedRepresentation(
                fileURL: fileURL,
                suppliedContentTypeHint: Sample.contentTypeHint(),
                form: .typedFileRepresentation
            )
        )
        keysAtWindowClose = await store.keys(in: .session(sessionID))
        representationSurvivedTheCopy = FileManager.default.fileExists(atPath: fileURL.path)
        try? FileManager.default.removeItem(at: directory)
        return outcome
    }
}
