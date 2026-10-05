import SwiftUI

#if PERSONAL_DIAGNOSTICS
struct PrivateBrowserSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Connect your own existing ChatGPT account and Dot. Your password stays with OpenAI. This private sign-in gives Dot account access until the token expires or you sign out.")
                }
                Section("Set up in Safari") {
                    Text("1. In iPhone Settings, open Apps → Safari → Extensions and enable Dot Private Sign-in.")
                    Text("2. Open Safari, go to chatgpt.com and sign in as yourself. Check that it is your account and workspace.")
                    Text("3. In Safari’s page menu, choose Dot Private Sign-in. Tap Connect this account to Dot.")
                    Text("4. Choose Return to Dot. The app verifies your account, saves the sign-in in Keychain and removes the temporary handoff.")
                }
                Section {
                    Button("Open chatgpt.com") { openURL(URL(string: "https://chatgpt.com/")!) }
                    Text("Use Safari for this setup. If another browser opens by default, enter chatgpt.com in Safari instead.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Text("To connect a different account, sign out in Dot first. Renewal uses the same Safari steps. Each person connects their own account.")
                }
            }
            .navigationTitle("Private sign-in")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
#endif
