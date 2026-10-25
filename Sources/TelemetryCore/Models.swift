import Foundation

public struct NodeProfile: Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var region: String
    public var sshAlias: String
    public var units: [String]
    public var sshConfigPath: String?
    public var expectedHostname: String?
    public var networkInterface: String?
    public init(id: String = UUID().uuidString, name: String, region: String, sshAlias: String, units: [String] = [], sshConfigPath: String? = nil, expectedHostname: String? = nil, networkInterface: String? = nil) {
        self.id = id; self.name = name; self.region = region; self.sshAlias = sshAlias; self.units = units
        self.sshConfigPath = sshConfigPath; self.expectedHostname = expectedHostname
        self.networkInterface = networkInterface
    }
    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80,
              !id.isEmpty, id.count <= 128, region.count <= 80,
              sshAlias.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$", options: .regularExpression) != nil,
              sshConfigPath.map({ $0.hasPrefix("/") && $0.count <= 4096 && !$0.contains("\0") && !$0.contains("\n") }) ?? true,
              expectedHostname.map({ !$0.isEmpty && $0.count <= 255 && $0.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]*$", options: .regularExpression) != nil }) ?? true,
              units.count <= 16,
              networkInterface.map({ $0 != "lo" && $0.range(of: "^[A-Za-z0-9][A-Za-z0-9_.:-]{0,63}$", options: .regularExpression) != nil }) ?? true,
              units.allSatisfy({ $0.range(of: "^[A-Za-z0-9_][A-Za-z0-9_.@:-]{0,119}\\.service$", options: .regularExpression) != nil })
        else { throw TelemetryError.invalidProfile }
    }
}

public enum TelemetryError: Error, LocalizedError {
    case invalidProfile, invalidSample, oversizedLine, incompatibleSchema, database
    public var errorDescription: String? {
        switch self {
        case .invalidProfile: return "Проверьте название, SSH-профиль и имена служб."
        case .invalidSample: return "Сервер прислал некорректные показания."
        case .oversizedLine: return "Ответ сборщика превысил допустимый размер."
        case .incompatibleSchema: return "Версия сборщика несовместима с приложением."
        case .database: return "Локальная история недоступна."
        }
    }
}

public struct ByteUsage: Codable, Equatable {
    public let total: Double
    public let available: Double
    public let usedBytes: Double?
    public let reservedBytes: Double?
    public var used: Double { usedBytes ?? max(0, total - available) }
    public var percent: Double { total > 0 ? used / total * 100 : 0 }
    public init(total: Double, available: Double, usedBytes: Double? = nil, reservedBytes: Double? = nil) {
        self.total = total; self.available = available; self.usedBytes = usedBytes; self.reservedBytes = reservedBytes
    }
    var valid: Bool {
        total.isFinite && available.isFinite && total >= 0 && available >= 0 && available <= total &&
        used.isFinite && used >= 0 && used <= total &&
        (reservedBytes.map { $0.isFinite && $0 >= 0 && used + available + $0 <= total + 1 } ?? true)
    }
}
public struct NetworkRate: Codable, Equatable {
    public let receivedBytesPerSecond: Double
    public let sentBytesPerSecond: Double
    public let interface: String?
    public init(receivedBytesPerSecond: Double, sentBytesPerSecond: Double, interface: String? = nil) {
        self.receivedBytesPerSecond = receivedBytesPerSecond; self.sentBytesPerSecond = sentBytesPerSecond
        self.interface = interface
    }
}
public struct UnitStatus: Codable, Identifiable, Equatable {
    public let name: String
    public let state: String
    public let restarts: Int?
    public var id: String { name }
    public init(name: String, state: String, restarts: Int? = nil) { self.name = name; self.state = state; self.restarts = restarts }
}
public struct TelemetrySample: Codable, Equatable {
    public let schema: Int
    public let nodeID: String
    public let hostname: String
    public let bootID: String
    public let sequence: Int
    public let measuredAt: Double
    public let uptime: Double
    public let cores: Int
    public let cpuPercent: Double?
    public let memory: ByteUsage?
    public let swap: ByteUsage?
    public let disk: ByteUsage?
    public let network: NetworkRate?
    public let load: [Double]?
    public let units: [UnitStatus]
    public let errors: [String: String]
    public init(schema: Int = 1, nodeID: String, hostname: String, bootID: String, sequence: Int,
                measuredAt: Double, uptime: Double, cores: Int, cpuPercent: Double?, memory: ByteUsage?,
                swap: ByteUsage?, disk: ByteUsage?, network: NetworkRate?, load: [Double]?,
                units: [UnitStatus], errors: [String: String]) {
        self.schema = schema; self.nodeID = nodeID; self.hostname = hostname; self.bootID = bootID
        self.sequence = sequence; self.measuredAt = measuredAt; self.uptime = uptime; self.cores = cores
        self.cpuPercent = cpuPercent; self.memory = memory; self.swap = swap; self.disk = disk
        self.network = network; self.load = load; self.units = units; self.errors = errors
    }
    public var date: Date { Date(timeIntervalSince1970: measuredAt) }
    public func validate(expectedNodeID: String, expectedHostname: String? = nil) throws {
        guard schema == 1 else { throw TelemetryError.incompatibleSchema }
        guard nodeID == expectedNodeID, expectedHostname.map({ hostname == $0 }) ?? true,
              hostname.count <= 255, !bootID.isEmpty, bootID.count <= 128,
              sequence >= 0, measuredAt.isFinite, measuredAt > 0,
              uptime.isFinite, uptime >= 0, (1...4096).contains(cores),
              cpuPercent.map({ $0.isFinite && (0...100).contains($0) }) ?? true,
              [memory, swap, disk].allSatisfy({ $0?.valid ?? true }),
              network.map({ $0.receivedBytesPerSecond.isFinite && $0.sentBytesPerSecond.isFinite && $0.receivedBytesPerSecond >= 0 && $0.sentBytesPerSecond >= 0 }) ?? true,
              network.map({ $0.interface.map({ !$0.isEmpty && $0.count <= 64 }) ?? true }) ?? true,
              load.map({ $0.count == 3 && $0.allSatisfy { $0.isFinite && $0 >= 0 } }) ?? true,
              units.count <= 16, units.allSatisfy({ $0.name.count <= 128 && $0.state.count <= 32 && ($0.restarts ?? 0) >= 0 }),
              errors.count <= 16, errors.allSatisfy({ $0.key.count <= 40 && $0.value.count <= 160 })
        else { throw TelemetryError.invalidSample }
    }
}

