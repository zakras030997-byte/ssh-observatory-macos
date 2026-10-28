import Foundation
import Combine
import Security
import CryptoKit

struct PendingControlOperation: Codable, Equatable {
    var request:ControlPreviewRequest
    var receipt:ControlOperationReceipt?
    var needsStatus:Bool
    var connectionID:String?=nil
    func withoutToken() -> Self {
        var copy=self;copy.receipt?.confirmationToken=nil;return copy
    }
}

/// Public connection metadata and one unresolved operation only; private keys stay in Keychain.
final class ControlLocalStore {
    private let directory:URL
    init(directory:URL?=nil) {
        self.directory=directory ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("SSH Observatory/control-api",isDirectory:true)
    }
    private func read<T:Decodable>(_ type:T.Type,name:String) throws -> T? {
        let url=directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath:url.path) else { return nil }
        let handle=try FileHandle(forReadingFrom:url);defer{try? handle.close()}
        let data=try handle.read(upToCount:65_537) ?? Data()
        guard data.count<=65_536 else { throw ControlAPIError.configuration }
        return try JSONDecoder().decode(type,from:data)
    }
    private func write<T:Encodable>(_ object:T,name:String) throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:directory.path)
        let url=directory.appendingPathComponent(name),data=try JSONEncoder().encode(object)
        guard data.count<=65_536 else { throw ControlAPIError.configuration }
        try data.write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    func profile() throws -> ControlConnectionProfile? { try read(ControlConnectionProfile.self,name:"connection.json") }
    func saveProfile(_ value:ControlConnectionProfile) throws { _=try value.validatedEndpoint();try write(value,name:"connection.json") }
    func pending() throws -> PendingControlOperation? {
        guard let object=try read(PendingControlOperation.self,name:"pending.json") else{return nil}
        try object.request.validate()
        if let binding=object.connectionID { guard binding.range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil else { throw ControlAPIError.configuration } }
        if let receipt=object.receipt { _=try receipt.validated(for:object.request) }
        return object.withoutToken()
    }
    func savePending(_ value:PendingControlOperation?) throws {
        if let value { try write(value.withoutToken(),name:"pending.json") }
        else {
            let url=directory.appendingPathComponent("pending.json")
            if FileManager.default.fileExists(atPath:url.path) { try FileManager.default.removeItem(at:url) }
        }
    }
}

enum ControlMutationSource: Hashable { case console, metadata }

