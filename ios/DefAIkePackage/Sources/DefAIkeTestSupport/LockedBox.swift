import Foundation

/// A minimal mutable box with mutual exclusion, for building `Sendable` doubles.
///
/// Doubles need mutable state (programmed outcomes, recorded calls) while satisfying
/// `Sendable` port requirements. An actor cannot do it, because two ports are
/// deliberately synchronous — ``PixelCalibrating/classify(_:quality:policy:)`` and
/// ``EvidenceFusing/resolve(pixel:provenance:rule:binding:)`` are pure total functions
/// with no `await` — and `Synchronization.Mutex` needs a newer platform than the
/// package's macOS 14 and iOS 17 minimums.
///
/// `NSLock` is enough here: every critical section is a few field assignments with no
/// reentrancy and no suspension point inside it.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        self.storage = value
    }

    /// The current value.
    var value: Value {
        lock.withLock { storage }
    }

    /// Replaces the value.
    func set(_ value: Value) {
        lock.withLock { storage = value }
    }

    /// Mutates the value under the lock and returns the mutation's result.
    @discardableResult
    func withValue<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        try lock.withLock { try body(&storage) }
    }
}
