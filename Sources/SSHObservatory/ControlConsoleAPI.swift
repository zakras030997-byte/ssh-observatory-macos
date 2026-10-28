import Foundation

/// The closed r2 vocabulary. New server capabilities never imply arbitrary commands.
enum ConsoleAction:String,Codable,CaseIterable,Identifiable {
    case requestInvoice="request_invoice",requestFree="request_free",requestDecline="request_decline",requestGift="request_gift"
    case clientTrial="client_trial_gift",refund="order_full_refund",resend="owner_subscription_resend"
    case suspend="key_suspend",resume="key_resume",revoke="key_revoke",days="key_extend_days",expiry="key_expiry_at"
    case periods="key_grant_periods",timeUnlimited="key_time_unlimited",traffic="key_grant_traffic"
    case unlimitedOn="key_traffic_unlimited_on",unlimitedOff="key_traffic_unlimited_off"
    case referralApprove="referral_approve",referralReject="referral_reject",reconcile="referrals_reconcile"
    var id:String {rawValue}
    var targetKind:ConsoleTarget.Kind {
        switch self {
        case .requestInvoice,.requestFree,.requestDecline,.requestGift:return .request
        case .clientTrial:return .client
        case .refund:return .order
        case .referralApprove,.referralReject:return .referral
        case .reconcile:return .referralScope
        default:return .key
        }
    }
    var title:String {
        switch self {
        case .requestInvoice:return "Одобрить и отправить счёт Stars"
        case .requestFree:return "Выдать бесплатно"
        case .requestDecline:return "Отклонить заявку"
        case .requestGift:return "Заменить неоплаченный счёт подарком"
        case .clientTrial:return "Пробный подарок клиенту"
        case .refund:return "Полный возврат Stars"
        case .resend:return "Отправить общую подписку в Telegram"
        case .suspend:return "Приостановить"
        case .resume:return "Возобновить"
        case .revoke:return "Отозвать доступ"
        case .days:return "Добавить дни без трафика"
        case .expiry:return "Установить дату окончания"
        case .periods:return "Добавить полные периоды"
        case .timeUnlimited:return "Бессрочный срок"
        case .traffic:return "Добавить трафик без изменения срока"
        case .unlimitedOn:return "Включить безлимит трафика"
        case .unlimitedOff:return "Отключить безлимит трафика"
        case .referralApprove:return "Одобрить приглашение"
        case .referralReject:return "Отклонить приглашение"
        case .reconcile:return "Обработать ожидающие бонусы"
        }
    }
    var parameterName:String? {
        switch self {
        case .requestFree,.requestDecline,.refund,.referralApprove,.referralReject:return "reason"
        case .days:return "days"
        case .expiry:return "expires_at"
        case .periods:return "periods"
        case .traffic:return "traffic_gb"
        default:return nil
        }
    }
    func parameters(_ input:String)throws->[String:ConsoleValue] {
        guard let field=parameterName else {
            guard input.isEmpty else{throw ControlAPIError.invalidRequest};return [:]
        }
        switch self {
        case .days,.periods,.traffic:
            let upper=self == .days ? 3650:self == .periods ? 120:100000
            guard input.range(of:"^[0-9]{1,6}$",options:.regularExpression) != nil,
                  let number=Int64(input),(1...Int64(upper)).contains(number) else{throw ControlAPIError.invalidRequest}
            return [field:.integer(number)]
        case .expiry:
            guard input.count<=40,(input.hasSuffix("Z") || input.hasSuffix("+00:00")),ControlOperationReceipt.parseDate(input) != nil else{throw ControlAPIError.invalidRequest}
            return [field:.string(input)]
        default:
            let low=self == .refund ? 3:1,high=self == .refund ? 500:160
            guard (low...high).contains(input.count),!input.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else{throw ControlAPIError.invalidRequest}
            return [field:.string(input)]
        }
    }
}

