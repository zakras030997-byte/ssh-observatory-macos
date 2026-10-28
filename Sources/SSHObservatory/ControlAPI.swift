import Foundation
import Security

enum ControlAPIError: Error, LocalizedError {
    case configuration, identity, trust, invalidRequest, invalidResponse, oversizedResponse
    case unavailable, conflict, expired, forbidden, busy, notFound, canceled
    var errorDescription: String? {
        switch self {
        case .configuration: return "Укажите HTTPS-адрес API и сертификат доверия сервера."
        case .identity: return "Клиентский сертификат недоступен или не принят сервером. Проверьте выбранную запись в Связке ключей."
        case .trust: return "Не удалось подтвердить защищённое соединение с API."
        case .invalidRequest: return "Проверьте параметры операции."
        case .invalidResponse: return "Ответ API не соответствует ожидаемому контракту."
        case .oversizedResponse: return "Ответ API превышает допустимый размер."
        case .unavailable: return "Нет подтверждённого ответа API. Уточните состояние операции перед новым действием."
        case .conflict: return "Состояние изменилось или подтверждение уже использовано. Обновите результат."
        case .expired: return "Подтверждение истекло. Обновите результат операции."
        case .forbidden: return "API не подтвердил право на это действие."
        case .busy: return "API временно занят. Повторите только проверку состояния."
        case .notFound: return "Объект не найден. Изменение не подтверждено."
        case .canceled: return "Запрос прерван; результат серверной операции нужно уточнить."
        }
    }
}

struct ControlConnectionProfile: Codable, Equatable {
    var endpoint: String
    var serverCA: Data
    var identityLabel: String
    func validatedEndpoint() throws -> URL {
        guard endpoint.utf8.count<=2048,
              !endpoint.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains),
              let c = URLComponents(string:endpoint), c.scheme == "https",
              let host=c.host, !host.isEmpty, host.count<=253,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.path.isEmpty || c.path == "/", (c.port.map { (1...65535).contains($0) } ?? true),
              !serverCA.isEmpty, serverCA.count<=65_536,
              !identityLabel.isEmpty, identityLabel.count<=120,
              !identityLabel.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains),
              let url=c.url else { throw ControlAPIError.configuration }
        return url
    }
}

enum ControlAction: String, Codable { case issue = "issue_owner_key", extend = "extend_owner_key_days" }
enum ControlOperationState: String, Codable {
    case prepared, queued, running, succeeded, failed, unknown, expired, canceled
    var terminal: Bool { [.succeeded,.failed,.expired,.canceled].contains(self) }
    var title: String {
        switch self {
        case .prepared:return "Подготовлено"
        case .queued:return "В очереди сервера"
        case .running:return "Выполняется на сервере"
        case .succeeded:return "Результат подтверждён"
        case .failed:return "Сервер сообщил об ошибке"
        case .unknown:return "Результат неизвестен — нужна сверка"
        case .expired:return "Подтверждение истекло"
        case .canceled:return "Отменено до выполнения"
        }
    }
}

struct ControlPreviewRequest: Codable, Equatable {
    let operationID: String
    let action: ControlAction
    var keyID: String? = nil
    var days: Int? = nil
    var timeMode: String? = nil
    var timeValue: Int? = nil
    var trafficMode: String? = nil
    var trafficGB: Int? = nil
    enum CodingKeys:String,CodingKey {
        case operationID="operation_id",action,keyID="key_id",days,timeMode="time_mode",timeValue="time_value",trafficMode="traffic_mode",trafficGB="traffic_gb"
    }
    static func newID() -> String { UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased() }
    static func validID(_ s:String) -> Bool { s.range(of:"^[0-9a-f]{32}$",options:.regularExpression) != nil }
    func validate() throws {
        guard Self.validID(operationID) else { throw ControlAPIError.invalidRequest }
        switch action {
        case .issue:
            guard keyID == nil, days == nil, ["days","periods","unlimited"].contains(timeMode ?? ""),
                  ["standard","custom","unlimited"].contains(trafficMode ?? "") else { throw ControlAPIError.invalidRequest }
            if timeMode == "unlimited" { guard timeValue == nil else { throw ControlAPIError.invalidRequest } }
            else { guard let n=timeValue, (1...(timeMode == "days" ? 3650:120)).contains(n) else { throw ControlAPIError.invalidRequest } }
            if trafficMode == "custom" { guard let n=trafficGB,(1...100_000).contains(n) else { throw ControlAPIError.invalidRequest } }
            else { guard trafficGB == nil else { throw ControlAPIError.invalidRequest } }
        case .extend:
            guard let k=keyID, UUID(uuidString:k) != nil, let n=days,(1...3650).contains(n),
                  timeMode == nil,timeValue == nil,trafficMode == nil,trafficGB == nil else { throw ControlAPIError.invalidRequest }
        }
    }
}

