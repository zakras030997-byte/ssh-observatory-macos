import Foundation
import Darwin

enum HomeEgressMode: String, CaseIterable, Identifiable {
    case automatic, lan, kz
    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: return "Авто · LAN → KZ"
        case .lan: return "Только домашняя LAN"
        case .kz: return "Только резерв KZ"
        }
    }
    func initialRoute(network: HomeEgressNetworkSnapshot) -> HomeEgressRoute {
        switch self {
        case .automatic: return network.hasLANCandidate ? .lan : .kz
        case .lan: return .lan
        case .kz: return .kz
        }
    }
    func allowsLANFallback(after error: Error) -> Bool {
        guard self == .automatic else { return false }
        // Called only around the first hostname command, never around API,
        // credential or tunnel creation. Identity/auth/config failures stop.
        if case HomeEgressFailure.timedOut = error { return true }
        if case let HomeEgressFailure.sshDiagnostic(phase, category, _, _) = error,
           phase == .hostname {
            return [.network_route, .connection_refused, .timeout].contains(category)
        }
        return false
    }
    static func mayResumeAfterNetworkChange(_ error: Error) -> Bool {
        if case HomeEgressFailure.timedOut = error { return true }
        if case HomeEgressFailure.apiUnavailable = error { return true }
        if case let HomeEgressFailure.sshDiagnostic(_, category, _, _) = error {
            return [.network_route, .connection_refused, .timeout].contains(category)
        }
        return false
    }
}

struct HomeEgressNetworkSnapshot: Equatable {
    struct IPv4Interface: Equatable {
        let name: String
        let address: UInt32
        let mask: UInt32
        init(name: String, address: UInt32, mask: UInt32) {
            self.name = name; self.address = address; self.mask = mask
        }
        init(name: String, address: String, mask: String) {
            self.init(name: name, address: UInt32(bigEndian: inet_addr(address)),
                      mask: UInt32(bigEndian: inet_addr(mask)))
        }
        var isPhysicalCandidate: Bool {
            !["lo", "utun", "ipsec", "gif", "stf"].contains(where: name.hasPrefix)
        }
    }
    let available: Bool
    let interfaces: [IPv4Interface]
    var hasLANCandidate: Bool {
        guard let access=try? HomeAccessConfiguration.load() else{return false}
        let target = UInt32(bigEndian: inet_addr(access.lanAddress))
        return interfaces.contains { $0.isPhysicalCandidate && $0.mask != 0 &&
            ($0.address & $0.mask) == (target & $0.mask) }
    }
    var label: String {
        if !available { return "Сеть недоступна" }
        return hasLANCandidate ? "Проверка домашней LAN по SSH" : "Внешняя IPv4-сеть"
    }
    static func current(available: Bool = true) -> Self {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return Self(available: false, interfaces: []) }
        defer { freeifaddrs(first) }
        var cursor = first, values = [IPv4Interface]()
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let value = entry.pointee
            guard value.ifa_flags & UInt32(IFF_UP) != 0,
                  value.ifa_flags & UInt32(IFF_RUNNING) != 0,
                  value.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let address = value.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  let mask = value.ifa_netmask else { continue }
            let ip = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr
            let netmask = UnsafeRawPointer(mask).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr
            values.append(IPv4Interface(name: String(cString: value.ifa_name), address: UInt32(bigEndian: ip), mask: UInt32(bigEndian: netmask)))
        }
        values.sort { ($0.name, $0.address, $0.mask) < ($1.name, $1.address, $1.mask) }
        return Self(available: available, interfaces: values)
    }
}
