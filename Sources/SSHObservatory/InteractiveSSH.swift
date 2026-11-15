import Foundation
import Darwin
import TelemetryCore

/// One bounded app-owned interactive SSH process. The process never falls back
/// to a direct route; its caller must register revocation before starting it.
final class InteractiveSSH: @unchecked Sendable {
    let id=UUID().uuidString
    let nodeID:String
    private let lock=NSLock()
    private let task=Process(), input=Pipe(), output=Pipe()
    private var buffer=Data(), ready=false, overflow=false, closed=false
    private let marker:String
    private var observedExit:Int32?
    private var lastUse=Date()
    init(profile:NodeProfile,port:Int) throws {
        nodeID=profile.id
        marker="__OBS_READY_\(UUID().uuidString.replacingOccurrences(of:"-",with:""))__"
        let script="""
import os,socket,sys
if CONFIG.get('expectedHostname') and socket.gethostname()!=CONFIG['expectedHostname']:sys.exit(42)
os.write(1,b'\(marker)')
os.execv('/bin/sh',['/bin/sh','-i'])
"""
        var arguments=try SSHSession.arguments(profile:profile,collector:script,protectedTorPort:port)
        guard let t=arguments.firstIndex(of:"-T"),let tty=arguments.firstIndex(of:"RequestTTY=no") else { throw HubFailure.invalid_request }
        arguments[t]="-tt";arguments[tty]="RequestTTY=force"
        task.executableURL=URL(fileURLWithPath:"/usr/bin/ssh");task.arguments=arguments
        task.standardInput=input;task.standardOutput=output;task.standardError=output
        var environment=ProcessInfo.processInfo.environment
        environment["TERM"]="xterm";environment["LC_ALL"]="C";environment["SSH_ASKPASS_REQUIRE"]="never"
        task.environment=environment
    }
    func start() throws {
        output.fileHandleForReading.readabilityHandler={ [weak self] handle in self?.receive(handle.availableData) }
        task.terminationHandler={ [weak self] process in
            guard let self else{return};self.lock.lock();self.observedExit=process.terminationStatus;self.lock.unlock()
        }
        do {
            try task.run()
            let fd=input.fileHandleForWriting.fileDescriptor
            guard fcntl(fd,F_SETFL,fcntl(fd,F_GETFL)|O_NONBLOCK) != -1,
                  fcntl(fd,F_SETNOSIGPIPE,1) != -1 else { close();throw HubFailure.unavailable }
        } catch { output.fileHandleForReading.readabilityHandler=nil;throw error }
    }
    private func receive(_ data:Data) {
        guard !data.isEmpty else{return}
        lock.lock()
        if closed {lock.unlock();return}
        buffer.append(data)
        if !ready,let match=buffer.range(of:Data(marker.utf8)) {
            buffer.removeSubrange(match);ready=true
        }
        if buffer.count>65536 {overflow=true;closed=true;lock.unlock();terminate();return}
        lock.unlock()
    }
    func read(limit:Int)->[String:Any] {
        lock.lock();defer{lock.unlock()};lastUse=Date()
        let count = ready || observedExit != nil || closed ? min(limit,buffer.count) : 0
        let data=Data(buffer.prefix(count));buffer.removeFirst(count)
        let state=overflow ? "overflow" : (closed || observedExit != nil ? "closed" : (ready ? "ready":"connecting"))
        var result:[String:Any]=["session_id":id,"node_id":nodeID,"state":state,"data_base64":data.base64EncodedString(),"remaining":buffer.count]
        if let status=observedExit {result["exit_code"]=Int(status)}
        return result
    }
    func write(_ data:Data)throws->Int {
        lock.lock();let canWrite=ready && !closed && observedExit == nil;lastUse=Date();lock.unlock()
        guard canWrite else {throw HubFailure.unavailable}
        let count=data.withUnsafeBytes { Darwin.write(input.fileHandleForWriting.fileDescriptor,$0.baseAddress,data.count) }
        guard count>=0 else {throw HubFailure.unavailable};return count
    }
    var expired:Bool {lock.lock();defer{lock.unlock()};return Date().timeIntervalSince(lastUse)>900}
    func close() {lock.lock();let doClose = !closed;closed=true;lock.unlock();if doClose {terminate()}}
    private func terminate() { output.fileHandleForReading.readabilityHandler=nil;try? input.fileHandleForWriting.close();if task.isRunning {task.terminate()} }
    deinit { close() }
}
