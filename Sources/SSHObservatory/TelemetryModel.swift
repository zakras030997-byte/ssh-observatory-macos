import AppKit
import Foundation
import TelemetryCore

enum LinkState: Equatable {
    case idle, connecting, online, retry(Int), failed(String), paused
    var title: String {
        switch self {
        case .idle: return "Не подключено"
        case .connecting: return "Подключение"
        case .online: return "На связи"
        case .retry(let n): return "Повтор \(n)/4"
        case .failed: return "Ошибка связи"
        case .paused: return "Пауза"
        }
    }
    var active: Bool {
        switch self { case .connecting, .online, .retry: return true; default: return false }
    }
}

@MainActor final class NodeModel: ObservableObject, Identifiable {
    typealias Factory = (NodeProfile, String, SessionCallbacks) -> SessionControl
    let profile: NodeProfile
    nonisolated let id: String
    @Published var state: LinkState = .idle
    @Published var window = SampleWindow()
    @Published var historyFailed = false
    @Published var skippedSamples = 0
    @Published private(set) var userPaused: Bool
    private var session: SessionControl?
    private var mailbox: LatestValueMailbox<TelemetrySample>?
    private var reconnectTask: Task<Void,Never>?
    private var generation = UUID()
    private var segment = UUID()
    private var retries = 0
    private var consecutiveSamples = 0
    private var receivedUptime: TimeInterval?
    private let policy = ReconnectPolicy()
    private let collector: String
    private let history: HistoryStore?
    private let factory: Factory
    private let retryDelay: Duration
    private let intentChanged: ((Bool) -> Void)?
    let demo: Bool
    var latest: ReceivedSample? { window.points.last }
    var fresh: Bool { state == .online && receivedUptime.map { ProcessInfo.processInfo.systemUptime - $0 < 12 } == true }
    init(profile: NodeProfile, demo: Bool, collector: String, history: HistoryStore?, userPaused: Bool = false,
         retryDelay: Duration = .seconds(5), loadHistory: Bool = true,
         factory: @escaping Factory = { p,c,cb in SSHSession(profile:p,collector:c,onSample:cb.sample,onExit:cb.exit) },
         intentChanged: ((Bool) -> Void)? = nil) {
        self.id=profile.id; self.profile=profile; self.demo=demo; self.collector=collector; self.history=history
        self.userPaused=userPaused; self.factory=factory; self.retryDelay=retryDelay; self.intentChanged=intentChanged
        if userPaused { state = .paused }
        if !demo, loadHistory, let history {
            Task { [weak self] in
                let result = await Task.detached(priority:.utility) { Result { try history.recent(nodeID:profile.id,expectedHostname:profile.expectedHostname) } }.value
                guard let self else { return }
                switch result {
                case .success(let points):
                    if self.window.points.isEmpty { for p in points { self.window.append(p) } }
                case .failure: self.historyFailed=true
                }
            }
        }
    }
    func connect(force: Bool = false) {
        guard !demo, force || !state.active else { return }
        userPaused=false; intentChanged?(false)
        stop(); retries=0; begin()
    }
    private func begin() {
        generation=UUID(); segment=UUID(); consecutiveSamples=0
        let token=generation, delivery=LatestValueMailbox<TelemetrySample>()
        mailbox=delivery; state = retries == 0 ? .connecting : .retry(retries)
        let callbacks=SessionCallbacks(sample: { [weak self] sample in
            guard delivery.offer(sample) else { return }
            Task { @MainActor [weak self] in
                guard let sample=delivery.take(), let self, self.generation==token else { return }
                self.skippedSamples=delivery.skippedCount
                self.consecutiveSamples=delivery.offeredCount
                self.accept(sample)
            }
        }, exit: { [weak self] failure in
            let validSamples=delivery.close()
            Task { @MainActor [weak self] in self?.failed(failure,token:token,validSamples:validSamples) }
        })
        let connection=factory(profile,collector,callbacks)
        session=connection; connection.start()
    }
    private func accept(_ sample: TelemetrySample) {
        if let last=latest, last.sample.bootID != sample.bootID { segment=UUID() }
        let point=ReceivedSample(sample:sample,segment:segment)
        guard window.append(point) else { return }
        receivedUptime=ProcessInfo.processInfo.systemUptime; state = .online
        if consecutiveSamples >= 10 { retries=0 }
        if let history {
            let accepted=history.enqueue(point,nodeID:sample.nodeID) { [weak self] in
                Task { @MainActor [weak self] in self?.historyFailed=true }
            }
            if !accepted { historyFailed=true }
        }
    }
    private func failed(_ error: SessionFailure, token: UUID, validSamples: Int) {
        guard generation==token else { return }
        // Channel health is counted before UI coalescing, including the final
        // pending record that close invalidates. UI speed cannot exhaust retries.
        if validSamples >= 10 { retries=0 }
        generation=UUID(); let retryToken=generation
        mailbox?.close(); mailbox=nil; session=nil
        guard policy.canRetry(afterRetries:retries,permanent:error.permanent) else { state = .failed(error.message); return }
        retries += 1; state = .retry(retries)
        reconnectTask=Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for:self.retryDelay)
            guard !Task.isCancelled, self.generation==retryToken, !self.userPaused else { return }
            self.begin()
        }
    }
    func pause() { userPaused=true; stop(paused:true); intentChanged?(true) }
    func stop(paused: Bool = false) {
        generation=UUID(); reconnectTask?.cancel(); reconnectTask=nil
        mailbox?.close(); mailbox=nil; session?.stop(); session=nil
        state = paused || userPaused ? .paused : .idle
    }
    func feedDemo(_ samples:[TelemetrySample]) {
        guard demo else { return }; state = .online
        for sample in samples { window.append(ReceivedSample(sample:sample,receivedAt:sample.date,segment:segment)) }
    }
}

