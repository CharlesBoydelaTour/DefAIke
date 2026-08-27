import Foundation

// Task 12.5: the two audits the offline and privacy smoke tests are built from.
//
// ``ValueGraphAudit`` reflects over a value graph and reports network and file-system surfaces
// reachable from it. ``FilesystemSentinel`` watches directories and reports what appeared while
// it was open. Each answers a question no type declaration can, and each is validated by being
// shown something that must make it report. That second half is not optional here. Task 12.2 measured a scanner that reported nothing because its own patterns
// never matched anything, and task 12.3 measured a `\b`-anchored symbol scan that was silently
// vacuous for the same reason. An audit nobody has watched fail is an audit nobody has watched
// work.
//
// ## What these audits are, and what they are not
//
// They are **value-graph** audits: they reflect over the values a real analysis flow assembles
// and produces, and report what they find. That makes them evidence about the shipping
// `DefAIkeDomain`, `DefAIkeApplication`, and `DefAIkePresentation` types those values are
// instances of.
//
// They are **not** evidence that the shipping platform adapters lack a network client. They
// cannot be: the flow substitutes the Image I/O, Core ML, and provenance adapters, so a network
// client inside one of them would not be in the graph to find. That claim belongs to
// `ios/Scripts/check-offline-privacy-archive.py`, which attributes every compiled object in both
// built archives and finds zero network symbol references from any DefAIke module. The header
// of `OfflineSessionAndPrivacySmokeTests.swift` states the division precisely.

// MARK: - What an audit found

/// One thing a value-graph audit found, and where.
///
/// The path is a member chain rather than a type name, because "some reachable value is a
/// `URLSession`" is not actionable and "`release.bundles.active.integrity.endpoint` is a
/// `URLSession`" is.
struct GraphFinding: Hashable, Sendable, CustomStringConvertible {
    /// What kind of thing was found.
    enum Kind: String, Hashable, Sendable, CaseIterable {
        /// A URL Loading System client, configuration, or task.
        case networkClient = "network-client"

        /// A request value addressed at a remote resource.
        case networkRequest = "network-request"

        /// A `URL` whose scheme is a network scheme.
        case networkURL = "network-url"

        /// A `URLComponents`, which exists to build one of the above.
        case urlBuilder = "url-builder"

        /// A raw file descriptor holder, which can be a socket.
        case fileHandle = "file-handle"

        /// A `URL` addressing a location on the file system.
        ///
        /// Not automatically a violation — an accepted ingest legitimately refers to nothing on
        /// disk, but a *lent* representation is a real file — so this kind is reported and the
        /// caller decides. Kept separate from ``networkURL`` for exactly that reason.
        case fileURL = "file-url"

        // An `objectiveCArchivable` kind for `NSCoding` was written, measured, and **withdrawn**,
        // because the assertion it supported was false rather than because it was inconvenient.
        //
        // Swift bridges `Int`, `Bool`, `String`, `Array`, `Set`, and `Dictionary` to Foundation
        // classes, and a bridged value satisfies `is NSCoding`. So a recursive `NSCoding` walk
        // over one completed flow reported **every leaf value in the graph** — 575 findings over
        // a 575-value walk, including every byte of a SHA-256 digest individually. A check that
        // matches everything distinguishes nothing.
        //
        // The claim is kept where it can be made honestly: the four result-bearing types are
        // tested for `NSCoding` at the top level in
        // `ResultPersistenceAbsenceTests.noProducedResultValueIsSerializable`, where they are
        // unbridged Swift enums and structs and the answer is a real one. `NSString` is used as
        // the positive control there, so that check is non-vacuous too.
    }

    let kind: Kind
    let path: String
    let typeName: String

    var description: String { "\(kind.rawValue) at \(path): \(typeName)" }
}

// MARK: - The value-graph walk

/// Reflects over a value graph, reporting network and archiving surfaces reachable from it.
///
/// **Bounded on purpose, and the bounds are reported.** A depth limit, a visit limit, and
/// reference-identity tracking are all required: a release graph contains actors holding
/// classes holding closures, and an unbounded walk over one either never terminates on a cycle
/// or spends minutes on the Foundation types hanging off a `Date`. Every bound that was actually
/// hit is recorded in ``truncations`` so a caller can assert it walked the graph rather than
/// bounced off the first limit.
struct ValueGraphAudit {
    /// How deep the walk goes before it stops descending.
    ///
    /// Twelve, measured rather than chosen: the deepest member chain a completed flow needs is
    /// the screen's provenance card's state copy's resolved reference's artifact identifier,
    /// which is eight. Twelve leaves headroom without inviting a walk into the standard
    /// library's internals.
    static let maximumDepth = 12

    /// How many values the walk visits before it stops.
    ///
    /// A ceiling rather than an expectation. A completed flow's whole graph is a few thousand
    /// values; this exists so a future graph that grew a cycle the identity set cannot see
    /// fails a bound assertion instead of hanging a test run.
    static let maximumVisits = 200_000

