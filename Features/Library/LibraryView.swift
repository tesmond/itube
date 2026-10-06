import ITubeCore
import SwiftUI

struct LibraryView: View {
    let app: AppEnvironment
    enum Section: String, CaseIterable { case bookmarks = "Bookmarks", playlists = "Playlists", subscriptions = "Subscriptions" }

    @State private var section: Section = .bookmarks
    @State private var bookmarks: [Video] = []
    @State private var playlists: [PlaylistRecord] = []
    @State private var subscriptions: [ChannelSummary] = []
    @State private var newPlaylistName = ""
    @State private var showingNewPlaylist = false
    @Environment(PlaybackCoordinator.self) private var coordinator

    var body: some View {
        List {
            Picker("Section", selection: $section) {
                ForEach(Section.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).listRowSeparator(.hidden)

            switch section {
            case .bookmarks:
                ForEach(bookmarks) { v in
                    VideoRow(video: v) { coordinator.play(v, upcoming: Array(bookmarks.drop { $0.id != v.id }.dropFirst())) }
                        .swipeActions { Button("Remove", role: .destructive) { Task { await app.libraryStore.setBookmark(v, bookmarked: false); await reload() } } }
                }
            case .playlists:
                ForEach(playlists) { p in
                    NavigationLink { PlaylistDetailView(app: app, playlist: p) { Task { await reload() } } } label: {
                        VStack(alignment: .leading) { Text(p.name).font(.headline); Text("\(p.videos.count) videos").font(.caption).foregroundStyle(.secondary) }
                    }
                    .swipeActions { Button("Delete", role: .destructive) { Task { await app.libraryStore.deletePlaylist(p.id); await reload() } } }
                }
            case .subscriptions:
                ForEach(subscriptions) { c in
                    NavigationLink { ChannelScreen(app: app, channel: c) } label: {
                        HStack(spacing: 12) {
                            ThumbnailView(url: c.thumbnailURL).frame(width: 40, height: 40).clipShape(Circle())
                            Text(c.name)
                        }
                    }
                    .swipeActions { Button("Unsubscribe", role: .destructive) { Task { await app.libraryStore.setSubscribed(c, subscribed: false); await reload() } } }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if section == .playlists { Button("New Playlist", systemImage: "plus") { showingNewPlaylist = true } }
            }
            ToolbarItem(placement: .topBarLeading) { NavigationLink("History") { HistoryView(app: app) } }
        }
        .alert("New Playlist", isPresented: $showingNewPlaylist) {
            TextField("Name", text: $newPlaylistName)
            Button("Create") { let n = newPlaylistName; newPlaylistName = ""; Task { _ = await app.libraryStore.createPlaylist(name: n); await reload() } }
            Button("Cancel", role: .cancel) { newPlaylistName = "" }
        }
        .overlay { if isEmpty { ContentUnavailableView("Nothing here yet", systemImage: "tray", description: Text(hint)) } }
        .task { await reload() }
    }

    private var isEmpty: Bool {
        switch section { case .bookmarks: bookmarks.isEmpty; case .playlists: playlists.isEmpty; case .subscriptions: subscriptions.isEmpty }
    }
    private var hint: String {
        switch section {
        case .bookmarks: "Long-press a video and choose Bookmark."
        case .playlists: "Tap + to create a playlist."
        case .subscriptions: "Open a channel and tap Subscribe. Subscriptions stay on this device."
        }
    }

    private func reload() async {
        bookmarks = await app.libraryStore.bookmarks()
        playlists = await app.libraryStore.playlists()
        subscriptions = await app.libraryStore.subscriptions()
    }
}

struct PlaylistDetailView: View {
    let app: AppEnvironment
    @State var playlist: PlaylistRecord
    var onChange: () -> Void
    @Environment(PlaybackCoordinator.self) private var coordinator

    var body: some View {
        List {
            ForEach(playlist.videos) { v in
                VideoRow(video: v) { coordinator.play(v, upcoming: Array(playlist.videos.drop { $0.id != v.id }.dropFirst())) }
                    .swipeActions {
                        Button("Remove", role: .destructive) {
                            playlist.videos.removeAll { $0.id == v.id }
                            Task { await app.libraryStore.remove(videoID: v.id, fromPlaylist: playlist.id); onChange() }
                        }
                    }
            }
        }
        .listStyle(.plain)
        .navigationTitle(playlist.name)
        .toolbar {
            if let first = playlist.videos.first {
                Button("Play All", systemImage: "play.fill") { coordinator.play(first, upcoming: Array(playlist.videos.dropFirst())) }
            }
        }
    }
}