enum ConsoleValue:Codable,Equatable {
    case null,string(String),integer(Int64),number(Double),boolean(Bool),array([ConsoleValue]),object([String:ConsoleValue])
    init(from decoder:Decoder)throws {
        let c=try decoder.singleValueContainer()
        if c.decodeNil(){self = .null}
        else if let v=try? c.decode(Bool.self){self = .boolean(v)}
        else if let v=try? c.decode(Int64.self){self = .integer(v)}
        else if let v=try? c.decode(Double.self),v.isFinite{self = .number(v)}
        else if let v=try? c.decode(String.self){self = .string(v)}
        else if let v=try? c.decode([ConsoleValue].self){self = .array(v)}
        else if let v=try? c.decode([String:ConsoleValue].self){self = .object(v)}
        else{throw ControlAPIError.invalidResponse}
    }
    func encode(to encoder:Encoder)throws {
        var c=encoder.singleValueContainer()
        switch self {
        case .null:try c.encodeNil()
        case .string(let v):try c.encode(v)
        case .integer(let v):try c.encode(v)
        case .number(let v):guard v.isFinite else{throw ControlAPIError.invalidResponse};try c.encode(v)
        case .boolean(let v):try c.encode(v)
        case .array(let v):try c.encode(v)
        case .object(let v):try c.encode(v)
        }
    }
    var text:String? {if case .string(let v)=self{return v};return nil}
    var number:Int64? {if case .integer(let v)=self{return v};return nil}
    var flag:Bool? {if case .boolean(let v)=self{return v};return nil}
    var fields:[String:ConsoleValue]? {if case .object(let v)=self{return v};return nil}
    var values:[ConsoleValue]? {if case .array(let v)=self{return v};return nil}
    func validate(depth:Int=0)throws {
        guard depth<=4 else{throw ControlAPIError.invalidResponse}
        switch self {
        case .number(let v):guard v.isFinite else{throw ControlAPIError.invalidResponse}
        case .string(let v):guard v.count<=2048,!v.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t"}) else{throw ControlAPIError.invalidResponse}
        case .array(let v):guard v.count<=100 else{throw ControlAPIError.invalidResponse};for x in v{try x.validate(depth:depth+1)}
        case .object(let v):guard v.count<=80,v.keys.allSatisfy({$0.count<=80 && !$0.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains)}) else{throw ControlAPIError.invalidResponse};for x in v.values{try x.validate(depth:depth+1)}
        default:break
        }
    }
    var display:String {
        switch self {
        case .null:return "Нет данных"
        case .string(let s):return s
        case .integer(let n):return String(n)
        case .number(let n):return String(n)
        case .boolean(let b):return b ? "Да":"Нет"
        case .array(let a):return a.map(\.display).joined(separator:" · ")
        case .object(let d):return d.keys.sorted().map{"\($0): \(d[$0]!.display)"}.joined(separator:"\n")
        }
    }
}

struct ConsoleTarget:Codable,Equatable {
    enum Kind:String,Codable {case request,client,order,key,referral,referralScope="referral_scope"}
    let kind:Kind,id:String
    var clientID:Int64?
    enum CodingKeys:String,CodingKey{case kind,id,clientID="client_id"}
    static func uuid(_ s:String)->Bool {UUID(uuidString:s)?.uuidString.lowercased()==s}
    func validate()throws {
        guard clientID.map({$0>0}) ?? true else{throw ControlAPIError.invalidRequest}
        switch kind {
        case .client:
            guard let value=Int64(id),value>0,String(value)==id,clientID==nil else{throw ControlAPIError.invalidRequest}
        case .referralScope:
            guard (id=="all" && clientID==nil) || (id=="client" && clientID != nil) else{throw ControlAPIError.invalidRequest}
        case .request,.order:
            guard Self.uuid(id),clientID != nil else{throw ControlAPIError.invalidRequest}
        default:guard Self.uuid(id) else{throw ControlAPIError.invalidRequest}
        }
    }
}

