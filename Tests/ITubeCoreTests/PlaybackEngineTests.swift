import Foundation
import Testing
@testable import ITubeCore

@MainActor
final class SessionSpy: AudioSessionControlling {
    var activations = 0, deactivations = 0
    func activate() { activations += 1 }
    func deactivate() { deactivations += 1 }
}

@MainActor @Suite struct PlaybackEngineTests {
    let backend = FakeBackend()
    let spy = SessionSpy()
    let video = makeVideo()
    var hlsResource: PlaybackResource { makeResource(streams: [stream("hls", audio: true, hls: true)]) }
    var mp4Resource: PlaybackResource {
        makeResource(streams: [stream("m18", audio: true, height: 360), stream("m22", audio: true, height: 720)])
    }

    func makeEngine(refresh: (@Sendable (VideoID) async throws -> PlaybackResource)? = nil) -> PlaybackEngine {
        PlaybackEngine(backend: backend, audioSession: spy, refresh: refresh)
    }

    @Test func loadTransitionsToReadyAndAutoplays() async throws {
        let e = makeEngine()
        var states: [PlaybackState] = []
        e.onNotification = { if case .stateChanged(let s) = $0 { states.append(s) } }
        try await e.load(video: video, resource: hlsResource, policy: StreamPolicy(), startAt: nil, autoplay: true)
        #expect(states == [.loading, .ready])
        #expect(e.isMediaLoaded); #expect(e.currentVideo == video); #expect(e.duration == .seconds(212))
        #expect(backend.plays == [1.0]); #expect(spy.activations == 1)
        backend.send(.timeControl(.playing)); await settle()
        #expect(e.state == .playing)
    }

    @Test func audioSessionIsActivatedOnlyWhenPlaybackStarts() async throws {
        let e = makeEngine()
        try await e.load(video: video, resource: hlsResource, policy: StreamPolicy(), startAt: nil, autoplay: false)
        #expect(spy.activations == 0)
        e.play()
        #expect(spy.activations == 1)
    }

    @Test func eventsDriveAnExplicitStateMachine() async throws {
        let e = makeEngine()
        try await e.load(video: video, resource: hlsResource, policy: StreamPolicy(), startAt: nil, autoplay: true)
        backend.send(.timeControl(.waiting)); await settle(); #expect(e.state == .buffering)
        backend.send(.timeControl(.playing)); await settle(); #expect(e.state == .playing)
        backend.send(.timeControl(.paused)); await settle(); #expect(e.state == .paused)
        #expect(!e.wantsToPlay)                                   // a system/PiP pause is respected, not fought
    }

