import Foundation

/// A value that is only reachable under its own lock.
///
/// State shared across queues is never a bare `static var` kept safe by a
/// convention ("this runs on one serial queue"): every read and write goes
/// through one lock, so the compiler has nothing to take on faith.
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

/// A value carried across a queue boundary whose safety the compiler cannot
/// see — a completion that is only called after hopping back to the main
/// thread, or a closure that does pure work. It checks nothing; every use
/// says in a comment why it holds. Prefer `Sendable` types and `Guarded`.
public struct Unchecked<Value>: @unchecked Sendable {
    public let value: Value

    public init(_ value: Value) {
        self.value = value
    }
}
