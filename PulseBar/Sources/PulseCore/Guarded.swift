import Foundation

/// A value that is only reachable under its own lock.
///
/// 12.3: the scan engine's memory between passes (resolved project paths,
/// `lsof` answers and back-off, CPU anchors, the `ps` field latch) used to be
/// bare `static var`s kept safe by a convention — "scans run on one serial
/// queue". The convention held, but only a comment enforced it, and the CLI
/// and self-test paths run the same code off that queue. Every read and write
/// now goes through one lock, so the compiler has nothing to take on faith.
public final class Guarded<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    public init(_ value: Value) {
        self.value = value
    }

    /// Run `body` with exclusive access to the value.
    @discardableResult
    public func withValue<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    /// A copy of the current value.
    public var snapshot: Value { withValue { $0 } }
}
