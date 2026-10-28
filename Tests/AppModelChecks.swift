import Foundation
import AppKit
import TelemetryCore

private final class FakeSession: SessionControl {
    var starts = 0, stops = 0
    var onStart: (() -> Void)?
    func start() { starts += 1; onStart?() }
    func stop() { stops += 1 }
}

@main struct AppModelChecks {
    @MainActor static func main() async throws {
        var checks = 0, failures = 0
        func check(_ value: @autoclosure () -> Bool, _ text: String) {
            if value() { print("PASS model: \(text)") } else { failures += 1; print("FAIL model: \(text)") }; checks += 1
        }
        func settle() async { try? await Task.sleep(for: .milliseconds(30)) }
        let profile = NodeProfile(id:"test",name:"Fixture",region:"",sshAlias:"fixture")
        func sample(_ n: Int) -> TelemetrySample {
            TelemetrySample(nodeID:"test",hostname:"test",bootID:"boot",sequence:n,measuredAt:1_700_000_000+Double(n),uptime:100,cores:1,cpuPercent:10,memory:nil,swap:nil,disk:nil,network:nil,load:nil,units:[],errors:[:])
        }
        var callbacks: [SessionCallbacks] = [], sessions: [FakeSession] = []
        let factory: NodeModel.Factory = { _,_,cb in
            let s=FakeSession(); sessions.append(s); callbacks.append(cb); return s
        }
        let node=NodeModel(profile:profile,demo:false,collector:"fixture",history:nil,retryDelay:.milliseconds(5),loadHistory:false,factory:factory)
        node.connect(); node.connect()
        check(sessions.count==1,"connect does not replace an active connection")
        for i in 0..<100_000 { callbacks[0].sample(sample(i)) }
        await settle()
        check(node.window.points.count==1 && node.latest?.sample.sequence==99_999,"stalled UI coalesces into latest sample")
        check(node.skippedSamples==99_999,"coalescing is visible")
        callbacks[0].sample(sample(100_000)); callbacks[0].exit(SessionFailure("overload",permanent:true))
        await settle()
        check(node.state == .failed("overload"),"pending delivery cannot revive a failed session")
        check(node.latest?.sample.sequence==99_999 && sessions.count==1,"terminal overload has no retry or stale update")
        node.connect(); check(sessions.count==2,"manual retry can create one new session")
        callbacks[0].sample(sample(200_000)); await settle()
        check(node.latest?.sample.sequence==99_999,"old generation is ignored")
        node.pause(); callbacks[1].sample(sample(300_000)); await settle()
        check(node.userPaused && node.state == .paused,"user pause cancels delivery")

        var retries: [FakeSession] = []
        let retryNode=NodeModel(profile:profile,demo:false,collector:"",history:nil,retryDelay:.milliseconds(5),loadHistory:false,factory:{ _,_,cb in
            let s=FakeSession(); s.onStart={ cb.exit(SessionFailure("offline")) }; retries.append(s); return s
        })
        retryNode.connect()
        for _ in 0..<100 { if retries.count==5 { break }; try? await Task.sleep(for:.milliseconds(5)) }
        await settle()
        check(retries.count==5 && retryNode.state == .failed("offline"),"initial attempt plus exactly four retries")
        retryNode.stop(); await settle(); check(retries.count==5,"stop cancels further retries")

        var healthyAttempts = 0
        let healthyNode=NodeModel(profile:profile,demo:false,collector:"",history:nil,retryDelay:.milliseconds(5),loadHistory:false,factory:{ _,_,cb in
            healthyAttempts += 1; let s=FakeSession(); let attempt=healthyAttempts
            s.onStart={
                if attempt < 5 { cb.exit(SessionFailure("offline")) }
                else if attempt == 5 {
                    for i in 0..<10 { cb.sample(sample(i)) }
                    cb.exit(SessionFailure("offline after healthy interval"))
                }
            }; return s
        })
        healthyNode.connect()
        for _ in 0..<100 { if healthyAttempts >= 6 { break }; try? await Task.sleep(for:.milliseconds(5)) }
        check(healthyAttempts==6,"ten valid ingress samples reset retries even when UI delivery coalesces")
        healthyNode.stop()

        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let model=TelemetryModel(base:root,collectorSource:"fixture",restore:false,observeWorkspace:false)
        check(!model.demo,"first launch uses real servers instead of demonstration")
        model.enterRealMode()
        for _ in 0..<100 { if !model.loading { break }; try? await Task.sleep(for:.milliseconds(5)) }
        try model.add(profile)
        model.nodes[0].pause()
        let saved=try JSONDecoder().decode(LaunchSettings.self,from:Data(contentsOf:root.appendingPathComponent("launch.json")))
        check(saved.pausedNodeIDs==["test"] && !saved.autoConnect,"individual pause persists without enabling autoconnect")
        let restored=TelemetryModel(base:root,collectorSource:"fixture",restore:true,observeWorkspace:false)
        for _ in 0..<100 { if !restored.loading { break }; try? await Task.sleep(for:.milliseconds(5)) }
        check(restored.nodes.first?.userPaused==true,"pause survives restart")
        model.nodes=[node]; node.connect(); let count=sessions.count
        model.connectAll(); await settle()
        check(sessions.count==count,"connect all preserves healthy sessions")
        node.pause()
        model.connectAll(); await settle()
        check(sessions.count==count && node.userPaused,"automatic connect all respects individual pause")
        model.connectAll(includePaused:true); await settle()
        check(sessions.count==count+1 && !node.userPaused,"explicit connect all resumes individually paused nodes")
        model.connectAll(includePaused:true); await settle()
        check(sessions.count==count+1,"repeated explicit connect all preserves active sessions")
        model.sleep(); node.pause(); model.wake(); await settle()
        check(sessions.count==count+1 && node.userPaused,"wake does not resume an explicitly paused node")
        let other=root.appendingPathComponent("aliases")
        try FileManager.default.createDirectory(at:other,withIntermediateDirectories:true)
        let sameAlias=[NodeProfile(id:"A",name:"A",region:"",sshAlias:"node",sshConfigPath:"/fixture/A.conf"),
                       NodeProfile(id:"B",name:"B",region:"",sshAlias:"node",sshConfigPath:"/fixture/B.conf")]
        try JSONEncoder().encode(sameAlias).write(to:other.appendingPathComponent("nodes.json"))
        let aliasModel=TelemetryModel(base:other,collectorSource:"fixture",restore:false,observeWorkspace:false)
        aliasModel.enterRealMode()
        for _ in 0..<100 { if !aliasModel.loading { break }; try? await Task.sleep(for:.milliseconds(5)) }
        check(aliasModel.nodes.count==2,"same alias in distinct existing config files remains loadable")
        aliasModel.stopAll()
        model.stopAll(rememberPause:true); restored.stopAll()
        print("App model checks: \(checks); failures: \(failures)")
        if failures != 0 { exit(1) }
    }
}
