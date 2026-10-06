import Foundation

public struct StoredCookie: Codable, Sendable, Equatable {
    public var name: String
    public var value: String
    public var domain: String
    public var path: String
    public var expires: Date?
    public var isSecure: Bool

    public init(name: String, value: String, domain: String, path: String = "/", expires: Date? = nil, isSecure: Bool = true) {
        self.name = name; self.value = value; self.domain = domain; self.path = path; self.expires = expires; self.isSecure = isSecure
    }

    public func isExpired(now: Date = .now) -> Bool { expires.map { $0 <= now } ?? false }

    func matches(host: String) -> Bool {
        let d = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        return host == d || host.hasSuffix("." + d)
    }
}

/// Provider authentication is isolated behind this protocol (ADR §51). Credentials live in the Keychain only.
public protocol AuthenticationProvider: Sendable {
    var isSignedIn: Bool { get async }
    /// Returns the request with authentication applied, or unchanged when signed out / not applicable.
    func authorize(_ request: URLRequest) async -> URLRequest
    func signIn(cookies: [StoredCookie]) async throws
    func signOut() async
}

public struct AnonymousAuthenticationProvider: AuthenticationProvider {
    public init() {}
    public var isSignedIn: Bool { get async { false } }
    public func authorize(_ request: URLRequest) async -> URLRequest { request }
    public func signIn(cookies: [StoredCookie]) async throws { throw ProviderError.unsupported }
    public func signOut() async {}
}