struct ControlOperationReceipt: Codable, Equatable, Identifiable {
    let operationID:String
    let action:ControlAction
    let state:ControlOperationState
    let summary:String
    let expiresAt:String?
    let keyID:String?
    let orderID:String?
    let errorCode:String?
    var confirmationToken:String?
    var id:String { operationID }
    enum CodingKeys:String,CodingKey {
        case operationID="operation_id",action,state,summary,expiresAt="expires_at",keyID="key_id",orderID="order_id",errorCode="error_code",confirmationToken="confirmation_token"
    }
    func validated(for request:ControlPreviewRequest) throws -> Self {
        guard operationID==request.operationID, action==request.action, summary.count<=2048,
              !summary.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" }),
              keyID.map({ UUID(uuidString:$0) != nil }) ?? true,
              orderID.map({ UUID(uuidString:$0) != nil }) ?? true,
              errorCode.map({ $0.count<=80 && $0.range(of:"^[A-Za-z0-9_.-]+$",options:.regularExpression) != nil }) ?? true,
              confirmationToken.map({ !$0.isEmpty && $0.count<=512 && $0.range(of:"^[A-Za-z0-9_=-]+$",options:.regularExpression) != nil }) ?? true,
              expiresAt.map({ Self.parseDate($0) != nil }) ?? true
        else { throw ControlAPIError.invalidResponse }
        if action == .extend, let keyID, keyID != request.keyID { throw ControlAPIError.invalidResponse }
        return self
    }
    static func parseDate(_ value:String) -> Date? {
        let formatter=ISO8601DateFormatter();formatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        if let date=formatter.date(from:value) { return date }
        formatter.formatOptions=[.withInternetDateTime];return formatter.date(from:value)
    }
}

struct ControlOwnerKey: Decodable, Identifiable, Equatable {
    let keyID:String, name:String, state:String
    let expiresAt:String?
    let timeUnlimited:Bool, trafficUnlimited:Bool
    let usedBytes:Int64?, limitBytes:Int64?
    var id:String { keyID }
    enum CodingKeys:String,CodingKey {
        case keyID="key_id",name,state,expiresAt="expires_at",timeUnlimited="time_unlimited",trafficUnlimited="traffic_unlimited",usedBytes="used_bytes",limitBytes="limit_bytes"
    }
    func validate() throws {
        guard UUID(uuidString:keyID) != nil, name.count<=200,state.count<=80,
              state.range(of:"^[A-Za-z0-9_.-]+$",options:.regularExpression) != nil,
              !name.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains),
              expiresAt.map({ ControlOperationReceipt.parseDate($0) != nil }) ?? true,
              usedBytes.map({ $0>=0 }) ?? true,limitBytes.map({ $0>=0 }) ?? true else { throw ControlAPIError.invalidResponse }
    }
}
struct ControlKeyPage: Decodable { let items:[ControlOwnerKey];let hasMore:Bool;enum CodingKeys:String,CodingKey {case items,hasMore="has_more"} }
struct ControlCapabilities: Decodable { let apiVersion:Int;let features:[String];enum CodingKeys:String,CodingKey {case apiVersion="api_version",features} }

protocol ControlHTTPTransport: AnyObject {
    func send(method:String,path:String,query:[URLQueryItem],body:Data?) async throws -> (Int,Data)
}

