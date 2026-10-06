import Foundation

/// Phantom-typed string identifier so a `VideoID` can never be passed where a `ChannelID` is expected.
public struct Identifier<Tag: Sendable>: Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    public var description: String { rawValue }
}

public enum VideoTag: Sendable {}
public enum ChannelTag: Sendable {}
public enum PlaylistTag: Sendable {}

public typealias VideoID = Identifier<VideoTag>
public typealias ChannelID = Identifier<ChannelTag>
public typealias PlaylistID = Identifier<PlaylistTag>

extension VideoID {
    /// Video identifiers arrive from deep links and remote JSON; only accept the shape we expect (ADR §70).
    public var isWellFormed: Bool {
        rawValue.utf8.count == 11 && rawValue.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D || $0 == 0x5F
        }
    }
}

extension Duration {
    public init(seconds value: Double) {
        self = .seconds(value.isFinite ? max(0, value) : 0)
    }
    public var totalSeconds: Double {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
    /// "1:02:03" / "4:05"
    public var clockString: String {
        let total = Int(totalSeconds.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
