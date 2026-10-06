import ITubeCore
import SwiftUI

@MainActor @Observable
final class SearchModel {
    var query = "" { didSet { if query != oldValue { queryChanged() } } }
    var filter: SearchFilter = .all { didSet { if filter != oldValue, submitted { submit() } } }
    private(set) var suggestions: [String] = []
    private(set) var recent: [String] = []
    private(set) var items: [SearchItem] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var submitted = false

    private var continuation: String?
    private var suggestionTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private let app: AppEnvironment

    init(app: AppEnvironment) { self.app = app }

    func loadRecent() async { recent = await app.historyStore.recentSearches(limit: 10) }

    private func queryChanged() {
        submitted = false
        suggestionTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { suggestions = []; items = []; return }
        suggestionTask = Task { [weak self, app] in
            try? await Task.sleep(for: .milliseconds(250))                       // debounce
            guard !Task.isCancelled else { return }
            let s = (try? await app.searchService.suggestions(for: q)) ?? []
            guard !Task.isCancelled else { return }
            self?.suggestions = s
        }
    }

    func submit(_ text: String? = nil) {
        if let text { query = text }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        suggestionTask?.cancel(); searchTask?.cancel()          // a newer query cancels the superseded request (ADR §28)
        submitted = true; suggestions = []; items = []; continuation = nil; errorMessage = nil; isLoading = true
        if app.settings.settings.searchHistoryEnabled {
            Task { [weak self, app] in await app.historyStore.recordSearch(q); await self?.loadRecent() }
        }
        let request = SearchRequest(query: q, filter: filter)
        searchTask = Task { [weak self, app] in
            do {
                let page = try await app.searchService.search(request)
                guard !Task.isCancelled, let self else { return }
                self.items = page.items; self.continuation = page.continuation
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.errorMessage = PlaybackError(error).userMessage
            }
            if !Task.isCancelled { self?.isLoading = false }
        }
    }

    func loadMoreIfNeeded(current: SearchItem) {
        guard let token = continuation, !isLoading, items.last?.id == current.id else { return }
        isLoading = true
        let request = SearchRequest(query: query, filter: filter, continuation: token)
        searchTask = Task { [weak self, app] in
            let page = try? await app.searchService.search(request)
            guard !Task.isCancelled, let self else { return }
            if let page {
                let known = Set(self.items.map(\.id))
                self.items += page.items.filter { !known.contains($0.id) }
                self.continuation = page.continuation
            } else { self.continuation = nil }
            self.isLoading = false
        }
    }

    func removeRecent(_ q: String) { Task { [weak self, app] in await app.historyStore.removeSearch(q); await self?.loadRecent() } }
    func clearRecent() { Task { [weak self, app] in await app.historyStore.clearSearches(); await self?.loadRecent() } }
    func cancel() { suggestionTask?.cancel(); searchTask?.cancel() }
}

struct SearchView: View {
    let app: AppEnvironment
    @State private var model: SearchModel
    @Environment(PlaybackCoordinator.self) private var coordinator

    init(app: AppEnvironment) {
        self.app = app
        _model = State(initialValue: SearchModel(app: app))
    }

