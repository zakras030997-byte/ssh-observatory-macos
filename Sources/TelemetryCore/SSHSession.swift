import Foundation
import Darwin

public struct SessionFailure {
    public let message: String
    public let permanent: Bool
    public init(_ message: String, permanent: Bool = false) { self.message = message; self.permanent = permanent }
}

public protocol SessionControl: AnyObject { func start(); func stop() }
public struct SessionCallbacks {
    public let sample: (TelemetrySample) -> Void
    public let exit: (SessionFailure) -> Void
    public init(sample: @escaping (TelemetrySample) -> Void, exit: @escaping (SessionFailure) -> Void) {
        self.sample = sample; self.exit = exit
    }
}
/// One owned ssh process; bounded nonblocking IO off the UI.
public final class SSHSession: SessionControl {
    private let queue = DispatchQueue(label: "sshobservatory.telemetry.ssh", qos: .utility)
    private let profile: NodeProfile
    private let collector: String
    private let executableURL: URL
    private let sampleHandler: (TelemetrySample) -> Void
    private let exitHandler: (SessionFailure) -> Void
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var errorPipe: Pipe?
    private var stdoutSource: DispatchSourceRead?
    private var stderrSource: DispatchSourceRead?
    private var stdoutFD: Int32?
    private var stderrFD: Int32?
    private var heartbeat: DispatchSourceTimer?
    private var framer = LineFramer()
    private var stderr = Data()
    private var admission = StreamAdmission()
    private var lastSequence: Int?
    private var lastBoot: String?
    private var ended = false
    private var lastValid = ProcessInfo.processInfo.systemUptime

