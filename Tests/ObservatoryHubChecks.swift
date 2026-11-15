import Foundation
import TelemetryCore
import Darwin

@main @MainActor struct ObservatoryHubChecks {
    static func main() async throws {
        signal(SIGPIPE,SIG_IGN)
        let directory=URL(fileURLWithPath:"/private/tmp/oh-"+UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer{try? FileManager.default.removeItem(at:directory)}
        let profile=NodeProfile(id:"test",name:"Synthetic",region:"test",sshAlias:"unused-fixture",expectedHostname:"fixture")
        try JSONEncoder().encode([profile]).write(to:directory.appendingPathComponent("nodes.json"))
        let telemetry=TelemetryModel(base:directory,collectorSource:"",restore:false,observeWorkspace:false)
        let home=HomeEgressModel(),hub=ObservatoryHub(socketURL:directory.appendingPathComponent("hub.sock"))
        hub.start(telemetry:telemetry,home:home);defer{hub.stop();telemetry.stopAll()}
        for _ in 0..<100 where telemetry.loading {try await Task.sleep(for:.milliseconds(10))}
        func call(_ method:String,_ params:[String:Any]=[:],extra:[String:Any]=[:])async throws->[String:Any] {
            var envelope:[String:Any]=["version":1,"id":UUID().uuidString,"method":method,"params":params]
            envelope.merge(extra){_,new in new}
            return try JSONSerialization.jsonObject(with:await hub.receive(JSONSerialization.data(withJSONObject:envelope))) as! [String:Any]
        }
        var passed=0
        func check(_ condition:Bool){precondition(condition);passed+=1}
        let status=try await call("hub.status");check(status["ok"] as? Bool==true)
        let peerURL=directory.appendingPathComponent("hub.sock")
        let native=try await Task.detached {try ContourClient.call("hub.status",socketURL:peerURL)}.value
        check(native["service_version"] as? String=="0.7.0")
        let second=ObservatorySocket(url:peerURL){_ in Data()}
        check((try? second.start()) == nil)
        let again=try await Task.detached {try ContourClient.call("hub.status",socketURL:peerURL)}.value
        check(again["instance_id"] as? String == native["instance_id"] as? String)
        try FileManager.default.setAttributes([.posixPermissions:0o666],ofItemAtPath:peerURL.path)
        let unsafe=await Task.detached {(try? ContourClient.call("hub.status",socketURL:peerURL)) == nil}.value
        check(unsafe)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:peerURL.path)
        let listed=try await call("nodes.list");let nodes=(listed["result"] as! [String:Any])["nodes"] as! [[String:Any]]
        check(nodes.count==1);check(nodes[0]["fresh"] as? Bool==false);check(nodes[0]["sample"] is NSNull)
        let unknown=try await call("node.telemetry",["node_id":"absent"]);check((unknown["error"] as? [String:Any])?["code"] as? String=="unknown_node")
        let injected=try await call("node.inspect",["node_id":"test","check":"identity; touch /tmp/no"]);check(injected["ok"] as? Bool==false)
        let noRoute=try await call("node.inspect",["node_id":"test","check":"identity"])
        check((noRoute["error"] as? [String:Any])?["code"] as? String=="unavailable")
        let noExecRoute=try await call("node.exec",["node_id":"test","command":"id"])
        check((noExecRoute["error"] as? [String:Any])?["code"] as? String=="unavailable")
        let invalidExec=try await call("node.exec",["node_id":"test","command":""])
        check((invalidExec["error"] as? [String:Any])?["code"] as? String=="invalid_request")
        let noSessionRoute=try await call("node.session.open",["node_id":"test"])
        check((noSessionRoute["error"] as? [String:Any])?["code"] as? String=="unavailable")
        let noFileRoute=try await call("node.file.transfer",["node_id":"test","direction":"download","local_path":"/tmp/fixture","remote_path":"/tmp/fixture","overwrite":false])
        check((noFileRoute["error"] as? [String:Any])?["code"] as? String=="unavailable")
        let sftpArgs=try ProtectedSFTP.arguments(profile:profile,port:19082)
        check(sftpArgs.contains("ProxyCommand=/usr/bin/nc -X 5 -x 127.0.0.1:19082 %h %p"))
        check(sftpArgs.contains("StrictHostKeyChecking=yes") && sftpArgs.contains("ControlPath=none"))
        check((try? ProtectedSFTP.quoted("/tmp/x\nput evil")) == nil)
        check(try ProtectedSFTP.quoted("/tmp/a \"b\"") == "\"/tmp/a \\\"b\\\"\"")
        let extra=try await call("node.telemetry",["node_id":"test","command":"env"]);check(extra["ok"] as? Bool==false)
        let secret=try await call("home.overview");check((secret["error"] as? [String:Any])?["code"] as? String=="home_not_connected")
        let mutation=try await call("home.apply",["action":"service.protect"]);check(mutation["ok"] as? Bool==false)
        let boolVersion=try await call("hub.status",extra:["version":true]);check(boolVersion["ok"] as? Bool==false)
        let shape=try await call("hub.status",extra:["command":"hostname"]);check(shape["ok"] as? Bool==false)
        let mode=(try FileManager.default.attributesOfItem(atPath:directory.appendingPathComponent("hub.sock").path)[.posixPermissions] as! NSNumber).intValue
        check(mode==0o600)
        let audit=try String(contentsOf:directory.appendingPathComponent("hub-audit.jsonl"),encoding:.utf8)
        check(!audit.contains("service.protect") && !audit.contains("touch /tmp/no") && !audit.contains("hostname"))
        hub.stop();check(!FileManager.default.fileExists(atPath:directory.appendingPathComponent("hub.sock").path))
        print("Observatory Hub checks passed: \(passed)")
    }
}
