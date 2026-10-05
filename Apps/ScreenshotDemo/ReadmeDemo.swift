import Foundation

/// Credential-free screenshots of the real SwiftUI screens. This launch flag
/// exists only in private simulator builds, never in a physical or public app.
enum ReadmeDemo {
    #if targetEnvironment(simulator) && PERSONAL_DIAGNOSTICS
    static var enabled: Bool { CommandLine.arguments.contains("--readme-demo") }
    #else
    static let enabled = false
    #endif
}
