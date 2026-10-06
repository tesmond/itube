import Foundation
import Testing
@testable import ITubeCore

@MainActor @Suite struct QueueManagerTests {
    let a = makeVideo("AAAAAAAAAAA"), b = makeVideo("BBBBBBBBBBB"), c = makeVideo("CCCCCCCCCCC"), d = makeVideo("DDDDDDDDDDD")

    @Test func startAdvanceRetreat() {
        let q = QueueManager()
        q.start(with: a, upcoming: [b, c])
        #expect(q.queue.current == a && q.queue.upcoming == [b, c])
        #expect(q.advance() == b); #expect(q.queue.previous == [a]); #expect(q.queue.upcoming == [c])
        #expect(q.retreat() == a); #expect(q.queue.current == a); #expect(q.queue.upcoming == [b, c])
        #expect(q.retreat() == nil)
    }

    @Test func advancingPastTheEndReturnsNilAndKeepsCurrent() {
        let q = QueueManager(); q.start(with: a)
        #expect(q.advance() == nil); #expect(q.queue.current == a)
    }

    @Test func enqueueDeduplicatesAndPlayNextJumpsTheLine() {
        let q = QueueManager(); q.start(with: a, upcoming: [b])
        q.enqueue(b); q.enqueue(a); q.enqueue(c)
        #expect(q.queue.upcoming == [b, c])
        q.playNext(c); #expect(q.queue.upcoming == [c, b])
    }

    @Test func startingAnUpcomingVideoRemovesItFromUpcoming() {
        let q = QueueManager(); q.start(with: a, upcoming: [b, c])
        q.start(with: b)
        #expect(q.queue.upcoming == [c]); #expect(q.queue.previous == [a])
    }

    @Test func queueIsBounded() {
        let q = QueueManager()
        let many = (0..<(PlaybackQueue.maxUpcoming + 50)).map { makeVideo(String(format: "V%010d", $0)) }
        q.start(with: a, upcoming: many)
        #expect(q.queue.upcoming.count == PlaybackQueue.maxUpcoming)
        for i in 0..<(PlaybackQueue.maxPrevious + 20) { q.start(with: makeVideo(String(format: "P%010d", i))) }
        #expect(q.queue.previous.count == PlaybackQueue.maxPrevious)
    }

    @Test func changesAreReported() {
        let q = QueueManager(); var n = 0
        q.onChange = { _ in n += 1 }
        q.start(with: a); q.enqueue(b); q.remove(b.id); q.clearUpcoming()
        #expect(n == 4)
    }

    @Test func moveReorders() {
        let q = QueueManager(); q.start(with: a, upcoming: [b, c, d])
        q.move(from: IndexSet(integer: 0), to: 3)
        #expect(q.queue.upcoming == [c, d, b])
    }
}

@MainActor @Suite struct SleepTimerTests {
    @Test func endOfVideoTimerConsumesTheEndEventOnce() {
        let t = SleepTimer(); var fired = 0
        t.onFire = { fired += 1 }
        #expect(t.consumeVideoEnd() == false)
        t.start(.endOfVideo)
        #expect(t.consumeVideoEnd()); #expect(fired == 1)
        #expect(t.consumeVideoEnd() == false); #expect(t.option == nil)
    }

    @Test func timedTimerFiresAndPausesNeverTerminates() async throws {
        let t = SleepTimer(); var fired = 0
        t.onFire = { fired += 1 }
        t.start(.minutes(5)); #expect(t.fireDate != nil)
        t.cancel(); #expect(t.option == nil && t.fireDate == nil)
        #expect(fired == 0)
        #expect(SleepTimerOption.all.count == 7)
    }
}

@Suite struct CacheTests {
    final class Clock: @unchecked Sendable {            // test-only; mutated from the single test task
        var now = Date(timeIntervalSince1970: 0)
    }

    @Test func entriesExpire() async {
        let clock = Clock()
        let cache = MetadataCache<String, Int>(capacity: 4, ttl: 10, now: { clock.now })
        await cache.insert(1, for: "a")
        #expect(await cache.value(for: "a") == 1)
        clock.now = Date(timeIntervalSince1970: 11)
        #expect(await cache.value(for: "a") == nil)
        #expect(await cache.count == 0)
    }

