import SwiftUI

@main struct DotWatchApp: App {
    @StateObject private var model = WatchModel()
    var body: some Scene {
        WindowGroup { WatchView(model: model) }
    }
}
