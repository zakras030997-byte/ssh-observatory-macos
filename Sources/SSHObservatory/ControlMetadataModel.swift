import Foundation
import Combine

/// Only reconciliation identifiers are persisted. Names, notes and proofs stay in memory.
struct MetadataCheckpoint: Equatable {
    let operationID: String, target: MetadataTarget, connectionID: String, digest: String
    var state: ControlOperationState, metadataRevision: Int64?
    var fields: MetadataWire.Object {
        ["schema_revision":.integer(1), "operation_id":.string(operationID), "target":.object(target.fields),
         "connection_id":.string(connectionID), "request_digest":.string(digest), "receipt_state":.string(state.rawValue),
         "metadata_revision":metadataRevision.map(ConsoleValue.integer) ?? .null]
    }
    init(operationID: String, target: MetadataTarget, connectionID: String, digest: String, state: ControlOperationState, metadataRevision: Int64? = nil) throws {
        guard MetadataWire.hash(operationID,count:32), MetadataWire.hash(connectionID), MetadataWire.hash(digest), metadataRevision.map({$0 >= 0}) ?? true else { throw ControlAPIError.configuration }
        self.operationID=operationID; self.target=target; self.connectionID=connectionID; self.digest=digest; self.state=state; self.metadataRevision=metadataRevision
    }
    init(_ d: MetadataWire.Object) throws {
        try MetadataWire.keys(d,["schema_revision","operation_id","target","connection_id","request_digest","receipt_state","metadata_revision"])
        try MetadataWire.revision(d)
        guard let state=ControlOperationState(rawValue:try MetadataWire.string(d,"receipt_state")) else { throw ControlAPIError.configuration }
        try self.init(operationID:MetadataWire.string(d,"operation_id"), target:MetadataTarget(MetadataWire.object(d["target"])), connectionID:MetadataWire.string(d,"connection_id"), digest:MetadataWire.string(d,"request_digest"), state:state, metadataRevision:d["metadata_revision"] == .null ? nil:MetadataWire.integer(d,"metadata_revision"))
    }
}

