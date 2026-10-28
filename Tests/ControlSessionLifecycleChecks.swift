import Foundation

private struct LifecycleFailure:Error {let message:String}

/// Requests are completed explicitly by the test, independently of Task cancellation.
/// This reproduces responses already delivered by a transport when the UI disconnects.
private actor LifecycleTransport:ControlHTTPTransport {
    struct Call {let method:String,path:String,query:[URLQueryItem],body:Data?}
    private var calls:[Call]=[]
    private var pending:[Int:CheckedContinuation<(Int,Data),Error>]=[:]
    func send(method:String,path:String,query:[URLQueryItem],body:Data?)async throws->(Int,Data) {
        let index=calls.count;calls.append(Call(method:method,path:path,query:query,body:body))
        return try await withCheckedThrowingContinuation{pending[index]=$0}
    }
    func call(_ index:Int)->Call?{calls.indices.contains(index) ? calls[index]:nil}
    func count()->Int{calls.count}
    func succeed(_ index:Int,_ data:Data,status:Int=200)throws {
        guard let reply=pending.removeValue(forKey:index) else{throw LifecycleFailure(message:"No pending response \(index)")}
        reply.resume(returning:(status,data))
    }
    func fail(_ index:Int)throws {
        guard let reply=pending.removeValue(forKey:index) else{throw LifecycleFailure(message:"No pending error \(index)")}
        reply.resume(throwing:ControlAPIError.unavailable)
    }
}
private final class LifecycleLegacyTransport:ControlHTTPTransport {
    func send(method:String,path:String,query:[URLQueryItem],body:Data?)async throws->(Int,Data) {
        if path=="/v1/capabilities" {return(200,Data(#"{"api_version":1,"features":["issue_owner_key","extend_owner_key_days","operation_status","owner_keys"]}"#.utf8))}
        return(200,Data(#"{"items":[],"has_more":false}"#.utf8))
    }
}

@main struct ControlSessionLifecycleChecks {
    static let profile=ControlConnectionProfile(endpoint:"https://fixture.example.invalid:29443",serverCA:Data([1]),identityLabel:"Lifecycle fixture only")
    static let keyID="326e4605-75d9-4c1b-86dc-d0e33ba1dd68"
    static let revision=String(repeating:"b",count:64)
    static let consoleCapabilities=Data(#"{"api_version":2,"contract":"anodhas.owner-control.r2","features":["clients_read","referrals_read","keys_read","durable_preview_confirm_status"],"actions":[{"action":"key_extend_days","enabled":true,"reason_code":null}]}"#.utf8)
    static let metadataCapabilities=Data(#"{"schema_revision":1,"enabled":true,"reason_code":null,"normalization":"NFC","length_unit":"unicode_scalar","name_min":1,"name_max":80,"note_max":1000,"preview_ttl_seconds":120,"request_max_bytes":8192}"#.utf8)
    static let overviewCapabilities=Data(#"{"schema_revision":1,"enabled":false,"scope":"non_owner_clients","counters":["registered_clients","active_clients","active_keys","slots_used"]}"#.utf8)

    @MainActor static func main()async throws {
        var checks=0
        func check(_ condition:Bool,_ message:String)throws {
            guard condition else{throw LifecycleFailure(message:message)}
            checks += 1;print("PASS lifecycle: \(message)")
        }
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("observatory-session-lifecycle-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let legacy=ControlAPIModel(store:ControlLocalStore(directory:root.appendingPathComponent("legacy")),makeClient:{_ in ControlAPIClient(transport:LifecycleLegacyTransport())})
        await legacy.connect(profile)
        try check(legacy.connected,"fixture legacy connection is ready without network or Keychain")

        // A disconnected capability request cannot revive readiness or end a newer attach.
        for failed in [false,true] {
            let suffix=failed ? "error":"success"
            let model=ControlConsoleModel(legacy:legacy,store:ConsoleLocalStore(directory:root.appendingPathComponent("caps-"+suffix)))
            let old=LifecycleTransport(),new=LifecycleTransport()
            let oldTask=Task{await model.attach(profile:profile,client:ControlConsoleClient(transport:old))}
            _=try await wait(old,0,path:"/v2/capabilities")
            model.disconnect()
            try check(!model.busy && !model.ready,"console disconnect releases only the invalidated session: \(suffix)")
            let newTask=Task{await model.attach(profile:profile,client:ControlConsoleClient(transport:new))}
            _=try await wait(new,0,path:"/v2/capabilities")
            if failed{try await old.fail(0)}else{try await old.succeed(0,consoleCapabilities)}
            await oldTask.value
            try check(model.busy && !model.ready && model.capabilities==nil && model.notice==nil,"late console capability \(suffix) cannot change new attach or its busy flag")
            try await new.succeed(0,consoleCapabilities);await newTask.value
            try check(model.ready && !model.busy,"new console attach owns its completion: \(suffix)")
            model.disconnect()
        }

        // The same lifecycle rule covers pages and details received after disconnect.
        for detail in [false,true] {
            let suffix=detail ? "detail":"page"
            let model=ControlConsoleModel(legacy:legacy,store:ConsoleLocalStore(directory:root.appendingPathComponent("read-"+suffix)))
            let old=LifecycleTransport(),new=LifecycleTransport()
            try await attachConsole(model,old)
            let readTask=Task{
                if detail{await model.loadDetail(path:"/v2/clients/7",kind:.client)}
                else{await model.loadPage(path:"/v2/clients",kind:.client,query:[],feature:"clients_read")}
            }
            _=try await wait(old,1,path:detail ? "/v2/clients/7":"/v2/clients")
            model.disconnect()
            let newTask=Task{await model.attach(profile:profile,client:ControlConsoleClient(transport:new))}
            _=try await wait(new,0,path:"/v2/capabilities")
            try await old.succeed(1,detail ? clientData():pageData(7));await readTask.value
            try check(model.busy && !model.ready && model.page==nil && model.detail==nil && model.notice==nil,"late console \(suffix) does not populate or unblock new session")
            try await new.succeed(0,consoleCapabilities);await newTask.value
            try check(model.ready && !model.busy,"console \(suffix) read cannot strand the new session")
            model.disconnect()
        }

        // Changing sections invalidates a read, permits its replacement, and isolates both results and errors.
        for failed in [false,true] {
            let suffix=failed ? "error":"success"
            let model=ControlConsoleModel(legacy:legacy,store:ConsoleLocalStore(directory:root.appendingPathComponent("selection-"+suffix)))
            let fixture=LifecycleTransport();try await attachConsole(model,fixture)
            let oldTask=Task{await model.loadPage(path:"/v2/clients",kind:.client,query:[],feature:"clients_read")}
            _=try await wait(fixture,1,path:"/v2/clients")
            model.clearSelection()
            try check(!model.busy && model.page==nil,"selection change frees only the old read slot: \(suffix)")
            let newTask=Task{await model.loadPage(path:"/v2/referrals",kind:.referral,query:[],feature:"referrals_read")}
            _=try await wait(fixture,2,path:"/v2/referrals")
            if failed{try await fixture.fail(1)}else{try await fixture.succeed(1,pageData(7))}
            await oldTask.value
            try check(model.busy && model.page==nil && model.notice==nil,"old selection \(suffix) neither replaces the new selection nor clears busy")
            try await fixture.succeed(2,pageData(9));await newTask.value
            try check(model.page?.total==9 && !model.busy,"replacement read completes with its own selection data: \(suffix)")
            model.disconnect()
        }
        // Detail results use the same selection guard, not merely connection identity.
        do {
            let model=ControlConsoleModel(legacy:legacy,store:ConsoleLocalStore(directory:root.appendingPathComponent("detail-selection")))
            let fixture=LifecycleTransport();try await attachConsole(model,fixture)
            let oldTask=Task{await model.loadDetail(path:"/v2/clients/7",kind:.client)}
            _=try await wait(fixture,1,path:"/v2/clients/7");model.clearSelection()
            let newTask=Task{await model.loadPage(path:"/v2/referrals",kind:.referral,query:[],feature:"referrals_read")}
            _=try await wait(fixture,2,path:"/v2/referrals")
            try await fixture.succeed(1,clientData());await oldTask.value
            try check(model.detail==nil && model.busy,"late detail cannot reopen a record in a different section")
            try await fixture.succeed(2,pageData(3));await newTask.value;model.disconnect()
        }

        // Clearing a selection must never release an unresolved mutation, including across reconnect.
        do {
            let store=ConsoleLocalStore(directory:root.appendingPathComponent("mutation")),fixture=LifecycleTransport()
            let model=ControlConsoleModel(legacy:legacy,store:store);try await attachConsole(model,fixture)
            let fields=keyFields(),record=try ConsoleRecord(kind:.key,fields:fields),target=ConsoleTarget(kind:.key,id:keyID,clientID:nil)
            let preparing=Task{await model.prepare(action:.days,target:target,input:"1",record:record)}
            let previewCall=try await wait(fixture,1,path:"/v2/operations/previews")
            let request=try JSONDecoder().decode(ConsoleRequest.self,from:previewCall.body!)
            try check(try store.load()?.request.operationID==request.operationID && model.pending?.needsStatus==true,"mutation operation id is durable before delayed POST response")
            model.clearSelection()
            try check(model.busy && !model.canStart && !legacy.canStart,"selection change keeps the active mutation and shared lock")
            await model.loadPage(path:"/v2/clients",kind:.client,query:[],feature:"clients_read")
            await model.prepare(action:.days,target:target,input:"1",record:record)
            try check(await fixture.count()==2,"selection change does not permit a competing GET or duplicate POST during mutation")
            model.disconnect()
            try check(!model.busy && !legacy.canStart && model.pending?.needsStatus==true,"disconnect clears request busy but preserves unresolved mutation lock")
            let new=LifecycleTransport(),newTask=Task{await model.attach(profile:profile,client:ControlConsoleClient(transport:new))}
            _=try await wait(new,0,path:"/v2/capabilities")
            try await fixture.succeed(1,receiptData(request,token:String(repeating:"a",count:64)));await preparing.value
            try check(model.busy && model.pending?.receipt==nil && model.pending?.needsStatus==true,"late preview cannot restore confirmation authority or clear newer busy")
            try await new.succeed(0,consoleCapabilities)
            let statusCall=try await wait(new,1,path:"/v2/operations/"+request.operationID)
            try check(statusCall.method=="GET","reconnect reconciles the exact mutation through GET only")
            try await new.succeed(1,receiptData(request,token:nil));await newTask.value
            try check(model.ready && !model.busy && !model.canConfirm && !legacy.canStart,"reconciled prepared operation retains shared lock without a confirmation proof")
            model.disconnect()
            // Keep this intentionally unresolved journal local to its fixture, not in subsequent scenarios.
            legacy.setOperationBlocked(false,source:.console)
        }

        // Metadata already rejects stale values; its old defer must also preserve a new request's busy state.
        for failed in [false,true] {
            let suffix=failed ? "error":"success"
            let model=ControlMetadataModel(legacy:legacy,store:MetadataLocalStore(directory:root.appendingPathComponent("metadata-"+suffix)))
            let old=LifecycleTransport(),new=LifecycleTransport()
            let oldTask=Task{await model.attach(profile:profile,client:ControlMetadataClient(transport:old))}
            _=try await wait(old,0,path:"/v2/key-metadata/capabilities")
            model.disconnect()
            try check(!model.busy && !model.ready,"metadata disconnect permits immediate reconnect: \(suffix)")
            let newTask=Task{await model.attach(profile:profile,client:ControlMetadataClient(transport:new))}
            _=try await wait(new,0,path:"/v2/key-metadata/capabilities")
            if failed{try await old.fail(0)}else{try await old.succeed(0,metadataCapabilities)}
            await oldTask.value
            try check(model.busy && !model.ready && model.notice==nil && !legacy.canStart,"old metadata \(suffix)/defer cannot release new session busy or shared lock")
            try await new.succeed(0,metadataCapabilities)
            _=try await wait(new,1,path:"/v2/overview/capabilities")
            try check(model.busy && model.ready,"new metadata attach remains busy until its own overview gate completes")
            try await new.succeed(1,overviewCapabilities);await newTask.value
            try check(model.ready && model.enabled && !model.busy && model.overview==nil,"new metadata session completes without invented overview counters")
            model.disconnect()
        }
        print("Control session lifecycle checks: \(checks); failures: 0")
    }

    /// Waiting observes an actual request; fixed delays do not decide response ordering.
    /// A bounded wait makes a missing replacement request fail rather than hang indefinitely.
    private static func wait(_ transport:LifecycleTransport,_ index:Int,path:String)async throws->LifecycleTransport.Call {
        for _ in 0..<2000 {
            if let call=await transport.call(index) {
                guard call.path==path else{throw LifecycleFailure(message:"Expected \(path), got \(call.path)")}
                return call
            }
            try await Task.sleep(nanoseconds:1_000_000)
        }
        throw LifecycleFailure(message:"Timed out awaiting fixture request \(index): \(path)")
    }
    @MainActor private static func attachConsole(_ model:ControlConsoleModel,_ transport:LifecycleTransport)async throws {
        let task=Task{await model.attach(profile:profile,client:ControlConsoleClient(transport:transport))}
        _=try await wait(transport,0,path:"/v2/capabilities")
        try await transport.succeed(0,consoleCapabilities);await task.value
        guard model.ready && !model.busy else{throw LifecycleFailure(message:"Fixture console did not attach")}
    }
    static func pageData(_ total:Int)throws->Data {
        try JSONSerialization.data(withJSONObject:["items":[],"total":total,"page":0,"page_size":20,"has_more":false])
    }
    static func clientData()throws->Data {
        try JSONSerialization.data(withJSONObject:["telegram_user_id":7,"display_name":"Fictional client","username":NSNull(),"slots_used":0,"slots_limit":1,"active_keys":0,"suspended_keys":0,"status":"active","expired_keys":0,"pending_keys":0,"identity_conflict":false,"revision":revision,"allowed_actions":[]])
    }
    static func keyFields()->[String:ConsoleValue] {
        ["key_id":.string(keyID),"name":.string("Fictional key"),"protocol":.string("fixture"),"state":.string("active"),"expires_at":.null,"period_ends_at":.null,"used_bytes":.integer(0),"limit_bytes":.integer(1000000000),"last_activity_at":.null,"time_unlimited":.boolean(false),"traffic_unlimited":.boolean(false),"traffic_available":.boolean(true),"traffic_updated_at":.null,"traffic_oldest_at":.null,"traffic_loss_unknown":.boolean(false),"traffic_partial_stale":.boolean(false),"traffic_scope":.null,"remaining_bytes":.integer(1000000000),"access_kind":.string("owner"),"telegram_user_id":.integer(7),"username":.null,"display_name":.null,"revision":.string(revision),"allowed_actions":.array([.object(["action":.string("key_extend_days"),"enabled":.boolean(true),"reason_code":.null])])]
    }
    static func receiptData(_ request:ConsoleRequest,token:String?)throws->Data {
        let future=ISO8601DateFormatter().string(from:Date().addingTimeInterval(120))
        let receipt=ConsoleReceipt(operationID:request.operationID,action:request.action,state:.prepared,summary:"Fictional one-day extension",target:request.target,expiresAt:future,preview:["kind":.string("key"),"before":.object(keyFields()),"after":.object(["summary":.string("Fictional one-day extension"),"parameters":.object(request.parameters),"amount_xtr":.null,"currency":.null,"delivery_to":.string("none"),"adds_quota":.boolean(false),"changes_term":.boolean(true)]),"expected_version":.string(revision)],effects:nil,errorCode:nil,confirmationToken:token)
        return try JSONEncoder().encode(receipt)
    }
}