    private(set) var findings: [GraphFinding] = []

    /// How many values the walk actually reflected over.
    ///
    /// The counted-work floor every assertion below is paired with. A walk that visited three
    /// values and found nothing has established nothing.
    private(set) var visited = 0

    /// Which bounds the walk hit, if any.
    private(set) var truncations: Set<String> = []

    private var seen: Set<ObjectIdentifier> = []

    /// Walks `value`, naming the root `label` in every finding's path.
    static func audit(_ value: Any, named label: String) -> ValueGraphAudit {
        var audit = ValueGraphAudit()
        audit.walk(value, at: label, depth: 0)
        return audit
    }

    /// Walks several roots into one result, so a caller can make one claim about a whole flow.
    static func audit(_ roots: [(label: String, value: Any)]) -> ValueGraphAudit {
        var audit = ValueGraphAudit()
        for root in roots {
            audit.walk(root.value, at: root.label, depth: 0)
        }
        return audit
    }

    private mutating func walk(_ value: Any, at path: String, depth: Int) {
        if visited >= Self.maximumVisits {
            truncations.insert("visit-limit")
            return
        }
        if depth >= Self.maximumDepth {
            truncations.insert("depth-limit")
            return
        }
        visited += 1

        // Reference identity first. A release graph reaches the same actor from several
        // directions, and revisiting it multiplies the walk without adding a fact.
        if type(of: value) is AnyClass, let object = value as AnyObject? {
            let identity = ObjectIdentifier(object)
            if seen.contains(identity) { return }
            seen.insert(identity)
        }

        classify(value, at: path)

        let mirror = Mirror(reflecting: value)
        // An `Optional` reflects as a one-child enum whose label is `some`. Unwrapping it keeps
        // paths readable and stops every optional from consuming a depth level.
        if mirror.displayStyle == .optional {
            if let child = mirror.children.first {
                walk(child.value, at: path, depth: depth)
            }
            return
        }
        for (index, child) in mirror.children.enumerated() {
            let step = child.label ?? "[\(index)]"
            walk(child.value, at: "\(path).\(step)", depth: depth + 1)
        }
    }

    private mutating func classify(_ value: Any, at path: String) {
        let typeName = String(describing: type(of: value))

        func record(_ kind: GraphFinding.Kind) {
            findings.append(GraphFinding(kind: kind, path: path, typeName: typeName))
        }

        // The URL Loading System, in every form that can transmit. `URLSession` is a class, so
        // an `is` test catches a subclass too.
        if value is URLSession || value is URLSessionConfiguration || value is URLSessionTask {
            record(.networkClient)
            return
        }
        if value is URLRequest || value is URLResponse {
            record(.networkRequest)
            return
        }
        if value is URLComponents {
            record(.urlBuilder)
            return
        }
        if let url = value as? URL {
            // `isFileURL` rather than a scheme allowlist: a relative URL has no scheme at all,
            // and treating "no scheme" as safe is how a network URL would slip past.
            record(url.isFileURL ? .fileURL : .networkURL)
            return
        }
        if value is FileHandle {
            record(.fileHandle)
            return
        }
    }

    /// The findings of one kind, in discovery order.
    func findings(of kind: GraphFinding.Kind) -> [GraphFinding] {
        findings.filter { $0.kind == kind }
    }

    /// Every kind this walk found, as a set an assertion can compare.
    var kinds: Set<GraphFinding.Kind> {
        Set(findings.map(\.kind))
    }

    /// A readable summary for a failure message.
    var summary: String {
        let listed = findings.prefix(8).map(\.description).joined(separator: "; ")
        return "visited \(visited), truncations \(truncations.sorted()), findings: \(listed)"
    }
}

// MARK: - Planted values, for proving the walk works

/// Values that must make ``ValueGraphAudit`` report, one kind at a time.
///
/// Nothing shaped like any of these is representable in the shipping modules. They exist so the
/// audit's silence over a real flow means "the walk looked and found nothing" rather than "the
/// walk cannot see anything".
enum PlantedNetworkSurface {
    /// A struct holding a live URL Loading System client.
    struct WithClient {
        let session: URLSession = .shared
    }

    /// A struct holding a request addressed at a remote host.
    ///
    /// `example.invalid` on purpose: the `.invalid` top-level domain is reserved and
    /// unresolvable, so this value cannot become a real request even if something tried.
    struct WithRequest {
        let request = URLRequest(url: URL(string: "https://example.invalid/models")!)
    }

    /// A struct holding a network URL.
    struct WithNetworkURL {
        let endpoint = URL(string: "https://example.invalid/manifest")!
    }

    /// A struct holding a `URLComponents`.
    struct WithBuilder {
        let components = URLComponents(string: "https://example.invalid")!
    }

