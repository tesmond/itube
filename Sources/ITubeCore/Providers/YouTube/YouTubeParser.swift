import Foundation

/// Pure functions from InnerTube JSON to ITube domain models. No networking, so fixture-testable (ADR §61).
enum YouTubeParser {
    /// Promoted content is never surfaced in itube's own lists (ADR §18, §76).
    static let promotedKeys: Set<String> = [
        "adSlotRenderer", "promotedSparklesWebRenderer", "searchPyvRenderer", "compactPromotedVideoRenderer",
        "displayAdRenderer", "inFeedAdLayoutRenderer", "promotedVideoRenderer", "bannerPromoRenderer",
        "statementBannerRenderer", "brandVideoSingletonRenderer", "brandVideoShelfRenderer",
    ]
    static let videoKeys: Set<String> = ["videoRenderer", "compactVideoRenderer", "gridVideoRenderer", "playlistVideoRenderer"]

    // MARK: Primitives

    static func text(_ v: JSONValue?) -> String? {
        guard let v else { return nil }
        if let s = v["simpleText"]?.string { return s }
        if let runs = v["runs"]?.array {
            let joined = runs.compactMap { $0["text"]?.string }.joined()
            return joined.isEmpty ? nil : joined
        }
        return v.string
    }

    /// Only https URLs are accepted; protocol-relative and http are upgraded (ADR §70).
    static func httpsURL(_ s: String?) -> URL? {
        guard var s, !s.isEmpty else { return nil }
        if s.hasPrefix("//") { s = "https:" + s }
        else if s.hasPrefix("http://") { s = "https://" + s.dropFirst("http://".count) }
        guard s.hasPrefix("https://"), let url = URL(string: s), url.host() != nil else { return nil }
        return url
    }

    static func thumbnails(_ v: JSONValue?) -> [Thumbnail] {
        (v?["thumbnails"]?.array ?? []).compactMap { t in
            guard let url = httpsURL(t["url"]?.string) else { return nil }
            return Thumbnail(url: url, width: t["width"]?.int, height: t["height"]?.int)
        }
    }

    /// "12:34" or "1:02:03"
    static func clockDuration(_ s: String?) -> Duration? {
        guard let s else { return nil }
        let parts = s.split(separator: ":").map { Int($0) }
        guard !parts.isEmpty, parts.count <= 3, !parts.contains(where: { $0 == nil }) else { return nil }
        let seconds = parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
        return .seconds(seconds)
    }

    /// "1,234,567 views", "1.2M views", "No views"
    static func count(_ s: String?) -> Int? {
        guard let s else { return nil }
        let lower = s.lowercased()
        if lower.hasPrefix("no ") { return 0 }
        var numeric = ""
        var suffix: Character?
        for ch in lower {
            if ch.isNumber || ch == "." { numeric.append(ch) }
            else if ch == "," { continue }
            else { suffix = ch; break }
        }
        guard let base = Double(numeric), base.isFinite else { return nil }
        let multiplier: Double = switch suffix { case "k": 1e3; case "m": 1e6; case "b": 1e9; default: 1 }
        return Int(base * multiplier)
    }

    // MARK: Renderers

    static func channel(from node: JSONValue) -> ChannelSummary? {
        for key in ["ownerText", "longBylineText", "shortBylineText"] {
            guard let byline = node[key], let run = byline["runs"]?[0], let name = run["text"]?.string else { continue }
            guard let id = run.at("navigationEndpoint", "browseEndpoint", "browseId")?.string else { continue }
            return ChannelSummary(id: ChannelID(id), name: name)
        }
        return nil
    }

    static func video(from node: JSONValue) -> Video? {
        guard let id = node["videoId"]?.string.map({ VideoID($0) }), id.isWellFormed else { return nil }
        guard let title = text(node["title"]) ?? node["headline"]?.string, !title.isEmpty else { return nil }
        var duration = clockDuration(node["lengthText"]?["simpleText"]?.string)
        if duration == nil, let secs = node["lengthSeconds"]?.int { duration = .seconds(secs) }
        if duration == nil {
            for overlay in node["thumbnailOverlays"]?.array ?? [] {
                if let t = overlay.at("thumbnailOverlayTimeStatusRenderer", "text", "simpleText")?.string, let d = clockDuration(t) { duration = d; break }
            }
        }
        let views = count(text(node["viewCountText"])) ?? count(text(node["shortViewCountText"]))
        return Video(
            id: id, title: title, channel: channel(from: node), duration: duration,
            thumbnails: thumbnails(node["thumbnail"]), publishedAt: nil,
            publishedText: text(node["publishedTimeText"]), viewCount: views)
    }