    @Test func capacityIsEnforcedWithLRUEviction() async {
        let cache = MetadataCache<Int, Int>(capacity: 2, ttl: 100)
        await cache.insert(1, for: 1); await cache.insert(2, for: 2)
        _ = await cache.value(for: 1)                          // 1 is now most recently used
        await cache.insert(3, for: 3)
        #expect(await cache.value(for: 2) == nil)
        #expect(await cache.value(for: 1) == 1); #expect(await cache.value(for: 3) == 3)
        await cache.removeAll(); #expect(await cache.count == 0)
    }
}

@Suite struct SettingsAndModelTests {
    @Test func qualityFollowsNetworkCost() {
        var s = AppSettings()
        s.defaultQuality = .p1080; s.mobileQuality = .p480; s.wifiQuality = .auto
        #expect(s.quality(isExpensiveNetwork: false) == .p1080)
        #expect(s.quality(isExpensiveNetwork: true) == .p480)
        s.wifiQuality = .p720; #expect(s.quality(isExpensiveNetwork: false) == .p720)
        s.useMobileQualityOnCellular = false; #expect(s.quality(isExpensiveNetwork: true) == .p1080)
    }

    @Test func settingsRoundTripAndSafeDefaults() {
        let defaults = UserDefaults(suiteName: "itube.tests.\(UUID().uuidString)")!
        let store = SettingsStore(defaults: defaults)
        #expect(store.load() == AppSettings())
        #expect(AppSettings().adSuppression && AppSettings().backgroundPlayback && AppSettings().automaticPiP)
        #expect(!AppSettings().sponsorSkipping)
        var s = AppSettings(); s.playbackSpeed = 1.5; s.skipCategories = [.intro]; s.captionLanguage = "fr"
        store.save(s); #expect(store.load() == s)
        defaults.set(Data("corrupt".utf8), forKey: "itube.settings.v1")
        #expect(store.load() == AppSettings())                 // corrupt data falls back to defaults
    }

    @Test func deepLinksAreValidated() {
        #expect(DeepLink(url: URL(string: "itube://video/dQw4w9WgXcQ")!) == .video("dQw4w9WgXcQ"))
        #expect(DeepLink(url: URL(string: "itube://video/short")!) == nil)
        #expect(DeepLink(url: URL(string: "itube://video/dQw4w9WgXc!")!) == nil)
        #expect(DeepLink(url: URL(string: "https://video/dQw4w9WgXcQ")!) == nil)
        #expect(DeepLink(url: URL(string: "itube://other/dQw4w9WgXcQ")!) == nil)
        #expect(DeepLink(url: URL(string: "itube://video/../../x")!) == nil)
    }

    @Test func durationHelpers() {
        #expect(Duration.seconds(75).clockString == "1:15"); #expect(Duration.seconds(3723).clockString == "1:02:03")
        #expect(Duration(seconds: .nan) == .zero); #expect(Duration(seconds: -4) == .zero)
        #expect(Duration.milliseconds(1500).totalSeconds == 1.5)
    }

    @Test func videoCompactionKeepsOneThumbnail() {
        let v = Video(id: "dQw4w9WgXcQ", title: "t", thumbnails: [
            Thumbnail(url: URL(string: "https://x.example.com/1")!, width: 120), Thumbnail(url: URL(string: "https://x.example.com/2")!, width: 480),
            Thumbnail(url: URL(string: "https://x.example.com/3")!, width: 1280)])
        #expect(v.compacted().thumbnails.count == 1); #expect(v.compacted().thumbnails[0].width == 480)
        #expect(v.thumbnail(forWidth: 2000)?.width == 1280)
    }

    @Test func providerSetsAreSwappableAtBuildTime() {
        let http = MockHTTPClient { _ in (Data(), 200) }
        #expect(FullProviderSet().makeRegistry(http: http, authentication: AnonymousAuthenticationProvider()).primary?.id == "youtube")
        #expect(AppStoreProviderSet().makeRegistry(http: http, authentication: AnonymousAuthenticationProvider()).primary == nil)
    }
}

@Suite struct PersistenceTests {
    func stack() throws -> PersistenceStack { try PersistenceStack.make(inMemory: true) }

