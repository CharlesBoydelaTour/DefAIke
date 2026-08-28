import DefAIkeDomain
import DefAIkePresentation
import DefAIkeProvenanceAPI
import DefAIkeSharedTransfer
import DefAIkeTestSupport
import Foundation
import Testing

@testable import DefAIkeApplication

// Task 12.5: offline sessions, result-persistence absence, and privacy smoke tests.
//
// ## How "networking unavailable" is made real here, and what that does and does not establish
//
// This is the honest part, and it is stated first because everything below depends on it.
//
// Three mechanisms were available. Only two were used, and neither is the one the requirement
// literally describes:
//
//   1. **A symbol and source audit proving no network API is reachable.** Used, and it is the
//      primary evidence — but it lives in `ios/Scripts/check-offline-privacy-archive.py`, not
//      here, because it is a claim about compiled bytes rather than about running code. That
//      script attributes **every** compiled object in both built archives, per architecture, and
//      requires zero references to any network symbol from any DefAIke module or Xcode target:
//      446 objects across 10 owners in the pixel-only build and 465 across 11 in the
//      provenance build, all zero. That is the strong claim, and it covers the shipping platform
//      adapters this file substitutes.
//   2. **A real sandbox with networking switched off.** Not available. Nothing here pretends
//      otherwise.
//   3. **A fake that fails every network call.** Deliberately **not** used. It would only
//      establish that the code handles a failure, and the claim needed is that no call is made.
//
// What this file adds is the third thing neither of those gives: **the flow actually runs to a
// terminal outcome, and the value graph it assembles and produces contains nothing that could
// transmit.** That is a runtime fact about the shipping `DefAIkeDomain`,
// `DefAIkeApplication`, and `DefAIkePresentation` types, gathered by reflecting over the real
// release, the real coordinator, the real accepted ingest, the real terminal outcome, the real
// Evidence Report, and the real projected screen.
//
// So, precisely:
//
// | Established here | **Not** established here |
// |---|---|
// | Both ingest routes reach one terminal outcome under all three compositions with no network-capable value anywhere in the graph | That the shipping Image I/O, Core ML, or C2PA adapters hold no network client — they are substituted, so a client in one would not be in the graph |
// | The values a session produces carry no request, client, URL builder, or network URL | That an iOS device with connectivity disabled behaves this way; every result here is a host result |
// | Nothing appears in a persistent user-domain directory across a whole flow | That iOS data protection was applied — `PlatformDataProtection.enforcesDataProtection` is `false` off iOS, so **no result here is Requirement 9.6 evidence** |
// | Conditional provenance is driven with an in-process collaborator only | That the real validator is offline. There is **no shipping `ProvenanceAnalyzing` conformance at all**, so the lane's collaborator here is a fixture and the real validator path is unreachable |
//
// ## The asymmetry between the two compositions, stated rather than glossed
//
// The archive audit measures something this file cannot, and it matters enough to write down
// here too. The one built archive is **not** uniform across the bundles inside it:
//
//   * The **Share Extension**'s `.appex` images reference zero network symbols and contain zero
//     URL-like strings, once the code-signing DOCTYPE URL is excluded — `codesign` embeds the
//     entitlements as an XML plist whose DOCTYPE names the property-list DTD, so a signed build
//     carries that one string in every image with an entitlements blob and an unsigned build
//     carries none. Its offline guarantee is *absence*, and it is the absence case that keeps
//     the application's non-zero counts a measurement rather than the only observation in a run.
//     (A second application archive used to supply that case, before the two capability
//     compositions were merged into one.)
//   * The **application**'s `DefAIke.debug.dylib` references ten — `URLSession`,
//     `NSURLSession`, `URLRequest`, `NSURLRequest`, and the POSIX `socket`, `connect`,
//     `sendto`, `recvfrom`, `socketpair`, `getaddrinfo` — because it statically links the
//     reviewed validator. The Swift-level four are attributable to `C2PA.o`, the vendor wrapper;
//     the POSIX ones belong to no products-directory object at all, because they arrive from the
//     420 MB `C2PAC` static archive, whose readable members define symbols from `reqwest`,
//     `hyper`, `hyper-rustls`, `h2`, `rustls`, `webpki`, and `tokio`. Its offline guarantee is
//     therefore **runtime configuration** — `C2PALibraryReader.applyOfflineSettings`, with
//     `remoteManifestFetch: false`, `ocspFetch: false`, `allowedNetworkHosts: []` — and not
//     absence.
//
// No DefAIke module references any of them. That is what makes the
// difference a Provenance Feasibility Gate security-review input rather than a violation of this
// task: nothing here added the capability, and removing it means removing the reviewed
// validator.
//
// ## Nothing here is an approved release value
//
// Every identifier, deadline, budget, payload, and copy key comes from task 12.4's synthetic
// scaffolding. No number below may be copied into a shipping artifact, and no host result here
// is physical-device evidence.