    @Test func failedLoadSetsFailedAndThrowsMappedError() async {
        let e = makeEngine()
        backend.loadError = PlaybackError.invalidManifest
        await #expect(throws: PlaybackError.invalidManifest) {
            try await e.load(video: video, resource: hlsResource, policy: StreamPolicy(), startAt: nil, autoplay: true)
        }
        #expect(e.state == .failed(.invalidManifest)); #expect(!e.isMediaLoaded)
    }

    @Test func unplayableResourceFailsBeforeTouchingTheBackend() async {
        let e = makeEngine()
        await #expect(throws: PlaybackError.unavailable) {
            try await e.load(video: video, resource: makeResource(streams: []), policy: StreamPolicy(), startAt: nil, autoplay: true)
        }
        #expect(backend.loads.isEmpty)
    }

    @Test func seekingClampsToDuration() async throws {
        let e = makeEngine()
        try await e.load(video: video, resource: hlsResource, policy: StreamPolicy(), startAt: nil, autoplay: false)
        await e.seek(to: .seconds(9999)); #expect(backend.seeks.last == .seconds(212))
        await e.seek(to: .seconds(-5)); #expect(backend.seeks.last == .zero)
        await e.seek(by: .seconds(30)); #expect(backend.seeks.last == .seconds(30))
        #expect(e.currentTime == .seconds(30))
    }

    @Test func seekBeforeLoadIsIgnored() async {
        let e = makeEngine()
        await e.seek(to: .seconds(5))
        #expect(backend.seeks.isEmpty)
    }

    @Test func rateIsClampedAndAppliedToBackend() async throws {
        let e = makeEngine()
        e.setRate(5); #expect(e.rate == 2.0)
        e.setRate(0.01); #expect(e.rate == 0.25)
        e.setRate(1.5); #expect(backend.rates.last == 1.5)
        try await e.load(video: video, resource: hlsResource, policy: StreamPolicy(), startAt: nil, autoplay: true)
        #expect(backend.plays.last == 1.5)                         // rate persists across items
    }

    @Test func playbackCompletionNotifiesAndLoopRestarts() async throws {
        let e = makeEngine()
        var ended = 0
        e.onNotification = { if $0 == .ended { ended += 1 } }
        try await e.load(video: video, resource: hlsResource, policy: StreamPolicy(), startAt: nil, autoplay: true)
        backend.send(.ended); await settle()
        #expect(e.state == .ended); #expect(ended == 1)

        e.setLooping(true)
        backend.send(.ended); await settle()
        #expect(ended == 1)                                        // loop: no completion notification
        #expect(backend.seeks.last == .zero); #expect(backend.plays.count >= 2)
    }

    @Test func progressEventsUpdateTimeAndNotify() async throws {
        let e = makeEngine()
        var last: Duration?
        e.onNotification = { if case .progress(let p, _) = $0 { last = p } }
        try await e.load(video: video, resource: hlsResource, policy: StreamPolicy(), startAt: nil, autoplay: true)
        backend.send(.time(.seconds(42))); await settle()
        #expect(e.currentTime == .seconds(42)); #expect(last == .seconds(42))
    }

    @Test func advertisementAndSponsorRangesAreSkippedWhilePlaying() async throws {
        let e = makeEngine()
        try await e.load(video: video, resource: hlsResource, policy: StreamPolicy(), startAt: nil, autoplay: true)
        e.skipRanges = [.seconds(10) ... .seconds(20)]
        backend.send(.timeControl(.playing)); await settle()
        backend.send(.time(.seconds(12))); await settle()
        #expect(backend.seeks.contains(.seconds(20)))
        backend.seeks.removeAll()
        backend.send(.time(.seconds(25))); await settle()
        #expect(backend.seeks.isEmpty)
    }

    @Test func expiredStreamIsRefreshedAndPositionRateAndPlayStateRestored() async throws {
        let fresh = hlsResource
        let e = makeEngine(refresh: { _ in fresh })
        e.setRate(1.5)
        try await e.load(video: video, resource: hlsResource, policy: StreamPolicy(quality: .p720), startAt: nil, autoplay: true)
        backend.send(.timeControl(.playing)); backend.send(.time(.seconds(77))); await settle()
        backend.send(.failed(.streamExpired)); await settle()
        #expect(backend.loads.count == 2)
        #expect(backend.loads[1].startAt == .seconds(77))          // timestamp preserved
        #expect(backend.loads[1].quality == .p720)                 // quality preference preserved
        #expect(backend.plays.last == 1.5)                         // rate + playing preserved
        #expect(e.state != .failed(.streamExpired))
    }

    @Test func refreshIsBoundedAndNeverLoopsForever() async throws {
        let counter = Counter()
        let fresh = hlsResource
        let e = makeEngine(refresh: { _ in await counter.bump(); return fresh })
        try await e.load(video: video, resource: hlsResource, policy: StreamPolicy(), startAt: nil, autoplay: true)
        for _ in 0..<5 { backend.send(.failed(.streamExpired)); await settle() }
        #expect(await counter.n == 2)
        #expect(e.state == .failed(.streamExpired))
    }

    @Test func refreshFailureSurfacesAnError() async throws {
        let e = makeEngine(refresh: { _ in throw ProviderError.unavailable })
        try await e.load(video: video, resource: hlsResource, policy: StreamPolicy(), startAt: nil, autoplay: true)
        backend.send(.failed(.streamExpired)); await settle()
        #expect(e.state == .failed(.unavailable))
    }

    @Test func nonExpiryFailuresAreNotRetried() async throws {
        let counter = Counter()
        let fresh = hlsResource
        let e = makeEngine(refresh: { _ in await counter.bump(); return fresh })
        try await e.load(video: video, resource: hlsResource, policy: StreamPolicy(), startAt: nil, autoplay: true)
        backend.send(.failed(.unsupportedCodec)); await settle()
        #expect(await counter.n == 0); #expect(e.state == .failed(.unsupportedCodec))
    }

    @Test func qualityOnHLSOnlyAppliesACap() async throws {
        let e = makeEngine()
        try await e.load(video: video, resource: hlsResource, policy: StreamPolicy(), startAt: nil, autoplay: false)
        await e.setQuality(.p480)
        #expect(backend.appliedQualities == [.p480]); #expect(backend.loads.count == 1); #expect(e.quality == .p480)
    }

    @Test func qualityOnProgressiveReloadsAtSamePosition() async throws {
        let e = makeEngine()
        try await e.load(video: video, resource: mp4Resource, policy: StreamPolicy(allowComposition: false), startAt: nil, autoplay: true)
        backend.send(.time(.seconds(30))); await settle()
        await e.setQuality(.p360)
        #expect(backend.loads.count == 2)
        guard case .progressive(let url, _) = backend.loads[1].media else { Issue.record("expected progressive"); return }
        #expect(url.lastPathComponent == "m18"); #expect(backend.loads[1].startAt == .seconds(30))
    }

    @Test func newerLoadSupersedesOlder() async throws {
        let e = makeEngine()
        try await e.load(video: video, resource: hlsResource, policy: StreamPolicy(), startAt: nil, autoplay: false)
        let second = makeVideo("9bZkp7q19f0", title: "Two")
        e.beginResolving(second)
        // The previous item stays loaded until the replacement is ready (ADR §8).
        #expect(e.state == .resolving); #expect(e.isMediaLoaded); #expect(e.currentVideo == video)
        try await e.load(video: second, resource: makeResource("9bZkp7q19f0", streams: [stream("hls2", audio: true, hls: true)]),
                         policy: StreamPolicy(), startAt: nil, autoplay: false)
        #expect(e.currentVideo == second)
    }

    @Test func stopReleasesMediaAndDeactivatesSession() async throws {
        let e = makeEngine()
        try await e.load(video: video, resource: hlsResource, policy: StreamPolicy(), startAt: nil, autoplay: true)
        e.stop()
        #expect(e.state == .idle); #expect(!e.isMediaLoaded); #expect(e.resource == nil)
        #expect(backend.stopped == 1); #expect(spy.deactivations == 1)
    }

    @Test func shutdownFinishesTheEventLoop() async {
        let e = makeEngine()
        e.shutdown()
        #expect(backend.isShutDown)
    }

    @Test func restoredSessionShowsMetadataWithoutLoadingOrPlaying() {
        let e = makeEngine()
        e.prepareRestored(video: video, position: .seconds(90), rate: 1.25, quality: .p720)
        #expect(e.currentVideo == video); #expect(e.currentTime == .seconds(90)); #expect(e.rate == 1.25)
        #expect(!e.isMediaLoaded); #expect(backend.loads.isEmpty); #expect(backend.plays.isEmpty); #expect(spy.activations == 0)
        e.play()
        #expect(backend.plays.isEmpty)                             // no audio after a cold launch until the user loads it
    }
}

@Suite struct PlaybackErrorMapperTests {
    @Test func http403InsideCoreMediaMapsToExpired() {
        let inner = NSError(domain: "CoreMediaErrorDomain", code: -12660)
        let outer = NSError(domain: "AVFoundationErrorDomain", code: -11800, userInfo: [NSUnderlyingErrorKey: inner])
        #expect(PlaybackErrorMapper.map(outer) == .streamExpired)
    }
    @Test func offlineAndUnknown() {
        #expect(PlaybackErrorMapper.map(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)) == .networkUnavailable)
        #expect(PlaybackErrorMapper.map(NSError(domain: "x", code: 1)) == .playbackFailed)
        #expect(PlaybackErrorMapper.map(nil) == .playbackFailed)
    }
}
