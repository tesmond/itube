import Foundation
import Testing
@testable import ITubeCore

actor Counter { var n = 0; func bump() { n += 1 } }

@Suite struct NetworkingTests {
    private func get(_ s: String) -> URLRequest { URLRequest(url: URL(string: s)!) }

    @Test func retriesTransientFailuresThenSucceeds() async throws {
        let counter = Counter()
        let http = MockHTTPClient { _ in
            // Simulates two 503s followed by success.
            (Data("ok".utf8), 200)
        }
        let flaky = FlakyClient(base: http, failures: [HTTPError.status(503), HTTPError.status(502)], counter: counter)
        let sleeps = Counter()
        let client = RetryingHTTPClient(base: flaky, sleep: { _ in await sleeps.bump() })
        let (data, _) = try await client.data(for: get("https://a.example.com"))
        #expect(String(data: data, encoding: .utf8) == "ok")
        #expect(await counter.n == 3)
        #expect(await sleeps.n == 2)
    }

    @Test func permanentFailuresFailImmediately() async {
        let http = MockHTTPClient { _ in (Data(), 404) }
        let client = RetryingHTTPClient(base: http, sleep: { _ in })
        await #expect(throws: HTTPError.status(404)) { try await client.data(for: get("https://a.example.com")) }
        #expect(await http.requests.count == 1)
    }

    @Test func retriesAreBounded() async {
        let http = MockHTTPClient { _ in (Data(), 503) }
        let client = RetryingHTTPClient(base: http, sleep: { _ in })
        await #expect(throws: HTTPError.status(503)) { try await client.data(for: get("https://a.example.com")) }
        #expect(await http.requests.count == 4)                  // 1 attempt + 3 backoff retries, never infinite
    }

    @Test func rateLimitAndTimeoutAreTransient() {
        #expect(RetryingHTTPClient.isTransient(HTTPError.status(429)))
        #expect(RetryingHTTPClient.isTransient(HTTPError.status(408)))
        #expect(RetryingHTTPClient.isTransient(URLError(.timedOut)))
        #expect(!RetryingHTTPClient.isTransient(HTTPError.status(401)))
        #expect(!RetryingHTTPClient.isTransient(HTTPError.blockedByPolicy))
        #expect(!RetryingHTTPClient.isTransient(CancellationError()))
    }

    @Test func cancellationStopsRetrying() async {
        let http = MockHTTPClient { _ in (Data(), 503) }
        let client = RetryingHTTPClient(base: http, sleep: { _ in throw CancellationError() })
        await #expect(throws: CancellationError.self) { try await client.data(for: get("https://a.example.com")) }
        #expect(await http.requests.count == 1)
    }

    @Test func policyBlocksTrackersAndAllowsMedia() async throws {
        let http = MockHTTPClient { _ in (Data("x".utf8), 200) }
        let client = PolicyEnforcingHTTPClient(base: http, policy: DomainDenylistPolicy())
        await #expect(throws: HTTPError.blockedByPolicy) { try await client.data(for: get("https://securepubads.g.doubleclick.net/pagead")) }
        await #expect(throws: HTTPError.blockedByPolicy) { try await client.data(for: get("https://www.google-analytics.com/collect")) }
        _ = try await client.data(for: get("https://i.ytimg.com/vi/x/hq.jpg"))
        _ = try await client.data(for: get("https://www.youtube.com/youtubei/v1/player"))
        #expect(await http.requests.count == 2)                  // blocked requests never reached the network
    }

    @Test func denylistMatchesSubdomainsNotLookalikes() {
        let p = DomainDenylistPolicy(domains: ["doubleclick.net"])
        #expect(p.evaluate(get("https://doubleclick.net/")) == .deny)
        #expect(p.evaluate(get("https://x.y.doubleclick.net/")) == .deny)
        #expect(p.evaluate(get("https://notdoubleclick.net/")) == .allow)
        #expect(p.evaluate(get("https://doubleclick.net.evil.com/")) == .allow)
        #expect(CompositePolicy([AllowAllPolicy(), p]).evaluate(get("https://doubleclick.net/")) == .deny)
    }

