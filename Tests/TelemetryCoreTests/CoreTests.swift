import XCTest
import Foundation
@testable import TelemetryCore

final class CoreTests: XCTestCase {
    func sample(sequence: Int = 1, boot: String = "boot", node: String = "test") -> TelemetrySample {
        TelemetrySample(nodeID: node, hostname: "test-host", bootID: boot, sequence: sequence,
            measuredAt: 1_700_000_000 + Double(sequence), uptime: 100, cores: 2, cpuPercent: 25,
            memory: ByteUsage(total: 1000, available: 600), swap: ByteUsage(total: 0, available: 0),
            disk: nil, network: nil, load: [0.1, 0.2, 0.3], units: [], errors: ["disk": "unavailable"])
    }
    func testStreamingSplitAndMultipleRecords() throws {
        var frame = LineFramer()
        XCTAssertTrue(try frame.append(Data("{\"a\"".utf8)).isEmpty)
        let lines = try frame.append(Data(":1}\n{\"a\":2}\n".utf8))
        XCTAssertEqual(lines.compactMap { String(data: $0, encoding: .utf8) }, ["{\"a\":1}", "{\"a\":2}"])
    }
    func testMissingNewlineCannotGrowMemoryWithoutBound() {
        var frame = LineFramer(limit: 8)
        XCTAssertThrowsError(try frame.append(Data(repeating: 65, count: 9)))
    }
    func testLineLimitAppliesPerRecord() throws {
        var frame = LineFramer(limit: 4)
        XCTAssertEqual(try frame.append(Data("1234\n1234\n".utf8)).count, 2)
    }
    func testProtocolRoundTripWithPartialSources() throws {
        let value = sample()
        let result = try JSONDecoder().decode(TelemetrySample.self, from: JSONEncoder().encode(value))
        try result.validate(expectedNodeID: "test")
        XCTAssertNil(result.disk)
        XCTAssertEqual(result.errors["disk"], "unavailable")
    }
    func testCrossNodeDataRejected() { XCTAssertThrowsError(try sample().validate(expectedNodeID: "other")) }
    func testNonFiniteAndOutOfRangeDataRejected() throws {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(sample())) as! [String: Any]
        object["cpuPercent"] = 101
        let value = try JSONDecoder().decode(TelemetrySample.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try value.validate(expectedNodeID: "test"))
        object["cpuPercent"] = 30; object["memory"] = ["total": 100, "available": 101]
        XCTAssertThrowsError(try JSONDecoder().decode(TelemetrySample.self, from: JSONSerialization.data(withJSONObject: object)).validate(expectedNodeID: "test"))
    }
    func testWindowIsBoundedAndRejectsDuplicates() {
        var window = SampleWindow(capacity: 3)
        let segment = UUID()
        for i in 0..<10 { window.append(ReceivedSample(sample: sample(sequence: i), segment: segment)) }
        XCTAssertEqual(window.points.map(\.sample.sequence), [7, 8, 9])
        XCTAssertFalse(window.append(ReceivedSample(sample: sample(sequence: 9), segment: segment)))
    }
    func testRebootAndReconnectAcceptSequenceResetWithoutJoiningLines() {
        var window = SampleWindow(); let segment = UUID()
        window.append(ReceivedSample(sample: sample(sequence: 20), segment: segment))
        XCTAssertTrue(window.append(ReceivedSample(sample: sample(sequence: 0, boot: "new-boot"), segment: UUID())))
        XCTAssertNotEqual(window.points[0].segment, window.points[1].segment)
    }
    func testExactlyFourRetriesAfterInitialFailure() {
        let policy = ReconnectPolicy()
        XCTAssertEqual(policy.delay, 5)
        XCTAssertEqual((0...5).map { policy.canRetry(afterRetries: $0, permanent: false) }, [true, true, true, true, false, false])
        XCTAssertFalse(policy.canRetry(afterRetries: 0, permanent: true))
    }
    func testAuthenticationAndChangedHostKeyNeverAutoRetry() {
        XCTAssertTrue(ReconnectPolicy.isPermanentSSHError("Host key verification failed."))
        XCTAssertTrue(ReconnectPolicy.isPermanentSSHError("Permission denied (publickey)."))
        XCTAssertFalse(ReconnectPolicy.isPermanentSSHError("Connection timed out"))
    }
    func testProfileCannotInjectRemoteShellOrSSHOptions() {
        for alias in ["-oProxyCommand=bad", "host; echo", "a b", "host\nother"] {
            XCTAssertThrowsError(try NodeProfile(name: "Test", region: "", sshAlias: alias).validate())
        }
        XCTAssertThrowsError(try NodeProfile(name: "Test", region: "", sshAlias: "safe", units: ["x.service;id"]).validate())
    }
    func testSSHCommandPinsHostAndDoesNotForwardOrMultiplex() throws {
        let args = try SSHSession.arguments(profile: NodeProfile(name: "Test", region: "", sshAlias: "safe-profile"), collector: "print('test')")
        for option in ["StrictHostKeyChecking=yes", "UpdateHostKeys=no", "ForwardAgent=no", "ClearAllForwardings=yes", "ControlPath=none", "BatchMode=yes"] {
            XCTAssertTrue(args.contains(option))
        }
        XCTAssertFalse(args.contains("sudo"))
        XCTAssertEqual(args[args.count - 2], "safe-profile")
    }
    func testSQLiteCapAndReadbackKeepOnlyNewestSamples() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(url: root.appendingPathComponent("history.sqlite"), maximumRows: 3)
        let segment = UUID()
        for i in 0..<8 { try store.append(ReceivedSample(sample: sample(sequence: i), segment: segment), nodeID: "test") }
        let points = try store.recent(nodeID: "test")
        XCTAssertEqual(points.map(\.sample.sequence), [5, 6, 7])
        XCTAssertTrue(points.allSatisfy { $0.segment == segment })
        let attrs = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("history.sqlite").path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testSessionReceivesFixtureAndClosesItsChild() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("fake-ssh")
        let pidFile = root.appendingPathComponent("pid")
        let json = String(data: try JSONEncoder().encode(sample()), encoding: .utf8)!
        try ("#!/bin/sh\nprintf '%s' $$ > '" + pidFile.path + "'\nprintf '%s\\n' '" + json + "'\nwhile IFS= read -r beat; do :; done\n").write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let received = DispatchSemaphore(value: 0)
        let session = SSHSession(profile: NodeProfile(id: "test", name: "Fixture", region: "", sshAlias: "fixture"), collector: "", executableURL: script, onSample: { _ in received.signal() }, onExit: { _ in })
        session.start()
        XCTAssertEqual(received.wait(timeout: .now() + 4), .success)
        let pid = Int32(try String(contentsOf: pidFile, encoding: .utf8))!
        session.stop()
        for _ in 0..<40 {
            if kill(pid, 0) != 0 { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertNotEqual(kill(pid, 0), 0)
    }
    func testSessionAuthErrorIsTerminalAndDoesNotLeakRawError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("fake-ssh")
        try "#!/bin/sh\nprintf 'Permission denied (publickey). private-text\\n' >&2\nexit 255\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let ended = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var failure: SessionFailure?
        let session = SSHSession(profile: NodeProfile(name: "Fixture", region: "", sshAlias: "fixture"), collector: "", executableURL: script, onSample: { _ in }, onExit: { value in
            lock.lock(); failure = value; lock.unlock(); ended.signal()
        })
        session.start()
        XCTAssertEqual(ended.wait(timeout: .now() + 4), .success)
        lock.lock(); let result = failure; lock.unlock()
        XCTAssertTrue(result?.permanent == true)
        XCTAssertFalse(result?.message.contains("private-text") == true)
        session.stop()
    }
    func testExistingExplicitConfigIsPassedWithoutShellInterpolation() throws {
        let profile = NodeProfile(name: "Node", region: "", sshAlias: "trusted-node", sshConfigPath: "/a path/existing.conf", expectedHostname: "expected-host")
        let args = try SSHSession.arguments(profile: profile, collector: "")
        XCTAssertEqual(Array(args.prefix(2)), ["-F", "/a path/existing.conf"])
        XCTAssertThrowsError(try NodeProfile(name: "Node", region: "", sshAlias: "trusted-node", sshConfigPath: "relative.conf").validate())
    }
    func testHostnameMismatchRejectsSampleDespiteMatchingNodeLabel() throws {
        XCTAssertThrowsError(try sample().validate(expectedNodeID: "test", expectedHostname: "wrong-host"))
        try sample().validate(expectedNodeID: "test", expectedHostname: "test-host")
    }
    func testIngressBudgetCountsBytesRecordsAndWindow() {
        var b = StreamAdmission(maximumBytes: 10, maximumRecords: 2, interval: 6)
        XCTAssertTrue(b.admit(bytes: 5, records: 1, now: 0))
        XCTAssertTrue(b.admit(bytes: 5, records: 1, now: 1))
        XCTAssertFalse(b.admit(bytes: 1, records: 0, now: 2))
        XCTAssertFalse(b.admit(bytes: 0, records: 1, now: 3))
        XCTAssertTrue(b.admit(bytes: 10, records: 2, now: 6))
        XCTAssertFalse(b.admit(bytes: -1, records: 0, now: 7))
    }
    func testMailboxBoundsStalledConsumerAndCancelsPending() {
        let m = LatestValueMailbox<Int>()
        var notifications = 0
        for i in 0..<100_000 { if m.offer(i) { notifications += 1 } }
        XCTAssertEqual(notifications, 1); XCTAssertEqual(m.pendingCount, 1)
        XCTAssertEqual(m.skippedCount, 99_999); XCTAssertEqual(m.take(), 99_999)
        XCTAssertTrue(m.offer(100_000)); m.close()
        XCTAssertNil(m.take()); XCTAssertFalse(m.offer(100_001)); XCTAssertEqual(m.pendingCount, 0)
    }
    private func exerciseFlood(_ body: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("fake-ssh")
        try ("#!/usr/bin/python3\nimport os,time\n" + body + "\ntime.sleep(10)\n").write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o700], ofItemAtPath:script.path)
        let ended = DispatchSemaphore(value:0), lock = NSLock()
        var count = 0, exits = 0, failure: SessionFailure?
        let session = SSHSession(profile:NodeProfile(id:"test",name:"Fixture",region:"",sshAlias:"fixture"), collector:"", executableURL:script,
            onSample:{ _ in lock.lock(); count += 1; lock.unlock() }, onExit:{ f in
                lock.lock(); exits += 1; failure=f; lock.unlock(); ended.signal()
            })
        session.start()
        XCTAssertEqual(ended.wait(timeout:.now()+4), .success)
        session.stop(); Thread.sleep(forTimeInterval:0.1)
        lock.lock(); let values=(count,exits,failure); lock.unlock()
        XCTAssertTrue(values.0 <= 4); XCTAssertEqual(values.1,1); XCTAssertTrue(values.2?.permanent == true)
        XCTAssertFalse(values.2?.message.contains("private-marker") == true)
    }
    func testValidRecordFloodIsTerminalAndBounded() throws {
        let row = String(data:try JSONEncoder().encode(sample()),encoding:.utf8)!
        try exerciseFlood("row=" + String(reflecting:row) + "\nfor i in range(200):\n os.write(1,(row+'\\n').encode())")
    }
    func testStderrFloodIsTerminalAndBounded() throws {
        try exerciseFlood("for i in range(64):\n os.write(2,b'private-marker'+b'x'*4096)")
    }
    func testBlankLineFloodIsTerminal() throws { try exerciseFlood("os.write(1,b'\\n'*10000)") }
    func testOversizedUnterminatedLineIsTerminal() throws { try exerciseFlood("os.write(1,b'x'*40000)") }
    func testDiskReservedSpaceAndOldRecordCompatibility() throws {
        let disk=ByteUsage(total:1000,available:200,usedBytes:750,reservedBytes:50)
        XCTAssertEqual(disk.used,750); XCTAssertEqual(disk.percent,75)
        let old=try JSONDecoder().decode(ByteUsage.self,from:Data("{\"total\":1000,\"available\":200}".utf8))
        XCTAssertEqual(old.used,800)
    }
    func testHistoryBatchesAndEnforcesAgeAndByteBudgets() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let size=try JSONEncoder().encode(sample()).count
        let store=try HistoryStore(url:root.appendingPathComponent("history.sqlite"),maximumPayloadBytes:size*3,maximumAge:60)
        let segment=UUID()
        try store.append(ReceivedSample(sample:sample(sequence:0),receivedAt:Date().addingTimeInterval(-120),segment:segment),nodeID:"test")
        XCTAssertTrue(try store.recent(nodeID:"test").isEmpty)
        for i in 1...12 { XCTAssertTrue(store.enqueue(ReceivedSample(sample:sample(sequence:i),segment:segment),nodeID:"test",onFailure:{})) }
        store.flush()
        let points=try store.recent(nodeID:"test")
        XCTAssertTrue(points.count <= 3)
        XCTAssertFalse(points.isEmpty)
        XCTAssertEqual(points.last?.sample.sequence,12)
        // A subsequent ordinary write remains possible after retention removal.
        try store.append(ReceivedSample(sample:sample(sequence:99),segment:segment),nodeID:"test")
        XCTAssertEqual(try store.recent(nodeID:"test").last?.sample.sequence,99)
    }
    func testHistoryOpenFailureIsReported() {
        XCTAssertThrowsError(try HistoryStore(url:URL(fileURLWithPath:"/dev/null/not-a-database")))
    }
    func testInterfaceCannotCarryShellOrPathSyntax() {
        for value in ["lo;id","../eth0","eth0\nother",""] {
            XCTAssertThrowsError(try NodeProfile(name:"Node",region:"",sshAlias:"safe",networkInterface:value).validate())
        }
    }

    func testSplitBurstAndDuplicateRecordsPreserveLegitimateSamples() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let rows=try [sample(sequence:1),sample(sequence:1),sample(sequence:2)].map { String(data:try JSONEncoder().encode($0),encoding:.utf8)! }.joined(separator:"\n")+"\n"
        let script=root.appendingPathComponent("fake-ssh")
        let body="#!/usr/bin/python3\nimport os,base64,sys,time\ndata=base64.b64decode('"+Data(rows.utf8).base64EncodedString()+"')\nos.write(1,data[:20])\ntime.sleep(0.02)\nos.write(1,data[20:])\nfor line in sys.stdin: pass\n"
        try body.write(to:script,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:script.path)
        let semaphore=DispatchSemaphore(value:0),lock=NSLock(); var received:[Int]=[]
        let session=SSHSession(profile:NodeProfile(id:"test",name:"Fixture",region:"",sshAlias:"fixture"),collector:"",executableURL:script,onSample:{ v in
            lock.lock();received.append(v.sequence);let done=received.count==2;lock.unlock();if done { semaphore.signal() }
        },onExit:{_ in})
        session.start();XCTAssertEqual(semaphore.wait(timeout:.now()+3),.success)
        session.stop();Thread.sleep(forTimeInterval:0.1)
        lock.lock();let result=received;lock.unlock();XCTAssertEqual(result,[1,2])
    }

}
