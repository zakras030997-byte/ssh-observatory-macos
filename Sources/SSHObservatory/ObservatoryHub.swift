import Foundation
import AppKit
import Darwin
import TelemetryCore
import CoreFoundation

enum HubFailure: String, Error {
    case unavailable, invalid_request, unknown_method, unknown_node, demo_mode, busy
    case home_not_connected, home_route_conflict, home_session_changed, upstream_error, oversized_response
}

/// Private IPC belongs to the running GUI; the MCP adapter owns no SSH/API credentials.
final class ObservatorySocket: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private let slots = DispatchSemaphore(value: 4)
    private let url: URL
    private let handler: @MainActor (Data) async -> Data
    init(url: URL, handler: @escaping @MainActor (Data) async -> Data) { self.url=url; self.handler=handler }
    func start() throws {
        let fm=FileManager.default, directory=url.deletingLastPathComponent()
        try fm.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let attributes=try fm.attributesOfItem(atPath:directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o077 == 0 else { throw HubFailure.unavailable }
        var address=sockaddr_un(); address.sun_family=sa_family_t(AF_UNIX)
        address.sun_len=UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes=Array(url.path.utf8)+[0]
        guard bytes.count <= MemoryLayout.size(ofValue:address.sun_path) else { throw HubFailure.unavailable }
        withUnsafeMutableBytes(of:&address.sun_path) { $0.copyBytes(from:bytes) }
        if fm.fileExists(atPath:url.path) {
            let info=try fm.attributesOfItem(atPath:url.path)
            guard info[.type] as? FileAttributeType == .typeSocket,
                  (info[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw HubFailure.unavailable }
            let probe=socket(AF_UNIX,SOCK_STREAM,0)
            let active=withUnsafePointer(to:&address) { p in p.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.connect(probe,$0,socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            Darwin.close(probe)
            guard active != 0 else { throw HubFailure.busy }
            try fm.removeItem(at:url)
        }
        let fd=socket(AF_UNIX,SOCK_STREAM,0); guard fd>=0 else { throw HubFailure.unavailable }
        let result=withUnsafePointer(to:&address) { p in p.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result==0 else { Darwin.close(fd); throw HubFailure.unavailable }
        guard chmod(url.path,0o600)==0,listen(fd,8)==0 else { Darwin.close(fd); try? fm.removeItem(at:url); throw HubFailure.unavailable }
        lock.lock(); descriptor=fd; lock.unlock()
        DispatchQueue.global(qos:.utility).async { [self] in
            while isOpen(fd) {
                let peer=accept(fd,nil,nil)
                if peer<0 { if errno==EINTR {continue}; break }
                guard slots.wait(timeout:.now()) == .success else { Darwin.close(peer); continue }
                DispatchQueue.global(qos:.utility).async { [self] in receive(peer) }
            }
        }
    }
    private func isOpen(_ fd:Int32)->Bool { lock.lock(); defer{lock.unlock()};return descriptor==fd }
    func stop() {
        lock.lock(); let fd=descriptor;descriptor = -1;lock.unlock()
        if fd>=0 {shutdown(fd,SHUT_RDWR);Darwin.close(fd);try? FileManager.default.removeItem(at:url)}
    }
    private func receive(_ peer:Int32) {
        var uid:uid_t=0,gid:gid_t=0
        guard getpeereid(peer,&uid,&gid)==0,uid==getuid() else {Darwin.close(peer);slots.signal();return}
        var timeout=timeval(tv_sec:5,tv_usec:0)
        _=withUnsafePointer(to:&timeout){setsockopt(peer,SOL_SOCKET,SO_RCVTIMEO,$0,socklen_t(MemoryLayout<timeval>.size))}
        var data=Data(),buffer=[UInt8](repeating:0,count:4096)
        while data.count<=65536 {
            let count=recv(peer,&buffer,buffer.count,0)
            if count<=0 {Darwin.close(peer);slots.signal();return}
            data.append(contentsOf:buffer.prefix(count))
            if data.contains(10) {break}
        }
        guard data.count<=65536,let end=data.firstIndex(of:10),end==data.index(before:data.endIndex) else {Darwin.close(peer);slots.signal();return}
        data.removeLast()
        Task { [self] in
            let response=await handler(data)+Data([10])
            var sendTimeout=timeval(tv_sec:5,tv_usec:0)
            _=withUnsafePointer(to:&sendTimeout){setsockopt(peer,SOL_SOCKET,SO_SNDTIMEO,$0,socklen_t(MemoryLayout<timeval>.size))}
            response.withUnsafeBytes { bytes in
                var sent=0
                while sent<bytes.count {
                    let count=Darwin.send(peer,bytes.baseAddress!.advanced(by:sent),bytes.count-sent,0)
                    if count<=0 {break};sent+=count
                }
            }
            Darwin.close(peer);slots.signal()
        }
    }
    deinit {stop()}
}

private final class HubNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void) {completionHandler(nil)}
}

@MainActor final class ObservatoryHub: ObservableObject {
    @Published private(set) var status="MCP не подключён"
    @Published private(set) var requests=0
    private weak var telemetry:TelemetryModel?
    private weak var home:HomeEgressModel?
    private var socket:ObservatorySocket?
    private var inspecting=Set<String>()
    private var interactive:[String:(InteractiveSSH,UUID)]=[:]
    private var sessionTimer:DispatchSourceTimer?
    private let instance=UUID().uuidString
    private let endpoint:URL
    nonisolated static var socketURL:URL {FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/SSH Observatory/hub.sock")}
    init(socketURL:URL? = nil){endpoint=socketURL ?? Self.socketURL}
    func start(telemetry:TelemetryModel,home:HomeEgressModel) {
        guard socket==nil else{return};self.telemetry=telemetry;self.home=home
        let listener=ObservatorySocket(url:endpoint){[weak self] data in
            guard let self else{return Data("{\"ok\":false,\"error\":{\"code\":\"unavailable\"}}".utf8)}
            return await self.receive(data)
        }
        do {
            try listener.start();socket=listener;status="MCP доступен · локально"
            let timer=DispatchSource.makeTimerSource(queue:.main)
            timer.schedule(deadline:.now()+60,repeating:60)
            timer.setEventHandler { [weak self] in Task { @MainActor [weak self] in self?.pruneInteractive() } }
            timer.resume();sessionTimer=timer
        }
        catch {status="MCP недоступен · проверьте локальное подключение"}
    }
    var isListening:Bool {socket != nil}
    func stop(){
        sessionTimer?.cancel();sessionTimer=nil
        for (_,entry) in interactive {entry.0.close();telemetry?.unregisterProtected(entry.1)}
        interactive.removeAll();socket?.stop();socket=nil;status="MCP отключён"
    }
    private func pruneInteractive() {
        let expired=interactive.filter{$0.value.0.expired}.map(\.key)
        for id in expired {if let entry=interactive.removeValue(forKey:id) {entry.0.close();telemetry?.unregisterProtected(entry.1)}}
    }
    func receive(_ data:Data) async -> Data {
        var id="",method="",node="",ok=false
        defer {audit(method:method,node:node,ok:ok)}
        do {
            guard let envelope=try JSONSerialization.jsonObject(with:data) as? [String:Any],
                  Set(envelope.keys)==Set(["version","id","method","params"]),
                  let version=envelope["version"] as? NSNumber,CFGetTypeID(version) != CFBooleanGetTypeID(),version.intValue==1,version.doubleValue==1,
                  let requestID=envelope["id"] as? String,UUID(uuidString:requestID) != nil,
                  let action=envelope["method"] as? String,action.count<=64,
                  let params=envelope["params"] as? [String:Any] else {throw HubFailure.invalid_request}
            id=requestID;method=action;node=params["node_id"] as? String ?? ""
            let result=try await dispatch(action,params)
            let response=try JSONSerialization.data(withJSONObject:["id":id,"ok":true,"result":result],options:[.sortedKeys])
            guard response.count<=2*1024*1024 else{throw HubFailure.oversized_response}
            ok=true;requests+=1;return response
        }catch {
            let code=(error as? HubFailure)?.rawValue ?? "upstream_error"
            return (try? JSONSerialization.data(withJSONObject:["id":id,"ok":false,"error":["code":code,"message":code]],options:[.sortedKeys])) ?? Data()
        }
    }
    private func validate(_ params:[String:Any],keys:Set<String>) throws {guard Set(params.keys)==keys else{throw HubFailure.invalid_request}}
    private func node(_ id:String)throws->NodeModel {
        guard let telemetry,!telemetry.demo else{throw HubFailure.demo_mode}
        guard !telemetry.loading else{throw HubFailure.busy}
        guard let node=telemetry.nodes.first(where:{$0.id==id}) else{throw HubFailure.unknown_node};return node
    }
    private func nodeInfo(_ node:NodeModel)throws->[String:Any] {
        var result:[String:Any]=["node_id":node.id,"name":node.profile.name,"region":node.profile.region,"state":node.state.title,"fresh":node.fresh,"paused":node.userPaused,"source":"running_observatory","demo":node.demo]
        if let point=node.latest {
            result["sample"]=try JSONSerialization.jsonObject(with:JSONEncoder().encode(point.sample))
            result["received_at"]=point.receivedAt.timeIntervalSince1970
            result["age_seconds"]=max(0,Date().timeIntervalSince(point.sample.date))
        }else{result["sample"]=NSNull()}
        return result
    }
    private func homeStatus()->[String:Any] {
        guard let home else{return ["connected":false]}
        return ["connected":home.session != nil,"connecting":home.connecting,"route":home.route.rawValue,"mode":home.mode.rawValue,"network":home.networkStatus,"state":home.status,"source":"running_observatory"]
    }
    private func dispatch(_ method:String,_ p:[String:Any]) async throws->[String:Any] {
        switch method {
        case "hub.status":
            try validate(p,keys:[])
            return ["service":"Security Contour — VPN → Tor → SSH","service_version":"0.7.0","route":["confirmed":telemetry?.routeEvidence.confirmed ?? false,"observed_at":telemetry?.routeEvidence.observedAt?.timeIntervalSince1970 ?? 0],"program":"SSH Observatory","instance_id":instance,"pid":ProcessInfo.processInfo.processIdentifier,"protocol":1,"timestamp":Date().timeIntervalSince1970,"demo":telemetry?.demo ?? false,"loading":telemetry?.loading ?? true,"node_count":telemetry?.nodes.count ?? 0,"home":homeStatus(),"scope":"live telemetry, fixed inspection and bounded SSH commands on registered VPN nodes; Home overview/audit"]
        case "node.pause":
            try validate(p,keys:["node_id"]);guard let id=p["node_id"] as? String else{throw HubFailure.invalid_request}
            let value=try node(id);value.pause();return try nodeInfo(value)
        case "node.add":
            try validate(p,keys:["profile"]);guard let profile=p["profile"],let telemetry else{throw HubFailure.invalid_request}
            let value=try JSONDecoder().decode(NodeProfile.self,from:JSONSerialization.data(withJSONObject:profile))
            try telemetry.add(value);return ["node_id":value.id]
        case "nodes.list":
            try validate(p,keys:[]);guard let telemetry else{throw HubFailure.unavailable}
            return ["nodes":try telemetry.nodes.map{try nodeInfo($0)},"home":homeStatus(),"timestamp":Date().timeIntervalSince1970]
        case "node.telemetry","node.connect":
            try validate(p,keys:["node_id"]);guard let id=p["node_id"] as? String else{throw HubFailure.invalid_request}
            let value=try node(id)
            if method=="node.connect" {value.connect()}
            return try nodeInfo(value)
        case "node.inspect":
            try validate(p,keys:["node_id","check"])
            guard let id=p["node_id"] as? String,let check=p["check"] as? String,["identity","resources","services","containers"].contains(check) else{throw HubFailure.invalid_request}
            guard !inspecting.contains(id) else{throw HubFailure.busy};inspecting.insert(id);defer{inspecting.remove(id)}
            let script=Self.inspection(check:check)
            let arguments:[String],expected:String?
            if id=="HOME" {
                guard let access=try? HomeAccessConfiguration.load() else {throw HubFailure.unavailable}
                expected=access.expectedHostname
                let config:[String:Any]=["nodeID":"HOME","expectedHostname":access.expectedHostname,"units":access.units]
                let encoded=try JSONSerialization.data(withJSONObject:config).base64EncodedString()
                let source="import json,base64\nCONFIG=json.loads(base64.b64decode('\(encoded)'))\n"+script
                let command="python3 -u -B -c 'exec(__import__(\"base64\").b64decode(\"\(Data(source.utf8).base64EncodedString())\"))'"
                arguments=(home?.route ?? .lan).commandArguments(command)
            }else {
                let value=try node(id);expected=value.profile.expectedHostname
                guard let port=telemetry?.protectedPort else { throw HubFailure.unavailable }
                arguments=try SSHSession.arguments(profile:value.profile,collector:script,protectedTorPort:port)
            }
            let runner=HomeEgressSSHCommand()
            let registration:UUID?
            if id == "HOME" { registration=nil }
            else {
                guard let token=telemetry?.registerProtected({ runner.cancel() }) else { throw HubFailure.unavailable }
                registration=token
            }
            defer { if let registration { telemetry?.unregisterProtected(registration) } }
            let raw=try await runner.run(arguments:arguments,phase:.hostname,timeout:id == "HOME" ? 20 : 45)
            guard let result=try JSONSerialization.jsonObject(with:raw) as? [String:Any],result["node_id"] as? String==id,
                  let host=result["hostname"] as? String,expected.map({host==$0}) ?? true else{throw HubFailure.upstream_error}
            return result
        case "node.exec":
            guard Set(p.keys)==Set(["node_id","command"]) || Set(p.keys)==Set(["node_id","command","timeout_seconds"]) else { throw HubFailure.invalid_request }
            guard let id=p["node_id"] as? String,let command=p["command"] as? String,
                  !command.isEmpty,command.utf8.count<=4096,!command.contains("\0") else { throw HubFailure.invalid_request }
            let timeout:Int
            if let requested=p["timeout_seconds"] {
                guard let number=requested as? NSNumber,CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue==Double(number.intValue),(1...120).contains(number.intValue) else { throw HubFailure.invalid_request }
                timeout=number.intValue
            } else { timeout=30 }
            let value=try node(id)
            guard !inspecting.contains(id) else { throw HubFailure.busy }
            guard let port=telemetry?.protectedPort else { throw HubFailure.unavailable }
            inspecting.insert(id);defer { inspecting.remove(id) }
            let script=Self.remoteCommand(command,timeout:timeout)
            let arguments=try SSHSession.arguments(profile:value.profile,collector:script,protectedTorPort:port)
            let runner=HomeEgressSSHCommand()
            guard let token=telemetry?.registerProtected({runner.cancel()}) else { throw HubFailure.unavailable }
            defer { telemetry?.unregisterProtected(token) }
            let raw=try await runner.run(arguments:arguments,phase:.hostname,timeout:TimeInterval(timeout+45),keepInputOpen:true,outputLimit:32768)
            guard let result=try JSONSerialization.jsonObject(with:raw) as? [String:Any],
                  let hostname=result["hostname"] as? String,
                  value.profile.expectedHostname.map({$0==hostname}) ?? true,
                  let code=result["exit_code"] as? Int, let truncated=result["truncated"] as? Bool,
                  let timedOut=result["timed_out"] as? Bool,
                  let out=result["stdout"] as? String,let err=result["stderr"] as? String,
                  let outBytes=Data(base64Encoded:out),let errBytes=Data(base64Encoded:err),
                  outBytes.count<=8192,errBytes.count<=8192 else { throw HubFailure.upstream_error }
            return ["node_id":id,"hostname":hostname,"exit_code":code,"stdout":String(decoding:outBytes,as:UTF8.self),"stderr":String(decoding:errBytes,as:UTF8.self),"truncated":truncated,"timed_out":timedOut]
        case "node.session.open":
            try validate(p,keys:["node_id"])
            guard let id=p["node_id"] as? String else {throw HubFailure.invalid_request}
            let value=try node(id)
            pruneInteractive()
            guard interactive.count<8 else {throw HubFailure.busy}
            guard let port=telemetry?.protectedPort else {throw HubFailure.unavailable}
            let session=try InteractiveSSH(profile:value.profile,port:port)
            guard let token=telemetry?.registerProtected({session.close()}) else {throw HubFailure.unavailable}
            do {try session.start()} catch {telemetry?.unregisterProtected(token);throw error}
            interactive[session.id]=(session,token)
            return ["session_id":session.id,"node_id":id,"state":"connecting"]
        case "node.session.read":
            try validate(p,keys:["session_id"])
            guard let id=p["session_id"] as? String,UUID(uuidString:id) != nil else {throw HubFailure.invalid_request}
            guard let session=interactive[id]?.0 else {throw HubFailure.unavailable}
            return session.read(limit:16384)
        case "node.session.write":
            try validate(p,keys:["session_id","data_base64"])
            guard let id=p["session_id"] as? String,UUID(uuidString:id) != nil,
                  let encoded=p["data_base64"] as? String,let data=Data(base64Encoded:encoded),!data.isEmpty,data.count<=4096 else {throw HubFailure.invalid_request}
            guard let session=interactive[id]?.0 else {throw HubFailure.unavailable}
            return ["session_id":id,"written":try session.write(data)]
        case "node.session.close":
            try validate(p,keys:["session_id"])
            guard let id=p["session_id"] as? String,UUID(uuidString:id) != nil else {throw HubFailure.invalid_request}
            guard let entry=interactive.removeValue(forKey:id) else {throw HubFailure.unavailable}
            entry.0.close();telemetry?.unregisterProtected(entry.1)
            return ["session_id":id,"state":"closed"]
        case "node.file.transfer":
            try validate(p,keys:["node_id","direction","local_path","remote_path","overwrite"])
            guard let id=p["node_id"] as? String,let direction=p["direction"] as? String,
                  let local=p["local_path"] as? String,let remote=p["remote_path"] as? String,
                  let overwrite=p["overwrite"] as? Bool,CFGetTypeID(p["overwrite"] as CFTypeRef)==CFBooleanGetTypeID(),
                  ["upload","download"].contains(direction) else {throw HubFailure.invalid_request}
            let value=try node(id)
            _=try ProtectedSFTP.quoted(local);_=try ProtectedSFTP.quoted(remote)
            guard !inspecting.contains(id) else {throw HubFailure.busy}
            // Host key is pinned by SSH; also verify the expected hostname before transfer.
            _=try await dispatch("node.inspect",["node_id":id,"check":"identity"])
            guard let port=telemetry?.protectedPort else {throw HubFailure.unavailable}
            let runner=ProtectedSFTP()
            guard let token=telemetry?.registerProtected({runner.cancel()}) else {throw HubFailure.unavailable}
            defer {telemetry?.unregisterProtected(token)}
            let arguments=try ProtectedSFTP.arguments(profile:value.profile,port:port)
            if direction=="upload" {
                // Explicit consent to potential remote replacement is mandatory.
                guard overwrite else {throw HubFailure.invalid_request}
                var metadata=stat()
                guard lstat(local,&metadata)==0,(metadata.st_mode & S_IFMT)==S_IFREG,metadata.st_size<=268435456 else {throw HubFailure.invalid_request}
                let batch="put \(try ProtectedSFTP.quoted(local)) \(try ProtectedSFTP.quoted(remote))"
                try await runner.run(arguments:arguments,batch:batch)
            } else {
                guard !overwrite else {throw HubFailure.invalid_request}
                let destination=URL(fileURLWithPath:local),parent=destination.deletingLastPathComponent()
                let temporary=parent.appendingPathComponent(".observatory-\(UUID().uuidString).partial").path
                let fd=open(temporary,O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW,0o600)
                guard fd>=0 else {throw HubFailure.upstream_error};Darwin.close(fd)
                defer { _=unlink(temporary) }
                let batch="get \(try ProtectedSFTP.quoted(remote)) \(try ProtectedSFTP.quoted(temporary))"
                try await runner.run(arguments:arguments,batch:batch)
                // Hard-link publication is atomic and never replaces an existing path.
                guard link(temporary,local)==0 else {throw HubFailure.upstream_error}
            }
            return ["node_id":id,"direction":direction,"status":"complete"]
        case "home.status":try validate(p,keys:[]);return homeStatus()
        case "home.connect":
            try validate(p,keys:["route"]);guard let route=p["route"] as? String,let choice=HomeEgressRoute(rawValue:route),let home else{throw HubFailure.invalid_request}
            if home.session != nil || home.connecting {guard home.route==choice else{throw HubFailure.home_route_conflict}}
            else{home.connect(route:choice)}
            return homeStatus()
        case "home.overview","home.audit":
            try validate(p,keys:[])
            return try await homeRead(method=="home.overview" ? "/api/v1/overview":"/api/v1/audit")
        default:throw HubFailure.unknown_method
        }
    }
    private func homeRead(_ path:String)async throws->[String:Any] {
        guard let current=home?.session,current.credentials.expiresAt>Date() else{throw HubFailure.home_not_connected}
        let config=URLSessionConfiguration.ephemeral;config.httpCookieStorage=nil;config.httpShouldSetCookies=false;config.urlCache=nil;config.timeoutIntervalForRequest=15
        let session=URLSession(configuration:config,delegate:HubNoRedirect(),delegateQueue:nil);defer{session.invalidateAndCancel()}
        var request=URLRequest(url:current.baseURL.appendingPathComponent(String(path.dropFirst())))
        request.setValue("home_egress_session=\(current.credentials.sessionToken)",forHTTPHeaderField:"Cookie")
        let (bytes,response)=try await session.bytes(for:request)
        guard let http=response as? HTTPURLResponse,http.statusCode==200,HomeEgressTransport.isAllowed(http.url ?? request.url!,base:current.baseURL) else{throw HubFailure.upstream_error}
        var data=Data();for try await byte in bytes {data.append(byte);guard data.count<=2*1024*1024 else{throw HubFailure.oversized_response}}
        guard home?.session?.id==current.id else{throw HubFailure.home_session_changed}
        let object=try JSONSerialization.jsonObject(with:data)
        return ["source":"observatory_home_session","route":home?.route.rawValue ?? "lan","timestamp":Date().timeIntervalSince1970,"data":object]
    }
    private func audit(method:String,node:String,ok:Bool) {
        guard !method.isEmpty else{return}
        let directory=endpoint.deletingLastPathComponent(),url=directory.appendingPathComponent("hub-audit.jsonl")
        let allowed=Set(["node.pause","node.add","hub.status","nodes.list","node.telemetry","node.connect","node.inspect","node.exec","node.session.open","node.session.read","node.session.write","node.session.close","node.file.transfer","home.status","home.connect","home.overview","home.audit"])
        let knownNode=node=="HOME" || telemetry?.nodes.contains(where:{$0.id==node}) == true
        let entry:[String:Any]=["timestamp":Date().timeIntervalSince1970,"method":allowed.contains(method) ? method:"unknown_method","node_id":knownNode ? node:"","ok":ok]
        guard var data=try? JSONSerialization.data(withJSONObject:entry,options:[.sortedKeys]) else{return};data.append(10)
        if ((try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0)>1_048_576 {try? FileManager.default.removeItem(at:directory.appendingPathComponent("hub-audit.previous.jsonl"));try? FileManager.default.moveItem(at:url,to:directory.appendingPathComponent("hub-audit.previous.jsonl"))}
        if !FileManager.default.fileExists(atPath:url.path){FileManager.default.createFile(atPath:url.path,contents:nil,attributes:[.posixPermissions:0o600])}
        if let handle=try? FileHandle(forWritingTo:url){defer{try? handle.close()};try? handle.seekToEnd();try? handle.write(contentsOf:data)}
    }
    private static func remoteCommand(_ command:String,timeout:Int)->String {
        let encoded=Data(command.utf8).base64EncodedString()
        return "COMMAND='\(encoded)'\nLIMIT=\(timeout)\n" + #"""
import os,sys,socket,json,base64,subprocess,selectors,time,signal
hostname=socket.gethostname()
if CONFIG.get('expectedHostname') and hostname!=CONFIG['expectedHostname']:raise SystemExit(42)
command=base64.b64decode(COMMAND).decode('utf-8')
p=subprocess.Popen(['/bin/sh','-c',command],stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
selector=selectors.DefaultSelector()
for f in (p.stdout,p.stderr): selector.register(f,selectors.EVENT_READ)
selector.register(sys.stdin.buffer,selectors.EVENT_READ)
buf={p.stdout:bytearray(),p.stderr:bytearray()};truncated=False;timed_out=False;deadline=time.monotonic()+LIMIT
def stop():
 try:os.killpg(p.pid,signal.SIGKILL)
 except ProcessLookupError:pass
while selector.get_map():
 if time.monotonic()>=deadline:timed_out=True;stop();break
 for key,_ in selector.select(min(0.2,max(0,deadline-time.monotonic()))):
  if key.fileobj is sys.stdin.buffer:
   if not os.read(key.fd,1024):stop();sys.exit(1)
   continue
  data=os.read(key.fd,4096)
  if not data:selector.unregister(key.fileobj);continue
  remaining=8192-len(buf[key.fileobj]);buf[key.fileobj].extend(data[:remaining])
  if len(data)>remaining:truncated=True;stop();break
 if truncated or (p.poll() is not None and len(selector.get_map())==1):break
try:p.wait(timeout=2)
except subprocess.TimeoutExpired:stop();p.wait()
selector.close()
result={'hostname':hostname,'exit_code':p.returncode,'truncated':truncated,'timed_out':timed_out,'stdout':base64.b64encode(buf[p.stdout]).decode(),'stderr':base64.b64encode(buf[p.stderr]).decode()}
print(json.dumps(result,separators=(',',':')))
"""#
    }
    private static func inspection(check:String)->String {
        let body=#"""
import os,socket,time,json,subprocess,shutil
hostname=socket.gethostname()
if CONFIG.get('expectedHostname') and hostname!=CONFIG['expectedHostname']:raise SystemExit(42)
out={'node_id':CONFIG['nodeID'],'hostname':hostname,'uid':os.getuid(),'measured_at':time.time(),'check':CHECK,'read_only':True}
if CHECK=='resources':
 mem={line.split(':',1)[0]:int(line.split()[1])*1024 for line in open('/proc/meminfo') if line.startswith(('MemTotal:','MemAvailable:','SwapTotal:','SwapFree:'))}
 disk=shutil.disk_usage('/');out.update(memory=mem,disk={'total':disk.total,'used':disk.used,'free':disk.free},cores=os.cpu_count(),load=list(os.getloadavg()),uptime=float(open('/proc/uptime').read().split()[0]))
elif CHECK=='services':
 out['units']=[]
 for unit in CONFIG.get('units',[])[:16]:
  p=subprocess.run(['systemctl','show',unit,'-p','ActiveState','-p','SubState','-p','NRestarts'],capture_output=True,text=True,timeout=2)
  fields=dict(x.split('=',1) for x in p.stdout.splitlines() if '=' in x);out['units'].append({'name':unit,'exit':p.returncode,'state':fields})
elif CHECK=='containers':
 try:
  p=subprocess.run(['docker','ps','-a','--format','{{json .}}'],capture_output=True,text=True,timeout=6)
  out['exit']=p.returncode;out['containers']=[];lines=p.stdout.splitlines();out['truncated']=len(lines)>16
  for line in lines[:16]:
   d=json.loads(line);out['containers'].append({k:str(d.get(k,''))[:120] for k in ['Names','Image','State','Status']})
 except (OSError,ValueError,subprocess.TimeoutExpired):out['unavailable']=True
print(json.dumps(out))
"""#
        return "CHECK='\(check)'\n"+body
    }
}
