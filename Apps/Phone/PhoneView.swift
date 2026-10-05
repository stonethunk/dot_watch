import SwiftUI
import DotCore

struct PhoneView: View {
    @ObservedObject var model: PhoneModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var browserSetupPresented = false

    var body: some View {
        VStack(spacing: 24) {
            Text("Dot on iPhone").font(.largeTitle.bold())
            Spacer(minLength: 0)
            Group {
                if let image = model.character {
                    Image(uiImage: image).resizable().scaledToFit()
                        .scaleEffect(reduceMotion || scenePhase != .active ? 1 : 1 + min(0.035, model.level * 0.15))
                        .accessibilityLabel("Your ChatGPT Dot")
                } else {
                    Text("Your Dot will appear here after setup.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: 320, maxHeight: 320)
            Text(model.status).font(.title3).accessibilityAddTraits(.updatesFrequently)
            if let message = model.message {
                Text(message).font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if model.state == .idle {
                Button("Talk to Dot", systemImage: "waveform") { Task { await model.start(.phone) } }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!model.configured || model.busy)
                if model.personalBuild {
                    if model.browserSetupAvailable {
                        Button("Sign in using Safari") { browserSetupPresented = true }
                    }
                    Button(model.busy ? "Connecting…" : "Refresh connection and appearance") { Task { await model.load() } }
                        .disabled(model.busy)
                } else if model.identity == nil {
                    Button("Continue with ChatGPT") { Task { await model.signIn() } }
                        .buttonStyle(.bordered).disabled(model.busy || !model.signInAvailable)
                    if !model.signInAvailable {
                        Text("OpenAI sign-in will be available when registration is complete.")
                            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                }
                if model.personalBuild || model.configured || model.identity != nil {
                    Button("Sign out", role: .destructive) { model.signOut() }.disabled(model.busy)
                }
            } else {
                if model.state.surface == .carPlay {
                    Button("Talk on iPhone") { Task { await model.start(.phone) } }
                }
                HStack(spacing: 28) {
                    if case .active(_, let muted) = model.state {
                        Button(muted ? "Unmute" : "Mute", systemImage: muted ? "mic.slash" : "mic") { model.toggleMute() }
                            .buttonStyle(.bordered)
                    }
                    Button("End", systemImage: "stop.fill", role: .destructive) { model.end() }
                        .buttonStyle(.borderedProminent)
                }.controlSize(.large)
            }
            if model.personalBuild {
                ShareLink(item: model.diagnosticsURL) { Label("Share diagnostics", systemImage: "square.and.arrow.up") }
                    .font(.footnote)
                Text(model.watchStatus).font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text("Personal diagnostic · \(model.buildLabel)").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(28)
        .background(Color(.systemBackground))
        .allowsHitTesting(!ReadmeDemo.enabled)
        .task {
            if ReadmeDemo.enabled, CommandLine.arguments.contains("--readme-setup") {
                browserSetupPresented = true
            }
        }
        .sheet(isPresented: $browserSetupPresented) {
            #if PERSONAL_DIAGNOSTICS
            PrivateBrowserSetupView()
            #else
            EmptyView()
            #endif
        }
    }
}