extension Tag {
    /// Task 12.5's offline, archive-composition, and privacy smoke scenarios.
    @Tag static var offlinePrivacySmoke: Self
}

// MARK: - Offline sessions

@Suite(
    "Offline sessions: a full flow completes with no network-capable value in the graph",
    .tags(.offlinePrivacySmoke)
)
@MainActor
struct OfflineAnalysisSessionTests {

    @Test(
        "Every route and composition reaches a terminal outcome with no transmitting value",
        arguments: FlowRoute.allCases,
        FlowComposition.allCases
    )
    func aFlowCompletesWithNothingThatCouldTransmit(
        route: FlowRoute,
        composition: FlowComposition
    ) async throws {
        let flow = try await AnalysisFlow.make(composition)
        let run = try await flow.runFlow(route)
        let session = run.session

        // The session really ran, and really finished. An audit over a graph that never analyzed
        // anything would be measuring an idle object.
        #expect(session.outcome.isCompleted)
        #expect(session.error == nil)
        let report = try #require(session.evidenceReport)
        #expect(report.binding.sessionID == run.sessionID)
        // The route is asserted on the accepted ingest rather than on the report, because
        // `EvidenceReport` carries no route member at all. That is a known gap this task did not
        // create and does not fix: task 12.4 recorded that the input route is absent from the
        // Evidence Report, and Requirement 8.12 wants the Byte Preservation Status and the bound
        // versions exposed but never names the route. Asserting it here would have required
        // inventing a member.
        #expect(run.asset.route == route.recordedRoute)

        // Every stage ran without connectivity, including the two conditional ones.
        let kinds = flow.recorder.callKinds
        #expect(kinds.contains(.validate))
        #expect(kinds.contains(.preprocess))
        #expect(kinds.contains(.loadModel))
        #expect(kinds.contains(.infer))
        #expect(kinds.contains(.calibrate))
        #expect(kinds.contains(.provenanceAnalyze) == composition.enablesProvenance)

        // The whole graph: the release that admitted the session, the coordinator that ran it,
        // the ingest it ran over, and everything it produced.
        let copy = try await flow.copyBinding(for: run.asset)
        let screen = try flow.project(
            session,
            copy: copy,
            onto: AnalysisViewStateProjector()
        ).screen
        let audit = ValueGraphAudit.audit([
            (label: "release", value: flow.release),
            (label: "coordinator", value: flow.coordinator),
            (label: "acceptedIngest", value: run.asset),
            (label: "terminalOutcome", value: session.outcome),
            (label: "evidenceReport", value: report),
            (label: "screen", value: screen),
        ])

        // Hoisted out of the macro. `#expect` with a trailing key-path call fails to produce a
        // diagnostic and in some targets aborts the compiler, so the arrays are built first and
        // the macro sees a plain comparison.
        let transmitting = audit.findings.filter { finding in
            switch finding.kind {
            case .networkClient, .networkRequest, .networkURL, .urlBuilder, .fileHandle:
                true
            case .fileURL:
                false
            }
        }
        #expect(
            transmitting.isEmpty,
            "a completed \(route) flow under \(composition) reaches a transmitting value: \(audit.summary)"
        )

