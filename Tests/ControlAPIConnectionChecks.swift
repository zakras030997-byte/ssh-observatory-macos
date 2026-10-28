import Foundation

private actor DelayedAPITransport: ControlHTTPTransport {
    struct Call { let method:String,path:String }
    private var calls:[Call]=[]
    private var gatePath:String?
    private var suspended:CheckedContinuation<Void,Never>?
    private var started:[CheckedContinuation<Void,Never>]=[]
    private var failGate=false
    private var populated=false
    init(gate:String?=nil){gatePath=gate}
    func arm(_ path:String,populated:Bool=false){gatePath=path;failGate=false;self.populated=populated}
    func waitUntilBlocked() async {
        if suspended != nil{return}
        await withCheckedContinuation{started.append($0)}
    }
    func release(fail:Bool=false){failGate=fail;suspended?.resume();suspended=nil}
    func count(_ method:String?=nil,_ path:String?=nil)->Int{calls.filter{(method==nil || $0.method==method) && (path==nil || $0.path==path)}.count}
    func send(method:String,path:String,query:[URLQueryItem],body:Data?) async throws -> (Int,Data) {
        calls.append(Call(method:method,path:path))
        if path==gatePath {
            gatePath=nil
            await withCheckedContinuation{continuation in
                suspended=continuation;let listeners=started;started=[];listeners.forEach{$0.resume()}
            }
            if failGate{throw ControlAPIError.unavailable}
        }
        if path=="/v1/capabilities"{return(200,Data(#"{"api_version":1,"features":["issue_owner_key","extend_owner_key_days","operation_status","owner_keys"]}"#.utf8))}
        if path=="/v1/owner/keys" {
            let data=populated ? #"{"items":[{"key_id":"11111111-1111-4111-8111-111111111111","name":"Fixture key","state":"active","expires_at":null,"time_unlimited":true,"traffic_unlimited":true,"used_bytes":0,"limit_bytes":null}],"has_more":false}"# : #"{"items":[],"has_more":false}"#
            return(200,Data(data.utf8))
        }
        if path=="/v1/operations/previews",let body {
            let request=try JSONDecoder().decode(ControlPreviewRequest.self,from:body)
            let receipt=ControlOperationReceipt(operationID:request.operationID,action:request.action,state:.prepared,summary:"Synthetic preview",expiresAt:ISO8601DateFormatter().string(from:Date().addingTimeInterval(300)),keyID:request.keyID,orderID:nil,errorCode:nil,confirmationToken:"fixture-only-not-a-secret")
            return(200,try JSONEncoder().encode(receipt))
        }
        throw ControlAPIError.notFound
    }
}

@main struct ControlAPIConnectionChecks {
    @MainActor static func main() async throws {
        var checks=0,failures=0
        func check(_ ok:Bool,_ label:String){checks+=1;if !ok{failures+=1};print("\(ok ? "PASS":"FAIL") connection: \(label)")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("observatory-connection-checks-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let profile=ControlConnectionProfile(endpoint:"https://fixture-a.example.invalid:8443",serverCA:Data([1]),identityLabel:"Synthetic identity")
        let other=ControlConnectionProfile(endpoint:"https://fixture-b.example.invalid:8443",serverCA:Data([2]),identityLabel:"Other synthetic identity")
        func store(_ name:String)->ControlLocalStore{ControlLocalStore(directory:root.appendingPathComponent(name))}
        func model(_ store:ControlLocalStore,_ transport:DelayedAPITransport)->ControlAPIModel{ControlAPIModel(store:store,makeClient:{_ in ControlAPIClient(transport:transport)})}
        let saved=store("saved"),normal=DelayedAPITransport();try saved.saveProfile(profile)
        let auto=model(saved,normal)
        check(await normal.count()==0,"construction does not contact API or Keychain")
        await auto.connectSavedProfileIfNeeded()
        check(auto.connected && !auto.busy,"saved profile connects on explicit first-open lifecycle")
        check(await normal.count()==2,"first-open performs only capabilities and key-list GET")
        await auto.connectSavedProfileIfNeeded()
        check(await normal.count()==2,"repeated appearance does not reconnect")
        auto.disconnect();await auto.connectSavedProfileIfNeeded()
        let disconnectedCount=await normal.count();check(!auto.connected && disconnectedCount==2,"explicit disconnect survives reappearance")
        await auto.connectSavedProfile()
        let reconnectedCount=await normal.count();check(auto.connected && reconnectedCount==4,"manual reconnect uses saved profile")
        check(await normal.count("POST")==0,"automatic and manual connection never POST")
        auto.disconnect()

        let old=DelayedAPITransport(gate:"/v1/capabilities"),fresh=DelayedAPITransport(gate:"/v1/capabilities")
        let switching=ControlAPIModel(store:store("switch"),makeClient:{p in ControlAPIClient(transport:p==profile ? old:fresh)})
        let first=Task{await switching.connect(profile)};await old.waitUntilBlocked();switching.disconnect()
        let second=Task{await switching.connect(other)};await fresh.waitUntilBlocked()
        await old.release(fail:true);await first.value
        check(switching.busy && !switching.connected,"late old error cannot unlock current connection")
        await fresh.release();await second.value
        check(switching.connected && switching.profile==other && !switching.busy,"new session survives old connection error")
        check(await old.count(nil,"/v1/owner/keys")==0,"abandoned handshake never proceeds to owner data")
        switching.disconnect()

        let late=DelayedAPITransport(gate:"/v1/owner/keys"),lateModel=model(store("late"),late)
        let loading=Task{await lateModel.connect(profile)};await late.waitUntilBlocked();lateModel.disconnect()
        await late.release();await loading.value
        check(!lateModel.connected && lateModel.keys.isEmpty && lateModel.profile==nil,"late initial keys cannot revive disconnected session or save profile")
        check(!lateModel.busy,"disconnect releases only its own pending work")

        let refreshing=DelayedAPITransport(),refresh=model(store("refresh"),refreshing);await refresh.connect(profile)
        await refreshing.arm("/v1/owner/keys",populated:true)
        let read=Task{await refresh.refreshKeys()};await refreshing.waitUntilBlocked();refresh.disconnect()
        await refreshing.release();await read.value
        check(!refresh.connected && refresh.keys.isEmpty,"late key refresh cannot repopulate disconnected view")

        let request=ControlPreviewRequest(operationID:ControlPreviewRequest.newID(),action:.issue,timeMode:"days",timeValue:1,trafficMode:"custom",trafficGB:1)
        let preview=DelayedAPITransport(),previewModel=model(store("preview"),preview);await previewModel.connect(profile)
        await preview.arm("/v1/operations/previews")
        let preparing=Task{await previewModel.prepare(request)};await preview.waitUntilBlocked();previewModel.disconnect()
        await preview.release();await preparing.value
        check(!previewModel.connected && !previewModel.canConfirm && previewModel.pending?.needsStatus==true,"late preview cannot restore confirmation authority")
        check(previewModel.pending?.receipt==nil && previewModel.pending?.connectionID != nil,"uncertain operation retains original binding without proof")
        check(await preview.count("POST")==1,"disconnect does not repeat preview or send confirmation")

        let a=DelayedAPITransport(),b=DelayedAPITransport(),boundStore=store("binding")
        let bound=ControlAPIModel(store:boundStore,makeClient:{p in ControlAPIClient(transport:p==profile ? a:b)})
        await bound.connect(profile);await bound.prepare(request);bound.disconnect();await bound.connect(other);await bound.refreshOperation()
        check(bound.connected && !bound.canStart && !bound.canConfirm,"different endpoint permits reading but blocks unresolved mutation")
        let bCount=await b.count(),bPosts=await b.count("POST");check(bCount==2 && bPosts==0,"old operation id is never sent to different API")
        check(bound.pending?.request==request && bound.pending?.needsStatus==true,"cross-profile connect preserves unresolved original checkpoint")
        bound.disconnect()

        let legacyStore=store("legacy");try legacyStore.saveProfile(profile)
        try legacyStore.savePending(PendingControlOperation(request:request,receipt:nil,needsStatus:true))
        let legacyTransport=DelayedAPITransport(),legacy=model(legacyStore,legacyTransport)
        await legacy.connect(other)
        check(legacy.pending?.connectionID != nil && !legacy.canStart,"legacy checkpoint binds to saved original profile before switching")
        check(await legacyTransport.count()==2,"legacy checkpoint is not queried on replacement endpoint")
        legacy.disconnect()
        let unboundStore=store("unbound");try unboundStore.savePending(PendingControlOperation(request:request,receipt:nil,needsStatus:true))
        let unboundTransport=DelayedAPITransport(),unbound=model(unboundStore,unboundTransport);await unbound.connect(profile)
        check(unbound.pending?.connectionID==nil && !unbound.canStart && !unbound.canConfirm,"legacy checkpoint without original profile fails closed")
        check(await unboundTransport.count()==2,"unknown checkpoint does not send status to guessed API")
        unbound.disconnect()
        print("Control API connection checks: \(checks) checks, \(failures) failures")
        if failures>0{exit(1)}
    }
}
