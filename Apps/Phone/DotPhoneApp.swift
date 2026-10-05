import SwiftUI

@main
struct DotPhoneApp: App {
    @StateObject private var model = PhoneModel.shared
    @Environment(\.scenePhase) private var scenePhase
    init() {
        // Install the WC delegate even for a Watch-triggered background launch.
        _ = PhoneModel.shared
    }

    var body: some Scene {
        WindowGroup {
            PhoneView(model: model)
                .task { await model.load() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await model.consumePrivateTransferIfPresent() } }
                }
                .onOpenURL { url in
                    if url.scheme == "dotwatch-private", url.host == "setup" {
                        Task { await model.consumePrivateTransferIfPresent() }
                    }
                }
        }
    }
}
