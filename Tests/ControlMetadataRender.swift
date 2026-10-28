import AppKit
import SwiftUI

/// No socket or Keychain access: a stateful synthetic transport for native UI acceptance.
private actor MetadataRenderTransport:ControlHTTPTransport {
    let metadata:[String:ConsoleValue],overview:[String:ConsoleValue]
    var current:[String:ConsoleValue],operation:[String:ConsoleValue]?
    init(metadata:[String:ConsoleValue],overview:[String:ConsoleValue])throws {
        self.metadata=metadata;self.overview=overview
        guard let v=metadata["records"]?.values?.first(where:{$0.fields?["name"]?.text=="original"})?.fields?["value"]?.fields else{throw ControlAPIError.configuration};current=v
    }
    private func record(_ source:[String:ConsoleValue],_ name:String)throws->[String:ConsoleValue] {
        guard let v=source["records"]?.values?.first(where:{$0.fields?["name"]?.text==name})?.fields?["value"]?.fields else{throw ControlAPIError.invalidResponse};return v
    }
    func send(method:String,path:String,query:[URLQueryItem],body:Data?)async throws->(Int,Data){
        if path=="/v1/capabilities"{return(200,Data(#"{"api_version":1,"features":["issue_owner_key","extend_owner_key_days","operation_status","owner_keys"]}"#.utf8))}
        if path=="/v1/owner/keys"{return(200,Data(#"{"items":[],"has_more":false}"#.utf8))}
        var value:[String:ConsoleValue]
        if path.hasSuffix("/capabilities") {value=try record(path.contains("overview") ? overview:metadata,"capabilities")}
        else if path=="/v2/overview" {value=try record(overview,"snapshot")}
        else if path.contains("/keys/") {value=current}
        else if path.hasSuffix("/previews") {
            let raw=try MetadataWire.decode(body!),p=try MetadataWire.object(raw["parameters"])
            let r=try MetadataRequest(operationID:MetadataWire.string(raw,"operation_id"),target:MetadataTarget(MetadataWire.object(raw["target"])),draft:.init(name:MetadataWire.string(p,"name"),note:MetadataWire.string(p,"note")),expectedRevision:MetadataWire.string(p,"expected_view_revision"))
            guard r.expectedRevision==current["view_revision"]?.text else{throw ControlAPIError.conflict}
            value=["schema_revision":.integer(1),"operation_id":.string(r.operationID),"action":.string("key_metadata_update"),"state":.string("prepared"),"request_digest":.string(r.digest),"target":.object(r.target.fields),"expires_at":.string(ISO8601DateFormatter().string(from:Date().addingTimeInterval(120))),"preview":.object(["target":.object(r.target.fields),"before":.object(current),"after":.object(["effective_name":.string(r.draft.name),"note":.string(r.draft.note),"business_fields_unchanged":.boolean(true)]),"expected_view_revision":.string(r.expectedRevision),"request_digest":.string(r.digest)]),"result":.null,"error_code":.null,"confirmation_token":.string(String(repeating:"f",count:64))];operation=value
        } else if path.hasSuffix("/confirm") || path.hasSuffix("/cancel") {
            guard var op=operation,op["state"]?.text=="prepared",path.contains(op["operation_id"]!.text!),let body,try MetadataWire.decode(body)==["confirmation_token":.string(String(repeating:"f",count:64))] else{throw ControlAPIError.forbidden}
            op["confirmation_token"] = .null;op["expires_at"] = .null
            if path.hasSuffix("/cancel") {op["state"] = .string("canceled")}
            else {
                let a=op["preview"]!.fields!["after"]!.fields!,rev=current["metadata_revision"]!.number!+1
                current["effective_name"]=a["effective_name"];current["note"]=a["note"];current["metadata_revision"] = .integer(rev);current["name_source"] = .string("override");current["updated_at"] = .string(ISO8601DateFormatter().string(from:Date()));current["view_revision"] = .string(try MetadataWire.digest(.array([.string("ui-fixture"),.integer(rev)])))
                op["state"] = .string("succeeded");op["result"] = .object(current)
            };operation=op;value=op
        } else {guard var op=operation,path.hasSuffix(op["operation_id"]!.text!) else{throw ControlAPIError.notFound};op["confirmation_token"] = .null;value=op}
        return(200,Data(try MetadataWire.canonical(.object(value)).utf8))
    }
}
private final class MetadataFixtureDelegate:NSObject,NSApplicationDelegate {
    var window:NSWindow?
    func applicationDidFinishLaunching(_ notification:Notification) {
        Task{@MainActor in do{try await show()}catch{fputs("FIXTURE_SETUP_FAILED\n",stderr);NSApplication.shared.terminate(nil)}}
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool {true}
    @MainActor private func show()async throws {
        let bundled=CommandLine.arguments.count==1
        guard bundled || (3...4).contains(CommandLine.arguments.count) else{throw ControlAPIError.configuration}
        let base=bundled ? Bundle.main.resourceURL!.path:CommandLine.arguments[1]
        let out=bundled ? "/private/tmp/observatory-metadata-fixture-cache.png":CommandLine.arguments[2]
        let showing=bundled || CommandLine.arguments.last=="--show"
        let m=try MetadataWire.decode(Data(contentsOf:URL(fileURLWithPath:base+"/WIRE-METADATA-r1.json"))),o=try MetadataWire.decode(Data(contentsOf:URL(fileURLWithPath:base+"/WIRE-OVERVIEW-r1.json")))
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("metadata-render-"+UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
        let transport=try MetadataRenderTransport(metadata:m,overview:o),profile=ControlConnectionProfile(endpoint:"https://fixture.example.invalid:29443",serverCA:Data([1]),identityLabel:"Fixture only")
        let legacy=ControlAPIModel(store:ControlLocalStore(directory:root.appendingPathComponent("v1")),makeClient:{_ in ControlAPIClient(transport:transport)});await legacy.connect(profile)
        let model=ControlMetadataModel(legacy:legacy,store:MetadataLocalStore(directory:root.appendingPathComponent("metadata")));await model.attach(profile:profile,client:ControlMetadataClient(transport:transport))
        let target=try MetadataTarget(id:"326e4605-75d9-4c1b-86dc-d0e33ba1dd68",clientID:910002);await model.load(target)
        guard let snapshot=model.snapshots[target.id] else{throw ControlAPIError.invalidResponse}
        await model.prepare(target:target,snapshot:snapshot,draft:.init(name:"Café 📱",note:"Первая\n\tвторая"))
        guard model.canConfirm else{throw ControlAPIError.invalidResponse}
        let content=ScrollView{VStack(alignment:.leading,spacing:18){Text("Локальный кандидат · вымышленные данные").font(.headline);ControlOverviewPanel(model:model);MetadataEditor(model:model,target:target);MetadataOperationPanel(model:model)}.padding(24)}.frame(width:1020,height:850).preferredColorScheme(.dark)
        let view=NSHostingView(rootView:content),w=NSWindow(contentRect:NSRect(x:0,y:0,width:1020,height:850),styleMask:showing ? [.titled,.closable]:[.borderless],backing:.buffered,defer:false)
        window=w;w.isReleasedWhenClosed=false;w.title="Observatory — вымышленные данные";w.appearance=NSAppearance(named:.darkAqua);w.backgroundColor = .windowBackgroundColor;w.contentView=view;w.center();w.makeKeyAndOrderFront(nil);view.layoutSubtreeIfNeeded()
        print("OWN_FIXTURE_WINDOW=\(w.windowNumber)");fflush(stdout)
        if showing {NSApplication.shared.activate(ignoringOtherApps:true)}
        try await Task.sleep(nanoseconds:showing ? 55_000_000_000:500_000_000)
        view.layoutSubtreeIfNeeded();view.displayIfNeeded()
        if let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds){view.cacheDisplay(in:view.bounds,to:bitmap);if let png=bitmap.representation(using:.png,properties:[:]){try png.write(to:URL(fileURLWithPath:out),options:.atomic)}}
        model.disconnect();legacy.disconnect();w.close();print("Fixture finished; synthetic state only");NSApplication.shared.terminate(nil)
    }
}
@main struct ControlMetadataRender {
    @MainActor static func main() {
        let application=NSApplication.shared,delegate=MetadataFixtureDelegate()
        application.setActivationPolicy(.regular);application.delegate=delegate
        withExtendedLifetime(delegate){application.run()}
    }
}
