import Foundation

/// One-way "stop now" signal shared between the engine and the worker threads
/// it spins up — the CPU busy loops, the Metal encode loop, the Core ML
/// prediction loop.
///
/// Deliberately not a captured `self` reference: the workers hold the flag and
/// nothing else, so an engine that goes away mid-session still leaves something
/// behind that can stop them. Each worker checks it once per chunk of work, so
/// the lock cost is negligible.
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Bool) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}