/// One explicitly configured mTLS endpoint; no redirects, cookies, external trust overrides or raw error logs.
final class MutualTLSControlTransport: NSObject, ControlHTTPTransport, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let endpoint:URL
    private let ca:SecCertificate
    private let identity:SecIdentity
    private var session:URLSession!
    convenience init(profile:ControlConnectionProfile) throws {
        _=try profile.validatedEndpoint()
        var result:CFTypeRef?
        let query:[CFString:Any]=[kSecClass:kSecClassIdentity,kSecAttrLabel:profile.identityLabel,kSecReturnRef:true,kSecMatchLimit:kSecMatchLimitOne]
        guard SecItemCopyMatching(query as CFDictionary,&result)==errSecSuccess,let result,
              CFGetTypeID(result)==SecIdentityGetTypeID() else { throw ControlAPIError.identity }
        try self.init(profile:profile,identity:result as! SecIdentity)
    }
    #if CONTROL_API_TESTS
    convenience init(fixtureProfile:ControlConnectionProfile,fixtureIdentity:SecIdentity) throws {
        try self.init(profile:fixtureProfile,identity:fixtureIdentity)
    }
    #endif
    private init(profile:ControlConnectionProfile,identity:SecIdentity) throws {
        endpoint=try profile.validatedEndpoint()
        guard let certificate=SecCertificateCreateWithData(nil,profile.serverCA as CFData) else { throw ControlAPIError.configuration }
        ca=certificate;self.identity=identity
        super.init()
        let config=URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies=false;config.httpCookieStorage=nil;config.urlCache=nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Keychain-backed client-certificate signing can take longer than a network RTT.
        // Keep a bounded request without aborting a valid first mTLS handshake.
        config.timeoutIntervalForRequest=45;config.timeoutIntervalForResource=60
        config.waitsForConnectivity=false;config.httpMaximumConnectionsPerHost=2
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        session=URLSession(configuration:config,delegate:self,delegateQueue:nil)
    }
    deinit { session?.invalidateAndCancel() }
    func close() { session.invalidateAndCancel() }
    func send(method:String,path:String,query:[URLQueryItem]=[],body:Data?) async throws -> (Int,Data) {
        guard ["GET","POST"].contains(method),(path.hasPrefix("/v1/") || path.hasPrefix("/v2/")),!path.contains(".."),!path.contains("?"),!path.contains("#"),body.map({$0.count<=8192}) ?? true else { throw ControlAPIError.invalidRequest }
        var c=URLComponents(url:endpoint,resolvingAgainstBaseURL:false)!;c.path=path;c.queryItems=query.isEmpty ? nil:query
        guard let url=c.url else { throw ControlAPIError.configuration }
        var request=URLRequest(url:url);request.httpMethod=method;request.httpBody=body
        request.setValue("application/json",forHTTPHeaderField:"Accept")
        if body != nil { request.setValue("application/json",forHTTPHeaderField:"Content-Type") }
        let bytes:URLSession.AsyncBytes,response:URLResponse
        do { (bytes,response)=try await session.bytes(for:request) }
        catch is CancellationError { throw ControlAPIError.canceled }
        catch {
            let failure=error as NSError
            #if CONTROL_API_TESTS
            print("Fixture transport failure: \(failure.domain) \(failure.code)")
            #endif
            if failure.domain==NSURLErrorDomain {
                switch failure.code {
                case NSURLErrorClientCertificateRejected:throw ControlAPIError.forbidden
                case NSURLErrorClientCertificateRequired:throw ControlAPIError.identity
                case NSURLErrorSecureConnectionFailed,NSURLErrorServerCertificateUntrusted,NSURLErrorServerCertificateHasBadDate,
                     NSURLErrorServerCertificateHasUnknownRoot,NSURLErrorServerCertificateNotYetValid:
                    throw ControlAPIError.trust
                case NSURLErrorCancelled:throw ControlAPIError.canceled
                default:break
                }
            }
            throw ControlAPIError.unavailable
        }
        defer { bytes.task.cancel() }
        guard let http=response as? HTTPURLResponse,
              response.url?.host==endpoint.host,response.url?.scheme=="https",
              response.url?.port==endpoint.port,
              response.expectedContentLength<=524_288 else { throw ControlAPIError.invalidResponse }
        guard http.mimeType=="application/json" else { throw ControlAPIError.invalidResponse }
        var data=Data()
        do {
            for try await byte in bytes {
                guard data.count<524_288 else { throw ControlAPIError.oversizedResponse }
                data.append(byte)
            }
        } catch let error as ControlAPIError { throw error }
        catch { throw ControlAPIError.unavailable }
        return (http.statusCode,data)
    }
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping (URLRequest?)->Void) { completionHandler(nil) }
    func urlSession(_ session:URLSession,task:URLSessionTask,didReceive challenge:URLAuthenticationChallenge,completionHandler:@escaping (URLSession.AuthChallengeDisposition,URLCredential?)->Void) {
        urlSession(session,didReceive:challenge,completionHandler:completionHandler)
    }
    func urlSession(_ session:URLSession,didReceive challenge:URLAuthenticationChallenge,completionHandler:@escaping (URLSession.AuthChallengeDisposition,URLCredential?)->Void) {
        let space=challenge.protectionSpace
        #if CONTROL_API_TESTS
        print("Fixture authentication: \(space.authenticationMethod)")
        #endif
        guard space.host==endpoint.host,space.port==(endpoint.port ?? 443),challenge.previousFailureCount==0 else { completionHandler(.cancelAuthenticationChallenge,nil);return }
        switch space.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            guard let trust=space.serverTrust,
                  SecTrustSetPolicies(trust,SecPolicyCreateSSL(true,space.host as CFString))==errSecSuccess,
                  SecTrustSetAnchorCertificates(trust,[ca] as CFArray)==errSecSuccess,
                  SecTrustSetAnchorCertificatesOnly(trust,true)==errSecSuccess,
                  SecTrustEvaluateWithError(trust,nil) else { completionHandler(.cancelAuthenticationChallenge,nil);return }
            completionHandler(.useCredential,URLCredential(trust:trust))
        case NSURLAuthenticationMethodClientCertificate:
            completionHandler(.useCredential,URLCredential(identity:identity,certificates:nil,persistence:.forSession))
        default:completionHandler(.cancelAuthenticationChallenge,nil)
        }
    }
}