    static func channelSummary(fromRenderer node: JSONValue) -> ChannelSummary? {
        guard let id = node["channelId"]?.string, let name = text(node["title"]) else { return nil }
        let thumb = thumbnails(node["thumbnail"]).first?.url
        return ChannelSummary(id: ChannelID(id), name: name, thumbnailURL: thumb, subscriberText: text(node["subscriberCountText"]))
    }

    static func playlistSummary(fromRenderer node: JSONValue) -> PlaylistSummary? {
        guard let id = node["playlistId"]?.string, let title = text(node["title"]) else { return nil }
        let thumbs = thumbnails(node["thumbnails"]?[0]).isEmpty ? thumbnails(node["thumbnail"]) : thumbnails(node["thumbnails"]?[0])
        return PlaylistSummary(id: PlaylistID(id), title: title, videoCountText: node["videoCount"]?.string ?? text(node["videoCountText"]), thumbnails: thumbs)
    }

    // MARK: Collections

    static func searchItems(_ root: JSONValue, filter: SearchFilter) -> [SearchItem] {
        let keys: Set<String> = ["videoRenderer", "channelRenderer", "playlistRenderer"]
        var seen = Set<String>()
        var items: [SearchItem] = []
        for (key, node) in root.descendants(namedAny: keys, skipping: promotedKeys) {
            let item: SearchItem?
            switch key {
            case "videoRenderer": item = video(from: node).map(SearchItem.video)
            case "channelRenderer": item = channelSummary(fromRenderer: node).map(SearchItem.channel)
            default: item = playlistSummary(fromRenderer: node).map(SearchItem.playlist)
            }
            guard let item, seen.insert(item.id).inserted else { continue }
            switch (filter, item) {
            case (.all, _), (.videos, .video), (.channels, .channel), (.playlists, .playlist): items.append(item)
            default: break
            }
        }
        return items
    }

    static func videos(_ root: JSONValue, excluding: VideoID? = nil, limit: Int = 60) -> [Video] {
        var seen = Set<VideoID>()
        var out: [Video] = []
        for (_, node) in root.descendants(namedAny: videoKeys, skipping: promotedKeys) {
            guard let v = video(from: node), v.id != excluding, seen.insert(v.id).inserted else { continue }
            out.append(v)
            if out.count >= limit { break }
        }
        return out
    }

    static func continuation(_ root: JSONValue) -> String? {
        root.descendants(named: "continuationCommand", skipping: promotedKeys).first?["token"]?.string
    }

    // MARK: Player response

    struct PlayerSnapshot: Sendable, Equatable {
        let resource: PlaybackResource
        let video: Video
        let description: String
    }

