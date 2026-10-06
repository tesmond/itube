import Foundation
import MediaPlayer
import Testing
@testable import ITubeCore

@MainActor @Suite struct PlaybackCoordinatorTests {
    struct Rig {
        let coordinator: PlaybackCoordinator
        let backend: FakeBackend
        let resolver: FakeResolver
        let persistence: PersistenceStack
        let settings: SettingsManager
    }

    let a = makeVideo("AAAAAAAAAAA", title: "A"), b = makeVideo("BBBBBBBBBBB", title: "B")

    func makeRig() async throws -> Rig {
        let backend = FakeBackend()
        let resolver = FakeResolver()
        await resolver.set(makeResource("AAAAAAAAAAA", streams: [stream("hlsA", audio: true, hls: true)]))
        await resolver.set(makeResource("BBBBBBBBBBB", streams: [stream("hlsB", audio: true, hls: true)]))
        let persistence = try PersistenceStack.make(inMemory: true)
        let settings = SettingsManager(store: SettingsStore(defaults: UserDefaults(suiteName: "itube.tests.\(UUID().uuidString)")!))
        let http = MockHTTPClient { _ in (Data(), 404) }
        let coordinator = PlaybackCoordinator(
            backend: backend, resolver: resolver, videos: VideoService(registry: ProviderRegistry(providers: [])),
            history: persistence.history, sessionStore: persistence.session, settings: settings, http: http, images: nil)
        return Rig(coordinator: coordinator, backend: backend, resolver: resolver, persistence: persistence, settings: settings)
    }

    @Test func playResolvesLoadsAndPresents() async throws {
        let r = try await makeRig()
        r.coordinator.play(a, upcoming: [b])
        #expect(r.coordinator.isPlayerPresented)
        #expect(await waitFor { r.backend.loads.count == 1 })
        #expect(r.coordinator.queue.queue.current == a); #expect(r.coordinator.queue.queue.upcoming == [b])
        #expect(r.coordinator.engine.currentVideo == a)
        r.coordinator.shutdown()
    }

    @Test func miniPlayerStartDoesNotPresentFullPlayer() async throws {
        let r = try await makeRig()
        r.coordinator.play(a, present: false)
        #expect(!r.coordinator.isPlayerPresented)
        r.coordinator.shutdown()
    }

    @Test func resolveFailureSurfacesAsPlaybackError() async throws {
        let r = try await makeRig()
        await r.resolver.setFailure(ProviderError.unavailable)
        r.coordinator.play(a)
        #expect(await waitFor { r.coordinator.engine.state == .failed(.unavailable) })
        #expect(r.backend.loads.isEmpty)
        r.coordinator.shutdown()
    }

    @Test func historyIsRecordedOnlyAfterMeaningfulViewing() async throws {
        let r = try await makeRig()
        r.coordinator.play(a)
        #expect(await waitFor { r.backend.loads.count == 1 })
        r.backend.send(.timeControl(.playing)); await settle()
        r.backend.send(.time(.seconds(1))); r.backend.send(.time(.seconds(2))); await settle()
        #expect(await r.persistence.history.recent(limit: 5).isEmpty)           // opening a video is not watching it
        for s in 3...14 { r.backend.send(.time(.seconds(s))) }
        #expect(await waitFor { r.coordinator.engine.currentTime >= .seconds(14) })
        try await Task.sleep(for: .milliseconds(100))
        #expect(await r.persistence.history.recent(limit: 5).map(\.id) == [a.id])
        r.coordinator.shutdown()
    }

    @Test func historyCanBeDisabled() async throws {
        let r = try await makeRig()
        r.settings.settings.historyEnabled = false
        r.coordinator.play(a)
        #expect(await waitFor { r.backend.loads.count == 1 })
        r.backend.send(.timeControl(.playing)); await settle()
        for s in 1...20 { r.backend.send(.time(.seconds(s))) }
        #expect(await waitFor { r.coordinator.engine.currentTime >= .seconds(20) })
        try await Task.sleep(for: .milliseconds(100))
        #expect(await r.persistence.history.recent(limit: 5).isEmpty)
        r.coordinator.shutdown()
    }

    @Test func resumesPartiallyWatchedAndRestartsNearlyComplete() async throws {
        let r = try await makeRig()
        await r.persistence.history.recordWatch(video: a, position: .seconds(50), duration: .seconds(212))
        await r.persistence.history.recordWatch(video: b, position: .seconds(210), duration: .seconds(212))     // 99%
        r.coordinator.play(a)
        #expect(await waitFor { r.backend.loads.count == 1 })
        #expect(r.backend.loads[0].startAt == .seconds(50))
        r.coordinator.play(b)
        #expect(await waitFor { r.backend.loads.count == 2 })
        #expect(r.backend.loads[1].startAt == nil)
        r.coordinator.shutdown()
    }

