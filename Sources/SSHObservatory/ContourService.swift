import AppKit
import Foundation
import Darwin

/// One launchd-owned service. The GUI never owns a second node transport.
enum ContourService {
    static let label="org.sshobservatory.security-contour"
    static var target:String { "gui/\(getuid())/\(label)" }
    static func launchctl(_ args:[String]) -> Bool {
        let p=Process();p.executableURL=URL(fileURLWithPath:"/bin/launchctl");p.arguments=args
        let errorPipe=Pipe();p.standardOutput=FileHandle.nullDevice;p.standardError=errorPipe
        do {
            try p.run();let message=errorPipe.fileHandleForReading.readDataToEndOfFile();p.waitUntilExit()
            if p.terminationStatus != 0 { recordLaunchFailure(args.first ?? "unknown",Int(p.terminationStatus),String(decoding:message.prefix(1024),as:UTF8.self)) }
            return p.terminationStatus==0
        } catch {recordLaunchFailure(args.first ?? "unknown",-1,String(describing:error));return false}
    }
    private static func recordLaunchFailure(_ action:String,_ code:Int,_ detail:String) {
        let url=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/SSH Observatory/service-launch-status.json")
        if let data=try? JSONSerialization.data(withJSONObject:["action":action,"code":code,"detail":detail]) {
            try? data.write(to:url,options:.atomic);try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        }
    }
    static func ensureStarted() {
        guard launchctl(["print",target]) else {
            let plist=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist").path
            if launchctl(["bootstrap","gui/\(getuid())",plist]) {_=launchctl(["kickstart",target])}
            return
        }
        _=launchctl(["kickstart",target])
    }
    static func stop() { _=launchctl(["bootout",target]) }
    @MainActor static func run() {
        signal(SIGPIPE,SIG_IGN)
        let app=NSApplication.shared;app.setActivationPolicy(.prohibited)
        let base=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/SSH Observatory")
        do {try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])} catch{exit(1)}
        let fd=open(base.appendingPathComponent("contour.lock").path,O_CREAT|O_RDWR|O_NOFOLLOW,0o600)
        guard fd>=0,flock(fd,LOCK_EX|LOCK_NB)==0 else {exit(0)}
        let model=TelemetryModel(),home=HomeEgressModel(),hub=ObservatoryHub()
        hub.start(telemetry:model,home:home)
        guard hub.isListening else {exit(1)}
        model.startProtectedRoute()
        signal(SIGTERM,SIG_IGN);signal(SIGINT,SIG_IGN)
        let sources=[SIGTERM,SIGINT].map { n -> DispatchSourceSignal in
            let s=DispatchSource.makeSignalSource(signal:n,queue:.main)
            s.setEventHandler {hub.stop();model.stopAll();model.stopProtectedRoute();home.disconnect();app.stop(nil);CFRunLoopStop(CFRunLoopGetMain())}
            s.resume();return s
        }
        withExtendedLifetime((model,home,hub,sources)) {app.run()}
        Darwin.close(fd)
    }
}

/// Same private IPC contract as MCP, with owner and inode checks on both sides.
enum ContourClient {
    static func call(_ method:String,_ params:[String:Any]=[:],socketURL:URL? = nil) throws -> [String:Any] {
        let url=socketURL ?? ObservatoryHub.socketURL
        func checked() throws -> stat {
            var st=stat(),parent=stat()
            guard lstat(url.deletingLastPathComponent().path,&parent)==0,
                  parent.st_mode & S_IFMT == S_IFDIR,parent.st_uid==getuid(),parent.st_mode & 0o077==0,
                  lstat(url.path,&st)==0,st.st_mode & S_IFMT == S_IFSOCK,
                  st.st_uid==getuid(),st.st_mode & 0o777==0o600 else {throw HubFailure.unavailable}
            return st
        }
        let before=try checked(),fd=socket(AF_UNIX,SOCK_STREAM,0)
        guard fd>=0 else {throw HubFailure.unavailable};defer{Darwin.close(fd)}
        _=fcntl(fd,F_SETNOSIGPIPE,1)
        var timeout=timeval(tv_sec:8,tv_usec:0)
        withUnsafePointer(to:&timeout) { p in
            _=setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,p,socklen_t(MemoryLayout<timeval>.size))
            _=setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,p,socklen_t(MemoryLayout<timeval>.size))
        }
        var a=sockaddr_un();a.sun_family=sa_family_t(AF_UNIX);a.sun_len=UInt8(MemoryLayout<sockaddr_un>.size)
        let path=Array(url.path.utf8)+[0];guard path.count<=MemoryLayout.size(ofValue:a.sun_path) else {throw HubFailure.unavailable}
        withUnsafeMutableBytes(of:&a.sun_path){$0.copyBytes(from:path)}
        let connected=withUnsafePointer(to:&a){p in p.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.connect(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size))}}
        var uid:uid_t=0,gid:gid_t=0
        let after=try checked()
        guard connected==0,getpeereid(fd,&uid,&gid)==0,uid==getuid(),before.st_ino==after.st_ino,before.st_dev==after.st_dev else {throw HubFailure.unavailable}
        let id=UUID().uuidString
        let data=try JSONSerialization.data(withJSONObject:["version":1,"id":id,"method":method,"params":params])+Data([10])
        guard data.count<=65536 else {throw HubFailure.invalid_request}
        try data.withUnsafeBytes { bytes in
            var sent=0
            while sent<bytes.count {let n=Darwin.send(fd,bytes.baseAddress!.advanced(by:sent),bytes.count-sent,0);guard n>0 else{throw HubFailure.unavailable};sent+=n}
        }
        var reply=Data(),buffer=[UInt8](repeating:0,count:8192)
        while !reply.contains(10) {
            let n=recv(fd,&buffer,buffer.count,0);guard n>0 else {throw HubFailure.unavailable}
            reply.append(contentsOf:buffer.prefix(n));guard reply.count<=2*1024*1024+1 else {throw HubFailure.oversized_response}
        }
        guard reply.last==10,reply.filter({$0==10}).count==1,
              let d=try JSONSerialization.jsonObject(with:reply) as? [String:Any],d["id"] as? String==id,
              d["ok"] as? Bool==true,let result=d["result"] as? [String:Any] else {throw HubFailure.upstream_error}
        return result
    }
}
