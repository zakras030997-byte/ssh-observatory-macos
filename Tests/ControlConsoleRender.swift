import AppKit
import SwiftUI

/// Renders one synthetic server preview using isolated stores and no transport.
@main struct ControlConsoleRender {
    @MainActor static func main() throws {
        guard (3...4).contains(CommandLine.arguments.count) else{fatalError("Supply isolated wire fixtures and output PNG")}
        let data=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))
        guard data.count<=4_194_304,
              let envelope=try JSONSerialization.jsonObject(with:data) as? [String:Any],
              envelope["contract_sha256"] as? String==ConsoleReferralPlan.contractSHA,
              let operations=envelope["operations"] as? [[String:Any]],
              let value=operations.first(where:{($0["request"] as? [String:Any])?["action"] as? String=="referrals_reconcile" && $0["post_preview"] as? Bool==true && $0["http_status"] as? Int==200}),
              let rawRequest=value["request"],let rawReceipt=value["value"] else{throw ControlAPIError.invalidResponse}
        let request=try JSONDecoder().decode(ConsoleRequest.self,from:JSONSerialization.data(withJSONObject:rawRequest))
        let receipt=try JSONDecoder().decode(ConsoleReceipt.self,from:JSONSerialization.data(withJSONObject:rawReceipt)).validated(for:request)
        _=NSApplication.shared
        let content=ScrollView{VStack(alignment:.leading,spacing:12){
            Text("Локальная проверка интерфейса · вымышленные данные").font(.headline)
            if let plan=receipt.preview?["cohort"]?.fields{ConsoleReferralPlanView(plan:plan)}
        }.padding(20)}.frame(width:1000,height:860).preferredColorScheme(.dark)
        let view=NSHostingView(rootView:content)
        let showing=CommandLine.arguments.last=="--show"
        NSApplication.shared.setActivationPolicy(.accessory)
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1000,height:860),styleMask:showing ? [.titled,.closable]:[.borderless],backing:.buffered,defer:false)
        window.title="Observatory Preview — только вымышленные данные"
        window.appearance=NSAppearance(named:.darkAqua)
        window.backgroundColor = .windowBackgroundColor
        window.contentView=view
        view.frame=NSRect(x:0,y:0,width:1000,height:860)
        view.layoutSubtreeIfNeeded()
        window.orderFrontRegardless()
        if showing {
            NSApplication.shared.activate(ignoringOtherApps:true)
            print("OWN_FIXTURE_WINDOW=\(window.windowNumber)");fflush(stdout)
            DispatchQueue.main.asyncAfter(deadline:.now()+45){
                NSApplication.shared.stop(nil)
                if let event=NSEvent.otherEvent(with:.applicationDefined,location:.zero,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,subtype:0,data1:0,data2:0){NSApplication.shared.postEvent(event,atStart:true)}
            }
            NSApplication.shared.run()
        }
        RunLoop.current.run(until:Date().addingTimeInterval(0.5))
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) else{throw ControlAPIError.configuration}
        view.cacheDisplay(in:view.bounds,to:bitmap)
        guard let png=bitmap.representation(using:.png,properties:[:]) else{throw ControlAPIError.configuration}
        try png.write(to:URL(fileURLWithPath:CommandLine.arguments[2]),options:.atomic)
        window.close()
        print("Rendered isolated synthetic preview; no connections or installed profiles used")
    }
}
