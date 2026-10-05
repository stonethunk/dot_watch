import SwiftUI

struct WatchView: View {
    @ObservedObject var model: WatchModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var dimmed
    @Environment(\.scenePhase) private var scenePhase
    #if PERSONAL_DIAGNOSTICS
    @StateObject private var audioTest = WatchAudioDiagnostic()
    @ObservedObject private var voice: WatchVoiceController
    #endif

    init(model: WatchModel) {
        self.model = model
        #if PERSONAL_DIAGNOSTICS
        self.voice = model.voice
        #endif
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Text(ReadmeDemo.enabled ? "Dot preview" : "Dot on Watch").font(.headline)
                if let character = model.character {
                    let still = ReadmeDemo.enabled || reduceMotion || dimmed || scenePhase != .active
                    TimelineView(.animation(minimumInterval: 0.1, paused: still)) { context in
                        let phase = context.date.timeIntervalSinceReferenceDate * 1.5
                        Image(uiImage: character).resizable().scaledToFit()
                            .scaleEffect(still ? 1 : characterScale(phase))
                            .accessibilityLabel("Your ChatGPT Dot")
                    }
                    .frame(height: 80)
                } else {
                    Text("Your Dot will appear here after iPhone setup.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(minHeight: 110)
                }
                #if PERSONAL_DIAGNOSTICS
                Text(voice.message).font(.caption2)
                if voice.busy {
                    if voice.active {
                        Button(voice.muted ? "Unmute" : "Mute", systemImage: voice.muted ? "mic.slash" : "mic") { voice.toggleMute() }
                    }
                    Button("End", systemImage: "stop.fill", role: .destructive) { voice.end() }
                } else {
                    Button("Talk to Dot", systemImage: "waveform") { voice.start(pairing: model.voicePairing) }
                        .disabled(audioTest.busy || model.syncingSignIn || !model.watchSignInReady || model.character == nil || dimmed || scenePhase != .active)
                }
                Text(model.message).font(.caption2).foregroundStyle(.secondary)
                Text(model.signInMessage).font(.caption2).foregroundStyle(.secondary)
                Button("Refresh Dot", systemImage: "arrow.clockwise") { model.refresh() }
                if voice.canSyncSignIn {
                    Button("Sync Watch sign-in", systemImage: "lock.shield") { Task { await model.syncSignIn() } }
                        .disabled(model.syncingSignIn || audioTest.busy)
                }
                Divider()
                Text(audioTest.message).font(.caption2)
                if audioTest.busy {
                    Button("Stop audio test", systemImage: "stop.fill", role: .destructive) { audioTest.stop() }
                } else {
                    Button("Test Watch audio", systemImage: "mic") { audioTest.start() }
                        .disabled(voice.busy)
                }
                #else
                Text(model.message).font(.caption2).foregroundStyle(.secondary)
                Button("Refresh Dot", systemImage: "arrow.clockwise") { model.refresh() }
                Text("Voice isn't available in this build. Open Dot on your iPhone to talk.")
                    .font(.caption2).foregroundStyle(.secondary)
                #endif
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 8)
        }
        .allowsHitTesting(!ReadmeDemo.enabled)
        .onOpenURL { url in
            // Complication entry launches the app; it never opens a microphone.
            if url.scheme == "dotwatch", url.host == "open" { model.refresh() }
        }
        #if PERSONAL_DIAGNOSTICS
        .onAppear { audioTest.sceneChanged(active: scenePhase == .active, dimmed: dimmed) }
        .onChange(of: scenePhase) { _, phase in audioTest.sceneChanged(active: phase == .active, dimmed: dimmed) }
        .onChange(of: dimmed) { _, reduced in audioTest.sceneChanged(active: scenePhase == .active, dimmed: reduced) }
        .onDisappear { audioTest.stop(reason: .viewClosed) }
        #if targetEnvironment(simulator)
        .task {
            if CommandLine.arguments.contains("--simulate-audio-check") { await audioTest.runSimulatorCheck() }
        }
        #endif
        #endif
    }

    private func characterScale(_ phase: Double) -> Double {
        #if PERSONAL_DIAGNOSTICS
        return 1 + (voice.active ? 0.035 * voice.level : 0.012 * sin(phase))
        #else
        return 1 + 0.012 * sin(phase)
        #endif
    }
}
