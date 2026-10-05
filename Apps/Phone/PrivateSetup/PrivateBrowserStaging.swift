import Foundation
import DotCore

/// Public upgrades use the location only to delete a pending private handoff.
/// This type never reads or decodes its contents.
public enum BrowserStagingLocation {
    public static var url: URL? {
        #if os(iOS)
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.dev.dotwatch.app.private-setup")?
            .appendingPathComponent("PrivateSetup", isDirectory: true).appendingPathComponent("session.json")
        #else
        nil
        #endif
    }
}

#if PERSONAL_DIAGNOSTICS
public enum PrivateBrowserStaging {
    public static var url: URL? { BrowserStagingLocation.url }

    /// A local bridge inside the signed app group, not a credential in a URL,
    /// clipboard, Safari storage, shared filesystem export or hosted service.
    public static func stage(_ transfer: PrivateCredentialTransfer) throws {
        guard let url else { throw DotError.invalidCredentials }
        if FileManager.default.fileExists(atPath: url.path) {
            let pending = try PrivateCredentialTransfer(data: Data(contentsOf: url), existingAccountID: nil)
            guard pending.credentials.accountID == transfer.credentials.accountID else {
                throw DotError.accountChangeRequiresSignOut
            }
        }
        let directory = url.deletingLastPathComponent()
        #if os(iOS)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var mutable = directory, values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutable.setResourceValues(values)
        try transfer.canonicalData().write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        throw DotError.invalidCredentials
        #endif
    }
}
#endif
