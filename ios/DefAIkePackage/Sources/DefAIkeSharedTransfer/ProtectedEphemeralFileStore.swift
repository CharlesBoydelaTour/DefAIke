import DefAIkeDomain
import Foundation

// The real, file-system-backed ephemeral store.
//
// This is the adapter behind ``EphemeralFileStoring``. It ships in both the main app and
// the Share Extension, so nothing here reaches inference, image-pipeline, model-bundle,
// or provenance code: it moves bytes, protects them, measures them, and deletes them.
//
// Three properties drive the on-disk layout, and each one rules out a simpler shape:
//
//   * **An incomplete copy must be unreadable and unpromotable.** A partially written
//     object lives at `payload.part`; the finalized name `payload` only ever appears
//     through a rename that happens after the bytes are flushed. There is no moment at
//     which a short file is visible under the finalized name (design, Shared Transfer
//     Store).
//   * **A scope move must be atomic.** Each object owns a directory holding its payload
//     and its measurements, so changing owner is one `rename` of that directory. Moving
//     two sibling files would leave a window with the payload in the new scope and its
//     digest in the old one, and the `staging → ready → claimed` progression depends on
//     an observer seeing the object in exactly one scope.
//   * **Locations must be random and app-controlled.** Keys are 128 random bits rendered
//     as hexadecimal, and scope directories are named by the digest of the scope rather
//     than by its identifier, so nothing user-derived and nothing session-correlatable
//     appears in a path (Requirement 9.11).
//
// The file system is authoritative for finished objects, because the extension writes and
// the app reads across a process boundary and either process can be terminated at any
// point. Only *in-flight* writes are in-process state: a digest is computed in the single
// streaming pass, so a half-written object cannot be adopted by a different process.
//
// ```text
// <root>/
//   <64-hex scope digest>/
//     scope.json                which scope this directory owns
//     <32-hex key>/
//       payload.part            being written; never readable
//       payload                 finalized, immutable
//       receipt.json            byte count, digest, and protection level as measured
// ```