    @Test func plainHTTPIsRefusedBeforeAnyNetworkActivity() async {
        let client = URLSessionHTTPClient()
        await #expect(throws: HTTPError.insecureScheme) { try await client.data(for: get("http://example.com/")) }
        await #expect(throws: HTTPError.insecureScheme) { try await client.data(for: URLRequest(url: URL(string: "file:///etc/hosts")!)) }
    }

    @Test func logsRedactSignedURLs() {
        let url = URL(string: "https://rr1.googlevideo.com/videoplayback?sig=SECRET&key=abc")!
        let redacted = URLRedactor.redact(url)
        #expect(!redacted.contains("SECRET")); #expect(!redacted.contains("sig")); #expect(redacted.hasPrefix("rr1.googlevideo.com"))
        #expect(URLRedactor.redact(nil) == "<invalid-url>")
    }

    @Test func errorMappingNeverLeaksDetails() {
        #expect(PlaybackError(HTTPError.status(403)) == .streamExpired)
        #expect(PlaybackError(HTTPError.status(404)) == .unavailable)
        #expect(PlaybackError(URLError(.notConnectedToInternet)) == .networkUnavailable)
        #expect(PlaybackError(ProviderError.restricted) == .restricted)
        #expect(PlaybackError(ProviderError.parsing("secret detail")) == .providerFailure)
        #expect(!PlaybackError.providerFailure.userMessage.contains("parsing"))
    }
}

/// Fails with the queued errors first, then delegates.
actor FlakyClient: HTTPClient {
    private var failures: [any Error]
    private let base: any HTTPClient
    private let counter: Counter
    init(base: any HTTPClient, failures: [any Error], counter: Counter) { self.base = base; self.failures = failures; self.counter = counter }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await counter.bump()
        if !failures.isEmpty { throw failures.removeFirst() }
        return try await base.data(for: request)
    }
}

@Suite struct HLSAndSubtitleParsingTests {
    @Test func masterPlaylistVariants() {
        let text = String(data: fixture("master", "m3u8"), encoding: .utf8)!
        let variants = HLSMasterPlaylist.parse(text)
        #expect(variants.count == 4)
        #expect(variants[1].height == 360 && variants[1].width == 640 && variants[1].bandwidth == 800_000)
        #expect(variants[0].codecs == "avc1.4d4015,mp4a.40.5")
    }

    @Test func variantHeightsUseShortSideAndAreDeduplicated() async throws {
        let m = fixture("master", "m3u8")
        let loader = ManifestLoader(http: MockHTTPClient { _ in (m, 200) })
        #expect(try await loader.variantHeights(for: URL(string: "https://x.example.com/m.m3u8")!, userAgent: nil) == [240, 360, 1080])
    }

    @Test func tolerantOfGarbage() {
        #expect(HLSMasterPlaylist.parse("not a playlist").isEmpty)
        #expect(HLSMasterPlaylist.parse("#EXT-X-STREAM-INF:RESOLUTION=1x1\nx").isEmpty)    // no BANDWIDTH → skipped
    }

    @Test func vttCuesAreParsedCleanedAndSorted() {
        let cues = VTTParser.parse(String(data: fixture("captions", "vtt"), encoding: .utf8)!)
        #expect(cues.count == 3)                                       // invalid cue (end < start) dropped
        #expect(cues[0].text == "Hello world & friends")
        #expect(cues[0].start == .milliseconds(1000) && cues[0].end == .milliseconds(3500))
        #expect(cues[1].text == "Second line\nwith break")
        #expect(cues[2].start == .seconds(3600))
    }

    @Test func vttHugeInputIsBounded() {
        let block = "00:00:01.000 --> 00:00:02.000\nx\n\n"
        #expect(VTTParser.parse(String(repeating: block, count: 20_000)).count == VTTParser.maxCues)
    }
}
