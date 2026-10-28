import Foundation

private final class ConsoleFixture:ControlHTTPTransport {
    struct Call{let method:String,path:String,query:[URLQueryItem],body:Data?}
    var calls:[Call]=[]
    var handler:((Call)throws->(Int,Data))!
    func send(method:String,path:String,query:[URLQueryItem],body:Data?)async throws->(Int,Data){let c=Call(method:method,path:path,query:query,body:body);calls.append(c);return try handler(c)}
}

@main struct ControlConsoleChecks {
    @MainActor static func main()async throws {
        var checks=0,failures=0
        func check(_ b:Bool,_ s:String){checks+=1;if b{print("PASS console: \(s)")}else{failures+=1;print("FAIL console: \(s)")}}
        func rejects(_ s:String,_ f:()throws->Void){do{try f();check(false,s)}catch{check(true,s)}}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("observatory-console-fixture-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let profile=ControlConnectionProfile(endpoint:"https://fixture.example.invalid:29443",serverCA:Data([1]),identityLabel:"Fixture")
        let id=UUID().uuidString.lowercased(),oid=ControlPreviewRequest.newID(),target=ConsoleTarget(kind:.key,id:id,clientID:nil)
        let request=ConsoleRequest(operationID:oid,action:.days,target:target,parameters:["days":.integer(1)])
        try request.validate();check(ConsoleAction.allCases.count==20,"closed20actions and no speed/IP/server command")
        rejects("wrong action target rejected"){try ConsoleRequest(operationID:oid,action:.refund,target:target,parameters:["reason":.string("fixture reason")]).validate()}
        rejects("key action cannot add quota via days parameters"){try ConsoleRequest(operationID:oid,action:.days,target:target,parameters:["days":.integer(1),"traffic_gb":.integer(500)]).validate()}
        rejects("zero days rejected"){_=try ConsoleAction.days.parameters("0")}
        rejects("unbounded periods rejected"){_=try ConsoleAction.periods.parameters("121")}
        rejects("manual refund amount rejected"){try ConsoleRequest(operationID:oid,action:.refund,target:.init(kind:.order,id:id,clientID:7),parameters:["reason":.string("fixture reason"),"amount_xtr":.integer(10)]).validate()}
        rejects("order cannot omit client binding"){try ConsoleTarget(kind:.order,id:id,clientID:nil).validate()}
        rejects("client id mismatch rejected"){try ConsoleTarget(kind:.client,id:"7",clientID:8).validate()}
        rejects("all referral scope cannot hide client filter"){try ConsoleTarget(kind:.referralScope,id:"all",clientID:7).validate()}
        rejects("path injection rejected"){try ControlConsoleClient.validatePath("/v2/clients/../orders")}
        rejects("unknown detail suffix rejected"){_=try ControlConsoleClient.validateRead(path:"/v2/requests/"+id+"/other",kind:.request,query:[],page:false)}
        rejects("caller actor query rejected"){_=try ControlConsoleClient.validateRead(path:"/v2/clients",kind:.client,query:[URLQueryItem(name:"actor",value:"7")],page:true)}
        rejects("duplicate query rejected"){_=try ControlConsoleClient.validateRead(path:"/v2/clients",kind:.client,query:[URLQueryItem(name:"status",value:"all"),URLQueryItem(name:"status",value:"active")],page:true)}
        rejects("pagination bound checked before transport"){_=try ControlConsoleClient.validateRead(path:"/v2/clients",kind:.client,query:[URLQueryItem(name:"page",value:"501")],page:true)}
        rejects("search cannot enter detail route"){_=try ControlConsoleClient.validateRead(path:"/v2/keys/"+id,kind:.key,query:[URLQueryItem(name:"query",value:"fixture")],page:false)}
        check(ConsoleAction(rawValue:"arbitrary_command")==nil,"unknown server command has no client action")
        let expiryRequest=ConsoleRequest(operationID:oid,action:.expiry,target:target,parameters:["expires_at":.string("2027-01-24T06:41:56.955258+00:00")])
        try expiryRequest.validate()
        check(ConsoleRecordSchema.parametersMatch(["expires_at":.string("2027-01-24T06:41:56.955258Z")],request:expiryRequest),"equivalent UTC timestamp notation preserves exact expiry")
        check(!ConsoleRecordSchema.parametersMatch(["expires_at":.string("2027-01-24T06:41:57.955258Z")],request:expiryRequest),"server cannot change exact expiry while normalizing UTC")
        check(!ConsoleRecordSchema.parametersMatch(["expires_at":.string("2027-01-24T06:41:56.955258Z"),"days":.integer(1)],request:expiryRequest),"timestamp normalization cannot hide extra parameters")
        rejects("non-UTC expiry rejected"){_=try ConsoleAction.expiry.parameters("2027-01-24T06:41:56+03:00")}
        rejects("deep response bounded before recursive DTO decoding"){var v:Any="fixture";for _ in 0..<15{v=["value":v]};try ControlConsoleClient.validateJSONBounds(JSONSerialization.data(withJSONObject:v))}
        for a in ConsoleAction.allCases {
            let t:ConsoleTarget
            switch a.targetKind{case .client:t = .init(kind:.client,id:"7",clientID:nil);case .request,.order:t = .init(kind:a.targetKind,id:id,clientID:7);case .referralScope:t = .init(kind:.referralScope,id:"all",clientID:nil);default:t = .init(kind:a.targetKind,id:id,clientID:nil)}
            let input=a.parameterName=="reason" ? "Fixture reason":a == .expiry ? "2027-01-01T00:00:00Z":a.parameterName==nil ? "":"1"
            try ConsoleRequest(operationID:oid,action:a,target:t,parameters:a.parameters(input)).validate()
        }
        check(true,"all20action parameter schemas accepted with proper target")
        let legacyFixture=ConsoleFixture();legacyFixture.handler={c in
            if c.path=="/v1/capabilities"{return(200,Data(#"{"api_version":1,"features":["issue_owner_key","extend_owner_key_days","operation_status","owner_keys"]}"#.utf8))}
            return(200,Data(#"{"items":[],"has_more":false}"#.utf8))
        }
        let legacy=ControlAPIModel(store:ControlLocalStore(directory:root.appendingPathComponent("v1")),makeClient:{_ in ControlAPIClient(transport:legacyFixture)})
        await legacy.connect(profile)
        let fixture=ConsoleFixture(),client=ControlConsoleClient(transport:fixture)
        let cap=ConsoleCapabilities(apiVersion:2,contract:"anodhas.owner-control.r2",features:["keys_read","durable_preview_confirm_status"],actions:[ConsoleAvailability(action:.days,enabled:true,reasonCode:nil),ConsoleAvailability(action:.refund,enabled:false,reasonCode:"FIXTURE_GATE")])
        let revision=String(repeating:"b",count:64)
        let keyFields:[String:ConsoleValue]=["key_id":.string(id),"name":.string("Fixture key"),"protocol":.string("fixture"),"state":.string("active"),"expires_at":.null,"period_ends_at":.null,"used_bytes":.integer(0),"limit_bytes":.integer(1000000000),"last_activity_at":.null,"time_unlimited":.boolean(false),"traffic_unlimited":.boolean(false),"traffic_available":.boolean(true),"traffic_updated_at":.null,"traffic_oldest_at":.null,"traffic_loss_unknown":.boolean(false),"traffic_partial_stale":.boolean(false),"traffic_scope":.null,"remaining_bytes":.integer(1000000000),"access_kind":.string("owner"),"telegram_user_id":.integer(7),"username":.null,"display_name":.null,"revision":.string(revision),"allowed_actions":.array([.object(["action":.string("key_extend_days"),"enabled":.boolean(true),"reason_code":.null])])]
        let record=try ConsoleRecord(kind:.key,fields:keyFields)
        rejects("money/counter type confusion rejected"){var fields=keyFields;fields["limit_bytes"] = .string("1000");_=try ConsoleRecord(kind:.key,fields:fields)}
        rejects("missing required DTO field rejected"){var fields=keyFields;fields.removeValue(forKey:"traffic_scope");_=try ConsoleRecord(kind:.key,fields:fields)}
        rejects("unexpected secret field rejected in DTO"){_=try ConsoleRecord(kind:.key,fields:["key_id":.string(id),"subscription_url":.string("fixture")])}
        let future=ISO8601DateFormatter().string(from:Date().addingTimeInterval(120)),proof=String(repeating:"a",count:64)
        func receipt(_ req:ConsoleRequest,_ state:ControlOperationState,token:String?=nil)->ConsoleReceipt {
            ConsoleReceipt(operationID:req.operationID,action:req.action,state:state,summary:"Fixture only",target:req.target,expiresAt:future,preview:["kind":.string("key"),"before":.object(keyFields),"after":.object(["summary":.string("Fixture only"),"parameters":.object(req.parameters),"amount_xtr":.null,"currency":.null,"delivery_to":.string("none"),"adds_quota":.boolean(false),"changes_term":.boolean(true)]),"expected_version":.string(revision)],effects:["business_confirmed":.boolean(state == .succeeded),"delivery_state":.string("none"),"payment_state":.string("none"),"access_state":.string("none"),"order_id":.null,"key_id":.null,"amount_xtr":.null,"currency":.null,"processed":.null],errorCode:nil,confirmationToken:token)
        }
        var current:ConsoleRequest?
        fixture.handler={c in
            if c.path=="/v2/capabilities" {
                return(200,try JSONSerialization.data(withJSONObject:["api_version":cap.apiVersion,"contract":cap.contract,"features":cap.features,"actions":[["action":"key_extend_days","enabled":true,"reason_code":NSNull()],["action":"order_full_refund","enabled":false,"reason_code":"FIXTURE_GATE"]]]))
            }
            if c.path=="/v2/operations/previews"{let r=try JSONDecoder().decode(ConsoleRequest.self,from:c.body!);current=r;return(200,try JSONEncoder().encode(receipt(r,.prepared,token:proof)))}
            if c.path.hasSuffix("/confirm"){throw ControlAPIError.unavailable}
            guard let r=current else{throw ControlAPIError.notFound};return(200,try JSONEncoder().encode(receipt(r,.running,token:proof)))
        }
        let normalHandler=fixture.handler!
        fixture.handler={_ in(200,try JSONEncoder().encode(["items":ConsoleValue.array([.object(keyFields),.object(keyFields)]),"total":.integer(2),"page":.integer(0),"page_size":.integer(20),"has_more":.boolean(false)]))}
        do{_=try await client.page(path:"/v2/clients/7/keys",kind:.key);check(false,"duplicate page records rejected")}catch{check(true,"duplicate page records rejected")}
        fixture.handler={_ in(200,try JSONEncoder().encode(["items":ConsoleValue.array([.object(keyFields)]),"total":.integer(1),"page":.integer(0),"page_size":.integer(20),"has_more":.boolean(false)]))}
        do{_=try await client.page(path:"/v2/clients/8/keys",kind:.key);check(false,"page cannot mix another client")}catch{check(true,"page cannot mix another client")}
        fixture.handler=normalHandler
        let constructionCalls=fixture.calls.count
        let store=ConsoleLocalStore(directory:root.appendingPathComponent("r2")),model=ControlConsoleModel(legacy:legacy,store:store)
        check(fixture.calls.count==constructionCalls,"construction performs no API or Keychain call")
        await model.attach(profile:profile,client:client)
        check(model.ready && model.canStart,"compatible r2 attaches without changing v1")
        check(model.availability(.refund,record:nil)?.enabled==false,"server deployment gate remains disabled")
        check(model.availability(.days,record:nil)==nil,"capability alone cannot authorize key action")
        let beforeMismatch=fixture.calls.count
        await model.prepare(action:.days,target:.init(kind:.key,id:UUID().uuidString.lowercased(),clientID:nil),input:"1",record:record)
        check(fixture.calls.count==beforeMismatch && model.pending==nil,"selected record cannot prepare another target")
        await model.prepare(action:.days,target:target,input:"1",record:record)
        check(model.canConfirm && !legacy.canStart,"prepared r2 blocks another v1 mutation")
        let saved=try String(contentsOf:root.appendingPathComponent("r2/pending-r2.json"),encoding:.utf8)
        check(!saved.contains(proof) && !saved.contains("confirmation_token"),"confirmation token not persisted")
        let mode=try FileManager.default.attributesOfItem(atPath:root.appendingPathComponent("r2/pending-r2.json").path)[.posixPermissions] as? NSNumber
        check(mode?.intValue==0o600,"r2 checkpoint owner-only")
        await model.confirm();let postCount=fixture.calls.filter{$0.method=="POST"}.count
        await model.confirm();await model.prepare(action:.days,target:target,input:"1",record:record)
        check(model.pending?.needsStatus==true && fixture.calls.filter{$0.method=="POST"}.count==postCount,"lost confirmation never repeats side effect")
        let restored=ControlConsoleModel(legacy:legacy,store:store)
        await restored.attach(profile:profile,client:client)
        check(restored.pending?.request.operationID==current?.operationID && restored.pending?.receipt?.state == .running,"restart GET reconciles same operation id")
        check(restored.pending?.receipt?.confirmationToken==nil && !restored.canConfirm,"GET cannot restore confirmation authority")
        check(fixture.calls.filter{$0.method=="POST"}.count==postCount,"reconnect issues no mutation")
        var other=profile;other.endpoint="https://other.example.invalid:29443";let before=fixture.calls.count
        await restored.attach(profile:other,client:client)
        check(!restored.ready && fixture.calls.count==before,"unresolved checkpoint cannot move to another connection")
        fixture.handler={c in if c.path=="/v2/capabilities"{return try normalHandler(c)};return(200,try JSONEncoder().encode(receipt(current!,.succeeded)))}
        await restored.attach(profile:profile,client:client)
        check(restored.canStart && legacy.canStart,"positive terminal reconciliation releases shared mutation lock")
        check(fixture.calls.filter{$0.method=="POST"}.count==postCount,"terminal reconciliation adds no side effect")
        fixture.handler={_ in(200,try JSONEncoder().encode(receipt(current!,.succeeded)))}
        await restored.attach(profile:profile,client:client) // capabilities deliberately invalid
        check(!restored.ready,"invalid capability response fails closed")
        let wrong=ConsoleReceipt(operationID:request.operationID,action:.days,state:.succeeded,summary:"Fixture",target:ConsoleTarget(kind:.key,id:UUID().uuidString.lowercased(),clientID:nil),expiresAt:nil,preview:nil,effects:nil,errorCode:nil,confirmationToken:nil)
        rejects("receipt for different target rejected"){_=try wrong.validated(for:request)}
        let unproved=ConsoleReceipt(operationID:request.operationID,action:.days,state:.succeeded,summary:"Fixture",target:target,expiresAt:nil,preview:nil,effects:["business_confirmed":.boolean(false),"delivery_state":.string("none"),"payment_state":.string("none"),"access_state":.string("none"),"order_id":.null,"key_id":.null,"amount_xtr":.null,"currency":.null,"processed":.null],errorCode:nil,confirmationToken:nil)
        rejects("success requires positive business evidence"){_=try unproved.validated(for:request)}
        var leakedEffects=unproved.effects!;leakedEffects["subscription_url"] = .string("fixture")
        rejects("effect payload has positive field allowlist"){try ConsoleRecordSchema.validateEffects(leakedEffects)}
        rejects("day extension cannot silently add quota"){var after=receipt(request,.prepared,token:proof).preview!["after"]!.fields!;after["adds_quota"] = .boolean(true);try ConsoleRecordSchema.validatePreview(kind:.key,before:keyFields,after:after,request:request)}
        func cohortItem(_ attribution:String=UUID().uuidString.lowercased(),reward:String?=nil)->[String:ConsoleValue] {
            ["attribution_id":.string(attribution),"reward_id":.string(reward ?? UUID().uuidString.lowercased()),"expected_version":.string(revision),"inviter_telegram_user_id":.integer(7),"device_key_id":.string(id),"period_id":.string(UUID().uuidString.lowercased()),"traffic_policy_id":.string(UUID().uuidString.lowercased()),"entitlement_id":.string(UUID().uuidString.lowercased()),"generation_id":.string(UUID().uuidString.lowercased()),"starts_at":.string("2027-01-01T00:00:00Z"),"ends_at":.string("2027-01-08T00:00:00Z"),"effect":.string("apply"),"creates_reward":.boolean(false),"term_seconds":.integer(604800),"traffic_mode":.string("unlimited")]
        }
        func cohort(_ items:[[String:ConsoleValue]])->[String:ConsoleValue] {
            ["plan_id":.string(UUID().uuidString.lowercased()),"revision":.string(revision),"candidate_count":.integer(Int64(items.count)),"candidate_ids":.array(items.map{$0["reward_id"] == .null ? $0["attribution_id"]!:$0["reward_id"]!}),"items":.array(items.map(ConsoleValue.object)),"excluded_count":.integer(2),"allowed_actions":.array([])]
        }
        let rewardID=UUID().uuidString.lowercased(),oneItem=cohortItem(reward:rewardID),onePlan=cohort([oneItem])
        try ConsoleReferralPlan.validate(onePlan);check(true,"cohort binds reward IDs while preserving attribution identity")
        rejects("cohort cannot hide another selected candidate"){var p=onePlan;p["candidate_ids"] = .array([.string(UUID().uuidString.lowercased())]);try ConsoleReferralPlan.validate(p)}
        rejects("cohort cannot repeat a reward effect"){try ConsoleReferralPlan.validate(cohort([oneItem,cohortItem(reward:rewardID)]))}
        rejects("cohort maximum enforced"){try ConsoleReferralPlan.validate(cohort((0..<101).map{_ in cohortItem()}))}
        rejects("cohort cannot carry hidden server fields"){var p=onePlan;p["secret"] = .string("fixture");try ConsoleReferralPlan.validate(p)}
        rejects("cohort cannot disguise unlimited traffic"){var item=oneItem;item["traffic_mode"] = .string("none");try ConsoleReferralPlan.validate(cohort([item]))}
        rejects("cohort duration must match shown dates"){var item=oneItem;item["term_seconds"] = .integer(1);try ConsoleReferralPlan.validate(cohort([item]))}
        rejects("cohort cannot apply twice to same period"){var item=cohortItem();item["period_id"]=oneItem["period_id"];try ConsoleReferralPlan.validate(cohort([oneItem,item]))}
        rejects("cohort candidate order matches shown effects"){var p=cohort([oneItem,cohortItem()]);p["candidate_ids"] = .array(p["candidate_ids"]!.values!.reversed());try ConsoleReferralPlan.validate(p)}
        var approveOnly=cohortItem();for name in ["reward_id","device_key_id","period_id","traffic_policy_id","entitlement_id","generation_id","starts_at","ends_at"]{approveOnly[name] = .null}
        approveOnly["effect"] = .string("approve_only");approveOnly["term_seconds"] = .integer(0);approveOnly["traffic_mode"] = .string("none")
        try ConsoleReferralPlan.validate(cohort([approveOnly]));check(true,"approval without rights explicitly has zero term and no traffic")
        let approveRequest=ConsoleRequest(operationID:ControlPreviewRequest.newID(),action:.referralApprove,target:.init(kind:.referral,id:rewardID,clientID:7),parameters:["reason":.string("Fixture")])
        let approveBefore:[String:ConsoleValue]=["attribution_id":oneItem["attribution_id"]!,"inviter_telegram_user_id":.integer(7)]
        try ConsoleReferralPlan.validateBinding(onePlan,request:approveRequest,before:approveBefore,expected:revision);check(true,"single approval maps reward target to original attribution")
        rejects("single approval cannot include another referral"){let p=cohort([oneItem,cohortItem()]);try ConsoleReferralPlan.validateBinding(p,request:approveRequest,before:approveBefore,expected:revision)}
        rejects("single approval cannot change attribution"){var before=approveBefore;before["attribution_id"] = .string(UUID().uuidString.lowercased());try ConsoleReferralPlan.validateBinding(onePlan,request:approveRequest,before:before,expected:revision)}
        rejects("preview version must match selected object revision"){var p=receipt(request,.prepared,token:proof).preview!;p["expected_version"] = .string(String(repeating:"c",count:64));let r=ConsoleReceipt(operationID:request.operationID,action:request.action,state:.prepared,summary:"Fixture",target:request.target,expiresAt:future,preview:p,effects:receipt(request,.prepared).effects,errorCode:nil,confirmationToken:proof);_=try r.validated(for:request)}
        let scopeRequest=ConsoleRequest(operationID:ControlPreviewRequest.newID(),action:.reconcile,target:.init(kind:.referralScope,id:"client",clientID:8),parameters:[:])
        rejects("cohort client scope excludes another recipient"){try ConsoleReferralPlan.validateBinding(onePlan,request:scopeRequest,before:onePlan,expected:revision)}
        rejects("cohort revision cannot differ from expected version"){try ConsoleReferralPlan.validateBinding(onePlan,request:scopeRequest,before:onePlan,expected:String(repeating:"c",count:64))}
        rejects("legacy capability cannot enable exact-referral actions"){let c=ConsoleCapabilities(apiVersion:2,contract:"anodhas.owner-control.r2",features:[],actions:[.init(action:.reconcile,enabled:true,reasonCode:nil)]);try c.validate()}
        let largePlan=cohort((0..<100).map{_ in cohortItem()})
        let largeRequest=ConsoleRequest(operationID:ControlPreviewRequest.newID(),action:.reconcile,target:.init(kind:.referralScope,id:"all",clientID:nil),parameters:[:])
        var largePreview:[String:ConsoleValue]=["kind":.string("referral_scope"),"before":.object(largePlan),"cohort":.object(largePlan),"after":.object(["summary":.string("Fixture only"),"parameters":.object([:]),"amount_xtr":.null,"currency":.null,"delivery_to":.string("none"),"adds_quota":.boolean(false),"changes_term":.boolean(true)]),"expected_version":.string(revision)]
        func planReceipt(_ preview:[String:ConsoleValue])->ConsoleReceipt{.init(operationID:largeRequest.operationID,action:.reconcile,state:.prepared,summary:"Fixture only",target:largeRequest.target,expiresAt:future,preview:preview,effects:receipt(request,.prepared).effects,errorCode:nil,confirmationToken:proof)}
        let largeStore=ConsoleLocalStore(directory:root.appendingPathComponent("large-plan")),largePending=ConsolePending(request:largeRequest,connectionID:try ConsoleLocalStore.connectionID(profile),receipt:planReceipt(largePreview),needsStatus:false)
        try largeStore.save(largePending)
        let largeSaved=try Data(contentsOf:root.appendingPathComponent("large-plan/pending-r2.json"))
        let largeLoaded=try largeStore.load()
        check(largeSaved.count>65536 && largeSaved.count<=ConsoleLocalStore.maximumBytes && largeLoaded?.receipt != nil && largeLoaded?.receipt?.confirmationToken==nil,"full100item cohort survives bounded checkpoint without proof")
        largePreview.removeValue(forKey:"cohort")
        rejects("exact referral cannot confirm legacy aggregate preview"){_=try planReceipt(largePreview).validated(for:largeRequest)}
        try Data(repeating:0,count:ConsoleLocalStore.maximumBytes+1).write(to:root.appendingPathComponent("large-plan/pending-r2.json"))
        rejects("checkpoint size cap remains enforced"){_=try largeStore.load()}
        // A visible confirmation must expire without another network response. Renewal is read-first,
        // never a replay, and may not turn an uncertain mutation into a new operation.
        let expiryPast=Date().addingTimeInterval(-2),expiryText=ISO8601DateFormatter().string(from:expiryPast)
        func timedReceipt(_ req:ConsoleRequest,_ state:ControlOperationState,futureExpiry:Bool=false)->ConsoleReceipt {
            let r=receipt(req,state,token:state == .prepared ? proof:nil)
            return ConsoleReceipt(operationID:r.operationID,action:r.action,state:r.state,summary:r.summary,target:r.target,
                                  expiresAt:futureExpiry ? future:expiryText,preview:r.preview,effects:r.effects,errorCode:nil,confirmationToken:r.confirmationToken)
        }
        let expiryFixture=ConsoleFixture();var renewalRequest:ConsoleRequest?,previewCount=0,expiryMode="expired"
        expiryFixture.handler={c in
            if c.path=="/v2/capabilities"{return try normalHandler(c)}
            if c.path=="/v2/operations/previews" {
                let r=try JSONDecoder().decode(ConsoleRequest.self,from:c.body!);renewalRequest=r;previewCount+=1
                return(200,try JSONEncoder().encode(timedReceipt(r,.prepared,futureExpiry:previewCount>1)))
            }
            guard let r=renewalRequest else{throw ControlAPIError.notFound}
            if expiryMode=="timeout"{throw ControlAPIError.unavailable}
            let state:ControlOperationState=expiryMode=="succeeded" ? .succeeded:expiryMode=="unknown" ? .unknown:expiryMode=="still-prepared" ? .prepared:.expired
            return(200,try JSONEncoder().encode(timedReceipt(r,state)))
        }
        let expiryStore=ConsoleLocalStore(directory:root.appendingPathComponent("expiry"))
        let expiryModel=ControlConsoleModel(legacy:legacy,store:expiryStore)
        await expiryModel.attach(profile:profile,client:ControlConsoleClient(transport:expiryFixture))
        await expiryModel.prepare(action:.days,target:target,input:"1",record:record)
        let exactDeadline=ControlOperationReceipt.parseDate(expiryText)!
        check(expiryModel.canConfirm(at:exactDeadline.addingTimeInterval(-1)),"clock-aware confirmation valid before exact deadline")
        check(!expiryModel.canConfirm(at:exactDeadline) && !expiryModel.canConfirm(at:exactDeadline.addingTimeInterval(3600)),"deadline and wake after deadline disable confirmation without a receipt change")
        check(expiryModel.confirmationSecondsRemaining(at:exactDeadline.addingTimeInterval(-61))==61 && expiryModel.confirmationSecondsRemaining(at:exactDeadline)==0,"visible countdown reaches zero at server deadline")
        check(expiryModel.canRenewPreview && !expiryModel.canConfirm,"expired visible preview offers renewal instead of a dead confirm button")
        let expiredID=renewalRequest!.operationID,beforeRenew=expiryFixture.calls.count
        await expiryModel.renewPreview()
        let renewalCalls=Array(expiryFixture.calls.dropFirst(beforeRenew))
        check(renewalCalls.count==2 && renewalCalls[0].method=="GET" && renewalCalls[0].path.contains(expiredID) && renewalCalls[1].path=="/v2/operations/previews","renewal first proves same old operation expired, then obtains one new preview")
        check(expiryModel.pending?.request.operationID != expiredID && expiryModel.pending?.request.target==target && expiryModel.pending?.request.parameters==["days":.integer(1)],"renewal preserves exact target and parameters under a fresh durable ID")
        check(expiryModel.canConfirm && expiryModel.pending?.mayHaveExecuted==false && !expiryFixture.calls.contains(where:{$0.path.hasSuffix("/confirm")}),"renewal never auto-confirms or performs the business action")
        let renewalSaved=try String(contentsOf:root.appendingPathComponent("expiry/pending-r2.json"),encoding:.utf8)
        check(!renewalSaved.contains(proof) && !renewalSaved.contains("confirmation_token"),"renewal proof stays out of durable checkpoint")
        let callsWhileFresh=expiryFixture.calls.count;await expiryModel.renewPreview()
        check(expiryFixture.calls.count==callsWhileFresh,"fresh preview cannot be renewed repeatedly")
        expiryModel.disconnect()
        for mode in ["succeeded","unknown","timeout","still-prepared"] {
            expiryMode=mode;previewCount=0
            let m=ControlConsoleModel(legacy:legacy,store:ConsoleLocalStore(directory:root.appendingPathComponent("expiry-"+mode)))
            await m.attach(profile:profile,client:ControlConsoleClient(transport:expiryFixture))
            await m.prepare(action:.days,target:target,input:"1",record:record)
            let posts=expiryFixture.calls.filter{$0.method=="POST"}.count
            await m.renewPreview()
            check(expiryFixture.calls.filter{$0.method=="POST"}.count==posts,"renewal does not issue new preview when old result is "+mode)
            if mode=="succeeded"{check(m.pending?.receipt?.state == .succeeded,"renewal reports already completed operation instead of replay")}
            if mode=="unknown" || mode=="timeout"{check(!m.canStart && !m.canRenewPreview,"uncertain old result remains locked for "+mode)}
            m.disconnect()
        }
        expiryMode="expired";previewCount=0
        let sentStore=ConsoleLocalStore(directory:root.appendingPathComponent("expiry-sent"))
        let sentRequest=ConsoleRequest(operationID:ControlPreviewRequest.newID(),action:.days,target:target,parameters:["days":.integer(1)])
        renewalRequest=sentRequest
        try sentStore.save(ConsolePending(request:sentRequest,connectionID:try ConsoleLocalStore.connectionID(profile),receipt:timedReceipt(sentRequest,.prepared),needsStatus:true,mayHaveExecuted:true))
        let sentModel=ControlConsoleModel(legacy:legacy,store:sentStore)
        await sentModel.attach(profile:profile,client:ControlConsoleClient(transport:expiryFixture))
        let sentCalls=expiryFixture.calls.count;await sentModel.renewPreview()
        check(sentModel.pending?.mayHaveExecuted==true && !sentModel.canRenewPreview && expiryFixture.calls.count==sentCalls,"an attempted confirmation never gains a renewal shortcut after restart")
        sentModel.disconnect()
        let rejectedFixture=ConsoleFixture()
        rejectedFixture.handler={c in if c.path=="/v2/capabilities"{return try normalHandler(c)};if c.path.hasSuffix("/previews"){return(409,Data())};return(404,Data())}
        let rejectedStore=ConsoleLocalStore(directory:root.appendingPathComponent("rejected")),rejected=ControlConsoleModel(legacy:legacy,store:rejectedStore)
        await rejected.attach(profile:profile,client:ControlConsoleClient(transport:rejectedFixture))
        await rejected.prepare(action:.days,target:target,input:"1",record:record)
        check(rejected.pending != nil && !rejected.canStart && !rejected.canAbandonUnconfirmed,"rejected preview still requires explicit status reconciliation")
        await rejected.refreshOperation()
        check(rejected.canAbandonUnconfirmed,"not-found can release only a never-confirmed preview")
        rejected.abandonUnconfirmed()
        check(rejected.canStart && rejected.pending?.locallyAbandoned==true,"local abandon retains checkpoint without server mutation")
        let rejectedPosts=rejectedFixture.calls.filter{$0.method=="POST"}.count
        let rejectedRestart=ControlConsoleModel(legacy:legacy,store:rejectedStore)
        await rejectedRestart.attach(profile:profile,client:ControlConsoleClient(transport:rejectedFixture))
        check(rejectedRestart.canStart && rejectedFixture.calls.filter{$0.method=="POST"}.count==rejectedPosts,"abandoned unconfirmed preview never resurrects after restart")
        await rejectedRestart.prepare(action:.days,target:target,input:"1",record:record)
        check(!rejectedRestart.canAbandonUnconfirmed,"old not-found proof cannot release another operation")
        await rejectedRestart.refreshOperation();rejectedRestart.abandonUnconfirmed()
        let missingFixture=ConsoleFixture()
        missingFixture.handler={c in if c.path=="/v2/capabilities" || c.path.hasSuffix("/previews"){return try normalHandler(c)};if c.path.hasSuffix("/confirm"){throw ControlAPIError.unavailable};return(404,Data())}
        let missing=ControlConsoleModel(legacy:legacy,store:ConsoleLocalStore(directory:root.appendingPathComponent("missing")))
        await missing.attach(profile:profile,client:ControlConsoleClient(transport:missingFixture))
        await missing.prepare(action:.days,target:target,input:"1",record:record);await missing.confirm();await missing.refreshOperation()
        check(missing.pending?.mayHaveExecuted==true && !missing.canAbandonUnconfirmed && !missing.canStart,"not-found after confirmation cannot release uncertainty")
        let missingCount=missingFixture.calls.count;missing.abandonUnconfirmed();await missing.confirm()
        check(missingFixture.calls.count==missingCount && missing.pending?.locallyAbandoned==false,"lost confirmed operation cannot be discarded or replayed")
        try FileManager.default.createDirectory(at:root.appendingPathComponent("corrupt"),withIntermediateDirectories:true)
        try Data("broken".utf8).write(to:root.appendingPathComponent("corrupt/pending-r2.json"))
        let corrupt=ControlConsoleModel(legacy:legacy,store:ConsoleLocalStore(directory:root.appendingPathComponent("corrupt")))
        check(corrupt.journalBlocked && !corrupt.canStart && !legacy.canStart,"corrupt r2 journal blocks all new management mutations")
        print("Console checks: \(checks); failures: \(failures)");if failures>0{exit(1)}
    }
}