/// Protected, bounded, scope-owned ephemeral storage on the file system.
///
/// Every object is created with a data-protection level and verified to carry it
/// (Requirement 9.6). Capacity is a required constructor value with no default: the
/// temporary-storage ceiling is an approved Resource Budget measurement, and a store that
/// invented one would be enforcing an unapproved limit.
public actor ProtectedEphemeralFileStore: EphemeralFileStoring {

    // MARK: - Configuration

    /// Where the store lives and how much it may hold.
    public struct Configuration: Sendable {
        /// The directory the store owns completely. Created if absent.
        ///
        /// For the main app this is app-private storage; for the Share Extension it is
        /// inside the registered App Group container. The store deletes only inside it.
        public let rootDirectory: URL

        /// Total bytes the store may hold across every scope.
        ///
        /// Supplied by the caller from the active target's Resource Budget
        /// `temporary-storage` limit. Exceeding it is
        /// ``EphemeralStoreError/capacityExceeded(scope:)``, which the caller's stage maps
        /// to `resource-limit`.
        public let capacityInBytes: UInt64

        /// Data protection applied to the root and to every scope directory.
        ///
        /// Individual objects are created with the level their writer requested, which is
        /// what the Extension Execution Policy fixes for staged handoff material.
        public let containerProtection: FileProtectionLevel

        public init(
            rootDirectory: URL,
            capacityInBytes: UInt64,
            containerProtection: FileProtectionLevel
        ) {
            self.rootDirectory = rootDirectory
            self.capacityInBytes = capacityInBytes
            self.containerProtection = containerProtection
        }
    }

    /// Why a store could not be configured from an approved budget.
    public enum ConfigurationError: Error, Hashable, Sendable {
        /// The budget defines no numeric `temporary-storage` limit in bytes, so no
        /// approved capacity exists to enforce.
        case temporaryStorageLimitUnavailable(ArtifactID)
    }

    private let configuration: Configuration
    private let protection: any DataProtectionApplying
    private let clock: any SessionClock

    /// One object this process is still writing.
    ///
    /// Holds the write handle and the in-flight hash. Not recoverable across processes by
    /// design: a stream whose hash state is gone cannot be finished honestly.
    private struct OpenObject {
        let scope: EphemeralStorageScope
        let protectionLevel: FileProtectionLevel
        let directory: URL
        let handle: FileHandle
        var hasher: StreamingSHA256
    }

    private var openObjects: [EphemeralStorageKey: OpenObject] = [:]

    /// Cached total of bytes on disk. Invalidated by anything that removes bytes.
    private var cachedStoredByteCount: UInt64?

    public init(
        configuration: Configuration,
        protection: any DataProtectionApplying = PlatformDataProtection(),
        clock: any SessionClock = SystemSessionClock()
    ) {
        self.configuration = configuration
        self.protection = protection
        self.clock = clock
    }

    /// Configures a store whose capacity comes from an approved Resource Budget.
    ///
    /// Fails when the budget carries no numeric byte limit for temporary storage, rather
    /// than falling back to a number chosen here.
    public static func configuration(
        rootDirectory: URL,
        budget: ResourceBudget,
        containerProtection: FileProtectionLevel
    ) throws(ConfigurationError) -> Configuration {
        guard
            case .numeric(let value, let unit) = budget.limit(for: .temporaryStorage),
            unit == .bytes
        else {
            throw .temporaryStorageLimitUnavailable(budget.id)
        }
        // Truncate rather than round: a ceiling is a limit, so the enforced value must
        // never exceed the approved one.
        var whole = Decimal()
        var declared = value.value
        NSDecimalRound(&whole, &declared, 0, .down)
        guard whole > 0, whole <= Decimal(UInt64.max) else {
            throw .temporaryStorageLimitUnavailable(budget.id)
        }
        return Configuration(
            rootDirectory: rootDirectory,
            capacityInBytes: NSDecimalNumber(decimal: whole).uint64Value,
            containerProtection: containerProtection
        )
    }

    /// Whether the platform enforces the data protection this store applies.
    ///
    /// Exposed so a startup gate can refuse to accept work on a platform that does not,
    /// instead of this store quietly deciding that unenforced protection is acceptable.
    public var enforcesDataProtection: Bool { protection.enforcesDataProtection }

    /// Total bytes the store may hold.
    public var capacityInBytes: UInt64 { configuration.capacityInBytes }

    // MARK: - EphemeralFileStoring: writing

    public func create(
        in scope: EphemeralStorageScope,
        protection level: FileProtectionLevel
    ) throws(EphemeralStoreError) -> EphemeralStorageKey {
        let scopeDirectory = try prepareScopeDirectory(scope)
        let key = Self.makeRandomKey()
        let objectDirectory = scopeDirectory.appending(
            path: key.rawValue,
            directoryHint: .isDirectory
        )
        guard !FileManager.default.fileExists(atPath: objectDirectory.path) else {
            // 128 random bits collided, or a stale directory carries this name. Either
            // way, reusing it would overwrite existing bytes.
            throw .keyAlreadyInUse(key)
        }
        try protection.createProtectedDirectory(at: objectDirectory, level: level)

        // Anything that goes wrong from here removes the object directory: a create that
        // reports failure must leave no partially prepared location behind.
        let partURL = Self.partURL(in: objectDirectory)
        let handle: FileHandle
        do {
            try protection.createProtectedFile(at: partURL, level: level)
            handle = try FileHandle(forWritingTo: partURL)
        } catch let error as EphemeralStoreError {
            try? FileManager.default.removeItem(at: objectDirectory)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: objectDirectory)
            throw .storeUnavailable
        }

        openObjects[key] = OpenObject(
            scope: scope,
            protectionLevel: level,
            directory: objectDirectory,
            handle: handle,
            hasher: StreamingSHA256()
        )
        return key
    }

    public func append(
        _ chunk: [UInt8],
        to key: EphemeralStorageKey
    ) throws(EphemeralStoreError) {
        guard var object = openObjects[key] else {
            throw unwritableReason(for: key)
        }
        guard !chunk.isEmpty else { return }

        let used = try storedByteCount()
        guard used + UInt64(chunk.count) <= configuration.capacityInBytes else {
            throw .capacityExceeded(scope: object.scope)
        }

        do {
            try object.handle.write(contentsOf: chunk)
        } catch {
            // A write that failed part way through leaves the file and the hash out of
            // step, and no honest digest can be produced for it. Abandoning the writer
            // makes the object unfinalizable rather than resumable, so a retry cannot
            // append the same chunk twice.
            abandonWriter(key)
            throw .storeUnavailable
        }
        // Hash in the same pass that writes, so the digest describes the bytes that
        // actually reached the file rather than the bytes the caller intended.
        object.hasher.update(chunk)
        openObjects[key] = object
        cachedStoredByteCount = used + UInt64(chunk.count)
    }

    public func finalize(
        _ key: EphemeralStorageKey
    ) throws(EphemeralStoreError) -> EphemeralWriteReceipt {
        guard let object = openObjects[key] else {
            // Finalizing twice is a success: the object is already complete and immutable.
            if let existing = receipt(for: key) { return existing }
            // Present but never completed, with its in-flight hash gone. Same answer a
            // read gives, and cleanup is what removes it.
            guard locate(key) == nil else { throw .notFinalized(key) }
            throw .notFound(key)
        }

        // From here the writer is spent either way: a failure must not leave a handle open
        // or an object that looks resumable.
        openObjects.removeValue(forKey: key)
        do {
            try object.handle.synchronize()
            try object.handle.close()
        } catch {
            try? object.handle.close()
            throw .storeUnavailable
        }

        let measurements = StoredMeasurements(
            byteCount: object.hasher.byteCount,
            sha256: object.hasher.digest(),
            protection: object.protectionLevel
        )
        // Order matters: the measurements land first, then the payload is renamed into
        // its finalized name. The finalized payload therefore never exists without the
        // digest that describes it, and a crash in between leaves only an unreadable
        // partial object that cleanup removes.
        try write(measurements, in: object.directory, level: object.protectionLevel)
        do {
            try FileManager.default.moveItem(
                at: Self.partURL(in: object.directory),
                to: Self.payloadURL(in: object.directory)
            )
        } catch {
            throw .storeUnavailable
        }

        return EphemeralWriteReceipt(
            key: key,
            scope: object.scope,
            byteCount: measurements.byteCount,
            sha256: measurements.sha256,
            protection: measurements.protection
        )
    }

    /// Closes and forgets an in-flight writer, leaving its partial object on disk.
    ///
    /// The partial object stays owned by its scope so cleanup finds it, and it stays
    /// unreadable and unpromotable because it has no finalized payload.
    private func abandonWriter(_ key: EphemeralStorageKey) {
        guard let object = openObjects.removeValue(forKey: key) else { return }
        try? object.handle.close()
    }

    // MARK: - EphemeralFileStoring: reading

    public func read(_ key: EphemeralStorageKey) throws(EphemeralStoreError) -> [UInt8] {
        guard let located = locate(key) else { throw .notFound(key) }
        let payload = Self.payloadURL(in: located.directory)
        guard FileManager.default.fileExists(atPath: payload.path) else {
            throw .notFinalized(key)
        }
        do {
            return try Array(Data(contentsOf: payload, options: [.mappedIfSafe]))
        } catch {
            throw .storeUnavailable
        }
    }

    public func receipt(for key: EphemeralStorageKey) -> EphemeralWriteReceipt? {
        guard
            let located = locate(key),
            FileManager.default.fileExists(atPath: Self.payloadURL(in: located.directory).path),
            let measurements = readMeasurements(in: located.directory)
        else {
            return nil
        }
        // The scope comes from the directory the object currently sits in, never from the
        // stored measurements, so a receipt always reports the present owner and a move
        // stays a single rename.
        return EphemeralWriteReceipt(
            key: key,
            scope: located.scope,
            byteCount: measurements.byteCount,
            sha256: measurements.sha256,
            protection: measurements.protection
        )
    }

    public func keys(in scope: EphemeralStorageScope) -> Set<EphemeralStorageKey> {
        let directory = Self.scopeDirectory(for: scope, under: configuration.rootDirectory)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            atPath: directory.path
        ) else {
            return []
        }
        return Set(entries.compactMap(Self.objectKey(fromDirectoryName:)))
    }

    public func occupiedScopes() -> Set<EphemeralStorageScope> {
        var occupied: Set<EphemeralStorageScope> = []
        for candidate in scopeDirectories() where !keys(in: candidate.scope).isEmpty {
            occupied.insert(candidate.scope)
        }
        return occupied
    }

    /// Every scope this store has a directory for, whether or not it still holds objects.
    ///
    /// Deliberately wider than ``occupiedScopes()``. An emptied scope directory still
    /// carries the marker naming the scope it owned, so it is residue from that scope even
    /// though it holds no objects, and cleanup has to be able to find it in order to leave
    /// nothing behind (Requirement 9.17). ``occupiedScopes()`` stays the narrower answer
    /// because startup resolution asks a different question: which scopes still hold
    /// material that could be resumed.
    public func knownScopes() -> Set<EphemeralStorageScope> {
        Set(scopeDirectories().map(\.scope))
    }

    // MARK: - EphemeralFileStoring: ownership and removal

    public func move(
        _ key: EphemeralStorageKey,
        to scope: EphemeralStorageScope
    ) throws(EphemeralStoreError) {
        guard let located = locate(key) else { throw .notFound(key) }
        guard FileManager.default.fileExists(
            atPath: Self.payloadURL(in: located.directory).path
        ) else {
            // An interrupted copy is never promoted.
            throw .notFinalized(key)
        }
        guard located.scope != scope else { return }

        let destinationScope = try prepareScopeDirectory(scope)
        let destination = destinationScope.appending(
            path: key.rawValue,
            directoryHint: .isDirectory
        )
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw .keyAlreadyInUse(key)
        }
        do {
            // One rename of the object's own directory: the payload and its measurements
            // change owner together.
            try FileManager.default.moveItem(at: located.directory, to: destination)
        } catch {
            throw .storeUnavailable
        }
    }

    public func deleteAll(
        in scope: EphemeralStorageScope,
        reason: SessionCleanupReason
    ) throws(EphemeralStoreError) -> EphemeralDeletionReceipt {
        // Release in-flight handles first. An open descriptor for a removed path would
        // keep the bytes alive for as long as the writer lived.
        for key in openObjects.filter({ $0.value.scope == scope }).keys {
            abandonWriter(key)
        }

        let removed = keys(in: scope)
        let directory = Self.scopeDirectory(for: scope, under: configuration.rootDirectory)
        if FileManager.default.fileExists(atPath: directory.path) {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                throw .storeUnavailable
            }
        }
        // Idempotent: a scope that was already empty removes nothing and still succeeds,
        // so repeated cleanup and cleanup after an interruption behave identically.
        cachedStoredByteCount = nil
        return EphemeralDeletionReceipt(
            scope: scope,
            reason: reason,
            removedObjectCount: removed.count,
            completedAt: clock.wallClockNow
        )
    }

    /// Removes every scope the store owns, and returns one receipt per scope removed.
    ///
    /// Startup cleanup for material an interrupted process left behind. Idempotent, and
    /// empty when there was nothing to clean (Requirement 11.16).
    public func deleteEverything(
        reason: SessionCleanupReason
    ) throws(EphemeralStoreError) -> [EphemeralDeletionReceipt] {
        var receipts: [EphemeralDeletionReceipt] = []
        for scope in occupiedScopes().sorted(by: Self.isOrderedBefore) {
            receipts.append(try deleteAll(in: scope, reason: reason))
        }
        // Scope directories with no objects left are still this store's litter.
        for candidate in scopeDirectories() where keys(in: candidate.scope).isEmpty {
            try? FileManager.default.removeItem(at: candidate.directory)
        }
        cachedStoredByteCount = nil
        return receipts
    }

    // MARK: - Inspection

    /// Keys created but never finalized: the incomplete-copy set.
    ///
    /// Only objects this process is writing. A partial object left by a terminated process
    /// is not resumable and is removed by cleanup rather than counted here.
    public var unfinalizedKeys: Set<EphemeralStorageKey> { Set(openObjects.keys) }

    /// Total bytes currently held on disk.
    public func usedByteCount() throws(EphemeralStoreError) -> UInt64 {
        try storedByteCount()
    }

    // MARK: - Layout

    private struct StoredMeasurements: Codable, Hashable, Sendable {
        let byteCount: UInt64
        let sha256: DefAIkeDomain.SHA256Digest
        let protection: FileProtectionLevel
    }

    private struct LocatedObject {
        let scope: EphemeralStorageScope
        let directory: URL
    }

    private static let scopeMarkerName = "scope.json"
    private static let measurementsName = "receipt.json"
    private static let payloadName = "payload"
    private static let partName = "payload.part"

    /// Object key length in hexadecimal characters: 16 random bytes.
    private static let keyCharacterCount = 32

    /// Scope directory name length: a SHA-256 digest in hexadecimal.
    private static let scopeDirectoryCharacterCount = DefAIkeDomain.SHA256Digest
        .hexadecimalCharacterCount

    private static func payloadURL(in objectDirectory: URL) -> URL {
        objectDirectory.appending(path: payloadName, directoryHint: .notDirectory)
    }

    private static func partURL(in objectDirectory: URL) -> URL {
        objectDirectory.appending(path: partName, directoryHint: .notDirectory)
    }

    /// The directory that owns `scope`.
    ///
    /// Named by the digest of a canonical scope description rather than by the identifiers
    /// themselves. That keeps every path component fixed-width and path-safe: a canonical
    /// identifier may legitimately contain `.` and `/`, so `..` is a valid identifier and
    /// using one directly as a directory name would be a traversal.
    private static func scopeDirectory(
        for scope: EphemeralStorageScope,
        under root: URL
    ) -> URL {
        let name = StreamingSHA256
            .digest(of: Data(canonicalDescription(of: scope).utf8))
            .hexadecimalString
        return root.appending(path: name, directoryHint: .isDirectory)
    }

    /// A canonical, injective description of a scope.
    ///
    /// Injective in two steps. The distinct `session:` and `transfer:` prefixes keep the
    /// two cases apart. Within the transfer case the slot state is the suffix after the
    /// final colon and is one of three fixed words, so a transfer identifier — which may
    /// itself contain a colon — cannot absorb the separator and produce another scope's
    /// string. Two different scopes therefore never share a directory.
    private static func canonicalDescription(of scope: EphemeralStorageScope) -> String {
        switch scope {
        case .session(let id):
            "session:\(id.rawValue)"
        case .transfer(let id, let state):
            "transfer:\(id.rawValue):\(state.rawValue)"
        }
    }

    private static let hexadecimalDigits: [Character] = Array("0123456789abcdef")

    /// A fresh random object name.
    ///
    /// 128 bits from the system generator, so a location is not derived from a file name,
    /// an asset identifier, a session identifier, or the bytes themselves.
    private static func makeRandomKey() -> EphemeralStorageKey {
        var generator = SystemRandomNumberGenerator()
        var raw = ""
        raw.reserveCapacity(keyCharacterCount)
        for _ in 0..<(keyCharacterCount / 2) {
            let byte = UInt8.random(in: .min ... .max, using: &generator)
            raw.append(hexadecimalDigits[Int(byte >> 4)])
            raw.append(hexadecimalDigits[Int(byte & 0x0F)])
        }
        guard let key = EphemeralStorageKey(raw) else {
            preconditionFailure("generated store key is not canonical: \(raw)")
        }
        return key
    }

    /// The key a directory name denotes, or `nil` when the entry is not an object.
    ///
    /// Only the exact generated shape is accepted, so `scope.json` and anything else that
    /// appears in a scope directory is never mistaken for an object.
    private static func objectKey(fromDirectoryName name: String) -> EphemeralStorageKey? {
        guard name.count == keyCharacterCount, isLowercaseHexadecimal(name) else { return nil }
        return EphemeralStorageKey(name)
    }

    /// Whether every character is one of the sixteen ASCII lowercase hexadecimal digits.
    ///
    /// Deliberately not `Character.isHexDigit`, which also accepts uppercase and full-width
    /// forms. Only the exact shape the store generates may be joined onto a path.
    private static func isLowercaseHexadecimal(_ name: String) -> Bool {
        name.allSatisfy(hexadecimalDigits.contains)
    }

    private static func isOrderedBefore(
        _ lhs: EphemeralStorageScope,
        _ rhs: EphemeralStorageScope
    ) -> Bool {
        canonicalDescription(of: lhs) < canonicalDescription(of: rhs)
    }

    // MARK: - Layout helpers

    private func prepareScopeDirectory(
        _ scope: EphemeralStorageScope
    ) throws(EphemeralStoreError) -> URL {
        try protection.createProtectedDirectory(
            at: configuration.rootDirectory,
            level: configuration.containerProtection
        )
        let directory = Self.scopeDirectory(
            for: scope,
            under: configuration.rootDirectory
        )
        try protection.createProtectedDirectory(
            at: directory,
            level: configuration.containerProtection
        )
        let marker = directory.appending(
            path: Self.scopeMarkerName,
            directoryHint: .notDirectory
        )
        if !FileManager.default.fileExists(atPath: marker.path) {
            // Records which scope this digest-named directory owns, so startup cleanup can
            // report the scopes it found rather than a set of opaque directory names.
            try protection.createProtectedFile(
                at: marker,
                level: configuration.containerProtection
            )
            try writeJSON(scope, to: marker)
        }
        return directory
    }

    private func scopeDirectories() -> [LocatedObject] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            atPath: configuration.rootDirectory.path
        ) else {
            return []
        }
        return entries.compactMap { name in
            guard name.count == Self.scopeDirectoryCharacterCount,
                Self.isLowercaseHexadecimal(name)
            else {
                return nil
            }
            let directory = configuration.rootDirectory.appending(
                path: name,
                directoryHint: .isDirectory
            )
            let marker = directory.appending(
                path: Self.scopeMarkerName,
                directoryHint: .notDirectory
            )
            guard let data = try? Data(contentsOf: marker),
                let scope = try? JSONDecoder().decode(EphemeralStorageScope.self, from: data)
            else {
                return nil
            }
            return LocatedObject(scope: scope, directory: directory)
        }
    }

    private func locate(_ key: EphemeralStorageKey) -> LocatedObject? {
        if let open = openObjects[key] {
            return LocatedObject(scope: open.scope, directory: open.directory)
        }
        // Only a name the store itself could have generated is ever joined onto a path. A
        // canonical identifier may legitimately contain `.` and `/`, so without this check
        // a caller-built key such as `..` would address a directory outside its scope.
        guard Self.objectKey(fromDirectoryName: key.rawValue) != nil else { return nil }
        for candidate in scopeDirectories() {
            let directory = candidate.directory.appending(
                path: key.rawValue,
                directoryHint: .isDirectory
            )
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            return LocatedObject(scope: candidate.scope, directory: directory)
        }
        return nil
    }

    /// Why an object cannot be appended to, when this process holds no writer for it.
    private func unwritableReason(for key: EphemeralStorageKey) -> EphemeralStoreError {
        guard let located = locate(key) else { return .notFound(key) }
        if FileManager.default.fileExists(atPath: Self.payloadURL(in: located.directory).path) {
            return .alreadyFinalized(key)
        }
        // A partial object whose in-flight hash belonged to a process that is gone. It
        // cannot be finished honestly, so it fails closed and cleanup removes it.
        return .storeUnavailable
    }

    private func readMeasurements(in objectDirectory: URL) -> StoredMeasurements? {
        let url = objectDirectory.appending(
            path: Self.measurementsName,
            directoryHint: .notDirectory
        )
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(StoredMeasurements.self, from: data)
    }

    private func write(
        _ measurements: StoredMeasurements,
        in objectDirectory: URL,
        level: FileProtectionLevel
    ) throws(EphemeralStoreError) {
        let url = objectDirectory.appending(
            path: Self.measurementsName,
            directoryHint: .notDirectory
        )
        if !FileManager.default.fileExists(atPath: url.path) {
            try protection.createProtectedFile(at: url, level: level)
        }
        try writeJSON(measurements, to: url)
    }

    private func writeJSON(
        _ value: some Encodable,
        to url: URL
    ) throws(EphemeralStoreError) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(value)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            throw .storeUnavailable
        }
    }

    private func storedByteCount() throws(EphemeralStoreError) -> UInt64 {
        if let cached = cachedStoredByteCount { return cached }
        var total: UInt64 = 0
        for scopeDirectory in scopeDirectories() {
            for key in keys(in: scopeDirectory.scope) {
                let objectDirectory = scopeDirectory.directory.appending(
                    path: key.rawValue,
                    directoryHint: .isDirectory
                )
                for url in [
                    Self.payloadURL(in: objectDirectory),
                    Self.partURL(in: objectDirectory),
                ] {
                    guard
                        let size = try? FileManager.default
                            .attributesOfItem(atPath: url.path)[.size] as? NSNumber
                    else {
                        continue
                    }
                    total += size.uint64Value
                }
            }
        }
        cachedStoredByteCount = total
        return total
    }
}
