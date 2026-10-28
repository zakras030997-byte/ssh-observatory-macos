import Foundation

/// Closed revision3 referral plan, independent of legacy revision2 record schemas.
enum ConsoleReferralPlan {
    static let contractSHA = "074e4712be5d2a6332f2ae2dd6884978f247a6c53212020251b3922205dda525"
    static let exactActions: Set<ConsoleAction> = [.referralApprove, .reconcile]
    static func validate(_ plan: [String:ConsoleValue]) throws {
        guard Set(plan.keys) == Set(["plan_id","revision","candidate_count","candidate_ids","items","excluded_count","allowed_actions"]),
              plan["plan_id"]?.text.map(ConsoleTarget.uuid) == true,
              plan["revision"]?.text.map(ConsoleRecordSchema.hex64) == true,
              let count = plan["candidate_count"]?.number, (1...100).contains(count),
              let excluded = plan["excluded_count"]?.number, (0...100).contains(excluded),
              let ids = plan["candidate_ids"]?.values, ids.count == Int(count),
              ids.allSatisfy({$0.text.map(ConsoleTarget.uuid) == true}),
              Set(ids.compactMap(\.text)).count == ids.count,
              let items = plan["items"]?.values, items.count == ids.count,
              let actions = plan["allowed_actions"]?.values, actions.count <= 20 else { throw ControlAPIError.invalidResponse }
        var seenActions = Set<ConsoleAction>()
        for value in actions {
            let action = try ConsoleRecord.availability(value)
            guard exactActions.contains(action.action), seenActions.insert(action.action).inserted else { throw ControlAPIError.invalidResponse }
        }
        var attributions = Set<String>(), rewards = Set<String>(), candidates:[String]=[]
        var effectIDs:[String:Set<String>]=[:]
        for value in items {
            guard let item = value.fields,
                  Set(item.keys) == Set(["attribution_id","reward_id","expected_version","inviter_telegram_user_id","device_key_id","period_id","traffic_policy_id","entitlement_id","generation_id","starts_at","ends_at","effect","creates_reward","term_seconds","traffic_mode"]),
                  let attribution = item["attribution_id"]?.text, ConsoleTarget.uuid(attribution),
                  attributions.insert(attribution).inserted,
                  item["expected_version"]?.text.map(ConsoleRecordSchema.hex64) == true,
                  let inviter = item["inviter_telegram_user_id"]?.number, inviter > 0,
                  let effect = item["effect"]?.text, ["approve_only","approve_and_apply","qualify_and_apply","apply"].contains(effect),
                  item["creates_reward"]?.flag != nil,
                  let term=item["term_seconds"]?.number,(0...604800).contains(term),
                  let traffic=item["traffic_mode"]?.text,["none","unlimited"].contains(traffic) else { throw ControlAPIError.invalidResponse }
            for key in ["reward_id","device_key_id","period_id","traffic_policy_id","entitlement_id","generation_id"] {
                guard let field = item[key], field == .null || field.text.map(ConsoleTarget.uuid) == true else { throw ControlAPIError.invalidResponse }
            }
            if let reward = item["reward_id"]?.text { guard rewards.insert(reward).inserted else { throw ControlAPIError.invalidResponse } }
            candidates.append(item["reward_id"]?.text ?? attribution)
            for key in ["period_id","traffic_policy_id","entitlement_id"] {
                if let identifier=item[key]?.text {
                    guard effectIDs[key,default:[]].insert(identifier).inserted else{throw ControlAPIError.invalidResponse}
                }
            }
            for key in ["starts_at","ends_at"] {
                guard let field = item[key] else { throw ControlAPIError.invalidResponse }
                if field != .null {
                    guard let date = field.text, date.hasSuffix("Z") || date.hasSuffix("+00:00"),
                          ControlOperationReceipt.parseDate(date) != nil else { throw ControlAPIError.invalidResponse }
                }
            }
            if let start = item["starts_at"]?.text.flatMap(ControlOperationReceipt.parseDate),
               let end = item["ends_at"]?.text.flatMap(ControlOperationReceipt.parseDate) {
                guard end > start,abs(end.timeIntervalSince(start)-Double(term))<0.000001 else { throw ControlAPIError.invalidResponse }
            }
            if effect=="approve_only" {
                guard term==0,traffic=="none",item["starts_at"] == .null,item["ends_at"] == .null,
                      ["device_key_id","period_id","traffic_policy_id","entitlement_id","generation_id"].allSatisfy({item[$0] == .null}) else{throw ControlAPIError.invalidResponse}
            } else {
                guard term>0,traffic=="unlimited",item["starts_at"]?.text != nil,item["ends_at"]?.text != nil,
                      ["reward_id","device_key_id","period_id","traffic_policy_id","entitlement_id","generation_id"].allSatisfy({item[$0]?.text != nil}) else{throw ControlAPIError.invalidResponse}
            }
        }
        guard candidates == ids.compactMap(\.text) else { throw ControlAPIError.invalidResponse }
        for value in plan.values { try value.validate() }
    }
    static func validateBinding(_ plan: [String:ConsoleValue], request:ConsoleRequest, before:[String:ConsoleValue], expected:String) throws {
        try validate(plan)
        guard exactActions.contains(request.action), plan["revision"]?.text == expected,
              let items = plan["items"]?.values else { throw ControlAPIError.invalidResponse }
        if request.action == .referralApprove {
            guard items.count == 1, items[0].fields?["attribution_id"] == before["attribution_id"],
                  items[0].fields?["inviter_telegram_user_id"] == before["inviter_telegram_user_id"] else { throw ControlAPIError.invalidResponse }
        } else {
            guard plan == before else { throw ControlAPIError.invalidResponse }
        }
        if let client = request.target.clientID {
            guard items.allSatisfy({$0.fields?["inviter_telegram_user_id"]?.number == client}) else { throw ControlAPIError.invalidResponse }
        }
    }
}
