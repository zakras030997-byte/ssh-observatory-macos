// Generated from frozen CONTRACT-r2 revision2; review changes against its SHA.
import Foundation

enum ConsoleRecordSchema {
    static let contractSHA="63affdaee2704512078641ab95996118ba55a761aff825bf90951c0635399a6e"
    enum Rule {case string(Bool,Bool,Bool),integer(Bool),boolean(Bool),actions,history,chain}
    static func rules(_ kind:ConsoleKind)->[String:Rule] {
        switch kind {
        case .request:return ["request_id":.string(false,false,false),"telegram_user_id":.integer(false),"username":.string(true,false,false),"display_name":.string(false,false,false),"device_count":.integer(false),"period_count":.integer(false),"total_xtr":.integer(false),"status":.string(false,false,false),"request_kind":.string(false,false,false),"stage":.string(true,false,false),"identity_conflict":.boolean(false),"replace_invoice_available":.boolean(false),"gift_order_id":.string(true,false,false),"revision":.string(false,false,true),"allowed_actions":.actions]
        case .client:return ["telegram_user_id":.integer(false),"display_name":.string(false,false,false),"username":.string(true,false,false),"slots_used":.integer(false),"slots_limit":.integer(false),"active_keys":.integer(false),"suspended_keys":.integer(false),"status":.string(false,false,false),"expired_keys":.integer(false),"pending_keys":.integer(false),"identity_conflict":.boolean(false),"revision":.string(false,false,true),"allowed_actions":.actions]
        case .key:return ["key_id":.string(false,false,false),"name":.string(false,false,false),"protocol":.string(false,false,false),"state":.string(false,false,false),"expires_at":.string(true,true,false),"period_ends_at":.string(true,true,false),"used_bytes":.integer(true),"limit_bytes":.integer(true),"last_activity_at":.string(true,true,false),"time_unlimited":.boolean(false),"traffic_unlimited":.boolean(false),"traffic_available":.boolean(false),"traffic_updated_at":.string(true,true,false),"traffic_oldest_at":.string(true,true,false),"traffic_loss_unknown":.boolean(false),"traffic_partial_stale":.boolean(false),"traffic_scope":.string(true,false,false),"remaining_bytes":.integer(true),"access_kind":.string(true,false,false),"telegram_user_id":.integer(true),"username":.string(true,false,false),"display_name":.string(true,false,false),"revision":.string(false,false,true),"allowed_actions":.actions]
        case .order:return ["order_id":.string(false,false,false),"telegram_user_id":.integer(false),"amount_xtr":.integer(false),"order_type":.string(false,false,false),"devices_count":.integer(false),"periods_count":.integer(false),"paid_at":.string(false,true,false),"payment_status":.string(false,false,false),"refundable":.boolean(false),"username":.string(true,false,false),"display_name":.string(true,false,false),"revision":.string(false,false,true),"allowed_actions":.actions]
        case .history:return ["event_id":.string(false,false,false),"created_at":.string(false,true,false),"actor":.string(false,false,false),"action":.string(false,false,false),"target":.string(false,false,false),"result":.string(false,false,false),"reason":.string(true,false,false),"before":.history,"after":.history,"telegram_user_id":.integer(true),"username":.string(true,false,false),"display_name":.string(true,false,false),"revision":.string(false,false,true),"allowed_actions":.actions]
        case .referral:return ["reward_id":.string(false,false,false),"attribution_id":.string(false,false,false),"status":.string(false,false,false),"reason":.string(true,false,false),"reviewable":.boolean(false),"earned_at":.string(true,true,false),"starts_at":.string(true,true,false),"ends_at":.string(true,true,false),"device_slot_id":.string(true,false,false),"order_id":.string(true,false,false),"bound_at":.string(false,true,false),"inviter_telegram_user_id":.integer(true),"inviter_username":.string(true,false,false),"inviter_display_name":.string(true,false,false),"invitee_telegram_user_id":.integer(true),"invitee_username":.string(true,false,false),"invitee_display_name":.string(true,false,false),"gift_created":.boolean(false),"gift_fulfilled":.boolean(false),"delivery_confirmed":.boolean(false),"revision":.string(false,false,true),"allowed_actions":.actions]
        case .attention:return ["problem_id":.string(false,false,false),"kind":.string(false,false,false),"status":.string(false,false,false),"object_id":.string(false,false,false),"stage":.string(false,false,false),"reason":.string(false,false,false),"first_event_at":.string(false,true,false),"last_event_at":.string(false,true,false),"attempts":.integer(false),"telegram_user_id":.integer(true),"username":.string(true,false,false),"display_name":.string(true,false,false),"chain":.chain,"next_step":.string(false,false,false),"responsible":.string(true,false,false),"revision":.string(false,false,true),"allowed_actions":.actions]
        }
    }
    static func validate(kind:ConsoleKind,fields:[String:ConsoleValue])throws {
        let spec=rules(kind)
        guard Set(fields.keys)==Set(spec.keys) else{throw ControlAPIError.invalidResponse}
        for (key,rule) in spec {
            let v=fields[key]!
            switch rule {
            case .string(let nullable,let utc,let digest):
                if v == .null && nullable{continue}
                guard let s=v.text,s.count<=2048 else{throw ControlAPIError.invalidResponse}
                if utc{guard (s.hasSuffix("Z") || s.hasSuffix("+00:00")),ControlOperationReceipt.parseDate(s) != nil else{throw ControlAPIError.invalidResponse}}
                if digest{guard hex64(s) else{throw ControlAPIError.invalidResponse}}
            case .integer(let nullable):
                if v == .null && nullable{continue}
                guard let n=v.number,n>=0 else{throw ControlAPIError.invalidResponse}
                if key.hasSuffix("telegram_user_id"){guard n>0 else{throw ControlAPIError.invalidResponse}}
            case .boolean(let nullable):
                if v == .null && nullable{continue}
                guard v.flag != nil else{throw ControlAPIError.invalidResponse}
            case .actions:
                guard let a=v.values,a.count<=20 else{throw ControlAPIError.invalidResponse}
                for item in a{_=try ConsoleRecord.availability(item)}
            case .history:
                if v == .null{continue}
                guard let values=v.fields,Set(values.keys).isSubset(of:historyKeys) else{throw ControlAPIError.invalidResponse}
                for leaf in values.values{switch leaf{case .null,.string,.integer,.number,.boolean:break;default:throw ControlAPIError.invalidResponse}}
            case .chain:
                guard let a=v.values,a.count<=100 else{throw ControlAPIError.invalidResponse}
                for item in a{guard let row=item.fields,Set(row.keys)==Set(["stage","status"]),row["stage"]?.text != nil,row["status"]?.text != nil else{throw ControlAPIError.invalidResponse}}
            }
        }
    }
    private static let historyKeys:Set<String>=["amount_xtr","attribution_state","base_quota_bytes","count","days","ends_at","manual_suspended_at","payment_status","periods","policy_revision","provision_state","quantity","quota_bytes","result","reward_state","starts_at","state","status","term_end","time_mode","traffic_mode"]
    static func hex64(_ s:String)->Bool{s.range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil}
    static func validatePreview(kind:ConsoleTarget.Kind,before:[String:ConsoleValue],after:[String:ConsoleValue],request:ConsoleRequest)throws {
        switch kind {
        case .referralScope:
            if before["plan_id"] != nil{try ConsoleReferralPlan.validate(before);break}
            guard Set(before.keys)==Set(["candidate_count","revision","candidate_ids"]),let n=before["candidate_count"]?.number,(0...100).contains(n),let ids=before["candidate_ids"]?.values,ids.count==Int(n),ids.allSatisfy({$0.text.map(ConsoleTarget.uuid) ?? false}),let revision=before["revision"]?.text,hex64(revision),Set(ids.compactMap(\.text)).count==ids.count else{throw ControlAPIError.invalidResponse}
        default:
            let recordKind:ConsoleKind
            switch kind{case .request:recordKind = .request;case .client:recordKind = .client;case .order:recordKind = .order;case .key:recordKind = .key;case .referral:recordKind = .referral;case .referralScope:throw ControlAPIError.invalidResponse}
            let record=try ConsoleRecord(kind:recordKind,fields:before)
            guard record.id==request.target.id else{throw ControlAPIError.invalidResponse}
            if let owner=request.target.clientID{guard record.clientID==owner else{throw ControlAPIError.invalidResponse}}
        }
        guard Set(after.keys)==Set(["summary","parameters","amount_xtr","currency","delivery_to","adds_quota","changes_term"]),after["summary"]?.text != nil,parametersMatch(after["parameters"]?.fields,request:request),after["adds_quota"]?.flag != nil,after["changes_term"]?.flag != nil,let destination=after["delivery_to"]?.text,["none","existing_client_telegram","owner_private_telegram"].contains(destination) else{throw ControlAPIError.invalidResponse}
        guard let amount=after["amount_xtr"],let currency=after["currency"] else{throw ControlAPIError.invalidResponse}
        if amount != .null{guard let n=amount.number,n>=0,currency.text=="XTR" else{throw ControlAPIError.invalidResponse}}else{guard currency == .null else{throw ControlAPIError.invalidResponse}}
        if request.action == .refund{guard before["refundable"]?.flag==true,before["amount_xtr"]?.number.map({$0>0})==true,after["amount_xtr"]==before["amount_xtr"],currency.text=="XTR" else{throw ControlAPIError.invalidResponse}}
        if [.days,.expiry,.timeUnlimited].contains(request.action){guard after["adds_quota"]?.flag==false else{throw ControlAPIError.invalidResponse}}
        if [.traffic,.unlimitedOn,.unlimitedOff].contains(request.action){guard after["changes_term"]?.flag==false else{throw ControlAPIError.invalidResponse}}
    }
    static func parametersMatch(_ parameters:[String:ConsoleValue]?,request:ConsoleRequest)->Bool {
        guard let parameters else{return false}
        if parameters==request.parameters{return true}
        guard request.action == .expiry,Set(parameters.keys)==Set(["expires_at"]),
              let actual=parameters["expires_at"]?.text,let wanted=request.parameters["expires_at"]?.text,
              (try? ConsoleAction.expiry.parameters(actual)) != nil,
              let a=ControlOperationReceipt.parseDate(actual),let b=ControlOperationReceipt.parseDate(wanted) else{return false}
        return a==b
    }
    static func validateEffects(_ fields:[String:ConsoleValue])throws {
        guard Set(fields.keys)==Set(["business_confirmed","delivery_state","payment_state","access_state","order_id","key_id","amount_xtr","currency","processed"]),fields["business_confirmed"]?.flag != nil else{throw ControlAPIError.invalidResponse}
        for (key,allowed) in [("delivery_state",["none","pending","telegram_accepted","delivered","unknown"]),("payment_state",["none","unpaid","pending","confirmed","unknown"]),("access_state",["none","pending","confirmed","unknown"])]{guard let s=fields[key]?.text,allowed.contains(s) else{throw ControlAPIError.invalidResponse}}
        for key in ["order_id","key_id"]{guard let v=fields[key],v == .null || (v.text.map(ConsoleTarget.uuid) ?? false) else{throw ControlAPIError.invalidResponse}}
        for key in ["amount_xtr","processed"]{guard let v=fields[key],v == .null || (v.number.map{$0>=0} ?? false) else{throw ControlAPIError.invalidResponse}}
        guard fields["currency"] == .null || fields["currency"]?.text=="XTR" else{throw ControlAPIError.invalidResponse}
    }
}