    @Test func historyRecordsPositionsAndOrdersByRecency() async throws {
        let s = try stack().history
        let a = makeVideo("AAAAAAAAAAA"), b = makeVideo("BBBBBBBBBBB")
        await s.recordWatch(video: a, position: .seconds(30), duration: .seconds(100))
        await s.recordWatch(video: b, position: .seconds(10), duration: .seconds(50))
        await s.updatePosition(videoID: a.id, position: .seconds(60), duration: .seconds(100))
        let pos = try #require(await s.position(for: a.id))
        #expect(pos.position == .seconds(60)); #expect(pos.fraction == 0.6)
        #expect(await s.position(for: "ZZZZZZZZZZZ") == nil)
        #expect(await s.recent(limit: 10).map(\.id.rawValue) == ["BBBBBBBBBBB", "AAAAAAAAAAA"])
        await s.updatePosition(videoID: "ZZZZZZZZZZZ", position: .seconds(1), duration: nil)      // unknown id: no phantom entry
        #expect(await s.recent(limit: 10).count == 2)
        await s.remove(videoID: a.id); #expect(await s.recent(limit: 10).count == 1)
        await s.clearHistory(); #expect(await s.recent(limit: 10).isEmpty)
    }

    @Test func watchingAgainUpdatesInsteadOfDuplicating() async throws {
        let s = try stack().history
        let a = makeVideo()
        await s.recordWatch(video: a, position: .seconds(5), duration: nil)
        await s.recordWatch(video: a, position: .seconds(50), duration: .seconds(200))
        #expect(await s.recent(limit: 10).count == 1); #expect(await s.position(for: a.id)?.position == .seconds(50))
    }

    @Test func searchHistoryDedupesTrimsAndRejectsJunk() async throws {
        let s = try stack().history
        await s.recordSearch("  swift  "); await s.recordSearch("swiftui"); await s.recordSearch("swift")
        await s.recordSearch("   "); await s.recordSearch(String(repeating: "x", count: 300))
        #expect(await s.recentSearches(limit: 10) == ["swift", "swiftui"])
        await s.removeSearch("swift"); #expect(await s.recentSearches(limit: 10) == ["swiftui"])
        await s.clearSearches(); #expect(await s.recentSearches(limit: 10).isEmpty)
    }

    @Test func bookmarksPlaylistsSubscriptions() async throws {
        let l = try stack().library
        let a = makeVideo("AAAAAAAAAAA"), b = makeVideo("BBBBBBBBBBB")
        await l.setBookmark(a, bookmarked: true); await l.setBookmark(a, bookmarked: true)
        #expect(await l.bookmarks().count == 1); #expect(await l.isBookmarked(a.id))
        await l.setBookmark(a, bookmarked: false); #expect(await l.bookmarks().isEmpty)

        let p = try #require(await l.createPlaylist(name: "  Mix  "))
        #expect(p.name == "Mix")
        #expect(await l.createPlaylist(name: "   ") == nil)
        await l.add(a, toPlaylist: p.id); await l.add(a, toPlaylist: p.id); await l.add(b, toPlaylist: p.id)
        #expect(await l.playlists().first?.videos.map(\.id) == [a.id, b.id])
        await l.remove(videoID: a.id, fromPlaylist: p.id); #expect(await l.playlists().first?.videos.count == 1)
        await l.deletePlaylist(p.id); #expect(await l.playlists().isEmpty)

        let ch = ChannelSummary(id: "UCabc123", name: "Chan")
        await l.setSubscribed(ch, subscribed: true); #expect(await l.isSubscribed(ch.id)); #expect(await l.subscriptions().count == 1)
        await l.setSubscribed(ch, subscribed: false); #expect(await l.subscriptions().isEmpty)
    }

    @Test func sessionRoundTrips() async throws {
        let s = try stack().session
        #expect(await s.load() == nil)
        let session = PersistedSession(queue: PlaybackQueue(current: makeVideo(), upcoming: [makeVideo("BBBBBBBBBBB")]), position: 12.5,
                                       rate: 1.25, quality: .p720, captionsEnabled: true, captionLanguage: "en")
        await s.save(session); await s.save(session)
        #expect(await s.load() == session)
        await s.clear(); #expect(await s.load() == nil)
    }
}