struct ConsoleRequest:Codable,Equatable {
    let operationID:String,action:ConsoleAction,target:ConsoleTarget,parameters:[String:ConsoleValue]
    enum CodingKeys:String,CodingKey{case operationID="operation_id",action,target,parameters}
    func validate()throws {
        guard operationID.range(of:"^[0-9a-f]{32}$",options:.regularExpression) != nil,action.targetKind==target.kind else{throw ControlAPIError.invalidRequest}
        try target.validate()
        if action == .resend && target.clientID != nil{throw ControlAPIError.invalidRequest}
        let input:String
        if let name=action.parameterName {
            guard parameters.count==1,let v=parameters[name] else{throw ControlAPIError.invalidRequest}
            switch v {case .string(let s):input=s;case .integer(let n):input=String(n);default:throw ControlAPIError.invalidRequest}
        }else{guard parameters.isEmpty else{throw ControlAPIError.invalidRequest};input=""}
        guard try action.parameters(input)==parameters else{throw ControlAPIError.invalidRequest}
    }
}

struct ConsoleAvailability:Codable,Equatable {
    let action:ConsoleAction,enabled:Bool,reasonCode:String?
    enum CodingKeys:String,CodingKey{case action,enabled,reasonCode="reason_code"}
    func validate()throws{guard reasonCode.map({$0.count<=80 && $0.range(of:"^[A-Za-z0-9_.-]+$",options:.regularExpression) != nil}) ?? true else{throw ControlAPIError.invalidResponse}}
}
struct ConsoleCapabilities:Decodable {
    let apiVersion:Int,contract:String,features:[String],actions:[ConsoleAvailability]
    var contractRevision:Int?=nil
    enum CodingKeys:String,CodingKey{case apiVersion="api_version",contract,features,actions,contractRevision="contract_revision"}
    func validate()throws {
        guard apiVersion==2,contract=="anodhas.owner-control.r2",features.count<=30,
              features.allSatisfy({$0.count<=100}),actions.count<=ConsoleAction.allCases.count,
              Set(actions.map(\.action)).count==actions.count,
              contractRevision==nil || [2,3].contains(contractRevision!),
              !actions.contains(where:{$0.enabled && ConsoleReferralPlan.exactActions.contains($0.action)}) || contractRevision==3 else{throw ControlAPIError.invalidResponse}
        for a in actions{try a.validate()}
    }
}

enum ConsoleKind:String,CaseIterable {case request,client,key,order,history,referral,attention
    var allowed:Set<String> {
        let base:[String]
        switch self {
        case .request:base=["request_id","telegram_user_id","username","display_name","device_count","period_count","total_xtr","status","request_kind","stage","identity_conflict","replace_invoice_available","gift_order_id"]
        case .client:base=["telegram_user_id","display_name","username","slots_used","slots_limit","active_keys","suspended_keys","status","expired_keys","pending_keys","identity_conflict"]
        case .key:base=["key_id","name","protocol","state","expires_at","period_ends_at","used_bytes","limit_bytes","last_activity_at","time_unlimited","traffic_unlimited","traffic_available","traffic_updated_at","traffic_oldest_at","traffic_loss_unknown","traffic_partial_stale","traffic_scope","remaining_bytes","access_kind","telegram_user_id","username","display_name"]
        case .order:base=["order_id","telegram_user_id","amount_xtr","order_type","devices_count","periods_count","paid_at","payment_status","refundable","username","display_name"]
        case .history:base=["event_id","created_at","actor","action","target","result","reason","before","after","telegram_user_id","username","display_name"]
        case .referral:base=["reward_id","attribution_id","status","reason","reviewable","earned_at","starts_at","ends_at","device_slot_id","order_id","bound_at","inviter_telegram_user_id","inviter_username","inviter_display_name","invitee_telegram_user_id","invitee_username","invitee_display_name","gift_created","gift_fulfilled","delivery_confirmed"]
        case .attention:base=["problem_id","kind","status","object_id","stage","reason","first_event_at","last_event_at","attempts","telegram_user_id","username","display_name","chain","next_step","responsible"]
        }
        return Set(base+["revision","allowed_actions"])
    }
    var identityKeys:[String] {
        switch self {
        case .request:return ["request_id"]
        case .client:return ["telegram_user_id"]
        case .key:return ["key_id"]
        case .order:return ["order_id"]
        case .history:return ["event_id"]
        case .referral:return ["reward_id","attribution_id"]
        case .attention:return ["problem_id"]
        }
    }
}

