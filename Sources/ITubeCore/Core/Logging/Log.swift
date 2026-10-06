import Foundation
import OSLog

/// Structured logging (ADR §53). Subsystems are categories of one app subsystem.
public enum Log {
    public static let subsystem = "com.tesmond.itube"
    public static let application = Logger(subsystem: subsystem, category: "application")
    public static let network = Logger(subsystem: subsystem, category: "network")
    public static let provider = Logger(subsystem: subsystem, category: "provider")
    public static let playback = Logger(subsystem: subsystem, category: "playback")
    public static let pip = Logger(subsystem: subsystem, category: "pip")
    public static let audio = Logger(subsystem: subsystem, category: "audio")
    public static let cache = Logger(subsystem: subsystem, category: "cache")
    public static let adFilter = Logger(subsystem: subsystem, category: "advertising-filter")
}

/// URLs can carry signed query parameters or private identifiers, so only the host is ever logged.
public enum URLRedactor {
    public static func redact(_ url: URL?) -> String {
        guard let url, let host = url.host() else { return "<invalid-url>" }
        let hasPath = url.path().count > 1
        let hasQuery = url.query() != nil
        return host + (hasPath ? "/…" : "") + (hasQuery ? "?…" : "")
    }
}
