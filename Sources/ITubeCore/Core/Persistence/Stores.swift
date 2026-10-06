import Foundation
import SwiftData

// MARK: - Public snapshot types

public struct PlaybackPosition: Sendable, Equatable {
    public let position: Duration
    public let duration: Duration?
    public init(position: Duration, duration: Duration?) { self.position = position; self.duration = duration }

    public var fraction: Double? {
        guard let duration, duration.totalSeconds > 0 else { return nil }
        return position.totalSeconds / duration.totalSeconds
    }
}

public struct HistoryEntry: Sendable, Equatable, Identifiable {
    public var id: VideoID { video.id }
    public let video: Video
    public let position: Duration
    public let duration: Duration?
    public let lastWatched: Date
}

public struct PlaylistRecord: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var videos: [Video]
    public let created: Date
}

public struct PersistedSession: Sendable, Codable, Equatable {
    public var queue: PlaybackQueue
    public var position: Double
    public var rate: Float
    public var quality: VideoQuality
    public var captionsEnabled: Bool
    public var captionLanguage: String?
    public init(queue: PlaybackQueue, position: Double, rate: Float, quality: VideoQuality, captionsEnabled: Bool, captionLanguage: String?) {
        self.queue = queue; self.position = position; self.rate = rate; self.quality = quality
        self.captionsEnabled = captionsEnabled; self.captionLanguage = captionLanguage
    }
}

// MARK: - Protocols (so tests and previews can substitute fakes)

public protocol HistoryStoring: Sendable {
    func recordWatch(video: Video, position: Duration, duration: Duration?) async
    func updatePosition(videoID: VideoID, position: Duration, duration: Duration?) async
    func position(for videoID: VideoID) async -> PlaybackPosition?
    func recent(limit: Int) async -> [HistoryEntry]
    func remove(videoID: VideoID) async
    func clearHistory() async
    func recordSearch(_ query: String) async
    func recentSearches(limit: Int) async -> [String]
    func removeSearch(_ query: String) async
    func clearSearches() async
}

public protocol LibraryStoring: Sendable {
    func bookmarks() async -> [Video]
    func isBookmarked(_ id: VideoID) async -> Bool
    func setBookmark(_ video: Video, bookmarked: Bool) async
    func playlists() async -> [PlaylistRecord]
    @discardableResult func createPlaylist(name: String) async -> PlaylistRecord?
    func add(_ video: Video, toPlaylist id: UUID) async
    func remove(videoID: VideoID, fromPlaylist id: UUID) async
    func deletePlaylist(_ id: UUID) async
    func subscriptions() async -> [ChannelSummary]
    func isSubscribed(_ id: ChannelID) async -> Bool
    func setSubscribed(_ channel: ChannelSummary, subscribed: Bool) async
}

public protocol SessionStoring: Sendable {
    func save(_ session: PersistedSession) async
    func load() async -> PersistedSession?
    func clear() async
}

// MARK: - Implementations