    public init(profile: NodeProfile, collector: String,
                executableURL: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
                onSample: @escaping (TelemetrySample) -> Void,
                onExit: @escaping (SessionFailure) -> Void) {
        self.profile = profile; self.collector = collector
        self.executableURL = executableURL
        self.sampleHandler = onSample; self.exitHandler = onExit
    }
    public static func arguments(profile: NodeProfile, collector: String) throws -> [String] {
        try profile.validate()
        var config: [String: Any] = ["nodeID": profile.id, "units": profile.units]
        if let hostname = profile.expectedHostname { config["expectedHostname"] = hostname }
        if let interface = profile.networkInterface { config["networkInterface"] = interface }
        let configuration = try JSONSerialization.data(withJSONObject: config).base64EncodedString()
        let source = "import json,base64\nCONFIG=json.loads(base64.b64decode('\(configuration)'))\n" + collector
        let encoded = Data(source.utf8).base64EncodedString()
        // Only Base64 enters the remote shell, never user-supplied shell text.
        let remote = "python3 -u -B -c 'exec(__import__(\"base64\").b64decode(\"\(encoded)\"))'"
        let configArguments = profile.sshConfigPath.map { ["-F", $0] } ?? []
        return configArguments + ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                "-o", "UpdateHostKeys=no", "-o", "ForwardAgent=no", "-o", "ForwardX11=no",
                "-o", "ClearAllForwardings=yes", "-o", "ControlMaster=no", "-o", "ControlPath=none",
                "-o", "PermitLocalCommand=no", "-o", "RequestTTY=no",
                "-o", "ConnectTimeout=8", "-o", "ConnectionAttempts=1",
                "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2",
                "-o", "LogLevel=ERROR", profile.sshAlias, remote]
    }
    public func start() {
        queue.async { [self] in
            guard !ended, process == nil else { return }
            do {
                let task = Process(), stdin = Pipe(), stdout = Pipe(), errors = Pipe()
                task.executableURL = executableURL
                task.arguments = try Self.arguments(profile: profile, collector: collector)
                // Keep SSH agent availability, but disable askpass prompts and English
                // error classification is fixed by locale; no env values are logged.
                var env = ProcessInfo.processInfo.environment
                env["LC_ALL"] = "C"; env["SSH_ASKPASS_REQUIRE"] = "never"
                task.environment = env
                task.standardInput = stdin; task.standardOutput = stdout; task.standardError = errors
                process = task; input = stdin; output = stdout; errorPipe = errors
                task.terminationHandler = { [weak self] _ in
                    self?.queue.async { [weak self] in self?.didTerminate() }
                }
                try task.run()
                let fd = stdin.fileHandleForWriting.fileDescriptor
                guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) != -1,
                      fcntl(fd, F_SETNOSIGPIPE, 1) != -1 else { throw TelemetryError.invalidProfile }
                (stdoutSource, stdoutFD) = try reader(stdout.fileHandleForReading, errors: false)
                (stderrSource, stderrFD) = try reader(errors.fileHandleForReading, errors: true)
                lastValid = ProcessInfo.processInfo.systemUptime
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now(), repeating: 3, leeway: .milliseconds(150))
                timer.setEventHandler { [weak self] in self?.tick() }
                heartbeat = timer; timer.resume()
            } catch {
                finish(SessionFailure("Не удалось запустить SSH. Проверьте профиль подключения.", permanent: true))
            }
        }
    }
    public func stop() { queue.async { [self] in finish(nil) } }
    private func reader(_ handle: FileHandle, errors: Bool) throws -> (DispatchSourceRead, Int32) {
        let fd = dup(handle.fileDescriptor)
        guard fd >= 0 else { throw TelemetryError.invalidProfile }
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) != -1,
              fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) != -1 else {
            Darwin.close(fd); throw TelemetryError.invalidProfile
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        // Readiness notifications coalesce; no Data is captured into queued work.
        source.setEventHandler { [weak self] in self?.readAvailable(fd, errors: errors) }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume(); return (source, fd)
    }
    private func readAvailable(_ fd: Int32, errors: Bool) {
        guard !ended else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        // Fairness for stop/timer: at most 16 KiB per readiness callback.
        for _ in 0..<4 {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK { finish(SessionFailure("Ошибка чтения SSH.")) }
                return
            }
            if count == 0 {
                if errors { stderrFD = nil; stderrSource?.cancel() }
                else { stdoutFD = nil; stdoutSource?.cancel() }
                return
            }
            let records = errors ? 0 : buffer.prefix(count).reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
            guard admission.admit(bytes: count, records: records, now: ProcessInfo.processInfo.systemUptime) else {
                finish(SessionFailure("Сервер превысил допустимый поток телеметрии. Подключение остановлено.", permanent: true)); return
            }
            let data = Data(buffer.prefix(count))
            if errors {
                stderr.append(data.prefix(max(0, 8192 - stderr.count)))
                if ReconnectPolicy.isPermanentSSHError(String(data: stderr, encoding: .utf8) ?? "") {
                    finish(SessionFailure("Ошибка авторизации или проверки ключа сервера.", permanent: true))
                }
            } else { consume(data) }
            if ended { return }
        }
    }
    private func consume(_ data: Data) {
        guard !ended else { return }
        if data.isEmpty { output?.fileHandleForReading.readabilityHandler = nil; return }
        do {
            for line in try framer.append(data) {
                let sample = try JSONDecoder().decode(TelemetrySample.self, from: line)
                try sample.validate(expectedNodeID: profile.id, expectedHostname: profile.expectedHostname)
                if lastBoot == sample.bootID, let sequence = lastSequence, sample.sequence <= sequence { continue }
                lastBoot = sample.bootID; lastSequence = sample.sequence
                lastValid = ProcessInfo.processInfo.systemUptime
                sampleHandler(sample)
            }
        } catch {
            finish(SessionFailure("Некорректный ответ сборщика; подключение остановлено.", permanent: true))
        }
    }
    private func tick() {
        guard !ended else { return }
        if ProcessInfo.processInfo.systemUptime - lastValid > 14 {
            finish(SessionFailure("SSH не передаёт свежие показания.")); return
        }
        guard let fd = input?.fileHandleForWriting.fileDescriptor else { return }
        let beat = Array("beat\n".utf8)
        let count = beat.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        if count != beat.count { finish(SessionFailure("Соединение SSH не принимает heartbeat.")) }
    }
    private func didTerminate() {
        guard !ended else { return }
        if let fd = stderrFD { readAvailable(fd, errors: true) }
        if !ended, let fd = stdoutFD { readAvailable(fd, errors: false) }
        guard !ended else { return }
        let raw = String(data: stderr, encoding: .utf8) ?? ""
        let permanent = ReconnectPolicy.isPermanentSSHError(raw) || raw.contains("python3: command not found") || raw.contains("python3: not found") || raw.contains("hostname mismatch")
        let message = permanent
            ? "Проверьте SSH-профиль, доверенный ключ сервера, права и наличие Python 3."
            : "SSH недоступен или сборщик завершился."
        finish(SessionFailure(message, permanent: permanent))
    }
    private func finish(_ failure: SessionFailure?) {
        guard !ended else { return }; ended = true
        heartbeat?.cancel(); heartbeat = nil
        stdoutSource?.cancel(); stderrSource?.cancel(); stdoutSource = nil; stderrSource = nil
        stdoutFD = nil; stderrFD = nil
        output?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        try? input?.fileHandleForWriting.close()
        if let process, process.isRunning { process.terminate() }
        // Termination callback captures self weakly; stopping does not schedule retries.
        if let failure { exitHandler(failure) }
        process = nil; input = nil; output = nil; errorPipe = nil
    }
}
