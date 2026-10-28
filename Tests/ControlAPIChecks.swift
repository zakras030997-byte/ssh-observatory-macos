import Foundation

private final class FixtureTransport: ControlHTTPTransport {
    struct Call { let method:String;let path:String;let body:Data? }
    var calls:[Call]=[]
    var handler:((Call)throws->(Int,Data))!
    func send(method:String,path:String,query:[URLQueryItem],body:Data?) async throws -> (Int,Data) {
        let call=Call(method:method,path:path,body:body);calls.append(call);return try handler(call)
    }
}

@main struct ControlAPIChecks {
    @MainActor static func main() async throws {
        var checks=0,failures=0
        func check(_ value:Bool,_ text:String) { checks+=1;if value {print("PASS control: \(text)")} else {failures+=1;print("FAIL control: \(text)")} }
        func rejects(_ text:String,_ body:()throws->Void) {do {try body();check(false,text)}catch{check(true,text)}}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("observatory-control-checks-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        defer{try? FileManager.default.removeItem(at:root)}
        let profile=ControlConnectionProfile(endpoint:"https://api.example.invalid:8443",serverCA:Data([1]),identityLabel:"Fixture only")
        _=try profile.validatedEndpoint();check(true,"HTTPS profile accepted without reading Keychain")
        for endpoint in ["http://api.example.invalid","https://user:pass@api.example.invalid","https://api.example.invalid/v1","https://api.example.invalid?q=1","https://api.example.invalid#x","https://api.example.invalid:0","https://api.example.invalid\n"] {
            rejects("invalid endpoint rejected") {var p=profile;p.endpoint=endpoint;_=try p.validatedEndpoint()}
        }
        rejects("oversized trust data rejected") {var p=profile;p.serverCA=Data(repeating:1,count:65_537);_=try p.validatedEndpoint()}
        rejects("control character in identity label rejected") {var p=profile;p.identityLabel="x\n";_=try p.validatedEndpoint()}
        let request=ControlPreviewRequest(operationID:ControlPreviewRequest.newID(),action:.issue,timeMode:"days",timeValue:30,trafficMode:"standard")
        try request.validate();let encoded=try JSONEncoder().encode(request)
        let object=try JSONSerialization.jsonObject(with:encoded) as! [String:Any]
        check(object["speed_limit_mbps"]==nil && object["actor"]==nil && object["operation_id"] as? String==request.operationID,"wire request contains neither speed nor actor")
        for bad in [ControlPreviewRequest(operationID:"../unsafe",action:.issue),ControlPreviewRequest(operationID:request.operationID,action:.issue,timeMode:"days",timeValue:0,trafficMode:"standard"),ControlPreviewRequest(operationID:request.operationID,action:.issue,timeMode:"unlimited",timeValue:30,trafficMode:"standard"),ControlPreviewRequest(operationID:request.operationID,action:.issue,timeMode:"days",timeValue:1,trafficMode:"custom",trafficGB:100_001),ControlPreviewRequest(operationID:request.operationID,action:.extend,keyID:UUID().uuidString,days:1,trafficMode:"standard")] {
            rejects("invalid operation shape rejected") {try bad.validate()}
        }
        let keyID=UUID().uuidString.lowercased()
        let extend=ControlPreviewRequest(operationID:ControlPreviewRequest.newID(),action:.extend,keyID:keyID,days:30)
        try extend.validate();check(true,"day extension accepts no quota fields")
        let future=ISO8601DateFormatter().string(from:Date().addingTimeInterval(300))
        func receipt(_ state:ControlOperationState,token:String?=nil,for req:ControlPreviewRequest?=nil)->ControlOperationReceipt {
            let r=req ?? request
            return ControlOperationReceipt(operationID:r.operationID,action:r.action,state:state,summary:"Fixture operation",expiresAt:future,keyID:r.keyID,orderID:nil,errorCode:nil,confirmationToken:token)
        }
        let prepared=receipt(.prepared,token:"fixture-proof")
        rejects("receipt from another operation rejected") {_=try prepared.validated(for:extend)}
        let wrongKey=ControlOperationReceipt(operationID:extend.operationID,action:.extend,state:.succeeded,summary:"Fixture",expiresAt:nil,keyID:UUID().uuidString,orderID:nil,errorCode:nil,confirmationToken:nil)
        rejects("extension receipt cannot refer to another key") {_=try wrongKey.validated(for:extend)}
        check(!ControlOperationState.queued.terminal && !ControlOperationState.unknown.terminal && ControlOperationState.succeeded.terminal,"queue and uncertain result are not completion")
        let caps=Data(#"{"api_version":1,"features":["issue_owner_key","extend_owner_key_days","operation_status","owner_keys"]}"#.utf8)
        let empty=Data(#"{"items":[],"has_more":false}"#.utf8)
        let transport=FixtureTransport()
        transport.handler={call in
            if call.path=="/v1/capabilities" {return(200,caps)}
            if call.path=="/v1/owner/keys" {return(200,empty)}
            if call.path=="/v1/operations/previews" {return(200,try JSONEncoder().encode(prepared))}
            if call.path.hasSuffix("/confirm") {throw ControlAPIError.unavailable}
            return(200,try JSONEncoder().encode(receipt(.queued)))
        }
        let store=ControlLocalStore(directory:root.appendingPathComponent("safe"))
        let model=ControlAPIModel(store:store,makeClient:{_ in ControlAPIClient(transport:transport)})
        check(transport.calls.isEmpty,"model construction makes no network or Keychain call")
        await model.connect(profile);check(model.connected && model.canStart,"configured fake API connects with capability check")
        await model.prepare(request)
        check(model.canConfirm && !model.canStart,"preview requires separate confirmation and blocks another mutation")
        let disk=try String(contentsOf:root.appendingPathComponent("safe/pending.json"),encoding:.utf8)
        check(!disk.contains("fixture-proof") && !disk.contains("confirmation_token"),"confirmation proof never persisted")
        let permissions=try FileManager.default.attributesOfItem(atPath:root.appendingPathComponent("safe/pending.json").path)[.posixPermissions] as? NSNumber
        check(permissions?.intValue==0o600,"pending record is owner-readable only")
        await model.confirm()
        check(model.pending?.needsStatus==true && !model.canConfirm && !model.canStart,"lost confirmation response blocks another side effect")
        let postsBefore=transport.calls.filter{$0.method=="POST"}.count
        await model.confirm();await model.prepare(extend)
        check(transport.calls.filter{$0.method=="POST"}.count==postsBefore,"uncertain confirmation is never blindly replayed")
        let restored=ControlAPIModel(store:store,makeClient:{_ in ControlAPIClient(transport:transport)})
        check(restored.pending?.request.operationID==request.operationID && restored.pending?.needsStatus==true,"restart restores same operation id")
        await restored.connect(profile)
        check(transport.calls.filter{$0.method=="POST"}.count==postsBefore && restored.pending?.receipt?.state == .queued,"reconnect uses GET only and preserves queued state")
        check(!restored.canStart,"queued operation prevents duplicate issuance")
        transport.handler={call in
            if call.path=="/v1/capabilities" {return(200,caps)}
            if call.path=="/v1/owner/keys" {return(200,empty)}
            return(200,try JSONEncoder().encode(receipt(.succeeded)))
        }
        await restored.refreshOperation();check(restored.canStart && restored.pending?.receipt?.state == .succeeded,"confirmed terminal result permits next operation")
        let corruptDir=root.appendingPathComponent("corrupt")
        try FileManager.default.createDirectory(at:corruptDir,withIntermediateDirectories:true)
        try Data("broken".utf8).write(to:corruptDir.appendingPathComponent("pending.json"))
        let corrupt=ControlAPIModel(store:ControlLocalStore(directory:corruptDir),makeClient:{_ in ControlAPIClient(transport:transport)})
        await corrupt.connect(profile)
        check(corrupt.connected && corrupt.journalBlocked && !corrupt.canStart,"corrupt journal fails closed even after API connection")
        let client=ControlAPIClient(transport:transport)
        transport.handler={_ in(200,try JSONEncoder().encode(prepared))}
        let evidenceOnly=try await client.status(request)
        check(evidenceOnly.confirmationToken==nil,"status response cannot restore permission to confirm")
        transport.handler={_ in(200,Data(#"{"api_version":2,"features":[]}"#.utf8))}
        do{_=try await client.capabilities();check(false,"incompatible API rejected")}catch{check(true,"incompatible API rejected")}
        transport.handler={_ in(200,Data(repeating:32,count:524_289))}
        do{_=try await client.capabilities();check(false,"oversized response rejected")}catch ControlAPIError.oversizedResponse{check(true,"oversized response rejected")}catch{check(false,"oversized response rejected")}
        transport.handler={_ in(409,Data("private server content".utf8))}
        do{_=try await client.status(request);check(false,"conflict is safe typed error")}catch ControlAPIError.conflict{check(true,"conflict is safe typed error")}catch{check(false,"conflict is safe typed error")}
        let key:[String:Any]=["key_id":keyID,"name":"Fixture","state":"active","expires_at":NSNull(),"time_unlimited":true,"traffic_unlimited":true,"used_bytes":0,"limit_bytes":NSNull()]
        transport.handler={_ in(200,try JSONSerialization.data(withJSONObject:["items":[key,key],"has_more":false]))}
        do{_=try await client.ownerKeys();check(false,"duplicate key page rejected")}catch{check(true,"duplicate key page rejected")}
        transport.handler={_ in(200,try JSONEncoder().encode(receipt(.prepared)))}
        do{_=try await client.preview(request);check(false,"preview without confirmation proof rejected")}catch{check(true,"preview without confirmation proof rejected")}
        let disconnectedPosts=transport.calls.count
        restored.disconnect();await restored.confirm();await restored.prepare(extend)
        check(!restored.connected && transport.calls.count==disconnectedPosts,"disconnected UI cannot submit mutations")
        print("Control API checks: \(checks); failures: \(failures)")
        if failures>0 {exit(1)}
    }
}
