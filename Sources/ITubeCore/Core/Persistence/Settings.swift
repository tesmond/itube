import Foundation
import Observation

public struct AppSettings: Codable, Equatable, Sendable {
    public var defaultQuality: VideoQuality = .auto
    public var wifiQuality: VideoQuality = .auto
    public var mobileQuality: VideoQuality = .p480
    public var playbackSpeed: Float = 1.0
    public var backgroundPlayback = true
    public var automaticPiP = true
    public var adSuppression = true          // ADR §73: default on where available and permitted
    public var sponsorSkipping = false
    public var skipCategories: Set<SegmentCategory> = [.sponsor]
    public var captionsEnabled = false
    public var captionLanguage: String?
    public var autoplay = true
    public var historyEnabled = true
    public var searchHistoryEnabled = true
    public var restartThreshold: Double = 0.95   // ADR §38: >95% watched → restart
    public var useMobileQualityOnCellular = true

    public init() {}

    public func quality(isExpensiveNetwork: Bool) -> VideoQuality {
        guard useMobileQualityOnCellular else { return defaultQuality }
        return isExpensiveNetwork ? mobileQuality : (wifiQuality == .auto ? defaultQuality : wifiQuality)
    }
}

/// UserDefaults is thread-safe; the value is a small Codable blob (never credentials — those use the Keychain).
public struct SettingsStore: Sendable {
    nonisolated(unsafe) private let defaults: UserDefaults
    private let key = "itube.settings.v1"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load() -> AppSettings {
        guard let data = defaults.data(forKey: key), let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }
    public func save(_ settings: AppSettings) {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: key) }
    }
    public func reset() { defaults.removeObject(forKey: key) }
}

@MainActor @Observable
public final class SettingsManager {
    public var settings: AppSettings { didSet { if settings != oldValue { store.save(settings) } } }
    @ObservationIgnored private let store: SettingsStore

    public init(store: SettingsStore = SettingsStore()) {
        self.store = store
        self.settings = store.load()
    }
}