    @Test func endOfVideoAdvancesTheQueue() async throws {
        let r = try await makeRig()
        r.coordinator.play(a, upcoming: [b])
        #expect(await waitFor { r.backend.loads.count == 1 })
        r.backend.send(.ended)
        #expect(await waitFor { r.backend.loads.count == 2 })
        #expect(r.coordinator.queue.queue.current == b); #expect(r.coordinator.queue.queue.previous == [a])
        r.coordinator.shutdown()
    }

    @Test func endOfVideoSleepTimerStopsAutoplayAndPauses() async throws {
        let r = try await makeRig()
        r.coordinator.play(a, upcoming: [b])
        #expect(await waitFor { r.backend.loads.count == 1 })
        r.coordinator.sleepTimer.start(.endOfVideo)
        r.backend.send(.ended); await settle()
        #expect(r.backend.loads.count == 1); #expect(r.backend.pauses >= 1)
        #expect(r.coordinator.sleepTimer.option == nil)
        r.coordinator.shutdown()
    }

    @Test func queueEndsQuietlyWhenNothingElseToPlay() async throws {
        let r = try await makeRig()
        r.settings.settings.autoplay = true
        r.coordinator.play(a)
        #expect(await waitFor { r.backend.loads.count == 1 })
        r.backend.send(.ended); await settle()
        #expect(r.backend.loads.count == 1)                       // no related videos known → nothing is started
        r.coordinator.shutdown()
    }

    @Test func previousRestartsCurrentVideoAfterThreeSeconds() async throws {
        let r = try await makeRig()
        r.coordinator.play(a, upcoming: [b])
        #expect(await waitFor { r.backend.loads.count == 1 })
        r.backend.send(.time(.seconds(40))); await settle()
        r.coordinator.previous(); await settle()
        #expect(r.backend.seeks.contains(.zero)); #expect(r.backend.loads.count == 1)
        r.coordinator.shutdown()
    }

    @Test func restoredSessionDoesNotPlayUntilUserAsks() async throws {
        let r = try await makeRig()
        await r.persistence.session.save(PersistedSession(queue: PlaybackQueue(current: a, upcoming: [b]), position: 33, rate: 1.25,
                                                          quality: .p720, captionsEnabled: false, captionLanguage: nil))
        await r.coordinator.restoreSession()
        #expect(r.coordinator.engine.currentVideo == a); #expect(r.coordinator.engine.currentTime == .seconds(33))
        #expect(r.coordinator.queue.queue.upcoming == [b])
        try await Task.sleep(for: .milliseconds(100))
        #expect(r.backend.loads.isEmpty && r.backend.plays.isEmpty)       // ADR §72: no audio after cold launch
        r.coordinator.togglePlayPause()
        #expect(await waitFor { r.backend.loads.count == 1 })
        #expect(r.backend.loads[0].startAt == .seconds(33))
        r.coordinator.shutdown()
    }

    @Test func backgroundPlaybackSettingIsHonoured() async throws {
        let r = try await makeRig()
        r.coordinator.play(a)
        #expect(await waitFor { r.backend.loads.count == 1 })
        r.backend.send(.timeControl(.playing)); await settle()

        r.coordinator.lifecycleChanged(.background); await settle()
        #expect(r.backend.pauses == 0)                              // default: background playback continues
        #expect(r.backend.intervals.last == 5)                      // and wakes less often while off-screen
        r.coordinator.lifecycleChanged(.active)
        #expect(r.backend.intervals.last == 0.5)

        r.settings.settings.backgroundPlayback = false
        r.coordinator.lifecycleChanged(.background); await settle()
        #expect(r.backend.pauses == 1)
        r.coordinator.shutdown()
    }

    @Test func closingTheSessionStopsAndClears() async throws {
        let r = try await makeRig()
        r.coordinator.play(a, upcoming: [b])
        #expect(await waitFor { r.backend.loads.count == 1 })
        r.coordinator.closeSession()
        #expect(r.backend.stopped == 1); #expect(r.coordinator.queue.queue.current == nil); #expect(!r.coordinator.isPlayerPresented)
        r.coordinator.shutdown()
    }
}

@MainActor @Suite struct NowPlayingInfoTests {
    @Test func infoContainsTheRequiredFields() {
        let v = makeVideo(title: "Hello")
        let info = NowPlayingManager.makeInfo(video: v, duration: .seconds(100), position: .seconds(10), rate: 1.5, isPlaying: true)
        #expect(info[MPMediaItemPropertyTitle] as? String == "Hello")
        #expect(info[MPMediaItemPropertyArtist] as? String == "Chan")
        #expect(info[MPMediaItemPropertyPlaybackDuration] as? Double == 100)
        #expect(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 10)
        #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1.5)
        let paused = NowPlayingManager.makeInfo(video: v, duration: nil, position: .zero, rate: 1.5, isPlaying: false)
        #expect(paused[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)
    }
}
