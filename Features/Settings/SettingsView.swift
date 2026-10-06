import ITubeCore
import SwiftUI

struct SettingsView: View {
    let app: AppEnvironment
    @Environment(SettingsManager.self) private var manager
    @Environment(AccountModel.self) private var account
    @State private var showSignIn = false
    @State private var confirmClearHistory = false
    @State private var cacheCleared = false
    @State private var diagnosticsSummary = ""

    var body: some View {
        @Bindable var m = manager
        Form {
            Section("Playback") {
                qualityPicker("Default quality", selection: $m.settings.defaultQuality)
                qualityPicker("Wi-Fi quality", selection: $m.settings.wifiQuality)
                qualityPicker("Mobile data quality", selection: $m.settings.mobileQuality)
                Toggle("Use mobile quality on cellular", isOn: $m.settings.useMobileQualityOnCellular)
                Picker("Default speed", selection: $m.settings.playbackSpeed) {
                    ForEach(PlaybackEngine.supportedRates, id: \.self) { Text(String(format: "%g×", $0)).tag($0) }
                }
                Toggle("Background playback", isOn: $m.settings.backgroundPlayback)
                Toggle("Automatic Picture in Picture", isOn: $m.settings.automaticPiP)
                Toggle("Autoplay next video", isOn: $m.settings.autoplay)
            }
            Section("Captions") {
                Toggle("Show captions by default", isOn: $m.settings.captionsEnabled)
                TextField("Preferred language code (e.g. en)", text: Binding(
                    get: { m.settings.captionLanguage ?? "" },
                    set: { m.settings.captionLanguage = $0.isEmpty ? nil : String($0.prefix(8)) }))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            Section {
                Toggle("Advertisement suppression", isOn: $m.settings.adSuppression)
                Toggle("Skip sponsor segments", isOn: $m.settings.sponsorSkipping)
                if m.settings.sponsorSkipping {
                    ForEach(SegmentCategory.allCases, id: \.self) { c in
                        Toggle(c.title, isOn: Binding(
                            get: { m.settings.skipCategories.contains(c) },
                            set: { on in if on { m.settings.skipCategories.insert(c) } else { m.settings.skipCategories.remove(c) } }))
                    }
                }
            } header: { Text("Filtering") } footer: {
                Text("itube never shows advertisements of its own. Suppression applies only where the content source supplies the information to do so.")
            }
            Section("Account") {
                if account.isSignedIn {
                    Label("Signed in", systemImage: "person.crop.circle.badge.checkmark")
                    Button("Sign Out", role: .destructive) { Task { await account.signOut() } }
                } else {
                    Button("Sign in with Google") { showSignIn = true }
                }
            }
            Section {
                Toggle("Save watch history", isOn: $m.settings.historyEnabled)
                Toggle("Save search history", isOn: $m.settings.searchHistoryEnabled)
                Button("Clear Watch History", role: .destructive) { confirmClearHistory = true }
                Button("Clear Search History", role: .destructive) { Task { await app.historyStore.clearSearches() } }
                Button(cacheCleared ? "Caches Cleared" : "Clear Caches") {
                    Task { await app.clearCaches(); cacheCleared = true }
                }
            } header: { Text("Privacy & Storage") } footer: {
                Text("History, bookmarks and subscriptions stay on this device. itube has no analytics or advertising SDKs.")
            }
            Section("Diagnostics (on device only)") {
                Text(diagnosticsSummary.isEmpty ? "No events recorded." : diagnosticsSummary).font(.footnote.monospacedDigit())
            }
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $showSignIn) { GoogleSignInView() }
        .confirmationDialog("Clear all watch history?", isPresented: $confirmClearHistory, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { Task { await app.historyStore.clearHistory() } }
        }
        .task { await refreshDiagnostics() }
    }

    private func qualityPicker(_ title: String, selection: Binding<VideoQuality>) -> some View {
        Picker(title, selection: selection) { ForEach(VideoQuality.allCases) { Text($0.title).tag($0) } }
    }

    private func refreshDiagnostics() async {
        let d = app.diagnostics
        let ready = await d.count { if case .timeToReady = $0 { true } else { false } }
        let failures = await d.count { if case .playbackFailure = $0 { true } else { false } }
        let refreshes = await d.count { $0 == .streamRefresh }
        let buffers = await d.count { $0 == .bufferEvent }
        diagnosticsSummary = ready + failures + refreshes + buffers == 0 ? "" :
            "ready: \(ready)  failures: \(failures)\nstream refreshes: \(refreshes)  buffer events: \(buffers)"
    }
}