        // Counted work, so silence means the walk looked. Measured at 3,000-plus values for the
        // smallest composition; the floor is deliberately far below that so a graph that shrinks
        // legitimately does not fail here, while a walk that bounced off its first value does.
        #expect(audit.visited > 500, "the audit visited only \(audit.visited) values")
        #expect(!audit.truncations.contains("visit-limit"), "\(audit.truncations.sorted())")
    }

    @Test(
        "The conditional provenance lane is driven by an in-process collaborator only",
        arguments: [FlowComposition.provenanceEnabled, .provenanceAndFusion]
    )
    func theProvenanceLaneNeedsNoConnectivity(composition: FlowComposition) async throws {
        // `.absent` rather than a validated summary. `ProvenanceLane.available(.absent)` is
        // still an available lane, so the arm's subject — that the lane *ran* with no
        // connectivity — is intact, and using the default avoids coupling this file to whether
        // a synthetic claim summary's policy identifier matches the release's bound policy.
        let flow = try await AnalysisFlow.make(composition)
        let run = try await flow.runFlow(.photos)
        let report = try #require(run.session.evidenceReport)

        // The lane ran and produced an enabled state, which is what makes the audit below a
        // statement about a lane that did work (Requirement 6.8).
        #expect(flow.recorder.callKinds.contains(.provenanceAnalyze))
        #expect(report.provenance.isAvailable)

        // The resolved lane provider is reached through the coordinator, so this audit covers
        // the collaborator the coordinator actually called rather than one a test built.
        let audit = ValueGraphAudit.audit(flow.coordinator, named: "coordinator")
        let clients = audit.findings(of: .networkClient)
        let requests = audit.findings(of: .networkRequest)
        #expect(clients.isEmpty, "\(audit.summary)")
        #expect(requests.isEmpty, "\(audit.summary)")
        #expect(audit.visited > 200, "the audit visited only \(audit.visited) values")

        // What this does NOT establish, recorded here rather than left implicit: there is no
        // shipping `ProvenanceAnalyzing` conformance, so the collaborator above is a fixture and
        // the real `c2pa-swift` path is unreachable from any test. The provenance archive's own
        // network capability is measured by
        // `ios/Scripts/check-offline-privacy-archive.py`, which attributes it to the vendor
        // rather than to any DefAIke module.
    }

    @Test("A session under a provenance composition binds no remote policy source")
    func theSessionBindingNamesNoRemoteSource() async throws {
        let flow = try await AnalysisFlow.make(.provenanceAndFusion)
        let run = try await flow.runFlow(.claimedShare)
        let report = try #require(run.session.evidenceReport)

        // Requirement 10.20: the bundle the session is bound to was verified and activated with
        // connectivity disabled. The archive audit establishes no download API is reachable from
        // `DefAIkeModelBundle`; this establishes the binding a *completed* session carries
        // names an artifact identity rather than a location.
        let audit = ValueGraphAudit.audit(report.binding, named: "binding")
        let networkURLs = audit.findings(of: .networkURL)
        let fileURLs = audit.findings(of: .fileURL)
        #expect(networkURLs.isEmpty, "\(audit.summary)")
        #expect(fileURLs.isEmpty, "\(audit.summary)")
        #expect(audit.visited > 30, "the audit visited only \(audit.visited) values")
    }

    // MARK: Non-vacuity

    @Test(
        "The audit reports every kind of transmitting value it claims to detect",
        arguments: PlantedNetworkSurface.Probe.allCases
    )
    func theAuditDetectsAPlantedSurface(probe: PlantedNetworkSurface.Probe) throws {
        let audit = ValueGraphAudit.audit(probe.plantedValue(), named: probe.rawValue)
        let matched = audit.findings(of: probe.expected)

        #expect(
            !matched.isEmpty,
            "the audit missed a planted \(probe.expected.rawValue) in \(probe): \(audit.summary)"
        )
    }

    @Test("The audit descends through optionals and collections")
    func theAuditReachesNestedValues() throws {
        let audit = ValueGraphAudit.audit(PlantedNetworkSurface.Nested(), named: "nested")
        let found = audit.findings(of: .networkURL)
        let paths = found.map(\.path)

        #expect(found.count == 1, "\(audit.summary)")
        // The path proves the walk went through the optional and into the array rather than
        // matching something at the top level.
        #expect(paths == ["nested.inner.endpoints.[0]"], "\(paths)")
    }

    @Test("Every kind the audit declares has a planted value that produces it")
    func everyDetectableKindIsProbed() throws {
        // Guards the probe table against the vocabulary growing past it. A kind with no planted
        // value is a kind nobody has watched fire.
        let probed = Set(PlantedNetworkSurface.Probe.allCases.map(\.expected))
        let unprobed = GraphFinding.Kind.allCases.filter { !probed.contains($0) }

        // `fileURL` and `fileHandle` are deliberately unprobed by a planted value: the flow's own
        // real ingest produces neither, and a probe that manufactured one would be testing
        // `URL.isFileURL` rather than the walk. `fileURL` is reported and never asserted on as a
        // violation, which is why the offline arm splits the kinds explicitly rather than
        // requiring the finding list to be empty.
        let unprobedNames = unprobed.map(\.rawValue).sorted()
        #expect(unprobedNames == ["file-handle", "file-url"], "\(unprobedNames)")
    }
}

