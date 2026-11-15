import AppKit
import SwiftUI
import WebKit
import Foundation
import Darwin
import Network

// The Home API stays loopback-only. OpenSSH owns transport and host verification;
// no private key or persistent browser credential is copied into this feature.
enum HomeEgressRoute: String, CaseIterable, Identifiable {
    case lan, kz
    var id: String { rawValue }
    var label: String { self == .lan ? "Домашняя LAN · основной" : "Резервный SSH-маршрут" }

    var commonArguments: [String] {
        var options = ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                       "-o", "ForwardAgent=no", "-o", "UpdateHostKeys=no",
                       "-o", "ControlMaster=no", "-o", "ControlPath=none",
                       "-o", "PermitLocalCommand=no", "-o", "RemoteCommand=none",
                       "-o", "RequestTTY=no", "-o", "ConnectTimeout=5",
                       "-o", "ConnectionAttempts=1", "-o", "LogLevel=ERROR"]
        if self == .lan {
            // The explicit alias owns identity configuration. LAN never uses a proxy.
            options += ["-o", "IdentitiesOnly=yes", "-o", "ProxyCommand=none", "-o", "ProxyJump=none"]
        }
        return options
    }
    var destination: String { guard let access=try? HomeAccessConfiguration.load() else{return "home-access-not-configured.invalid"};return self == .lan ? access.lanAlias : access.reserveAlias }
    func commandArguments(_ command: String) -> [String] { commonArguments + [destination, command] }
    func tunnelArguments(localPort: UInt16) -> [String] {
        commonArguments + ["-N", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=15",
                           "-o", "ServerAliveCountMax=2", "-L", "127.0.0.1:\(localPort):127.0.0.1:18788", destination]
    }
}

enum HomeEgressFailure: Error, LocalizedError {
    case ssh, wrongHost, invalidSession, timedOut, cancelled, port, apiUnavailable
    case sshDiagnostic(phase: HomeEgressSSHPhase, category: HomeEgressSSHCategory, exitCode: Int32?, osCode: Int?)
    var errorDescription: String? {
        switch self {
        case .ssh: return "SSH не подключился. Проверьте сеть, доступный профиль и доверенный ключ сервера."
        case .wrongHost: return "SSH ответил с другого сервера. Подключение остановлено."
        case .invalidSession: return "Home вернул неподходящую сессию панели. Доступ не открыт."
        case .timedOut: return "SSH не завершил проверку вовремя. Попробуйте подключиться ещё раз."
        case .cancelled: return "Подключение отменено."
        case .port: return "Не удалось выделить локальный порт SSH."
        case .apiUnavailable: return "Не удалось получить ответ ядра через локальный SSH-туннель. Проверьте подключение и попробуйте снова."
        case let .sshDiagnostic(phase, category, exitCode, osCode):
            var suffix = "\(phase.rawValue)/\(category.rawValue)"
            if let exitCode { suffix += "; exit \(exitCode)" }
            if let osCode { suffix += "; OS \(osCode)" }
            return "SSH · \(phase.label): \(category.label) (\(suffix))."
        }
    }
}

enum HomeEgressSSHPhase: String {
    case hostname, session, tunnel
    var label: String {
        switch self { case .hostname: return "проверка сервера"; case .session: return "создание сессии"; case .tunnel: return "локальный туннель" }
    }
}