@MainActor final class ControlAPIModel: ObservableObject {
    @Published private(set) var profile:ControlConnectionProfile?
    @Published private(set) var connected=false
    @Published private(set) var busy=false
    @Published private(set) var keys:[ControlOwnerKey]=[]
    @Published private(set) var pending:PendingControlOperation?
    @Published var notice:String?
    @Published private(set) var journalBlocked=false
    @Published private(set) var otherOperationBlocked=false
    private let store:ControlLocalStore
    private var client:ControlAPIClient?
    private var transport:MutualTLSControlTransport?
    private var generation=0
    private var attemptedSavedConnection=false
    private var connectionID:String?
    private let makeClient:((ControlConnectionProfile)throws->ControlAPIClient)?
    var connectionSessionID:Int? { connected ? generation:nil }
    var canStart:Bool { connected && !busy && !journalBlocked && !otherOperationBlocked && (pending == nil || pending?.receipt?.state.terminal == true) }
    var canConfirm:Bool {
        guard connected,!busy,!journalBlocked,!otherOperationBlocked,let p=pending,p.connectionID==connectionID,!p.needsStatus,let r=p.receipt,r.state == .prepared,
              r.confirmationToken != nil,let value=r.expiresAt,let expiry=ControlOperationReceipt.parseDate(value) else { return false }
        return expiry>Date()
    }
    private var mutationBlocks = Set<ControlMutationSource>()
    func setOperationBlocked(_ value: Bool, source: ControlMutationSource) {
        if value { mutationBlocks.insert(source) } else { mutationBlocks.remove(source) }
        let blocked = !mutationBlocks.isEmpty
        if otherOperationBlocked != blocked { otherOperationBlocked = blocked }
    }
    func isOperationBlocked(excluding source: ControlMutationSource) -> Bool { !mutationBlocks.subtracting([source]).isEmpty }
    func setOtherOperationBlocked(_ value:Bool) { setOperationBlocked(value, source: .console) }
    func connectedManagementTransport() -> ControlHTTPTransport? { connected ? transport:nil }
    init(store:ControlLocalStore=ControlLocalStore(),makeClient:((ControlConnectionProfile)throws->ControlAPIClient)?=nil) {
        self.store=store;self.makeClient=makeClient
        do { profile=try store.profile();pending=try store.pending();if pending != nil { pending?.needsStatus=true } }
        catch { journalBlocked=true;notice="Не удалось прочитать журнал API. Изменения заблокированы до сверки сохранённой операции; автоматических действий не выполнялось." }
    }
    private static func binding(_ profile:ControlConnectionProfile) throws -> String {
        _=try profile.validatedEndpoint();let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        return SHA256.hash(data:try encoder.encode(profile)).map{String(format:"%02x",$0)}.joined()
    }
    /// Opening the management tab may reconnect once; it never previews or confirms an operation.
    func connectSavedProfileIfNeeded() async {
        guard !attemptedSavedConnection,!connected,!busy,let profile else{return}
        attemptedSavedConnection=true
        await connect(profile)
    }
    func connectSavedProfile() async {
        guard let profile else{return};await connect(profile)
    }
    func connect(_ value:ControlConnectionProfile) async {
        guard !busy else{return}
        attemptedSavedConnection=true;generation += 1;let g=generation
        busy=true;defer{if generation==g{busy=false}};notice=nil
        transport?.close();transport=nil;client=nil;connectionID=nil;connected=false;keys=[]
        do {
            let binding=try Self.binding(value)
            // Legacy checkpoints may bind only to their already saved original profile.
            if var old=pending,old.connectionID==nil,let original=profile {
                old.connectionID=try Self.binding(original);old.needsStatus=true;old=old.withoutToken()
                try store.savePending(old);pending=old
            }
            let candidate:ControlAPIClient
            if let makeClient { candidate=try makeClient(value) }
            else { let t=try MutualTLSControlTransport(profile:value);transport=t;candidate=ControlAPIClient(transport:t) }
            _=try await candidate.capabilities();guard generation==g else{return}
            let loaded=try await candidate.ownerKeys();guard generation==g else{return}
            try store.saveProfile(value);profile=value;client=candidate;connectionID=binding;keys=loaded;connected=true
            if let operation=pending {
                if operation.connectionID==binding {
                    do {
                        let receipt=try await candidate.status(operation.request);guard generation==g else{return}
                        try apply(receipt,request:operation.request)
                    } catch {
                        guard generation==g else{return}
                        notice="API подключён; сохранённую операцию пока не удалось сверить. Новое изменение недоступно."
                    }
                } else {
                    notice="Сохранённая операция относится к другому или неустановленному подключению. Для сверки верните исходный адрес и сертификат. Автоматических изменений не было."
                }
            }
            if journalBlocked { notice="Журнал операций повреждён или недоступен. Просмотр API работает; изменения заблокированы до сверки журнала." }
        } catch {
            guard generation==g else{return}
            transport?.close();transport=nil;client=nil;connectionID=nil;connected=false;keys=[]
            notice=safeMessage(error)
        }
    }
    func disconnect() {
        generation += 1;attemptedSavedConnection=true
        transport?.close();transport=nil;client=nil;connectionID=nil;connected=false;keys=[];busy=false
        if var record=pending { record.needsStatus=true;record=record.withoutToken();pending=record;try? store.savePending(record) }
    }
    func refreshKeys(archived:Bool=false) async {
        guard connected,!busy,let client else{return};let g=generation;busy=true;defer{if generation==g{busy=false}}
        do {let loaded=try await client.ownerKeys(archived:archived);guard generation==g else{return};keys=loaded;notice=nil}
        catch {guard generation==g else{return};notice=safeMessage(error)}
    }
    func prepare(_ request:ControlPreviewRequest) async {
        guard canStart,let client,let binding=connectionID else{return};let g=generation;busy=true;defer{if generation==g{busy=false}};notice=nil
        do {
            try request.validate()
            let record=PendingControlOperation(request:request,receipt:nil,needsStatus:true,connectionID:binding)
            // Durably retain the ID and connection before the first request; never replay a lost response.
            try store.savePending(record);pending=record
            let receipt=try await client.preview(request);guard generation==g else{return}
            try apply(receipt,request:request)
        } catch {guard generation==g else{return};notice=safeMessage(error)}
    }
    func confirm() async {
        guard canConfirm,let client,let record=pending,let token=record.receipt?.confirmationToken else{return}
        let g=generation;busy=true;defer{if generation==g{busy=false}};notice=nil
        do {
            var uncertain=record;uncertain.needsStatus=true
            try store.savePending(uncertain);pending=uncertain
            let receipt=try await client.confirm(record.request,token:token);guard generation==g else{return}
            try apply(receipt,request:record.request)
        } catch {guard generation==g else{return};notice=safeMessage(error)}
    }
    func refreshOperation() async {
        guard !busy,connected,let client,let record=pending,record.connectionID==connectionID else{return}
        let g=generation;busy=true;defer{if generation==g{busy=false}};notice=nil
        do {let receipt=try await client.status(record.request);guard generation==g else{return};try apply(receipt,request:record.request)}
        catch {guard generation==g else{return};notice=safeMessage(error);pending?.needsStatus=true;try? store.savePending(pending)}
    }
    func cancelPrepared() async {
        guard canConfirm,let client,let record=pending,let token=record.receipt?.confirmationToken else{return}
        let g=generation;busy=true;defer{if generation==g{busy=false}};notice=nil
        do {
            var uncertain=record;uncertain.needsStatus=true;try store.savePending(uncertain);pending=uncertain
            let receipt=try await client.cancel(record.request,token:token);guard generation==g else{return}
            try apply(receipt,request:record.request)
        } catch {guard generation==g else{return};notice=safeMessage(error)}
    }
    private func apply(_ value:ControlOperationReceipt,request:ControlPreviewRequest) throws {
        guard let binding=connectionID,pending?.connectionID==binding,pending?.request==request else{throw ControlAPIError.configuration}
        let receipt=try value.validated(for:request)
        // GET must not restore authority to confirm: its receipt deliberately has no proof.
        let record=PendingControlOperation(request:request,receipt:receipt,needsStatus:false,connectionID:binding)
        try store.savePending(record);pending=record
    }
    private func safeMessage(_ error:Error) -> String {
        (error as? ControlAPIError)?.errorDescription ?? "Локальное сохранение или запрос API не завершён. Результат операции нужно уточнить."
    }
}
