import Foundation
import CryptoKit

// Closed, separate namespace: never extends the accepted r2 action vocabulary.
enum MetadataWire {
    typealias Object = [String: ConsoleValue]
    static let errors = Set("INVALID_BODY INVALID_JSON JSON_REQUIRED BODY_TOO_LARGE INVALID_METADATA INVALID_OPERATION_ID INVALID_KEY_ID INVALID_TARGET INVALID_QUERY INVALID_REQUEST UNKNOWN_ACTION OPERATION_NOT_FOUND FORBIDDEN OWNER_UNAVAILABLE INVALID_CONFIRMATION PREVIEW_EXPIRED METADATA_CHANGED BODY_CONFLICT OPERATION_ID_IN_USE RESOURCE_RECONCILIATION_REQUIRED QUEUE_CAPACITY JOURNAL_CAPACITY CORE_CAPACITY PREVIEW_PENDING CANNOT_CANCEL STOPPING METADATA_STORAGE_UNAVAILABLE CORE_OUTCOME_UNKNOWN RECEIPT_UNAVAILABLE INTERNAL_UNAVAILABLE CLIENT_CERTIFICATE_REQUIRED CERTIFICATE_NOT_AUTHORIZED RATE_LIMITED METHOD_NOT_ALLOWED NOT_FOUND OBJECT_NOT_FOUND PREVIEW_OUTCOME_UNKNOWN REQUEST_CAPACITY".split(separator: " ").map(String.init))
    static func keys(_ value: Object, _ required: Set<String>, optional: Set<String> = []) throws {
        guard required.isSubset(of: Set(value.keys)), Set(value.keys).isSubset(of: required.union(optional)) else { throw ControlAPIError.invalidResponse }
    }
    static func string(_ d: Object, _ k: String, max: Int = 2048) throws -> String {
        guard let s = d[k]?.text, s.unicodeScalars.count <= max else { throw ControlAPIError.invalidResponse }; return s
    }
    static func integer(_ d: Object, _ k: String, minimum: Int64 = 0) throws -> Int64 {
        guard let n = d[k]?.number, n >= minimum else { throw ControlAPIError.invalidResponse }; return n
    }
    static func flag(_ d: Object, _ k: String) throws -> Bool {
        guard let b = d[k]?.flag else { throw ControlAPIError.invalidResponse }; return b
    }
    static func hash(_ s: String, count: Int = 64) -> Bool { s.utf8.count == count && s.range(of: "^[0-9a-f]+$", options: .regularExpression) != nil }
    static func utc(_ s: String) -> Bool { s.hasSuffix("Z") && ControlOperationReceipt.parseDate(s) != nil }
    static func nullableString(_ d: Object, _ k: String) throws -> String? {
        guard let v = d[k] else { throw ControlAPIError.invalidResponse }
        if v == .null { return nil }; return try string(d, k)
    }
    static func revision(_ d: Object) throws { guard try integer(d, "schema_revision") == 1 else { throw ControlAPIError.invalidResponse } }
    static func object(_ value: ConsoleValue?) throws -> Object {
        guard let v = value?.fields else { throw ControlAPIError.invalidResponse }; return v
    }
    static func decode(_ data: Data) throws -> Object {
        guard data.count <= 65536 else { throw ControlAPIError.oversizedResponse }
        try ControlConsoleClient.validateJSONBounds(data)
        return try JSONDecoder().decode(Object.self, from: data)
    }
    // Same canonical form as pinned key_metadata_codec: UTF-8, sorted ASCII keys,
    // unescaped Unicode/slashes, JSON control escaping, no floats in metadata payloads.
    static func canonical(_ value: ConsoleValue) throws -> String {
        switch value {
        case .null: return "null"
        case .boolean(let b): return b ? "true" : "false"
        case .integer(let n): return String(n)
        case .string(let s):
            var out = "\""
            for c in s.unicodeScalars {
                switch c.value {
                case 34: out += "\\\""
                case 92: out += "\\\\"
                case 8: out += "\\b"
                case 9: out += "\\t"
                case 10: out += "\\n"
                case 12: out += "\\f"
                case 13: out += "\\r"
                case 0..<32: out += String(format: "\\u%04x", c.value)
                default: out.unicodeScalars.append(c)
                }
            }
            return out + "\""
        case .array(let a): return "[" + (try a.map(canonical)).joined(separator: ",") + "]"
        case .object(let d):
            return "{" + (try d.keys.sorted().map { try canonical(.string($0)) + ":" + canonical(d[$0]!) }).joined(separator: ",") + "}"
        case .number: throw ControlAPIError.invalidRequest
        }
    }
    static func digest(_ v: ConsoleValue) throws -> String {
        SHA256.hash(data: Data(try canonical(v).utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct MetadataTarget: Equatable, Codable {
    let id: String
    let clientID: Int64?
    var fields: MetadataWire.Object {
        var d: MetadataWire.Object = ["kind": .string("key"), "id": .string(id)]
        if let clientID { d["client_id"] = .integer(clientID) }; return d
    }
    enum CodingKeys: String, CodingKey { case kind, id, clientID = "client_id" }
    init(id: String, clientID: Int64? = nil) throws {
        guard ConsoleTarget.uuid(id), clientID.map({ $0 > 0 }) ?? true else { throw ControlAPIError.invalidRequest }
        self.id = id; self.clientID = clientID
    }
    init(_ d: MetadataWire.Object) throws {
        try MetadataWire.keys(d, ["kind", "id"], optional: ["client_id"])
        guard try MetadataWire.string(d, "kind") == "key" else { throw ControlAPIError.invalidResponse }
        try self.init(id: MetadataWire.string(d, "id"), clientID: d["client_id"] == nil ? nil : MetadataWire.integer(d, "client_id", minimum: 1))
    }
    init(from decoder: Decoder) throws { try self.init(MetadataWire.Object(from: decoder)) }
    func encode(to encoder: Encoder) throws { try fields.encode(to: encoder) }
}

struct KeyMetadataSnapshot: Equatable {
    let keyID: String, clientID: Int64, originalName: String, effectiveName: String, nameSource: String
    let note: String, revision: Int64, viewRevision: String, updatedAt: String?
    init(_ d: MetadataWire.Object) throws {
        try MetadataWire.keys(d, ["schema_revision", "key_id", "client_id", "original_name", "effective_name", "name_source", "note", "metadata_revision", "view_revision", "updated_at"])
        try MetadataWire.revision(d)
        keyID = try MetadataWire.string(d, "key_id"); clientID = try MetadataWire.integer(d, "client_id", minimum: 1)
        originalName = try MetadataWire.string(d, "original_name"); effectiveName = try MetadataWire.string(d, "effective_name")
        nameSource = try MetadataWire.string(d, "name_source"); note = try MetadataWire.string(d, "note", max: 1000)
        revision = try MetadataWire.integer(d, "metadata_revision"); viewRevision = try MetadataWire.string(d, "view_revision")
        updatedAt = try MetadataWire.nullableString(d, "updated_at")
        guard ConsoleTarget.uuid(keyID), MetadataWire.hash(viewRevision), updatedAt.map(MetadataWire.utc) ?? true else { throw ControlAPIError.invalidResponse }
        if nameSource == "original" {
            guard revision == 0, effectiveName == originalName, note.isEmpty, updatedAt == nil else { throw ControlAPIError.invalidResponse }
        } else {
            guard nameSource == "override", revision > 0, updatedAt != nil,
                  try ControlMetadataDraft(name: effectiveName, note: note).normalized() == ControlMetadataDraft(name: effectiveName, note: note) else { throw ControlAPIError.invalidResponse }
        }
    }
    func matches(_ target: MetadataTarget) -> Bool { keyID == target.id && (target.clientID == nil || target.clientID == clientID) }
}

struct MetadataRequest {
    let operationID: String, target: MetadataTarget, draft: ControlMetadataDraft, expectedRevision: String, digest: String
    var payload: MetadataWire.Object { ["target": .object(target.fields), "parameters": .object(["name": .string(draft.name), "note": .string(draft.note), "expected_view_revision": .string(expectedRevision)])] }
    var fields: MetadataWire.Object { ["operation_id": .string(operationID), "action": .string("key_metadata_update"), "target": .object(target.fields), "parameters": payload["parameters"]!] }
    init(operationID: String, target: MetadataTarget, draft: ControlMetadataDraft, expectedRevision: String) throws {
        guard MetadataWire.hash(operationID, count: 32), MetadataWire.hash(expectedRevision) else { throw ControlAPIError.invalidRequest }
        self.operationID = operationID; self.target = target; self.draft = try draft.normalized(); self.expectedRevision = expectedRevision
        let p: MetadataWire.Object = ["target": .object(target.fields), "parameters": .object(["name": .string(self.draft.name), "note": .string(self.draft.note), "expected_view_revision": .string(expectedRevision)])]
        digest = try MetadataWire.digest(.array([.string("metadata-operation-r1"), .object(p)]))
    }
    func data() throws -> Data {
        let data = Data(try MetadataWire.canonical(.object(fields)).utf8)
        guard data.count <= 8192 else { throw ControlAPIError.invalidRequest }; return data
    }
}

struct MetadataCapabilities {
    let enabled: Bool
    init(_ d: MetadataWire.Object) throws {
        try MetadataWire.keys(d, ["schema_revision", "enabled", "reason_code", "normalization", "length_unit", "name_min", "name_max", "note_max", "preview_ttl_seconds", "request_max_bytes"])
        try MetadataWire.revision(d); enabled = try MetadataWire.flag(d, "enabled")
        let reason = try MetadataWire.nullableString(d, "reason_code")
        guard try MetadataWire.string(d, "normalization") == "NFC", try MetadataWire.string(d, "length_unit") == "unicode_scalar",
              try MetadataWire.integer(d, "name_min") == 1, try MetadataWire.integer(d, "name_max") == 80,
              try MetadataWire.integer(d, "note_max") == 1000, try MetadataWire.integer(d, "preview_ttl_seconds") == 120,
              try MetadataWire.integer(d, "request_max_bytes") == 8192,
              (enabled && reason == nil) || (!enabled && reason == "METADATA_STORAGE_UNAVAILABLE") else { throw ControlAPIError.invalidResponse }
    }
}

struct MetadataPreview {
    let target: MetadataTarget, before: KeyMetadataSnapshot, after: ControlMetadataDraft, expectedRevision: String, digest: String
    init(_ d: MetadataWire.Object) throws {
        try MetadataWire.keys(d, ["target", "before", "after", "expected_view_revision", "request_digest"])
        target = try MetadataTarget(MetadataWire.object(d["target"])); before = try KeyMetadataSnapshot(MetadataWire.object(d["before"]))
        let a = try MetadataWire.object(d["after"]); try MetadataWire.keys(a, ["effective_name", "note", "business_fields_unchanged"])
        after = ControlMetadataDraft(name: try MetadataWire.string(a, "effective_name", max: 80), note: try MetadataWire.string(a, "note", max: 1000))
        expectedRevision = try MetadataWire.string(d, "expected_view_revision"); digest = try MetadataWire.string(d, "request_digest")
        guard try MetadataWire.flag(a, "business_fields_unchanged"), try after.normalized() == after,
              before.matches(target), expectedRevision == before.viewRevision, MetadataWire.hash(digest) else { throw ControlAPIError.invalidResponse }
        let request = try MetadataRequest(operationID: String(repeating: "0", count: 32), target: target, draft: after, expectedRevision: expectedRevision)
        guard request.digest == digest else { throw ControlAPIError.invalidResponse }
    }
}

struct MetadataOperation {
    let operationID: String, digest: String, target: MetadataTarget, state: ControlOperationState
    let expiresAt: String?, preview: MetadataPreview?, result: KeyMetadataSnapshot?, errorCode: String?, token: String?
    init(_ d: MetadataWire.Object) throws {
        try MetadataWire.keys(d, ["schema_revision", "operation_id", "action", "state", "request_digest", "target", "expires_at", "preview", "result", "error_code", "confirmation_token"])
        try MetadataWire.revision(d); operationID = try MetadataWire.string(d, "operation_id"); digest = try MetadataWire.string(d, "request_digest")
        target = try MetadataTarget(MetadataWire.object(d["target"]))
        guard let state = ControlOperationState(rawValue: try MetadataWire.string(d, "state")),
              try MetadataWire.string(d, "action") == "key_metadata_update", MetadataWire.hash(operationID, count: 32), MetadataWire.hash(digest) else { throw ControlAPIError.invalidResponse }
        self.state = state; expiresAt = try MetadataWire.nullableString(d, "expires_at"); token = try MetadataWire.nullableString(d, "confirmation_token")
        errorCode = try MetadataWire.nullableString(d, "error_code")
        preview = d["preview"] == .null ? nil : try MetadataPreview(MetadataWire.object(d["preview"]))
        result = d["result"] == .null ? nil : try KeyMetadataSnapshot(MetadataWire.object(d["result"]))
        guard expiresAt.map(MetadataWire.utc) ?? true, token.map({ MetadataWire.hash($0) }) ?? true,
              errorCode.map({ MetadataWire.errors.contains($0) }) ?? true else { throw ControlAPIError.invalidResponse }
        if let preview { guard preview.target == target, preview.digest == digest else { throw ControlAPIError.invalidResponse } }
        if let result { guard result.matches(target) else { throw ControlAPIError.invalidResponse } }
        if state != .succeeded { guard result == nil else { throw ControlAPIError.invalidResponse } }
        if state == .prepared { guard preview != nil, expiresAt != nil, errorCode == nil, result == nil else { throw ControlAPIError.invalidResponse } }
        else { guard token == nil else { throw ControlAPIError.invalidResponse } }
        if state == .succeeded {
            guard let result, let preview, preview.before.revision < Int64.max,
                  result.revision == preview.before.revision + 1, result.effectiveName == preview.after.name,
                  result.note == preview.after.note, result.originalName == preview.before.originalName,
                  result.clientID == preview.before.clientID, result.nameSource == "override", errorCode == nil else { throw ControlAPIError.invalidResponse }
        }
    }
    func check(id: String, target: MetadataTarget, digest: String) throws {
        guard operationID == id, self.target == target, self.digest == digest else { throw ControlAPIError.invalidResponse }
    }
}

struct ControlOverview {
    let registeredClients: Int64, activeClients: Int64, activeKeys: Int64, slotsUsed: Int64, snapshotAt: String
    static let counters = Set(["registered_clients", "active_clients", "active_keys", "slots_used"])
    static func validateCapabilities(_ d: MetadataWire.Object) throws -> Bool {
        try MetadataWire.keys(d, ["schema_revision", "enabled", "scope", "counters"]); try MetadataWire.revision(d)
        guard try MetadataWire.string(d, "scope") == "non_owner_clients", let a = d["counters"]?.values,
              a.count == 4, Set(a.compactMap(\.text)) == counters else { throw ControlAPIError.invalidResponse }
        return try MetadataWire.flag(d, "enabled")
    }
    init(_ d: MetadataWire.Object) throws {
        try MetadataWire.keys(d, ["schema_revision", "registered_clients", "active_clients", "active_keys", "slots_used", "snapshot_at", "scope"]); try MetadataWire.revision(d)
        registeredClients = try MetadataWire.integer(d, "registered_clients"); activeClients = try MetadataWire.integer(d, "active_clients")
        activeKeys = try MetadataWire.integer(d, "active_keys"); slotsUsed = try MetadataWire.integer(d, "slots_used"); snapshotAt = try MetadataWire.string(d, "snapshot_at")
        guard try MetadataWire.string(d, "scope") == "non_owner_clients", MetadataWire.utc(snapshotAt),
              activeClients <= registeredClients, activeKeys >= activeClients, activeKeys <= slotsUsed else { throw ControlAPIError.invalidResponse }
    }
}

final class ControlMetadataClient {
    private let transport: ControlHTTPTransport
    init(transport: ControlHTTPTransport) { self.transport = transport }
    private func call(path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil) async throws -> MetadataWire.Object {
        let (status, data) = try await transport.send(method: method, path: path, query: query, body: body)
        let d = try MetadataWire.decode(data)
        guard (200...299).contains(status) else {
            try MetadataWire.keys(d, ["error"]); let e = try MetadataWire.object(d["error"])
            try MetadataWire.keys(e, ["code", "message", "retryable"])
            guard MetadataWire.errors.contains(try MetadataWire.string(e, "code")), try MetadataWire.string(e, "message", max: 240).unicodeScalars.count <= 240,
                  try !MetadataWire.flag(e, "retryable") else { throw ControlAPIError.invalidResponse }
            switch status { case 401,403: throw ControlAPIError.forbidden; case 404: throw ControlAPIError.notFound; case 409: throw ControlAPIError.conflict; case 410: throw ControlAPIError.expired; case 429: throw ControlAPIError.busy; default: throw ControlAPIError.unavailable }
        }
        return d
    }
    func capabilities() async throws -> MetadataCapabilities { try MetadataCapabilities(await call(path: "/v2/key-metadata/capabilities")) }
    func key(_ t: MetadataTarget) async throws -> KeyMetadataSnapshot {
        let d = try await call(path: "/v2/key-metadata/keys/" + t.id, query: t.clientID.map { [URLQueryItem(name: "client_id", value: String($0))] } ?? [])
        let v = try KeyMetadataSnapshot(d); guard v.matches(t) else { throw ControlAPIError.invalidResponse }; return v
    }
    func preview(_ r: MetadataRequest) async throws -> MetadataOperation {
        let v = try MetadataOperation(await call(path: "/v2/key-metadata/operations/previews", method: "POST", body: r.data()))
        try v.check(id: r.operationID, target: r.target, digest: r.digest)
        guard let p = v.preview, p.after == r.draft, p.expectedRevision == r.expectedRevision else { throw ControlAPIError.invalidResponse }; return v
    }
    func status(id: String, target: MetadataTarget, digest: String) async throws -> MetadataOperation {
        guard MetadataWire.hash(id, count: 32) else { throw ControlAPIError.invalidRequest }
        let v = try MetadataOperation(await call(path: "/v2/key-metadata/operations/" + id)); try v.check(id: id, target: target, digest: digest)
        guard v.token == nil else { throw ControlAPIError.invalidResponse }; return v
    }
    func proof(id: String, target: MetadataTarget, digest: String, token: String, cancel: Bool) async throws -> MetadataOperation {
        guard MetadataWire.hash(id, count: 32), MetadataWire.hash(token) else { throw ControlAPIError.invalidRequest }
        let body = Data(try MetadataWire.canonical(.object(["confirmation_token": .string(token)])).utf8)
        let v = try MetadataOperation(await call(path: "/v2/key-metadata/operations/" + id + (cancel ? "/cancel" : "/confirm"), method: "POST", body: body))
        try v.check(id: id, target: target, digest: digest); return v
    }
    func overviewCapabilities() async throws -> Bool { try ControlOverview.validateCapabilities(await call(path: "/v2/overview/capabilities")) }
    func overview() async throws -> ControlOverview { try ControlOverview(await call(path: "/v2/overview")) }
}