    static func parseMime(_ mime: String) -> (type: String, container: MediaStream.Container, codecs: [String]) {
        let pieces = mime.split(separator: ";", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        let typeParts = (pieces.first ?? "").split(separator: "/").map(String.init)
        let type = typeParts.first ?? "", subtype = typeParts.count > 1 ? typeParts[1] : ""
        var codecs: [String] = []
        if pieces.count > 1, let r = pieces[1].range(of: "codecs=\"") {
            let rest = pieces[1][r.upperBound...]
            if let end = rest.firstIndex(of: "\"") {
                codecs = rest[..<end].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            }
        }
        let container: MediaStream.Container = switch (type, subtype) {
        case ("video", "mp4"): .mp4
        case ("audio", "mp4"): .m4a
        case (_, "webm"): .webm
        default: .other
        }
        return (type, container, codecs)
    }

    static func stream(from f: JSONValue, muxed: Bool) -> MediaStream? {
        // Ciphered formats (`signatureCipher`) would need JavaScript evaluation to decode; that is rejected (ADR §70).
        guard let url = httpsURL(f["url"]?.string), let mime = f["mimeType"]?.string else { return nil }
        let parsed = parseMime(mime)
        let hasVideo = parsed.type == "video"
        let hasAudio = parsed.type == "audio" || (hasVideo && muxed)
        guard hasVideo || hasAudio else { return nil }
        let itag = f["itag"]?.int.map(String.init) ?? UUID().uuidString
        return MediaStream(
            id: itag, url: url, container: parsed.container, hasVideo: hasVideo, hasAudio: hasAudio,
            width: f["width"]?.int, height: f["height"]?.int,
            bitrate: f["averageBitrate"]?.int ?? f["bitrate"]?.int, frameRate: f["fps"]?.double,
            codecs: parsed.codecs, isDefaultAudio: f.at("audioTrack", "audioIsDefault")?.bool ?? true)
    }

    static func captionTracks(_ root: JSONValue) -> (tracks: [SubtitleTrack], translations: [LanguageOption]) {
        guard let renderer = root.at("captions", "playerCaptionsTracklistRenderer") else { return ([], []) }
        var tracks: [SubtitleTrack] = []
        for t in renderer["captionTracks"]?.array ?? [] {
            guard let base = httpsURL(t["baseUrl"]?.string), let lang = t["languageCode"]?.string else { continue }
            var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
            var items = (comps?.queryItems ?? []).filter { $0.name != "fmt" }
            items.append(URLQueryItem(name: "fmt", value: "vtt"))
            comps?.queryItems = items
            guard let url = comps?.url else { continue }
            let auto = t["kind"]?.string == "asr"
            tracks.append(SubtitleTrack(
                id: lang + (auto ? "-asr" : ""), languageCode: lang,
                displayName: text(t["name"]) ?? lang, url: url, isAutoGenerated: auto))
        }
        let translations = (renderer["translationLanguages"]?.array ?? []).compactMap { l -> LanguageOption? in
            guard let code = l["languageCode"]?.string, let name = text(l["languageName"]) else { return nil }
            return LanguageOption(code: code, name: name)
        }
        return (tracks, tracks.isEmpty ? [] : translations)
    }

    static func playerSnapshot(_ root: JSONValue, requestedID: VideoID, now: Date, userAgent: String?) throws -> PlayerSnapshot {
        let status = root.at("playabilityStatus", "status")?.string ?? ""
        switch status {
        case "OK": break
        case "LOGIN_REQUIRED", "AGE_VERIFICATION_REQUIRED", "CONTENT_CHECK_REQUIRED", "UNPLAYABLE": throw ProviderError.restricted
        default: throw ProviderError.unavailable
        }
        guard let details = root["videoDetails"], details["videoId"]?.string == requestedID.rawValue else {
            throw ProviderError.parsing("videoDetails missing or for a different video")
        }
        guard let streaming = root["streamingData"] else { throw ProviderError.unavailable }

        var videoStreams: [MediaStream] = []
        if let hls = httpsURL(streaming["hlsManifestUrl"]?.string) {
            videoStreams.append(MediaStream(id: "hls", url: hls, container: .hls, hasVideo: true, hasAudio: true))
        }
        videoStreams += (streaming["formats"]?.array ?? []).compactMap { stream(from: $0, muxed: true) }
        var audioStreams: [MediaStream] = []
        for f in streaming["adaptiveFormats"]?.array ?? [] {
            guard let s = stream(from: f, muxed: false) else { continue }
            if s.hasVideo { videoStreams.append(s) } else { audioStreams.append(s) }
        }
        guard !videoStreams.isEmpty else { throw ProviderError.unavailable }

        let seconds = details["lengthSeconds"]?.int
        let isLive = details["isLive"]?.bool ?? false
        let duration: Duration? = (isLive || seconds == nil || seconds == 0) ? nil : .seconds(seconds!)
        let channel = details["channelId"]?.string.map { ChannelSummary(id: ChannelID($0), name: details["author"]?.string ?? "") }
        let thumbs = thumbnails(details["thumbnail"])
        let title = details["title"]?.string ?? ""
        let (captions, translations) = captionTracks(root)

        var expires: Date?
        if let secs = streaming["expiresInSeconds"]?.int { expires = now.addingTimeInterval(TimeInterval(secs)) }

        var published: Date?
        if let d = root.at("microformat", "playerMicroformatRenderer", "publishDate")?.string {
            let f = ISO8601DateFormatter(); f.formatOptions = [.withFullDate]
            published = f.date(from: String(d.prefix(10)))
        }

        let video = Video(id: requestedID, title: title, channel: channel, duration: duration, thumbnails: thumbs,
                          publishedAt: published, viewCount: details["viewCount"]?.int)
        let resource = PlaybackResource(
            videoID: requestedID, title: title, channelName: channel?.name, videoStreams: videoStreams, audioStreams: audioStreams,
            subtitles: captions, translationLanguages: translations, artworkURL: thumbs.last?.url,
            duration: duration, isLive: isLive, expiresAt: expires, httpUserAgent: userAgent)
        return PlayerSnapshot(resource: resource, video: video, description: details["shortDescription"]?.string ?? "")
    }
}