enum HomeEgressSSHCategory: String {
    case authentication, host_key, key_permissions, key_missing, file_permission, configuration_permission
    case network_permission, network_route, connection_refused, timeout, hostname_dns, configuration
    case remote_authorization, helper_missing, launch_failed, oversized_output, other
    var label: String {
        switch self {
        case .authentication: return "сервер не принял SSH-ключ"
        case .host_key: return "доверенный ключ сервера не подтверждён; проверка не ослаблялась"
        case .key_permissions: return "SSH отклонил права файла ключа"
        case .key_missing: return "файл выбранного SSH-ключа недоступен"
        case .file_permission: return "macOS не разрешила прочитать файл SSH"
        case .configuration_permission: return "SSH не смог прочитать включённый файл профиля"
        case .network_permission: return "macOS не разрешила сетевое подключение"
        case .network_route: return "нет сетевого маршрута к Home"
        case .connection_refused: return "сервер отказал в соединении"
        case .timeout: return "сервер не ответил вовремя"
        case .hostname_dns: return "имя SSH-профиля не определилось"
        case .configuration: return "SSH отклонил параметры профиля"
        case .remote_authorization: return "сервер не разрешил создание сессии панели"
        case .helper_missing: return "на Home не найден помощник панели"
        case .launch_failed: return "macOS не запустила системный SSH"
        case .oversized_output: return "SSH вернул ответ сверх допустимого размера"
        case .other: return "SSH завершился с ошибкой; секретный вывод не показывается"
        }
    }
    static func classify(_ bytes: Data) -> HomeEgressSSHCategory {
        let text = String(decoding: bytes, as: UTF8.self).lowercased()
        if text.contains("host key verification failed") || text.contains("remote host identification has changed") { return .host_key }
        if text.contains("bad owner or permissions") || text.contains("unprotected private key") { return .key_permissions }
        if (text.contains("config") || text.contains("include")) && (text.contains("permission denied") || text.contains("operation not permitted")) { return .configuration_permission }
        if text.contains("no such identity") || (text.contains("identity file") && text.contains("not accessible")) { return .key_missing }
        if text.contains("load key") && (text.contains("permission denied") || text.contains("operation not permitted")) { return .file_permission }
        if text.contains("operation not permitted") || (text.contains("connect to host") && text.contains("permission denied")) { return .network_permission }
        if text.contains("no route to host") || text.contains("network is unreachable") { return .network_route }
        if text.contains("connection refused") { return .connection_refused }
        if text.contains("timed out") || text.contains("timeout") { return .timeout }
        if text.contains("could not resolve hostname") { return .hostname_dns }
        if text.contains("bad configuration") || text.contains("unsupported option") || text.contains("bad command-line option") { return .configuration }
        if text.contains("sudo:") { return .remote_authorization }
        if text.contains("permission denied") || text.contains("authentication failed") { return .authentication }
        if text.contains("not found") && text.contains("home-egress-control") { return .helper_missing }
        return .other
    }
}

// Stderr is drained concurrently to avoid pipe deadlock, retained only up to4KiB
// for whitelist classification and never printed, stored or returned verbatim.
private final class HomeEgressSSHStderr: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func drain(_ pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; return }
            self?.append(chunk)
        }
    }
    private func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        let remaining = max(0,4096-bytes.count)
        if remaining>0 { bytes.append(data.prefix(remaining)) }
    }
    func finish(_ pipe: Pipe) -> HomeEgressSSHCategory {
        pipe.fileHandleForReading.readabilityHandler = nil
        append(pipe.fileHandleForReading.readDataToEndOfFile())
        try? pipe.fileHandleForReading.close()
        lock.lock(); let result = HomeEgressSSHCategory.classify(bytes); bytes.removeAll(); lock.unlock()
        return result
    }
}

struct HomeEgressCredentials: Decodable {
    let sessionToken: String
    let csrfToken: String
    let expiresAt: Date
    enum CodingKeys: String, CodingKey { case sessionToken = "session_token", csrfToken = "csrf_token", expiresAt = "expires_at" }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sessionToken = try values.decode(String.self, forKey: .sessionToken)
        csrfToken = try values.decode(String.self, forKey: .csrfToken)
        if let epoch = try? values.decode(Double.self, forKey: .expiresAt) {
            expiresAt = Date(timeIntervalSince1970: epoch)
        } else {
            let text = try values.decode(String.self, forKey: .expiresAt)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let fallback = ISO8601DateFormatter()
            guard let date = formatter.date(from: text) ?? fallback.date(from: text) else { throw HomeEgressFailure.invalidSession }
            expiresAt = date
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard (32...512).contains(sessionToken.utf8.count),
              (16...512).contains(csrfToken.utf8.count),
              sessionToken.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              csrfToken.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              expiresAt > Date() else { throw HomeEgressFailure.invalidSession }
    }
}