struct LaunchSettings: Codable {
    let mode:String
    let autoConnect:Bool
    var pausedNodeIDs:[String]? = nil
}

@MainActor final class TelemetryModel: ObservableObject {
    @Published var nodes:[NodeModel]=[]
    @Published var demo=false
    @Published var notice:String?
    @Published private(set) var loading=false
    private var sleepObserver:NSObjectProtocol?
    private var wakeObserver:NSObjectProtocol?
    private var resumeIDs=Set<String>()
    private var pausedIDs=Set<String>()
    private var loadTask:Task<Void,Never>?
    private var loadGeneration=UUID()
    private var collector=""
    private var history:HistoryStore?
    private var autoConnect=false
    private let base:URL
    init(base:URL? = nil, collectorSource:String? = nil, restore:Bool = true, observeWorkspace:Bool = true) {
        self.base=base ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("SSH Observatory",isDirectory:true)
        #if SWIFT_PACKAGE
        let resourceBundle=Bundle.module
        #else
        let resourceBundle=Bundle.main
        #endif
        if let collectorSource { collector=collectorSource }
        else if let url=resourceBundle.url(forResource:"collector",withExtension:"py") { collector=(try? String(contentsOf:url,encoding:.utf8)) ?? "" }
        let saved=restore ? (try? Self.readLimited(self.base.appendingPathComponent("launch.json"),limit:16_384)).flatMap { try? JSONDecoder().decode(LaunchSettings.self,from:$0) } : nil
        pausedIDs=Set(saved?.pausedNodeIDs ?? [])
        enterRealMode(resume:saved?.mode == "live" && saved?.autoConnect == true)
        if observeWorkspace {
            let center=NSWorkspace.shared.notificationCenter
            sleepObserver=center.addObserver(forName:NSWorkspace.willSleepNotification,object:nil,queue:.main) { [weak self] _ in Task { @MainActor in self?.sleep() } }
            wakeObserver=center.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:.main) { [weak self] _ in Task { @MainActor in self?.wake() } }
        }
    }
    func sleep() {
        resumeIDs=Set(nodes.filter { $0.state.active && !$0.userPaused }.map(\.id))
        nodes.forEach { $0.stop(paused:true) }
    }
    func wake() {
        for node in nodes where resumeIDs.contains(node.id) && !node.userPaused { node.connect() }
        resumeIDs.removeAll()
    }
    func stopAll(rememberPause:Bool = false) {
        nodes.forEach { $0.stop() }; resumeIDs.removeAll()
        if rememberPause && !demo { saveLaunch(autoConnect:false) }
    }
    private func saveLaunch(autoConnect:Bool) {
        self.autoConnect=autoConnect
        do {
            try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let url=base.appendingPathComponent("launch.json")
            try JSONEncoder().encode(LaunchSettings(mode:demo ? "demo":"live",autoConnect:autoConnect,pausedNodeIDs:pausedIDs.sorted())).write(to:url,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        } catch { notice="Не удалось сохранить режим запуска; текущие соединения не изменены." }
    }
    func showDemo() {
        loadTask?.cancel(); loadGeneration=UUID(); stopAll(); demo=true; loading=false; notice=nil
        if FileManager.default.fileExists(atPath:base.path) { saveLaunch(autoConnect:false) }
        let profiles=[NodeProfile(id:"demo-bg",name:"Болгария",region:"Европа · Hysteria 2",sshAlias:"demo-bg"),
            NodeProfile(id:"demo-kz",name:"Казахстан",region:"Центральная Азия · VLESS",sshAlias:"demo-kz"),
            NodeProfile(id:"demo-us",name:"Новая Америка",region:"США · Hysteria 2",sshAlias:"demo-us"),
            NodeProfile(id:"demo-waw",name:"Варшава",region:"Европа · Trojan",sshAlias:"demo-waw")]
        nodes=profiles.enumerated().map { i,p in
            let node=NodeModel(profile:p,demo:true,collector:"",history:nil)
            node.feedDemo(DemoSamples.make(profile:p,index:i)); return node
        }
    }
    nonisolated static func readLimited(_ url:URL,limit:Int) throws -> Data {
        let handle=try FileHandle(forReadingFrom:url); defer { try? handle.close() }
        let data=try handle.read(upToCount:limit+1) ?? Data()
        guard data.count <= limit else { throw TelemetryError.invalidProfile }; return data
    }
    func enterRealMode(resume:Bool = false) {
        loadTask?.cancel(); stopAll(); demo=false; notice=nil; loading=true; nodes=[]
        loadGeneration=UUID(); let token=loadGeneration, directory=base
        saveLaunch(autoConnect:resume)
        loadTask=Task { [weak self] in
            let result=await Task.detached(priority:.utility) { () -> Result<([NodeProfile],HistoryStore?,Bool),Error> in
                Result {
                    let url=directory.appendingPathComponent("nodes.json")
                    let profiles=FileManager.default.fileExists(atPath:url.path) ? try JSONDecoder().decode([NodeProfile].self,from:Self.readLimited(url,limit:128_000)) : []
                    guard profiles.count <= 24, Set(profiles.map(\.id)).count==profiles.count else { throw TelemetryError.invalidProfile }
                    try profiles.forEach { try $0.validate() }
                    let history=try? HistoryStore(url:directory.appendingPathComponent("history.sqlite"))
                    return (profiles,history,history == nil)
                }
            }.value
            guard let self, !Task.isCancelled, self.loadGeneration==token, !self.demo else { return }
            self.loading=false
            switch result {
            case .success(let (profiles,history,historyError)):
                self.history=history; self.nodes=profiles.map { self.makeNode($0) }
                if historyError { self.notice="История недоступна; текущие показания сохраняются только в памяти." }
                if self.autoConnect { self.connectAll() }
            case .failure: self.nodes=[]; self.notice="Не удалось прочитать список серверов. Исходный файл не изменён."
            }
        }
    }
    private func makeNode(_ profile:NodeProfile) -> NodeModel {
        NodeModel(profile:profile,demo:false,collector:collector,history:history,userPaused:pausedIDs.contains(profile.id),intentChanged:{ [weak self] paused in
            guard let self else { return }
            if paused { self.pausedIDs.insert(profile.id); self.resumeIDs.remove(profile.id) }
            else { self.pausedIDs.remove(profile.id) }
            self.saveLaunch(autoConnect:paused ? self.autoConnect:true)
        })
    }
    func add(_ profile:NodeProfile) throws {
        try profile.validate()
        guard !demo, !loading, nodes.count < 24, !nodes.contains(where: {
            ($0.profile.sshAlias==profile.sshAlias && $0.profile.sshConfigPath==profile.sshConfigPath) || $0.id==profile.id
        }) else { throw TelemetryError.invalidProfile }
        let profiles=nodes.map(\.profile)+[profile],url=base.appendingPathComponent("nodes.json")
        try JSONEncoder().encode(profiles).write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        nodes.append(makeNode(profile))
    }
    func connectAll(includePaused:Bool = false) {
        guard !demo, !loading, !collector.isEmpty, !nodes.isEmpty else { return }
        saveLaunch(autoConnect:true)
        for node in nodes where (includePaused || !node.userPaused) && !node.state.active { node.connect() }
    }
}

