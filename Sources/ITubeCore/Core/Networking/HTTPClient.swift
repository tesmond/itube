import Foundation

public enum HTTPError: Error, Sendable, Equatable {
    case insecureScheme
    case blockedByPolicy
    case status(Int)
    case responseTooLarge
    case invalidResponse
}

/// The only way provider code touches the network (ADR §39). Never `URLSession.shared`.
public protocol HTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// `URLSession` wrapper: HTTPS only (§70), cookie-isolated (§51), bounded caches and response sizes (§56).
public final class URLSessionHTTPClient: HTTPClient {
    private let session: URLSession
    private let maxResponseBytes: Int

    public init(maxResponseBytes: Int = 8 * 1024 * 1024, configuration: URLSessionConfiguration = .ephemeral) {
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        configuration.requestCachePolicy = .useProtocolCachePolicy
        configuration.urlCache = URLCache(memoryCapacity: 4 * 1024 * 1024, diskCapacity: 50 * 1024 * 1024)
        self.session = URLSession(configuration: configuration)
        self.maxResponseBytes = maxResponseBytes
    }

    deinit { session.finishTasksAndInvalidate() }

    public func clearCache() { session.configuration.urlCache?.removeAllCachedResponses() }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard request.url?.scheme?.lowercased() == "https" else { throw HTTPError.insecureScheme }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HTTPError.invalidResponse }
        guard data.count <= maxResponseBytes else { throw HTTPError.responseTooLarge }
        guard (200..<300).contains(http.statusCode) else { throw HTTPError.status(http.statusCode) }
        return (data, http)
    }
}

/// Applies a `RequestPolicy` in front of any client; call sites stay unaware of filtering (§21).
public struct PolicyEnforcingHTTPClient: HTTPClient {
    private let base: any HTTPClient
    private let policy: any RequestPolicy

    public init(base: any HTTPClient, policy: any RequestPolicy) {
        self.base = base; self.policy = policy
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if policy.evaluate(request) == .deny {
            Log.adFilter.debug("Blocked request to \(URLRedactor.redact(request.url), privacy: .public)")
            throw HTTPError.blockedByPolicy
        }
        return try await base.data(for: request)
    }
}

/// Bounded exponential backoff for transient failures only (ADR §48).
public struct RetryingHTTPClient: HTTPClient {
    private let base: any HTTPClient
    private let delays: [Duration]
    private let sleep: @Sendable (Duration) async throws -> Void

    public init(
        base: any HTTPClient,
        delays: [Duration] = [.milliseconds(250), .milliseconds(500), .seconds(1)],
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.base = base; self.delays = delays; self.sleep = sleep
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            do {
                return try await base.data(for: request)
            } catch {
                guard attempt < delays.count, Self.isTransient(error) else { throw error }
                try await sleep(delays[attempt])
                try Task.checkCancellation()
                attempt += 1
            }
        }
    }

    /// Permanent failures (4xx other than 408/429, blocked, insecure) fail immediately.
    static func isTransient(_ error: any Error) -> Bool {
        switch error {
        case let e as HTTPError:
            if case .status(let code) = e { return code == 408 || code == 429 || [500, 502, 503, 504].contains(code) }
            return false
        case let e as URLError:
            return [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(e.code)
        default:
            return false
        }
    }
}
