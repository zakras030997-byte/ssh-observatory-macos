import Foundation
import Darwin

/// Optional deployment metadata. No host, user, key or reserve is bundled.
struct HomeAccessConfiguration: Codable {
    let lanAlias:String
    let reserveAlias:String
    let lanAddress:String
    let expectedHostname:String
    let units:[String]
    static func load() throws -> Self {
        let path=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/SSH Observatory/home-access.json")
        let handle=try FileHandle(forReadingFrom:path);defer{try? handle.close()}
        let data=try handle.read(upToCount:16385) ?? Data()
        guard data.count<=16384 else{throw HomeEgressFailure.invalidSession}
        let value=try JSONDecoder().decode(Self.self,from:data)
        let alias="^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$"
        var address=in_addr()
        guard value.lanAlias.range(of:alias,options:.regularExpression) != nil,
              value.reserveAlias.range(of:alias,options:.regularExpression) != nil,
              value.expectedHostname.range(of:"^[A-Za-z0-9][A-Za-z0-9_.-]{0,254}$",options:.regularExpression) != nil,
              inet_pton(AF_INET,value.lanAddress,&address)==1,
              value.units.count<=16,value.units.allSatisfy({$0.range(of:"^[A-Za-z0-9_][A-Za-z0-9_.@:-]{0,119}\\.service$",options:.regularExpression) != nil})
        else{throw HomeEgressFailure.invalidSession}
        return value
    }
}
