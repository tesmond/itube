import Foundation
import SwiftData

// SwiftData entities stay internal to the module. Only `Sendable` snapshot structs cross isolation
// boundaries, so no `@Model` object is ever shared between actors (ADR §37, §44).

@Model final class HistoryEntryModel {
    @Attribute(.unique) var videoID: String
    var title: String
    var channelID: String?
    var channelName: String?
    var thumbnailURLString: String?
    var positionSeconds: Double
    var durationSeconds: Double?
    var lastWatched: Date

    init(videoID: String, title: String, channelID: String?, channelName: String?, thumbnailURLString: String?,
         positionSeconds: Double, durationSeconds: Double?, lastWatched: Date) {
        self.videoID = videoID; self.title = title; self.channelID = channelID; self.channelName = channelName
        self.thumbnailURLString = thumbnailURLString; self.positionSeconds = positionSeconds
        self.durationSeconds = durationSeconds; self.lastWatched = lastWatched
    }
}

@Model final class SearchHistoryModel {
    @Attribute(.unique) var query: String
    var lastUsed: Date
    init(query: String, lastUsed: Date) { self.query = query; self.lastUsed = lastUsed }
}

@Model final class BookmarkModel {
    @Attribute(.unique) var videoID: String
    var videoData: Data
    var added: Date
    init(videoID: String, videoData: Data, added: Date) { self.videoID = videoID; self.videoData = videoData; self.added = added }
}

@Model final class PlaylistModel {
    @Attribute(.unique) var id: UUID
    var name: String
    var created: Date
    var videosData: Data
    init(id: UUID, name: String, created: Date, videosData: Data) {
        self.id = id; self.name = name; self.created = created; self.videosData = videosData
    }
}

@Model final class SubscriptionModel {
    @Attribute(.unique) var channelID: String
    var name: String
    var thumbnailURLString: String?
    var added: Date
    init(channelID: String, name: String, thumbnailURLString: String?, added: Date) {
        self.channelID = channelID; self.name = name; self.thumbnailURLString = thumbnailURLString; self.added = added
    }
}

@Model final class SessionModel {
    @Attribute(.unique) var key: String
    var data: Data
    init(key: String, data: Data) { self.key = key; self.data = data }
}
