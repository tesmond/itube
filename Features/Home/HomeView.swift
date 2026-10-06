import ITubeCore
import SwiftUI

@MainActor @Observable
final class HomeModel {
    struct Section: Identifiable { let id: String; let title: String; let videos: [Video] }

    private(set) var sections: [Section] = []
    private(set) var isLoading = false
    private let app: AppEnvironment

    init(app: AppEnvironment) { self.app = app }

    /// Provider-dependent sections simply disappear when unsupported or failing (ADR §29).
    func load() async {
        isLoading = true
        defer { isLoading = false }
        let caps = app.videoService.capabilities
        let signedIn = app.account.isSignedIn
        let service = app.videoService

        async let continueWatching = app.historyStore.recent(limit: 20)
        async let recommended = (signedIn && caps.contains(.recommended)) ? (try? await service.recommended()) : nil
        async let subscriptions = (signedIn && caps.contains(.subscriptionsFeed)) ? (try? await service.subscriptionsFeed()) : nil
        async let trending = caps.contains(.trending) ? (try? await service.trending()) : nil

        var result: [Section] = []
        let history = await continueWatching
        let unfinished = history.filter { entry in
            guard let d = entry.duration, d.totalSeconds > 0 else { return entry.position > .seconds(5) }
            let f = entry.position.totalSeconds / d.totalSeconds
            return entry.position > .seconds(5) && f < app.settings.settings.restartThreshold
        }.map(\.video)
        if !unfinished.isEmpty { result.append(Section(id: "continue", title: "Continue Watching", videos: unfinished)) }
        if let v = await recommended, !v.isEmpty { result.append(Section(id: "rec", title: "Recommended", videos: Array(v.prefix(20)))) }
        if let v = await subscriptions, !v.isEmpty { result.append(Section(id: "subs", title: "Subscriptions", videos: Array(v.prefix(20)))) }
        if let v = await trending, !v.isEmpty { result.append(Section(id: "trending", title: "Trending", videos: Array(v.prefix(30)))) }
        let recent = history.map(\.video)
        if !recent.isEmpty { result.append(Section(id: "recent", title: "Recently Watched", videos: Array(recent.prefix(10)))) }
        sections = result
    }
}

struct HomeView: View {
    let app: AppEnvironment
    @State private var model: HomeModel
    @Environment(PlaybackCoordinator.self) private var coordinator

    init(app: AppEnvironment) {
        self.app = app
        _model = State(initialValue: HomeModel(app: app))
    }

    var body: some View {
        Group {
            if app.providerRegistry.providers.isEmpty {
                ContentUnavailableView("No content source", systemImage: "play.slash",
                                       description: Text("This build of itube has no video provider enabled."))
            } else if model.sections.isEmpty {
                if model.isLoading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else { ErrorStateView(title: "Nothing to show yet", message: "Search for a video to get started.") { Task { await model.load() } } }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20, pinnedViews: []) {
                        ForEach(model.sections) { section in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(section.title).font(.title3.bold()).accessibilityAddTraits(.isHeader)
                                ForEach(section.videos) { video in
                                    VideoRow(video: video) {
                                        let after = section.videos.drop { $0.id != video.id }.dropFirst()
                                        coordinator.play(video, upcoming: Array(after))
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                }
            }
        }
        .navigationTitle("Home")
        .refreshable { await model.load() }
        .task(id: app.account.isSignedIn) { await model.load() }
    }
}