// MARK: - Result persistence, export, and sharing absence

@Suite(
    "Privacy smoke: a whole flow persists, exports, and shares nothing",
    .tags(.offlinePrivacySmoke)
)
@MainActor
struct ResultPersistenceAbsenceTests {

    @Test(
        "A whole flow adds nothing to a persistent user-domain directory",
        arguments: FlowRoute.allCases
    )
    func nothingAppearsInAPersistentDirectory(route: FlowRoute) async throws {
        // Opened before the flow exists, so the window covers ingest, analysis, cleanup, and
        // presentation rather than only the analysis.
        let sentinel = FilesystemSentinel(watching: FilesystemSentinel.persistentDomains)
        let watched = sentinel.directories.map(\.path)
        #expect(watched.count == 2, "\(watched)")
        // Both directories must exist and be readable. Without this, a sentinel pointed at a
        // directory it cannot list would report no additions forever, and the arm would pass for
        // the wrong reason — the same failure mode as a symbol scan whose patterns never match.
        for directory in sentinel.directories {
            let exists = FileManager.default.fileExists(atPath: directory.path)
            #expect(exists, "the sentinel cannot watch \(directory.path), which does not exist")
        }

        let flow = try await AnalysisFlow.make(.provenanceAndFusion)
        let run = try await flow.runFlow(route)
        let copy = try await flow.copyBinding(for: run.asset)
        _ = try flow.project(run.session, copy: copy, onto: AnalysisViewStateProjector()).screen

        let additions = sentinel.additions()
        #expect(
            additions.isEmpty,
            "a completed \(route) flow wrote into a persistent directory: \(additions)"
        )