struct ConsoleRecord:Identifiable,Equatable {
    let kind:ConsoleKind,fields:[String:ConsoleValue]
    let id:String
    init(kind:ConsoleKind,fields:[String:ConsoleValue])throws {
        guard Set(fields.keys).isSubset(of:kind.allowed) else{throw ControlAPIError.invalidResponse}
        try ConsoleRecordSchema.validate(kind:kind,fields:fields)
        for v in fields.values{try v.validate()}
        var identifier:String?
        for key in kind.identityKeys {
            if let s=fields[key]?.text,!s.isEmpty{identifier=s;break}
            if let n=fields[key]?.number,n>0{identifier=String(n);break}
        }
        guard let identifier,identifier.count<=200,!identifier.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else{throw ControlAPIError.invalidResponse}
        if [.request,.key,.order,.referral].contains(kind){guard ConsoleTarget.uuid(identifier) else{throw ControlAPIError.invalidResponse}}
        if let revision=fields["revision"],revision != .null {guard let s=revision.text,!s.isEmpty,s.count<=200 else{throw ControlAPIError.invalidResponse}}
        if let actions=fields["allowed_actions"] {
            guard let values=actions.values,values.count<=20 else{throw ControlAPIError.invalidResponse}
            var seen=Set<ConsoleAction>()
            for v in values {
                let a=try Self.availability(v);guard seen.insert(a.action).inserted else{throw ControlAPIError.invalidResponse}
                let expected:ConsoleTarget.Kind?
                switch kind{case .request:expected = .request;case .client:expected = .client;case .key:expected = .key;case .order:expected = .order;case .referral:expected = .referral;default:expected=nil}
                guard a.action.targetKind==expected else{throw ControlAPIError.invalidResponse}
            }
        }
        self.kind=kind;self.fields=fields;id=identifier
    }
    static func availability(_ value:ConsoleValue)throws->ConsoleAvailability {
        guard let f=value.fields,Set(f.keys)==Set(["action","enabled","reason_code"]),
              let raw=f["action"]?.text,let action=ConsoleAction(rawValue:raw),let enabled=f["enabled"]?.flag else{throw ControlAPIError.invalidResponse}
        if let r=f["reason_code"],r != .null,r.text==nil{throw ControlAPIError.invalidResponse}
        let result=ConsoleAvailability(action:action,enabled:enabled,reasonCode:f["reason_code"]?.text);try result.validate();return result
    }
    var actions:[ConsoleAvailability] {(fields["allowed_actions"]?.values ?? []).compactMap{try? Self.availability($0)}}
    var revision:String? {fields["revision"]?.text}
    func text(_ name:String)->String? {fields[name]?.text}
    var clientID:Int64? {fields["telegram_user_id"]?.number ?? fields["inviter_telegram_user_id"]?.number}
    var title:String {text("name") ?? text("display_name") ?? text("inviter_display_name") ?? text("action") ?? id}
    func target(for action:ConsoleAction,clientScope:Int64?)throws->ConsoleTarget {
        if kind == .key,let clientScope,clientScope != clientID{throw ControlAPIError.invalidRequest}
        let qualifier=kind == .key ? clientScope:kind == .client ? nil:clientID
        let t=ConsoleTarget(kind:action.targetKind,id:id,clientID:qualifier)
        try t.validate();return t
    }
}

