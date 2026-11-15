import Foundation

struct RouteEvidence: Equatable {
    let confirmed:Bool
    let observedAt:Date?
    static let unknown=RouteEvidence(confirmed:false,observedAt:nil)
    func isFresh(at date:Date)->Bool {
        guard let observedAt else {return false}
        let age=date.timeIntervalSince(observedAt)
        return confirmed && age >= -5 && age < 15
    }
}

/// Candidate supervisor. This does not attest the security of VPN split rules.
@MainActor final class ProtectedRoute {
    private let runtimeOverride:URL?
    init(runtimeOverride:URL? = nil) { self.runtimeOverride=runtimeOverride }
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var pending = Data()
    private var generation = UUID()
    private var retry: Task<Void,Never>?
    private var stopped = true
    private(set) var port: Int?
    var changed: ((Int?) -> Void)?
    var evidenceChanged: ((RouteEvidence) -> Void)?
    private var revocations:[UUID:() -> Void]=[:]

    func register(_ revoke:@escaping () -> Void) -> UUID? {
        guard port != nil else { return nil }
        let token=UUID(); revocations[token]=revoke; return token
    }
    func unregister(_ token:UUID) { revocations.removeValue(forKey:token) }

    func start() {
        guard stopped else { return }
        stopped = false
        launch()
    }
    func stop() {
        stopped = true; retry?.cancel(); retry=nil
        generation=UUID(); setPort(nil);evidenceChanged?(.unknown)
        output?.fileHandleForReading.readabilityHandler=nil
        try? input?.fileHandleForWriting.close()
        process=nil; input=nil; output=nil; pending.removeAll()
    }
    private func setPort(_ value:Int?) {
        guard port != value else { return }
        port=value
        if value == nil {
            let callbacks=Array(revocations.values); revocations.removeAll()
            callbacks.forEach { $0() }
        }
        changed?(value)
    }
    private func launch() {
        guard !stopped, process == nil else { return }
        guard let runtime=runtimeOverride ?? Bundle.main.url(forResource:"route_runtime",withExtension:"py",subdirectory:"vpn-tor") else {
            setPort(nil); return
        }
        let task=Process(), stdin=Pipe(), stdout=Pipe(), token=UUID()
        generation=token; pending.removeAll()
        task.executableURL=URL(fileURLWithPath:"/usr/bin/python3")
        task.arguments=["-B",runtime.path]; task.standardInput=stdin; task.standardOutput=stdout
        task.standardError=FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data=handle.availableData
            Task { @MainActor [weak self] in self?.receive(data,token:token) }
        }
        task.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in self?.ended(token:token) }
        }
        process=task; input=stdin; output=stdout
        do { try task.run() } catch { ended(token:token) }
    }
    private func receive(_ data:Data, token:UUID) {
        guard token==generation, !stopped else { return }
        if data.isEmpty { setPort(nil);evidenceChanged?(.unknown);return }
        pending.append(data)
        guard pending.count <= 8192 else { stop(); return }
        while let end=pending.firstIndex(of:10) {
            let frame=Data(pending[..<end]); pending.removeSubrange(...end)
            guard let json=(try? JSONSerialization.jsonObject(with:frame)) as? [String:Any],
                  let state=json["state"] as? String else { stop(); return }
            let observed=(json["observed_at"] as? NSNumber).map { Date(timeIntervalSince1970:$0.doubleValue) }
            if state == "unavailable" { setPort(nil);evidenceChanged?(RouteEvidence(confirmed:false,observedAt:observed)) }
            else if state == "ready", let number=json["port"] as? NSNumber,
                    (1024...65535).contains(number.intValue) { setPort(number.intValue);evidenceChanged?(RouteEvidence(confirmed:true,observedAt:observed)) }
            else { stop(); return }
        }
    }
    private func ended(token:UUID) {
        guard token==generation else { return }
        setPort(nil);evidenceChanged?(.unknown);output?.fileHandleForReading.readabilityHandler=nil
        process=nil; input=nil; output=nil; pending.removeAll()
        guard !stopped else { return }
        retry=Task { [weak self] in
            try? await Task.sleep(for:.seconds(3))
            guard !Task.isCancelled, let self, !self.stopped else { return }
            self.launch()
        }
    }
}
