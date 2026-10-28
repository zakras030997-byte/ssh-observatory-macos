import Foundation

// Uses only a local fixture transport. Never reads the installed profile or Keychain.
private final class WireTransport: ControlHTTPTransport {
    let response: Data
    let status: Int
    init(_ value: Any, status: Int = 200) throws { response = try JSONSerialization.data(withJSONObject: value); self.status = status }
    func send(method: String, path: String, query: [URLQueryItem], body: Data?) async throws -> (Int, Data) {
        (status, response)
    }
}

@main struct ControlConsoleWireChecks {
    static func recordKind(_ raw: String) -> ConsoleKind? {
        ["AccessRequestView": .request, "UserOverview": .client, "DeviceView": .key,
         "RefundOrderView": .order, "AdminHistoryView": .history,
         "ReferralView": .referral, "AdminProblemView": .attention][raw]
    }
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Supply one isolated WIRE-FIXTURES.json path") }
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        guard data.count <= 4_194_304,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contractSHA=root["contract_sha256"] as? String,
              [ConsoleRecordSchema.contractSHA,ConsoleReferralPlan.contractSHA].contains(contractSHA),
              let records = root["records"] as? [[String: Any]],
              let pages = root["pages"] as? [[String: Any]],
              let operations = root["operations"] as? [[String: Any]] else {
            fatalError("Fixture envelope or frozen contract mismatch")
        }
        var passed = 0, failed = 0
        func run(_ name: String, _ body: () async throws -> Void) async {
            do { try await body(); passed += 1; print("PASS wire: \(name)") }
            catch { failed += 1; print("FAIL wire: \(name) [\(type(of: error))]") }
        }
        for item in records {
            let name = item["name"] as? String ?? "record"
            await run(name) {
                if item["kind"] as? String == "Capabilities", let value = item["value"] {
                    _ = try await ControlConsoleClient(transport: WireTransport(value)).capabilities()
                    return
                }
                guard let rawKind = item["kind"] as? String, let kind = recordKind(rawKind),
                      let value = item["value"] else { throw ControlAPIError.invalidResponse }
                let bytes = try JSONSerialization.data(withJSONObject: value)
                try ControlConsoleClient.validateJSONBounds(bytes)
                let fields = try JSONDecoder().decode([String: ConsoleValue].self, from: bytes)
                _ = try ConsoleRecord(kind: kind, fields: fields)
            }
        }
        for item in pages {
            let name = item["name"] as? String ?? "page"
            await run(name) {
                guard let rawKind = item["kind"] as? String, let kind = recordKind(rawKind),
                      let path = item["path"] as? String, let value = item["value"] else { throw ControlAPIError.invalidResponse }
                let query = try (item["query"] as? [[String: Any]] ?? []).map { field -> URLQueryItem in
                    guard let key = field["name"] as? String, let value = field["value"] as? String else { throw ControlAPIError.invalidResponse }
                    return URLQueryItem(name: key, value: value)
                }
                _ = try await ControlConsoleClient(transport: WireTransport(value)).page(path: path, kind: kind, query: query)
            }
        }
        for item in operations {
            let name = item["name"] as? String ?? "operation"
            await run(name) {
                guard let requestValue = item["request"], let value = item["value"],
                      let isPreview = item["post_preview"] as? Bool else { throw ControlAPIError.invalidResponse }
                let request = try JSONDecoder().decode(ConsoleRequest.self, from: JSONSerialization.data(withJSONObject: requestValue))
                try request.validate()
                let status = item["http_status"] as? Int ?? 200
                let client = try ControlConsoleClient(transport: WireTransport(value, status: status))
                if status == 409 {
                    do { _ = try await client.preview(request) }
                    catch ControlAPIError.conflict { return }
                    throw ControlAPIError.invalidResponse
                }
                guard status == 200 else { throw ControlAPIError.invalidResponse }
                if isPreview { _ = try await client.preview(request) }
                else { _ = try await client.status(request) }
            }
        }
        print("Wire checks: \(passed + failed); failures: \(failed); records: \(records.count); pages: \(pages.count); operations: \(operations.count)")
        if failed > 0 { exit(1) }
    }
}
