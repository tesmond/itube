import Foundation
import Testing
@testable import ITubeCore

@Suite struct StreamSelectorTests {
    let selector = StreamSelector()
    let audio = stream("a140", video: false, audio: true, container: .m4a, codecs: ["mp4a.40.2"], bitrate: 130_000)

    @Test func prefersHLSWhenAvailable() throws {
        let r = makeResource(streams: [stream("m18", audio: true, height: 360), stream("hls", audio: true, hls: true)])
        guard case .hls(let url, let ua) = try selector.select(r, policy: StreamPolicy()) else { Issue.record("expected HLS"); return }
        #expect(url.lastPathComponent == "hls"); #expect(ua == "UA")
    }

    @Test func autoPicksHighestNativelyPlayablePath() throws {
        let r = makeResource(streams: [stream("m18", audio: true, height: 360), stream("v137", height: 1080)], audio: [audio])
        guard case .composition(let v, let a, _) = try selector.select(r, policy: StreamPolicy()) else { Issue.record("expected composition"); return }
        #expect(v.lastPathComponent == "v137"); #expect(a.lastPathComponent == "a140")
    }

    @Test func compositionCanBeDisabled() throws {
        let r = makeResource(streams: [stream("m18", audio: true, height: 360), stream("v137", height: 1080)], audio: [audio])
        guard case .progressive(let url, _) = try selector.select(r, policy: StreamPolicy(allowComposition: false)) else { Issue.record("expected progressive"); return }
        #expect(url.lastPathComponent == "m18")
    }

    @Test func manualQualityCapsAndFallsBackToLowest() throws {
        let r = makeResource(streams: [stream("m18", audio: true, height: 360), stream("v137", height: 1080), stream("v136", height: 720)], audio: [audio])
        guard case .composition(let v, _, _) = try selector.select(r, policy: StreamPolicy(quality: .p720)) else { Issue.record("shape"); return }
        #expect(v.lastPathComponent == "v136")
        guard case .progressive(let low, _) = try selector.select(r, policy: StreamPolicy(quality: .p144)) else { Issue.record("shape"); return }
        #expect(low.lastPathComponent == "m18")                              // nothing ≤144p exists → lowest available
    }

    @Test func nonNativeCodecsAreNeverSelected() {
        let r = makeResource(streams: [stream("vp9", height: 1080, container: .webm, codecs: ["vp9"])], audio: [audio])
        #expect(throws: PlaybackError.unsupportedCodec) { try selector.select(r, policy: StreamPolicy()) }
        #expect(throws: PlaybackError.unavailable) { try selector.select(makeResource(streams: []), policy: StreamPolicy()) }
    }

    @Test func availableQualitiesShowOnlyWhatExists() {
        let r = makeResource(streams: [stream("m18", audio: true, height: 360), stream("v137", height: 1080), stream("v22", height: 720)], audio: [audio])
        #expect(selector.availableQualities(r, policy: StreamPolicy()) == [.auto, .p360, .p720, .p1080])
        #expect(selector.availableQualities(r, policy: StreamPolicy(allowComposition: false)) == [.auto, .p360])
        let hls = makeResource(streams: [stream("hls", audio: true, hls: true)])
        #expect(selector.availableQualities(hls, policy: StreamPolicy(), hlsHeights: [240, 1080]) == [.auto, .p240, .p1080])
        #expect(selector.availableQualities(hls, policy: StreamPolicy()) == [.auto])
    }

    @Test func portraitVideoIsLabelledByShortSide() {
        let s = MediaStream(id: "p", url: URL(string: "https://x.example.com")!, container: .mp4, hasVideo: true, hasAudio: true, width: 1080, height: 1920)
        #expect(s.qualityHeight == 1080)
        #expect(VideoQuality(height: 1080) == .p1080); #expect(VideoQuality(height: 500) == .p480); #expect(VideoQuality(height: 100) == nil)
    }
}

@Suite struct AdSuppressionTests {
    private let url = { (s: String) in URL(string: s)! }

    @Test func knownAdvertisementStreamIsRemovedAndContentRetained() {
        let ad = MediaStream(id: "ad", url: url("https://pagead2.googlesyndication.com/ad.mp4"), container: .mp4, hasVideo: true, hasAudio: true)
        let content = stream("c", audio: true, height: 720)
        let r = AdSuppressionEngine().process(makeResource(streams: [ad, content]), enabled: true)
        #expect(r.videoStreams.map(\.id) == ["c"])
    }

    @Test func disabledEngineChangesNothing() {
        let ad = MediaStream(id: "ad", url: url("https://doubleclick.net/ad.mp4"), container: .mp4, hasVideo: true, hasAudio: true)
        let input = makeResource(streams: [ad, stream("c", audio: true, height: 720)])
        #expect(AdSuppressionEngine().process(input, enabled: false) == input)
    }

    @Test func unknownSegmentsAreRetainedAndNeverBecomeAds() {
        let seg = MediaSegment(url: url("https://cdn.example.com/seg1.ts"), range: .seconds(0) ... .seconds(10), kind: .unknown)
        let r = AdSuppressionEngine().process(makeResource(streams: [stream("c", audio: true, height: 720)], segments: [seg]), enabled: true)
        #expect(r.segments.first?.kind == .unknown)
        #expect(AdSuppressionEngine().advertisementRanges(in: r, enabled: true).isEmpty)
    }

