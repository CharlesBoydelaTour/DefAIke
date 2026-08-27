import DefAIkeDomain
import Foundation
import Testing

@testable import DefAIkeSharedTransfer

/// The bounded manifest encoding: what round-trips, what is refused, and why.
///
/// The manifest crosses a process boundary, so its reader is the adversary's target: a
/// payload that decodes two ways, or decodes at all when it should not, would let the app
/// and the extension disagree about which bytes were handed off. Every rejection here is one
/// the claim path would otherwise have to catch by hand.
@Suite("Transfer manifest encoding")
struct TransferManifestTests {

    private func makeManifest(
        ticket: ShareTransferTicket = Sample.ticket(),
        manifestKey: String = "0123456789abcdef0123456789abcdef",
        payloadKey: String = "fedcba9876543210fedcba9876543210"
    ) -> TransferManifest {
        guard let manifest = TransferManifest(
            ticket: ticket,
            manifestKey: Sample.storageKey(manifestKey),
            payloadKey: Sample.storageKey(payloadKey)
        ) else {
            preconditionFailure("the manifest fixture must be internally consistent")
        }
        return manifest
    }

    // MARK: - Round trip

    @Test("A manifest round-trips through the bounded encoding unchanged")
    func roundTripPreservesEveryField() throws {
        let manifest = makeManifest()

        let decoded = try TransferManifestCoding.decode(
            try TransferManifestCoding.encode(manifest)
        )

        #expect(decoded == manifest)
        #expect(decoded.ticket == manifest.ticket)
        // The timestamp matters on its own: a truncating date strategy would leave the
        // manifest equal in every other field and silently change the expiry evaluation.
        #expect(decoded.ticket.createdAt == manifest.ticket.createdAt)
    }

    @Test("Encoding is deterministic, so the same manifest is the same bytes")
    func encodingIsDeterministic() throws {
        let manifest = makeManifest()

        let first = try TransferManifestCoding.encode(manifest)
        let second = try TransferManifestCoding.encode(manifest)

        #expect(first == second)
    }

    @Test("A manifest whose every field is at its ceiling still fits the bound")
    func maximalManifestFitsTheCeiling() throws {
        // The ceiling is derived from the schema's own bounds rather than chosen freely, so
        // a manifest that saturates every one of them has to encode within it. Without this
        // the constant is a guess, and the failure mode would be a share that cannot be
        // published for an image that is perfectly fine.
        let maximal = Sample.ticket(
            transferID: Sample.transferID(String(repeating: "t", count: 256)),
            sessionID: Sample.sessionID(String(repeating: "s", count: 256)),
            contentTypeHint: Sample.contentTypeHint(String(repeating: "h", count: 128)),
            byteCount: UInt64.max,
            extensionBuildID: Sample.buildID(String(repeating: "b", count: 256))
        )

        let encoded = try TransferManifestCoding.encode(makeManifest(ticket: maximal))

        #expect(UInt64(encoded.count) <= TransferManifestCoding.maximumEncodedByteCount)
        #expect(try TransferManifestCoding.decode(encoded).ticket == maximal)
    }

    // MARK: - Structural rejection

    @Test("A manifest cannot name itself as its own payload")
    func selfReferentialPayloadIsRejected() {
        let key = "0123456789abcdef0123456789abcdef"
        #expect(
            TransferManifest(
                ticket: Sample.ticket(),
                manifestKey: Sample.storageKey(key),
                payloadKey: Sample.storageKey(key)
            ) == nil
        )
    }

    @Test("An unreadable envelope version is rejected rather than interpreted")
    func unknownEnvelopeVersionIsRejected() {
        #expect(
            TransferManifest(
                schemaVersion: TransferManifest.currentSchemaVersion + 1,
                ticket: Sample.ticket(),
                manifestKey: Sample.storageKey("0123456789abcdef0123456789abcdef"),
                payloadKey: Sample.storageKey("fedcba9876543210fedcba9876543210")
            ) == nil
        )
    }

    @Test("A payload over the ceiling is refused before it is decoded")
    func oversizePayloadIsRefused() throws {
        let padded = Array(
            Data(
                """
                {"schemaVersion":1,"padding":"\(String(repeating: "x", count: 5_000))"}
                """.utf8
            )
        )

        let fault = decodingFault(of: padded)

        guard case .some(.unreadable(.payloadTooLarge(let limit, let actual))) = fault else {
            Issue.record("expected a payload-too-large rejection, got \(String(describing: fault))")
            return
        }
        #expect(limit == TransferManifestCoding.maximumEncodedByteCount)
        #expect(actual == UInt64(padded.count))
    }

    @Test("A duplicated key is refused rather than silently resolved")
    func duplicateKeyIsRefused() {
        // The reason the profile exists. A general-purpose decoder keeps one of the two
        // silently, so the same handed-off bytes could read as two different tickets in the
        // two processes and the byte-identity comparison would stop pinning anything.
        let duplicated = Array(Data(#"{"schemaVersion":1,"schemaVersion":1}"#.utf8))

        let fault = decodingFault(of: duplicated)

        guard case .some(.unreadable(.duplicateKey(_, let key))) = fault else {
            Issue.record("expected a duplicate-key rejection, got \(String(describing: fault))")
            return
        }
        #expect(key == "schemaVersion")
    }

    @Test("Image bytes are not mistaken for a manifest")
    func arbitraryBytesAreNotAManifest() {
        // Deliberately not JSON: the payload object in a transfer slot holds encoded image
        // bytes, and resolution must reject them without inspecting them for structure.
        #expect(decodingFault(of: Sample.bytes(count: 512)) != nil)
    }

    @Test("A ticket whose status and basis were altered independently is refused")
    func tamperedPreservationPairIsRefused() throws {
        // The pair is the interesting mutation because each field is individually
        // plausible. `PreservationBasis.supports` is what makes the combination
        // unrepresentable, and the manifest decode has to inherit that rather than
        // re-implement it.
        let encoded = try TransferManifestCoding.encode(
            makeManifest(
                ticket: Sample.ticket(
                    preservationBasis: .providerDeclaredCurrentRepresentationOnly
                )
            )
        )
        let tampered = String(decoding: encoded, as: UTF8.self)
            .replacingOccurrences(of: "\"unknown\"", with: "\"originalBytes\"")

        #expect(decodingFault(of: Array(tampered.utf8)) != nil)
    }

    /// The fault `bytes` produce, or `nil` when they decode.
    private func decodingFault(of bytes: [UInt8]) -> TransferManifestCodingFault? {
        do {
            _ = try TransferManifestCoding.decode(bytes)
            return nil
        } catch {
            return error
        }
    }
}