struct ConsolePage:Equatable {let items:[ConsoleRecord];let total:Int,page:Int,pageSize:Int,hasMore:Bool}
struct ConsoleReceipt:Codable,Equatable {
    let operationID:String,action:ConsoleAction,state:ControlOperationState,summary:String,target:ConsoleTarget
    let expiresAt:String?,preview:[String:ConsoleValue]?,effects:[String:ConsoleValue]?,errorCode:String?
    var confirmationToken:String?
    enum CodingKeys:String,CodingKey{case operationID="operation_id",action,state,summary,target,expiresAt="expires_at",preview,effects,errorCode="error_code",confirmationToken="confirmation_token"}
    func validated(for request:ConsoleRequest)throws->Self {
        guard operationID==request.operationID,action==request.action,target==request.target,summary.count<=2048,
              !summary.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0) && $0 != "\n"}),
              expiresAt.map({ControlOperationReceipt.parseDate($0) != nil}) ?? true,
              errorCode.map({$0.count<=100 && $0.range(of:"^[A-Za-z0-9_.-]+$",options:.regularExpression) != nil}) ?? true,
              confirmationToken.map({$0.range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil}) ?? true else{throw ControlAPIError.invalidResponse}
        if let preview {
            let baseKeys=Set(["kind","before","after","expected_version"])
            guard (Set(preview.keys)==baseKeys || Set(preview.keys)==baseKeys.union(["cohort"])),preview["kind"]?.text==target.kind.rawValue,
                  let version=preview["expected_version"]?.text,version.range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil,
                  let before=preview["before"]?.fields,let after=preview["after"]?.fields else{throw ControlAPIError.invalidResponse}
            try ConsoleRecordSchema.validatePreview(kind:target.kind,before:before,after:after,request:request)
            if ConsoleReferralPlan.exactActions.contains(action) {
                guard let cohort=preview["cohort"]?.fields else{throw ControlAPIError.invalidResponse}
                try ConsoleReferralPlan.validateBinding(cohort,request:request,before:before,expected:version)
            } else {
                guard before["revision"]?.text==version else{throw ControlAPIError.invalidResponse}
                if let cohort=preview["cohort"],cohort != .null{throw ControlAPIError.invalidResponse}
            }
            for v in preview.values{try v.validate()}
        }
        guard let effects else{throw ControlAPIError.invalidResponse}
        try ConsoleRecordSchema.validateEffects(effects);for v in effects.values{try v.validate()}
        if state == .succeeded {
            guard effects["business_confirmed"]?.flag==true else{throw ControlAPIError.invalidResponse}
            if action == .refund {guard effects["payment_state"]?.text=="confirmed",effects["access_state"]?.text=="confirmed" else{throw ControlAPIError.invalidResponse}}
        }
        if state == .prepared {guard expiresAt != nil,preview != nil else{throw ControlAPIError.invalidResponse}}
        return self
    }
    func withoutToken()->Self {var copy=self;copy.confirmationToken=nil;return copy}
}