    @Test func providerMarkedAdvertisementRangesAreExposed() {
        let segs = [MediaSegment(range: .seconds(10) ... .seconds(20), kind: .advertisement),
                    MediaSegment(range: .seconds(15) ... .seconds(30), kind: .advertisement),
                    MediaSegment(range: .seconds(40) ... .seconds(50), kind: .content)]
        let r = makeResource(streams: [stream("c", audio: true, height: 720)], segments: segs)
        #expect(AdSuppressionEngine().advertisementRanges(in: r, enabled: true) == [.seconds(10) ... .seconds(30)])
        #expect(AdSuppressionEngine().advertisementRanges(in: r, enabled: false).isEmpty)
    }

    @Test func neverRemovesEveryPlayableStream() {
        let ad = MediaStream(id: "ad", url: url("https://doubleclick.net/ad.mp4"), container: .mp4, hasVideo: true, hasAudio: true)
        let input = makeResource(streams: [ad])
        #expect(AdSuppressionEngine().process(input, enabled: true).videoStreams.count == 1)   // false positives must not break playback
    }

    @Test func malformedOrOlderRuleUpdatesAreIgnored() {
        let current = AdRuleSet.default
        #expect(AdRuleSet.decode(Data("garbage".utf8), replacing: current) == nil)
        #expect(AdRuleSet.decode(try! JSONEncoder().encode(AdRuleSet(version: 1, blockedHosts: ["x.com"])), replacing: current) == nil)
        let good = AdRuleSet.decode(try! JSONEncoder().encode(AdRuleSet(version: 2, blockedHosts: ["Ads.Example.com", "../etc", "with space.com", "nodots"])), replacing: current)
        #expect(good?.blockedHosts == ["ads.example.com"])
    }

    @Test func classifierWithEmptyRulesBlocksNothing() {
        let c = RuleBasedAdClassifier(rules: AdRuleSet(version: 1, blockedHosts: []))
        #expect(c.classify(stream("x")) == .unknown)
    }
}

@Suite struct SegmentSkipTests {
    private func seg(_ a: Int, _ b: Int, _ c: SegmentCategory?) -> MediaSegment {
        MediaSegment(range: .seconds(a) ... .seconds(b), kind: .content, category: c)
    }

    @Test func onlySelectedCategoriesAreSkippedAndRangesMerge() {
        let r = makeResource(streams: [stream("c", audio: true)], segments: [seg(0, 10, .intro), seg(5, 15, .sponsor), seg(12, 20, .sponsor), seg(50, 60, .outro), seg(70, 80, nil)])
        let ranges = SegmentSkipEngine().skipRanges(for: r, categories: [.sponsor, .intro], enabled: true)
        #expect(ranges == [.seconds(0) ... .seconds(20)])
        #expect(SegmentSkipEngine().skipRanges(for: r, categories: [.outro], enabled: true) == [.seconds(50) ... .seconds(60)])
        #expect(SegmentSkipEngine().skipRanges(for: r, categories: [.sponsor], enabled: false).isEmpty)
        #expect(SegmentSkipEngine().skipRanges(for: r, categories: [], enabled: true).isEmpty)
    }
}

@Suite struct StreamResolverTests {
    actor CountingProvider: VideoProvider {
        nonisolated let id = "fake"; nonisolated let displayName = "Fake"; nonisolated let capabilities: ProviderCapabilities = [.search]
        var fetches = 0, invalidations = 0
        let resource: PlaybackResource
        init(_ r: PlaybackResource) { resource = r }
        func search(_ request: SearchRequest) async throws -> SearchPage { SearchPage(items: []) }
        func details(for id: VideoID) async throws -> VideoDetails { VideoDetails(video: makeVideo()) }
        func playbackResource(for id: VideoID) async throws -> PlaybackResource {
            fetches += 1
            try await Task.sleep(for: .milliseconds(30))
            return resource
        }
        func invalidatePlaybackResource(for id: VideoID) async { invalidations += 1 }
    }

    @Test func concurrentRequestsAreCoalesced() async throws {
        let p = CountingProvider(makeResource(streams: [stream("c", audio: true, height: 360)]))
        let resolver = StreamResolver(registry: ProviderRegistry(providers: [p]))
        async let a = resolver.resolve("dQw4w9WgXcQ", forceRefresh: false, adSuppression: true)
        async let b = resolver.resolve("dQw4w9WgXcQ", forceRefresh: false, adSuppression: true)
        _ = try await (a, b)
        #expect(await p.fetches == 1)
    }

    @Test func forceRefreshInvalidatesProviderCache() async throws {
        let p = CountingProvider(makeResource(streams: [stream("c", audio: true, height: 360)]))
        let resolver = StreamResolver(registry: ProviderRegistry(providers: [p]))
        _ = try await resolver.resolve("dQw4w9WgXcQ", forceRefresh: true, adSuppression: true)
        #expect(await p.invalidations == 1)
    }

    @Test func noProviderMeansUnavailable() async {
        let resolver = StreamResolver(registry: ProviderRegistry(providers: []))
        await #expect(throws: PlaybackError.unavailable) { try await resolver.resolve("dQw4w9WgXcQ", forceRefresh: false, adSuppression: true) }
    }
}
