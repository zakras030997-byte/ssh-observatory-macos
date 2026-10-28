import Foundation
import SQLite3

/// Local batched history; UI callers never wait for a write. Row/payload/age limits
/// are enforced in the same transaction. Existing JSON rows remain readable.
public final class HistoryStore {
    private var database: OpaquePointer?
    private let queue = DispatchQueue(label: "sshobservatory.telemetry.history", qos: .utility)
    private let lock = NSLock()
    private struct Write { let point: ReceivedSample; let node: String; let failure: () -> Void }
    private var pending: [Write] = []
    private var outstanding = 0
    private var scheduled = false
    private var storedBytes: Int64 = 0
    public let maximumRows: Int
    public let maximumPayloadBytes: Int
    public let maximumAge: TimeInterval
    public init(url: URL, maximumRows: Int = 200_000, maximumPayloadBytes: Int = 64 * 1024 * 1024,
                maximumAge: TimeInterval = 7 * 86400) throws {
        self.maximumRows = min(200_000, max(1, maximumRows))
        self.maximumPayloadBytes = max(1, maximumPayloadBytes)
        self.maximumAge = max(1, maximumAge)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw TelemetryError.database }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            sqlite3_busy_timeout(database, 500)
            try execute("PRAGMA journal_mode=DELETE; PRAGMA auto_vacuum=INCREMENTAL; PRAGMA max_page_count=32768; CREATE TABLE IF NOT EXISTS samples (id INTEGER PRIMARY KEY, node TEXT NOT NULL, received REAL NOT NULL, segment TEXT NOT NULL, payload BLOB NOT NULL); CREATE INDEX IF NOT EXISTS samples_node ON samples(node,id); CREATE INDEX IF NOT EXISTS samples_received ON samples(received,id);")
            storedBytes = try scalar("SELECT COALESCE(SUM(length(payload)),0) FROM samples")
            try execute("BEGIN IMMEDIATE")
            try prune(now: Date())
            try execute("COMMIT")
        } catch {
            if let database { sqlite3_exec(database, "ROLLBACK", nil, nil, nil); sqlite3_close(database) }
            database = nil; throw error
        }
    }
    deinit { if let database { sqlite3_close(database) } }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw TelemetryError.database }
    }
    private func scalar(_ sql: String) throws -> Int64 {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &s, nil) == SQLITE_OK else { throw TelemetryError.database }
        defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_ROW else { throw TelemetryError.database }
        return sqlite3_column_int64(s, 0)
    }
    public func append(_ point: ReceivedSample, nodeID: String) throws {
        try queue.sync { try writeBatch([(point, nodeID)]) }
    }
    @discardableResult public func enqueue(_ point: ReceivedSample, nodeID: String, onFailure: @escaping () -> Void) -> Bool {
        lock.lock()
        guard outstanding < 32 else { lock.unlock(); return false }
        outstanding += 1; pending.append(Write(point: point, node: nodeID, failure: onFailure))
        let needsSchedule = !scheduled; scheduled = true; lock.unlock()
        if needsSchedule { queue.asyncAfter(deadline: .now() + 0.2) { [self] in flushOnQueue() } }
        return true
    }
    /// Intended for tests or explicit lifecycle checkpoints, never the rendering path.
    public func flush() { queue.sync { flushOnQueue() } }
    private func flushOnQueue() {
        lock.lock(); let batch = pending; pending.removeAll(keepingCapacity: true); scheduled = false; lock.unlock()
        guard !batch.isEmpty else { return }
        do { try writeBatch(batch.map { ($0.point, $0.node) }) }
        catch { batch.forEach { $0.failure() } }
        lock.lock(); outstanding -= batch.count; lock.unlock()
    }
    private func writeBatch(_ points: [(ReceivedSample, String)]) throws {
        let beforeBytes = storedBytes
        try execute("BEGIN IMMEDIATE")
        do {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "INSERT INTO samples(node,received,segment,payload) VALUES(?,?,?,?)", -1, &statement, nil) == SQLITE_OK else { throw TelemetryError.database }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (point, node) in points {
                let data = try JSONEncoder().encode(point.sample)
                guard data.count <= 32_768, data.count <= maximumPayloadBytes else { throw TelemetryError.oversizedLine }
                sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                sqlite3_bind_text(statement, 1, node, -1, transient)
                sqlite3_bind_double(statement, 2, point.receivedAt.timeIntervalSince1970)
                sqlite3_bind_text(statement, 3, point.segment.uuidString, -1, transient)
                _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 4, $0.baseAddress, Int32(data.count), transient) }
                guard sqlite3_step(statement) == SQLITE_DONE else { throw TelemetryError.database }
                storedBytes += Int64(data.count)
            }
            try prune(now: Date())
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK"); storedBytes = beforeBytes; throw error
        }
    }
    private func remove(where predicate: String) throws {
        let bytes = try scalar("SELECT COALESCE(SUM(length(payload)),0) FROM samples WHERE \(predicate)")
        try execute("DELETE FROM samples WHERE \(predicate)")
        storedBytes -= bytes
    }
    private func prune(now: Date) throws {
        // id is a positive automatically assigned rowid. A fixed id range bounds
        // count even when age-based removal has left gaps, without OFFSET scans.
        let newest = try scalar("SELECT COALESCE(MAX(id),0) FROM samples")
        if newest > Int64(maximumRows) { try remove(where: "id <= \(newest - Int64(maximumRows))") }
        let cutoff = now.timeIntervalSince1970 - maximumAge
        try remove(where: "received < \(cutoff)")
        while storedBytes > maximumPayloadBytes {
            let boundary = try oldestBoundary(removing: storedBytes - Int64(maximumPayloadBytes))
            guard boundary > 0 else { throw TelemetryError.database }
            try remove(where: "id <= \(boundary)")
        }
    }
    private func oldestBoundary(removing bytes: Int64) throws -> Int64 {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT id,length(payload) FROM samples ORDER BY id LIMIT 64", -1, &s, nil) == SQLITE_OK else { throw TelemetryError.database }
        defer { sqlite3_finalize(s) }
        var removed: Int64 = 0, boundary: Int64 = 0
        while sqlite3_step(s) == SQLITE_ROW {
            boundary = sqlite3_column_int64(s,0); removed += sqlite3_column_int64(s,1)
            if removed >= bytes { break }
        }
        return boundary
    }
    public func recent(nodeID: String, limit: Int = 120, expectedHostname: String? = nil) throws -> [ReceivedSample] {
        try queue.sync {
            var s: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT received,segment,payload FROM samples WHERE node=? ORDER BY id DESC LIMIT ?", -1, &s, nil) == SQLITE_OK else { throw TelemetryError.database }
            defer { sqlite3_finalize(s) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(s, 1, nodeID, -1, transient)
            sqlite3_bind_int(s, 2, Int32(min(max(limit,1),600)))
            var result: [ReceivedSample] = []
            var status = sqlite3_step(s)
            while status == SQLITE_ROW {
                let count = Int(sqlite3_column_bytes(s,2))
                guard count <= 32_768, let bytes = sqlite3_column_blob(s,2), let raw = sqlite3_column_text(s,1),
                      let segment = UUID(uuidString: String(cString: raw)) else { throw TelemetryError.database }
                let sample = try JSONDecoder().decode(TelemetrySample.self, from: Data(bytes: bytes,count: count))
                try sample.validate(expectedNodeID: nodeID, expectedHostname: expectedHostname)
                result.append(ReceivedSample(sample: sample,receivedAt: Date(timeIntervalSince1970: sqlite3_column_double(s,0)),segment: segment))
                status = sqlite3_step(s)
            }
            guard status == SQLITE_DONE else { throw TelemetryError.database }
            return result.reversed()
        }
    }
}