public struct ReceivedSample: Identifiable {
    public let id = UUID()
    public let sample: TelemetrySample
    public let receivedAt: Date
    public let segment: UUID
    public init(sample: TelemetrySample, receivedAt: Date = Date(), segment: UUID) {
        self.sample = sample; self.receivedAt = receivedAt; self.segment = segment
    }
}

public struct SampleWindow {
    public private(set) var points: [ReceivedSample] = []
    public let capacity: Int
    public init(capacity: Int = 120) { self.capacity = max(1, capacity) }
    @discardableResult public mutating func append(_ point: ReceivedSample) -> Bool {
        if let last = points.last, last.segment == point.segment,
           last.sample.bootID == point.sample.bootID, point.sample.sequence <= last.sample.sequence { return false }
        points.append(point)
        if points.count > capacity { points.removeFirst(points.count - capacity) }
        return true
    }
    public mutating func clear() { points.removeAll(keepingCapacity: true) }
}

public struct LineFramer {
    private var buffer = Data()
    public let limit: Int
    public init(limit: Int = 32_768) { self.limit = limit }
    public mutating func append(_ chunk: Data) throws -> [Data] {
        var lines: [Data] = []
        // Incremental framing bounds memory even when the peer omits newlines.
        for byte in chunk {
            if byte == 10 {
                if !buffer.isEmpty { lines.append(buffer) }
                buffer.removeAll(keepingCapacity: true)
            } else {
                guard buffer.count < limit else { throw TelemetryError.oversizedLine }
                buffer.append(byte)
            }
        }
        return lines
    }
}

public struct ReconnectPolicy {
    public let maximumRetries: Int
    public let delay: TimeInterval
    public init(maximumRetries: Int = 4, delay: TimeInterval = 5) {
        self.maximumRetries = maximumRetries; self.delay = delay
    }
    public func canRetry(afterRetries retries: Int, permanent: Bool) -> Bool { !permanent && retries < maximumRetries }
    public static func isPermanentSSHError(_ text: String) -> Bool {
        let s = text.lowercased()
        return ["permission denied", "host key verification failed", "remote host identification has changed", "could not resolve hostname", "bad configuration option", "no such identity", "too many authentication failures", "unprotected private key"].contains { s.contains($0) }
    }
}
