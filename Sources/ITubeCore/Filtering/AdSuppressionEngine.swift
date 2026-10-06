import Foundation

/// Data-only classification rules (ADR §20, §70). Rules are decoded from data, never evaluated as code.
public struct AdRuleSet: Codable, Sendable, Equatable {
    public var version: Int
    public var blockedHosts: [String]

    public static let `default` = AdRuleSet(version: 1, blockedHosts: DomainDenylistPolicy.defaultDomains)

    public init(version: Int, blockedHosts: [String]) { self.version = version; self.blockedHosts = blockedHosts }

    /// A malformed or older rule update returns nil so the previous rules stay active and playback is unaffected (ADR §65).
    public static func decode(_ data: Data, replacing current: AdRuleSet) -> AdRuleSet? {
        guard let candidate = try? JSONDecoder().decode(AdRuleSet.self, from: data), candidate.version > current.version else { return nil }
        let hosts = candidate.blockedHosts.map { $0.lowercased() }.filter { $0.contains(".") && !$0.contains("/") && !$0.contains(" ") }
        return AdRuleSet(version: candidate.version, blockedHosts: hosts)
    }
}

public protocol AdClassifying: Sendable {
    func classify(_ stream: MediaStream) -> SegmentClassification
    func classify(_ segment: MediaSegment) -> SegmentClassification
}

/// Conservative classifier: only an explicit match is `.advertisement`; everything ambiguous stays `.unknown`
/// and is therefore *kept*, so a false positive can never make a requested video unplayable (ADR §23).
public struct RuleBasedAdClassifier: AdClassifying {
    private let rules: AdRuleSet
    public init(rules: AdRuleSet = .default) { self.rules = rules }

    private func isBlocked(_ url: URL?) -> Bool {
        guard let host = url?.host()?.lowercased() else { return false }
        return rules.blockedHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    public func classify(_ stream: MediaStream) -> SegmentClassification {
        isBlocked(stream.url) ? .advertisement : .unknown
    }

    public func classify(_ segment: MediaSegment) -> SegmentClassification {
        if segment.kind != .unknown { return segment.kind }
        return isBlocked(segment.url) ? .advertisement : .unknown
    }
}

/// Sits between the provider and the stream selector (ADR §19). The playback engine never sees ad logic.
public struct AdSuppressionEngine: Sendable {
    private let classifier: any AdClassifying
    public init(classifier: any AdClassifying = RuleBasedAdClassifier()) { self.classifier = classifier }

    public func process(_ resource: PlaybackResource, enabled: Bool) -> PlaybackResource {
        guard enabled else { return resource }
        let video = resource.videoStreams.filter { classifier.classify($0) != .advertisement }
        let audio = resource.audioStreams.filter { classifier.classify($0) != .advertisement }
        let segments = resource.segments.map {
            MediaSegment(url: $0.url, range: $0.range, kind: classifier.classify($0), category: $0.category)
        }
        // Never strip every playable stream — an ambiguous resource must still play.
        guard !video.isEmpty else { return resource }
        return resource.replacing(videoStreams: video, audioStreams: audio, segments: segments)
    }

    /// Time ranges of provider-identified advertisements, for the engine to seek past (only when explicitly marked).
    public func advertisementRanges(in resource: PlaybackResource, enabled: Bool) -> [ClosedRange<Duration>] {
        guard enabled else { return [] }
        return SegmentSkipEngine.merge(resource.segments.compactMap { $0.kind == .advertisement ? $0.range : nil })
    }
}