    var body: some View {
        List {
            if model.submitted {
                Picker("Filter", selection: $model.filter) {
                    ForEach(SearchFilter.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)

                if let message = model.errorMessage { Text(message).foregroundStyle(.secondary) }
                ForEach(model.items) { item in
                    row(for: item).onAppear { model.loadMoreIfNeeded(current: item) }
                }
                if model.isLoading { ProgressView().frame(maxWidth: .infinity) }
            } else if model.query.isEmpty {
                if !model.recent.isEmpty {
                    Section {
                        ForEach(model.recent, id: \.self) { q in
                            Button { model.submit(q) } label: { Label(q, systemImage: "clock.arrow.circlepath") }
                                .swipeActions { Button("Delete", role: .destructive) { model.removeRecent(q) } }
                        }
                    } header: {
                        HStack { Text("Recent"); Spacer(); Button("Clear") { model.clearRecent() }.font(.footnote) }
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Search")
        .searchable(text: $model.query, prompt: "Search videos")
        .searchSuggestions {
            ForEach(model.suggestions, id: \.self) { s in Text(s).searchCompletion(s) }
        }
        .onSubmit(of: .search) { model.submit() }
        .task { await model.loadRecent() }
        .onDisappear { model.cancel() }
        .overlay {
            if !app.searchService.isAvailable {
                ContentUnavailableView("Search unavailable", systemImage: "magnifyingglass", description: Text("No video provider is enabled in this build."))
            }
        }
    }

    @ViewBuilder
    private func row(for item: SearchItem) -> some View {
        switch item {
        case .video(let v):
            VideoRow(video: v) {
                let rest = model.items.compactMap { i -> Video? in if case .video(let x) = i { x } else { nil } }
                coordinator.play(v, upcoming: Array(rest.drop { $0.id != v.id }.dropFirst()))
            }
        case .channel(let c):
            NavigationLink { ChannelScreen(app: app, channel: c) } label: {
                HStack(spacing: 12) {
                    ThumbnailView(url: c.thumbnailURL).frame(width: 56, height: 56).clipShape(Circle())
                    VStack(alignment: .leading) {
                        Text(c.name).font(.headline)
                        if let s = c.subscriberText { Text(s).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        case .playlist(let p):
            NavigationLink { PlaylistScreen(app: app, playlist: p) } label: {
                HStack(spacing: 12) {
                    ThumbnailView(url: p.thumbnails.last?.url).aspectRatio(16 / 9, contentMode: .fit).frame(width: 120).clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading) {
                        Text(p.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                        if let c = p.videoCountText { Text("\(c) videos").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }
}

// MARK: Channel & playlist screens

struct ChannelScreen: View {
    let app: AppEnvironment
    let channel: ChannelSummary
    @Environment(\.libraryStore) private var library
    @State private var subscribed = false

    var body: some View {
        PagedVideoList(title: channel.name) { token in try await app.videoService.channelVideos(channel.id, continuation: token) }
            .toolbar {
                Button(subscribed ? "Subscribed" : "Subscribe") {
                    subscribed.toggle()
                    Task { await library?.setSubscribed(channel, subscribed: subscribed) }
                }
            }
            .task { subscribed = await library?.isSubscribed(channel.id) ?? false }
    }
}

struct PlaylistScreen: View {
    let app: AppEnvironment
    let playlist: PlaylistSummary
    var body: some View {
        PagedVideoList(title: playlist.title) { token in try await app.videoService.playlistVideos(playlist.id, continuation: token) }
    }
}

struct PagedVideoList: View {
    let title: String
    let load: @Sendable (String?) async throws -> ContentPage
    @State private var videos: [Video] = []
    @State private var continuation: String?
    @State private var isLoading = false
    @State private var failed = false
    @Environment(PlaybackCoordinator.self) private var coordinator

    var body: some View {
        List {
            ForEach(videos) { v in
                VideoRow(video: v) { coordinator.play(v, upcoming: Array(videos.drop { $0.id != v.id }.dropFirst())) }
                    .onAppear { if v.id == videos.last?.id { Task { await more() } } }
            }
            if isLoading { ProgressView().frame(maxWidth: .infinity) }
        }
        .listStyle(.plain)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if failed && videos.isEmpty { ErrorStateView(title: "Couldn’t load", message: "Please try again.") { Task { await more(reset: true) } } } }
        .task { if videos.isEmpty { await more() } }
    }

    private func more(reset: Bool = false) async {
        guard !isLoading else { return }
        if reset { videos = []; continuation = nil }
        guard reset || videos.isEmpty || continuation != nil else { return }
        isLoading = true; failed = false
        defer { isLoading = false }
        do {
            let page = try await load(continuation)
            let known = Set(videos.map(\.id))
            videos += page.videos.filter { !known.contains($0.id) }
            continuation = page.continuation
        } catch is CancellationError {
        } catch { failed = true }
    }
}