        // Requirements 9.14 and 9.17, on the two stores the flow actually uses. Nothing the
        // session held survives its terminal, in the app-private store or in the App Group
        // container the Share route publishes through.
        let sessionObjects = await flow.sessionObjectCount(run.sessionID)
        let transferScopes = await flow.occupiedTransferScopes()
        #expect(sessionObjects == 0, "the session store still holds \(sessionObjects) object(s)")
        #expect(transferScopes.isEmpty, "\(transferScopes)")
    }

    @Test("The sentinel reports a file created inside its window")
    func theSentinelDetectsAnAddition() throws {
        // Pointed at a directory this test owns rather than at a real persistent domain. Same
        // code path, and it pollutes nothing: a real-domain probe would have to write into the
        // user's `Application Support` to prove the same thing.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: "defaike-t125-probe-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sentinel = FilesystemSentinel(watching: [directory])
        #expect(sentinel.additions().isEmpty)

        let exported = directory.appending(path: "evidence-report.json", directoryHint: .notDirectory)
        try Data([0x7B, 0x7D]).write(to: exported)

        let additions = sentinel.additions()
        #expect(additions == [exported.path], "\(additions)")
    }

    @Test("The sentinel reports a directory created inside its window")
    func theSentinelDetectsADirectoryAddition() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: "defaike-t125-probe-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sentinel = FilesystemSentinel(watching: [directory])
        let history = directory.appending(path: "AnalysisHistory", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)

        let additions = sentinel.additions()
        #expect(additions == [history.path], "\(additions)")
    }

    @Test(
        "No value a session produces is serializable",
        arguments: FlowRoute.allCases,
        FlowComposition.allCases
    )
    func noProducedResultValueIsSerializable(
        route: FlowRoute,
        composition: FlowComposition
    ) async throws {
        let flow = try await AnalysisFlow.make(composition)
        let run = try await flow.runFlow(route)
        let report = try #require(run.session.evidenceReport)
        let copy = try await flow.copyBinding(for: run.asset)
        let screen = try flow.project(
            run.session,
            copy: copy,
            onto: AnalysisViewStateProjector()
        ).screen

        // The `Encodable` check is deliberately **top-level only**, and the reason is a measured
        // over-claim rather than a shortcut. A recursive `Encodable` audit would fire on the
        // signed policy structures reachable through the immutable session binding, which the
        // design says are `Codable` on purpose with bounded canonical encodings. Those are
        // release artifacts, not results. What Requirements 9.14 and 9.15 forbid is a *result*
        // leaving the session, so the claim is made about the result-bearing types.
        //
        // Boxed as `Any` first, then tested. A direct `is Encodable` on a concrete type the
        // compiler knows is not `Encodable` is a warning-generating always-false cast; going
        // through `Any` makes it a real runtime conformance query, which is the question being
        // asked.
        let resultBearingValues: [(String, Any)] = [
            ("SessionTerminalOutcome", run.session.outcome),
            ("CompletedAnalysisSession", run.session),
            ("EvidenceReport", report),
            ("AnalysisScreen", screen),
        ]
        for (name, value) in resultBearingValues {
            #expect(!(value is any Encodable), "\(name) is Encodable, so a result can be exported")
            #expect(!(value is NSCoding), "\(name) is NSCoding, so a result can be archived")
        }

        // And no result-bearing value carries a location a result could be written to.
        let audit = ValueGraphAudit.audit([
            (label: "terminalOutcome", value: run.session.outcome),
            (label: "evidenceReport", value: report),
            (label: "screen", value: screen),
        ])
        let fileURLs = audit.findings(of: .fileURL)
        #expect(fileURLs.isEmpty, "\(audit.summary)")
        #expect(audit.visited > 200, "the audit visited only \(audit.visited) values")
    }

    @Test("The serializability check can fail, and does not over-report")
    func theSerializabilityCheckDetectsAnEncodableResult() throws {
        // Nothing shaped like this is representable in the shipping modules.
        struct ExportableResult: Encodable {
            let label = "Signals consistent with AI generation"
        }

        let value: Any = ExportableResult()
        #expect(value is any Encodable)

        // `NSString` is the positive control for the `NSCoding` half. Without it, that half
        // would be a check nobody has watched fire: the four result-bearing types are unbridged
        // Swift enums and structs, for which the answer can only ever be `false`.
        let archivable: Any = NSString(string: "result")
        #expect(archivable is NSCoding)

        // And the reason the `Encodable` claim above is made at the **top level only**, measured
        // rather than asserted: `PixelEvidence` — the verdict label itself — is declared
        // `Codable`, deliberately, and it is reachable through the report. So a recursive
        // `Encodable` audit would report the shipping domain as exportable. It is not: what
        // Requirements 9.14 and 9.15 forbid is a *result* leaving the session, and the report,
        // the terminal outcome, the completed session, and the screen are each unencodable, so
        // there is nothing to encode a label out of.
        let label: Any = PixelEvidence.signalsConsistentWithAIGeneration
        #expect(label is any Encodable)
    }
}