@ModelActor
actor HistoryStore: HistoryStoring {
    static let historyCap = 500
    static let searchCap = 50

    func recordWatch(video: Video, position: Duration, duration: Duration?) {
        let id = video.id.rawValue
        let existing = fetchEntry(id)
        if let existing {
            existing.positionSeconds = position.totalSeconds
            existing.durationSeconds = duration?.totalSeconds ?? existing.durationSeconds
            existing.lastWatched = .now
        } else {
            modelContext.insert(HistoryEntryModel(
                videoID: id, title: video.title, channelID: video.channel?.id.rawValue, channelName: video.channel?.name,
                thumbnailURLString: video.thumbnail(forWidth: 480)?.url.absoluteString,
                positionSeconds: position.totalSeconds, durationSeconds: (duration ?? video.duration)?.totalSeconds, lastWatched: .now))
        }
        save()
        prune()
    }

    func updatePosition(videoID: VideoID, position: Duration, duration: Duration?) {
        guard let entry = fetchEntry(videoID.rawValue) else { return }
        entry.positionSeconds = position.totalSeconds
        if let duration { entry.durationSeconds = duration.totalSeconds }
        save()
    }

    func position(for videoID: VideoID) -> PlaybackPosition? {
        guard let e = fetchEntry(videoID.rawValue) else { return nil }
        return PlaybackPosition(position: Duration(seconds: e.positionSeconds), duration: e.durationSeconds.map { Duration(seconds: $0) })
    }

    func recent(limit: Int) -> [HistoryEntry] {
        var d = FetchDescriptor<HistoryEntryModel>(sortBy: [SortDescriptor(\.lastWatched, order: .reverse)])
        d.fetchLimit = limit
        return ((try? modelContext.fetch(d)) ?? []).map { m in
            let channel = m.channelID.map { ChannelSummary(id: ChannelID($0), name: m.channelName ?? "") }
            let thumbs = m.thumbnailURLString.flatMap(URL.init(string:)).map { [Thumbnail(url: $0)] } ?? []
            let dur = m.durationSeconds.map { Duration(seconds: $0) }
            return HistoryEntry(
                video: Video(id: VideoID(m.videoID), title: m.title, channel: channel, duration: dur, thumbnails: thumbs),
                position: Duration(seconds: m.positionSeconds), duration: dur, lastWatched: m.lastWatched)
        }
    }

    func remove(videoID: VideoID) {
        if let e = fetchEntry(videoID.rawValue) { modelContext.delete(e); save() }
    }

    func clearHistory() {
        try? modelContext.delete(model: HistoryEntryModel.self)
        save()
    }

    func recordSearch(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, q.count <= 200 else { return }
        var d = FetchDescriptor<SearchHistoryModel>(predicate: #Predicate { $0.query == q })
        d.fetchLimit = 1
        if let hit = (try? modelContext.fetch(d))?.first { hit.lastUsed = .now }
        else { modelContext.insert(SearchHistoryModel(query: q, lastUsed: .now)) }
        save()
        let total = (try? modelContext.fetchCount(FetchDescriptor<SearchHistoryModel>())) ?? 0
        if total > Self.searchCap {
            var old = FetchDescriptor<SearchHistoryModel>(sortBy: [SortDescriptor(\.lastUsed)])
            old.fetchLimit = total - Self.searchCap
            for m in (try? modelContext.fetch(old)) ?? [] { modelContext.delete(m) }
            save()
        }
    }

    func recentSearches(limit: Int) -> [String] {
        var d = FetchDescriptor<SearchHistoryModel>(sortBy: [SortDescriptor(\.lastUsed, order: .reverse)])
        d.fetchLimit = limit
        return ((try? modelContext.fetch(d)) ?? []).map(\.query)
    }

    func removeSearch(_ query: String) {
        let d = FetchDescriptor<SearchHistoryModel>(predicate: #Predicate { $0.query == query })
        for m in (try? modelContext.fetch(d)) ?? [] { modelContext.delete(m) }
        save()
    }

    func clearSearches() {
        try? modelContext.delete(model: SearchHistoryModel.self)
        save()
    }

    private func fetchEntry(_ id: String) -> HistoryEntryModel? {
        var d = FetchDescriptor<HistoryEntryModel>(predicate: #Predicate { $0.videoID == id })
        d.fetchLimit = 1
        return (try? modelContext.fetch(d))?.first
    }

    private func prune() {
        let total = (try? modelContext.fetchCount(FetchDescriptor<HistoryEntryModel>())) ?? 0
        guard total > Self.historyCap else { return }
        var old = FetchDescriptor<HistoryEntryModel>(sortBy: [SortDescriptor(\.lastWatched)])
        old.fetchLimit = total - Self.historyCap
        for m in (try? modelContext.fetch(old)) ?? [] { modelContext.delete(m) }
        save()
    }

    private func save() {
        do { try modelContext.save() } catch { Log.application.error("History save failed: \(error.localizedDescription, privacy: .public)") }
    }
}

@ModelActor
actor PlaylistStore: LibraryStoring {
    private static let maxPlaylistItems = 500

    func bookmarks() -> [Video] {
        let d = FetchDescriptor<BookmarkModel>(sortBy: [SortDescriptor(\.added, order: .reverse)])
        return ((try? modelContext.fetch(d)) ?? []).compactMap { try? JSONDecoder().decode(Video.self, from: $0.videoData) }
    }

    func isBookmarked(_ id: VideoID) -> Bool { fetchBookmark(id.rawValue) != nil }

    func setBookmark(_ video: Video, bookmarked: Bool) {
        let existing = fetchBookmark(video.id.rawValue)
        if bookmarked, existing == nil, let data = try? JSONEncoder().encode(video.compacted()) {
            modelContext.insert(BookmarkModel(videoID: video.id.rawValue, videoData: data, added: .now))
        } else if !bookmarked, let existing {
            modelContext.delete(existing)
        }
        save()
    }

    func playlists() -> [PlaylistRecord] {
        let d = FetchDescriptor<PlaylistModel>(sortBy: [SortDescriptor(\.created)])
        return ((try? modelContext.fetch(d)) ?? []).map(record)
    }

    func createPlaylist(name: String) -> PlaylistRecord? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 100, let data = try? JSONEncoder().encode([Video]()) else { return nil }
        let model = PlaylistModel(id: UUID(), name: trimmed, created: .now, videosData: data)
        modelContext.insert(model)
        save()
        return record(model)
    }

    func add(_ video: Video, toPlaylist id: UUID) {
        guard let p = fetchPlaylist(id) else { return }
        var videos = (try? JSONDecoder().decode([Video].self, from: p.videosData)) ?? []
        guard !videos.contains(where: { $0.id == video.id }), videos.count < Self.maxPlaylistItems else { return }
        videos.append(video.compacted())
        if let data = try? JSONEncoder().encode(videos) { p.videosData = data; save() }
    }

    func remove(videoID: VideoID, fromPlaylist id: UUID) {
        guard let p = fetchPlaylist(id) else { return }
        var videos = (try? JSONDecoder().decode([Video].self, from: p.videosData)) ?? []
        videos.removeAll { $0.id == videoID }
        if let data = try? JSONEncoder().encode(videos) { p.videosData = data; save() }
    }

    func deletePlaylist(_ id: UUID) {
        if let p = fetchPlaylist(id) { modelContext.delete(p); save() }
    }

    func subscriptions() -> [ChannelSummary] {
        let d = FetchDescriptor<SubscriptionModel>(sortBy: [SortDescriptor(\.name)])
        return ((try? modelContext.fetch(d)) ?? []).map {
            ChannelSummary(id: ChannelID($0.channelID), name: $0.name, thumbnailURL: $0.thumbnailURLString.flatMap(URL.init(string:)))
        }
    }

    func isSubscribed(_ id: ChannelID) -> Bool { fetchSubscription(id.rawValue) != nil }

    func setSubscribed(_ channel: ChannelSummary, subscribed: Bool) {
        let existing = fetchSubscription(channel.id.rawValue)
        if subscribed, existing == nil {
            modelContext.insert(SubscriptionModel(channelID: channel.id.rawValue, name: channel.name,
                                                  thumbnailURLString: channel.thumbnailURL?.absoluteString, added: .now))
        } else if !subscribed, let existing {
            modelContext.delete(existing)
        }
        save()
    }

    private func record(_ p: PlaylistModel) -> PlaylistRecord {
        PlaylistRecord(id: p.id, name: p.name, videos: (try? JSONDecoder().decode([Video].self, from: p.videosData)) ?? [], created: p.created)
    }
    private func fetchBookmark(_ id: String) -> BookmarkModel? {
        var d = FetchDescriptor<BookmarkModel>(predicate: #Predicate { $0.videoID == id }); d.fetchLimit = 1
        return (try? modelContext.fetch(d))?.first
    }
    private func fetchPlaylist(_ id: UUID) -> PlaylistModel? {
        var d = FetchDescriptor<PlaylistModel>(predicate: #Predicate { $0.id == id }); d.fetchLimit = 1
        return (try? modelContext.fetch(d))?.first
    }
    private func fetchSubscription(_ id: String) -> SubscriptionModel? {
        var d = FetchDescriptor<SubscriptionModel>(predicate: #Predicate { $0.channelID == id }); d.fetchLimit = 1
        return (try? modelContext.fetch(d))?.first
    }
    private func save() {
        do { try modelContext.save() } catch { Log.application.error("Library save failed: \(error.localizedDescription, privacy: .public)") }
    }
}

@ModelActor
actor SessionStore: SessionStoring {
    private static let key = "session"

    func save(_ session: PersistedSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        let key = Self.key
        var d = FetchDescriptor<SessionModel>(predicate: #Predicate { $0.key == key }); d.fetchLimit = 1
        if let existing = (try? modelContext.fetch(d))?.first { existing.data = data }
        else { modelContext.insert(SessionModel(key: key, data: data)) }
        try? modelContext.save()
    }

    func load() -> PersistedSession? {
        let key = Self.key
        var d = FetchDescriptor<SessionModel>(predicate: #Predicate { $0.key == key }); d.fetchLimit = 1
        guard let m = (try? modelContext.fetch(d))?.first else { return nil }
        return try? JSONDecoder().decode(PersistedSession.self, from: m.data)
    }

    func clear() {
        try? modelContext.delete(model: SessionModel.self)
        try? modelContext.save()
    }
}

/// One container, three serial actors. The factory is the only place `ModelContainer` is touched.
public struct PersistenceStack: Sendable {
    public let history: any HistoryStoring
    public let library: any LibraryStoring
    public let session: any SessionStoring

    public init(history: any HistoryStoring, library: any LibraryStoring, session: any SessionStoring) {
        self.history = history; self.library = library; self.session = session
    }

    public static func make(inMemory: Bool = false) throws -> PersistenceStack {
        let schema = Schema([HistoryEntryModel.self, SearchHistoryModel.self, BookmarkModel.self,
                             PlaylistModel.self, SubscriptionModel.self, SessionModel.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return PersistenceStack(
            history: HistoryStore(modelContainer: container),
            library: PlaylistStore(modelContainer: container),
            session: SessionStore(modelContainer: container))
    }
}
