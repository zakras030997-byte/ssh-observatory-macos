import Foundation
import Darwin
import TelemetryCore

/// One app-owned sftp process using only the app's current VPN→Tor route.
final class ProtectedSFTP: @unchecked Sendable {
    private let lock=NSLock()
    private var process:Process?
    private var cancelled=false, expired=false
    func cancel() {
        lock.lock();cancelled=true;let child=process;lock.unlock()
        if child?.isRunning == true {child?.terminate()}
    }
    static func quoted(_ path:String)throws->String {
        guard path.hasPrefix("/"),path.utf8.count<=2048,!path.unicodeScalars.contains(where:{$0.value<32 || $0.value==127}) else {throw HubFailure.invalid_request}
        return "\""+path.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"")+"\""
    }
    static func arguments(profile:NodeProfile,port:Int)throws->[String] {
        try profile.validate();guard (1024...65535).contains(port) else {throw HubFailure.unavailable}
        let config=profile.sshConfigPath.map{["-F",$0]} ?? []
        return ["-q","-b","-"]+config+["-o","ProxyCommand=/usr/bin/nc -X 5 -x 127.0.0.1:\(port) %h %p",
            "-o","ProxyJump=none","-o","BindInterface=none","-o","StrictHostKeyChecking=yes","-o","BatchMode=yes",
            "-o","UpdateHostKeys=no","-o","ForwardAgent=no","-o","ClearAllForwardings=yes","-o","ControlMaster=no",
            "-o","ControlPath=none","-o","PermitLocalCommand=no","-o","RemoteCommand=none","-o","RequestTTY=no",
            "-o","ConnectTimeout=30","-o","ConnectionAttempts=1","-o","ServerAliveInterval=5","-o","ServerAliveCountMax=2",profile.sshAlias]
    }
    func run(arguments:[String],batch:String) async throws {
        try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
            DispatchQueue.global(qos:.utility).async { [self] in
                let child=Process(),stdin=Pipe(),output=Pipe()
                child.executableURL=URL(fileURLWithPath:"/usr/bin/sftp");child.arguments=arguments
                child.standardInput=stdin;child.standardOutput=output;child.standardError=output
                var environment=ProcessInfo.processInfo.environment;environment["LC_ALL"]="C";environment["SSH_ASKPASS_REQUIRE"]="never";child.environment=environment
                lock.lock()
                if cancelled {lock.unlock();continuation.resume(throwing:HubFailure.unavailable);return}
                process=child
                do {try child.run()} catch {process=nil;lock.unlock();continuation.resume(throwing:HubFailure.upstream_error);return}
                lock.unlock()
                let timer=DispatchWorkItem { [self] in
                    lock.lock();expired=true;let child=process;lock.unlock()
                    if child?.isRunning == true {child?.terminate()}
                }
                DispatchQueue.global().asyncAfter(deadline:.now()+150,execute:timer)
                let fd=stdin.fileHandleForWriting.fileDescriptor
                if fcntl(fd,F_SETNOSIGPIPE,1) == -1 {cancel()}
                else {do {try stdin.fileHandleForWriting.write(contentsOf:Data((batch+"\n").utf8));try stdin.fileHandleForWriting.close()} catch {cancel()}}
                var count=0,oversize=false
                while true {
                    let data=output.fileHandleForReading.readData(ofLength:4096)
                    if data.isEmpty {break};count += data.count
                    if count>16384 {oversize=true;cancel();break}
                }
                child.waitUntilExit();timer.cancel()
                lock.lock();let failed=cancelled || expired || oversize || child.terminationStatus != 0;process=nil;lock.unlock()
                if failed {continuation.resume(throwing:HubFailure.upstream_error)} else {continuation.resume()}
            }
        }
    }
}
