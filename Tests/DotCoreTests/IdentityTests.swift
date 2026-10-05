import Foundation
import Testing
@testable import DotCore

struct IdentityTests {
    func fixture() throws -> JSONValue {
        try JSONValue.decode(Data(contentsOf: Bundle.module.url(forResource: "primary", withExtension: "json", subdirectory: "Fixtures")!))
    }

    @Test func decodesSyntheticPrimary() throws {
        let dot = try DotIdentity(primary: fixture())
        #expect(dot.threadID == "fixture-thread")
        #expect(dot.dotID == "fixture-dot")
        #expect(dot.appearanceVersion.count == 64)
    }

    @Test func rejectsDifferentDotOrConversation() throws {
        for key in ["id", "active_root_thread_id"] {
            var root = try fixture().object!
            var profile = root["profile"]!.object!
            profile[key] = .string("someone-else")
            root["profile"] = .object(profile)
            #expect(throws: DotError.identityMismatch) { try DotIdentity(primary: .object(root)) }
        }
    }

    @Test func acceptsObservedTildeButRejectsPathAndQuerySyntax() throws {
        for identifier in ["fixture~dot", "../dot", "dot/other", "dot?query", "dot#fragment", "dot%2Fother"] {
            var root = try fixture().object!
            var selection = root["selection"]!.object!
            var profile = root["profile"]!.object!
            selection["aeon_id"] = .string(identifier)
            profile["id"] = .string(identifier)
            root["selection"] = .object(selection); root["profile"] = .object(profile)
            if identifier == "fixture~dot" {
                #expect(try DotIdentity(primary: .object(root)).dotID == identifier)
            } else {
                #expect(throws: DotError.identityMismatch) { try DotIdentity(primary: .object(root)) }
            }
        }
    }

    @Test func rejectsUnavailableDot() throws {
        var root = try fixture().object!
        root["selection"] = .object(["available": .bool(false)])
        #expect(throws: DotError.unavailable) { try DotIdentity(primary: .object(root)) }
    }

    @Test func rejectsCredentialExfiltrationOrigins() {
        for string in ["https://chatgpt.com.evil.test/", "http://chatgpt.com/", "https://chatgpt.com:444/", "https://user@chatgpt.com/"] {
            #expect(throws: DotError.unsafeURL) { try EndpointPolicy.validateAuthenticated(URL(string: string)!) }
        }
        for string in ["https://oaiusercontent.com.evil.test/a", "http://a.oaiusercontent.com/a", "https://user@a.oaiusercontent.com/a"] {
            #expect(throws: DotError.unsafeURL) { try EndpointPolicy.validateSnapshot(URL(string: string)!) }
        }
    }

    @Test func integerConversionIsBounded() {
        #expect(JSONValue.number(.infinity).int == nil)
        #expect(JSONValue.number(1e30).int == nil)
        #expect(JSONValue.number(1.5).int == nil)
        #expect(JSONValue.number(24000).int == 24000)
    }
}