struct HomeEgressBrowserSession {
    let id = UUID()
    let baseURL: URL
    let credentials: HomeEgressCredentials
}

enum HomeEgressTransport {
    static let sessionCommand = "sudo -n /usr/local/sbin/home-egress-control session"
    static func cookie(_ credentials: HomeEgressCredentials) -> HTTPCookie? {
        HTTPCookie(properties: [
            .name: "home_egress_session", .value: credentials.sessionToken,
            .domain: "127.0.0.1", .path: "/", .expires: credentials.expiresAt,
            HTTPCookiePropertyKey("HttpOnly"): "TRUE", HTTPCookiePropertyKey("SameSite"): "Strict"
        ])
    }
    static func isAllowed(_ url: URL, base: URL) -> Bool {
        url.scheme == "http" && url.host == "127.0.0.1" && url.port == base.port &&
        url.user == nil && url.password == nil
    }
    static func validateIdentity(_ data: Data) throws {
        guard let access=try? HomeAccessConfiguration.load(),
              let hostname=String(data:data,encoding:.utf8)?.trimmingCharacters(in:.whitespacesAndNewlines),
              hostname==access.expectedHostname else {
            throw HomeEgressFailure.wrongHost
        }
    }
    static func availableLoopbackPort() throws -> UInt16 {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw HomeEgressFailure.port }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw HomeEgressFailure.port }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard result == 0 else { throw HomeEgressFailure.port }
        return UInt16(bigEndian: address.sin_port)
    }
}

// A finite SSH command. Only bounded stdout is retained; neither stdout nor
// stderr is ever logged. Cancellation addresses exactly this Process object.
final class HomeEgressSSHCommand: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var expired = false

    func cancel() {
        lock.lock(); cancelled = true; let child = process; lock.unlock()
        if child?.isRunning == true { child?.terminate() }
    }
    func run(arguments: [String], phase: HomeEgressSSHPhase, timeout: TimeInterval = 8, keepInputOpen:Bool = false, outputLimit:Int = 8192) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let child = Process(), pipe = Pipe(), errorPipe = Pipe(), errors = HomeEgressSSHStderr()
                child.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                child.arguments = arguments
                let input=Pipe()
                if keepInputOpen { child.standardInput=input } else { child.standardInput=FileHandle.nullDevice }
                child.standardOutput = pipe
                child.standardError = errorPipe
                errors.drain(errorPipe)
                var environment = ProcessInfo.processInfo.environment
                environment["LC_ALL"] = "C"; environment["SSH_ASKPASS_REQUIRE"] = "never"
                child.environment = environment
                self.lock.lock()
                if self.cancelled { self.lock.unlock(); continuation.resume(throwing: HomeEgressFailure.cancelled); return }
                self.process = child
                do { try child.run() } catch {
                    self.process = nil; self.lock.unlock()
                    errorPipe.fileHandleForReading.readabilityHandler = nil
                    try? errorPipe.fileHandleForReading.close(); try? errorPipe.fileHandleForWriting.close()
                    continuation.resume(throwing: HomeEgressFailure.sshDiagnostic(phase: phase, category: .launch_failed, exitCode: nil, osCode: (error as NSError).code)); return
                }
                self.lock.unlock()
                let deadline = DispatchWorkItem {
                    self.lock.lock(); self.expired = true; let running = self.process; self.lock.unlock()
                    if running?.isRunning == true { running?.terminate() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
                var output = Data(), oversized = false
                while true {
                    let chunk = pipe.fileHandleForReading.readData(ofLength: 4096)
                    if chunk.isEmpty { break }
                    if output.count + chunk.count > outputLimit {
                        oversized = true
                        if child.isRunning { child.terminate() }
                        break
                    }
                    output.append(chunk)
                }
                child.waitUntilExit()
                if keepInputOpen { try? input.fileHandleForWriting.close() }
                deadline.cancel()
                let category = errors.finish(errorPipe)
                try? pipe.fileHandleForReading.close()
                self.lock.lock(); let wasCancelled = self.cancelled, wasExpired = self.expired; self.process = nil; self.lock.unlock()
                if wasCancelled { continuation.resume(throwing: HomeEgressFailure.cancelled) }
                else if wasExpired { continuation.resume(throwing: HomeEgressFailure.timedOut) }
                else if oversized || child.terminationStatus != 0 { continuation.resume(throwing: HomeEgressFailure.sshDiagnostic(phase: phase, category: oversized ? .oversized_output : category, exitCode: child.terminationStatus, osCode: nil)) }
                else { continuation.resume(returning: output) }
            }
        }
    }
}

