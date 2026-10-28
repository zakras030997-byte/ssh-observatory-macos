import Foundation
import Combine
import CryptoKit

struct ConsolePending:Codable,Equatable {
    let request:ConsoleRequest,connectionID:String
    var receipt:ConsoleReceipt?,needsStatus:Bool
    var mayHaveExecuted=false
    var locallyAbandoned=false
    func withoutToken()->Self {var copy=self;copy.receipt=copy.receipt?.withoutToken();return copy}
}

/// Separate r2 checkpoint; never overwrites the accepted v1 operation file.
final class ConsoleLocalStore {
    static let maximumBytes=1_048_576
    private let directory:URL
    init(directory:URL?=nil){self.directory=directory ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("SSH Observatory/control-api",isDirectory:true)}
    func load()throws->ConsolePending? {
        let p=directory.appendingPathComponent("pending-r2.json")
        guard FileManager.default.fileExists(atPath:p.path) else{return nil}
        let h=try FileHandle(forReadingFrom:p);defer{try? h.close()}
        let data=try h.read(upToCount:Self.maximumBytes+1) ?? Data();guard data.count<=Self.maximumBytes else{throw ControlAPIError.configuration}
        let value=try JSONDecoder().decode(ConsolePending.self,from:data);try value.request.validate()
        guard value.connectionID.range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil else{throw ControlAPIError.configuration}
        if let r=value.receipt{_=try r.validated(for:value.request)}
        guard !value.locallyAbandoned || (!value.mayHaveExecuted && (value.receipt==nil || value.receipt?.state == .prepared)) else{throw ControlAPIError.configuration}
        return value.withoutToken()
    }
    func save(_ value:ConsolePending)throws {
        try value.request.validate()
        let data=try JSONEncoder().encode(value.withoutToken());guard data.count<=Self.maximumBytes else{throw ControlAPIError.configuration}
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:directory.path)
        let file=directory.appendingPathComponent("pending-r2.json");try data.write(to:file,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
    static func connectionID(_ profile:ControlConnectionProfile)throws->String {
        _=try profile.validatedEndpoint();let e=JSONEncoder();e.outputFormatting=[.sortedKeys]
        return SHA256.hash(data:try e.encode(profile)).map{String(format:"%02x",$0)}.joined()
    }
}

@MainActor final class ControlConsoleModel:ObservableObject {
    @Published private(set) var ready=false
    @Published private(set) var busy=false
    @Published private(set) var journalBlocked=false
    @Published private(set) var capabilities:ConsoleCapabilities?
    @Published private(set) var pending:ConsolePending?
    @Published private(set) var page:ConsolePage?
    @Published private(set) var detail:ConsoleRecord?
    @Published private(set) var notice:String?
    @Published private(set) var statusNotFound=false
    let legacy:ControlAPIModel
    private let store:ConsoleLocalStore
    private var client:ControlConsoleClient?,connectionID:String?
    private var generation=0,selectionGeneration=0
    private var busyTicket:UUID?,readTicket:UUID?
    private var legacySubscription:AnyCancellable?
    init(legacy:ControlAPIModel,store:ConsoleLocalStore=ConsoleLocalStore()) {
        self.legacy=legacy;self.store=store
        do{pending=try store.load();if pending != nil{pending?.needsStatus=true}}
        catch{journalBlocked=true;notice="Журнал расширенного управления недоступен. Изменения заблокированы до сверки сохранённой операции."}
        updateLegacyLock()
        legacySubscription=legacy.objectWillChange.sink{[weak self] in self?.objectWillChange.send()}
    }
    var legacyClear:Bool {legacy.connected && !legacy.busy && !legacy.journalBlocked && !legacy.isOperationBlocked(excluding:.console) && (legacy.pending==nil || legacy.pending?.receipt?.state.terminal==true)}
    var unresolved:Bool {pending != nil && pending?.locallyAbandoned != true && pending?.receipt?.state.terminal != true}
    var canStart:Bool {ready && !busy && !journalBlocked && !unresolved && legacyClear}
    var canConfirm:Bool {canConfirm(at:Date())}
    func canConfirm(at now:Date)->Bool {
        guard ready,!busy,!journalBlocked,legacyClear,let pending,!pending.needsStatus,!pending.locallyAbandoned,
              let r=pending.receipt,r.state == .prepared,r.confirmationToken != nil,
              let raw=r.expiresAt,let date=ControlOperationReceipt.parseDate(raw),date>now else{return false}
        return pending.connectionID==connectionID
    }
    func confirmationSecondsRemaining(at now:Date)->Int? {
        guard let p=pending,!p.needsStatus,!p.locallyAbandoned,let r=p.receipt,r.state == .prepared,
              let raw=r.expiresAt,let date=ControlOperationReceipt.parseDate(raw) else{return nil}
        return max(0,Int(ceil(date.timeIntervalSince(now))))
    }
    var canRenewPreview:Bool {canRenewPreview(at:Date())}
    func canRenewPreview(at now:Date)->Bool {
        guard ready,!busy,!journalBlocked,legacyClear,let p=pending,!p.needsStatus,
              !p.locallyAbandoned,!p.mayHaveExecuted,p.connectionID==connectionID,let r=p.receipt,
              capabilities?.actions.first(where:{$0.action==p.request.action})?.enabled==true else{return false}
        return r.state == .expired || (r.state == .prepared && confirmationSecondsRemaining(at:now)==0)
    }
    private func updateLegacyLock(){legacy.setOtherOperationBlocked(busy || journalBlocked || unresolved)}
    private func setBusy(_ value:Bool){busy=value;updateLegacyLock()}
    private func beginWork(read:Bool=false)->UUID {
        let ticket=UUID();busyTicket=ticket;readTicket=read ? ticket:nil;setBusy(true);return ticket
    }
    private func finishWork(_ ticket:UUID) {
        guard busyTicket==ticket else{return}
        busyTicket=nil;readTicket=nil;setBusy(false)
    }
    func availability(_ action:ConsoleAction,record:ConsoleRecord?=nil)->ConsoleAvailability? {
        guard ready,let global=capabilities?.actions.first(where:{$0.action==action}) else{return nil}
        if !global.enabled{return global}
        if let record {
            guard record.revision != nil,let local=record.actions.first(where:{$0.action==action}) else{return nil}
            return local
        }
        return action == .reconcile ? global:nil
    }
    func connect()async {
        guard let profile=legacy.profile,let transport=legacy.connectedManagementTransport() else{disconnect();return}
        await attach(profile:profile,client:ControlConsoleClient(transport:transport))
    }
    // Injectable only through a local fixture transport; no new identity or endpoint.
    func attach(profile:ControlConnectionProfile,client:ControlConsoleClient)async {
        guard !busy else{return};generation += 1;selectionGeneration += 1
        let g=generation,ticket=beginWork();defer{finishWork(ticket)}
        ready=false;capabilities=nil;self.client=nil;connectionID=nil;page=nil;detail=nil;notice=nil;statusNotFound=false
        do {
            let binding=try ConsoleLocalStore.connectionID(profile)
            if let p=pending,p.connectionID != binding,p.receipt?.state.terminal != true {
                notice="Сохранённая операция относится к другому подключению. Верните прежний адрес и сертификат для проверки её результата.";return
            }
            let caps=try await client.capabilities();guard generation==g else{return}
            capabilities=caps;self.client=client;connectionID=binding;ready=true
            if let p=pending,p.connectionID==binding,!p.locallyAbandoned {
                do {
                    let receipt=try await client.status(p.request);guard generation==g else{return}
                    try apply(receipt,request:p.request)
                }
                catch ControlAPIError.notFound {
                    guard generation==g else{return}
                    statusNotFound=true;pending?.needsStatus=true;notice="Сервер не нашёл сохранённую операцию. Подтверждённую или отправленную команду повторять нельзя."
                }
                catch {
                    guard generation==g else{return}
                    notice="Расширенный API подключён, но сохранённая операция ещё не сверена. Новые изменения заблокированы.";pending?.needsStatus=true
                }
            }
            if journalBlocked{notice="Просмотр работает. Изменения заблокированы до проверки повреждённого журнала."}
        } catch ControlAPIError.notFound {
            guard generation==g else{return}
            notice="На сервере пока установлен первый API-пакет. Остальные разделы ещё не включены."
        } catch {
            guard generation==g else{return};notice=message(error)
        }
    }
    func disconnect() {
        generation += 1;selectionGeneration += 1;busyTicket=nil;readTicket=nil
        client=nil;connectionID=nil;ready=false;capabilities=nil;page=nil;detail=nil;statusNotFound=false
        if pending != nil{pending?.needsStatus=true;if let p=pending{try? store.save(p)}}
        setBusy(false)
    }
    func clearSelection() {
        selectionGeneration += 1;page=nil;detail=nil;notice=nil
        // Replacing a read may free its slot, but must not release a preview/confirmation lock.
        if let ticket=readTicket{finishWork(ticket)}
    }
    func supports(_ feature:String)->Bool{ready && (capabilities?.features.contains(feature) ?? false)}
    func loadPage(path:String,kind:ConsoleKind,query:[URLQueryItem],feature:String)async {
        guard !busy,supports(feature),let client else{return}
        let g=generation,s=selectionGeneration,ticket=beginWork(read:true);defer{finishWork(ticket)}
        page=nil;detail=nil;notice=nil
        do {
            let value=try await client.page(path:path,kind:kind,query:query)
            guard generation==g,selectionGeneration==s else{return};page=value
        } catch {
            guard generation==g,selectionGeneration==s else{return};notice=message(error)
        }
    }
    func loadDetail(path:String,kind:ConsoleKind,query:[URLQueryItem]=[])async {
        guard ready,!busy,let client else{return}
        let g=generation,s=selectionGeneration,ticket=beginWork(read:true);defer{finishWork(ticket)}
        detail=nil;notice=nil
        do {
            let value=try await client.detail(path:path,kind:kind,query:query)
            guard generation==g,selectionGeneration==s else{return};detail=value
        } catch {
            guard generation==g,selectionGeneration==s else{return};notice=message(error)
        }
    }
    func prepare(action:ConsoleAction,target:ConsoleTarget,input:String,record:ConsoleRecord?)async {
        guard canStart,availability(action,record:record)?.enabled==true,let client,let binding=connectionID else{return}
        let g=generation,ticket=beginWork();defer{finishWork(ticket)};notice=nil;statusNotFound=false
        do {
            if let record {
                guard record.id==target.id else{throw ControlAPIError.invalidRequest}
                if let recipient=target.clientID{guard record.clientID==recipient else{throw ControlAPIError.invalidRequest}}
            }
            let request=ConsoleRequest(operationID:ControlPreviewRequest.newID(),action:action,target:target,parameters:try action.parameters(input))
            try request.validate()
            // Durable ID before the first POST; a lost preview is reconciled, never re-created silently.
            let value=ConsolePending(request:request,connectionID:binding,receipt:nil,needsStatus:true)
            try store.save(value);pending=value;updateLegacyLock()
            let receipt=try await client.preview(request);guard generation==g else{return}
            try apply(receipt,request:request)
        } catch {
            guard generation==g else{return};notice=message(error)
        }
    }
    /// A new preview is allowed only after the server proves the old, never-confirmed one expired.
    /// It preserves the recipient and parameters, gets a new durable ID, and never confirms itself.
    func renewPreview()async {
        guard canRenewPreview else{return}
        await refreshOperation()
        guard canStart,let p=pending,p.receipt?.state == .expired,!p.needsStatus,
              !p.mayHaveExecuted,!p.locallyAbandoned,p.connectionID==connectionID,
              capabilities?.actions.first(where:{$0.action==p.request.action})?.enabled==true,
              let client,let binding=connectionID else{return}
        let request=ConsoleRequest(operationID:ControlPreviewRequest.newID(),action:p.request.action,
                                   target:p.request.target,parameters:p.request.parameters)
        let g=generation,ticket=beginWork();defer{finishWork(ticket)};notice=nil;statusNotFound=false
        do {
            try request.validate()
            let value=ConsolePending(request:request,connectionID:binding,receipt:nil,needsStatus:true)
            try store.save(value);pending=value;updateLegacyLock()
            let receipt=try await client.preview(request);guard generation==g else{return}
            try apply(receipt,request:request)
        } catch {
            guard generation==g else{return};notice=message(error)
        }
    }
    func confirm()async{await consume(cancel:false)}
    func cancel()async{await consume(cancel:true)}
    private func consume(cancel:Bool)async {
        guard canConfirm,let client,let p=pending,let token=p.receipt?.confirmationToken else{notice="Подтверждение сейчас недоступно. Обновите результат операции перед действием.";return}
        let g=generation,ticket=beginWork();defer{finishWork(ticket)};notice=nil
        do {
            var uncertain=p;uncertain.needsStatus=true;if !cancel{uncertain.mayHaveExecuted=true};try store.save(uncertain);pending=uncertain
            let r=try await (cancel ? client.cancel(p.request,token:token):client.confirm(p.request,token:token))
            guard generation==g else{return};try apply(r,request:p.request)
        } catch {
            guard generation==g else{return};notice=message(error)
        }
    }
    func refreshOperation()async {
        guard ready,!busy,let client,let p=pending,!p.locallyAbandoned,p.connectionID==connectionID else{return}
        let g=generation,ticket=beginWork();defer{finishWork(ticket)};notice=nil;statusNotFound=false
        do {
            let receipt=try await client.status(p.request);guard generation==g else{return}
            try apply(receipt,request:p.request)
        } catch ControlAPIError.notFound {
            guard generation==g else{return}
            statusNotFound=true;pending?.needsStatus=true;if let p=pending{try? store.save(p)};notice="Сервер не нашёл операцию. Отправленное подтверждение нельзя повторять; неподтверждённый черновик можно снять локально."
        } catch {
            guard generation==g else{return}
            pending?.needsStatus=true;if let p=pending{try? store.save(p)};notice=message(error)
        }
    }
    var canAbandonUnconfirmed:Bool{ready && !busy && !journalBlocked && statusNotFound && pending?.connectionID==connectionID && pending?.mayHaveExecuted==false && pending?.locallyAbandoned==false && (pending?.receipt==nil || pending?.receipt?.state == .prepared)}
    func abandonUnconfirmed(){
        guard canAbandonUnconfirmed,var p=pending else{return}
        do{p.locallyAbandoned=true;p.receipt=p.receipt?.withoutToken();try store.save(p);pending=p;statusNotFound=false;notice="Неподтверждённый черновик снят локально. Серверные изменения не запускались.";updateLegacyLock()}
        catch{notice=message(error)}
    }
    private func apply(_ receipt:ConsoleReceipt,request:ConsoleRequest)throws {
        guard let binding=connectionID else{throw ControlAPIError.configuration}
        let r=try receipt.validated(for:request)
        var value=ConsolePending(request:request,connectionID:binding,receipt:r,needsStatus:false)
        value.mayHaveExecuted=(pending?.request.operationID==request.operationID && pending?.mayHaveExecuted==true) || [.queued,.running,.succeeded,.unknown].contains(r.state)
        try store.save(value);pending=value;statusNotFound=false;updateLegacyLock()
    }
    private func message(_ error:Error)->String{(error as? ControlAPIError)?.errorDescription ?? "Запрос или сохранение результата не завершены. Команда автоматически не повторяется."}
}