    /// A struct whose network URL is nested inside a collection inside an optional.
    ///
    /// The depth probe. A walk that unwrapped optionals but did not descend into arrays, or that
    /// stopped at the first aggregate, would pass every probe above and still miss this — and
    /// this is the shape a result-export surface would actually have, because a screen's fields
    /// are arrays of cards rather than one field.
    struct Nested {
        struct Inner {
            let endpoints: [URL]
        }

        let inner: Inner? = Inner(endpoints: [
            URL(string: "https://example.invalid/nested")!
        ])
    }

    /// One planted probe, as a `Sendable` case rather than a stored value.
    ///
    /// The values above hold `URLSession.shared` and `NSString`, so a table of them typed as
    /// `Any` is not `Sendable` and cannot be a static property under strict concurrency, nor an
    /// argument to a parameterized test. The case is the argument and the value is built inside
    /// the test, which is both what the language allows and the better shape: a probe that
    /// shared one live `URLSession` across parallel test cases would be sharing state the probe
    /// is about.
    enum Probe: String, Sendable, CaseIterable, CustomStringConvertible {
        case client
        case request
        case networkURL
        case builder
        case nested

        var description: String { rawValue }

        /// The value this probe plants.
        func plantedValue() -> Any {
            switch self {
            case .client: WithClient()
            case .request: WithRequest()
            case .networkURL: WithNetworkURL()
            case .builder: WithBuilder()
            case .nested: Nested()
            }
        }

        /// The kind the audit must report for it.
        var expected: GraphFinding.Kind {
            switch self {
            case .client: .networkClient
            case .request: .networkRequest
            case .networkURL, .nested: .networkURL
            case .builder: .urlBuilder
            }
        }
    }
}

// MARK: - The file-system sentinel

/// Watches a fixed set of directories and reports entries that appeared while it was open.
///
/// The point is a claim no type declaration can make: that running a whole analysis flow leaves
/// nothing behind in a location that outlives a session (Requirements 9.14, 9.15, 9.17). A type
/// with no `save` member proves nothing about what a real ingest adapter wrote.
///
/// ## What it watches, and the one thing it deliberately does not
///
/// The real runs watch the user-domain `Documents` and `Application Support` directories at
/// depth one. Those are where a result export or a history database would land, no test in this
/// package writes to either, and a depth-one listing of each is a handful of `readdir` calls.
///
/// `NSTemporaryDirectory()` is **deliberately not watched**, and the reason is measured rather
/// than tidiness: `FlowHostFile` in task 12.4's fixtures creates a real directory there for
/// every lent provider representation, the package's test suites run in parallel, and the
/// entries are named with fresh UUIDs. So a temporary-directory delta cannot be attributed to
/// the session under test, and asserting on one would be a flake rather than a check. What
/// happens to those directories is asserted a different way — through the store's own occupied
/// scopes — in `OfflineSessionAndPrivacySmokeTests`.
///
/// Depth one rather than a recursive walk, for the same honesty reason in the other direction: a
/// recursive enumeration of a real user's `Documents` is slow enough to change how a test run
/// behaves, and a persistence bug creates a top-level file or directory rather than burying one
/// four levels inside an existing tree. The limitation is stated rather than hidden.
struct FilesystemSentinel {
    /// The directories being watched.
    let directories: [URL]

    private let opening: [URL: Set<String>]

    /// Opens a window over `directories`, recording what each one held.
    ///
    /// A directory that does not exist is recorded as empty rather than skipped, so a file
    /// appearing in a directory the flow *created* is an addition too.
    init(watching directories: [URL]) {
        self.directories = directories
        var opening: [URL: Set<String>] = [:]
        for directory in directories {
            opening[directory] = Self.entries(of: directory)
        }
        self.opening = opening
    }

    /// The user-domain directories a real run watches.
    static var persistentDomains: [URL] {
        let manager = FileManager.default
        let domains: [FileManager.SearchPathDirectory] = [
            .documentDirectory,
            .applicationSupportDirectory,
        ]
        return domains.compactMap { manager.urls(for: $0, in: .userDomainMask).first }
    }

    private static func entries(of directory: URL) -> Set<String> {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        )
        guard let contents else { return [] }
        return Set(contents.map(\.lastPathComponent))
    }

    /// Entries present now that were not present when the window opened.
    ///
    /// Paths rather than names, so a failure message says which directory gained what.
    func additions() -> [String] {
        var appeared: [String] = []
        for directory in directories {
            let now = Self.entries(of: directory)
            let before = opening[directory] ?? []
            for name in now.subtracting(before).sorted() {
                appeared.append(directory.appending(path: name).path)
            }
        }
        return appeared
    }

    /// How many entries the window recorded at opening.
    ///
    /// The counted-work figure for the sentinel: a sentinel over two directories that could not
    /// be read at all would report no additions forever, which is why the probe below points
    /// one at a directory it fills itself.
    var observedEntryCount: Int {
        opening.values.reduce(0) { $0 + $1.count }
    }
}
