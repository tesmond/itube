import ITubeCore
import SwiftUI

struct RootView: View {
    let app: AppEnvironment
    @State private var coordinator: PlaybackCoordinator

    init(app: AppEnvironment) {
        self.app = app
        _coordinator = State(initialValue: app.coordinator)
    }

    var body: some View {
        TabView {
            Tab("Home", systemImage: "house") { NavigationStack { HomeView(app: app) } }
            Tab("Search", systemImage: "magnifyingglass") { NavigationStack { SearchView(app: app) } }
            Tab("Library", systemImage: "books.vertical") { NavigationStack { LibraryView(app: app) } }
            Tab("Settings", systemImage: "gearshape") { NavigationStack { SettingsView(app: app) } }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if coordinator.displayedVideo != nil, !coordinator.isPlayerPresented {
                MiniPlayerView(coordinator: coordinator)
                    .padding(.bottom, 49)   // sits above the tab bar
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { coordinator.isPlayerPresented },
            set: { $0 ? coordinator.presentPlayer() : coordinator.dismissPlayer() })
        ) {
            PlayerView(app: app)
        }
        .environment(coordinator)
        .environment(app.settings)
        .environment(app.account)
        .environment(\.imageLoader, app.imageLoader)
        .environment(\.libraryStore, app.libraryStore)
        .task {
            await app.account.refresh()
            await coordinator.restoreSession()
        }
        .onChange(of: app.settings.settings) { coordinator.applySettings() }
        .onChange(of: coordinator.isPlayerPresented) { _, presented in OrientationController.allowLandscape(presented) }
        .onOpenURL { url in
            guard let link = DeepLink(url: url) else { return }
            Task { await open(link) }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            Task { await app.handleMemoryWarning() }
        }
    }

    /// An existing playback session continues until the replacement is intentionally started (ADR §71).
    private func open(_ link: DeepLink) async {
        guard case .video(let id) = link, let details = try? await app.videoService.details(for: id) else { return }
        coordinator.play(details.video, upcoming: details.related)
    }
}
