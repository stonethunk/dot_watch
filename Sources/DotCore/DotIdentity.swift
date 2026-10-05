import Foundation

public struct DotIdentity: Sendable, Equatable {
    public let dotID: String
    public let threadID: String
    public let snapshotURL: URL
    public let snapshotSHA256: String
    public let appearanceVersion: String
    public let snapshotWidth: Int
    public let snapshotHeight: Int

    public init(primary: JSONValue) throws {
        let selection = primary["selection"]
        let profile = primary["profile"]
        guard selection["available"].bool == true else { throw DotError.unavailable }
        guard let dot = selection["aeon_id"].string, Self.safeIdentifier(dot),
              profile["id"].string == dot,
              let thread = selection["thread_id"].string, Self.safeIdentifier(thread),
              profile["active_root_thread_id"].string == thread else { throw DotError.identityMismatch }
        let snapshot = profile["avatar_manifest"]["snapshot"]
        guard profile["avatar_type"].string == "rendered-interactive",
              let urlString = profile["avatar_url"].string,
              let url = URL(string: urlString),
              let hash = snapshot["content_sha256"].string, Self.isHash(hash),
              let version = snapshot["manifest_sha256"].string, Self.isHash(version),
              let width = snapshot["width"].int, width > 0, width <= 8192,
              let height = snapshot["height"].int, height > 0, height <= 8192 else { throw DotError.invalidResponse }
        try EndpointPolicy.validateSnapshot(url)
        dotID = dot
        threadID = thread
        snapshotURL = url
        snapshotSHA256 = hash.lowercased()
        appearanceVersion = version.lowercased()
        snapshotWidth = width
        snapshotHeight = height
    }

    private static func isHash(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }
    }

    private static func safeIdentifier(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_~-]{1,128}$", options: .regularExpression) != nil
    }
}

public enum EndpointPolicy {
    public static let api = URL(string: "https://chatgpt.com/backend-api/")!
    public static let cloud = URL(string: "https://codex-cloud-backend.chatgpt.com/")!
    public static let socket = URL(string: "wss://codex-cloud-backend.chatgpt.com/")!

    public static func validateAuthenticated(_ url: URL) throws {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              ["chatgpt.com", "codex-cloud-backend.chatgpt.com"].contains(url.host?.lowercased() ?? "") else { throw DotError.unsafeURL }
    }

    public static func validateSnapshot(_ url: URL) throws {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased(), host.hasSuffix(".oaiusercontent.com"),
              host.count > ".oaiusercontent.com".count else { throw DotError.unsafeURL }
    }
}
