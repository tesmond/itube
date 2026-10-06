import CryptoKit
import Foundation

/// Cookie-based Google sign-in for the web InnerTube client. Cookies are kept only in the Keychain and are
/// injected per request, never into a shared cookie jar (ADR §51). Note: this is an undocumented mechanism.
public actor YouTubeAuthentication: AuthenticationProvider {
    static let allowedCookieNames: Set<String> = [
        "SID", "HSID", "SSID", "APISID", "SAPISID", "__Secure-1PSID", "__Secure-3PSID", "__Secure-1PAPISID", "__Secure-3PAPISID",
        "LOGIN_INFO", "__Secure-1PSIDTS", "__Secure-3PSIDTS", "SIDCC", "__Secure-1PSIDCC", "__Secure-3PSIDCC",
        "PREF", "VISITOR_INFO1_LIVE", "YSC",
    ]
    private static let account = "youtube.cookies.v1"

    private let secrets: any SecretStoring
    private let origin: String
    private let clock: @Sendable () -> Date
    private var cookies: [StoredCookie]
    private var loaded: Bool

    public init(secrets: any SecretStoring = KeychainStore(), origin: String = "https://www.youtube.com", clock: @escaping @Sendable () -> Date = { .now }) {
        self.secrets = secrets; self.origin = origin; self.clock = clock
        self.cookies = []; self.loaded = false
    }

    public var isSignedIn: Bool {
        loadIfNeeded()
        return sapisid != nil
    }

    public func authorize(_ request: URLRequest) async -> URLRequest {
        loadIfNeeded()
        guard let url = request.url, let host = url.host()?.lowercased(), host == "youtube.com" || host.hasSuffix(".youtube.com"),
              url.scheme == "https", let sapisid else { return request }
        var r = request
        let live = cookies.filter { !$0.isExpired(now: clock()) && $0.matches(host: host) }
        r.setValue(live.map { "\($0.name)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        let ts = Int(clock().timeIntervalSince1970)
        r.setValue(Self.sapisidHash(sapisid: sapisid, origin: origin, timestamp: ts), forHTTPHeaderField: "Authorization")
        r.setValue(origin, forHTTPHeaderField: "X-Origin")
        r.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
        return r
    }

    public func signIn(cookies incoming: [StoredCookie]) async throws {
        let filtered = incoming.filter {
            Self.allowedCookieNames.contains($0.name) && !$0.isExpired(now: clock())
                && ($0.domain.hasSuffix("youtube.com") || $0.domain.hasSuffix("google.com"))
        }
        guard filtered.contains(where: { $0.name == "SAPISID" || $0.name == "__Secure-3PAPISID" }) else {
            throw ProviderError.authenticationRequired
        }
        try secrets.write(JSONEncoder().encode(filtered), account: Self.account)
        cookies = filtered
        loaded = true
    }

    public func signOut() async {
        secrets.delete(account: Self.account)
        cookies = []
        loaded = true
    }

    private var sapisid: String? {
        cookies.first { $0.name == "SAPISID" }?.value ?? cookies.first { $0.name == "__Secure-3PAPISID" }?.value
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let data = secrets.read(account: Self.account), let stored = try? JSONDecoder().decode([StoredCookie].self, from: data) {
            cookies = stored
        }
    }

    /// `SAPISIDHASH <timestamp>_<sha1("<timestamp> <sapisid> <origin>")>`
    public static func sapisidHash(sapisid: String, origin: String, timestamp: Int) -> String {
        let digest = Insecure.SHA1.hash(data: Data("\(timestamp) \(sapisid) \(origin)".utf8))
        return "SAPISIDHASH \(timestamp)_\(digest.map { String(format: "%02x", $0) }.joined())"
    }
}
