import Foundation

public struct HLSVariant: Sendable, Equatable {
    public let bandwidth: Int
    public let width: Int?
    public let height: Int?
    public let codecs: String?
}

public enum HLSMasterPlaylist {
    /// Extracts `#EXT-X-STREAM-INF` variants. Tolerant by design: unknown tags are ignored.
    public static func parse(_ text: String) -> [HLSVariant] {
        var variants: [HLSVariant] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("#EXT-X-STREAM-INF:") else { continue }
            let attrs = parseAttributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
            guard let bw = attrs["BANDWIDTH"].flatMap(Int.init) else { continue }
            var w: Int?, h: Int?
            if let res = attrs["RESOLUTION"] {
                let parts = res.split(separator: "x")
                if parts.count == 2 { w = Int(parts[0]); h = Int(parts[1]) }
            }
            variants.append(HLSVariant(bandwidth: bw, width: w, height: h, codecs: attrs["CODECS"]))
        }
        return variants
    }

    static func parseAttributes(_ s: String) -> [String: String] {
        var result: [String: String] = [:]
        var key = "", value = "", inKey = true, inQuotes = false
        func flush() { if !key.isEmpty { result[key] = value }; key = ""; value = ""; inKey = true }
        for ch in s {
            if inQuotes {
                if ch == "\"" { inQuotes = false } else { value.append(ch) }
            } else if ch == "\"" {
                inQuotes = true
            } else if ch == "," {
                flush()
            } else if ch == "=" && inKey {
                inKey = false
            } else if inKey {
                key.append(ch)
            } else {
                value.append(ch)
            }
        }
        flush()
        return result
    }
}

/// Fetches a master playlist only to learn which resolutions exist (for the quality menu).
public struct ManifestLoader: Sendable {
    private let http: any HTTPClient
    public init(http: any HTTPClient) { self.http = http }

    public func variantHeights(for url: URL, userAgent: String?) async throws -> [Int] {
        var request = URLRequest(url: url)
        if let userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        let (data, _) = try await http.data(for: request)
        guard let text = String(data: data, encoding: .utf8) else { throw PlaybackError.invalidManifest }
        let variants = HLSMasterPlaylist.parse(text)
        let heights = variants.compactMap { v -> Int? in
            guard let h = v.height else { return nil }
            return min(h, v.width ?? h)
        }
        return Array(Set(heights)).sorted()
    }
}
