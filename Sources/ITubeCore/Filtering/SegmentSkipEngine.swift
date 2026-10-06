import Foundation

/// User-configurable sponsor/intro/outro skipping — deliberately independent of ad suppression (ADR §24).
/// Only provider-supplied metadata is used; nothing is fetched from third-party services.
public struct SegmentSkipEngine: Sendable {
    public init() {}

    public func skipRanges(for resource: PlaybackResource, categories: Set<SegmentCategory>, enabled: Bool) -> [ClosedRange<Duration>] {
        guard enabled, !categories.isEmpty else { return [] }
        let ranges = resource.segments.compactMap { seg -> ClosedRange<Duration>? in
            guard let category = seg.category, categories.contains(category) else { return nil }
            return seg.range
        }
        return Self.merge(ranges)
    }

    static func merge(_ ranges: [ClosedRange<Duration>]) -> [ClosedRange<Duration>] {
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var out: [ClosedRange<Duration>] = []
        for r in sorted {
            if let last = out.last, r.lowerBound <= last.upperBound {
                out[out.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
            } else {
                out.append(r)
            }
        }
        return out
    }
}
