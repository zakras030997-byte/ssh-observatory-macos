import Foundation

/// Receiver limits shared by stdout/stderr, before decoding or delivery.
public struct StreamAdmission {
    public let maximumBytes: Int
    public let maximumRecords: Int
    public let interval: TimeInterval
    private var started: TimeInterval?
    private var bytes = 0
    private var records = 0
    public init(maximumBytes: Int = 131_072, maximumRecords: Int = 4, interval: TimeInterval = 6) {
        self.maximumBytes = max(1, maximumBytes); self.maximumRecords = max(1, maximumRecords)
        self.interval = max(0.1, interval)
    }
    public mutating func admit(bytes incoming: Int, records count: Int, now: TimeInterval) -> Bool {
        if started == nil || now - started! >= interval { started = now; bytes = 0; records = 0 }
        guard incoming >= 0, count >= 0, incoming <= maximumBytes - bytes,
              count <= maximumRecords - records else { return false }
        bytes += incoming; records += count; return true
    }
}

/// One pending value/notification even while the UI is stalled. Closing cancels old work.
public final class LatestValueMailbox<Value> {
    private let lock = NSLock()
    private var pending: Value?
    private var scheduled = false
    private var closed = false
    private var skipped = 0
    private var offered = 0
    public init() {}
    public func offer(_ value: Value) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return false }
        offered += 1
        if pending != nil { skipped += 1 }
        pending = value
        guard !scheduled else { return false }
        scheduled = true; return true
    }
    public func take() -> Value? {
        lock.lock(); defer { lock.unlock() }
        scheduled = false
        guard !closed else { return nil }
        let value = pending; pending = nil; return value
    }
    @discardableResult public func close() -> Int {
        lock.lock(); defer { lock.unlock() }; closed = true; pending = nil; return offered
    }
    public var offeredCount: Int { lock.lock(); defer { lock.unlock() }; return offered }
    public var skippedCount: Int { lock.lock(); defer { lock.unlock() }; return skipped }
    public var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return pending == nil ? 0 : 1 }
}