private final class HomeEgressNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // A local API readiness request never follows another origin with its cookie.
        completionHandler(nil)
    }
}

@MainActor final class HomeEgressModel: ObservableObject {
    @Published var route: HomeEgressRoute = .lan
    @Published var mode: HomeEgressMode = .automatic {
        didSet { preferences?.set(mode.rawValue, forKey: "HomeEgressConnectionMode") }
    }
    @Published private(set) var networkStatus = ""
    @Published private(set) var connecting = false
    @Published private(set) var status = "Не подключено"
    @Published private(set) var notice: String?
    @Published private(set) var session: HomeEgressBrowserSession?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var command: HomeEgressSSHCommand?
    private var tunnel: Process?
    private let preferences: UserDefaults?
    private var networkMonitor: NWPathMonitor?
    private var network = HomeEgressNetworkSnapshot.current()
    private var reconnectTask: Task<Void, Never>?
    private var wantsConnection = false

    init(observeNetwork: Bool = true, preferences: UserDefaults? = .standard) {
        self.preferences = preferences
        if let saved = preferences?.string(forKey: "HomeEgressConnectionMode"), let selection = HomeEgressMode(rawValue: saved) { mode = selection }
        networkStatus = network.label
        if observeNetwork {
            let monitor = NWPathMonitor(); networkMonitor = monitor
            monitor.pathUpdateHandler = { [weak self] path in
                let current = HomeEgressNetworkSnapshot.current(available: path.status == .satisfied)
                Task { @MainActor in self?.networkChanged(current) }
            }
            monitor.start(queue: DispatchQueue(label: "sshobservatory.home.network", qos: .utility))
        }
    }
    deinit { networkMonitor?.cancel() }