enum DemoSamples {
    static func make(profile: NodeProfile, index: Int) -> [TelemetrySample] {
        let now = Date().timeIntervalSince1970
        return (0..<100).map { i in
            let phase = Double(i) / 8 + Double(index) * 2
            let cpu = max(2, min(98, 18 + Double(index) * 10 + sin(phase) * 7 + cos(phase * 2.1) * 3))
            return TelemetrySample(schema: 1, nodeID: profile.id, hostname: "demonstration", bootID: "demo-boot", sequence: i,
                measuredAt: now - Double(99 - i) * 3, uptime: 248_000, cores: index == 2 ? 1 : 2,
                cpuPercent: cpu, memory: ByteUsage(total: 4 * 1_073_741_824, available: (2.7 - Double(index) * 0.36) * 1_073_741_824),
                swap: ByteUsage(total: 0, available: 0), disk: ByteUsage(total: 40 * 1_073_741_824, available: Double(28 - index * 4) * 1_073_741_824),
                network: NetworkRate(receivedBytesPerSecond: (4 + sin(phase)) * 1_000_000, sentBytesPerSecond: (1 + cos(phase) * 0.2) * 1_000_000),
                load: [0.3, 0.2, 0.1], units: [UnitStatus(name: index == 1 ? "xray.service" : "hysteria.service", state: "active", restarts: 0)], errors: [:])
        }
    }
}