/// Safe read/write surface over the existing mTLS transport; no new endpoint or identity.
final class ControlConsoleClient {
    private let transport:ControlHTTPTransport
    init(transport:ControlHTTPTransport){self.transport=transport}
    private func call<T:Decodable>(_ type:T.Type,method:String,path:String,query:[URLQueryItem]=[],body:Data?=nil)async throws->T {
        let (code,data)=try await transport.send(method:method,path:path,query:query,body:body)
        guard data.count<=524288 else{throw ControlAPIError.oversizedResponse}
        guard (200...299).contains(code) else {
            switch code{case 401,403:throw ControlAPIError.forbidden;case 404:throw ControlAPIError.notFound;case 409:throw ControlAPIError.conflict;case 410:throw ControlAPIError.expired;case 429:throw ControlAPIError.busy;default:throw ControlAPIError.unavailable}
        }
        try Self.validateJSONBounds(data)
        return try JSONDecoder().decode(type,from:data)
    }
    static func validateJSONBounds(_ data:Data)throws {
        guard data.count<=524288 else{throw ControlAPIError.oversizedResponse}
        let value=try JSONSerialization.jsonObject(with:data)
        var stack:[(Any,Int)]=[(value,0)],nodes=0
        while let (item,depth)=stack.popLast(){
            nodes+=1;guard nodes<=20000,depth<=12 else{throw ControlAPIError.invalidResponse}
            if let s=item as? String{guard s.count<=2048 else{throw ControlAPIError.invalidResponse}}
            else if let a=item as? [Any]{guard a.count<=100 else{throw ControlAPIError.invalidResponse};for v in a{stack.append((v,depth+1))}}
            else if let d=item as? [String:Any]{guard d.count<=100,d.keys.allSatisfy({$0.count<=80}) else{throw ControlAPIError.invalidResponse};for v in d.values{stack.append((v,depth+1))}}
        }
    }
    func capabilities()async throws->ConsoleCapabilities {
        let c=try await call(ConsoleCapabilities.self,method:"GET",path:"/v2/capabilities");try c.validate();return c
    }
    func detail(path:String,kind:ConsoleKind,query:[URLQueryItem]=[])async throws->ConsoleRecord {
        let scope=try Self.validateRead(path:path,kind:kind,query:query,page:false)
        let fields=try await call([String:ConsoleValue].self,method:"GET",path:path,query:query)
        let record=try ConsoleRecord(kind:kind,fields:fields)
        guard record.revision != nil,fields["allowed_actions"] != nil else{throw ControlAPIError.invalidResponse}
        if let id=scope.id{guard record.id==id else{throw ControlAPIError.invalidResponse}}
        if let owner=scope.clientID,let recipient=record.clientID{guard recipient==owner else{throw ControlAPIError.invalidResponse}}
        if scope.clientID != nil && [.client,.key,.order,.referral].contains(kind){guard record.clientID==scope.clientID else{throw ControlAPIError.invalidResponse}}
        return record
    }
    func page(path:String,kind:ConsoleKind,query:[URLQueryItem]=[])async throws->ConsolePage {
        let scope=try Self.validateRead(path:path,kind:kind,query:query,page:true)
        let p=try await call([String:ConsoleValue].self,method:"GET",path:path,query:query)
        guard Set(p.keys)==Set(["items","total","page","page_size","has_more"]),let values=p["items"]?.values,
              let total=p["total"]?.number,total>=0,total<=Int64(Int.max),let page=p["page"]?.number,(0...500).contains(page),
              let size=p["page_size"]?.number,(1...20).contains(size),values.count<=size,let more=p["has_more"]?.flag else{throw ControlAPIError.invalidResponse}
        let items=try values.map{value in guard let fields=value.fields else{throw ControlAPIError.invalidResponse};return try ConsoleRecord(kind:kind,fields:fields)}
        guard Set(items.map(\.id)).count==items.count else{throw ControlAPIError.invalidResponse}
        if let owner=scope.clientID{guard items.allSatisfy({$0.clientID==owner || ($0.kind == .history && $0.clientID==nil)}) else{throw ControlAPIError.invalidResponse}}
        return ConsolePage(items:items,total:Int(total),page:Int(page),pageSize:Int(size),hasMore:more)
    }
    static func validatePath(_ path:String)throws {
        let parts=path.split(separator:"/",omittingEmptySubsequences:false)
        guard path.hasPrefix("/v2/"),path.count<=250,!path.contains(".."),!path.contains("%"),!path.contains("?"),!path.contains("#"),
              parts.dropFirst().allSatisfy({!$0.isEmpty && $0.range(of:"^[A-Za-z0-9_:-]+$",options:.regularExpression) != nil}) else{throw ControlAPIError.invalidRequest}
    }
    static func validateRead(path:String,kind:ConsoleKind,query:[URLQueryItem],page:Bool)throws->(id:String?,clientID:Int64?) {
        try validatePath(path)
        let p=path.split(separator:"/").map(String.init)
        var expected:ConsoleKind?,isPage=false,allowed=Set<String>(),statuses:[String]=[],id:String?,client:Int64?
        func decimal(_ s:String)throws->Int64{guard s.range(of:"^[0-9]{1,19}$",options:.regularExpression) != nil,let n=Int64(s),n>0,String(n)==s else{throw ControlAPIError.invalidRequest};return n}
        func objectID(_ s:String)throws->String{guard ConsoleTarget.uuid(s) else{throw ControlAPIError.invalidRequest};return s}
        switch p.dropFirst().first {
        case "requests":
            if p.count==2{expected = .request;isPage=true;allowed=["page","page_size","query","status"];statuses=["all","pending","payment","processing","completed"]}
            else if p.count==3{expected = .request;id=try objectID(p[2])}
        case "clients":
            if p.count==2{expected = .client;isPage=true;allowed=["page","page_size","query","status"];statuses=["all","active","expired","payment","pending","blocked"]}
            else if p.count>=3 {
                client=try decimal(p[2])
                if p.count==3{expected = .client;id=p[2]}
                else if p.count==4 {
                    isPage=true;allowed=["page","page_size"]
                    switch p[3]{case "keys":expected = .key;allowed.insert("archived");case "history":expected = .history;case "payments":expected = .order;allowed.insert("status");statuses=["all","succeeded","refund_pending","refunded","refund_failed","refund_unknown"];default:break}
                }else if p.count==5 {
                    if p[3]=="orders"{expected = .order;id=try objectID(p[4])}
                    else if p[3]=="history"{expected = .history;id=p[4]}
                }
            }
        case "keys":if p.count==3{expected = .key;id=try objectID(p[2]);allowed=["client_id"]}
        case "referrals":
            allowed=["client_id"]
            if p.count==2{expected = .referral;isPage=true;allowed.formUnion(["page","page_size","status"]);statuses=["all","awaiting_gift","awaiting_delivery","qualified","earned","pending","review","rejected","active","scheduled","completed"]}
            else if p.count==3{expected = .referral;id=try objectID(p[2])}
        case "attention":
            if p.count==2{expected = .attention;isPage=true;allowed=["page","page_size","kind","status"];statuses=["all","attention","accepted","resolved"]}
            else if p.count==3{expected = .attention;id=p[2]}
        default:break
        }
        guard expected==kind,isPage==page,Set(query.map(\.name)).count==query.count,Set(query.map(\.name)).isSubset(of:allowed) else{throw ControlAPIError.invalidRequest}
        for q in query {
            guard let value=q.value else{throw ControlAPIError.invalidRequest}
            switch q.name {
            case "page","page_size":guard value.range(of:"^[0-9]{1,3}$",options:.regularExpression) != nil,let n=Int(value),(q.name=="page" ? 0...500:1...20).contains(n) else{throw ControlAPIError.invalidRequest}
            case "query":guard value.count<=80,!value.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else{throw ControlAPIError.invalidRequest}
            case "status":guard statuses.contains(value) else{throw ControlAPIError.invalidRequest}
            case "kind":guard ["all","traffic","delivery","issuance","control","refund","referral","payment"].contains(value) else{throw ControlAPIError.invalidRequest}
            case "archived":guard ["true","false"].contains(value) else{throw ControlAPIError.invalidRequest}
            case "client_id":client=try decimal(value)
            default:throw ControlAPIError.invalidRequest
            }
        }
        return (id,client)
    }
    func preview(_ r:ConsoleRequest)async throws->ConsoleReceipt {
        try r.validate();let body=try JSONEncoder().encode(r);guard body.count<=8192 else{throw ControlAPIError.invalidRequest}
        let result=try await call(ConsoleReceipt.self,method:"POST",path:"/v2/operations/previews",body:body).validated(for:r)
        guard result.state == .prepared,result.confirmationToken != nil else{throw ControlAPIError.invalidResponse};return result
    }
    func status(_ r:ConsoleRequest)async throws->ConsoleReceipt {
        try r.validate();return try await call(ConsoleReceipt.self,method:"GET",path:"/v2/operations/"+r.operationID).validated(for:r).withoutToken()
    }
    func confirm(_ r:ConsoleRequest,token:String)async throws->ConsoleReceipt {try await proof(r,token:token,verb:"confirm")}
    func cancel(_ r:ConsoleRequest,token:String)async throws->ConsoleReceipt {try await proof(r,token:token,verb:"cancel")}
    private func proof(_ r:ConsoleRequest,token:String,verb:String)async throws->ConsoleReceipt {
        try r.validate();guard token.range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil else{throw ControlAPIError.invalidRequest}
        return try await call(ConsoleReceipt.self,method:"POST",path:"/v2/operations/"+r.operationID+"/"+verb,body:JSONEncoder().encode(["confirmation_token":token])).validated(for:r).withoutToken()
    }
}