    func networkChanged(_ current: HomeEgressNetworkSnapshot) {
        guard network != current else { return }
        network = current; networkStatus = current.label
        guard wantsConnection else { return }
        disconnect(keepIntent: true)
        status = "Сеть изменилась · проверка пути Home…"
        guard current.available || current.hasLANCandidate else {
            notice = "Нет доступной сети. Ручные операции не повторяются."; return
        }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled, let self, self.wantsConnection else { return }
            self.reconnectTask = nil
            self.connect()
        }
    }

    func connect(route explicitRoute: HomeEgressRoute? = nil) {
        guard (try? HomeAccessConfiguration.load()) != nil else {
            notice="Home access is not configured. Add your private home-access.json and SSH aliases.";return
        }
        guard !connecting && session == nil else { return }
        if let explicitRoute { mode = explicitRoute == .lan ? .lan : .kz }
        disconnect(keepIntent: true)
        wantsConnection = true
        network = HomeEgressNetworkSnapshot.current(); networkStatus = network.label
        route = mode.initialRoute(network: network)
        let ticket = generation, selectedMode = mode
        var selectedRoute = route
        connecting = true; status = "Проверка SSH и сервера…"; notice = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let identity: Data
                do {
                    identity = try await self.execute(selectedRoute.commandArguments("hostname"), phase: .hostname)
                } catch {
                    guard self.generation == ticket && !Task.isCancelled else { return }
                    guard selectedRoute == .lan, selectedMode.allowsLANFallback(after: error) else { throw error }
                    selectedRoute = .kz; self.route = .kz
                    self.status = "LAN недоступна · проверка резерва KZ…"
                    identity = try await self.execute(selectedRoute.commandArguments("hostname"), phase: .hostname)
                }
                guard self.generation == ticket && !Task.isCancelled else { return }
                try HomeEgressTransport.validateIdentity(identity)
                self.status = "Создание временной сессии…"
                let response = try await self.execute(selectedRoute.commandArguments(HomeEgressTransport.sessionCommand), phase: .session)
                guard self.generation == ticket && !Task.isCancelled else { return }
                let credentials = try JSONDecoder().decode(HomeEgressCredentials.self, from: response)
                let port = try HomeEgressTransport.availableLoopbackPort()
                let child = Process()
                child.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                child.arguments = selectedRoute.tunnelArguments(localPort: port)
                child.standardInput = FileHandle.nullDevice; child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
                var environment = ProcessInfo.processInfo.environment
                environment["LC_ALL"] = "C"; environment["SSH_ASKPASS_REQUIRE"] = "never"; child.environment = environment
                child.terminationHandler = { [weak self] process in
                    Task { @MainActor in
                        guard let self, self.generation == ticket, self.tunnel === process else { return }
                        let recover = self.session != nil && self.wantsConnection && selectedMode == .automatic
                        self.disconnect(keepIntent: recover)
                        self.notice = "SSH-соединение завершилось. Подключитесь снова; операции не повторяются автоматически."
                        // Only a previously established connection is recovered.
                        // The new strict hostname/auth check may stop recovery;
                        // a failed attempt never loops on its own.
                        if recover {
                            self.status = "SSH прервался · повторная проверка пути…"
                            self.scheduleReconnect()
                        }
                    }
                }
                self.tunnel = child
                try child.run()
                self.status = "Проверка ядра через SSH…"
                let url = URL(string: "http://127.0.0.1:\(port)/")!
                try await self.waitForAPI(baseURL: url, credentials: credentials, ticket: ticket)
                guard self.generation == ticket && !Task.isCancelled else { return }
                self.session = HomeEgressBrowserSession(baseURL: url, credentials: credentials)
                self.connecting = false; self.status = "Подключено · \(selectedRoute == .lan ? "LAN" : "резерв KZ")\(selectedMode == .automatic ? " · авто" : " · вручную")"; self.task = nil
            } catch {
                guard self.generation == ticket else { return }
                if case let HomeEgressFailure.sshDiagnostic(phase, category, exitCode, osCode) = error {
                    // All fields are fixed enums or numeric codes, never raw stderr.
                    fputs("HOME_SSH_FAILURE phase=\(phase.rawValue) category=\(category.rawValue) exit=\(exitCode.map(String.init) ?? "none") os=\(osCode.map(String.init) ?? "none")\n", stderr)
                }
                self.disconnect(keepIntent: HomeEgressMode.mayResumeAfterNetworkChange(error))
                self.notice = (error as? HomeEgressFailure)?.localizedDescription ?? "Не удалось открыть сессию Home. Секреты не сохранялись; попробуйте подключиться снова."
            }
        }
    }

    private func execute(_ arguments: [String], phase: HomeEgressSSHPhase) async throws -> Data {
        let runner = HomeEgressSSHCommand(); command = runner
        defer { if command === runner { command = nil } }
        return try await runner.run(arguments: arguments, phase: phase)
    }

    private func waitForAPI(baseURL: URL, credentials: HomeEgressCredentials, ticket: UUID) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil; configuration.timeoutIntervalForRequest = 1
        let client = URLSession(configuration: configuration, delegate: HomeEgressNoRedirect(), delegateQueue: nil)
        defer { client.invalidateAndCancel() }
        // A multi-hop KZ SSH transport can take several seconds before it binds
        // the local listener. Connection-refused is immediate, so a fixed seven
        // retries previously expired in about1.4s even with a healthy tunnel.
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            guard generation == ticket && !Task.isCancelled else { throw HomeEgressFailure.cancelled }
            guard tunnel?.isRunning == true else { throw HomeEgressFailure.ssh }
            var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/session"))
            request.setValue("home_egress_session=\(credentials.sessionToken)", forHTTPHeaderField: "Cookie")
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            do {
                let (data, response) = try await client.data(for: request)
                if let code = (response as? HTTPURLResponse)?.statusCode, [401,403].contains(code) {
                    throw HomeEgressFailure.invalidSession
                }
                if (response as? HTTPURLResponse)?.statusCode == 200,
                   data.count < 16384,
                   let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   body["csrf_token"] as? String == credentials.csrfToken { return }
            } catch is CancellationError { throw HomeEgressFailure.cancelled }
            catch HomeEgressFailure.invalidSession { throw HomeEgressFailure.invalidSession }
            catch { /* The forward may still be establishing; bounded read retry only. */ }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw HomeEgressFailure.apiUnavailable
    }

    func disconnect(keepIntent: Bool = false) {
        if !keepIntent { wantsConnection = false }
        reconnectTask?.cancel(); reconnectTask = nil
        generation = UUID()
        task?.cancel(); task = nil
        command?.cancel(); command = nil
        let oldTunnel = tunnel; tunnel = nil
        oldTunnel?.terminationHandler = nil
        if oldTunnel?.isRunning == true { oldTunnel?.terminate() }
        session = nil; connecting = false; status = "Не подключено"
    }
    func webContentFailed() {
        disconnect()
        notice = "Окно панели завершилось. Подключитесь снова, чтобы открыть новую временную сессию."
    }
}

