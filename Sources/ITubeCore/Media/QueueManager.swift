import Foundation
import Observation

/// The persistent play queue (ADR §35). Bounded in both directions so it can't grow without limit (§56).
@MainActor @Observable
public final class QueueManager {
    public private(set) var queue = PlaybackQueue()
    @ObservationIgnored public var onChange: (@MainActor (PlaybackQueue) -> Void)?

    public init() {}

    public func restore(_ restored: PlaybackQueue) { queue = restored; changed() }

    /// Makes `video` current. The previous current video moves to history; `upcoming` replaces the list when provided.
    public func start(with video: Video, upcoming: [Video]? = nil) {
        if let current = queue.current, current.id != video.id {
            queue.previous.append(current)
            if queue.previous.count > PlaybackQueue.maxPrevious { queue.previous.removeFirst(queue.previous.count - PlaybackQueue.maxPrevious) }
        }
        queue.current = video
        if let upcoming { queue.upcoming = Array(upcoming.filter { $0.id != video.id }.prefix(PlaybackQueue.maxUpcoming)) }
        else { queue.upcoming.removeAll { $0.id == video.id } }
        changed()
    }

    public func enqueue(_ video: Video) {
        guard queue.current?.id != video.id, !queue.upcoming.contains(where: { $0.id == video.id }),
              queue.upcoming.count < PlaybackQueue.maxUpcoming else { return }
        queue.upcoming.append(video); changed()
    }

    public func playNext(_ video: Video) {
        queue.upcoming.removeAll { $0.id == video.id }
        queue.upcoming.insert(video, at: 0)
        if queue.upcoming.count > PlaybackQueue.maxUpcoming { queue.upcoming.removeLast() }
        changed()
    }

    public func remove(_ id: VideoID) { queue.upcoming.removeAll { $0.id == id }; changed() }

    public func move(from source: IndexSet, to destination: Int) {
        queue.upcoming.move(fromOffsets: source, toOffset: destination); changed()
    }

    public func clearUpcoming() { queue.upcoming.removeAll(); changed() }
    public func clearAll() { queue = PlaybackQueue(); changed() }

    @discardableResult
    public func advance() -> Video? {
        guard !queue.upcoming.isEmpty else { return nil }
        let next = queue.upcoming.removeFirst()
        if let current = queue.current { queue.previous.append(current) }
        if queue.previous.count > PlaybackQueue.maxPrevious { queue.previous.removeFirst() }
        queue.current = next
        changed()
        return next
    }

    @discardableResult
    public func retreat() -> Video? {
        guard let prev = queue.previous.popLast() else { return nil }
        if let current = queue.current { queue.upcoming.insert(current, at: 0) }
        queue.current = prev
        changed()
        return prev
    }

    private func changed() { onChange?(queue) }
}

public enum SleepTimerOption: Hashable, Sendable, Identifiable {
    case minutes(Int)
    case endOfVideo

    public static let all: [SleepTimerOption] = [5, 10, 15, 30, 45, 60].map(SleepTimerOption.minutes) + [.endOfVideo]
    public var id: String { switch self { case .minutes(let m): "m\(m)"; case .endOfVideo: "end" } }
    public var title: String { switch self { case .minutes(let m): "\(m) minutes"; case .endOfVideo: "End of video" } }
}

/// One sleeping `Task` — no polling timer. Pauses playback; never terminates the app (ADR §32).
@MainActor @Observable
public final class SleepTimer {
    public private(set) var option: SleepTimerOption?
    public private(set) var fireDate: Date?
    @ObservationIgnored public var onFire: (@MainActor () -> Void)?
    @ObservationIgnored private var task: Task<Void, Never>?

    public init() {}

    public func start(_ option: SleepTimerOption) {
        cancel()
        self.option = option
        guard case .minutes(let m) = option else { return }
        fireDate = Date.now.addingTimeInterval(TimeInterval(m * 60))
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(m * 60))
            guard !Task.isCancelled else { return }
            self?.fire()
        }
    }

    public func cancel() { task?.cancel(); task = nil; option = nil; fireDate = nil }

    /// Returns true when an end-of-video timer consumed the end event (so autoplay must not continue).
    public func consumeVideoEnd() -> Bool {
        guard option == .endOfVideo else { return false }
        cancel(); onFire?()
        return true
    }

    private func fire() { cancel(); onFire?() }
}
