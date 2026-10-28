import Foundation

private final class MetadataFixture:ControlHTTPTransport {
    struct Call { let method:String,path:String,query:[URLQueryItem],body:Data? }
    var calls:[Call]=[]
    var handler:((Call)async throws->(Int,Data))!
    func send(method:String,path:String,query:[URLQueryItem],body:Data?)async throws->(Int,Data) { let c=Call(method:method,path:path,query:query,body:body); calls.append(c); return try await handler(c) }
}
@main struct ControlMetadataChecks {
    @MainActor static func main() async throws {
        var checks=0
        func check(_ b:Bool,_ s:String)throws { guard b else { throw Failure(label:s) }; checks += 1; print("PASS metadata: \(s)") }
        func rejects(_ s:String,_ f:()throws->Void)throws { do { try f() } catch { try check(true,s); return }; throw Failure(label:s) }
        func read(_ path:String)throws->MetadataWire.Object { try MetadataWire.decode(Data(contentsOf:URL(fileURLWithPath:path))) }
        let base=CommandLine.arguments[1]
        let wire=try read(base+"/WIRE-METADATA-r1.json"), overview=try read(base+"/WIRE-OVERVIEW-r1.json"), unicode=try read(base+"/WIRE-UNICODE-r1.json")
        var records:[String:MetadataWire.Object]=[:]
        for value in wire["records"]!.values! {
            let r=value.fields!,v=r["value"]!.fields!,name=r["name"]!.text!,kind=r["kind"]!.text!; records[name]=v
            switch kind {
            case "MetadataCapabilities":_=try MetadataCapabilities(v)
            case "KeyMetadata":_=try KeyMetadataSnapshot(v)
            case "MetadataOperation":_=try MetadataOperation(v)
            default:let e=try MetadataWire.object(v["error"]);try MetadataWire.keys(e,["code","message","retryable"])
            }
            try check(true,"actual wire \(name)")
        }
        for value in overview["records"]!.values! { let r=value.fields!,v=r["value"]!.fields!; if r["kind"]!.text=="Overview" { _=try ControlOverview(v) } else { _=try ControlOverview.validateCapabilities(v) }; try check(true,"actual wire overview \(r["name"]!.text!)") }
        let full=try read(base+"/FULL-SERVICE-WIRE.json")
        let fullSnapshot=try KeyMetadataSnapshot(MetadataWire.object(full["key_metadata"]))
        let fullOperation=try MetadataOperation(MetadataWire.object(full["operation"]))
        try check(fullOperation.state == .succeeded && fullOperation.result != nil,"actual SQLite service HTTP operation decodes in Swift")
        try check(fullSnapshot.keyID==fullOperation.target.id && fullSnapshot.clientID==fullOperation.result?.clientID,"actual core snapshot preserves key and client binding")
        for value in unicode["cases"]!.values! {
            let c=value.fields!,valid=c["valid"]!.flag!,name=c["name"]!.text!
            if let raw=c["raw_name_json"]?.text { try rejects("Unicode \(name)"){_=try JSONDecoder().decode(String.self,from:Data(raw.utf8))}; continue }
            let draft=ControlMetadataDraft(name:c["input_name"]!.text!,note:c["input_note"]!.text!)
            if valid { let n=try draft.normalized(); try check(n.name.utf8.elementsEqual(c["normalized_name"]!.text!.utf8) && n.note.utf8.elementsEqual(c["normalized_note"]!.text!.utf8),"Unicode \(name)") }
            else { try rejects("Unicode \(name)"){_=try draft.normalized()} }
        }
        try rejects("raw scalar cap before normalization"){_=try ControlMetadataDraft(name:String(repeating:" ",count:512)+"a",note:"").normalized()}
        try check(try ControlMetadataDraft(name:"\u{200b}x\u{200b}",note:"").normalized().name=="\u{200b}x\u{200b}","non White_Space format scalar not silently trimmed")
        let original=try KeyMetadataSnapshot(records["original"]!),first=try MetadataOperation(records["preview.1"]!),target=first.target
        let request=try MetadataRequest(operationID:first.operationID,target:target,draft:.init(name:"  Cafe\u{301} 📱  ",note:"Первая\r\n\tвторая"),expectedRevision:original.viewRevision)
        try check(request.digest==first.digest,"Python and Swift canonical digest match real wire")
        let requestData=try request.data(); try check(try MetadataWire.decode(requestData)["parameters"]!.fields!["name"]!.text=="Café 📱","outgoing payload normalized")
        var v=records["original"]!; v["secret"] = .string("fixture"); try rejects("unknown key field"){_=try KeyMetadataSnapshot(v)}
        v=records["original"]!; v.removeValue(forKey:"note"); try rejects("missing field including null"){_=try KeyMetadataSnapshot(v)}
        v=records["original"]!; v["metadata_revision"] = .string("0"); try rejects("counter type confusion"){_=try KeyMetadataSnapshot(v)}
        v=records["preview.1"]!; v["request_digest"] = .string(String(repeating:"0",count:64)); try rejects("tampered digest"){_=try MetadataOperation(v)}
        v=records["preview.1"]!; var p=v["preview"]!.fields!; var a=p["after"]!.fields!; a["business_fields_unchanged"] = .boolean(false); p["after"] = .object(a); v["preview"] = .object(p); try rejects("policy changes rejected in metadata preview"){_=try MetadataOperation(v)}
        v=records["succeeded.1"]!; v["result"] = .object(records["current"]!); try rejects("latest metadata cannot replace historical result"){_=try MetadataOperation(v)}
        v=records["state.failed"]!;v["result"] = records["succeeded.1"]!["result"];try rejects("failed receipt cannot claim saved metadata"){_=try MetadataOperation(v)}
        try rejects("receipt cannot change client binding"){try first.check(id:first.operationID,target:MetadataTarget(id:target.id,clientID:910003),digest:first.digest)}
        let historic=try MetadataOperation(records["historical-first-after-second-edit"]!),current=try KeyMetadataSnapshot(records["current"]!)
        try check(historic.result?.revision==1 && current.revision==2,"exact historical snapshot stays separate")
        var ov=overview["records"]!.values![1].fields!["value"]!.fields!; ov["active_clients"] = .integer(99);try rejects("inconsistent global counters"){_=try ControlOverview(ov)}
        ov=overview["records"]!.values![1].fields!["value"]!.fields!;ov["online"] = .integer(1);try rejects("invented online count rejected"){_=try ControlOverview(ov)}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("observatory-metadata-tests-"+UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let profile=ControlConnectionProfile(endpoint:"https://fixture.example.invalid:29443",serverCA:Data([1]),identityLabel:"Fixture")
        let legacyTransport=MetadataFixture(); legacyTransport.handler={ c in
            if c.path=="/v1/capabilities" { return(200,Data(#"{"api_version":1,"features":["issue_owner_key","extend_owner_key_days","operation_status","owner_keys"]}"#.utf8)) }; return(200,Data(#"{"items":[],"has_more":false}"#.utf8))
        }
        let legacy=ControlAPIModel(store:ControlLocalStore(directory:root.appendingPathComponent("v1")),makeClient:{_ in ControlAPIClient(transport:legacyTransport)}); await legacy.connect(profile)
        let fixture=MetadataFixture(),client=ControlMetadataClient(transport:fixture),store=MetadataLocalStore(directory:root.appendingPathComponent("meta"))
        var live:MetadataWire.Object?,dropConfirm=false,notFound=false
        let caps=records["capabilities"]!,ovCaps=overview["records"]!.values![0].fields!["value"]!.fields!,ovSnapshot=overview["records"]!.values![1].fields!["value"]!.fields!
        fixture.handler={ c in
            var result:MetadataWire.Object
            if c.path.hasSuffix("/capabilities") { result=c.path.contains("overview") ? ovCaps:caps }
            else if c.path=="/v2/overview" { result=ovSnapshot }
            else if c.path.contains("/keys/") { result=records["original"]! }
            else if c.path.hasSuffix("/previews") {
                let b=try MetadataWire.decode(c.body!),params=b["parameters"]!.fields!
                let r=try MetadataRequest(operationID:b["operation_id"]!.text!,target:MetadataTarget(b["target"]!.fields!),draft:.init(name:params["name"]!.text!,note:params["note"]!.text!),expectedRevision:params["expected_view_revision"]!.text!)
                var value=records["preview.1"]!;value["operation_id"] = .string(r.operationID);value["request_digest"] = .string(r.digest);value["expires_at"] = .string(ISO8601DateFormatter().string(from:Date().addingTimeInterval(120)))
                var preview=value["preview"]!.fields!;preview["request_digest"] = .string(r.digest);preview["after"] = .object(["effective_name":.string(r.draft.name),"note":.string(r.draft.note),"business_fields_unchanged":.boolean(true)]);value["preview"] = .object(preview);live=value;result=value
            } else if c.path.hasSuffix("/confirm") {
                guard var value=live else { throw ControlAPIError.notFound };value["state"] = .string("queued");value["confirmation_token"] = .null; live=value
                if dropConfirm { throw ControlAPIError.unavailable }; result=value
            } else {
                if notFound { return(404,Data(#"{"error":{"code":"OPERATION_NOT_FOUND","message":"Not found","retryable":false}}"#.utf8)) }
                guard var value=live else { throw ControlAPIError.notFound };value["confirmation_token"] = .null;result=value
            }
            return(200,Data(try MetadataWire.canonical(.object(result)).utf8))
        }
        let consoleTransport=MetadataFixture(); consoleTransport.handler={_ in (200,Data(#"{"api_version":2,"contract":"anodhas.owner-control.r2","features":["keys_read"],"actions":[]}"#.utf8))}
        let console=ControlConsoleModel(legacy:legacy,store:ConsoleLocalStore(directory:root.appendingPathComponent("r2")));await console.attach(profile:profile,client:ControlConsoleClient(transport:consoleTransport))
        let model=ControlMetadataModel(legacy:legacy,store:store); await model.attach(profile:profile,client:client)
        try check(model.canStart && model.overview?.registeredClients==2,"capabilities and exact overview ready")
        legacy.setOtherOperationBlocked(true);try check(!model.canStart,"r2 operation excludes metadata mutation");legacy.setOtherOperationBlocked(false)
        let draft=ControlMetadataDraft(name:"PRIVATE_NAME_fixture",note:"PRIVATE_NOTE_fixture")
        await model.prepare(target:target,snapshot:original,draft:draft)
        try check(model.canConfirm && !legacy.canStart && !console.canStart,"preview holds v1 and r2 mutation locks")
        let saved=try Data(contentsOf:store.file),text=String(decoding:saved,as:UTF8.self),checkpoint=try store.load()!
        try check(!text.contains("PRIVATE_") && !text.contains("confirmation_token") && !text.contains("effective_name") && Set(try MetadataWire.decode(saved).keys).count==7,"checkpoint contains identifiers only")
        let attrs=try FileManager.default.attributesOfItem(atPath:store.file.path);try check((attrs[.posixPermissions] as? NSNumber)?.intValue==0o600,"private checkpoint permissions")
        model.disconnect(); let restored=ControlMetadataModel(legacy:legacy,store:store),before=fixture.calls.count
        await restored.attach(profile:profile,client:client)
        try check(!restored.canConfirm && restored.canRefreshPreview && restored.receipt?.token==nil,"restored prepared requires explicit fresh proof")
        try check(fixture.calls.dropFirst(before).allSatisfy{$0.method=="GET"},"restore makes no automatic POST")
        await restored.refreshPreview();try check(restored.canConfirm && restored.pending?.operationID==checkpoint.operationID && restored.pending?.digest==checkpoint.digest,"explicit preview refresh preserves identity and digest")
        dropConfirm=true;await restored.confirm()
        try check(restored.needsStatus && restored.pending?.state == .unknown && !restored.canConfirm && !legacy.canStart,"lost confirmation response stays locked")
        restored.disconnect();let afterConfirm=ControlMetadataModel(legacy:legacy,store:store),start=fixture.calls.count;await afterConfirm.attach(profile:profile,client:client)
        try check(afterConfirm.pending?.state == .queued && fixture.calls.dropFirst(start).allSatisfy{$0.method=="GET"},"restart queries queued receipt without replay")
        notFound=true;await afterConfirm.refreshOperation();try check(!afterConfirm.canAbandon && !afterConfirm.canStart,"unknown confirmed operation cannot be discarded on 404")
        let other=ControlConnectionProfile(endpoint:"https://other.example.invalid:29443",serverCA:Data([1]),identityLabel:"Other"),prior=fixture.calls.count;afterConfirm.disconnect();await afterConfirm.attach(profile:other,client:client)
        try check(!afterConfirm.ready && fixture.calls.count==prior,"connection mismatch blocks all requests")
        var bad=checkpoint.fields;bad["note"] = .string("forbidden");try rejects("checkpoint rejects additional text fields"){_=try MetadataCheckpoint(bad)}
        let proofFixture=MetadataFixture();proofFixture.handler={_ in (200,Data(try MetadataWire.canonical(.object(records["preview.1"]!)).utf8))}
        do{_=try await ControlMetadataClient(transport:proofFixture).status(id:first.operationID,target:target,digest:first.digest);throw Failure(label:"GET proof accepted")}catch ControlAPIError.invalidResponse{try check(true,"GET cannot restore confirmation proof")}
        let missingFixture=MetadataFixture();missingFixture.handler={c in
            if c.path.contains("key-metadata"){return(404,Data(#"{"error":{"code":"NOT_FOUND","message":"Not installed","retryable":false}}"#.utf8))}
            return(200,Data(try MetadataWire.canonical(.object(c.path.hasSuffix("capabilities") ? ovCaps:ovSnapshot)).utf8))
        }
        let missing=ControlMetadataModel(legacy:legacy,store:MetadataLocalStore(directory:root.appendingPathComponent("missing")));await missing.attach(profile:profile,client:ControlMetadataClient(transport:missingFixture))
        try check(!missing.ready && missing.overview != nil && !missing.canStart,"metadata capability 404 does not invent readiness or lose overview")
        let lateFixture=MetadataFixture();lateFixture.handler={_ in try await Task.sleep(nanoseconds:40_000_000);return(200,Data(try MetadataWire.canonical(.object(caps)).utf8))}
        let late=ControlMetadataModel(legacy:legacy,store:MetadataLocalStore(directory:root.appendingPathComponent("late")))
        let lateTask=Task{await late.attach(profile:profile,client:ControlMetadataClient(transport:lateFixture))};try await Task.sleep(nanoseconds:10_000_000);late.disconnect();await lateTask.value
        try check(!late.ready && late.overview==nil && lateFixture.calls.count==1,"late response cannot revive disconnected model")
        let failureStore=MetadataLocalStore(directory:root.appendingPathComponent("blocked-directory"));try Data("fixture".utf8).write(to:failureStore.directory)
        let blocked=ControlMetadataModel(legacy:legacy,store:failureStore);await blocked.attach(profile:profile,client:client)
        legacy.setOperationBlocked(false,source:.metadata)
        let previousPosts=fixture.calls.filter{$0.method=="POST"}.count
        await blocked.prepare(target:target,snapshot:original,draft:draft)
        try check(blocked.journalBlocked && fixture.calls.filter{$0.method=="POST"}.count==previousPosts,"failed durable save prevents first POST")
        let link=MetadataLocalStore(directory:root.appendingPathComponent("link"));try FileManager.default.createSymbolicLink(at:link.directory,withDestinationURL:store.directory);try rejects("checkpoint refuses symlink"){_=try link.load()}
        let corrupt=MetadataLocalStore(directory:root.appendingPathComponent("bad"));try FileManager.default.createDirectory(at:corrupt.directory,withIntermediateDirectories:true);try Data("{}".utf8).write(to:corrupt.file)
        let corruptModel=ControlMetadataModel(legacy:legacy,store:corrupt);try check(corruptModel.journalBlocked && !legacy.canStart,"corrupt journal fails closed across mutation namespaces")
        print("ControlMetadata: \(checks) checks PASS; synthetic data only; no live identities, network or effects")
    }
    struct Failure:Error { let label:String }
}