final class MetadataLocalStore {
    let directory: URL
    var file: URL { directory.appendingPathComponent("pending-metadata-r1.json") }
    init(directory: URL? = nil) { self.directory=directory ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("SSH Observatory/control-api",isDirectory:true) }
    private func checkPath() throws {
        for p in [directory,file] where FileManager.default.fileExists(atPath:p.path) {
            let a=try FileManager.default.attributesOfItem(atPath:p.path)
            guard a[.type] as? FileAttributeType != .typeSymbolicLink else { throw ControlAPIError.configuration }
        }
    }
    func load() throws -> MetadataCheckpoint? {
        try checkPath(); guard FileManager.default.fileExists(atPath:file.path) else { return nil }
        let h=try FileHandle(forReadingFrom:file); defer { try? h.close() }
        let d=try h.read(upToCount:8193) ?? Data(); guard d.count <= 8192 else { throw ControlAPIError.configuration }
        return try MetadataCheckpoint(MetadataWire.decode(d))
    }
    func save(_ value: MetadataCheckpoint) throws {
        try checkPath()
        let d=Data(try MetadataWire.canonical(.object(value.fields)).utf8); guard d.count <= 8192 else { throw ControlAPIError.configuration }
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:directory.path)
        try d.write(to:file,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
    func clear() throws { try checkPath(); if FileManager.default.fileExists(atPath:file.path) { try FileManager.default.removeItem(at:file) } }
}

@MainActor final class ControlMetadataModel: ObservableObject {
    @Published private(set) var ready=false
    @Published private(set) var enabled=false
    @Published private(set) var busy=false
    @Published private(set) var journalBlocked=false
    @Published private(set) var needsStatus=false
    @Published private(set) var statusNotFound=false
    @Published private(set) var pending: MetadataCheckpoint?
    @Published private(set) var receipt: MetadataOperation?
    @Published private(set) var snapshots: [String:KeyMetadataSnapshot]=[:]
    @Published private(set) var overview: ControlOverview?
    @Published private(set) var overviewEnabled=false
    @Published private(set) var notice: String?
    @Published private(set) var overviewNotice: String?
    let legacy: ControlAPIModel
    private let store: MetadataLocalStore
    private var client: ControlMetadataClient?, connectionID: String?, generation=0
    private var subscription: AnyCancellable?
    init(legacy:ControlAPIModel,store:MetadataLocalStore=MetadataLocalStore()) {
        self.legacy=legacy; self.store=store
        do { pending=try store.load(); needsStatus=pending != nil } catch { journalBlocked=true; notice="Не удалось прочитать журнал имён и заметок. Изменения заблокированы до сверки операции." }
        updateLock(); subscription=legacy.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }
    var unresolved: Bool { pending != nil && (needsStatus || pending?.state.terminal != true) }
    private var legacyClear: Bool { legacy.connected && !legacy.busy && !legacy.journalBlocked && !legacy.isOperationBlocked(excluding:.metadata) && (legacy.pending == nil || legacy.pending?.receipt?.state.terminal == true) }
    var canStart: Bool { ready && enabled && !busy && !journalBlocked && !unresolved && legacyClear }
    var canConfirm: Bool {
        guard ready, enabled, !busy, !journalBlocked, !needsStatus, legacyClear, let r=receipt, r.state == .prepared, r.token != nil, let raw=r.expiresAt, let expiry=ControlOperationReceipt.parseDate(raw), expiry > Date(), pending?.connectionID == connectionID else { return false }; return true
    }
    var canRefreshPreview: Bool { ready && enabled && !busy && !journalBlocked && !needsStatus && legacyClear && receipt?.state == .prepared && receipt?.preview != nil && pending?.connectionID == connectionID }
    var canAbandon: Bool { ready && !busy && !journalBlocked && statusNotFound && pending?.state == .prepared && pending?.connectionID == connectionID }
    private func updateLock() { legacy.setOperationBlocked(busy || journalBlocked || unresolved,source:.metadata) }
    private func setBusy(_ value: Bool) { busy=value; updateLock() }
    private func save(_ value: MetadataCheckpoint) throws {
        do { try store.save(value); pending=value; updateLock() } catch { journalBlocked=true; updateLock(); throw error }
    }
    func connect() async {
        guard let p=legacy.profile, let transport=legacy.connectedManagementTransport() else { disconnect(); return }
        await attach(profile:p,client:ControlMetadataClient(transport:transport))
    }
    func attach(profile:ControlConnectionProfile,client:ControlMetadataClient) async {
        guard !busy else { return }; generation += 1; let g=generation; setBusy(true); defer { if generation==g { setBusy(false) } }
        ready=false; enabled=false; snapshots=[:]; overview=nil; overviewEnabled=false; receipt=nil; notice=nil; overviewNotice=nil; self.client=nil; connectionID=nil; statusNotFound=false; needsStatus=pending != nil
        do {
            let binding=try ConsoleLocalStore.connectionID(profile)
            if let p=pending,p.connectionID != binding { notice="Сохранённая операция относится к другому подключению. Верните прежний адрес и сертификат для сверки."; return }
            self.client=client; connectionID=binding
            do { let c=try await client.capabilities(); guard generation==g else { return }; ready=true; enabled=c.enabled; if !c.enabled { notice="Хранилище имён и заметок сейчас недоступно." } }
            catch ControlAPIError.notFound { guard generation==g else { return }; notice="Пакет имён и заметок ещё не установлен на сервере." }
            catch { guard generation==g else { return }; notice=message(error) }
            if generation==g,ready,let p=pending { do { let r=try await client.status(id:p.operationID,target:p.target,digest:p.digest); guard generation==g else { return }; try apply(r) } catch ControlAPIError.notFound { guard generation==g else { return }; statusNotFound=true; notice="Сохранённая операция не найдена. Отправленное подтверждение автоматически не повторяется." } catch { guard generation==g else { return }; notice=message(error) } }
            guard generation==g else { return }
            do { let ok=try await client.overviewCapabilities(); guard generation==g else { return }; overviewEnabled=ok; if ok { let v=try await client.overview(); guard generation==g else { return }; overview=v } else { overviewNotice="Сводка клиентов отключена на сервере." } }
            catch { guard generation==g else { return }; overviewNotice="Сводка клиентов пока недоступна; нулевые значения не подставляются." }
        } catch { if generation==g { notice=message(error) } }
    }
    func disconnect() { generation += 1; client=nil; connectionID=nil; ready=false; enabled=false; overviewEnabled=false; overview=nil; snapshots=[:]; receipt=nil; statusNotFound=false; if pending != nil { needsStatus=true }; setBusy(false) }
    func refreshOverview() async {
        guard !busy,overviewEnabled,let client else { return }; let g=generation; setBusy(true); defer { if generation==g { setBusy(false) } }; overviewNotice=nil
        do { let v=try await client.overview(); guard generation==g else { return }; overview=v } catch { if generation==g { overviewNotice="Обновление сводки не удалось. Показан предыдущий снимок." } }
    }
    func load(_ target: MetadataTarget) async {
        guard ready,!busy,let client else { return }; let g=generation; setBusy(true); defer { if generation==g { setBusy(false) } }; notice=nil
        do { let v=try await client.key(target); guard generation==g else { return }; cache(v) } catch { if generation==g { snapshots.removeValue(forKey:target.id); notice=message(error) } }
    }
    func prepare(target:MetadataTarget,snapshot:KeyMetadataSnapshot,draft:ControlMetadataDraft) async {
        guard canStart, snapshot.matches(target), let client, let binding=connectionID else { return }; let g=generation; setBusy(true); defer { if generation==g { setBusy(false) } }; notice=nil; statusNotFound=false
        do {
            let request=try MetadataRequest(operationID:ControlPreviewRequest.newID(),target:target,draft:draft,expectedRevision:snapshot.viewRevision)
            try save(MetadataCheckpoint(operationID:request.operationID,target:target,connectionID:binding,digest:request.digest,state:.prepared)); receipt=nil; needsStatus=true
            let r=try await client.preview(request); guard generation==g else { return }; try apply(r)
        } catch { if generation==g { notice=message(error) } }
    }
    func refreshPreview() async {
        guard canRefreshPreview, let p=pending, let preview=receipt?.preview, let client else { return }; let g=generation; setBusy(true); defer { if generation==g { setBusy(false) } }; notice=nil
        do {
            let request=try MetadataRequest(operationID:p.operationID,target:p.target,draft:preview.after,expectedRevision:preview.expectedRevision)
            guard request.digest==p.digest else { throw ControlAPIError.invalidResponse }; needsStatus=true
            let r=try await client.preview(request); guard generation==g else { return }; try apply(r)
        } catch { if generation==g { notice=message(error) } }
    }
    func confirm() async { await consume(cancel:false) }
    func cancel() async { await consume(cancel:true) }
    private func consume(cancel:Bool) async {
        guard canConfirm, var p=pending, let token=receipt?.token, let client else { return }; let g=generation; setBusy(true); defer { if generation==g { setBusy(false) } }; notice=nil
        do {
            // Once a proof may have left the Mac, only the exact operation may reconcile it.
            p.state = .unknown; try save(p); needsStatus=true
            let r=try await client.proof(id:p.operationID,target:p.target,digest:p.digest,token:token,cancel:cancel)
            guard generation==g else { return }; try apply(r)
        } catch { if generation==g { notice=message(error) } }
    }
    func refreshOperation() async {
        guard ready,!busy,let p=pending,p.connectionID==connectionID,let client else { return }; let g=generation; setBusy(true); defer { if generation==g { setBusy(false) } }; notice=nil; statusNotFound=false; needsStatus=true
        do { let r=try await client.status(id:p.operationID,target:p.target,digest:p.digest); guard generation==g else { return }; try apply(r) }
        catch ControlAPIError.notFound { if generation==g { statusNotFound=true; notice="Операция не найдена. Подтверждённую команду повторять нельзя." } }
        catch { if generation==g { notice=message(error) } }
    }
    func abandonUnconfirmed() {
        guard canAbandon else { return }
        do { try store.clear(); pending=nil; receipt=nil; needsStatus=false; statusNotFound=false; updateLock(); notice="Неподтверждённый черновик снят локально." } catch { journalBlocked=true; updateLock(); notice=message(error) }
    }
    private func apply(_ r: MetadataOperation) throws {
        guard let p=pending,p.connectionID==connectionID else { throw ControlAPIError.configuration }; try r.check(id:p.operationID,target:p.target,digest:p.digest)
        var next=p; next.state=r.state; next.metadataRevision=r.result?.revision; try save(next); receipt=r; needsStatus=false; statusNotFound=false
        if let result=r.result { cache(result) }; updateLock()
    }
    private func cache(_ v:KeyMetadataSnapshot) { if let old=snapshots[v.keyID], old.revision > v.revision { return }; snapshots[v.keyID]=v }
    private func message(_ error:Error) -> String { (error as? MetadataDraftError)?.errorDescription ?? (error as? ControlAPIError)?.errorDescription ?? "Результат не подтверждён. Команда автоматически не повторяется." }
}