struct HomeEgressView: View {
    @ObservedObject var model: HomeEgressModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Home · защищённый выход", systemImage: "shield.lefthalf.filled").font(.title2.weight(.medium))
                    Text(model.status).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Путь SSH", selection: $model.mode) {
                    ForEach(HomeEgressMode.allCases) { mode in Text(mode.label).tag(mode) }
                }
                .labelsHidden().frame(width: 238)
                .disabled(model.connecting || model.session != nil)
                if model.connecting || model.session != nil {
                    Button("Отключить") { model.disconnect() }.buttonStyle(.bordered)
                } else {
                    Button("Подключить по SSH") { model.connect() }.buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 20).padding(.top, 16)
            if let notice = model.notice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange).padding(.horizontal, 20)
            }
            if let session = model.session {
                HomeEgressWebView(session: session, onFailure: { model.webContentFailed() })
            } else if model.connecting {
                VStack(spacing: 14) {
                    ProgressView()
                    Text(model.status).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("Управление сетью Home", systemImage: "network.badge.shield.half.filled")
                } description: {
                    Text("Карта сервисов и маршрутов, выбор VPN-ноды, защищённый запуск и API для CRM. Подключение начнётся только по вашей кнопке.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text("Доступ только с этого Mac через SSH. Авто: дома LAN, вне дома KZ. Ручной выбор сохраняется; операции не повторяются.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.bottom, 12)
        }
        .frame(minWidth: 780, minHeight: 580)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct HomeEgressWebView: NSViewRepresentable {
    let session: HomeEgressBrowserSession
    let onFailure: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(baseURL: session.baseURL, onFailure: onFailure) }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator; view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = false
        view.isInspectable = false
        return view
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {
        guard context.coordinator.loadedSession != session.id else { return }
        context.coordinator.loadedSession = session.id
        guard let cookie = HomeEgressTransport.cookie(session.credentials) else { onFailure(); return }
        let ticket = session.id
        nsView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) { [weak nsView, weak coordinator = context.coordinator] in
            guard coordinator?.loadedSession == ticket else { return }
            nsView?.load(URLRequest(url: session.baseURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData))
        }
    }
    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.loadedSession = nil
        nsView.stopLoading(); nsView.navigationDelegate = nil; nsView.uiDelegate = nil
        let store = nsView.configuration.websiteDataStore
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast, completionHandler: {})
    }
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let baseURL: URL
        let onFailure: () -> Void
        var loadedSession: UUID?
        init(baseURL: URL, onFailure: @escaping () -> Void) { self.baseURL = baseURL; self.onFailure = onFailure }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard navigationAction.targetFrame != nil, let url = navigationAction.request.url,
                  HomeEgressTransport.isAllowed(url, base: baseURL) else { decisionHandler(.cancel); return }
            decisionHandler(.allow)
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { onFailure() }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { onFailure() }
        }
    }
}