final class ControlAPIClient {
    private let transport:ControlHTTPTransport
    init(transport:ControlHTTPTransport) { self.transport=transport }
    private func call<T:Decodable>(_ type:T.Type,method:String,path:String,query:[URLQueryItem]=[],body:Data?=nil) async throws -> T {
        let (status,data)=try await transport.send(method:method,path:path,query:query,body:body)
        guard data.count<=524_288 else { throw ControlAPIError.oversizedResponse }
        guard (200...299).contains(status) else {
            switch status {
            case 401,403:throw ControlAPIError.forbidden
            case 404:throw ControlAPIError.notFound
            case 409:throw ControlAPIError.conflict
            case 410:throw ControlAPIError.expired
            case 429,503:throw ControlAPIError.busy
            default:throw ControlAPIError.invalidResponse
            }
        }
        do { return try JSONDecoder().decode(type,from:data) } catch { throw ControlAPIError.invalidResponse }
    }
    func capabilities() async throws -> ControlCapabilities {
        let value=try await call(ControlCapabilities.self,method:"GET",path:"/v1/capabilities")
        guard value.apiVersion==1,value.features.count<=32,
              ["issue_owner_key","extend_owner_key_days","operation_status","owner_keys"].allSatisfy(value.features.contains) else { throw ControlAPIError.invalidResponse }
        return value
    }
    func ownerKeys(archived:Bool=false) async throws -> [ControlOwnerKey] {
        var items:[ControlOwnerKey]=[]
        for offset in stride(from:0,to:1000,by:100) {
            let page=try await call(ControlKeyPage.self,method:"GET",path:"/v1/owner/keys",query:[.init(name:"archived",value:archived ? "true":"false"),.init(name:"limit",value:"100"),.init(name:"offset",value:String(offset))])
            guard page.items.count<=100 else { throw ControlAPIError.invalidResponse }
            try page.items.forEach { try $0.validate() };items.append(contentsOf:page.items)
            guard Set(items.map(\.keyID)).count==items.count else { throw ControlAPIError.invalidResponse }
            if !page.hasMore { return items }
            guard !page.items.isEmpty else { throw ControlAPIError.invalidResponse }
        }
        throw ControlAPIError.oversizedResponse
    }
    func preview(_ request:ControlPreviewRequest) async throws -> ControlOperationReceipt {
        try request.validate()
        let receipt=try await call(ControlOperationReceipt.self,method:"POST",path:"/v1/operations/previews",body:JSONEncoder().encode(request)).validated(for:request)
        if receipt.state == .prepared { guard receipt.confirmationToken != nil else { throw ControlAPIError.invalidResponse } }
        return receipt
    }
    func confirm(_ request:ControlPreviewRequest,token:String) async throws -> ControlOperationReceipt {
        try request.validate();guard !token.isEmpty,token.count<=512 else { throw ControlAPIError.invalidRequest }
        return try await call(ControlOperationReceipt.self,method:"POST",path:"/v1/operations/\(request.operationID)/confirm",body:JSONSerialization.data(withJSONObject:["confirmation_token":token])).validated(for:request)
    }
    func status(_ request:ControlPreviewRequest) async throws -> ControlOperationReceipt {
        try request.validate()
        var receipt=try await call(ControlOperationReceipt.self,method:"GET",path:"/v1/operations/\(request.operationID)").validated(for:request)
        // A status response is evidence only, never fresh authority to mutate.
        receipt.confirmationToken=nil
        return receipt
    }
    func cancel(_ request:ControlPreviewRequest,token:String) async throws -> ControlOperationReceipt {
        try request.validate();guard !token.isEmpty,token.count<=512 else { throw ControlAPIError.invalidRequest }
        return try await call(ControlOperationReceipt.self,method:"POST",path:"/v1/operations/\(request.operationID)/cancel",body:JSONSerialization.data(withJSONObject:["confirmation_token":token])).validated(for:request)
    }
}
